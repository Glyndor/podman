#!/usr/bin/env bash
#
# Tests that the build image takes everything it adds from Debian's signed archive.
#
# The package is compiled inside the image scripts/build/Dockerfile describes. What goes
# into that image beside the base is a compiler, a short-name list, the source of
# passt and the AppArmor tools that compile its profile, and each comes through apt,
# which checks it against a signed Release file:
# Rust from trixie-backports instead of an installer piped into a shell, passt's source
# from the archive because its tags carry no signature, the short names from Debian's
# package because upstream's spec fetches the head of an unsigned branch. Replacing any
# of them with a download left every suite green, and a change there is a change to
# what gets compiled and signed.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# violations <Dockerfile>: one line per way the image would take something that apt
# did not check, and per missing statement of where the three inputs come from.
violations() {
	python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
# Instructions with their continuation lines joined, comments left out.
body = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
instructions = [i.strip() for i in re.sub(r"\\\n", " ", body).split("\n") if i.strip()]
fetchers = [
    (r"\bcurl\b", "curl"), (r"\bwget\b", "wget"), (r"\bgit\s+clone\b", "git clone"),
    (r"\brustup\b", "rustup"), (r"\bpip3?\s+install\b", "pip install"),
    (r"\bcargo\s+install\b", "cargo install"), (r"\bgo\s+install\b", "go install"),
    (r"\bnpm\s+(install|i)\b", "npm install"), (r"\bgem\s+install\b", "gem install"),
]
unsafe = ["--allow-unauthenticated", "--allow-insecure-repositories", "--allow-downgrade-to-insecure",
          "AllowUnauthenticated", "AllowInsecureRepositories", "trusted=yes", "--no-check-certificate",
          "--insecure", "--force-yes"]
for ins in instructions:
    word = ins.split()[0].upper()
    if word == "ADD" and re.search(r"\bhttps?://", ins):
        print("ADD takes a file from a URL")
    if word == "COPY" and "--from=" in ins and not re.search(r"--from=[a-z0-9_]+\b(?![:/@.])", ins):
        print("COPY takes a file from another image")
    if word != "RUN":
        continue
    for pattern, name in fetchers:
        if re.search(pattern, ins):
            print(f"RUN downloads with {name}, which checks nothing")
    for flag in unsafe:
        if flag in ins:
            print(f"RUN tells apt to accept what it cannot verify ({flag})")
    for source in re.findall(r'echo\s+"(deb(?:-src)?\s[^"]*)"', ins):
        if not re.fullmatch(r"deb(-src)? http://deb\.debian\.org/debian trixie-backports main", source):
            print(f"an apt source that is not Debian's trixie-backports: {source}")
joined = " ".join(instructions)
for need, what in (
    (r"apt-get install [^&]*-t trixie-backports cargo rustc\b", "Rust is not installed from trixie-backports"),
    (r"apt-get source [^&]*-t trixie-backports passt\b", "the source of passt is not taken from trixie-backports"),
    (r"apt-get download golang-github-containers-common\b", "the short-name list is not taken from Debian's package"),
    (r"apt-get install [^&]*(?<![\w-])apparmor(?![\w-])", "apparmor_parser is not installed, and the build compiles the profile of pasta with it"),
):
    if not re.search(need, joined):
        print(what)
PY
}

D="$HERE/scripts/build/Dockerfile"
check "the build image takes Rust, passt and the short names from Debian's signed archive, and downloads nothing else" "" "$(violations "$D")"

B="$WORK/Dockerfile"
swap() { # <text> <replacement>: a copy of the Dockerfile with that one text replaced
	python3 - "$D" "$B" "$1" "$2" <<'PY'
import sys
t = open(sys.argv[1]).read()
if t.count(sys.argv[3]) != 1:
    sys.exit(f"the text to replace is in the Dockerfile {t.count(sys.argv[3])} times, not once")
open(sys.argv[2], "w").write(t.replace(sys.argv[3], sys.argv[4]))
PY
}
add() { cp "$D" "$B" && printf '%s\n' "$1" >> "$B"; } # <line>: a copy with one more instruction

swap "apt-get install -y -qq --no-install-recommends -t trixie-backports cargo rustc" "curl -sSf https://sh.rustup.rs | sh -s -- -y"
check "Rust from an installer piped into a shell is named, twice over" \
	"RUN downloads with curl, which checks nothing|RUN downloads with rustup, which checks nothing|Rust is not installed from trixie-backports" \
	"$(violations "$B" | paste -sd'|')"
swap "apt-get source -qq -t trixie-backports passt" "git clone --depth 1 https://passt.top/passt"
check "the source of passt from a clone is named" \
	"RUN downloads with git clone, which checks nothing|the source of passt is not taken from trixie-backports" "$(violations "$B" | paste -sd'|')"
swap "apt-get download golang-github-containers-common" "wget -q https://example.invalid/shortnames.conf"
check "the short names from a download are named" \
	"RUN downloads with wget, which checks nothing|the short-name list is not taken from Debian's package" "$(violations "$B" | paste -sd'|')"
swap "apt-get source -qq -t trixie-backports passt" "apt-get source -qq passt"
check "passt's source from whatever release answers is named" "the source of passt is not taken from trixie-backports" "$(violations "$B")"
swap "deb http://deb.debian.org/debian trixie-backports main" "deb [trusted=yes] http://mirror.example.invalid/debian trixie-backports main"
check "an apt source that is not Debian's, marked trusted, is named" "2" "$(violations "$B" | grep -c -e 'trusted=yes' -e "not Debian's trixie-backports")"
swap "-t trixie-backports cargo rustc" "-t trixie-backports --allow-unauthenticated cargo rustc"
check "telling apt to install what it cannot verify is named" "1" "$(violations "$B" | grep -c -F 'RUN tells apt to accept what it cannot verify (--allow-unauthenticated)')"
swap "protobuf-compiler python3 apparmor" "protobuf-compiler python3 libapparmor-dev"
check "an image with no apparmor package, only its headers, is named" \
	"apparmor_parser is not installed, and the build compiles the profile of pasta with it" "$(violations "$B")"
add "ADD https://example.invalid/tool /usr/local/bin/tool"
check "a file added from a URL is named" "ADD takes a file from a URL" "$(violations "$B")"
add "COPY --from=docker.io/library/rust:1 /usr/local/cargo /usr/local/cargo"
check "a file copied out of another image is named" "COPY takes a file from another image" "$(violations "$B")"
add "COPY --from=base /etc/os-release /etc/os-release.base"
check "a file copied from a stage of this same file is fine" "" "$(violations "$B")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
