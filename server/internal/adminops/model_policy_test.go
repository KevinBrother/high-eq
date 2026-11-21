package adminops

import (
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestModelManagementRestricted(t *testing.T) {
	for _, path := range []string{"GET /admissions", "POST /admissions", "DELETE /admissions/:ref", "GET /models", "PATCH /models/:id", "POST /models", "POST /models/:id/test", "GET /routes", "PUT /routes/:task"} {
		if r := rules[path]; !r.live || !r.super {
			t.Errorf("unsafe or missing policy: %s", path)
		}
	}
}

func TestManagementObjectRequiresExplicitEvidence(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, tc := range []struct {
		body  string
		valid bool
	}{
		{`{"cross_border":false,"days":0}`, true},
		{`{"days":0}`, false}, {`{"cross_border":null,"days":0}`, false},
		{`{"cross_border":true,"cross_border":false,"days":0}`, false},
		{`{"cross_border":false,"days":0,"messages":[]}`, false},
		{`{"cross_border":false,"days":0} {}`, false},
	} {
		c, _ := gin.CreateTestContext(httptest.NewRecorder())
		c.Request = httptest.NewRequest("POST", "/", strings.NewReader(tc.body))
		_, err := object(c, "cross_border days", "cross_border days", "")
		if (err == nil) != tc.valid {
			t.Error("incorrect management input validation")
		}
	}
}
