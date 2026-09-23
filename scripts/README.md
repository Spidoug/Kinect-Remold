# Repository helper scripts

## Native drivers

- `windows/BUILD-DRIVER.cmd` — builds the current Windows native driver/runtime source.
- `linux/BUILD-DRIVER.sh` — builds the current Linux native driver/runtime source.
- `linux/INSTALL-DRIVER.sh` — installs the already-built Linux runtime offline; it never downloads or recompiles dependencies.

## SynKinect Studio

- `windows/BUILD-STUDIO.cmd` — bootstraps versioned Processing/JOGL/GlueGen dependencies, stages runtime templates and rebuilds the self-contained Java 17 Studio JAR.
- `windows/BUILD-APPLICATION-RUNTIME.cmd` — creates the minimized Windows Java runtime used by a portable application package.
- `windows/PACKAGE-APPLICATION.cmd` — packages the Windows application runtime.
- `linux/BUILD-STUDIO.sh` — bootstraps versioned dependencies and JDK 17+ when needed, rebuilds the Studio JAR, and creates the self-contained Linux Java runtime with `jlink`.

Native driver outputs and generated Studio payloads are build outputs and are not repository inputs.
