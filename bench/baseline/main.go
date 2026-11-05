// bench/baseline/main.go
// A minimal reverse proxy using Go's standard httputil.ReverseProxy.
// Benchmarks run against this to establish a baseline, so JerryCop
// numbers can be expressed as "X% faster than stdlib ReverseProxy".
//
// Usage:
//   go run ./bench/baseline --listen=:9090 --upstream=http://127.0.0.1:8001
package main

import (
	"flag"
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
)

func main() {
	listen   := flag.String("listen", ":9090", "address to listen on")
	upstream := flag.String("upstream", "http://127.0.0.1:8001", "upstream backend URL")
	flag.Parse()

	target, err := url.Parse(*upstream)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid upstream URL: %v\n", err)
		os.Exit(1)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)

	// Use a generous transport so the baseline isn't throttled by default
	// idle connection limits (default MaxIdleConnsPerHost=2 is a known trap).
	proxy.Transport = &http.Transport{
		MaxIdleConns:        10000,
		MaxIdleConnsPerHost: 10000,
		IdleConnTimeout:     90e9, // 90s in nanoseconds
	}

	fmt.Printf("stdlib ReverseProxy listening on %s -> %s\n", *listen, *upstream)
	if err := http.ListenAndServe(*listen, proxy); err != nil {
		fmt.Fprintf(os.Stderr, "baseline error: %v\n", err)
		os.Exit(1)
	}
}

