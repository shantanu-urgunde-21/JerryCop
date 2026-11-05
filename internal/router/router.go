package router

import (
	configparser "JerryCop/internal/configParser"
	"JerryCop/internal/request"
	"errors"
	"math/rand/v2"
)

// note to self: will add ip-hash based and weighted round robin in future

func getPathRandom(job *request.RequestsJob, proxySettings *configparser.Proxy, state *State) (string, error) {
	routing, found := FindMatchingServer(job.Req.URL.Path, proxySettings.ServerConfig)
	if !found || len(routing.ProxyPass) == 0 {
		return "", errors.New("no matching upstream server found for path")
	}

	randIndex := rand.IntN(len(routing.ProxyPass))
	chosenUpstream := routing.ProxyPass[randIndex]

	return BuildTargetURL(chosenUpstream, job.Req.URL.Path, job.Req.URL.RawQuery)
}

func getPathRoundRobin(job *request.RequestsJob, proxySettings *configparser.Proxy, state *State) (string, error) {
	routing, found := FindMatchingServer(job.Req.URL.Path, proxySettings.ServerConfig)
	if !found || len(routing.ProxyPass) == 0 {
		return "", errors.New("no matching upstream server found for path")
	}

	upstreams := routing.ProxyPass
	prefix := routing.Prefix
	var chosenUpstream string
	if state != nil && state.RoundRobinIndex != nil && state.RoundRobinIndex[prefix] != nil {
		idx := state.RoundRobinIndex[prefix].Add(1) - 1
		chosenUpstream = upstreams[idx%uint64(len(upstreams))]
	} else {
		chosenUpstream = upstreams[0]
	}

	return BuildTargetURL(chosenUpstream, job.Req.URL.Path, job.Req.URL.RawQuery)
}

func getPathLeastConn(job *request.RequestsJob, proxySettings *configparser.Proxy, state *State) (string, error) {
	routing, found := FindMatchingServer(job.Req.URL.Path, proxySettings.ServerConfig)
	if !found || len(routing.ProxyPass) == 0 {
		return "", errors.New("no matching upstream server found for path")
	}

	upstreams := routing.ProxyPass
	chosenUpstream := upstreams[0]

	if state != nil && len(upstreams) > 1 {
		minConns := state.NumOfConns[chosenUpstream].Load()
		for _, u := range upstreams[1:] {
			if counter := state.NumOfConns[u]; counter != nil {
				if c := counter.Load(); c < minConns {
					minConns = c
					chosenUpstream = u
				}
			}
		}
	}

	if state != nil && state.NumOfConns != nil {
		if counter := state.NumOfConns[chosenUpstream]; counter != nil {
			counter.Add(1)
			if job != nil && job.Done != nil {
				go func() {
					<-job.Done
					counter.Add(-1)
				}()
			}
		}
	}

	return BuildTargetURL(chosenUpstream, job.Req.URL.Path, job.Req.URL.RawQuery)
}

func GetPath(job *request.RequestsJob, proxySettings *configparser.Proxy, state ...*State) (string, error) {
	var s *State
	if len(state) > 0 {
		s = state[0]
	}

	switch proxySettings.DistAlgo {
	case "RANDOM":
		return getPathRandom(job, proxySettings, s)
	case "ROUND_ROBIN":
		return getPathRoundRobin(job, proxySettings, s)
	case "LEAST_CONNECTION", "LEAST_CONN":
		return getPathLeastConn(job, proxySettings, s)
	}

	return "", errors.New("could not get path.")
}
