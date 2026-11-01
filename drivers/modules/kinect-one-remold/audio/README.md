# Kinect v2 microphone endpoints

The audio service provides the same Studio IPC endpoints on Linux (Unix sockets) and Windows (named pipes). It captures from a **four-channel operating-system microphone input** and exports 16 kHz signed 32-bit PCM. It does not implement a new USB kernel driver or calibrated beamforming.

Install `sounddevice` and, on Windows, `pywin32` into the Python environment running the service. Linux also requires an ALSA/PipeWire device exposed by `snd-usb-audio`; OS permissions and the actual device configuration determine availability.

```sh
python drivers/modules/kinect-one-remold/audio/kinect_v2_audio_service.py --list-devices
python drivers/modules/kinect-one-remold/audio/kinect_v2_audio_service.py --device kinect
```

The service must run separately before the Studio can detect its audio and control endpoints. The service is not yet installed or automatically started by the native Kinect driver installers. A Windows system without an appropriate audio endpoint cannot be repaired by the user-space service alone.
