<div align="center">

# Sensor Calibration

### Guided RGB + metric-depth calibration with explicit review and save steps

[Documentation](README.md) · [Quick start](QUICKSTART.md) · [Architecture](ARCHITECTURE.md)

</div>

`Sensor Calibration` is an auxiliary Studio frontend. It owns its RGB-D session and calibration candidate, follows the Kinect selected in the Studio shell, and does not require the 3D Scanner module to be active. Its labels and actions follow the Studio locale immediately while the window is open. Standard actions use the same host button palette, hover outline, disabled state and sizing language as the main Studio frontend.

The calibration profile is stored per active Kinect. Changing the selected Kinect while the window is open cancels any in-progress candidate, switches the RGB-D session to the new active depth device and loads that device's saved profile. Saving or resetting emits a host depth-calibration context event so consumers can reload the profile without depending on the calibration window implementation.

Use one flat, matte white wall with no people, furniture, corners, windows, strong shadows, or reflective objects in the target area. Keep the wall filling most of RGB and Metric Depth. Press **Calibrate**, hold the Kinect still for each station, then move it closer to or farther from the same wall when instructed. The default profile uses five separated distance stations so the correction can estimate per-pixel scale, offset, and noise instead of fitting one distance only.


<p align="center"><img src="images/synkinect-studio-sensor-calibration.png" alt="SynKinect Studio Sensor Calibration" width="100%"></p>

The window reports live wall coverage and planar RMS. A completed candidate is not persisted automatically. Review its classification and metrics, then press **Save calibration**. **Reset calibration** cancels the current candidate, deletes the saved per-device profile, and returns that Kinect to the nominal sensor model.

Quality is an engineering diagnostic, not a factory Kinect certification. `Good` currently requires at least 70% calibrated-pixel coverage and post-fit training RMS <= 8 mm without regression. `Regular` requires at least 50% coverage and RMS <= 16 mm. Other completed profiles are `Poor`; no saved profile is `No calibration`. These thresholds can be tuned after physical validation.

Calibration primarily affects metric depth. Better residual error and coverage can reduce depth-related surface noise, registration drift, and dimensional error in 3D scanning. It cannot correct motion blur, occlusion, reflective/transparent surfaces, missing depth, poor scan technique, or all RGB/depth extrinsic errors.
## Module consumption

Depth calibration is a Studio service rather than Scanner-owned UI state. Built-in RGB-D consumers reload the active profile when calibration changes. External Java modules can query `StudioModuleContext.depthCalibration()` for the selected Kinect or `depthCalibration(deviceId)` for a specific Studio-qualified device. The returned `StudioDepthCalibration` is immutable and exposes profile dimensions, coverage/RMS metadata, `correctDepthMm(pixelIndex, rawMm)` and calibrated per-pixel noise.

Modules that cache calibration-dependent geometry should react to `StudioContextEvent.DEPTH_CALIBRATION_CHANGED`, reacquire the profile from the context and invalidate any depth-registration or metric-coordinate cache. A missing profile is reported as `null`; modules should then continue with the device's nominal/factory metric-depth model.
