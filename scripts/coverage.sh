#!/bin/bash
# Runs the tests with code coverage and fails when a module's line coverage drops under its limit.
# The modules that drive the hardware and the helper's decisions have limits; the rest is only reported.
#
#   scripts/coverage.sh            run the tests, then check
#   scripts/coverage.sh --no-test  check the data of the last `swift test --enable-code-coverage`
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Minimum line coverage, in percent, per module. Raise a limit when coverage goes up; never lower one to pass.
LIMITS="ClamDownHelperKit=93 ClamDownSensors=75 ClamDownShared=94 ClamDownAppKit=82"

if [ "${1:-}" != "--no-test" ]; then
  swift test --enable-code-coverage
fi

bin="$(swift build --show-bin-path)"
profile="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
[ -f "$profile" ] || { echo "FAIL: no coverage data at $profile" >&2; exit 1; }

# Each test target is its own bundle, so every bundle is passed to llvm-cov; otherwise most modules are missing.
objects=()
for bundle in "$bin"/*.xctest; do
  name="$(basename "$bundle" .xctest)"
  objects+=("$bundle/Contents/MacOS/$name")
done
[ ${#objects[@]} -gt 0 ] || { echo "FAIL: no test bundles in $bin" >&2; exit 1; }

args=("${objects[0]}")
for object in "${objects[@]:1}"; do args+=(-object "$object"); done

report="$(mktemp)"
trap 'rm -f "$report"' EXIT
xcrun llvm-cov export "${args[@]}" -instr-profile "$profile" -summary-only \
  -ignore-filename-regex '(/Tests/|/\.build/|/checkouts/)' > "$report"

python3 -I - "$report" $LIMITS <<'PY'
import json, sys
from collections import defaultdict

report, limits = sys.argv[1], dict(item.split("=") for item in sys.argv[2:])
covered, total = defaultdict(int), defaultdict(int)
for f in json.load(open(report))["data"][0]["files"]:
    parts = f["filename"].split("/Sources/")
    if len(parts) < 2:
        continue
    module = parts[-1].split("/")[0]
    lines = f["summary"]["lines"]
    covered[module] += lines["covered"]
    total[module] += lines["count"]

failed = False
for module in sorted(total):
    percent = 100 * covered[module] / total[module] if total[module] else 100
    limit = limits.get(module)
    mark = ""
    if limit is not None:
        ok = percent >= float(limit)
        failed |= not ok
        mark = f"  (limit {limit}%{'' if ok else ', FAIL'})"
    print(f"{module:20} {percent:5.1f}%  {covered[module]}/{total[module]} lines{mark}")
missing = [m for m in limits if m not in total]
for module in missing:
    print(f"FAIL: no coverage data for {module}")
sys.exit(1 if failed or missing else 0)
PY
