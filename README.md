# Kinect Xbox 360 Remold

Kinect Xbox 360 Remold is a clean-source Windows and Linux runtime plus SynKinect Studio for Kinect Xbox 360 models 1414 and 1473.

The repository contains source, build scripts, runtime templates and documentation only. Downloaded dependencies, toolchains, native build intermediates and generated binaries are not stored in the source tree.

## Architecture

Every connected Kinect is represented by one stable device identity. That identity binds the control transport, raw camera transport, audio transport, virtual camera and application endpoints for the same physical sensor.

For each connected Kinect:

- one virtual camera is published;
- one four-channel Remold audio stream endpoint is published;
- one audio-control endpoint is published;
- camera/scanner operations are routed by the same device ID;
- motor, LED and accelerometer commands are routed by the same device ID;
- SynKinect Studio enables driver-backed controls only when the required endpoint for the selected Kinect is available.

Windows uses Media Foundation virtual cameras, WinUSB for Remold-owned USB transports, the Windows USB Audio stack for the Kinect UAC runtime and WASAPI for four-channel capture.

Linux uses libusb for Kinect camera/control transport, ALSA for the Kinect USB Audio runtime and one v4l2loopback virtual camera per connected Kinect.

## Smart virtual camera and automatic Tilt

Automatic Tilt is scoped to each Kinect independently.

The virtual camera for a Kinect tracks whether that specific virtual camera is being consumed. While active, its face tracker evaluates that Kinect's RGB stream and adjusts only that Kinect's motor through the per-device control route. Accelerometer feedback, command rate limits, dead zones and motor settling limits are applied independently per sensor.

When a virtual camera is not being consumed, its face-tracking Tilt loop does not move the corresponding Kinect.

The virtual camera always carries the Kinect RGB stream and follows the RGB HQ setting of its Kinect: 1280x1024 while RGB HQ is on, 640x480 otherwise, on Linux and Windows alike. Digital pan, zoom and vertical framing follow the same face target as the motor.

Linux and Windows run the same Smart Tilt controller and the same per-model motion contract: the camera service is the only component that polls motor status (1414 every 25 ms, 1473 every 500 ms, only while a frame consumer is active) and every frame carries its accelerometer/tilt sample. See [`docs/MOTION.md`](docs/MOTION.md).

## IP camera

The optional IP-camera runtime is secure-by-default: it is disabled after a fresh install and binds only to `127.0.0.1` until an administrator explicitly enables LAN mode. Credentials are randomly generated and hidden from normal status output. On normal enable, the stream is pinned to one stable Kinect `deviceId`, so a disconnected sensor is not silently replaced by another camera. LAN mode is limited to private/link-local peers; Windows additionally limits its firewall rule to the Private profile and LocalSubnet. Repeated failed logins are rate-limited, request sizes/routes/methods are constrained, and browser-facing responses carry restrictive security headers.

The built-in transport is authenticated HTTP, not TLS. Do not expose it directly to the public internet; use a VPN or TLS reverse proxy for access outside a trusted private network. Linux runs the IP service as a dedicated unprivileged account. Local product IPC is available immediately to the desktop session; physical USB nodes remain protected by udev/logind access control.

## Build output

A full build creates one root output tree:

```text
binaries/
├── windows/
│   ├── applications/
│   │   └── SynKinectStudio/
│   ├── drivers/
│   └── sdk/
└── linux/
    ├── applications/
    │   └── SynKinectStudio/
    ├── drivers/
    └── sdk/
```

No generated binary is written to `applications/` or `drivers/`.

## Windows build

Double-click or run:

```bat
Kinect-Xbox-360-Remold.cmd
```

If any required binary is missing, the launcher builds the complete Windows runtime and Studio. When all artifacts are ready it opens SynKinect Studio directly through the windowless launcher, without keeping a Command Prompt open.

The build downloads verified build dependencies into:

```text
%LOCALAPPDATA%\Kinect360Remold\Cache\windows
```

and keeps temporary work outside the repository under:

```text
%LOCALAPPDATA%\Kinect360Remold\Work\windows
```

The generated runtime control entry point is:

```text
binaries\windows\drivers\KINECT.cmd
```

SynKinect Studio is generated under:

```text
binaries\windows\applications\SynKinectStudio\
```

## Linux build

Run or launch `Kinect-Xbox-360-Remold.sh`. If required binaries are missing it builds the complete Linux runtime and Studio; otherwise it opens Studio directly. From a graphical desktop, a terminal is used only while a build is actually required. Missing build dependencies are detected before compilation and can be installed through the native `apt`, `dnf` or `pacman` package manager after the normal administrator prompt. If compilation fails, the build terminal remains open and reports the failing stage and log path; after a successful build, the launcher verifies that SynKinect Studio actually starts before closing the build terminal.

The Linux launcher, the control panel's Install and `INSTALL.sh` compare a content fingerprint of `drivers/linux` with the one stored in the built runtime, so the installed broker/camera/audio executables always come from the current sources. Hardware routing is model-specific: model 1414 uses the dedicated `045E:02B0` motor function; model 1473 leaves `045E:02C2` as the parent hub and uses runtime `02BB/02C3 MI_00` for control while ALSA uses the UAC audio interface.

The Linux build is also the provisioning boundary: it prepares the verified UAC firmware and compiles the pinned `v4l2loopback` module for the running kernel. `Install / Reinstall` and `binaries/linux/drivers/INSTALL.sh` perform no download, package-manager operation or compilation; they install and verify only the already-built bundle.

```bash
bash Kinect-Xbox-360-Remold.sh
```

Temporary build work is kept outside the repository under the XDG cache location, or under `REMOLD_WORK_ROOT` when explicitly configured.

The generated runtime control entry point is:

```text
binaries/linux/drivers/KINECT.sh
```

SynKinect Studio is generated under:

```text
binaries/linux/applications/SynKinectStudio/
```

## Firmware

Windows obtains and verifies the Microsoft Kinect Runtime 1.8 package during the driver build and extracts the required `UACFirmware` into build work outside the source tree.

Linux uses the same UAC runtime model. `UACFirmware` is not committed to this repository. During a full Linux build, the official Microsoft Kinect Runtime v1.8 package is downloaded into the user cache, verified, and the exact UAC firmware image is extracted and verified before it is placed in the generated runtime support directory. `KINECT_UAC_FIRMWARE` remains available for an offline build with the exact validated image.

## SDK endpoint

The SDK output is an endpoint contract, not a copy of the Microsoft Kinect SDK.

Windows:

```text
\\.\pipe\Kinect360RemoldSdk
```

Linux:

```text
/run/kinect360-remold/sdk.sock
```

Both SDK transports select a physical Kinect by stable `deviceId` or sensor index.

## Source layout

```text
applications/   SynKinect Studio source, resources and module API source
drivers/        Windows and Linux native runtime source
scripts/        top-level Studio, driver and SDK build entry points
docs/           architecture, installation and protocol documentation
licenses/       repository license material
Kinect-Xbox-360-Remold.cmd  smart Windows build/launch entry point
Kinect-Xbox-360-Remold.sh   smart Linux build/launch entry point
VERSION         product version
```

See `docs/QUICKSTART.md`, `docs/ARCHITECTURE.md` and `docs/BUILD-DRIVERS.md` for the operating model and build details.
