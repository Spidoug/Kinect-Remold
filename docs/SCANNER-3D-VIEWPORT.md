<div align="center">

# Scanner 3D Viewport

### Navigation, partial reconstruction and coordinate-safe mesh workflows

[Documentation](README.md) · [Sensor calibration](SENSOR-CALIBRATION.md) · [SynSkeleton](SKELETON-3D-ARCHITECTURE.md)

</div>

The reconstruction viewport is a metric 3D workspace rather than a camera-image preview.

## Navigation

- Left drag orbits around the current reconstruction center.
- Right drag pans in the current camera plane.
- Mouse wheel zooms around the cursor anchor.
- Middle click resets the orbit, pan and zoom to the fitted reconstruction view.
- **Reset** clears reconstruction state without changing the current viewport camera; orbit, pan and zoom are preserved.
- A newly-created reconstruction is framed automatically. Live mesh refreshes do not override a view after the user has adjusted it.

## Scene guide

The reconstruction surface uses a neutral light-gray CAD-style background. The ground grid is rendered on the lower face of the reference cube. Generated meshes receive a display-only vertical offset so their lowest point rests on that floor, while the XYZ reference remains anchored at the reconstruction origin. This presentation transform never changes the stored mesh, ICP poses, TSDF, Mesh Tools input, or exported coordinates.

## Partial reconstruction and Mesh Tools

A complete revolution is a quality target, not a prerequisite for mesh processing. Build Mesh, Clean, Smooth, Center and export can operate from a partial reconstruction once at least one frame has actually been accepted into the TSDF.

When a mesh operation is requested during active capture, the Scanner pauses ingestion, clears pending reconstruction work, takes a coherent TSDF snapshot when necessary, and performs the operation while capture remains paused. The operator resumes acquisition explicitly. This prevents editing and fusion from racing over mutable reconstruction state and makes the point-cloud-to-mesh transition deterministic.

Undo remains available for mesh edits. Operations that require actual geometry remain disabled until either a mesh exists or at least one frame has been accepted into the TSDF. Clicking a disabled Scanner action reports the blocking reason in the status footer instead of failing silently.

## Coordinate integrity

Viewport orbit, pan, zoom, grid and axes never transform the stored mesh. Exported geometry remains in the Scanner metric coordinate system regardless of the current camera view.

## Projected auto-framing

The Scanner viewport fits the reconstructed geometry from its projected extents after the current orbit rotation, rather than from a spherical scene radius. Tall human scans, seated subjects and narrow objects therefore use substantially more of the viewport. The fit is smoothed between frames, while user orbit, pan and zoom remain additive controls. Robust 1st/99th percentile bounds keep isolated reconstruction outliers from forcing the useful scan to shrink.

## Backend surface confidence and reciprocal ICP

The Scanner point-cloud builder now evaluates local surface support in addition to range, calibrated depth confidence and edge confidence. A 3x3 metric-depth neighborhood estimates coherent support and local depth variance; isolated structured-light noise and unstable edge pixels are down-weighted or removed before registration and TSDF integration.

Realtime ICP now applies a reciprocal correspondence check. A current-frame point may match the accumulated reference only when the reference point also maps back to the same local source neighborhood within a bounded metric tolerance. This suppresses many-to-one correspondences at silhouettes, self-occlusions and newly revealed turntable surfaces. Reciprocal filtering is combined with trimmed residuals, robust weighting, overlap gating and the turntable motion prior.

Turntable mode now uses a locked metric Bounding Box as the primary background mask. The first coherent object component bootstraps the box; subsequent tracking accepts every valid point inside that fixed volume, including a textured rotating plate, and rejects the static room outside it. Optional synchronized RGB contributes only a bounded photometric correspondence weight, so color can disambiguate repeated geometry without overriding metric depth.

Relevant controls are `cloud.surfaceNoiseM`, `cloud.minimumSupport`, `tracking.icpReciprocal` and `tracking.icpReciprocalToleranceM`.

## Rotation-axis regularized pose composition

The realtime tracker first solves the complete rigid ICP pose (XYZ translation plus pitch, yaw and roll). In turntable mode, that solution is then compared with a rotation around the locked gravity-aligned target axis. When the axis-constrained pose explains the observed surface within the configured score slack, it is preferred and only a small bounded translation residual is retained. If unrestricted SE(3) is materially better, the full pose is preserved.

This keeps natural subject motion possible while preventing silhouette changes from being accumulated as false camera-space drift. The coarse-to-fine turntable yaw search remains the initial motion hypothesis; reciprocal correspondences, robust residual trimming, pose regularization, and fusion-consistency gates decide whether a frame can enter the TSDF.

The point-cloud builder keeps the dominant connected target component inside the selected metric volume, so same-depth islands from walls, furniture, or unrelated background surfaces do not enter registration or fusion. HQ reconstruction also guards each offline ICP refinement against implausibly large deviation from its accepted realtime keyframe pose before reintegration.


### Continuous turn tracking and fused coverage

The Scanner keeps two angular states. The continuous turn angle advances from every stable ICP pose, so slow rotation remains visible even when an anti-ghosting check rejects a frame. Fused coverage advances only after successful TSDF integration. The UI percentage and TURN metric report tracked motion; the coverage strip and automatic full-turn completion remain tied to confirmed fused sectors. The turntable seed uses geometry plus bounded registered RGB evidence and a low-angle deadband so slow physical rotation is not quantized to zero.

### Registered point-cloud capture preview

While **Scan** is active, the 3D viewport no longer switches to a periodically extracted mesh. Accepted frames are transformed by the current ICP pose and accumulated into a bounded voxelized point model; the latest tracked frame is composited over that model as a transient registration preview. This keeps reconstruction growth and ICP alignment visible without paying the live-meshing cost or hiding tracking errors behind a surface.

After the metric Bounding Box locks, it becomes the primary segmentation authority. The initial depth-target detector is no longer allowed to drop the scan merely because a rotating face moves nearer/farther inside the locked volume. Full-turn detection uses filtered signed yaw, direction hysteresis and reverse-jitter suppression. Small ICP reversals are ignored; sustained physical reversal is interpreted as real motion.

Completing a turn preserves the accumulated point cloud and pauses capture. Mesh generation is explicit through **Build Mesh** or **Refine HQ**.


## Turntable registration stability

When the target rotates in place, realtime tracking regularizes the converged ICP pose around the locked vertical rotation axis. Unrestricted SE(3) remains available only when it explains the observed depth surface materially better. This prevents small silhouette changes from accumulating as false XYZ translation, pitch, or roll and producing duplicated shells in the TSDF.

The constraint retains a small bounded translation residual for natural subject motion. Fusion still applies TSDF-surface and rolling-reference consistency tests before accepting geometry. The relevant controls are `tracking.turntable.poseConstraint`, `tracking.turntable.constraintScoreSlack`, `tracking.turntable.constraintTranslationM`, and `tracking.turntable.constraintTranslationAuthority`.

## Mesh view state

**Build Mesh** and **Refine HQ** are explicit transitions from acquisition preview to editable mesh view. If capture was running it is paused, pending reconstruction work is drained, and the generated mesh owns the viewport. Pressing **Resume** returns the viewport to the registered point reconstruction without discarding the generated mesh data.

Texture mode renders registered TSDF/HQ vertex color whenever it is available. Solid mode renders the same mesh with the Scanner material. Clean, Smooth, Center, and Undo replace the displayed mesh immediately and trigger a fresh frontend fit; they never modify the camera-space acquisition data or ICP state.

## Stable scanner auto-fit

Scanner auto-fit is intentionally slower than body-tracking auto-fit. Reconstruction bounds are noisy while new sides become visible, so both zoom and recentering use a wider dead-band, delayed zoom-in, and low response gains. Manual orbit, pan, and zoom remain additive and are not written back into reconstruction coordinates.


## Offline reconstruction from imperfect live tracking

The point-cloud viewport is diagnostic and is not the final reconstruction authority. Build Mesh and Refine HQ retain usable RGB-D keyframes independently of realtime TSDF acceptance. Mesh generation estimates a canonical sweep-axis prior, performs coarse-to-fine bidirectional ICP against neighboring keyframes, validates each corrected pose against local consensus, rejects incompatible outliers, applies distributed loop closure on a completed turn, and reintegrates only the corrected set into a fresh TSDF. Consequently, visible pose drift or duplicate shells in the acquisition preview do not have to be baked into the generated mesh. Refine HQ uses the same recovered pose graph with the high-resolution TSDF and multi-frame depth super-resolution profile.
