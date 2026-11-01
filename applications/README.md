<div align="center">

# Applications

### SynKinect Studio, runtime launchers and extension SDK

[Project overview](../README.md) · [Documentation](../docs/README.md)

</div>

The application layer is intentionally separate from generation-specific driver code. SynKinect Studio discovers registered driver-module SDK endpoints, merges devices by `module-id + deviceId`, and enables features according to advertised capabilities.

| Area | Location | Purpose |
|---|---|---|
| SynKinect Studio | `processing/SynKinectStudio/` | Desktop application source, modules, localization and assets |
| Studio Module SDK | `studio-module-sdk/` | Public plugin lifecycle and host-context contract |
| Runtime templates | `runtime-templates/` | Generated launcher/runtime packaging templates |

Generated application binaries are published under `binaries/<platform>/applications/`, never back into this directory.

### Studio window identity

Auxiliary AWT/Swing windows opened by SynKinect Studio use the same packaged application icon as the main Studio window. Native folder/export dialogs are owned by an icon-bearing Studio window so their taskbar/title identity remains consistent with the application.
