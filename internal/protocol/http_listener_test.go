package protocol

import (
	"JerryCop/internal/request"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNewHTTPListener(t *testing.T) {
	// Nil channel should return nil
	if listener := NewHTTPListener(":8080", 100, nil); listener != nil {
		t.Fatal("expected nil listener for nil RequestsChan")
	}

	ch := make(chan request.RequestsJob, 10)
	listener := NewHTTPListener(":8080", 100, []chan request.RequestsJob{ch})
	if listener == nil {
		t.Fatal("expected non-nil listener")
	}
	if listener.Server == nil {
		t.Fatal("expected non-nil http.Server")
	}
}

func TestLimitMiddleware(t *testing.T) {
	const maxConcurrent = 3
	var activeCount atomic.Int32
	var maxObserved atomic.Int32

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		current := activeCount.Add(1)
		for {
			old := maxObserved.Load()
			if current <= old || maxObserved.CompareAndSwap(old, current) {
				break
			}
		}

		time.Sleep(20 * time.Millisecond)
		activeCount.Add(-1)
		w.WriteHeader(http.StatusOK)
	})

	limited := limitMiddleware(maxConcurrent, handler)

	var wg sync.WaitGroup
	const totalRequests = 15

	for i := 0; i < totalRequests; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			req := httptest.NewRequest("GET", "/test", nil)
			rec := httptest.NewRecorder()
			limited.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				t.Errorf("unexpected status %d", rec.Code)
			}
		}()
	}

	wg.Wait()

	if maxObserved.Load() > maxConcurrent {
		t.Errorf("max concurrent observed was %d, expected <= %d", maxObserved.Load(), maxConcurrent)
	}
}

func TestHTTPListener_HandleRequest(t *testing.T) {
	ch := make(chan request.RequestsJob, 1)
	listener := &HTTPListener{ShardedChans: []chan request.RequestsJob{ch}}

	req := httptest.NewRequest("GET", "/api/items?cat=books", nil)
	rec := httptest.NewRecorder()

	go func() {
		job := <-ch
		if job.Req.URL.Path != "/api/items" {
			t.Errorf("expected path /api/items, got %s", job.Req.URL.Path)
		}
		if job.ID == "" {
			t.Error("expected non-empty job ID")
		}
		job.Writer.WriteHeader(http.StatusOK)
		close(job.Done)
	}()

	listener.handleRequest(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", rec.Code)
	}
}
