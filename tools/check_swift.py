#!/usr/bin/env python3
"""Catches Swift mistakes before the macOS CI does (cloud sessions have no Swift compiler).

Usage: python3 tools/check_swift.py [--base REV] [FILE...]

Without files it checks every .swift file changed against REV (default origin/master, plus
uncommitted changes). Two checks:

  syntax    tree-sitter-swift parse errors that the file did not already have at REV. The grammar
            is not the compiler: it misses type errors, and a few valid constructs parse as errors
            (Sibionics2Configuration.swift and LibreNFC.swift have some), which is why only errors
            new since REV are reported.
  pitfalls  patterns that compiled here but broke the CI build before:
            * `super.` inside an escaping closure ("using 'super' in a closure where 'self' is
              explicitly captured is not yet supported") - call it from a private method instead;
            * `%` in a Double context (Date(timeIntervalSince1970:), TimeInterval(...)) - '%' is
              unavailable for floating point; precompute the value or use truncatingRemainder;
            * `data.append(1)` / `data.append(flag ? 1 : 0)` on a Data value: the untyped literal
              selects Data.append<Int> and writes eight bytes, not one - write `UInt8(...)`.

The parser is installed on first use with pip into tools/.tslib (git-ignored):
tree-sitter 0.26.0 and tree-sitter-swift 0.7.4.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "tools", ".tslib")


def parser():
    sys.path.insert(0, LIB)
    try:
        import tree_sitter_swift
        from tree_sitter import Language, Parser
    except ImportError:
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", "--target", LIB,
                        "tree-sitter==0.26.0", "tree-sitter-swift==0.7.4"], check=True)
        import importlib
        importlib.invalidate_caches()
        import tree_sitter_swift
        from tree_sitter import Language, Parser
    return Parser(Language(tree_sitter_swift.language()))


def syntax_errors(swift_parser, source):
    found = []

    def walk(node):
        if node.type == "ERROR" or node.is_missing:
            found.append(node.start_point[0] + 1)
            return
        if node.has_error:
            for child in node.children:
                walk(child)

    walk(swift_parser.parse(source).root_node)
    return found


def git(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True)


def changed_files(base):
    names = set(git("diff", "--name-only", base, "--", "*.swift").stdout.split("\n"))
    names |= set(git("diff", "--name-only", "--", "*.swift").stdout.split("\n"))
    names |= set(git("ls-files", "--others", "--exclude-standard", "--", "*.swift").stdout.split("\n"))
    return sorted(os.path.join(ROOT, n) for n in names if n and os.path.exists(os.path.join(ROOT, n)))


CLOSURE_START = re.compile(r"\{\s*(\[[^\]]*\]\s*)?(\(?[\w\s,_]*\)?\s*)?in\s*$")
DOUBLE_CALL = re.compile(r"(timeIntervalSince1970:|TimeInterval\(|addingTimeInterval\()")


def modulo_in_double_argument(code):
    """`%` directly in the argument of a call taking a TimeInterval, not inside a nested call
    such as Double(index % 3), where it works on integers."""
    for match in DOUBLE_CALL.finditer(code):
        depth = 1 if match.group(1).endswith("(") else 0
        direct = []
        for character in code[match.end():]:
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth < 0 or (depth == 0 and match.group(1).endswith("(")):
                    break
            elif depth == (1 if match.group(1).endswith("(") else 0):
                if character == "," and not match.group(1).endswith("("):
                    break
                direct.append(character)
        if " % " in "".join(direct):
            return True
    return False


DATA_LITERAL_APPEND = re.compile(
    r"\b\w*[dD]ata\.append\(\s*(0x[0-9A-Fa-f]+|\d+|[^()]*\?\s*(0x[0-9A-Fa-f]+|\d+)\s*:\s*(0x[0-9A-Fa-f]+|\d+))\s*\)")


def pitfalls(lines):
    found = []
    for number, line in enumerate(lines):
        code = line.split("//")[0]
        if modulo_in_double_argument(code):
            found.append((number + 1, "'%' in a Double context"))
        if DATA_LITERAL_APPEND.search(code):
            found.append((number + 1, "Data.append with an untyped integer literal writes eight bytes"))
        if CLOSURE_START.search(code):
            depth = 0
            for offset, inner in enumerate(lines[number:number + 80]):
                inner_code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', inner.split("//")[0])
                if offset > 0 and re.search(r"\bsuper\.", inner_code) and depth > 0:
                    found.append((number + offset + 1, "`super.` inside a closure"))
                depth += inner_code.count("{") - inner_code.count("}")
                if depth <= 0 and offset > 0:
                    break
    return found


def main(arguments):
    base = "origin/master"
    if "--base" in arguments:
        index = arguments.index("--base")
        base = arguments[index + 1]
        arguments = arguments[:index] + arguments[index + 2:]
    files = [os.path.abspath(a) for a in arguments] or changed_files(base)
    swift_parser = parser()
    problems = 0
    for path in files:
        relative = os.path.relpath(path, ROOT)
        source = open(path, "rb").read()
        now = syntax_errors(swift_parser, source)
        before_text = git("show", f"{base}:{relative}")
        before = syntax_errors(swift_parser, before_text.stdout.encode()) if before_text.returncode == 0 else []
        # Errors are compared by count: lines move when code is added above them.
        if len(now) > len(before):
            print(f"{relative}: {len(now) - len(before)} new syntax error(s), parse errors at lines {now[:8]}")
            problems += 1
        for line, message in pitfalls(source.decode("utf-8", "replace").split("\n")):
            print(f"{relative}:{line}: {message}")
            problems += 1
    print(f"{len(files)} files, {problems} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
