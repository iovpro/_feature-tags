#!/usr/bin/env bats
# Tests for ftags.sh. Expectations are derived from the contract, not from the implementation.
# Runs on bats >= 1.4 (BATS_TEST_TMPDIR) with bash 3.2: no [[ =~ ]], no mapfile, no declare -A.
#
# Expected findings of `check` on fixtures/violations, per class (total 29):
#   format    7  pkg/v/format.go x6 (upper-case, bare domain, 2 segments on func, 3 segments on type,
#                unknown marker @exit, marker on feature tag), pkg/v/format_test.go x1 (marker on test)
#   text      4  pkg/v/text.go:3 (text before tag), :8 (edition-1 line: text after tag), :11 (double space),
#                docker/compose.yml:6 (tag without comment marker inside a YAML value)
#   placement 6  pkg/v/text.go:8 (edition-1 line: no blank line before func), pkg/v/placement.go:3 (two blank
#                lines), :9 (tag group over a non-declaration), :16 (trailing tag on an ordinary line),
#                :19 (tag group at end of file), docker/compose.yml:2 (tag indent != key indent)
#   file      3  pkg/v/header.go:1 (over package), header.yml:1 (first line, over a comment),
#                scripts/header.sh:2 (after shebang, no declaration seen before an indented line)
#   field     3  pkg/v/field.go:5 (struct field), :10 (tag group inside struct), :17 (interface method)
#   orphan    1  pkg/v/ok.go (fx.zzz.orphan)
#   nostart   1  fx.demo.stop (done, tagged in pkg/v/ok.go, no @entry/@operation on the prod side)
#   deps      3  registry.md:10 (unknown target), :11 (self-reference), :13 (duplicate edge)
#   registry  1  domains fx and fxx (prefix clash)
# The edition-1 line pkg/v/text.go:8 yields text + placement and still binds legacyStyle (checked via trace).

setup() {
  TOOL="$BATS_TEST_DIRNAME/.."
  FTAGS="$TOOL/ftags.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures"
  TP='#''f:'
  TAB=$'\t'
  ERR="$BATS_TEST_TMPDIR/stderr"
  export LC_ALL=C
}

# --- helpers (no flow logic, untagged) ---------------------------------------------------------------

ftags() {
  bash "$FTAGS" "$@" 2>"$ERR"
}

err_has() {
  grep -qF -- "$1" "$ERR"
}

err_is_empty() {
  [ ! -s "$ERR" ]
}

has_line() {
  printf '%s\n' "$output" | grep -qxF -- "$1"
}

has_text() {
  printf '%s\n' "$output" | grep -qF -- "$1"
}

lacks_text() {
  ! printf '%s\n' "$output" | grep -qF -- "$1"
}

count_lines_with() {
  printf '%s\n' "$output" | grep -cF -- "$1" || true
}

count_class() {
  printf '%s\n' "$output" | grep -c "^$1$TAB" || true
}

row_has() {
  printf '%s\n' "$output" | grep -F -- "$1" | grep -qF -- "$2"
}

assert_output_is() {
  if [ "$output" != "$1" ]; then
    printf -- '--- expected\n%s\n--- actual\n%s\n' "$1" "$output" >&2
    return 1
  fi
}

trace_line() {
  printf '%6s  %-6s  %-32s  %s' "$1" "$2" "$3" "$4"
}

sed_file() {
  sed -E "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

insert_after() {
  awk -v pat="$2" -v ins="$3" '{ print } index($0, pat) > 0 { print ins }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

append_line() {
  printf '%s\n' "$2" >> "$1"
}

make_repo() {
  REPO="$BATS_TEST_TMPDIR/repo"
  cp -R "$FIX/$1" "$REPO"
  git -C "$REPO" -c init.defaultBranch=main init -q
  git -C "$REPO" config user.email ftags@example.com
  git -C "$REPO" config user.name ftags
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" tag base
}

commit_head() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m head
  git -C "$REPO" tag head
}

# =====================================================================================================
# check
# =====================================================================================================

@test "check: violations fixture yields exact per-class counts and exit 1" {
  run ftags -C "$FIX/violations" check
  [ "$status" -eq 1 ]
  [ "$(count_class format)" -eq 7 ]
  [ "$(count_class text)" -eq 4 ]
  [ "$(count_class placement)" -eq 6 ]
  [ "$(count_class file)" -eq 3 ]
  [ "$(count_class field)" -eq 3 ]
  [ "$(count_class orphan)" -eq 1 ]
  [ "$(count_class nostart)" -eq 1 ]
  [ "$(count_class deps)" -eq 3 ]
  [ "$(count_class registry)" -eq 1 ]
  [ "${#lines[@]}" -eq 29 ]
  grep -qxF 'ftags: 29 finding(s)' "$ERR"
}

@test "check: every line is <class>TAB<file>:<line>TAB<detail>, sorted by class" {
  run ftags -C "$FIX/violations" check
  [ "$status" -eq 1 ]
  bad=$(printf '%s\n' "$output" | grep -vE "^[a-z]+$TAB[^$TAB]+:[0-9]+$TAB.+$" || true)
  [ -z "$bad" ]
  classes=$(printf '%s\n' "$output" | cut -f1)
  [ "$classes" = "$(printf '%s\n' "$classes" | sort)" ]
}

@test "check: text findings point at the offending lines" {
  run ftags -C "$FIX/violations" check
  has_text "text${TAB}pkg/v/text.go:3${TAB}"
  has_text "text${TAB}pkg/v/text.go:8${TAB}"
  has_text "text${TAB}pkg/v/text.go:11${TAB}"
  has_text "text${TAB}docker/compose.yml:6${TAB}"
}

@test "check: placement findings carry the tag-line number" {
  run ftags -C "$FIX/violations" check
  has_text "placement${TAB}pkg/v/text.go:"
  has_text "placement${TAB}pkg/v/placement.go:3${TAB}"
  has_text "placement${TAB}pkg/v/placement.go:9${TAB}"
  has_text "placement${TAB}pkg/v/placement.go:16${TAB}"
  has_text "placement${TAB}pkg/v/placement.go:19${TAB}"
  has_text "placement${TAB}docker/compose.yml:2${TAB}"
}

@test "check: file and field findings per language" {
  run ftags -C "$FIX/violations" check
  has_text "file${TAB}pkg/v/header.go:1${TAB}"
  has_text "file${TAB}header.yml:1${TAB}"
  has_text "file${TAB}scripts/header.sh:2${TAB}"
  has_text "field${TAB}pkg/v/field.go:5${TAB}"
  has_text "field${TAB}pkg/v/field.go:10${TAB}"
  has_text "field${TAB}pkg/v/field.go:17${TAB}"
}

@test "check: format findings name the offending files" {
  run ftags -C "$FIX/violations" check
  [ "$(count_lines_with "format${TAB}pkg/v/format.go:")" -eq 6 ]
  [ "$(count_lines_with "format${TAB}pkg/v/format_test.go:")" -eq 1 ]
  has_text "${TP}FX.Demo.Run"
  has_text "${TP}fx.demo.run@exit"
}

@test "check: orphan, nostart, deps and registry findings" {
  run ftags -C "$FIX/violations" check
  row_has "orphan${TAB}pkg/v/ok.go:" "fx.zzz.orphan"
  row_has "nostart${TAB}" "fx.demo.stop"
  has_text "deps${TAB}registry.md:10${TAB}"
  has_text "deps${TAB}registry.md:11${TAB}"
  has_text "deps${TAB}registry.md:13${TAB}"
  row_has "registry${TAB}registry.md:" "fxx"
}

@test "check: clean fixture is silent with exit 0" {
  run ftags -C "$FIX/clean" check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  err_is_empty
}

@test "check: excluded path gen/* is not scanned" {
  run ftags -C "$FIX/clean" check
  [ "$status" -eq 0 ]
  run ftags -C "$FIX/clean" scan
  [ "$status" -eq 0 ]
  lacks_text "gen/generated.go"
}

@test "config: .ftags.conf is found upwards from a subdirectory; paths are relative to its directory" {
  run ftags -C "$FIX/clean/pkg/a" check
  [ "$status" -eq 0 ]
  run ftags -C "$FIX/clean/pkg/a" scan
  [ "$status" -eq 0 ]
  has_line "D${TAB}go${TAB}pkg/a/entry.go${TAB}6${TAB}decl${TAB}prod${TAB}Run${TAB}${TP}fx.demo.run@entry"
}

# =====================================================================================================
# trace / entries / operations / tests
# =====================================================================================================

@test "trace: fx.demo.run prints entry, steps (recv marked), tests in order; files alphabetical" {
  run ftags -C "$FIX/clean" trace fx.demo.run
  [ "$status" -eq 0 ]
  expected=$(
    printf '%s\n' '# entry' 'pkg/a/entry.go'
    trace_line 6 decl Run "${TP}fx.demo.run@entry"; printf '\n'
    printf '%s\n' '# steps' 'pkg/a/steps.go'
    trace_line 11 decl Verify "${TP}fx.demo.run.verify"; printf '\n'
    printf '%s\n' 'pkg/b/recv.go'
    trace_line 6 decl HandleRun "${TP}fx.demo.run.apply@recv"; printf '  <recv>\n'
    trace_line 8 branch 'case "ack":' "${TP}fx.demo.run.ack"; printf '\n'
    printf '%s\n' 'pkg/b/stop.go'
    trace_line 13 decl shared "${TP}fx.demo.run.persist ${TP}fx.demo.stop.persist"; printf '\n'
    printf '%s\n' '# tests' 'pkg/a/entry_test.go'
    trace_line 8 test TestRun "${TP}fx.demo.run"; printf '\n'
    trace_line 16 test TestRun_Stop "${TP}fx.demo.run ${TP}fx.demo.stop"; printf '\n'
  )
  assert_output_is "$expected"
}

@test "trace: fx.demo.stop shows entry, branch step, shared step and the shared test" {
  run ftags -C "$FIX/clean" trace fx.demo.stop
  [ "$status" -eq 0 ]
  expected=$(
    printf '%s\n' '# entry' 'pkg/b/stop.go'
    trace_line 6 decl Stop "${TP}fx.demo.stop@entry"; printf '\n'
    printf '%s\n' '# steps' 'pkg/b/recv.go'
    trace_line 10 branch 'default:' "${TP}fx.demo.stop"; printf '\n'
    printf '%s\n' 'pkg/b/stop.go'
    trace_line 13 decl shared "${TP}fx.demo.run.persist ${TP}fx.demo.stop.persist"; printf '\n'
    printf '%s\n' '# tests' 'pkg/a/entry_test.go'
    trace_line 16 test TestRun_Stop "${TP}fx.demo.run ${TP}fx.demo.stop"; printf '\n'
  )
  assert_output_is "$expected"
}

@test "trace: fx.core.hash has an operation section and no entry section" {
  run ftags -C "$FIX/clean" trace fx.core.hash
  [ "$status" -eq 0 ]
  expected=$(
    printf '%s\n' '# operation' 'pkg/a/steps.go'
    trace_line 21 decl hash "${TP}fx.core.hash@operation"; printf '\n'
  )
  assert_output_is "$expected"
}

@test "trace: argument with prefix and marker is equivalent to the bare flow" {
  run ftags -C "$FIX/clean" trace fx.demo.run
  [ "$status" -eq 0 ]
  plain="$output"
  run ftags -C "$FIX/clean" trace "${TP}fx.demo.run@entry"
  [ "$status" -eq 0 ]
  assert_output_is "$plain"
  run ftags -C "$FIX/clean" trace "${TP}fx.demo.run"
  [ "$status" -eq 0 ]
  assert_output_is "$plain"
}

@test "trace: prefix match is segment-based (fx.demo.ru matches nothing)" {
  run ftags -C "$FIX/clean" trace fx.demo.ru
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  err_has "ftags: nothing tagged fx.demo.ru"
}

@test "trace: unknown flow exits 1 with a message" {
  run ftags -C "$FIX/clean" trace fx.nope
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  err_has "ftags: nothing tagged fx.nope"
}

@test "trace: edition-1 lines in violations are still bound and traceable" {
  run ftags -C "$FIX/violations" trace fx.demo.run
  [ "$status" -eq 0 ]
  has_text "legacyStyle"
  has_text "${TP}fx.demo.run.legacy"
  has_text "textBefore"
  has_text "doubleSpace"
  has_text "RunEntry"
}

@test "entries: four @entry starts sorted by tag, file, line" {
  run ftags -C "$FIX/clean" entries
  [ "$status" -eq 0 ]
  expected=$(printf '%s\n' \
    "pkg/a/entry.go:6${TAB}decl${TAB}Run${TAB}${TP}fx.demo.run@entry" \
    "pkg/b/stop.go:6${TAB}decl${TAB}Stop${TAB}${TP}fx.demo.stop@entry" \
    "docker/Dockerfile:3${TAB}decl${TAB}FROM${TAB}${TP}fx.ops.build@entry" \
    "docker/compose.yml:4${TAB}decl${TAB}demo${TAB}${TP}fx.ops.up@entry")
  assert_output_is "$expected"
}

@test "operations: single @operation start" {
  run ftags -C "$FIX/clean" operations
  [ "$status" -eq 0 ]
  assert_output_is "pkg/a/steps.go:21${TAB}decl${TAB}hash${TAB}${TP}fx.core.hash@operation"
}

@test "entries and operations are disjoint" {
  run ftags -C "$FIX/clean" entries
  [ "$status" -eq 0 ]
  entries="$output"
  run ftags -C "$FIX/clean" operations
  [ "$status" -eq 0 ]
  ops="$output"
  [ -n "$entries" ]
  [ -n "$ops" ]
  printf '%s\n' "$ops" | while IFS= read -r line; do
    if printf '%s\n' "$entries" | grep -qxF -- "$line"; then
      echo "shared line: $line" >&2
      exit 1
    fi
  done
}

@test "entries/operations with a flow filter: matches exit 0, no matches exit 1, no argument and empty exits 0" {
  run ftags -C "$FIX/clean" entries fx.ops
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  has_text "${TP}fx.ops.build@entry"
  has_text "${TP}fx.ops.up@entry"
  run ftags -C "$FIX/clean" entries fx.later
  [ "$status" -eq 1 ]
  run ftags -C "$FIX/clean" operations fx.demo
  [ "$status" -eq 1 ]
  run ftags -C "$FIX/clean" operations fx.core.hash
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  run ftags -C "$FIX/violations" operations
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tests --lang go: names joined with | and go test command on stderr" {
  run ftags -C "$FIX/clean" --lang go tests fx.demo.run
  [ "$status" -eq 0 ]
  assert_output_is "TestRun|TestRun_Stop"
  err_has '# go: go test -race ./... -run "^(TestRun|TestRun_Stop)$"'
}

@test "tests: fx.demo.stop finds only the shared Go test" {
  run ftags -C "$FIX/clean" tests fx.demo.stop
  [ "$status" -eq 0 ]
  assert_output_is "TestRun_Stop"
  err_has "# go: go test -race"
}

@test "tests: fx.ops.up finds the bats test and prints the bats command" {
  run ftags -C "$FIX/clean" tests fx.ops.up
  [ "$status" -eq 0 ]
  assert_output_is "up starts the demo stack"
  err_has '# sh: bats -f "up starts the demo stack" tests/'
}

@test "tests: fx.ops.build has no tests but yaml code, so EVIDENCE_CMD is printed with exit 0" {
  run ftags -C "$FIX/clean" tests fx.ops.build
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  err_has "# yaml: docker compose down"
}

@test "tests: done flow without tests and without evidence exits 1 as plain not-found" {
  run ftags -C "$FIX/clean" tests fx.core.hash
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  err_has "ftags: no tests tagged fx.core.hash"
  ! err_has "evidence"
}

@test "tests: planned flow without tests exits 1 the same way, status is not consulted" {
  run ftags -C "$FIX/clean" tests fx.later.x
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  err_has "ftags: no tests tagged fx.later.x"
  ! err_has "evidence"
}

# =====================================================================================================
# scan
# =====================================================================================================

@test "scan: clean fixture emits well-formed D and E records and no V records" {
  run ftags -C "$FIX/clean" scan
  [ "$status" -eq 0 ]
  bad=$(printf '%s\n' "$output" | grep -vE "^[DE]$TAB" || true)
  [ -z "$bad" ]
  badnf=$(printf '%s\n' "$output" | awk -F "$TAB" '($1 == "D" && NF != 8) || ($1 == "E" && NF != 4) { print }')
  [ -z "$badnf" ]
  has_line "D${TAB}go${TAB}pkg/a/entry.go${TAB}6${TAB}decl${TAB}prod${TAB}Run${TAB}${TP}fx.demo.run@entry"
  has_line "D${TAB}go${TAB}pkg/a/entry.go${TAB}17${TAB}decl${TAB}prod${TAB}Config${TAB}${TP}fx.demo"
  has_line "D${TAB}go${TAB}pkg/a/entry.go${TAB}24${TAB}decl${TAB}prod${TAB}const${TAB}${TP}fx.demo"
  has_line "D${TAB}go${TAB}pkg/a/entry_test.go${TAB}16${TAB}test${TAB}test${TAB}TestRun_Stop${TAB}${TP}fx.demo.run ${TP}fx.demo.stop"
  has_line "D${TAB}go${TAB}pkg/b/recv.go${TAB}8${TAB}branch${TAB}prod${TAB}case \"ack\":${TAB}${TP}fx.demo.run.ack"
  has_line "D${TAB}go${TAB}pkg/b/recv.go${TAB}10${TAB}branch${TAB}prod${TAB}default:${TAB}${TP}fx.demo.stop"
  has_line "D${TAB}yaml${TAB}docker/compose.yml${TAB}1${TAB}decl${TAB}prod${TAB}services${TAB}-"
  has_line "D${TAB}yaml${TAB}docker/compose.yml${TAB}4${TAB}decl${TAB}prod${TAB}demo${TAB}${TP}fx.ops.up@entry"
  has_line "D${TAB}yaml${TAB}docker/Dockerfile${TAB}3${TAB}decl${TAB}prod${TAB}FROM${TAB}${TP}fx.ops.build@entry"
  has_line "D${TAB}sh${TAB}scripts/run.sh${TAB}9${TAB}decl${TAB}prod${TAB}up_main${TAB}${TP}fx.ops.up.main"
  has_line "D${TAB}sh${TAB}scripts/run.sh${TAB}15${TAB}decl${TAB}prod${TAB}case${TAB}${TP}fx.ops.up"
  has_line "D${TAB}sh${TAB}scripts/run.sh${TAB}16${TAB}branch${TAB}prod${TAB}up)${TAB}${TP}fx.ops.up.start"
  has_line "D${TAB}sh${TAB}scripts/run.bats${TAB}5${TAB}test${TAB}test${TAB}up starts the demo stack${TAB}${TP}fx.ops.up"
  has_line "E${TAB}go${TAB}pkg/a/entry.go${TAB}27"
  has_line "E${TAB}sh${TAB}scripts/run.bats${TAB}8"
  lacks_text "gen/"
  lacks_text "registry.md"
}

@test "scan --lang go: only Go records" {
  run ftags -C "$FIX/clean" --lang go scan
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  other=$(printf '%s\n' "$output" | awk -F "$TAB" '$2 != "go" { print }')
  [ -z "$other" ]
  lacks_text "docker/"
  lacks_text "scripts/"
}

@test "scan: violations fixture emits V records with five fields" {
  run ftags -C "$FIX/violations" scan
  [ "$status" -eq 0 ]
  v=$(printf '%s\n' "$output" | grep "^V$TAB" || true)
  [ -n "$v" ]
  badnf=$(printf '%s\n' "$v" | awk -F "$TAB" 'NF != 5 { print }')
  [ -z "$badnf" ]
  has_text "V${TAB}text${TAB}pkg/v/text.go${TAB}3${TAB}"
  has_text "V${TAB}field${TAB}pkg/v/field.go${TAB}5${TAB}"
  has_line "D${TAB}go${TAB}pkg/v/text.go${TAB}9${TAB}decl${TAB}prod${TAB}legacyStyle${TAB}${TP}fx.demo.run.legacy"
}

# =====================================================================================================
# configuration and usage errors (exit 2)
# =====================================================================================================

@test "config: missing .ftags.conf exits 2" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run ftags -C "$BATS_TEST_TMPDIR/empty" check
  [ "$status" -eq 2 ]
  err_has "ftags: "
  err_has ".ftags.conf"
}

@test "config: unknown key exits 2 and names the key" {
  cp -R "$FIX/clean" "$BATS_TEST_TMPDIR/repo"
  append_line "$BATS_TEST_TMPDIR/repo/.ftags.conf" "BOGUS=1"
  run ftags -C "$BATS_TEST_TMPDIR/repo" check
  [ "$status" -eq 2 ]
  err_has "BOGUS"
}

@test "config: missing REG file exits 2" {
  cp -R "$FIX/clean" "$BATS_TEST_TMPDIR/repo"
  sed_file "$BATS_TEST_TMPDIR/repo/.ftags.conf" 's/^REG=.*$/REG=missing-registry.md/'
  run ftags -C "$BATS_TEST_TMPDIR/repo" check
  [ "$status" -eq 2 ]
  err_has "ftags: "
}

@test "config: unknown --lang exits 2" {
  run ftags -C "$FIX/clean" --lang nope check
  [ "$status" -eq 2 ]
  err_has "ftags: "
}

@test "usage: unknown command and unknown option exit 2; help exits 0" {
  run ftags -C "$FIX/clean" frobnicate
  [ "$status" -eq 2 ]
  err_has "ftags: "
  run ftags -C "$FIX/clean" --frob check
  [ "$status" -eq 2 ]
  run ftags -C "$FIX/clean" help
  [ "$status" -eq 0 ]
  has_text "qa-scope"
  run ftags -C "$FIX/clean" --help
  [ "$status" -eq 0 ]
  run ftags -C "$FIX/clean" -h
  [ "$status" -eq 0 ]
}

@test "changed/qa-scope: --base is mandatory (exit 2 with a hint)" {
  make_repo clean
  run ftags -C "$REPO" changed
  [ "$status" -eq 2 ]
  err_has "--base <rev>"
  run ftags -C "$REPO" qa-scope
  [ "$status" -eq 2 ]
  err_has "--base <rev>"
}

@test "changed: bad revision exits 2" {
  make_repo clean
  run ftags -C "$REPO" changed --base nosuchrev
  [ "$status" -eq 2 ]
  err_has "ftags: "
}

@test "changed: outside a git repository exits 2" {
  cp -R "$FIX/clean" "$BATS_TEST_TMPDIR/repo"
  run ftags -C "$BATS_TEST_TMPDIR/repo" changed --base HEAD
  [ "$status" -eq 2 ]
  err_has "ftags: "
}

# =====================================================================================================
# language profiles
# =====================================================================================================

@test "profiles: go, yaml, sh, ts declare every contract key exactly once (parsed as data)" {
  required="NAME FILES EXCLUDE COMMENT GAP_RE DECL_RE TAG_TARGET_RE DECL_NAME_STRIP FLOW_DECL_RE FEAT_DECL_RE BRANCH_RE FIELD_OPEN_RE FIELD_CLOSE_RE HEADER_RE TEST_FILES TEST_RE TEST_NAME_STRIP TEST_NAME_END RUN_CMD RUN_JOIN EVIDENCE_CMD"
  optional="SCANNER"
  allowed="$required $optional"
  for lang in go yaml sh ts; do
    f="$TOOL/langs/$lang.conf"
    [ -f "$f" ]
    keys=$(grep -E '^[A-Z_]+=' "$f" | sed -E 's/=.*$//')
    for k in $required; do
      printf '%s\n' "$keys" | grep -qx -- "$k" || { echo "$lang.conf: missing $k" >&2; return 1; }
    done
    for k in $keys; do
      printf '%s\n' $allowed | grep -qx -- "$k" || { echo "$lang.conf: unknown key $k" >&2; return 1; }
    done
    dups=$(printf '%s\n' "$keys" | sort | uniq -d)
    [ -z "$dups" ]
    name=$(grep -E '^NAME=' "$f" | sed -E 's/^NAME=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
    [ "$name" = "$lang" ]
    junk=$(grep -vE '^(#|[A-Z_]+=|[[:space:]]*$)' "$f" || true)
    [ -z "$junk" ]
  done
}

@test "profiles: test support and evidence per language match langs.md" {
  val() {
    grep -E "^$2=" "$1" | head -n 1 | sed -E "s/^$2=//; s/^\"(.*)\"\$/\1/; s/^'(.*)'\$/\1/"
  }
  [ -n "$(val "$TOOL/langs/go.conf" TEST_RE)" ]
  [ -n "$(val "$TOOL/langs/go.conf" TEST_FILES)" ]
  [ -z "$(val "$TOOL/langs/go.conf" EVIDENCE_CMD)" ]
  [ -n "$(val "$TOOL/langs/sh.conf" TEST_RE)" ]
  [ -n "$(val "$TOOL/langs/sh.conf" TEST_FILES)" ]
  [ -z "$(val "$TOOL/langs/sh.conf" EVIDENCE_CMD)" ]
  [ -z "$(val "$TOOL/langs/yaml.conf" TEST_RE)" ]
  [ -z "$(val "$TOOL/langs/yaml.conf" TEST_FILES)" ]
  [ -n "$(val "$TOOL/langs/yaml.conf" EVIDENCE_CMD)" ]
  [ "$(val "$TOOL/langs/go.conf" COMMENT)" = "//" ]
  [ "$(val "$TOOL/langs/yaml.conf" COMMENT)" = "#" ]
  [ "$(val "$TOOL/langs/sh.conf" COMMENT)" = "#" ]
  [ "$(val "$TOOL/langs/go.conf" RUN_JOIN)" = "|" ]
  [ "$(val "$TOOL/langs/sh.conf" RUN_JOIN)" = "|" ]
  # ts profile: SCANNER set, test files but no TEST_RE (AST handles it)
  [ "$(val "$TOOL/langs/ts.conf" SCANNER)" = "scan-ts.mjs" ]
  [ -n "$(val "$TOOL/langs/ts.conf" TEST_FILES)" ]
  [ -z "$(val "$TOOL/langs/ts.conf" TEST_RE)" ]
  [ "$(val "$TOOL/langs/ts.conf" COMMENT)" = "//" ]
  [ "$(val "$TOOL/langs/ts.conf" RUN_JOIN)" = "|" ]
  # go/sh/yaml have no SCANNER (optional key, defaults to empty = use scan.awk)
  [ -z "$(val "$TOOL/langs/go.conf" SCANNER)" ]
  [ -z "$(val "$TOOL/langs/sh.conf" SCANNER)" ]
  [ -z "$(val "$TOOL/langs/yaml.conf" SCANNER)" ]
}

# =====================================================================================================
# changed (git scenarios on a copy of the clean fixture)
# =====================================================================================================

@test "changed: unmodified repository prints '# no changes' with exit 0" {
  make_repo clean
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  assert_output_is "# no changes"
  err_has "# registry base: registry.md@base"
}

@test "check --base: unmodified repository stays clean" {
  make_repo clean
  run ftags -C "$REPO" check --base base
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "changed: editing the body of hash marks fx.core.hash changed and its consumers affected with chains" {
  make_repo clean
  sed_file "$REPO/pkg/a/steps.go" 's/sum\[:4\]/sum[:8]/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[0]}" = "# changed" ]
  [ "${lines[1]}" = "${TP}fx.core.hash${TAB}pkg/a/steps.go:21 hash" ]
  [ "${lines[2]}" = "# affected" ]
  has_line "${TP}fx.demo.run${TAB}<- ${TP}fx.core.hash"
  has_line "${TP}fx.demo.stop${TAB}<- ${TP}fx.core.hash"
  has_line "${TP}fx.ops.up${TAB}<- ${TP}fx.demo.run <- ${TP}fx.core.hash"
  lacks_text "# new"
  lacks_text "# untagged"
}

@test "changed: section headers come from the QA scope vocabulary only" {
  make_repo clean
  sed_file "$REPO/pkg/a/steps.go" 's/sum\[:4\]/sum[:8]/'
  append_line "$REPO/registry.md" '| `'"$TP"'fx.demo.new` | New demo flow | — | planned |'
  sed_file "$REPO/registry.md" '/fx\.remote\.only/ s/\| done \|/| deprecated |/'
  append_line "$REPO/pkg/a/steps.go" 'func helper() {}'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 1 ]
  headers=$(printf '%s\n' "$output" | grep '^# ')
  expected=$(printf '%s\n' '# new' '# changed' '# affected' '# deprecated' '# untagged')
  [ "$headers" = "$expected" ]
}

@test "changed: an untagged declaration is reported and exits 1" {
  make_repo clean
  append_line "$REPO/pkg/a/steps.go" 'func helper() {}'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 1 ]
  has_line "# untagged"
  has_line "pkg/a/steps.go:25${TAB}decl${TAB}helper"
  lacks_text "# no changes"
}

@test "changed: an untracked file with a tag is changed; --head ignores untracked files" {
  make_repo clean
  printf '%s\n' 'package b' '' "// ${TP}fx.demo.stop.extra" '' '// extra is a new step of the stop flow.' 'func extra() {}' > "$REPO/pkg/b/extra.go"
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  has_line "${TP}fx.demo.stop${TAB}pkg/b/extra.go:6 extra"
  lacks_text "# affected"
  run ftags -C "$REPO" changed --base base --head base
  [ "$status" -eq 0 ]
  assert_output_is "# no changes"
}

@test "changed: an edit confined to a test declaration gives no category at all" {
  make_repo clean
  sed_file "$REPO/pkg/a/entry_test.go" 's/Name: "y"/Name: "z"/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  assert_output_is "# no changes"
  sed_file "$REPO/pkg/a/steps.go" 's/sum\[:4\]/sum[:8]/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[0]}" = "# changed" ]
  [ "${lines[1]}" = "${TP}fx.core.hash${TAB}pkg/a/steps.go:21 hash" ]
  has_line "${TP}fx.demo.run${TAB}<- ${TP}fx.core.hash"
  has_line "${TP}fx.demo.stop${TAB}<- ${TP}fx.core.hash"
}

@test "changed: a new test declaration without a tag is still untagged" {
  make_repo clean
  append_line "$REPO/pkg/a/entry_test.go" 'func TestHelper(t *testing.T) {}'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 1 ]
  has_line "# untagged"
  has_line "pkg/a/entry_test.go:21${TAB}test${TAB}TestHelper"
}

@test "changed: a feature-level tag on a touched type makes every implemented child flow changed with via-hint" {
  make_repo clean
  insert_after "$REPO/pkg/a/entry.go" 'Retries int' "${TAB}Timeout int"
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  row_has "${TP}fx.demo.run${TAB}" "pkg/a/entry.go:17 Config"
  row_has "${TP}fx.demo.run${TAB}" "(через ${TP}fx.demo)"
  row_has "${TP}fx.demo.stop${TAB}" "pkg/a/entry.go:17 Config"
  row_has "${TP}fx.demo.stop${TAB}" "(через ${TP}fx.demo)"
  has_line "# affected"
  has_line "${TP}fx.ops.up${TAB}<- ${TP}fx.demo.run"
}

@test "changed: a new registry flow is reported under '# new' with its status" {
  make_repo clean
  append_line "$REPO/registry.md" '| `'"$TP"'fx.demo.new` | New demo flow | — | planned |'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "# new" ]
  has_line "${TP}fx.demo.new${TAB}planned"
}

@test "changed: registry status and text changes are changed with registry reasons" {
  make_repo clean
  sed_file "$REPO/registry.md" '/fx\.later\.x/ s/\| planned \|/| done |/'
  sed_file "$REPO/registry.md" 's/runtime image for the demo/runtime image for the demo (rebuilt)/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  row_has "${TP}fx.later.x${TAB}" "registry: status planned->done"
  row_has "${TP}fx.ops.build${TAB}" "registry: text"
}

@test "changed: a flow switched to deprecated is reported under '# deprecated'" {
  make_repo clean
  sed_file "$REPO/registry.md" '/fx\.remote\.only/ s/\| done \|/| deprecated |/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "# deprecated" ]
  row_has "${TP}fx.remote.only${TAB}" "deprecated"
  lacks_text "# changed"
}

@test "check --base: a new dependency edge onto a deprecated flow is a deprecated finding" {
  make_repo clean
  sed_file "$REPO/registry.md" '/fx\.remote\.only/ s/\| done \|/| deprecated |/'
  insert_after "$REPO/registry.md" 'fx.ops.up` | `' '| `'"$TP"'fx.ops.build` | `'"$TP"'fx.remote.only` |'
  run ftags -C "$REPO" check --base base
  [ "$status" -eq 1 ]
  [ "$(count_class deprecated)" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  row_has "deprecated${TAB}registry.md:" "fx.remote.only"
  run ftags -C "$REPO" check
  [ "$status" -eq 0 ]
  run ftags -C "$REPO" changed --base base
  row_has "${TP}fx.ops.build${TAB}" "registry: deps"
}

@test "check --base: a new code tag of a deprecated flow is a deprecated finding" {
  make_repo clean
  sed_file "$REPO/registry.md" '/fx\.remote\.only/ s/\| done \|/| deprecated |/'
  printf '%s\n' '' "// ${TP}fx.remote.only.more" '' 'func more() {}' >> "$REPO/pkg/c/remote.go"
  run ftags -C "$REPO" check --base base
  [ "$status" -eq 1 ]
  [ "$(count_class deprecated)" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  row_has "deprecated${TAB}pkg/c/remote.go:" "fx.remote.only"
  run ftags -C "$REPO" check
  [ "$status" -eq 0 ]
}

@test "changed --head: committed edits give the same result without untracked files" {
  make_repo clean
  sed_file "$REPO/pkg/a/steps.go" 's/sum\[:4\]/sum[:8]/'
  commit_head
  printf '%s\n' 'package b' '' "// ${TP}fx.demo.stop.extra" '' 'func extra() {}' > "$REPO/pkg/b/extra.go"
  run ftags -C "$REPO" changed --base base --head head
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[1]}" = "${TP}fx.core.hash${TAB}pkg/a/steps.go:21 hash" ]
  has_line "${TP}fx.demo.stop${TAB}<- ${TP}fx.core.hash"
  lacks_text "extra.go"
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "${TP}fx.demo.stop${TAB}pkg/b/extra.go:5 extra"
}

# =====================================================================================================
# qa-scope
# =====================================================================================================

@test "qa-scope: five sections in order, category rows, evidence cells" {
  make_repo clean
  sed_file "$REPO/pkg/a/steps.go" 's/sum\[:4\]/sum[:8]/'
  append_line "$REPO/docker/Dockerfile" 'RUN adduser -D demo'
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "## QA Scope" ]
  has_text 'Base: `base`'
  has_text 'Head: `working tree`'
  has_text 'Registry base: `registry.md@base`'
  headers=$(printf '%s\n' "$output" | grep '^### ')
  expected=$(printf '%s\n' '### Новые флоу' '### Изменённые флоу' '### Косвенно затронутые' '### Deprecated-флоу' '### QA-проверки')
  [ "$headers" = "$expected" ]
  [ "$(count_lines_with '— нет')" -eq 2 ]
  lacks_text '### Изменения покрытия'
  has_text '- `'"$TP"'fx.core.hash` — '
  has_text '- `'"$TP"'fx.ops.build` — '
  row_has '- `'"$TP"'fx.ops.up` — ' '`'"$TP"'fx.demo.run` ← `'"$TP"'fx.core.hash`'
  row_has '- `'"$TP"'fx.demo.stop` — ' '← `'"$TP"'fx.core.hash`'
  has_line '| Тип влияния | Флоу | Что изменилось / почему затронуто | Спека | Стартовые точки | Автотесты / стенд | Ручная проверка |'
  row_has '| changed | `'"$TP"'fx.core.hash` |' 'pkg/a/steps.go:21'
  row_has '| changed | `'"$TP"'fx.core.hash` |' '`docs/core.md` §1'
  row_has '| changed | `'"$TP"'fx.ops.build` |' 'docker compose down'
  row_has '| changed | `'"$TP"'fx.ops.build` |' 'docker/Dockerfile:3'
  row_has '| affected | `'"$TP"'fx.demo.run` |' 'TestRun_Stop'
  row_has '| affected | `'"$TP"'fx.demo.run` |' 'go test -race'
  row_has '| affected | `'"$TP"'fx.demo.stop` |' 'TestRun_Stop'
  row_has '| affected | `'"$TP"'fx.ops.up` |' 'up starts the demo stack'
  row_has '| affected | `'"$TP"'fx.ops.up` |' 'bats -f'
  lacks_text 'Непомеченные объявления'
  err_has "# registry base: registry.md@base"
}

@test "qa-scope: changed rows precede affected rows in the table" {
  make_repo clean
  sed_file "$REPO/pkg/a/steps.go" 's/sum\[:4\]/sum[:8]/'
  run ftags -C "$REPO" qa-scope --base base
  kinds=$(printf '%s\n' "$output" | grep -E '^\| [a-z]+ \| `' | cut -d '|' -f 2 | tr -d ' ')
  [ "$kinds" = "$(printf '%s\n' changed affected affected affected)" ]
}

@test "qa-scope: an empty affected section names the dependency table as its source" {
  make_repo clean
  printf '%s\n' 'package b' '' "// ${TP}fx.demo.stop.extra" '' '// extra is a new step of the stop flow.' 'func extra() {}' > "$REPO/pkg/b/extra.go"
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 0 ]
  has_text '- `'"$TP"'fx.demo.stop` — '
  has_line '— нет по таблице зависимостей'
  headers=$(printf '%s\n' "$output" | grep '^### ')
  expected=$(printf '%s\n' '### Новые флоу' '### Изменённые флоу' '### Косвенно затронутые' '### Deprecated-флоу' '### QA-проверки')
  [ "$headers" = "$expected" ]
}

@test "qa-scope: a new planned flow gets its n/a cell and a touched test adds no row" {
  make_repo clean
  sed_file "$REPO/pkg/a/entry_test.go" 's/Name: "y"/Name: "z"/'
  append_line "$REPO/registry.md" '| `'"$TP"'fx.demo.new` | New demo flow | — | planned |'
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 0 ]
  has_text '- `'"$TP"'fx.demo.new` — `planned`'
  row_has '| new | `'"$TP"'fx.demo.new` |' 'n/a — не реализовано'
  lacks_text '`'"$TP"'fx.demo.run`'
  lacks_text '`'"$TP"'fx.demo.stop`'
  lacks_text 'n/a — production-поведение не менялось'
  [ "$(count_lines_with '| `'"$TP"'fx.demo.new` |')" -eq 1 ]
}

@test "qa-scope: a flow touched in both production and tests gets exactly one changed row" {
  make_repo clean
  sed_file "$REPO/pkg/a/entry_test.go" 's/Name: "x"/Name: "q"/'
  sed_file "$REPO/pkg/a/steps.go" 's/empty name/missing name/'
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 0 ]
  [ "$(count_lines_with '| `'"$TP"'fx.demo.run` |')" -eq 1 ]
  row_has '| changed | `'"$TP"'fx.demo.run` |' 'pkg/a/steps.go:11 Verify'
  row_has '| changed | `'"$TP"'fx.demo.run` |' 'TestRun, TestRun_Stop'
  kinds=$(printf '%s\n' "$output" | grep -E '^\| [a-z]+ \| `' | cut -d '|' -f 2 | tr -d ' ' | sort -u)
  [ "$kinds" = "$(printf '%s\n' affected changed)" ]
}

@test "qa-scope: deprecated tombstone gets n/a cells" {
  make_repo clean
  sed_file "$REPO/registry.md" '/fx\.later\.x/ s/\| planned \|/| deprecated |/'
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 0 ]
  has_text '- `'"$TP"'fx.later.x` — '
  row_has '| deprecated | `'"$TP"'fx.later.x` |' 'n/a — tombstone'
}

@test "qa-scope: untagged declarations are listed before the sections and exit 1, report still complete" {
  make_repo clean
  append_line "$REPO/pkg/a/steps.go" 'func helper() {}'
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 1 ]
  has_text '**Непомеченные объявления**'
  has_text 'pkg/a/steps.go:25'
  has_line '### QA-проверки'
  untagged_at=$(printf '%s\n' "$output" | grep -n -F 'Непомеченные объявления' | head -n 1 | cut -d: -f1)
  sections_at=$(printf '%s\n' "$output" | grep -n -F '### Новые флоу' | head -n 1 | cut -d: -f1)
  [ "$untagged_at" -lt "$sections_at" ]
}

@test "qa-scope --head: header names the head revision" {
  make_repo clean
  sed_file "$REPO/pkg/a/steps.go" 's/sum\[:4\]/sum[:8]/'
  commit_head
  run ftags -C "$REPO" qa-scope --base base --head head
  [ "$status" -eq 0 ]
  has_text 'Head: `head`'
}

# =====================================================================================================
# G1: pipe escaping in qa-scope table
# =====================================================================================================

@test "qa-scope: pipes in test names are escaped; every table row has exactly 8 unescaped |" {
  make_repo clean
  # Edit the Run body so that fx.demo.run is changed (it has two tests: TestRun, TestRun_Stop)
  sed_file "$REPO/pkg/a/entry.go" 's/return nil/_ = 1; return nil/'
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 0 ]
  # The evidence cell for fx.demo.run should contain the test command with escaped pipes
  has_text 'TestRun, TestRun_Stop'
  has_text 'go test -race'
  # The pipe between test names in the regex must be escaped
  row_has '| changed |' 'TestRun\|TestRun_Stop'
  # Every table row (starting with |) must have exactly 8 unescaped | (7 cells + borders = 8 pipes)
  table_rows=$(printf '%s\n' "$output" | grep '^| ')
  printf '%s\n' "$table_rows" | while IFS= read -r row; do
    stripped=$(printf '%s' "$row" | sed 's/\\|//g')
    count=$(printf '%s' "$stripped" | awk '{ print gsub(/[|]/, "|") }')
    [ "$count" = "8" ] || { echo "bad row ($count pipes): $row" >&2; exit 1; }
  done
}

@test "qa-scope: shell branch with pipe a|b) is escaped in the table" {
  make_repo clean
  # Replace the up) branch with up|start) to introduce a pipe in a branch name
  sed_file "$REPO/scripts/run.sh" 's/^  up\)/  up|start)/'
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 0 ]
  # The branch name must have its pipe escaped in the table cell
  has_text 'up\|start)'
  # Verify valid table structure: every table row has 8 unescaped pipes
  table_rows=$(printf '%s\n' "$output" | grep '^| ')
  printf '%s\n' "$table_rows" | while IFS= read -r row; do
    stripped=$(printf '%s' "$row" | sed 's/\\|//g')
    count=$(printf '%s' "$stripped" | awk '{ print gsub(/[|]/, "|") }')
    [ "$count" = "8" ] || { echo "bad row ($count pipes): $row" >&2; exit 1; }
  done
}

# =====================================================================================================
# G2: comment-only hunks
# =====================================================================================================

@test "changed: editing only a doc-comment is comment-only and gives no changes" {
  make_repo clean
  # Change only the doc-comment of the Run function
  sed_file "$REPO/pkg/a/entry.go" 's/Run starts the demo flow/Run initiates the demo flow/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  assert_output_is "# no changes"
}

@test "changed: adding a tag line to an existing declaration is comment-only" {
  make_repo clean
  # Add a step-level tag to the Verify function (already has fx.demo.run.verify)
  sed_file "$REPO/pkg/a/steps.go" "s|// ${TP}fx.demo.run.verify|// ${TP}fx.demo.run.verify ${TP}fx.demo.run.check|"
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  assert_output_is "# no changes"
}

@test "changed: comment + code in the same hunk makes the declaration changed" {
  make_repo clean
  # Change both a comment and code in the same function
  sed_file "$REPO/pkg/a/steps.go" 's/Verify checks that the config/Verify validates the config/'
  sed_file "$REPO/pkg/a/steps.go" 's/empty name/missing name/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  row_has "${TP}fx.demo.run${TAB}" "pkg/a/steps.go:11 Verify"
}

@test "changed: comment edit in a test function gives no changes" {
  make_repo clean
  # Change only the doc-comment of the test
  sed_file "$REPO/pkg/a/entry_test.go" 's/TestRun covers the happy path/TestRun covers the basic path/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  assert_output_is "# no changes"
}

@test "check --base: adding a deprecated flow tag is still detected even if comment-only" {
  make_repo clean
  sed_file "$REPO/registry.md" '/fx\.remote\.only/ s/\| done \|/| deprecated |/'
  # Add a tag line for the deprecated flow (a comment-only change)
  printf '%s\n' '' "// ${TP}fx.remote.only.more" '' 'func more() {}' >> "$REPO/pkg/c/remote.go"
  run ftags -C "$REPO" check --base base
  [ "$status" -eq 1 ]
  [ "$(count_class deprecated)" -eq 1 ]
  row_has "deprecated${TAB}pkg/c/remote.go:" "fx.remote.only"
}

@test "changed: an untracked file is always fully changed regardless of content" {
  make_repo clean
  # Create a new file with only comments
  printf '%s\n' 'package b' '' "// ${TP}fx.demo.stop.extra" '' '// extra is a purely doc comment.' 'func extra() {}' > "$REPO/pkg/b/extra.go"
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  has_line "${TP}fx.demo.stop${TAB}pkg/b/extra.go:6 extra"
}

@test "changed: pure blank-line hunk is comment-only" {
  make_repo clean
  # Add a blank line inside the Run function body (escape parens+dot for ERE; {G;} for portable append)
  sed_file "$REPO/pkg/a/entry.go" '/hash\(cfg\.Name\)/{G;}'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  assert_output_is "# no changes"
}

# =====================================================================================================
# G3: via-feature-tag hint
# =====================================================================================================

@test "changed: a touch through a flow-level tag has no via-hint" {
  make_repo clean
  # Edit the body of hash — fx.core.hash has a flow-level tag (3 segments)
  sed_file "$REPO/pkg/a/steps.go" 's/sum\[:4\]/sum[:8]/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  has_line "${TP}fx.core.hash${TAB}pkg/a/steps.go:21 hash"
  lacks_text "через"
}

@test "changed: own and via-feature touches on one flow produce mixed reasons" {
  make_repo clean
  # Touch Config (feature tag fx.demo) -> via-hint on fx.demo.run and fx.demo.stop
  insert_after "$REPO/pkg/a/entry.go" 'Retries int' "${TAB}Timeout int"
  # Also touch Verify (flow tag fx.demo.run.verify) -> own reason on fx.demo.run
  sed_file "$REPO/pkg/a/steps.go" 's/empty name/missing name/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  # fx.demo.run has both an own reason (from Verify) and a via-feature reason (from Config)
  row_has "${TP}fx.demo.run${TAB}" "pkg/a/steps.go:11 Verify"
  row_has "${TP}fx.demo.run${TAB}" "(через ${TP}fx.demo)"
  # fx.demo.stop has only a via-feature reason
  row_has "${TP}fx.demo.stop${TAB}" "(через ${TP}fx.demo)"
}

@test "qa-scope: via-hint appears in the table for feature-level touches" {
  make_repo clean
  insert_after "$REPO/pkg/a/entry.go" 'Retries int' "${TAB}Timeout int"
  run ftags -C "$REPO" qa-scope --base base
  [ "$status" -eq 0 ]
  row_has '| changed |' "(через ${TP}fx.demo)"
  row_has '| affected |' "${TP}fx.demo.run"
}

# =====================================================================================================
# TS AST scanner (scan-ts.mjs)
# Requires Node.js; tests skip gracefully when `node` is not in PATH.
# =====================================================================================================

require_node() {
  command -v node >/dev/null 2>&1 || skip "Node.js not available"
}

@test "ts-scan: fixture emits well-formed D and E records and no V records" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  bad=$(printf '%s\n' "$output" | grep -vE "^[DE]$TAB" || true)
  [ -z "$bad" ]
  badnf=$(printf '%s\n' "$output" | awk -F "$TAB" '($1 == "D" && NF != 8) || ($1 == "E" && NF != 4) { print }')
  [ -z "$badnf" ]
  lacks_text "V$TAB"
}

@test "ts-scan: .d.ts files are excluded" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  lacks_text "types.d.ts"
}

@test "ts-scan: top-level function and const arrow fn are declarations" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  has_text "D${TAB}ts${TAB}src/service.ts${TAB}22${TAB}decl${TAB}prod${TAB}listItems${TAB}${TP}tx.api.list@entry"
  has_text "D${TAB}ts${TAB}src/service.ts${TAB}29${TAB}decl${TAB}prod${TAB}createItem${TAB}${TP}tx.api.create@entry"
}

@test "ts-scan: class members are separate declaration boundaries" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  # Class itself (starts at decorator line per CC-14)
  has_text "D${TAB}ts${TAB}src/handler.ts${TAB}6${TAB}decl${TAB}prod${TAB}ItemController${TAB}${TP}tx.api.list"
  # Methods (start at decorator line when decorated)
  has_text "D${TAB}ts${TAB}src/handler.ts${TAB}10${TAB}decl${TAB}prod${TAB}list${TAB}${TP}tx.api.list"
  has_text "D${TAB}ts${TAB}src/handler.ts${TAB}18${TAB}decl${TAB}prod${TAB}create${TAB}${TP}tx.api.create"
  # Private methods without tags
  has_text "D${TAB}ts${TAB}src/handler.ts${TAB}24${TAB}decl${TAB}prod${TAB}getItems${TAB}-"
  has_text "D${TAB}ts${TAB}src/handler.ts${TAB}28${TAB}decl${TAB}prod${TAB}saveItem${TAB}-"
}

@test "ts-scan: namespace members are separate declaration boundaries" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  has_text "D${TAB}ts${TAB}src/utils.ts${TAB}3${TAB}decl${TAB}prod${TAB}Formatter${TAB}${TP}tx.ns.format@operation"
  has_text "D${TAB}ts${TAB}src/utils.ts${TAB}6${TAB}decl${TAB}prod${TAB}formatDate${TAB}${TP}tx.ns.format"
  has_text "D${TAB}ts${TAB}src/utils.ts${TAB}12${TAB}decl${TAB}prod${TAB}formatAmount${TAB}${TP}tx.ns.format"
}

@test "ts-scan: nested const/let/var inside function body is NOT a declaration" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  # queryStore has `const items` and `const filtered` inside — they must not appear as D records
  lacks_text "${TAB}items${TAB}"
  lacks_text "${TAB}filtered${TAB}"
  # validateInput has `const trimmed` inside — must not appear as a D record
  lacks_text "${TAB}trimmed${TAB}"
  # The functions themselves are declarations
  has_text "queryStore"
  has_text "validateInput"
}

@test "ts-scan: enum is a declaration but members are not boundaries" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  has_text "ValidationRule"
  # Enum members (Required, MinLength, MaxLength) must NOT be separate declarations
  lacks_text "Required"
  lacks_text "MinLength"
  lacks_text "MaxLength"
}

@test "ts-scan: TSX component is a declaration" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  has_text "D${TAB}ts${TAB}src/card.tsx${TAB}5${TAB}decl${TAB}prod${TAB}Card${TAB}${TP}tx.ui.card@entry"
}

@test "ts-scan: interface and type alias are declarations" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  has_text "D${TAB}ts${TAB}src/service.ts${TAB}6${TAB}decl${TAB}prod${TAB}Item${TAB}${TP}tx.api"
  has_text "D${TAB}ts${TAB}src/service.ts${TAB}14${TAB}decl${TAB}prod${TAB}ItemStatus${TAB}${TP}tx.api"
}

@test "ts-scan: test it() and test() calls are recognized" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  has_text "D${TAB}ts${TAB}src/service.test.ts${TAB}6${TAB}test${TAB}test${TAB}lists items for a valid user${TAB}${TP}tx.api.list"
  has_text "D${TAB}ts${TAB}src/service.test.ts${TAB}13${TAB}test${TAB}test${TAB}rejects empty user id${TAB}${TP}tx.api.list ${TP}tx.core.validate"
  has_text "D${TAB}ts${TAB}src/service.test.ts${TAB}19${TAB}test${TAB}test${TAB}validates trimming${TAB}${TP}tx.core.validate"
}

@test "ts-scan: check on lang-ts fixture is clean (exit 0)" {
  require_node
  run ftags -C "$FIX/lang-ts" check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ts-scan: trace shows entry, steps and tests for a flow" {
  require_node
  run ftags -C "$FIX/lang-ts" trace tx.api.list
  [ "$status" -eq 0 ]
  has_text "# entry"
  has_text "listItems"
  has_text "# steps"
  has_text "list"
  has_text "ItemController"
  has_text "# tests"
  has_text "lists items for a valid user"
  has_text "rejects empty user id"
}

@test "ts-scan: tests command returns test names and run command" {
  require_node
  run ftags -C "$FIX/lang-ts" tests tx.api.list
  [ "$status" -eq 0 ]
  has_text "lists items for a valid user"
  has_text "rejects empty user id"
  err_has "npx jest -t"
}

@test "ts-scan: untagged function is reported by changed" {
  require_node
  make_repo lang-ts
  append_line "$REPO/src/service.ts" 'export function helper(): void {}'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 1 ]
  has_line "# untagged"
  has_text "helper"
}

@test "ts-scan: editing untagged class method reports the method, not the class" {
  require_node
  make_repo lang-ts
  # Change the body of the untagged getItems method
  sed_file "$REPO/src/handler.ts" 's/return \[\]/return [{ id: "1" }]/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 1 ]
  has_line "# untagged"
  has_text "getItems"
  # The class itself should NOT be in untagged (it has a tag)
  lacks_text "untagged${TAB}ItemController"
}

@test "ts-scan: editing body of tagged function reports the flow as changed" {
  require_node
  make_repo lang-ts
  sed_file "$REPO/src/service.ts" "s/input\.trim()/input.trim().toLowerCase()/"
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  has_text "${TP}tx.core.validate"
}

@test "ts-scan: comment-only edit (single-line //) gives no changes" {
  require_node
  make_repo lang-ts
  # Edit a // tag comment line: this is a comment-only change
  sed_file "$REPO/src/utils.ts" "s|// ${TP}tx.ns.format@operation|// ${TP}tx.ns.format@operation ${TP}tx.ns.format|"
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  assert_output_is "# no changes"
}

@test "ts-scan: editing code after block comment is detected as changed" {
  require_node
  make_repo lang-ts
  # checkLength has `/* max: 100 */` on the same line as code
  sed_file "$REPO/src/utils.ts" 's/s\.length <= limit/s.length < limit/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  has_text "${TP}tx.core.validate"
}

@test "ts-scan: decorators are part of declaration range (CC-14)" {
  require_node
  run ftags -C "$FIX/lang-ts" scan
  [ "$status" -eq 0 ]
  # @Controller decorator makes the class start at line 6 (decorator line), not line 7 (class keyword)
  has_text "D${TAB}ts${TAB}src/handler.ts${TAB}6${TAB}decl${TAB}prod${TAB}ItemController${TAB}${TP}tx.api.list"
  # @Get decorator on a method — method starts at decorator line
  has_text "D${TAB}ts${TAB}src/handler.ts${TAB}10${TAB}decl${TAB}prod${TAB}list${TAB}${TP}tx.api.list"
  # @Post decorator on a method
  has_text "D${TAB}ts${TAB}src/handler.ts${TAB}18${TAB}decl${TAB}prod${TAB}create${TAB}${TP}tx.api.create"
}

@test "ts-scan: editing a decorator is detected as changed" {
  require_node
  make_repo lang-ts
  # Change the decorator argument: @Controller('/items') -> @Controller('/api/v2/items')
  sed_file "$REPO/src/handler.ts" 's/@Controller.*$/@Controller("\/api\/v2\/items")/'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  has_text "${TP}tx.api.list"
}

@test "ts-scan: editing string literal containing // is detected as changed, not comment-only" {
  require_node
  make_repo lang-ts
  # defaultMessage has `const prefix = "// validation"` — editing the string content
  sed_file "$REPO/src/utils.ts" 's|// validation|// check|'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  has_text "${TP}tx.core.validate"
}

@test "ts-scan: nested const inside function body is not a declaration" {
  require_node
  make_repo lang-ts
  # defaultMessage has `const prefix = ...` inside — editing it should touch the function, not the const
  sed_file "$REPO/src/utils.ts" 's|"// validation"|"## validation"|'
  run ftags -C "$REPO" changed --base base
  [ "$status" -eq 0 ]
  has_line "# changed"
  has_text "${TP}tx.core.validate"
  # The nested const must NOT appear in untagged
  lacks_text "prefix"
}

@test "ts-scan: tag group in file header emits file violation" {
  require_node
  make_repo lang-ts
  # Add a file with a tag group before any declaration (only imports after it)
  cat > "$REPO/src/header-bad.ts" << 'TSEOF'
// #f:tx.api.list

import { Request } from 'express';

export function badHandler(): void {}
TSEOF
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add
  run ftags -C "$REPO" check
  [ "$status" -eq 1 ]
  has_text "file"
  has_text "header-bad.ts"
  has_text "tag group in file header"
}

@test "ts-scan: trailing tag on non-branch line emits placement violation" {
  require_node
  make_repo lang-ts
  cat > "$REPO/src/trailing-bad.ts" << 'TSEOF'
import { Request } from 'express'; // #f:tx.api.list

export function trailingHandler(): void {}
TSEOF
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add
  run ftags -C "$REPO" check
  [ "$status" -eq 1 ]
  has_text "placement"
  has_text "trailing-bad.ts"
  has_text "trailing tag not on a branch line"
}

@test "ts-scan: unbound tag group after last declaration emits placement violation" {
  require_node
  make_repo lang-ts
  cat > "$REPO/src/orphan-bad.ts" << 'TSEOF'
export function orphanHandler(): void {}

// #f:tx.api.list
TSEOF
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add
  run ftags -C "$REPO" check
  [ "$status" -eq 1 ]
  has_text "placement"
  has_text "orphan-bad.ts"
  has_text "tag group not followed by a declaration"
}

@test "ts-scan: second blank line between tag group and declaration breaks the link (F11)" {
  require_node
  make_repo lang-ts
  cat > "$REPO/src/double-blank.ts" << 'TSEOF'
// #f:tx.api.list@entry


export function doubleBlank(): void {}
TSEOF
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m add
  run ftags -C "$REPO" scan
  # Tag group should NOT be bound to the declaration
  has_text "placement"
  has_text "second blank line breaks the link"
  # The declaration should appear as untagged (no tags)
  run ftags -C "$REPO" check
  [ "$status" -eq 1 ]
}

@test "ts-scan: slash-prefixed TEST_FILES glob classifies test file correctly (F9)" {
  require_node
  # Verify that buildTestMatchers handles /-prefixed globs (JS slice(1), not slice(2)).
  make_repo lang-ts
  lst="$BATS_TEST_TMPDIR/filelist"
  printf 'src/service.test.ts\n' > "$lst"
  # Use a /-prefixed exact-path glob: should match full path src/service.test.ts
  run bash -c "cd '$REPO' && FTAGS_LIST='$lst' FTAGS_LANG=ts TEST_FILES='/src/service.test.ts' COMMENT='//' node '$TOOL/scan-ts.mjs'" 2>"$ERR"
  [ "$status" -eq 0 ]
  # Output must classify file as test side, not prod
  has_text "test"
  lacks_text "prod"
}

@test "ts-scan: POSIX [[:space:]] in BRANCH_RE is converted to JS equivalent (F12)" {
  require_node
  # BRANCH_RE in ts.conf uses POSIX character classes; compileRE must convert them
  # to JS equivalents so that branch trailing tags are detected, not lost as placement.
  make_repo lang-ts
  run ftags -C "$REPO" scan
  [ "$status" -eq 0 ]
  # router.ts contains case/default trailing tags -- they must emit branch D-records
  has_line "D${TAB}ts${TAB}src/router.ts${TAB}7${TAB}branch${TAB}prod${TAB}case 'list':${TAB}${TP}tx.api.list"
  has_line "D${TAB}ts${TAB}src/router.ts${TAB}10${TAB}branch${TAB}prod${TAB}case 'create':${TAB}${TP}tx.api.create"
  has_line "D${TAB}ts${TAB}src/router.ts${TAB}13${TAB}branch${TAB}prod${TAB}default:${TAB}${TP}tx.core.validate"
}

@test "ts-scan: trailing tag on valid branch line gives no placement violation (F12)" {
  require_node
  # Without POSIX-to-JS conversion, branch tags would emit false placement violations.
  make_repo lang-ts
  run ftags -C "$REPO" check
  [ "$status" -eq 0 ]
  # No placement violations should reference router.ts
  lacks_text "router.ts"
}

@test "ts-scan: 3 levels of describe nesting finds all tests (F14)" {
  require_node
  # processTestBlock depth limit must support at least 3 levels of describe nesting,
  # which is an idiomatic Jest/Vitest pattern.
  make_repo lang-ts
  cat > "$REPO/src/deep.test.ts" << 'TSEOF'
import { listItems } from './service';

describe('Level 1', () => {
  // #f:tx.api.list

  it('L1 test', async () => {
    const items = await listItems('user-1');
    expect(items).toBeDefined();
  });

  describe('Level 2', () => {
    it('L2 test', () => {
      expect(true).toBe(true);
    });

    describe('Level 3', () => {
      it('L3 test', () => {
        expect(true).toBe(true);
      });
    });
  });
});
TSEOF
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m 'add deep test'
  run ftags -C "$REPO" scan
  [ "$status" -eq 0 ]
  has_text "L1 test"
  has_text "L2 test"
  has_text "L3 test"
}

