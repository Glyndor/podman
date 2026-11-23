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
#   purge      installing the new package where there is no file, then purging it: the copy it made goes,
#              with its record, and one the administrator edited stays
#   interrupted  an upgrade that stops after preinst and before postinst (dpkg --unpack, no --configure): the next
#              configuration puts the administrator's file back, and when the administrator made another in the meantime
#              keeps it and sets the earlier one aside under another name
#   apparmor   the configuration with no AppArmor on the machine, and with AppArmor whose parser fails: it exits 0, and
#              says which profile did not load in the second
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

# --- purge: what the maintainer script made goes with the package, unless the administrator changed it ---
apt-get purge -y -qq podman > /dev/null 2>&1; rm -f "$policy"
out="$(apt-get install -y "$new" < /dev/null 2>&1)"; rc=$?
check "purge: the first install of the new package copies the default" test "$rc" -eq 0 -a "$(cat "$policy")" = "$new_default"
out="$(apt-get purge -y podman < /dev/null 2>&1)"; rc=$?
check "purge: the purge exits 0 and takes the copy nobody changed" test "$rc" -eq 0 -a ! -e "$policy"
check "purge: and the record of the copy with it" test ! -e /var/lib/glyndor-podman/policy.md5
out="$(apt-get install -y "$new" < /dev/null 2>&1)"
printf '%s\n' "$admin_policy" > "$policy"
out="$(apt-get purge -y podman < /dev/null 2>&1)"; rc=$?
check "purge with the file edited: the purge exits 0 and the administrator's file is still there, byte for byte" test "$rc" -eq 0 -a "$(cat "$policy")" = "$admin_policy"
check "purge with the file edited: nothing else of the package is left" test ! -e /var/lib/glyndor-podman -a ! -e /usr/share/containers/seccomp.json
rm -f "$policy"

# remove is not purge: the file and its record stay, and a purge of the package that is already removed takes them
apt-get purge -y -qq podman > /dev/null 2>&1; rm -f "$policy"
apt-get install -y -qq "$new" < /dev/null > /dev/null 2>&1
out="$(apt-get remove -y podman < /dev/null 2>&1)"; rc=$?
check "remove: exits 0 and the copy of the policy and its record are still there" test "$rc" -eq 0 -a -f "$policy" -a -f /var/lib/glyndor-podman/policy.md5
out="$(apt-get purge -y podman < /dev/null 2>&1)"; rc=$?
check "purge of a package that is already removed: exits 0 and takes the copy and its record" test "$rc" -eq 0 -a ! -e "$policy" -a ! -e /var/lib/glyndor-podman
out="$(dpkg --purge podman 2>&1 < /dev/null)"; rc=$?
check "purge of a package that is not installed at all: exits 0" test "$rc" -eq 0
# the empty directories the package creates under /etc/containers: dpkg takes them when they are empty at the purge,
# and nothing the administrator put in one is taken, so the directory stays with it
check "purge: no directory of the package is left under /etc/containers" test ! -e /etc/containers
apt-get install -y -qq "$new" < /dev/null > /dev/null 2>&1
mkdir -p /etc/containers/registries.conf.d && printf 'unqualified-search-registries = ["example.org"]\n' > /etc/containers/registries.conf.d/50-admin.conf
out="$(apt-get purge -y podman < /dev/null 2>&1)"; rc=$?
check "purge with a file of the administrator's inside one of those directories: exits 0 and the file is still there" \
	test "$rc" -eq 0 -a -f /etc/containers/registries.conf.d/50-admin.conf
check "and the policy.json of the package is gone, with every directory that was left empty" test ! -e "$policy" -a "$(find /etc/containers -mindepth 1 -type f -o -mindepth 1 -type d | sort | tr '\n' ' ')" = "/etc/containers/registries.conf.d /etc/containers/registries.conf.d/50-admin.conf "
rm -rf /etc/containers

# the package of r12 and the one of this release leave a policy.json the administrator deleted deleted
if [ "$transition" = 0 ]; then
	reset_old deleted || exit 1
	out="$(dpkg -i "$new" 2>&1 < /dev/null)"; rc=$?
	check "dpkg -i over a release that already is r12 or later, with the file deleted by the administrator: exits 0 and does not create it" test "$rc" -eq 0 -a ! -e "$policy"
fi

# --- an upgrade interrupted between preinst and postinst ---
reset_old edited || exit 1
dpkg --unpack "$new" > /dev/null 2>&1
if [ "$transition" = 1 ]; then
	check "interrupted: the file of the administrator is set aside by preinst while the package is unpacked and not configured" test -e "$policy.glyndor-kept" -a ! -e "$policy"
fi
out="$(dpkg --configure podman 2>&1 < /dev/null)"; rc=$?
check "interrupted: the next configuration exits 0 and the file is the administrator's, byte for byte" test "$rc" -eq 0 -a "$(cat "$policy")" = "$admin_policy"
check "interrupted: nothing is left beside it" nothing_beside
if [ "$transition" = 1 ]; then
	reset_old edited || exit 1
	dpkg --unpack "$new" > /dev/null 2>&1
	printf '%s\n' '{"default":[{"type":"reject"}],"transports":{}}' > "$policy"
	out="$(dpkg --configure podman 2>&1 < /dev/null)"; rc=$?
	check "interrupted, and a file made in the meantime: it is not replaced, and the earlier one is set aside under another name" \
		test "$rc" -eq 0 -a "$(cat "$policy")" = '{"default":[{"type":"reject"}],"transports":{}}' -a "$(cat "$policy.glyndor-previous")" = "$admin_policy"
	check "interrupted, and a file made in the meantime: it says so" bash -c 'printf "%s\n" "$1" | grep -q glyndor-previous' _ "$out"
	rm -f "$policy.glyndor-previous"
fi

# --- the configuration with and without AppArmor ---
postinst=/var/lib/dpkg/info/podman.postinst
check "apparmor: with none on the machine the configuration exits 0 and says nothing of a profile" \
	bash -c 'out="$(PATH=/usr/bin:/bin sh "$1" configure 2>&1)"; rc=$?; [ "$rc" -eq 0 ] && ! printf "%s\n" "$out" | grep -q "did not load"' _ "$postinst"
mkdir -p /tmp/aa /etc/apparmor.d
printf '#!/bin/sh\nexit 1\n' > /tmp/aa/apparmor_parser; printf '#!/bin/sh\nexit 0\n' > /tmp/aa/aa-enabled; chmod +x /tmp/aa/apparmor_parser /tmp/aa/aa-enabled
: > /etc/apparmor.d/usr.bin.passt
check "apparmor: with it on and a parser that fails, the configuration exits 0 and names the profile" \
	bash -c 'out="$(PATH=/tmp/aa:/usr/bin:/bin sh "$1" configure 2>&1)"; rc=$?; [ "$rc" -eq 0 ] && printf "%s\n" "$out" | grep -q "AppArmor profile usr.bin.passt did not load"' _ "$postinst"
rm -f /etc/apparmor.d/usr.bin.passt; rm -rf /tmp/aa

echo
if [ "${#failed[@]}" -gt 0 ]; then
	echo "config upgrade test failed: ${failed[*]}"
	exit 1
fi
echo "config upgrade test passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
