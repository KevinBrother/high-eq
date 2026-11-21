package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"math"
	"strings"

	"high-eq/server/internal/scoring"
)

type observation struct {
	Case        int     `json:"case"`
	Run         int     `json:"run"`
	Model       string  `json:"model"`
	Version     string  `json:"prompt_version"`
	Seed        string  `json:"seed_sha256"`
	Temperature float64 `json:"temperature"`
	Output      string  `json:"output"`
}

func regression(id int, v *scoring.Full) bool {
	switch id {
	case 11:
		return v.Mode == "express" && v.NVC.Observation.Score == 0
	case 12:
		return v.Mode == "express" && v.NVC.Observation.Score == 15 && v.TargetTurn != nil && *v.TargetTurn == 2
	}
	return true
}
func mean(xs []int) float64 {
	var sum float64
	for _, x := range xs {
		sum += float64(x)
	}
	return sum / float64(len(xs))
}
func deviation(xs []int) float64 {
	m := mean(xs)
	var sum float64
	for _, x := range xs {
		sum += math.Pow(float64(x)-m, 2)
	}
	return math.Sqrt(sum / float64(len(xs)))
}
func span(xs []int) int {
	lo, hi := xs[0], xs[0]
	for _, x := range xs {
		lo = min(lo, x)
		hi = max(hi, x)
	}
	return hi - lo
}

// Read exactly five consecutive FIRST attempts per synthetic case. No trimming,
// replacement samples, or dropping bad rows before computing the format rate.
func check(cs []sample, r io.Reader, w io.Writer) error {
	scan := bufio.NewScanner(r)
	scan.Buffer(make([]byte, 4096), 32<<20)
	var model, version string
	okCount, pending := 0, 0
	pass := true
	for _, c := range cs {
		var totals []int
		var levels [3][]int
		regOK := true
		for i := 1; i <= 5; i++ {
			var rec observation
			if !scan.Scan() || decode(scan.Bytes(), &rec) != nil || rec.Case != c.Case || rec.Run != i || rec.Seed != seedHash() || rec.Temperature != 0.2 || strings.TrimSpace(rec.Model) == "" || strings.TrimSpace(rec.Version) == "" {
				return fmt.Errorf("case %d run %d: missing or invalid run identity/settings", c.Case, i)
			}
			if model == "" {
				model, version = rec.Model, rec.Version
			}
			if rec.Model != model || rec.Version != version {
				return errors.New("mixed model or prompt version")
			}
			v, err := scoring.ParseFull([]byte(rec.Output), c.userTurns())
			if err != nil {
				pass = false
				continue
			}
			okCount++
			totals = append(totals, v.NVC.Total)
			for j, l := range []int{v.Emotion.ReadOthers.Level, v.Emotion.SelfManagement.Level, v.Emotion.Relationship.Level} {
				levels[j] = append(levels[j], l)
			}
			regOK = regOK && regression(c.Case, v)
		}
		reviewed := c.LabelStatus != "待人工复核"
		if !reviewed {
			pending++
		}
		if len(totals) != 5 {
			fmt.Fprintf(w, "case=%d format=%d/5 incomplete\n", c.Case, len(totals))
			continue
		}
		sd := deviation(totals)
		stable := sd <= 5
		accurate := math.Abs(mean(totals)-float64(c.Expected.Total)) <= 10
		var ranges [3]int
		for j, xs := range levels {
			ranges[j] = span(xs)
			stable = stable && ranges[j] <= 1
			accurate = accurate && math.Abs(mean(xs)-float64(c.Expected.Emotion[j])) <= 1
		}
		acc := fmt.Sprint(accurate)
		if !reviewed {
			acc = "pending"
		}
		fmt.Fprintf(w, "case=%d format=5/5 nvc_mean=%.2f nvc_sd=%.2f emotion_ranges=%v stable=%t accuracy=%s regression=%t\n", c.Case, mean(totals), sd, ranges, stable, acc, regOK)
		pass = pass && stable && regOK && (!reviewed || accurate)
	}
	if scan.Scan() || scan.Err() != nil {
		return errors.New("extra or unreadable run records")
	}
	fmt.Fprintf(w, "format=%d/%d pending_human_reviews=%d\n", okCount, 5*len(cs), pending)
	if !pass || pending > 0 {
		return errors.New("evaluation incomplete or thresholds not met")
	}
	return nil
}
