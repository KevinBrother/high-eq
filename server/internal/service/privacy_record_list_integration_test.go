//go:build integration

package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

type wireRecordLocator struct {
	Kind       string     `json:"kind"`
	Id         *uuid.UUID `json:"id"`
	Label      string     `json:"label"`
	RecordedAt *time.Time `json:"recorded_at"`
	Channel    *string    `json:"channel"`
}

type wireRecordLocatorPage struct {
	Items      []wireRecordLocator `json:"items"`
	NextCursor *string             `json:"next_cursor"`
}

func TestRecordLocatorListsOnlyOwnedPublicDeletionKeys(t *testing.T) {
	f := newDeletionHTTPFixture(t)
	ownerSubject := uuid.NewString()
	owner := f.register(t, ownerSubject)
	other := f.register(t, uuid.NewString())
	empty := f.register(t, uuid.NewString())

	at := time.Date(2026, 11, 23, 10, 0, 0, 0, time.UTC)
	assessmentTime := at.Add(123456 * time.Microsecond)
	assessmentIDs := []uuid.UUID{uuid.New(), uuid.New(), uuid.New()}
	otherAssessment := uuid.New()
	for _, id := range assessmentIDs {
		f.exec(t, `insert into assessments(id,user_id,instrument_version,answers_enc,scores_enc,completed_at) values($1,$2,'fixture',$3,$4,$5)`, id, owner.UserId, []byte("T35-SENSITIVE-ASSESSMENT"), []byte("T35-SENSITIVE-SCORE"), assessmentTime)
	}
	f.exec(t, `insert into assessments(id,user_id,instrument_version,answers_enc,scores_enc,completed_at) values($1,$2,'fixture',$3,$4,$5)`, otherAssessment, other.UserId, []byte("other"), []byte("other"), assessmentTime)

	practice := uuid.New()
	drill := uuid.New()
	review := uuid.New()
	reply := uuid.New()
	practiceSource, drillSource, reviewSource, replySource := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	f.exec(t, `insert into activities(id,user_id,source_id,kind,created_at,state) values($1,$2,$3,'practice',$4,'complete'),($5,$2,$6,'drill',$4,'complete'),($7,$2,$8,'review',$4,'complete'),($9,$2,$10,'reply',$4,'complete')`, practice, owner.UserId, practiceSource, at, drill, drillSource, review, reviewSource, reply, replySource)
	otherReview := uuid.New()
	f.exec(t, `insert into activities(id,user_id,source_id,kind,created_at,state) values($1,$2,$3,'review',$4,'complete')`, otherReview, other.UserId, uuid.New(), at)

	contactA, contactB, otherContact := uuid.New(), uuid.New(), uuid.New()
	f.exec(t, `insert into contacts(id,user_id,profile_enc,last_used_at) values($1,$2,$3,$4),($5,$2,$3,$4),($6,$7,$3,$4)`, contactA, owner.UserId, []byte("T35-SENSITIVE-CONTACT"), at, contactB, otherContact, other.UserId)

	mark, otherMark := uuid.New(), uuid.New()
	f.exec(t, `insert into manual_marks(id,user_id,accepted_at,mark_enc) values($1,$2,$3,$4),($5,$6,$3,$4)`, mark, owner.UserId, at, []byte("T35-SENSITIVE-MARK"), otherMark, other.UserId)
	event, otherEvent := uuid.New(), uuid.New()
	f.exec(t, `insert into signal_events(id,user_id,occurred_at,event_enc) values($1,$2,$3,$4),($5,$6,$3,$4)`, event, owner.UserId, at, []byte("T35-SENSITIVE-EVENT"), otherEvent, other.UserId)

	healthAt := at
	voiceAt := at.Add(30 * time.Second)
	healthPurge, voicePurge, otherPurge := uuid.New(), uuid.New(), uuid.New()
	f.exec(t, `insert into signal_windows(user_id,starts_at,channel,purge_id,stats_enc) values($1,$2,'health',$3,$4),($1,$5,'voice',$6,$4),($7,$2,'health',$8,$4)`, owner.UserId, healthAt, healthPurge, []byte("T35-SENSITIVE-WINDOW"), voiceAt, voicePurge, other.UserId, otherPurge)

	// Historical deletion must remain available without an active membership or
	// current collection consent. The records above were inserted directly.
	f.exec(t, `with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '60 days',now()-interval '1 day' from o`, owner.UserId, []byte(uuid.NewString()))
	f.exec(t, `insert into consents(user_id,purpose,version,granted_at,withdrawn_at) values($1,'health','v1',now()-interval '2 days',now()-interval '1 day'),($1,'voice','v1',now()-interval '2 days',now()-interval '1 day'),($1,'contacts','v1',now()-interval '2 days',now()-interval '1 day')`, owner.UserId)

	f.request(t, "GET", "/v1/me/data/assessments", "", nil, 401)
	f.request(t, "GET", "/v1/me/data/not_a_kind", owner.AccessToken, nil, 400)
	f.request(t, "GET", "/v1/me/data/assessments?limit=0", owner.AccessToken, nil, 400)
	f.request(t, "GET", "/v1/me/data/assessments?limit=101", owner.AccessToken, nil, 400)

	page := func(path string) (wireRecordLocatorPage, []byte) {
		t.Helper()
		body := f.request(t, "GET", path, owner.AccessToken, nil, 200)
		var out wireRecordLocatorPage
		decoder := json.NewDecoder(bytes.NewReader(body))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&out); err != nil {
			t.Fatalf("decode %s: %v: %s", path, err, body)
		}
		var raw struct {
			Items      []map[string]json.RawMessage `json:"items"`
			NextCursor json.RawMessage              `json:"next_cursor"`
		}
		requireDeletionFixture(t, json.Unmarshal(body, &raw))
		if len(raw.NextCursor) == 0 {
			t.Fatalf("%s omitted next_cursor: %s", path, body)
		}
		for i, item := range raw.Items {
			if len(item) != 4 || len(item["recorded_at"]) == 0 {
				t.Fatalf("%s has incomplete record fields: %s", path, body)
			}
			if out.Items[i].Kind == "contacts" && string(item["recorded_at"]) != "null" {
				t.Fatalf("%s has non-null contact timestamp: %s", path, body)
			}
		}
		if out.Items == nil {
			t.Fatalf("%s returned null items: %s", path, body)
		}
		return out, body
	}

	// Same-timestamp assessments paginate by the stable (recorded_at,id) key.
	var pagedAssessments []uuid.UUID
	var assessmentCursor *string
	cursor := ""
	for i := 0; i < 10; i++ {
		path := "/v1/me/data/assessments?limit=1"
		if cursor != "" {
			path += "&cursor=" + url.QueryEscape(cursor)
		}
		out, _ := page(path)
		if len(out.Items) != 1 || out.Items[0].Id == nil {
			t.Fatalf("assessment page %d = %+v", i, out)
		}
		if out.Items[0].RecordedAt == nil || !out.Items[0].RecordedAt.Equal(assessmentTime) {
			t.Fatalf("assessment page %d did not preserve timestamp precision: %+v", i, out)
		}
		pagedAssessments = append(pagedAssessments, *out.Items[0].Id)
		if assessmentCursor == nil {
			assessmentCursor = out.NextCursor
		}
		if out.NextCursor == nil {
			break
		}
		if *out.NextCursor == cursor {
			t.Fatal("assessment cursor did not advance")
		}
		cursor = *out.NextCursor
	}
	expectedAssessments := append([]uuid.UUID(nil), assessmentIDs...)
	sort.Slice(expectedAssessments, func(i, j int) bool { return expectedAssessments[i].String() > expectedAssessments[j].String() })
	if fmt.Sprint(pagedAssessments) != fmt.Sprint(expectedAssessments) {
		t.Fatalf("assessment pages = %v, want %v", pagedAssessments, expectedAssessments)
	}
	if assessmentCursor == nil {
		t.Fatal("missing cursor before final assessment page")
	}
	f.request(t, "GET", "/v1/me/data/sessions?cursor="+url.QueryEscape(*assessmentCursor), owner.AccessToken, nil, 400)
	f.request(t, "GET", "/v1/me/data/assessments?limit=100&userId="+other.UserId.String(), owner.AccessToken, nil, 200)

	kinds := []string{"assessments", "sessions", "reviews", "replies", "contacts", "manual_marks", "signal_events", "signal_windows"}
	publicIDs := make(map[string]uuid.UUID)
	var responseBytes []byte
	for _, kind := range kinds {
		out, body := page("/v1/me/data/" + kind + "?limit=100")
		responseBytes = append(responseBytes, body...)
		for _, item := range out.Items {
			if item.Kind != kind || item.Label == "" {
				t.Fatalf("%s item = %+v", kind, item)
			}
			if kind == "signal_windows" {
				if item.Id != nil || item.Channel == nil || item.RecordedAt == nil || !item.RecordedAt.Equal(item.RecordedAt.Truncate(30*time.Second)) {
					t.Fatalf("window item = %+v", item)
				}
				continue
			}
			if item.Id == nil || item.Channel != nil {
				t.Fatalf("%s item has invalid key: %+v", kind, item)
			}
			if kind == "contacts" {
				if item.RecordedAt != nil {
					t.Fatalf("contact recorded_at = %v, want null", item.RecordedAt)
				}
			} else if item.RecordedAt == nil {
				t.Fatalf("%s item missing recorded_at: %+v", kind, item)
			}
			if _, exists := publicIDs[kind]; !exists {
				publicIDs[kind] = *item.Id
			}
		}
	}
	emptyPage, _ := func() (wireRecordLocatorPage, []byte) {
		body := f.request(t, "GET", "/v1/me/data/assessments", empty.AccessToken, nil, 200)
		var out wireRecordLocatorPage
		if err := json.Unmarshal(body, &out); err != nil {
			t.Fatal(err)
		}
		return out, body
	}()
	if len(emptyPage.Items) != 0 || emptyPage.NextCursor != nil {
		t.Fatalf("empty page = %+v", emptyPage)
	}

	for _, id := range []uuid.UUID{otherAssessment, otherReview, otherContact, otherMark, otherEvent} {
		if bytes.Contains(responseBytes, []byte(id.String())) {
			t.Fatalf("foreign record %s leaked", id)
		}
	}
	for _, sentinel := range []string{
		"T35-SENSITIVE", practiceSource.String(), drillSource.String(), reviewSource.String(), replySource.String(),
		healthPurge.String(), voicePurge.String(), otherPurge.String(),
		`"source_id"`, `"purge_id"`, `"request_id"`, `"feedback_id"`, `"contact_id"`,
		`"profile_enc"`, `"stats_enc"`, `"answers_enc"`, `"scores_enc"`, `"mark_enc"`, `"event_enc"`, `"content_enc"`,
	} {
		if bytes.Contains(responseBytes, []byte(sentinel)) {
			t.Fatalf("record locator response leaked %q", sentinel)
		}
	}

	f.request(t, "DELETE", "/v1/me/data/assessments/"+otherAssessment.String(), owner.AccessToken, nil, 404)
	f.request(t, "DELETE", "/v1/me/data/replies/"+review.String(), owner.AccessToken, nil, 404)
	f.request(t, "DELETE", "/v1/me/data/sessions/"+practiceSource.String(), owner.AccessToken, nil, 404)
	f.request(t, "DELETE", "/v1/me/data/signal_windows/"+healthPurge.String(), owner.AccessToken, nil, 400)
	f.request(t, "DELETE", "/v1/me/data/assessments/"+uuid.Nil.String(), owner.AccessToken, nil, 400)

	for _, kind := range []string{"assessments", "sessions", "reviews", "replies", "contacts", "manual_marks", "signal_events"} {
		id, ok := publicIDs[kind]
		if !ok {
			t.Fatalf("%s returned no deletion key", kind)
		}
		path := "/v1/me/data/" + kind + "/" + id.String()
		body := f.request(t, "DELETE", path, owner.AccessToken, nil, 200)
		if !bytes.Equal(body, []byte(`{"ok":true}`)) {
			t.Fatalf("%s returned invalid deletion receipt: %s", kind, body)
		}
		after, _ := page("/v1/me/data/" + kind + "?limit=100")
		for _, item := range after.Items {
			if item.Id != nil && *item.Id == id {
				t.Fatalf("%s still lists deleted record %s", kind, id)
			}
		}
		f.request(t, "DELETE", path, owner.AccessToken, nil, 404)
	}
	otherPage := f.request(t, "GET", "/v1/me/data/assessments", other.AccessToken, nil, 200)
	var otherRecords wireRecordLocatorPage
	requireDeletionFixture(t, json.Unmarshal(otherPage, &otherRecords))
	if len(otherRecords.Items) != 1 || otherRecords.Items[0].Id == nil || *otherRecords.Items[0].Id != otherAssessment {
		t.Fatalf("other account's assessment missing after deletion: %s", otherPage)
	}

	windows, _ := page("/v1/me/data/signal_windows?limit=100")
	if len(windows.Items) != 2 {
		t.Fatalf("windows = %+v, want health and voice", windows.Items)
	}
	if windows.Items[0].Channel == nil || *windows.Items[0].Channel != "voice" || windows.Items[1].Channel == nil || *windows.Items[1].Channel != "health" {
		t.Fatalf("window order = %+v", windows.Items)
	}
	deleteWindow := func(item wireRecordLocator) {
		t.Helper()
		if item.RecordedAt == nil || item.Channel == nil {
			t.Fatalf("incomplete window key: %+v", item)
		}
		path := "/v1/signal-windows?starts_at=" + url.QueryEscape(item.RecordedAt.Format(time.RFC3339Nano)) + "&channel=" + string(*item.Channel)
		if body := f.request(t, "DELETE", path, owner.AccessToken, nil, 200); !bytes.Equal(body, []byte(`{"ok":true}`)) {
			t.Fatalf("window returned invalid deletion receipt: %s", body)
		}
	}
	assertOtherHealthWindow := func() {
		t.Helper()
		body := f.request(t, "GET", "/v1/me/data/signal_windows", other.AccessToken, nil, 200)
		var out wireRecordLocatorPage
		requireDeletionFixture(t, json.Unmarshal(body, &out))
		if len(out.Items) != 1 || out.Items[0].Channel == nil || *out.Items[0].Channel != "health" ||
			out.Items[0].RecordedAt == nil || !out.Items[0].RecordedAt.Equal(healthAt) {
			t.Fatalf("other account lost its same-key health window: %s", body)
		}
	}
	assertOtherHealthWindow()
	deleteWindow(windows.Items[1])
	assertOtherHealthWindow()
	remaining, _ := page("/v1/me/data/signal_windows")
	if len(remaining.Items) != 1 || remaining.Items[0].Channel == nil || *remaining.Items[0].Channel != "voice" {
		t.Fatalf("after health deletion = %+v", remaining.Items)
	}
	deleteWindow(remaining.Items[0])
	finalWindows, _ := page("/v1/me/data/signal_windows")
	if len(finalWindows.Items) != 0 || finalWindows.NextCursor != nil {
		t.Fatalf("final windows = %+v", finalWindows)
	}

	// Freeze continues to reject reads even after re-authentication.
	f.request(t, "POST", "/v1/me/closure", owner.AccessToken, map[string]any{"proof": f.proof(t, ownerSubject)}, 200)
	var recovery app.Tokens
	requireDeletionFixture(t, json.Unmarshal(f.request(t, "POST", "/v1/auth/login", "", map[string]any{"credential": f.proof(t, ownerSubject)}, 200), &recovery))
	f.request(t, "GET", "/v1/me/data/assessments", recovery.AccessToken, nil, 401)
	f.request(t, "DELETE", "/v1/me/data/assessments/"+assessmentIDs[0].String(), recovery.AccessToken, nil, 401)
}

func TestSelectedRecordDeleteRetriesOnlyExactPendingRoot(t *testing.T) {
	f := newDeletionHTTPFixture(t)
	subject := uuid.NewString()
	owner, other := f.register(t, subject), f.register(t, uuid.NewString())
	var revoked app.Tokens
	requireDeletionFixture(t, json.Unmarshal(f.request(t, "POST", "/v1/auth/login", "", map[string]any{
		"credential": f.proof(t, subject),
	}, 200), &revoked))
	if revoked.UserId != owner.UserId || revoked.AccessToken == owner.AccessToken {
		t.Fatal("expected a separate session for the same owner")
	}
	f.request(t, "POST", "/v1/auth/logout", revoked.AccessToken, map[string]any{"refresh_token": revoked.RefreshToken}, 200)
	pending, control := uuid.New(), uuid.New()
	f.exec(t, `insert into assessments(id,user_id,instrument_version,answers_enc,scores_enc)
		values($1,$2,'fixture','answers','scores'),($3,$2,'fixture','answers','scores')`, pending, owner.UserId, control)
	f.exec(t, `insert into pending_erasure(root_id) values($1)`, pending)
	path := "/v1/me/data/assessments/" + pending.String()
	f.request(t, "GET", "/v1/me/data/assessments", owner.AccessToken, nil, 503)
	f.request(t, "DELETE", "/v1/me/data/assessments/"+control.String(), owner.AccessToken, nil, 503)
	f.request(t, "DELETE", path, other.AccessToken, nil, 404)
	f.request(t, "DELETE", path, "", nil, 401)
	f.request(t, "DELETE", path, revoked.AccessToken, nil, 401)
	if body := f.request(t, "DELETE", path, owner.AccessToken, nil, 200); !bytes.Equal(body, []byte(`{"ok":true}`)) {
		t.Fatalf("exact retry returned invalid receipt: %s", body)
	}
	body := f.request(t, "GET", "/v1/me/data/assessments", owner.AccessToken, nil, 200)
	var page wireRecordLocatorPage
	requireDeletionFixture(t, json.Unmarshal(body, &page))
	if len(page.Items) != 1 || page.Items[0].Id == nil || *page.Items[0].Id != control {
		t.Fatalf("exact retry removed the wrong records: %s", body)
	}
	f.request(t, "DELETE", path, owner.AccessToken, nil, 404)
}
