#!/usr/bin/env bash
# xplat.sh -- cross-platform test runner for ftags.
# Runs bats on four awk implementations: BSD (default), gawk, mawk (debian), busybox awk (alpine).
# Then, when META_DIR points at a code repository, runs ftags.sh check and ftags.sh changed --base there.
#
# Usage: tests/xplat.sh [--skip-docker] [--skip-meta]
#
# Environment:
#   FTAGS_TOOL       path to ftags.sh (default: auto-detected from script location)
#   BATS_BIN         bats executable (default: bats)
#   FTAGS_AWK        override awk for the local run (default: awk)
#   BASE_REV         base revision for ftags changed (required for --skip-docker=false or meta checks)
#   META_DIR         code repository root with .ftags.conf; meta checks are skipped when unset
#   DEBIAN_IMAGE     Docker image for mawk/gawk tests (default: debian:bookworm-slim)
#   ALPINE_IMAGE     Docker image for busybox awk/gawk tests (default: alpine:3.21)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FTAGS_TOOL=${FTAGS_TOOL:-"$(cd "$SCRIPT_DIR/.." && pwd -P)/ftags.sh"}
BATS_BIN=${BATS_BIN:-bats}
TOOL_DIR=$(dirname "$FTAGS_TOOL")
TESTS_DIR="$TOOL_DIR/tests"
META_DIR=${META_DIR:-}
DEBIAN_IMAGE=${DEBIAN_IMAGE:-debian:bookworm-slim}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.21}

skip_docker=0
skip_meta=0
for arg in "$@"; do
  case $arg in
    --skip-docker) skip_docker=1 ;;
    --skip-meta) skip_meta=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ok=0
fail=0
step() {
  printf '\n=== %s ===\n' "$1"
}
pass() {
  printf 'PASS: %s\n' "$1"
  ok=$((ok + 1))
}
failed() {
  printf 'FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

# --- local: BSD awk (default) ---
step "bats on default awk"
if "$BATS_BIN" "$TESTS_DIR/ftags.bats"; then
  pass "bats (default awk)"
else
  failed "bats (default awk)"
fi

# --- local: gawk ---
step "bats on gawk"
if command -v gawk >/dev/null 2>&1; then
  if FTAGS_AWK=gawk "$BATS_BIN" "$TESTS_DIR/ftags.bats"; then
    pass "bats (gawk)"
  else
    failed "bats (gawk)"
  fi
else
  echo "gawk not found, skipping" >&2
fi

# --- docker: debian (mawk + gawk) ---
if [ "$skip_docker" = 0 ]; then
  step "bats in $DEBIAN_IMAGE (mawk, then gawk)"
  if command -v docker >/dev/null 2>&1; then
    docker run --rm \
      -v "$TOOL_DIR:/ftags:ro" \
      -e LC_ALL=C \
      "$DEBIAN_IMAGE" sh -c '
        set -e
        apt-get update -qq && apt-get install -y -qq git gawk bats >/dev/null 2>&1
        echo "--- mawk ---"
        FTAGS_AWK=mawk bats /ftags/tests/ftags.bats
        echo "--- gawk ---"
        FTAGS_AWK=gawk bats /ftags/tests/ftags.bats
      ' && pass "debian (mawk + gawk)" || failed "debian (mawk + gawk)"
  else
    echo "docker not found, skipping" >&2
  fi

  # --- docker: alpine (busybox awk + gawk) ---
  step "bats in $ALPINE_IMAGE (busybox awk, then gawk)"
  if command -v docker >/dev/null 2>&1; then
    docker run --rm \
      -v "$TOOL_DIR:/ftags:ro" \
      -e LC_ALL=C \
      "$ALPINE_IMAGE" sh -c '
        set -e
        apk add --no-cache bash git gawk bats >/dev/null 2>&1
        echo "--- busybox awk ---"
        FTAGS_AWK=awk bats /ftags/tests/ftags.bats
        echo "--- gawk ---"
        FTAGS_AWK=gawk bats /ftags/tests/ftags.bats
      ' && pass "alpine (busybox + gawk)" || failed "alpine (busybox + gawk)"
  else
    echo "docker not found, skipping" >&2
  fi
fi

# --- code repository checks ---
if [ "$skip_meta" = 0 ]; then
  step "ftags check from code repository"
  if [ -n "$META_DIR" ] && [ -f "$META_DIR/.ftags.conf" ]; then
    if bash "$FTAGS_TOOL" -C "$META_DIR" check; then
      pass "ftags check"
    else
      failed "ftags check"
    fi
  else
    echo "META_DIR not set or has no .ftags.conf, skipping" >&2
  fi

  step "ftags changed --base from code repository"
  if [ -n "${BASE_REV:-}" ] && [ -n "$META_DIR" ] && [ -f "$META_DIR/.ftags.conf" ]; then
    out=$(bash "$FTAGS_TOOL" -C "$META_DIR" changed --base "$BASE_REV" 2>/dev/null) || true
    if printf '%s\n' "$out" | grep -q '^# untagged'; then
      printf '%s\n' "$out"
      failed "ftags changed --base $BASE_REV (untagged declarations)"
    else
      printf '%s\n' "$out"
      pass "ftags changed --base $BASE_REV"
    fi
  else
    echo "BASE_REV or META_DIR not set, skipping" >&2
  fi
fi

# --- summary ---
printf '\n=== summary: %d passed, %d failed ===\n' "$ok" "$fail"
[ "$fail" = 0 ]
