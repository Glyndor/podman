#!/usr/bin/env bash
#
# Decide which suites a change can affect, and write the decision where the step
# that runs the suites reads it.
#
# This script is read from the BASE commit, never from the checkout of the pull
# request it is judging: a pull request that rewrites the decision to hide its
# own suites gets the full set instead. That is the rule for a gate script: a
# gate script is read from the base commit, never from the checkout of the pull
# request it is judging. The resolver it reads is read from the base commit for
# the same reason.
#
# Everything fails open. Any event but a pull request, a resolver that cannot be
# read from the base commit or that ends in an error, a decision that names a
# suite this job was not given: all of them run every suite. A wrong skip lets a
# change merge untested; a wrong run costs seconds, and the asymmetry decides
# every borderline case in favour of running.
#
# It writes two things:
#   * $RUNNER_TEMP/suite-scope.list: the suites to run, one per line. A file that
#     names nothing means every suite, which is what the step that runs them
#     does with it.
#   * $GITHUB_OUTPUT: mldsa=true|false, whether the wheel of the ML-DSA-65 suite
#     has to be installed.
#
# Environment: EVENT (the event name), RUNNER_TEMP and GITHUB_OUTPUT.
set -euo pipefail

EVENT="${EVENT:-}"

# The suites this change can affect are decided by the resolver and the map of
# the BASE commit, never as this pull request ships them.
mapfile -t suites < <(find tests -name '*.test.sh' | LC_ALL=C sort)
total=${#suites[@]}
resolver="$RUNNER_TEMP/ci-job-scope.sh"
scope_file="$RUNNER_TEMP/suite-scope.list"
decision=""
if [ "$EVENT" = pull_request ] \
  && git show "HEAD^1:scripts/quality/scope/ci-job-scope.sh" > "$resolver" 2>/dev/null; then
	# A resolver that ends in an error decided nothing, whatever it had
	# printed by then.
	if ! decision="$(bash "$resolver" suites "${suites[@]}")"; then
		echo "the resolver of the base commit ended in an error; every suite runs."
		decision=""
	fi
fi
# A decision is only a decision when every name in it is a suite this job was
# given. Anything else means the scope could not be established, and an
# established scope is the only thing that may skip a suite.
usable=1
[ -n "$decision" ] || usable=0
while IFS= read -r name; do
	[ -n "$name" ] || continue
	case " ${suites[*]} " in
		*" $name "*) ;;
		*) usable=0 ;;
	esac
done <<< "$decision"
if [ "$usable" = 1 ]; then
	mapfile -t selected <<< "$decision"
else
	selected=("${suites[@]}")
fi
: > "$scope_file"
for name in "${selected[@]}"; do
	if [ -n "$name" ]; then
		printf '%s\n' "$name" >> "$scope_file"
	fi
done
echo "scope: ${#selected[@]} of $total suites can be affected by this change; the rest cannot."
# The wheel of the ML-DSA-65 suite is installed unless it is certain that no
# suite that runs needs it: each of them is named otherwise than
# *-mldsa.test.sh, the pattern the step below runs on the wheel, and the
# dependency map of the base commit says once that it needs nothing. A suite the
# map does not know, a line it cannot be read from and a base without the map all
# install it.
mldsa=false
deps="$(git show "HEAD^1:scripts/quality/scope/suite-dependencies.txt" 2>/dev/null || true)"
for name in "${selected[@]}"; do
	[ -n "$name" ] || continue
	case "$name" in
		*-mldsa.test.sh) mldsa=true ;;
	esac
	entry="$(awk -v suite="$name" '$1 == suite { print NF, $2 }' <<< "$deps")"
	[ "$entry" = "2 -" ] || mldsa=true
done
echo "mldsa=$mldsa" >> "$GITHUB_OUTPUT"
