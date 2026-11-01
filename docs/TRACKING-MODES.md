# Tracking configuration

Both operating systems use the same Studio tracking configuration at `applications/processing/SynKinectStudio/data/skeleton/config/config.properties`.

## Models

- `tracking.mode=rgb` (default): MoveNet ONNX body-pose model (`data/skeleton/movenet.onnx`). RGB frames must be synchronized with calibrated depth for 3D projection. MoveNet has 17 body keypoints; **it does not provide 21 finger landmarks**. Fine hand tracking in RGB mode therefore remains unavailable until a separate hand model and crop pipeline are integrated.
- `tracking.mode=depth`: `SynSkeleton.onnx` exported by Kinect DepthAutoLearn. Uses the calibrated metric-depth input `[1,1,240,320]` and `keypoints` output `[1,58,4]`, which includes left/right hand landmarks.

**Model weights are not bundled.** Use the proper ONNX model for the chosen backend; the two networks are not interchangeable. To select a mode and install a model from a local file:

```sh
python scripts/configure_tracking.py --mode rgb --model /path/to/movenet.onnx
python scripts/configure_tracking.py --mode depth --model /path/to/SynSkeleton.onnx
```

The command changes only the shared configuration and copies the requested model. Restart the Studio to apply it. For depth mode, copy `SynHand.onnx` only if the separately supported hand refiner is needed; there is no implicit hot reload.

## Operational constraints

RGB body landmarks are mapped back into depth space using the shared RGB-to-depth camera calibration. A landmark is dropped if it has no nearby valid depth measurement. This ensures a missing or unsynchronized RGB/depth stream cannot produce an invented metric position. The mapping is currently CPU intensive and has not been measured on real hardware.

The Studio does not silently substitute one mode for the other when a model or input is missing. Both modes use the same body-tracking block on Windows and Linux, but hardware drivers remain platform-specific. This configuration has not been validated with physical Kinect sensors or a built Studio.
