package service

import (
	"context"
	"log/slog"
	"time"
)

// RunMaintenancePass performs the work scheduled by each API maintenance tick.
func (s *Runtime) RunMaintenancePass(ctx context.Context, now time.Time) {
	log := func(module, message string, err error) {
		if err != nil && ctx.Err() == nil {
			slog.Error(message, "module", module, "result", "retry")
		}
	}
	log("marks", "cleanup unavailable", s.Marks.PurgeDue(ctx, now))
	log("chat_imports", "cleanup unavailable", s.Practice.PurgeChatImports(ctx, now))
	log("emotion", "cleanup unavailable", s.Emotion.PurgeDue(ctx, now))
	log("emotion", "feedback pending", s.Emotion.ReplayPending(ctx))
	log("accounts", "cleanup unavailable", s.Accounts.PurgeDue(ctx))
	log("privacy", "cleanup unavailable", s.Data.RetryPending(ctx))
	log("practice", "completion delivery unavailable", s.Practice.ReplayPending(ctx))
	log("reviews", "score delivery pending", s.Reviews.ReplayPending(ctx))
	log("replies", "feedback delivery unavailable", s.Replies.ReplayPending(ctx))
	log("assessments", "completion delivery unavailable", s.Assessments.ReplayPending(ctx))
}
