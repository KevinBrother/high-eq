package service

import (
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/scoring"
	"high-eq/server/internal/training"
)

func (s *Runtime) practiceService() *training.Service {
	if s == nil {
		return nil
	}
	return s.Practice
}
func (s *Runtime) initPractice() {
	s.Practice = &training.Service{Accounts: s.Accounts, Rights: s.Membership, Fields: s.Fields, Data: s.Data, DB: s.db, Bus: s.Bus, Router: func(stop gateway.Stop) (scoring.Runner, error) { return s.catalog.NewRouter(s.Data, stop) }}
}
