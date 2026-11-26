#!/usr/bin/env python3
"""Checks the English and Ukrainian `.strings` tables of the app, widgets and watch.

Usage: python3 tools/check_strings.py            (every en.lproj / uk.lproj table)
       python3 tools/check_strings.py FILE...     (only these)

Reports, per table:
  * ERROR  a line the .strings grammar cannot parse (a missing `;` or an unescaped quote breaks
           the whole table at runtime: every key after it falls back to the English default);
  * ERROR  a key whose format specifiers differ between en and uk (`%@` vs `%d` crashes or prints
           garbage at runtime);
  * note   duplicate keys (allowed: the later one wins; upstream has a few) and keys present in
           en but missing in uk (shown with --missing; such a key shows the English text).
Exit status 1 when there is an ERROR.
"""
import os
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:[^"\\]|\\.)*"\s*=\s*"(?:[^"\\]|\\.)*"\s*;', re.S)
ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)
# No space flag: "25 % or less" is prose, not "% o".
SPECIFIER = re.compile(r'%(?:\d+\$)?[-+#0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%]')


def tables():
    for directory, _, files in os.walk(ROOT):
        if os.sep + "build" in directory or os.sep + "." in directory:
            continue
        if os.path.basename(directory) in ("en.lproj", "uk.lproj"):
            for name in files:
                if name.endswith(".strings"):
                    yield os.path.join(directory, name)


def parse(path):
    """The (key, value) entries of a table, or an error at the first line that does not parse."""
    text = open(path, encoding="utf-8").read()
    entries = []
    position = 0
    while position < len(text):
        match = TOKEN.match(text, position)
        if not match:
            line = text.count("\n", 0, position) + 1
            return None, f"{os.path.relpath(path, ROOT)}:{line}: cannot parse: {text[position:position + 60]!r}"
        entry = ENTRY.fullmatch(match.group(0).strip())
        if entry:
            entries.append(entry.groups())
        position = match.end()
    return entries, None


def specifiers(value):
    return sorted(s for s in SPECIFIER.findall(value) if s != "%%")


def main(arguments):
    show_missing = "--missing" in arguments
    files = [a for a in arguments if not a.startswith("--")] or sorted(tables())
    errors = 0
    parsed = {}
    for path in files:
        entries, problem = parse(path)
        if problem:
            print("ERROR", problem)
            errors += 1
            continue
        parsed[os.path.abspath(path)] = entries
        duplicates = [key for key, count in Counter(k for k, _ in entries).items() if count > 1]
        if duplicates:
            print(f"note  {os.path.relpath(path, ROOT)}: duplicate keys {duplicates[:6]}")
    for path, entries in parsed.items():
        if f"{os.sep}en.lproj{os.sep}" not in path:
            continue
        other = path.replace(f"{os.sep}en.lproj{os.sep}", f"{os.sep}uk.lproj{os.sep}")
        if other not in parsed:
            continue
        english = dict(entries)
        ukrainian = dict(parsed[other])
        for key, value in english.items():
            if key in ukrainian and specifiers(value) != specifiers(ukrainian[key]):
                print(f"ERROR {os.path.relpath(other, ROOT)}: \"{key}\" has {specifiers(ukrainian[key])}, en has {specifiers(value)}")
                errors += 1
        missing = [key for key in english if key not in ukrainian]
        if missing and show_missing:
            print(f"note  {os.path.relpath(other, ROOT)}: {len(missing)} keys only in en, e.g. {missing[:5]}")
    print(f"{len(files)} tables, {errors} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
