# Runtime and build configuration

Machine- and installation-dependent values are not embedded in the launchers or Linux runtime sources. Build dependency metadata lives in `build.env`; Linux account/group integration metadata lives in `linux.env`. Every `REMOLD_*` value can be overridden by the process environment.

Linux paths are resolved at runtime by `scripts/linux/lib/remold-env.sh` from the host environment and system APIs (`HOME`/XDG, `systemd-path`, `pkg-config`, `findmnt`, `modinfo`, and executable discovery). Explicit `REMOLD_*` path variables take precedence. Generated service units, udev rules and SDK headers are rendered from the resolved paths during build/install.

Hardware/protocol constants such as USB IDs, endpoint geometry, packet layouts, register values, ABI magic values and image dimensions remain constants because they describe the Kinect protocol rather than a specific computer or account.
