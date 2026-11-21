// Package assessment implements the versioned WLEIS self-assessment, not a diagnostic scale.
package assessment

import (
	"bytes"
	_ "embed"
	"errors"
	"io"
	"os"
	"strings"

	"github.com/goccy/go-yaml"
)

//go:embed wleis.yaml
var bundled []byte

type Item struct {
	ID        int    `yaml:"id" json:"id"`
	Dimension string `yaml:"dim" json:"dimension"`
	English   string `yaml:"en" json:"-"`
	Chinese   string `yaml:"zh" json:"zh"`
}

type group struct {
	Name    string `yaml:"name"`
	Ability string `yaml:"app_ability"`
	Items   []int  `yaml:"items"`
}

type Instrument struct {
	Version    string                 `yaml:"version" json:"version"`
	Items      []Item                 `yaml:"items" json:"items"`
	Options    []string               `yaml:"options" json:"options"`
	Status     string                 `yaml:"zh_status" json:"-"`
	Scale      struct{ Min, Max int } `yaml:"scale" json:"-"`
	Reverse    []int                  `yaml:"reverse_scored" json:"-"`
	Dimensions map[string]group       `yaml:"dimensions" json:"-"`
}

var badConfig = errors.New("invalid WLEIS instrument")

// Load validates the entire bank before serving. Never fall back on a bad override.
func Load(path string) (*Instrument, error) {
	data := bundled
	if path != "" {
		var err error
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, err
		}
	}
	return parse(data)
}

func parse(data []byte) (*Instrument, error) {
	var b Instrument
	dec := yaml.NewDecoder(bytes.NewReader(data), yaml.Strict())
	if err := dec.Decode(&b); err != nil {
		return nil, err
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return nil, badConfig
	}
	if strings.TrimSpace(b.Version) == "" || b.Status != "final" || b.Scale.Min != 1 || b.Scale.Max != 7 || len(b.Items) != 16 || len(b.Options) != 7 || len(b.Reverse) != 0 || len(b.Dimensions) != 4 {
		return nil, badConfig
	}
	labels := map[string]bool{}
	for _, label := range b.Options {
		if strings.TrimSpace(label) == "" || labels[label] {
			return nil, badConfig
		}
		labels[label] = true
	}
	seen := map[int]bool{}
	for _, dim := range []string{"SEA", "OEA", "UOE", "ROE"} {
		g := b.Dimensions[dim]
		if len(g.Items) != 4 || g.Name == "" || g.Ability == "" {
			return nil, badConfig
		}
		for _, id := range g.Items {
			if id < 1 || id > 16 || seen[id] {
				return nil, badConfig
			}
			item := b.Items[id-1]
			if item.ID != id || item.Dimension != dim || strings.TrimSpace(item.English) == "" || strings.TrimSpace(item.Chinese) == "" {
				return nil, badConfig
			}
			seen[id] = true
		}
	}
	return &b, nil
}
