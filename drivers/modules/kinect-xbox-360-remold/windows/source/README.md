# Windows native source

This directory contains the Windows driver/runtime source. Build through `drivers/modules/kinect-xbox-360-remold/windows/BUILD.cmd` or the repository `Kinect-Remold.cmd`.

Intermediate outputs and dependency caches are external to the source tree. Final publication is limited to `binaries/windows/drivers/kinect-xbox-360-remold/` and `binaries/windows/sdk/kinect-xbox-360-remold/`.

The runtime uses stable per-Kinect identity for control, camera, audio, audio-control and virtual-camera routing. The device manifest retains `Booting` and `Reconnecting` entries during transient USB re-enumeration.


Windows image output is capability-selected at install time. Windows 11 build 22000 or newer uses the native Media Foundation virtual-camera API. Windows 10 build 19041 or newer uses the loopback-only MJPEG runtime automatically; CameraBridge and ScannerPort remain identical on both paths.
