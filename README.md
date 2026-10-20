# webserver-load-test

A small bash wrapper for quick HTTP load tests. Uses **`wrk`** when
available, falls back to **ApacheBench (`ab`)**. It validates the target
with `curl` first (fail fast), runs the test, parses the output, and
prints a clean summary table. With `--compare`, two URLs run back-to-back
and print side-by-side.

```bash
./load-test.sh --url https://example.com/
./load-test.sh --url https://example.com/ --duration 30s --concurrency 100 --threads 4
./load-test.sh --url https://staging.example.com/ --compare https://example.com/ --output report.md
./load-test.sh --url https://example.com/api --header "Authorization: Bearer TOKEN"
```

## Options

| Flag | Default | Meaning |
|------|---------|---------|
| `--url URL` | *(required)* | Target to test |
| `--compare URL2` | — | Second target; both run, results side-by-side |
| `--duration 15s` | `15s` | Time per target (`15s`, `1m`, `90`) |
| `--concurrency 50` | `50` | Concurrent connections |
| `--threads 2` | `2` | Threads (wrk only) |
| `--header "Name: value"` | — | Extra request header; repeat the flag |
| `--output FILE` | — | Save a Markdown report to FILE |

Exit code is non-zero when a target is unreachable or no engine is
installed.

## wrk vs ab

- **wrk** (preferred): multi-threaded, accurate at high concurrency, and
  reports a real latency distribution (avg, stdev, p50, p99 via `--latency`).
- **ab** (fallback): single-threaded and simpler; the script still reports
  requests/sec, mean latency, p50 and p99 (stdev shows `n/a`).

Install hints:

```bash
# Debian/Ubuntu
sudo apt install wrk            # preferred
sudo apt install apache2-utils  # for ab
```

## Example output

```
Testing https://example.com/ (wrk, 15s, c=50)…

Target:      https://example.com/
Tool:        wrk
Duration:    15s   Concurrency: 50

Metric           Value
---------------- --------
Requests/sec     8225.01
Latency avg      6.07ms
Latency stdev    3.45ms
p50              5.12ms
p99              18.90ms
```

## Files

- `load-test.sh` — the whole tool (`chmod +x load-test.sh`)

## Requirements

Bash 4+, `curl`, and `wrk` or `ab`.

## License

MIT — see `LICENSE`.
