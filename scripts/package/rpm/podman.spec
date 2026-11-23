# Podman with its network stack, built from the upstream releases.
#
# This spec packages a tree that scripts/package/build-payload.sh already built from the
# verified upstream tags, so it compiles nothing and fetches nothing: the install section
# copies the tree. scripts/package/rpm/build-rpm.sh passes every gl_* value on the command
# line; a build without one fails here instead of producing a package that says something else.
#
# What it says to the package manager is the contract of this repository
# (docs/packages.md): the epoch of the distribution's own Podman, so that it replaces
# that one, and the Provides and Obsoletes that make it replace the packages the .deb also
# replaces.

%global debug_package %{nil}
%global _build_id_links none
# The tree is stripped and its man pages are plain files: the brp scripts would compress,
# strip and rewrite what the payload already settled, and a rewritten man page link breaks
# the file list.
%global __os_install_post %{nil}

%{!?gl_epoch:%{error:gl_epoch is not set}}
%{!?gl_version:%{error:gl_version is not set}}
%{!?gl_release:%{error:gl_release is not set}}
%{!?gl_id:%{error:gl_id is not set}}
%{!?gl_family:%{error:gl_family is not set}}
%{!?gl_payload:%{error:gl_payload is not set}}
%{!?gl_netavark:%{error:gl_netavark is not set}}
%{!?gl_aardvark:%{error:gl_aardvark is not set}}
%{!?gl_nv_epoch:%{error:gl_nv_epoch is not set}}
%{!?gl_cc_epoch:%{error:gl_cc_epoch is not set}}
%{!?gl_cc_version:%{error:gl_cc_version is not set}}
%{!?gl_passt_min:%{error:gl_passt_min is not set}}

Name:           podman
Epoch:          %{gl_epoch}
Version:        %{gl_version}
Release:        %{gl_release}.glyndor.%{gl_id}
Summary:        Podman with its network stack, built from the upstream releases
License:        Apache-2.0 AND BSD-2-Clause AND BSD-3-Clause AND ISC AND MIT AND MPL-2.0
URL:            https://podman.io
Vendor:         Glyndor
Packager:       Glyndor <noreply@glyndor.net>
ExclusiveArch:  x86_64 aarch64

Requires:       catatonit
Requires:       conmon >= 2.1.7
Requires:       crun >= 1.21
Requires:       passt >= %{gl_passt_min}
Requires:       nftables
Requires:       (container-selinux if selinux-policy)
%if "%{gl_family}" == "suse"
Recommends:     shadow
%else
Recommends:     shadow-utils
%endif

# What this package carries and the distribution's packages it replaces. Unversioned
# Obsoletes: a later build of any of them by the distribution is not installed beside this
# one. The epochs are the ones the distribution uses for each name, so that what depends
# on them keeps being satisfied.
Provides:       podman-remote = %{epoch}:%{version}-%{release}
Obsoletes:      podman-remote
Provides:       podman-quadlet = %{epoch}:%{version}-%{release}
Obsoletes:      podman-quadlet
Provides:       podman-manpages = %{epoch}:%{version}-%{release}
# Two packages of the distribution that require podman at an exact version, which would stop
# the update of a host that has them. They are cheaper to replace than to rebuild.
Obsoletes:      podman-machine
Obsoletes:      podman-tests
%if "%{gl_id}" == "el9"
# What the distribution's podman provides on EL 9 beyond its own name.
Provides:       podman-catatonit = %{epoch}:%{version}-%{release}
Provides:       podman-podmansh = %{epoch}:%{version}-%{release}
Provides:       podman-shell = %{epoch}:%{version}-%{release}
Provides:       podmansh = %{epoch}:%{version}-%{release}
%endif
Provides:       netavark = %{gl_nv_epoch}:%{gl_netavark}-%{release}
Obsoletes:      netavark
Provides:       aardvark-dns = %{gl_nv_epoch}:%{gl_aardvark}-%{release}
Obsoletes:      aardvark-dns
Provides:       container-network-stack = 2
%if "%{gl_family}" == "suse"
Provides:       libcontainers-common = %{gl_cc_epoch}:%{gl_cc_version}-%{release}
Obsoletes:      libcontainers-common
Provides:       libcontainers-image = %{gl_cc_version}
Obsoletes:      libcontainers-image
Provides:       libcontainers-storage = %{gl_cc_version}
Obsoletes:      libcontainers-storage
Provides:       libcontainers-policy = %{gl_cc_version}
Obsoletes:      libcontainers-policy
Provides:       registries-conf = %{gl_cc_version}
Obsoletes:      registries-conf
%else
Provides:       containers-common = %{gl_cc_epoch}:%{gl_cc_version}-%{release}
Obsoletes:      containers-common
Provides:       containers-common-extra = %{gl_cc_epoch}:%{gl_cc_version}-%{release}
Obsoletes:      containers-common-extra
Provides:       skopeo-containers = %{gl_cc_epoch}:%{gl_cc_version}-%{release}
Obsoletes:      skopeo-containers
%endif

%description
Daemonless container engine, packaged from the signed upstream tags of Podman, netavark and
aardvark-dns, with the containers-common configuration it asks for. The network components
and that configuration replace the older copies the distributions ship.

# What the administrator wrote in /etc/containers belongs to the administrator, and this package puts no file
# there. The packages it replaces own some of them, and removing a package takes its files with it. Measured on
# 2026-11-23: on Fedora 45 and EL 10 the package owns containers.conf and storage.conf as %ghost files, and
# erasing it removes whatever is there, which includes what an administrator wrote; EL 9 and Amazon Linux 2023
# save an edited %config file as .rpmsave, and delete a plain one. Podman then falls back to
# /usr/share/containers, the default and not the policy the administrator chose. So, when this is the first
# Glyndor podman on the machine, each file of /etc/containers that a package owns and that is either marked
# %ghost or reported changed by rpm -V (the digest flag) is copied aside before the transaction starts and put
# back after it, only where nothing is.
%pretrans -p /bin/sh
if ! rpm -q --qf '%%{VENDOR}\n' podman 2> /dev/null | grep -qx Glyndor; then
	for f in $(find /etc/containers -type f 2> /dev/null); do
		rpm -qf "$f" > /dev/null 2>&1 || continue
		if rpm -Vf "$f" 2> /dev/null | grep -Eq "^.{2}5.* $f\$" \
			|| rpm -qf --qf '[%%{FILENAMES} %%{FILEFLAGS:fflags}\n]' "$f" 2> /dev/null | grep -Eq "^$f [a-zA-Z]*g"; then
			cp -p "$f" "$f.glyndor-saved"
		fi
	done
fi
exit 0

%posttrans -p /bin/sh
for s in $(find /etc/containers -name '*.glyndor-saved' 2> /dev/null); do
	f="${s%%.glyndor-saved}"
	if [ -e "$f" ]; then
		rm -f "$s"
	else
		mv "$s" "$f"
		echo "podman: kept your $f, which a package that podman replaces had" >&2
	fi
done
exit 0

%package docker
Summary:        Emulate the Docker CLI using Podman
BuildArch:      noarch
Requires:       podman = %{epoch}:%{version}-%{release}
Conflicts:      docker
Conflicts:      docker-latest
Conflicts:      docker-ce
Conflicts:      docker-ee
Conflicts:      moby-engine

%description docker
A script named docker that runs Podman commands, and the links between the docker and podman
man pages.

%package -n podmansh
Summary:        Confined login and user shell using Podman
BuildArch:      noarch
Requires:       podman = %{epoch}:%{version}-%{release}
Provides:       podman-shell = %{epoch}:%{version}-%{release}
Provides:       podman-podmansh = %{epoch}:%{version}-%{release}

%description -n podmansh
podmansh is a link to the podman binary that runs a confined login and user shell inside a
container.

%prep

%build

%install
cp -a %{gl_payload}/main/. %{buildroot}/
cp -a %{gl_payload}/docker/. %{buildroot}/
cp -a %{gl_payload}/sh/. %{buildroot}/
# A directory that two packages own has to have the same mode in both, or the transaction
# stops on a conflict: Fedora's catatonit owns /usr/libexec/podman as 0755, and the payload
# was written by whoever ran the build, with whatever umask. Nothing here is group or world
# writable.
chmod -R u+rwX,go+rX,go-w %{buildroot}
# The file lists are read from the payload, so a file it gains is owned by the package, and
# one the package names that is not there stops the build. Files under /etc are
# configuration, and the directories of the containers configuration are owned: nothing
# else would remove them.
lists=%{_topdir}/lists
mkdir -p "$lists"
filelist() { # <tree>
    ( cd "$1" && find . -mindepth 1 \( -type f -o -type l \) -print | sed 's|^\.||' | LC_ALL=C sort ) \
        | sed -e 's|^\(/etc/.*\)$|%%config(noreplace) \1|'
}
filelist %{gl_payload}/main > "$lists/podman.files"
( cd %{gl_payload}/main && find etc/containers usr/share/containers usr/libexec/podman -type d -print \
    | sed 's|^|/|' | LC_ALL=C sort ) | sed 's|^|%%dir |' >> "$lists/podman.files"
filelist %{gl_payload}/docker > "$lists/podman-docker.files"
filelist %{gl_payload}/sh > "$lists/podmansh.files"

%files -f %{_topdir}/lists/podman.files

%files docker -f %{_topdir}/lists/podman-docker.files

%files -n podmansh -f %{_topdir}/lists/podmansh.files
