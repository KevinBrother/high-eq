package profile

import (
	"bytes"
	"testing"

	"github.com/google/uuid"

	"high-eq/server/internal/fieldcrypt"
)

func TestDecodeReviewScene(t *testing.T) {
	fields, err := fieldcrypt.New(1, map[uint32][]byte{1: bytes.Repeat([]byte{42}, 32)})
	if err != nil {
		t.Fatal(err)
	}
	s := Service{Fields: fields}
	u, activity := uuid.New(), uuid.New()
	aad := "review/v1/" + u.String() + "/" + activity.String() + "/journal"
	for _, tc := range []struct {
		name, journal, suffix, want string
		invalid                     bool
	}{
		{name: "submitted scene only", journal: `{"scene":"partner","submitted":{"scene":"work","my_action":"synthetic quote"},"repair_phrase":"synthetic advice"}`, want: "work"},
		{name: "scene omitted by T23", journal: `{"submitted":{"happened":"synthetic journal"}}`},
		{name: "null scene", journal: `{"submitted":{"scene":null}}`},
		{name: "missing submitted", journal: `{"scene":"work"}`, invalid: true},
		{name: "null submitted", journal: `{"submitted":null}`, invalid: true},
		{name: "wrong enum", journal: `{"submitted":{"scene":"synthetic quote"}}`, invalid: true},
		{name: "blank scene is not null", journal: `{"submitted":{"scene":""}}`, invalid: true},
		{name: "wrong scene type", journal: `{"submitted":{"scene":[]}}`, invalid: true},
		{name: "wrong field AAD", journal: `{"submitted":{"scene":"work"}}`, suffix: "/score", invalid: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			enc, err := fields.Seal([]byte(tc.journal), []byte(aad+tc.suffix))
			if err != nil {
				t.Fatal(err)
			}
			got, err := s.decodeReviewScene(u, activity, enc)
			if (err != nil) != tc.invalid || got != tc.want {
				t.Fatalf("scene=%q err=%v, want scene=%q invalid=%v", got, err, tc.want, tc.invalid)
			}
			if !tc.invalid {
				if _, err := s.decodeReviewScene(uuid.New(), activity, enc); err == nil {
					t.Fatal("accepted other account's journal")
				}
				if _, err := s.decodeReviewScene(u, uuid.New(), enc); err == nil {
					t.Fatal("accepted other activity's journal")
				}
			}
		})
	}
}
