// bench/backends/main.go
// Mock backend server for benchmarking.
//
// Usage:
//   go run ./bench/backends --port=8001 --latency=0
//   go run ./bench/backends --port=8002 --latency=50ms
//
// Flags:
//   --port     TCP port to listen on (default: 8001)
//   --latency  Fixed response latency as Go duration (default: 0)
//
// Responds with 200 OK and a small JSON body. Latency simulates
// a backend that is slow (e.g. a DB-bound handler).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"sync/atomic"
	"time"
)

func main() {
	port := flag.String("port", "8001", "port to listen on")
	latency := flag.Duration("latency", 0, "simulated response latency (e.g. 5ms, 50ms)")
	flag.Parse()

	var (
		curInFlight   atomic.Int64
		peakInFlight  atomic.Int64
		totalRequests atomic.Int64
	)

	mux := http.NewServeMux()
	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]int64{
			"peak_inflight":  peakInFlight.Load(),
			"cur_inflight":   curInFlight.Load(),
			"total_requests": totalRequests.Load(),
		})
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		cur := curInFlight.Add(1)
		for {
			peak := peakInFlight.Load()
			if cur <= peak || peakInFlight.CompareAndSwap(peak, cur) {
				break
			}
		}
		defer curInFlight.Add(-1)
		totalRequests.Add(1)

		if *latency > 0 {
			time.Sleep(*latency)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"ok":true}`))
	})

	addr := "127.0.0.1:" + *port
	fmt.Printf("backend listening on %s (latency=%s)\n", addr, *latency)
	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Fprintf(os.Stderr, "backend error: %v\n", err)
		os.Exit(1)
	}
}
