package workers

import (
	"JerryCop/internal/configParser"
	"JerryCop/internal/request"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCopyHeaders(t *testing.T) {
	src := http.Header{
		"X-Custom-Header": []string{"val1", "val2"},
		"Authorization":   []string{"Bearer token123"},
	}
	dest := make(http.Header)

	copyHeaders(src, dest)

	if len(dest["X-Custom-Header"]) != 2 {
		t.Fatalf("expected 2 values, got %d", len(dest["X-Custom-Header"]))
	}
	if dest.Get("Authorization") != "Bearer token123" {
		t.Errorf("expected Bearer token123, got %s", dest.Get("Authorization"))
	}
}

func TestForwardRequest_Success(t *testing.T) {
	// Mock upstream backend server
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Upstream-Header", "served-by-backend")
		w.WriteHeader(http.StatusAccepted)
		body, _ := io.ReadAll(r.Body)
		w.Write([]byte("echo: " + string(body)))
	}))
	defer backend.Close()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/data", strings.NewReader("payload123"))
	req.Header.Set("Content-Type", "text/plain")

	job := &request.RequestsJob{
		ID:     "test-1",
		Req:    req,
		Writer: rec,
		Done:   make(chan struct{}),
	}

	forwardRequest(job, defaultClient, backend.URL+"/data")

	resp := rec.Result()
	if resp.StatusCode != http.StatusAccepted {
		t.Errorf("expected status %d, got %d", http.StatusAccepted, resp.StatusCode)
	}
	if resp.Header.Get("X-Upstream-Header") != "served-by-backend" {
		t.Errorf("expected header X-Upstream-Header to be forwarded")
	}
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "echo: payload123" {
		t.Errorf("unexpected body: %s", string(body))
	}
}

func TestForwardRequest_BackendDown(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/test", nil)

	job := &request.RequestsJob{
		ID:     "test-down",
		Req:    req,
		Writer: rec,
		Done:   make(chan struct{}),
	}

	// Port 1 is not running anything
	forwardRequest(job, defaultClient, "http://127.0.0.1:1/nonexistent")

	resp := rec.Result()
	if resp.StatusCode != http.StatusBadGateway {
		t.Errorf("expected 502 Bad Gateway when upstream is down, got %d", resp.StatusCode)
	}
}

func TestWorker_Start(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	}))
	defer backend.Close()

	proxyCfg := &configparser.Proxy{
		DistAlgo: "RANDOM",
		ServerConfig: []configparser.ServerConfig{
			{
				ServerRouting: []configparser.Routing{
					{
						Prefix:    "/",
						ProxyPass: []string{backend.URL},
					},
				},
			},
		},
	}

	ch := make(chan request.RequestsJob, 5)
	var wg sync.WaitGroup
	w := &Worker{Id: "worker-1"}

	wg.Add(1)
	go w.Start(proxyCfg, ch, &wg)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/test", nil)
	done := make(chan struct{})

	job := request.RequestsJob{
		ID:     "1",
		Req:    req,
		Writer: rec,
		Done:   done,
	}

	ch <- job

	select {
	case <-done:
		// success
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for worker to process job")
	}

	if rec.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", rec.Code)
	}

	close(ch)
	wg.Wait()
}
