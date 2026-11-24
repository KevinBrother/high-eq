package httpjson

import (
	"bytes"
	"errors"
	"io"
	"net/http/httptest"
	"testing"
)

func TestReadStrictUTF8PreservesValidMultibyteAndReplacementCharacter(t *testing.T) {
	raw := []byte(`{"text":"合法多字节 �"}`)
	req := httptest.NewRequest("POST", "/", bytes.NewReader(raw))
	w := httptest.NewRecorder()

	got, err := ReadStrictUTF8(w, req, 256)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, raw) {
		t.Fatalf("body changed: got %q want %q", got, raw)
	}
	replayed, err := io.ReadAll(req.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(replayed, raw) {
		t.Fatalf("restored body=%q want %q", replayed, raw)
	}
}

func TestReadStrictUTF8RejectsInvalidRawBytes(t *testing.T) {
	raw := append([]byte(`{"text":"非法`), 0xff)
	raw = append(raw, []byte(`"}`)...)
	req := httptest.NewRequest("POST", "/", bytes.NewReader(raw))
	w := httptest.NewRecorder()

	if _, err := ReadStrictUTF8(w, req, 256); !errors.Is(err, ErrInvalidUTF8) {
		t.Fatalf("err=%v want ErrInvalidUTF8", err)
	}
}

func TestReadStrictUTF8PreservesBodyLimit(t *testing.T) {
	raw := []byte(`{"a":1}`)
	for _, tc := range []struct {
		limit int64
		ok    bool
	}{
		{limit: int64(len(raw)), ok: true},
		{limit: int64(len(raw) - 1), ok: false},
	} {
		req := httptest.NewRequest("POST", "/", bytes.NewReader(raw))
		w := httptest.NewRecorder()
		_, err := ReadStrictUTF8(w, req, tc.limit)
		if tc.ok && err != nil {
			t.Fatalf("limit=%d rejected exact body: %v", tc.limit, err)
		}
		if !tc.ok && err == nil {
			t.Fatalf("limit=%d accepted oversized body", tc.limit)
		}
	}
}
