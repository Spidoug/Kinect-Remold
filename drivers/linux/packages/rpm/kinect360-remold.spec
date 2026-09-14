Name:           kinect360-remold
Version:        1.0
Release:        1%{?dist}
Summary:        Kinect Xbox 360 Remold native Linux runtime
License:        LicenseRef-Kinect-Xbox-360-Remold
URL:            https://github.com/
Source0:        %{name}-%{version}.tar.gz
BuildArch:      x86_64

BuildRequires:  gcc-c++
BuildRequires:  cmake
BuildRequires:  pkgconfig(libusb-1.0)
BuildRequires:  pkgconfig(alsa)
BuildRequires:  libjpeg-turbo-devel
BuildRequires:  systemd-rpm-macros
BuildRequires:  python3
BuildRequires:  ca-certificates
BuildRequires:  cabextract
BuildRequires:  msitools

Requires:       libusb1
Requires:       alsa-lib
Requires:       libjpeg-turbo
Requires:       systemd
Requires:       udev
Requires:       kmod
Requires:       v4l2loopback >= 0.15.0
Requires:       v4l-utils

%description
Kinect Xbox 360 Remold V1 user-space runtime: direct libusb RGB/RGB-HQ/IR/Depth,
four-channel audio, motor/status broker, V4L2 virtual camera and authenticated
IP-camera service for Kinect 1414/1473.

%prep
%setup -q

%build
REMOLD_BUILD_JOBS=%{?_smp_build_ncpus} REMOLD_BUILD_DIR="$PWD/build" REMOLD_DIST_DIR="$PWD/dist/usr" \
  bash scripts/build.sh --clean --no-deps

%install
rm -rf %{buildroot}
install -d %{buildroot}%{_prefix}
cp -a dist/usr/. %{buildroot}%{_prefix}/
install -d %{buildroot}%{_unitdir} %{buildroot}%{_udevrulesdir} \
  %{buildroot}%{_sysconfdir}/kinect360-remold %{buildroot}%{_datadir}/kinect360-remold
install -m0644 systemd/* %{buildroot}%{_unitdir}/
install -m0644 udev/60-kinect360-remold.rules %{buildroot}%{_udevrulesdir}/
install -m0644 config/remold.conf %{buildroot}%{_sysconfdir}/kinect360-remold/remold.conf

%post
/usr/bin/systemctl daemon-reload >/dev/null 2>&1 || :
/usr/bin/systemctl disable kinect360-remold.target >/dev/null 2>&1 || :
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :
/usr/bin/udevadm trigger --subsystem-match=usb >/dev/null 2>&1 || :
%{_libexecdir}/kinect360-remold/ensure-v4l2-device.sh >/dev/null 2>&1 || :
KINECT_PRESENT=0
for DEV in /sys/bus/usb/devices/*; do
  [ -r "$DEV/idVendor" ] && [ -r "$DEV/idProduct" ] || continue
  [ "$(cat "$DEV/idVendor")" = "045e" ] || continue
  case "$(cat "$DEV/idProduct")" in 02b0|02c2|02ae|02ad|02bb|02c3) KINECT_PRESENT=1; break;; esac
done
if [ "$KINECT_PRESENT" = 1 ]; then /usr/bin/systemctl start kinect360-remold.target >/dev/null 2>&1 || :; fi

%preun
if [ "$1" -eq 0 ]; then /usr/bin/systemctl stop kinect360-remold.target >/dev/null 2>&1 || :; fi

%postun
/usr/bin/systemctl daemon-reload >/dev/null 2>&1 || :
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :

%files
%config(noreplace) %{_sysconfdir}/kinect360-remold/remold.conf
%{_bindir}/kinect360-remoldctl
%{_libexecdir}/kinect360-remold/*
%{_unitdir}/kinect360-remold*
%{_udevrulesdir}/60-kinect360-remold.rules

%changelog
* Tue Aug 25 2026 Kinect Xbox 360 Remold Project - 1.0-1
- V1 source build with multi-Kinect transport, RGB-HQ and current service policy.
