package emotion

import "testing"

func TestNegativeFeedbackSeparatesLegacyAndCurrentSpeechRate(t *testing.T) {
	counts := map[string]int{}
	countNegativeTriggers(counts, record{Triggers: []string{"speech_rate", "volume"}})
	if counts["speech_rate"] != 0 || counts["volume"] != 1 {
		t.Fatalf("legacy speech feedback polluted current thresholds: %+v", counts)
	}
	countNegativeTriggers(counts, record{Triggers: []string{"speech_rate", "pitch"}, SpeechRateUnit: SpeechRateUnitCharactersPerSecond})
	if counts["speech_rate"] != 1 || counts["pitch"] != 1 {
		t.Fatalf("current speech feedback was not counted: %+v", counts)
	}
}
