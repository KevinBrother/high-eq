// Package adminops is the independent security boundary for the operator console.
package adminops

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"regexp"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
	"high-eq/server/internal/api/admin"
)

var loginName = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
var errCredentials = errors.New("invalid credentials")

// Provision is intentionally available only from a trusted database-side CLI; no public signup or default credentials.
func Provision(ctx context.Context, db *pgxpool.Pool, login, password, role string) (uuid.UUID, error) {
	if !loginName.MatchString(login) || len(password) < 12 || len(password) > 72 || (role != "operator" && role != "super_admin") {
		return uuid.Nil, errors.New("invalid account")
	}
	hash, e := bcrypt.GenerateFromPassword([]byte(password), 12)
	if e != nil {
		return uuid.Nil, e
	}
	id := uuid.New()
	e = pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
		if _, e := tx.Exec(ctx, "insert into admin_accounts(id,login,password_hash,role) values ($1,$2,$3,$4)", id, login, hash, role); e != nil {
			return e
		}
		_, e := tx.Exec(ctx, "insert into admin_audit_logs(actor_id,action,target,result) values ($1,'provisionAdmin',$2,'ok')", uuid.Nil, id.String())
		return e
	})
	return id, e
}

type identity struct {
	id     uuid.UUID
	role   admin.AdminSessionRole
	digest []byte
}

func digest(token string) []byte { sum := sha256.Sum256([]byte(token)); return sum[:] }
func (a api) identify(ctx context.Context, authorization string) (identity, error) {
	var p identity
	token, ok := strings.CutPrefix(authorization, "Bearer ")
	if !ok || len(token) != 47 || !strings.HasPrefix(token, "adm_") {
		return p, errCredentials
	}
	p.digest = digest(token)
	e := a.db.QueryRow(ctx, `select a.id,a.role from admin_sessions s join admin_accounts a on a.id=s.admin_id where s.token_hash=$1 and s.expires_at>now()`, p.digest).Scan(&p.id, &p.role)
	if errors.Is(e, pgx.ErrNoRows) {
		e = errCredentials
	}
	return p, e
}

// An unknown account also pays one bcrypt comparison. This constant is not an account credential.
const dummyHash = "$2a$12$7EqJtq98hPqEX7fNZaFWoO5CzZ9vRbOJl1Xq9z/8VdFZcTpsATy.a"

func (a api) verify(ctx context.Context, login, password string) (identity, error) {
	var p identity
	var hash []byte
	e := a.db.QueryRow(ctx, "select id,role,password_hash from admin_accounts where login=$1", login).Scan(&p.id, &p.role, &hash)
	missing := errors.Is(e, pgx.ErrNoRows)
	if missing {
		hash = []byte(dummyHash)
	} else if e != nil {
		return p, e
	}
	if bcrypt.CompareHashAndPassword(hash, []byte(password)) != nil || missing {
		return p, errCredentials
	}
	return p, nil
}
func issue(ctx context.Context, tx pgx.Tx, p identity) (admin.AdminSession, error) {
	var random [32]byte
	rand.Read(random[:])
	token := "adm_" + base64.RawURLEncoding.EncodeToString(random[:])
	s := admin.AdminSession{AccessToken: token, Role: p.role}
	if _, e := tx.Exec(ctx, "delete from admin_sessions where admin_id=$1 and expires_at<=now()", p.id); e != nil {
		return s, e
	}
	e := tx.QueryRow(ctx, "insert into admin_sessions(token_hash,admin_id,expires_at) values ($1,$2,now()+interval '8 hours') returning expires_at", digest(token), p.id).Scan(&s.ExpiresAt)
	return s, e
}
