# Platform runtime mapping

Kinect Xbox 360 Remold supports Xbox 360 Kinect models **1414** and **1473** with the same device identities, command ordering, camera modes, audio firmware and application-visible behavior on both operating systems.

The operating-system transport layer differs:

- **Windows:** WinUSB for Kinect vendor USB functions; Windows USB Audio + WASAPI after UAC firmware startup; Media Foundation for the system virtual camera.
- **Linux:** libusb-1.0 over usbfs/udev for Kinect vendor USB functions; snd-usb-audio + ALSA after UAC firmware startup; V4L2 loopback for the system virtual camera.

| Function | Windows | Linux | Kinect behavior |
| --- | --- | --- | --- |
| 1414 motor / tilt / LED / accelerometer | WinUSB `045E:02B0` | libusb-1.0 `045E:02B0` | same commands and state |
| 1473 topology | `045E:02C2` parent + runtime control | same USB topology through Linux USB core/libusb | same model decision |
| RGB / RGB-HQ / IR / Depth | WinUSB `045E:02AE` | libusb-1.0 `045E:02AE` | `0x81` RGB/IR/HQ, `0x82` Depth |
| Audio startup | WinUSB `045E:02AD` | libusb-1.0 `045E:02AD` | Bulk OUT `0x01`, Bulk IN `0x81` |
| Audio firmware | UACFirmware 01.02.709.00 | UACFirmware 01.02.709.00 | same firmware image |
| Runtime microphones | USB Audio + WASAPI | USB Audio + ALSA | 4-channel 16 kHz 32-bit capture |
| 1473 runtime control | `02BB/02C3 MI_00` | corresponding control interface | same logical controls |
| System camera | Media Foundation | V4L2 loopback | RGB camera presentation |

RGB, IR and RGB-HQ share camera endpoint `0x81` and are arbitrated as `IR > HQ > RGB`. Depth uses `0x82` independently. The operating-system RGB camera remains subscribed and resumes when IR/HQ releases `0x81`.

The Linux V4L2 producer stays connected for the service lifetime. The device is identified by the label `Kinect Xbox 360 Camera`; `/dev/video42` is only a preferred number and another free `/dev/videoN` is used when necessary.
