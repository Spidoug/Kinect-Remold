# Windows UAC audio runtime — V1

The Windows V1 audio path uses Microsoft UACFirmware **01.02.709.00** from Kinect for Windows Runtime v1.8 for the Kinect NUI Audio boot function. The same firmware image is used for models 1414 and 1473.

```text
USB\VID_045E&PID_02AD
  ↓ Microsoft WinUSB
Kinect360RemoldAudioBridge
  ↓ UACFirmware upload
USB re-enumeration
  ↓
USB\VID_045E&PID_02BB&MI_02  OR  USB\VID_045E&PID_02C3&MI_02
  ↓ Microsoft inbox USB Audio
WASAPI capture
  ↓
Remold four-channel application fan-out
```

The build obtains the pinned UACFirmware image, validates it and embeds it into `Kinect360RemoldAudioBridge.exe`. The bridge uploads the raw image through boot bulk endpoints `0x01/0x81`, starts it at the Kinect UAC entry point, then waits for the USB Audio runtime identity.

For Windows, the builder validates the complete extracted image against its pinned SHA-256. The host expects the Kinect microphone data path on Audio ISO IN `0x82` with the four-channel, 16 kHz, 32-bit application audio format. The firmware itself owns the USB descriptor timing, including `bInterval`; Remold does not fabricate or overwrite that field. No executable firmware byte or independent `02AE` RGB/IR/Depth camera descriptor is modified.

The raw `02AD` audio transport seen before firmware launch is only the boot state. After re-enumeration, `MI_02` stays on the Microsoft inbox USB Audio stack. The 1473 keeps its own `MI_00` motor/LED/accelerometer control topology, while Windows owns the microphone endpoint exactly as it does for a normal capture device.

At runtime AudioBridge discovers the Kinect capture endpoint through MMDevice/WASAPI and opens the endpoint **only in shared mode** using the Windows mix format. It never falls back to exclusive ownership. This keeps the Windows Sound input meter, endpoint volume control and other recording applications live while Remold is running. If Windows exposes fewer than four channels in its shared mix, the Remold application bus publishes only the channels actually supplied by Windows and marks the remaining channels invalid instead of taking the device exclusively.

Install/Reinstall installs AudioBridge as a persistent delayed-auto product service from `%ProgramFiles%`, independently of whether the RAM-resident firmware currently exposes `02AD` or has already re-enumerated to the `02BB/02C3` UAC family. Setup treats `02BB&MI_02` or `02C3&MI_02` presence plus a running AudioBridge service as transport readiness. Capture quality is a runtime concern: `audio-bridge-status.txt` reports the actual mode, channel count, sample rate and published-frame counters, and Studio surfaces subscription/capture errors to the user.

Capture policy is deliberately Windows-native and non-exclusive:

1. keep `02BB/02C3&MI_02` on the Microsoft USB Audio class driver;
2. query the endpoint's current Windows shared mix format;
3. open event-driven WASAPI in `AUDCLNT_SHAREMODE_SHARED` only;
4. preserve every real channel Windows supplies, zero-fill absent application channels and publish a validity mask;
5. resample all supplied channels with one phase accumulator when the shared mix runs above 16 kHz.

`audio-bridge-status.txt` exposes `capture_mode`, channel count, sample rate, WASAPI packet counters and `published_frames`. These counters are the authoritative runtime evidence for microphone capture after installation.

The V1 audio path does not require a Remold-authored kernel audio `.sys`.
