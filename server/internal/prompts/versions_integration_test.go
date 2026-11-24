//go:build integration

package prompts

import (
	"context"
	"os"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"high-eq/server/internal/api/admin"
	"high-eq/server/migrations"
)

func TestConcurrentDraftNumbers(t *testing.T) {
	ctx := context.Background()
	dsn := os.Getenv("DATABASE_URL")
	if err := migrations.Up(ctx, dsn); err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	const writers = 8
	type result struct {
		version int
		err     error
	}
	out := make(chan result, writers)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for range writers {
		wg.Go(func() {
			<-start
			var v admin.PromptVersion
			e := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
				var err error
				v, err = Create(ctx, tx, admin.CreatePromptVersionJSONBody{Task: admin.TaskReviewAnalysis, Template: "fixture"})
				return err
			})
			out <- result{v.Version, e}
		})
	}
	close(start)
	wg.Wait()
	close(out)
	seen := map[int]bool{}
	highest := 0
	for r := range out {
		if r.err != nil || r.version < 1 || seen[r.version] {
			t.Fatal("concurrent save failed", r.err)
		}
		seen[r.version] = true
		highest = max(highest, r.version)
	}
	for i := range writers {
		if !seen[highest-i] {
			t.Fatal("version gap")
		}
	}
}
