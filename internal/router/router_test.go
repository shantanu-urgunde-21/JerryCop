package router

import (
	"JerryCop/internal/request"
	configparser "JerryCop/internal/configParser"
	"net/http/httptest"
	"testing"
	"time"
)

func TestGetPath_Random(t *testing.T) {
	cfg := &configparser.Proxy{
		DistAlgo: "RANDOM",
		ServerConfig: []configparser.ServerConfig{
			{
				ServerRouting: []configparser.Routing{
					{
						Prefix:    "/api",
						ProxyPass: []string{"http://10.0.0.1:8000", "http://10.0.0.2:8000"},
					},
				},
			},
		},
	}

	req := httptest.NewRequest("GET", "/api/v1/users?active=true", nil)
	job := &request.RequestsJob{Req: req}

	target, err := GetPath(job, cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	expectedPrefix1 := "http://10.0.0.1:8000/api/v1/users?active=true"
	expectedPrefix2 := "http://10.0.0.2:8000/api/v1/users?active=true"
	if target != expectedPrefix1 && target != expectedPrefix2 {
		t.Errorf("got %s, expected either %s or %s", target, expectedPrefix1, expectedPrefix2)
	}
}

func TestGetPath_NoMatch(t *testing.T) {
	cfg := &configparser.Proxy{
		DistAlgo: "RANDOM",
		ServerConfig: []configparser.ServerConfig{
			{
				ServerRouting: []configparser.Routing{
					{
						Prefix:    "/admin",
						ProxyPass: []string{"http://10.0.0.1:8000"},
					},
				},
			},
		},
	}

	req := httptest.NewRequest("GET", "/public/index.html", nil)
	job := &request.RequestsJob{Req: req}

	_, err := GetPath(job, cfg)
	if err == nil {
		t.Fatal("expected error for unmatched route, got nil")
	}
}

func TestGetPath_UnsupportedAlgo(t *testing.T) {
	cfg := &configparser.Proxy{
		DistAlgo: "UNSUPPORTED_ALGO",
		ServerConfig: []configparser.ServerConfig{
			{
				ServerRouting: []configparser.Routing{
					{
						Prefix:    "/",
						ProxyPass: []string{"http://10.0.0.1:8000"},
					},
				},
			},
		},
	}

	req := httptest.NewRequest("GET", "/test", nil)
	job := &request.RequestsJob{Req: req}

	_, err := GetPath(job, cfg)
	if err == nil {
		t.Fatal("expected error for unsupported algorithm, got nil")
	}
}

func TestGetPath_RoundRobin(t *testing.T) {
	cfg := &configparser.Proxy{
		DistAlgo: "ROUND_ROBIN",
		ServerConfig: []configparser.ServerConfig{
			{
				ServerRouting: []configparser.Routing{
					{
						Prefix:    "/api",
						ProxyPass: []string{"http://10.0.0.1:8000", "http://10.0.0.2:8000"},
					},
				},
			},
		},
	}

	state := State{}.NewState(cfg)

	req1 := httptest.NewRequest("GET", "/api/data", nil)
	target1, err := GetPath(&request.RequestsJob{Req: req1}, cfg, &state)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	req2 := httptest.NewRequest("GET", "/api/data", nil)
	target2, err := GetPath(&request.RequestsJob{Req: req2}, cfg, &state)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if target1 != "http://10.0.0.1:8000/api/data" {
		t.Errorf("expected target1 to be 10.0.0.1, got %s", target1)
	}
	if target2 != "http://10.0.0.2:8000/api/data" {
		t.Errorf("expected target2 to be 10.0.0.2, got %s", target2)
	}
}

func TestGetPath_LeastConnection(t *testing.T) {
	cfg := &configparser.Proxy{
		DistAlgo: "LEAST_CONNECTION",
		ServerConfig: []configparser.ServerConfig{
			{
				ServerRouting: []configparser.Routing{
					{
						Prefix:    "/api",
						ProxyPass: []string{"http://10.0.0.1:8000", "http://10.0.0.2:8000"},
					},
				},
			},
		},
	}

	state := State{}.NewState(cfg)

	done1 := make(chan struct{})
	req1 := httptest.NewRequest("GET", "/api/data", nil)
	target1, err := GetPath(&request.RequestsJob{Req: req1, Done: done1}, cfg, &state)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if target1 != "http://10.0.0.1:8000/api/data" {
		t.Errorf("expected target1 to be 10.0.0.1, got %s", target1)
	}
	if c := state.NumOfConns["http://10.0.0.1:8000"].Load(); c != 1 {
		t.Errorf("expected 1 active conn on 10.0.0.1, got %d", c)
	}

	// Request 2 should choose 10.0.0.2 since 10.0.0.1 has 1 active connection
	done2 := make(chan struct{})
	req2 := httptest.NewRequest("GET", "/api/data", nil)
	target2, err := GetPath(&request.RequestsJob{Req: req2, Done: done2}, cfg, &state)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if target2 != "http://10.0.0.2:8000/api/data" {
		t.Errorf("expected target2 to be 10.0.0.2, got %s", target2)
	}
	if c := state.NumOfConns["http://10.0.0.2:8000"].Load(); c != 1 {
		t.Errorf("expected 1 active conn on 10.0.0.2, got %d", c)
	}

	// Finish request 1 (on 10.0.0.1)
	close(done1)

	// Wait for goroutine to decrement
	for i := 0; i < 50; i++ {
		if state.NumOfConns["http://10.0.0.1:8000"].Load() == 0 {
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	if c := state.NumOfConns["http://10.0.0.1:8000"].Load(); c != 0 {
		t.Errorf("expected 0 active conns on 10.0.0.1, got %d", c)
	}

	// Now 10.0.0.1 has 0 active connections while 10.0.0.2 still has 1 active connection
	// Request 3 must be routed to 10.0.0.1
	done3 := make(chan struct{})
	req3 := httptest.NewRequest("GET", "/api/data", nil)
	target3, err := GetPath(&request.RequestsJob{Req: req3, Done: done3}, cfg, &state)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if target3 != "http://10.0.0.1:8000/api/data" {
		t.Errorf("expected target3 to be 10.0.0.1, got %s", target3)
	}

	close(done2)
	close(done3)
}

func TestGetPath_LeastConnAlias(t *testing.T) {
	cfg := &configparser.Proxy{
		DistAlgo: "LEAST_CONN",
		ServerConfig: []configparser.ServerConfig{
			{
				ServerRouting: []configparser.Routing{
					{
						Prefix:    "/",
						ProxyPass: []string{"http://10.0.0.1:8000"},
					},
				},
			},
		},
	}

	req := httptest.NewRequest("GET", "/test", nil)
	job := &request.RequestsJob{Req: req}

	target, err := GetPath(job, cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if target != "http://10.0.0.1:8000/test" {
		t.Errorf("expected target to be http://10.0.0.1:8000/test, got %s", target)
	}
}

func TestGetPath_SingleServerMultiplePrefixes(t *testing.T) {
	cfg := &configparser.Proxy{
		DistAlgo: "ROUND_ROBIN",
		ServerConfig: []configparser.ServerConfig{
			{
				Names: []string{"multi_route_server"},
				ServerRouting: []configparser.Routing{
					{
						Prefix:    "/",
						ProxyPass: []string{"http://10.0.0.1:8000"},
					},
					{
						Prefix:    "/api",
						ProxyPass: []string{"http://10.0.0.2:8000"},
					},
				},
			},
		},
	}

	state := State{}.NewState(cfg)

	// Path /api/users should match /api -> 10.0.0.2
	reqAPI := httptest.NewRequest("GET", "/api/users", nil)
	targetAPI, err := GetPath(&request.RequestsJob{Req: reqAPI}, cfg, &state)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if targetAPI != "http://10.0.0.2:8000/api/users" {
		t.Errorf("expected 10.0.0.2, got %s", targetAPI)
	}

	// Path /about should match / -> 10.0.0.1
	reqRoot := httptest.NewRequest("GET", "/about", nil)
	targetRoot, err := GetPath(&request.RequestsJob{Req: reqRoot}, cfg, &state)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if targetRoot != "http://10.0.0.1:8000/about" {
		t.Errorf("expected 10.0.0.1, got %s", targetRoot)
	}
}
