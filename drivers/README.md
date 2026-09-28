<div align="center">

# Driver Modules

### Generation-specific native runtimes behind one capability-driven Studio

[Project overview](../README.md) · [Architecture](../docs/ARCHITECTURE.md) · [Build](../docs/BUILD-DRIVERS.md)

</div>

**by Douglas Santana · @spidoug**

Each Kinect generation is isolated as a native driver module. A module owns its platform transports, installer, runtime services and public SDK endpoint; SynKinect Studio consumes stable device identities and advertised capabilities without importing module-private USB details.

| Module | Generation | Primary scope |
|---|---|---|
| `kinect-xbox-360-remold` | Xbox 360 / Kinect v1 | Models 1414 + 1473; RGB, IR, depth, four-channel audio, motion and LED |
| `kinect-one-remold` | Xbox One / Kinect v2 | Independent WinUSB/libusb transport; publishes only implemented capabilities |

Generated artifacts are isolated by module:

```text
binaries/windows/drivers/<module-id>/
binaries/windows/sdk/<module-id>/
binaries/linux/drivers/<module-id>/
binaries/linux/sdk/<module-id>/
```

Cross-generation behavior belongs in capability handling or a public SDK interface. The application layer must not depend on private runtime manifests, USB endpoint numbers or generation-specific service internals.
