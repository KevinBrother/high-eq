package gateway

import (
	"context"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/privacy"
)

type operationExportRow struct {
	task      Task
	activity  *uuid.UUID
	contact   *uuid.UUID
	operation *uuid.UUID
	kind      string
}

type operationExportRows struct {
	pgx.Rows
	data []operationExportRow
	next int
}

func (r *operationExportRows) Close()     {}
func (r *operationExportRows) Err() error { return nil }
func (r *operationExportRows) Next() bool {
	r.next++
	return r.next <= len(r.data)
}

func (r *operationExportRows) Scan(dest ...any) error {
	row := r.data[r.next-1]
	public := map[string]any{"task": string(row.task)}
	if row.activity != nil {
		public["activity_id"] = row.activity.String()
	}
	if row.contact != nil {
		public["contact_id"] = row.contact.String()
	}
	*dest[0].(*map[string]any) = public
	*dest[1].(**uuid.UUID) = row.operation
	*dest[2].(*Task) = row.task
	*dest[3].(**uuid.UUID) = row.activity
	*dest[4].(**uuid.UUID) = row.contact
	*dest[5].(*bool) = row.task == Scoring && row.kind == "review"
	return nil
}

type operationExportTx struct {
	pgx.Tx
	rows []operationExportRow
}

func (tx operationExportTx) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return &operationExportRows{data: tx.rows}, nil
}

func TestAIExportGroupsFollowBusinessOperation(t *testing.T) {
	user, operation, otherOperation := uuid.New(), uuid.New(), uuid.New()
	review, reply, firstPractice, secondPractice := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	firstContact, secondContact := uuid.New(), uuid.New()
	rows := []struct {
		group string
		row   operationExportRow
	}{
		{"review", operationExportRow{task: ReviewAnalysis, activity: &review, operation: &operation, kind: "review"}},
		{"review", operationExportRow{task: Scoring, activity: &review, operation: &operation, kind: "review"}},
		{"review", operationExportRow{task: Scoring, activity: &review, operation: &operation, kind: "review"}},
		{"reply", operationExportRow{task: ReplySuggestion, activity: &reply, operation: &operation, kind: "reply"}},
		{"reply", operationExportRow{task: ReplySuggestion, activity: &reply, operation: &operation, kind: "reply"}},
		{"profile", operationExportRow{task: ProfileInference, contact: &firstContact, operation: &operation}},
		{"profile", operationExportRow{task: ProfileInference, contact: &firstContact, operation: &operation}},
		{"other profile contact", operationExportRow{task: ProfileInference, contact: &secondContact, operation: &operation}},
		{"other profile request", operationExportRow{task: ProfileInference, contact: &firstContact, operation: &otherOperation}},
		{"practice turn", operationExportRow{task: RolePlay, activity: &firstPractice, operation: &operation, kind: "practice"}},
		{"practice finish", operationExportRow{task: Scoring, activity: &firstPractice, operation: &operation, kind: "practice"}},
		{"other practice turn", operationExportRow{task: RolePlay, activity: &secondPractice, operation: &operation, kind: "practice"}},
		{"legacy", operationExportRow{task: Scoring, operation: &operation}},
		{"legacy", operationExportRow{task: Scoring, operation: &operation}},
		{"", operationExportRow{task: Scoring}},
	}
	var data []operationExportRow
	for _, row := range rows {
		data = append(data, row.row)
	}
	export := func(account uuid.UUID) map[string]uuid.UUID {
		t.Helper()
		groups := make(map[string]uuid.UUID)
		owners := make(map[uuid.UUID]string)
		index := 0
		hook := Hooks([]byte("synthetic export key"))
		err := hook.Export(t.Context(), operationExportTx{rows: data}, privacy.ExportRequest{UserID: account}, func(value any) error {
			row := rows[index]
			index++
			public := value.(map[string]any)
			if public["task"] != string(row.row.task) {
				t.Fatalf("export changed task %s: %v", row.row.task, public["task"])
			}
			got := public["operation_id"]
			if row.group == "" {
				if got != nil {
					t.Fatalf("missing internal operation exported as %v", got)
				}
				return nil
			}
			id, ok := got.(uuid.UUID)
			if !ok || id.Version() != 8 || id == *row.row.operation {
				t.Fatalf("%s exported invalid group %v", row.group, got)
			}
			if prior, ok := owners[id]; ok && prior != row.group {
				t.Fatalf("independent operations %q and %q share a group", prior, row.group)
			}
			if prior, ok := groups[row.group]; ok && prior != id {
				t.Fatalf("attempts for %q were split", row.group)
			}
			owners[id], groups[row.group] = row.group, id
			return nil
		})
		if err != nil || index != len(rows) {
			t.Fatalf("exported %d of %d attempts: %v", index, len(rows), err)
		}
		return groups
	}
	first, repeated, other := export(user), export(user), export(uuid.New())
	for name, id := range first {
		if id != repeated[name] || id == other[name] {
			t.Errorf("%q group changed on download or was shared across accounts", name)
		}
	}
}
