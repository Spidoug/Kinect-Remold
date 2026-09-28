# Kinect hardware-operation audit

This document records the runtime invariants used by Kinect Remold 1.0.0 for every supported sensor family. A device is not considered operational merely because a USB PID, service, socket, pipe, or WinUSB binding exists. The runtime must be able to open the exact physical function selected for that model and complete the protocol operation used by the Studio.

## Kinect Xbox 360 1414

- Camera identity: `045E:02AE`, `bcdDevice 0x010B`.
- Motor / LED / accelerometer: dedicated `045E:02B0`, classic Kinect vendor-control protocol.
- Windows: `02B0` is bound deterministically to the Remold WinUSB INF so the broker interface GUID is always published.
- Linux: interface 0 is explicitly claimed before classic control transfers.
- Audio: `02AD` boot function transitions to the Kinect UAC runtime and is normalized to the Remold four-channel audio ABI.

## Kinect Xbox 360 1473

- Camera identity: `045E:02AE` with a non-1414 `bcdDevice` (normally `0x0205`).
- `045E:02C2` is the parent USB hub and is never treated as the motor transport.
- Motor / LED / accelerometer: UAC runtime control interface `02BB/02C3 MI_00`, bulk protocol.
- Audio capture: `02BB/02C3 MI_02`; the control path never resets the active capture interface.
- The working 1473 control sequence is preserved unchanged on Windows and Linux.

## Kinect for Windows 1517

- Camera identity: `045E:02BF`.
- Motor / LED / accelerometer: dedicated `045E:02C2 REV_0100`, using the classic first-generation control ABI.
- Windows: the revision-scoped Remold WinUSB INF is bound deterministically. A generic `winusb.sys` state alone is not accepted because it may not publish the broker interface GUID. After services start, installation also requires a successful non-destructive physical `Status` transaction before motor/control is reported `READY`.
- Linux: the model is resolved from camera identity before `02C2` can be selected, so a 1473 parent hub can never be mistaken for a 1517 motor.
- Audio: factory `045E:02BE` UAC runtime.

## Kinect v2 / Xbox One

- Runtime USB ownership is native WinUSB on Windows and native libusb on Linux.
- Device identity is stable across USB re-enumeration. Linux reopens by serial/public identity with physical topology as a deterministic secondary locator; it never reopens by ephemeral USB device address. Windows derives the public identity from the physical location path when available and uses the interface path only as a fallback locator.
- A v2 device is `Ready` only after its native command channel can be opened and a hardware probe completes.
- RGB, depth and infrared use the same shared Remold protocol and shared depth engine on Windows and Linux.
- Kinect v2 audio is not currently advertised by the Remold module.

## Cross-platform rule

OS-specific transport is allowed to differ. Sensor identity, model selection, protocol semantics, published frame/audio formats, capability names, and readiness meaning must not. Models 1414, 1473 and 1517 therefore converge on one first-generation Studio contract even though their USB control/audio topology differs. A service being installed or an IPC endpoint existing is necessary but not sufficient evidence that the corresponding physical transport is operational.

## Runtime readiness invariant

For an attached Kinect, module status succeeds only when the Studio-facing core,
physical control, image output, Scanner transport and raw four-channel audio
transport are all operational. A running service, a present USB PID or a
STARTED WinUSB devnode is not sufficient. The optional IP-camera service may
remain disabled by secure default.

On Windows classic-control discovery (1414/1517) first requires exact camera to
motor identity matching. A single-interface fallback is allowed only when that
transport class has exactly one present interface, making the mapping
unambiguous; this handles Windows USB stacks that expose sibling location paths
with different final USB elements. Multi-Kinect systems never use this fallback.
