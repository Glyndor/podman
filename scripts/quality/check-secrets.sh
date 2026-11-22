#!/usr/bin/env bash
#
# Refuse a pull request that adds something shaped like a credential.
#
# Looks only at the lines <base>..<head> adds, so an old file is never a reason to
# fail. It reports file and line and the name of the pattern, never the value: a
# CI log of a public repository is public too.
#
# What it knows: private key blocks (a PEM file, or a PEM with its body inside a
# string; code that only writes or checks the header line is not one), the token formats of AWS, GitHub, GitLab,
# Slack, npm, Google and OpenAI, JWTs, and an assignment of a long value to a name
# that says secret, token, password or key, which includes the names of the two
# release signing keys. The last one is what catches a
# credential with a format of its own, such as a signing key in base64. A line that
# carries the word secret-scan:allow is skipped, for a value that is public on
# purpose; say why next to it. A file cannot carry a comment, so a repository that
# keeps throwaway test keys lists the paths in .secret-scan-allow at its root, one
# regular expression per line, each with a comment saying why. The list counts
# once it is on the base branch: a change cannot add its own exceptions, and an
# expression that does not compile fails the scan.
#
# This is a filter for the mistake, not a vault: GitHub's push protection and
# secret scanning remain the other half.
#
# Usage: check-secrets.sh <base> <head>

set -euo pipefail

base="${1:?base}"; head="${2:?head}"

# Bytes, not characters: a line with a byte that is not valid UTF-8 must not stop a
# pattern from matching what comes after it.
export LC_ALL=C

# Separates the path, the line number and the text of a record. It is a control
# character, which no file name that gets this far can hold, so a name cannot forge a
# record, and the text of a line is only ever matched after the second one.
SEP=$'\037'

names="$(mktemp)"; allowfile="$(mktemp)"; patchfile="$(mktemp)"
trap 'rm -f "$names" "$allowfile" "$patchfile"' EXIT

# Paths the repository declares as holding throwaway keys on purpose. The list is
# read from <base>, the branch the change lands on, never from <head>: a change
# that carries its own list would be the one deciding what the scan may skip, and
# an expression that matches every line would switch the scan off. Every
# expression is compiled before it is used, because a grep that cannot compile
# one reads nothing and would leave the scan with nothing to report. An expression
# is matched against the path of a file and nothing else.
list_at="$base:.secret-scan-allow"
if git cat-file -e "$list_at" 2>/dev/null; then
	list="$(git show "$list_at")" # set -e: a list that exists and cannot be read stops the scan
	n=0
	while IFS= read -r expr || [ -n "$expr" ]; do
		n=$((n + 1))
		[[ "$expr" =~ ^[[:space:]]*(#|$) ]] && continue
		rc=0; printf '' | grep -qE -e "^($expr)" 2>/dev/null || rc=$?
		[ "$rc" -le 1 ] || { echo "::error::.secret-scan-allow line $n is not a valid regular expression" >&2; exit 1; }
		printf '%s\n' "^($expr)" >> "$allowfile"
	done <<< "$list"
fi

# One "path<SEP>line<SEP>text" per added line. The files come from git's own list, and
# each one is diffed on its own and reported under the name git gave: a path read out
# of the patch would be read out of its text too, and a line a file adds that begins
# "++ b/" is a "+++ b/" line inside the hunk. A diff that cannot be taken stops the
# scan: reading nothing must never read as finding nothing.
git --literal-pathspecs diff --name-only -z "$base...$head" > "$names" || { echo "::error::could not take the diff $base...$head, so nothing was scanned" >&2; exit 1; }
# A name with a control character (a line break, a tab) is refused whole, before any
# record is made. Bytes outside ASCII are names like any other.
[ "$(tr -d '\000\040-\176\200-\377' < "$names" | wc -c)" -eq 0 ] || { echo "::error::a changed file has a control character in its name, so nothing was scanned" >&2; exit 1; }
merge_base="$(git merge-base "$base" "$head")"
added=""
while IFS= read -r -d '' file; do
	if [ -s "$allowfile" ]; then
		rc=0; grep -qE -f "$allowfile" <<< "$file" || rc=$?
		[ "$rc" -le 1 ] || { echo "::error::could not apply .secret-scan-allow, so nothing was scanned" >&2; exit 1; }
		[ "$rc" -ne 0 ] || continue
	fi
	# The tree being judged carries its own .gitattributes and, on a runner, its own
	# configuration: a file marked -diff or binary, or given a text conversion or an
	# external diff, would show no lines. The text of the file is what is read.
	# set -e: a file whose diff cannot be taken stops the scan, with git's own message.
	git --literal-pathspecs diff --no-color --text --no-textconv --no-ext-diff -U0 "$base...$head" -- "$file" > "$patchfile"
	# And if a changed file still shows nothing to read, the scan stops rather than pass it:
	# a line saying the files differ, or no hunk for a file whose content is not empty.
	unread=false
	if grep -aq '^Binary files .* differ$' "$patchfile"; then unread=true
	elif ! grep -aq '^@@' "$patchfile"; then
		new="$(git rev-parse -q --verify "$head:$file" || true)"; old="$(git rev-parse -q --verify "$merge_base:$file" || true)"
		if [ -n "$new" ] && [ "$new" != "$old" ] && [ "$(git cat-file -s "$new")" -gt 0 ]; then unread=true; fi
	fi
	[ "$unread" = false ] || { echo "::error::git showed no added lines for a changed file that is not empty, so nothing was scanned" >&2; exit 1; }
	lines="$(FILE="$file" SEP="$SEP" awk '
		/^@@/            { inhunk = 1; split($3, a, ","); line = substr(a[1], 2) + 0; next }
		inhunk && /^\+/  { text = substr($0, 2); if (index(text, "secret-scan:allow") == 0) print ENVIRON["FILE"] ENVIRON["SEP"] line ENVIRON["SEP"] text; line++ }
	' "$patchfile")"
	[ -z "$lines" ] || added+="$lines"$'\n'
done < "$names"
added="${added%$'\n'}"

[ -n "$added" ] || { echo "no credential-shaped lines added"; exit 0; }

# What follows matches the text of a record, after its path and its line number.
prefix="^[^${SEP}]*${SEP}[0-9]+${SEP}"

patterns=(
	'private key block|^-----BEGIN ((RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED) )?PRIVATE KEY( BLOCK)?-----[[:space:]]*$'
	'private key inside a string|-----BEGIN ((RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED) )?PRIVATE KEY( BLOCK)?-----(\\n|[[:space:]])*[A-Za-z0-9+/]{20,}'
	'AWS access key|(AKIA|ASIA)[0-9A-Z]{16}'
	'GitHub token|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}'
	'GitLab token|glpat-[A-Za-z0-9_-]{20}'
	'Slack token|xox[baprs]-[A-Za-z0-9-]{10,}'
	'npm token|npm_[A-Za-z0-9]{36}'
	'Google API key|AIza[0-9A-Za-z_-]{35}'
	'API key|sk-[A-Za-z0-9]{32,}'
	'JWT|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{10,}'
)

bad=0
report() { # <name> <matching lines>
	printf '%s\n' "$2" | awk -F"$SEP" -v what="$1" '{ print "::error::" $1 ":" $2 " " what }'
	bad=1
}

for entry in "${patterns[@]}"; do
	name="${entry%%|*}"; re="${entry#*|}"
	case "$re" in
		^*) re="$prefix${re#^}" ;;
		*) re="$prefix.*($re)" ;;
	esac
	hits="$(printf '%s\n' "$added" | grep -aE -- "$re" || true)"
	[ -z "$hits" ] || report "$name" "$hits"
done

# A credential with a format of its own is caught by the name it is assigned to.
generic='(token|secret|passw(or)?d|api[_-]?key|private[_-]?key|signing[_-]?key|access[_-]?key|ed25519[_-]?key|mldsa[0-9_-]*key|credential)[a-z0-9_]*["'"'"']?[ \t]*[:=][ \t]*["'"'"']?[a-z0-9+/_=-]{32,}'
skip='_(file|path|dir|url|name|env|var)[a-z0-9_]*["'"'"']?[ \t]*[:=]|secrets\.|\$\{|\$\(|example|placeholder|dummy|fake|fixture|changeme|redacted|your|<[a-z_-]+>'
hits="$(printf '%s\n' "$added" | grep -aiE -- "$prefix.*($generic)" | grep -aviE -- "$prefix.*($skip)" || true)"
[ -z "$hits" ] || report "long value assigned to a secret-like name" "$hits"

if [ "$bad" -ne 0 ]; then
	echo "Remove the value and rotate it if it was ever real; add secret-scan:allow only for a value that is public on purpose." >&2
	exit 1
fi
echo "no credential-shaped lines added"
