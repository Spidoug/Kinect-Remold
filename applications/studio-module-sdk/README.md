# SynKinect Studio Module API

**Software version:** 1

The module API lets Java modules run inside SynKinect Studio without changing the Studio source. Modules are entered from the Home screen and share the same top navigation shell.

A module implements `org.synkinect.studio.api.SynKinectStudioModule`, is packaged as a JAR and registers its implementation with Java `ServiceLoader` in:

```text
META-INF/services/org.synkinect.studio.api.SynKinectStudioModule
```

Copy the finished JAR to the `modules/` directory beside the packaged Studio runtime and start SynKinect Studio.

The host provides the selected Kinect, device enumeration, per-Kinect audio/control endpoints, camera/control/NUI/SDK endpoints, local transport access, Processing drawing access, locale, content size, per-module data storage, logging and managed worker threads through `StudioModuleContext`.

The locale reported by the host can be `en-US`, `pt-BR`, `es-ES`, `fr-FR`, `de-DE`, `it-IT`, `ja-JP` or `zh-CN`. `StudioModuleContext.dataDirectory()` returns the module-owned directory inside the Studio program tree at `data/modules/<module-id>/output/`.

Modules execute in the SynKinect Studio process with the same operating-system permissions as the Studio. Install modules only from sources you trust.

The API requires Java 17 or newer. The project build creates `SynKinectStudio-module-api.jar` for module compilation and runtime loading.

## Lifecycle and host-context rules

The current module API keeps module lifecycle policy generic. `contextChanged(StudioContextEvent)` receives locale, device-registry and selected-device changes; modules react to those events themselves instead of requiring host-side module exceptions. `closeBlockReason(localeTag)` can temporarily veto shutdown with a user-facing reason, and `mouseReleased(...)` completes the pointer lifecycle. Modules that do not need these hooks inherit safe no-op defaults. The host accepts only the current module API contract.

Module identity is string-based and independent of navigation position. IDs are validated once by the registry and collisions are rejected against the modules that are actually registered; there is no hard-coded reserved-name list for built-ins. UI layout is also host-owned: declarative panels, metrics and buttons use shared maximum widths, spacing and responsive columns so new modules receive the same compact layout without per-module sizing rules.

For ordinary modules, no Processing front-end code is required. Implement `ui(localeTag)` and return a `StudioModuleUi` containing `StudioModulePanel`, `StudioModuleMetric` and `StudioModuleAction` objects. SynKinect Studio renders those objects with the same responsive blocks, panels, typography and buttons used by built-in modules, including localization-safe fitting, low-resolution layout and hit testing. Handle button presses in `action(actionId)`. `draw()` remains available only for specialized visualizations that genuinely need custom graphics.

`audioEndpoint(deviceId)` and `audioControlEndpoint(deviceId)` address the dedicated Remold audio transport for one physical Kinect. The zero-argument forms resolve the currently selected Kinect. Without a selected physical Kinect, the endpoint is empty and the operation must fail explicitly.

