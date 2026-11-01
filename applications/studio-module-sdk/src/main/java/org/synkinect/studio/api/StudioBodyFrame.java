package org.synkinect.studio.api;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Immutable body-tracking snapshot delivered by {@link StudioBodyTracking}. */
public final class StudioBodyFrame {
    private final String deviceId;
    private final long timestampMs, frameNumber, trackingId;
    private final boolean tracked;
    private final float confidence;
    private final float[] upVector;
    private final List<StudioBodyJoint> joints, humanoidBones;

    public StudioBodyFrame(String deviceId, long timestampMs, long frameNumber, long trackingId, boolean tracked,
                           float confidence, float[] upVector, List<StudioBodyJoint> joints, List<StudioBodyJoint> humanoidBones) {
        this.deviceId = deviceId == null ? "" : deviceId;
        this.timestampMs = timestampMs;
        this.frameNumber = frameNumber;
        this.trackingId = trackingId;
        this.tracked = tracked;
        this.confidence = confidence;
        this.upVector = upVector == null || upVector.length != 3 ? null : upVector.clone();
        this.joints = joints == null ? Collections.<StudioBodyJoint>emptyList() : Collections.unmodifiableList(new ArrayList<StudioBodyJoint>(joints));
        this.humanoidBones = humanoidBones == null ? Collections.<StudioBodyJoint>emptyList() : Collections.unmodifiableList(new ArrayList<StudioBodyJoint>(humanoidBones));
    }

    /** Studio-qualified device ID ({@code <module-id>:<native-id>}). */
    public String deviceId() { return deviceId; }
    /** Host monotonic clock in milliseconds (not wall-clock time). */
    public long timestampMs() { return timestampMs; }
    public long frameNumber() { return frameNumber; }
    /** Identity of the tracked person; changes when a different person is acquired. 0 = none. */
    public long trackingId() { return trackingId; }
    public boolean tracked() { return tracked; }
    public float confidence() { return confidence; }
    /** Gravity "up" unit vector in camera space (approximately (0,-1,0)), or null when unknown. */
    public float[] upVector() { return upVector == null ? null : upVector.clone(); }
    /** Kinect v1 20-joint naming (+ optional hand tips / thumbs) in Studio camera space. */
    public List<StudioBodyJoint> joints() { return joints; }
    /** Unity HumanBodyBones with local rotations in Unity space; empty when unavailable. */
    public List<StudioBodyJoint> humanoidBones() { return humanoidBones; }

    public StudioBodyJoint joint(String name) { return find(joints, name); }
    public StudioBodyJoint humanoid(String name) { return find(humanoidBones, name); }

    private static StudioBodyJoint find(List<StudioBodyJoint> list, String name) {
        if (name == null) return null;
        for (StudioBodyJoint j : list) if (j.name().equals(name)) return j;
        return null;
    }
}
