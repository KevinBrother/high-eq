package membership

import (
	"context"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"
)

// One short-lived counter per account/feature. Before checking/incrementing it,
// reconcile against the locked SQL snapshot: eviction, rollback, lost replies
// and yesterday's refunds cannot mint capacity. Redis is not a second ledger.
var admit = redis.NewScript(`
local baseline,limit,take=tonumber(ARGV[1]),tonumber(ARGV[2]),tonumber(ARGV[3])
if tonumber(redis.call('GET',KEYS[1])) ~= baseline then redis.call('SET',KEYS[1],baseline) end
redis.call('PEXPIRE',KEYS[1],ARGV[4])
if take == 1 and baseline >= limit then return -1 end
if take == 1 then redis.call('INCR',KEYS[1]) end
return math.max(limit-baseline-take,0)`)

func counterKey(user uuid.UUID, feature string) string {
	return "quota:v1:" + user.String() + ":" + feature
}
func (s *Service) capacity(ctx context.Context, tx pgx.Tx, user uuid.UUID, f string, a access, exclude uuid.UUID, take bool) (int, error) {
	var baseline int
	e := tx.QueryRow(ctx, `select coalesce((select used from daily_quota_usage
        where user_id=$1 and feature=$2 and charged_day=$3::date),0) + (
        select count(*) from quota_attempts q join activities a on a.id=q.activity_id
        where a.user_id=$1 and a.kind::text=$2 and q.held_day=$3::date
          and q.activity_id<>$4 and q.state='held' and q.metered and q.valid_until>$5
    )`, user, f, a.day, exclude, a.at).Scan(&baseline)
	if e != nil {
		return 0, e
	}
	inc := 0
	if take {
		inc = 1
	}
	v, e := admit.Run(ctx, s.cache, []string{counterKey(user, f)}, baseline, *a.Daily[f], inc, max(a.reset.Sub(a.at).Milliseconds(), 1)).Int()
	if e == nil && v < 0 {
		return 0, ErrLimit
	}
	return v, e
}
