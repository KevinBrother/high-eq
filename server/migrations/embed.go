package migrations

import (
	"context"
	"database/sql"
	"embed"
	"errors"

	"github.com/golang-migrate/migrate/v4"
	migrator "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	_ "github.com/jackc/pgx/v5/stdlib"
)

//go:embed *.sql
var files embed.FS

func Up(ctx context.Context, url string) error {
	s, e := iofs.New(files, ".")
	if e != nil {
		return e
	}
	db, e := sql.Open("pgx", url)
	if e != nil {
		return e
	}
	defer db.Close()
	if e = db.PingContext(ctx); e != nil {
		return e
	}
	d, e := migrator.WithInstance(db, &migrator.Config{})
	if e != nil {
		return e
	}
	defer d.Close()
	m, e := migrate.NewWithInstance("embedded", s, "pgx5", d)
	if e != nil {
		return e
	}
	e = m.Up()
	if errors.Is(e, migrate.ErrNoChange) {
		return nil
	}
	return e
}
