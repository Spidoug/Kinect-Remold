# Motion, tilt and accelerometer contract

This contract is identical on Linux and Windows for Kinect Xbox 360 models
1414 and 1473. Both runtimes implement it with the same names and values:

| Concern | Linux | Windows |
|---|---|---|
| Model and motion policy | `include/remold/hardware_profile.hpp` | `device/shared/Kinect360RemoldHardwareProfile.h` |
| Status owner | `MotionSampler` in `camera_bridge.cpp` | `MotionSampler` in `Kinect360RemoldCameraBridge.cpp` |
| Smart Tilt control law and digital framing | `include/remold/smart_tilt.hpp` | `camera/shared/Kinect360RemoldSmartTilt.h` (byte-identical) |

## Model resolution

The model is always resolved from the `045E:02AE` camera, never from the
runtime audio PID, because both models expose `02BB/02C3` once the UAC firmware
runs.

| Model | Camera | Motor / LED / accelerometer transport |
|---|---|---|
| 1414 | `02AE`, `bcdDevice 0x010B` | dedicated `045E:02B0`, USB control requests |
| 1473 | `02AE`, any other `bcdDevice` (`0x0205` known) | `02BB/02C3` `MI_00` bulk pair `0x01/0x81` |

Linux reads `bcdDevice` from libusb. Windows reads it from the camera's PnP
hardware ID (`USB\VID_045E&PID_02AE&REV_xxxx`), so the Broker never has to open
the WinUSB handle that CameraBridge owns. A device-scoped Broker request is
pinned to the resolved transport: a 1414 never falls through to `02BB/02C3`. An
unscoped request, or a sensor whose camera is re-enumerating,
prefers the unambiguous `02B0` and otherwise uses `MI_00`.

## Motion sampling

The camera service is the only component that sends periodic `Status`
requests. Nothing else polls the Broker: not the virtual cameras, not the IP
cameras, not SynKinect Studio.

| Model | Poll period | Sample valid for |
|---|---|---|
| 1414 | 25 ms | 250 ms |
| 1473 | 500 ms | 1500 ms |

Polling runs only while the camera session is online and a frame consumer is
active:

- Linux: any ScannerPort subscription (Studio, V4L2 virtual camera while a V4L2
  client is open, IP camera while an authenticated viewer is connected).
- Windows: any ScannerPort subscription, or a renewed frame consumer lease on
  `Global\Kinect360RemoldFrameLease-<device-id>` (virtual camera while an
  application requests frames, IP camera while an authenticated viewer is
  connected). The lease expires 2000 ms after its last renewal.

A failed or busy `Status` keeps the previous sample; the sample is dropped once
it is older than the model's validity window. The Linux Broker exchange is
bounded to 2000 ms by socket timeouts.

## Per-frame sample

Every frame carries the latest valid sample taken when the frame completed on
USB (the same moment its capture timestamp refers to):

- ScannerPort `FrameHeader.motion` on both platforms (RGB, RGB HQ, IR, Depth);
- Windows shared-memory RGB slots (`FrameSlotMeta.motion`) consumed by the
  virtual camera and the IP camera.

`MotionSample.flags` has `MotionAccelerometerValid` and `MotionTiltValid` set
together when the sample is valid and both clear when no valid sample exists.
`tickMs` is the monotonic time at which the sample was measured.

## Tilt in flight

`Tilt` holds its device until travel is verified. 1414 polls completion on
`02B0`. 1473 sends the one-shot `0x803B` command, keeps `MI_00` silent for the
whole mechanical travel and then reads the angle once: the silent window is
`max(1500 ms, 600 ms + 85 ms per degree)` of distance from the last measured
angle (full range when unknown). Any `MI_00` transaction during travel makes the
1473 motor stop and restart, which is why a single command never overlaps
status traffic. Smart Tilt on a 1473 therefore moves in discrete steps, one per
completed command. While a Tilt is in flight the Broker answers `Status` immediately with
`EBUSY` (Linux) or `ERROR_BUSY` (Windows) instead of queueing it. Frames
therefore carry no motion sample while the motor travels, and Smart Tilt cannot
issue a new command from a stale angle. Both Brokers serve every connection on
its own thread, so Ping and other Kinects are never blocked by a travelling
motor.

## Smart Tilt

Both virtual cameras run the same controller at the face period (40 ms):

- the measured angle and accelerometer come only from the frame's motion
  sample;
- activation and deactivation of the virtual camera reset the controller and
  never move the motor; the first valid sample warm-starts the target from the
  measured angle;
- face error (group target: centre of all detected faces) drives an absolute,
  rate-limited, settle-aware tilt command;
- accelerometer pitch, with motor-to-gravity polarity learned from real
  movement, adds a low-authority stabilization term;
- digital framing (pan, zoom up to the digital zoom limit, vertical crop)
  follows the same face target and hides the coarse motor movement; it relaxes
  towards the full frame 2 s after the last face;
- after 8 s without a face the motor returns to the startup pose;
- with automatic framing off, the manual target is commanded instead.

Face detection is platform-specific (Windows `FaceTracker`, Linux OpenCV Haar
cascade); both use the group target (common bounding box of every face). On
Windows the camera-control property set also exposes manual pan, zoom, tilt and
target mode; V4L2 loopback has no control plane, so Linux reads the same
settings from `remold.conf`.

| Policy | Windows `Product.psd1` | Linux `remold.conf` | Default |
|---|---|---|---|
| Startup tilt | `StartupTiltDegrees` | `tilt.startup` | 6 |
| Face period | `SmartTiltPolicy.FacePeriodMs` | `smart_tilt.face_period_ms` | 40 |
| Command period | `SmartTiltPolicy.CommandPeriodMs` | `smart_tilt.command_period_ms` | 90 |
| Vertical dead zone | `SmartTiltPolicy.FaceVerticalDeadZonePixels` | `smart_tilt.face_vertical_dead_zone_pixels` | 10 |
| Face error filter | `SmartTiltPolicy.FaceErrorFilterAlpha` | `smart_tilt.face_error_filter_alpha` | 0.35 |
| Accelerometer filter | `SmartTiltPolicy.AccelFilterAlpha` | `smart_tilt.accel_filter_alpha` | 0.30 |
| Correction filter | `SmartTiltPolicy.AccelCorrectionFilterAlpha` | `smart_tilt.accel_correction_filter_alpha` | 0.30 |
| Minimum command delta | `SmartTiltPolicy.MinCommandDeltaDegrees` | `smart_tilt.min_command_delta_degrees` | 1 |
| Settle tolerance | `SmartTiltPolicy.MotorSettleToleranceDegrees` | `smart_tilt.motor_settle_tolerance_degrees` | 1 |
| Settle time | `SmartTiltPolicy.MotorSettleMs` | `smart_tilt.motor_settle_ms` | 140 |
| Automatic framing | camera control `AutoFraming` | `smart_tilt.auto_framing` | on |
| Tracking speed | camera control `TrackingSpeed` | `smart_tilt.tracking_speed` | 90 |
| Framing dead zone | camera control `DeadZonePercent` | `smart_tilt.dead_zone_percent` | 7 % |
| Digital zoom limit | camera control `DigitalZoomLimitPercent` | `smart_tilt.digital_zoom_limit_percent` | 180 % |
| Stabilization | camera control `TiltStabilization` | `smart_tilt.stabilization` | on |
| Stabilization strength | camera control `StabilizationStrength` | `smart_tilt.stabilization_strength` | 60 |
| Auto-center | camera control `AutoCenter` | `smart_tilt.auto_center` | on |

The tilt range is -27° to +27° on both platforms.

## Virtual camera RGB mode

Both virtual cameras carry the Kinect RGB stream and follow the RGB HQ driver
setting:

- the default format is 1280x1024 at 15 fps while RGB HQ is on and 640x480 at
  30 fps otherwise (Windows lists the HQ media types first; Linux sets the
  V4L2 output format);
- a client that is already streaming keeps its negotiated format: the camera
  service switches the sensor mode and the frames are scaled to that format;
- the next client that opens the camera gets the format of the current mode.
