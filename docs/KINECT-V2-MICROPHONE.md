# Kinect v2 microphone endpoints

Kinect v2 uses the Studio's existing microphone and acoustic transport, just like Kinect v1. The Kinect One driver exposes **audio** and **audio-control** fields in device discovery only while the corresponding local IPC endpoints are present and the sensor is Ready. Studio uses its existing microphone recording, monitoring, volume, mute and acoustic analysis modules; no special UI mode is necessary.

The audio service captures a four-channel, 16 kHz, signed 32-bit input from a driver/OS audio device. This requires an accessible four-channel microphone input; a stereo or mono beamformed device cannot provide independent microphone array channels. The service intentionally rejects such devices rather than duplicating channels. An OS driver providing Kinect v2 audio is required on both Windows and Linux. Kinect v2 audio is separate from RGB-D USB transport.

## Setup

Install the runtime prerequisites with `python -m pip install sounddevice`. On Windows, install `pywin32` too. Select an operating-system input device exposing at least four channels and start the Studio endpoint service from the Kinect Remold root:

```shell
python drivers/modules/kinect-one-remold/audio/kinect_v2_audio_service.py --device INDEX
```

On Linux, the service's `--socket-dir` must match the Kinect One driver's runtime directory (normally `/run/kinect-one-remold`), and the user running the service must have permission to create sockets there. The Studio user must have permission to connect to the socket files. On Windows the service exposes `\\.\pipe\KinectOneRemoldAudio` and `\\.\pipe\KinectOneRemoldAudioControl`, using local-only named pipes. Run this service under an account with access to the Kinect v2 recording device. Start the SDK service and endpoint service before opening the Studio. Refresh device discovery when starting or stopping it.

The driver advertises these endpoints only for a **single detected Kinect v2**; multiple sensors require stable per-device audio association, which this service cannot infer from OS audio names alone. With multiple sensors it deliberately omits the microphone capability rather than routing audio to the wrong physical device.

The data endpoint implements the existing Studio 16-byte subscription and 32-byte response, followed by 48-byte frame headers and 4096-byte interleaved PCM packets. The control endpoint implements the 16-byte request and 20-byte response, including software gain and mute. No new Studio protocol is introduced.

## Operational boundaries

These endpoints allow Studio's Microphones and Acoustic modules to consume native **four-channel** frames. Kinect v1 microphone geometry is not a valid calibration for Kinect v2. Direction-of-arrival, localization and beam steering must be calibrated for the actual v2 channel order and positions before their output can be trusted. Native capture is not hardware-tested on either operating system. This implementation is not bundled as an automatically managed Windows/Linux service and does not claim A/V clock synchronization or exclusive per-device ownership by the Kinect One camera runtime.
