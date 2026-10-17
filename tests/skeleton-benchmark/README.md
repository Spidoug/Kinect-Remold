# SynSkeleton ground-truth benchmark

This tool measures the accuracy of the 20-joint body tracker without a Kinect. It exercises the same `SkeletonProcessingSession` used by the Studio. A compatible `SynSkeleton.onnx` must be available to the harness/runtime before the benchmark can publish poses.

`SkeletonHarness.java` builds an articulated person with forward kinematics. The person is about 1.75 m tall and made of capsules and rounded boxes. They stand in a room with a floor and a back wall.

The harness renders what a **Kinect Xbox 360** would measure. It then sends every frame through the **unmodified** `SkeletonProcessingSession` and compares each published joint with the exact joint position.

## Sensor model

The sensor model is the same one the scanner benchmark uses:

- Disparity comes from a 7.5 cm baseline, with Gaussian noise σ = 0.075 px and 1/8 px quantisation.
- It includes IR projector shadows, grazing-angle and edge dropouts, and speckle holes.
- It uses the pipeline's own lens-corrected rays.
- The accelerometer reports gravity in the camera frame.

## Choreography

The person performs these segments in order. There is a 0.6 s blend between segments, and errors are only counted once a pose has settled.

| Segment | What it stresses |
|---|---|
| rest, rest2 | Arms hanging next to the torso |
| tpose | Arms fully extended sideways |
| wave | Raised forearm oscillating |
| reach | Arms pointing straight at the sensor, which is foreshortened |
| type | Forearms toward the sensor with fast hand motion, hands close together |
| cross | Crossed forearms in front of the chest |
| kneeUp | Alternating knee raises toward the sensor |
| turn | ±40° torso yaw |
| overhead | Both arms above the head |
| sideSweep | Person walks laterally across the Kinect FOV; validates off-centre body association and shared Body3D framing |
| depthSweep | Person moves toward/away from the sensor; validates depth tracking without presentation zoom feedback |

## Running

```bash
tests/skeleton-benchmark/run-benchmark.sh 2.6 3                            # full body at 2.6 m
JOPTS="-Dskel.fps=10" tests/skeleton-benchmark/run-benchmark.sh 2.6 3      # 10 fps (faster)
JOPTS="-Dskel.solver=legacy -Dskel.fps=10" tests/skeleton-benchmark/run-benchmark.sh
JOPTS="-Dskel.fps=10 -Dskel.scene=near -Dskel.camH=1.15 -Dskel.lookH=1.2 -Dskel.stopAfter=21" \
  tests/skeleton-benchmark/run-benchmark.sh 1.6 5                          # close range, upper body
```

The script needs the Processing and JOGL jars that `scripts/linux/BUILD-STUDIO.sh` stages. Rendered frames are cached in `binaries/benchmark/skelcache`, so a second run only measures the tracker.

The benchmark also executes the project's actual `BodySkeletonPreview.prepareFrame()` at 760×430, 520×270 and 360×220. `BODY3D VIEWPORT RESULT: PASS` requires the plausible segmented cloud to remain inside all three panels with bounded center error/occupancy while the body performs the lateral/depth sweeps.

Other options:

- `-Dskel.verbose=true` prints per-frame hand errors.
- `-Dskel.dumpJoints=1` prints ground truth and estimates for every tenth frame.
- `-Darticulated.debug=1` prints solver internals: extrema, limb fits and a stage profile.

## Reference results (September 2026 revision, 10 FPS evaluation)

These are mean joint errors. **hands < 8 cm** is the fraction of hand samples within 8 cm of the true hand.

| | Torso + head | Shoulders | Elbows | Wrists + hands | Hips + knees | Ankles + feet | Hands < 8 cm | Swaps |
|---|---|---|---|---|---|---|---|---|
| Previous Body3D solver, 2.6 m | 34.6 cm | 35.7 cm | 37.3 cm | 53.0 cm | 28.1 cm | 16.2 cm | 10 % | 139 |
| Articulated solver, 2.6 m | **1.5 cm** | **1.4 cm** | **3.1 cm** | **2.6 cm** | **3.4 cm** | **3.4 cm** | **99 %** | **0** |
| Articulated solver, 1.6 m (upper body, feet out of view) | 2.1 cm | 1.8 cm | 3.1 cm | 4.4 cm | 2.5 cm | – | 91 % | 1 |

At 1.6 m the previous solver lost the person in five of the seven segments.

The articulated solver uses the Kinect SDK side convention: "left" is the user's anatomical left. The previous solver published image-left, which the benchmark detects as `MIRRORED`.

Processing time is 14–16 ms per frame at 2.6 m and about 25 ms at 1.6 m on the 2-core build VM. That is comparable to the previous solver, and the tracker runs on its own worker thread.
