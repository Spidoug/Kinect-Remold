<div align="center">

# SynKinect Studio module behavior

### Runtime behavior, resource ownership and parity rules of the built-in modules

[Documentation](README.md) · [Architecture](ARCHITECTURE.md) · [Module layout](MODULE-LAYOUT.md) · [UI language](STUDIO-UI-STYLE.md)

</div>

This document describes the runtime behavior of the SynKinect Studio application as shipped in this source tree. The Studio is capability-driven: each module acquires only the streams and device controls it requires, and module activation/deactivation owns the lifecycle of those resources. The Studio shell and `StudioUi` provide the frontend; each module provides its backend and composes host UI blocks; shared processing (RGB-D with depth calibration, body tracking, Scanner reconstruction, spatial audio) comes from `StudioProcessingBlocks`. Built-in modules: `scanner`, `acoustic`, `microphones`, `surveillance`, `interactivity` and `mocap` (`studio.modules.enabled` in `data/studio/config/config.properties`).

## 3D scanner

The 3D Scanner acquires synchronized color and metric depth, establishes a camera-space Volume Of Interest around the target, and rejects geometry outside that volume before registration. Realtime tracking is frame-to-model point-to-plane ICP against the fused TSDF: planar motion (rotation about the support normal plus in-plane translation) in Turntable, free 6-DoF in Kinect fusion, with optional synchronized color correspondence weighting. Accepted geometry is fused into a TSDF and a bounded accumulated point-cloud preview. Coverage advances from accepted fusion poses rather than from elapsed frames. Build Mesh is the low-latency path: it extracts the coherent live TSDF directly and applies topology-safe cleanup without repeating registration. Refine HQ is the explicit offline path and performs quality-ranked keyframe selection, neighboring-view recovery, turntable consensus when applicable, loop closure, confidence weighting, multi-frame depth super-resolution and fresh high-resolution TSDF reintegration. Recovered or weak frames are down-weighted and incompatible frames are not allowed to contaminate the final surface. Clean, Smooth, Center and Undo operate on the current mesh; export actions consume the visible mesh or build it from fused geometry first. Sensor calibration and RGB-HQ settings remain device-scoped.

## Acoustic scanner

Acoustic Scanner consumes the four-microphone array and runs band-limited GCC-PHAT/SRP localization. Pair reliability, voice activity and temporal direction tracking drive manual or automatic beam direction. The beamformed mono playback path then applies adaptive spectral noise suppression followed by output-only voice enhancement: low-frequency rumble reduction, a speech-weighted presence lift, automatic speech gain and soft compression/limiting. The raw four-channel transport is unchanged. The module owns its audio consumer state independently from the visual modules.

## Microphones

Microphones exposes the four channels for live monitoring, metering and recording. Raw-channel recording is not modified by the playback DSP. Its spatial monitor uses the same localization, voice activity, beamforming, adaptive suppression and voice-enhancement services as Acoustic Scanner, while presenting channel-oriented controls and runtime state. Recording lifecycle belongs to the module and is stopped cleanly when the module is deactivated.

## Surveillance

Surveillance manages every connected compatible camera as an independent surveillance source. It uses RGB in normal illumination and IR in low light, with hysteresis and a minimum automatic mode-hold interval to prevent rapid oscillation. Motion analysis combines appearance and luminance change. Each camera maintains a compressed in-memory pre-event ring and writes synchronized MJPEG/AVI event recordings when recording criteria are met. Surveillance does not request Depth, so depth consumers can operate independently.

- RGB → IR switching uses luminance hysteresis. The default entry point is 0.24 mean luma for 8 consecutive sampled frames, so IR starts in a dim scene instead of waiting for near-black RGB. Returning to RGB requires the higher 0.34 threshold, preventing mode chatter.
- Arming resets every camera motion background. A 2.5 s arm grace period plus a 24-frame detector warmup prevents the pre-arm scene or startup exposure changes from immediately opening an event.
- Motion must be spatially coherent and persist for 5 frames. Isolated changed samples are rejected by neighborhood support, while a lower release threshold keeps a real moving event stable once acquired.

## Interactivity

Interactivity owns one `BodyTrackingSession` (depth-only, full FOV) while its tab is active and runs SynSkeleton on a dedicated latest-frame worker. The default articulated solver fits a 20-joint model to the segmented metric depth; the view is a body-centric nominal metric frame referenced to 1.10 m: its presentation origin follows the tracked torso and a bounded safety fit only zooms out when needed to keep the measured body inside the panel; these presentation transforms never feed back into tracking. Tracking details: [SynSkeleton 3D architecture](SKELETON-3D-ARCHITECTURE.md).

`Interactivity.pde` holds the desktop controller and presentation; `InteractionControl.pde` holds the hands, filters and air keyboard. Each hand owns an interaction zone anchored at its shoulder and scaled by arm length; a hand controls only when raised in front of the body. A relative push toward the sensor clicks (hysteresis, spike rejection, click lock); the second hand gives right click, double click and joystick-style scroll; holding both hands above the head toggles the air keyboard, on which both hands type at the same time. The pointer uses a One-Euro filter. The hand selector cycles Auto / Right / Left and the tracking category cycles Auto / Body / hands / Hands & fingers; both are stored in the user preference store. XY is anchored to the refined palm or the body hand, never to a fingertip. Losing tracking, disabling control or leaving the module releases any held button. Details: [Interactivity controls](INTERACTIVITY-CONTROLS.md) and [Hands and fingers](HANDS-AND-FINGERS.md).

## Motion capture

Motion Capture (`mocap`) owns its own `BodyTrackingSession` while its tab is active, retargets each `BodyFrame` to a Unity humanoid (`MocapRetarget.pde`) and streams it through the enabled sinks (`MocapSinks.pde`): VMC over OSC/UDP (default 39539), plain OSC, JSON over UDP and a WebSocket server (default 39540), plus BVH recording to the per-user data directory. Each sink has its own thread and latest-only mailbox. All sockets bind to `bindAddress` (default `127.0.0.1`). Leaving the tab stops tracking, closes the sockets and finalizes a running BVH recording; returning re-opens the enabled sinks. Details: [Motion capture](MOTION-CAPTURE.md).

## Sensor calibration

Sensor Calibration opens as a standalone RGB + Metric Depth window with its own `RgbdSession`. It captures one flat wall at several distances, fits planes in inverse depth and solves a smooth, distance-aware residual (`DepthCorrectionSolver`, profile v3). An optional tape-measured reference distance fixes absolute scale. Results are reviewed and saved explicitly per device identity; saving or resetting emits `DEPTH_CALIBRATION_CHANGED`. Every `RgbdSession` loads the saved profile, so Scanner, registration, point-cloud construction and body tracking share one depth authority. Details: [Sensor calibration](SENSOR-CALIBRATION.md).

## Home, system controls and device routing

Home presents built-in and external modules through the same module lifecycle. Device discovery merges native driver-module registries into one Studio list. The selected Kinect is routed to single-device modules; modules that intentionally support all devices maintain their own per-device sessions. System/driver operations are separate from module controls and request elevation only for protected operating-system changes. LANguage and selected-device context changes are dispatched to initialized modules.

## External module SDK

External modules are loaded through the Studio module API and receive a `StudioModuleContext` for UI, device metadata, transport, saved depth calibration, host-owned body tracking (`bodyTracking(deviceId)`) and lifecycle events. Their state and class loader are isolated from built-in module state. Setup, activation, deactivation, drawing and disposal follow the same host lifecycle used by built-in modules.

## Concurrency and ownership

Camera/audio transport, reconstruction, interaction fusion, recording and slow maintenance tasks run outside the Processing render thread. The UI consumes published snapshots. Each module releases its own stream/control resources when deactivated, so leaving one module does not silently stop another module's independent session. Shared workers provide bounded shutdown and the Studio keeps fatal runtime failures visible with diagnostic log paths instead of closing silently.

Observer-facing visual orientation: camera/depth previews, the 3D body view, live/reconstructed Scanner 3D views, Surveillance tiles and the acoustic radar use one consistent horizontal presentation for a Kinect aimed at the subject. This is presentation-only: calibrated camera coordinates, tracking, ICP/TSDF reconstruction, exported geometry and raw acoustic azimuth remain in native sensor coordinates.

### Body-tracking ownership

All 3D body processing is owned by `Skeleton.pde` / `SkeletonLibrary` and exposed through `BodyTrackingSession`: person segmentation, the articulated solver, joint confidence, hands/fingers, occlusion hold and the metric body cloud. Modules consume the resulting snapshots. Interactivity keeps only desktop-control behavior; Motion Capture keeps only retargeting and output sinks.


## Windows/Linux parity contract

Built-in modules must not branch on Windows versus Linux for feature semantics. Scanner, Acoustic Scanner, Microphones, Surveillance, Interactivity, Motion Capture, SynSkeleton and Sensor Calibration consume the same `KinectDevice` capability/state contract and the same local transport timeout/reconnect policy. Platform checks are allowed only at operating-system integration boundaries such as opening the native maintenance script, choosing a folder, or selecting the native local IPC implementation.

Device discovery runs driver modules independently. A missing Kinect One runtime must not delay Kinect 360 discovery, and the reverse is also true. Short USB reenumerations preserve the selected physical device as `Reconnecting` for the shared grace period rather than forcing module teardown/reselection immediately.

Microphone status is backend-neutral at Studio level. The common counter is `transport_packets`; backend-specific diagnostics may be recorded internally, but they do not change the visible meaning of READY/PENDING/error.

### Surveillance video orientation

Surveillance preserves each Kinect camera stream in its native left-right orientation for preview, motion evidence and recording. The timestamp/camera stamp is composited only after orientation correction, so it remains in the configured bottom-right position and is never mirrored with the image.
