package service

import "github.com/gin-gonic/gin"

// Router mounts both independent authentication domains on the same HTTP server.
func (s *Runtime) Router() *gin.Engine { return newRouter(s.Health, s.Accounts, s.db, s.Membership) }
