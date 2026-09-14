# Kinect Xbox 360 Remold — Linux V1 source

This directory contains the Linux-native user-space runtime for Kinect for Xbox 360 models 1414/1473. Kinect protocol and function ownership stay in user space; Linux provides usbfs/udev, libusb-1.0, USB Audio/ALSA, V4L2 and systemd facilities. Kinect vendor USB camera/control/firmware-boot functions are accessed through libusb-1.0; there is no Remold-specific kernel USB driver.

## Camera and Depth

`kinect360-remold-camera` exclusively owns the camera function. Endpoint `0x81` carries RGB/RGB-HQ/IR and endpoint `0x82` carries Depth. Transfer buffers use each endpoint's negotiated libusb ISO capacity while the parser preserves the Kinect logical framing. RGB and IR remain mutually exclusive; Depth can run concurrently. The camera service never resets the audio/control runtime as part of normal recovery.

## Audio

`kinect360-remold-audio` uses the Kinect v1 audio startup sequence shared by both platforms. Only the dedicated `045e:02ad` one-interface bulk identity is a bootloader; it receives Microsoft UACFirmware 01.02.709.00 with the Kinect command/tag/page/chunk/launch protocol. After re-enumeration, `02BB/02C3` USB Audio is captured through ALSA at four channels, 16 kHz, S32_LE. Composite runtime interfaces are never reset or treated as bootloaders.

The runtime uses Microsoft Kinect for Windows Runtime v1.8 UACFirmware 01.02.709.00. Firmware acquisition is a build stage, not an install-time recovery step: the build downloads `KinectRuntime-v1.8-Setup.exe`, validates its pinned SHA-256, extracts `UACFirmware 01.02.709.00`, validates SHA-256 `4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9`, generates `Kinect360RemoldAudioFirmware.generated.h`, and compiles the firmware into `kinect360-remold-audio`. The source ZIP does not redistribute Microsoft's firmware bytes.

## NUI-style compatibility

`kinect360-remold-nui` exposes runtime discovery at `/run/kinect360-remold/nui.sock` and a versioned 20-joint skeleton relay at `/run/kinect360-remold/nui-skeleton.sock`. The topology follows Kinect-v1 NUI joint ordering and retains legs even though Studio desktop interaction is intentionally upper-body gated. This is a Remold compatibility ABI, not Microsoft's proprietary binary runtime.

## Plug and play

udev recognizes Kinect USB identities and requests `kinect360-remold.target`. The target is not enabled unconditionally. Services remain alive and retry their own function after disconnect/reconnect. The camera service publishes `/run/kinect360-remold/devices.tsv` and one Unix socket per physical camera.

## Build / install

```bash
bash BUILD.sh --clean
bash BUILD.sh
sudo bash INSTALL.sh --direct
```

`BUILD.sh` owns build dependency/tool acquisition and firmware extraction. `INSTALL.sh` installs only the already-built `dist/<arch>` payload plus runtime dependencies; it does not compile source as root. The interactive `KINECT.sh` performs the build automatically when the distribution is absent, then elevates only for installation. During install the connected sensor is classified as 1414, 1473, mixed, or absent. Model 1414 uses direct 02B0 user-space control; model 1473 keeps 02C2 on the inbox hub stack, claims only runtime control MI_00, and leaves MI_02 on `snd-usb-audio`.

Build dependencies: CMake, a C++17 compiler, pkg-config, libusb-1.0 >= 1.0.18 development headers, ALSA development headers, libjpeg development headers, cabextract/msitools, Python 3 and CA certificates. Runtime installation does not require those development tools. `drivers/linux/BUILD.sh` records a timestamped log and keeps an interactive terminal open at the end; pass `--no-pause` for automation.

Debian packages: `bash packages/build-deb.sh amd64`. RPM packages: `packages/build-rpm.sh` on an RPM build host. Both package paths compile current source and do not consume a repository binary payload.
