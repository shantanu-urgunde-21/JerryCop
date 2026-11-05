package protocol

import (
	"net/http"
	"time"

	"github.com/gorilla/mux"
)

type HTTPWorkerServer struct {
	Server *http.Server
}

func NewHTTPWorkerServer(listenAddr string) *HTTPListener {
	mux := mux.NewRouter()

	NewHTTPWorkerServer := HTTPListener{
		Server: &http.Server{
			Addr:         listenAddr,
			Handler:      mux,
			WriteTimeout: time.Second * 30,
			ReadTimeout:  time.Second * 10,
			IdleTimeout:  time.Minute,
		},
	}

	return &NewHTTPWorkerServer
}

// func limitMiddleware(maxConcurrent int, next http.Handler) http.Handler {
// 	// A buffered channel acts as an semaphore
// 	semaphore := make(chan struct{}, maxConcurrent)

// 	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
// 		// Acquire a slot. If full, this blocks until a slot opens up.
// 		semaphore <- struct{}{}

// 		// Ensure the slot is released when the request finishes
// 		defer func() { <-semaphore }()

// 		next.ServeHTTP(w, r)
// 	})
// }

func (s *HTTPWorkerServer) Serve(ForwardPath string, resWriter *http.ResponseWriter) {

}

func (s *HTTPWorkerServer) Listen() error {

	if err := s.Server.ListenAndServe(); err != nil {
		return err
	}

	return nil
}
