# Motion capture

The **Motion Capture** Studio module (`mocap`) streams the SynSkeleton body pose in
real time to 3D editors, VTuber applications and game engines, and records BVH
files. It uses the same depth-only body tracker as Interactivity.

```
Kinect depth ──► BodyTrackingSession (RGB-D + SynSkeleton, latest-frame worker)
                    │  immutable BodyFrame, latest-only mailbox per consumer
                    ▼
               Mocap-Retarget thread: MocapRetargeter ──► MocapPose (Unity humanoid)
                    │  latest-only mailbox per sink, one thread per sink
     ┌──────────────┼───────────────┬──────────────┬──────────────┐
     ▼              ▼               ▼              ▼              ▼
  VMC (OSC/UDP)  OSC joints     JSON/UDP       WebSocket       BVH recorder
  :39539         :39542         :39541         ws://:39540/    data dir
```

A slow receiver can only skip stale frames of its own sink; it never blocks the
solver, the retargeter or other sinks.

## Using the module

Open **Motion Capture** from the Studio Home screen and stand 1.5–3.5 m in front
of the Kinect with the whole body visible. The status panel shows tracking
state, body FPS, end-to-end latency (depth arrival → packet sent), packets sent,
WebSocket clients, BVH frames, VMC target and mirror state.

| Button | Action |
|---|---|
| VMC / OSC / JSON UDP / WebSocket | Enable or disable that stream (highlighted = running) |
| Record BVH / Stop BVH | Start/stop a BVH recording |
| Mirror | Avatar mirrors the user (user's left hand drives the avatar's right hand) |
| VMC port | Cycle `vmc.presets` (default 39539 ↔ 39540) |

**Camera ownership.** Like every single-camera module, Motion Capture owns its
depth transport only while its tab is active. Leaving the tab stops tracking,
closes all sockets (ports are released) and saves a running BVH recording;
returning re-opens the streams that were enabled. To stream while using another
application, keep the Studio on the Motion Capture tab (it may be minimised).

### Configuration

`data/mocap/config/config.properties`:

| Key | Default | Meaning |
|---|---|---|
| `bindAddress` | `127.0.0.1` | Local address for all sockets. Use `0.0.0.0` only on a trusted network — streams are unauthenticated. |
| `vmc.enabled`, `vmc.host`, `vmc.port` | `true`, `127.0.0.1`, `39539` | VMC target |
| `vmc.presets` | `39539,39540` | Ports offered by the VMC port button |
| `osc.enabled`, `osc.host`, `osc.port` | `false`, `127.0.0.1`, `39542` | Plain OSC target |
| `json.enabled`, `json.host`, `json.port` | `false`, `127.0.0.1`, `39541` | JSON UDP target |
| `json.space` | `unity` | `unity` (humanoid bones) or `camera` (Kinect joints); also used by WebSocket |
| `ws.enabled`, `ws.port` | `true`, `39540` | WebSocket server (TCP; does not collide with VMC UDP 39540) |
| `mirror` | `false` | Initial mirror state |
| `root.center` | `true` | Put the avatar at the origin when a new person is acquired (walking still translates it) |
| `sendRate` | `60` | Max messages/s per sink; ≥ 60 sends every solved frame |

BVH files are written to `<Studio data>/mocap/recordings/mocap-YYYYMMDD-HHMMSS.bvh`
(Linux: `~/.local/share/Kinect Remold/Data/SynKinect Studio/mocap/recordings`,
Windows: `%LOCALAPPDATA%\Kinect Remold\Data\SynKinect Studio\mocap\recordings`).

## Coordinate conventions

**Studio camera space** (`BodyFrame`, `/synkinect/joint`, JSON `space:"camera"`,
SDK `StudioBodyFrame.joints()`): right-handed, metres, +X image right (= the
user's **left** when facing the sensor), +Y down, +Z away from the sensor.
Left/right joint names follow the Kinect SDK anatomical convention
(`ShoulderLeft` is the user's own left shoulder).

**Unity humanoid space** (VMC, `/synkinect/bone`, JSON `space:"unity"`, SDK
`humanoidBones()`): left-handed, +X right, +Y up, +Z forward, metres; the avatar
faces +Z and its left side is at -X. The floor is Y = 0.

Conversion, with `up` the gravity-up unit vector in camera space (floor normal
or accelerometer; `(0,-1,0)` when unknown):

```
Rg  = fromTo(up, (0,-1,0))            // minimal rotation: gravity alignment
p_U = diag(-1,-1,-1) · Rg · p_C        // same physical space, right→left-handed
p_U.y += floorOffset                   // floor plane d, else feet on Y=0
p_U.xz -= origin.xz                    // when root.center=true
```

`diag(-1,-1,-1)` has determinant -1, which is exactly the handedness change; it
sends the user's facing direction (toward the sensor, -Z_C) to +Z_U, up (-Y_C) to
+Y_U and the user's left (+X_C) to -X_U. All quaternions are computed on Unity
components with the standard Hamilton formulas (what `UnityEngine.Quaternion`
implements), so `(x, y, z, w)` can be assigned directly to
`Transform.localRotation`.

**Rest pose.** A VRM/Unity-normalised T-pose facing +Z where every bone has
identity rotation. Rest bone directions: spine/neck +Y, left arm -X, right arm
+X, legs -Y, feet ≈ normalize(0,-0.4,1).

**Rotations.** Global rotation `G` of each bone maps the rest frame onto the
measured frame: *swing* takes the rest direction onto the measured bone
direction; *twist* comes from a secondary axis:

| Bone | Direction | Twist source |
|---|---|---|
| Hips | HipCenter→Spine | hip line (HipLeft→HipRight) |
| Spine / Chest | Spine→ShoulderCenter | mean hip+shoulder line / shoulder line |
| Neck | ShoulderCenter→Head | shoulder line |
| Head, Left/RightShoulder | — | local identity (no face / clavicle measurement) |
| UpperArm | Shoulder→Elbow | elbow bend plane (forearm ⊥ upper arm, rest +Z) |
| LowerArm | Elbow→Wrist | thumb (rest +Z) when tracked |
| Hand | Wrist→HandTip (or Hand) | thumb when tracked |
| UpperLeg | Hip→Knee | knee bend plane (shin ⊥ thigh, rest -Z) |
| LowerLeg | Knee→Ankle | foot direction (rest +Z) |
| Foot | Ankle→Foot | swing only |

When the twist axis is degenerate (straight elbow/knee, untracked thumb) the bone
takes the minimal swing from its parent (hinge behaviour); the two solutions
are blended smoothly by the bend amount. `LOCAL = conj(G_parent) · G`. A bone
whose joints are not tracked holds its previous local rotation. Rest bone
lengths are learned per tracking ID (running mean, then slow EMA) and drive the
local bone offsets and the BVH hierarchy.

**Mirror.** Reflection across the avatar's sagittal plane: positions
`x → -x`, quaternions `(x,y,z,w) → (x,-y,-z,w)`, Left/Right bones swapped.

## Endpoints and message formats

### VMC protocol (OSC 1.0 / UDP, default 127.0.0.1:39539)

One OSC bundle per frame (time tag `1` = immediately):

| Address | Arguments |
|---|---|
| `/VMC/Ext/OK` | `i` 1 (model loaded) |
| `/VMC/Ext/T` | `f` time in seconds since the stream started |
| `/VMC/Ext/Root/Pos` | `s "root"`, `f px,py,pz`, `f qx,qy,qz,qw` — always origin / identity |
| `/VMC/Ext/Bone/Pos` | `s name`, `f px,py,pz` (local position), `f qx,qy,qz,qw` (local rotation) |

Bones: `Hips, Spine, Chest, Neck, Head, LeftShoulder, LeftUpperArm, LeftLowerArm,
LeftHand, RightShoulder, RightUpperArm, RightLowerArm, RightHand, LeftUpperLeg,
LeftLowerLeg, LeftFoot, RightUpperLeg, RightLowerLeg, RightFoot`. The `Hips`
local position is the hips position in the room (Y = height above the floor);
other local positions are the T-pose offsets from the parent. `UpperChest` and
`Toes` are not sent (optional in Unity humanoids).

### Plain OSC (UDP, default 127.0.0.1:39542)

One bundle per frame:

- `/synkinect/frame` `i frame, f time_s, i trackingId, i tracked(0/1), f upX, upY, upZ`
- `/synkinect/joint` × 24 `s name, f x, y, z, f confidence` — Kinect v1 names, camera space
  (`HipCenter … FootRight`, then `HandTipLeft, ThumbLeft, HandTipRight, ThumbRight`)
- `/synkinect/bone` × 19 `s name, f px, py, pz, f qx, qy, qz, qw` — Unity space, global position and rotation

### JSON (UDP datagram per frame, default 127.0.0.1:39541; WebSocket ws://127.0.0.1:39540/)

```json
{"v":1,"device":"kinect-xbox360:0","t":1234.567,"frame":8812,"space":"unity","mirror":false,
 "bodies":[{"id":7,"tracked":true,"confidence":0.91,
   "joints":{"Hips":{"p":[0.0,0.95,0.0],"q":[0,0,0,1],"g":[0,0,0,1],"c":0.9}, "...":{}}}]}
```

- `t`: host monotonic seconds; `frame`: depth frame number.
- `space:"unity"`: keys are humanoid bones; `p` global position, `q` local rotation,
  `g` global rotation, `c` confidence.
- `space:"camera"`: keys are Kinect joint names; `p` camera-space position, `c`
  confidence, `s` state (0 lost, 1 inferred, 2 tracked, 3 predicted, 4 occluded).
- `bodies` is empty when nobody is tracked.

The WebSocket server implements the RFC 6455 handshake, sends one unmasked text
frame per pose to every client (up to 16), answers pings with pongs and ignores
client data frames. Browser example:

```js
const ws = new WebSocket("ws://127.0.0.1:39540/");
ws.onmessage = e => { const f = JSON.parse(e.data); const b = f.bodies[0];
  if (b) console.log(b.joints.LeftHand.p); };
```

Python: `websockets.connect("ws://127.0.0.1:39540/")` or a UDP socket bound to
39541 with `json.loads(data)`.

## Connecting applications

- **VSeeFace**: *Settings → General settings → OSC/VMC receiver*: enable, port
  `39539`. Tick *Apply VMC tracking data* for the body; keep face tracking in
  VSeeFace if desired. If VSeeFace is on another PC set `vmc.host` to its IP and
  `bindAddress` to a routable local address.
- **VirtualMotionCapture / Warudo / VNyan / other VMC performers**: enable the VMC
  receiver on port 39539 (or 39540 — use the *VMC port* button).
- **Unity — EVMC4U**: add the `ExternalReceiver` prefab, assign your VRM/humanoid
  model, port 39539. Bone rotations are applied as local rotations of the
  normalised humanoid; enable root position if the avatar should walk.
- **Blender — VMC4B**: install the add-on, select the armature, set the receiver
  port to 39539 and start. Use a VRM/rigify armature mapped to humanoid names.
  For keyframe capture use VMC4B's recording or record a BVH here.
- **Unreal — VMC4UE**: add the VMC4UE OSC receiver (port 39539) and a VRM4U-imported
  skeleton; use the VMC4UE animation node in the AnimBP.
- **Custom tools**: OSC libraries (python-osc, oscP5, CNMAT) for `/synkinect/*`, or
  JSON over UDP/WebSocket.

## BVH recordings

Press **Record BVH**, perform, press **Stop BVH**. The file contains:

- `HIERARCHY` with the 19 humanoid joints (HumanBodyBones names), offsets from the
  rest bone lengths learned when recording started, T-pose, in **centimetres**;
  `End Site`s for Head, Hands and Feet.
- Root `Hips`: `Xposition Yposition Zposition Zrotation Xrotation Yrotation`; other
  joints `Zrotation Xrotation Yrotation` (R = Rz·Rx·Ry, degrees, unwrapped for
  continuity).
- BVH space: right-handed, Y up, character facing +Z, its left at +X (CMU
  convention): `x_bvh = -x_unity`, quaternion `(x,y,z,w) → (x,-y,-z,w)`.
- `Frame Time` = average interval between recorded frames (≈ 0.033 s).

**Blender**: *File → Import → Motion Capture (.bvh)*, scale 0.01 (cm → m),
Forward `Z`, Up `Y`. **MotionBuilder**: *File → Motion File Import*, then
characterize the skeleton (names match the HumanIK auto-mapping for most joints;
map `LeftUpperArm→LeftArm`, `LeftLowerArm→LeftForeArm`, `LeftUpperLeg→LeftUpLeg`,
`LeftLowerLeg→LeftLeg` if prompted).

## Module SDK

External modules can consume the same tracker without linking against Studio
internals:

```java
StudioBodyTracking body = context.bodyTracking(null); // selected Kinect; null if unsupported
AutoCloseable sub = body.subscribe(frame -> {
    StudioBodyJoint hand = frame.joint("HandRight");          // camera space
    StudioBodyJoint arm  = frame.humanoid("RightUpperArm");   // Unity space, local rotation
});
// ... sub.close(); body.close();
```

`StudioModuleContext.bodyTracking` is a default method (API version stays 1).
The session follows the module's activation: frames flow only while the module
is active. Each subscriber has its own latest-only mailbox and thread.

## Shared Body3D preview

Motion Capture uses the same `BodySkeletonPreview` as Interactivity. Its camera follows a weighted torso anchor and applies a bounded safety fit so the segmented point cloud, skeleton and hand detail remain inside the 3D panel during lateral/depth motion and window resizing. The preview state is reset when Motion Capture activates or the selected Kinect changes; this prevents a reused session-local tracking ID from inheriting the previous subject's presentation origin. These transforms affect only the on-screen preview: retargeted humanoid poses, VMC/OSC/JSON/WebSocket output and BVH recording continue to use the calibrated `BodyFrame` coordinates.

## Limitations

- Single person (the SynSkeleton primary body); one `bodies` entry.
- No head/face orientation and no clavicle motion (local identity); no finger
  bones in VMC (hand landmarks are used only for hand twist when tracked).
- Upper-arm/forearm twist is inferred from the elbow plane and thumb; with a
  straight arm and no thumb it falls back to minimal swing.
- Streams are unauthenticated and unencrypted; keep `bindAddress=127.0.0.1`
  unless on a trusted network.
- Receiver
  integrations (VSeeFace, EVMC4U, VMC4B, VMC4UE) follow the public VMC protocol
  specification and still need validation with real hardware.
