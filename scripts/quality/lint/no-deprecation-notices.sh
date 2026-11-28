#!/usr/bin/env bash
#
# Fail when a job of the commit carries a warning that something it uses is
# deprecated or is going away. GitHub reports those as annotations on the job (a
# Node runtime an action still runs on, a command it retired), and a run that is
# green with one is a run that stops working on a date nobody wrote down.
#
# The checks of this repository are eight workflows, so the annotations are spread
# over the runs of the commit: this lists every run of the commit that a pull
# request started, and for each of them the jobs and the annotations of the jobs.
#
# The annotations of a job are written while the job runs, so the runs of the
# commit have to be finished before they are read. The script waits for them, up
# to WAIT_SECONDS, and a run that does not finish in that time is a failure: a
# check that could not look has not found nothing. The run of this check is not
# among the runs it waits for: it is the one waiting, and it would wait for itself.
#
# Inputs (env): GH_TOKEN (read access to actions and checks), REPO, HEAD_SHA.
#
# It reads every job of every run of the commit and, for each, the annotations of
# level `warning` or `failure`, and fails when one of them matches PATTERN. A
# notice is not read: only a warning says that something has to change. A listing
# or a read that fails is a failure too, for the same reason.
set -uo pipefail

repo="${REPO:?REPO}"
sha="${HEAD_SHA:?HEAD_SHA}"
case "$sha" in
*[!0-9a-f]* | "") echo "::error::HEAD_SHA is not the sha of a commit" >&2; exit 1 ;;
esac
# The run of this check, which waits and would wait for itself.
self="${RUN_ID:-${GITHUB_RUN_ID:-}}"
# The longest chain of job ceilings among the workflows of a pull request is 80
# minutes (package-check.yml); the wait is longer than that, so a run that is
# only slow is not read as one that never finished.
wait_seconds="${WAIT_SECONDS:-5400}"
# Once a minute: every listing spends the token's hourly budget.
poll_seconds="${POLL_SECONDS:-60}"
case "$wait_seconds" in '' | *[!0-9]*) wait_seconds=5400 ;; esac
case "$poll_seconds" in '' | *[!0-9]*) poll_seconds=60 ;; esac
PATTERN='deprecat|no longer supported|will be (removed|disabled|retired)|forced to run on node'

# runs_of_commit: the runs of the commit that a pull request started, one per line:
# the id of the run, its name and its status.
runs_of_commit() {
	timeout 120 gh api --paginate "repos/${repo}/actions/runs?head_sha=${sha}&per_page=100" \
		| jq -r '.workflow_runs[]? | select(.event == "pull_request") | [(.id | tostring), .name, .status] | @tsv'
}

found=0
runs=""
if ! runs="$(runs_of_commit)"; then
	echo "::error::the runs of commit $sha could not be listed, so their warnings were not read"
	found=1
fi

# The wait: the runs of the commit have to be finished before their annotations
# are read. The run of this check is left out: it is the one waiting.
deadline=$((SECONDS + wait_seconds))
while [ "$found" -eq 0 ]; do
	pending=""
	while IFS=$'\t' read -r id name status; do
		[ -n "$id" ] || continue
		[ "$id" = "$self" ] && continue
		[ "$status" = completed ] || pending="$pending $name"
	done <<<"$runs"
	[ -z "$pending" ] && break
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "::error::the runs of commit $sha did not finish in ${wait_seconds}s ($pending), so their warnings were not read"
		found=1
		break
	fi
	sleep "$poll_seconds"
	if ! fresh="$(runs_of_commit)"; then
		echo "::error::the runs of commit $sha could not be listed again, so their warnings were not read"
		found=1
		break
	fi
	runs="$fresh"
done

# The annotations of every job of every run of the commit.
while IFS=$'\t' read -r id name status; do
	[ -n "$id" ] || continue
	if ! jobs="$(timeout 120 gh api --paginate "repos/${repo}/actions/runs/${id}/jobs?per_page=100" \
		| jq -r '.jobs[]? | [(.id | tostring), .name] | @tsv')"; then
		echo "::error::the jobs of run $name could not be listed, so their warnings were not read"
		found=1
		continue
	fi
	while IFS=$'\t' read -r job_id job_name; do
		[ -n "$job_id" ] || continue
		if ! notes="$(timeout 120 gh api --paginate "repos/${repo}/check-runs/${job_id}/annotations?per_page=100" \
			| jq -r '.[]? | select(.annotation_level == "warning" or .annotation_level == "failure") | .message')"; then
			echo "::error::the annotations of '$job_name' could not be read, so they were not checked"
			found=1
			continue
		fi
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			if printf '%s\n' "$line" | grep -qiE "$PATTERN"; then
				echo "::error::'$job_name' carries a deprecation warning: $line"
				found=1
			fi
		done <<<"$notes"
	done <<<"$jobs"
done <<<"$runs"

[ "$found" -eq 0 ] && echo "no job of commit $sha carries a deprecation warning"
exit "$found"
