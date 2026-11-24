# A dependency of podman that a distribution lacks or has too old, built from its upstream release and
# packaged beside podman: crun, conmon, catatonit or passt. scripts/package/rpm/build-extras.sh
# compiled it into a tree and passes every gl_* value on the command line; a build without one fails
# here. The package has the Name of the distribution's own, so what requires the name is satisfied and a
# newer package of the distribution replaces it, and no Obsoletes: this one leaves when the
# distribution catches up.

%global debug_package %{nil}
%global _build_id_links none
%global __os_install_post %{nil}

%{!?gl_name:%{error:gl_name is not set}}
%{!?gl_version:%{error:gl_version is not set}}
%{!?gl_epoch:%{error:gl_epoch is not set}}
%{!?gl_release:%{error:gl_release is not set}}
%{!?gl_id:%{error:gl_id is not set}}
%{!?gl_tree:%{error:gl_tree is not set}}

Name:           %{gl_name}
Epoch:          %{gl_epoch}
Version:        %{gl_version}
Release:        %{gl_release}.glyndor.%{gl_id}
Summary:        %{gl_name} %{gl_version}, built from its upstream release
License:        GPL-2.0-or-later AND LGPL-2.1-or-later AND GPL-3.0-or-later AND ISC AND MIT
URL:            https://github.com/containers
Vendor:         Glyndor
Packager:       Glyndor <noreply@glyndor.net>
ExclusiveArch:  x86_64 aarch64
%if "%{gl_name}" == "crun"
Provides:       oci-runtime
%endif

%description
%{gl_name} %{gl_version}, packaged by Glyndor beside Podman for a distribution whose own package is
missing or older than the one Podman needs.

%prep

%build

%install
cp -a %{gl_tree}/. %{buildroot}/
chmod -R u+rwX,go+rX,go-w %{buildroot}
lists=%{_topdir}/lists
mkdir -p "$lists"
( cd %{buildroot} && find . -mindepth 1 \( -type f -o -type l \) -print | sed 's|^\.||' | LC_ALL=C sort ) > "$lists/%{gl_name}.files"
%if "%{gl_name}" == "catatonit"
# The directory Podman looks for its helpers in, which podman owns with the same mode.
echo '%%dir /usr/libexec/podman' >> "$lists/%{gl_name}.files"
%endif

%files -f %{_topdir}/lists/%{gl_name}.files
