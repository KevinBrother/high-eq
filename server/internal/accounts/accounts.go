// Package accounts owns identity, sessions and explicit consent. All identifiers
// returned by providers are looked up with a keyed digest, never as ciphertext.
package accounts

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

var (
	ErrInvalid  = errors.New("invalid account input")
	ErrAuth     = errors.New("authentication required")
	ErrConflict = errors.New("identity already bound")
	ErrQuota    = errors.New("SMS quota exceeded")
)

const PolicyVersion = "2026-11"

type Service struct {
	db                          *pgxpool.Pool
	guard                       *privacy.Coordinator
	fields                      *fieldcrypt.Cipher
	sms                         SMS
	exchange                    Exchange
	identityKey, otpKey, jwtKey []byte
}

func digest(key []byte, text string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(text))
	return h.Sum(nil)
}
func New(db *pgxpool.Pool, g *privacy.Coordinator, fields *fieldcrypt.Cipher, key []byte, sms SMS, exchange Exchange) (*Service, error) {
	if len(key) != 32 || sms == nil || exchange == nil || db == nil || g == nil || fields == nil {
		return nil, errors.New("missing identity dependencies")
	}
	return &Service{db: db, guard: g, fields: fields, sms: sms, exchange: exchange, identityKey: digest(key, "accounts/identity"), otpKey: digest(key, "accounts/otp"), jwtKey: digest(key, "accounts/access/v1")}, nil
}

type identity struct {
	provider, subject string
	hash              []byte
}

func (s *Service) identity(provider, subject string) identity {
	return identity{provider, subject, digest(s.identityKey, provider+"\x00"+subject)}
}
func aad(user uuid.UUID, provider string) []byte {
	return []byte("login_identities/subject_enc/" + user.String() + "/" + provider)
}
func (i identity) owner(ctx context.Context, tx pgx.Tx) (uuid.UUID, error) {
	var id uuid.UUID
	e := tx.QueryRow(ctx, "select user_id from login_identities where provider=$1 and subject_hmac=$2", i.provider, i.hash).Scan(&id)
	return id, e
}
func (s *Service) bind(ctx context.Context, tx pgx.Tx, user uuid.UUID, i identity) error {
	enc, e := s.fields.Seal([]byte(i.subject), aad(user, i.provider))
	if e != nil {
		return e
	}
	tag, e := tx.Exec(ctx, `insert into login_identities(provider,subject_hmac,subject_enc,user_id) values($1,$2,$3,$4) on conflict do nothing`, i.provider, i.hash, enc, user)
	if e != nil {
		return e
	}
	if tag.RowsAffected() == 0 {
		owner, e := i.owner(ctx, tx)
		if errors.Is(e, pgx.ErrNoRows) || e == nil && owner != user {
			return ErrConflict
		}
		return e
	}
	return nil
}
func (s *Service) Login(ctx context.Context, in app.LoginInput, existingOnly bool) (app.Tokens, error) {
	var out app.Tokens
	i, e := s.verify(ctx, in.Credential)
	if e != nil {
		return out, e
	}
	e = pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		// Serialize first-use registration of this verified identity across instances.
		if _, e := tx.Exec(ctx, `select pg_advisory_xact_lock(hashtextextended(encode($1::bytea,'hex'),0))`, i.hash); e != nil {
			return e
		}
		id, e := i.owner(ctx, tx)
		newUser := errors.Is(e, pgx.ErrNoRows)
		if newUser {
			if existingOnly {
				return ErrAuth
			}
			if in.AgeConfirmed == nil || !bool(*in.AgeConfirmed) || in.PrivacyVersion == nil || *in.PrivacyVersion != PolicyVersion || in.TermsVersion == nil || *in.TermsVersion != PolicyVersion {
				return ErrInvalid
			}
			if e = tx.QueryRow(ctx, "insert into users(age_confirmed_at) values(clock_timestamp()) returning id").Scan(&id); e != nil {
				return e
			}
		} else if e != nil {
			return e
		}
		if e = s.guard.GuardTx(ctx, tx, id); e != nil {
			return e
		}
		if newUser {
			if e = s.bind(ctx, tx, id, i); e != nil {
				return e
			}
			if _, e = tx.Exec(ctx, "insert into consents(user_id,purpose,version) values($1,'privacy',$2),($1,'terms',$2)", id, PolicyVersion); e != nil {
				return e
			}
		}
		out, e = s.issue(ctx, tx, id)
		return e
	})
	return out, e
}
func (s *Service) reauth(ctx context.Context, tx pgx.Tx, id uuid.UUID, i identity) error {
	owner, e := i.owner(ctx, tx)
	if errors.Is(e, pgx.ErrNoRows) || e == nil && owner != id {
		return ErrAuth
	}
	return e
}
func (s *Service) Bind(ctx context.Context, p Principal, current, next app.Credential) (app.Account, error) {
	var a app.Account
	i, e := s.verify(ctx, current)
	if e != nil {
		return a, e
	}
	j, e := s.verify(ctx, next)
	if e != nil {
		return a, e
	}
	e = s.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if e := s.reauth(ctx, tx, p.User, i); e != nil {
			return e
		}
		if e := s.bind(ctx, tx, p.User, j); e != nil {
			return e
		}
		a, e = account(ctx, tx, p.User)
		return e
	})
	return a, e
}
func validText(v string, max int) bool { return v != "" && strings.TrimSpace(v) == v && len(v) <= max }
