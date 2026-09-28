<div align="center">

# SynSkeleton 3D Architecture

### Current 20-joint topology, fusion policy and runtime boundaries

[Documentation](README.md) · [Architecture](ARCHITECTURE.md) · [Scanner 3D](SCANNER-3D-VIEWPORT.md)

</div>

SynSkeleton is the Studio-wide, provider-neutral body-tracking layer used by built-in and external Studio modules. The current implementation exposes the Kinect Xbox 360 / NUI **20-joint body topology** and operates on calibrated RGB-D input. It does not currently expose Kinect v2 25-joint body output, articulated finger joints, palm landmarks, pinch/grab states or a native Kinect SDK skeleton relay.

## Current topology

The public pose contains 20 joints:

- HipCenter, Spine, ShoulderCenter and Head;
- left/right Shoulder, Elbow, Wrist and Hand;
- left/right Hip, Knee, Ankle and Foot.

Every tracked joint carries camera-space XYZ metres, image projection, confidence, state, velocity and temporal history used by the filtering and prediction stages. Tracking state distinguishes valid observations from inferred/held data internally, while NUI-facing surfaces may collapse state to the NUI representation.

## Fusion policy

Depth is authoritative for metric geometry. RGB is used for calibrated preview/registration and may support higher-level visual providers, but body metric position must remain consistent with registered depth before it can update the canonical pose.

The current dependency-free body solver uses calibrated metric depth to segment the person and estimate the 20-joint body. Observations then pass through temporal consensus, adaptive filtering, a constant-velocity Kalman stage, motion priors, kinematic constraints, anthropometric stabilization and depth-consistency checks before publication.

The native 20-joint body solver treats `HandLeft` and `HandRight` as terminal body joints. Articulated finger landmarks are a separate hand-detail layer and are never fabricated from body-depth geometry.

## Generation policy

Kinect Xbox 360 / v1 uses calibrated RGB-D with SynSkeleton as the Studio body source.

Kinect One / v2 currently exposes raw/native RGB, depth and infrared through the Remold runtime. SynKinect Studio may run the same 20-joint StudioBody3D/SynSkeleton layer on those calibrated frames, but the runtime must not claim native Microsoft Kinect SDK body-joint transport unless such a transport is actually implemented.

Provider extensions may add richer internal landmarks while preserving an explicit compatibility mapping for modules that consume the 20-joint ABI. Capability reporting is derived from the body data produced by the active runtime/Studio combination.

## Temporal and model stages

Each `SkeletonTracker` owns its own history so multiple modules or Kinect devices can track independently. The current pipeline includes:

1. depth-person segmentation and temporal identity affinity;
2. depth-based joint observations and full-resolution local refinement;
3. robust multi-frame temporal consensus;
4. One-Euro / confidence-aware filtering and innovation gating;
5. constant-velocity Kalman prediction and coherent root stabilization;
6. learned symmetric limb lengths and iterative articulated-body constraints;
7. short occlusion hold and posture-aware lower-body handling.

Shared tuning is stored in `applications/processing/SynKinectStudio/data/skeleton/config/config.properties` and loaded by `SkeletonConfig` in `Skeleton.pde`.

## Runtime boundary

SynSkeleton is an in-Studio service. The native driver transports camera frames and calibration metadata; it does not publish a NUI skeleton socket in the current integrated package. Built-in and external Studio modules obtain independent trackers through the Studio service layer rather than opening generation-specific skeleton transports directly.

## Typography

Studio text uses semantic sizes (`tiny`, `small`, `body`, `label`, `metric`, `title`, `button`) through `studioText()`. Modules must not call `textSize()` directly. Font selection prefers Unicode-capable Noto Sans / Noto Sans CJK, then Segoe UI, DejaVu Sans and logical SansSerif. Responsive scaling is viewport-based and language-independent; fitting may only reduce text when a translated string does not fit its control.

## Body3D live framing

Interactivity keeps the Body3D solver in calibrated camera coordinates and applies presentation framing only after tracking. Its frontend derives a bounded metric envelope from robust body-cloud and joint extents, then applies posture-aware minimum dimensions. Seated and partial bodies therefore use the 3D panel efficiently instead of being forced into a standing-height frame, while a full-body pose retains a stable human-scale minimum. Width/height caps reject isolated background outliers.

`StableViewportFilter` is host-side presentation infrastructure. Normal framing changes use deadband and asymmetric smoothing; large envelope growth uses a faster emergency zoom-out so an arm raised quickly stays visible, while zoom-in remains delayed to prevent breathing after a transient occlusion. The filtered center follows the robust metric envelope with bounded range rather than a fixed body offset.

Acquisition is independent from that frontend transform. SynSkeleton person segmentation already evaluates the complete depth frame. The Interactivity presentation cloud likewise samples the complete depth frame, then applies torso-relative metric X/Y/Z discovery bounds plus articulated body support; it has no screen-space crop derived from the rendered skeleton. Raising or extending an arm can therefore enter tracking and visualization while the previous pose is compact, and viewport zoom never feeds back into segmentation, joint fitting or desktop-control coordinates.

## Cloud-scale fitting and occlusion recovery

The segmented metric body cloud is the scale reference for the articulated model. Body3D smooths the measured cloud height, uses the current silhouette to stabilize shoulder and hip spans, and applies learned anthropometric lengths as soft constraints rather than allowing temporary missing depth to shorten a limb. Reliable observations update the learned model conservatively.

Each joint also owns motion and occlusion state. When a previously tracked joint disappears, Body3D predicts it from root translation plus bounded, decaying joint velocity for the configured occlusion hold. Reacquisition searches only the anatomical region and side that belong to that joint; an inferred hand therefore cannot become a torso point or silently swap to the opposite arm. Confidence decays while prediction is unsupported and rises only after compatible cloud evidence returns.

## Articulated cloud fusion

The Interactivity backend now treats the Body3D pose and the live depth surface as one metric model rather than two independent overlays. After person segmentation and articulated fitting, the body cloud is gated by 3D capsules that follow the tracked bones plus dedicated head/torso support volumes. Points that are inside the image crop but outside this articulated support are rejected.

After anthropometric and bone constraints, measured limb joints are conservatively re-attached to robust local depth support. Fusion is confidence-weighted and displacement-limited, so elbows, wrists, hands, knees, ankles and feet remain embedded in the observed surface without allowing a noisy depth patch to deform the skeleton. Torso-center joints use much weaker surface attraction because they represent internal anatomical centers rather than skin-surface points.

The shared skeleton profile also uses a denser body sample step, tighter full-resolution depth refinement and a slightly lower measurement-noise assumption. These settings trade some CPU time for improved joint precision while retaining temporal/Kalman and anthropometric stabilization.

## Depth-layer limb disambiguation

Body3D estimates a torso depth layer from the central chest/pelvis portion of the segmented metric cloud. Every cloud sample can then be described not only by body-relative left/right and vertical position but also by how far it sits in front of or behind the torso surface. This depth-layer evidence is part of arm/hand classification.

When an arm crosses the chest, projects over the opposite arm, or visually overlaps the torso, foreground depth evidence allows the arm to retain its limb identity even near the image centerline. When an arm is lowered, samples deep in the lower-body band are accepted as arm/hand evidence only when they have compatible lateral separation, foreground depth, bone length and temporal continuity. This prevents shin/ankle/foot points from becoming lowered arms while still allowing a real hand to pass in front of the hip or upper leg.

The same metric body cloud defines the body scale. Torso length and both lower-limb chains have minimum axial proportions tied to measured body height, while feet remain attached to the observed floor/depth layer. These constraints prevent the articulated model from collapsing vertically when some distal depth samples are temporarily missing.

## Limb and posture disambiguation

The Body3D solver explicitly handles four difficult poses that are common with Kinect Xbox 360 depth data:

- **arms fully lowered beside the body:** lower-body candidates receive a continuous penalty when they remain inside the leg corridor without foreground-depth evidence. This prevents lower-leg points from being promoted into wrists/hands without introducing hard threshold transitions that would make a real lowered hand flicker between hypotheses;
- **one arm in front of the chest:** foreground depth relative to the torso layer is treated as positive arm evidence, while torso anchors suppress that foreground layer. The arm can therefore pass across the sternum without pulling `Spine`, `ShoulderCenter` or `HipCenter` forward;
- **two arms crossing in front of the body:** centerline candidates are resolved with temporal identity, parent-chain distance and parent-to-candidate depth continuity. These terms are continuous scores rather than binary gates, so image-side position can become a weak cue near the centerline without causing one-frame left/right swaps;
- **seated versus standing:** missing ankles or feet are treated as partial/occluded evidence, not seated evidence. A seated state requires current knee/thigh geometry compatible with flexion; an extended hip-knee-ankle chain is positive standing evidence. Posture classification does not invalidate joints, so a one-frame classification change cannot damage the next frame's articulated prior.

The vertical normalization used by torso/hip extraction is robust to lowered-arm outliers. Torso anchors are fitted from the torso depth layer, and hip/shoulder side anchors use separate weighted regions, so resting arms no longer shorten the apparent trunk or raise the pelvis estimate.

## Anatomical frame continuity and support gating

The Body3D solver keeps its anatomical right/up/forward frame temporally coherent with the previously accepted torso and shoulder axes. This prevents PCA/silhouette changes caused by an extended arm, chair back or temporary occlusion from flipping the body frame and swapping left/right limb hypotheses.

Before a pose is published, peripheral joints are checked again against the current segmented metric-depth cloud. Elbows, wrists and hands accept the full overhead-arm range rather than a mid-torso vertical band, while side/anatomical constraints still prevent cross-body swaps. Fast distal motion uses a wider local reacquisition radius; a short evidence gap preserves an inferred same-side limb with decaying confidence instead of immediately deleting it. Once compatible depth returns, the joint is reattached to measured surface support. Lower-body checks remain conservative so stale limbs cannot move independently of the observed body surface.

### Raised-arm and bent-limb fitting

Upper-limb fitting uses the segmented metric surface as the final geometric authority. Elbow and wrist candidates are solved as a two-segment articulated chain rather than by placing both joints on the straight shoulder-to-hand chord. This keeps flexed and overhead arms coherent when the hand approaches or crosses the torso centerline.

The left/right classifier permits centerline overlap when either overhead geometry or foreground depth supports an arm crossing the torso. Side identity is then resolved by shoulder-root distance, torso-relative depth, temporal continuity, body-part likelihood and learned limb lengths. After temporal, Kalman and biomechanical stages, distal limbs are anchored to the current metric cloud again with a bounded correction. The cloud remains authoritative while isolated extremity noise cannot teleport the entire arm or leg chain in one frame.

The Interactivity point-cloud preview uses a shoulder-centered discovery volume for previously unseen arm surface instead of a rectangular torso volume. This keeps raised arms discoverable while rejecting most floor, chair and background points that would otherwise destabilize the frontend auto-fit. These visualization rules remain frontend-only and do not alter the sensor transport or module backend contract.

## Tracking-loss continuity

SynSkeleton treats a short loss of depth evidence as an occlusion, not as a new pose. The last coherent articulated pose is retained with bounded velocity prediction and decaying confidence for the configured occlusion window. Missing joints in otherwise valid frames are restored as `OCCLUDED` observations, and low-confidence reacquisition is blended against the last coherent joint before publication. A neutral/default pose is never synthesized during a transient miss; identity and pose state are reset only after the complete hold window expires.

## Desktop interaction controller

Interactivity can drive the operating-system pointer through `java.awt.Robot`. The control path is body-relative: shoulder direction defines the horizontal axis, the shoulder-to-spine direction defines the vertical axis, and the torso normal provides the forward/depth axis. Cursor position therefore follows hand motion in the user's body frame rather than raw camera pixels.

Desktop control is a frontend capability and can be armed at any time when `java.awt.Robot` is available; it is not blocked by Kinect readiness or a safety latch. The Enable control and Hand controls remain interactive independently from body-tracking readiness. Module hit testing uses the same content-local coordinate system as rendering and hover feedback. If no valid pose is available the controller simply waits without emitting pointer/button events. While control is enabled, the controller receives every current pose and owns its own tracking gate, hand-selection hysteresis, pointer filtering and release timeout. A transient confidence change therefore does not freeze the controller state. Auto hand mode scores both hands by confidence and forward reach and switches only after the configured hysteresis interval. Right and Left modes pin control to the chosen side.

Normal lateral/vertical hand motion controls pointer position even near the torso plane. Forward depth is primarily reserved for gestures: crossing the press threshold holds the primary mouse button for drag, returning through the release threshold releases it, two stable pushed hands issue a double click, and stable two-hand vertical motion without a held button produces wheel scrolling. Lost tracking, module deactivation, hand-mode changes and control disable all release any held mouse button. Multi-monitor bounds are discovered from the active Java graphics devices and the pointer is clamped to the combined desktop rectangle.
