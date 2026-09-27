<div align="center">

# Installation

### Install generated Kinect Remold runtimes without mixing build artifacts into the source tree

[Documentation](README.md) · [Quick start](QUICKSTART.md) · [Build](BUILD-DRIVERS.md) · [Compatibility](KINECT-COMPATIBILITY-MATRIX.md)

</div>

Kinect Remold separates **building** from **installing**. Build tools may download verified dependencies into user cache/work locations, while installation consumes only the generated bundle under `binaries/`.

## Windows

1. Build with `Kinect-Remold.cmd` when required.
2. Open `binaries\windows\drivers\kinect-xbox-360-remold\KINECT.cmd`.
3. Choose **Install / Reinstall**.
4. Allow the installer to trust the packaged development certificate and stage the generated PnP packages.

The installer does not disable Secure Boot or Windows signature enforcement. The Windows runtime uses Microsoft inbox WinUSB and USB Audio facilities together with Remold user-mode services. Windows 11 uses the Media Foundation virtual-camera path; Windows 10 build 19041 or newer uses the local MJPEG image backend.

## Linux

1. Build with `bash Kinect-Remold.sh`.
2. Run `sudo binaries/linux/drivers/kinect-xbox-360-remold/INSTALL.sh`.
3. Start SynKinect Studio from its generated desktop launcher or `SynKinectStudio.sh`.

The generated installer is an offline installation boundary: dependency resolution, firmware preparation and kernel-specific build work happen before installation. The installer maps the prepared bundle into normal `/usr` and `/etc` locations and does not perform package-manager downloads or compilation.

## Kinect One Remold

Kinect One Remold is a separate generation module under `drivers/modules/kinect-one-remold/`. It owns its own WinUSB/libusb transport and publishes only the capabilities implemented by that runtime. Do not treat Xbox 360-only controls such as tilt, LED or the 360 microphone-array path as cross-generation guarantees.

On both Windows and Linux the installed Kinect One service/daemon is detached from the source/build tree. Windows runs from `C:\Program Files\Kinect One Remold`; Linux runs from `/usr/libexec/kinect-one-remold` and stores its maintenance payload under `/usr/share/kinect-one-remold/maintenance`. After installation, moving or deleting the repository must not stop the runtime or leave a service holding repository files open. Repair and uninstall operate against the installed runtime state rather than requiring a live source checkout.

## Reinstall and recovery

A reinstall should be performed through the generated platform installer rather than by manually replacing individual binaries. This keeps driver package, service, endpoint and certificate state synchronized.

For build-stage failures, use the [Build guide](BUILD-DRIVERS.md) before changing installed device state. Build logs are kept outside the authored source tree under the platform work directory.
