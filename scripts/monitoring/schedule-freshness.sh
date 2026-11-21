#!/usr/bin/env bash
#
# Say whether a scheduled workflow has run lately. A cron that stops firing
# emits nothing, and no alert is indistinguishable from all clear, so the check
# lives on a path that does run: it reads the workflow's own scheduled runs.
#
# What counts as having run is a run that reached its end, green or red. A red
# run has fired and has its own alarm; this is about the silence, so a run that
# was cancelled, skipped or never started does not count.
#
# The input is a file, so the decision can be tested without a network: the JSON
# that `gh run list --workflow <file> --event schedule --json createdAt,conclusion`
# prints.
#
# A cron that was added a moment ago has not fired yet, and that is not a miss.
# With <scheduled-since-epoch>, the time its schedule began (the commit that added
# the workflow), no finished run is fine until <max-hours> after it, and a miss
# after that, as without it.
#
# Exit 0: the newest finished scheduled run is within <max-hours>, or there is none
# yet inside the grace. Exit 1: it is older, or there is none. Exit 2: it could not
# decide (unreadable input, a date it cannot parse, a start that is not a number or
# lies in the future), which the caller must treat as a failure, never as fresh.
#
# Usage: schedule-freshness.sh <runs.json> <now-epoch> <max-hours> [<scheduled-since-epoch>]

set -euo pipefail

runs="${1:?runs.json}"; now="${2:?now}"; max_hours="${3:?max-hours}"; since="${4:-}"
if [ -n "$since" ]; then
	[[ "$since" =~ ^[0-9]+$ ]] && [ "$since" -le "$now" ] \
		|| { echo "the schedule's start '$since' is not a time before now" >&2; exit 2; }
fi

newest="$(jq -r '
	if type != "array" then error("not a list of runs") else . end
	| map(select(.conclusion == "success" or .conclusion == "failure") | .createdAt)
	| map(fromdateiso8601)
	| max // "none"
' "$runs" 2> /dev/null)" || { echo "cannot read the list of runs in $runs" >&2; exit 2; }

if [ "$newest" = none ]; then
	if [ -n "$since" ] && [ $(( (now - since) / 3600 )) -le "$max_hours" ]; then
		echo "no scheduled run has finished yet; the schedule began $(( (now - since) / 3600 )) hours ago, inside the $max_hours-hour limit"
		exit 0
	fi
	echo "no scheduled run has finished" >&2
	exit 1
fi

hours=$(( (now - newest) / 3600 ))
if [ "$hours" -gt "$max_hours" ]; then
	echo "the newest scheduled run is $hours hours old (limit $max_hours)" >&2
	exit 1
fi
echo "the newest scheduled run is $hours hours old, inside the $max_hours-hour limit"
