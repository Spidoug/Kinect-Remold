# Automated tests

These tests are development-only and are not required to run SynKinect Studio. Execute from the project root.

- `python3 tests/test_kinect_v2_audio_service.py`: verifies Kinect v2 microphone endpoint protocol behavior with simulated audio.
- `python3 tests/body3d-viewport-benchmark/run-benchmark.py`: verifies viewport framing with synthetic inputs.
- Other headless Studio harnesses under `tests/` require the Processing/JOGL Java libraries. Build the Studio first using the platform build scripts.

A passing synthetic test does not establish Kinect hardware, Windows, or Studio GUI compatibility. The Kinect v2 microphone service resides under `drivers/modules/kinect-one-remold/audio/` and is not automatically started by the launchers.
