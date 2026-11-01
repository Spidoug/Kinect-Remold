# SynSkeleton 3D architecture

SynSkeleton is the single body-tracking layer used by SynKinect Studio, Interactivity, Motion Capture and external modules. The authoritative pose provider is `SynSkeleton.onnx`.

## Runtime model

The model is stored at:

```text
applications/processing/SynKinectStudio/data/skeleton/SynSkeleton.onnx
```

Packaged builds copy the same file to `data/skeleton/SynSkeleton.onnx` beside the Studio runtime. The model interface is documented by `SynSkeleton_layout.json`.

Input:

- `depth_metric`
- shape `1 × 1 × 240 × 320`
- depth values use the same normalization as the KinectDepthAutoLearn trainer.

Primary output:

- 58 landmarks
- each landmark is `[x_normalized, y_normalized, z_mm, confidence]`
- 16 head/body landmarks
- 21 left-hand landmarks
- 21 right-hand landmarks

The model may additionally expose structural `segments` and `endpoints`; the Studio pose API is driven by the landmark output.

## Processing path

`BodyTrackingSession` acquires the newest metric Depth frame and sends it to `SkeletonProcessingSession`. `SynSkeletonOnnx.pde` resizes the depth input to 320×240, runs ONNX Runtime, and converts every observed landmark back to the active device's depth geometry.

The output Z value is metric millimetres. XY is mapped to the current depth frame and deprojected with the selected Kinect's calibration. This produces the camera-space XYZ used by all Studio modules.

The model directly supplies head, shoulders, elbows, wrists, hips, knees, ankles and both 21-landmark hands. The Remold canonical API also needs shoulder-center, spine, hip-center, body-level hand, foot, hand-tip and thumb anchors. Those are derived only from currently observed SynSkeleton landmarks. They are topology adapters, not an independent pose estimator.

## No alternate pose fallback

If `SynSkeleton.onnx` is missing, fails to load, fails inference, or does not observe a hand/joint, the Studio does not invoke the old geometric or articulated pose solver. Missing hands are not synthesized.

A light temporal filter may smooth a landmark that is observed in consecutive frames. It never turns an unobserved current-frame hand into a rendered hand.

## Body cloud

Depth still provides the metric 3D surface shown in Body3D. The presentation cloud is selected around the current neural skeleton using joint/bone support distances. The point cloud is diagnostic/presentation evidence only and does not solve or replace the pose.

## Consumers

The same `SkeletonPose3D` snapshot is consumed by:

- Body3D visualization;
- Interactivity and desktop control;
- Motion Capture, VMC/OSC/JSON/WebSocket and BVH;
- module SDK body-tracking subscribers.

This guarantees that all skeleton-dependent Studio features use one pose authority: `SynSkeleton.onnx`.

## Build dependency

SynKinect Studio packages Microsoft ONNX Runtime Java. The Windows and Linux Studio build scripts download the pinned ONNX Runtime version declared in `config/build.env` and place the runtime JAR beside the Studio application JAR.
