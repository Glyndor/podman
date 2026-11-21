# shellcheck shell=bash
#
# syntax_ok <file>: whether a file still parses after a mutation, for
# tests/mutation/run-mutations.sh, which sources this file and sets WORK first.
# A mutant that does not parse makes its suites red for a reason that is not the
# guard, so the runner does not count it as killed. Returns 0 when the file
# parses, 1 when it does not, and 2 when no check is known for its kind.
#
# A shell script is read with `bash -n`, and the Python it hands to python3 in a
# heredoc is compiled too; a Python file is compiled; a workflow is parsed as YAML
# and the shell of each of its steps is read with `bash -n`.
syntax_ok() { # <file> -> 0 when it parses, 1 when it does not, 2 when no check is known
	local rc=0
	case "$1" in
	*.py)
		PYTHONPYCACHEPREFIX="$WORK/pycache" python3 -m py_compile "$1" >/dev/null 2>&1 || rc=1
		;;
	*.yml | *.yaml)
		# A workflow is parsed as YAML, which is how the suites read it, and the
		# shell of each of its steps is read as bash, which is how GitHub runs it.
		rm -rf "$WORK/steps"
		mkdir -p "$WORK/steps"
		python3 -I - "$1" "$WORK/steps" <<-'PY' >/dev/null 2>&1 || return 1
			import sys
			import yaml

			doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
			n = 0
			for job in (doc.get("jobs") or {}).values():
			    for step in (job or {}).get("steps") or []:
			        if "run" in step:
			            n += 1
			            with open(f"{sys.argv[2]}/{n}.sh", "w", encoding="utf-8") as fh:
			                fh.write(str(step["run"]))
		PY
		for step in "$WORK"/steps/*.sh; do
			[ -e "$step" ] || continue
			bash -n "$step" >/dev/null 2>&1 || rc=1
		done
		;;
	*.sh | *.bash)
		bash -n "$1" >/dev/null 2>&1 || rc=1
		# A shell script of this repository carries python in a heredoc, and
		# `bash -n` cannot see it. A mutation that breaks the python would
		# leave a script that dies of a syntax error, which reads as a kill
		# of a guard that was never removed.
		[ "$rc" -eq 0 ] || return "$rc"
		python3 -I - "$1" <<-'PY' >/dev/null 2>&1 || rc=1
			import re
			import sys

			# Every heredoc this file hands to python3, and its body. Only
			# those: a heredoc that carries shell or text is not python and
			# compiling it would fail a file that is perfectly correct.
			pattern = re.compile(r"python3[^\n]*<<-?'([A-Za-z_][A-Za-z0-9_]*)'")
			lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
			bodies = []
			for index, line in enumerate(lines):
			    match = pattern.search(line)
			    if not match:
			        continue
			    tag = match.group(1)
			    body = []
			    for following in lines[index + 1:]:
			        if following.strip() == tag:
			            break
			        body.append(following)
			    else:
			        # An unterminated heredoc: the shell parser is the
			        # authority on that, not this.
			        body = None
			        break
			    if body is not None:
			        bodies.append("\n".join(body))
			for body in bodies:
			    compile(body, sys.argv[1], "exec")
		PY
		;;
	*)
		# A script without an extension is shell when its shebang says so.
		head -n 1 "$1" 2>/dev/null \
			| grep -qE '^#!.*(/| )(sh|bash|dash)([[:space:]]|$)' || return 2
		shell="$(head -n 1 "$1" 2>/dev/null)"
		case "$shell" in
		*bash*) bash -n "$1" >/dev/null 2>&1 || rc=1 ;;
		*) sh -n "$1" >/dev/null 2>&1 || rc=1 ;;
		esac
		;;
	esac
	return "$rc"
}

