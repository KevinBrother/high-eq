package accounts

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

func TestJWTValidation(t *testing.T) {
	s := Service{jwtKey: []byte("test-only-key-not-used-by-runtime")}
	for _, tc := range []struct {
		name   string
		change func(*jwt.RegisteredClaims)
		method jwt.SigningMethod
		ok     bool
	}{
		{"valid", func(*jwt.RegisteredClaims) {}, jwt.SigningMethodHS256, true},
		{"expired", func(c *jwt.RegisteredClaims) { c.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Minute)) }, jwt.SigningMethodHS256, false},
		{"missing expiry", func(c *jwt.RegisteredClaims) { c.ExpiresAt = nil }, jwt.SigningMethodHS256, false},
		{"other audience", func(c *jwt.RegisteredClaims) { c.Audience = jwt.ClaimStrings{"admin"} }, jwt.SigningMethodHS256, false},
		{"other issuer", func(c *jwt.RegisteredClaims) { c.Issuer = "admin" }, jwt.SigningMethodHS256, false},
		{"different algorithm", func(*jwt.RegisteredClaims) {}, jwt.SigningMethodHS512, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := jwt.RegisteredClaims{Issuer: issuer, Audience: jwt.ClaimStrings{"high-eq/app"}, ID: uuid.NewString(), Subject: uuid.NewString(), ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}
			tc.change(&c)
			v, e := jwt.NewWithClaims(tc.method, c).SignedString(s.jwtKey)
			if e != nil {
				t.Fatal(e)
			}
			if _, e = s.Parse(v); (e == nil) != tc.ok {
				t.Fatal(e)
			}
		})
	}
}
func TestDevProvidersFailClosed(t *testing.T) {
	c := redis.NewClient(&redis.Options{})
	defer c.Close()
	for _, env := range []string{"", "production", "staging", "Development"} {
		if _, _, e := DevelopmentProviders(env, c); e == nil {
			t.Fatalf("accepted dev auth for %q", env)
		}
	}
}
