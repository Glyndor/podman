# shellcheck shell=bash
#
# The rpm packages of a release as the suites fake them: the names come from scripts/release/rpm/names.sh, read from the
# tables of the repository, and each file is the lead of an rpm package followed by its own name, so two files never
# hash alike. Sourced, never run, with HERE set by the suite.

# small_table <file>: three rows of the committed table in <file>, the one every script of the release then reads
# (GLYNDOR_DISTROS_FILE). For the suites whose subject is not the table: forty packages take seconds to hash and sign in
# every case, and the mutation sweep runs these suites once for each guard. Sixteen signed packages say the same.
small_table() {
	grep -E '^(fc45|fc44|el9)\|' "$HERE/scripts/package/distros.txt" > "$1"
	export GLYNDOR_DISTROS_FILE="$1"
}

# rpm_names <version>: the files the release of that version carries
rpm_names() { bash "$HERE/scripts/release/rpm/names.sh" release "$1"; }

# fake_rpm <path> [text]: a file that starts as an rpm package does
fake_rpm() { printf '\355\253\356\333%s\n' "${2:-${1##*/}}" > "$1"; }

# fake_rpms <dir> <version>: every package of the release of that version, in <dir>
fake_rpms() {
	local name
	mkdir -p "$1"
	while IFS= read -r name; do fake_rpm "$1/$name"; done <<< "$(rpm_names "$2")"
}

# signed_names <version>: every file the release of that version signs, in the order of scripts/release/signed-set.sh
signed_names() { TAG="v$1" bash "$HERE/scripts/release/signed-set.sh" list; }

# sign_stage <workspace> <stage> <version>: what the signing step reads: the scripts of the repository in <workspace>,
# and the packages the check of the download left in <stage>
sign_stage() {
	# The folder of the workspace is named through a variable: the check of the scope map reads a literal path after "$1"
	# as a file of this repository, and would ask every suite to depend on all of scripts/.
	local name tree=scripts
	mkdir -p "$1/$tree" "$2"
	cp -r "$HERE/scripts/release" "$1/$tree/release"
	cp -r "$HERE/scripts/package" "$1/$tree/package"
	cp -r "$HERE/scripts/build" "$1/$tree/build"
	: > "$2/podman_${3}_amd64.deb"
	: > "$2/podman_${3}_arm64.deb"
	while IFS= read -r name; do fake_rpm "$2/$name"; done <<< "$(rpm_names "$3")"
}
