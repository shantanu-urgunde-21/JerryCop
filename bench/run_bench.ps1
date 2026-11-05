# bench/run_bench.ps1
# JerryCop comprehensive benchmark suite with proper warm-ups,
# true successful-throughput calculations, and baseline comparisons.
#
# Prerequisites:
#   - Go installed and on PATH
#   - `hey` installed: go install github.com/rakyll/hey@latest
#   - Caddy installed: go install github.com/caddyserver/caddy/v2/cmd/caddy@latest
#
# Usage (from repo root):
#   cd d:\programming\go\JerryCop
#   .\bench\run_bench.ps1
#
# Output: results are printed to console and also written to bench\results.txt

param (
    [string]$Duration = "15s",
    [int]$Test1Runs = 5
)

$ErrorActionPreference = "Stop"
$REPO_ROOT = Split-Path -Parent $PSScriptRoot
$RESULTS_FILE = "$PSScriptRoot\results.txt"
$HEY = "hey"

$script:logLines = New-Object System.Collections.Generic.List[string]

function Log($msg) {
    Write-Host $msg
    $script:logLines.Add([string]$msg)
}

function Flush-Log {
    try {
        [System.IO.File]::WriteAllLines($RESULTS_FILE, $script:logLines)
    } catch {}
}

function Stop-Proc($proc) {
    if ($null -ne $proc) {
        try {
            if (-not $proc.HasExited) {
                $proc.Kill()
                $proc.WaitForExit(2000)
            }
        } catch {}
    }
}

function Kill-Port($port) {
    # Stop processes listening on this port via Get-NetTCPConnection
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }

    # Fallback to netstat
    $pids = netstat -ano | Select-String ":$port\s.*LISTENING" | ForEach-Object {
        ($_ -split '\s+')[-1]
    } | Select-Object -Unique
    foreach ($p in $pids) {
        if ($p -match '^\d+$' -and $p -ne '0') {
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 300
}

function Cleanup-All {
    Get-Process -Name "baseline", "backend", "jerrycop", "caddy" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($p in @(8001, 8002, 8080, 9090, 9091)) {
        Kill-Port $p
    }
}

function Wait-Port($port, $proc = $null) {
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if ($proc -and $proc.HasExited) {
            throw "Process (PID $($proc.Id)) exited prematurely with code $($proc.ExitCode) before port $port became ready"
        }
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            return
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    throw "Port $port did not come up within 10s"
}

function Parse-HeyOutput([string]$output) {
    $res = [ordered]@{
        TotalSec     = 0.0
        ReportedRps  = 0.0
        Success200   = 0
        Errors       = 0
        SuccessRps   = 0.0
        ErrorPct     = 0.0
        P50          = 0.0
        P90          = 0.0
        P99          = 0.0
    }

    if ($output -match "Total:\s+([\d\.]+)\s+secs") {
        $res.TotalSec = [double]$matches[1]
    }
    if ($output -match "Requests/sec:\s+([\d\.]+)") {
        $res.ReportedRps = [double]$matches[1]
    }
    if ($output -match "\[200\]\s+(\d+)\s+responses") {
        $res.Success200 = [int]$matches[1]
    }
    if ($output -match "50%%\s+in\s+([\d\.]+)\s+secs") {
        $res.P50 = [math]::Round([double]$matches[1] * 1000, 2)
    }
    if ($output -match "90%%\s+in\s+([\d\.]+)\s+secs") {
        $res.P90 = [math]::Round([double]$matches[1] * 1000, 2)
    }
    if ($output -match "99%%\s+in\s+([\d\.]+)\s+secs") {
        $res.P99 = [math]::Round([double]$matches[1] * 1000, 2)
    }

    if ($output -match "(?s)Error distribution:\s*(.+?)(?:\r?\n\r?\n|$)") {
        $errBlock = $matches[1]
        $errMatches = [regex]::Matches($errBlock, "\[(\d+)\]")
        foreach ($m in $errMatches) {
            $res.Errors += [int]$m.Groups[1].Value
        }
    }

    if ($res.TotalSec -gt 0) {
        $res.SuccessRps = [math]::Round($res.Success200 / $res.TotalSec, 1)
    }
    $totalReqs = $res.Success200 + $res.Errors
    if ($totalReqs -gt 0) {
        $res.ErrorPct = [math]::Round(($res.Errors / $totalReqs) * 100, 1)
    }

    return $res
}

function Get-Median($items, [string]$property = "SuccessRps") {
    if (-not $items -or $items.Count -eq 0) { return $null }
    $sorted = @($items | Sort-Object { [double]$_[$property] })
    $count = $sorted.Count
    if ($count % 2 -eq 1) {
        $idx = [int][Math]::Floor($count / 2)
        return $sorted[$idx]
    } else {
        $idx = [int]($count / 2) - 1
        return $sorted[$idx]
    }
}

function Run-Benchmark($label, $url, $opts, $warmupOpts = $null, $runs = 3) {
    Log ""
    Log "--------------------------------------------------------"
    Log " $label"
    Log " Target: $url"
    Log "--------------------------------------------------------"

    if ($warmupOpts) {
        Log " [Warmup] Sending warm-up traffic ($($warmupOpts -join ' '))..."
        & $HEY @warmupOpts $url 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }

    $results = @()
    for ($i = 1; $i -le $runs; $i++) {
        Log " [Run $i/$runs] hey $($opts -join ' ') $url"
        $raw = & $HEY @opts $url 2>&1
        $parsed = Parse-HeyOutput ($raw -join "`n")
        $results += $parsed

        Log ("   Run {0}: Reported: {1,8:F1} req/s | Successful: {2,8:F1} req/s | Errors: {3,5} ({4,4:F1}%) | P50: {5,6:F1}ms | P99: {6,6:F1}ms" -f `
            $i, $parsed.ReportedRps, $parsed.SuccessRps, $parsed.Errors, $parsed.ErrorPct, $parsed.P50, $parsed.P99)
        Flush-Log
        Start-Sleep -Milliseconds 300
    }

    $median = Get-Median $results "SuccessRps"

    Log ""
    Log (" >>> MEDIAN for {0}:" -f $label)
    Log ("     Successful: {0,8:F1} req/s | Reported: {1,8:F1} req/s | Errors: {2,5} ({3,4:F1}%) | P50: {4,6:F1}ms | P99: {5,6:F1}ms" -f `
        $median.SuccessRps, $median.ReportedRps, $median.Errors, $median.ErrorPct, $median.P50, $median.P99)
    Flush-Log
    return $median
}

function Start-Backend($port, $latency) {
    $exePath = "$REPO_ROOT\bench\backends\backend.exe"
    $proc = Start-Process -FilePath $exePath -ArgumentList "--port=$port", "--latency=$latency" -PassThru -WindowStyle Hidden
    Wait-Port $port $proc
    return $proc
}

function Start-JerryCop($config) {
    $configDest = "$REPO_ROOT\config\config.yaml"
    Copy-Item -Path $config -Destination $configDest -Force
    $exePath = "$REPO_ROOT\jerrycop.exe"
    $proc = Start-Process -FilePath $exePath -PassThru -WindowStyle Hidden
    Wait-Port 8080 $proc
    return $proc
}

function Start-Baseline($upstream) {
    $exePath = "$REPO_ROOT\bench\baseline\baseline.exe"
    $proc = Start-Process -FilePath $exePath -ArgumentList "--listen=127.0.0.1:9090", "--upstream=$upstream" -PassThru -WindowStyle Hidden
    Wait-Port 9090 $proc
    return $proc
}

function Start-Caddy($upstream) {
    $caddyCmd = Get-Command caddy -ErrorAction SilentlyContinue
    $caddyPath = if ($caddyCmd) { $caddyCmd.Source } else { "$env:USERPROFILE\go\bin\caddy.exe" }
    if (-not (Test-Path $caddyPath)) {
        Log "WARNING: caddy executable not found. Skipping Caddy benchmark."
        return $null
    }
    $proc = Start-Process -FilePath $caddyPath -ArgumentList "reverse-proxy", "--from", "http://127.0.0.1:9091", "--to", $upstream -PassThru -WindowStyle Hidden
    Wait-Port 9091 $proc
    return $proc
}

# --- Build --------------------------------------------------------------------
Log "========================================================"
Log " JerryCop Benchmark Suite (Rigorous Mode)"
Log " $(Get-Date)"
Log " CPU Cores: $([System.Environment]::ProcessorCount)"
Log " Test 1 Duration per Run: $Duration | Runs: $Test1Runs"
Log "========================================================"
Log ""

Cleanup-All

Log "--- Building binaries ---"

Push-Location $REPO_ROOT

try {
    go build -o jerrycop.exe     .\cmd\main.go
    go build -o bench\backends\backend.exe  .\bench\backends\
    go build -o bench\baseline\baseline.exe .\bench\baseline\

    Log "Build complete."
    Log ""
    Flush-Log

    # --- Test 1: Single Fast Backend Throughput Comparison -----------------------
    Log "========================================================"
    Log " TEST 1: Throughput -- stdlib vs Caddy vs JerryCop"
    Log "         Single fast backend (0ms latency), c=200, -z $Duration"
    Log "         Includes warm-up pass; reports median of $Test1Runs runs"
    Log "========================================================"

    $b1 = Start-Backend 8001 "0"

    $t1Opts = @("-z", $Duration, "-c", "200", "-t", "10")
    $warmupOpts = @("-z", "3s", "-c", "100", "-t", "10")

    # 1.1 Stdlib ReverseProxy
    $baseline = Start-Baseline "http://127.0.0.1:8001"
    $medStdlib = Run-Benchmark "Go stdlib ReverseProxy -> 8001" "http://127.0.0.1:9090/" $t1Opts $warmupOpts $Test1Runs
    Stop-Proc $baseline
    Kill-Port 9090

    # 1.2 Caddy v2
    $medCaddy = $null
    $caddyRuns = @()
    Log ""
    Log "--------------------------------------------------------"
    Log " Caddy v2 -> 8001 (restarted per run)"
    Log " Target: http://127.0.0.1:9091/"
    Log "--------------------------------------------------------"
    for ($i = 1; $i -le $Test1Runs; $i++) {
        Kill-Port 9091
        $caddy = Start-Caddy "127.0.0.1:8001"
        if (-not $caddy) { break }

        # Warmup pass
        & $HEY @warmupOpts "http://127.0.0.1:9091/" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 300

        Log " [Run $i/$Test1Runs] hey $($t1Opts -join ' ') http://127.0.0.1:9091/"
        $raw = & $HEY @t1Opts "http://127.0.0.1:9091/" 2>&1
        $parsed = Parse-HeyOutput ($raw -join "`n")
        $caddyRuns += $parsed

        Log ("   Run {0}: Reported: {1,8:F1} req/s | Successful: {2,8:F1} req/s | Errors: {3,5} ({4,4:F1}%) | P50: {5,6:F1}ms | P99: {6,6:F1}ms" -f `
            $i, $parsed.ReportedRps, $parsed.SuccessRps, $parsed.Errors, $parsed.ErrorPct, $parsed.P50, $parsed.P99)
        Flush-Log

        Stop-Proc $caddy
        Kill-Port 9091
        Start-Sleep -Milliseconds 300
    }
    $medCaddy = Get-Median $caddyRuns "SuccessRps"
    if ($medCaddy) {
        Log ""
        Log " >>> MEDIAN for Caddy v2 -> 8001:"
        Log ("     Successful: {0,8:F1} req/s | Reported: {1,8:F1} req/s | Errors: {2,5} ({3,4:F1}%) | P50: {4,6:F1}ms | P99: {5,6:F1}ms" -f `
            $medCaddy.SuccessRps, $medCaddy.ReportedRps, $medCaddy.Errors, $medCaddy.ErrorPct, $medCaddy.P50, $medCaddy.P99)
        Flush-Log
    }

    # 1.3 JerryCop (Single Backend)
    $jerrySingle = Start-JerryCop "$PSScriptRoot\configs\single_fast.yaml"
    $medJerry = Run-Benchmark "JerryCop (Single Backend) -> 8001" "http://127.0.0.1:8080/" $t1Opts $warmupOpts $Test1Runs
    Stop-Proc $jerrySingle
    Kill-Port 8080

    Stop-Proc $b1
    Kill-Port 8001
    Flush-Log

    Log ""
    Log "--- TEST 1 HEAD-TO-HEAD SUMMARY (Median of $Test1Runs Runs) ---"
    Log ("  stdlib ReverseProxy: {0,8:F1} Successful req/s | P50: {1,5:F1}ms | P99: {2,6:F1}ms | Errors: {3:F1}%" -f `
        $medStdlib.SuccessRps, $medStdlib.P50, $medStdlib.P99, $medStdlib.ErrorPct)
    if ($medCaddy) {
        Log ("  Caddy v2:            {0,8:F1} Successful req/s | P50: {1,5:F1}ms | P99: {2,6:F1}ms | Errors: {3:F1}%" -f `
            $medCaddy.SuccessRps, $medCaddy.P50, $medCaddy.P99, $medCaddy.ErrorPct)
    }
    Log ("  JerryCop:            {0,8:F1} Successful req/s | P50: {1,5:F1}ms | P99: {2,6:F1}ms | Errors: {3:F1}%" -f `
        $medJerry.SuccessRps, $medJerry.P50, $medJerry.P99, $medJerry.ErrorPct)
    Flush-Log

    Start-Sleep 1

    # --- Test 2: LEAST_CONNECTION vs ROUND_ROBIN under Skew -----------------------
    Log ""
    Log "========================================================"
    Log " TEST 2: LEAST_CONNECTION vs ROUND_ROBIN under Skew"
    Log "         Backend A: 0ms, Backend B: 200ms latency"
    Log "         Concurrency: c=50, Total Requests: 2,000"
    Log "========================================================"

    $fast = Start-Backend 8001 "0"
    $slow = Start-Backend 8002 "200ms"

    $t2Opts = @("-n", "2000", "-c", "50", "-t", "15")
    $t2Warmup = @("-n", "200", "-c", "20", "-t", "10")

    # 2.1 ROUND_ROBIN
    $jerryRR = Start-JerryCop "$PSScriptRoot\configs\rr_jitter.yaml"
    $resRR = Run-Benchmark "JerryCop ROUND_ROBIN (0ms vs 200ms)" "http://127.0.0.1:8080/" $t2Opts $t2Warmup 2
    $s1_rr = Invoke-RestMethod http://127.0.0.1:8001/stats
    $s2_rr = Invoke-RestMethod http://127.0.0.1:8002/stats
    Log ("   Traffic Split: Backend A (0ms): {0} reqs | Backend B (200ms): {1} reqs" -f $s1_rr.total_requests, $s2_rr.total_requests)
    Stop-Proc $jerryRR
    Kill-Port 8080
    Start-Sleep 1

    # Reset backends for fair count
    Stop-Proc $fast
    Stop-Proc $slow
    Kill-Port 8001
    Kill-Port 8002
    Start-Sleep 1
    $fast = Start-Backend 8001 "0"
    $slow = Start-Backend 8002 "200ms"

    # 2.2 LEAST_CONNECTION
    $jerryLC = Start-JerryCop "$PSScriptRoot\configs\least_conn_jitter.yaml"
    $resLC = Run-Benchmark "JerryCop LEAST_CONNECTION (0ms vs 200ms)" "http://127.0.0.1:8080/" $t2Opts $t2Warmup 2
    $s1_lc = Invoke-RestMethod http://127.0.0.1:8001/stats
    $s2_lc = Invoke-RestMethod http://127.0.0.1:8002/stats
    Log ("   Traffic Split: Backend A (0ms): {0} reqs | Backend B (200ms): {1} reqs" -f $s1_lc.total_requests, $s2_lc.total_requests)
    Stop-Proc $jerryLC
    Kill-Port 8080

    Stop-Proc $fast
    Stop-Proc $slow
    Kill-Port 8001
    Kill-Port 8002
    Flush-Log

    Log ""
    Log "--- TEST 2 SUMMARY (ROUND_ROBIN vs LEAST_CONNECTION under 200ms Skew) ---"
    Log ("  ROUND_ROBIN:      {0,8:F1} req/s | P50: {1,6:F1}ms | P90: {2,6:F1}ms | P99: {3,6:F1}ms | Split: {4}% fast / {5}% slow" -f `
        $resRR.SuccessRps, $resRR.P50, $resRR.P90, $resRR.P99, `
        [math]::Round(($s1_rr.total_requests / ($s1_rr.total_requests + $s2_rr.total_requests)) * 100, 1), `
        [math]::Round(($s2_rr.total_requests / ($s1_rr.total_requests + $s2_rr.total_requests)) * 100, 1))
    Log ("  LEAST_CONNECTION: {0,8:F1} req/s | P50: {1,6:F1}ms | P90: {2,6:F1}ms | P99: {3,6:F1}ms | Split: {4}% fast / {5}% slow" -f `
        $resLC.SuccessRps, $resLC.P50, $resLC.P90, $resLC.P99, `
        [math]::Round(($s1_lc.total_requests / ($s1_lc.total_requests + $s2_lc.total_requests)) * 100, 1), `
        [math]::Round(($s2_lc.total_requests / ($s1_lc.total_requests + $s2_lc.total_requests)) * 100, 1))
    Flush-Log

    Start-Sleep 1

    # --- Test 3: Overload / Concurrency Limiter Verification ----------------------
    Log ""
    Log "========================================================"
    Log " TEST 3: Overload / Concurrency Limiter Verification"
    Log "         Backend: 100ms latency, Clients: c=300 concurrent"
    Log "         Expectation: MaxConcReq=100 limits backend in-flight"
    Log "         concurrency to <= 100 and caps throughput near 1,000 req/s"
    Log "========================================================"

    $b3 = Start-Backend 8001 "100ms"

    # 3.1 Limited Run: MaxConcReq = 100
    $jerryOver = Start-JerryCop "$PSScriptRoot\configs\overload.yaml"
    Log " [Limited] Running with MaxConcReq=100 at c=300 (2,000 reqs)..."
    $rawOver = & $HEY -n 2000 -c 300 -t 15 "http://127.0.0.1:8080/" 2>&1
    $resOver = Parse-HeyOutput ($rawOver -join "`n")
    $statsOver = Invoke-RestMethod http://127.0.0.1:8001/stats
    Stop-Proc $jerryOver
    Kill-Port 8080
    Start-Sleep 1

    # Reset backend for clean peak in-flight count
    Stop-Proc $b3
    Kill-Port 8001
    Start-Sleep 1
    $b3 = Start-Backend 8001 "100ms"

    # 3.2 Unconstrained Run: MaxConcReq = 20000
    $jerryUnlim = Start-JerryCop "$PSScriptRoot\configs\single_fast.yaml"
    Log " [Unconstrained] Running with MaxConcReq=20000 at c=300 (2,000 reqs)..."
    $rawUnlim = & $HEY -n 2000 -c 300 -t 15 "http://127.0.0.1:8080/" 2>&1
    $resUnlim = Parse-HeyOutput ($rawUnlim -join "`n")
    $statsUnlim = Invoke-RestMethod http://127.0.0.1:8001/stats
    Stop-Proc $jerryUnlim
    Kill-Port 8080

    Stop-Proc $b3
    Kill-Port 8001
    Flush-Log

    Log ""
    Log "--- TEST 3 SUMMARY (Limiter Verification on 100ms Backend) ---"
    Log ("  MaxConcReq=100:   Throughput: {0,6:F1} req/s | Backend Peak In-Flight: {1,4} | Errors: {2}" -f `
        $resOver.SuccessRps, $statsOver.peak_inflight, $resOver.Errors)
    Log ("  Unconstrained:    Throughput: {0,6:F1} req/s | Backend Peak In-Flight: {1,4} | Errors: {2}" -f `
        $resUnlim.SuccessRps, $statsUnlim.peak_inflight, $resUnlim.Errors)
    Flush-Log

    Start-Sleep 1

    # --- Test 4: Concurrency Scaling Sweep (True Successful Throughput) -----------
    Log ""
    Log "========================================================"
    Log " TEST 4: Concurrency Scaling Sweep (Successful req/s)"
    Log "         Single fast backend (0ms), JerryCop Single Backend"
    Log "         50,000 requests per tier"
    Log "========================================================"

    $b4 = Start-Backend 8001 "0"
    $jerry4 = Start-JerryCop "$PSScriptRoot\configs\single_fast.yaml"

    Log ""
    Log "  | Concurrency | Reported/s | Successful/s | Errors | Error % |   P50   |   P99   |"
    Log "  |-------------|------------|--------------|--------|---------|---------|---------|"

    foreach ($conc in @(50, 100, 200, 500, 1000, 2000)) {
        $rawSweep = & $HEY -n 50000 -c $conc -t 15 "http://127.0.0.1:8080/" 2>&1
        $ps = Parse-HeyOutput ($rawSweep -join "`n")
        Log ("  | {0,11} | {1,8:F1}/s | {2,10:F1}/s | {3,6} | {4,6:F1}% | {5,5:F1}ms | {6,5:F1}ms |" -f `
            $conc, $ps.ReportedRps, $ps.SuccessRps, $ps.Errors, $ps.ErrorPct, $ps.P50, $ps.P99)
        Flush-Log
        Start-Sleep -Milliseconds 500
    }

    Stop-Proc $jerry4
    Stop-Proc $b4
    Kill-Port 8080
    Kill-Port 8001

    Log ""
    Log "========================================================"
    Log " All tests complete. Results saved to bench\results.txt"
    Log "========================================================"
    Flush-Log
} finally {
    Cleanup-All
    Pop-Location
}
