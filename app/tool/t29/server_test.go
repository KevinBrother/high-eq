//go:build t29live

// Mounted into the T30 service test package only in an isolated Compose job.
package service

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/emotion"
)

func TestT29LiveServer(t *testing.T) {
	token := os.Getenv("T29_FIXTURE_TOKEN")
	if token == "" {
		t.Fatal("T29_FIXTURE_TOKEN is required")
	}

	ctx := context.Background()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	app := s.Router()

	writeJSON := func(w http.ResponseWriter, status int, value any) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(status)
		if err := json.NewEncoder(w).Encode(value); err != nil {
			t.Errorf("write fixture response: %v", err)
		}
	}
	authorized := func(r *http.Request) bool {
		got := r.Header.Get("X-T29-Fixture-Token")
		return len(got) == len(token) &&
			subtle.ConstantTimeCompare([]byte(got), []byte(token)) == 1
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/__t29/member":
			if !authorized(r) {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			if r.Method != http.MethodPost {
				w.Header().Set("Allow", http.MethodPost)
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			var in struct {
				UserID string `json:"user_id"`
			}
			decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&in); err != nil {
				http.Error(w, "invalid fixture request", http.StatusBadRequest)
				return
			}
			if err := decoder.Decode(&struct{}{}); err != io.EOF {
				http.Error(w, "invalid fixture request", http.StatusBadRequest)
				return
			}
			user, err := uuid.Parse(in.UserID)
			if err != nil {
				http.Error(w, "invalid user_id", http.StatusBadRequest)
				return
			}
			if err := t29FixtureMember(ctx, s, user); err != nil {
				t.Errorf("fixture member: %v", err)
				http.Error(w, "fixture setup failed", http.StatusInternalServerError)
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"user_id": user.String(),
				"member":  true,
			})
		case "/__t29/windows":
			if !authorized(r) {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			if r.Method != http.MethodGet {
				w.Header().Set("Allow", http.MethodGet)
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			user, err := uuid.Parse(r.URL.Query().Get("user_id"))
			if err != nil {
				http.Error(w, "invalid user_id", http.StatusBadRequest)
				return
			}
			windows, err := t29FixtureWindows(ctx, s, user)
			if err != nil {
				t.Errorf("fixture windows: %v", err)
				http.Error(w, "fixture read failed", http.StatusInternalServerError)
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"windows": windows})
		default:
			app.ServeHTTP(w, r)
		}
	})

	// Compose publishes this port only on the host's 127.0.0.1 interface.
	server := &http.Server{
		Addr:              ":8080",
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	t.Fatal(server.ListenAndServe())
}

func t29FixtureMember(
	ctx context.Context,
	s *Runtime,
	user uuid.UUID,
) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var orderID uuid.UUID
	if err := tx.QueryRow(ctx, `
		insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
		values($1,'apple',$2,'fixture',1,'paid')
		returning id`, user, []byte(uuid.NewString())).Scan(&orderID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		insert into entitlements(order_id,user_id,starts_at,ends_at)
		values($1,$2,now()-interval '181 days',now()+interval '1 day')`, orderID, user); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func t29FixtureWindows(ctx context.Context, s *Runtime, user uuid.UUID) ([]emotion.Window, error) {
	rows, err := s.db.Query(ctx, `
		select purge_id, stats_enc
		from signal_windows
		where user_id=$1 and channel='voice'
		order by starts_at`, user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	windows := []emotion.Window{}
	for rows.Next() {
		var purgeID uuid.UUID
		var encrypted []byte
		if err := rows.Scan(&purgeID, &encrypted); err != nil {
			return nil, err
		}
		plain, err := s.Fields.Open(
			encrypted,
			[]byte("window/"+user.String()+"/"+purgeID.String()),
		)
		if err != nil {
			return nil, err
		}
		var window emotion.Window
		if err := json.Unmarshal(plain, &window); err != nil {
			return nil, err
		}
		windows = append(windows, window)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return windows, nil
}
