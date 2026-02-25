# untaken (Pro CLI Upgrade)

A significantly upgraded Bash CLI for checking whether **TikTok usernames** appear to be taken.

This version keeps the original simple usage (`-u <username>`) and adds **parallel checking**, **resume**, **cache**, **machine-readable outputs**, and more robust request handling.

> ⚠️ TikTok can rate-limit/challenge requests. This tool now errs on the side of `UNKNOWN` when responses look blocked or ambiguous.

---

## Major upgrades in this version

### Speed & scale
- ✅ **Parallel workers** (`--workers N`)
- ✅ **Profiles** (`--profile fast|balanced|conservative`)
- ✅ **Input shuffle** (`--shuffle`) to avoid fixed-order request patterns

### Reliability
- ✅ **Resume mode** (`--resume`) skips usernames already present in prior outputs
- ✅ **Per-username cache** (`--cache-dir`, `--cache-ttl`)
- ✅ **Connect timeout + total timeout** controls
- ✅ **Retries** for transient errors
- ✅ **Challenge / anti-bot detection** to reduce false “untaken” reports
- ✅ **Strict mode** to require explicit “not found” clues before marking `UNTAKEN`

### Automation / CI / scripting
- ✅ **CSV + NDJSON exports** by default (`results.csv`, `results.ndjson`)
- ✅ Optional **JSON array export** (`--json`)
- ✅ **Summary TXT + Summary JSON** for pipelines
- ✅ **Terminal output formats**: pretty / TSV / JSONL (`--print-format`)
- ✅ **Exit code 2** when `UNKNOWN` or `INVALID` records exist
- ✅ **Graceful interrupt handling** (writes summary before exit)

### Input & UX
- ✅ Backward-compatible `-u <username>` and `-u <file.txt>`
- ✅ `@username` and pasted TikTok profile URL normalization
- ✅ Dedup by default (opt out with `--keep-duplicates`)
- ✅ Optional `--config` file for defaults
- ✅ Optional response body capture (`--save-bodies-dir`) for debugging

---

## Requirements

- Bash (modern Bash with `wait -n` recommended for parallel mode)
- `curl`
- `grep`
- `sed`
- `awk`
- `mktemp`

---

## Quick start

### Single username

```bash
./untaken.sh -u mybrandname
```

### File of usernames

```bash
./untaken.sh -f usernames.txt
```

### Legacy file mode (still supported)

```bash
./untaken.sh -u usernames.txt
```

### Read from STDIN

```bash
cat usernames.txt | ./untaken.sh --stdin
```

---

## Output files

By default each run writes to a timestamped folder:

```text
untaken_results_YYYYMMDD_HHMMSS/
```

Inside you’ll get:

- `taken.txt`
- `untaken.txt`
- `unknown.txt`
- `invalid.txt`
- `results.csv`
- `results.ndjson`
- `summary.txt`
- `summary.json`

Optional:

- `results.json` (when using `--json`)

---

## Usage

```bash
./untaken.sh [options]
```

### Input options

- `-u, --username <value>` → Username **or** file path (backward compatible)
- `-f, --file <file>` → File with one username per line
- `--stdin` → Read usernames from STDIN
- `--keep-duplicates` → Don’t de-duplicate usernames
- `--no-validate` → Skip username validation
- `--shuffle` → Shuffle inputs before checking
- `--resume` → Skip usernames already found in the output files/exports

### Performance / behavior

- `--workers <n>` → Parallel worker count (default: `1`)
- `--profile <fast|balanced|conservative>` → Preset tuning
- `--dry-run` → Normalize/validate inputs and generate outputs **without network calls**

### Output options

- `-o, --output-dir <dir>` → Custom output directory
- `--csv <file>` → Custom CSV path
- `--ndjson <file>` → Custom NDJSON path
- `--json <file>` → JSON array export path
- `--summary-json <file>` → Summary JSON path
- `--save-bodies-dir <dir>` → Save raw response bodies per username (debugging)
- `--append` → Append to existing outputs
- `--summary-only` → Suppress per-item terminal lines
- `--print-format <pretty|tsv|jsonl>` → Machine-friendly terminal output

### Network / detection options

- `--timeout <sec>` → Per-request total timeout (default: `15`)
- `--connect-timeout <sec>` → Connection timeout (default: `8`)
- `--retries <n>` → Retry count on transient failures (default: `2`)
- `--delay <sec>` → Delay (primarily between retries and in sequential mode)
- `--user-agent <ua>` → Custom User-Agent
- `--rotate-user-agent` → Pick from built-in UA pool for each request
- `--proxy <url>` → Use a proxy for `curl`
- `--insecure` → Skip TLS verification (debugging only)
- `--strict` → Require explicit “not found” marker for `UNTAKEN`
- `--max-body-kb <n>` → Limit response body parsing size (default: `512`)

### Cache

- `--cache-dir <dir>` → Enable per-username cache
- `--cache-ttl <sec>` → Cache freshness window (`0` = always use cache if present)

### UI / general

- `-q, --quiet`
- `--no-banner`
- `--no-color`
- `--config <file>` → Load defaults from a simple `KEY=VALUE` file
- `-V, --version`
- `-h, --help`

---

## Examples

### Fast parallel run (throughput-focused)

```bash
./untaken.sh -f usernames.txt --profile fast --workers 16 --rotate-user-agent
```

### Safer run (lower false positives)

```bash
./untaken.sh -f usernames.txt --profile conservative --strict --delay 0.7
```

### Resume a previous run folder

```bash
./untaken.sh -f usernames.txt --resume --append -o runs/daily
```

### Cache results for 24 hours

```bash
./untaken.sh -f usernames.txt --cache-dir .cache/untaken --cache-ttl 86400
```

### CI-friendly outputs

```bash
./untaken.sh -f usernames.txt \
  --summary-only \
  --print-format jsonl \
  --ndjson artifacts/results.ndjson \
  --summary-json artifacts/summary.json
```

### Dry-run input validation / normalization only

```bash
./untaken.sh -f usernames.txt --dry-run --summary-only
```

---

## Config file (`--config`) example

See `.untakenrc.example`.

Supported keys include:

- `timeout`
- `connect_timeout`
- `retries`
- `delay`
- `workers`
- `strict_mode`
- `validate`
- `rotate_user_agent`
- `proxy`
- `cache_dir`
- `cache_ttl`
- `profile`
- `print_format`
- `user_agent`

---

## Exit codes

- `0` → Completed and no `UNKNOWN`/`INVALID` results
- `2` → Completed but there were `UNKNOWN` or `INVALID` entries
- `130` → Interrupted

---

## Notes / caveats

- TikTok may block, challenge, or return region-dependent content; those cases are often classified as `UNKNOWN`.
- Parallel mode improves speed but may increase the chance of rate-limiting or challenges.
- `STRICT` mode is recommended when avoiding false positives matters more than maximizing detections.

---

## Credits

Original project by **Haitham Aouati**.
This package includes a major CLI enhancement pass with additional capabilities and automation-focused outputs.
