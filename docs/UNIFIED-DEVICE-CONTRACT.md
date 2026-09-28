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
| `body-tracking` | Studio Body3D path is supported |
| `sdk` | device-scoped Remold SDK endpoint is usable |

The exact native transport remains private to the driver module. LED and accelerometer are part of the first-generation physical control contract behind the `control` endpoint; operating-system image output is reported by the dedicated `virtual-camera` endpoint column rather than inferred from the generation.

## First-generation parity: 1414, 1473 and 1517

The three first-generation models are intentionally presented as one functional family. When healthy, they expose the same Studio-level operating conditions:

- RGB, depth and infrared capture;
- metric depth calibration;
- manual tilt, startup tilt, LED and accelerometer status;
- four-channel 16 kHz raw microphone transport and audio control;
- 3D Scanner, Acoustic Scanner, Microphones, Surveillance and Interactivity;
- system image output, RGB HQ, optional IP camera and multi-Kinect routing.

Their native control and audio paths differ, but those differences are not exposed as different Studio workflows:

| Model | Native control path | Native audio path |
|---|---|---|
| 1414 | dedicated `045E:02B0` classic control | `02AD` firmware transition, then native four-microphone runtime |
| 1473 | `02BB/02C3 MI_00` alternate bulk control | `02BB/02C3 MI_02` USB Audio runtime |
| 1517 | revision-scoped `045E:02C2 REV_0100` classic control | factory `045E:02BE` USB Audio runtime |

Windows and Linux normalize these paths to the same Remold control, Scanner and audio protocols.

## Kinect v2 parity boundary

Kinect v2 uses the same Studio shell, device identity rules, RGB-D/IR synchronization, metric depth contract, Scanner, Surveillance, Interactivity and Sensor Calibration workflows. Its hardware does not provide the v1 motor/LED mechanism, so tilt/LED controls are not shown. The current Remold v2 runtime also does not advertise a four-channel audio endpoint; therefore Microphones and Acoustic Scanner remain unavailable for v2 until that native backend exists.

This is a hardware/backend capability boundary, not a separate UI philosophy. If a future v2 runtime advertises another common capability, the Studio can expose it without adding generation-specific Home logic.

## Platform parity

Windows and Linux use different operating-system transports but publish the same semantics:

| Layer | Windows | Linux | Studio contract |
|---|---|---|---|
| control | WinUSB + named pipe | libusb + Unix socket | same control commands/status semantics |
| RGB-D/IR | WinUSB + local IPC | libusb + local IPC | same frame/stream semantics |
| v1 audio | WASAPI or native Kinect USB path | ALSA or native Kinect USB path | 4ch, 16 kHz, S32LE Remold ABI |
| system camera | Media Foundation / local MJPEG fallback | V4L2/v4l2loopback | one image output per device |
| services | Windows SCM | systemd | installed runtime independent of repository |

## UI rule

Home system controls are generated from capabilities/endpoints, not generation names. `Sensor Calibration`, `Tilt`, `Startup tilt`, `RGB HQ` and IP-camera actions appear only when the selected device advertises the capability needed by that action. `Open camera` appears only when the device exposes an actual operating-system image output or the supported IP-image path; a transport readiness probe is never presented as a user camera action. This is the normative behavior for future Kinect modules as well.
