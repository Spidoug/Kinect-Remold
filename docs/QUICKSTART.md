<div align="center">

# Quick Start

### From source tree to a running Kinect Remold environment

[Documentation](README.md) · [Installation](INSTALLATION.md) · [Build](BUILD-DRIVERS.md)

</div>

> **Target hardware:** first-generation Kinect 1414, 1473 and Kinect for Windows 1517, plus Kinect v2 / Kinect for Xbox One through the separate Kinect One Remold runtime.

## Windows

1. Extract the source ZIP to a normal writable directory.
2. Run `Kinect-Remold.cmd` from an ordinary Command Prompt.
3. After the driver build succeeds, run `binaries\windows\drivers\kinect-xbox-360-remold\KINECT.cmd` and choose **Install / Reinstall**.
4. After the Studio build succeeds, launch `binaries\windows\applications\SynKinectStudio\SynKinectStudio.exe`.

The resident runtime reconciles hot-plugged Kinects by stable device identity. Windows 11 can expose a Media Foundation virtual camera for each Kinect. Windows 10 build 19041 or newer uses the loopback-only local MJPEG image backend. Audio and control endpoints remain per device.

> **Build note:** the native runtime and SynKinect Studio are built as separate stages. If a stage fails, fix that stage and rerun the root launcher; successfully generated native artifacts remain available for diagnosis and reinstall.

## Linux

1. Extract the source ZIP to a normal writable directory.
2. Run `bash Kinect-Remold.sh`.
3. After a successful native build, run `sudo binaries/linux/drivers/kinect-xbox-360-remold/INSTALL.sh`.
4. Launch `binaries/linux/applications/SynKinectStudio/SynKinectStudio.desktop` from the desktop environment, or run `SynKinectStudio.sh`.

Linux installation is performed only by the generated scripts. The source tree does not generate native package-manager packages.

## Device lifecycle

The Studio discovers devices through every registered driver-module SDK endpoint and merges them into one selector using the qualified identity `module-id + deviceId`. A Kinect remains represented while it is `Booting` or `Reconnecting`; controls are enabled only when their required endpoint reports ready.

## Studio preferences

The language selected in the Studio top bar is stored per operating-system user and restored on the next launch. Packaged locale and configuration files are not modified.

## Next steps

- Need a clean install/reinstall path? Continue with [Installation](INSTALLATION.md).
- Need to understand the Broker, CameraBridge and AudioBridge boundaries? Read [Architecture](ARCHITECTURE.md).
- Need exact model behavior? Read the [Compatibility matrix](KINECT-COMPATIBILITY-MATRIX.md).
