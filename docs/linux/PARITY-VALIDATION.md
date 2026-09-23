# Linux / Windows parity validation

Audit date: 2026-09-23.

The Windows runtime remains the behavioural reference for Kinect 1414/1473 USB sequencing. The Linux implementation is intentionally independent (libusb/ALSA/V4L2) but follows the same firmware state transitions and public transport contracts.

## Checks completed in the audit environment

- every Linux shell script passes `bash -n`;
- dependency-independent Linux C++ sources (`remoldctl`, SDK, Scanner/camera server and IP camera) pass C++17 syntax checks with `-Wall -Wextra -Wpedantic -Wconversion -Wshadow`;
- a clean CMake build with `REMOLD_BUILD_HARDWARE=OFF` succeeds;
- configuration parsing regression tests reject partially parsed integers, NaN/Inf doubles and invalid boolean text while preserving configured fallbacks;
- the Studio Module SDK compiles with `javac -Xlint:all -Werror` using a minimal `processing.core.PApplet` API stub;
- Linux `smart_tilt.hpp` and Windows `Kinect360RemoldSmartTilt.h` are byte-identical;
- the Linux installer contains no package-manager or downloader command and verifies the kernel release, v4l2loopback version/source hash/module hash, firmware hash and runtime library resolution before replacing the installed runtime;
- no generated object, JAR, kernel module, DLL/EXE, temporary or backup artifact is retained in the source tree;
- the Linux RGB/IR sequence matches Windows: stop/configure firmware, arm ISO 0x81, then start the stream through register 0x05;
- the Linux depth sequence matches Windows: stop/configure the depth firmware path, arm ISO 0x82, then enable the projector/depth engine through register 0x06;
- the Linux 1473 audio firmware probe uses the same tolerant version-response rule and 10 s control timeout as the working Windows path.

## Environment limitations

This audit container has no physical Kinect and does not contain the native libusb, ALSA or OpenCV development headers required for the complete hardware-enabled Linux build. It also has no MSVC/WDK/PowerShell Windows build environment and no complete Processing/JOGL runtime dependency cache. Therefore this document does **not** claim a physical 1414/1473 hardware pass, a complete Studio package build, or a Windows native package build in this container.

Those remaining checks are target-machine acceptance tests, not substitutes for the static/source checks above.

## Target Linux acceptance

After a full build on the target machine, run:

```bash
bash Kinect-Xbox-360-Remold.sh --rebuild
sudo binaries/linux/drivers/INSTALL.sh
bash drivers/linux/DIAGNOSE.sh
```

For the strict offline-install test, disconnect networking after the build and before `INSTALL.sh`. The installation must complete without network or package-manager activity.

Validate at minimum:

1. Kinect 1473: RGB, IR/depth, four-channel audio, motor/LED/control, Studio and V4L2 virtual camera.
2. Kinect 1414: RGB, IR/depth, motor/control, Studio and V4L2 virtual camera.
3. Multi-Kinect: independent device IDs, ScannerPort/audio endpoints and virtual-camera slots.
4. Uninstall while Studio is open: `/run/kinect360-remold/devices.tsv` disappears and Studio removes Linux devices immediately; `gspca_kinect` is restored when available.
5. Reboot: services, udev rules, virtual camera and model-specific USB ownership return without a rebuild or download.

If Secure Boot enforces unsigned external modules, the kernel may reject the bundled `v4l2loopback.ko`; the installer now reports this explicitly rather than attempting an online fallback.
