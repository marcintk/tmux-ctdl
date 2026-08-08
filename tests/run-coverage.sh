#!/usr/bin/env bash
# Run the test suite under kcov and print per-file line coverage.
# --html: also open the full HTML report.
cd "$(dirname "$0")/.." || exit 1 # workspace

HTML=0
[ "$1" = "--html" ] && HTML=1

OUT=.coverage
rm -rf "$OUT"
# KCOV_TRACER_LOST: a small number of lines that shell out to a foreign
# (non-bash) binary — sqlite3, in adapter-copilot.sh's copilot_collect —
# reproducibly lose kcov's line-hit tracking even though they demonstrably
# run (see tests/adapter/test-pull-usage-copilot.sh's
# test_collect_and_parse_shared_direct, which asserts on their output).
# Confirmed via isolated single-file kcov runs across many invocation
# shapes; not a real test gap. Marked and excluded rather than reported as
# a false 0%.
kcov --include-path=. --exclude-line=KCOV_TRACER_LOST "$OUT" tests/run-tests.sh
RUN_DIR=$(find "$OUT" -maxdepth 1 -type d -name 'run-tests.sh.*')

python3 - "$RUN_DIR/index.js" <<'EOF'
import re, sys, json
js = open(sys.argv[1]).read()
raw = re.search(r'var data = (\{.*?\]\});', js, re.S).group(1)
raw = raw.replace('{files:', '{"files":', 1)
raw = re.sub(r',\s*\]', ']', raw)
data = json.loads(raw)
files = [f for f in data['files'] if '/tests/' not in f['summary_name']]
for f in sorted(files, key=lambda x: x['summary_name']):
    print(f"{f['covered']:>6}%  ({f['covered_lines']}/{f['total_lines']})  {f['summary_name']}")
EOF

if [ "$HTML" -eq 1 ]; then
  echo
  echo "Full HTML report: $RUN_DIR/index.html"
  xdg-open "$RUN_DIR/index.html" >/dev/null 2>&1 &
fi
