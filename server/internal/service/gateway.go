package service

import (
	"context"

	"high-eq/server/internal/gateway"
)

// StartGateway shares the application pool, ordinary Redis, and field keyring.
// The routing layer owns the returned catalog and closes it before Runtime.Close.
func (s *Runtime) StartGateway(ctx context.Context) (*gateway.Catalog, error) {
	return gateway.Start(ctx, s.db, s.cache, s.Fields)
}
