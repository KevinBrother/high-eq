package service

import (
	"encoding/base64"
	"errors"
	"os"
	"strconv"

	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/fieldcrypt"
)

type Config struct {
	Listen, DatabaseURL string
	InstrumentPath      string
	Environment         string
	authMaster          []byte
	Cache, Ledger       *redis.Options
	BackupDays          int
	Fields              *fieldcrypt.Cipher
}

func LoadConfig() (Config, error) {
	c := Config{Listen: os.Getenv("LISTEN_ADDR"), DatabaseURL: os.Getenv("DATABASE_URL")}
	if c.Listen == "" {
		c.Listen = ":8080"
	}
	c.InstrumentPath = os.Getenv("WLEIS_CONFIG_PATH")
	c.Environment = os.Getenv("APP_ENV")
	if c.Environment != "development" {
		return c, errors.New("development key provider disabled outside development; configure KMS first")
	}
	var e error
	if c.Cache, e = redis.ParseURL(os.Getenv("REDIS_URL")); e != nil {
		return c, errors.New("invalid REDIS_URL")
	}
	if c.Ledger, e = redis.ParseURL(os.Getenv("LEDGER_URL")); e != nil || c.Ledger.DB != 0 {
		return c, errors.New("invalid LEDGER_URL")
	}
	if c.BackupDays, e = strconv.Atoi(os.Getenv("BACKUP_RETENTION_DAYS")); e != nil || c.BackupDays < 1 || c.BackupDays > 36500 || c.DatabaseURL == "" {
		return c, errors.New("missing database or invalid backup retention")
	}
	k, e := base64.StdEncoding.DecodeString(os.Getenv("FIELD_KEY_BASE64"))
	if e != nil {
		return c, errors.New("invalid field key encoding")
	}
	c.authMaster = k // development-only root; accounts derives domain-separated keys
	c.Fields, e = fieldcrypt.New(1, map[uint32][]byte{1: k})
	return c, e
}
