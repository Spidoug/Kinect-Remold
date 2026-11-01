<div align="center">

# Sensor calibration

### Guided RGB + metric-depth calibration with explicit review and save steps

[Documentation](README.md) · [Quick start](QUICKSTART.md) · [Architecture](ARCHITECTURE.md)

</div>

`Sensor Calibration` is an auxiliary Studio frontend. It owns its RGB-D session and calibration candidate, follows the Kinect selected in the Studio shell, and does not require the 3D Scanner module to be active. Its labels and actions follow the Studio locale immediately while the window is open. Standard actions use the same host button palette, hover outline, disabled state and sizing language as the main Studio frontend.

The calibration profile is stored per active Kinect. Changing the selected Kinect while the window is open cancels any in-progress candidate, switches the RGB-D session to the new active depth device and loads that device's saved profile. Saving or resetting emits a host depth-calibration context event so consumers can reload the profile without depending on the calibration window implementation.

Use one flat, matte white wall with no people, furniture, corners, windows, strong shadows, or reflective objects in the target area. Keep the wall filling most of RGB and Metric Depth. Press **Calibrate**, hold the Kinect still for each station, then move it closer to or farther from the same wall when instructed. The default profile uses eight separated distance stations (30 frames each). Cover the whole working range, for example 0.7 m to 3.5 m. Squareness to the wall is not required: tilts of ±20° are fine and help the fit.


The window reports live wall coverage and planar RMS. After the last station, the model is fitted on a background thread in a few seconds. A completed candidate is not persisted automatically. Review its classification and metrics, then press **Save calibration**. **Reset calibration** cancels the current candidate, deletes the saved per-device profile, and returns that Kinect to the nominal sensor model.

Quality is an engineering diagnostic, not a factory Kinect certification. The UI classifies the profile from leave-one-station-out validation RMS (see below) rather than from the samples used to fit the correction. `Good` currently requires at least 70% calibrated-pixel coverage and validation RMS <= 8 mm without regression; `Regular` requires at least 50% coverage and validation RMS <= 16 mm. Training RMS is used only as a fallback when a holdout result is unavailable. Other completed profiles are `Poor`; no saved profile is `No calibration`. These thresholds can be tuned after physical validation.

Calibration primarily affects metric depth. Better residual error and coverage can reduce depth-related surface noise, registration drift, and dimensional error in 3D scanning. It cannot correct motion blur, occlusion, reflective/transparent surfaces, missing depth, poor scan technique, or all RGB/depth extrinsic errors.
## Module consumption

Depth calibration is a Studio service rather than Scanner-owned UI state. Built-in RGB-D consumers reload the active profile when calibration changes. External Java modules can query `StudioModuleContext.depthCalibration()` for the selected Kinect or `depthCalibration(deviceId)` for a specific Studio-qualified device. The returned `StudioDepthCalibration` is immutable and exposes profile dimensions, coverage/RMS metadata, `correctDepthMm(pixelIndex, rawMm)` and calibrated per-pixel noise.

Modules that cache calibration-dependent geometry should react to `StudioContextEvent.DEPTH_CALIBRATION_CHANGED`, reacquire the profile from the context and invalidate any depth-registration or metric-coordinate cache. A missing profile is reported as `null`; modules should then continue with the device's nominal/factory metric-depth model.

## Absolute reference distance

A flat wall constrains shape, not size. Scaling every depth by a common factor, or adding a constant disparity offset, keeps every plane planar, so wall captures alone cannot observe global scale. The window therefore has an optional **Reference distance (m)** field. Measure the distance from the sensor front to the wall along the optical axis (image centre) with a tape for one or more captured stations. Enter it as `1.20`, or as `1.20; 2.40` for several, then press **Apply reference** (or Enter) and save.

Each value is matched to the captured station whose centre distance is closest, within ±12 % (`referenceMatchTolerance`). The absolute model is `1/z_true = g·(1/z) + o`:

* One reference, or references closer together than 0.25 m⁻¹ in inverse depth: gain only (`o = 0`), i.e. `z_true = s·z` with `s = 1/g`.
* Two or more references spanning at least 0.25 m⁻¹: least-squares gain and disparity offset.

A reference that implies a scale more than 10 % from 1 (`referenceMaxScaleError`), or an offset above 0.08 m⁻¹, is rejected. Without a reference, scale stays 1.0 and the result text says so. References can also be applied to a loaded v3 profile, because per-station centre distances are stored in it. The result text shows the scale, the reference residual, and each referenced station's centre error before and after.

## Method

1. **Robust station depth.** Each station keeps its raw frames (default 30). Per pixel, the Studio drops pixels valid in fewer than 60 % of frames and takes a trimmed temporal mean (20 % trimmed at each end). It also estimates noise σ as the larger of the trimmed std and IQR/1.349. Flying pixels are rejected when σ exceeds `flyingPixelSigma` × the expected noise at that range, when the temporal spread exceeds 25 % of range, or when the pixel differs from a 4-neighbour by more than 5 % of range + 10 mm.
2. **Plane in inverse depth.** Every depth pixel owns one undistorted normalized ray `(x̂, ŷ)` from `Calibration.rays()`. This is the table `RgbDepthRegistration` uses at runtime: Brown-Conrady inverse of the device's depth distortion, with pixel convention `x_d = (u + pixelCenter + depthShiftU − cx)/fx`. A plane is exactly linear in inverse depth over these rays: `1/z = a·x̂ + b·ŷ + c`. It is fitted by Huber IRLS (scale from MAD, hard rejection beyond 6σ), and the predicted depth is `1/(a·x̂ + b·ŷ + c)`. Frame and station gates use the inverse-depth RMS, which equals the metric RMS at 1 m (`planeResidualMaxM`). Far stations are therefore not rejected for Kinect quantisation noise.
3. **Distance-aware residual field.** The Studio models the inverse-depth residual `R(u,v,w) = w_plane − w_measured`, with `w = 1/z`, on a coarse lattice of 40 × 30 control points × 8 bins. The bins are spread evenly in `w` over the robust range of the stations. R is evaluated bilinearly in (u,v) and linearly in w, and clamped outside the calibrated range. Working in inverse depth matches the Kinect v1 disparity distortion (Herrera et al. 2012, Smisek et al. 2011). That distortion is a smooth spatial pattern whose disparity amplitude decays with distance. In inverse depth it is well conditioned across the range, whereas in millimetres it grows with z².
4. **Solver.** Weighted least squares with per-station weights `1/σ_s²`. σ_s is the station's median per-pixel noise of the mean in inverse depth, plus a small floor for bias that averaging cannot remove. Regularisation combines second-difference (Laplacian) smoothness with a weak first-difference term, along u, v and the depth axis, plus a tiny ridge. Every sample is first aggregated into a per-station 27-point normal-equation stencil. The system is then solved by Jacobi-preconditioned conjugate gradient, dependency-free.
5. **Validation and regularisation choice.** Leave-one-station-out: for each station, the model is solved without that station's normal equations and applied to its data. A robust plane is refitted to the corrected depth, and RMS, mean |e| and p95 are reported in mm against that plane, before and after. The smoothing weight is picked from {0.03, 0.3, 3} × the mean data diagonal by the lowest pooled validation RMS (`regularization=0`). A positive value fixes it. The final model uses all stations.
6. **Runtime.** On load, the profile expands the grid into a per-pixel table with one value per depth bin. Correction is `w_c = g·(1/z + R) + o`, then `z = 1/w_c`: two lookups and one interpolation per pixel. With no profile, or with `calibration.depthCorrection.enabled=false`, correction is the identity.

The design is based on these requirements:

* The residual must be a function of distance, not a per-pixel affine map in millimetres. A per-pixel affine fit of measured-to-plane depth over pinhole rays is biased: a plane is not linear in z over pinhole rays, and the fit uses rays that differ from those used at runtime. It also overfits noise with two free parameters per pixel. In the ground-truth benchmark, it made shape error worse than no correction at all.
* The model must use the same rays at calibration and at runtime.

## Benchmark

The correction model can be evaluated against synthetic wall captures with known geometry, scale distortion, noise and quantisation. Numerical accuracy must be verified on the target hardware.

## Profile storage and compatibility

Profiles are stored in `core/rgbd/calibration/<key>.depthcal`. The key is the Studio registry key (`module:id`), with fallback to the legacy bare device id. Format v3 stores:

* the model type, grid size, bins and inverse-depth range, and the regularisation used
* absolute gain/offset, the reference count and residual
* a hash of the depth geometry the model was fitted with: size, intrinsics, distortion, pixel convention and shift
* per-station centre, reference and validation metrics
* the grid, and per-pixel noise

A v3 profile is applied only while the current depth geometry has the same hash. If the intrinsics change, recalibrate. Legacy v2 files (per-pixel affine) still load and apply unchanged, and the window labels them as legacy. Saving writes v3 under the registry key and removes the legacy file.

For `StudioDepthCalibration`, a v3 profile also exposes a per-pixel affine approximation (least squares over the calibrated range) through the existing `correctDepthMm` API.

## Depth geometry per device

`Calibration` owns the depth geometry per device: intrinsics, Brown-Conrady `k1 k2 k3 p1 p2`, pixel-centre convention and depth-image shift. It builds the single undistorted ray table. `SkeletonCalibration3D.projectDepth` is the exact inverse of deprojection: forward distortion, intrinsics, then the same pixel convention. It also indexes rays with the device's real frame width (640 × 480 or 512 × 424).

* **Kinect 360**: `calibration.depth.*` from `config.properties`. `calibration.depthShiftU/V` (default 0) model the known depth-to-IR image offset of a few pixels. The sign depends on how `cx`/`cy` were calibrated, so set them only when measured for the configured intrinsics.
* **Kinect One**: the native driver reports the factory intrinsics in the v1 reply. A client that sets `RequestV2.deviceId[63] = 0xC3` (id ≤ 62 bytes) receives `depthCalibrationValid = 3` and a 64-byte `ReplyExtension` after the 68-byte reply. The extension carries the factory depth distortion, the ray pixel-centre convention (u + 0.5) and the factory color intrinsics (f, cx, cy, shift_d, shift_m). Older drivers ignore the marker and keep sending the 68-byte reply. Studio then uses zero distortion with the 0.5 pixel-centre convention, and no longer applies the Kinect 360 distortion defaults to Kinect One. Color intrinsics are stored per device in `Calibration` for registration consumers.

## Configuration

`data/scanner/config/config.properties`, `calibration.depthCorrection.*`:

* capture: `stations`, `framesPerStation`, `distanceSeparationM`, `stabilityToleranceM` (scaled by z²), `planeResidualMaxM` (inverse-depth RMS at 1 m)
* robust statistics: `trimFraction`, `flyingPixelSigma`, `noiseFloorM`, `noiseCeilingM`
* model: `gridX`, `gridY`, `depthBins`, `regularization`, `minimumStationsPerPixel` (coverage)
* references: `referenceMatchTolerance`, `referenceMaxScaleError`
* legacy v2 profiles only: `slopeMin`, `slopeMax`, `offsetMaxM`

