package replies

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/membership"
)

type consentBinding struct {
	chat     uuid.UUID
	contacts *uuid.UUID
}

func activeConsentID(ctx context.Context, tx pgx.Tx, user uuid.UUID, purpose string, missing error) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `select id from consents where user_id=$1 and purpose=$2 and withdrawn_at is null order by granted_at desc,id desc limit 1 for share`, user, purpose).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, missing
	}
	return id, err
}

// activeConsentBinding captures the exact grant rows a reply request may use.
// The contacts row is read only when the user explicitly selected a contact.
func (s *Service) activeConsentBinding(ctx context.Context, tx pgx.Tx, user uuid.UUID, contact *uuid.UUID) (consentBinding, error) {
	chat, err := activeConsentID(ctx, tx, user, "chat_import", ErrConsent)
	if err != nil {
		return consentBinding{}, err
	}
	binding := consentBinding{chat: chat}
	if contact == nil {
		return binding, nil
	}
	contacts, err := activeConsentID(ctx, tx, user, "contacts", membership.ErrForbidden)
	if err != nil {
		return consentBinding{}, err
	}
	binding.contacts = &contacts
	return binding, nil
}

// requireBoundConsent rejects withdrawal and regrant for this request. Locking
// the exact active rows with FOR SHARE keeps authorization and its write in the
// same transaction when the consent row changes concurrently.
func (s *Service) requireBoundConsent(ctx context.Context, tx pgx.Tx, user uuid.UUID, contact *uuid.UUID, binding consentBinding) error {
	if binding.chat == uuid.Nil {
		return ErrConsent
	}
	chat, err := activeConsentID(ctx, tx, user, "chat_import", ErrConsent)
	if err != nil {
		return err
	}
	if chat != binding.chat {
		return ErrConsent
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
	contacts, err := activeConsentID(ctx, tx, user, "contacts", membership.ErrForbidden)
	if err != nil {
		return err
	}
	if contacts != *binding.contacts {
		return membership.ErrForbidden
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
