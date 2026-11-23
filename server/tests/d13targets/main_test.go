package main

import (
	"strings"
	"testing"
)

const (
	validDatabase = "postgres://d13:synthetic-secret@127.0.0.1:55432/d13_isolated?sslmode=disable"
	validCache    = "redis://127.0.0.1:56380/0"
	validLedger   = "redis://127.0.0.1:56381/0"
)

func TestValidateURLsAcceptsSyntheticLoopback(t *testing.T) {
	tests := []struct {
		name     string
		database string
		cache    string
		ledger   string
	}{
		{name: "IPv4 with sslmode disable", database: validDatabase, cache: validCache, ledger: validLedger},
		{name: "default TLS preference", database: "postgresql://d13:secret@127.0.0.1:55432/d13_isolated", cache: validCache, ledger: validLedger},
		{name: "TLS fallback stays on same endpoint", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=prefer", cache: validCache, ledger: validLedger},
		{name: "IPv6 and Redis credentials", database: "postgres://d13:secret@[::1]:55432/d13_isolated?sslmode=require", cache: "rediss://cache:cache-secret@[::1]:56380/1", ledger: "redis://ledger:ledger-secret@[::1]:56381/0"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := validateURLs(test.database, test.cache, test.ledger); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestValidateURLsIgnoresInheritedPostgresSettings(t *testing.T) {
	t.Setenv("PGHOST", "192.0.2.10")
	t.Setenv("PGPORT", "6543")
	t.Setenv("PGDATABASE", "wrong_database")
	t.Setenv("PGUSER", "wrong_user")
	t.Setenv("PGPASSWORD", "wrong_password")
	t.Setenv("PGSERVICE", "external-service")
	t.Setenv("PGSERVICEFILE", "/must/not/be/read")
	t.Setenv("PGPASSFILE", "/must/not/be/read")
	t.Setenv("PGSSLMODE", "verify-full")

	if err := validateURLs(validDatabase, validCache, validLedger); err != nil {
		t.Fatal(err)
	}
}

func TestValidateURLsRejectsPostgresTargetOverrides(t *testing.T) {
	tests := []struct {
		name     string
		database string
	}{
		{name: "host query override", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=disable&host=192.0.2.10"},
		{name: "same host still rejected as unnecessary override", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=disable&host=127.0.0.1"},
		{name: "port query override", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=disable&port=55433"},
		{name: "database query override", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=disable&dbname=other"},
		{name: "user query override", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=disable&user=other"},
		{name: "password query override", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=disable&password=other"},
		{name: "service override", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=disable&service=external"},
		{name: "multiple sslmode", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=disable&sslmode=require"},
		{name: "multi host authority", database: "postgres://d13:secret@127.0.0.1:55432,192.0.2.10:5432/d13_isolated?sslmode=disable"},
		{name: "non loopback host", database: "postgres://d13:secret@192.0.2.10:55432/d13_isolated?sslmode=disable"},
		{name: "hostname requires resolution", database: "postgres://d13:secret@localhost:55432/d13_isolated?sslmode=disable"},
		{name: "implicit port", database: "postgres://d13:secret@127.0.0.1/d13_isolated?sslmode=disable"},
		{name: "implicit database", database: "postgres://d13:secret@127.0.0.1:55432/?sslmode=disable"},
		{name: "multiple database path segments", database: "postgres://d13:secret@127.0.0.1:55432/d13/other?sslmode=disable"},
		{name: "missing password", database: "postgres://d13@127.0.0.1:55432/d13_isolated?sslmode=disable"},
		{name: "empty password", database: "postgres://d13:@127.0.0.1:55432/d13_isolated?sslmode=disable"},
		{name: "bad sslmode", database: "postgres://d13:secret@127.0.0.1:55432/d13_isolated?sslmode=trust"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateURLs(test.database, validCache, validLedger)
			if err == nil {
				t.Fatal("expected validation failure")
			}
			if strings.Contains(err.Error(), "synthetic-secret") {
				t.Fatalf("validation error exposed a password: %v", err)
			}
		})
	}
}

func TestValidateURLsRejectsRedisAmbiguity(t *testing.T) {
	tests := []struct {
		name   string
		cache  string
		ledger string
	}{
		{name: "cache db query override", cache: "redis://127.0.0.1:56380/0?db=1", ledger: validLedger},
		{name: "cache implicit db", cache: "redis://127.0.0.1:56380", ledger: validLedger},
		{name: "cache missing port", cache: "redis://127.0.0.1/0", ledger: validLedger},
		{name: "cache non loopback host", cache: "redis://192.0.2.10:56380/0", ledger: validLedger},
		{name: "cache multi host", cache: "redis://127.0.0.1:56380,192.0.2.10:6379/0", ledger: validLedger},
		{name: "shared Redis port", cache: validCache, ledger: "redis://127.0.0.2:56380/0"},
		{name: "ledger implicit db", cache: validCache, ledger: "redis://127.0.0.1:56381"},
		{name: "ledger nonzero db", cache: validCache, ledger: "redis://127.0.0.1:56381/1"},
		{name: "ledger query override", cache: validCache, ledger: "redis://127.0.0.1:56381/0?db=0"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := validateURLs(validDatabase, test.cache, test.ledger); err == nil {
				t.Fatal("expected validation failure")
			}
		})
	}
}
