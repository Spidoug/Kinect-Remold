# Kinect 1414 transport notes

Kinect Remold treats the Kinect Xbox 360 model 1414 as three independent runtime transports.

- Camera: `045E:02AE`, raw RGB/depth through the Scanner ABI.
- Motor/control: `045E:02B0`, classic USB control requests for tilt, LED and accelerometer.
- Microphones: `045E:02AD` boot firmware followed by the runtime audio function. After the UAC firmware upload the function re-enumerates as `02BB/02C3`; Windows captures it with WASAPI and Linux with `snd-usb-audio` / ALSA. Both resample the native rate to the common four-channel 16 kHz S32LE Remold ABI through an anti-alias FIR.

Windows uses WinUSB for the 1414 motor/control function. The broker first opens the Remold control interface GUID and, if Windows has not published that GUID yet even though the function is STARTED, it can open the exact `045E:02B0` devnode through the system USB-device interface and initialize WinUSB on that same device. This fallback is hardware-ID scoped and is never used to claim the 1473 `02C2` parent hub.

A runtime component is reported READY only after the transport used by SynKinect Studio responds successfully. PnP presence, a socket/pipe path, or a running service alone is not sufficient.
