# Repository helper scripts

## Native drivers

- `windows/BUILD-DRIVER.cmd` — builds the current Windows native driver/runtime source.
- `linux/BUILD-DRIVER.sh` — builds the current Linux native driver/runtime source.
- `linux/INSTALL-DRIVER.sh` — installs the already-built Linux runtime offline; it never downloads or recompiles dependencies.

## SynKinect Studio

- `windows/BUILD-STUDIO.cmd` — bootstraps pinned Processing/JOGL/GlueGen dependencies, builds the Studio JAR, creates the bundled Java runtime and packages the native Windows application image.
- `windows/PACKAGE-APPLICATION.cmd` — packages the generated native Windows application image.
- `linux/BUILD-STUDIO.sh` — bootstraps pinned dependencies and JDK 17+ when needed, rebuilds the Studio JAR, and creates the self-contained Linux Java runtime with `jlink`.

Native driver outputs and generated Studio payloads are build outputs and are not repository inputs.

## Launcher path policy

Top-level and platform build entry points resolve paths relative to their own script location rather than the caller's working directory. Windows `.cmd` files remain ASCII/CRLF-safe; Linux `.sh` files are distributed executable and use script-root discovery that tolerates symlinks, spaces and wrapper directories introduced by repeated archive extraction.
