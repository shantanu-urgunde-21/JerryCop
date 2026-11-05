package router

import (
	configparser "JerryCop/internal/configParser"
	"testing"
)

func TestMatchPrefix(t *testing.T) {
	tests := []struct {
		reqPath  string
		prefix   string
		expected bool
	}{
		{"/api/users", "/api", true},
		{"/api", "/api", true},
		{"/api/", "/api", true},
		{"/apikey", "/api", false},
		{"/api-keys", "/api", false},
		{"/users/123", "/users", true},
		{"/other", "/", true},
		{"/other", "", true},
	}

	for _, tc := range tests {
		got := MatchPrefix(tc.reqPath, tc.prefix)
		if got != tc.expected {
			t.Errorf("MatchPrefix(%q, %q) = %v; want %v", tc.reqPath, tc.prefix, got, tc.expected)
		}
	}
}

func TestFindMatchingServer_LPM(t *testing.T) {
	servers := []configparser.ServerConfig{
		{
			ServerRouting: []configparser.Routing{
				{
					Prefix:    "/",
					ProxyPass: []string{"http://root-backend"},
				},
			},
		},
		{
			// Single server with multiple prefixes
			ServerRouting: []configparser.Routing{
				{
					Prefix:    "/api",
					ProxyPass: []string{"http://api-backend"},
				},
				{
					Prefix:    "/api/v1",
					ProxyPass: []string{"http://v1-backend"},
				},
			},
		},
	}

	matched, found := FindMatchingServer("/api/v1/users", servers)
	if !found || matched.Prefix != "/api/v1" {
		t.Fatalf("expected /api/v1, got %+v", matched)
	}

	matched, found = FindMatchingServer("/api/users", servers)
	if !found || matched.Prefix != "/api" {
		t.Fatalf("expected /api, got %+v", matched)
	}

	matched, found = FindMatchingServer("/something-else", servers)
	if !found || matched.Prefix != "/" {
		t.Fatalf("expected /, got %+v", matched)
	}
}

func TestBuildTargetURL(t *testing.T) {
	target, err := BuildTargetURL("http://localhost:8080", "/api/users", "id=123&sort=asc")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	expected := "http://localhost:8080/api/users?id=123&sort=asc"
	if target != expected {
		t.Errorf("BuildTargetURL = %s; want %s", target, expected)
	}
}

func BenchmarkBuildTargetURL(b *testing.B) {
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_, _ = BuildTargetURL("http://localhost:8080", "/api/users", "id=123&sort=asc")
	}
}
