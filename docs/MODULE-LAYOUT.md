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

## Driver modules

`drivers/modules/<generation>/` owns generation-specific code. Platform implementations remain below `windows/` and `linux/`; cross-platform definitions remain in `shared/`. Within a platform, `source/` owns buildable source and its platform packaging assets. Public names and build entry points are part of the current module contract.

Do not create a second copy of a resource merely to satisfy layout symmetry. A directory exists only when that module owns that resource class.
