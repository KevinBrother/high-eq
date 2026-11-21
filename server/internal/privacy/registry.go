package privacy

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"regexp"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type ExportRequest struct{ OperationID, UserID uuid.UUID }
type Emit func(any) error
type Module struct {
	Name   string
	Delete func(context.Context, pgx.Tx, Deletion) error
	Export func(context.Context, pgx.Tx, ExportRequest, Emit) error
}
type Registry struct{ modules []Module }

var nameRE = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)

// The inventory comes from the composition root, independently of hook registration.
func NewRegistry(required []string, modules ...Module) (*Registry, error) {
	need := map[string]bool{}
	for _, name := range required {
		if !nameRE.MatchString(name) || need[name] {
			return nil, errors.New("invalid module manifest")
		}
		need[name] = true
	}
	for _, m := range modules {
		if !need[m.Name] || m.Delete == nil || m.Export == nil {
			return nil, errors.New("missing, duplicate or incomplete module")
		}
		delete(need, m.Name)
	}
	if len(need) != 0 {
		return nil, errors.New("missing required data module")
	}
	return &Registry{append([]Module(nil), modules...)}, nil
}
func (c *Coordinator) Export(ctx context.Context, q ExportRequest, dst io.Writer) error {
	if q.OperationID == uuid.Nil || q.UserID == uuid.Nil || len(c.registry.modules) == 0 {
		return errors.New("invalid export or empty inventory")
	}
	z := zip.NewWriter(dst)
	e := c.Access(ctx, q.UserID, func(tx pgx.Tx) error {
		for _, m := range c.registry.modules {
			w, e := z.Create(m.Name + ".json")
			if e != nil {
				return e
			}
			if _, e = io.WriteString(w, "["); e != nil {
				return e
			}
			first := true
			var writeErr error
			emit := func(v any) error {
				if writeErr != nil {
					return writeErr
				}
				if !first {
					_, writeErr = io.WriteString(w, ",")
				}
				first = false
				if writeErr == nil {
					writeErr = json.NewEncoder(w).Encode(v)
				}
				return writeErr
			}
			if e = m.Export(ctx, tx, q, emit); e != nil {
				return e
			}
			if writeErr != nil {
				return writeErr
			}
			if _, e = io.WriteString(w, "]"); e != nil {
				return e
			}
		}
		return nil
	})
	if e != nil {
		return e
	}
	return z.Close()
}
