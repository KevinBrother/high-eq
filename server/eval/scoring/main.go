package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"high-eq/server/internal/gateway"
	"high-eq/server/internal/prompts"
	"high-eq/server/internal/scoring"
)

func seedHash() string { return fmt.Sprintf("%x", sha256.Sum256([]byte(scoring.Seed()))) }

type job struct {
	Case        int               `json:"case"`
	Run         int               `json:"run"`
	Seed        string            `json:"seed_sha256"`
	Temperature float64           `json:"temperature"`
	Messages    []gateway.Message `json:"messages"`
}
type capture struct{ messages []gateway.Message }

func (p *capture) Run(_ context.Context, c gateway.Call) (gateway.Reply, error) {
	system, err := prompts.Render(scoring.Seed(), c.Variables)
	if err != nil {
		return gateway.Reply{}, err
	}
	p.messages = append([]gateway.Message{{Role: "system", Content: system}}, c.Messages...)
	return gateway.Reply{}, gateway.ErrProvider
}
func plan(cs []sample, w io.Writer) error {
	enc := json.NewEncoder(w)
	for _, c := range cs {
		var p capture
		scoring.New(&p, gateway.Scope{}).ScoreSession(context.Background(), c.Scene, c.Turns, "")
		if len(p.messages) == 0 {
			return errors.New("plan rendering failed")
		}
		for i := 1; i <= 5; i++ {
			if err := enc.Encode(job{c.Case, i, seedHash(), 0.2, p.messages}); err != nil {
				return err
			}
		}
	}
	return nil
}
func execute(args []string) error {
	cs, err := loadCases()
	if err != nil {
		return err
	}
	if len(args) == 1 {
		switch args[0] {
		case "plan":
			return plan(cs, os.Stdout)
		case "seed":
			return json.NewEncoder(os.Stdout).Encode(map[string]string{"task": "scoring", "template": scoring.Seed()})
		}
	}
	if (len(args) == 1 || len(args) == 2) && args[0] == "check" {
		if len(args) == 2 {
			f, e := os.Open(args[1])
			if e != nil {
				return errors.New("cannot open human review sidecar")
			}
			defer f.Close()
			if e = applyReviews(cs, f); e != nil {
				return e
			}
		}
		return check(cs, os.Stdin, os.Stdout)
	}
	return errors.New("usage: scoring seed | plan | check [human-reviews.jsonl] < project-results.jsonl")
}
func main() {
	if err := execute(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
