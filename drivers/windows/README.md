# Windows native runtime

The Windows driver/runtime source lives entirely under `source/`. Generated driver payloads are produced by the build.

## Build environment

- Windows 11 x64;
- Visual Studio/MSBuild with the current Microsoft desktop driver-development components;
- Windows SDK/Driver Kit 10.0.28000;
- PowerShell 5.1 or newer.

Build:

```text
Kinect-Xbox-360-Remold.cmd --build-only
```

The builder compiles the current source and publishes only to the repository-root `binaries\windows\drivers\` directory. It builds the per-device/multi-client camera bridge with RGB-HQ support, motor/device broker, audio bridge, virtual camera, IP camera, setup tools and PnP package artifacts.

The generated driver directory is recreated by the build and is ignored by source control. Build intermediates, downloads and logs remain outside the source tree.

After a successful build, run:

```text
..\..\binaries\windows\drivers\KINECT.cmd
```

and choose Install / Reinstall.

The native architecture uses Microsoft inbox WinUSB/USB Audio facilities and user-mode Remold services. See `BINARY-PAYLOAD.md`, `../../docs/BUILD-DRIVERS.md` and `../../docs/windows/ARCHITECTURE.md`.

## Camera stability policy

The physical Kinect color engine always starts in the proven 640×480 RGB mode. Scanner 3D uses RGB 640×480 + Depth as its default live transport. IR is selected only by a real IR consumer. RGB-HQ remains an isolated Scanner capability and is never requested by the Windows virtual camera or by Studio startup.

The virtual camera is a read-only 640×480/30 consumer of the shared RGB stream and has no authority to change the physical Kinect mode.
