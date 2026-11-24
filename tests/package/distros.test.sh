#!/usr/bin/env bash
#
# Tests for scripts/package/distros.sh and the table it reads: a row says what the contract
# says, a malformed table is refused, the matrix has one entry for every distribution and
# architecture, and every id of the table has the image it is built in, pinned by digest.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/package/distros.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
table() { GLYNDOR_DISTROS_FILE="$WORK/t" bash "$SCRIPT" "$@" 2>&1; }

# --- the table as committed ---------------------------------------------------------
check "the epoch of fc45 is the one Fedora's own podman has" 5 "$(bash "$SCRIPT" field fc45 epoch)"
check "the family of fc44" fedora "$(bash "$SCRIPT" field fc44 family)"
check "an id the table does not have is refused" "unknown distribution: nope" "$(bash "$SCRIPT" field nope epoch 2>&1)"
check "a column it does not have is refused" "unknown column: colour" "$(bash "$SCRIPT" field fc45 colour 2>&1)"
check "a row with no images to test on has an empty value, not an error" "0 " "$(bash "$SCRIPT" field fc45 tests > "$WORK/v" 2>&1; echo "$? $(cat "$WORK/v")")"
check "every id is a format of the contract" "" "$(for id in $(bash "$SCRIPT" ids rpm) $(bash "$SCRIPT" ids pacman); do bash "$SCRIPT" field "$id" format | grep -v -x -e rpm -e pacman; done)"

# Every id has the image it is built in, every image is pinned to a digest except the three whose registry drops the
# digests (below), and every runner the matrix hands out is a label the workflows name.
#
# The exception to "base images are pinned by digest", and why it is a list that is checked here: quay.io re-points
# fedora:44 and fedora:45 to a new index every day, between 05:56 and 07:03 UTC, and deletes the previous one in that
# instant (measured on 2026-11-24: the digests of the last 14 days of fedora:44 had all expired), and the registry of
# openSUSE stops serving the digests of Tumbleweed after a few days; a pin by digest fails the build the next day, and
# Dependabot cannot keep up, since the digest it would propose lives about two hours after its run. AlmaLinux, Rocky
# and Red Hat's UBI keep the digests they replace, so they stay pinned: the list below is the whole exception, an image
# that is on it must not carry a digest and one that is not must.
MOVING="fc44 fc45 tumbleweed"
# Every image a row uses: the one it is built in (its id) and the ones it is also proved on (its tests column), each with
# the row it belongs to, which says the architectures it has to have.
images() { # -> "<image> <row>" per line
	local id t
	for id in $(bash "$SCRIPT" ids rpm) $(bash "$SCRIPT" ids pacman); do
		echo "$id $id"
		for t in $(bash "$SCRIPT" field "$id" tests | tr ',' ' '); do echo "$t $id"; done
	done
}
moving() { case " $MOVING " in *" $1 "*) return 0 ;; esac; return 1; }
while read -r id row; do
	file="$HERE/scripts/package/images/$id/Dockerfile"
	check "$id has its image" 1 "$([ -f "$file" ] && echo 1 || echo 0)"
	if moving "$id"; then
		case "$id" in fc*) want_tag="${id#fc}" ;; *) want_tag=latest ;; esac
		check "$id's image is one FROM with the tag $want_tag and no digest, as the exception says" 1 \
			"$(grep -c -E "^FROM [a-z0-9./-]+:$want_tag\$" "$file")"
		check "$id's Dockerfile says that it is an exception, why and when it was measured" 1 \
			"$(grep -c -e 'NOT by digest, on purpose' -e 'measured on 2026-11-24' "$file" | sed 's/^2$/1/')"
	else
		check "$id's image is one FROM, a release tag and a sha256 digest, because its registry keeps the digests it replaces" 1 \
			"$(grep -c -E '^FROM [a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$' "$file")"
	fi
	check "$id's image has no other instruction than the one RUN that installs the programs of the proof" "1 1" \
		"$(grep -v -e '^#' -e '^$' -e '^FROM ' "$file" | wc -l | tr -d ' ') $(grep -c '^RUN ' "$file")"
done < <(images)
# An image is built and tested on every architecture its row names, from the one Dockerfile, so the digest it is
# pinned to is the digest of an INDEX with an image for each: the digest of one architecture's manifest makes the
# other runner try to execute the wrong binaries ("exec format error"). The index is read from the registry with
# docker or podman; with neither the check says so and fails.
platforms() { # <name:tag@digest, or name:tag when it moves>: the linux architectures of the index, "gone" when the registry no longer has the digest, or why it could not be read
	local ref="$1" name target raw err
	name="${ref%%:*}"; target="$name@${ref##*@}"
	case "$ref" in *@*) ;; *) target="$ref" ;; esac
	case "$name" in */*) ;; *) name="docker.io/library/$name"; target="docker.io/library/$target" ;; esac
	err="$WORK/manifest.err"; : > "$err"
	if command -v docker > /dev/null 2>&1 && raw="$(docker buildx imagetools inspect --raw "$target" 2>> "$err")"; then :
	elif command -v podman > /dev/null 2>&1 && raw="$(podman manifest inspect "docker://$target" 2>> "$err")"; then :
	elif grep -q -i -e 'not found' -e 'manifest unknown' -e '404' "$err" 2> /dev/null; then echo gone; return
	else echo "cannot read the manifest of $ref with docker or podman"; return; fi
	printf '%s' "$raw" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "manifests" not in d:
    print("not an index")
else:
    print(" ".join(sorted({m["platform"]["architecture"] for m in d["manifests"] if m.get("platform", {}).get("os") == "linux"} & {"amd64", "arm64"})))
'
}
# What a failure of the pin says when the registry has dropped the digest.
gone_message() { echo "the digest pinned for $1 is no longer in the registry. Dependabot moves it (group package-images); until it does, this suite fails here"; }
check "the message of a digest the registry dropped says what moves it and what fails until then" \
	"the digest pinned for tumbleweed's image is no longer in the registry. Dependabot moves it (group package-images); until it does, this suite fails here" \
	"$(gone_message "tumbleweed's image")"
# The two ways the registry answers when it cannot give the manifest, with a docker and a podman that say so.
mkdir -p "$WORK/fakeregistry"
printf '#!/bin/sh\necho "$FAKE_ERROR" >&2\nexit 1\n' > "$WORK/fakeregistry/docker"
printf '#!/bin/sh\necho "${FAKE_ERROR_PODMAN:-$FAKE_ERROR}" >&2\nexit 1\n' > "$WORK/fakeregistry/podman"
chmod +x "$WORK/fakeregistry/docker" "$WORK/fakeregistry/podman"
check "a digest the registry no longer has is told as gone, not as an unreadable manifest" gone \
	"$(FAKE_ERROR='ERROR: registry.example/x@sha256:00: not found' PATH="$WORK/fakeregistry:$PATH" platforms registry.example/x:latest@sha256:00)"
check "docker saying not found is enough, whatever podman says of the reference it is given" gone \
	"$(FAKE_ERROR='ERROR: registry.example/x@sha256:00: not found' FAKE_ERROR_PODMAN='Error: unsupported transport "docker" for looking up local images' PATH="$WORK/fakeregistry:$PATH" platforms registry.example/x:latest@sha256:00)"
check "so is the answer of a registry that says manifest unknown" gone \
	"$(FAKE_ERROR='Error: manifest unknown' PATH="$WORK/fakeregistry:$PATH" platforms registry.example/x:latest@sha256:00)"
# An image that moves is asked for by its tag, and a docker that answers with an index is read the same way.
printf '#!/bin/sh\nprintf "%%s" "{\\"manifests\\":[{\\"platform\\":{\\"os\\":\\"linux\\",\\"architecture\\":\\"arm64\\"}},{\\"platform\\":{\\"os\\":\\"linux\\",\\"architecture\\":\\"amd64\\"}}]}"\necho "$*" >> "%s/asked"\n' "$WORK" > "$WORK/fakeregistry/docker"
check "an image asked for by its tag gives the architectures of its index" "amd64 arm64" "$(PATH="$WORK/fakeregistry:$PATH" platforms quay.io/fedora/fedora:45)"
check "and it is asked for by that tag, not by a digest" "buildx imagetools inspect --raw quay.io/fedora/fedora:45" "$(tail -n 1 "$WORK/asked")"
check "an image pinned by digest is asked for by the digest" "buildx imagetools inspect --raw quay.io/x/y@sha256:00" "$(PATH="$WORK/fakeregistry:$PATH" platforms quay.io/x/y:10@sha256:00 > /dev/null; tail -n 1 "$WORK/asked")"
printf '#!/bin/sh\necho "$FAKE_ERROR" >&2\nexit 1\n' > "$WORK/fakeregistry/docker"
check "a registry that cannot be reached is not told as gone" "cannot read the manifest of registry.example/x:latest@sha256:00 with docker or podman" \
	"$(FAKE_ERROR='dial tcp: connection refused' PATH="$WORK/fakeregistry:$PATH" platforms registry.example/x:latest@sha256:00)"
while read -r id row; do
	ref="$(sed -n 's/^FROM \([^ ]*\)$/\1/p' "$HERE/scripts/package/images/$id/Dockerfile")"
	want="$(bash "$SCRIPT" field "$row" arches | tr ',' '\n' | sed 's/x86_64/amd64/; s/aarch64/arm64/' | sort | paste -sd' ')"
	got="$(platforms "$ref")"
	if [ "$got" = gone ]; then
		# The digest of an image that is kept in its registry is gone: the pin has to be moved by hand or by Dependabot
		# (group package-images of .github/dependabot.yml), and until that is merged this is what fails.
		check "$(gone_message "$id's image")" present gone
		continue
	fi
	# The index may have more than the row builds for, never fewer.
	ok=1
	for a in $want; do case " $got " in *" $a "*) ;; *) ok=0 ;; esac; done
	if moving "$id"; then
		check "$id's image, read by its tag today, is an index with an image for each architecture it is built for ($want); the tag moves, so this is the answer of the day the suite ran" "1" "$ok"
	else
		check "$id's image is pinned to an index with an image for each architecture it is built for ($want)" "1" "$ok"
	fi
done < <(images)
for dir in "$HERE"/scripts/package/images/*/; do
	name="$(basename "$dir")"
	known=0
	for id in $(bash "$SCRIPT" ids rpm) $(bash "$SCRIPT" ids pacman); do
		[ "$id" = "$name" ] && known=1
		for t in $(bash "$SCRIPT" field "$id" tests | tr ',' ' '); do [ "$t" = "$name" ] && known=1; done
	done
	check "the image $name belongs to a row of the table" 1 "$known"
done
check "the runners of the matrix are the ones the workflows name" "ubuntu-24.04 ubuntu-24.04-arm" \
	"$(bash "$SCRIPT" matrix rpm all | grep -o '"runner":"[^"]*"' | cut -d'"' -f4 | sort -u | paste -sd' ')"

# --- the matrix ------------------------------------------------------------------------
cat > "$WORK/t" <<'T'
# a comment
a1|rpm|fedora|x86_64,aarch64|5|2|5|upstream|0^20260716|
b2|rpm|suse|x86_64|0|0|0|upstream|20260716|imgone,imgtwo
c3|pacman|arch|x86_64|0|0|1|upstream|20260716|
T
check "ids of a format, in table order" "a1 b2" "$(table ids rpm | paste -sd' ')"
check "every architecture of every row of the format" \
	'[{"id":"a1","family":"fedora","arch":"x86_64","runner":"ubuntu-24.04"},{"id":"a1","family":"fedora","arch":"aarch64","runner":"ubuntu-24.04-arm"},{"id":"b2","family":"suse","arch":"x86_64","runner":"ubuntu-24.04"}]' \
	"$(table matrix rpm all)"
check "one architecture leaves out the rows that do not build there" '[{"id":"a1","family":"fedora","arch":"aarch64","runner":"ubuntu-24.04-arm"}]' "$(table matrix rpm aarch64)"
check "a format with no row is an empty list" "[]" "$(table matrix nothing all)"
check "an unknown architecture is a usage error" "unknown architectures: riscv" "$(table matrix rpm riscv)"
check "the list of images to test on" "imgone,imgtwo" "$(table field b2 tests)"

# --- a malformed table ------------------------------------------------------------------
bad() { # <desc> <line> <what it says>
	printf '%s\n' "$2" > "$WORK/t"
	check "$1" "$3" "$(table ids rpm | tail -n 1)"
}
bad "a row with a field too few" 'a1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716' "distros.txt is malformed"
bad "an id with a capital" 'A1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an id with a character a file name or a shell would read" 'a-1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "a format that is neither rpm nor pacman" 'a1|deb|fedora|x86_64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an unknown family" 'a1|rpm|gentoo|x86_64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an unknown architecture" 'a1|rpm|fedora|riscv64|5|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an epoch that is not a number" 'a1|rpm|fedora|x86_64|five|2|5|upstream|0^20260716|' "distros.txt is malformed"
bad "an unknown containers-common scheme" 'a1|rpm|fedora|x86_64|5|2|5|dated|0^20260716|' "distros.txt is malformed"
bad "a passt version that is not one" 'a1|rpm|fedora|x86_64|5|2|5|upstream|new|' "distros.txt is malformed"
bad "a test image with a character a shell would read" 'a1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|img;rm' "distros.txt is malformed"
printf 'a1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|\na1|rpm|fedora|x86_64|5|2|5|upstream|0^20260716|\n' > "$WORK/t"
check "an id twice" "distros.txt is malformed" "$(table ids rpm | tail -n 1)"
out="$(GLYNDOR_DISTROS_FILE="$WORK/absent" bash "$SCRIPT" ids rpm 2>&1)"; check "a table that is not there" "1" "$?"
check "and it says so" "no distribution table at $WORK/absent" "$out"
bash "$SCRIPT" > /dev/null 2>&1; check "no command is a usage error" 2 "$?"
check "and it says how to call it" 1 "$(bash "$SCRIPT" 2>&1 | grep -c "usage: distros.sh field")"
bash "$SCRIPT" field fc45 > /dev/null 2>&1; check "field without a column is a usage error" 2 "$?"
bash "$SCRIPT" ids > /dev/null 2>&1; check "ids without a format is a usage error" 2 "$?"
bash "$SCRIPT" matrix rpm > /dev/null 2>&1; check "matrix without architectures is a usage error" 2 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
