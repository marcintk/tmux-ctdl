#!/usr/bin/env bash
# Gate: fail if any non-test source file's line coverage (as kcov reported it
# in the most recent tests/run-coverage.sh run) drops below <threshold>%.
# Test files themselves are excluded — this gates the code under test, not
# the tests exercising it.
cd "$(dirname "$0")/.." || exit 1

THRESHOLD=${1:-90}
RUN_DIR=$(find .coverage -maxdepth 1 -type d -name 'run-tests.sh.*' | head -1)
[ -n "$RUN_DIR" ] || { echo "check-coverage: no coverage run found — run tests/run-coverage.sh first" >&2; exit 1; }

python3 - "$RUN_DIR/coverage.json" "$THRESHOLD" <<'EOF'
import json, sys

path, threshold = sys.argv[1], float(sys.argv[2])
data = json.load(open(path))
files = [f for f in data["files"] if "/tests/" not in f["file"]]

failed = False
for f in sorted(files, key=lambda x: x["file"]):
    pct = float(f["percent_covered"])
    status = "FAIL" if pct < threshold else "ok"
    if pct < threshold:
        failed = True
    print(f"  {status:4} {pct:6.2f}%  ({f['covered_lines']}/{f['total_lines']})  {f['file']}")

if failed:
    print(f"\ncoverage gate FAILED: one or more files below {threshold}%")
    sys.exit(1)
print(f"\ncoverage gate passed: every file >= {threshold}%")
EOF
