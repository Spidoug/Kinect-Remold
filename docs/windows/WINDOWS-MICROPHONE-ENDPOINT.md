# Windows microphone endpoint — V1

The V1 audio runtime uses Microsoft inbox USB audio facilities and a Remold user-mode bridge:

```text
Kinect 02AD
  ↓ Microsoft winusb.sys
UACFirmware upload
  ↓ device re-enumeration
Kinect 02BB MI_02
  ↓ Microsoft inbox USB Audio
WASAPI capture endpoint
  ↓
Kinect360RemoldAudioBridge
  ↓
Remold four-channel S32LE application pipe
```

The `02AD` state exists only for UAC firmware upload. After re-enumeration, Windows owns the audio endpoint through its USB Audio class driver. `Kinect360RemoldAudioBridge` locates every Kinect capture endpoint through MMDevice/WASAPI, associates it with the corresponding physical Kinect ID, and republishes the first four channels through the stable Remold application protocol.

The V1 package does not require an authored Remold kernel audio `.sys` file. The Remold Audio INF binds the temporary firmware-boot interface to Microsoft WinUSB and installs the user-mode bridge service.
