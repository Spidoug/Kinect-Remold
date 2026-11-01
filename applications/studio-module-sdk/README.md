<div align="center">

# SynKinect Studio module API

### A generation-neutral plugin contract with host-owned lifecycle, context and presentation

[Applications](../README.md) · [Studio](../processing/SynKinectStudio/README.md) · [Python bridge](PYTHON-PLUGIN-BRIDGE.md)

</div>

The module API lets Java modules run inside SynKinect Studio without changing the Studio source. Modules are entered from the Home screen and share the same top navigation shell.

A module implements `org.synkinect.studio.api.SynKinectStudioModule`, is packaged as a JAR and registers its implementation with Java `ServiceLoader` in:

```text
META-INF/services/org.synkinect.studio.api.SynKinectStudioModule
```

Copy the finished JAR to the `modules/` directory beside the packaged Studio runtime and start SynKinect Studio.

The host provides the selected Kinect, device enumeration, per-Kinect audio/control endpoints, camera/control/audio/SDK endpoints, saved metric-depth calibration, local transport access, Processing drawing access, locale, content size, per-module data storage, logging and managed worker threads through `StudioModuleContext`.

The locale reported by the host can be `en-US`, `pt-BR`, `es-ES`, `fr-FR`, `de-DE`, `it-IT`, `ja-JP` or `zh-CN`. `StudioModuleContext.dataDirectory()` returns a writable per-user directory owned by the module under the Studio application-data root. Packaged runtime files remain read-only.

Modules execute in the SynKinect Studio process with the same operating-system permissions as the Studio. Install modules only from sources you trust.

The API requires Java 17 or newer. The project build creates `SynKinectStudio-module-api.jar` for module compilation and runtime loading.


## Metric-depth calibration

`StudioModuleContext.depthCalibration()` returns the saved calibration for the currently selected Kinect. `depthCalibration(deviceId)` resolves a specific Studio-qualified device. A profile is represented by immutable `StudioDepthCalibration`; modules can inspect calibration quality, correct raw millimeter samples with `correctDepthMm(pixelIndex, rawMm)` and inspect calibrated per-pixel noise with `noiseMeters(pixelIndex)`. A return value of `null` means that no saved user calibration exists for that Kinect.

When Sensor Calibration saves or resets a profile, modules receive `StudioContextEvent.DEPTH_CALIBRATION_CHANGED`. Consumers that cache depth-derived geometry or registration state should reacquire the profile and invalidate those caches. This keeps calibration reusable by Scanner, interaction/tracking modules and third-party depth consumers without importing Scanner implementation classes.

## Multi-generation devices

`StudioDeviceInfo.id()` is the Studio-stable qualified identity (`<module-id>:<native-id>`). Use this value with context methods such as `audioEndpoint(deviceId)` and `audioControlEndpoint(deviceId)`. `nativeId()` is the identifier understood by the owning native module, while `moduleId()` identifies the driver module and `generation()` describes the Kinect generation (for example `xbox-360`). This keeps external modules instantiable when several Kinect generations expose overlapping native IDs.

Driver modules may also advertise `capabilities()` plus `colorWidth()/colorHeight()`, `depthWidth()/depthHeight()`, `infraredWidth()/infraredHeight()` and the corresponding maximum FPS values. Modules should size buffers and views from this metadata or from frame headers rather than assuming Xbox 360 dimensions. Generation-specific controls must be gated by `hasCapability(...)`.

Do not hard-code Xbox 360 pipe/socket names in a Studio module. Resolve `cameraEndpoint()`, `controlEndpoint()`, `audioEndpoint()`, `audioControlEndpoint()` and `sdkEndpoint()` from the selected device/context. Generation-specific behavior should be selected from `moduleId()`/`generation()` only when the required capability genuinely differs.

## Lifecycle and host-context rules

The current module API keeps module lifecycle policy generic. `contextChanged(StudioContextEvent)` receives locale, device-registry and selected-device changes; modules react to those events themselves instead of requiring host-side module exceptions. `closeBlockReason(localeTag)` can temporarily veto shutdown with a user-facing reason, and `mouseReleased(...)` completes the pointer lifecycle. Modules that do not need these hooks inherit safe no-op defaults. The host accepts only the current module API version.

Module identity is string-based and independent of navigation position. IDs are validated once by the registry and collisions are rejected against the modules that are actually registered; there is no hard-coded reserved-name list for built-ins. UI layout is also host-owned: declarative panels, metrics and buttons use shared maximum widths, spacing and responsive columns so new modules receive the same compact layout without per-module sizing rules.

For ordinary modules, no Processing front-end code is required. Implement `ui(localeTag)` and return a `StudioModuleUi` containing `StudioModulePanel`, `StudioModuleMetric` and `StudioModuleAction` objects. SynKinect Studio renders those objects with the same responsive blocks, panels, typography and buttons used by built-in modules, including localization-safe fitting, low-resolution layout and hit testing. Handle button presses in `action(actionId)`. `draw()` remains available only for specialized visualizations that genuinely need custom graphics.

`audioEndpoint(deviceId)` and `audioControlEndpoint(deviceId)` address the dedicated Remold audio transport for one physical Kinect using its qualified Studio device ID. The zero-argument forms resolve the currently selected Kinect. Without a selected physical Kinect, the endpoint is empty and the operation must fail explicitly.


## Reusable host processing boundary

Built-in Studio modules use host-owned processing blocks for RGB-D, Skeleton, Scanner reconstruction and spatial audio. Third-party JAR modules intentionally do not link against those internal Processing classes. They consume the stable public boundaries already exposed by `StudioModuleContext`: device capabilities, the selected device camera endpoint, control/audio/SDK endpoints, saved metric-depth calibration and managed workers/transports. This keeps a plugin instantiable across Windows/Linux and Kinect generations without freezing internal tracker or reconstruction class layouts into the public ABI.

## Body tracking

`StudioModuleContext.bodyTracking(deviceId)` (default method, API version 1) opens a host-owned depth + skeleton session and returns `StudioBodyTracking`, or `null` when unavailable. `subscribe(Consumer<StudioBodyFrame>)` delivers immutable frames on a host thread through a latest-only mailbox, so a slow module never stalls the tracker. `StudioBodyFrame.joints()` uses Kinect v1 20-joint names in Studio camera space; `humanoidBones()` gives Unity `HumanBodyBones` with local rotations in Unity space. The camera is used only while the module is active. Close the subscription and the session when done. Formats and conventions: [docs/MOTION-CAPTURE.md](../../docs/MOTION-CAPTURE.md).

## Module design rules

Treat each module provider as an independent runtime instance. Keep mutable state on the module instance, not in static globals. Acquire native transports, camera/audio sessions and managed workers from `StudioModuleContext`; open them during `setup()`/`activate()` and release them during `deactivate()`/shutdown. React to `StudioContextEvent` for locale and device changes instead of reading host implementation fields or assuming a navigation position.

Use stable string IDs for actions and state, keep localized presentation in `name(localeTag)`, `description(localeTag)` and `ui(localeTag)`, and let the host own standard panel/button/metric layout. Custom Processing drawing should be limited to visualizations that cannot be represented by the declarative UI model. This keeps a module portable across window sizes, languages and Windows/Linux hosts without host-side special cases.


## Cross-platform device state

`StudioDeviceInfo` exposes the driver-published lifecycle `state()` and `ready()` helper. Modules should use capabilities plus this runtime state and should not infer device health from `context.platform()`. Platform-specific code is reserved for genuine OS integration; Remold endpoints opened through `StudioModuleContext.openTransport()` have the same timeout/reconnect semantics on Windows and Linux.

The module API metadata value is `1`. It is compatibility metadata only and is not part of Studio titles or module display names.

## Backend-only modules

A backend that does not depend on Processing can implement `StudioBackend` rather
than `SynKinectStudioModule`. The host discovers backends via:

```text
META-INF/services/org.synkinect.studio.api.StudioBackend
```

Each provider must have a public no-argument constructor. The host constructs a
`StudioBackendAdapter`, supplies a restricted `StudioBackendContext`, and renders
its `StudioModuleUi` snapshots. This context exposes device discovery, transports,
body tracking, managed workers and module storage, but no `PApplet` or graphics
methods. Implementations own their state, implement lifecycle methods and release
resources in `close()`. Identity collisions with existing modules are rejected.
The backend runs inside the host process and is not a security sandbox.

This interface enables independent *new* backend plugins. Existing built-in
Scanner, Acoustic, Microphones, Surveillance, Interactivity and Motion capture
implementations still use Processing-global functions and host state. They are
not yet isolated backend implementations and cannot be instantiated concurrently
without further migration of their processing engines and UI adapters.

## Backend factories and instance lifecycle

For modules requiring guaranteed fresh backend instances, register a provider in
`META-INF/services/org.synkinect.studio.api.StudioBackendFactory`. Its `create()`
method must return a new `StudioBackend` for each registration. Avoid publishing
the same implementation both as a factory and as a direct `StudioBackend` provider.
The host rejects duplicate module identifiers. Adapters initialize once, activate
and deactivate idempotently, and release the backend on disposal.

The built-in Scanner, Acoustic, Microphones, Surveillance, Interactivity and Motion
capture screens still contain Processing-specific rendering and host state accesses.
They are not independent headless backends yet; their full extraction requires
separate processing engines and renderer-independent view models.
