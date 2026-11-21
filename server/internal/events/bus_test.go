package events

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestSubscribers(t *testing.T) {
	var topic Topic[int]
	ctx := context.Background()
	if e := topic.dispatch(ctx, nil, 4); e == nil {
		t.Fatal("silently dropped")
	}
	var seen []int
	stop := errors.New("stop")
	topic.Subscribe(func(_ context.Context, _ pgx.Tx, i int) error { seen = append(seen, i); return nil })
	topic.Subscribe(func(context.Context, pgx.Tx, int) error { return stop })
	if e := topic.dispatch(ctx, nil, 4); !errors.Is(e, stop) || len(seen) != 1 || seen[0] != 4 {
		t.Fatal(e, seen)
	}
}
