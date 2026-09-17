# Linux driver/runtime

## Scope

The Linux implementation is a user-space Kinect 1414/1473 driver/runtime. It does not install a Remold-authored kernel USB driver. Generic Linux facilities provide usbfs/udev, USB Audio/ALSA, V4L2 and service infrastructure; libusb-1.0 is the user-space API for Kinect vendor USB functions. Remold owns the Kinect protocol, stream policy, IPC and service lifecycle and installs no Kinect-specific kernel USB driver.

## Native components

| Binary | Responsibility |
| --- | --- |
| `kinect360-remold-broker` | motor, tilt, LED and accelerometer/status control |
| `kinect360-remold-camera` | direct libusb RGB/IR/depth acquisition + ScannerPort |
| `kinect360-remold-audio` | 02AD UACFirmware boot over libusb-1.0 + post-firmware 02BB/02C3 USB Audio capture through ALSA |
| `kinect360-remold-nui` | NUI-style endpoint discovery + canonical 20-joint skeleton relay |
| `kinect360-remold-v4l2` | V4L2 loopback RGB webcam publication |
| `kinect360-remold-camera-ip` | authenticated HTTP/MJPEG RGB service |
| `kinect360-remoldctl` | status/tilt/LED and NUI endpoint diagnostics |

## Build, install and plug-and-play lifecycle

Linux native executables are generated from the current source and installed by the project scripts. Build and install with:

```bash
bash drivers/linux/BUILD.sh
sudo bash drivers/linux/INSTALL.sh --direct
```

udev recognizes the Kinect USB identities and requests `kinect360-remold.target`. The target is not enabled as an unconditional boot target. Each service keeps retrying only its own hardware function after disconnect/reconnect.

## IPC and NUI-style compatibility

```text
/run/kinect360-remold/control.sock
/run/kinect360-remold/devices.tsv
/run/kinect360-remold/devices/<device-id>.sock
/run/kinect360-remold/audio.sock
/run/kinect360-remold/audio-control.sock
/run/kinect360-remold/audio-bridge-status.txt
/run/kinect360-remold/nui.sock
/run/kinect360-remold/nui-skeleton.sock
```

`nui.sock` returns the active camera, audio, control and skeleton endpoint paths plus capabilities. `nui-skeleton.sock` carries a versioned 20-joint Kinect-v1 topology, tracking ID/state and per-joint XYZ/confidence/state, with ABI space for up to six bodies. This is a Remold compatibility interface using NUI semantics; it is not the proprietary Microsoft Kinect SDK/runtime ABI.

Use `kinect360-remoldctl nui` to inspect the advertised endpoints and `kinect360-remoldctl backend` to confirm the Linux transport model (`libusb-1.0` over usbfs/udev, plus ALSA for UAC audio).

## Camera ownership and frame delivery

The camera service owns only the physical camera USB function (`045e:02ae` or the supported Kinect-for-Windows-v1 identity). Camera startup is independent from the audio service. To match the Windows sequence on model 1473, the camera service performs the same **bounded, best-effort** control-broker `PrepareCamera` handshake before opening the physical stream: at most 20 attempts spaced 250 ms apart. Failure to obtain the handshake does not turn camera startup into an unbounded dependency. Model 1414 opens the dedicated camera/control topology directly.

RGB/IR endpoint `0x81` and Depth endpoint `0x82` use asynchronous libusb ISO transfer rings. Their lifetime follows the same session model on both platforms: a ring is registered once for the physical camera session and is preserved across normal module handoffs. Changing RGB/IR/HQ stops the video engine, cancels/rearms the existing `0x81` ring and starts the selected mode instead of destroying/recreating the USB stream. After the first Depth request, `0x82` stays registered until the physical camera session ends; register `0x06` only gates projector demand. Mode rearm is bounded and a real device/session close performs the final libusb cancellation/drain.

RGB, RGB-HQ and IR share one physical video engine. Logical subscribers may coexist; the bridge applies **IR > RGB-HQ > baseline RGB** arbitration. Baseline RGB used by the operating-system camera remains subscribed continuously and resumes automatically after an IR/HQ owner releases the engine. Depth remains independent and may run with the selected video mode. Projector state is reconciled from active Depth/IR demand so temporary HQ priming cannot accidentally turn off Depth illumination.

### V4L2 virtual camera

`kinect360-remold-v4l2` is the long-lived producer for the operating-system camera. With `exclusive_caps=1`, it opens the loopback output before any desktop application tries to enumerate the camera; this makes the node advertise capture capability to consumers. It does **not** depend on private v4l2loopback start/stop events. While the physical Kinect is absent, reconnecting, or temporarily preempted by IR/HQ, the producer remains attached and may publish a black frame, keeping the virtual camera present.

The node number is not an ABI. `/dev/video42` is only the configured preference. `ensure-v4l2-device.sh` first reuses a correctly labelled Remold node, never overwrites an unrelated webcam, chooses a free `/dev/videoN` on collisions, and uses `v4l2loopback-ctl add` when the module is already owned by another application. The resolved node is written atomically to `/run/kinect360-remold/v4l2-device`; both the V4L2 bridge and `KINECT.sh` validate the `Kinect Xbox 360 Camera` label before opening it. Video-node selection is handled by `ensure-v4l2-device.sh`; fixed boot-time video-number policy is not installed.

Hot-unplug removes only the disconnected physical `CameraNode`; service-level publication and other Kinect devices remain alive. ScannerPort uses bounded per-stream queues and clears a stream queue when its final subscriber disconnects.

## Audio

The audio runtime uses this Kinect sequence:

1. Detect the dedicated `045E:02AD` boot identity.
2. Open its bulk `OUT 0x01` / `IN 0x81` transport with libusb-1.0.
3. Upload the exact Microsoft Kinect Runtime v1.8 **UACFirmware 01.02.709.00** embedded at driver compilation time.
4. Launch at `0x00080030` after loading at `0x00080000`, using the configured page/chunk sizes, status magic, timeout and post-boot delay.
5. Wait for `045E:02BB` or `045E:02C3` USB Audio re-enumeration.
6. Leave the capture interface to Linux `snd-usb-audio` and consume the four-channel 16 kHz 32-bit stream through ALSA, for four-channel capture.

V1 has one audio path: Runtime v1.8 UACFirmware on `02AD`, followed by USB Audio `02BB/02C3`. The platform substitution is WinUSB→libusb-1.0 for boot transport and WASAPI→ALSA for post-firmware capture.

## Skeleton/interactivity model

SynKinect Studio uses NUI20 Kinematic Fusion: multi-hypothesis metric-Depth person segmentation, temporal identity affinity, medial/geodesic limb association, adaptive 3D filtering, anthropometric bone constraints and short-occlusion retention. The complete 20-joint body, including legs, remains tracked and exported. Desktop interactivity is gated only by torso, shoulders, arms and hands.

## Recovery semantics

Each native service retries discovery independently. Camera recovery never resets audio/control; audio bootstrapping never resets a runtime composite; slow NUI skeleton subscribers are dropped instead of blocking the publisher. Frame sequence numbers are propagated so queue overflow and sequence gaps remain observable.

## Build and install ownership

Compilation performs dependency bootstrap, Runtime v1.8/UACFirmware acquisition and native compilation. Installation consumes the compiled distribution and installs runtime dependencies only; it does not compile the driver as root. The installer detects 1414 versus 1473 and writes `/etc/kinect360-remold/model.conf`; 1473 `045e:02c2` remains owned by the normal hub stack while only the composite control interface is claimed and the capture interface remains on `snd-usb-audio`.
