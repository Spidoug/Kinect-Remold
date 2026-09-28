<div align="center">

# Kinect Compatibility Matrix

### Capability routing and safety rules by generation and model

[Documentation](README.md) · [Unified device contract](UNIFIED-DEVICE-CONTRACT.md) · [Architecture](ARCHITECTURE.md) · [Motion](MOTION.md)

</div>

This file is normative for device identification. A USB PID alone is never enough when that PID can be a hub, adapter, boot function, or a topology-dependent control function.

| Family / model | Safe identity | Camera/depth/IR | Motion / LED / accel | Audio | Remold policy |
|---|---|---|---|---|---|
| Kinect for Xbox 360 1414 | camera 045E:02AE + bcdDevice 010B; control 02B0 in same physical topology | native v1 backend | 02B0 classic control | 02AD boot -> runtime audio topology | supported |
| Kinect for Xbox 360 1473 | camera 045E:02AE with non-010B bcdDevice; 02C2 is topology/hub, not a 1517 proof | native v1 backend | runtime audio-control MI_00 after firmware | 02AD -> 02BB/02C3 family | supported; never classify from 02C2 alone |
| Kinect for Windows v1 1517 | camera 045E:02BF; dedicated control 045E:02C2 REV_0100; audio 045E:02BE | native v1 backend | dedicated 02C2 classic control, revision-scoped on Windows | factory 02BE USB Audio through ALSA/WASAPI | supported |
| Kinect v2 / Kinect for Xbox One | sensor 045E:02C4 or 045E:02D8 | native v2 backend, USB 3 required; RGB/depth/IR + native calibration | no v1 tilt/LED hardware capability | standard USB-audio path is outside the private image transport; no directional-audio claim | supported; complete Remold v2 sensor-imaging pipeline |


## Common operating profile

Models 1414, 1473 and 1517 are normalized to the same first-generation Studio profile when their transports are healthy: RGB + depth + IR, four-channel 16 kHz raw audio, audio control, manual/startup tilt, LED, accelerometer, RGB HQ, Scanner, Surveillance, Interactivity, Microphones, Acoustic Scanner and Sensor Calibration. Model-specific USB topology must never change the user-level semantics of those capabilities.

Kinect v2 follows the same imaging profile where hardware/runtime capabilities overlap. It does not expose v1 tilt/LED controls and the current Remold v2 module does not advertise audio.

## Capability rule

The Studio must consume capabilities emitted by the concrete runtime device. It must not infer `audio`, `manual-tilt`, `rgb-hq`, `infrared`, `ip-stream`, or other controls solely from a generation name. Missing capabilities disable the corresponding UI.

## Safety rule

Unknown hardware, incomplete enumeration, and ambiguous topologies fail closed. Remold does not probe a 1414 motor protocol and then fall through to a 1473 protocol merely because a camera is temporarily absent. This avoids sending vendor commands to the wrong USB function during re-enumeration.