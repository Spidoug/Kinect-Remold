# SynKinect Studio

`SynKinectStudio.pde` is the single editable Processing application for the Kinect Xbox 360 Remold project. The Studio includes five hardware modules and can load additional modules as tabs in the same window:

- **3D Scanner** — RGB + calibrated metric depth reconstruction, mesh editing and OBJ/STL/PLY export.
- **Acoustic Scanner** — four-microphone GCC-PHAT/TDOA localization with voice activity detection, adaptive noise suppression and conservative AUTO/MANUAL beamforming to the system playback output.
- **Microphones** — four-channel monitor, diagnostics and recording, with its own instance of the same voice-aware DOA/noise-suppression/beamforming engine used by Acoustic Scanner.
- **Surveillance** — all-connected-Kinect adaptive video surveillance: RGB in normal light or IR in low light, never Depth, with appearance/luminance motion detection, a compressed 10-minute RAM ring per camera and synchronized internal MJPEG/AVI event recording.
- **Interactivity** — NUI20 Kinematic Fusion over metric Depth, with calibrated RGB overlay, stable identity, per-joint temporal/anthropometric filtering and body-relative 3D desktop interaction on Windows and Linux.

Use the top tab bar or keys `1`..`5` to switch modules. The top-level Kinect control selects the device used by single-camera modules. **3D Scanner and Interactivity each open their own RGB 640×480 + metric-Depth session for the selected Kinect.** Surveillance is deliberately different: while its tab is active it monitors every device in the central registry concurrently. RGB and raw IR share one physical Kinect video engine. Foreground Surveillance owns that arbitration and subscribes exactly one video stream: RGB in normal light or IR in low light. It never subscribes Depth. Leaving Surveillance disarms it and releases video ownership so Scanner/Interactivity are not blocked.


## Instance-owned Studio runtime

`SynKinectStudio.pde` keeps the Processing callbacks only as the required `PApplet` host boundary. The Studio itself is a `StudioController` instance that owns the built-in and loaded `StudioModule` instances. Each module has instance lifecycle methods for initialization, activation, deactivation, drawing, input and disposal. Protocols, themes, transports, UI objects and the 3D viewport are also normal object instances; the PDE contains no `static` declaration.

Tab switching is asynchronous. The render/UI thread only requests a target module; a dedicated lifecycle worker releases the current native transport and activates the latest requested module. Rapid tab changes are coalesced, so blocking pipe/socket shutdown and worker joins never run in the Processing draw/input thread.

Scanner and Interactivity use independent camera transport instances. They reuse the same calibration math, but never share a live RGBD connection. Leaving either module invalidates and closes its transport immediately; the superseded worker retires by session generation and cannot stop a newly opened module. Interactivity consumes only its newest RGB + metric-Depth pair and sends immutable snapshots to a separate tracking worker, keeping the Processing render thread free of camera I/O and heavy CV work.

Surveillance owns all discovered Kinect video streams only while its tab is active. Leaving Surveillance disarms monitoring, stops any active event asynchronously and releases RGB/IR ownership so Scanner or Interactivity cannot be blocked by a hidden video consumer. While active, every discovered Kinect owns an independent RGB-or-IR subscriber, appearance/luminance motion detector and compressed JPEG retention ring in RAM. The default ring is **10 minutes** and every event flushes **60 seconds of pre-roll** per camera before appending live frames. Motion from any camera starts one global event containing one compact MJPEG/AVI file per connected Kinect. The AVI writer is part of the Studio and starts no external encoder process.


## Global seven-language policy

Language ownership is centralized in `StudioController`/`StudioShellI18n`. The supported order is configured by `data/studio.properties` and contains `en-US`, `pt-BR`, `es-ES`, `fr-FR`, `de-DE`, `it-IT` and `ja-JP`. **English (`en-US`) is the primary/default language.** The shell exposes exactly one Language control in the top bar. It cycles the shared locale and propagates it to every initialized module; modules created later start directly in the current shell locale. Individual modules do not own separate language controls or locale state.

There is one physical catalog directory: `data/i18n/`. It contains exactly seven locale files. Separation of concerns is preserved by key namespaces inside each file: `studio.*`, `scanner.*`, `acoustic.*`, `microphone.*`, `surveillance.*` and `interaction.*`. The seven files are key-parity checked as one catalog.

## Responsive typography

`studioUiScale()`, `responsiveFontSize()`, `fitCurrentTextSize()` and `ellipsizeToWidth()` are the shared typography policy. Base font size follows the actual window dimensions. Text that lives inside a finite control is then fitted against that control's real width/height, with an ellipsis only if the configured minimum size still cannot fit. Tabs, buttons, cards, metrics, pills, status rows and Interactivity fields use this policy.

## Interactivity pipeline

The Interactivity module acquires **synchronized Kinect RGB + metric Depth** and never subscribes to IR. Body tracking is performed by **NUI20 Kinematic Fusion**, implemented inside the Studio. The depth segmenter keeps several plausible person-depth hypotheses instead of selecting one largest blob, then chooses connected components using geometry plus temporal center/depth affinity. Torso anchors come from robust silhouette profiles; arms and legs follow depth-continuous medial/geodesic paths, with intermediate joints sampled by physical path length and refined from local depth support. The result is constrained by learned bilateral 3D bone lengths and lifted to calibrated camera-space XYZ. RGB is used only for calibrated preview/overlay.

Every published joint stores image coordinates, camera-space XYZ metres, confidence and tracking state. `InteractionPoseFilter` applies adaptive 3D filtering, innovation gating and velocity limiting; `NuiAnthropometricModel` learns symmetric limb proportions and projects noisy measurements back to plausible bone lengths. The full canonical Kinect-v1 20-joint skeleton remains available, including hips, knees, ankles and feet, while desktop interaction deliberately requires only the torso/shoulders/arms/hands. Hand analysis estimates a depth-supported palm and contour extrema for fingertips, openness, grab and pinch cues. On Linux the same 20-joint order can be published through `/run/kinect360-remold/nui-skeleton.sock` for project-side NUI-compatible adapters; this is not binary impersonation of the Microsoft Kinect runtime.

The overlay remains a virtual-rig presentation built from the filtered **full-body** pose, including hips, knees, ankles and feet. The interactive-control gate is deliberately upper-body only: torso identity, shoulders, arms and hands drive pointer/gesture input, so missing or occluded legs cannot disable desktop interaction. Lower-body joints continue to be detected, filtered, biomechanically validated and rendered for diagnostics and future full-body features. Pointer coordinates are derived from a shoulder/torso-aligned 3D body frame rather than raw image pixels or camera-global axes, reducing cursor drift when the user rotates or shifts relative to the camera. Losing tracking, disabling control, changing tabs or pressing `Esc` releases held input state.


## Compact Surveillance video

Surveillance writes `recordings/event-YYYYMMDD-HHmmss/kinect-<device-id>.avi` with Motion JPEG plus an `event.properties` manifest. Video compression and AVI indexing are implemented inside the Studio; FFmpeg is not used. The pre-roll source is the in-memory compressed ring; temporary camera disconnects preserve already-retained frames and a reconnect with the same stable device ID rejoins the same event recorder.

## Window-close safety

`Esc` is consumed globally by the Studio and acts only as a cancel/release key; Processing's default ESC-to-exit path is disabled. The JOGL native window uses `DO_NOTHING_ON_CLOSE`, and all close requests are routed through the Studio policy. If Surveillance is armed or recording, the close request is rejected and a localized warning is shown. After Surveillance is disarmed, the same close button exits normally.

## Window resize and pointer coordinates

The Studio opens at **1280×800** and enforces that same size as its minimum resizable window, preventing panels from collapsing below the layout they were designed for. The shell reserves the top `STUDIO_TAB_H` pixels for navigation and renders each module after translating the canvas into content space. Pointer input uses the inverse transform exposed by `StudioController.contentMouseX()/contentMouseY()`; modules must not read global `mouseX`/`mouseY` directly for content controls. This keeps hover, click and drag geometry aligned after resizing the P3D window so the visible controls and hit areas share the same coordinate transform.

## 3D viewport containment

The 3D Scanner reconstruction environment is rendered by an instance-owned off-screen `PGraphics(P3D)` viewport. Grid, axes, point cloud and mesh are rendered into that buffer and then composited into the reconstruction card as one image. This prevents camera/projection/depth state from leaking into the Studio renderer or drawing outside the panel. The viewport is recreated to match the actual panel dimensions after a window resize, so the UI follows the generated window size rather than a fixed design-time height.

## Application icon

The SynKinect Studio icon asset is maintained with the application source. The sketch contains Processing export icon sizes (`icon-16.png` through `icon-512.png`), keeps `data/synkinect-studio-icon.png` as the runtime window icon, and embeds the same PNG in the unified application JAR as a fallback resource. Documentation screenshots and the full Kinect hardware reference image are kept separately under `../../../docs/images/`. Runtime launchers are sourced from `../../runtime-templates/`; Linux staging also copies the PNG and a `.desktop` entry. Generated runtime files are created under the build output tree when needed.

## RAW camera boundary

ScannerPort uses GRBG8 Bayer RGB, packed 10-bit IR and packed 11-bit Depth. The Studio rejects decoded camera wire formats instead of selecting alternate decoders. RGB demosaic, IR unpack/crop and calibrated Depth conversion are performed in the module-side processing layer. Module objects are instantiated independently at startup, but transports remain closed until the corresponding module is activated.

## Linux/Processing runtime interface

The application uses one local transport implementation for Windows named pipes and Linux Unix-domain sockets. Transport shutdown is idempotent and actively closes both input and output sides so worker threads do not remain blocked while changing tabs or closing the program.

## 3D scanner low-latency pipeline

Scanner buffering is bounded and prioritizes current capture data:

1. the native camera bridge keeps bounded FIFO queues per RGB/IR/depth stream;
2. `KinectSource` keeps bounded RGB/depth synchronization history and publishes synchronized `RgbdFramePair` objects;
3. the Processing render loop drains several available pairs per tick, while preview diagnostics and RGB preview conversion are paid only for the newest drained pair;
4. active reconstruction keeps a small bounded latest-frame window and drops the oldest pending reconstruction item if fusion falls behind;
5. ICP tracking is geometry-only. RGB decoding/calibrated registration is deferred until a pose is accepted, so rejected tracking frames do not pay the color-fusion cost;
6. TSDF reset/initialization runs on the reconstruction worker; **Scan** does not clear the reconstruction volume on the Processing render/UI thread.

Queue sizes and drain rate are configurable in `data/scanner.properties`. The real-time profile uses a 4-frame reconstruction window, 8 published RGBD pairs and 10 synchronization-history frames while preserving the configured 192³ TSDF volume. Native and Processing frame numbers are monitored so transport gaps are visible instead of being silently hidden.

## High-quality final reconstruction

The 192³ TSDF remains the low-latency preview used while the operator moves around the object. When `quality.enabled=true`, accepted full RGBD keyframes are also retained and the **Build** action performs a second, offline-quality reconstruction instead of simply exporting the preview volume.

### Scanner color transport

The live Scanner defaults to RGB 640×480 + metric Depth as its physical baseline. Geometry therefore remains independent of high-resolution color modes, while the **RGB HQ** switch can optionally promote the color stream to the native 1280×1024 Bayer mode without changing the 640×480 metric Depth geometry. High-quality reconstruction continues to use calibration, robust registration, multi-view fusion and the HQ TSDF build; if HQ color is unavailable the camera transport falls back to VGA RGB.


## Compact mesh export

The Save action uses Processing `selectOutput()` and suggests `SynKinectScan.stl`, `.obj` or `.ply`, so Windows displays a file-save workflow rather than a folder/open selector.

Exports run outside the capture/render thread. Before writing, the mesh is converted to an indexed representation, nearby vertices are welded, degenerate/duplicate faces are removed and triangle count is bounded with conservative geometric clustering. PLY is binary little-endian. OBJ reuses indexed vertices and always exports as a save-file operation; when compatible photos are found automatically in the selected export folder, it also creates material/texture assets from them. These photos are resized and JPEG-compressed according to `scanner.properties`. STL remains binary and uses the compacted face set.

Important export settings in `data/scanner.properties`:

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

The Scanner capture bar exposes **SENSOR CALIBRATION** and **RGB HQ**. Per-device depth calibration is enabled by default and learns per-pixel correction/noise confidence from multiple flat-wall distances; this improves use of valid depth samples but cannot create measurements inside the physical sensor's invalid/zero-depth region. RGB HQ is disabled by default and can be enabled before a scan (or with `H`); when available it requests the Kinect 1280x1024 Bayer color stream and falls back safely when the transport does not advertise it. The Kinect system control panel and the Studio system settings also expose the persistent RGB HQ policy used by the virtual camera and derived RGB services.

The Remold NUI20 stream uses Kinect-v1 joint ordering. `ShoulderCenter` is published from the upper torso/neck anchor rather than the lower chest estimate, and the Linux skeleton relay completes partial socket writes so slow consumers remain connected. The Remold NUI ABI is an adapter-facing compatibility layer; it is not binary impersonation of Microsoft's Kinect SDK and does not make an Xbox 360 console game accept a PC-hosted sensor automatically.

## Module API 1

External modules implement `org.synkinect.studio.api.SynKinectStudioModule` and are discovered from trusted JAR files in the packaged `modules/` directory through Java `ServiceLoader`. The public API is maintained under `applications/studio-module-sdk/` and is built as `SynKinectStudio-module-api.jar`.

Built-in modules remain first in navigation. Loaded modules receive `StudioModuleContext`, which provides the Processing host, locale, device snapshots, public Remold endpoints, local transport access, per-module data storage, logging and managed workers. Module JARs execute in the Studio process with the Studio user's operating-system permissions.
