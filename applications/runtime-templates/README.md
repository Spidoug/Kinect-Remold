# Runtime launcher templates

These files are source templates used by the Studio builders. Generated application images, Java runtimes and JARs are published only beneath `binaries/<os>/applications/SynKinectStudio/`.

Windows is packaged as a native `SynKinectStudio.exe` application image with its Java runtime embedded by `jpackage`; no script or VBScript application launcher is shipped. Linux uses one `SynKinectStudio.sh` runtime entry point and one `.desktop` file for desktop-shell integration. The Linux runtime always uses the Java image bundled with the Studio.
