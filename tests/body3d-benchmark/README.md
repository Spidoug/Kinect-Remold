# Body3D complete regression suite

Runs the Body3D tests as one command:

```bash
tests/body3d-benchmark/run-all.sh
```

The suite always executes the dependency-free viewport/framing regression. If the Processing/JOGL jars staged by `scripts/linux/BUILD-STUDIO.sh` are present, it additionally runs the real SynSkeleton ground-truth benchmark (including lateral/depth sweeps and the actual shared `BodySkeletonPreview.prepareFrame()`), the Interactivity input harness, and the Motion Capture retarget/network/BVH harness.

On a source-only tree, `ALLOW_MISSING_DEPS=1 tests/body3d-benchmark/run-all.sh` returns a deliberate `PARTIAL` result after the viewport test. Without that flag, missing runtime jars fail the suite so CI cannot accidentally report a complete pass.
