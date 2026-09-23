# Linux UAC firmware input

Kinect Xbox 360 Remold uses Microsoft Kinect Runtime 1.8 **UACFirmware 01.02.709.00** for models 1414 and 1473.

The firmware blob is not committed or redistributed. A normal Linux build downloads the official Microsoft Kinect Runtime v1.8 installer into the user cache, verifies the pinned Runtime SHA-256, extracts the firmware locally, verifies the pinned firmware SHA-256, and places the validated image only in the generated `binaries/linux/drivers` runtime.

For an offline build, set `KINECT_UAC_FIRMWARE=/path/to/UACFirmware` to the exact validated raw image before starting the build.

After launch, Linux waits for the kernel USB Audio/ALSA capture device and keeps the per-Kinect logical audio endpoint stable while that PCM appears or reconnects. The firmware owns its USB descriptor timing; Remold consumes the working four-channel, 16 kHz, S32_LE ALSA capture endpoint without rewriting descriptor timing.
