# Linux driver/runtime

The Linux runtime is built from `drivers/linux/source/` and published to `binaries/linux/drivers/`.

The generated driver bundle uses `bin/`, `libexec/kinect360-remold/` and `support/`; installation maps those files into the normal system `/usr` and `/etc` locations.

Runtime services own physical Kinect transports and expose stable per-device application endpoints. Broker owns control and SDK discovery, CameraBridge owns 02AE and the internal device manifest, AudioBridge owns the 02AD firmware transition and native UAC capture, and the virtual-camera bridge consumes CameraBridge rather than reopening USB. `/run/kinect360-remold/devices.tsv` is an internal runtime manifest with:

`id, label, state, control, camera, audio, audio-control, virtual-camera, sdk`.

Each Kinect receives its own camera socket, audio socket, audio-control socket and V4L2 virtual-camera assignment. The control ABI carries the same `deviceId`, so Tilt/LED/status operations cannot fall through to another connected sensor. CameraBridge checks control availability with a device-scoped `Ping`; it does not poll accelerometer/motor status merely to keep the UI enabled. The raw-audio and audio-control sockets are stable per-device capabilities and remain published independently of the instantaneous ALSA capture state. Subscribers keep the same logical device identity while the native endpoint reconnects.

A transient USB re-enumeration moves the device to `Booting` or `Reconnecting`; stable logical audio endpoints stay associated with the same physical device while ALSA capture re-enumerates. Confirmed physical removal tears them down after the reconnect grace period.

Build with `bash Kinect-Xbox-360-Remold.sh`; install the generated runtime with `sudo binaries/linux/drivers/INSTALL.sh`. Linux uses script-only installation.


## Local IPC security

The root-owned hardware services keep direct USB ownership. Product-local UNIX sockets under `/run/kinect360-remold` are mode `0666`, so the already-running desktop session can use camera, audio, control and SDK endpoints immediately after installation instead of requiring a logout/login solely to refresh supplementary groups. These sockets expose only local Kinect runtime operations; the network-facing IP camera remains separately authenticated and sandboxed.

USB and V4L2 device nodes remain under normal Linux `video`/`audio` ownership with `uaccess` for the active desktop seat. The installer does not permanently alter the invoking user's supplementary groups; privileged hardware ownership stays in the services and interactive desktop access uses logind/udev `uaccess`. Core systemd services use `NoNewPrivileges` and filesystem/kernel hardening that does not hide the hardware device nodes they require. The optional IP-camera service has a stricter dedicated sandbox and runs as `kinect360-remold-ip`.

See [IP camera runtime](IP-CAMERA-RUNTIME.md) for its network/authentication boundary.
