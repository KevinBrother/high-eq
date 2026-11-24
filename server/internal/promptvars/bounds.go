// Package promptvars records the byte bounds of values that production task
// calls actually put into published prompt variables. It is separate from the
// custom-scenario input limit: that larger text stays in the first user JSON.
package promptvars

const (
	RolePlaySceneMaxBytes = 94

	ScoringAssessmentMaxBytes = 12
	ScoringTargetItemMaxBytes = 11
	ScoringRetryMaxBytes      = 96

	ProfileSceneMaxBytes   = 7
	ProfileOptionsMaxBytes = 501
)
