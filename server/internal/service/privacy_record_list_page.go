package service

import (
	"errors"
	"fmt"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/recordlocator"
)

var (
	errDataRecordKindMismatch = errors.New("data record kind does not match request")
	errDataRecordTimeMissing  = errors.New("timed data record has no recorded_at")
)

// dataRecordPage keeps the response item kind tied to the path kind that was
// used to query the page. OpenAPI 3.0 cannot express that cross-message
// constraint, so both this server boundary and the mobile decoder enforce it.
func dataRecordPage(kind recordlocator.Kind, page recordlocator.Page) (app.DataRecordPage, error) {
	out := app.DataRecordPage{
		Items:      make([]app.DataRecord, 0, len(page.Items)),
		NextCursor: page.NextCursor,
	}
	for _, item := range page.Items {
		if item.Kind != kind {
			return app.DataRecordPage{}, fmt.Errorf(
				"%w: got %q, want %q",
				errDataRecordKindMismatch,
				item.Kind,
				kind,
			)
		}
		if kind != recordlocator.KindContact && item.RecordedAt == nil {
			return app.DataRecordPage{}, errDataRecordTimeMissing
		}

		var record app.DataRecord
		var err error
		switch kind {
		case recordlocator.KindContact:
			err = record.FromContactDataRecord(app.ContactDataRecord{
				Kind:  app.ContactDataRecordKindContacts,
				Id:    item.ID,
				Label: item.Label,
			})
		case recordlocator.KindSignalWindows:
			err = record.FromWindowDataRecord(app.WindowDataRecord{
				Kind:       app.WindowDataRecordKindSignalWindows,
				Channel:    app.WindowDataRecordChannel(item.Channel),
				Label:      item.Label,
				RecordedAt: *item.RecordedAt,
			})
		default:
			err = record.FromTimedDataRecord(app.TimedDataRecord{
				Kind:       app.TimedDataRecordKind(item.Kind),
				Id:         item.ID,
				Label:      item.Label,
				RecordedAt: *item.RecordedAt,
			})
		}
		if err != nil {
			return app.DataRecordPage{}, fmt.Errorf("build data record: %w", err)
		}
		out.Items = append(out.Items, record)
	}
	return out, nil
}
