package protocol

import (
	"JerryCop/internal/request"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/gorilla/mux"
)

var reqCounter atomic.Uint64

type HTTPListener struct {
	Server       *http.Server
	ShardedChans []chan request.RequestsJob
}

func NewHTTPListener(listenAddr string, MaxConcReq int, ShardedChans []chan request.RequestsJob) *HTTPListener {
	if ShardedChans == nil {
		return nil
	}

	mux := mux.NewRouter()

	listener := &HTTPListener{
		ShardedChans: ShardedChans,
	}

	mux.PathPrefix("/").HandlerFunc(listener.handleRequest)

	Limit := limitMiddleware(MaxConcReq, mux)
	listener.Server = &http.Server{
		Addr:         listenAddr,
		Handler:      Limit,
		WriteTimeout: time.Second * 30,
		ReadTimeout:  time.Second * 10,
		IdleTimeout:  time.Minute,
	}

	return listener
}

func (s *HTTPListener) handleRequest(w http.ResponseWriter, r *http.Request) {
	done := make(chan struct{})

	id := reqCounter.Add(1)
	job := request.RequestsJob{
		ID:     strconv.FormatUint(id, 10),
		Req:    r,
		Writer: w,
		Done:   done,
	}

	shard := id % uint64(len(s.ShardedChans))
	s.ShardedChans[shard] <- job
	<-done
}


func limitMiddleware(maxConcurrent int, next http.Handler) http.Handler {
	// A buffered channel acts as an semaphore
	semaphore := make(chan struct{}, maxConcurrent)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Acquire a slot. If full, this blocks until a slot opens up.
		semaphore <- struct{}{}
		
		// Ensure the slot is released when the request finishes
		defer func() { <-semaphore }()

		next.ServeHTTP(w, r)
	})
}

func (s *HTTPListener) Listen() error {

	if err := s.Server.ListenAndServe(); err != nil {
		return err
	}
	return nil
}
