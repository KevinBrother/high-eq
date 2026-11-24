//go:build integration && t26flutter

package service

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

func TestT26FixtureFailureReceipt(t *testing.T) {
	const childCase = "T26_FIXTURE_FAILURE_TEST_CASE"
	const dsn = "postgres://t26_fixture:synthetic-dsn-sentinel@127.0.0.1:5432/t26_fixture"
	const diagnostic = "synthetic-database-diagnostic-sentinel"
	const redisEndpoint = "127.0.0.1:49173"
	const redisDiagnostic = "synthetic-redis-dial-sentinel"
	if branch := os.Getenv(childCase); branch != "" {
		err := &pgconn.PgError{Code: "XX000", Message: diagnostic + " " + dsn}
		switch branch {
		case "setup":
			h := &practiceWire{t: t, reportFailure: t26ReportFixtureFailure}
			h.mustAt("start_runtime", err)
		case "setup_dsn":
			h := &practiceWire{t: t, reportFailure: t26ReportFixtureFailure}
			// The malformed URL fails parsing in Start before any dial.
			_, startErr := Start(t.Context(), Config{DatabaseURL: dsn + "/%ZZ", DatabasePoolMaxConns: 1})
			h.mustAt("start_runtime", startErr)
		case "redis_dial":
			t26RunFixture(t, func(t *testing.T) {
				t26FailRedisDial(t, redisEndpoint, redisDiagnostic)
			})
		case "redis_default":
			t26RunFixture(t, func(t *testing.T) { t.Log("synthetic fixture process passed") })
			if os.Getenv(t26FixtureChildTest) == "" {
				t26FailRedisDial(t, redisEndpoint, redisDiagnostic)
			}
		case "readback":
			cfg, parseErr := pgxpool.ParseConfig(dsn + "?sslmode=disable")
			if parseErr != nil {
				t.Fatal("could not parse synthetic pool config")
			}
			cfg.ConnConfig.DialFunc = func(context.Context, string, string) (net.Conn, error) {
				return nil, err
			}
			pool, poolErr := pgxpool.NewWithConfig(t.Context(), cfg)
			if poolErr != nil {
				t.Fatal("could not create synthetic pool")
			}
			t.Cleanup(pool.Close)
			t26CheckReadback(t, &practiceWire{s: &Runtime{db: pool}}, "synthetic-subject")
		case "readback_query":
			t26ReportReadbackFailure(t, "practice", fmt.Errorf("query diagnostic %s: %w", diagnostic, err))
		case "readback_assertion":
			assertion := t26ReadbackAssertion("want one completed assessment plan level and one projected practice score, got 1 and 0")
			t26ReportReadbackFailure(t, "plan", fmt.Errorf("%s: %w", diagnostic, assertion))
		default:
			t.Fatal("unknown fixture failure branch")
		}
		return
	}

	for _, tc := range []struct {
		branch string
		want   string
	}{
		{"setup", "T26 fixture: stage=start_runtime error=database"},
		{"setup_dsn", "T26 fixture: stage=start_runtime error=operation"},
		{"redis_dial", "T26 fixture: stage=start_runtime error=connection"},
		{"redis_default", "T26 fixture: stage=start_runtime error=connection"},
		{"readback", "T26 readback: stage=begin error=connection"},
		{"readback_query", "T26 readback: stage=practice error=database"},
		{"readback_assertion", "T26 readback: stage=plan error=assertion (want one completed assessment plan level and one projected practice score, got 1 and 0)"},
	} {
		t.Run(tc.branch, func(t *testing.T) {
			bin, err := os.Executable()
			if err != nil {
				t.Fatal("could not locate the Go test binary")
			}
			cmd := exec.CommandContext(t.Context(), bin, "-test.run=^TestT26FixtureFailureReceipt$", "-test.v")
			scratch := t.TempDir()
			cmd.Env = []string{
				childCase + "=" + tc.branch,
				"PGPASSFILE=" + filepath.Join(scratch, "pgpass"),
				"PGSERVICEFILE=" + filepath.Join(scratch, "pg_service.conf"),
			}
			out, err := cmd.CombinedOutput()
			exit, ok := err.(*exec.ExitError)
			receipt := string(out)
			if !ok || exit.ExitCode() != 1 || !strings.Contains(receipt, "--- FAIL: TestT26FixtureFailureReceipt") {
				t.Fatal("expected the child test to report a real failure and exit 1")
			}
			for _, forbidden := range []string{"postgres://", "synthetic-dsn-sentinel", diagnostic} {
				if strings.Contains(receipt, forbidden) {
					t.Error("failure receipt contains raw database diagnostics")
					break
				}
			}
			if !strings.Contains(receipt, tc.want) {
				t.Errorf("failure receipt is missing %q", tc.want)
			}
			if tc.branch == "redis_default" {
				for _, want := range []string{"synthetic fixture process passed", redisEndpoint, redisDiagnostic, "failed to dial after"} {
					if !strings.Contains(receipt, want) {
						t.Errorf("default-path receipt is missing %q", want)
					}
				}
				return
			}
			for _, forbidden := range []string{redisEndpoint, redisDiagnostic, "failed to dial after"} {
				if strings.Contains(receipt, forbidden) {
					t.Errorf("failure receipt contains raw Redis diagnostics (%q)", forbidden)
				}
			}
		})
	}
}

func t26FailRedisDial(t *testing.T, endpoint, diagnostic string) {
	t.Helper()
	client := redis.NewClient(&redis.Options{
		Addr:               endpoint,
		MaxRetries:         -1,
		DialerRetries:      1,
		DialerRetryTimeout: time.Nanosecond,
		Dialer: func(_ context.Context, network, addr string) (net.Conn, error) {
			return nil, &net.OpError{
				Op:   "dial",
				Net:  network,
				Addr: net.TCPAddrFromAddrPort(netip.MustParseAddrPort(addr)),
				Err:  errors.New(diagnostic),
			}
		},
	})
	t.Cleanup(func() { _ = client.Close() })
	h := &practiceWire{t: t, reportFailure: t26ReportFixtureFailure}
	_, err := instance(t.Context(), client)
	h.mustAt("start_runtime", err)
}
