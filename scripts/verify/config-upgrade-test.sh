#!/usr/bin/env bash
#
# Prove the upgrade from the release that is published keeps what the administrator did to
# /etc/containers/policy.json, which says which images may be pulled, and never asks dpkg's
# question about it. Run as root inside a clean container of a release, with the published package
# (<old.deb>) and the one just built (<new.deb>).
#
# Releases before 6.2.0+r12 shipped /etc/containers/policy.json as a plain file of the package, so
# dpkg removes it on an upgrade to a package that does not list it, edited or not; the new package
# ships its default under /usr/share/containers and puts a copy in /etc only when there is none.
# Each case installs the old package, does something to the file, upgrades without any answer to a
# prompt available (no tty, no force option, no debconf), and reads what is left:
#   unedited   the default the old package shipped: it is the new package's default afterwards
#   edited     a policy of the administrator's: it is the same file afterwards, nothing beside it
#   deleted    no file: the default is copied once, because buildah and skopeo read only /etc
#   reinstall  after the edit above, the same package again: the edit is still there
# Every case has to end with the upgrade exiting 0 and no *.dpkg-* or *.glyndor-kept file left.
# Once the published release is itself 6.2.0+r12 or later (it already ships nothing in /etc), what is proved is
# the plain upgrade: the edit stays, the default is not copied back over an administrator's deletion.
#
# Usage: config-upgrade-test.sh <old.deb> <new.deb>

set -uo pipefail

old="$(cd "$(dirname "${1:?old .deb}")" && pwd)/$(basename "$1")"
new="$(cd "$(dirname "${2:?new .deb}")" && pwd)/$(basename "$2")"
[ -f "$old" ] && [ -f "$new" ] || { echo "no such package: $old $new" >&2; exit 2; }
policy=/etc/containers/policy.json
failed=()
check() { # <name> <command...>
	local name="$1"
	shift
	echo "== $name"
	if "$@"; then echo "ok    $name"; else echo "FAIL  $name"; failed+=("$name"); fi
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null 2>&1 || true
# The dependencies of both packages come with the old one; the new one asks for nothing else.
apt-get install -y -qq "$old" > /dev/null || { echo "cannot install $old" >&2; exit 1; }
# The version from which the package stopped shipping the file; build-deb.sh has the same constant.
config_free_since=6.2.0+r12
old_version="$(dpkg-deb -f "$old" Version)"
if dpkg --compare-versions "$old_version" lt "$config_free_since"; then transition=1; else transition=0; fi
new_default="$(dpkg-deb --fsys-tarfile "$new" | tar -xO ./usr/share/containers/policy.json)"
[ -n "$new_default" ] || { echo "$new ships no /usr/share/containers/policy.json" >&2; exit 1; }
admin_policy='{"default":[{"type":"reject"}],"transports":{"docker":{"example.org":[{"type":"insecureAcceptAnything"}]}}}'

# Back to the published package with the file in a state, then the upgrade; sets rc and out.
reset_old() { # <state: shipped|edited|deleted>
	apt-get install -y -qq --allow-downgrades "$old" > /dev/null 2>&1 || dpkg -i --force-confnew "$old" > /dev/null 2>&1 || return 1
	case "$1" in
		shipped)
			if [ "$transition" = 1 ]; then
				dpkg-deb --fsys-tarfile "$old" | tar -xO ./etc/containers/policy.json > "$policy"
			else
				dpkg-deb --fsys-tarfile "$old" | tar -xO ./usr/share/containers/policy.json > "$policy"
			fi ;;
		edited) printf '%s\n' "$admin_policy" > "$policy" ;;
		deleted) rm -f "$policy" ;;
	esac
}
upgrade() { out="$(apt-get install -y "$new" < /dev/null 2>&1)"; rc=$?; }
nothing_beside() { [ -z "$(ls "$policy".* /etc/containers/*.dpkg-* 2> /dev/null)" ]; }
unprompted() { ! printf '%s\n' "$out" | grep -q -e 'Configuration file' -e 'conffile' -e 'end of file on stdin'; }

reset_old shipped || { echo "cannot go back to the published package" >&2; exit 1; }
upgrade
check "unedited: the upgrade exits 0 and asks nothing" test "$rc" -eq 0 -a -z "$(printf '%s\n' "$out" | grep -e 'Configuration file' -e 'end of file on stdin')"
check "unedited: the file is the default of the new package" test "$(cat "$policy")" = "$new_default"
check "unedited: nothing is left beside it" nothing_beside

reset_old edited || exit 1
upgrade
check "edited: the upgrade exits 0 and asks nothing" test "$rc" -eq 0 -a -z "$(printf '%s\n' "$out" | grep -e 'Configuration file' -e 'end of file on stdin')"
check "edited: the file is the administrator's, byte for byte" test "$(cat "$policy")" = "$admin_policy"
check "edited: nothing is left beside it" nothing_beside
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' podman)" ge "$(dpkg-deb -f "$new" Version)" || failed+=("the new package is not the installed one")
out="$(apt-get install -y --reinstall "$new" < /dev/null 2>&1)"; rc=$?
check "reinstall: the edit is still there and the command exits 0" test "$rc" -eq 0 -a "$(cat "$policy")" = "$admin_policy"

reset_old deleted || exit 1
upgrade
check "deleted: the upgrade exits 0" test "$rc" -eq 0
if [ "$transition" = 1 ]; then
	check "deleted: the default is copied, so buildah and skopeo have a policy" test "$(cat "$policy")" = "$new_default"
else
	check "deleted: an administrator who is on this release and deleted the file is not given it back" test ! -e "$policy"
fi
check "deleted: nothing is left beside it" nothing_beside
rm -f "$policy"
out="$(apt-get install -y --reinstall "$new" < /dev/null 2>&1)"; rc=$?
check "deleted afterwards, by an administrator who is on this release: it stays deleted" test "$rc" -eq 0 -a ! -e "$policy"

echo
if [ "${#failed[@]}" -gt 0 ]; then
	echo "config upgrade test failed: ${failed[*]}"
	exit 1
fi
echo "config upgrade test passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
