# Kinect 360 Remold native SDK bridge

`drivers/sdk/` provides the C/C++ host interface used by native applications and emulator adapters.

The API exposes Kinect v1/NUI-style sensor discovery, initialization, tilt, accelerometer, RGB/Depth/IR endpoint discovery, NUI20 skeleton access and microphone volume/mute control. Windows uses Remold named pipes; Linux uses Remold Unix-domain sockets.

Build:

```bash
cmake -S drivers/sdk -B build/sdk
cmake --build build/sdk
```

The public header is `include/remold_sdk_bridge.h` and the static library target is `kinect360-remold-sdk-bridge`.
