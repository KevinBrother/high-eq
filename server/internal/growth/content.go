package growth

import (
	"errors"
	"fmt"
	"sync"

	"github.com/goccy/go-yaml"
	"github.com/google/uuid"

	contentdata "high-eq/server/content"
)

type Exercise struct {
	ID          uuid.UUID `yaml:"id"`
	Scene       string    `yaml:"scene"`
	Focus       string    `yaml:"focus"`
	Question    string    `yaml:"question"`
	Choices     []string  `yaml:"choices"`
	AnswerIndex int       `yaml:"answer_index"`
	Explanation string    `yaml:"explanation"`
}

type Card struct {
	ID    uuid.UUID `yaml:"id"`
	Scene string    `yaml:"scene"`
	Title string    `yaml:"title"`
	Body  string    `yaml:"body"`
}

type Content struct {
	SourceNote string     `yaml:"source_note"`
	Exercises  []Exercise `yaml:"exercises"`
	Cards      []Card     `yaml:"cards"`
}

var (
	contentOnce sync.Once
	loaded      Content
	contentErr  error
)

// LoadContent parses the embedded content exactly once. Callers must not keep
// a mutable copy of the returned slices; scheduling treats it as read-only.
func LoadContent() (Content, error) {
	contentOnce.Do(func() {
		contentErr = yaml.Unmarshal(contentdata.T26YAML, &loaded)
		if contentErr == nil {
			contentErr = validateContent(loaded)
		}
	})
	return loaded, contentErr
}

func validateContent(c Content) error {
	if c.SourceNote == "" || len(c.Exercises) < 50 || len(c.Cards) < 20 {
		return errors.New("T26 content must contain at least 50 exercises and 20 cards")
	}
	ids := make(map[uuid.UUID]bool, len(c.Exercises)+len(c.Cards))
	sceneCounts := make(map[string]int, 5)
	cardCounts := make(map[string]int, 5)
	for _, e := range c.Exercises {
		if e.ID == uuid.Nil || ids[e.ID] || !validScene(e.Scene) || !validFocus(e.Focus) || e.Question == "" || len(e.Choices) < 2 || e.AnswerIndex < 0 || e.AnswerIndex >= len(e.Choices) || e.Explanation == "" {
			return fmt.Errorf("invalid exercise %q", e.ID)
		}
		for _, choice := range e.Choices {
			if choice == "" {
				return fmt.Errorf("empty choice in exercise %q", e.ID)
			}
		}
		ids[e.ID] = true
		sceneCounts[e.Scene]++
	}
	for _, v := range c.Cards {
		if v.ID == uuid.Nil || ids[v.ID] || !validScene(v.Scene) || v.Title == "" || v.Body == "" {
			return fmt.Errorf("invalid card %q", v.ID)
		}
		ids[v.ID] = true
		cardCounts[v.Scene]++
	}
	for _, scene := range scenes {
		if sceneCounts[scene] == 0 || cardCounts[scene] == 0 {
			return fmt.Errorf("missing content for scene %s", scene)
		}
	}
	return nil
}

var scenes = [...]string{"work", "partner", "family", "friends", "social"}
var focuses = [...]string{"observation", "feeling", "need", "request"}

func validScene(v string) bool {
	for _, s := range scenes {
		if v == s {
			return true
		}
	}
	return false
}
func validFocus(v string) bool {
	for _, f := range focuses {
		if v == f {
			return true
		}
	}
	return false
}
