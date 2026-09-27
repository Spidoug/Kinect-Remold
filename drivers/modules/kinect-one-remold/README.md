<div align="center">

# Kinect One Remold

### Independent Kinect v2 transport module for Windows and Linux

[Driver modules](../../README.md) · [Project overview](../../../README.md)

</div>

**by Douglas Santana - @spidoug**


Native Kinect v2 / Kinect for Xbox One transport for Kinect Remold.

The module is self-contained at source level. Windows binds the sensor to `winusb.sys` and talks to it through WinUSB. Linux talks to the sensor through `libusb-1.0`. Device command framing, calibration acquisition, stream endpoint handling, packet assembly, CPU depth reconstruction and Studio IPC are implemented in this repository.

## USB transport

Supported sensor IDs are `045E:02C4` and `045E:02D8`. Kinect v2 image transport requires a SuperSpeed USB 3.x connection.

The native transport uses interface 0 for commands/color and interface 1 for depth/IR. Command OUT is `0x02`, command IN is `0x81`, color IN is `0x83`, and the depth/IR isochronous endpoint is `0x84`. The shared `KinectOneNativeUsb.h` module owns command packet framing, response completion validation, JPEG frame assembly and ten-subframe depth assembly so Windows and Linux use one protocol core.

Per-device subscriptions use the project protocol extension carrying the selected sensor ID. The Xbox 360 runtime continues to use its 16-byte request format.

## Windows

The service uses SetupAPI + WinUSB and publishes SDK/discovery at `\\.\pipe\KinectOneRemoldSdk`. The supplied INF binds only Kinect One/v2 hardware IDs to the project interface GUID. Device IDs are derived from the WinUSB device path instead of enumeration order so multi-sensor selection remains stable across ordinary reconnects.

Depth/IR uses overlapped WinUSB isochronous reads with a queued transfer ring. RGB uses the native bulk endpoint and is published as JPEG payloads for Studio-side decoding.

## Linux

The service uses `libusb-1.0`, udev and publishes SDK/discovery at `/run/kinect-one-remold/sdk.sock`. The udev rule grants direct access to the supported sensor PIDs `02C4`/`02D8`. It detects non-SuperSpeed connections and reports them as `USB3Required` rather than advertising image streaming. Depth/IR uses asynchronous isochronous transfers; RGB uses the bulk endpoint.


## Build and installation

Windows builds the service with CMake and stages the service executable, WinUSB INF, generated catalog, public signing certificate and installer under `binaries/windows/drivers/kinect-one-remold`. The build accepts a code-signing certificate through `KINECT_REMOLD_SIGNING_THUMBPRINT`; when none is supplied, it creates a local development code-signing certificate for the generated package. Installation trusts that package certificate locally, installs the WinUSB package, copies the persistent runtime to `C:\Program Files\Kinect One Remold`, and registers the Windows service only against that installed copy. The source/build repository can therefore be moved or deleted after installation without a running service locking its files. Uninstall stops the service with a bounded shutdown (and forced process release if required), removes the service, matching driver package, package certificate and installed runtime directory.

Linux builds with CMake against `libusb-1.0` and stages the runtime together with its installer, uninstall helper, udev rule and systemd unit under `binaries/linux/drivers/kinect-one-remold`. Installation places the persistent executable at `/usr/libexec/kinect-one-remold/kinect-one-remold`, stores a self-contained maintenance snapshot under `/usr/share/kinect-one-remold/maintenance`, exposes `/usr/bin/kinect-one-remoldctl`, installs the udev rule/systemd unit, reloads device rules and starts the service. The systemd unit never points into the repository. Uninstall uses bounded service shutdown plus a forced process fallback before removing installed files.

Generated files under `binaries/` are build outputs and are not part of the source tree.

## Depth / IR processing

`KinectOneDepthEngine.h` is the project CPU reconstruction library. It loads the sensor's depth intrinsics and phase tables, builds distortion/geometry tables, decodes packed 11-bit measurements, performs three-frequency phase correlation and phase unwrapping, applies metric correction and an edge-aware cleanup pass, then emits 512x424 `DepthMm16` and 16-bit infrared frames.

The implementation does not require a third-party Kinect runtime at execution time. Windows needs the Windows SDK/WinUSB development interfaces to build; Linux needs the `libusb-1.0` development package.

## Runtime interface and Studio integration

A camera session is advertised as Ready only after USB 3.x validation, command-channel probing, depth/P0/color calibration reads and the sensor-ready status handshake complete. The runtime can publish native 1920x1080 JPEG color, 512x424 metric depth and 512x424 16-bit infrared concurrently. The existing Studio IPC endpoint and binary structure sizes remain unchanged; Kinect One uses the existing calibration fields to carry native depth `fx`, `fy`, `cx` and `cy` so Studio deprojection, ICP and Body3D use sensor geometry instead of Xbox 360 defaults.

The Studio-side Body3D tracker consumes synchronized depth plus infrared when available. Color remains available concurrently for preview, surface-color accumulation and reconstruction. For Remold, the Kinect v2 module is considered complete for its sensor-imaging role: RGB, metric depth, infrared, native calibration/registration data and synchronized Studio acquisition are implemented. Kinect v1-only tilt/LED controls do not exist on this generation. Raw microphone capture is a standard USB-audio concern rather than part of the v2 image transport; the module does not advertise a private Remold microphone endpoint or calibrated directional-audio feature.
