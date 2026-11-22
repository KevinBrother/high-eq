// Emit a T11 draft request, never publish or select a vendor automatically.
package main

import (
	"encoding/json"
	"os"

	"high-eq/server/internal/training"
)

func main() {
	if err := json.NewEncoder(os.Stdout).Encode(map[string]string{"task": "role_play", "template": training.Seed()}); err != nil {
		os.Exit(1)
	}
}
