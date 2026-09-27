<div align="center">

# Build

### Reproducible native runtimes and SynKinect Studio from a clean source tree

[Documentation](README.md) · [Quick start](QUICKSTART.md) · [Installation](INSTALLATION.md)

</div>

The repository keeps generated binaries, downloaded toolchains and temporary build work outside the authored source tree. Platform launchers detect missing outputs, prepare dependencies, build native modules and then build SynKinect Studio as a separate stage.

## Windows

Run:

```bat
Kinect-Remold.cmd
```

The Windows pipeline detects Visual Studio C++, the Windows SDK/WDK and required build tools; builds each driver module; validates INF/catalog generation; signs development packages where configured; publishes SDK/runtime outputs under `binaries\windows\`; and then builds SynKinect Studio.

A driver build and a Studio build are independent success boundaries. If the native runtime succeeds but `javac` fails, the driver package remains a separate artifact and the overall launcher correctly reports failure for the complete product build.

Generated paths:

```text
binaries\windows\drivers\<module-id>\
binaries\windows\sdk\<module-id>\
binaries\windows\applications\SynKinectStudio\
```

## Linux

Run:

```bash
bash Kinect-Remold.sh
```

The Linux build resolves required development packages, prepares the verified Kinect UAC firmware input, builds the native runtime and kernel-specific virtual-camera dependency, publishes generated driver/SDK outputs, and builds the Studio launcher/runtime bundle. Installation is performed later by the generated `INSTALL.sh` and does not repeat build-time downloads or compilation.

Generated paths:

```text
binaries/linux/drivers/<module-id>/
binaries/linux/sdk/<module-id>/
binaries/linux/applications/SynKinectStudio/
```

## Build isolation

Authored source remains under `applications/`, `drivers/`, `scripts/` and `docs/`. Generated outputs go to `binaries/`; caches, downloads, intermediate objects and logs use operating-system user work/cache locations.

This separation is intentional: a clean source archive should not need to contain downloaded Microsoft packages, extracted firmware, compiler outputs or generated driver catalogs.

## Kinect One Remold

`kinect-one-remold` is built as its own module and publishes its own runtime/SDK paths. It shares the generation-neutral Studio discovery contract but not the Xbox 360 USB implementation.

## Clean-build preflight

Before treating a build as releasable, verify all of the following:

- native module compile/link completes;
- INF validation and catalog generation complete where applicable;
- generated package signing state is explicit;
- expected `binaries/` outputs are present;
- Studio compilation and runtime generation complete independently;
- no generated binary or downloaded dependency has leaked back into authored source directories.

Build results belong in the generated platform logs, not in the architecture documents. Keep the documentation focused on reproducible commands, expected outputs and stable runtime behavior.
