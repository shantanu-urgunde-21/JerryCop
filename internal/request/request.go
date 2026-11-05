package request

import "net/http"

type RequestsJob struct {
	ID     string
	Req    *http.Request
	Writer http.ResponseWriter
	Done   chan struct{}
}
