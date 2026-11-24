#!/usr/bin/env bash
#
# Read scripts/package/distros.txt.
#
# Usage: distros.sh field <id> <column>      one value of the row of <id>
#        distros.sh ids <format>             the ids of that format, one per line
#        distros.sh matrix <format> <arches> the rows as a JSON list for a workflow matrix, one
#                                            entry per id and architecture; <arches> is "all" or
#                                            one architecture, and an id that does not build
#                                            there is left out
#
# Columns: id format family arches epoch nv_epoch cc_epoch cc_scheme passt_min tests
# GLYNDOR_DISTROS_FILE names another table, for tests.

set -euo pipefail

table="${GLYNDOR_DISTROS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/distros.txt}"
[ -f "$table" ] || { echo "no distribution table at $table" >&2; exit 1; }
columns=(id format family arches epoch nv_epoch cc_epoch cc_scheme passt_min tests)

rows() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$table"; }

# Every row has every column, an id nobody else has, and values that cannot carry shell or
# JSON with them: the rows end up in file names, in a matrix and in a command line.
validate() {
	rows | awk -F'|' -v n="${#columns[@]}" '
		NF != n { printf "line %d has %d fields, not %d\n", NR, NF, n; bad = 1; next }
		$1 !~ /^[a-z][a-z0-9]*$/ { printf "id %s is not lowercase letters and digits\n", $1; bad = 1 }
		$2 !~ /^(rpm|pacman)$/ { printf "%s: format %s is neither rpm nor pacman\n", $1, $2; bad = 1 }
		$3 !~ /^(fedora|el|amzn|suse|arch)$/ { printf "%s: unknown family %s\n", $1, $3; bad = 1 }
		$4 !~ /^(x86_64|aarch64)(,(x86_64|aarch64))*$/ { printf "%s: unknown architectures %s\n", $1, $4; bad = 1 }
		$5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ || $7 !~ /^[0-9]+$/ { printf "%s: an epoch is not a number\n", $1; bad = 1 }
		$8 !~ /^(upstream|podman)$/ { printf "%s: unknown containers-common scheme %s\n", $1, $8; bad = 1 }
		$9 !~ /^[0-9^.]+$/ { printf "%s: passt_min %s is not a version\n", $1, $9; bad = 1 }
		$10 !~ /^([a-z0-9-]+(,[a-z0-9-]+)*)?$/ { printf "%s: tests %s is not a list of image names\n", $1, $10; bad = 1 }
		seen[$1]++ { printf "id %s appears twice\n", $1; bad = 1 }
		END { exit bad }' || { echo "distros.txt is malformed" >&2; exit 1; }
}

cmd="${1:-}"
[ "$#" -eq 0 ] || shift
validate
case "$cmd" in
	field)
		[ "$#" -eq 2 ] || { echo "usage: distros.sh field <id> <column>" >&2; exit 2; }
		col=0
		for i in "${!columns[@]}"; do
			if [ "${columns[$i]}" = "$2" ]; then col=$((i + 1)); fi
		done
		[ "$col" -gt 0 ] || { echo "unknown column: $2" >&2; exit 2; }
		rows | awk -F'|' -v id="$1" -v c="$col" '$1 == id {print $c; found = 1} END {exit !found}' \
			|| { echo "unknown distribution: $1" >&2; exit 1; } ;;
	ids)
		[ "$#" -eq 1 ] || { echo "usage: distros.sh ids <format>" >&2; exit 2; }
		rows | awk -F'|' -v f="$1" '$2 == f {print $1}' ;;
	matrix)
		[ "$#" -eq 2 ] || { echo "usage: distros.sh matrix <format> <arches|all>" >&2; exit 2; }
		case "$2" in all | x86_64 | aarch64) ;; *) echo "unknown architectures: $2" >&2; exit 2 ;; esac
		rows | awk -F'|' -v f="$1" -v want="$2" '
			$2 != f { next }
			{
				n = split($4, a, ",")
				for (i = 1; i <= n; i++) {
					if (want != "all" && a[i] != want) continue
					runner = (a[i] == "aarch64") ? "ubuntu-24.04-arm" : "ubuntu-24.04"
					out = out (out == "" ? "" : ",") sprintf("{\"id\":\"%s\",\"family\":\"%s\",\"arch\":\"%s\",\"runner\":\"%s\"}", $1, $3, a[i], runner)
				}
			}
			END { print "[" out "]" }' ;;
	*)
		echo "usage: distros.sh field <id> <column> | ids <format> | matrix <format> <arches|all>" >&2
		exit 2 ;;
esac
