# Scanner 3D — capture, reconstruction and viewport

## Execution model

The Scanner deliberately separates **capture** from **reconstruction**.

### Scan — realtime, latency-bounded

`Scan` does not create or update a TSDF/Surface-SDF and does not run global pose optimization, loop closure, deformation graph or mesh extraction. Its jobs are limited to:

- metric Depth/RGB acquisition;
- foreground target lock from Depth;
- support-plane / turntable ROI handling where applicable;
- lightweight temporal ICP used only to estimate motion;
- instantaneous turn/view coverage;
- quality diagnostics;
- selection and storage of RGB-D keyframes;
- a bounded decimated point-cloud preview.

This makes the displayed angle/capture progress independent from the speed of mesh reconstruction.

### Build mesh — first dense reconstruction

`Build Mesh` pauses capture if necessary and starts the first dense/offline reconstruction from the retained keyframes. The balanced path performs global pose recovery and builds a fresh TSDF only inside the background mesh task. No live TSDF is kept during Scan.

### Refine HQ — maximum-quality reconstruction

`Refine HQ` goes back to the retained RGB-D keyframes and runs the FULL QUALITY engine:

1. organized coarse-to-fine point-to-plane ICP;
2. loop-closure candidate validation;
3. global SE(3) pose-graph optimization;
4. deformation-graph correction;
5. normal-oriented Surface-SDF fusion;
6. surface extraction and detail-preserving polish.

The existing mesh is never required as the geometric source of truth; the captured keyframes are.

## Buttons and state transitions

- **Mode** — switches Turntable / Fusion only before a capture session starts.
- **Scan** — starts capture. While active it becomes **Pause**; while paused it becomes **Resume**.
- **Reset** — discards the current capture/reconstruction session and cancels mesh/HQ work when safe.
- **Build Mesh** — available after enough keyframes exist; starts the balanced offline reconstruction.
- **Refine HQ** — starts the maximum-quality offline reconstruction from the source keyframes.
- **Clean / Smooth / Center / Undo** — operate only on an already generated mesh.
- **STL / OBJ / PLY** — export the current mesh. If capture changed after the last mesh, the Scanner rebuilds before export rather than silently exporting stale geometry.
- **Surface mode** — changes final mesh presentation/output preference; it does not trigger reconstruction.

There is intentionally no **Finish** operation. A completed turn pauses capture; the user can build/refine the mesh or resume acquisition.

## Foreground Depth lock

Before Scan starts, idle Depth detection identifies a stable foreground subject. Starting Scan freezes that subject as the capture target. During acquisition:

- small gradual distance changes are followed with conservative smoothing;
- temporary loss keeps the previous subject depth instead of reacquiring the strongest depth histogram mode;
- a large jump to a distant wall is rejected;
- the tracking cloud stays inside a foreground depth band around the locked subject;
- Fusion may widen that band when geometry is sparse, but it widens around the same subject depth and never falls back to an unrestricted room cloud.

This is the Scanner equivalent of focus lock: Depth determines what the object is; the background cannot steal the target merely because it contains more pixels.

## Turntable angle and 360-degree coverage

Turntable rotation is an acquisition measurement, not an integration side effect.

The instantaneous angle is updated from every accepted tracking pose. Coverage sectors are confirmed by the same tracking stream. When two accepted measurements jump across multiple angular sectors, every crossed sector is filled, so a slower UI/worker cadence does not create artificial holes in coverage.

A complete turn therefore does not depend on TSDF integration speed. When the configured full-turn criterion is reached, capture auto-pauses and preserves all keyframes; no mesh work starts automatically.

## Fusion capture progress

Fusion capture also remains reconstruction-free. Progress is derived from:

- retained keyframe count; and
- angular diversity of the recorded camera trajectory around the Depth-locked subject.

It is not computed from touched TSDF voxels. The trajectory panel and progress indicator can therefore remain realtime even when final reconstruction is expensive.

## Viewport policy

During Scan, the viewport renders a bounded decimated point-cloud accumulation plus the latest registered cloud. This is a visualization aid, not a reconstruction volume.

The viewport camera is frozen once capture establishes a coherent framing. Automatic fit is allowed while idle/final mesh presentation is active, but it does not continuously zoom/recenter during acquisition. Manual orbit, pan and zoom never modify tracking or reconstruction coordinates.

In Fusion, the wireframe target box represents the Depth-locked subject region, not a live TSDF. The camera trajectory is drawn independently from the final mesh.

## Scheduling and performance

Capture uses a newest-frame queue: when work falls behind, stale pending capture work is replaced rather than replayed. The capture cadence adapts to measured lightweight tracking cost. Dense reconstruction runs only in the low-priority mesh worker.

Opening the Scanner no longer allocates the old realtime 192³ TSDF. Dense volumes are allocated only inside Build Mesh / Refine HQ and released with those tasks. This reduces idle memory pressure and prevents the capture loop from doing work whose result would later be rebuilt offline anyway.

## Sensor calibration

Scanner calibration is not duplicated. The module consumes the shared `DepthCorrectionProfile` owned by the Studio **Sensor Calibration** area and reacts to `DEPTH_CALIBRATION_CHANGED`. New capture/reconstruction work therefore uses the same per-device calibration source as the rest of SynKinect Studio.
