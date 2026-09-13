#!/usr/bin/env node
// scan-ts.mjs -- ftags AST scanner for TypeScript / JavaScript.
//
// Uses the TypeScript compiler API to parse source files and emit D/V/E records
// in the same TSV format as scan.awk. Replaces regex-based scanning for TS/JS
// with full AST awareness: class members, namespaces, nested scopes, decorators,
// and lexically accurate comment detection.
//
// Input (all via environment, matching the scan.awk contract):
//   FTAGS_LIST       path to a file listing the files to scan (one per line)
//   FTAGS_LANG       profile name (e.g. "ts")
//   COMMENT          comment marker (e.g. "//")
//   TEST_FILES       glob masks for test files (space-separated)
//   BRANCH_RE        ERE for branch lines (case/default)
//   HEADER_RE        not used (AST determines file header by declaration position)
//   FLOW_DECL_RE     not used (empty for ts)
//   FEAT_DECL_RE     not used (empty for ts)
//   FIELD_OPEN_RE    not used (empty for ts)
//   FIELD_CLOSE_RE   not used (empty for ts)
//
// Output (TSV, TAB separated):
//   D <lang> <file> <line> <kind> <side> <name> <tags>
//   V <class> <file> <line> <detail>
//   E <lang> <file> <nlines>

import { readFileSync } from 'fs';
import { basename } from 'path';
import { createRequire } from 'module';

// Resolve typescript from CWD (project) or scanner's own node_modules.
function loadTS() {
  const paths = [process.cwd() + '/', import.meta.url];
  for (const base of paths) {
    try {
      const req = createRequire(base);
      return req('typescript');
    } catch { /* try next */ }
  }
  process.stderr.write('ftags: scan-ts: typescript package not found\n');
  process.exit(2);
}

const ts = loadTS();
const TP = '#' + 'f:';
const TAG_RE = /^#f:[a-z0-9]+(\.[a-z0-9]+)*(@(entry|operation|recv))?$/;
const STRICT_TAG_LINE_RE = new RegExp(`^ ${TP.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^\\s]*(\\s+${TP.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^\\s]*)*\\s*$`);

const LANG = process.env.FTAGS_LANG || 'ts';
const LIST_PATH = process.env.FTAGS_LIST;
const CM = process.env.COMMENT || '//';
const TEST_FILES_RAW = process.env.TEST_FILES || '';
const BRANCH_RE_RAW = process.env.BRANCH_RE || '';

if (!LIST_PATH) {
  process.stderr.write('ftags: scan-ts: FTAGS_LIST is not set\n');
  process.exit(2);
}

// Build test-file matchers from glob masks.
function buildTestMatchers(raw) {
  if (!raw) return [];
  return raw.split(/\s+/).filter(Boolean).map(glob => {
    const re = glob
      .replace(/[.+^${}()|[\]\\]/g, '\\$&')
      .replace(/\*/g, '.*')
      .replace(/\?/g, '.');
    const hasSlash = glob.includes('/');
    if (!hasSlash) return { test: f => new RegExp(`^${re}$`).test(basename(f)) };
    if (glob.startsWith('/')) return { test: f => new RegExp(`^${re.slice(1)}$`).test(f) };
    return { test: f => new RegExp(`(^|/)${re}$`).test(f) };
  });
}

const testMatchers = buildTestMatchers(TEST_FILES_RAW);
function isTestFile(f) {
  return testMatchers.some(m => m.test(f));
}

// Compile optional EREs from the profile.
// Profile values use POSIX ERE syntax (for awk compatibility); JS RegExp does not
// support POSIX character classes, so we convert the common ones before compiling.
function compileRE(raw) {
  if (!raw) return null;
  // Strip surrounding single quotes that the profile parser leaves.
  let s = raw;
  if (s.startsWith("'") && s.endsWith("'")) s = s.slice(1, -1);
  // Convert POSIX character classes to JS equivalents.
  // [:space:] inside [...] becomes \s, [:alpha:] becomes a-zA-Z, etc.
  s = s.replace(/\[:space:]/g, '\\s');
  s = s.replace(/\[:alpha:]/g, 'a-zA-Z');
  s = s.replace(/\[:alnum:]/g, 'a-zA-Z0-9');
  s = s.replace(/\[:digit:]/g, '\\d');
  s = s.replace(/\[:upper:]/g, 'A-Z');
  s = s.replace(/\[:lower:]/g, 'a-z');
  try { return new RegExp(s); } catch { return null; }
}

const branchRE = compileRE(BRANCH_RE_RAW);

// Output helpers.
function col(s) {
  if (!s) return '-';
  return s.replace(/\t/g, ' ') || '-';
}

function emitD(file, line, kind, side, name, tags) {
  process.stdout.write(`D\t${LANG}\t${file}\t${line}\t${kind}\t${side}\t${col(name)}\t${col(tags)}\n`);
}

function emitV(cls, file, line, detail) {
  process.stdout.write(`V\t${cls}\t${file}\t${line}\t${col(detail)}\n`);
}

function emitE(file, nlines) {
  process.stdout.write(`E\t${LANG}\t${file}\t${nlines}\n`);
}

// Tag parsing: extract valid tags from the portion after the comment marker.
function parseTags(post, file, line) {
  const tokens = post.trim().split(/\s+/).filter(Boolean);
  const seen = new Set();
  const valid = [];
  for (const tok of tokens) {
    if (!tok.startsWith(TP)) continue;
    if (!TAG_RE.test(tok)) {
      emitV('format', file, line, tok);
      continue;
    }
    const ns = nseg(tok);
    if (ns < 2) {
      emitV('format', file, line, `${tok} bare domain`);
      continue;
    }
    if (seen.has(tok)) continue;
    seen.add(tok);
    valid.push(tok);
  }
  return valid.join(' ');
}

function nseg(tag) {
  let base = tag;
  if (base.startsWith(TP)) base = base.slice(3);
  const at = base.indexOf('@');
  if (at > 0) base = base.substring(0, at);
  return base.split('.').length;
}

function markerOf(tag) {
  const at = tag.indexOf('@');
  return at > 0 ? tag.substring(at + 1) : '';
}

// Check depth rules when tags are bound to a declaration.
function checkBound(tags, kind, file, vline) {
  for (const t of tags.split(' ')) {
    if (!t) continue;
    const ns = nseg(t);
    const mk = markerOf(t);
    if (mk && kind === 'test') emitV('format', file, vline, `${t} marker on test`);
    if (mk && ns === 2) emitV('format', file, vline, `${t} marker on feature tag`);
  }
}

// Determine if a TS AST node is a declaration we recognize.
// Returns { name, isTest, isDecl } or null.
function classifyNode(node, sourceFile, depth) {
  const sk = ts.SyntaxKind;

  switch (node.kind) {
    case sk.FunctionDeclaration: {
      const name = node.name ? node.name.text : '(anonymous)';
      return { name, isDecl: true };
    }
    case sk.ClassDeclaration: {
      const name = node.name ? node.name.text : '(anonymous)';
      return { name, isDecl: true };
    }
    case sk.InterfaceDeclaration:
      return { name: node.name.text, isDecl: true };
    case sk.TypeAliasDeclaration:
      return { name: node.name.text, isDecl: true };
    case sk.EnumDeclaration:
      return { name: node.name.text, isDecl: true };
    case sk.ModuleDeclaration:
      return { name: node.name.text, isDecl: true };
    case sk.VariableStatement: {
      // Only top-level or namespace-level variable statements are declarations.
      // Depth 0 = module-level, depth 1 = namespace-level.
      if (depth > 1) return null;
      const decls = node.declarationList.declarations;
      if (decls.length === 0) return null;
      const first = decls[0];
      const name = first.name.getText(sourceFile);
      return { name, isDecl: true };
    }
    case sk.ExportAssignment: {
      // export default ... — treat as declaration
      return { name: 'default', isDecl: true };
    }
    default:
      return null;
  }
}

// Check if a node is a class/interface member we should treat as a declaration boundary.
function classifyMember(node, sourceFile) {
  const sk = ts.SyntaxKind;
  switch (node.kind) {
    case sk.MethodDeclaration:
    case sk.GetAccessor:
    case sk.SetAccessor:
    case sk.Constructor: {
      const name = node.name ? node.name.getText(sourceFile) : 'constructor';
      return { name, isDecl: true };
    }
    case sk.PropertyDeclaration: {
      const name = node.name ? node.name.getText(sourceFile) : '(property)';
      return { name, isDecl: true };
    }
    default:
      return null;
  }
}

// Test detection: check if a line matches `it(`, `test(`, `it.only(`, `test.each(` etc.
function classifyTest(line) {
  const m = line.match(/^\s*(?:it|test)(?:\.(only|skip|concurrent|each\([^)]*\)))*\s*\(\s*(['"`])((?:(?!\2).)*)\2/);
  if (m) return { name: m[3] };

  // describe.each, test.each with template literal
  const m2 = line.match(/^\s*(?:it|test)(?:\.(only|skip|concurrent|each))*\s*\(\s*`([^`]*)`/);
  if (m2) return { name: m2[2] };

  return null;
}

// Get the starting line of a node, accounting for decorators (decorators are part of the declaration).
function declStartLine(node, sourceFile) {
  // If the node has decorators, use the first decorator's position.
  const decorators = ts.canHaveDecorators(node) ? ts.getDecorators(node) : undefined;
  if (decorators && decorators.length > 0) {
    return sourceFile.getLineAndCharacterOfPosition(decorators[0].getStart(sourceFile)).line + 1;
  }
  return sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;
}

// Main scanning function for a single file.
function scanFile(filePath) {
  let source;
  try {
    source = readFileSync(filePath, 'utf-8');
  } catch {
    process.stderr.write(`ftags: scan-ts: cannot read ${filePath}\n`);
    emitE(filePath, 0);
    return;
  }

  const lines = source.split('\n');
  // If file ends with newline, last element is empty — that's correct, line count = lines.length
  // But if file doesn't end with newline, nlines = lines.length
  const nlines = source.endsWith('\n') ? lines.length - 1 : lines.length;
  const side = isTestFile(filePath) ? 'test' : 'prod';

  const isJSX = filePath.endsWith('.tsx') || filePath.endsWith('.jsx');
  const scriptKind = isJSX ? ts.ScriptKind.TSX : undefined;
  const sourceFile = ts.createSourceFile(filePath, source, ts.ScriptTarget.Latest, true, scriptKind);

  let seenDecl = false;
  let firstDeclLine = Infinity;
  const boundTagLines = new Set();

  // Parse tag groups from comments above a declaration.
  // Returns { tags, tagLine } or null.
  function findTagGroup(startLine) {
    // Walk backwards from startLine-1 looking for a tag group.
    // Pattern: tag-line, then blank line, then optional gap lines (comments, decorators handled by AST)
    // Actually for AST scanner: look upward from declaration for a tag-group comment.
    //
    // A tag group is a line that:
    //   1. contains only the comment marker followed by #f: tags
    //   2. is separated from the declaration by exactly one blank line
    //   3. optionally, between blank line and declaration: doc-comments, decorators (handled by AST)
    //
    // We look backwards from the declaration start (which includes decorators) for:
    //   blank line -> tag line

    let i = startLine - 2; // 0-based, one line before declaration
    if (i < 0) return null;

    // Skip blank lines (but only one allowed between tag group and what follows)
    // First, find the first non-blank line above the declaration.
    // Between tag-group and declaration, GAP_RE lines (comments) and blank lines are allowed.
    // But per spec: exactly one blank line required after tag group.

    // Walk up through gap: blank lines and comment lines (// lines).
    // Per spec: a second blank line breaks the link between tag group and declaration.
    let blankCount = 0;
    while (i >= 0) {
      const line = lines[i];
      if (/^\s*$/.test(line)) { blankCount++; i--; continue; }
      if (/^\s*\/\//.test(line) && line.indexOf(TP) < 0) { i--; continue; }
      // JSDoc: /** ... */ lines
      if (/^\s*\/?\*/.test(line) && line.indexOf(TP) < 0) { i--; continue; }
      break;
    }

    if (i < 0) return null;

    const candidate = lines[i];
    // Check if this line is a tag line
    if (candidate.indexOf(TP) < 0) return null;

    // Find the comment marker
    const cmIdx = candidate.lastIndexOf(CM);
    if (cmIdx < 0) return null;

    const pre = candidate.substring(0, cmIdx);
    const post = candidate.substring(cmIdx + CM.length);

    // Tag line: pre must be whitespace only
    if (!/^\s*$/.test(pre)) return null;

    // Check strict format
    if (!STRICT_TAG_LINE_RE.test(post)) {
      emitV('text', filePath, i + 1, candidate.trim().substring(0, 100));
    }

    const tags = parseTags(post, filePath, i + 1);

    // Second blank line breaks the link (spec: "вторую пустую разрывает связь").
    // blankCount tracks total blank lines in the gap between tag line and declaration.
    if (blankCount >= 2) {
      emitV('placement', filePath, i + 1, 'second blank line breaks the link');
      boundTagLines.add(i + 1); // prevent Phase 2 double-report
      return null;
    }

    // Verify blank line separation: there must be at least one blank line between tag line and declaration
    // (or comments between them)
    if (i + 1 < startLine - 1) {
      // Check if the line right after the tag line is blank or a comment
      const nextLine = lines[i + 1];
      if (!/^\s*$/.test(nextLine) && !/^\s*\/\//.test(nextLine) && !/^\s*\/?\*/.test(nextLine)) {
        emitV('placement', filePath, i + 1, 'blank line required after tag group');
      }
    } else if (i + 1 === startLine - 1) {
      // Tag line is directly above declaration — no blank line
      emitV('placement', filePath, i + 1, 'blank line required after tag group');
    }

    boundTagLines.add(i + 1);
    return { tags, tagLine: i + 1 };
  }

  // Process declarations recursively.
  function processDeclarations(parent, depth) {
    ts.forEachChild(parent, node => {
      const info = classifyNode(node, sourceFile, depth);
      if (info && info.isDecl) {
        const startLine = declStartLine(node, sourceFile);

        // Mark as seen
        seenDecl = true;
        if (startLine < firstDeclLine) firstDeclLine = startLine;

        // Look for tag group
        const tg = findTagGroup(startLine);

        // For test files, check if declaration is a test call (it/test at this line)
        let kind = 'decl';
        let name = info.name;

        if (side === 'test') {
          const lineText = lines[startLine - 1] || '';
          const testInfo = classifyTest(lineText);
          if (testInfo) {
            kind = 'test';
            name = testInfo.name;
          }
        }

        const tags = tg ? tg.tags : '';
        emitD(filePath, startLine, kind, side, name, tags);
        if (tg && tags) {
          checkBound(tags, kind, filePath, tg.tagLine);
        }

        // Recurse into class/interface/namespace members
        if (node.kind === ts.SyntaxKind.ClassDeclaration ||
            node.kind === ts.SyntaxKind.InterfaceDeclaration) {
          processMembers(node, depth + 1);
        }
        if (node.kind === ts.SyntaxKind.ModuleDeclaration) {
          // Namespace body
          const body = node.body;
          if (body && body.kind === ts.SyntaxKind.ModuleBlock) {
            processDeclarations(body, depth + 1);
          }
        }
      } else if (node.kind === ts.SyntaxKind.ExpressionStatement && side === 'test') {
        // Check for it()/test() calls at top level or inside describe()
        const lineNum = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;
        const lineText = lines[lineNum - 1] || '';
        const testInfo = classifyTest(lineText);
        if (testInfo) {
          seenDecl = true;
          if (lineNum < firstDeclLine) firstDeclLine = lineNum;
          const tg = findTagGroup(lineNum);
          const tags = tg ? tg.tags : '';
          emitD(filePath, lineNum, 'test', side, testInfo.name, tags);
          if (tg && tags) {
            checkBound(tags, 'test', filePath, tg.tagLine);
          }
        }
        // Also recurse into describe() blocks to find nested it/test
        processTestBlock(node, depth + 1);
      } else if (node.kind === ts.SyntaxKind.ExpressionStatement) {
        // Non-test expression statement — might contain describe() with tests
        // Skip in prod mode
      }
    });
  }

  // Process class/interface members.
  function processMembers(classNode, depth) {
    ts.forEachChild(classNode, node => {
      const info = classifyMember(node, sourceFile);
      if (info && info.isDecl) {
        const startLine = declStartLine(node, sourceFile);

        seenDecl = true;
        const tg = findTagGroup(startLine);
        const tags = tg ? tg.tags : '';
        emitD(filePath, startLine, 'decl', side, info.name, tags);
        if (tg && tags) {
          checkBound(tags, 'decl', filePath, tg.tagLine);
        }
      }
    });
  }

  // Process describe() blocks to find nested it/test calls.
  // Each describe level adds ~4 AST hops (ExpressionStatement -> CallExpression
  // -> ArrowFunction -> Block), so 50 supports ~12 levels of nesting.
  function processTestBlock(node, depth) {
    if (depth > 50) return; // safety limit

    ts.forEachChild(node, child => {
      if (child.kind === ts.SyntaxKind.ExpressionStatement) {
        const lineNum = sourceFile.getLineAndCharacterOfPosition(child.getStart(sourceFile)).line + 1;
        const lineText = lines[lineNum - 1] || '';
        const testInfo = classifyTest(lineText);
        if (testInfo) {
          seenDecl = true;
          if (lineNum < firstDeclLine) firstDeclLine = lineNum;
          const tg = findTagGroup(lineNum);
          const tags = tg ? tg.tags : '';
          emitD(filePath, lineNum, 'test', side, testInfo.name, tags);
          if (tg && tags) {
            checkBound(tags, 'test', filePath, tg.tagLine);
          }
        }
      }
      // Recurse into any child nodes that might contain describe blocks
      processTestBlock(child, depth + 1);
    });
  }

  // Phase 1: collect all declarations from AST
  processDeclarations(sourceFile, 0);

  // Phase 2: detect unbound standalone tag lines and trailing tags on any line.
  for (let i = 0; i < nlines; i++) {
    const line = lines[i];
    if (line.indexOf(TP) < 0) continue;

    const cmIdx = line.lastIndexOf(CM);
    if (cmIdx < 0) {
      // Tag without comment marker (e.g. inside a string or template)
      emitV('text', filePath, i + 1, line.trim().substring(0, 100));
      continue;
    }

    const pre = line.substring(0, cmIdx);
    const post = line.substring(cmIdx + CM.length);

    if (/^\s*$/.test(pre)) {
      // Standalone tag line — skip if already bound to a declaration by findTagGroup
      if (boundTagLines.has(i + 1)) continue;
      // Unbound: classify as file-header or placement
      if (i + 1 < firstDeclLine || !seenDecl) {
        emitV('file', filePath, i + 1, 'tag group in file header');
      } else {
        emitV('placement', filePath, i + 1, 'tag group not followed by a declaration');
      }
      continue;
    }

    // Trailing tag on a code line
    if (branchRE && branchRE.test(pre)) {
      const tags = parseTags(post, filePath, i + 1);
      if (tags) {
        emitD(filePath, i + 1, 'branch', side, pre.trim().substring(0, 60), tags);
        checkBound(tags, 'branch', filePath, i + 1);
      }
    } else {
      emitV('placement', filePath, i + 1, 'trailing tag not on a branch line');
    }
  }

  emitE(filePath, nlines);
}

// Read file list and process each file.
function main() {
  let listContent;
  try {
    listContent = readFileSync(LIST_PATH, 'utf-8');
  } catch {
    process.stderr.write(`ftags: scan-ts: cannot read file list ${LIST_PATH}\n`);
    process.exit(2);
  }

  const files = listContent.split('\n').filter(f => f.trim());
  for (const f of files) {
    scanFile(f);
  }
}

main();
