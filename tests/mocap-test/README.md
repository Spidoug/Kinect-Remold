# Motion-capture pipeline test

Headless test for the SynKinect Studio motion-capture backend. No Kinect, no
network access beyond `127.0.0.1` ephemeral ports.

```bash
tests/mocap-test/run-test.sh
# or with a custom Processing/JOGL library directory
REMOLD_BENCH_LIB=/path/to/lib tests/mocap-test/run-test.sh
```

`MocapHarness` builds synthetic SynSkeleton poses (Kinect camera space, same
pose-builder conventions as `tests/interaction-test`) and checks:

| Area | Check |
|---|---|
| Retargeter | T-pose gives ~identity local rotations; hips height from the floor plane |
| Retargeter | Left/right arm raised 90° gives a 90° `UpperArm` local rotation about -Z / +Z (Unity) |
| Retargeter | Elbow flexion gives 90° `LowerArm` about +Y without upper-arm twist; forearm hanging down gives 90° upper-arm twist |
| Retargeter | Mirror swaps sides and reflects rotations; a 12° pitched sensor is removed by gravity alignment |
| VMC | OSC bundle decoded by an independent parser: `/VMC/Ext/OK`, `/VMC/Ext/T`, `/VMC/Ext/Root/Pos`, 19 `/VMC/Ext/Bone/Pos` with unit quaternions |
| OSC / JSON UDP | 24 `/synkinect/joint` + `/synkinect/frame`; JSON schema v1 datagram |
| WebSocket | `java.net.http.WebSocket` client receives a JSON frame, ping → pong, close |
| Mailbox | 1000 offers to a slow consumer never block the producer |
| BVH | Recorded file re-parsed: joint count, channel count, frame count, frame time, ZXY Euler of a raised arm |
| SDK | `StudioBodyFrame` conversion (24 joints + 19 humanoid bones) |

The last line is `RESULT: PASS` or `RESULT: FAIL [...]` (exit code 0/1).
