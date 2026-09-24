# Windows generated payload

The Windows source build publishes the runtime only to `binaries/windows/drivers/`.

The generated payload contains PnP packages, resident user-mode bridges, the Media Foundation virtual-camera source/tool, the native IP-camera service, setup utilities and the `KINECT.cmd` control entry point. The SDK contract is published separately to `binaries/windows/sdk/`.

The source ZIP intentionally contains none of those generated native artifacts.
