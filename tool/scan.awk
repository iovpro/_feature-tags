# scan.awk -- ftags scanner: files of one language profile -> record stream (contract §5).
#
# POSIX awk only (BSD awk, mawk, busybox awk, gawk). No gensub, no length(arr),
# no interval expressions, no nextfile. Runs entirely in BEGIN, so awk never
# reads stdin: invoke as `awk -f scan.awk` with no file arguments.
#
# Input (all via ENVIRON, exported by the caller; regexes must not go through -v):
#   FTAGS_LIST            path to a file listing the files to scan, one path per line;
#                         paths are echoed verbatim in the output
#   FTAGS_LANG            profile name (falls back to NAME)
#   FTAGS_TEST_FILES_RE   ERE selecting test files, already converted from the
#                         TEST_FILES globs by the caller (matched against the full
#                         path and against the basename). When this variable is not
#                         exported at all, TEST_FILES is converted here with the §3
#                         glob semantics (no `/` -> basename, leading `/` -> anchored
#                         path, otherwise `(^|/)...$`).
#   NAME COMMENT GAP_RE DECL_RE TAG_TARGET_RE DECL_NAME_STRIP FLOW_DECL_RE FEAT_DECL_RE
#   BRANCH_RE FIELD_OPEN_RE FIELD_CLOSE_RE HEADER_RE TEST_FILES TEST_RE TEST_NAME_STRIP
#   TEST_NAME_END         profile fields (§4); an empty regex means "not applicable"
#   LC_ALL=C              expected to be set by the caller (byte semantics, and gawk
#                         mis-handles regexes when no locale variable is set at all)
#
# Output (TSV, TAB separated, empty value is `-`, TABs inside a value become spaces):
#   D <lang> <file> <line> <kind> <side> <name> <tags>   kind: decl|test|branch; side: prod|test
#   V <class> <file> <line> <detail>                     class: text|format|placement|file|field
#   E <lang> <file> <nlines>                             end of file
#
# Decisions on points the contract leaves open:
#   - a `#f:` occurrence with no comment marker before it gives `V text` and the line is not
#     parsed any further (§5 p.1, literal): no tags, no D record, pending state untouched
#   - a tag line whose every token was rejected still opens a tag group with no tags; a
#     declaration bound to it gets `-` in the tags column (it is effectively untagged)
#   - an unresolved tag group is classified (file / field / placement) only when it is dropped
#     by a non-declaration code line (§5 p.5 "otherwise"): `file` when that line matches
#     HEADER_RE or no DECL_RE/TAG_TARGET_RE line was seen yet in the file, else `field`
#     inside FIELD_OPEN/CLOSE, else `placement`. The other three drops always give
#     `placement`, literally per the contract: a second blank line (§5 p.5), the next tag
#     line (§5 p.4) and the end of file (§5 p.6)
#   - the "marker on feature tag" check also applies to branch tags; the FLOW/FEAT depth
#     checks apply only to declarations bound to a tag group (the branch line is not a
#     declaration); "marker on test" applies only to kind=test
#   - `V format` produced while binding a tag group points at the tag line; for branches
#     it points at the branch line
#   - a line with a trailing tag is processed as code afterwards (§5 p.4); if that line is a
#     declaration it may bind a pending tag group or be reported as untagged
#   - exit status 2 when FTAGS_LIST or COMMENT is missing, when the list file cannot be read,
#     or when a listed file cannot be read (reported on stderr; the remaining files are
#     still scanned and the unreadable one gets `E ... 0`)

function trim(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return s
}

function trunc(s, n) {
  return (length(s) > n) ? substr(s, 1, n) : s
}

# Empty value -> "-"; TABs would break the TSV columns.
function col(s) {
  gsub(/\t/, " ", s)
  return (s == "") ? "-" : s
}

function indent_of(s) {
  match(s, /^[[:space:]]*/)
  return substr(s, 1, RLENGTH)
}

function emit_v(class, line, detail) {
  printf "V\t%s\t%s\t%d\t%s\n", class, FILE, line, col(detail)
}

function emit_d(line, kind, name, tags) {
  printf "D\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n", LANG, FILE, line, kind, SIDE, col(name), col(tags)
}

# glob -> ERE (§3): `*` -> `.*`, `?` -> `.`, other metacharacters escaped.
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

function is_test_file(f,    base, i) {
  base = f
  sub(/^.*\//, "", base)
  if (TF_FROM_ENV) return (TF_ENV_RE != "" && (f ~ TF_ENV_RE || base ~ TF_ENV_RE))
  for (i = 1; i <= TF_N; i++) {
    if (TF_BASE[i]) { if (base ~ TF_RE[i]) return 1 }
    else if (f ~ TF_RE[i]) return 1
  }
  return 0
}

# Number of segments of a tag without its marker ("#f:a.b.c@entry" -> 3).
function nseg(tag,    base, segs) {
  base = tag
  sub(/@.*$/, "", base)
  return split(substr(base, 4), segs, ".")
}

function marker_of(tag,    p) {
  p = index(tag, "@")
  return (p > 0) ? substr(tag, p + 1) : ""
}

# Tokens after the comment marker -> valid, deduplicated tags (§5 p.3). Bad tokens -> V format.
function parse_tags(post, lineno,    n, i, toks, tok, out, seen) {
  out = ""
  split("", seen)
  n = split(post, toks, /[[:space:]]+/)
  for (i = 1; i <= n; i++) {
    tok = toks[i]
    if (tok == "" || index(tok, TP) != 1) continue
    if (tok !~ TOKEN_RE) { emit_v("format", lineno, tok); continue }
    if (nseg(tok) < 2) { emit_v("format", lineno, tok " bare domain"); continue }
    if (tok in seen) continue
    seen[tok] = 1
    out = (out == "") ? tok : out " " tok
  }
  return out
}

# Declaration name (§4 DECL_NAME_STRIP): strip the prefix, cut at the first of
# space ( [ { : = ; empty result -> first word of the line.
function decl_name(line,    s, dl, i, p, best, w) {
  s = line
  if (DECL_NAME_STRIP != "") sub(DECL_NAME_STRIP, "", s)
  dl = " ([{:="
  best = 0
  for (i = 1; i <= length(dl); i++) {
    p = index(s, substr(dl, i, 1))
    if (p > 0 && (best == 0 || p < best)) best = p
  }
  if (best > 0) s = substr(s, 1, best - 1)
  s = trim(s)
  if (s == "") {
    split(trim(line), w, /[[:space:]]+/)
    s = w[1]
  }
  return s
}

function test_name(line,    s) {
  s = line
  if (TEST_NAME_STRIP != "") sub(TEST_NAME_STRIP, "", s)
  if (TEST_NAME_END != "") sub(TEST_NAME_END, "", s)
  return trim(s)
}

function is_test_line(line) {
  return (SIDE == "test" && TEST_RE != "" && line ~ TEST_RE)
}

# Checks performed when tags get attached to a record (§5 p.5).
function check_bound(tags, kind, declline, vline,    n, i, t, arr, ns, mk) {
  n = split(tags, arr, " ")
  for (i = 1; i <= n; i++) {
    t = arr[i]
    ns = nseg(t)
    mk = marker_of(t)
    if (kind != "branch") {
      if (FLOW_DECL_RE != "" && declline ~ FLOW_DECL_RE && ns < 3)
        emit_v("format", vline, t " flow-level tag required")
      if (FEAT_DECL_RE != "" && declline ~ FEAT_DECL_RE && ns != 2)
        emit_v("format", vline, t " feature-level tag required")
    }
    if (mk != "" && kind == "test") emit_v("format", vline, t " marker on test")
    if (mk != "" && ns == 2) emit_v("format", vline, t " marker on feature tag")
  }
}

function clear_pending() {
  pending = 0; ptags = ""; pindent = ""; pline = 0; pphase = 0
}

# Drop an unresolved tag group on a non-declaration line: file header / field / placement
# (§5 p.5 "otherwise", §6).
function drop_pending(detail, curline) {
  if ((HEADER_RE != "" && curline != "" && curline ~ HEADER_RE) || !seen_decl)
    emit_v("file", pline, "tag group in file header")
  else if (infield)
    emit_v("field", pline, "tag group on a struct/interface member")
  else
    emit_v("placement", pline, detail)
  clear_pending()
}

function bind_pending(line,    kind, name) {
  if (is_test_line(line)) { kind = "test"; name = test_name(line) }
  else { kind = "decl"; name = decl_name(line) }
  emit_d(nlines, kind, name, ptags)
  check_bound(ptags, kind, line, pline)
  clear_pending()
}

function untagged_decl(line) {
  if (is_test_line(line)) emit_d(nlines, "test", test_name(line), "")
  else emit_d(nlines, "decl", decl_name(line), "")
}

function process(line,    p, s, c, off, q, pre, post, tags, is_decl, is_target, blank) {
  # 1-4. tags on this line
  p = index(line, TP)
  if (p > 0) {
    s = substr(line, 1, p - 1)
    c = 0; off = 0
    while ((q = index(substr(s, off + 1), CM)) > 0) { c = off + q; off = off + q }
    if (c == 0) {
      # tag without a comment marker (string literal, YAML value): report and stop here
      emit_v("text", nlines, trunc(trim(line), 100))
      return
    } else {
      pre = substr(line, 1, c - 1)
      post = substr(line, c + length(CM))
      if (post !~ STRICT_RE) emit_v("text", nlines, trunc(trim(line), 100))
      tags = parse_tags(post, nlines)
      if (pre ~ /^[[:space:]]*$/) {
        # tag line: opens a new tag group
        if (pending) { emit_v("placement", pline, "tag group not followed by a declaration"); clear_pending() }
        pending = 1; ptags = tags; pindent = pre; pline = nlines; pphase = 1
        return
      }
      # trailing tag
      if (BRANCH_RE != "" && pre ~ BRANCH_RE) {
        emit_d(nlines, "branch", trunc(trim(pre), 60), tags)
        check_bound(tags, "branch", line, nlines)
      } else if (infield) {
        emit_v("field", nlines, "trailing tag on a struct/interface member")
      } else {
        emit_v("placement", nlines, "trailing tag not on a branch line")
      }
    }
  }

  # 5. code line
  is_decl = (DECL_RE != "" && line ~ DECL_RE)
  is_target = (TAG_TARGET_RE != "" && line ~ TAG_TARGET_RE)
  blank = (line ~ /^[[:space:]]*$/)
  if (pending) {
    if (pphase == 1) {
      if (blank) { pphase = 2; return }
      emit_v("placement", pline, "blank line required after tag group")
      pphase = 2
    }
    if ((is_decl || is_target) && indent_of(line) == pindent) {
      bind_pending(line)
    } else if (GAP_RE != "" && line ~ GAP_RE) {
      return
    } else if (blank) {
      emit_v("placement", pline, "second blank line breaks the link"); clear_pending()
      return
    } else {
      drop_pending("tag group not followed by a declaration of the same indent", line)
      if (is_decl) untagged_decl(line)
    }
  } else if (is_decl) {
    untagged_decl(line)
  }
  if (is_decl || is_target) seen_decl = 1
  if (FIELD_OPEN_RE != "" && line ~ FIELD_OPEN_RE) infield = 1
  else if (FIELD_CLOSE_RE != "" && infield && line ~ FIELD_CLOSE_RE) infield = 0
}

function scan_file(f,    line, rc) {
  FILE = f
  SIDE = is_test_file(f) ? "test" : "prod"
  nlines = 0; infield = 0; seen_decl = 0
  clear_pending()
  while ((rc = (getline line < f)) > 0) {
    nlines++
    process(line)
  }
  if (rc < 0) { print "ftags: scan: cannot read " f > "/dev/stderr"; failed = 1 }
  close(f)
  if (pending) { emit_v("placement", pline, "tag group at end of file"); clear_pending() }
  printf "E\t%s\t%s\t%d\n", LANG, FILE, nlines
}

BEGIN {
  TP = "#" "f:"
  LIST = ENVIRON["FTAGS_LIST"]
  LANG = ENVIRON["FTAGS_LANG"]
  if (LANG == "") LANG = ENVIRON["NAME"]
  CM = ENVIRON["COMMENT"]
  GAP_RE = ENVIRON["GAP_RE"]
  DECL_RE = ENVIRON["DECL_RE"]
  TAG_TARGET_RE = ENVIRON["TAG_TARGET_RE"]
  DECL_NAME_STRIP = ENVIRON["DECL_NAME_STRIP"]
  FLOW_DECL_RE = ENVIRON["FLOW_DECL_RE"]
  FEAT_DECL_RE = ENVIRON["FEAT_DECL_RE"]
  BRANCH_RE = ENVIRON["BRANCH_RE"]
  FIELD_OPEN_RE = ENVIRON["FIELD_OPEN_RE"]
  FIELD_CLOSE_RE = ENVIRON["FIELD_CLOSE_RE"]
  HEADER_RE = ENVIRON["HEADER_RE"]
  TEST_RE = ENVIRON["TEST_RE"]
  TEST_NAME_STRIP = ENVIRON["TEST_NAME_STRIP"]
  TEST_NAME_END = ENVIRON["TEST_NAME_END"]

  if (LIST == "") { print "ftags: scan: FTAGS_LIST is not set" > "/dev/stderr"; exit 2 }
  if (CM == "") { print "ftags: scan: COMMENT is empty for profile " LANG > "/dev/stderr"; exit 2 }

  # strict tag line: one space, tokens separated by single spaces, optional trailing whitespace
  STRICT_RE = "^ " TP "[^[:space:]]*( " TP "[^[:space:]]*)*[[:space:]]*$"
  # token grammar (README, section "Grammar")
  TOKEN_RE = "^" TP "[a-z0-9]+(\\.[a-z0-9]+)*(@(entry|operation|recv))?$"

  if ("FTAGS_TEST_FILES_RE" in ENVIRON) {
    TF_FROM_ENV = 1
    TF_ENV_RE = ENVIRON["FTAGS_TEST_FILES_RE"]
  } else {
    TF_FROM_ENV = 0
    TF_N = split(ENVIRON["TEST_FILES"], masks, " ")
    for (i = 1; i <= TF_N; i++) {
      g = masks[i]
      if (index(g, "/") == 0) { TF_BASE[i] = 1; TF_RE[i] = "^" glob2ere(g) "$" }
      else if (substr(g, 1, 1) == "/") { TF_BASE[i] = 0; TF_RE[i] = "^" glob2ere(substr(g, 2)) "$" }
      else { TF_BASE[i] = 0; TF_RE[i] = "(^|/)" glob2ere(g) "$" }
    }
  }

  failed = 0
  while ((rc = (getline f < LIST)) > 0) {
    if (f == "") continue
    scan_file(f)
  }
  close(LIST)
  if (rc < 0) { print "ftags: scan: cannot read file list " LIST > "/dev/stderr"; exit 2 }
  if (failed) exit 2
}
