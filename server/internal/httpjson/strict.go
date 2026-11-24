// Package httpjson contains request-body guards shared by strict JSON handlers.
package httpjson

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"unicode/utf8"
)

var ErrInvalidUTF8 = errors.New("request body is not valid UTF-8")

// ReadStrictUTF8 reads at most limit bytes and restores them for the endpoint's
// existing JSON decoder. It must run before decoding because encoding/json
// replaces malformed UTF-8 instead of reporting it.
func ReadStrictUTF8(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, error) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(body) {
		return nil, ErrInvalidUTF8
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	return body, nil
}
