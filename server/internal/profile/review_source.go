package profile

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var errReviewScene = errors.New("invalid review source context")

// The completed T23 save writes the journal and its score atomically. A bare
// activity row is not sufficient. The score FK ties the key and kind to the
// activity; the journal envelope authenticates the account and activity ID.
func (s *Service) reviewActivityScene(ctx context.Context, tx pgx.Tx, u, activity uuid.UUID) (string, error) {
	var enc []byte
	e := tx.QueryRow(ctx, `select a.content_enc from activities a
		join scores s on (s.activity_id,s.activity_kind,s.id)=(a.id,a.kind,a.source_id)
		where a.user_id=$1 and a.id=$2 and a.kind='review' and a.state='complete' and a.content_enc is not null`, u, activity).Scan(&enc)
	if e != nil {
		return "", e
	}
	return s.decodeReviewScene(u, activity, enc)
}

// Match T23 reviews.save's stable journal envelope. Do not decode submitted
// material or the model's repair phrase into a profile object or an error.
func (s *Service) decodeReviewScene(u, activity uuid.UUID, enc []byte) (string, error) {
	plain, e := s.Fields.Open(enc, []byte("review/v1/"+u.String()+"/"+activity.String()+"/journal"))
	if e != nil {
		return "", errReviewScene
	}
	var journal struct {
		Submitted *struct {
			Scene *string `json:"scene"`
		} `json:"submitted"`
	}
	if e = json.Unmarshal(plain, &journal); e != nil || journal.Submitted == nil {
		return "", errReviewScene
	}
	if journal.Submitted.Scene == nil {
		return "", nil
	}
	sc := *journal.Submitted.Scene
	if !scene(sc) {
		return "", errReviewScene
	}
	return sc, nil
}
