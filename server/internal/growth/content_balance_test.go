package growth

import "testing"

func TestDefaultContentHasVariedAnswerPositions(t *testing.T) {
	content, err := LoadContent()
	if err != nil {
		t.Fatal(err)
	}

	positions := make(map[int]struct{})
	for _, exercise := range content.Exercises {
		positions[exercise.AnswerIndex] = struct{}{}
	}
	if len(positions) < 2 {
		t.Fatalf("default content must use at least two answer positions, got %v", positions)
	}
}

func TestDefaultExerciseAnswerContract(t *testing.T) {
	content, err := LoadContent()
	if err != nil {
		t.Fatal(err)
	}

	service := &PlanService{Content: content}
	for _, exercise := range content.Exercises {
		for choice := range exercise.Choices {
			correct, explanation, err := service.AnswerExercise(exercise.ID, choice)
			if err != nil {
				t.Fatalf("exercise %s choice %d: %v", exercise.ID, choice, err)
			}
			if want := choice == exercise.AnswerIndex; correct != want {
				t.Errorf("exercise %s choice %d: correct=%v want %v", exercise.ID, choice, correct, want)
			}
			if explanation != exercise.Explanation {
				t.Errorf("exercise %s choice %d: explanation changed", exercise.ID, choice)
			}
		}
	}
}
