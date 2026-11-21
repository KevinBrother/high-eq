package service

import (
	"github.com/gin-gonic/gin"
	"high-eq/server/internal/adminops"
)

// Router mounts both independent authentication domains on the same HTTP server.
func (s *Runtime) Router() *gin.Engine {
	return newRouter(s.Payments, s.Health, s.Accounts, s.mountAdmin, s.Membership, s.Assessments, s.Emotion)
}
func (s *Runtime) mountAdmin(r gin.IRouter) { adminops.RegisterDashboard(r, s.db, s.catalog, s.Fields) }
