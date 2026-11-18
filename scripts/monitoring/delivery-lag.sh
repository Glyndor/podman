#!/usr/bin/env bash
#
# Say whether what this repository publishes has fallen behind upstream for too
# long. It looks at the result, not at the machinery: it does not ask whether the
# cron ran or the last run was green, because a cron that never fires, a schedule
# GitHub switched off, or a run that succeeds while publishing nothing all look
# fine from there. It asks the one question that matters: is there something
# upstream (or in how the package is built) that the newest release does not
# carry, and has it been there for more than <max-hours>?
#
# Inputs are files, so the decision can be tested without a network:
#   fresh     the components upstream has now, "<name> <tag>" per line, plus a
#             "recipe <id>" line for how the package is built
#   released  the components of the newest published release
#   tags      the release tags this repository already has
#   dates     "<name> <value> <epoch>": when each value in fresh appeared
#             (an upstream release's publication time, or the last commit that
#             changed how the package is built)
#   now       epoch seconds
#
# Exit 0: up to date, or behind for less than the limit. Exit 1: behind for
# longer. Exit 2: it could not decide, which the caller must treat as a failure
# too, never as "fine".
#
# Usage: delivery-lag.sh <fresh> <released> <tags> <dates> <now> <max-hours>

set -euo pipefail

fresh="${1:?fresh}"; released="${2:?released}"; tags="${3:?tags}"
dates="${4:?dates}"; now="${5:?now}"; max_hours="${6:?max-hours}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

plan="$("$here/../upstream/plan-release.sh" "$fresh" "$released" "$tags")" \
	|| { echo "cannot tell what the newest release carries" >&2; exit 2; }
case "$plan" in
	*build=false*) echo "the newest release carries everything upstream has"; exit 0 ;;
esac

newest=0
behind=""
while read -r name value; do
	[ -n "$name" ] || continue
	grep -qxF "$name $value" "$released" && continue
	when="$(awk -v n="$name" -v v="$value" '$1 == n && $2 == v {print $3}' "$dates")"
	[ -n "$when" ] || { echo "no date known for $name $value" >&2; exit 2; }
	behind="$behind $name"
	[ "$when" -le "$newest" ] || newest="$when"
done < "$fresh"

hours=$(( (now - newest) / 3600 ))
if [ "$hours" -gt "$max_hours" ]; then
	echo "behind upstream for $hours hours (limit $max_hours); not yet released:$behind" >&2
	exit 1
fi
echo "behind upstream for $hours hours, inside the $max_hours-hour limit; not yet released:$behind"
