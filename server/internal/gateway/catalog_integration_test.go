//go:build integration

package gateway

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/fieldcrypt"
)

// Run in the disposable runtime.sh stack with a loopback TLS provider only.
func TestGatewayHotUpdate(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	db, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	must(err)
	defer db.Close()
	opt, err := redis.ParseURL(os.Getenv("REDIS_URL"))
	must(err)
	cache := redis.NewClient(opt)
	defer cache.Close()
	k := make([]byte, 32)
	_, err = rand.Read(k)
	must(err)
	fields, err := fieldcrypt.New(1, map[uint32][]byte{1: k})
	must(err)
	var calls atomic.Int32
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		var body struct{ Model string }
		if json.NewDecoder(r.Body).Decode(&body) != nil || r.Header.Get("Authorization") != "Bearer key-only-"+body.Model {
			t.Error("model/key mismatch")
		}
		fmt.Fprintf(w, `{"choices":[{"message":{"content":%q},"finish_reason":"stop"}]}`, body.Model)
	}))
	defer s.Close()
	catalog, err := Start(ctx, db, cache, fields)
	must(err)
	defer catalog.Close()
	catalog.adapters["openai_compatible"] = compatible{noRedirect(s.Client().Transport)}
	id := uuid.New()
	ref := uuid.NewString()
	cfg := Config{ID: id, Name: "fixture", Provider: "fake", Endpoint: s.URL, ModelName: "one", AdmissionRef: ref, Enabled: true, Kind: Model, Protocol: "openai_compatible"}
	save := func() error { return catalog.Save(ctx, cfg, []byte("key-only-"+cfg.ModelName)) }
	defer func() {
		db.Exec(ctx, `delete from model_configs where id=$1`, id)
		db.Exec(ctx, `delete from provider_admissions where ref=$1`, ref)
	}()
	if !errors.Is(save(), ErrConfig) {
		t.Fatal("enabled without admission")
	}
	insert := `insert into provider_admissions(ref,provider,endpoint,model_scope,kind,purpose,sent_fields,processing_country,storage_country,cross_border,max_retention_days,deletion_method,terms_evidence) values($1,'fake',$2,'one','model','synthetic test',ARRAY['model','messages.role','messages.content','stream','response_format.type'],$3,$4,$5,$6,$7,$8)`
	for _, bad := range [][]any{{"?", "CN", false, 0, "auto", "evidence"}, {"CN", "?", false, 0, "auto", "evidence"}, {"CN", "CN", true, 0, "auto", "evidence"}, {"CN", "CN", false, nil, "auto", "evidence"}, {"CN", "CN", false, 0, " ", "evidence"}, {"CN", "CN", false, 0, "auto", "\n\t"}} {
		if _, err := db.Exec(ctx, insert, append([]any{ref, s.URL}, bad...)...); err == nil {
			t.Fatal("incomplete evidence admitted")
		}
	}
	_, err = db.Exec(ctx, insert, ref, s.URL, "CN", "CN", false, 0, "auto", "fixture-terms")
	must(err)
	cfg.ModelName = "unapproved"
	if !errors.Is(save(), ErrConfig) {
		t.Fatal("model outside contract enabled")
	}
	cfg.ModelName = "one"
	// A distinct, explicitly endpoint-wide contract covers both synthetic models.
	_, err = db.Exec(ctx, `update provider_admissions set model_scope='*' where ref=$1`, ref)
	must(err)
	cfg.Kind = Moderation
	if !errors.Is(save(), ErrConfig) {
		t.Fatal("model approval reused for moderation")
	}
	cfg.Kind = Model
	cfg.Endpoint += "/unreviewed"
	if !errors.Is(save(), ErrConfig) {
		t.Fatal("approval reused for different endpoint")
	}
	cfg.Endpoint = s.URL
	must(save())
	var blob []byte
	must(db.QueryRow(ctx, `select api_key_enc from model_configs where id=$1`, id).Scan(&blob))
	if bytes.Contains(blob, []byte("key-only")) {
		t.Fatal("plaintext stored")
	}
	if _, err := fields.Open(blob, keyAAD(uuid.New())); err == nil {
		t.Fatal("envelope accepted for another row")
	}
	resolve := func(_ context.Context, task string) (uuid.UUID, error) {
		if task != "scoring" {
			t.Fatal("task lost")
		}
		return id, nil
	}
	req := Request{Mode: Text, Messages: []Message{{"user", "虚构"}}}
	chat := catalog.ForTasks(Model, resolve)
	call := func(want string) {
		t.Helper()
		out, err := chat.Chat(ctx, "scoring", req)
		must(err)
		if out.Text != want {
			t.Fatal("stale provider config")
		}
	}
	call("one")
	if _, err := catalog.ForTasks(Moderation, resolve).Chat(ctx, "scoring", req); !errors.Is(err, ErrConfig) {
		t.Fatal("wrong kind dispatched")
	}
	cfg.ModelName = "two"
	must(save())
	var version uuid.UUID
	must(db.QueryRow(ctx, "select version from gateway_revision").Scan(&version))
	deadline := time.Now().Add(5 * time.Second)
	for catalog.version() != version {
		if time.Now().After(deadline) {
			t.Fatal("notification did not proactively reload")
		}
		time.Sleep(10 * time.Millisecond)
	}
	call("two")
	// No Redis publish: revocation must still protect the very next dispatch.
	_, err = db.Exec(ctx, `update model_configs set enabled=false where id=$1`, id)
	must(err)
	if _, err := chat.Chat(ctx, "scoring", req); !errors.Is(err, ErrConfig) || calls.Load() != 2 {
		t.Fatal("stale config contacted provider")
	}
}
