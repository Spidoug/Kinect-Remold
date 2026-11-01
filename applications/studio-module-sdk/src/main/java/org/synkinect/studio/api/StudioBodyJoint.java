package org.synkinect.studio.api;

/**
 * Immutable joint or humanoid bone sample published by the Studio body tracker.
 *
 * <p>For {@link StudioBodyFrame#joints()} the name uses the Kinect v1 20-joint naming
 * ({@code HipCenter}, {@code ShoulderLeft}, ...; plus optional {@code HandTipLeft},
 * {@code ThumbLeft}, {@code HandTipRight}, {@code ThumbRight}) and the position is in Studio
 * camera space: metres, +X image right (the user's LEFT when facing the sensor), +Y down,
 * +Z away from the sensor. Left/right follow the Kinect SDK anatomical convention.
 * Such joints carry no rotation.</p>
 *
 * <p>For {@link StudioBodyFrame#humanoidBones()} the name is a Unity {@code HumanBodyBones}
 * name ({@code Hips}, {@code LeftUpperArm}, ...), the position is the bone's global position
 * in Unity space (left-handed, +X right, +Y up, +Z forward, avatar facing +Z, metres, floor at
 * Y=0) and the rotation is the bone's LOCAL rotation relative to a T-pose whose bones all have
 * identity rotation (VRM-normalised rig).</p>
 */
public final class StudioBodyJoint {
    public static final int LOST = 0, INFERRED = 1, TRACKED = 2, PREDICTED = 3, OCCLUDED = 4;

    private final String name;
    private final float x, y, z, confidence;
    private final int state;
    private final boolean hasRotation;
    private final float qx, qy, qz, qw;

    public StudioBodyJoint(String name, float x, float y, float z, float confidence, int state) {
        this(name, x, y, z, confidence, state, false, 0, 0, 0, 1);
    }

    public StudioBodyJoint(String name, float x, float y, float z, float confidence, int state,
                           boolean hasRotation, float qx, float qy, float qz, float qw) {
        this.name = name == null ? "" : name;
        this.x = x; this.y = y; this.z = z;
        this.confidence = confidence;
        this.state = state;
        this.hasRotation = hasRotation;
        this.qx = qx; this.qy = qy; this.qz = qz; this.qw = qw;
    }

    public String name() { return name; }
    public float x() { return x; }
    public float y() { return y; }
    public float z() { return z; }
    public float confidence() { return confidence; }
    /** One of LOST, INFERRED, TRACKED, PREDICTED, OCCLUDED. */
    public int state() { return state; }
    public boolean tracked() { return state > LOST && confidence > 0; }
    public boolean hasRotation() { return hasRotation; }
    public float qx() { return qx; }
    public float qy() { return qy; }
    public float qz() { return qz; }
    public float qw() { return qw; }

    @Override public String toString() {
        return name + "(" + x + ", " + y + ", " + z + " c=" + confidence + ")";
    }
}
