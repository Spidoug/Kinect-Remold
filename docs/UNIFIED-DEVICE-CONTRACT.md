<div align="center">

# Unified Kinect device contract

### One Studio behavior across supported Kinect models and operating systems

[Documentation](README.md) · [Compatibility matrix](KINECT-COMPATIBILITY-MATRIX.md) · [Architecture](ARCHITECTURE.md)

</div>

Kinect Remold normalizes model- and operating-system-specific transports into one capability-driven contract. Native USB details may differ, but a capability has the same meaning to SynKinect Studio regardless of whether it came from Windows or Linux, Kinect 1414, 1473, 1517, or Kinect v2.

## Common user contract

Every discovered sensor has one stable `deviceId`, one state model and one advertised capability set. The Studio never enables a control because of a model name alone. A control is shown and enabled only when the selected device publishes the corresponding capability and the required transport is operational.

`READY` is operational, not merely installed. For a capability to be READY, the runtime must be able to use the physical path that backs the Studio operation. A present USB PID, running service, existing socket/pipe or STARTED WinUSB node is not sufficient by itself.

The common capability vocabulary is:

| Capability | User-visible meaning |
|---|---|
| `color` | RGB/image stream is usable |
| `depth` | metric depth path is usable |
| `infrared` | IR stream is usable |
| `audio` | raw four-channel Remold microphone stream is usable |
| `audio-control` | per-device volume/mute control is usable |
| `manual-tilt` | physical tilt can be commanded |
| `startup-tilt` | persistent startup tilt is supported |
| `rgb-hq` | high-quality RGB profile is supported |
| `ip-stream` | optional authenticated IP/MJPEG runtime is available |
| `body-tracking` | Studio SynSkeleton body tracking is supported |
| `sdk` | device-scoped Remold SDK endpoint is usable |

The exact native transport remains private to the driver module. LED and accelerometer are part of the first-generation physical control contract behind the `control` endpoint; operating-system image output is reported by the dedicated `virtual-camera` endpoint column rather than inferred from the generation.

## First-generation parity: 1414, 1473 and 1517

The three first-generation models are intentionally presented as one functional family. When healthy, they expose the same Studio-level operating conditions:

- RGB, depth and infrared capture;
- metric depth calibration;
- manual tilt, startup tilt, LED and accelerometer status;
- four-channel 16 kHz raw microphone transport and audio control;
- 3D Scanner, Acoustic Scanner, Microphones, Surveillance, Interactivity and Motion Capture;
- system image output, RGB HQ, optional IP camera and multi-Kinect routing.

Their native control and audio paths differ, but those differences are not exposed as different Studio workflows:

| Model | Native control path | Native audio path |
|---|---|---|
| 1414 | dedicated `045E:02B0` classic control | `02AD` firmware transition, then `02BB/02C3` USB Audio runtime |
| 1473 | `02BB/02C3 MI_00` alternate bulk control | `02BB/02C3 MI_02` USB Audio runtime |
| 1517 | revision-scoped `045E:02C2 REV_0100` classic control | factory `045E:02BE` USB Audio runtime |

Windows and Linux normalize these paths to the same Remold control, Scanner and audio protocols; field layouts are in the [driver wire-protocol reference](ARCHITECTURE.md#driver-wire-protocol-reference).

## Kinect v2 parity boundary

Kinect v2 uses the same Studio shell, device identity rules, RGB-D/IR synchronization, metric depth contract, Scanner, Surveillance, Interactivity, Motion Capture and Sensor Calibration workflows. Its hardware does not provide the v1 motor/LED mechanism, so tilt/LED controls are not shown. The current Remold v2 runtime also does not advertise a four-channel audio endpoint; therefore Microphones and Acoustic Scanner remain unavailable for v2 until that native backend exists.

This is a hardware/backend capability boundary, not a separate UI philosophy. If a future v2 runtime advertises another common capability, the Studio can expose it without adding generation-specific Home logic.

## Platform parity

Windows and Linux use different operating-system transports but publish the same semantics:

| Layer | Windows | Linux | Studio contract |
|---|---|---|---|
| control | WinUSB + named pipe | libusb + Unix socket | same binary control ABI and SDK `CONTROL` text commands |
| RGB-D/IR | WinUSB + local IPC | libusb + local IPC | same frame/stream semantics |
| Xbox 360 audio | USB Audio + shared WASAPI | `snd-usb-audio` / ALSA + KinectRemold ALSA capture endpoint | 4ch, 16 kHz, S32LE Remold ABI (anti-aliased resampling) |
| system camera (Xbox 360 module) | Media Foundation / local MJPEG fallback | V4L2/v4l2loopback | one image output per first-generation device |
| Kinect One/v2 OS camera | not currently advertised | not currently advertised | Studio/SDK imaging only |
| services | Windows SCM | systemd | installed runtime independent of repository |

## Studio/runtime parity

SynKinect Studio applies one lifecycle policy above the native drivers. Windows named pipes and Linux Unix-domain sockets use the same connection retry count, retry interval and read/write timeout budget. Device discovery is performed independently for each installed driver module so an unavailable generation does not delay another generation. A Kinect that briefly disappears keeps its Studio identity during the common reconnect grace period; modules receive the same device/selection context events on both operating systems.

The Studio consumes generic runtime counters and semantic states. For example, microphone diagnostics use `transport_packets`, `published_frames`, `runtime_sessions`, `stream_sample_rate`, `capture_channels` and `stage`. Likewise, third-party Studio modules receive the runtime `state` and can use `StudioDeviceInfo.ready()` rather than inferring health from the host operating system.

The following differences remain intentionally native and are not functional differences: Windows uses named pipes/SCM/native Shell dialogs, Linux uses Unix sockets/systemd and the available desktop file chooser; font-family selection follows fonts installed on each desktop. Hardware-generation differences remain capability-driven.

## UI rule

Home system controls are generated from capabilities/endpoints, not generation names. `Sensor Calibration`, `Tilt`, `Startup tilt`, `RGB HQ` and IP-camera actions appear only when the selected device advertises the capability needed by that action. `Open camera` appears only when the device exposes an actual operating-system image output or the supported IP-image path; a transport readiness probe is never presented as a user camera action. This is the normative behavior for future Kinect modules as well.
