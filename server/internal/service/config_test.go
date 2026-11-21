package service

import (
	"strings"
	"testing"
)

func TestDevelopmentOnly(t *testing.T) {
	for k, v := range map[string]string{"APP_ENV": "development", "DATABASE_URL": "postgres://localhost/test", "REDIS_URL": "redis://cache:6379", "LEDGER_URL": "redis://ledger:6379", "FIELD_KEY_BASE64": strings.Repeat("A", 43) + "=", "BACKUP_RETENTION_DAYS": "60"} {
		t.Setenv(k, v)
	}
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
