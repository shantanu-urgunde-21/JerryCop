package main

import (
	configparser "JerryCop/internal/configParser"
	"JerryCop/internal/protocol"
	request "JerryCop/internal/request"
	workers "JerryCop/internal/workers"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"syscall"

	"github.com/google/uuid"

	_ "github.com/joho/godotenv"
)

func main() {

	// Step1: Load Config
	ProxySettings, err := configparser.LoadConfig()

	if err != nil {
		fmt.Println("Error loading config:", err)
		os.Exit(1)
	}

	// Step2: Create Dedicated Channels
	numShards := runtime.NumCPU()
	shardedChans := make([]chan request.RequestsJob, numShards)
	for i := 0; i < numShards; i++ {
		shardedChans[i] = make(chan request.RequestsJob, ProxySettings.MaxConcReq/numShards)
	}

	// Step3: Spawn Workers
	var workersWg sync.WaitGroup

	workersPerShard := ProxySettings.NumWorkers / numShards
	for shardIdx := 0; shardIdx < numShards; shardIdx++ {
		for w := 0; w < workersPerShard; w++ {
			worker := &workers.Worker{Id: uuid.NewString()}
			workersWg.Add(1)
			go worker.Start(&ProxySettings, shardedChans[shardIdx], &workersWg)
		}
	}

	// Step4: spawns Listener and listens to the incoming requests.
	Listener := protocol.NewHTTPListener(ProxySettings.ProxyPort, ProxySettings.MaxConcReq, shardedChans)
	if Listener == nil {
		fmt.Printf("Error creating Listener for port %s\n", ProxySettings.ProxyPort)
		os.Exit(1)
	}

	done := make(chan os.Signal, 1)
	signal.Notify(done, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		if err := Listener.Listen(); err != nil && err != http.ErrServerClosed {
			fmt.Println("Listener error:", err)
		}
	}()

	fmt.Println("Blocking, press ctrl+c to continue...")
	<-done
	fmt.Println("Interrupted! Shutting down...")

	// Stop the Listener
	_ = Listener.Server.Close()

	// Tell the workers threads to stop taking the requests.
	for _, ch := range shardedChans {
		close(ch)
	}
	// Wait till the worker threads are done with their workload.
	workersWg.Wait()

	fmt.Println("All workers finished. Exiting.")
}
