# Installation

The project must be built before installation. The source tree itself contains no native binaries.

## Windows

Build with `Kinect-Xbox-360-Remold.cmd`, then run:

```text
binaries\windows\drivers\KINECT.cmd
```

Choose **Install / Reinstall**. The installer stages the required PnP packages, installs the resident services, copies the runtime to Program Files and starts CameraBridge, which is the sole owner that reconciles one Media Foundation virtual camera per Kinect. Development builds install the generated development certificate required by their signed PnP catalogs.

Uninstall through the same control panel or the generated driver `UNINSTALL` path.

## Linux

Build with:

```bash
bash Kinect-Xbox-360-Remold.sh
```

Install with:

```bash
sudo binaries/linux/drivers/INSTALL.sh
```

Uninstall with:

```bash
sudo binaries/linux/drivers/UNINSTALL.sh
```

The build stage downloads/installs host build dependencies, prepares the verified Kinect UAC firmware and compiles the kernel-specific `v4l2loopback` module. The installer only places that prebuilt bundle, udev rules, systemd units and configuration. Installation performs no download, package-manager operation or compilation. If the running kernel differs from the one used to build the bundle, installation stops before modifying the runtime and requests a rebuild under the current kernel.
