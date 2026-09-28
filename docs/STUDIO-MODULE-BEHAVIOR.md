# SynKinect Studio module behavior

This document describes the runtime behavior of the SynKinect Studio application as shipped in this source tree. The Studio is capability-driven: each module acquires only the streams and device controls it requires, and module activation/deactivation owns the lifecycle of those resources. Shared services provide device discovery, RGB-D calibration, skeleton tracking, UI, worker management, localization and external-module hosting.

## 3D Scanner

The 3D Scanner acquires synchronized color and metric depth, establishes a camera-space Volume Of Interest around the target, and rejects geometry outside that volume before registration. Realtime pose tracking uses robust 6-DoF ICP with turntable-aware initialization and optional synchronized color correspondence weighting. Accepted geometry is fused into a TSDF and a bounded accumulated point-cloud preview. Coverage advances from accepted fusion poses rather than from elapsed frames. Build Mesh reconstructs from retained keyframes, while Refine HQ performs quality-ranked angular keyframe selection, repeated neighboring-view recovery, fixed-axis turntable consensus, loop closure, per-frame confidence weighting, multi-frame depth super-resolution and fresh TSDF reintegration. Recovered or weak frames are down-weighted and incompatible frames are not allowed to contaminate the final surface. Clean, Smooth, Center and Undo operate on the current mesh; export actions consume the visible mesh or build it from fused geometry first. Sensor calibration and RGB-HQ settings remain device-scoped.

## Acoustic Scanner

Acoustic Scanner consumes the four-microphone array and runs band-limited GCC-PHAT/SRP localization. Pair reliability, voice activity, temporal direction tracking and adaptive noise suppression are combined before direction output. Manual beam direction can be selected explicitly; automatic beam mode follows the tracked acoustic source. The module owns its audio session independently from the visual modules.

## Microphones

Microphones exposes the four channels for live monitoring, metering and recording. It uses the same spatial-audio processing services as Acoustic Scanner for direction, voice activity, suppression and beamforming, while presenting channel-oriented controls and runtime state. Recording lifecycle belongs to the module and is stopped cleanly when the module is deactivated.

## Surveillance

Surveillance manages every connected compatible camera as an independent surveillance source. It uses RGB in normal illumination and IR in low light, with hysteresis and a minimum automatic mode-hold interval to prevent rapid oscillation. Motion analysis combines appearance and luminance change. Each camera maintains a compressed in-memory pre-event ring and writes synchronized MJPEG/AVI event recordings when recording criteria are met. Surveillance does not request Depth, so depth consumers can operate independently.

## Interactivity

Interactivity owns a full-FOV metric-depth session and runs SynSkeleton/Body3D on a dedicated latest-frame worker. The tracker segments the person, constructs a calibrated 3D body cloud, estimates a temporally stable body coordinate frame and fits the 20-joint NUI-compatible topology. The visual point cloud and skeleton remain in the same metric camera space; viewport zoom and centering are presentation-only.

Body3D assigns probabilistic anatomical labels to depth samples, maintains subject-specific bone statistics and uses the segmented cloud as the scale authority. Torso length, shoulder/hip span and leg chains are stabilized against measured body height. The high-precision profile runs denser cloud sampling, longer temporal consensus and repeated articulated-model/cloud refinement. Full-resolution joint searches reject incompatible depth layers, while velocity plus acceleration limiting suppress isolated motion spikes. Distal joints are reattached to same-side metric cloud support after kinematic fitting. Floor support constrains the feet.

For overlapping geometry, Body3D estimates the torso's depth layer. A hand or forearm crossing the chest can therefore be identified by being physically in front of the torso even when it occupies the same 2D pixels. Lower-body arm hypotheses are scored continuously from depth, side, reach and temporal history instead of being switched by one hard threshold. Short occlusions use root translation plus bounded joint velocity; confidence decays until compatible depth evidence reacquires the joint. Distal cloud anchoring is correction-limited so isolated depth noise cannot snap a complete limb between frames.

Desktop control uses the tracked torso as a local coordinate system. Hand lateral/vertical displacement maps to the combined operating-system desktop, while hand depth relative to the torso drives press/release gestures. Pointer XY is filtered separately from the skeleton: a stationary dead-zone removes micro-jitter, adaptive smoothing becomes faster during intentional movement, and pointer acceleration/speed bounds reject one-frame joint spikes without changing the depth gesture thresholds. Enable control, Disable control and Hand mode are frontend state controls and use the same content-local coordinates as their rendering and hover states. Auto hand mode selects the stronger hand with hysteresis; explicit Right and Left modes are persistent. A forward push presses and holds the primary button for drag, pullback releases it, a stable two-hand push generates double-click, and stable two-hand vertical movement generates wheel scrolling. The controller receives every active pose while enabled and performs its own tracking/loss handling, ensuring that temporary pose-confidence changes do not leave the cursor or mouse button in a stale state.

## Sensor Calibration

Sensor Calibration opens as a standalone calibrated RGB + Metric Depth workflow. Multiple flat-wall stations are averaged, robust planes are fit at separate ranges, and the resulting per-pixel depth scale/offset/noise profile is stored by device identity. All metric consumers use the calibrated depth accessor so Scanner, registration, point-cloud construction and Body3D share one depth authority.

## Home, system controls and device routing

Home presents built-in and external modules through the same module lifecycle. Device discovery merges native driver-module registries into one Studio list. The selected Kinect is routed to single-device modules; modules that intentionally support all devices maintain their own per-device sessions. System/driver operations are separate from module controls and request elevation only for protected operating-system changes. Language and selected-device context changes are dispatched to initialized modules.

## External module SDK

External modules are loaded through the Studio module API and receive a `StudioModuleContext` for UI, device metadata, transport and lifecycle events. Their state and class loader are isolated from built-in module state. Setup, activation, deactivation, drawing and disposal follow the same host lifecycle used by built-in modules.

## Concurrency and ownership

Camera/audio transport, reconstruction, interaction fusion, recording and slow maintenance tasks run outside the Processing render thread. The UI consumes published snapshots. Each module releases its own stream/control resources when deactivated, so leaving one module does not silently stop another module's independent session. Shared workers provide bounded shutdown and the Studio keeps fatal runtime failures visible with diagnostic log paths instead of closing silently.

Observer-facing visual orientation: camera/depth previews, Body3D, live/reconstructed Scanner 3D views, Surveillance tiles and the acoustic radar use one consistent horizontal presentation for a Kinect aimed at the subject. This is presentation-only: calibrated camera coordinates, tracking, ICP/TSDF reconstruction, exported geometry and raw acoustic azimuth remain in native sensor coordinates.

### Skeleton processing ownership

All 3D body processing is owned by `Skeleton.pde` / `SkeletonLibrary`: person segmentation, Body3D fusion, joint confidence, temporal consensus, Kalman/One-Euro filtering, adaptive per-joint motion learning, anthropometry, occlusion recovery, biomechanical refinement and the metric body cloud. Frontends consume the resulting pose/cloud snapshot. The Interactivity module keeps only interaction-specific behavior such as cursor smoothing, click/drag/scroll gestures and UI presentation.
