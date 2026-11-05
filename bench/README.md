# Benchmark Suite

This directory contains everything needed to benchmark JerryCop on your local machine.

## Prerequisites

Install `hey` (the load generator):
```bash
go install github.com/rakyll/hey@latest
```

## Running

From the **repo root**:
```powershell
.\bench\run_bench.ps1
```

Results are printed to the terminal and saved to `bench\results.txt`.

---

## What is Tested

| Test | Config | Description |
|---|---|---|
| **1 — Throughput** | `round_robin.yaml` | JerryCop vs stdlib `httputil.ReverseProxy`, single fast backend, 500 concurrent, 50k requests. 2 runs each to establish median. |
| **2 — Jitter** | `rr_jitter.yaml` vs `least_conn_jitter.yaml` | Backend A: 0ms, Backend B: 50ms. ROUND_ROBIN blindly routes half to the slow one; LEAST_CONNECTION drains the fast one. Compares P99. |
| **3 — Overload** | `overload.yaml` | MaxConcReq=100 with 1000 concurrent clients pushing 50k requests. Shows the semaphore queues gracefully rather than crashing. |
| **4 — Scaling** | `round_robin.yaml` | Sweeps concurrency at c=50, 200, 500, 1000, 2000 to show how throughput and latency scale with load. |

---

## Directory Layout

```
bench/
  backends/     mock backend server (--port, --latency flags)
  baseline/     stdlib httputil.ReverseProxy (control benchmark)
  configs/      config.yaml files for each test scenario
  run_bench.ps1 benchmark runner script (builds, starts, measures, kills)
  results.txt   written after a run
```

---

## Target Resume Bullet

Once you have clean numbers, the target statement is:

> Sustained **X req/s** at **1,000 concurrent connections** with **zero errors** and **P99 < Y ms** — **Z% faster** than Go's stdlib `httputil.ReverseProxy` on the same hardware. `LEAST_CONNECTION` routing reduced P99 by **N%** vs `ROUND_ROBIN` under a mixed-latency backend pool.

Fill in X, Y, Z, N from the actual `results.txt`.

