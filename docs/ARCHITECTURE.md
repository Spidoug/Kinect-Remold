<div align="center">

# Architecture

### Cross-platform ownership, stable device identity and capability-driven Studio integration

[Documentation](README.md) · [Quick start](QUICKSTART.md) · [Motion](MOTION.md) · [Protocols](windows/PROTOCOL.md)

</div>

## Design goal

Kinect Remold separates the cross-generation application layer from generation-specific native driver modules. SynKinect Studio operates on discovered device capabilities and stable device identities; it does not own USB endpoints or assume that every Kinect generation exposes the same physical transport.

The key rules are:

> **Each driver module owns its generation-specific hardware. SynKinect Studio consumes stable per-device capabilities across all registered modules.**

The `kinect-xbox-360-remold` module supports first-generation models 1414, 1473 and Kinect for Windows 1517. The `kinect-one-remold` module owns Kinect v2 transport through WinUSB on Windows and libusb-1.0 on Linux. Both publish independent SDK endpoints without coupling Studio modules to generation-specific USB details.

### Discovery identity

Every discovered sensor is identified by the pair `module-id + deviceId`. The SDK row also publishes `generation`, allowing the Studio to present or specialize generation-specific behavior without coupling generic modules to native driver names.

## Cross-platform boundary

Within each driver module, Windows and Linux follow the same ownership and application interfaces. Across generations, the Studio sees a registry of module endpoints and merges their per-device capabilities into one device selector.

```text
                         Applications
                              │
                    Remold application ABI
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
   Broker + SDK host     CameraBridge        AudioBridge
         │                    │                    │
 control + discovery     RGB / IR / Depth    UAC boot + 4ch bus
         │                    │                    │
         └────────────────────┼────────────────────┘
                              │
                   platform transport adapters
                    Windows           Linux
                 WinUSB/WASAPI     libusb/ALSA
                 Media Foundation      V4L2
                              │
               generation-specific Kinect hardware
```

For the Kinect Xbox 360 Remold module, the Broker owns both the model-neutral control endpoint and SDK discovery on both systems (`Named Pipes` on Windows, `Unix Domain Sockets` on Linux). CameraBridge is the sole camera owner and manifest publisher. AudioBridge is the sole audio boot/capture owner. Virtual-camera and IP-camera adapters consume those bridges rather than opening Kinect hardware independently. Applications never need to understand USB endpoints, ALSA device enumeration, WinUSB interfaces or Kinect firmware state.


## Kinect Xbox 360 Remold hardware-control interface

The runtime presents one control interface for both supported Kinect Xbox 360 hardware models:

```text
status -> accelerometer + measured tilt (busy while a tilt is travelling)
tilt   -> requested degrees; reply distinguishes accepted from measured/verified
led    -> logical Remold LED mode
```

Both brokers resolve the model from the `02AE` camera and serve every connection concurrently. The camera service is the only periodic `status` owner and attaches the latest valid sample to every frame; see [MOTION.md](MOTION.md).

The LED interface is also model-neutral and restricted to states both physical controllers implement natively: `Off`, `Green`, `Red` and `BlinkGreen`. `PrepareCamera` initializes a fresh physical control session to solid green on both models. Later explicit LED commands remain in effect for that session. No model-specific color substitution is exposed through the SDK.

Connection details stay behind the broker backend. Model 1414 opens dedicated `045E:02B0`. Model 1473 preserves `045E:02C2 REV_0001` as the Microsoft hub and opens `045E:02BB/02C3&MI_00` after audio firmware re-enumeration. Model 1517 opens its dedicated `045E:02C2 REV_0100` motor/control function with the classic first-generation control protocol. Windows and Linux use the same model-neutral command/reply ABI. Model 1414 can verify movement through its dedicated motor endpoint; model 1473 treats a completed 0x803B OUT transfer as the one-shot commit point and verifies only after an uninterrupted travel interval, so a late ACK can never trigger a second physical command.

Model-specific preparation, endpoint discovery and USB encoding stay entirely inside the physical backend.

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
   └── UACFirmware upload
          ↓ re-enumeration
045e:02bb USB Audio
   └── ALSA ── four-channel S32LE 16 kHz
```

The Linux camera process enumerates every Kinect camera interface with libusb. Each physical USB topology path receives a stable device ID and its own Unix socket under `/run/kinect360-remold/devices/`. `/run/kinect360-remold/devices.tsv` is an internal atomic manifest consumed by the Broker SDK endpoint. SynKinect Studio performs discovery only through that SDK endpoint. Each device maintains independent RGB/IR/depth state and permits multiple clients on its own endpoint.

## Video arbitration

First-generation Kinect 1414, 1473 and 1517 share the same mutually exclusive RGB/IR video-engine behavior in the Remold v1 backend. Remold therefore rejects requests that would require RGB and IR simultaneously. Depth is independent and can run alongside either video mode.

```text
RGB ─┐
     ├── physical endpoint/video engine 0x81
IR  ─┘

Depth ───────────────────────── endpoint 0x82
```

This constraint belongs in the runtime, not in each application.

Each virtual-camera worker acquires RGB only while its own V4L2/Media Foundation camera has an active consumer and remains bound to that camera's `deviceId`. The optional IP-camera service selects a currently Ready Kinect from the capability registry rather than defining a global primary camera. Foreground Surveillance dynamically chooses exactly RGB or IR and never subscribes Depth. A luminance hysteresis switches to IR in low light; RGB recovery checks are evidence-driven and cooldown-limited. Motion is temporal appearance/luminance change in whichever video stream is active. Because RGB and IR are physically exclusive, leaving the Surveillance tab releases IR and returns its background transport to RGB, preventing Scanner/Interactivity starvation.

## Depth calibration

Both native camera backends expose the same RAW-only ScannerPort camera ABI. Depth is the sensor-native packed 11-bit payload on Windows and Linux, and both handshakes expose the factory calibration constants. SynKinect Studio is the only application-side unpack/raw→millimetre authority, so USB acquisition/recovery remains isolated from metric reconstruction math. There is no unpacked-uint16 camera wire format in the current protocol.

If calibration cannot be obtained, raw shift samples can still traverse the private transport, but Studio marks metric Depth unavailable and never labels those samples as millimetres.

Above that factory disparity→metric conversion, the Studio can apply a **per-device surface calibration**. It collects averaged views of one flat wall at multiple ranges, robustly fits one plane per range, and solves a bounded affine correction independently for each depth pixel. The same capture also estimates temporal sigma per pixel. The profile is keyed by the central device registry ID, so USB enumeration order does not select calibration. The corrected depth accessor is the single authority used by target estimation, point-cloud construction and Depth→RGB registration; HQ TSDF additionally consumes the learned confidence as an observation weight.

## Audio ownership

The NUI Audio device starts in a firmware boot identity. Remold uploads Microsoft's UAC firmware through the boot USB interface. After the device re-enumerates as USB Audio, the operating system's audio stack owns isochronous scheduling:

- Windows: inbox USB Audio + WASAPI;
- Linux: ALSA (and therefore normal PipeWire integration above ALSA if desired).

AudioBridge publishes one phase-preserving four-channel multi-client raw bus per Kinect, keyed by the same stable `deviceId`, so software consumers can subscribe to the selected physical array without contending for the native capture handle or crossing sensors. Microphones and Acoustic Scanner each instantiate the same DSP pipeline off the UI thread: GCC-PHAT/TDOA estimates DOA, a near-field grid estimates horizontal x/z, and fractional-delay delay-and-sum beamforming provides AUTO or MANUAL spatial isolation to the system playback output.

## Failure and reconnect model

Linux native services are long-lived and retry device discovery. The direct camera backend marks its session invalid when an asynchronous USB transfer can no longer be resubmitted or the device disappears; the outer runtime loop closes and attempts a fresh reopen.

System installation uses udev/systemd so hardware reconnection does not require reinstalling the project.

Recovery is service/session oriented: a dead transport session is closed, its queues are cleared, and the runtime attempts a fresh reopen.

## Linux runtime endpoints

| Endpoint | Role |
| --- | --- |
| `/run/kinect360-remold/control.sock` | Broker motor/status/tilt/LED control |
| `/run/kinect360-remold/devices.tsv` | internal CameraBridge manifest consumed by Broker and native adapters |
| `/run/kinect360-remold/devices/<device-id>.sock` | RGB/IR/depth ScannerPort for one physical Kinect; multi-client |
| `/run/kinect360-remold/audio/<device-id>.sock` | multi-client raw 4-channel audio bus for one physical Kinect |
| `/run/kinect360-remold/audio/<device-id>-control.sock` | per-Kinect volume/mute control; independent of capture-stream readiness |
| `/run/kinect360-remold/virtual-cameras.tsv` | stable `deviceId` → V4L2 node assignments |
| `/run/kinect360-remold/sdk.sock` | Broker-hosted discovery endpoint (`LIST`, `GET`, `INDEX`) |
| `/run/kinect360-remold/audio-bridge-status.txt` | internal audio runtime status consumed by Studio |

Public Linux SDK interfaces are published as `Kinect360RemoldControlProtocol.hpp` and `Kinect360RemoldAudioControlProtocol.hpp`. ScannerPort, raw audio transport and runtime paths remain internal.

## SynKinect Studio object and lifecycle model

The Processing sketch is the UI host, not the Kinect owner. `StudioController` owns module lifecycle on `SynKinectStudio-Lifecycle`; no blocking device transition belongs to the Processing render/input thread. Built-in modules are created through factories and external modules are discovered through the same lifecycle registry, so module identity, activation, context events and resource ownership do not depend on navigation indexes. User-interface preferences are separate from packaged configuration: the selected language and small interaction preferences are stored in the Java per-user preference store, while `data/*/config.properties` remains read-only application policy.

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
                              SynKinect Body / Depth geometry
```

Only the active single-camera module owns a live transport. Scanner and Interactivity share calibration data and registration mathematics only. A tab transition immediately revokes the superseded module's transport generation and closes its pipe; the next module opens its required mode without waiting for the superseded worker to join. Interactivity never subscribes to IR.

Scanner and Interactivity use the same calibrated RGB↔Depth registration mathematics while keeping independent live transport/state objects. Scanner turntable capture begins by locking a metric **Bounding Box / Volume Of Interest** from the first coherent target component; once locked, points outside that camera-space volume are discarded before tracking, fusion and HQ refinement, while the rotating base can remain inside the volume. ICP keeps a persistent turntable pivot, predicts short-term yaw and performs a coarse-to-fine angular search only to seed registration; the converged full SE(3) pose (XYZ + pitch/yaw/roll) is preserved for global TSDF composition. When synchronized RGB is valid, color similarity supplies a bounded photometric weight to otherwise valid geometric correspondences; depth geometry remains authoritative and RGB absence falls back to depth-only ICP. Measurable-overlap gating and confidence/robust-residual weighting protect the fit, then weighted TSDF and the rolling accepted-cloud reference independently check surface consistency before fusion. A candidate that would create a displaced duplicate shell is rejected without advancing fusion state, coverage or HQ archive; genuinely new surface is not penalized when the TSDF has no prior evidence there. Interactivity runs one **SynKinect Body** instance per module. After metric person segmentation, each 3D sample is assigned normalized probabilistic body-part evidence (head, torso, left/right arm, hand, leg and foot). Joint candidates are extracted from local probability modes and then constrained by parent-chain geometry, temporal continuity, IR/depth support and subject-specific learned bone lengths. It segments the person directly in metric Depth, derives torso anchors from robust silhouette profiles and a torso-depth layer, normalizes vertical body coordinates with robust quantiles so lowered arms do not shorten the apparent trunk, associates arms and legs by geodesic continuity through the depth mask with temporal/side affinity, rejects implausible 3D bone relationships, lifts the remaining landmarks to camera-space XYZ, adaptively stabilizes them, and projects the filtered result into calibrated RGB coordinates. The default tracker does not require an external neural runtime; a confidence-weighted articulated motion prior complements the depth observations before temporal filtering and kinematic optimization.

The interaction renderer is clipped to the exact RGB image rectangle and all published joint image coordinates are clamped to the 640×480 Kinect viewport. Pose inference is isolated from the Processing render/input thread; the UI only consumes immutable published snapshots.

The Processing render/input thread never performs transport, pairing, reconstruction or skeleton extraction; it consumes published snapshots only.

Frontend-native dialogs are host-owned. `StudioUiSystem` exposes `StudioNativeDialogs` so built-in modules do not implement their own file/folder chooser stacks. Scanner exports use the host save-file dialog; Microphones and Surveillance use the same host directory picker. Windows delegates directory selection to the Windows Shell/Explorer, Linux prefers the native desktop chooser (`zenity` or `kdialog`), and unsupported environments fall back to the host Swing chooser. User-initiated folder/save dialogs do not force Downloads, application-data, or a previously configured recording directory as their starting location; the host desktop chooses its normal/recent location. Module code owns only the selected path and persistence policy, not the platform dialog implementation.

Frontend text follows locale-catalog casing rather than module-local transformations. Ordinary states and actions use normal sentence/title capitalization; technical identifiers and established abbreviations such as RGB, RGB-D, USB, ICP, IMU, STL, OBJ, PLY, XYZ, RMS and SNR retain their conventional uppercase forms. Built-in module pointer hit testing is always performed in content-local coordinates, matching the transform used to render module panels below the Studio shell.

Surveillance is multi-camera by design. Every discovered Kinect has an independent compressed JPEG ring retained in RAM for 10 minutes by default. Appearance/luminance motion from any active RGB/IR camera opens one event session; every camera recorder first drains its own 60-second pre-roll and then receives live JPEG packets that the internal Java AVI writer stores as indexed Motion-JPEG frames. This preserves synchronized evidence across cameras without retaining raw 640×480 RGB frames in RAM.

The 3D reconstruction view has its own off-screen P3D renderer instance. It cannot alter the camera, clipping, depth state or projection of the main Studio surface, and its buffer follows the live reconstruction-card dimensions after window resizing.

Surveillance starts disarmed at application startup and is active only while its tab owns the video resources. Leaving the tab disarms Surveillance, closes an active recording asynchronously and releases RGB/IR ownership. While Surveillance is active, hot-plug discovery is centralized in `KinectDeviceRegistry`; newly connected cameras are added automatically and disconnected cameras are removed without changing the Studio selector for unrelated devices.

The unified application JAR is identical in Windows and Linux staging. Platform-specific differences are limited to the launcher/runtime-native libraries and native Remold transport implementation.


## Stability rules

- The visible ROOT product devnode is a software container for the broker service; it is not a WinUSB function and is not required to report DN_STARTED.
- The live 3D Scanner maintains one stable color + Depth consumer session for the duration of the tab. RGB HQ is not Scanner state: it is a persistent per-Kinect driver setting controlled from the Studio system/driver panel or `KINECT`. Scanner follows the selected Kinect's driver setting and immediately renegotiates its active transport after a confirmed RGB HQ change, while START SCAN still starts reconstruction only and never changes driver configuration. On Windows, ScannerPort carries raw Bayer color and packed raw Depth; Studio performs the user-space conversions.
- Reconstruction is bounded and low-priority (default 8 fusion frames/s) so the UI and shared camera consumers stay responsive.
- Windows audio keeps 02BB MI_02 on the inbox USB Audio driver and captures the four raw microphones with WASAPI. Kinect-named capture endpoints are format-validated instead of relying only on one PnP instance-string representation. The Studio ABI remains 4ch S32LE at 16 kHz.


### Kinect One Remold module

The Kinect One module is a project-owned user-space driver module. Windows transport calls Microsoft WinUSB directly; Linux transport calls libusb-1.0 directly. A single runtime process owns each physical Kinect v2 and multiplexes Studio consumers through local scanner endpoints, preventing multiple Studio modules from opening the USB device concurrently. Discovery advertises `generation=xbox-one` and only capabilities actually supplied by the native module or Studio RGB-D layer.
