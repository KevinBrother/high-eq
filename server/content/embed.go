// Package content owns versioned, build-time training material.
package content

import _ "embed"

// T26YAML is the first reviewed-format batch of original fictional exercises
// and knowledge cards. It is intentionally embedded so deployment cannot run
// with a partially copied content directory.
//
//go:embed t26.yaml
var T26YAML []byte
