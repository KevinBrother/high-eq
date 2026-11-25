package emotion

import "testing"

func fullBaselines() Baselines {
	base := 70.0
	threshold := 84.0
	progress := Progress{Days: 7, Today: 30, Ready: true, Reason: "基线已就绪", Baseline: &base, Threshold: &threshold}
	return Baselines{
		Heart:  progress,
		Speech: progress,
		Volume: progress,
		Pitch:  progress,
		HRV:    Trend{Readings: 5, Days: 2, Reason: "仅供历史趋势，不参与提醒"},
	}
}

func TestRestrictKeepsOnlyGrantedPurposes(t *testing.T) {
	b := fullBaselines()
	b.Restrict(false, true)
	if b.Heart.Days != 0 || b.Heart.Today != 0 || b.Heart.Ready || b.Heart.Baseline != nil || b.Heart.Threshold != nil || b.Heart.Reason != HealthOffReason {
		t.Fatalf("health withdrawal retained data: %+v", b.Heart)
	}
	if b.HRV.Readings != 0 || b.HRV.Days != 0 || b.HRV.Reason != HealthOffReason {
		t.Fatalf("health withdrawal retained HRV: %+v", b.HRV)
	}
	for name, p := range map[string]Progress{"speech": b.Speech, "volume": b.Volume, "pitch": b.Pitch} {
		if p.Days != 7 || p.Today != 30 || !p.Ready || p.Baseline == nil || p.Threshold == nil {
			t.Fatalf("health restriction leaked into %s: %+v", name, p)
		}
	}

	b = fullBaselines()
	b.Restrict(true, false)
	for name, p := range map[string]Progress{"speech": b.Speech, "volume": b.Volume, "pitch": b.Pitch} {
		if p.Days != 0 || p.Today != 0 || p.Ready || p.Baseline != nil || p.Threshold != nil || p.Reason != VoiceOffReason {
			t.Fatalf("voice withdrawal retained %s: %+v", name, p)
		}
	}
	if b.Heart.Days != 7 || b.HRV.Readings != 5 {
		t.Fatalf("health withdrawal leaked into voice masking: %+v", b)
	}

	b = fullBaselines()
	b.Restrict(false, false)
	if b.Heart.Reason != HealthOffReason || b.Speech.Reason != VoiceOffReason || b.Volume.Reason != VoiceOffReason || b.Pitch.Reason != VoiceOffReason {
		t.Fatalf("both withdrawals not minimized: %+v", b)
	}
}
