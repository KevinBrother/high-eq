package growth

import (
	"fmt"
	"testing"

	"github.com/google/uuid"
)

func TestValidateContentMinimumAndLegalExtensions(t *testing.T) {
	if err := validateContent(contentFixture(50, 20)); err != nil {
		t.Fatalf("minimum content rejected: %v", err)
	}

	t.Run("below minimum exercises", func(t *testing.T) {
		if err := validateContent(contentFixture(49, 20)); err == nil {
			t.Fatal("content with fewer than 50 exercises accepted")
		}
	})
	t.Run("below minimum cards", func(t *testing.T) {
		if err := validateContent(contentFixture(50, 19)); err == nil {
			t.Fatal("content with fewer than 20 cards accepted")
		}
	})
	t.Run("friends observation exercise", func(t *testing.T) {
		c := contentFixture(50, 20)
		c.Exercises = append(c.Exercises, fixtureExercise(51, "friends", "observation"))
		if err := validateContent(c); err != nil {
			t.Fatalf("legal 51st exercise rejected: %v", err)
		}
	})
	t.Run("twenty first card", func(t *testing.T) {
		c := contentFixture(50, 20)
		c.Cards = append(c.Cards, fixtureCard(1021, "friends"))
		if err := validateContent(c); err != nil {
			t.Fatalf("legal 21st card rejected: %v", err)
		}
	})
	t.Run("exercise and card together", func(t *testing.T) {
		c := contentFixture(50, 20)
		c.Exercises = append(c.Exercises, fixtureExercise(51, "friends", "observation"))
		c.Cards = append(c.Cards, fixtureCard(1021, "friends"))
		if err := validateContent(c); err != nil {
			t.Fatalf("legal 51st exercise and 21st card rejected: %v", err)
		}
	})
}

func TestValidateContentRejectsInvalidExtensions(t *testing.T) {
	t.Run("invalid exercise", func(t *testing.T) {
		c := contentFixture(50, 20)
		bad := fixtureExercise(51, "friends", "observation")
		bad.Question = ""
		c.Exercises = append(c.Exercises, bad)
		if err := validateContent(c); err == nil {
			t.Fatal("invalid appended exercise accepted")
		}
	})
	t.Run("invalid card", func(t *testing.T) {
		c := contentFixture(50, 20)
		bad := fixtureCard(1021, "friends")
		bad.Body = ""
		c.Cards = append(c.Cards, bad)
		if err := validateContent(c); err == nil {
			t.Fatal("invalid appended card accepted")
		}
	})
}

func contentFixture(exercises, cards int) Content {
	c := Content{
		SourceNote: "测试夹具：原创虚构材料",
		Exercises:  make([]Exercise, exercises),
		Cards:      make([]Card, cards),
	}
	for i := range c.Exercises {
		c.Exercises[i] = fixtureExercise(i+1, scenes[i%len(scenes)], focuses[i%len(focuses)])
	}
	for i := range c.Cards {
		c.Cards[i] = fixtureCard(1001+i, scenes[i%len(scenes)])
	}
	return c
}

func dueLevelReviewContent() Content {
	return Content{
		SourceNote: "测试夹具",
		Exercises: []Exercise{
			fixtureExercise(101, "friends", "observation"),
			fixtureExercise(102, "friends", "observation"),
		},
		Cards: []Card{fixtureCard(1101, "friends")},
	}
}

func fixtureExercise(n int, scene, focus string) Exercise {
	return Exercise{
		ID:          fixtureUUID(n),
		Scene:       scene,
		Focus:       focus,
		Question:    fmt.Sprintf("fixture question %d", n),
		Choices:     []string{"fixture choice a", "fixture choice b"},
		AnswerIndex: 0,
		Explanation: fmt.Sprintf("fixture explanation %d", n),
	}
}

func fixtureCard(n int, scene string) Card {
	return Card{
		ID:    fixtureUUID(n),
		Scene: scene,
		Title: fmt.Sprintf("fixture card %d", n),
		Body:  fmt.Sprintf("fixture body %d", n),
	}
}

func fixtureUUID(n int) uuid.UUID {
	return uuid.MustParse(fmt.Sprintf("90000000-0000-4000-8000-%012d", n))
}

func fixtureContainsExercise(c Content, id uuid.UUID) bool {
	for _, exercise := range c.Exercises {
		if exercise.ID == id {
			return true
		}
	}
	return false
}
