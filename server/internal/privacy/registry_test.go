package privacy

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestRequiredHooks(t *testing.T) {
	del := func(context.Context, pgx.Tx, Deletion) error { return nil }
	for _, mods := range [][]Module{nil, {{Name: "training", Delete: del}}, {{Name: "../leak", Delete: del}}} {
		if _, err := NewRegistry([]string{"training"}, mods...); err == nil {
			t.Fatal("incomplete module enabled")
		}
	}
}

func TestRegistryReservesManifestName(t *testing.T) {
	deleteHook := func(context.Context, pgx.Tx, Deletion) error { return nil }
	exportHook := func(context.Context, pgx.Tx, ExportRequest, Emit) error { return nil }
	if _, err := NewRegistry([]string{"manifest"}, Module{Name: "manifest", Delete: deleteHook, Export: exportHook}); err == nil {
		t.Fatal("manifest collision accepted")
	}
}
