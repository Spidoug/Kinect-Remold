<div align="center">

# Interactivity controls

### Hand pointer, two-hand gestures and air keyboard

[Documentation](README.md) · [SynSkeleton](SKELETON-3D-ARCHITECTURE.md) · [Hands and fingers](HANDS-AND-FINGERS.md)

</div>

Interactivity turns the tracked skeleton into desktop input. It uses only Java/AWT (`Robot`, a Swing overlay window) and has no external dependencies. The controller lives in `Interactivity.pde` (`InteractionDesktopController`) and in `InteractionControl.pde` (hands, filters, keyboard). All values below come from `data/interactivity/config/config.properties`.

## Hand interaction zones

As in the Kinect for Windows SDK interaction stream, **each hand owns its own physical interaction zone**:

- The zone is anchored at that hand's shoulder, in a body-aligned frame (the user's right, up, and toward the sensor).
- It is sized in fractions of the user's arm length (`zone.widthArm`, `zone.heightArm`, `zone.topArm`, `zone.outwardArm`).

The mapping is therefore the same for any body size and any distance to the sensor, and both hands are equally comfortable.

A hand takes control ("engaged") only when it is raised in front of the body (`engage.*`). A hand resting at your side never moves the pointer. In automatic hand mode, the engaged hand becomes the pointer hand. If both hands are engaged, the pointer hand only changes when the other hand stays clearly more extended.

The pointer uses a One-Euro filter (`pointer.*`). It is steady while hovering and has no noticeable lag during fast motion.

## Press (click)

A press is a **relative push toward the sensor**. It is measured against an adaptive baseline, so you never need to reach an absolute depth. The baseline follows slow drift, and it follows quickly whenever the hand moves across the zone or has just been raised (`engage.settleMs`, `press.direction*`). As a result, raising or sweeping the hand never clicks.

These rules make clicks land where you aimed:

- **Hysteresis:** a press registers at `press.deltaArm` and releases at `press.releaseArm`.
- **Spike rejection:** a single-frame depth spike from rest must persist for `press.stableMs` before it counts.
- **Click lock:** once a push starts, the pointer freezes at the position it had just before the push (`press.lockLookbackMs`). It stays there while you pull back (`press.releaseHoldMs`).
- **Drag:** moving the pressed hand beyond `press.dragUnlock` starts a drag.

## Two-hand mouse gestures

| Gesture | Result |
|---|---|
| Pointer hand: push | Left click; push and move to drag |
| Other hand: push | Right click (`gesture.rightClick`) |
| Push the other hand while the pointer hand is pressed | Double click (`gesture.doubleClickWindowMs`) |
| Other hand raised to shoulder height, then moved up or down | Continuous scroll, joystick style (`scroll.*`) |
| Both hands held above the head for `keyboard.toggleHoldMs` | Show or hide the air keyboard |

## Air keyboard

The **Virtual keyboard** button (or the two-hands-up gesture) opens an on-screen keyboard at the bottom of the screen. The overlay is always on top and never takes focus, so text goes to the application that already has the keyboard focus.

While the keyboard is shown, **each hand has its own cursor** (left hand orange, right hand blue), and both hands can type at the same time. The left-hand zone is centred on the left part of the keyboard and the right-hand zone on the right part (`keyboard.sideOffset`, `keyboard.zoneScale`).

To press a key, push toward the sensor, the same way you click. Backspace, space and the arrow keys repeat while held (`keyboard.repeat*`). `keyboard.dwellMs > 0` adds dwell typing for accessibility: hover still over a key to press it.

The layout includes:

- Letters, digits and `ç`.
- A second layer with Portuguese accented letters and symbols.
- Shift (press twice for caps lock), Tab, Enter, arrow keys and Close.

Letters and digits are typed as key codes. Accented characters and symbols are typed through the clipboard, and the previous clipboard text is restored, so they work with any keyboard layout. You can also click the keys with the physical mouse.

## Testing

Gestures and two-hand typing require validation with representative sensor recordings and the target operating system.
