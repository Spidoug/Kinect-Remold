# Packaged module data

Each Studio module owns only immutable packaged data here:

- `<module>/config/` — default configuration and registries.
- `<module>/resources/` — locale catalogs, icons and immutable UI resources.
- `<module>/models/` — optional model weights/manifests.

Runtime output, recordings, exports, logs, calibration profiles, recovery state and caches belong to the per-user application-data directory resolved by the Studio. A module does not need to create an empty category directory it does not use.
