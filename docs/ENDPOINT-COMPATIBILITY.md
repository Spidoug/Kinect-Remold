# Kinect Xbox 360 Remold V1 endpoint compatibility

The runtime uses the Kinect device identities, USB endpoints and stream semantics listed below.

| Function | Identity / interface | Endpoint / ownership |
| --- | --- | --- |
| 1414 control / motor | `045E:02B0` | Remold control transport |
| 1473 parent | `045E:02C2` | Remains on the operating-system hub stack |
| RGB / IR camera | `045E:02AE` | ISO IN `0x81`; RGB and IR are mutually exclusive |
| Depth camera | `045E:02AE` | ISO IN `0x82`; may run with RGB or IR |
| Audio firmware boot | `045E:02AD` | Bulk OUT `0x01`, Bulk IN `0x81` |
| 1473 runtime control | `02BB/02C3 MI_00` | Remold control only |
| Runtime microphone capture | `02BB/02C3 MI_02` | USB Audio; capture ISO IN `0x82` |

RGB HQ uses the camera RGB/IR engine (`0x81`) and requests the Kinect v1 1280x1024 Bayer mode. It is disabled by default and can be enabled from the Kinect control panel or the Studio system settings. The virtual camera and derived RGB services consume the selected source policy.

## Games and NUI compatibility

Matching USB endpoints is necessary for the Remold hardware drivers, but it is not sufficient to make arbitrary Xbox 360 or Kinect-for-Windows games use the sensor. Xbox 360 console titles expect the console's own Kinect USB/runtime stack. Windows Kinect applications commonly target Microsoft's Kinect runtime/NUI API. Remold exposes an adapter-facing NUI20 semantic ABI and canonical 20-joint topology, but does not claim binary impersonation of Microsoft's proprietary runtime. A game-specific adapter can consume Remold streams; direct console compatibility would require a separate USB-device/runtime emulation project.
