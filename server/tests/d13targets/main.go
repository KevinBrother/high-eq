// Command d13targets validates the effective D13 test destinations without
// opening a connection. It deliberately uses the same parsers as the service.
package main

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

var (
	databaseNamePattern = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$`)
	redisDBPathPattern  = regexp.MustCompile(`^/(0|[1-9][0-9]{0,9})$`)
)

type postgresTarget struct {
	host, database, user, password string
	port                           uint16
}

type redisTarget struct {
	host, username, password string
	port, database           int
}

func main() {
	if err := validateURLs(
		os.Getenv("D13_DATABASE_URL"),
		os.Getenv("D13_REDIS_URL"),
		os.Getenv("D13_LEDGER_URL"),
	); err != nil {
		fmt.Fprintln(os.Stderr, "D13 target validation failed:", err)
		os.Exit(1)
	}
	fmt.Println("PASS: D13 connections resolve only to the declared loopback test endpoints")
}

func validateURLs(databaseURL, cacheURL, ledgerURL string) error {
	// pgx reads libpq's PG* variables even when a connection URL is present.
	// Remove all inherited overrides and make the passfile an empty safe path.
	if err := sanitizePGEnvironment(); err != nil {
		return fmt.Errorf("cannot isolate PostgreSQL environment: %w", err)
	}

	if _, err := validatePostgresURL(databaseURL); err != nil {
		return fmt.Errorf("D13_DATABASE_URL: %w", err)
	}
	cache, err := validateRedisURL(cacheURL)
	if err != nil {
		return fmt.Errorf("D13_REDIS_URL: %w", err)
	}
	ledger, err := validateRedisURL(ledgerURL)
	if err != nil {
		return fmt.Errorf("D13_LEDGER_URL: %w", err)
	}
	if ledger.database != 0 {
		return fmt.Errorf("D13_LEDGER_URL: ledger DB must be 0")
	}
	if cache.port == ledger.port {
		return fmt.Errorf("D13_REDIS_URL and D13_LEDGER_URL must use independent Redis ports")
	}

	return nil
}

func sanitizePGEnvironment() error {
	for _, entry := range os.Environ() {
		name, _, ok := strings.Cut(entry, "=")
		if ok && strings.HasPrefix(name, "PG") {
			if err := os.Unsetenv(name); err != nil {
				return fmt.Errorf("cannot unset %s", name)
			}
		}
	}
	if err := os.Setenv("PGPASSFILE", os.DevNull); err != nil {
		return fmt.Errorf("cannot set an empty passfile")
	}
	return nil
}

func validatePostgresURL(raw string) (postgresTarget, error) {
	want, err := parsePostgresSurface(raw)
	if err != nil {
		return postgresTarget{}, err
	}

	poolConfig, err := pgxpool.ParseConfig(raw)
	if err != nil {
		return postgresTarget{}, fmt.Errorf("pgx rejected the URL")
	}
	got := poolConfig.ConnConfig
	if got.Host != want.host || got.Port != want.port ||
		got.Database != want.database || got.User != want.user || got.Password != want.password {
		return postgresTarget{}, fmt.Errorf("pgx resolved target fields different from the URL authority and path")
	}
	for _, fallback := range got.Fallbacks {
		if fallback.Host != want.host || fallback.Port != want.port {
			return postgresTarget{}, fmt.Errorf("pgx resolved an additional or different connection target")
		}
	}
	return want, nil
}

func parsePostgresSurface(raw string) (postgresTarget, error) {
	if raw == "" {
		return postgresTarget{}, fmt.Errorf("is required")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Opaque != "" {
		return postgresTarget{}, fmt.Errorf("is not a valid PostgreSQL URL")
	}
	if u.Scheme != "postgres" && u.Scheme != "postgresql" {
		return postgresTarget{}, fmt.Errorf("must use postgres or postgresql scheme")
	}
	if u.Fragment != "" || u.ForceQuery || strings.Contains(u.Host, ",") {
		return postgresTarget{}, fmt.Errorf("contains unsupported or ambiguous URL components")
	}
	if u.User == nil {
		return postgresTarget{}, fmt.Errorf("must include an explicit test user and password")
	}
	user := u.User.Username()
	password, hasPassword := u.User.Password()
	if user == "" || !hasPassword || password == "" {
		return postgresTarget{}, fmt.Errorf("must include an explicit test user and password")
	}

	host := u.Hostname()
	if !isLiteralLoopback(host) {
		return postgresTarget{}, fmt.Errorf("must use a literal loopback IP")
	}
	port, err := explicitPort(u)
	if err != nil {
		return postgresTarget{}, err
	}

	database := strings.TrimPrefix(u.Path, "/")
	if !strings.HasPrefix(u.Path, "/") || strings.Contains(database, "/") || !databaseNamePattern.MatchString(database) {
		return postgresTarget{}, fmt.Errorf("must include one explicit safe database name in the URL path")
	}

	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return postgresTarget{}, fmt.Errorf("has an unparseable query")
	}
	for key, values := range query {
		if key != "sslmode" || len(values) != 1 || !validSSLMode(values[0]) {
			return postgresTarget{}, fmt.Errorf("query may contain only one valid sslmode")
		}
	}
	if u.RawQuery != "" && len(query) == 0 {
		return postgresTarget{}, fmt.Errorf("has an empty or ambiguous query")
	}

	return postgresTarget{host: host, port: port, database: database, user: user, password: password}, nil
}

func validateRedisURL(raw string) (redisTarget, error) {
	want, err := parseRedisSurface(raw)
	if err != nil {
		return redisTarget{}, err
	}

	options, err := redis.ParseURL(raw)
	if err != nil {
		return redisTarget{}, fmt.Errorf("go-redis rejected the URL")
	}
	if options.Network != "tcp" {
		return redisTarget{}, fmt.Errorf("go-redis resolved a non-TCP network")
	}
	host, portText, err := net.SplitHostPort(options.Addr)
	if err != nil {
		return redisTarget{}, fmt.Errorf("go-redis resolved an invalid TCP address")
	}
	port, err := parseCanonicalPort(portText)
	if err != nil || host != want.host || int(port) != want.port || options.DB != want.database ||
		options.Username != want.username || options.Password != want.password {
		return redisTarget{}, fmt.Errorf("go-redis resolved target fields different from the URL")
	}
	return want, nil
}

func parseRedisSurface(raw string) (redisTarget, error) {
	if raw == "" {
		return redisTarget{}, fmt.Errorf("is required")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Opaque != "" {
		return redisTarget{}, fmt.Errorf("is not a valid Redis URL")
	}
	if u.Scheme != "redis" && u.Scheme != "rediss" {
		return redisTarget{}, fmt.Errorf("must use redis or rediss scheme")
	}
	if u.Fragment != "" || u.ForceQuery || u.RawQuery != "" || strings.Contains(u.Host, ",") {
		return redisTarget{}, fmt.Errorf("must not contain query options, fragments, or multiple hosts")
	}
	host := u.Hostname()
	if !isLiteralLoopback(host) {
		return redisTarget{}, fmt.Errorf("must use a literal loopback IP")
	}
	port, err := explicitPort(u)
	if err != nil {
		return redisTarget{}, err
	}
	if !redisDBPathPattern.MatchString(u.Path) {
		return redisTarget{}, fmt.Errorf("must include an explicit canonical database number in the URL path")
	}
	database, err := strconv.Atoi(strings.TrimPrefix(u.Path, "/"))
	if err != nil || database < 0 {
		return redisTarget{}, fmt.Errorf("has an invalid Redis database number")
	}

	var username, password string
	if u.User != nil {
		username = u.User.Username()
		password, _ = u.User.Password()
	}
	return redisTarget{
		host: host, port: int(port), database: database,
		username: username, password: password,
	}, nil
}

func explicitPort(u *url.URL) (uint16, error) {
	text := u.Port()
	if text == "" {
		return 0, fmt.Errorf("must include an explicit port")
	}
	return parseCanonicalPort(text)
}

func parseCanonicalPort(text string) (uint16, error) {
	value, err := strconv.ParseUint(text, 10, 16)
	if err != nil || value == 0 || strconv.FormatUint(value, 10) != text {
		return 0, fmt.Errorf("must include one canonical non-zero port")
	}
	return uint16(value), nil
}

func isLiteralLoopback(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback() && !strings.Contains(host, "%")
}

func validSSLMode(value string) bool {
	switch value {
	case "disable", "allow", "prefer", "require", "verify-ca", "verify-full":
		return true
	default:
		return false
	}
}
