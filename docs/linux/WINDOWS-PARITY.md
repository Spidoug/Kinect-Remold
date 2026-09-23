# Linux / Windows hardware parity

The Linux runtime follows the same **functional hardware split** as the Windows
runtime. The two Xbox 360 Kinect revisions must not be inferred from the audio
runtime PID because both can expose `045E:02BB` / `045E:02C3` after Microsoft
UAC firmware starts.

## Model selection

| Kinect | Camera identity | Motor / LED / accelerometer | Audio after firmware |
|---|---|---|---|
| Xbox 360 model 1414 | `045E:02AE`, `bcdDevice=0x010B` | dedicated `045E:02B0`, classic USB control requests | `045E:02BB/02C3`, ALSA UAC capture |
| Xbox 360 model 1473 | `045E:02AE`, `bcdDevice!=0x010B` (`0x0205` is the known Xbox 1473 value) | `MI_00` bulk control on runtime `045E:02BB/02C3` | `MI_02` UAC capture through ALSA |

`045E:02C2` is the 1473 parent USB hub/controller. Linux never claims or resets
it. It is only an enumeration/start trigger.

## Camera

Both models use the same 02AE camera command protocol and raw frame contract.
Linux discovers the interface/alternate setting and ISO packet geometry from
live USB descriptors instead of assuming a single topology. The libfreenect
packet conventions remain the compatibility reference: RGB/video on EP81,
depth on EP82, 1920-byte video USB packets and 1760-byte depth USB packets.

The ScannerPort behavior matches Windows: RGB/IR exclusivity, RGB+depth
concurrency, persistent camera session, six-frame low-latency queue, depth
projector reference counting, raw Bayer/IR10/depth11 payloads and per-frame
motion metadata. Device labels are identical on both platforms: `Kinect 1414` or
`Kinect 1473`; Studio shows them as `Kinect 1473 · 1/2`. The stable device ID
is a separate manifest field (a USB topology path on Linux, a hashed Windows
location path on Windows). A newer ScannerPort connection from the same client process
supersedes its stale connection so an RGB <-> IR mode change cannot be blocked
by a late-closing descriptor.

The endpoint `0x81` video engine runs only while a consumer wants video: a
ScannerPort RGB, RGB HQ or IR subscription, the V4L2 virtual camera while a
client is open (Linux), or a renewed frame consumer lease from the Media
Foundation virtual camera or the IP camera (Windows).

## Virtual camera

The virtual camera of each Kinect (V4L2 loopback on Linux, Media Foundation on
Windows) carries the RGB stream and follows the RGB HQ driver setting: its
default format is 1280x1024 while RGB HQ is on and 640x480 otherwise. A client
that is already streaming keeps its format while the sensor switches mode and
receives scaled frames. Smart Tilt, the group face target and digital framing
(pan, zoom, vertical crop) use the shared controller in
`smart_tilt.hpp`/`Kinect360RemoldSmartTilt.h`; see `docs/MOTION.md`.

## Control panel

`KINECT.sh` and `Kinect.ps1` offer the same menu in the same order: install,
status, virtual camera, manual Tilt, startup pose, RGB HQ, the IP camera
actions, SynKinect Studio, runtime restart, diagnostics and uninstall. The
diagnostics report the installed version, the USB functions with their 1414 or
1473 classification, the services, the device manifest, the ScannerPort
self-test of every Kinect, the virtual cameras and the recent service logs.

## Motion / motor

The per-model motion contract — model resolution, the single status owner,
poll and validity windows, per-frame samples, Tilt-in-flight behaviour and the
Smart Tilt control law — is shared with Windows and documented in
[`docs/MOTION.md`](../MOTION.md).

For 1414, status/tilt/LED use the dedicated 02B0 control requests. For 1473,
control uses only the runtime composite MI_00 bulk pair. Tilt is committed once,
its immediate ACK is consumed, and verification occurs after uninterrupted
motor travel. A recovery may clear halted MI_00 bulk pipes but never reset the
whole 02BB/02C3 composite, because doing that would tear down MI_02 audio.

## Audio

The same verified Microsoft Kinect UAC firmware image used by the Windows
runtime is uploaded only while the sensor exposes 02AD. One upload attempt is
allowed per physical connection; a failed transition is not repeatedly flashed
until the sensor is unplugged/replugged.

After runtime enumeration, Linux accepts only Kinect 02BB/02C3 ALSA capture
nodes and opens them in their native format, exactly like the shared WASAPI
stream on Windows: S32LE, S24LE, S24_3LE, S16LE or FLOAT_LE, up to four
channels and any rate from 16 kHz up. Samples are converted to the product
frame (16 kHz, four channels, S32LE, 256 samples) with one decimation phase for
all channels, and the frame's channel mask reports the channels actually
supplied. XRUN/suspend recovery uses the ALSA recovery path without resetting
the USB composite device.

## Self-test

`kinect360-remoldctl --device ID probe [rgb|rgb-hq|ir|depth|rgb+depth|ir+depth] [s]`
on Linux and `Kinect360RemoldNui.exe --device ID probe ...` on Windows subscribe
through ScannerPort exactly like Studio and report frames per stream, factory
calibration and motion samples. `Kinect360RemoldNui.exe frames` additionally
inspects the Windows shared RGB transport of the virtual camera (layout
version, frame progress, consumer lease). `DIAGNOSE.sh` runs the Linux probes
for every published Kinect.

## Build identity

The build stores `drivers/linux/FINGERPRINT.sh` (a SHA-256 over every file in
`drivers/linux`) as `binaries/linux/drivers/BUILD-FINGERPRINT`:

- the launcher rebuilds whenever the fingerprint differs from the sources;
- the control panel's **Install / Reinstall** installs only the already-built
  offline bundle; if that bundle is stale, `INSTALL.sh` refuses it and directs
  the user to run the build first;
- `INSTALL.sh` refuses a bundle whose fingerprint does not match the project;
- the installed fingerprint is kept in `/usr/share/kinect360-remold/` and
  `DIAGNOSE.sh` reports whether it matches the current sources.

The project `VERSION` is installed next to the fingerprint and printed by the
installer and by `DIAGNOSE.sh`.

## Camera ownership and IR illumination

`gspca_kinect` is blacklisted: like the Windows WinUSB camera package, the
Remold camera service is the only owner of `045E:02AE`. The IR projector
(register `0x06`) is reference counted exactly like Windows: on while IR or
Depth is requested. Factory depth calibration uses the same reply acceptance
as Windows (constant shift in the second word of a reply of at least 4 bytes).

## RGB HQ fallback

If RGB HQ (1280x1024) never completes a frame on a sensor, both platforms keep
streaming VGA for that connection instead of restarting the camera session in a
loop: RGB HQ subscriptions are refused, the effective driver setting reports HQ
off, virtual cameras receive VGA frames, and the camera log records packet,
frame and sync-loss counters for the failed stream.
