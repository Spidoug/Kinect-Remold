# Installation — V1

Native drivers are built from the source in this repository. The source archive does not include a native driver executable/package payload.

## Windows x64

Requirements:

- Windows 10/11 x64;
- Visual Studio/MSBuild with the current Microsoft desktop driver-development components (bootstrapped automatically when absent);
- Windows SDK/Driver Kit 10.0.28000 (bootstrapped automatically when absent);
- PowerShell 5.1+.

Build:

```text
drivers\windows\BUILD.cmd
```

The command generates `drivers\windows\binaries\` from the current source. Then run:

```text
drivers\windows\binaries\KINECT.cmd
```

and choose Install / Reinstall. `KINECT.cmd` itself stays at normal user integrity; UAC is requested only when an administrative operation begins. SynKinect Studio is never launched elevated.

The build/signing flow must use the intended Windows signing environment. V1 does not require weakening Secure Boot, BCD or Code Integrity policy.

## Linux x86-64

### Build and install current source

Build SynKinect Studio and the Linux runtime, then install the generated distribution:

```bash
bash BUILD.sh
sudo bash drivers/linux/INSTALL.sh --direct
```

For desktop use, `bash drivers/linux/INSTALL.sh` opens the control panel. Its **Install / Reinstall** action runs the native driver build automatically when the compiled distribution is absent or incomplete, and requests `sudo`/`pkexec` only after the build succeeds. The build stage handles build dependencies, Runtime v1.8/UACFirmware acquisition and native compilation. `INSTALL.sh --direct` installs runtime dependencies and consumes only the completed distribution. Use `--no-deps` only when the runtime packages are already installed.

The virtual camera is published by `v4l2loopback` with `exclusive_caps=1`. Remold keeps the V4L2 producer open for the service lifetime, so capture applications can discover the camera even before they open it. No private v4l2loopback client-usage event is required. `/dev/video42` is only a preference: the helper validates the stable label `Kinect Xbox 360 Camera`, avoids occupied nodes, records the selected node in `/run/kinect360-remold/v4l2-device`, and can add a loopback dynamically when another application already owns the module. On Linux 6.18+ the installer requires v4l2loopback 0.15.3 or newer; supported older kernels accept v4l2loopback 0.15.0 or newer.

The Linux Kinect USB backend is `libusb-1.0 >= 1.0.18` in user space over the kernel `usbfs` interface, with udev for access/hot-plug policy. The `045e:02ad` audio bootloader uses libusb-1.0 bulk transfers with embedded UACFirmware. After firmware re-enumeration, `02BB/02C3` microphone capture remains on `snd-usb-audio`/ALSA.

After installation, verify the selected transport model with:

```bash
kinect360-remoldctl backend
```

### Build Debian package

```bash
bash drivers/linux/packages/build-deb.sh amd64
```

The builder compiles the native runtime in a temporary directory and creates a new `.deb` under `drivers/linux/packages/output/`.

### RPM-family distributions

Use `drivers/linux/packages/rpm/kinect360-remold.spec` in the target RPM build environment. The spec compiles the current source during `%build`.

## SynKinect Studio

The editable Processing source is under:

```text
applications/processing/SynKinectStudio/
```

Application launchers are generated during the build and then appear under `applications/binaries/<platform>/`.

The Studio targets Java 17+. On Linux, `bash scripts/linux/BUILD-STUDIO.sh` uses an existing JDK 17+ when available or bootstraps a verified Microsoft OpenJDK 17, then creates a minimal runtime under `applications/binaries/linux-x64/java`. The generated Linux Studio is self-contained and does not require Java to be installed system-wide. The Studio launchers actively prevent an Administrator/root Java process; if invoked from an elevated context they relaunch/drop to the standard desktop user where possible.
