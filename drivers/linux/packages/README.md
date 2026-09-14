# Native Linux packages — V1

Package artifacts are generated from current source and are not committed to the repository.

## Debian / Ubuntu / Mint

```bash
bash build-deb.sh amd64
```

The builder creates a temporary CMake build, compiles the complete native runtime, stages that exact output and generates:

```text
output/kinect360-remold_1.0-1_amd64.deb
```

The package installs the control broker, RGB/RGB-HQ/IR/Depth camera bridge, four-channel audio bridge with build-time embedded UACFirmware, V4L2 bridge, IP camera, control tool, udev rules, systemd units and configuration.

## Fedora / RHEL family

```bash
bash build-rpm.sh
```

The RPM builder creates a temporary source archive from `drivers/linux/source/` and invokes `rpmbuild`. `rpm/kinect360-remold.spec` compiles that source in `%build`; no generated driver payload is used as an input.

Distribution package names for facilities such as `v4l2loopback` can vary. V1 requires v4l2loopback 0.15.0 or newer at runtime.


Firmware policy: package compilation downloads and validates the pinned Microsoft Kinect for Windows Runtime v1.8, extracts UACFirmware 01.02.709.00, verifies SHA-256 `4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9`, and embeds it into `kinect360-remold-audio`. Runtime package installation performs no firmware download.