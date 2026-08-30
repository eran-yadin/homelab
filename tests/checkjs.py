#!/usr/bin/env python3
"""Structural check for the JS inside hub/index.html.

Not a parser -- there is no JS engine on this machine -- but it scans with
enough understanding of the language to be trustworthy about bracket balance:
it skips line and block comments, single/double-quoted strings, template
literals including nested ${...}, and regex literals.

Regex literals are the fiddly part. `/` is division or the start of a regex
depending on what came before it, so we track that: after a value (identifier,
number, closing bracket) a slash is division; otherwise it starts a regex.
Without this, a pattern like /"/g reads as an unterminated string and the
whole file appears unbalanced.

Usage: tests/checkjs.py [file ...]   (default: hub/index.html)
"""
import re
import sys

PAIRS = {')': '(', ']': '[', '}': '{'}
# A slash right after one of these is division, not a regex.
VALUE_END = re.compile(r'[)\]}\w$]')
KEYWORDS_BEFORE_REGEX = {
    'return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete',
    'void', 'throw', 'case', 'do', 'else', 'yield', 'await',
}


def extract_js(text):
    if '<script>' not in text:
        return text
    return text[text.index('<script>') + len('<script>'): text.rindex('</script>')]


def check(js):
    i, n = 0, len(js)
    line = 1
    stack, errs = [], []
    prev = ''          # last significant character
    prev_word = ''     # last identifier, for the keyword cases

    while i < n:
        c = js[i]

        if c == '\n':
            line += 1; i += 1; continue
        if c in ' \t\r':
            i += 1; continue

        if c == '/' and i + 1 < n and js[i + 1] == '/':
            while i < n and js[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and js[i + 1] == '*':
            i += 2
            while i + 1 < n and not (js[i] == '*' and js[i + 1] == '/'):
                if js[i] == '\n':
                    line += 1
                i += 1
            i += 2; continue

        if c == '/':
            is_regex = (not prev) or prev_word in KEYWORDS_BEFORE_REGEX \
                or not VALUE_END.match(prev)
            if is_regex:
                i += 1
                in_class = False
                while i < n:
                    if js[i] == '\\':
                        i += 2; continue
                    if js[i] == '[':
                        in_class = True
                    elif js[i] == ']':
                        in_class = False
                    elif js[i] == '/' and not in_class:
                        break
                    elif js[i] == '\n':
                        errs.append(f"line {line}: unterminated regex")
                        break
                    i += 1
                i += 1
                while i < n and js[i].isalpha():   # flags
                    i += 1
                prev, prev_word = 'x', ''
                continue
            prev, prev_word = '/', ''
            i += 1; continue

        if c in "'\"":
            q, start = c, line
            i += 1
            while i < n and js[i] != q:
                if js[i] == '\\':
                    i += 1
                elif js[i] == '\n':
                    errs.append(f"line {start}: unterminated string")
                    break
                i += 1
            i += 1
            prev, prev_word = 'x', ''
            continue

        if c == '`':
            i += 1
            while i < n:
                if js[i] == '\\':
                    i += 2; continue
                if js[i] == '`':
                    break
                if js[i] == '$' and i + 1 < n and js[i + 1] == '{':
                    depth = 1
                    i += 2
                    while i < n and depth:
                        if js[i] == '{':
                            depth += 1
                        elif js[i] == '}':
                            depth -= 1
                        elif js[i] == '\n':
                            line += 1
                        i += 1
                    continue
                if js[i] == '\n':
                    line += 1
                i += 1
            i += 1
            prev, prev_word = 'x', ''
            continue

        if c in '([{':
            stack.append((c, line))
            prev, prev_word = c, ''
            i += 1; continue

        if c in ')]}':
            if not stack:
                errs.append(f"line {line}: stray '{c}'")
            elif stack[-1][0] != PAIRS[c]:
                op, ol = stack.pop()
                errs.append(f"line {line}: '{c}' closes '{op}' opened at line {ol}")
            else:
                stack.pop()
            prev, prev_word = c, ''
            i += 1; continue

        if c.isalnum() or c in '_$':
            j = i
            while j < n and (js[j].isalnum() or js[j] in '_$'):
                j += 1
            prev_word = js[i:j]
            prev = js[j - 1]
            i = j; continue

        prev, prev_word = c, ''
        i += 1

    for ch, ln in stack:
        errs.append(f"unclosed '{ch}' opened at line {ln}")
    return errs


def main(paths):
    bad = 0
    for p in paths:
        js = extract_js(open(p).read())
        errs = check(js)
        if errs:
            bad = 1
            print(f"{p}: FAIL")
            for e in errs:
                print(f"  {e}")
        else:
            print(f"{p}: ok ({len(js.splitlines())} lines of js, brackets balanced)")
    return bad


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:] or ['hub/index.html']))
