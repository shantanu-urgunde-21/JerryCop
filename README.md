# JerryCop

A high-performance, concurrent reverse proxy and layer-7 load balancer built in Go.

Designed for low-latency request routing and traffic management, JerryCop combines a CPU-sharded worker architecture with prefix-based path routing, active load balancing, and concurrency limiting to protect upstream backend services from overload.

---

## Benchmarks

### Environment & Specifications

- **Operating System**: Linux (WSL2 / Ubuntu)
- **CPU**: 8 Cores (`runtime.NumCPU() = 8`)
- **Benchmarking Tool**: `hey` (HTTP/1.1, keep-alive enabled)
- **Target Network**: Local loopback (`127.0.0.1`)
- **Methodology**:
  - Warm-up traffic pass executed before recorded measurements to warm connection pools and runtime caches.
  - Throughput reported as **Successful req/s** (HTTP 200 responses / duration), strictly excluding failed requests.
  - Multi-run tests report the true median run.

---

### 1. Head-to-Head Throughput (Single 0ms Backend)

Single fast upstream backend at concurrency $c=200$ across 10-second duration runs (`-z 10s`). Results report the median of 3 measured runs following a warm-up pass:

| Reverse Proxy | Successful req/s | P50 Latency | P99 Latency | Error Rate |
| :--- | :---: | :---: | :---: | :---: |
| **NGINX (`epoll`)** | **32,700.0** | 5.9 ms | 12.2 ms | **0.0%** |
| **JerryCop** | **29,979.9** | **5.7 ms** | **21.6 ms** | **0.0%** |
| **Go stdlib (`httputil.ReverseProxy`)** | 22,943.9 | 7.5 ms | 27.5 ms | 0.0% |

> JerryCop delivers **~30,000 req/s**, outperforming Go's standard library reverse proxy by **+30.7%** and operating within **8% of C-based NGINX**, with a slightly lower P50 latency (5.7 ms vs. 5.9 ms).

---

### 2. Multi-Backend Latency Skew (4 Upstream Servers)

Evaluates dynamic traffic diversion when an outlier server suffers performance degradation.
The cluster comprises **4 upstream backends**:
- **3 Healthy / Fast Nodes**: Backends 1, 2, 3 (`0ms` response latency)
- **1 Degraded / Outlier Node**: Backend 4 (`200ms` tail latency)
- **Workload**: 100 concurrent clients ($c=100$) for 10 seconds. Traffic distribution tracked via backend `/stats`:

| Reverse Proxy & Algorithm | Successful req/s | P50 Latency | P99 Latency | Traffic Split (Fast vs. Degraded) |
| :--- | :---: | :---: | :---: | :---: |
| **NGINX `ROUND_ROBIN`** | 1,937.2 | 1.0 ms | 206.6 ms | 75.0% (Fast) / 25.0% (Slow) |
| **JerryCop `ROUND_ROBIN`** | 1,884.3 | 1.9 ms | 207.4 ms | 75.0% (Fast) / 25.0% (Slow) |
| **NGINX `LEAST_CONN`** | 25,902.7 | 2.8 ms | 8.2 ms | 99.5% (Fast) / 0.5% (Slow) |
| **JerryCop `LEAST_CONNECTION`** | **27,984.4** | **2.1 ms** | **11.0 ms** | **99.5% (Fast) / 0.5% (Slow)** |

> **Key Observation**:
> - Under **`ROUND_ROBIN`**, requests are dispatched evenly (25% to each node). Because client connections stall on the degraded backend, overall throughput collapses to ~1.9k req/s.
> - Under **`LEAST_CONNECTION`**, JerryCop immediately detects accumulating in-flight connections on the degraded node and diverts **99.5% of incoming traffic** to the 3 healthy nodes, achieving **27,984.4 req/s** (a **$14.8\times$ speedup**) and outperforming NGINX's native `least_conn` directive (25.9k req/s).

---

### 3. Concurrency Limiter Verification (Overload Protection)

Evaluates semaphore throttling against an upstream backend with 100ms response latency under 300 concurrent clients ($c=300$, 2,000 requests). Peak in-flight concurrency was measured directly at the backend via `/stats`:

| Mode | `MaxConcReq` Setting | Backend Peak In-Flight | Successful req/s | Error Rate |
| :--- | :---: | :---: | :---: | :---: |
| **Throttled** | **100** | **100** | **942.4** | **0.0%** |
| **Unconstrained** | 20,000 | 300 | 2,452.0 | 0.0% |

> When `MaxConcReq=100`, JerryCop strictly enforces the 100 in-flight connection threshold at the upstream server with zero leakage, preventing backend thread exhaustion while queuing excess requests safely.

---

### 4. Concurrency Scaling Sweep

Single fast backend (0ms) proxied through JerryCop under sustained high concurrency (50,000 requests per tier):

| Concurrency ($c$) | Successful req/s | Error % | P50 Latency | P99 Latency |
| :---: | :---: | :---: | :---: | :---: |
| **50** | 18,576.3 | **0.0%** | 1.8 ms | 17.2 ms |
| **100** | 27,731.6 | **0.0%** | 2.9 ms | 11.0 ms |
| **200** | 26,407.5 | **0.0%** | 6.1 ms | 25.2 ms |
| **500** | 26,685.2 | **0.0%** | 14.0 ms | 76.2 ms |
| **1000** | 27,261.3 | **0.0%** | 28.9 ms | 120.8 ms |
| **2000** | 23,083.0 | **0.0%** | 65.5 ms | 282.5 ms |

> JerryCop scales smoothly across extreme concurrency levels, maintaining **0.0% errors** and sustaining **>23,000–27,000 req/s** up to 2,000 concurrent client connections without connection dropping or memory leakage.

---

## Key Features

- **High-Throughput Sharded Dispatcher**: Partitions incoming requests across dedicated CPU core shards (`runtime.NumCPU()`) to minimize channel lock contention under heavy concurrency.
- **Concurrent Worker Pools & Graceful Draining**: Workers pull jobs asynchronously from shard channels, executing requests in per-job goroutines tracked by `sync.WaitGroup` to enable clean in-flight request draining on shutdown.
- **Traffic Routing & Longest Prefix Matching (LPM)**: Intelligently routes paths (e.g. `/`, `/api`, `/api/v1`) to designated upstream server groups, supporting multiple prefix routes per server.
- **Pluggable Load Balancing**:
  - `ROUND_ROBIN`: Atomic state-tracked rotation across backend servers.
  - `RANDOM`: Low-overhead uniform pseudo-random distribution.
  - `LEAST_CONNECTION`: Upstream selection based on active connection tracking.
- **Rate Limiting & Lifecycle Synchronization**: Semaphore-guarded connection thresholds (`MaxConcReq`) coordinated with per-request `Done` channel signaling to prevent server saturation and cleanly release slots.
- **Optimized Network I/O**:
  - Upstream HTTP keep-alive connection pooling via reusable transports.
  - Recycled 32 KB copy buffers via `sync.Pool` to minimize GC pressure during large data transfers.
  - Fast single-pass target URL construction with zero intermediate URL re-parsing.
  - RFC 7230-compliant hop-by-hop header sanitization (`Connection`, `Keep-Alive`, `Upgrade`, etc.).

---

## Architecture Overview

```
                      ┌──────────────────────┐
                      │  Incoming HTTP Req   │
                      └──────────┬───────────┘
                                 │
                                 ▼
                     ┌────────────────────────┐
                     │    limitMiddleware     │ (Semaphore / MaxConcReq)
                     └───────────┬────────────┘
                                 │
                                 ▼
                     ┌────────────────────────┐
                     │      HTTPListener      │◄────────────────┐
                     └───────────┬────────────┘                 │
                                 │ (id % numShards)             │
             ┌───────────────────┼───────────────────┐          │
             ▼                   ▼                   ▼          │
     ┌───────────────┐   ┌───────────────┐   ┌───────────────┐  │ (close job.Done /
     │ Shard Chan 0  │   │ Shard Chan 1  │   │ Shard Chan N  │  │  release slot)
     └───────┬───────┘   └───────┬───────┘   └───────┬───────┘  │
             │                   │                   │          │
             ▼                   ▼                   ▼          │
     ┌───────────────┐   ┌───────────────┐   ┌───────────────┐  │
     │ Worker Pool 0 │   │ Worker Pool 1 │   │ Worker Pool N │  │ (Async goroutines
     └───────┬───────┘   └───────┬───────┘   └───────┬───────┘  │  + sync.WaitGroup)
             │                   │                   │          │
             └───────────────────┼───────────────────┘          │
                                 │                              │
                                 ▼                              │
                     ┌────────────────────────┐                 │
                     │   Router & LoadBal     │                 │
                     └───────────┬────────────┘                 │
                                 │ (LPM + RR/Random/LeastConn)  │
                                 ▼                              │
                     ┌────────────────────────┐                 │
                     │   Upstream Backends    │─────────────────┘
                     └────────────────────────┘ (stream response)
```

---

## Configuration

JerryCop is configured via `config/config.yaml`:

```yaml
Proxy:
  ProxyPort: ":8080"
  NumWorkers: 3000
  MaxConcReq: 20000
  DistAlgo: ROUND_ROBIN # Options: ROUND_ROBIN, RANDOM, LEAST_CONNECTION

Servers:
  Server1:
    ServerPorts:
      - "8001"
      - "8002"
      - "8003"
    Names:
      - backend1
      - backend2
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
```

---

## Getting Started

### Prerequisites

- Go 1.22+

### Running the Proxy

```bash
# Run directly
go run ./cmd/main.go

# Or using Makefile
make run
```

### Running Tests

```bash
# Run all tests
go test -v ./...

# Or using Makefile
make test
```

### Building Binary

```bash
# Build standalone binary into bin/
make build
```