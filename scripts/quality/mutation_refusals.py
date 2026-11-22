# The part of scripts/quality/check-mutation-coverage.sh that reads a script or a workflow and
# finds its refusals, kept apart from the part that holds them to the catalogue so that
# neither passes the size limit. This file refuses nothing itself; the check imports it.
# Its own tests are tests/quality/check-mutation-coverage.test.sh.
#
# WHAT IS A REFUSAL
#
# A line of code, comments and quoted text aside, that exits with a non-zero
# status: `exit N`, an `exit` that hands on a status it holds in a variable
# (`exit "$rc"`, `exit $?`), a call of `fail` where the file defines that helper,
# `return N` in the shell of a function (`return 1` is one; `return 0`, a bare
# `return` and `return "$rc"` are not), or, in
# the Python a script carries, `sys.exit(...)` or `raise SystemExit(...)` whose
# argument is a non-zero integer or starts with a string: `sys.exit(3)`,
# `sys.exit("no index")`, `sys.exit(f"cannot read {path}")`,
# `raise SystemExit("no index")`. Python prints a string argument and exits
# with status 1, which is how most of the Python in a script here refuses.
# `sys.exit(0)`, `sys.exit()`, `sys.exit(None)` and a bare `raise SystemExit`
# end the program well and are not refusals. The refusal is the statement that
# leads to it: the condition on the same line
# (`[ ... ] || exit 1`) and the lines it continues, or else the block that
# holds it, from its header (`if`, `elif`, a `case` arm, `|| {`, a Python
# `if`/`except`) down to the refusal. A refusal with no enclosing block reaches
# back to the start of the statement before it.
#
# A function that returns 1 hands the refusal to its caller, which decides what
# it means: `installed` in package-state.sh returns 1 for a package dpkg does
# not list, and the caller refuses on it. The `return 1` is the place a mutation
# removes that refusal, so it is read as one. A function that returns 1 to say
# "no" to a question, and not to refuse, is read the same way, and is exempted
# with that reason. A `return` inside Python is Python returning a value, and is
# not read.
#
# A refusal directly in the body of a function is not guarded by the function:
# it reaches back to the statement before it, as one at the top level does, so
# an entry elsewhere in the same function does not cover it.
#
# An `exit` with a status in a variable is the last line of a step or a script
# that collected a verdict on the way: the job that runs every suite, a watcher
# that reports what its script answered. Changed to `exit 0`, nothing it
# collected reaches the caller, so it is read as a refusal, though the status
# may be 0 on a given run. `return "$rc"` and `sys.exit(message)` with a
# message in a variable are not read: a helper that hands a status back to its
# caller refuses nothing itself, and one that refuses that way is invisible
# here.

import re

EXIT = re.compile(r"(?<![\w$.-])exit\s+[1-9][0-9]*\b")
# An exit that hands on a status: a quoted word (read as STRING, see code_of) or
# an expansion.
EXIT_HANDED = re.compile(r"(?<![\w$.-])exit\s+(?:" + "\x01" + r"|\$[{A-Za-z_?])")
RETURN = re.compile(r"(?<![\w$.-])return\s+[1-9][0-9]*\b")
# A heredoc handed to python3, and the word that ends it.
PY_HEREDOC = re.compile(r"\bpython3\b[^\n]*<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
# The key of a `run:` step: a block scalar (`run: |`, `run: >-`, `- run: |`, a
# comment after it) or a command on the same line.
RUN_BLOCK = re.compile(r"^(\s*(?:-\s+)?)run:\s*[|>][-+]?[0-9]*\s*(?:#.*)?$")
RUN_LINE = re.compile(r"^(\s*(?:-\s+)?run:\s*)\S")
# A quote is read as STRING (see code_of) so a string argument can be told from
# `sys.exit()`, whose parentheses hold nothing.
STRING = "\x01"
PY_EXIT = re.compile(r"\b(?:sys\.exit|raise\s+SystemExit)\(\s*(?:[1-9][0-9]*\s*\)|[rRbBfFuU]{0,2}" + STRING + ")")
FAIL_CALL = re.compile(r"(?:^|[\s;&|{(])fail(?=\s|$)")
FAIL_DEF = re.compile(r"^\s*fail\s*\(\)\s*\{?")
PY_FAIL_CALL = re.compile(r"(?<![\w.])fail\(")
# The first line of a function, shell or Python.
FUNC_DEF = re.compile(r"^\s*(?:def\s+\w+\s*\(|function\s+[\w-]+|[\w-]+\s*\(\)\s*\{?\s*$)")
PY_FAIL_DEF = re.compile(r"^\s*def\s+fail\s*\(")
# The first line of a block: a shell `if`, `elif`, `else`, loop, `case` arm or
# `{`, or a Python statement that ends with a colon. A line with less
# indentation that is none of these (a YAML key, a heredoc that starts the
# Python of a script) is not a block of this code, and a refusal under it is at
# the top level.
HEADER = re.compile(r"^(?:if|elif|else|while|until|for|case|except|try|with|def)\b"
                    r"|(?:\bthen|\bdo|\{|\)|:|\bin)$")


def is_python(rel):
    return rel.endswith(".py")


def shell_of(lines):
    """The lines of a workflow with everything but the shell of its `run:` steps blanked."""
    out = [""] * len(lines)
    n = 0
    while n < len(lines):
        block = RUN_BLOCK.match(lines[n])
        inline = RUN_LINE.match(lines[n])
        if block:
            key = len(block.group(1).expandtabs(8))
            n += 1
            while n < len(lines) and (not lines[n].strip() or indent(lines[n]) > key):
                out[n] = lines[n]
                n += 1
            continue
        if inline:
            out[n] = " " * len(inline.group(1)) + lines[n][len(inline.group(1)):]
        n += 1
    return out


def python_lines(lines):
    """0-based numbers of the lines of a heredoc handed to python3."""
    inside, n = set(), 0
    while n < len(lines):
        start = PY_HEREDOC.search(lines[n])
        if not start or "python3" not in code_of(lines[n]):
            n += 1
            continue
        tag = start.group(1)
        n += 1
        while n < len(lines) and lines[n].strip() != tag:
            inside.add(n)
            n += 1
        n += 1
    return inside


def code_of(line, mark=" "):
    """The line with quoted text and a trailing comment removed; a quote leaves `mark`."""
    out, quote, i = [], None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c
            out.append(mark)
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def indent(line):
    expanded = line.expandtabs(8)
    return len(expanded) - len(expanded.lstrip())


def blank(line):
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def refusals(rel, lines):
    """(first line, refusal line) of every refusal, 0-based."""
    pyfile = is_python(rel)
    defines_fail = any((PY_FAIL_DEF if pyfile else FAIL_DEF).match(line) for line in lines)
    python = set(range(len(lines))) if pyfile else python_lines(lines)
    found = []
    for n, line in enumerate(lines):
        if blank(line):
            continue
        code = code_of(line)
        if FAIL_DEF.match(line) or PY_FAIL_DEF.match(line):
            continue
        if pyfile:
            hit = PY_EXIT.search(code_of(line, STRING)) or (defines_fail and PY_FAIL_CALL.search(code))
        else:
            hit = EXIT.search(code) or (n not in python and EXIT_HANDED.search(code_of(line, STRING))) \
                or PY_EXIT.search(code_of(line, STRING)) \
                or (defines_fail and FAIL_CALL.search(code)) \
                or (n not in python and RETURN.search(code))
        if not hit:
            continue
        start = statement_start(lines, n)
        before = " ".join(code_of(lines[i]) for i in range(start, n)) + code[:hit.start()]
        if "||" in before or "&&" in before:
            span = (start, n)
        else:
            header = enclosing(lines, start)
            if header is not None and (FAIL_DEF.match(lines[header]) or PY_FAIL_DEF.match(lines[header])):
                continue
            # A function is not the guard of a refusal in its body: the statement
            # before the refusal is, as at the top level.
            if header is not None and FUNC_DEF.match(lines[header]):
                header = None
            span = (header if header is not None else sibling(lines, start), n)
        found.append(span)
    return found


def statement_start(lines, n):
    i = n
    while i > 0:
        stripped = lines[i].strip()
        if stripped.startswith(("||", "&&", "|")) or lines[i - 1].rstrip().endswith("\\"):
            i -= 1
            continue
        break
    return i


def enclosing(lines, n):
    """The header of the block that holds line n, or None at the top level."""
    level = indent(lines[n])
    for i in range(n - 1, -1, -1):
        if blank(lines[i]):
            continue
        if indent(lines[i]) < level:
            head = statement_start(lines, i)
            code = code_of(lines[i]).strip()
            if not HEADER.search(code) and not HEADER.search(code_of(lines[head]).strip()):
                return None
            if code.startswith(("else", "elif")):
                return opening_if(lines, i) or head
            return head
    return None


def opening_if(lines, n):
    level = indent(lines[n])
    for i in range(n - 1, -1, -1):
        if blank(lines[i]) or indent(lines[i]) != level:
            continue
        if lines[i].strip().startswith("if"):
            return statement_start(lines, i)
    return None


def sibling(lines, n):
    level = indent(lines[n])
    for i in range(n - 1, -1, -1):
        if blank(lines[i]):
            continue
        if indent(lines[i]) <= level:
            return statement_start(lines, i)
    return n
