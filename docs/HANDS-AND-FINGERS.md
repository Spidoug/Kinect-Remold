# Hands and fingers

Hands and fingers are part of `SynSkeleton.onnx`; there is no separate hand pose provider in the Studio tracking path.

The model publishes 21 landmarks per hand using the standard wrist + four landmarks for each thumb/index/middle/ring/pinky chain. These landmarks are converted to calibrated camera-space XYZ exactly like body landmarks.

## Visibility rule

A hand exists only when the current SynSkeleton inference contains sufficient current-frame hand landmarks. The Studio does not manufacture a hand from the wrist/forearm and does not retain an entire missing hand as a fallback.

Derived palm/body-hand anchors are created only from currently observed model landmarks. If the hand leaves the field of view or the model stops observing it, detailed hand rendering stops.

## Stability

For landmarks observed in consecutive frames, the Studio applies a light confidence-aware temporal smoothing. Large intentional motion is released quickly; sub-centimetre jitter is damped. Missing current-frame landmarks are not recreated by the filter.

## Interactivity

Interactivity consumes the same SynSkeleton hand data used by Body3D and Motion Capture. `Body / hands` uses body-level hand anchors derived from the neural hand/wrist evidence. `Hands & fingers` exposes the detailed 21-landmark hand when available. `Auto` selects the appropriate representation without switching to another detector.
