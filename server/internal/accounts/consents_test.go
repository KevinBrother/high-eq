package accounts

import (
	"errors"
	"testing"
)

func TestConsentVersionPolicyForReplyChatImport(t *testing.T) {
	for _, tc := range []struct {
		name    string
		purpose string
		version string
		grant   bool
		wantErr error
	}{
		{name: "grant exact reply version", purpose: "reply_chat_import", version: "2026-11-reply", grant: true},
		{name: "withdraw exact reply version", purpose: "reply_chat_import", version: "2026-11-reply"},
		{name: "grant legacy chat import version", purpose: "reply_chat_import", version: "2026-11", grant: true, wantErr: ErrInvalid},
		{name: "withdraw legacy chat import version", purpose: "reply_chat_import", version: "2026-11", wantErr: ErrInvalid},
		{name: "contacts import keeps its own version", purpose: "chat_import", version: "2026-11", grant: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateConsentRequest(tc.purpose, tc.version, tc.grant)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err=%v want=%v", err, tc.wantErr)
			}
		})
	}
}
