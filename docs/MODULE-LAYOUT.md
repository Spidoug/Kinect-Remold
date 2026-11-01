<div align="center">

# Module layout

### Where driver generations, Studio modules and generated artifacts belong

[Documentation](README.md) · [Architecture](ARCHITECTURE.md) · [Build](BUILD-DRIVERS.md)

</div>

The project uses a predictable ownership layout.

## Frontend / backend rule

- The **Studio shell** (`SynKinectStudio.pde`) and **`StudioUi.pde`** provide the frontend: navigation, Home cards, device selector, language, lifecycle, layout, typography, native dialogs and instantiable UI blocks (`StudioUiPanel`, `StudioUiButton`, `StudioUiMetric`, `StudioUiRenderer`, `StudioPluginAutoView`). `StudioPalette` is the single colour palette; each module `*Theme` class extends it and adds only module-specific colours.
- Each **module**, built-in or external JAR, provides its backend (state, commands, sinks, recorders) and composes the host UI blocks. External JARs use the declarative `StudioModuleUi` from the Module API.
- **Shared processing** lives in blocks created through `StudioProcessingBlocks` (`ProcessingBlocks.pde`): RGB-D acquisition with depth calibration, SynSkeleton / body tracking, Scanner reconstruction and spatial audio. A new module reuses a block whenever its input/output contract matches instead of copying the algorithm into its UI file.

See [Architecture](ARCHITECTURE.md#studio-frontend--backend-rule) for the block table.

## Studio source layout

`applications/processing/SynKinectStudio/`:

| Group | Files | Contents |
|---|---|---|
| Shell and frontend | `SynKinectStudio.pde`, `StudioUi.pde`, `Modules.pde`, `ViewportStabilizer.pde` | `StudioController`, `StudioServices`, device registry, built-in and JAR module registry, UI blocks, `StudioPalette`, presentation-only viewport filter |
| Processing-block factory | `ProcessingBlocks.pde` | `StudioProcessingBlocks`, `ScannerProcessingSession` |
| Shared RGB-D core | `CoreConfig.pde` (`AppConfig`), `CoreMath3D.pde`, `CorePointCloud.pde`, `RgbdCore.pde` (`RgbdSession`, frame types), `RgbdTransport.pde` (`KinectSource`), `RgbdProtocol.pde` (`ScannerProtocol`, RGB HQ processing), `RgbdRegistration.pde`, `DepthCalibration.pde` | Transport, frame decode, calibration, registration and per-device depth correction (`DepthCorrectionSolver`, profile v3) |
| Body tracking | `SynSkeletonOnnx.pde` (ONNX inference), `Skeleton.pde` (`SkeletonLibrary`, canonical pose types/session), `BodyTracking.pde` (`BodyTrackingSession`, `BodyFrame`, `BodySkeletonPreview`) | SynSkeleton model and the reusable body-tracking block |
| Spatial audio | `SpatialAudio.pde` | Per-device audio session, localization, beamforming, noise suppression, voice enhancement |
| 3D Scanner | `Scanner.pde`, `ScannerUI.pde`, `ScannerIcp.pde`, `ScannerMesh.pde`, `ScannerExport.pde`, `ScannerCoverage.pde`, `ScannerDepthDetection.pde`, `ScannerReconstruction.pde`, `MarchingCubes.pde` | Scanner-only module code |
| Interactivity | `Interactivity.pde` (desktop controller, presentation), `InteractionControl.pde` (hands, filters, air keyboard) | Desktop input over body tracking |
| Motion Capture | `MotionCapture.pde`, `MocapRetarget.pde`, `MocapSinks.pde` | Retargeting, VMC / OSC / JSON / WebSocket sinks, BVH recorder |
| Audio modules | `Acoustic.pde`, `Microphones.pde` | Acoustic Scanner and Microphones |
| Surveillance | `Surveillance.pde` | Multi-camera RGB/IR monitoring and recording |
| Calibration window | `SensorCalibrationWindow.pde` | Standalone Sensor Calibration frontend |

## Studio module data

`applications/processing/SynKinectStudio/data/<module>/` may contain:

- `config/` — packaged defaults and module registry/configuration.
- `resources/` — localized strings, icons and immutable UI assets.
- `models/` — optional model weights and model manifests (no current module ships one).

Current directories: `studio`, `scanner`, `acoustic`, `microphones`, `surveillance`, `interactivity`, `mocap`, `skeleton` (config only) and `spatial-audio` (config only).

Mutable recordings, exports, calibration profiles, plugin output, recovery files and caches belong to the per-user application data directory, not the packaged module tree.

## Driver modules

`drivers/modules/<module-id>/` owns generation-specific code. Platform implementations remain below `windows/` and `linux/`; cross-platform definitions remain in `shared/`. Within a platform, `source/` owns buildable source and its platform packaging assets. Public names and build entry points are part of the current module contract.

Do not create a second copy of a resource merely to satisfy layout symmetry. A directory exists only when that module owns that resource class.

Backend-only third-party modules register `StudioBackend` through Java ServiceLoader. The host renders their snapshots using the shared front-end. Built-in modules still require extraction of their Processing-bound engines before they can support independent concurrent instances.
