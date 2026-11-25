// Package recordlocator exposes only the stable, public keys needed to locate
// and delete records owned by the authenticated account. It intentionally does
// not read encrypted content, profiles, audio, transcriptions, or internal
// source/purge identifiers.
package recordlocator

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const (
	DefaultLimit    = 20
	MaxLimit        = 100
	MaxCursorLength = 300
	cursorVersion   = 1
)

var ErrInvalidQuery = errors.New("invalid record locator query")

type Kind string

const (
	KindAssessments   Kind = "assessments"
	KindSessions      Kind = "sessions"
	KindReviews       Kind = "reviews"
	KindReplies       Kind = "replies"
	KindContact       Kind = "contacts"
	KindManualMarks   Kind = "manual_marks"
	KindSignalEvents  Kind = "signal_events"
	KindSignalWindows Kind = "signal_windows"
)

type Channel string

const (
	ChannelHealth Channel = "health"
	ChannelVoice  Channel = "voice"
)

type Key struct {
	ID      uuid.UUID
	At      time.Time
	Channel Channel
}

type Request struct {
	Kind   string
	Cursor *string
	Limit  *int
}

type Item struct {
	Kind       Kind
	ID         uuid.UUID
	Label      string
	RecordedAt *time.Time
	Channel    Channel
}

type Page struct {
	Items      []Item
	NextCursor *string
}

func AllKinds() []Kind {
	return []Kind{
		KindAssessments,
		KindSessions,
		KindReviews,
		KindReplies,
		KindContact,
		KindManualMarks,
		KindSignalEvents,
		KindSignalWindows,
	}
}

func ParseKind(raw string) (Kind, error) {
	for _, kind := range AllKinds() {
		if raw == string(kind) {
			return kind, nil
		}
	}
	return "", ErrInvalidQuery
}

func Limit(value *int) (int, error) {
	if value == nil {
		return DefaultLimit, nil
	}
	if *value < 1 || *value > MaxLimit {
		return 0, ErrInvalidQuery
	}
	return *value, nil
}

type cursorPayload struct {
	Version int       `json:"v"`
	Kind    Kind      `json:"k"`
	ID      string    `json:"id,omitempty"`
	At      time.Time `json:"at,omitempty"`
	Channel Channel   `json:"ch,omitempty"`
}

func EncodeCursor(kind Kind, key Key) (string, error) {
	if !validCursorKey(kind, key) {
		return "", ErrInvalidQuery
	}
	payload := cursorPayload{Version: cursorVersion, Kind: kind, At: key.At, Channel: key.Channel}
	if key.ID != uuid.Nil {
		payload.ID = key.ID.String()
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", ErrInvalidQuery
	}
	encoded := base64.RawURLEncoding.EncodeToString(raw)
	if len(encoded) > MaxCursorLength {
		return "", ErrInvalidQuery
	}
	return encoded, nil
}

func DecodeCursor(kind Kind, raw string) (Key, error) {
	var key Key
	if raw == "" || len(raw) > MaxCursorLength {
		return key, ErrInvalidQuery
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return key, ErrInvalidQuery
	}
	var payload cursorPayload
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		return key, ErrInvalidQuery
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		return key, ErrInvalidQuery
	}
	if payload.Version != cursorVersion || payload.Kind != kind {
		return key, ErrInvalidQuery
	}
	key.At = payload.At
	key.Channel = payload.Channel
	if payload.ID != "" {
		key.ID, err = uuid.Parse(payload.ID)
		if err != nil || key.ID == uuid.Nil {
			return Key{}, ErrInvalidQuery
		}
	}
	if !validCursorKey(kind, key) {
		return Key{}, ErrInvalidQuery
	}
	return key, nil
}

func validCursorKey(kind Kind, key Key) bool {
	switch kind {
	case KindContact:
		return key.ID != uuid.Nil && key.At.IsZero() && key.Channel == ""
	case KindSignalWindows:
		return key.ID == uuid.Nil && !key.At.IsZero() && validChannel(key.Channel)
	case KindAssessments, KindSessions, KindReviews, KindReplies, KindManualMarks, KindSignalEvents:
		return key.ID != uuid.Nil && !key.At.IsZero() && key.Channel == ""
	default:
		return false
	}
}

func validChannel(channel Channel) bool {
	return channel == ChannelHealth || channel == ChannelVoice
}

// QueryTx performs keyset pagination inside the caller's protected account
// transaction. Every source query is explicitly scoped to userID.
func QueryTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, request Request) (Page, error) {
	kind, err := ParseKind(request.Kind)
	if err != nil {
		return Page{}, err
	}
	limit, err := Limit(request.Limit)
	if err != nil {
		return Page{}, err
	}
	if tx == nil || userID == uuid.Nil {
		return Page{}, errors.New("invalid record locator transaction")
	}
	var key *Key
	if request.Cursor != nil {
		decoded, err := DecodeCursor(kind, *request.Cursor)
		if err != nil {
			return Page{}, err
		}
		key = &decoded
	}
	switch kind {
	case KindAssessments:
		items, err := timedItems(ctx, tx, userID, limit, key,
			`select id,completed_at,null::text from assessments where user_id=$1 order by completed_at desc,id desc limit $2`,
			`select id,completed_at,null::text from assessments where user_id=$1 and (completed_at<$2 or (completed_at=$2 and id<$3)) order by completed_at desc,id desc limit $4`)
		return timedPage(kind, items, limit, err)
	case KindSessions:
		items, err := timedItems(ctx, tx, userID, limit, key,
			`select id,created_at,kind::text from activities where user_id=$1 and kind in ('practice','drill') order by created_at desc,id desc limit $2`,
			`select id,created_at,kind::text from activities where user_id=$1 and kind in ('practice','drill') and (created_at<$2 or (created_at=$2 and id<$3)) order by created_at desc,id desc limit $4`)
		return timedPage(kind, items, limit, err)
	case KindReviews:
		items, err := timedItems(ctx, tx, userID, limit, key,
			`select id,created_at,null::text from activities where user_id=$1 and kind='review' order by created_at desc,id desc limit $2`,
			`select id,created_at,null::text from activities where user_id=$1 and kind='review' and (created_at<$2 or (created_at=$2 and id<$3)) order by created_at desc,id desc limit $4`)
		return timedPage(kind, items, limit, err)
	case KindReplies:
		items, err := timedItems(ctx, tx, userID, limit, key,
			`select id,created_at,null::text from activities where user_id=$1 and kind='reply' order by created_at desc,id desc limit $2`,
			`select id,created_at,null::text from activities where user_id=$1 and kind='reply' and (created_at<$2 or (created_at=$2 and id<$3)) order by created_at desc,id desc limit $4`)
		return timedPage(kind, items, limit, err)
	case KindManualMarks:
		items, err := timedItems(ctx, tx, userID, limit, key,
			`select id,accepted_at,null::text from manual_marks where user_id=$1 order by accepted_at desc,id desc limit $2`,
			`select id,accepted_at,null::text from manual_marks where user_id=$1 and (accepted_at<$2 or (accepted_at=$2 and id<$3)) order by accepted_at desc,id desc limit $4`)
		return timedPage(kind, items, limit, err)
	case KindSignalEvents:
		items, err := timedItems(ctx, tx, userID, limit, key,
			`select id,occurred_at,null::text from signal_events where user_id=$1 order by occurred_at desc,id desc limit $2`,
			`select id,occurred_at,null::text from signal_events where user_id=$1 and (occurred_at<$2 or (occurred_at=$2 and id<$3)) order by occurred_at desc,id desc limit $4`)
		return timedPage(kind, items, limit, err)
	case KindContact:
		return contactPage(ctx, tx, userID, limit, key)
	case KindSignalWindows:
		return windowPage(ctx, tx, userID, limit, key)
	default:
		return Page{}, ErrInvalidQuery
	}
}

func timedItems(ctx context.Context, tx pgx.Tx, userID uuid.UUID, limit int, key *Key, firstSQL, nextSQL string) ([]Item, error) {
	var (
		rows pgx.Rows
		err  error
	)
	if key == nil {
		rows, err = tx.Query(ctx, firstSQL, userID, limit+1)
	} else {
		rows, err = tx.Query(ctx, nextSQL, userID, key.At, key.ID, limit+1)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]Item, 0, limit+1)
	for rows.Next() {
		var (
			id     uuid.UUID
			at     time.Time
			detail *string
		)
		if err := rows.Scan(&id, &at, &detail); err != nil {
			return nil, err
		}
		itemAt := at
		items = append(items, Item{ID: id, RecordedAt: &itemAt, Label: timedLabel(detail)})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return items, nil
}

func timedLabel(detail *string) string {
	if detail == nil {
		return ""
	}
	if *detail == "drill" {
		return "单项练习"
	}
	return ""
}

func timedPage(kind Kind, items []Item, limit int, err error) (Page, error) {
	if err != nil {
		return Page{}, err
	}
	page := Page{Items: make([]Item, 0, min(len(items), limit))}
	for i := range items {
		item := items[i]
		item.Kind = kind
		switch kind {
		case KindSessions:
			if item.Label == "" {
				item.Label = "对练"
			}
		case KindAssessments:
			item.Label = "测评"
		case KindReviews:
			item.Label = "复盘"
		case KindReplies:
			item.Label = "回复"
		case KindManualMarks:
			item.Label = "手动标记"
		case KindSignalEvents:
			item.Label = "情绪事件"
		}
		page.Items = append(page.Items, item)
	}
	if len(page.Items) <= limit {
		return page, nil
	}
	page.Items = page.Items[:limit]
	last := page.Items[len(page.Items)-1]
	next, err := EncodeCursor(kind, Key{ID: last.ID, At: *last.RecordedAt})
	if err != nil {
		return Page{}, err
	}
	page.NextCursor = &next
	return page, nil
}

func contactPage(ctx context.Context, tx pgx.Tx, userID uuid.UUID, limit int, key *Key) (Page, error) {
	rows, err := tx.Query(ctx, `select id from contacts where user_id=$1 and ($2::uuid is null or id>$2) order by id limit $3`, userID, nullableUUID(key), limit+1)
	if err != nil {
		return Page{}, err
	}
	defer rows.Close()
	page := Page{Items: make([]Item, 0, limit+1)}
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			return Page{}, err
		}
		page.Items = append(page.Items, Item{Kind: KindContact, ID: id, Label: "关系人"})
	}
	if err := rows.Err(); err != nil {
		return Page{}, err
	}
	if len(page.Items) > limit {
		page.Items = page.Items[:limit]
		last := page.Items[len(page.Items)-1]
		next, err := EncodeCursor(KindContact, Key{ID: last.ID})
		if err != nil {
			return Page{}, err
		}
		page.NextCursor = &next
	}
	return page, nil
}

func windowPage(ctx context.Context, tx pgx.Tx, userID uuid.UUID, limit int, key *Key) (Page, error) {
	var (
		rows pgx.Rows
		err  error
	)
	if key == nil {
		rows, err = tx.Query(ctx, `select starts_at,channel from signal_windows where user_id=$1 order by starts_at desc,channel desc limit $2`, userID, limit+1)
	} else {
		rows, err = tx.Query(ctx, `select starts_at,channel from signal_windows where user_id=$1 and (starts_at<$2 or (starts_at=$2 and channel<$3)) order by starts_at desc,channel desc limit $4`, userID, key.At, string(key.Channel), limit+1)
	}
	if err != nil {
		return Page{}, err
	}
	defer rows.Close()
	page := Page{Items: make([]Item, 0, limit+1)}
	for rows.Next() {
		var (
			at      time.Time
			channel string
		)
		if err := rows.Scan(&at, &channel); err != nil {
			return Page{}, err
		}
		itemAt := at
		item := Item{Kind: KindSignalWindows, RecordedAt: &itemAt, Channel: Channel(channel)}
		if item.Channel == ChannelHealth {
			item.Label = "健康窗口"
		} else if item.Channel == ChannelVoice {
			item.Label = "语音窗口"
		} else {
			return Page{}, errors.New("unexpected signal window channel")
		}
		page.Items = append(page.Items, item)
	}
	if err := rows.Err(); err != nil {
		return Page{}, err
	}
	if len(page.Items) > limit {
		page.Items = page.Items[:limit]
		last := page.Items[len(page.Items)-1]
		next, err := EncodeCursor(KindSignalWindows, Key{At: *last.RecordedAt, Channel: last.Channel})
		if err != nil {
			return Page{}, err
		}
		page.NextCursor = &next
	}
	return page, nil
}

func nullableUUID(key *Key) any {
	if key == nil {
		return nil
	}
	return key.ID
}
