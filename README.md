# untaken

A more capable command-line tool for checking whether **TikTok usernames** are taken.

This upgraded version keeps the original simple workflow, while adding better detection, retries, validation, richer exports, and automation-friendly outputs.

## What’s new in this upgrade

- ✅ **Backwards compatible** with the original `-u <username>` and `-u <file.txt>` behavior
- ✅ **Better result classification**: `TAKEN`, `UNTAKEN`, `UNKNOWN`, `INVALID`
- ✅ **Retry + timeout controls** for unstable network responses
- ✅ **Anti-bot / challenge detection** (avoids false “untaken” results in many blocked cases)
- ✅ **Input normalization** (supports `@username` and pasted TikTok profile URLs)
- ✅ **De-duplication** by default (can be disabled)
- ✅ **CSV export** for every run (default)
- ✅ **Optional JSON export**
- ✅ **Run summary file** for logging / CI pipelines
- ✅ **Strict mode** to reduce false positives on uncertain responses
- ✅ **Exit code 2** when there are unknown/invalid results (useful for automation)

---

## Requirements

- Bash
- `curl`
- `grep`
- `sed`
- `awk`

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

By default each run writes into a timestamped folder like:

```text
untaken_results_20260225_184500/
```

Inside you’ll get:

- `taken.txt`
- `untaken.txt`
- `unknown.txt`
- `invalid.txt`
- `results.csv`
- `summary.txt`

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

### Output options

- `-o, --output-dir <dir>` → Custom output directory
- `--csv <file>` → Custom CSV export path
- `--json <file>` → JSON export path
- `--append` → Append to existing output files
- `--summary-only` → Only print final summary to terminal

### Network / detection options

- `--timeout <sec>` → Per-request timeout (default: `15`)
- `--retries <n>` → Retry count on transient errors (default: `2`)
- `--delay <sec>` → Delay between checks (default: `0`)
- `--user-agent <ua>` → Custom User-Agent
- `--strict` → Only mark as `UNTAKEN` when explicit “not found” clues are detected

### UI / general options

- `-q, --quiet` → Quiet mode
- `--no-color` → Disable ANSI colors
- `-V, --version` → Show version
- `-h, --help` → Show help

---

## Examples

### Safer checks with retries and delay

```bash
./untaken.sh -f usernames.txt --delay 0.5 --retries 3 --timeout 20
```

### Strict mode + JSON export

```bash
./untaken.sh -f usernames.txt --strict --json reports/results.json
```

### Append results to an existing run folder

```bash
./untaken.sh -u mybrand --append -o daily_checks
```

### Use in scripts / CI

```bash
./untaken.sh -f usernames.txt --summary-only
echo $?   # 0 = clean, 2 = unknown/invalid present
```

---

## Notes

- TikTok may rate-limit, block, or challenge requests. In those situations, entries can be marked as `UNKNOWN` rather than falsely reporting `UNTAKEN`.
- `STRICT` mode is recommended when you care more about avoiding false positives than maximizing detections.

---

## Credits

Original project by **Haitham Aouati**.
This package contains an enhanced CLI version with additional capabilities and improved reliability.
