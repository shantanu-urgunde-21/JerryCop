package workers

import (
	configParser "JerryCop/internal/configParser"
	request "JerryCop/internal/request"
	router "JerryCop/internal/router"
	"io"
	"net/http"
	"sync"
	"time"
)

// Shared connection interface
// Idle connections are kept alive so they can be reused
// instead of creating new connection.
var defaultTransport = &http.Transport{
	MaxIdleConns:        20000,
	MaxIdleConnsPerHost: 5000,
	IdleConnTimeout:     90 * time.Second,
}

// Shared HTTP Client
var defaultClient = &http.Client{
	Transport: defaultTransport,
	Timeout:   30 * time.Second,
}

// 32KB buffer that can be shared
var bufferPool = sync.Pool{
	New: func() any {
		b := make([]byte, 32*1024)
		return &b
	},
}

// Workers are taking Requests till the Channel is open.
type Worker struct {
	Id string
}

// Start consumes jobs from RequestsChan and processes them concurrently.
//
// For each received job, Start launches a goroutine to handle it. When the
// channel is closed and all queued jobs have been received, Start waits for
// all jobs launched by this worker to finish before returning.
//
// Note: There is no limit to the number of concurrent
// jobs handled by a worker concurrently, that is but still it is capped by
// the number of jobs in the channel which has an limit on it
func (w *Worker) Start(ProxySettings *configParser.Proxy, RequestsChan <-chan request.RequestsJob, wg *sync.WaitGroup) {
	defer wg.Done()

	var jobWg sync.WaitGroup

	for job := range RequestsChan {
		jobCopy := job
		jobWg.Add(1)
		go func() {
			defer jobWg.Done()
			w.handleJob(&jobCopy, defaultClient, ProxySettings)
		}()
	}

	jobWg.Wait()
}

// HandleJob determines the internal servers' destination for a request and forwards it.
//
// The router uses the job and proxy configuration to determine the target URL.
// forwardRequest then sends the request to that destination and writes the
// internal server's response to the client's ResponseWriter.
//
// Closing job.Done tells that this job is finished.
func (w *Worker) handleJob(job *request.RequestsJob, client *http.Client, ProxySettings *configParser.Proxy) {
	defer close(job.Done)

	// Get the path to the response is being sent to, .
	// The algorithm is based on the configuration in the config.
	// The work of load balancing management is also managed by the router.
	forwardPath, err := router.GetPath(job, ProxySettings)
	if err != nil {
		http.Error(job.Writer, "Bad Gateway", http.StatusBadGateway)
		return
	}
	forwardRequest(job, client, forwardPath)
}

// Hop-by-hop headers that must not be forwarded by a proxy (RFC 7230 Section 6.1).
var hopHeaders = map[string]bool{
	"Connection":          true,
	"Proxy-Connection":    true,
	"Keep-Alive":          true,
	"Proxy-Authenticate":  true,
	"Proxy-Authorization": true,
	"Te":                  true,
	"Trailer":             true,
	"Transfer-Encoding":   true,
	"Upgrade":             true,
}

// ForwardRequest sends an incoming request to a internal server and relays
// the internal server's response to the original client.
//
// It copies the incoming headers, executes the request using client,
// and then copies the response headers and status code to job.Writer and sends to client
func forwardRequest(job *request.RequestsJob, client *http.Client, targetURL string) {
	upstreamReq, err := http.NewRequest(job.Req.Method, targetURL, job.Req.Body)
	if err != nil {
		http.Error(job.Writer, "Bad Gateway", http.StatusBadGateway)
		return
	}

	// Preserve content length for POST/PUT payloads
	upstreamReq.ContentLength = job.Req.ContentLength
	copyHeaders(job.Req.Header, upstreamReq.Header)

	resp, err := client.Do(upstreamReq)
	if err != nil {
		http.Error(job.Writer, "Bad Gateway", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	copyHeaders(resp.Header, job.Writer.Header())
	job.Writer.WriteHeader(resp.StatusCode)

	buf := bufferPool.Get().(*[]byte)
	defer bufferPool.Put(buf)
	io.CopyBuffer(job.Writer, resp.Body, *buf)
}

// CopyHeaders copies headers while filtering out hop-by-hop transport headers.
func copyHeaders(src, dest http.Header) {
	for k, vv := range src {
		if hopHeaders[k] {
			continue
		}
		for _, v := range vv {
			dest.Add(k, v)
		}
	}
}
