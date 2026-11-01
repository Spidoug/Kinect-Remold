<div align="center">

# Functionality status

### Source-audited behavior, capability boundaries and physical-validation requirements

[Documentation](README.md) · [Compatibility matrix](KINECT-COMPATIBILITY-MATRIX.md) · [Unified device contract](UNIFIED-DEVICE-CONTRACT.md) · [Studio behavior](STUDIO-MODULE-BEHAVIOR.md)

</div>

This document records what the current source tree actually implements. It deliberately distinguishes a complete code path from a physically validated Kinect result. A service, socket or USB node existing is not by itself evidence that a capability works; runtime status is expected to report **READY** only after the underlying data path is usable.

## Verification boundaries

Automated numerical verification has exercised the production `QuaternionFit` and `RigidTransform` implementation with a minimal `PVector` adapter, without replacing the fitting algorithm. All 80 exact rigid-alignment cases and all 80 cases with independent Gaussian coordinate noise (standard deviation 2 mm) passed the synthetic checks. Example root-mean-square residuals were approximately 0.00005–0.00007 mm without noise and 3.28–3.71 mm with noise. These are examples, **not aggregate accuracy statistics** and **not reconstructed-mesh accuracy**.

Five synthetic angular-coverage scenarios for Turntable passed, as did nine Python audio/tracking-configuration tests. Shell and Python syntax checks passed in the tested environment. These results do not validate the entire Scanner reconstruction pipeline, ICP correspondence selection and convergence, TSDF fusion, mesh accuracy, acoustic direction finding, Surveillance, or ONNX model execution.

End-to-end Processing/JOGL execution and full Windows/Linux Studio builds were not demonstrated in this validation environment. The distribution does not bundle ONNX weights. Device-level capture, physical accuracy and platform parity require connected hardware and complete runtime dependencies. Treat implementation descriptions in this document as **source capabilities**, not as proof of production-grade physical performance.

## Runtime and driver modules

| Area | Current implementation | Functional boundary |
|---|---|---|
| Xbox 360 camera / depth / IR | Native first-generation transport for 1414, 1473 and 1517 on Windows and Linux, per-device identity and reconnect handling. Lost USB packets in a depth frame are filled with the 11-bit "no reading" code 2047 and flagged `recovered` (frame flag bit 0) on both systems; IR requests take priority over RGB on both systems | Requires physical validation on the target model/host after driver changes |
| Xbox 360 tilt / LED / accelerometer | Model-specific control backend normalized to one Studio contract; status replies set `0x40000000` when the accelerometer is valid but the tilt angle is unknown (1414 moving); `Ping` is answered during a tilt; a committed tilt is not re-sent on a late ACK | Available only on hardware that advertises the capability. The Linux 1414 path still retries a tilt once with a fresh handle when verification fails |
| Xbox 360 SDK endpoint | `LIST` / `GET` / `INDEX` plus `CONTROL\t<id>\t<action>` (`Status`, `OpenCamera`, `LedOff`/`LedGreen`/`LedRed`/`LedBlink`) with the same replies on Windows and Linux; see [SDK protocol](ARCHITECTURE.md#driver-module-sdk-protocol) | Tilt stays on the binary control ABI |
| Xbox 360 raw audio | Four-channel 16 kHz Remold stream. Windows captures through USB Audio + WASAPI; Linux captures 1414, 1473 and 1517 through `snd-usb-audio` / ALSA and republishes through the `KinectRemold` ALSA endpoint. 48 → 16 kHz uses an anti-alias FIR on both systems | Linux installation/status is strict: `PENDING` is not success; frames, a recent packet and system-audio publication must all be flowing |
| Xbox 360 OS camera | Windows 11 Media Foundation / Windows 10 local MJPEG image output; Linux V4L2/v4l2loopback | First-generation driver feature only |
| Local IPC | Bounded per-client timeouts on every Broker, CameraBridge and AudioBridge endpoint on both systems | A stalled client is dropped rather than blocking the service |
| Kinect One / v2 RGB-D-IR | Native v2 imaging transport, native calibration metadata and Studio/SDK stream path on Windows and Linux; SDK supports `LIST`, `GET` and `CONTROL`; an opt-in extended stream reply carries factory depth distortion and colour intrinsics | Current module does not advertise Remold audio, v1 tilt/LED or an OS virtual camera; no `INDEX` command |
| IP camera | Optional authenticated MJPEG runtime, disabled or loopback-only by default according to platform policy. `/snapshot.jpg` waits briefly for a fresh frame instead of returning a stale cached JPEG | Not a substitute for a missing physical camera transport |

### Linux audio readiness

For a connected first-generation Kinect, installation is considered successful only when the audio status reports an active capture (`uac-runtime-capturing`), at least four capture channels, a 16 kHz Remold stream, increasing published frames, a recent frame age, and active system-audio publication with packets. A resident AudioBridge with zero frames remains **PENDING** and causes install/status verification to fail instead of being reported as operational.

## SynKinect Studio modules

| Module | Source-audited behavior | Important limitation / validation |
|---|---|---|
| 3D Scanner — Turntable | Fixed-sensor rotating-object capture with support-plane removal, Depth-locked foreground, lightweight temporal ICP, tracking-driven angular coverage/keyframes, offline Build Mesh and FULL QUALITY Refine HQ | Capture no longer performs dense fusion; final reconstruction quality still depends on actual depth quality, object surface and scan motion |
| 3D Scanner — Kinect Fusion | Moving-sensor SE(3) capture with foreground Depth lock, lightweight temporal ICP, keyframe/trajectory retention and viewpoint-diversity progress; Build Mesh / Refine HQ perform dense reconstruction offline | Realtime capture prioritizes responsiveness; offline registration still requires sufficient geometric overlap between retained views |
| Acoustic Scanner | Four-channel localization, VAD, beam steering/beamforming, adaptive noise suppression and output-only voice enhancement | Enabled only when the selected device exposes healthy raw audio; v2 support requires an independently available four-channel OS audio input and an explicitly started service; v2 acoustic localization is not calibrated or validated |
| Microphones | Four raw channels, meters, recording, monitor/playback and runtime audio diagnostics | Raw recording is intentionally not modified by output DSP; depends on healthy audio capability |
| Surveillance | Multi-device RGB/IR monitoring, low-light hysteresis, armed-background warmup, coherent-motion confirmation, pre-event buffering and event recording | Does not request depth; motion sensitivity still depends on scene lighting, camera vibration and physical validation |
| Interactivity | SynSkeleton ONNX body/hand/finger tracking through the shared `BodyTrackingSession`, per-hand interaction zones scaled by arm length, push-to-click with click lock, second-hand right click / double click / scroll and two-hand air keyboard | Tracking quality depends on the installed `SynSkeleton.onnx`; desktop injection needs a desktop that allows `java.awt.Robot` |
| Motion Capture | Built-in module `mocap`: same body-tracking block, Unity-humanoid retargeting, VMC (OSC/UDP 39539), plain OSC, JSON over UDP, WebSocket (39540) and BVH recording | Single person; no head/face, clavicle or finger bones; streams are unauthenticated; receiver integrations (VSeeFace, EVMC4U, VMC4B, VMC4UE) still need validation with real hardware |
| Sensor Calibration (upgraded) | Flat-wall capture at several distances, inverse-depth plane fits, distance-aware residual grid (`DepthCorrectionSolver`, profile v3), optional tape reference for absolute scale, leave-one-station-out validation, explicit save/reset | Without a tape reference, global scale is not observable; calibration does not fix occlusion, reflective surfaces or motion blur. Legacy v2 (per-pixel affine) profiles still load. Accuracy figures come from the synthetic benchmark only; the v3 model is not yet validated on physical Kinects |

## SynSkeleton / body tracking

`SynSkeleton.onnx` is the single pose authority for the Studio. Metric Depth is normalized into the model input; its 58 current-frame landmarks are mapped through the active Kinect calibration into camera-space XYZ. Body anchors required by the Remold API (shoulder center, spine, hip center, body-hand/palm and feet) are derived only from currently observed model landmarks.

There is no alternate geometric or articulated pose fallback. If the model is missing, cannot be loaded, fails inference or does not observe a hand, that pose/hand is not published. The body-cloud view uses depth points selected around the neural skeleton and cannot replace the neural pose.

Windows and Linux builds package Microsoft ONNX Runtime Java; the model itself must be present at `data/skeleton/SynSkeleton.onnx`.

## External module API

The external Java module API is the current single contract. External modules run in-process, receive capability/state snapshots and lifecycle events, can open the host body tracker through `StudioModuleContext.bodyTracking(deviceId)` (default method, API version 1), and must target the current API metadata value. No compatibility shim for removed legacy NUI/skeleton endpoints or backend-specific audio counters is retained.

## Not yet hardware-validated

The following recent changes are source-complete and covered by headless harnesses or static checks, but have not been validated end-to-end on physical Kinects: the SDK `CONTROL` command, the frame `recovered` flag, the tilt-unknown status flag and committed-tilt rule, the anti-aliased 48 → 16 kHz decimation, ALSA capture for 1414/1473 on Linux, Linux IR-over-RGB priority, the fresh-frame `/snapshot.jpg`, the Kinect One extended calibration reply, the v3 depth calibration, SynSkeleton ONNX tracking on each physical Kinect/model combination and Motion Capture with real receivers.

## Verification meaning

Production validation requires an installed Processing runtime and representative Kinect hardware; synthetic unit checks alone do not establish end-to-end operation.

The repository can be checked statically for source consistency, localization parity, shell syntax, documentation links, configuration duplicates and Java interface compilation. Those checks catch packaging and code-contract defects, but they do not replace physical tests. For a hardware-facing release, validate at minimum: enumerate → open → stream → stop → disconnect → reconnect on each supported physical model and on both operating systems, then exercise every capability that the selected device advertises.
