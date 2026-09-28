<div align="center">

# Linux Runtime

### Native per-device services, local IPC and installation boundary

[Documentation](../README.md) · [USB backend](USB-BACKEND.md) · [IP runtime](IP-CAMERA-RUNTIME.md)

</div>

The Linux runtime is built from `drivers/modules/kinect-xbox-360-remold/linux/source/` and published to `binaries/linux/drivers/kinect-xbox-360-remold/`.

The generated driver bundle uses `bin/`, `libexec/kinect360-remold/` and `support/`; installation maps those files into the normal system `/usr` and `/etc` locations.

Runtime services own physical Kinect transports and expose stable per-device application endpoints. Broker owns control and SDK discovery, CameraBridge owns 02AE and the internal device manifest, AudioBridge owns the 02AD firmware transition and native UAC capture, and the virtual-camera bridge consumes CameraBridge rather than reopening USB. `/run/kinect360-remold/devices.tsv` is an internal runtime manifest with:

`id, label, state, control, camera, audio, audio-control, virtual-camera, sdk, module-id, generation, capabilities, color-width, color-height, depth-width, depth-height, ir-width, ir-height, color-fps, depth-fps`.

Each Kinect receives its own camera socket, audio socket, audio-control socket and V4L2 virtual-camera assignment. The control ABI carries the same `deviceId`, so Tilt/LED/status operations cannot fall through to another connected sensor. LED behavior uses the same public API across 1414, 1473 and 1517: the public modes are `Off`, `Green`, `Red` and `BlinkGreen`, and a fresh camera/control session is initialized to solid green once. CameraBridge checks control availability with a device-scoped `Ping`; it does not poll accelerometer/motor status merely to keep the UI enabled. The raw-audio and audio-control sockets are stable per-device capabilities and remain published independently of the instantaneous native capture state. Model 1414 uses the Kinect v1 isochronous microphone transport directly; 1473/1517 use their UAC/ALSA runtime paths. Subscribers keep the same logical device identity while the native endpoint reconnects.

A transient USB re-enumeration moves the device to `Booting` or `Reconnecting`; stable logical audio endpoints stay associated with the same physical device while the native audio transport re-enumerates. Confirmed physical removal tears them down after the reconnect grace period.

Build with `bash Kinect-Remold.sh`; install the generated runtime with `sudo binaries/linux/drivers/kinect-xbox-360-remold/INSTALL.sh`. Linux uses script-only installation.


## Local IPC security

The root-owned hardware services keep direct USB ownership. Product-local UNIX sockets under `/run/kinect360-remold` are mode `0666`, so the already-running desktop session can use camera, audio, control and SDK endpoints immediately after installation instead of requiring a logout/login solely to refresh supplementary groups. These sockets expose only local Kinect runtime operations; the network-facing IP camera remains separately authenticated and sandboxed.

USB and V4L2 device nodes remain under normal Linux `video`/`audio` ownership with `uaccess` for the active desktop seat. The installer does not permanently alter the invoking user's supplementary groups; privileged hardware ownership stays in the services and interactive desktop access uses logind/udev `uaccess`. Core systemd services use `NoNewPrivileges` and filesystem/kernel hardening that does not hide the hardware device nodes they require. The optional IP-camera service has a stricter dedicated sandbox and runs as `kinect360-remold-ip`.

See [IP camera runtime](IP-CAMERA-RUNTIME.md) for its network/authentication boundary.


## Studio functional parity

SynKinect Studio uses the same Java/Processing frontend, module state machines and transport protocols on Windows and Linux. Platform differences are isolated below the module layer: Windows uses named pipes and native camera output, while Linux uses AF_UNIX sockets, V4L2, native libusb isochronous capture for 1414 audio and ALSA where the UAC path is appropriate. The Scanner, Surveillance, Interactivity/Body3D and Sensor Calibration modules consume the same RGB/depth/IR ABI on both systems. Microphones and Acoustic Scanner consume the same four-channel raw-audio ABI; Linux normalizes either the native 1414 isochronous stream or the supported UAC/ALSA path into that ABI, while Windows publishes the same ABI from WASAPI.

The Kinect One Linux SDK socket is mode `0666`, matching the product-local Xbox 360 IPC policy, so the already-running desktop user can connect immediately after installation without a logout/login. USB device nodes remain protected by udev/logind and are owned by the privileged runtime. The Kinect One stream server reads complete device-scoped subscription requests before parsing them, so AF_UNIX stream fragmentation cannot truncate the selected device ID.

Desktop maintenance terminals use the same module/action header on both operating systems. Linux supports `x-terminal-emulator`, GNOME Terminal, Konsole, MATE Terminal, KGX, Kitty, Alacritty and XTerm. Native folder selection uses Windows Shell on Windows and Zenity/KDialog on Linux.

Kinect v2 audio is not advertised by either platform backend until a native Remold audio endpoint exists for that generation. Therefore Microphones and Acoustic Scanner remain capability-disabled for Kinect v2 rather than silently using an unrelated host microphone.


### Interactivity desktop control

The Interactivity body tracker itself is compositor-independent because it consumes metric depth through the Remold transport. Desktop pointer injection uses Java AWT `Robot`; it is enabled only when the running Linux desktop/JVM permits global pointer control. X11 and XWayland sessions normally provide that path. A compositor that intentionally blocks synthetic global input can leave body tracking fully operational while desktop control is unavailable; the Studio reports that capability state instead of treating the sensor as failed.

## Quiet maintenance execution

`KINECT.sh` executes the complete offline installer and uninstaller with console output redirected to a persistent per-user maintenance log. The normal terminal shows only the operation, the resulting runtime status and success/failure. This is presentation-only: package verification, v4l2loopback validation, runtime replacement, policy/firmware installation, systemd/udev configuration, service startup and transport verification all still execute. Logs are stored below `${XDG_STATE_HOME:-~/.local/state}/Kinect Remold/logs/kinect-xbox-360-remold/`.
