# Packaged module data

Each Studio module owns only immutable packaged data here:

- `<module>/config/` — default configuration and registries.
- `<module>/resources/` — locale catalogs, icons and immutable UI resources.
- `<module>/models/` — optional model weights/manifests.

Runtime output, recordings, exports, logs, calibration profiles, recovery state and caches belong to the per-user application-data directory resolved by the Studio. A module does not need to create an empty category directory it does not use.

## Current module data

| Directory | Contents |
|---|---|
| `studio/` | Shell configuration (`config.properties`, including `studio.modules.enabled`), driver-module registry (`driver-modules.properties`), locales, icon |
| `scanner/` | Scanner, RGB-D core and depth-calibration configuration; locales |
| `acoustic/`, `microphones/`, `surveillance/`, `interactivity/`, `mocap/` | Module configuration (where needed) and locales |
| `skeleton/` | `SynSkeleton.onnx`, model layout metadata and SynSkeleton configuration |
| `spatial-audio/` | Shared spatial-audio configuration only |

SynSkeleton loads `skeleton/SynSkeleton.onnx` at runtime. The trained model is the authoritative body/hand/finger pose source; if it is absent, Studio publishes no skeleton instead of selecting another pose solver.

