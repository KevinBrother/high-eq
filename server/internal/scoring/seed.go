package scoring

import _ "embed"

//go:embed seed.txt
var seed string

// Seed is an unpublished T11 draft. Never substitute it for gateway resolution.
func Seed() string { return seed }
