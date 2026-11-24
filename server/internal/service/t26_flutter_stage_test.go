//go:build integration && t26flutter

package service

import (
	"io"
	"strings"
	"testing"
)

const t26FlutterStagePrefix = "T26_STAGE "

var t26FlutterStages = [...]string{"login", "assessment", "plan", "chat", "score"}
var t26FlutterAssessmentPhases = [...]string{"load", "answer", "scene", "submit", "continueReady"}
var t26FlutterChatPhases = [...]string{"openPlan", "planOpened", "consent", "chatInput", "send", "awaitReply", "verifyReply", "revealFinish"}
var t26FlutterScorePhases = [...]string{
	"finish", "feedback", "returnLobby", "lobbyCurrent", "lobbyBack",
	"returnPlan", "planCompletion", "revealCompletion", "readback", "verified",
}

// Accept only complete stdout lines that match the next stage or phase.
// One bounded line buffer suffices even when Flutter emits a long diagnostic.
type t26FlutterStageReceipt struct {
	line               [32]byte
	used               int
	reached            int
	phase              int
	finishBeforeScroll string
}

func (r *t26FlutterStageReceipt) Write(p []byte) (int, error) {
	for _, b := range p {
		if b == '\n' {
			if r.used <= len(r.line) {
				r.acceptLine(strings.TrimSuffix(string(r.line[:r.used]), "\r"))
			}
			r.used = 0
			continue
		}
		if r.used < len(r.line) {
			r.line[r.used] = b
			r.used++
		} else {
			r.used = len(r.line) + 1
		}
	}
	return len(p), nil
}

func (r *t26FlutterStageReceipt) acceptLine(line string) {
	if r.reached < len(t26FlutterStages) && line == t26FlutterStagePrefix+t26FlutterStages[r.reached] {
		r.reached++
		r.phase = 0
		return
	}
	if r.stage() == "chat" && r.phase == len(t26FlutterChatPhases) && r.finishBeforeScroll == "" {
		switch line {
		case "T26_FINISH hit":
			r.finishBeforeScroll = "hit"
		case "T26_FINISH miss":
			r.finishBeforeScroll = "miss"
		}
	}
	prefix, phases := r.phases()
	if r.phase >= len(phases) {
		return
	}
	if line == prefix+phases[r.phase] {
		r.phase++
	} else if r.stage() == "chat" && phases[r.phase] == "consent" && line == prefix+"chatInput" {
		// An already-granted practice purpose goes straight to chat.
		r.phase += 2
	}
}

func (r *t26FlutterStageReceipt) phases() (string, []string) {
	switch r.stage() {
	case "assessment":
		return "T26_ASSESSMENT ", t26FlutterAssessmentPhases[:]
	case "chat":
		return "T26_CHAT ", t26FlutterChatPhases[:]
	case "score":
		return "T26_SCORE ", t26FlutterScorePhases[:]
	default:
		return "", nil
	}
}

func (r *t26FlutterStageReceipt) stage() string {
	if r.reached == 0 {
		return "unreported"
	}
	return t26FlutterStages[r.reached-1]
}

func (r *t26FlutterStageReceipt) failureLocation() string {
	location := "stage=" + r.stage()
	if r.phase != 0 {
		_, phases := r.phases()
		location += ", phase=" + phases[r.phase-1]
	}
	if r.finishBeforeScroll != "" {
		location += ", finish_before_scroll=" + r.finishBeforeScroll
	}
	return location
}

func (r *t26FlutterStageReceipt) completed() bool {
	return r.stage() == "score" && r.phase == len(t26FlutterScorePhases) && r.finishBeforeScroll != ""
}

func TestT26FlutterStageReceipt(t *testing.T) {
	var receipt t26FlutterStageReceipt
	for _, step := range []struct {
		chunk string
		want  string
	}{
		{"", "unreported"},
		{"T26_STAGE score\nT26_STAGE login synthetic-proof\n", "unreported"},
		{"diagnostic T26_STAGE login\nT26_STAGE log", "unreported"},
		{"in\r\n", "login"},
		{"T26_STAGE assessment" + strings.Repeat("x", 128<<10) + "\n", "login"},
		{"T26_STAGE assessment\nT26_STAGE plan\n", "plan"},
		{"T26_STAGE unknown\nT26_STAGE login\n", "plan"},
		{"T26_STAGE chat\nT26_STAGE score", "chat"},
		{"\n", "score"},
	} {
		n, err := io.WriteString(&receipt, step.chunk)
		if n != len(step.chunk) || err != nil {
			t.Fatalf("unexpected stage writer result: n=%d, err=%v", n, err)
		}
		if got := receipt.stage(); got != step.want {
			t.Fatalf("stage = %q, want %q", got, step.want)
		}
	}
}

func TestT26FlutterAssessmentPhaseReceipt(t *testing.T) {
	var receipt t26FlutterStageReceipt
	for i, step := range []struct {
		chunk string
		want  string
	}{
		{"T26_ASSESSMENT load\nT26_STAGE login\nT26_ASSESSMENT load\n", "stage=login"},
		{"T26_STAGE assessment\nT26_ASSESSMENT answer\n", "stage=assessment"},
		{"diagnostic T26_ASSESSMENT load\nT26_ASSESSMENT load extra\nT26_ASSESSMENT lo", "stage=assessment"},
		{"ad\r\n", "stage=assessment, phase=load"},
		{"T26_ASSESSMENT load\nT26_ASSESSMENT scene\n", "stage=assessment, phase=load"},
		{"T26_ASSESSMENT answer" + strings.Repeat("x", 128<<10) + "\n", "stage=assessment, phase=load"},
		{"T26_ASSESSMENT answer\n", "stage=assessment, phase=answer"},
		{"T26_ASSESSMENT scene\nT26_ASSESSMENT unknown\n", "stage=assessment, phase=scene"},
		{"T26_ASSESSMENT submit\nT26_ASSESSMENT continueReady", "stage=assessment, phase=submit"},
		{"\n", "stage=assessment, phase=continueReady"},
		{"T26_STAGE plan\nT26_ASSESSMENT load\n", "stage=plan"},
	} {
		_, _ = io.WriteString(&receipt, step.chunk)
		if got := receipt.failureLocation(); got != step.want {
			t.Fatalf("step %d: location = %q, want %q", i+1, got, step.want)
		}
	}
}

func TestT26FlutterChatAndScorePhaseReceipt(t *testing.T) {
	var receipt t26FlutterStageReceipt
	for i, step := range []struct {
		chunk string
		want  string
	}{
		{"T26_STAGE login\nT26_STAGE assessment\nT26_STAGE plan\nT26_CHAT openPlan\n", "stage=plan"},
		{"T26_STAGE chat\nT26_CHAT send\nT26_CHAT openPlan extra\nT26_CHAT open", "stage=chat"},
		{"Plan\r\n", "stage=chat, phase=openPlan"},
		{"T26_CHAT planOpened\nT26_CHAT consent" + strings.Repeat("x", 128<<10) + "\n", "stage=chat, phase=planOpened"},
		{"T26_CHAT consent\nT26_SCORE finish\nT26_CHAT send\n", "stage=chat, phase=consent"},
		{"T26_CHAT chatInput\nT26_CHAT send\n", "stage=chat, phase=send"},
		{"T26_CHAT awaitReply\nT26_CHAT revealFinish\n", "stage=chat, phase=awaitReply"},
		{"T26_CHAT verifyReply\nT26_CHAT revealFinish\n", "stage=chat, phase=revealFinish"},
		{"T26_STAGE score\nT26_SCORE finish\nT26_CHAT revealFinish\n", "stage=score, phase=finish"},
		{"T26_SCORE feedback\nT26_SCORE returnPlan\nT26_SCORE returnLobby\n", "stage=score, phase=returnLobby"},
		{"T26_SCORE lobbyBack\nT26_SCORE lobbyCurrent\n", "stage=score, phase=lobbyCurrent"},
		{"T26_SCORE lobbyBack extra\nT26_SCORE lobbyBack\n", "stage=score, phase=lobbyBack"},
		{"T26_SCORE returnPlan\nT26_SCORE readback\n", "stage=score, phase=returnPlan"},
		{"T26_SCORE planCompletion\nT26_SCORE revealCompletion\n", "stage=score, phase=revealCompletion"},
		{"T26_SCORE readback\nT26_SCORE verified", "stage=score, phase=readback"},
		{"\n", "stage=score, phase=verified"},
	} {
		_, _ = io.WriteString(&receipt, step.chunk)
		if got := receipt.failureLocation(); got != step.want {
			t.Fatalf("step %d: location = %q, want %q", i+1, got, step.want)
		}
	}
}

func TestT26FlutterChatPhaseReceiptWithExistingConsent(t *testing.T) {
	var receipt t26FlutterStageReceipt
	_, _ = io.WriteString(&receipt, "T26_STAGE login\nT26_STAGE assessment\nT26_STAGE plan\nT26_STAGE chat\n"+
		"T26_CHAT openPlan\nT26_CHAT planOpened\nT26_CHAT chatInput\nT26_CHAT consent\n")
	if got, want := receipt.failureLocation(), "stage=chat, phase=chatInput"; got != want {
		t.Fatalf("location = %q, want %q", got, want)
	}
}

func TestT26FlutterFinishReceipt(t *testing.T) {
	var receipt t26FlutterStageReceipt
	_, _ = io.WriteString(&receipt, "T26_STAGE login\nT26_STAGE assessment\nT26_STAGE plan\nT26_STAGE chat\n"+
		"T26_CHAT openPlan\nT26_CHAT planOpened\nT26_CHAT chatInput\nT26_CHAT send\nT26_CHAT awaitReply\nT26_CHAT verifyReply\n"+
		"T26_FINISH hit\nT26_CHAT revealFinish\nT26_FINISH hit extra\nT26_FINISH miss\nT26_FINISH hit\n"+
		"T26_STAGE score\nT26_SCORE finish\n")
	if got, want := receipt.failureLocation(), "stage=score, phase=finish, finish_before_scroll=miss"; got != want {
		t.Fatalf("location = %q, want %q", got, want)
	}
}
