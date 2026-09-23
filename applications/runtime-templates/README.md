# Runtime launcher templates

These files are source templates used by the Studio builders. Generated launchers, Java runtimes and JARs are published only beneath `binaries/<os>/applications/SynKinectStudio/`.

Windows uses `SynKinectStudio.vbs`/`javaw.exe` for windowless desktop startup. Linux uses `Terminal=false` in the desktop entry, detaches the Java process from the launcher TTY, verifies the initial Java process startup and writes launcher diagnostics to `logs/SynKinectStudio.log`.
