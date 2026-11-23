#!/usr/bin/env bash
#
# Tests for scripts/package/rpm/build-extras.sh against fake sources and a rpmbuild that writes down what
# it was asked: each extra of the row of the distribution is unpacked, compiled and installed the way its
# project builds, packaged under its own name with the version and epoch of extras.txt and the release
# R.glyndor.<id>, and a name nobody has a recipe for, a missing source or a bad revision is refused.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$HERE/scripts/package/rpm/build-extras.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

mkdir "$WORK/bin" "$WORK/src"
# Package managers and the compiler tools answer yes; rpmbuild records its defines and makes a file.
for t in dnf zypper autoreconf; do printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$t" > "$WORK/bin/$t"; done
printf '#!/bin/sh\necho 2\n' > "$WORK/bin/nproc"
printf '#!/bin/sh\necho "ELF 64-bit"\n' > "$WORK/bin/file"
printf '#!/bin/sh\necho "strip $*" >> "$CALLS"\n' > "$WORK/bin/strip"
cat > "$WORK/bin/rpmbuild" <<'RB'
#!/bin/sh
echo "rpmbuild $*" >> "$CALLS"
prev=""; for a in "$@"; do [ "$prev" = --define ] && case "$a" in "_topdir "*) top="${a#_topdir }" ;; "gl_name "*) name="${a#gl_name }" ;; "gl_tree "*) tree="${a#gl_tree }" ;; esac; prev="$a"; done
(cd "$tree" && find . | sort) > "$TREES/$name.txt"
mkdir -p "$top/RPMS/x86_64"; : > "$top/RPMS/x86_64/$name-1.x86_64.rpm"
RB
# make: what the recipe asked for is written down, and install makes the files it would install
cat > "$WORK/bin/make" <<'MK'
#!/bin/sh
echo "make $*" >> "$CALLS"
dest=""; for a in "$@"; do case "$a" in DESTDIR=*) dest="${a#DESTDIR=}" ;; esac; done
[ -n "$dest" ] || exit 0
mkdir -p "$dest/usr/bin" "$dest/usr/lib"
for f in crun conmon catatonit passt; do : > "$dest/usr/bin/$f"; done
: > "$dest/usr/lib/libx.la"
MK
chmod +x "$WORK"/bin/*
# sources: tarballs for crun and catatonit, trees for conmon and passt, as fetch-extras.sh leaves them
mkdir -p "$WORK/t/crun-1.31" "$WORK/t/catatonit-0.2.1"
printf '#!/bin/sh\necho "configure $*" >> "$CALLS"\n' > "$WORK/t/crun-1.31/configure"; cp "$WORK/t/crun-1.31/configure" "$WORK/t/catatonit-0.2.1/configure"
chmod +x "$WORK/t"/*/configure
mkdir -p "$WORK/src/crun" "$WORK/src/catatonit" "$WORK/src/conmon/tree" "$WORK/src/passt/tree"
tar -C "$WORK/t" -czf "$WORK/src/crun/src.tar.gz" crun-1.31
tar -C "$WORK/t" -cJf "$WORK/src/catatonit/src.tar.xz" catatonit-0.2.1
echo m > "$WORK/src/conmon/tree/Makefile"; echo m > "$WORK/src/passt/tree/Makefile"
mkdir "$WORK/trees"; export CALLS="$WORK/calls" TREES="$WORK/trees"
PATH="$WORK/bin:$PATH"
run() { : > "$CALLS"; rm -rf "$WORK/out"; out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }
says() { printf '%s\n' "$out" | grep -c -F -- "$1"; }
calls() { grep -c -F -- "$1" "$CALLS"; }
defined() { grep -F "gl_name $1 " "$CALLS" | grep -o -- "--define $2 [^ ]*" | head -n 1 | cut -d' ' -f3; }

# a table of rows, and the real pins, for ids that take them
cat > "$WORK/table" <<'T'
am|rpm|amzn|x86_64|0|2|5|upstream|0^20260716||crun,conmon,catatonit
lp|rpm|suse|x86_64|0|0|0|upstream|20260716||crun,passt
nn|rpm|fedora|x86_64|5|2|5|upstream|0^20260716||
T
export GLYNDOR_DISTROS_FILE="$WORK/table"

run am 12 "$WORK/src" "$WORK/out"
check "a distribution that takes three extras builds them" 0 "$rc"
check "each is packaged under its own name" "catatonit-1.x86_64.rpm conmon-1.x86_64.rpm crun-1.x86_64.rpm" "$(ls "$WORK/out" | paste -sd' ')"
check "the version and the epoch are the ones of extras.txt: crun 1.31 epoch 0, conmon 2.2.1 epoch 2" "1.31 0 2.2.1 2" \
	"$(defined crun gl_version) $(defined crun gl_epoch) $(defined conmon gl_version) $(defined conmon gl_epoch)"
check "the release counter is the revision and the id is the distribution's" "12 am" "$(defined crun gl_release) $(defined crun gl_id)"
check "the tarballs are configured for /usr and installed into a tree each (crun and catatonit)" "2 2" "$(calls 'configure --prefix=/usr') $(calls 'make DESTDIR=')"
check "catatonit is regenerated before it is configured: its tarball has no configure of its own" 1 "$(calls 'autoreconf -fi')"
check "catatonit moves to where the distributions put it and is linked where Podman looks for it" "./usr/libexec/catatonit/catatonit ./usr/libexec/podman/catatonit" \
	"$(grep -e libexec/catatonit/catatonit -e libexec/podman/catatonit "$TREES/catatonit.txt" | paste -sd' ')"
check "and it is no longer in /usr/bin" 0 "$(grep -c '^./usr/bin/catatonit$' "$TREES/catatonit.txt")"
check "libraries nobody links against are not shipped" 0 "$(grep -c '\.la$' "$TREES/crun.txt")"
check "conmon is built with the prefix make asks for" 1 "$(calls 'make PREFIX=/usr DESTDIR=')"
check "binaries are stripped" 1 "$([ "$(calls 'strip --strip-unneeded')" -gt 0 ] && echo 1 || echo 0)"
run lp 3 "$WORK/src" "$WORK/out"
check "passt is built with its lower-case prefix" "0 1" "$rc $(calls 'make prefix=/usr DESTDIR=')"
check "and gets the pasta link" 1 "$(grep -c '^./usr/bin/pasta$' "$TREES/passt.txt")"
run nn 3 "$WORK/src" "$WORK/out"
check "a distribution that takes none builds nothing and succeeds" "0 0" "$rc $(calls rpmbuild)"
check "and says so" 1 "$(says 'takes no extras')"

rm -rf "$WORK/src/crun"; mkdir "$WORK/src/crun"; run am 12 "$WORK/src" "$WORK/out"
check "a source that was not fetched is refused" "1 1" "$rc $(says 'cannot unpack the source of crun')"
tar -C "$WORK/t" -czf "$WORK/src/crun/src.tar.gz" crun-1.31
printf 'zz|rpm|fedora|x86_64|5|2|5|upstream|0^20260716||crun\n' > "$WORK/table"
printf 'crun|1|0|tarball|u|p|k|f\n' > "$WORK/pins"
mv "$WORK/src/crun/src.tar.gz" "$WORK/src/crun/src.off"
GLYNDOR_EXTRAS_FILE="$WORK/pins" run zz 1 "$WORK/src" "$WORK/out"
check "a tarball source that is not there is refused" "1 1" "$rc $(says 'cannot unpack the source of crun')"
mv "$WORK/src/crun/src.off" "$WORK/src/crun/src.tar.gz"
printf 'crun|1|0|svn|u|p|k|f\n' > "$WORK/pins"
GLYNDOR_EXTRAS_FILE="$WORK/pins" run zz 1 "$WORK/src" "$WORK/out"
check "a kind nobody knows is built as a tree, and a tree that is not there is refused" 1 "$rc"
: > "$WORK/pins"
GLYNDOR_EXTRAS_FILE="$WORK/pins" run zz 1 "$WORK/src" "$WORK/out"
check "an extra the pins do not have is refused" "1 1" "$rc $(says 'is not in')"
printf 'nn|rpm|fedora|x86_64|5|2|5|upstream|0^20260716||\n' > "$WORK/table"
for bad in "" x 1.2 -1; do run nn "$bad" "$WORK/src" "$WORK/out"; check "the revision '$bad' is refused" 1 "$rc"; done
"$SCRIPT" > /dev/null 2>&1; check "no arguments is refused" 1 "$?"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
