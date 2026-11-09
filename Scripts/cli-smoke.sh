#!/bin/bash
# End-to-end check of the bundled command-line tool against a folder fixture and a throwaway ExFAT image.
# Usage: Scripts/cli-smoke.sh build/CleanEject.app/Contents/Helpers/cleaneject
# Read-only for everything but its own fixture (build/cli-smoke/) and its own image (/Volumes/CETEST-CLI*).
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <path to cleaneject>" >&2; exit 2; }
CLI="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
[ -x "$CLI" ] || { echo "not executable: $1" >&2; exit 2; }

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
SMOKE="$REPO/build/cli-smoke"
FOLDER="$SMOKE/folder"
SCRATCH="$(mktemp -d)"
OUT="$SCRATCH/out"
ERR="$SCRATCH/err"
DEVICE=""

cleanup() {
    if [ -n "$DEVICE" ]; then hdiutil detach -force -quiet "$DEVICE" || true; fi
    rm -rf "$SMOKE" "$SCRATCH"
}
trap cleanup EXIT

failures=0
pass() { echo "ok    $*"; }
fail() { echo "FAIL  $*" >&2; sed 's/^/      stdout: /' "$OUT" >&2; sed 's/^/      stderr: /' "$ERR" >&2; failures=$((failures + 1)); }

# Runs the tool with stdout and stderr captured; the exit status lands in CODE.
run() {
    set +e
    "$CLI" "$@" >"$OUT" 2>"$ERR"
    CODE=$?
    set -e
}

# expect <exit code> <description> -- <arguments>...
expect() {
    local want="$1" what="$2"
    shift 3
    run "$@"
    if [ "$CODE" -eq "$want" ]; then pass "$what (exit $CODE)"; else fail "$what: exit $CODE, expected $want"; fi
}

check() {
    local what="$1"
    shift
    if "$@"; then pass "$what"; else fail "$what"; fi
}

json_ok() { jq -e "$1" "$OUT" >/dev/null 2>&1; }
exists() { [ -e "$FOLDER/$1" ] || [ -L "$FOLDER/$1" ]; }
all_exist() { local p; for p in "$@"; do exists "$p" || { echo "      missing: $p" >&2; return 1; }; done; }
none_exist() { local p; for p in "$@"; do ! exists "$p" || { echo "      still there: $p" >&2; return 1; }; done; }

JUNK=(.DS_Store sub/.DS_Store ._a.txt sub/._b.txt)
DS_STORES=(.DS_Store sub/.DS_Store)
SIDECARS=(._a.txt sub/._b.txt)
KEPT=(a.txt sub/b.txt ._ .DS_Store.bak .Trashes/x)

make_fixture() {
    rm -rf "$FOLDER"
    mkdir -p "$FOLDER/sub" "$FOLDER/.Trashes"
    local p
    for p in "${JUNK[@]}" "${KEPT[@]}"; do printf 'x' >"$FOLDER/$p"; done
}

echo "== usage and refusals"
expect 0 "--help" -- --help
grep -q "Usage: cleaneject" "$OUT" || fail "--help prints the usage"
expect 2 "no arguments" --
expect 2 "unknown option" -- clean --bogus "$REPO"
grep -q "cleaneject --help" "$ERR" || fail "usage error points to --help"
expect 2 "unknown --skip rule" -- clean --skip nope "$REPO"
expect 2 "--skip macosx-folder is not a delete toggle" -- clean --skip macosx-folder "$REPO"
expect 1 "clean / is refused" -- clean /
grep -q "never cleaned" "$ERR" || fail "clean / names the refusal"
expect 1 "clean /tmp is refused" -- clean /tmp
grep -q "system location" "$ERR" || fail "clean /tmp names the refusal"

echo "== folder fixture"
make_fixture
FOLDER="$(cd "$FOLDER" && pwd -P)"
expect 0 "preview --json" -- preview --json "$FOLDER"
check "preview output parses as JSON" json_ok '.results | length == 1'
expected="$(for p in "${JUNK[@]}"; do echo "$FOLDER/$p"; done | sort)"
listed="$(jq -r '.results[0].removals[].path' "$OUT" 2>/dev/null | sort)"
check "preview lists exactly the junk" [ "$listed" = "$expected" ]
check "preview is a dry run of a folder" json_ok '.results[0].dryRun == true and .results[0].kind == "folder" and .results[0].eject == null and .refusals == []'
check "preview removed nothing" all_exist "${JUNK[@]}" "${KEPT[@]}"

expect 2 "clean --eject on a folder" -- clean --eject "$FOLDER"
check "clean --eject on a folder removed nothing" all_exist "${JUNK[@]}" "${KEPT[@]}"

expect 1 "mixed run with a refused path" -- clean "$FOLDER" /tmp
check "mixed run removed nothing" all_exist "${JUNK[@]}" "${KEPT[@]}"

(cd "$FOLDER" && "$CLI" clean "" >"$OUT" 2>"$ERR") && CODE=0 || CODE=$?
if [ "$CODE" -eq 2 ]; then pass "clean \"\" in the fixture (exit 2)"; else fail "clean \"\": exit $CODE, expected 2"; fi
check "clean \"\" removed nothing" all_exist "${JUNK[@]}" "${KEPT[@]}"

expect 0 "clean --skip ds-store" -- clean --skip ds-store "$FOLDER"
check "--skip ds-store keeps .DS_Store" all_exist "${DS_STORES[@]}" "${KEPT[@]}"
check "--skip ds-store still removes sidecars" none_exist "${SIDECARS[@]}"

make_fixture
expect 0 "clean" -- clean "$FOLDER"
check "clean removes the junk" none_exist "${JUNK[@]}"
check "clean keeps regular files" all_exist "${KEPT[@]}"

echo "== list"
expect 0 "list --json" -- list --json
check "list output parses as JSON" json_ok '.volumes | type == "array"'

echo "== ExFAT image"
DMG="$SCRATCH/cetest-cli.dmg"
hdiutil create -quiet -size 20m -fs ExFAT -volname CETEST-CLI "$DMG"
attach="$(hdiutil attach -nobrowse "$DMG")"
DEVICE="$(echo "$attach" | head -1 | awk '{print $1}')"
VOLUME="$(echo "$attach" | grep -o '/Volumes/CETEST-CLI.*$' | sed 's/[[:space:]]*$//')"
[ -d "$VOLUME" ] || { echo "image did not mount: $attach" >&2; exit 1; }
VOLUME_JUNK=(.DS_Store sub/.DS_Store ._x .apdisk .Trashes/x .fseventsd/x .TemporaryItems/x)
mkdir -p "$VOLUME/sub" "$VOLUME/.Trashes" "$VOLUME/.fseventsd" "$VOLUME/.TemporaryItems"
for p in "${VOLUME_JUNK[@]}" keep.txt; do printf 'x' >"$VOLUME/$p"; done

expect 0 "clean --eject --json on the image" -- clean --eject --json "$VOLUME"
check "clean output parses as JSON" json_ok '.results | length == 1'
check "the volume run had no failures" json_ok '.results[0].kind == "volume" and .results[0].failures == [] and .refusals == []'
check "reports ejected: true" json_ok '.results[0].eject.ejected == true and .results[0].eject.error == null'
removed="$(jq -r '.results[0].removals[].path | rtrimstr("/")' "$OUT" 2>/dev/null)"
for p in .DS_Store sub/.DS_Store ._x .apdisk .Trashes .fseventsd .TemporaryItems; do
    check "removed $p" grep -qxF "$VOLUME/$p" <<<"$removed"
done
check "kept keep.txt and sub" bash -c '! grep -qxE "$1/(keep\.txt|sub)" <<<"$2"' _ "$VOLUME" "$removed"

for _ in $(seq 50); do [ -e "$VOLUME" ] || break; sleep 0.2; done
check "the volume is gone from /Volumes" [ ! -e "$VOLUME" ]
if [ ! -e "$VOLUME" ]; then DEVICE=""; fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "All CLI smoke checks passed."
