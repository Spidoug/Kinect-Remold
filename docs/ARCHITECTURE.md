# Architecture

## Design goal

Remold treats Kinect Xbox 360 models 1414 and 1473 as managed sensor subsystems rather than library handles owned independently by every application.

The key rule is:

> **One native runtime owns physical hardware; applications consume stable user-space protocols.**

This is the main architectural difference between Remold and a conventional application linking directly to a Kinect library.

## Cross-platform boundary

```text
                         Applications
                              │
                    Remold application ABI
                              │
           ┌──────────────────┴──────────────────┐
           │                                     │
        Windows                                Linux
   Named Pipes / shared memory            Unix Domain Sockets
           │                                     │
   WinUSB / WASAPI / MF          libusb-1.0 / ALSA / V4L2
           │                                     │
           └──────────────────┬──────────────────┘
                              │
                    Kinect 1414 / 1473
```

The applications should not need to understand USB endpoints, ALSA device enumeration, WinUSB interfaces or Kinect firmware state.


## Unified hardware-control interface

The runtime presents one control interface for both Kinect Xbox 360 revisions:

```text
status -> accelerometer + measured tilt
tilt   -> requested degrees; success only after measured-angle confirmation
led    -> logical Remold LED mode
```

Connection details stay behind the broker backend. Model 1414 opens the dedicated `045E:02B0` motor interface and uses the dedicated 02B0 USB control protocol. Model 1473 preserves `045E:02C2` as the Microsoft hub and opens `045E:02BB/02C3&MI_00` after audio firmware re-enumeration, using the alternate bulk command protocol. The model-neutral command/reply ABI defines issue, retry and verification semantics; device discovery, USB encoding and polling cadence are handled by the host runtime.

Revision-specific preparation, endpoint discovery and USB encoding stay entirely inside the physical backend.

## Linux physical ownership

```text
045e:02ae Camera
   ├── endpoint 0x81 ── RGB or IR
   └── endpoint 0x82 ── Depth

1414: 045e:02b0 Motor
   └── control transfer ── Tilt / LED / accelerometer

1473: 045e:02c2 Microsoft hub
   └── post-firmware 045e:02bb interface 0
          └── bulk control ── Tilt / LED / accelerometer

045e:02ad NUI Audio boot
   └── validated audio firmware upload via libusb-1.0
          ↓ re-enumeration
   ├── UAC runtime ── snd-usb-audio / ALSA ── 4ch S32LE 16 kHz
   └── UAC runtime 02BB/02C3 ── snd-usb-audio + ALSA ── 4ch S32LE 16 kHz
```

The Linux camera process enumerates every Kinect camera interface with libusb. Each physical USB topology path receives a stable Remold ID and its own Unix socket under `/run/kinect360-remold/devices/`. `/run/kinect360-remold/devices.tsv` is the atomic discovery manifest consumed by the Studio. Each device maintains independent RGB/IR/depth state and permits multiple clients on its own endpoint.

## Video arbitration

Kinect 1414 and 1473 share the same Kinect v1 camera RGB/IR engine behavior. Remold therefore rejects requests that would require RGB and IR simultaneously. Depth is independent and can run alongside either video mode.

```text
RGB ─┐
     ├── physical endpoint/video engine 0x81
IR  ─┘

Depth ───────────────────────── endpoint 0x82
```

This constraint belongs in the runtime, not in each application.

Virtual-camera and IP-camera services acquire RGB only while they have active consumers and follow the registry primary camera. Foreground Surveillance dynamically chooses exactly RGB or IR and never subscribes Depth. A luminance hysteresis switches to IR in low light; RGB recovery checks are evidence-driven and cooldown-limited. Motion is temporal appearance/luminance change in whichever video stream is active. Because RGB and IR are physically exclusive, leaving the Surveillance tab releases IR and returns its background transport to RGB, preventing Scanner/Interactivity starvation.

## Depth calibration

The native camera backend exposes the RAW-only ScannerPort camera ABI. Depth is the sensor-native packed 11-bit payload, and the handshake exposes the factory calibration constants. SynKinect Studio is the only application-side unpack/raw→millimetre authority, so USB acquisition/recovery remains isolated from metric reconstruction math. There is no unpacked-uint16 camera wire format in V1.

If calibration cannot be obtained, raw shift samples can still traverse the private transport, but Studio marks metric Depth unavailable and never labels those samples as millimetres.

Above that factory disparity→metric conversion, the Studio can apply a **per-device surface calibration**. It collects averaged views of one flat wall at multiple ranges, robustly fits one plane per range, and solves a bounded affine calibration transform independently for each depth pixel. The same capture also estimates temporal sigma per pixel. The profile is keyed by the central device registry ID, so USB enumeration order does not select calibration. The calibrated depth accessor is the single authority used by target estimation, point-cloud construction and Depth→RGB registration; HQ TSDF additionally consumes the learned confidence as an observation weight.

## Audio ownership

The NUI Audio device starts in a firmware boot identity. Remold uploads a validated Kinect v1 audio image through the boot USB interface. Runtime ownership is platform- and firmware-dependent:

- Windows: WinUSB owns the vendor boot/control functions; the inbox USB Audio stack + WASAPI owns the UAC microphone interface.
- Linux UAC path: `snd-usb-audio` owns the standard audio interface and Remold captures through ALSA (with normal PipeWire integration available above ALSA).
- Linux vendor path: Remold owns only the matching vendor interface through libusb-1.0 and services both isochronous directions, IN `0x82` and OUT `0x02`.

AudioBridge maintains one phase-preserving four-channel capture stream per physical Kinect and multiplexes those streams over the shared multi-client raw bus. Every subscription carries the stable Kinect device ID, so two sensors of the same model or different models remain independent while software consumers share the transport safely. Microphones and Acoustic Scanner each instantiate the same DSP pipeline off the UI thread: GCC-PHAT/TDOA estimates DOA, a near-field grid estimates horizontal x/z, and fractional-delay delay-and-sum beamforming provides AUTO or MANUAL spatial isolation to the system playback output.

## Failure and reconnect model

Linux native services are long-lived and retry device discovery. The direct camera backend marks its session invalid when an asynchronous USB transfer can no longer be resubmitted or the device disappears; the outer runtime loop closes and attempts a fresh reopen.

System installation uses udev/systemd so hardware reconnection does not require reinstalling the project.

Recovery is service/session oriented: a dead transport session is closed, its queues are cleared, and the runtime attempts a fresh reopen.

## IPC endpoints on Linux

| Endpoint | Role |
| --- | --- |
| `/run/kinect360-remold/control.sock` | motor/status/tilt/LED control |
| `/run/kinect360-remold/devices.tsv` | discovered Kinect IDs, labels and per-device ScannerPort endpoints |
| `/run/kinect360-remold/devices/<device-id>.sock` | RGB/IR/depth ScannerPort v1 for one physical Kinect; multi-client |
| `/run/kinect360-remold/audio.sock` | multi-client raw 4-channel audio bus multiplexed by physical Kinect ID; each software module owns its DSP instance |
| `/run/kinect360-remold/audio-bridge-status.txt` | audio diagnostics |
| `/run/kinect360-remold/nui.sock` | NUI-style capability and endpoint discovery |
| `/run/kinect360-remold/nui-skeleton.sock` | canonical Kinect-v1 20-joint skeleton relay (publisher/subscribers) |

See `drivers/linux/source/include/remold/protocol.hpp` for the binary protocol definitions.

## SynKinect Studio object and lifecycle model

The Processing sketch is the UI host, not the Kinect owner. `StudioController` owns module lifecycle on `SynKinectStudio-Lifecycle`; no blocking device transition belongs to the Processing render/input thread.

3D Scanner and Interactivity use the same RGBD protocol and synchronization algorithm, but each module owns its own transport instance:

```text
Studio lifecycle worker
        │
        ├──────── Scanner tab ────────┐
        │                             ▼
        │                     KinectSource instance A
        │                     RGB + metric Depth
        │                     bounded synchronizer
        │                             │
        │                             ▼
        │                     ICP / TSDF reconstruction
        │
        └──── Interactivity tab ──────┐
                                      ▼
                              KinectSource instance B
                              RGB + metric Depth
                              bounded synchronizer
                                      │
                                      ▼
                              NUI20 Kinematic Fusion / Depth geometry
```

Only the active single-camera module owns a live transport. Scanner and Interactivity share calibration data and registration mathematics only. A tab transition immediately revokes the superseded module's transport generation and closes its pipe; the next module opens its required mode without waiting for the superseded worker to join. Interactivity never subscribes to IR.

Scanner and Interactivity use the same calibrated RGB↔Depth registration mathematics while keeping independent live transport/state objects. Scanner uses pair residual as texture-sync quality, edge-preserving depth filtering and robust ICP before TSDF integration. Interactivity runs one **NUI20 Kinematic Fusion** tracker per module. Instead of committing to a single largest/nearest depth blob, the tracker ranks several person-depth hypotheses, scores connected components with temporal center/depth affinity, derives torso anchors from robust silhouette profiles, follows arms and legs through depth-continuous medial/geodesic paths, learns bilateral limb proportions, applies 3D anthropometric constraints and stabilizes joints with adaptive temporal filtering and short-occlusion prediction. A local hand-contour stage derives palm support, fingertip extrema, openness/grab and pinch cues before the filtered result is projected into calibrated RGB coordinates. No external pose runtime is required.

The tracker publishes the canonical Kinect-v1/NUI **20-joint topology** (`HipCenter` through `FootRight`) including both legs. Interactivity input is intentionally gated only by the upper body: spine/chest, shoulders, arms and at least one hand. Lower-body loss therefore cannot cancel an otherwise reliable interaction pose. Cursor mapping uses a shoulder-axis/torso-axis camera-space frame, so body yaw and camera placement have less influence than camera-global X/Y/Z mapping. Full-body confidence remains available for visualization, diagnostics and the Linux NUI skeleton relay. The relay is a project ABI with NUI-compatible semantics; it does not impersonate the proprietary Microsoft Kinect runtime.

The interaction renderer is clipped to the exact RGB image rectangle and all published joint image coordinates are clamped to the 640×480 Kinect viewport. Pose inference is isolated from the Processing render/input thread; the UI only consumes immutable published snapshots.

The Processing render/input thread never performs transport, pairing, reconstruction or skeleton extraction; it consumes published snapshots only.

Surveillance is designed for multiple cameras. Every discovered Kinect has an independent compressed JPEG ring retained in RAM for 10 minutes by default. Appearance/luminance motion from any active RGB/IR camera opens one event session; every camera recorder first drains its own 60-second pre-roll and then receives live JPEG packets that the internal Java AVI writer stores as indexed Motion-JPEG frames. This preserves synchronized evidence across cameras without retaining raw 640×480 RGB frames in RAM.

The 3D reconstruction view has its own off-screen P3D renderer instance. It cannot alter the camera, clipping, depth state or projection of the main Studio surface, and its buffer follows the live reconstruction-card dimensions after window resizing.

Surveillance starts disarmed at application startup and is active only while its tab owns the video resources. Leaving the tab disarms Surveillance, closes an active recording asynchronously and releases RGB/IR ownership. While Surveillance is active, hot-plug discovery is centralized in `KinectDeviceRegistry`; newly connected cameras are added automatically and disconnected cameras are removed without changing the Studio selector for unrelated devices.

The application JAR is staged with the required launcher, runtime-native libraries and native Remold transport implementation.


## V1 stability rules

- The visible ROOT product devnode is a software container for the broker service; it is not a WinUSB function and is not required to report DN_STARTED.
- The live 3D Scanner owns one stable RGB 640×480 + Depth session for the duration of the tab. On Windows, ScannerPort carries raw Bayer RGB and packed raw Depth; Studio performs the user-space conversions. START SCAN starts reconstruction only and never reprograms or reopens the physical camera transport.
- Reconstruction is bounded and low-priority (default 8 fusion frames/s) so the UI and shared camera consumers stay responsive.
- Windows audio keeps 02BB MI_02 on the inbox USB Audio driver and captures the four raw microphones with WASAPI. Kinect-named capture endpoints are format-validated instead of relying only on one PnP instance-string representation. The Studio ABI remains 4ch S32LE at 16 kHz.
