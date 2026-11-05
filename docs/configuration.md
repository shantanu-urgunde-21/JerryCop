# JerryCop Configuration Guide

This document details how to write configuration files for JerryCop (`config/config.yaml`) and explains step-by-step how the parser processes the configuration into runtime structures.

---

## 1. Configuration Syntax & Structure

JerryCop reads its configuration from `config/config.yaml`. The configuration is split into two primary sections:

1. **`Proxy`**: Global proxy settings, concurrency limits, and load-balancing algorithms.
2. **`Servers`**: Group definitions for backend upstream servers and their routing rules.

### Complete Example

```yaml
Proxy:
  ProxyPort: ":8080"
  NumWorkers: 3000
  MaxConcReq: 20000
  DistAlgo: ROUND_ROBIN # Options: ROUND_ROBIN, RANDOM, LEAST_CONNECTION

Servers:
  # Server 1: Multiple routing rules under a single server block
  MainApp:
    ServerPorts:
      - "8001"
      - "8002"
      - "8003"
    Names:
      - backend_web
    Routing:
      - Prefix: /api
        ProxyPass:
          - http://127.0.0.1:8003
        ProxyHeaders:
          Host: localhost
          XRealIP: 127.0.0.1
          XForwardedFor: 127.0.0.1
      - Prefix: /
        ProxyPass:
          - http://127.0.0.1:8001
          - http://127.0.0.1:8002
        ProxyHeaders:
          Host: localhost
          XRealIP: 127.0.0.1
          XForwardedFor: 127.0.0.1

  # Server 2: Single routing rule under a standalone server block
  AuthService:
    ServerPorts:
      - "8004"
    Names:
      - auth_backend
    Routing:
      Prefix: /auth
      ProxyPass:
        - http://127.0.0.1:8004
      ProxyHeaders:
        Host: localhost
        XRealIP: 127.0.0.1
        XForwardedFor: 127.0.0.1
```

---

## 2. Field Reference

### `Proxy` Section

| Field | Type | Description |
|---|---|---|
| `ProxyPort` | `string` | The network address and port JerryCop listens on (e.g. `":8080"` or `"0.0.0.0:8080"`). |
| `NumWorkers` | `int` | Total worker goroutines spawned. Partitioned evenly across CPU core shards: `workersPerShard = NumWorkers / runtime.NumCPU()`. |
| `MaxConcReq` | `int` | Global concurrency ceiling. Backed by a buffered channel semaphore; requests exceeding this block until a slot frees up. |
| `DistAlgo` | `string` | Load-balancing strategy: `ROUND_ROBIN`, `RANDOM`, or `LEAST_CONNECTION` (alias: `LEAST_CONN`). |

### `Servers` Section

The `Servers` block is a dictionary of arbitrary server identifiers (e.g. `MainApp`, `Server1`, `AuthService`). Each entry contains:

| Field | Type | Description |
|---|---|---|
| `ServerPorts` | `[]string` | Ports associated with the backend group (for documentation / metadata). |
| `Names` | `[]string` | Human-readable alias names for the server group. |
| `Routing` | Object or List | The route definitions for this server. Can be written as a **single object** or as a **YAML list** (`- Prefix: ...`). |

#### `Routing` Item Fields

| Field | Type | Description |
|---|---|---|
| `Prefix` | `string` | The URL path prefix matched via Longest Prefix Matching (LPM). Examples: `/`, `/api`, `/api/v1`. |
| `ProxyPass` | `[]string` | Upstream backend URLs to relay requests to (e.g. `["http://127.0.0.1:8001", "http://127.0.0.1:8002"]`). |
| `ProxyHeaders` | `object` | Headers injected into upstream requests (`Host`, `XRealIP`, `XForwardedFor`). |

---

## 3. How Configuration is Parsed

The parsing pipeline resides in [`internal/configParser/config.go`](file:///d:/programming/go/JerryCop/internal/configParser/config.go).

### Step 1: Reading the File
When `LoadConfig()` is called:
1. It reads `config/config.yaml` using `os.ReadFile()`.
2. If the file cannot be read, it logs an error and returns a fallback `defaultProxy()` (`:8080`, 10 workers, 1000 max requests, `RANDOM`).

### Step 2: Unmarshaling YAML
The YAML data is decoded using `gopkg.in/yaml.v3` into an internal `configFile` struct:

```go
type configFile struct {
    Proxy struct {
        ProxyPort  string `yaml:"ProxyPort"`
        NumWorkers int    `yaml:"NumWorkers"`
        MaxConcReq int    `yaml:"MaxConcReq"`
        DistAlgo   string `yaml:"DistAlgo"`
    } `yaml:"Proxy"`
    Servers map[string]ServerConfig `yaml:"Servers"`
}
```

### Step 3: Polymorphic Route Parsing (`Routings.UnmarshalYAML`)
`ServerConfig.ServerRouting` uses a custom type `Routings` (`[]Routing`) implementing `yaml.Unmarshaler`:

```go
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
```

- If `Routing` in YAML is a single map with a `Prefix`, it decodes into a 1-element slice.
- If `Routing` in YAML is a sequence (`- Prefix: ...`), it decodes into a multi-element slice.
- This allows single-route servers and multi-route servers to coexist in the same configuration file without schema friction.

### Step 4: Normalizing into `Proxy` Struct
1. Top-level settings (`ProxyPort`, `NumWorkers`, `MaxConcReq`, `DistAlgo`) are copied to `configparser.Proxy`.
2. The `Servers` map is preserved in `proxy.Servers`.
3. To enable fast $O(N)$ linear scans during request routing without map iteration overhead, all server configurations are also flattened into the `proxy.ServerConfig` slice:
   ```go
   for _, sc := range rawConfig.Servers {
       proxy.ServerConfig = append(proxy.ServerConfig, sc)
   }
   ```

---

## 4. How Parsed Config is Used at Runtime

```
 config.yaml
      │
      ▼ (LoadConfig)
 configparser.Proxy
      │
      ├──► cmd/main.go
      │       ├── runtime.NumCPU() channels sized (MaxConcReq / NumShards)
      │       └── NumWorkers spawned across shards
      │
      ├──► router.State (stateTracker.go)
      │       ├── RoundRobinIndex[prefix] -> atomic.Uint64
      │       └── NumOfConns[upstreamURL]  -> atomic.Int64
      │
      └──► router.FindMatchingServer (prefix.go)
              └── Longest Prefix Matching (LPM) over all ServerConfig[i].ServerRouting[j]
```

1. **Dispatcher Channels**: `MaxConcReq` determines the buffer size of each CPU shard channel (`MaxConcReq / runtime.NumCPU()`).
2. **Worker Allocation**: `NumWorkers` determines how many worker goroutines are spawned per shard (`NumWorkers / runtime.NumCPU()`).
3. **State Tracker Initialization**: `State{}.NewState(&proxySettings)` scans all `ServerConfig[i].ServerRouting[j]` to initialize:
   - Atomic round-robin index counters for each unique `Prefix`.
   - Atomic active-connection counters for each unique upstream URL in `ProxyPass`.
4. **Request Routing**: Each incoming request calls `FindMatchingServer(path, servers)` which matches the URL path against all routes using Longest Prefix Matching (LPM). The longest matched prefix determines the `ProxyPass` upstream pool.

