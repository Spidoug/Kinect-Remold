# Interactivity hand-control test

`InteractionHarness.java` tests the Interactivity controller without a Kinect and without moving the real mouse. It drives `InteractionDesktopController` with a scripted two-hand skeleton (with configurable joint noise) and records the input it would send through a recording `InteractionInputSink`.

The script checks each of these:

1. Raising the hand does not click.
2. Moving the hand moves the pointer.
3. A push of the right hand makes a left click, and the click is released at the pixel where it was pressed.
4. A push of the left hand makes a right click.
5. Raising the left hand and lifting it scrolls up.
6. Push-and-move makes a drag.
7. Pushing both hands makes a double click.
8. Typing a sentence on the virtual keyboard with both hands produces exactly that text.
9. The hover jitter of the pointer is measured.

It also renders the keyboard overlay to `virtual-keyboard.png` and `virtual-keyboard-symbols.png` in the current directory.

```bash
tests/interaction-test/run-test.sh                       # prints RESULT: PASS / FAIL
JOPTS="-Dnoise=0.006 -Dtext='kinect 2026'" tests/interaction-test/run-test.sh
```

The `noise` option is the per-joint Gaussian noise in metres (default 4 mm). The script needs the Processing and JOGL jars that `scripts/linux/BUILD-STUDIO.sh` stages.
