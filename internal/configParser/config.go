package configparser

import (
	"os"

	"gopkg.in/yaml.v3"
)

// Although the config and stateTracker both deal with the servers,
// config only loads the data about the servers in memory
// While the stateTracker deals with the information
// tracking about the Connections and Servers at the runtime.

// Note: Based on the layout of config.yaml

// Proxy holds the proxy's runtime configuration and the configuration
// of all registered backend server groups.
type Proxy struct {
	ProxyPort    string                  `yaml:"ProxyPort"`
	NumWorkers   int                     `yaml:"NumWorkers"`
	MaxConcReq   int                     `yaml:"MaxConcReq"`
	DistAlgo     string                  `yaml:"DistAlgo"`
	Servers      map[string]ServerConfig `yaml:"Servers"`
	ServerConfig []ServerConfig          `yaml:"ServerConfig"`
}

// ServerConfig defines a backend server group and its routing configuration.
type ServerConfig struct {
	ServerPorts   []string `yaml:"ServerPorts"`
	Names         []string `yaml:"Names"`
	ServerRouting Routings `yaml:"Routing"`
}

// Routings supports either a single Routing or a slice of Routings in YAML.
type Routings []Routing

func (r *Routings) UnmarshalYAML(value *yaml.Node) error {
	var single Routing
	if err := value.Decode(&single); err == nil && single.Prefix != "" {
		*r = []Routing{single}
		return nil
	}
	var multi []Routing
	if err := value.Decode(&multi); err != nil {
		return err
	}
	*r = multi
	return nil
}

// Routing defines the rules for matching incoming requests and forwarding
// them to backend servers.
type Routing struct {
	Prefix       string      `yaml:"Prefix"`
	ProxyPass    []string    `yaml:"ProxyPass"`
	ProxyHeaders ProxyHeader `yaml:"ProxyHeaders"`
}

type ProxyHeader struct {
	Host          string `yaml:"Host"`
	XRealIP       string `yaml:"XRealIP"`
	XForwardedFor string `yaml:"XForwardedFor"`
}

type configFile struct {
	Proxy struct {
		ProxyPort  string `yaml:"ProxyPort"`
		NumWorkers int    `yaml:"NumWorkers"`
		MaxConcReq int    `yaml:"MaxConcReq"`
		DistAlgo   string `yaml:"DistAlgo"`
	} `yaml:"Proxy"`
	Servers map[string]ServerConfig `yaml:"Servers"`
}

func LoadConfig() (Proxy, error) {
	configPath := "config/config.yaml"
	data, err := os.ReadFile(configPath)

	if err != nil {
		return defaultProxy(), err
	}

	var rawConfig configFile
	if err := yaml.Unmarshal(data, &rawConfig); err != nil {
		return defaultProxy(), err
	}

	proxy := Proxy{
		ProxyPort:  rawConfig.Proxy.ProxyPort,
		NumWorkers: rawConfig.Proxy.NumWorkers,
		MaxConcReq: rawConfig.Proxy.MaxConcReq,
		DistAlgo:   rawConfig.Proxy.DistAlgo,

		Servers: rawConfig.Servers,
	}

	for _, sc := range rawConfig.Servers {
		proxy.ServerConfig = append(proxy.ServerConfig, sc)
	}

	return proxy, nil
}

func defaultProxy() Proxy {
	return Proxy{
		ProxyPort:  ":8080",
		NumWorkers: 10,
		MaxConcReq: 1000,
		DistAlgo:   "RANDOM",

		Servers:      make(map[string]ServerConfig),
		ServerConfig: []ServerConfig{},
	}
}
