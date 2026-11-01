<div align="center">

# Linux runtime

### Native per-device services, local IPC and installation boundary

[Documentation](../README.md) · [USB backend](USB-BACKEND.md) · [IP runtime](IP-CAMERA-RUNTIME.md)

</div>

The Linux runtime is built from `drivers/modules/kinect-xbox-360-remold/linux/source/` and published to `binaries/linux/drivers/kinect-xbox-360-remold/`.

The generated driver bundle uses `bin/`, `libexec/kinect360-remold/` and `support/`; installation maps those files into the normal system `/usr` and `/etc` locations.

Runtime services own physical Kinect transports and expose stable per-device application endpoints. Broker owns control and SDK discovery, CameraBridge owns 02AE and the internal device manifest, AudioBridge owns the 02AD firmware transition and native UAC capture, and the virtual-camera bridge consumes CameraBridge rather than reopening USB. `/run/kinect360-remold/devices.tsv` is an internal runtime manifest with:

`id, label, state, control, camera, audio, audio-control, virtual-camera, sdk, module-id, generation, capabilities, color-width, color-height, depth-width, depth-height, ir-width, ir-height, color-fps, depth-fps`.

Each Kinect receives its own camera socket, audio socket, audio-control socket and V4L2 virtual-camera assignment. The control ABI carries the same `deviceId`, so Tilt/LED/status operations cannot fall through to another connected sensor. LED behavior uses the same public API across 1414, 1473 and 1517: the public modes are `Off`, `Green`, `Red` and `BlinkGreen`, and a fresh camera/control session is initialized to solid green once. CameraBridge checks control availability with a device-scoped `Ping`; it does not poll accelerometer/motor status merely to keep the UI enabled. The raw-audio and audio-control sockets are stable per-device capabilities and remain published independently of the instantaneous native capture state. All three models are captured through `snd-usb-audio` / ALSA: 1414 and 1473 after the UAC firmware upload (`02BB/02C3`), 1517 through its factory `02BE` function. All three are republished to Linux applications through the product-owned KinectRemold ALSA capture card, so Remold internal capture and the operating-system microphone endpoint coexist. Subscribers keep the same logical device identity while the native endpoint reconnects.

A transient USB re-enumeration moves the device to `Booting` or `Reconnecting`; stable logical audio endpoints stay associated with the same physical device while the native audio transport re-enumerates. Confirmed physical removal tears them down after the reconnect grace period.

Build with `./Kinect-Remold.sh`; install the generated runtime with `sudo binaries/linux/drivers/kinect-xbox-360-remold/INSTALL.sh`. Linux uses script-only installation.


## Local IPC security

The root-owned hardware services keep direct USB ownership. Product-local UNIX sockets under `/run/kinect360-remold` are mode `0666`, so the already-running desktop session can use camera, audio, control and SDK endpoints immediately after installation instead of requiring a logout/login solely to refresh supplementary groups. These sockets expose only local Kinect runtime operations; the network-facing IP camera remains separately authenticated and sandboxed.

USB and V4L2 device nodes remain under normal Linux `video`/`audio` ownership with `uaccess` for the active desktop seat. The installer does not permanently alter the invoking user's supplementary groups; privileged hardware ownership stays in the services and interactive desktop access uses logind/udev `uaccess`. Core systemd services use `NoNewPrivileges` and filesystem/kernel hardening that does not hide the hardware device nodes they require. The optional IP-camera service has a stricter dedicated sandbox and runs as `kinect360-remold-ip`.

See [IP camera runtime](IP-CAMERA-RUNTIME.md) for its network/authentication boundary.


## Studio functional parity

SynKinect Studio uses the same Java/Processing frontend, module state machines and transport protocols on Windows and Linux. Platform differences are isolated below the module layer: Windows uses named pipes and native camera output, while Linux uses AF_UNIX sockets and V4L2; audio uses the kernel `snd-usb-audio` / ALSA path for all three first-generation models. The Scanner, Surveillance, Interactivity, Motion Capture and Sensor Calibration modules consume the same RGB/depth/IR ABI on both systems. Microphones and Acoustic Scanner consume the same four-channel raw-audio ABI; Linux resamples the ALSA capture to that ABI with the same anti-alias FIR used by Windows, which publishes it from WASAPI.

The Kinect One Linux SDK socket is mode `0666`, matching the product-local Xbox 360 IPC policy, so the already-running desktop user can connect immediately after installation without a logout/login. USB device nodes remain protected by udev/logind and are owned by the privileged runtime. The Kinect One stream server reads complete device-scoped subscription requests before parsing them, so AF_UNIX stream fragmentation cannot truncate the selected device ID.

Desktop maintenance terminals use the same module/action header on both operating systems. Linux supports `x-terminal-emulator`, GNOME Terminal, Konsole, MATE Terminal, KGX, Kitty, Alacritty and XTerm. Native folder selection uses Windows Shell on Windows and Zenity/KDialog on Linux.

Kinect v2 audio is not advertised by either platform backend until a native Remold audio endpoint exists for that generation. Therefore Microphones and Acoustic Scanner remain capability-disabled for Kinect v2 rather than silently using an unrelated host microphone.


### Interactivity desktop control

The Interactivity body tracker itself is compositor-independent because it consumes metric depth through the Remold transport. Desktop pointer injection uses Java AWT `Robot`; it is enabled only when the running Linux desktop/JVM permits global pointer control. X11 and XWayland sessions normally provide that path. A compositor that intentionally blocks synthetic global input can leave body tracking fully operational while desktop control is unavailable; the Studio reports that capability state instead of treating the sensor as failed.

## Quiet maintenance execution

`KINECT.sh` executes the complete offline installer and uninstaller with console output redirected to a persistent per-user maintenance log. The normal terminal shows only the operation, the resulting runtime status and success/failure. This is presentation-only: package verification, v4l2loopback validation, runtime replacement, policy/firmware installation, systemd/udev configuration, service startup and transport verification all still execute. Logs are stored below `${XDG_STATE_HOME:-~/.local/state}/Kinect Remold/logs/kinect-xbox-360-remold/`.

## Audio ownership and READY state

The Linux AudioBridge is the sole product-level owner of Kinect microphone capture. All three models use the kernel `snd-usb-audio` / ALSA capture path: 1414 and 1473 after the UAC firmware upload re-enumerates them as `02BB/02C3`, 1517 through its factory `02BE` function. No kernel driver is detached, so the 1473 `MI_00` motor/LED/accelerometer interface stays attached to Broker. The native rate (usually 48 kHz) is converted to 16 kHz by a Blackman-windowed sinc anti-alias low-pass. Kinect sound nodes remain marked with `ACP_IGNORE=1` and `PULSE_IGNORE=1` so desktop sound servers do not compete with the product runtime when ALSA is used.

`audio-bridge-status.txt` distinguishes the native capture format from the Remold application stream. `capture_sample_rate` / `capture_channels` describe the hardware side, while `stream_sample_rate=16000` describes the normalized public ABI. `active_capture_sessions` is balanced once per live capture session, and `frame_age_ms` proves that published PCM is recent. The maintenance UI reports **READY** only when the bridge is actively capturing four microphone channels, the public stream is 16 kHz, at least one frame has been published, the latest frame is recent, and the `KinectRemold` system-audio publisher has emitted packets. A resident socket without live PCM remains **PENDING**, and a connected Kinect in that state fails install/status verification rather than being reported as operational.

### System microphone endpoint

The Linux AudioBridge owns the native Kinect microphone source so connection order cannot make the first sensor permanently busy. It simultaneously feeds a product-owned `snd-aloop` card identified as `KinectRemold`. Desktop sound servers and ordinary ALSA clients record from device 1 of that card, while AudioBridge writes to the paired device 0 substream. Up to eight substreams are available and are assigned deterministically from the physical Kinect identity. This mirrors the Windows behavior at the contract level: installing the driver leaves a microphone endpoint available to the operating system while SynKinect Studio continues to receive its four-channel internal bus.
