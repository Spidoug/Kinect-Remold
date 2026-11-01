# SynSkeleton model

SynKinect Studio uses `SynSkeleton.onnx` as the single authoritative source for body, hand and finger tracking.

Place the trained model at:

```text
data/skeleton/SynSkeleton.onnx
```

The packaged application carries this directory to its runtime `data/skeleton/` folder. The model must expose the same interface described by `SynSkeleton_layout.json`: input `depth_metric` shaped `1x1x240x320` and a first output containing 58 keypoints as normalized X, normalized Y, metric Z in millimetres, and confidence.

If the model is absent or cannot be loaded, Studio reports SynSkeleton as unavailable and publishes no skeleton. There is no alternate pose solver fallback.

Copy the exported DepthAutoLearn V1 `SynSkeleton.onnx` file into this directory, or specify its path using the `synkinect.synskeleton.model` JVM property. The runtime input must use invalid depth `-2.0`, valid depth normalization `(mm-2200)/1800` clamped to [-1, 1.8], and a median of valid 2x2 samples for 640x480 inputs. The optional SynHand.onnx is not executed by this backend.

Tracking mode and model installation: see `../../../../../docs/TRACKING-MODES.md`.
