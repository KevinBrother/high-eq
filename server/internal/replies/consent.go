package replies

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/membership"
)

type consentBinding struct {
	chat     uuid.UUID
	contacts *uuid.UUID
}

// ErrBoundConsentExpired marks a stale submitted or persisted grant. A fresh
// request must go through authorization again.
var ErrBoundConsentExpired = errors.New("reply request consent binding expired")

func activeConsentVersionID(ctx context.Context, tx pgx.Tx, user uuid.UUID, purpose, version string, missing error) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `select id from consents where user_id=$1 and purpose=$2 and version=$3 and withdrawn_at is null order by granted_at desc,id desc limit 1 for share`, user, purpose, version).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, missing
	}
	return id, err
}

// activeConsentBinding captures the exact grant rows a reply request may use.
// The contacts row is read only when the user explicitly selected a contact.
func (s *Service) activeConsentBinding(ctx context.Context, tx pgx.Tx, user uuid.UUID, contact *uuid.UUID) (consentBinding, error) {
	chat, err := activeConsentVersionID(ctx, tx, user, accounts.ReplyChatImportPurpose, accounts.ReplyChatImportVersion, ErrConsent)
	if err != nil {
		return consentBinding{}, err
	}
	binding := consentBinding{chat: chat}
	if contact == nil {
		return binding, nil
	}
	contacts, err := activeConsentVersionID(ctx, tx, user, "contacts", accounts.ContactNoticeVersion, membership.ErrForbidden)
	if err != nil {
		return consentBinding{}, err
	}
	binding.contacts = &contacts
	return binding, nil
}

// bindNewConsent checks the caller's exact decisions in the transaction
// that would bind a new key. No state should be written before it succeeds.
func (s *Service) bindNewConsent(ctx context.Context, tx pgx.Tx, user uuid.UUID, contact, replyID, contactsID *uuid.UUID) (consentBinding, error) {
	binding, err := s.activeConsentBinding(ctx, tx, user, contact)
	if err != nil {
		return consentBinding{}, err
	}
	if err = matchExpectedConsent(replyID, contactsID, binding); err != nil {
		return consentBinding{}, err
	}
	return binding, nil
}

func matchExpectedConsent(replyID, contactsID *uuid.UUID, binding consentBinding) error {
	if replyID == nil || *replyID == uuid.Nil {
		return ErrConsent
	}
	if *replyID != binding.chat {
		return ErrBoundConsentExpired
	}
	if binding.contacts == nil {
		if contactsID != nil {
			return membership.ErrForbidden
		}
		return nil
	}
	if contactsID == nil || *contactsID == uuid.Nil {
		return membership.ErrForbidden
	}
	if *contactsID != *binding.contacts {
		return ErrBoundConsentExpired
	}
	return nil
}

// requireBoundConsent rejects withdrawal and regrant for this request. Locking
// the exact active rows with FOR SHARE keeps authorization and its write in the
// same transaction when the consent row changes concurrently.
func (s *Service) requireBoundConsent(ctx context.Context, tx pgx.Tx, user uuid.UUID, contact *uuid.UUID, binding consentBinding) error {
	if binding.chat == uuid.Nil {
		return ErrConsent
	}
	chat, err := activeConsentVersionID(ctx, tx, user, accounts.ReplyChatImportPurpose, accounts.ReplyChatImportVersion, ErrBoundConsentExpired)
	if err != nil {
		return err
	}
	if chat != binding.chat {
		return ErrBoundConsentExpired
	}
	if contact == nil {
		if binding.contacts != nil {
			return membership.ErrForbidden
		}
		return nil
	}
	if binding.contacts == nil || *binding.contacts == uuid.Nil {
		return membership.ErrForbidden
	}
	contacts, err := activeConsentVersionID(ctx, tx, user, "contacts", accounts.ContactNoticeVersion, ErrBoundConsentExpired)
	if err != nil {
		return err
	}
	if contacts != *binding.contacts {
		return ErrBoundConsentExpired
	}
	return nil
}

func (s *Service) allow(ctx context.Context, tx pgx.Tx, user uuid.UUID, contact *uuid.UUID, binding consentBinding) error {
	if err := s.requireBoundConsent(ctx, tx, user, contact, binding); err != nil {
		return err
	}
	return s.requireSelectedContact(ctx, tx, user, contact)
}

// A reply without a profile must not consume or require a spare contact slot.
// RequireContact(nil) is the membership check for *creating* a contact.
func (s *Service) requireSelectedContact(ctx context.Context, tx pgx.Tx, user uuid.UUID, contact *uuid.UUID) error {
	if contact == nil {
		return nil
	}
	return s.rights.RequireContact(ctx, tx, user, contact)
}
