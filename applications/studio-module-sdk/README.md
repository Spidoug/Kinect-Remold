# SynKinect Studio Module API

**Software version:** 1

The module API lets Java modules run as SynKinect Studio tabs without changing the Studio source.

A module implements `org.synkinect.studio.api.SynKinectStudioModule`, is packaged as a JAR and registers its implementation with Java `ServiceLoader` in:

```text
META-INF/services/org.synkinect.studio.api.SynKinectStudioModule
```

Copy the finished JAR to the `modules/` directory beside the packaged Studio runtime and start SynKinect Studio.

The host provides the selected Kinect, device enumeration, camera/audio/control/NUI/SDK endpoints, local transport access, Processing drawing access, locale, content size, per-module data storage, logging and managed worker threads through `StudioModuleContext`.

Modules execute in the SynKinect Studio process with the same operating-system permissions as the Studio. Install modules only from sources you trust.

The API requires Java 17 or newer. The project build creates `SynKinectStudio-module-api.jar` for module compilation and runtime loading.

