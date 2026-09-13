#!/bin/bash
# ftags -- feature-hashtag tracing tool.
# bash 3.2 + POSIX awk + grep + sed + git. No build step; lives in tool/.
# Run `ftags.sh help` for the command list. Contract: spec.md (repository root).
set -euo pipefail
export LC_ALL=C

TAB=$'\t'
TP='#''f:'
TOOL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ftags.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

CONF_KEYS='REG LANGS EXCLUDE NOSTART_IGNORE'
PROFILE_KEYS='NAME FILES EXCLUDE COMMENT GAP_RE SCANNER DECL_RE TAG_TARGET_RE DECL_NAME_STRIP FLOW_DECL_RE FEAT_DECL_RE BRANCH_RE FIELD_OPEN_RE FIELD_CLOSE_RE HEADER_RE TEST_FILES TEST_RE TEST_NAME_STRIP TEST_NAME_END RUN_CMD RUN_JOIN EVIDENCE_CMD'

OPT_LANG=
REPO_ROOT=
CONF_REG=
CONF_LANGS=
CONF_EXCLUDE=
CONF_NOSTART_IGNORE=
ACTIVE_LANGS=
LANGS_TSV=
SCAN_N=0
REG_FILES=()
REG_ROOT=
REG_BASE_REV=
REG_HEAD_REV=
REGDIFF=0
REG_LABEL=

die() {
  printf 'ftags: %s\n' "$*" >&2
  exit 2
}

warn() {
  printf 'ftags: %s\n' "$*" >&2
}

awkrun() {
  ${FTAGS_AWK:-awk} "$@"
}

usage() {
  cat <<EOF
usage: ftags.sh [-C <dir>] [--lang <name>] <command> [args]

  trace <flow>                         flow declarations: @entry, @operation, steps (@recv marked), tests; by file
  entries [<flow>]                     external starts (@entry) only
  operations [<flow>]                  operation starts (@operation) only
  check [--base <rev>] [--reg-base <rev>]
                                       static integrity; with --base also new tags/edges on deprecated flows
  tests <flow>                         test names (stdout) and the run command (stderr); exit 1 when nothing is found
  changed --base <rev> [--head <rev>] [--reg-base <rev>]
                                       new/changed/affected/deprecated flows and untagged declarations
  qa-scope --base <rev> [--head <rev>] [--reg-base <rev>]
                                       Markdown QA scope
  scan                                 debug dump of scanner records (TSV)
  help | --help | -h

<flow> may be given with or without the tag prefix; a marker suffix is ignored.
Config: .ftags.conf searched from the current directory upwards. Env: FTAGS_AWK (default awk).
EOF
}

# parse_kv FILE ALLOWED_KEYS PREFIX -- declarative KEY=VALUE parser shared by .ftags.conf and
# language profiles. Never sources the file. Sets <PREFIX><KEY> variables; KV_SEEN lists the keys read.
parse_kv() {
  local file=$1 allowed=$2 prefix=$3 line stripped key val
  KV_SEEN=
  [ -f "$file" ] || die "config not found: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line#"${line%%[![:space:]]*}"}
    case $stripped in
      '' | '#'*) continue ;;
      *=*) ;;
      *) die "$file: expected KEY=VALUE, got: $line" ;;
    esac
    key=${stripped%%=*}
    val=${stripped#*=}
    case $key in
      '' | *[!A-Z_]*) die "$file: bad key: $key" ;;
    esac
    case " $allowed " in
      *" $key "*) ;;
      *) die "$file: unknown key $key" ;;
    esac
    case $val in
      \'*\')
        val=${val#\'}
        val=${val%\'}
        case $val in *\'*) die "$file: quote inside quoted value of $key" ;; esac
        ;;
      \"*\")
        val=${val#\"}
        val=${val%\"}
        case $val in *\"*) die "$file: quote inside quoted value of $key" ;; esac
        ;;
      *) val=${val%"${val##*[![:space:]]}"} ;;
    esac
    printf -v "$prefix$key" '%s' "$val"
    KV_SEEN="$KV_SEEN $key"
  done <"$file"
}

# find_conf -- print the directory holding .ftags.conf, searching upwards from cwd.
find_conf() {
  local d
  d=$(pwd -P)
  while :; do
    if [ -f "$d/.ftags.conf" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    [ "$d" = / ] && return 1
    d=$(dirname "$d")
  done
}

# load_conf -- locate and parse .ftags.conf, chdir to REPO_ROOT, resolve the active profiles.
load_conf() {
  local l found
  REPO_ROOT=$(find_conf) || die "no .ftags.conf found from $(pwd -P) upwards"
  cd "$REPO_ROOT"
  CONF_REG=
  CONF_LANGS=
  CONF_EXCLUDE=
  CONF_NOSTART_IGNORE=
  parse_kv "$REPO_ROOT/.ftags.conf" "$CONF_KEYS" CONF_
  [ -n "$CONF_REG" ] || CONF_REG=features.md
  [ -n "$CONF_LANGS" ] || die ".ftags.conf: LANGS is required"
  if [ -n "$OPT_LANG" ]; then
    found=0
    for l in $CONF_LANGS; do
      [ "$l" = "$OPT_LANG" ] && found=1
    done
    [ "$found" = 1 ] || die "--lang $OPT_LANG is not in LANGS ($CONF_LANGS)"
    ACTIVE_LANGS=$OPT_LANG
  else
    ACTIVE_LANGS=$CONF_LANGS
  fi
  LANGS_TSV=$TMP/langs.tsv
  : >"$LANGS_TSV"
  for l in $ACTIVE_LANGS; do
    load_profile "$l"
    printf '%s\t%s\t%s\t%s\n' "$l" "$P_RUN_CMD" "$P_RUN_JOIN" "$P_EVIDENCE_CMD" >>"$LANGS_TSV"
  done
}

# load_profile NAME -- parse langs/NAME.conf into P_* variables.
# Every key in PROFILE_KEYS is required except SCANNER (optional, default empty).
load_profile() {
  local name=$1 file k
  file=$TOOL_DIR/langs/$name.conf
  [ -f "$file" ] || die "unknown language profile: $name ($file)"
  for k in $PROFILE_KEYS; do
    printf -v "P_$k" '%s' ''
  done
  parse_kv "$file" "$PROFILE_KEYS" P_
  for k in $PROFILE_KEYS; do
    case " $KV_SEEN " in
      *" $k "*) ;;
      *) case $k in SCANNER) ;; *) die "$file: missing key $k" ;; esac ;;
    esac
  done
  [ -n "$P_COMMENT" ] || die "$file: COMMENT is empty"
  [ -n "$P_FILES" ] || die "$file: FILES is empty"
}

# list_all_files ROOT OUT -- regular files under ROOT (git listing when possible), relative, sorted.
list_all_files() {
  local root=$1 out=$2 f
  (
    cd "$root"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -c core.quotePath=false ls-files -co --exclude-standard
    else
      find . -path ./.git -prune -o -type f -print | sed -e 's|^\./||'
    fi
  ) | while IFS= read -r f; do
    if [ -n "$f" ] && [ -f "$root/$f" ] && [ ! -L "$root/$f" ]; then
      printf '%s\n' "$f"
    fi
  done | sort >"$out"
}

# filter_files LIST INC_MASKS EXC_MASKS OUT -- apply gitignore-like masks (contract glob semantics).
filter_files() {
  local list=$1 out=$4
  export FTAGS_INC=$2 FTAGS_EXC=$3
  awkrun '
    function glob2ere(g,    i, c, o) {
      o = ""
      for (i = 1; i <= length(g); i++) {
        c = substr(g, i, 1)
        if (c == "*") o = o ".*"
        else if (c == "?") o = o "."
        else if (index(".+()[]{}^$|\\", c) > 0) o = o "\\" c
        else o = o c
      }
      return o
    }
    function mkre(g) {
      if (index(g, "/") == 0) return "B^" glob2ere(g) "$"
      if (substr(g, 1, 1) == "/") return "P^" glob2ere(substr(g, 2)) "$"
      return "P(^|/)" glob2ere(g) "$"
    }
    BEGIN {
      ni = split(ENVIRON["FTAGS_INC"], im, " ")
      for (i = 1; i <= ni; i++) { r = mkre(im[i]); IK[i] = substr(r, 1, 1); IR[i] = substr(r, 2) }
      ne = split(ENVIRON["FTAGS_EXC"], em, " ")
      for (i = 1; i <= ne; i++) { r = mkre(em[i]); EK[i] = substr(r, 1, 1); ER[i] = substr(r, 2) }
    }
    {
      f = $0; b = f; sub(/^.*\//, "", b)
      ok = 0
      for (i = 1; i <= ni; i++) if ((IK[i] == "B" ? b : f) ~ IR[i]) { ok = 1; break }
      if (!ok) next
      for (i = 1; i <= ne; i++) if ((EK[i] == "B" ? b : f) ~ ER[i]) next
      print f
    }
  ' "$list" >"$out"
}

# scan_list ROOT LIST OUT -- scan the listed files (paths relative to ROOT) with every active profile;
# appends scanner records (contract section 5) to OUT.
scan_list() {
  local root=$1 list=$2 out=$3 lang lst
  for lang in $ACTIVE_LANGS; do
    load_profile "$lang"
    SCAN_N=$((SCAN_N + 1))
    lst=$TMP/list.$lang.$SCAN_N
    filter_files "$list" "$P_FILES" "$P_EXCLUDE $CONF_EXCLUDE" "$lst"
    [ -s "$lst" ] || continue
    if [ -n "$P_SCANNER" ]; then
      # AST scanner: dispatch to external program (e.g. node scan-ts.mjs)
      (
        cd "$root"
        export FTAGS_LIST="$lst" FTAGS_LANG="$lang"
        export COMMENT="$P_COMMENT" TEST_FILES="$P_TEST_FILES"
        export BRANCH_RE="$P_BRANCH_RE" HEADER_RE="$P_HEADER_RE"
        export FLOW_DECL_RE="$P_FLOW_DECL_RE" FEAT_DECL_RE="$P_FEAT_DECL_RE"
        export FIELD_OPEN_RE="$P_FIELD_OPEN_RE" FIELD_CLOSE_RE="$P_FIELD_CLOSE_RE"
        node "$TOOL_DIR/$P_SCANNER"
      ) >>"$out" || die "scanner $P_SCANNER failed for profile $lang"
    else
      # regex scanner: POSIX awk
      (
        cd "$root"
        unset FTAGS_TEST_FILES_RE
        export FTAGS_LIST="$lst" FTAGS_LANG="$lang"
        export NAME="$P_NAME" COMMENT="$P_COMMENT" GAP_RE="$P_GAP_RE" DECL_RE="$P_DECL_RE"
        export TAG_TARGET_RE="$P_TAG_TARGET_RE" DECL_NAME_STRIP="$P_DECL_NAME_STRIP"
        export FLOW_DECL_RE="$P_FLOW_DECL_RE" FEAT_DECL_RE="$P_FEAT_DECL_RE" BRANCH_RE="$P_BRANCH_RE"
        export FIELD_OPEN_RE="$P_FIELD_OPEN_RE" FIELD_CLOSE_RE="$P_FIELD_CLOSE_RE" HEADER_RE="$P_HEADER_RE"
        export TEST_FILES="$P_TEST_FILES" TEST_RE="$P_TEST_RE"
        export TEST_NAME_STRIP="$P_TEST_NAME_STRIP" TEST_NAME_END="$P_TEST_NAME_END"
        ${FTAGS_AWK:-awk} -f "$TOOL_DIR/scan.awk"
      ) >>"$out"
    fi
  done
}

# scan_tree ROOT OUT -- scan every profile file under ROOT.
scan_tree() {
  local root=$1 out=$2 all
  SCAN_N=$((SCAN_N + 1))
  all=$TMP/all.$SCAN_N
  list_all_files "$root" "$all"
  : >"$out"
  scan_list "$root" "$all" "$out"
}

# expand_reg -- resolve REG (file or glob, relative to REPO_ROOT) into REG_FILES.
expand_reg() {
  local f
  REG_FILES=()
  for f in $CONF_REG; do
    [ -f "$f" ] && REG_FILES+=("$f")
  done
  [ ${#REG_FILES[@]} -gt 0 ] || die "no registry files match REG=$CONF_REG (from $REPO_ROOT)"
}

# parse_registry CONTENT_FILE DISPLAY_NAME OUT -- markdown registry tables -> F/X records:
#   F <tag> <status> <desc> <spec> <file> <line>   flow row (last non-empty column is a status)
#   X <consumer> <used> <file> <line>              dependency edge
parse_registry() {
  local content=$1 out=$3
  export FTAGS_FILE=$2
  awkrun -v TP="$TP" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function col(s) { gsub(/\t/, " ", s); return (s == "") ? "-" : s }
    BEGIN { FILE = ENVIRON["FTAGS_FILE"]; TPRE = TP "[a-z0-9.]+" }
    $0 !~ /^\|/ { next }
    {
      n = split($0, c, "|")
      t = trim(c[2])
      if (index(t, "`" TP) != 1) next
      gsub(/[`[:space:]]/, "", t)
      tag = substr(t, 4)
      st = ""
      for (i = n; i >= 2; i--) { s = trim(c[i]); if (s != "") { st = s; break } }
      if (st ~ /^(planned|partial|done|deprecated)$/) {
        printf "F\t%s\t%s\t%s\t%s\t%s\t%d\n", tag, st, col(trim(c[3])), col(trim(c[4])), FILE, NR
        next
      }
      d = c[3]
      if (index(d, TP) == 0) next
      while (match(d, TPRE)) {
        printf "X\t%s\t%s\t%s\t%d\n", tag, substr(d, RSTART + 3, RLENGTH - 3), FILE, NR
        d = substr(d, RSTART + RLENGTH)
      }
    }
  ' "$content" >>"$out"
}

# read_registry OUT -- parse the working-tree registry files into OUT.
read_registry() {
  local out=$1 f
  expand_reg
  : >"$out"
  for f in ${REG_FILES[@]+"${REG_FILES[@]}"}; do
    parse_registry "$f" "$f" "$out"
  done
}

# reg_relpath FILE -- path of a registry file relative to REG_ROOT.
reg_relpath() {
  local abs
  abs=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  printf '%s\n' "${abs#"$REG_ROOT/"}"
}

# read_registry_at REV OUT -- parse the registry files as of REV in the registry git repository;
# a file missing at REV counts as an empty registry.
read_registry_at() {
  local rev=$1 out=$2 f n=0 tmpf
  : >"$out"
  for f in ${REG_FILES[@]+"${REG_FILES[@]}"}; do
    n=$((n + 1))
    tmpf=$TMP/reg.$rev.$n.md
    if ! git -C "$REG_ROOT" show "$rev:$(reg_relpath "$f")" >"$tmpf" 2>/dev/null; then
      : >"$tmpf"
    fi
    parse_registry "$tmpf" "$f" "$out"
  done
}

# resolve_reg_base BASE HEAD REGBASE -- decide which revision of the registry is the base:
# --reg-base wins; same git repository as the code -> BASE (and HEAD); otherwise HEAD of the
# registry repository; registry outside git -> registry diff is skipped (REGDIFF=0).
resolve_reg_base() {
  local base=$1 head=$2 regbase=$3 coderoot d f
  expand_reg
  d=$(cd "$(dirname "${REG_FILES[0]}")" && pwd -P)
  REG_ROOT=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)
  coderoot=$(git rev-parse --show-toplevel 2>/dev/null || true)
  REG_BASE_REV=
  REG_HEAD_REV=
  REGDIFF=0
  REG_LABEL=
  if [ -z "$REG_ROOT" ]; then
    warn "registry $CONF_REG is not in a git repository; registry diff skipped"
    REG_LABEL='n/a (registry not in git)'
    return 0
  fi
  if [ -n "$regbase" ]; then
    REG_BASE_REV=$regbase
  elif [ "$REG_ROOT" = "$coderoot" ]; then
    REG_BASE_REV=$base
    REG_HEAD_REV=$head
  else
    REG_BASE_REV=HEAD
  fi
  git -C "$REG_ROOT" rev-parse --verify --quiet "$REG_BASE_REV^{commit}" >/dev/null 2>&1 \
    || die "registry base revision not found in $REG_ROOT: $REG_BASE_REV"
  REGDIFF=1
  for f in ${REG_FILES[@]+"${REG_FILES[@]}"}; do
    REG_LABEL="${REG_LABEL:+$REG_LABEL, }$f@$REG_BASE_REV"
  done
}

# load_registries BASE HEAD REGBASE -- reg_head.tsv (head registry) and reg_base.tsv (base registry).
load_registries() {
  resolve_reg_base "$1" "$2" "$3"
  if [ -n "$REG_HEAD_REV" ]; then
    read_registry_at "$REG_HEAD_REV" "$TMP/reg_head.tsv"
  else
    read_registry "$TMP/reg_head.tsv"
  fi
  : >"$TMP/reg_base.tsv"
  if [ "$REGDIFF" = 1 ]; then
    read_registry_at "$REG_BASE_REV" "$TMP/reg_base.tsv"
  fi
}

# require_git -- the code repository must be a git work tree.
require_git() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $REPO_ROOT"
}

# build_combined_gap -- collect GAP_RE from every active profile into a single ERE
# for comment-only hunk detection. Empty if no profile has a GAP_RE.
build_combined_gap() {
  local l combined=""
  for l in $ACTIVE_LANGS; do
    load_profile "$l"
    [ -n "$P_GAP_RE" ] || continue
    combined="${combined:+$combined|}$P_GAP_RE"
  done
  printf '%s' "$combined"
}

# git_diff_ranges BASE HEAD -- run the strict git diff and derive:
#   ranges: N <path> <c> <d> [C] (new side), O <oldpath> <a> <b> <newpath> [C] (old side), W <path> (untracked)
#     C suffix marks a comment-only hunk (CC-1): every changed line is blank or matches GAP_RE.
#   added:  A <path> <line> <tag> for every tag token on an added line
git_diff_ranges() {
  local base=$1 head=$2
  require_git
  if ! git -c core.quotePath=false diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
    --relative -U0 "$base" ${head:+"$head"} -- >"$TMP/diff" 2>"$TMP/git.err"; then
    die "$(cat "$TMP/git.err")"
  fi
  export FTAGS_RANGES=$TMP/ranges FTAGS_ADDED=$TMP/added
  export FTAGS_COMBINED_GAP=$(build_combined_gap)
  awkrun -v TP="$TP" '
    # Flush a pending hunk: emit its buffered range records, appending C if comment-only.
    function flush_hunk(    co) {
      if (!h_pending) return
      co = (h_has_code == 0) ? "\tC" : ""
      if (h_o != "") print h_o co > RANGES
      if (h_n != "") print h_n co > RANGES
      h_pending = 0; h_has_code = 0; h_o = ""; h_n = ""
    }
    BEGIN {
      TPRE = TP "[a-z0-9.]+"; state = 0
      RANGES = ENVIRON["FTAGS_RANGES"]; ADDED = ENVIRON["FTAGS_ADDED"]
      GAPRE = ENVIRON["FTAGS_COMBINED_GAP"]
      h_pending = 0; h_has_code = 0; h_o = ""; h_n = ""
    }
    /^diff --git / { flush_hunk(); state = 1; oldp = "-"; newp = "-"; next }
    state == 1 && /^--- / {
      oldp = substr($0, 5); sub(/\t.*$/, "", oldp)
      if (oldp == "/dev/null") oldp = "-"; else sub(/^a\//, "", oldp)
      state = 2; next
    }
    state == 2 && /^\+\+\+ / {
      newp = substr($0, 5); sub(/\t.*$/, "", newp)
      if (newp == "/dev/null") newp = "-"; else sub(/^b\//, "", newp)
      state = 3; next
    }
    state >= 3 && /^@@ / {
      flush_hunk()
      if (!match($0, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/)) next
      h = substr($0, 4, RLENGTH - 6)
      split(h, parts, " ")
      na = split(substr(parts[1], 2), ab, ","); a = ab[1]; b = (na > 1) ? ab[2] : 1
      nc = split(substr(parts[2], 2), cd, ","); c = cd[1]; d = (nc > 1) ? cd[2] : 1
      h_pending = 1; h_has_code = 0; h_o = ""; h_n = ""
      if (oldp != "-" && b > 0) h_o = sprintf("O\t%s\t%d\t%d\t%s", oldp, a, b, newp)
      if (newp != "-") {
        if (d == 0) h_n = sprintf("N\t%s\t%d\t%d", newp, (c == 0) ? 1 : c, 1)
        else h_n = sprintf("N\t%s\t%d\t%d", newp, c, d)
      }
      cur = c; state = 4; next
    }
    state == 4 && /^\+/ {
      s = substr($0, 2)
      while (match(s, TPRE)) {
        printf "A\t%s\t%d\t%s\n", newp, cur, substr(s, RSTART, RLENGTH) > ADDED
        s = substr(s, RSTART + RLENGTH)
      }
      sl = substr($0, 2)
      if (sl !~ /^[[:space:]]*$/ && (GAPRE == "" || sl !~ GAPRE)) h_has_code = 1
      cur++; next
    }
    state == 4 && /^-/ {
      sl = substr($0, 2)
      if (sl !~ /^[[:space:]]*$/ && (GAPRE == "" || sl !~ GAPRE)) h_has_code = 1
      next
    }
    state == 4 && /^ / { cur++; next }
    END { flush_hunk() }
  ' "$TMP/diff"
  touch "$TMP/ranges" "$TMP/added"
  if [ -z "$head" ]; then
    git -c core.quotePath=false ls-files --others --exclude-standard | while IFS= read -r f; do
      if [ -n "$f" ] && [ -f "$f" ] && [ ! -L "$f" ]; then
        printf '%s\n' "$f"
      fi
    done >"$TMP/untracked"
    if [ -s "$TMP/untracked" ]; then
      export FTAGS_LIST=$TMP/untracked
      awkrun -v TP="$TP" '
        BEGIN {
          TPRE = TP "[a-z0-9.]+"; RANGES = ENVIRON["FTAGS_RANGES"]; ADDED = ENVIRON["FTAGS_ADDED"]
          while ((getline f < ENVIRON["FTAGS_LIST"]) > 0) {
            if (f == "") continue
            printf "W\t%s\n", f >> RANGES
            n = 0
            while ((getline l < f) > 0) {
              n++; s = l
              while (match(s, TPRE)) {
                printf "A\t%s\t%d\t%s\n", f, n, substr(s, RSTART, RLENGTH) >> ADDED
                s = substr(s, RSTART + RLENGTH)
              }
            }
            close(f)
          }
        }
      ' </dev/null
    fi
  fi
}

# materialize_base BASE -- old side of the diff: `git show BASE:./<oldpath>` into TMP/base/<oldpath>,
# list of relative paths in TMP/oldlist.
materialize_base() {
  local base=$1 p
  : >"$TMP/oldlist"
  [ -s "$TMP/ranges" ] || return 0
  awkrun -F '\t' '$1 == "O" && !($2 in seen) { seen[$2] = 1; print $2 }' "$TMP/ranges" | while IFS= read -r p; do
    mkdir -p "$TMP/base/$(dirname "$p")"
    if git show "$base:./$p" >"$TMP/base/$p" 2>/dev/null; then
      printf '%s\n' "$p"
    fi
  done >"$TMP/oldlist"
}

# materialize_head HEAD -- whole tree at HEAD (relative to REPO_ROOT) into TMP/head.
materialize_head() {
  local head=$1 top prefix
  top=$(git rev-parse --show-toplevel)
  prefix=$(git rev-parse --show-prefix)
  mkdir -p "$TMP/head"
  if ! git -C "$top" archive --format=tar "$head:$prefix" 2>"$TMP/git.err" | tar -xf - -C "$TMP/head"; then
    die "$(cat "$TMP/git.err")"
  fi
}

# categorize -- code diff + both scans + registry diff -> categories with reasons and untagged declarations:
#   C <prio> <cat> <flow> <reasons>     cat: deprecated|new|changed|affected (checks.md, QA scope vocabulary)
#   U <file> <line> <kind> <name> <flag> flag: - | (base)
# Reverse transitive closure over the dependency table gives affected flows with their chain.
# Only the production side of the diff categorizes: an edit confined to test declarations gives
# no category at all, while an untagged test declaration is still reported.
categorize() {
  local l
  export HEAD_TSV=$TMP/head.tsv BASE_TSV=$TMP/base.tsv RANGES=$TMP/ranges
  export REG_HEAD=$TMP/reg_head.tsv REG_BASE=$TMP/reg_base.tsv REGDIFF
  for l in $ACTIVE_LANGS; do
    load_profile "$l"
    export "FTAGS_GAP_$l=$P_GAP_RE"
  done
  awkrun -v TP="$TP" '
    function flow_of(t,    p, n, a) {
      if (index(t, TP) == 1) t = substr(t, 4)
      p = index(t, "@"); if (p) t = substr(t, 1, p - 1)
      n = split(t, a, "."); if (n > 3) t = a[1] "." a[2] "." a[3]
      return t
    }
    function nseg(t,    a) { return split(t, a, ".") }
    function add(arr, cnt, k, v) {
      if (k in arr) {
        if (index("; " arr[k] "; ", "; " v "; ") > 0) return
        arr[k] = arr[k] "; " v
      } else arr[k] = v
      cnt[k]++
    }
    function limit(s, n,    parts, m, i, out) {
      if (n <= 5) return s
      m = split(s, parts, "; ")
      out = parts[1]
      for (i = 2; i <= 5 && i <= m; i++) out = out "; " parts[i]
      return out " +" (n - 5)
    }
    function isort(arr, n,    i, j, v) {
      for (i = 2; i <= n; i++) { v = arr[i]; j = i - 1; while (j >= 1 && arr[j] > v) { arr[j + 1] = arr[j]; j-- } arr[j + 1] = v }
    }
    function sorted_set(s,    n, a, i, out) {
      n = split(s, a, " "); isort(a, n); out = ""
      for (i = 1; i <= n; i++) out = out " " a[i]
      return out
    }
    function load_lines(path, key,    l, n) {
      n = 0
      while ((getline l < path) > 0) { n++; LN[key, n] = l }
      close(path); LNN[key] = n
    }
    function decl_start(root, file, line, lang,    key, i, l, gap, start) {
      key = root SUBSEP file
      if (!(key in LNN)) load_lines(root "/" file, key)
      gap = ENVIRON["FTAGS_GAP_" lang]
      start = line
      for (i = line - 1; i >= 1; i--) {
        l = LN[key, i]
        if (l ~ /^[[:space:]]*$/) continue
        if (gap != "" && l ~ gap) { if (index(l, TP) > 0) { start = i; break } continue }
        break
      }
      return start
    }
    function load_ranges(path,    l, f) {
      while ((getline l < path) > 0) {
        split(l, f, "\t")
        if (f[1] == "N") { NRN[f[2]]++; NA[f[2], NRN[f[2]]] = f[3]; NB[f[2], NRN[f[2]]] = f[3] + f[4] - 1; if (f[5] == "C") NCO[f[2], NRN[f[2]]] = 1 }
        else if (f[1] == "W") WH[f[2]] = 1
        else if (f[1] == "O") { ORN[f[2]]++; OA[f[2], ORN[f[2]]] = f[3]; OB[f[2], ORN[f[2]]] = f[3] + f[4] - 1; ONEW[f[2]] = f[5]; if (f[6] == "C") OCO[f[2], ORN[f[2]]] = 1 }
      }
      close(path)
    }
    function affected(isbase, file, s, e,    i, n) {
      if (isbase) {
        n = ORN[file]
        for (i = 1; i <= n; i++) if (OA[file, i] <= e && OB[file, i] >= s && !OCO[file, i]) return 1
        return 0
      }
      if (file in WH) return 1
      n = NRN[file]
      for (i = 1; i <= n; i++) if (NA[file, i] <= e && NB[file, i] >= s && !NCO[file, i]) return 1
      return 0
    }
    function load_reg(path, isbase,    l, f, key) {
      while ((getline l < path) > 0) {
        split(l, f, "\t")
        if (f[1] == "F") {
          if (isbase) { BS[f[2]] = f[3]; BD[f[2]] = f[4]; BP[f[2]] = f[5] }
          else { if (!(f[2] in HS)) HT[++nht] = f[2]; HS[f[2]] = f[3]; HD[f[2]] = f[4]; HP[f[2]] = f[5] }
        } else if (f[1] == "X") {
          key = f[2] SUBSEP f[3]
          if (isbase) { if (!(key in BEK)) { BEK[key] = 1; BE[f[2]] = BE[f[2]] " " f[3] } }
          else if (!(key in HEK)) { HEK[key] = 1; HE[f[2]] = HE[f[2]] " " f[3]; CONS[f[3]] = CONS[f[3]] " " f[2] }
        }
      }
      close(path)
    }
    function touch(isbase, f, reason, name) {
      if (isbase) { if ((ONEW[CFILE] SUBSEP name SUBSEP f) in HSEEN) return }
      else HSEEN[CFILE SUBSEP name SUBSEP f] = 1
      add(CHANGED, CHC, f, reason)
      HASCODE[f] = 1
    }
    function handle(isbase, i,    n, t, j, f, reason, ns, k) {
      if (ct[i] == "-") {
        if (ck[i] == "branch") return
        if (isbase) {
          if (ONEW[CFILE] != "-" && ((ONEW[CFILE] SUBSEP cnm[i]) in HN)) return
          printf "U\t%s\t%d\t%s\t%s\t(base)\n", CFILE, cl[i], ck[i], cnm[i]
        } else printf "U\t%s\t%d\t%s\t%s\t-\n", CFILE, cl[i], ck[i], cnm[i]
        return
      }
      # A touched test declaration changes no production behaviour: it carries no category.
      if (cs[i] != "prod") return
      reason = CFILE ":" cl[i] " " cnm[i]
      if (isbase) reason = reason " (base)"
      n = split(ct[i], t, " ")
      for (j = 1; j <= n; j++) {
        f = flow_of(t[j]); ns = nseg(f)
        if (ns < 2) continue
        if (ns == 2) {
          via_reason = reason " (\321\207\320\265\321\200\320\265\320\267 " TP f ")"
          for (k = 1; k <= nht; k++)
            if (index(HT[k], f ".") == 1 && nseg(HT[k]) == 3 && (HS[HT[k]] == "partial" || HS[HT[k]] == "done"))
              touch(isbase, HT[k], via_reason, cnm[i])
          continue
        }
        touch(isbase, f, reason, cnm[i])
      }
    }
    function flush_file(isbase,    i, j, e) {
      for (i = 1; i <= cn; i++)
        cst[i] = (ck[i] != "branch" && ct[i] != "-") ? decl_start(isbase ? ENVIRON["BROOT"] : ENVIRON["HROOT"], CFILE, cl[i], clg[i]) : cl[i]
      for (i = 1; i <= cn; i++) {
        if (ck[i] == "branch") e = cl[i]
        else {
          e = NLINES
          for (j = i + 1; j <= cn; j++) if (ck[j] != "branch") { e = cst[j] - 1; break }
        }
        if (affected(isbase, CFILE, cst[i], e)) handle(isbase, i)
      }
      cn = 0
    }
    function stream(path, isbase,    l, f) {
      cn = 0; CFILE = ""
      while ((getline l < path) > 0) {
        split(l, f, "\t")
        if (f[1] == "D") {
          CFILE = f[3]
          cn++; clg[cn] = f[2]; cl[cn] = f[4]; ck[cn] = f[5]; cs[cn] = f[6]; cnm[cn] = f[7]; ct[cn] = f[8]
          if (!isbase && f[5] != "branch") HN[f[3] SUBSEP f[7]] = 1
        } else if (f[1] == "E") {
          CFILE = f[3]; NLINES = f[4]
          flush_file(isbase)
          cn = 0
        }
      }
      close(path)
    }
    BEGIN {
      nht = 0
      load_reg(ENVIRON["REG_HEAD"], 0)
      if (ENVIRON["REGDIFF"] == "1") load_reg(ENVIRON["REG_BASE"], 1)
      load_ranges(ENVIRON["RANGES"])
      stream(ENVIRON["HEAD_TSV"], 0)
      stream(ENVIRON["BASE_TSV"], 1)
      if (ENVIRON["REGDIFF"] == "1") {
        for (k = 1; k <= nht; k++) {
          t = HT[k]
          if (nseg(t) != 3) continue
          if (!(t in BS)) {
            if (HS[t] == "deprecated") DEPREC[t] = "status -> deprecated"; else NEW[t] = HS[t]
            continue
          }
          if (HS[t] == "deprecated") { if (BS[t] != "deprecated") DEPREC[t] = "status -> deprecated" }
          else if (HS[t] != BS[t]) add(CHANGED, CHC, t, "registry: status " BS[t] "->" HS[t])
          if (HD[t] != BD[t] || HP[t] != BP[t]) add(CHANGED, CHC, t, "registry: text")
          if (sorted_set(HE[t]) != sorted_set(BE[t])) add(CHANGED, CHC, t, "registry: deps")
        }
      }
      for (f in HASCODE) if (HS[f] == "deprecated") DEPREC[f] = (f in DEPREC) ? DEPREC[f] "; code changed" : "code changed"
      nq = 0
      for (f in CHANGED) Q[++nq] = f
      for (f in DEPREC) if ((f in HASCODE) && !(f in CHANGED)) Q[++nq] = f
      isort(Q, nq)
      for (i = 1; i <= nq; i++) { VIS[Q[i]] = 1; CH[Q[i]] = "" }
      h = 1
      while (h <= nq) {
        x = Q[h++]
        m = split(CONS[x], cc, " "); isort(cc, m)
        for (i = 1; i <= m; i++) if (!(cc[i] in VIS)) {
          VIS[cc[i]] = 1
          CH[cc[i]] = "<- " TP x ((CH[x] == "") ? "" : " " CH[x])
          Q[++nq] = cc[i]
        }
      }
      na = 0
      for (f in DEPREC) if (!(f in ALL)) { ALL[f] = 1; AL[++na] = f }
      for (f in NEW) if (!(f in ALL)) { ALL[f] = 1; AL[++na] = f }
      for (f in CHANGED) if (!(f in ALL)) { ALL[f] = 1; AL[++na] = f }
      for (f in VIS) if (!(f in ALL)) { ALL[f] = 1; AL[++na] = f }
      isort(AL, na)
      for (i = 1; i <= na; i++) {
        f = AL[i]
        if (f in DEPREC) printf "C\t1\tdeprecated\t%s\t%s\n", f, DEPREC[f]
        else if (f in NEW) printf "C\t2\tnew\t%s\t%s\n", f, NEW[f]
        else if (f in CHANGED) printf "C\t3\tchanged\t%s\t%s\n", f, limit(CHANGED[f], CHC[f])
        else printf "C\t4\taffected\t%s\t%s\n", f, CH[f]
      }
    }
  ' </dev/null >"$TMP/cat.raw"
  grep '^C' "$TMP/cat.raw" | sort -t "$TAB" -k2,2n -k4,4 >"$TMP/cat.tsv" || true
  grep '^U' "$TMP/cat.raw" | sort -t "$TAB" -k2,2 -k3,3n >"$TMP/untagged.tsv" || true
}

# analyze_changes BASE HEAD REGBASE -- shared pipeline of `changed` and `qa-scope`:
# diff ranges, head scan (work tree or materialized HEAD), base scan of touched old files,
# registries, categories. Results in TMP/{head.tsv,base.tsv,cat.tsv,untagged.tsv}.
analyze_changes() {
  local base=$1 head=$2 regbase=$3
  git_diff_ranges "$base" "$head"
  if [ -n "$head" ]; then
    materialize_head "$head"
    export HROOT=$TMP/head
  else
    export HROOT=$REPO_ROOT
  fi
  scan_tree "$HROOT" "$TMP/head.tsv"
  materialize_base "$base"
  : >"$TMP/base.tsv"
  export BROOT=$TMP/base
  if [ -s "$TMP/oldlist" ]; then
    scan_list "$TMP/base" "$TMP/oldlist" "$TMP/base.tsv"
  fi
  load_registries "$base" "$head" "$regbase"
  categorize
}

# parse_diff_opts ARGS -- --base/--head/--reg-base into OPT_BASE/OPT_HEAD/OPT_REGBASE.
parse_diff_opts() {
  OPT_BASE=
  OPT_HEAD=
  OPT_REGBASE=
  while [ $# -gt 0 ]; do
    case $1 in
      --base) [ $# -ge 2 ] || die "--base requires <rev>"; OPT_BASE=$2; shift 2 ;;
      --head) [ $# -ge 2 ] || die "--head requires <rev>"; OPT_HEAD=$2; shift 2 ;;
      --reg-base) [ $# -ge 2 ] || die "--reg-base requires <rev>"; OPT_REGBASE=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

# cmd_check -- static integrity: scanner findings, orphans, missing starts, registry deps/domains;
# with --base also new tags and edges on deprecated flows. Exit 1 when anything is found.
cmd_check() {
  local n
  parse_diff_opts "$@"
  scan_tree "$REPO_ROOT" "$TMP/head.tsv"
  read_registry "$TMP/reg_head.tsv"
  : >"$TMP/findings"
  awkrun -F '\t' '$1 == "V" { printf "%s\t%s\t%s\t%s\n", $2, $3, $4, $5 }' "$TMP/head.tsv" >>"$TMP/findings"
  check_scan_vs_registry >>"$TMP/findings"
  check_registry >>"$TMP/findings"
  if [ -n "$OPT_BASE" ]; then
    git_diff_ranges "$OPT_BASE" "$OPT_HEAD"
    load_registries "$OPT_BASE" "$OPT_HEAD" "$OPT_REGBASE"
    check_deprecated >>"$TMP/findings"
  fi
  sort -t "$TAB" -k1,1 -k2,2 -k3,3n "$TMP/findings" \
    | awkrun -F '\t' '{ printf "%s\t%s:%s\t%s\n", $1, $2, $3, $4 }'
  n=$(($(wc -l <"$TMP/findings")))
  if [ "$n" -gt 0 ]; then
    printf 'ftags: %d finding(s)\n' "$n" >&2
    return 1
  fi
  return 0
}

# check_scan_vs_registry -- orphan tags and implemented flows without a start marker.
check_scan_vs_registry() {
  export FTAGS_NOSTART_IGNORE=$CONF_NOSTART_IGNORE REG_HEAD=$TMP/reg_head.tsv
  awkrun -F '\t' -v TP="$TP" '
    function flow_of(t,    p, n, a) {
      if (index(t, TP) == 1) t = substr(t, 4)
      p = index(t, "@"); if (p) t = substr(t, 1, p - 1)
      n = split(t, a, "."); if (n > 3) t = a[1] "." a[2] "." a[3]
      return t
    }
    function marker_of(t,    p) { p = index(t, "@"); return (p > 0) ? substr(t, p + 1) : "" }
    BEGIN {
      while ((getline l < ENVIRON["REG_HEAD"]) > 0) {
        split(l, f, "\t")
        if (f[1] == "F") { REGT[f[2]] = 1; if (!(f[2] in RST)) RL[++nr] = f[2]; RST[f[2]] = f[3] }
      }
      close(ENVIRON["REG_HEAD"])
      n = split(ENVIRON["FTAGS_NOSTART_IGNORE"], ig, " ")
      for (i = 1; i <= n; i++) IGN[ig[i]] = 1
    }
    $1 == "D" && $8 != "-" {
      n = split($8, t, " ")
      for (i = 1; i <= n; i++) {
        fl = flow_of(t[i])
        if (!(fl in REGT)) printf "orphan\t%s\t%s\t%s\n", $3, $4, t[i]
        if (split(fl, a, ".") != 3) continue
        if (!(fl in FIRST)) { FIRST[fl] = $3 "\t" $4 }
        m = marker_of(t[i])
        if ($6 == "prod" && (m == "entry" || m == "operation")) START[fl] = 1
      }
    }
    END {
      for (i = 1; i <= nr; i++) {
        fl = RL[i]
        if ((RST[fl] == "partial" || RST[fl] == "done") && (fl in FIRST) && !(fl in START) && !(fl in IGN))
          printf "nostart\t%s\t%s has no @entry/@operation\n", FIRST[fl], TP fl
      }
    }
  ' "$TMP/head.tsv"
}

# check_registry -- dependency table integrity (unknown flow, self-reference, duplicate edge)
# and domains that are prefixes of each other.
check_registry() {
  awkrun -F '\t' -v TP="$TP" '
    $1 == "F" {
      REGT[$2] = 1
      split($2, a, "."); dom = a[1]
      if (!(dom in DOM)) { DOM[dom] = 1; DL[++nd] = dom; DF[dom] = $6; DLN[dom] = $7 }
    }
    $1 == "X" { ne++; EC[ne] = $2; EU[ne] = $3; EF[ne] = $4; EL[ne] = $5 }
    END {
      for (i = 1; i <= ne; i++) {
        e = TP EC[i] " -> " TP EU[i]
        if (!(EC[i] in REGT)) printf "deps\t%s\t%s\tedge %s: unknown flow %s\n", EF[i], EL[i], e, TP EC[i]
        if (!(EU[i] in REGT)) printf "deps\t%s\t%s\tedge %s: unknown flow %s\n", EF[i], EL[i], e, TP EU[i]
        if (EC[i] == EU[i]) printf "deps\t%s\t%s\tedge %s: self-reference\n", EF[i], EL[i], e
        key = EC[i] SUBSEP EU[i]
        if (key in SEEN) printf "deps\t%s\t%s\tedge %s: duplicate edge\n", EF[i], EL[i], e
        SEEN[key] = 1
      }
      for (i = 1; i <= nd; i++) for (j = 1; j <= nd; j++) {
        if (i == j) continue
        if (index(DL[j], DL[i]) == 1) printf "registry\t%s\t%s\tdomain %s is a prefix of domain %s\n", DF[DL[j]], DLN[DL[j]], DL[i], DL[j]
      }
    }
  ' "$TMP/reg_head.tsv"
}

# check_deprecated -- with --base: tags of deprecated flows on added lines of profile files and
# new dependency edges onto deprecated flows.
check_deprecated() {
  export REG_HEAD=$TMP/reg_head.tsv REG_BASE=$TMP/reg_base.tsv HEAD_TSV=$TMP/head.tsv REGDIFF
  awkrun -F '\t' -v TP="$TP" '
    function flow_of(t,    p, n, a) {
      if (index(t, TP) == 1) t = substr(t, 4)
      p = index(t, "@"); if (p) t = substr(t, 1, p - 1)
      n = split(t, a, "."); if (n > 3) t = a[1] "." a[2] "." a[3]
      return t
    }
    BEGIN {
      while ((getline l < ENVIRON["REG_HEAD"]) > 0) {
        split(l, f, "\t")
        if (f[1] == "F") HS[f[2]] = f[3]
        else if (f[1] == "X") { ne++; EC[ne] = f[2]; EU[ne] = f[3]; EF[ne] = f[4]; EL[ne] = f[5] }
      }
      close(ENVIRON["REG_HEAD"])
      if (ENVIRON["REGDIFF"] == "1") {
        while ((getline l < ENVIRON["REG_BASE"]) > 0) { split(l, f, "\t"); if (f[1] == "X") BEK[f[2] SUBSEP f[3]] = 1 }
        close(ENVIRON["REG_BASE"])
      }
      while ((getline l < ENVIRON["HEAD_TSV"]) > 0) { split(l, f, "\t"); if (f[1] == "E") FILES[f[3]] = 1 }
      close(ENVIRON["HEAD_TSV"])
    }
    $1 == "A" && ($2 in FILES) {
      fl = flow_of($4)
      if (HS[fl] == "deprecated") printf "deprecated\t%s\t%s\t%s tags deprecated flow %s\n", $2, $3, $4, TP fl
    }
    END {
      if (ENVIRON["REGDIFF"] != "1") exit 0
      for (i = 1; i <= ne; i++) {
        if (HS[EU[i]] == "deprecated" && !((EC[i] SUBSEP EU[i]) in BEK))
          printf "deprecated\t%s\t%s\tnew edge %s -> %s on deprecated flow\n", EF[i], EL[i], TP EC[i], TP EU[i]
      }
    }
  ' "$TMP/added"
}

# cmd_changed -- categories of the change set (contract section 8). Exit 1 when untagged declarations exist.
cmd_changed() {
  parse_diff_opts "$@"
  [ -n "$OPT_BASE" ] || die "changed requires --base <rev>"
  analyze_changes "$OPT_BASE" "$OPT_HEAD" "$OPT_REGBASE"
  print_reg_base_note
  export CAT=$TMP/cat.tsv UNTAGGED=$TMP/untagged.tsv
  awkrun -F '\t' -v TP="$TP" '
    BEGIN {
      order[1] = "new"; order[2] = "changed"; order[3] = "affected"; order[4] = "deprecated"
      while ((getline l < ENVIRON["CAT"]) > 0) {
        split(l, f, "\t")
        n[f[3]]++; L[f[3], n[f[3]]] = TP f[4] "\t" f[5]
      }
      close(ENVIRON["CAT"])
      nu = 0
      while ((getline l < ENVIRON["UNTAGGED"]) > 0) {
        split(l, f, "\t")
        nu++; U[nu] = f[2] ":" f[3] "\t" f[4] "\t" f[5] ((f[6] == "(base)") ? "\t(base)" : "")
      }
      close(ENVIRON["UNTAGGED"])
      any = 0
      for (i = 1; i <= 4; i++) {
        if (n[order[i]] == 0) continue
        any = 1
        print "# " order[i]
        for (j = 1; j <= n[order[i]]; j++) print L[order[i], j]
      }
      if (nu > 0) { any = 1; print "# untagged"; for (i = 1; i <= nu; i++) print U[i] }
      if (!any) print "# no changes"
      if (nu > 0) exit 1
    }
  ' </dev/null
}

# print_reg_base_note -- stderr note about the registry base used (changed / qa-scope).
print_reg_base_note() {
  local f
  if [ "$REGDIFF" = 1 ]; then
    for f in ${REG_FILES[@]+"${REG_FILES[@]}"}; do
      printf '# registry base: %s@%s\n' "$f" "$REG_BASE_REV" >&2
    done
  else
    printf '# registry base: n/a (registry not in git)\n' >&2
  fi
}

# cmd_qa_scope -- Markdown QA scope (contract section 9). Exit 1 on untagged declarations;
# the report is still printed in full.
cmd_qa_scope() {
  parse_diff_opts "$@"
  [ -n "$OPT_BASE" ] || die "qa-scope requires --base <rev>"
  analyze_changes "$OPT_BASE" "$OPT_HEAD" "$OPT_REGBASE"
  print_reg_base_note
  render_qa "$OPT_BASE" "$OPT_HEAD"
}

# render_qa BASE HEAD -- categories + head scan + registry + profiles -> Markdown.
render_qa() {
  export FTAGS_BASE=$1 FTAGS_HEAD=${2:-working tree} FTAGS_REGLABEL=$REG_LABEL
  export CAT=$TMP/cat.tsv UNTAGGED=$TMP/untagged.tsv HEAD_TSV=$TMP/head.tsv REG_HEAD=$TMP/reg_head.tsv LANGS_TSV
  awkrun -F '\t' -v TP="$TP" '
    function flow_of(t,    p, n, a) {
      if (index(t, TP) == 1) t = substr(t, 4)
      p = index(t, "@"); if (p) t = substr(t, 1, p - 1)
      n = split(t, a, "."); if (n > 3) t = a[1] "." a[2] "." a[3]
      return t
    }
    function nseg(t,    a) { return split(t, a, ".") }
    function marker_of(t,    p) { p = index(t, "@"); return (p > 0) ? substr(t, p + 1) : "" }
    function ere_escape(s,    out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (index(".[]()*+?{}^$|\\", c) > 0) out = out "\\" c; else out = out c }
      return out
    }
    function esc_pipe(s) { gsub(/[|]/, "\\|", s); return s }
    function fill(cmd, joined,    p) { p = index(cmd, "{TESTS}"); if (p == 0) return cmd; return substr(cmd, 1, p - 1) joined substr(cmd, p + 7) }
    function tests_cell(f,    i, l, out, names, joined, j, m, parts) {
      out = ""
      for (i = 1; i <= nl; i++) {
        l = LO[i]
        if (TN[f, l] == 0) continue
        names = TL[f, l]
        if (JOIN[l] == "|") {
          m = split(names, parts, ", "); joined = ""
          for (j = 1; j <= m; j++) joined = joined ((j > 1) ? "|" : "") ere_escape(parts[j])
        } else {
          m = split(names, parts, ", "); joined = ""
          for (j = 1; j <= m; j++) joined = joined ((j > 1) ? JOIN[l] : "") parts[j]
        }
        out = out ((out == "") ? "" : "; ") names " → `" fill(RUN[l], joined) "`"
      }
      if (out != "") return out
      for (i = 1; i <= nl; i++) { l = LO[i]; if (((f SUBSEP l) in HASLANG) && EV[l] != "") out = out ((out == "") ? "" : "; ") EV[l] }
      return out
    }
    function chain_md(f, reason,    n, t, i, out) {
      out = "`" TP f "`"
      n = split(reason, t, " ")
      for (i = 1; i <= n; i++) { if (t[i] == "<-") continue; out = out " ← `" t[i] "`" }
      return out
    }
    function deprec_md(reason,    s) {
      s = reason
      gsub(/status -> deprecated/, "статус → deprecated", s)
      gsub(/code changed/, "изменён compatibility-код", s)
      return s
    }
    function dash(s) { return (s == "" || s == "-") ? "—" : s }
    BEGIN {
      nl = 0
      while ((getline l < ENVIRON["LANGS_TSV"]) > 0) { split(l, f, "\t"); nl++; LO[nl] = f[1]; RUN[f[1]] = f[2]; JOIN[f[1]] = f[3]; EV[f[1]] = f[4] }
      close(ENVIRON["LANGS_TSV"])
      while ((getline l < ENVIRON["REG_HEAD"]) > 0) { split(l, f, "\t"); if (f[1] == "F") { HD[f[2]] = f[4]; HP[f[2]] = f[5] } }
      close(ENVIRON["REG_HEAD"])
      while ((getline l < ENVIRON["HEAD_TSV"]) > 0) {
        split(l, f, "\t")
        if (f[1] != "D" || f[8] == "-") continue
        n = split(f[8], t, " ")
        for (i = 1; i <= n; i++) {
          fl = flow_of(t[i]); if (nseg(fl) < 3) continue
          HASLANG[fl, f[2]] = 1; HASANY[fl] = 1
          m = marker_of(t[i])
          if (f[6] == "prod" && (m == "entry" || m == "operation")) {
            s = "`" f[3] ":" f[4] "` (`@" m "`)"
            if (index(START[fl], s) == 0) START[fl] = START[fl] ((START[fl] == "") ? "" : ", ") s
          }
          if (f[5] == "test") {
            key = fl SUBSEP f[2] SUBSEP f[7]
            if (!(key in TSEEN)) { TSEEN[key] = 1; TN[fl, f[2]]++; TL[fl, f[2]] = TL[fl, f[2]] ((TN[fl, f[2]] > 1) ? ", " : "") f[7] }
          }
        }
      }
      close(ENVIRON["HEAD_TSV"])
      nc = 0
      while ((getline l < ENVIRON["CAT"]) > 0) { split(l, f, "\t"); nc++; CC[nc] = f[3]; CF[nc] = f[4]; CR[nc] = f[5] }
      close(ENVIRON["CAT"])
      nu = 0
      while ((getline l < ENVIRON["UNTAGGED"]) > 0) { split(l, f, "\t"); nu++; UL[nu] = "- `" f[2] ":" f[3] "` " f[4] " " f[5] ((f[6] == "(base)") ? " (base)" : "") }
      close(ENVIRON["UNTAGGED"])
      err = 0
      print "## QA Scope"
      print ""
      print "Base: `" ENVIRON["FTAGS_BASE"] "` · Head: `" ENVIRON["FTAGS_HEAD"] "` · Registry base: `" ENVIRON["FTAGS_REGLABEL"] "`"
      print ""
      if (nu > 0) {
        print "**Непомеченные объявления** — QA scope неполон:"
        print ""
        for (i = 1; i <= nu; i++) print UL[i]
        print ""
        err = 1
      }
      print "### Новые флоу"
      print ""
      k = 0
      for (i = 1; i <= nc; i++) if (CC[i] == "new") {
        k++
        if (CR[i] == "planned") print "- `" TP CF[i] "` — `planned` — изменение каталога без реализованного сценария"
        else print "- `" TP CF[i] "` — `" CR[i] "` — " dash(HD[CF[i]])
      }
      if (k == 0) print "— нет"
      print ""
      print "### Изменённые флоу"
      print ""
      k = 0
      for (i = 1; i <= nc; i++) if (CC[i] == "changed") { k++; print "- `" TP CF[i] "` — " CR[i] }
      if (k == 0) print "— нет"
      print ""
      print "### Косвенно затронутые"
      print ""
      k = 0
      for (i = 1; i <= nc; i++) if (CC[i] == "affected") { k++; print "- `" TP CF[i] "` — " chain_md(CF[i], CR[i]) }
      # Unlike the other sections, an empty list here is not a fact about the code: the closure runs
      # over the hand-written dependency table, so it names its source instead of asserting "none".
      if (k == 0) print "— нет по таблице зависимостей"
      print ""
      print "### Deprecated-флоу"
      print ""
      k = 0
      for (i = 1; i <= nc; i++) if (CC[i] == "deprecated") { k++; print "- `" TP CF[i] "` — " deprec_md(CR[i]) "; замена — по описанию реестра: " dash(HD[CF[i]]) }
      if (k == 0) print "— нет"
      print ""
      print "### QA-проверки"
      print ""
      print "| Тип влияния | Флоу | Что изменилось / почему затронуто | Спека | Стартовые точки | Автотесты / стенд | Ручная проверка |"
      print "| --- | --- | --- | --- | --- | --- | --- |"
      if (nc == 0) print "| — | — | — | — | — | — | — |"
      for (i = 1; i <= nc; i++) {
        fl = CF[i]; cat = CC[i]
        tomb = (cat == "deprecated" && !(fl in HASANY))
        if (cat == "new") what = "новый флоу (`" CR[i] "`)"
        else if (cat == "affected") what = chain_md(fl, CR[i])
        else if (cat == "deprecated") what = deprec_md(CR[i])
        else what = CR[i]
        if (tomb) start = "n/a — tombstone"
        else if (cat == "new" && CR[i] == "planned") start = "n/a — не реализовано"
        else start = dash(START[fl])
        ev = tests_cell(fl)
        ev = dash(ev)
        manual = tomb ? "n/a — tombstone" : "—"
        printf "| %s | `%s` | %s | %s | %s | %s | %s |\n", esc_pipe(cat), esc_pipe(TP fl), esc_pipe(what), esc_pipe(dash(HP[fl])), esc_pipe(start), esc_pipe(ev), esc_pipe(manual)
      }
      if (err) exit 1
    }
  ' </dev/null
}

# cmd_trace FLOW -- declarations of a flow grouped by marker and file (contract section 10).
cmd_trace() {
  local flow
  [ $# -eq 1 ] || die "trace requires exactly one <flow>"
  flow=$(norm_flow "$1")
  scan_tree "$REPO_ROOT" "$TMP/head.tsv"
  export FTAGS_FLOW=$flow
  awkrun -F '\t' -v TP="$TP" '
    function base_of(t,    p) { if (index(t, TP) == 1) t = substr(t, 4); p = index(t, "@"); if (p) t = substr(t, 1, p - 1); return t }
    function marker_of(t,    p) { p = index(t, "@"); return (p > 0) ? substr(t, p + 1) : "" }
    function matches(t,    b) { b = base_of(t); return (b == F || index(b, F ".") == 1) }
    BEGIN { F = ENVIRON["FTAGS_FLOW"] }
    $1 == "D" && $8 != "-" {
      n = split($8, t, " ")
      for (i = 1; i <= n; i++) {
        if (!matches(t[i])) continue
        m = marker_of(t[i])
        if ($5 == "test") sec = 4; else if (m == "entry") sec = 1; else if (m == "operation") sec = 2; else sec = 3
        key = sec SUBSEP $3 SUBSEP $4
        if (key in seen) continue
        seen[key] = 1
        printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", sec, $3, $4, $5, $7, $8, (m == "recv") ? "<recv>" : ""
      }
    }
  ' "$TMP/head.tsv" | sort -t "$TAB" -k1,1n -k2,2 -k3,3n >"$TMP/trace.tsv"
  if [ ! -s "$TMP/trace.tsv" ]; then
    printf 'ftags: nothing tagged %s\n' "$flow" >&2
    return 1
  fi
  awkrun -F '\t' '
    BEGIN { names[1] = "entry"; names[2] = "operation"; names[3] = "steps"; names[4] = "tests"; cursec = "" }
    {
      if ($1 != cursec) { cursec = $1; curfile = ""; print "# " names[$1] }
      if ($2 != curfile) { curfile = $2; print curfile }
      line = sprintf("%6s  %-6s  %-32s  %s", $3, $4, $5, $6)
      if ($7 != "") line = line "  " $7
      print line
    }
  ' "$TMP/trace.tsv"
}

# cmd_entries [FLOW] -- one line per @entry tag.
cmd_entries() {
  list_marked entry "$@"
}

# cmd_operations [FLOW] -- one line per @operation tag.
cmd_operations() {
  list_marked operation "$@"
}

# list_marked MARKER [FLOW] -- `<file>:<line> <kind> <name> <tag@marker>` sorted by tag, file, line;
# exit 1 when a flow was given and nothing matched.
list_marked() {
  local marker=$1 flow=
  shift
  [ $# -le 1 ] || die "too many arguments"
  [ $# -eq 1 ] && flow=$(norm_flow "$1")
  scan_tree "$REPO_ROOT" "$TMP/head.tsv"
  export FTAGS_FLOW=$flow FTAGS_MARKER=$marker
  awkrun -F '\t' -v TP="$TP" '
    function base_of(t,    p) { if (index(t, TP) == 1) t = substr(t, 4); p = index(t, "@"); if (p) t = substr(t, 1, p - 1); return t }
    function marker_of(t,    p) { p = index(t, "@"); return (p > 0) ? substr(t, p + 1) : "" }
    function matches(t,    b) { if (F == "") return 1; b = base_of(t); return (b == F || index(b, F ".") == 1) }
    BEGIN { F = ENVIRON["FTAGS_FLOW"]; M = ENVIRON["FTAGS_MARKER"] }
    $1 == "D" && $8 != "-" {
      n = split($8, t, " ")
      for (i = 1; i <= n; i++) if (marker_of(t[i]) == M && matches(t[i])) printf "%s\t%s\t%s\t%s\t%s\n", t[i], $3, $4, $5, $7
    }
  ' "$TMP/head.tsv" | sort -t "$TAB" -k1,1 -k2,2 -k3,3n >"$TMP/marked.tsv"
  awkrun -F '\t' '{ printf "%s:%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $1 }' "$TMP/marked.tsv"
  if [ -n "$flow" ] && [ ! -s "$TMP/marked.tsv" ]; then
    printf 'ftags: no @%s tagged %s\n' "$marker" "$flow" >&2
    return 1
  fi
  return 0
}

# cmd_tests FLOW -- test names per language (stdout, joined by RUN_JOIN) and the run command (stderr);
# without tests: EVIDENCE_CMD of a profile holding code of the flow, otherwise exit 1.
cmd_tests() {
  local flow
  [ $# -eq 1 ] || die "tests requires exactly one <flow>"
  flow=$(norm_flow "$1")
  scan_tree "$REPO_ROOT" "$TMP/head.tsv"
  export FTAGS_FLOW=$flow LANGS_TSV
  awkrun -F '\t' -v TP="$TP" '
    function base_of(t,    p) { if (index(t, TP) == 1) t = substr(t, 4); p = index(t, "@"); if (p) t = substr(t, 1, p - 1); return t }
    function matches(t,    b) { b = base_of(t); return (b == F || index(b, F ".") == 1) }
    function ere_escape(s,    out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (index(".[]()*+?{}^$|\\", c) > 0) out = out "\\" c; else out = out c }
      return out
    }
    function fill(cmd, joined,    p) { p = index(cmd, "{TESTS}"); if (p == 0) return cmd; return substr(cmd, 1, p - 1) joined substr(cmd, p + 7) }
    BEGIN {
      F = ENVIRON["FTAGS_FLOW"]
      while ((getline l < ENVIRON["LANGS_TSV"]) > 0) { split(l, f, "\t"); nl++; LO[nl] = f[1]; RUN[f[1]] = f[2]; JOIN[f[1]] = f[3]; EV[f[1]] = f[4] }
      close(ENVIRON["LANGS_TSV"])
    }
    $1 == "D" && $8 != "-" {
      n = split($8, t, " "); hit = 0
      for (i = 1; i <= n; i++) if (matches(t[i])) hit = 1
      if (!hit) next
      HAS[$2] = 1
      if ($5 != "test") next
      key = $2 SUBSEP $7
      if (key in seen) next
      seen[key] = 1
      TN[$2]++; TS[$2, TN[$2]] = $7
    }
    END {
      any = 0
      for (i = 1; i <= nl; i++) {
        l = LO[i]
        if (TN[l] == 0) continue
        any = 1; joined = ""
        for (j = 1; j <= TN[l]; j++) joined = joined ((j > 1) ? JOIN[l] : "") ((JOIN[l] == "|") ? ere_escape(TS[l, j]) : TS[l, j])
        print joined
        print "# " l ": " fill(RUN[l], joined) > "/dev/stderr"
      }
      if (any) exit 0
      ev = 0
      for (i = 1; i <= nl; i++) { l = LO[i]; if ((l in HAS) && EV[l] != "") { print "# " l ": " EV[l] > "/dev/stderr"; ev = 1 } }
      if (ev) exit 0
      print "ftags: no tests tagged " F > "/dev/stderr"
      exit 1
    }
  ' "$TMP/head.tsv"
}

# norm_flow ARG -- strip the tag prefix and any marker from a flow argument.
norm_flow() {
  local f=$1
  f=${f#"$TP"}
  f=${f%%@*}
  [ -n "$f" ] || die "empty flow"
  printf '%s\n' "$f"
}

# cmd_scan -- debug dump of the scanner records for the work tree.
cmd_scan() {
  [ $# -eq 0 ] || die "scan takes no arguments"
  scan_tree "$REPO_ROOT" "$TMP/head.tsv"
  cat "$TMP/head.tsv"
}

cmd_dispatch() {
  local cmd=$1
  shift
  "cmd_$cmd" "$@"
}

main() {
  local cmd
  while [ $# -gt 0 ]; do
    case $1 in
      -C)
        [ $# -ge 2 ] || die "-C requires <dir>"
        cd "$2" || die "cannot chdir to $2"
        shift 2
        ;;
      --lang)
        [ $# -ge 2 ] || die "--lang requires <name>"
        OPT_LANG=$2
        shift 2
        ;;
      -h | --help | help)
        usage
        exit 0
        ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  if [ $# -eq 0 ]; then
    usage >&2
    exit 2
  fi
  cmd=$1
  shift
  case "$cmd" in
    trace | entries | operations | tests)
      load_conf
      cmd_dispatch "$cmd" "$@" ;;
    check | changed)
      load_conf
      cmd_dispatch "$cmd" "$@" ;;
    qa-scope)
      load_conf
      cmd_qa_scope "$@" ;;
    scan)
      load_conf
      cmd_scan "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
