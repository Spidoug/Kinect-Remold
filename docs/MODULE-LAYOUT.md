<div align="center">

# Module Layout

### Where driver generations, Studio modules and generated artifacts belong

[Documentation](README.md) · [Architecture](ARCHITECTURE.md) · [Build](BUILD-DRIVERS.md)

</div>

The project uses a predictable ownership layout.

## Studio modules

`applications/processing/SynKinectStudio/data/<module>/` may contain:

- `config/` — packaged defaults and module registry/configuration.
- `resources/` — localized strings, icons and immutable UI assets.
- `models/` — optional model weights and model manifests.

Mutable recordings, exports, calibration profiles, plugin output, recovery files and caches belong to the per-user application data directory, not the packaged module tree.

Shared processing belongs in instantiable blocks, not frontend modules. `ProcessingBlocks.pde` is the construction boundary for common RGB-D, Skeleton and spatial-audio sessions; `Skeleton.pde`, `SpatialAudio.pde` and the Scanner processing classes own their algorithms. Frontends such as Interactivity call these blocks and keep only module-specific interaction/presentation logic. A new built-in module should reuse an existing block whenever its input/output contract matches instead of copying the algorithm into its UI file.

## Driver modules

`drivers/modules/<generation>/` owns generation-specific code. Platform implementations remain below `windows/` and `linux/`; cross-platform definitions remain in `shared/`. Within a platform, `source/` owns buildable source and its platform packaging assets. Public names and build entry points are part of the current module contract.

Do not create a second copy of a resource merely to satisfy layout symmetry. A directory exists only when that module owns that resource class.
