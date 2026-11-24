package service

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func writeTestArchive(z *zip.Writer) error {
	f, err := z.Create("manifest.json")
	if err != nil {
		return err
	}
	_, err = io.WriteString(f, `{"files":["manifest.json"]}`)
	return err
}

func TestStreamingExportWritesBeforeCommitReturns(t *testing.T) {
	var response bytes.Buffer
	wrote := make(chan int, 1)
	release := make(chan struct{})
	result := make(chan error, 1)
	payload := make([]byte, 8<<20)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}

	go func() {
		result <- withStreamingExport(&response, func(z *zip.Writer) error {
			f, err := z.Create("large.bin")
			if err != nil {
				return err
			}
			if _, err = f.Write(payload); err != nil {
				return err
			}
			wrote <- response.Len()
			<-release
			return nil
		})
	}()

	var streamed int
	select {
	case streamed = <-wrote:
	case <-time.After(30 * time.Second):
		close(release)
		t.Fatal("producer did not reach the streaming checkpoint")
	}
	close(release)
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	if streamed == 0 {
		t.Fatal("export was staged instead of streamed to the response")
	}
	if _, err := zip.NewReader(bytes.NewReader(response.Bytes()), int64(response.Len())); err != nil {
		t.Fatalf("streamed response is not a readable ZIP: %v", err)
	}
}

func TestStreamingExportDoesNotCloseOnCommitFailure(t *testing.T) {
	var response bytes.Buffer
	commitFailure := errors.New("transaction commit failed")

	payload := make([]byte, 8<<20)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	err := withStreamingExport(&response, func(z *zip.Writer) error {
		if err := writeTestArchive(z); err != nil {
			return err
		}
		f, err := z.Create("large.bin")
		if err != nil {
			return err
		}
		if _, err = f.Write(payload); err != nil {
			return err
		}
		return commitFailure
	})

	if !errors.Is(err, commitFailure) {
		t.Fatalf("error = %v, want %v", err, commitFailure)
	}
	if response.Len() == 0 || !bytes.HasPrefix(response.Bytes(), []byte("PK\x03\x04")) {
		t.Fatalf("failed commit did not preserve a ZIP prefix: %q", response.Bytes())
	}
	if bytes.Contains(response.Bytes(), []byte(`"internal_error"`)) {
		t.Fatal("failed commit appended a JSON error to the archive")
	}
	if _, err := zip.NewReader(bytes.NewReader(response.Bytes()), int64(response.Len())); err == nil {
		t.Fatal("failed commit produced a readable complete ZIP")
	}
}

func TestStreamingExportClosesAfterCommit(t *testing.T) {
	var response bytes.Buffer

	err := withStreamingExport(&response, func(z *zip.Writer) error {
		return writeTestArchive(z)
	})
	if err != nil {
		t.Fatal(err)
	}
	z, err := zip.NewReader(bytes.NewReader(response.Bytes()), int64(response.Len()))
	if err != nil {
		t.Fatalf("successful transaction returned unreadable ZIP: %v", err)
	}
	if len(z.File) != 1 || z.File[0].Name != "manifest.json" {
		t.Fatalf("unexpected archive entries: %+v", z.File)
	}
}

func TestExportLateFailureDoesNotEndAsNormalHTTP1Response(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := newLateFailureExportEngine(t, func() error { return errors.New("transaction commit failed") })
	client, server := net.Pipe()
	if err := client.SetDeadline(time.Now().Add(15 * time.Second)); err != nil {
		t.Fatal(err)
	}
	listener := &singleConnListener{conn: server, closed: make(chan struct{})}
	httpServer := &http.Server{Handler: engine}
	serveDone := make(chan error, 1)
	go func() { serveDone <- httpServer.Serve(listener) }()
	t.Cleanup(func() {
		_ = client.Close()
		_ = listener.Close()
		_ = httpServer.Close()
		<-serveDone
	})

	request, err := http.NewRequest(http.MethodGet, "http://export.test/v1/me/export", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fmt.Fprintf(client, "GET /v1/me/export HTTP/1.1\r\nHost: export.test\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(client), request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.ProtoMajor != 1 {
		t.Fatalf("test request used HTTP/%d, want HTTP/1.x", response.ProtoMajor)
	}
	if got := response.TransferEncoding; len(got) != 1 || got[0] != "chunked" {
		t.Fatalf("late failure transport encoding = %v, want chunked", got)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("streaming export status = %d, want 200", response.StatusCode)
	}
	body, readErr := io.ReadAll(response.Body)
	assertLateExportFailure(t, body, readErr)
}

func TestExportLateFailureAbortsHTTP2Stream(t *testing.T) {
	gin.SetMode(gin.TestMode)
	engine := newLateFailureExportEngine(t, func() error { return errors.New("transaction commit failed") })
	server := newTLSHTTP2Server(t, engine)
	defer server.Close()

	response, err := server.Client().Get(server.URL + "/v1/me/export")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.ProtoMajor != 2 {
		t.Fatalf("test request used HTTP/%d, want HTTP/2", response.ProtoMajor)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("streaming export status = %d, want 200", response.StatusCode)
	}
	body, readErr := io.ReadAll(response.Body)
	assertLateExportFailure(t, body, readErr)
}

func TestExportLatePanicAbortsResponse(t *testing.T) {
	engine := newLateFailureExportEngine(t, func() error { panic("export producer failed") })
	w := httptest.NewRecorder()
	defer func() {
		if got := recover(); got != http.ErrAbortHandler {
			t.Fatalf("late export panic = %v, want transport abort", got)
		}
		assertBrokenArchive(t, w.Body.Bytes())
	}()
	engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/me/export", nil))
}

func newLateFailureExportEngine(t *testing.T, fault func() error) *gin.Engine {
	t.Helper()
	payload := make([]byte, 128<<10)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	engine := gin.New()
	engine.Use(requestMiddleware())
	engine.GET("/v1/me/export", func(c *gin.Context) {
		c.Header("Content-Type", "application/zip")
		api := appAPI{}
		api.streamExport(c, func(z *zip.Writer) error {
			if err := writeTestArchive(z); err != nil {
				return err
			}
			f, err := z.Create("large.bin")
			if err != nil {
				return err
			}
			if _, err := f.Write(payload); err != nil {
				return err
			}
			return fault()
		})
	})
	return engine
}

func assertLateExportFailure(t *testing.T, body []byte, readErr error) {
	t.Helper()
	if readErr == nil {
		t.Fatalf("late export failure ended as a normal HTTP response (%d bytes)", len(body))
	}
	assertBrokenArchive(t, body)
}

func assertBrokenArchive(t *testing.T, body []byte) {
	t.Helper()
	if !bytes.HasPrefix(body, []byte("PK\x03\x04")) {
		t.Fatalf("late failure did not preserve a ZIP prefix: %q", body[:min(len(body), 16)])
	}
	if bytes.Contains(body, []byte(`"internal_error"`)) {
		t.Fatal("late failure appended a JSON error to the archive")
	}
	if _, err := zip.NewReader(bytes.NewReader(body), int64(len(body))); err == nil {
		t.Fatal("late failure exposed a readable complete ZIP")
	}
}

func newTLSHTTP2Server(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	defer func() {
		if recovered := recover(); recovered != nil {
			message := fmt.Sprint(recovered)
			if !strings.Contains(message, "failed to listen on a port") {
				panic(recovered)
			}
			t.Skipf("HTTP/2 listener unavailable in this environment: %s", message)
		}
	}()
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.StartTLS()
	return server
}

type singleConnListener struct {
	conn   net.Conn
	once   sync.Once
	mu     sync.Mutex
	closed chan struct{}
}

func (l *singleConnListener) Accept() (net.Conn, error) {
	var accepted net.Conn
	l.once.Do(func() { accepted = l.conn })
	if accepted != nil {
		return accepted, nil
	}
	<-l.closed
	return nil, net.ErrClosed
}

func (l *singleConnListener) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	select {
	case <-l.closed:
	default:
		close(l.closed)
	}
	return nil
}

func (l *singleConnListener) Addr() net.Addr { return l.conn.LocalAddr() }
