# Linux V1 firmware policy

The build uses Microsoft **UACFirmware 01.02.709.00** extracted from the pinned runtime package.

Firmware acquisition happens during **driver compilation**, not during first install or first device connection. The Linux build downloads the pinned Microsoft Kinect for Windows Runtime v1.8 (`1.8.0.595`), validates the Runtime SHA-256, extracts `UACFirmware`, validates the firmware SHA-256, and generates a C/C++ header that is compiled into `kinect360-remold-audio`.

Pinned identities:

- Runtime SHA-256: `f4d4143fb0f0a8d276889c077bfc8af42bfe99c128cadab5e316bf015a9858e9`
- UACFirmware version: `01.02.709.00`
- UACFirmware SHA-256: `4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9`
- Load address: `0x00080000`
- Entry address: `0x00080030`

The firmware binary itself is not stored in the project ZIP. It is downloaded from Microsoft's official Runtime package into the local Linux build cache and embedded in the locally compiled audio bridge, matching the Windows build policy.
