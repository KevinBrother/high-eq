package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/service"
)

type quiet struct{}

func (quiet) Printf(context.Context, string, ...interface{}) {}
func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	redis.SetLogger(quiet{})
	if e := run(); e != nil {
		slog.Error("service unavailable", "module", "api", "result", "startup_or_runtime_error")
		os.Exit(1)
	}
}
func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	cfg, e := service.LoadConfig()
	if e != nil {
		return e
	}
	start, cancel := context.WithTimeout(ctx, 60*time.Second)
	s, e := service.Start(start, cfg)
	cancel()
	if e != nil {
		return e
	}
	defer s.Close()
	srv := http.Server{Addr: cfg.Listen, Handler: s.Router(), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: time.Minute}
	// Stop maintenance before closing storage; expired accounts are denied inline
	// even while a deletion is pending or being retried.
	worker, stopWorker := context.WithCancel(ctx)
	workerDone := make(chan struct{})
	defer func() { stopWorker(); <-workerDone }()
	go func() {
		defer close(workerDone)
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-worker.Done():
				return
			case <-t.C:
				if e := s.Emotion.PurgeDue(worker, time.Now()); e != nil && worker.Err() == nil {
					slog.Error("cleanup unavailable", "module", "emotion", "result", "retry")
				}
				if e := s.Emotion.ReplayPending(worker); e != nil && worker.Err() == nil {
					slog.Error("feedback pending", "module", "emotion", "result", "retry")
				}
				if e := s.Accounts.PurgeDue(worker); e != nil && worker.Err() == nil {
					slog.Error("cleanup unavailable", "module", "accounts", "result", "retry")
				}
				if e := s.Assessments.ReplayPending(worker); e != nil && worker.Err() == nil {
					slog.Error("completion delivery unavailable", "module", "assessments", "result", "retry")
				}
			}
		}
	}()
	done := make(chan error, 1)
	go func() { done <- srv.ListenAndServe() }()
	select {
	case <-ctx.Done():
		end, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(end)
	case e := <-done:
		if errors.Is(e, http.ErrServerClosed) {
			return nil
		}
		return e
	}
}
