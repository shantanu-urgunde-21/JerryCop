package router

import (
	configparser "JerryCop/internal/configParser"
	"sync/atomic"
)

// Although the config and stateTracker both deal with the servers,
// config only loads the data about the servers in memory
// While the stateTracker deals with the information
// tracking about the Connections and Servers at the runtime.

type State struct {
	LastConnection   InternalServer
	IsInternalServer map[string]struct{}
	NumOfConns       map[string]*atomic.Int64
	TotalServers     int
	RoundRobinIndex  map[string]*atomic.Uint64
}

type InternalServer struct {
	ServerPath string
}

func (State) NewState(configSettings *configparser.Proxy) State {
	totalServers := 0
	if configSettings != nil {
		totalServers = len(configSettings.ServerConfig)
	}

	state := State{
		LastConnection:   InternalServer{},
		IsInternalServer: make(map[string]struct{}),
		NumOfConns:       make(map[string]*atomic.Int64),
		TotalServers:     totalServers,
		RoundRobinIndex:  make(map[string]*atomic.Uint64),
	}

	if configSettings != nil {
		for _, server := range configSettings.ServerConfig {
			for _, routing := range server.ServerRouting {
				state.RoundRobinIndex[routing.Prefix] = new(atomic.Uint64)
				for _, upstream := range routing.ProxyPass {
					state.IsInternalServer[upstream] = struct{}{}
					state.NumOfConns[upstream] = new(atomic.Int64)
				}
			}
		}
	}

	return state
}
