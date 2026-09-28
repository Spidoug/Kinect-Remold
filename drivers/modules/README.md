<div align="center">

# Kinect Remold Driver Modules

### Native runtime ownership organized by Kinect generation

[Drivers](../README.md) · [Architecture](../../docs/ARCHITECTURE.md) · [Build](../../docs/BUILD-DRIVERS.md)

</div>

Each directory under this tree is one independently buildable Kinect-generation module. Module IDs are stable machine-readable identifiers used by SynKinect Studio device discovery.

Current modules:

- `kinect-xbox-360-remold` (`generation=xbox-360`)
- `kinect-one-remold` (`generation=xbox-one`)

Each module owns its native USB/runtime implementation and publishes the same Studio discovery interface.
