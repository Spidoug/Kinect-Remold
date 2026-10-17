# Body3D viewport benchmark

Dependency-free regression test for the shared Body3D presentation used by Interactivity and Motion Capture. It reproduces lateral/depth walking, large arm envelopes, compact panels, Kinect-v1-like range noise, sparse segmentation edge outliers and the historical `trackingId` reuse after a tab/device restart.

It verifies both source wiring (`BodyViewFrame`, shared `prepareFrame`, hard point clipping and preview reset hooks) and the framing mathematics. A pass requires zero plausible cloud points outside the panel, bounded centering error and bounded occupancy for 760x430, 520x270 and 360x220 viewports.

Run:

```bash
tests/body3d-viewport-benchmark/run-benchmark.sh
```

For the full body pipeline, run this together with `tests/skeleton-benchmark`, `tests/interaction-test` and `tests/mocap-test` after the Processing/JOGL jars have been staged by `scripts/linux/BUILD-STUDIO.sh` or the Windows build script.
