#!/usr/bin/env bash
#
# Tests for the step of the job that publishes in .github/workflows/release.yml that creates the release, run under the
# shell the workflow gives it with a gh that knows which tags exist: the tag is created through the API on the commit the
# plan fixed and refused when it exists whatever it points at, and the release is created with --verify-tag.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck source=tests/lib/workflow-step.sh
. "$HERE/tests/lib/workflow-step.sh"
# shellcheck source=tests/lib/release-workflow.sh
. "$HERE/tests/lib/release-workflow.sh"

# --- release.yml, publish: the step that creates the release ---------------------
R="$WORK/create"
if step release.yml publish "name=Create the release" "$R"; then
	check "the release step's run block has no expression in it" 0 "$(grep -c '\${{' "$R/run.sh")"
	mkdir -p "$R/bin"
	# A gh with the tags of a repository: the API makes a reference only if there is none of that name, whatever
	# commit it points at; a release is made only for a tag that exists. $TAGS has one "<tag> <commit>" per line.
	cat > "$R/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "$CALLS"
case "$1 $2 $3" in
	"api --method POST")
		for a in "$@"; do case "$a" in ref=refs/tags/*) name="${a#ref=refs/tags/}" ;; sha=*) sha="${a#sha=}" ;; esac; done
		if grep -q -F -x -e "$name" <(cut -d' ' -f1 "$TAGS"); then echo "Reference already exists" >&2; exit 1; fi
		echo "$name $sha" >> "$TAGS" ;;
	"release create "*)
		grep -q -F -x -e "$3" <(cut -d' ' -f1 "$TAGS") || { echo "tag $3 not found" >&2; exit 1; } ;;
esac
GH
	chmod +x "$R/bin/gh"
	SHA=0123456789abcdef0123456789abcdef01234567
	release() { # <REQUIRE_MLDSA, may be empty> [TAG] [SHA]
		rm -rf "$R/art" "$R/calls" "$R/rt" "$R/tags"; mkdir "$R/art" "$R/rt"; : > "$R/calls"
		printf '%s' "${PRE_TAGS-}" > "$R/tags"
		local a
		for a in amd64 arm64; do : > "$R/art/podman_6.2.0+r2_$a.deb"; : > "$R/art/podman_6.2.0+r2_$a.deb.sig"; done
		run_step "$R" "$R/art" PATH="$R/bin:$PATH" CALLS="$R/calls" TAGS="$R/tags" RUNNER_TEMP="$R/rt" TAG="${2-v6.2.0+r2}" SHA="${3-$SHA}" \
			PODMAN=v6.2.0 NETAVARK=v2.1.0 AARDVARK=v2.1.3 RECIPE=r1 REQUIRE_MLDSA="$1" \
			GH_TOKEN=a-token GH_REPO=owner/repo
	}
	assets() { grep "^release create v6.2.0+r2 --verify-tag " "$R/calls" | sed 's/.*before signing\. //; s#'"$R"'/rt/##'; }
	base="podman_6.2.0+r2_amd64.deb podman_6.2.0+r2_amd64.deb.sig podman_6.2.0+r2_arm64.deb podman_6.2.0+r2_arm64.deb.sig"
	mldsa="podman_6.2.0+r2_amd64.deb podman_6.2.0+r2_amd64.deb.sig podman_6.2.0+r2_amd64.deb.mldsa65.sig podman_6.2.0+r2_arm64.deb podman_6.2.0+r2_arm64.deb.sig podman_6.2.0+r2_arm64.deb.mldsa65.sig"

	release true
	check "a required second signature: the release is created on the commit the plan fixed, from the exact names" "0 1 $mldsa components.txt" \
		"$rc $(grep -c '^release create' "$R/calls") $(assets)"
	check "and the tag is made by the API on the commit the plan fixed, once, before the release" "1 api --method POST repos/owner/repo/git/refs -f ref=refs/tags/v6.2.0+r2 -f sha=$SHA|release create" \
		"$(grep -c '^api ' "$R/calls") $(sed -n 1p "$R/calls")|$(sed -n 2p "$R/calls" | cut -d' ' -f1-2)"
	check "and the release takes no commit of its own: it verifies the tag, and there is no --target" "1 0" "$(grep -c -e '--verify-tag' "$R/calls") $(grep -c -e '--target' "$R/calls")"
	# The attack: somebody made the tag during the build, on another commit, with no release. The run
	# stops and publishes nothing; the same name on the right commit is no different, it was not made by this run.
	PRE_TAGS="v6.2.0+r2 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
"
	release true
	check "a tag that exists on another commit stops the run: no release, and the tag is left alone" "1 0 v6.2.0+r2 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
		"$rc $(grep -c '^release create' "$R/calls") $(cat "$R/tags" | paste -sd'|' | tr -d '\n')"
	check "and it says which tag, and on which commit it was to be made" 1 "$(says "the tag v6.2.0+r2 could not be created on $SHA")"
	PRE_TAGS="v6.2.0+r2 $SHA
"
	release true
	check "a tag that exists on the very commit is refused as well: this run did not make it" "1 0" "$rc $(grep -c '^release create' "$R/calls")"
	PRE_TAGS=""
	check "and components.txt lists the four components the plan compares" "podman v6.2.0|netavark v2.1.0|aardvark-dns v2.1.3|recipe r1" \
		"$(paste -sd'|' "$R/rt/components.txt")"
	release false
	check "none required: the release carries the assets it always has" "0 $base components.txt" "$rc $(assets)"
	release ""
	check "a step output that is empty requires nothing" "0 $base components.txt" "$rc $(assets)"
	for bad in main v6.2 'v6.2.0+r2; touch x' 'v6.2.0+r2
x'; do
		release false "$bad"
		check "the tag '$(printf '%s' "$bad" | head -n 1)' is not a version: nothing is created" "1 0 0" "$rc $(grep -c '^release create' "$R/calls") $(grep -c '^api ' "$R/calls")"
	done
	for bad in abc123 main "${SHA}0" "${SHA%?}" ""; do
		release false v6.2.0+r2 "$bad"
		check "the commit '$bad' is not a full commit id: nothing is created" "1 0 0" "$rc $(grep -c '^release create' "$R/calls") $(grep -c '^api ' "$R/calls")"
	done
else
	fail=$((fail + 1)); echo "FAIL  release.yml: cannot find the step that creates the release"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
