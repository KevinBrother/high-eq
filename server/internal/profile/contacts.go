package profile

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
)

type Runner interface {
	Run(context.Context, gateway.Call) (gateway.Reply, error)
}
type Service struct {
	Fields *fieldcrypt.Cipher
	Rights *membership.Service
	Data   *privacy.Coordinator
	AI     Runner
}

// ErrContactNotFound means the account-scoped contact row was absent.
var ErrContactNotFound = errors.New("contact not found")

func aad(kind string, u, id uuid.UUID) []byte {
	return []byte(kind + "/" + u.String() + "/" + id.String())
}
func (s *Service) seal(kind string, u, id uuid.UUID, v any) ([]byte, error) {
	b, e := json.Marshal(v)
	if e != nil {
		return nil, e
	}
	return s.Fields.Seal(b, aad(kind, u, id))
}
func (s *Service) open(kind string, u, id uuid.UUID, b []byte, v any) error {
	plain, e := s.Fields.Open(b, aad(kind, u, id))
	if e != nil {
		return e
	}
	return json.Unmarshal(plain, v)
}
func consent(ctx context.Context, tx pgx.Tx, u uuid.UUID, p string) error {
	ok, e := accounts.Granted(ctx, tx, u, p)
	if e == nil && !ok {
		return membership.ErrForbidden
	}
	return e
}
func (s *Service) write(ctx context.Context, tx pgx.Tx, u uuid.UUID, id *uuid.UUID) error {
	if e := consent(ctx, tx, u, "contacts"); e != nil {
		return e
	}
	return s.Rights.RequireContact(ctx, tx, u, id)
}
func (s *Service) read(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (dossier, error) {
	return s.readRow(ctx, tx, u, id, false)
}

// readLocked serializes profile mutations with the evidence snapshot they replace.
func (s *Service) readLocked(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (dossier, error) {
	return s.readRow(ctx, tx, u, id, true)
}

func (s *Service) readRow(ctx context.Context, tx pgx.Tx, u, id uuid.UUID, lock bool) (d dossier, e error) {
	var b []byte
	sql := `select profile_enc from contacts where user_id=$1 and id=$2`
	if lock {
		sql += ` for update`
	}
	e = tx.QueryRow(ctx, sql, u, id).Scan(&b)
	if e == nil {
		e = s.open("profile", u, id, b, &d)
	}
	return
}
func (s *Service) store(ctx context.Context, tx pgx.Tx, u, id uuid.UUID, d dossier, create bool) error {
	b, e := s.seal("profile", u, id, d)
	if e != nil {
		return e
	}
	sql := `update contacts set profile_enc=$3 where user_id=$1 and id=$2`
	if create {
		sql = `insert into contacts(user_id,id,profile_enc,last_used_at) values($1,$2,$3,null)`
	}
	_, e = tx.Exec(ctx, sql, u, id, b)
	return e
}
func (s *Service) Create(ctx context.Context, tx pgx.Tx, u uuid.UUID, in app.CreateContactInput) (app.Contact, error) {
	id := uuid.New()
	d, e := initial(in)
	if e == nil {
		e = s.write(ctx, tx, u, nil)
	}
	if e == nil {
		e = s.store(ctx, tx, u, id, d, true)
	}
	return app.Contact{Id: id, Editable: true, Scene: d.Scene, Nickname: d.Nickname, Profile: d.render(nil)}, e
}
func (s *Service) Edit(ctx context.Context, tx pgx.Tx, u, id uuid.UUID, in app.EditContactInput) (app.Contact, error) {
	if e := s.write(ctx, tx, u, &id); e != nil {
		return app.Contact{}, e
	}
	d, e := s.readLocked(ctx, tx, u, id)
	if e == nil {
		e = d.edit(in.Nickname, string(in.Scene), in.InitialContext)
	}
	if e == nil {
		e = s.store(ctx, tx, u, id, d, false)
	}
	if e != nil {
		return app.Contact{}, e
	}
	return s.Contact(ctx, tx, u, id)
}
func (s *Service) Contact(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (app.Contact, error) {
	d, e := s.read(ctx, tx, u, id)
	if errors.Is(e, pgx.ErrNoRows) {
		return app.Contact{}, ErrContactNotFound
	}
	if e != nil {
		return app.Contact{}, e
	}
	e = s.Rights.RequireContact(ctx, tx, u, &id)
	editable := e == nil
	if !editable && !errors.Is(e, membership.ErrForbidden) {
		return app.Contact{}, e
	}
	v, e := s.votes(ctx, tx, u, id)
	return app.Contact{Id: id, Nickname: d.Nickname, Scene: d.Scene, Editable: editable, Profile: d.render(v)}, e
}
func (s *Service) Choose(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (app.Contact, error) {
	if e := consent(ctx, tx, u, "contacts"); e != nil {
		return app.Contact{}, e
	}
	if e := s.Rights.SelectContact(ctx, tx, u, id); e != nil {
		return app.Contact{}, e
	}
	return s.Contact(ctx, tx, u, id)
}

// AuthorizedScene returns the scene of the most recently used contact for the
// personal plan. The membership gate must run before consent or profile access;
// this read never selects a contact or refreshes last_used_at.
func (s *Service) AuthorizedScene(ctx context.Context, tx pgx.Tx, u uuid.UUID) (string, bool, error) {
	if s == nil || s.Rights == nil || s.Fields == nil || tx == nil || u == uuid.Nil {
		return "", false, accounts.ErrInvalid
	}
	if err := s.Rights.Require(ctx, tx, u, membership.PersonalPlan); err != nil {
		return "", false, err
	}
	if err := consent(ctx, tx, u, "contacts"); err != nil {
		return "", false, err
	}
	var id uuid.UUID
	err := tx.QueryRow(ctx, `select id from contacts
where user_id=$1 and last_used_at is not null
order by last_used_at desc, id
limit 1`, u).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	d, err := s.read(ctx, tx, u, id)
	if err != nil {
		return "", false, err
	}
	return string(d.Scene), true, nil
}

// ForModel authorizes actual training use, unlike a historical detail read. Call in the activity's transaction.
func (s *Service) ForModel(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (app.Profile, error) {
	if e := s.write(ctx, tx, u, &id); e != nil {
		return app.Profile{}, e
	}
	c, e := s.Choose(ctx, tx, u, id)
	return c.Profile, e
}
func (s *Service) List(ctx context.Context, tx pgx.Tx, u uuid.UUID, p app.ListContactsParams) (app.ListContactsResult, error) {
	out := app.ListContactsResult{Items: []app.Contact{}}
	limit := 20
	if p.Limit != nil {
		limit = *p.Limit
	}
	after := uuid.Nil
	if p.Cursor != nil {
		var e error
		after, e = uuid.Parse(*p.Cursor)
		if e != nil {
			return out, accounts.ErrInvalid
		}
	}
	if limit < 1 || limit > 100 {
		return out, accounts.ErrInvalid
	}
	rows, e := tx.Query(ctx, `select id from contacts where user_id=$1 and id>$2 order by id limit $3`, u, after, limit+1)
	if e != nil {
		return out, e
	}
	ids, e := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if e != nil {
		return out, e
	}
	if len(ids) > limit {
		v := ids[limit-1].String()
		out.NextCursor = &v
		ids = ids[:limit]
	}
	for _, id := range ids {
		c, e := s.Contact(ctx, tx, u, id)
		if e != nil {
			return out, e
		}
		out.Items = append(out.Items, c)
	}
	return out, nil
}
