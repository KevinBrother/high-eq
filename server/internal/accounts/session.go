package accounts

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
)

type Principal struct {
	User, Session uuid.UUID
	Expires       time.Time
}

const issuer = "high-eq/accounts"

func refreshHash(token string) []byte { v := sha256.Sum256([]byte(token)); return v[:] }
func (s *Service) issue(ctx context.Context, tx pgx.Tx, user uuid.UUID) (app.Tokens, error) {
	var out app.Tokens
	var allowed bool
	e := tx.QueryRow(ctx, `select closure_requested_at is null or closure_requested_at>clock_timestamp()-interval '360 hours' from users where id=$1`, user).Scan(&allowed)
	if e != nil {
		return out, e
	}
	if !allowed {
		return out, ErrAuth
	}
	var raw [32]byte
	rand.Read(raw[:])
	id := uuid.New()
	now := time.Now().UTC().Truncate(time.Second)
	exp := now.Add(15 * time.Minute)
	rt := base64.RawURLEncoding.EncodeToString(raw[:])
	_, e = tx.Exec(ctx, `insert into auth_sessions values($1,$2,$3,clock_timestamp()+interval '720 hours')`, id, user, refreshHash(rt))
	if e != nil {
		return out, e
	}
	claims := jwt.RegisteredClaims{Issuer: issuer, Audience: jwt.ClaimStrings{"high-eq/app"}, Subject: user.String(), ID: id.String(), IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(exp)}
	at, e := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(s.jwtKey)
	if e != nil {
		return out, e
	}
	return app.Tokens{AccessToken: at, RefreshToken: rt, ExpiresAt: exp, UserId: user}, nil
}
func (s *Service) Parse(token string) (Principal, error) {
	var p Principal
	var claims jwt.RegisteredClaims
	if len(token) > 4096 {
		return p, ErrAuth
	}
	_, e := jwt.ParseWithClaims(token, &claims, func(*jwt.Token) (any, error) { return s.jwtKey, nil }, jwt.WithValidMethods([]string{"HS256"}), jwt.WithExpirationRequired(), jwt.WithIssuer(issuer), jwt.WithAudience("high-eq/app"))
	if e != nil {
		return p, ErrAuth
	}
	p.Expires = claims.ExpiresAt.Time
	if p.User, e = uuid.Parse(claims.Subject); e != nil {
		return p, ErrAuth
	}
	if p.Session, e = uuid.Parse(claims.ID); e != nil {
		return p, ErrAuth
	}
	return p, nil
}

// WithSession rechecks revocation, freeze and the privacy barrier in the very
// transaction doing the business write (not only before HTTP dispatch).
func (s *Service) WithSession(ctx context.Context, p Principal, allowFrozen bool, fn func(pgx.Tx) error) error {
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if e := s.guard.GuardTx(ctx, tx, p.User); e != nil {
			return e
		}
		if e := s.ValidateSessionTx(ctx, tx, p, allowFrozen); e != nil {
			return e
		}
		if fn == nil {
			return nil
		}
		return fn(tx)
	})
}

// WithReadSession performs the same revocation, freeze and privacy checks in a
// repeatable-read, read-only transaction. It must never execute business writes.
func (s *Service) WithReadSession(ctx context.Context, p Principal, allowFrozen bool, fn func(pgx.Tx) error) error {
	tx, e := s.db.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if e = s.guard.GuardReadTx(ctx, tx, p.User); e != nil {
		if errors.Is(e, pgx.ErrNoRows) {
			return ErrAuth
		}
		return e
	}
	if e = s.ValidateSessionTx(ctx, tx, p, allowFrozen); e != nil {
		return e
	}
	if fn != nil {
		if e = fn(tx); e != nil {
			return e
		}
	}
	return tx.Commit(ctx)
}

// ValidateSessionTx rechecks the presented session inside a caller-owned
// account-locked transaction. Callers must not perform business writes first.
func (s *Service) ValidateSessionTx(ctx context.Context, tx pgx.Tx, p Principal, allowFrozen bool) error {
	var valid bool
	e := tx.QueryRow(ctx, `select exists(select from auth_sessions a join users u on u.id=a.user_id where a.id=$1 and u.id=$2 and a.expires_at>clock_timestamp() and $4::timestamptz>clock_timestamp() and (u.closure_requested_at is null or ($3 and u.closure_requested_at>clock_timestamp()-interval '360 hours')))`, p.Session, p.User, allowFrozen, p.Expires).Scan(&valid)
	if e != nil {
		return e
	}
	if !valid {
		return ErrAuth
	}
	return nil
}
func (s *Service) Refresh(ctx context.Context, rt string) (app.Tokens, error) {
	var out app.Tokens
	if len(rt) != 43 {
		return out, ErrAuth
	}
	hash := refreshHash(rt)
	var user uuid.UUID
	e := s.db.QueryRow(ctx, "select user_id from auth_sessions where refresh_hash=$1", hash).Scan(&user)
	if e != nil {
		return out, e
	}
	e = pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if e := s.guard.GuardTx(ctx, tx, user); e != nil {
			return e
		}
		tag, e := tx.Exec(ctx, `delete from auth_sessions where user_id=$1 and refresh_hash=$2 and expires_at>clock_timestamp()`, user, hash)
		if e != nil {
			return e
		}
		if tag.RowsAffected() != 1 {
			return ErrAuth
		}
		out, e = s.issue(ctx, tx, user)
		return e
	})
	return out, e
}
func (s *Service) Logout(ctx context.Context, p Principal, rt string) error {
	return s.WithSession(ctx, p, true, func(tx pgx.Tx) error {
		tag, e := tx.Exec(ctx, "delete from auth_sessions where id=$1 and user_id=$2 and refresh_hash=$3", p.Session, p.User, refreshHash(rt))
		if e != nil {
			return e
		}
		if tag.RowsAffected() != 1 {
			return ErrAuth
		}
		return nil
	})
}
func IsAuth(err error) bool { return errors.Is(err, ErrAuth) || errors.Is(err, pgx.ErrNoRows) }
