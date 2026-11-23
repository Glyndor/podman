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
