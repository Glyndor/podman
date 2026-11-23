#!/usr/bin/env bash
#
# Runs the steps of the probe in order inside the container of the distribution under
# test, each with a log of its own, and records how each ended: ok, fail, or skip when a
# step said (exit 3) it had nothing to work on. A failed step does not stop the next one,
# so one run measures as much as the distribution allows. The first error is cut out of
# its log with the lines before and after it, for the result to quote.
#
# Usage: run.sh   (as root; PODMAN_TAG and PODMAN_IMAGE come from the environment)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

# first_error <step> <log>: the line the step marked as its failure, or else the first
# line that looks like an error, with 30 lines before it and 9 after it.
first_error() {
	local step="$1" log="$2" line
	[ ! -s "$PROBE_OUT/first-error.txt" ] || return 0
	line="$(grep -n -m1 'PROBE-FAIL' "$log" | cut -d: -f1)"
	[ -n "$line" ] || line="$(grep -n -m1 -i -E 'error|fatal|failed|cannot|no match|unable to' "$log" | cut -d: -f1)"
	[ -n "$line" ] || line="$(wc -l < "$log")"
	{
		echo "step: $step (line $line of its log)"
		sed -n "$((line > 30 ? line - 30 : 1)),$((line + 9))p" "$log"
	} > "$PROBE_OUT/first-error.txt"
}

for step in 01-toolchain 02-build 03-install 04-inventory 04b-short-deps 05-boot; do
	log="$PROBE_OUT/logs/$step.log"
	echo "::group::$step"
	bash "$here/$step.sh" 2>&1 | tee "$log"
	rc="${PIPESTATUS[0]}"
	echo "::endgroup::"
	case "$rc" in
		0) fact "step.$step" ok ;;
		3) fact "step.$step" skip ;;
		*) fact "step.$step" fail; first_error "$step" "$log" ;;
	esac
done

grep -q -P '^step\.[0-9a-z-]+\tfail$' "$PROBE_OUT/facts.tsv" && exit 1
exit 0
