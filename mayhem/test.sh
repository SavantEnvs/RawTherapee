#!/usr/bin/env bash
# mayhem/test.sh — known-answer test of RawTherapee's vendored LibRaw, using LibRaw's own sample
# tools (raw-identify, dcraw_emu) built by mayhem/build.sh with normal flags.
# Inputs are headerless sensor dumps that LibRaw identifies by exact file size (its camera table in
# src/metadata/identify.cpp), filled with a fixed byte pattern; for each we assert the identification
# (camera, sizes, filter pattern, ...) and the sha256 of the developed image against
# mayhem/test-golden.txt.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/build-mayhem/test"
GOLDEN="$SRC/mayhem/test-golden.txt"
for t in raw-identify dcraw_emu; do
  [ -x "$BIN/$t" ] || { echo "missing $BIN/$t — run mayhem/build.sh" >&2; emit_ctrf libraw-known-answer 0 1; exit 1; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/libraw-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# size:camera pairs from LibRaw's file-size table (8-, 10-, 12- and 16-bit dumps)
CASES="460800 1581060 2818048 5067304"
actual="$work/actual.txt"
: > "$actual"
for sz in $CASES; do
  f="$work/dump_$sz.raw"
  # deterministic, non-constant content
  seq 1 2000000 | head -c "$sz" > "$f"
  {
    echo "== $sz identify"
    "$BIN/raw-identify" "$f" 2>&1 | sed "s|$work/||"
    "$BIN/raw-identify" -v "$f" 2>&1 | grep -v -e "^Filename:" -e "^Timestamp:"
    echo "== $sz develop"
    if (cd "$work" && "$BIN/dcraw_emu" -w "dump_$sz.raw" >/dev/null 2>&1) && [ -s "$f.ppm" ]; then
      sha256sum < "$f.ppm" | cut -d' ' -f1
    else
      echo "develop failed"
    fi
  } >> "$actual"
done

if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then cp "$actual" "$GOLDEN"; echo "golden updated"; fi

passed=0; failed=0
for sz in $CASES; do
  for part in identify develop; do
    exp=$(awk -v h="== $sz $part" '$0==h{f=1;next} /^== /{f=0} f' "$GOLDEN")
    got=$(awk -v h="== $sz $part" '$0==h{f=1;next} /^== /{f=0} f' "$actual")
    if [ -n "$exp" ] && [ "$exp" = "$got" ]; then
      passed=$((passed+1)); echo "PASS $sz $part"
    else
      failed=$((failed+1)); echo "FAIL $sz $part"; diff <(echo "$exp") <(echo "$got") | head -20
    fi
  done
done
emit_ctrf libraw-known-answer "$passed" "$failed"
