#!/bin/bash
# Build every test harness target in Package.swift and run each one, with HOME in a /tmp scratch directory.
# Exits non-zero if any harness fails to build or fails.
#   bash tools/run-tests.sh [scratch-directory, default /tmp/tokenstatsbar-tests] [HarnessName ...]
# With no harness names, every harness runs. Logs are in <scratch-directory>/<HarnessName>/log.
set -uo pipefail
cd "$(dirname "$0")/.."
root=${1:-/tmp/tokenstatsbar-tests}
shift || true
case "$root" in /tmp/*) ;; *) echo 'Scratch directory must be under /tmp' >&2; exit 2;; esac
mkdir -p "$root"

# Harness names come from the harnesses list in Package.swift. macOS ships bash 3.2, so this uses plain strings.
if [ $# -gt 0 ]; then
    selected="$*"
else
    selected=$(sed -n '/^let harnesses/,/^]/p' Package.swift | grep -oE '^    \("[A-Za-z0-9]+"' | tr -d ' ("' | tr '\n' ' ')
fi

swift build || { echo "FAIL: swift build" >&2; exit 1; }
bin=$(swift build --show-bin-path)

count=0
failures=""
for name in $selected; do
    count=$((count + 1))
    directory="$root/$name"
    mkdir -p "$directory/home"
    command=(env HOME="$directory/home" CFFIXED_USER_HOME="$directory/home" TMPDIR="$directory/" "$bin/$name")
    if "${command[@]}" >"$directory/log" 2>&1; then
        echo "ok    $name: $(tail -1 "$directory/log")"
    else
        echo "FAIL  $name (log: $directory/log)"
        grep -E 'FAIL|Fatal error|error:' "$directory/log" | head -5 | sed 's/^/      /'
        failures="$failures $name"
    fi
done

if [ -n "$failures" ]; then
    echo "$count harnesses, $(echo $failures | wc -w | tr -d ' ') failed:$failures"
    exit 1
fi
echo "$count harnesses, 0 failed"
