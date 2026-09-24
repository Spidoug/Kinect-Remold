# Build

The source tree contains no generated binaries or downloaded dependencies. A full build publishes only under the root `binaries/` directory.

```text
binaries/
├── windows/
│   ├── applications/SynKinectStudio/
│   ├── drivers/
│   └── sdk/
└── linux/
    ├── applications/SynKinectStudio/
    ├── drivers/
    └── sdk/
```

## Windows

Run `Kinect-Xbox-360-Remold.cmd` from an ordinary Command Prompt. Native components are compiled first, followed by SynKinect Studio. Temporary work, dependency downloads and logs remain outside the repository under the Windows user cache/temp locations.

The Windows driver build publishes the signed PnP packages, user-mode services, virtual-camera components, installer/control scripts and tools into `binaries/windows/drivers/`. The SDK contract and protocol headers are published into `binaries/windows/sdk/`.

## Linux

Run `bash Kinect-Xbox-360-Remold.sh`. The driver build uses an external CMake build directory and publishes the runtime into `binaries/linux/drivers/`; the SDK contract is published into `binaries/linux/sdk/`. SynKinect Studio is published into `binaries/linux/applications/SynKinectStudio/`.

Linux installation is script-only. There are no DEB or RPM builders in the current build system. The build stage is the only stage allowed to fetch/install dependencies or compile the kernel-specific `v4l2loopback` module. Run `sudo binaries/linux/drivers/INSTALL.sh` after a successful build; installation is offline and consumes only the prepared bundle. Run `sudo binaries/linux/drivers/UNINSTALL.sh` to remove it.

## Build isolation

Do not place generated objects, caches, downloaded archives, toolchains or runtime products under `applications/` or `drivers/`. Those directories are source-only.
