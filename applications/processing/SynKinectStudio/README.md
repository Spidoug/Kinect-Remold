# SynKinect Studio

`SynKinectStudio.pde` is the single editable Processing application for the Kinect Xbox 360 Remold project. The Studio includes five hardware modules and can load additional modules in the same window:

- **3D Scanner** — RGB + calibrated metric depth reconstruction with rolling-model trimmed ICP, confidence/distance-weighted TSDF fusion, high-quality keyframe refinement, mesh editing and OBJ/STL/PLY export.
- **Acoustic Scanner** — four-microphone band-limited SRP/GCC-PHAT localization with per-pair reliability weighting, temporal source tracking, voice activity detection, adaptive noise suppression and conservative AUTO/MANUAL beamforming to the system playback output.
- **Microphones** — four-channel monitor, runtime status and recording, with its own instance of the same voice-aware DOA/noise-suppression/beamforming engine used by Acoustic Scanner.
- **Surveillance** — all-connected-Kinect adaptive video surveillance: RGB in normal light or IR in low light, never Depth, with appearance/luminance motion detection, a compressed 10-minute RAM ring per camera and synchronized internal MJPEG/AVI event recording.
- **Interactivity** — 20-joint Kinematic Fusion over metric Depth, with calibrated RGB overlay, stable identity, confidence-aware joint filtering, anthropometric stabilization, persistent Auto/Right/Left hand selection and precision body-relative 3D desktop interaction on Windows and Linux.

Open modules from the Home cards. The top bar is intentionally limited to Home, Kinect selection and Language so every module receives the same navigation shell. Home uses an automatically flowing card grid backed by a scroll viewport: built-in and newly loaded modules are inserted with the same title/description cards, the grid chooses its column count from the available width, and the mouse wheel or draggable scrollbar reaches additional rows without moving the shell title. The Kinect system/driver controls follow the module grid at their natural content height instead of reserving a large empty panel. All built-in modules use the shared `StudioUi` component system for panels, metric blocks, buttons, status footers, responsive spacing and localization-safe text fitting while preserving the established appearance: one single-line module header followed by titled cards for previews, status and action/control groups. Specialized preview canvases remain module-owned, while reusable front-end controls and resize behavior are host-owned. Interactive buttons stay inside action/control panels instead of floating in or below the header. The top-level Kinect control selects the device used by single-camera modules and shows the detected model plus the selected/total count, for example `Kinect 1473 · 2/2`. An explicit selector change is treated differently from an automatic reconnect: it immediately drops frames from the previous sensor, closes that sensor's active module transports and reconnects Scanner, Interactivity, Acoustic and Microphones to the newly selected stable `device-id`. The device registry lists physical sensors independently of camera-endpoint readiness; a sensor may remain selectable while its video transport is re-enumerating, and video-dependent modules wait for that sensor's endpoint instead of removing the sensor from the Studio. **3D Scanner and Interactivity each open their own RGB 640×480 + metric-Depth session for the selected Kinect.** Surveillance is deliberately different: while the module is active it monitors every device in the central registry concurrently. RGB and raw IR share one physical Kinect video engine. Foreground Surveillance owns that arbitration and subscribes exactly one video stream: RGB in normal light or IR in low light. It never subscribes Depth. Leaving the Surveillance module disarms it and releases video ownership so Scanner/Interactivity are not blocked.


## Instance-owned Studio runtime

`SynKinectStudio.pde` keeps the Processing callbacks only as the required `PApplet` host boundary. The Studio itself is a `StudioController` instance that owns the built-in and loaded `StudioModule` instances. Each module has instance lifecycle methods for initialization, activation, deactivation, drawing, input and disposal. Protocols, themes, transports, UI objects and the 3D viewport are also normal object instances; the PDE contains no `static` declaration.

Module switching is asynchronous. The render/UI thread only requests a target module; a dedicated lifecycle worker releases the current native transport and activates the latest requested module. Rapid module changes are coalesced, so blocking pipe/socket shutdown and worker joins never run in the Processing draw/input thread.

Scanner and Interactivity use independent camera transport instances. They reuse the same calibration math, but never share a live RGBD connection. Leaving either module invalidates and closes its transport immediately; the superseded worker retires by session generation and cannot stop a newly opened module. Interactivity consumes only its newest RGB + metric-Depth pair and sends immutable snapshots to a separate tracking worker, keeping the Processing render thread free of camera I/O and heavy CV work.

Surveillance owns all discovered Kinect video streams only while the module is active. Leaving Surveillance disarms monitoring, stops any active event asynchronously and releases RGB/IR ownership so Scanner or Interactivity cannot be blocked by a hidden video consumer. While active, every discovered Kinect owns an independent RGB-or-IR subscriber, appearance/luminance motion detector and compressed JPEG retention ring in RAM. When Surveillance is already in IR mode and motion is confirmed, it immediately attempts a bounded RGB probe; usable color keeps RGB active, while darkness, a failed RGB subscription or a probe timeout automatically restores IR. Ambient-light recovery remains a slower secondary RGB probe path. The default ring is **10 minutes** and every event flushes **60 seconds of pre-roll** per camera before appending live frames. Motion from any camera starts one global event containing one compact MJPEG/AVI file per connected Kinect. The AVI writer is part of the Studio and starts no external encoder process.


## Application-local language and data layout

Language selection remains global in `StudioController`/`StudioShellI18n`. The top bar contains exactly three aligned controls: Home, the centered Kinect selector, and Language. Module names are not duplicated in the top bar; modules are opened from Home. The configured order is `en-US`, `pt-BR`, `es-ES`, `fr-FR`, `de-DE`, `it-IT`, `ja-JP` and `zh-CN`. **English (`en-US`) is the primary/default language.** Chinese uses Simplified Chinese (`zh-CN`) and the Studio selects CJK-capable fonts when available.

Resources are separated by application instead of sharing one monolithic catalog. Each built-in application owns its configuration and locale package:

```text
data/
  studio/
    config.properties
    i18n/<locale>.properties
  scanner/
    config.properties
    i18n/<locale>.properties
  acoustic/
    config.properties
    i18n/<locale>.properties
  microphones/
    config.properties
    i18n/<locale>.properties
  surveillance/
    config.properties
    i18n/<locale>.properties
  interactivity/
    config.properties
    i18n/<locale>.properties
```

Every application also owns an `output/` directory under its same `data/<app>/` folder. Runtime files therefore stay inside the SynKinect Studio program tree while remaining isolated by feature: Scanner stores preferences, per-device calibration and exports under `data/scanner/output/`; Microphones stores WAV recordings under `data/microphones/output/recordings/`; Surveillance stores event recordings under `data/surveillance/output/recordings/`; Studio launcher logs use `data/studio/output/logs/`. External modules receive `data/modules/<module-id>/output/`. Output directories are created on demand and are not part of the distributed resource set.

## Responsive typography

`studioUiScale()`, `responsiveFontSize()`, `fitCurrentTextSize()` and `ellipsizeToWidth()` are the shared typography policy. Base font size follows the actual window dimensions. Text that lives inside a finite control is then fitted against that control's real width/height, with an ellipsis only if the configured minimum size still cannot fit. Buttons, cards, metrics, pills, status rows and Interactivity fields use this policy.

## Module visual ownership

The host owns structural UI rules: content width, panel columns, panel/button/metric maximum widths, gaps, responsive typography and generic hit testing. Built-in and external modules therefore receive the same spacing behavior without module-name exceptions. A module owns only specialized visualization and domain presentation that cannot be expressed with the shared `StudioUi` components. Built-ins may define domain-specific button labels/actions, but their geometry is delegated to the same layout engine used by declarative external modules.

## Shared RGB-D session

`RgbdCore.pde` exposes an independent RGB-D session boundary for modules that need synchronized RGB and metric depth. A module owns its own session and can select a Kinect without depending on another module's lifecycle. Shared frame types live at this boundary so future modules can consume RGB-D data without importing Scanner UI or Scanner state.

## Shared spatial-audio library

`SpatialAudio.pde` is the shared per-Kinect spatial-audio runtime used by the built-in audio modules. Exactly one `SpatialAudioDeviceSession` owns the raw 4-channel transport, frame decode, localization and human-voice/VAD analysis for each `device-id`; Acoustic Scanner and Microphones attach as independent consumers of that same immutable frame/analysis stream. Each consumer may still instantiate its own beamformer/noise-suppression output state, so playback choices never feed back into capture/VAD. Shared tuning lives in `data/spatial-audio/config.properties`. Additional modules can attach to the same per-device session without opening a second microphone transport.

## Shared SynSkeleton library

Body tracking is implemented in `Skeleton.pde` as **SynSkeleton**, a Studio-wide library rather than an Interactivity-only subsystem. `StudioServices.skeletons` exposes a reusable `SkeletonLibrary`; any built-in module can create an independent `SkeletonTracker` with `studio.services.skeletons.createTracker(calibration, rgbRegistration)`. Each tracker owns its temporal history, person identity, learned anthropometry and occlusion state, so trackers may be instantiated independently for different modules or Kinect devices. Shared tuning lives in `data/skeleton/config.properties`.

A tracker consumes calibrated metric Depth directly, or an `RgbdFramePair`, and returns a `SkeletonPose3D` using the canonical Kinect Xbox 360/NUI 20-joint topology. The pipeline combines robust median depth sampling, multi-hypothesis person segmentation with a soft human-silhouette prior, short depth-gap bridging, vertical silhouette continuity, temporal identity affinity, medial/geodesic limb tracing, coarse-to-fine depth-supported landmark refinement at native depth resolution, robust multi-frame median/MAD consensus, a depth-aware constant-velocity Kalman stage, confidence-aware One-Euro-style filtering, innovation and velocity gates, coherent torso/root stabilization, bounded bilateral anthropometric learning, iterative articulated-body constraint optimization, direction constraints and short occlusion prediction. Body acquisition depends on body/torso evidence and core-joint coverage rather than hand quality; `interactionTracked()` is a separate stricter gate for modules that require a usable hand. Acquisition evidence accumulates with hysteresis instead of resetting after a single weak frame, and after a sustained miss the person segmenter broadens its search instead of remaining locked to a stale predicted location.

Every joint stores image coordinates, camera-space XYZ metres, confidence and tracking state. `SkeletonPoseFilter` uses joint-class motion limits so torso anchors remain stable while hands, wrists, feet and other extremities remain responsive. `SkeletonAnthropometricModel` learns symmetric limb proportions only from high-confidence measurements and bounds outlier observations before they can change learned bone lengths. `SkeletonTemporalConsensus` rejects isolated joint spikes before low-pass filtering, while `SkeletonRootStabilizer` applies a coherent body translation instead of allowing independent filters to make the torso shimmer. The public pose is exactly the Kinect Xbox 360/NUI 20-joint model: HipCenter, Spine, ShoulderCenter, Head and the bilateral shoulder/elbow/wrist/hand/hip/knee/ankle/foot joints. Hands are ordinary terminal joints; the tracker does not infer fingers, palm landmarks, pinch or grab states. The integrated driver package does not expose a NUI skeleton relay socket, so SynSkeleton remains an in-Studio service for built-in/external Studio modules and the optional publisher stays disabled.

## Interactivity pipeline

The Interactivity module acquires **synchronized Kinect RGB + metric Depth** and never subscribes to IR. It instantiates SynSkeleton through the shared library and adds only interaction-specific behavior on top: skeleton visualization, hand selection and desktop pointer control. RGB is used for calibrated preview/overlay; body tracking itself is driven by metric Depth. The full-body skeleton remains available to other modules even though desktop interaction deliberately requires only torso, shoulders, arms and hands. Interaction uses only 20-joint joint positions: forward hand motion controls press/drag, a simultaneous two-hand push produces a double click, and two-hand vertical motion controls scrolling. No finger detection or finger counting is required.

The overlay remains a virtual-rig presentation built from the filtered **full-body** pose, including hips, knees, ankles and feet. The interactive-control gate is deliberately upper-body only: torso identity, shoulders, arms and hands drive pointer/gesture input, so missing or occluded legs cannot disable desktop interaction. Lower-body joints continue to be detected, filtered, biomechanically validated and rendered for runtime inspection and future full-body features. Pointer coordinates are derived from a shoulder/torso-aligned 3D body frame rather than raw image pixels or camera-global axes. A confidence-aware precision filter adds stationary jitter rejection, bounded outlier jumps and small velocity prediction so fine pointing remains steady without making fast movements sluggish. The control-hand button cycles **Auto → Right → Left**; Auto uses confidence, forward reach and hysteresis, and the selection is stored under `data/interactivity/output/preferences.properties`. Losing tracking, disabling control or changing modules releases held input state.


## Compact Surveillance video

Each connected Kinect owns an independent ScannerPort endpoint and remains visible in the Studio device selector while its physical identity is present. The Windows installer requires the Remold private camera interface on every physical `02AE`; generic WinUSB alone is not treated as a complete camera installation. The Broker SDK is the Studio discovery source. The runtime refreshes its internal device manifest continuously, and the Studio tolerates a 30-second SDK reconnect interval before removing a previously observed device. During that interval the device state becomes `reconnecting` and no stale camera endpoint is advertised. This prevents normal 02AD→02BB/02C3 firmware re-enumeration, 02AE PnP rebinding or a CameraBridge service restart from collapsing the complete multi-Kinect list. Surveillance renders all connected cameras in a grid and records one AVI per camera inside the same event directory.

For concurrent live streams, USB host-controller bandwidth remains a hardware constraint. Kinect Xbox 360 was specified around a dedicated USB 2.0 bus; when several sensors share one controller, Windows can reject or starve isochronous bandwidth even though all sensors are correctly enumerated. In a multi-Kinect installation, CameraBridge therefore keeps each inactive sensor at zero streaming bandwidth and closes the physical RGB/Depth session when that sensor has no ScannerPort or virtual-camera consumer. Selecting another Kinect releases the previous session before the new sensor retries its stream. Separate root USB controllers/PCIe USB controllers are still recommended when several sensors must stream simultaneously.

Surveillance writes `data/surveillance/output/recordings/event-YYYYMMDD-HHmmss/kinect-<device-id>.avi` with Motion JPEG plus an `event.properties` manifest. Video compression and AVI indexing are implemented inside the Studio; FFmpeg is not used. The pre-roll source is the in-memory compressed ring; temporary camera disconnects preserve already-retained frames and a reconnect with the same stable device ID rejoins the same event recorder.

## Window-close safety

Keyboard shortcuts are not used by the built-in Studio modules. Processing's default ESC-to-exit path is disabled so accidental key input cannot close the application. The JOGL native window uses `DO_NOTHING_ON_CLOSE`, and all close requests are routed through the Studio policy. If Surveillance is armed or recording, the close request is rejected and a localized warning is shown. After Surveillance is disarmed, the same close button exits normally.

## Window resize and pointer coordinates

The Studio opens at **1440×900** and enforces that same size as its minimum resizable window. Shared `StudioUiSystem` axis allocators distribute panel groups within the exact available rectangle, shrink gaps before content, and only compress component minima as a final fallback; child button and metric grids never reserve geometry outside their host panel. The Studio now uses the normal operating-system frame and title bar. It deliberately does not call `GLWindow.setUndecorated()`, hide/show the native peer, or recreate the window after startup; moving, resizing, minimizing and maximizing are handled by the OS. The internal Studio top bar continues to provide application navigation, device selector, language control and its orderly close action. The shell reserves the top `STUDIO_TOP_BAR_H` pixels for navigation and renders each module after translating the canvas into content space. Pointer input uses the inverse transform exposed by `StudioController.contentMouseX()/contentMouseY()`; modules must not read global `mouseX`/`mouseY` directly for content controls.

## 3D viewport containment

The 3D Scanner reconstruction environment is rendered by an instance-owned off-screen `PGraphics(P3D)` viewport. Grid, axes, point cloud and mesh are rendered into that buffer and then composited into the reconstruction card as one image. This prevents camera/projection/depth state from leaking into the Studio renderer or drawing outside the panel. The viewport is recreated to match the actual panel dimensions after a window resize, so the UI follows the generated window size rather than a fixed design-time height.

## Application icon

The SynKinect Studio icon asset is maintained with the application source. The sketch contains Processing export icon sizes (`icon-16.png` through `icon-512.png`), keeps `data/studio/synkinect-studio-icon.png` as the runtime window icon, and embeds the same PNG in the unified application JAR as a fallback resource. The full Kinect hardware reference image is kept separately under `../../../docs/images/`. Runtime launchers are sourced from `../../runtime-templates/`; Linux staging also copies the PNG and a `.desktop` entry. Build artifacts are created under the build output tree; application-generated data is kept in the owning `data/<app>/output/` directory.

## RAW camera boundary

ScannerPort uses GRBG8 Bayer RGB, packed 10-bit IR and packed 11-bit Depth. The Studio rejects decoded camera wire formats instead of selecting alternate decoders. RGB demosaic, IR unpack/crop and calibrated Depth conversion are performed in the module-side processing layer. Module objects are instantiated independently at startup, but transports remain closed until the corresponding module is activated.

## Linux/Processing runtime interface

The application uses one local transport implementation for Windows named pipes and Linux Unix-domain sockets. Transport shutdown is idempotent and actively closes both input and output sides so worker threads do not remain blocked while changing modules or closing the program.

## 3D scanner low-latency pipeline

Scanner buffering is bounded and prioritizes current capture data:

1. the native camera bridge keeps bounded FIFO queues per RGB/IR/depth stream;
2. `KinectSource` keeps bounded RGB/depth synchronization history and publishes synchronized `RgbdFramePair` objects;
3. the Processing render loop drains several available pairs per tick, while preview metrics and RGB preview conversion are paid only for the newest drained pair;
4. active reconstruction keeps a small bounded latest-frame window and drops the oldest pending reconstruction item if fusion falls behind;
5. ICP tracking is geometry-only. RGB decoding/calibrated registration is deferred until a pose is accepted, so rejected tracking frames do not pay the color-fusion cost;
6. TSDF reset/initialization runs on the reconstruction worker; **Scan** does not clear the reconstruction volume on the Processing render/UI thread.

Queue sizes and drain rate are configurable in `data/scanner/config.properties`. The real-time profile uses a 4-frame reconstruction window, 8 published RGBD pairs and 10 synchronization-history frames while preserving the configured 192³ TSDF volume. Native and Processing frame numbers are monitored so transport gaps are visible instead of being silently hidden.

## High-quality final reconstruction

The 192³ TSDF remains the low-latency preview used while the operator moves around the object. When `quality.enabled=true`, accepted full RGBD keyframes are also retained and the **Build** action performs a second, offline-quality reconstruction instead of simply exporting the preview volume.

### Scanner color transport

The live Scanner keeps 640×480 metric Depth as its geometry baseline. RGB resolution is owned by the selected Kinect driver instance: when **RGB HQ** is enabled in the Studio system/driver panel or through `KINECT`, the Scanner follows that setting and consumes the native 1280×1024 Bayer color stream without changing Depth geometry. High-quality reconstruction continues to use calibration, robust registration, multi-view fusion and the HQ TSDF build; if the HQ transport stalls, the camera session is restarted without silently changing the selected RGB mode.


## Compact mesh export

The Save action uses Processing `selectOutput()` and suggests `SynKinectScan.stl`, `.obj` or `.ply`, so Windows displays a file-save workflow rather than a folder/open selector.

Exports run outside the capture/render thread. Before writing, the mesh is converted to an indexed representation, nearby vertices are welded, degenerate/duplicate faces are removed and triangle count is bounded with conservative geometric clustering. PLY is binary little-endian. OBJ reuses indexed vertices and always exports as a save-file operation; when compatible photos are found automatically in the selected export folder, it also creates material/texture assets from them. These photos are resized and JPEG-compressed according to `data/scanner/config.properties`. STL remains binary and uses the compacted face set.

Important export settings in `data/scanner/config.properties`:

```properties
export.weldToleranceM=0.0010
export.maxWeldToleranceM=0.004
export.maxTriangles=600000
export.textureMaxSize=4096
export.jpegQuality=0.90
```

Increase `export.maxTriangles` or reduce `export.weldToleranceM` when maximum geometric detail matters more than file size.

Surveillance uses an adaptive per-frame JPEG budget (10 KiB by default at 320×240 / 5 fps), targeting roughly **2.9 MiB per minute** before small AVI container overhead while retaining standard MJPEG/AVI playback.

### Scanner sensor options

The Scanner capture bar exposes **SENSOR CALIBRATION** only; it does not own RGB HQ state. Per-device depth calibration is enabled by default and learns per-pixel correction/noise confidence from multiple flat-wall distances; this improves use of valid depth samples but cannot create measurements inside the physical sensor's invalid/zero-depth region. RGB HQ is a persistent per-Kinect driver setting controlled from the Studio system/driver panel or `KINECT`. The Scanner follows that setting, and the operating-system virtual camera for the same Kinect advertises the HQ format after clients reopen and renegotiate.

The Remold 20-joint stream uses Kinect Xbox 360 joint ordering. `ShoulderCenter` is the shoulder-midline anchor and `HipCenter` is the pelvis midpoint; the Linux skeleton relay completes partial socket writes so slow consumers remain connected. The Remold NUI ABI is an project runtime interface; it is not binary impersonation of Microsoft's Kinect SDK and does not make an Xbox 360 console game accept a PC-hosted sensor automatically.

## Module API 1

External modules implement `org.synkinect.studio.api.SynKinectStudioModule` and are discovered from trusted JAR files in the packaged `modules/` directory through Java `ServiceLoader`. The public API is maintained under `applications/studio-module-sdk/` and is built as `SynKinectStudio-module-api.jar`.

The Studio registry treats built-in and external modules through the same string identity and lifecycle contract. Runtime active/ready checks for built-in hardware state use instance identity rather than fixed navigation indexes or module-name comparisons. The host dispatches language, Kinect-selection, input and close-policy behavior through generic lifecycle/context contracts: initialized modules receive `StudioContextEvent` notifications and decide internally how their own resources react. Module state is installed in a type-keyed instance store rather than fixed fields in `StudioController`, so adding another built-in state type does not change the controller.

Built-in modules remain first in navigation. Loaded modules receive `StudioModuleContext`, which provides the Processing host, locale, device snapshots, per-Kinect audio/control endpoints, public Remold endpoints, local transport access, per-module data storage, logging and managed workers. New modules can be backend-only: returning a declarative `StudioModuleUi` lets the host build and resize panels, metric blocks, buttons, status areas and hit targets automatically. The current module API provides generic context-change, mouse-release and close-guard hooks. The loader accepts only the current API contract. Custom `draw()` remains optional for specialized graphics. Module JARs execute in the Studio process with the Studio user's operating-system permissions.
