#!/usr/bin/env bash
#
# The %pretrans and %posttrans of podman.spec, which keep what an administrator wrote in /etc/containers when the packages
# that own it are replaced. They are cut out of the spec and run here on a copy of /etc/containers, with an rpm that
# answers what the real one answers for the cases (owned or not, changed or not, %ghost or not) and with NO find on the
# PATH, since the minimal images of Amazon Linux, Leap and Tumbleweed have none: a scriptlet that needed it saved
# nothing there, without a word, and the update lost registries.conf and policy.json (podman#97, Leap 16.1).
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SPEC="$HERE/scripts/package/rpm/podman.spec"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# The scriptlets as rpm hands them to sh: %% is a % after the macros are expanded, and the directory is this one's.
cut_scriptlet() { # <name>: the body between %<name> -p /bin/sh and its exit 0
	sed -n "/^%$1 -p \\/bin\\/sh\$/,/^exit 0\$/p" "$SPEC" | sed '1d' | sed 's/%%/%/g' | sed "s#/etc/containers#$WORK/etc/containers#g"
}
cut_scriptlet pretrans > "$WORK/pretrans.sh"
cut_scriptlet posttrans > "$WORK/posttrans.sh"
check "the pretrans is found in the spec" 1 "$([ "$(wc -l < "$WORK/pretrans.sh")" -gt 5 ] && echo 1 || echo 0)"
check "the posttrans is found in the spec" 1 "$([ "$(wc -l < "$WORK/posttrans.sh")" -gt 5 ] && echo 1 || echo 0)"
check "neither of them runs find" 0 "$(grep -v '^[[:space:]]*#' "$WORK/pretrans.sh" "$WORK/posttrans.sh" | grep -c '\bfind\b')"

# An rpm that says what the cases need: OWNED are the files a package owns, MODIFIED those rpm -V reports with the digest flag,
# GHOST those it marks %ghost; the vendor of podman is VENDOR.
mkdir -p "$WORK/bin" "$WORK/tools"
cat > "$WORK/bin/rpm" <<'RPM'
#!/bin/sh
case "$1" in
	-q) [ "$2" = --qf ] && printf '%s\n' "${VENDOR:-SUSE LLC}"; exit 0 ;;
	-qf)
		if [ "$2" = --qf ]; then f="$4"; case " $GHOST " in *" $f "*) printf '%s cng\n' "$f" ;; *) printf '%s cn\n' "$f" ;; esac; exit 0; fi
		case " $OWNED " in *" $2 "*) exit 0 ;; *) exit 1 ;; esac ;;
	-Vf) case " $MODIFIED " in *" $2 "*) printf 'S.5....T.  c %s\n' "$2" ;; esac; exit 0 ;;
esac
RPM
chmod +x "$WORK/bin/rpm"
# The plain tools the scriptlets use and no find: the PATH is these and the rpm above, nothing else.
for t in sh grep cp mv rm cat; do ln -sf "$(command -v "$t")" "$WORK/tools/$t"; done
check "the PATH of the test has no find" 1 "$(PATH="$WORK/tools:$WORK/bin" command -v find > /dev/null 2>&1; echo $?)"

E="$WORK/etc/containers"
fresh() { rm -rf "${WORK:?}/etc"; mkdir -p "$E/registries.conf.d" "$E/certs.d/host"
	for f in registries.conf policy.json storage.conf containers.conf registries.conf.d/50-admin.conf certs.d/host/ca.crt; do echo "changed $f" > "$E/$f"; done; }
runs() { PATH="$WORK/tools:$WORK/bin" OWNED="$OWNED" MODIFIED="$MODIFIED" GHOST="$GHOST" VENDOR="${VENDOR:-SUSE LLC}" sh "$WORK/$1.sh" > "$WORK/out.$1" 2>&1; }
saved() { (cd "$E" && ls *.glyndor-saved */*.glyndor-saved */*/*.glyndor-saved 2> /dev/null | sed 's/\.glyndor-saved$//' | sort | paste -sd' '); }

fresh
OWNED="$E/registries.conf $E/policy.json $E/storage.conf $E/registries.conf.d/50-admin.conf $E/certs.d/host/ca.crt"
MODIFIED="$E/registries.conf $E/policy.json $E/registries.conf.d/50-admin.conf $E/certs.d/host/ca.crt"
GHOST="$E/storage.conf"
runs pretrans
check "the pretrans sets aside what a package owns and rpm reports changed, at every level, and what it marks %ghost" \
	"certs.d/host/ca.crt policy.json registries.conf registries.conf.d/50-admin.conf storage.conf" "$(saved)"
check "and it sets aside nothing that no package owns (containers.conf is the administrator's own)" 0 "$([ -e "$E/containers.conf.glyndor-saved" ] && echo 1 || echo 0)"
check "and the files themselves are still there, untouched" "changed policy.json" "$(cat "$E/policy.json")"
fresh; MODIFIED="$E/policy.json"; GHOST=""; runs pretrans
check "a file that a package owns and that is unchanged is not set aside" "policy.json" "$(saved)"
fresh; VENDOR=Glyndor; MODIFIED="$E/policy.json $E/registries.conf"; runs pretrans
check "when the installed podman is already Glyndor's nothing is set aside: what is there belongs to the administrator" "" "$(saved)"
VENDOR=""
# The posttrans: what the update removed is put back, what it left is not overwritten.
fresh; rm "$E/registries.conf" "$E/policy.json"; echo "saved registries" > "$E/registries.conf.glyndor-saved"; echo "saved policy" > "$E/policy.json.glyndor-saved"
echo "written by the package" > "$E/storage.conf"; echo "saved storage" > "$E/storage.conf.glyndor-saved"
echo "saved ca" > "$E/certs.d/host/ca.crt.glyndor-saved"; rm "$E/certs.d/host/ca.crt"
runs posttrans
check "the posttrans puts back registries.conf" "saved registries" "$(cat "$E/registries.conf")"
check "and policy.json" "saved policy" "$(cat "$E/policy.json")"
check "and a file in a subdirectory" "saved ca" "$(cat "$E/certs.d/host/ca.crt")"
check "and leaves alone a file the update put there, and drops the copy" "written by the package 0" "$(cat "$E/storage.conf") $([ -e "$E/storage.conf.glyndor-saved" ] && echo 1 || echo 0)"
check "and says which files it kept" 3 "$(grep -c 'podman: kept your' "$WORK/out.posttrans")"
check "and no copy is left behind" "" "$(saved)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
