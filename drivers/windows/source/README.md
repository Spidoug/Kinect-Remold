# Windows native source

This directory contains the Windows driver/runtime source. Build through `drivers/windows/BUILD.cmd` or the repository `Kinect-Xbox-360-Remold.cmd`.

Intermediate outputs and dependency caches are external to the source tree. Final publication is limited to `binaries/windows/drivers/` and `binaries/windows/sdk/`.

The runtime uses stable per-Kinect identity for control, camera, audio, audio-control and virtual-camera routing. The device manifest retains `Booting` and `Reconnecting` entries during transient USB re-enumeration.
