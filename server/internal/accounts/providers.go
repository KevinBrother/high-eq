package accounts

import (
	"context"
	"errors"
	"regexp"

	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/api/app"
)

// Issue delivers an OTP over the provider channel and returns the code solely
// for hashing. Exchange must verify a fresh provider credential, not a client ID.
type SMS interface {
	Issue(context.Context, string) (string, error)
}
type Exchange interface {
	Subject(context.Context, string, string) (string, error)
}
type development struct{ cache *redis.Client }

func DevelopmentProviders(env string, c *redis.Client) (SMS, Exchange, error) {
	if env != "development" || c == nil {
		return nil, nil, errors.New("development identity providers disabled")
	}
	d := development{c}
	return d, d, nil
}
func (development) Issue(context.Context, string) (string, error) { return "000000", nil } // no network, local test code only
func (d development) Subject(ctx context.Context, provider, ticket string) (string, error) {
	v, e := d.cache.GetDel(ctx, "dev:ticket:"+provider+":"+ticket).Result()
	if errors.Is(e, redis.Nil) {
		return "", ErrAuth
	}
	return v, e
}

var phoneRE = regexp.MustCompile(`^\+[1-9][0-9]{7,14}$`)
var codeRE = regexp.MustCompile(`^[0-9]{6}$`)

func (s *Service) RequestCode(ctx context.Context, phone string) error {
	if !phoneRE.MatchString(phone) {
		return ErrInvalid
	}
	i := s.identity("phone", phone)
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		tag, e := tx.Exec(ctx, `insert into sms_challenges(phone_hmac,sent_at,quota_day,sends,attempts) values($1,clock_timestamp(),(clock_timestamp() at time zone 'Asia/Shanghai')::date,1,5)
 on conflict(phone_hmac) do update set sent_at=excluded.sent_at, quota_day=excluded.quota_day,sends=case when sms_challenges.quota_day=excluded.quota_day then sms_challenges.sends+1 else 1 end,attempts=5
 where sms_challenges.sent_at<=excluded.sent_at-interval '60 seconds' and (sms_challenges.quota_day<>excluded.quota_day or sms_challenges.sends<10)`, i.hash)
		if e != nil {
			return e
		}
		if tag.RowsAffected() == 0 {
			return ErrQuota
		}
		code, e := s.sms.Issue(ctx, phone)
		if e != nil {
			return e
		}
		if !codeRE.MatchString(code) {
			return errors.New("bad OTP provider")
		}
		_, e = tx.Exec(ctx, "update sms_challenges set otp_hash=$2 where phone_hmac=$1", i.hash, digest(s.otpKey, phone+":"+code))
		return e
	})
}
func (s *Service) verify(ctx context.Context, c app.Credential) (identity, error) {
	var i identity
	if !validText(c.Proof, 8192) {
		return i, ErrInvalid
	}
	switch c.Provider {
	case "phone":
		if c.Phone == nil || !phoneRE.MatchString(*c.Phone) {
			return i, ErrInvalid
		}
		if !codeRE.MatchString(c.Proof) {
			return i, ErrAuth
		}
		i = s.identity("phone", *c.Phone)
		var ok bool
		// One atomic statement: consume once, including charging wrong attempts even when login later fails.
		e := s.db.QueryRow(ctx, `with challenge as (select phone_hmac,otp_hash=$2 as matches from sms_challenges where phone_hmac=$1 and attempts>0 and otp_hash is not null and sent_at>clock_timestamp()-interval '5 minutes' for update)
 update sms_challenges s set attempts=attempts-1,otp_hash=case when c.matches or attempts=1 then null else otp_hash end from challenge c where s.phone_hmac=c.phone_hmac returning c.matches`, i.hash, digest(s.otpKey, *c.Phone+":"+c.Proof)).Scan(&ok)
		if errors.Is(e, pgx.ErrNoRows) || e == nil && !ok {
			return i, ErrAuth
		}
		return i, e
	case "apple", "wechat":
		if c.Phone != nil {
			return i, ErrInvalid
		}
		subject, e := s.exchange.Subject(ctx, string(c.Provider), c.Proof)
		if e != nil {
			return i, e
		}
		if !validText(subject, 512) {
			return i, ErrAuth
		}
		return s.identity(string(c.Provider), subject), nil
	default:
		return i, ErrInvalid
	}
}
