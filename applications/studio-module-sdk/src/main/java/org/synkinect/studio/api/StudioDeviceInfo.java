package org.synkinect.studio.api;

import java.util.Objects;

/** Immutable description of one Kinect exposed by the Remold runtime. */
public final class StudioDeviceInfo {
    private final String id;
    private final String label;
    private final String cameraEndpoint;

    public StudioDeviceInfo(String id, String label, String cameraEndpoint) {
        this.id = Objects.requireNonNullElse(id, "");
        this.label = Objects.requireNonNullElse(label, this.id);
        this.cameraEndpoint = Objects.requireNonNullElse(cameraEndpoint, "");
    }

    public String id() { return id; }
    public String label() { return label; }
    public String cameraEndpoint() { return cameraEndpoint; }

    @Override public String toString() {
        return label.isEmpty() ? id : label + " [" + id + "]";
    }
}
