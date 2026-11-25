package service

import (
	"net/url"

	"high-eq/server/internal/recordlocator"
)

// validateDataRecordQuery checks the raw query because the generated binder
// calls URL.Query(), which silently drops malformed fields and only takes the
// first value of repeated scalar parameters.
func validateDataRecordQuery(rawQuery string) error {
	values, err := url.ParseQuery(rawQuery)
	if err != nil {
		return recordlocator.ErrInvalidQuery
	}
	for _, name := range []string{"cursor", "limit"} {
		if len(values[name]) > 1 {
			return recordlocator.ErrInvalidQuery
		}
	}
	return nil
}
