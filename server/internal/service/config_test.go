package service

import (
	"strings"
	"testing"
)

func setValidConfigEnv(t *testing.T) {
	t.Helper()
	for k, v := range map[string]string{"APP_ENV": "development", "DATABASE_URL": "postgres://localhost/test", "REDIS_URL": "redis://cache:6379", "LEDGER_URL": "redis://ledger:6379", "FIELD_KEY_BASE64": strings.Repeat("A", 43) + "=", "BACKUP_RETENTION_DAYS": "60"} {
		t.Setenv(k, v)
	}
}

func TestDatabasePoolMaxConns(t *testing.T) {
	setValidConfigEnv(t)
	for _, tt := range []struct {
		name  string
		value string
		want  int32
		ok    bool
	}{
		{"default", "", 16, true},
		{"minimum", "1", 1, true},
		{"maximum", "256", 256, true},
		{"zero", "0", 0, false},
		{"negative", "-1", 0, false},
		{"too_large", "257", 0, false},
		{"not_integer", "sixteen", 0, false},
		{"fractional", "1.5", 0, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("DATABASE_POOL_MAX_CONNS", tt.value)
			c, e := LoadConfig()
			if tt.ok && (e != nil || c.DatabasePoolMaxConns != tt.want) {
				t.Fatalf("max conns = %d, err = %v; want %d", c.DatabasePoolMaxConns, e, tt.want)
			}
			if !tt.ok && e == nil {
				t.Fatalf("accepted DATABASE_POOL_MAX_CONNS=%q", tt.value)
			}
		})
	}
}

func TestDevelopmentOnly(t *testing.T) {
	setValidConfigEnv(t)
	if _, e := LoadConfig(); e != nil {
		t.Fatal(e)
	}
	t.Setenv("APP_ENV", "production")
	if _, e := LoadConfig(); e == nil {
		t.Fatal("production accepted development key")
	}
	t.Setenv("APP_ENV", "development")
	t.Setenv("FIELD_KEY_BASE64", "redacted")
	if _, e := LoadConfig(); e == nil {
		t.Fatal("invalid key")
	}
}
