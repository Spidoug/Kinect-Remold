package org.synkinect.studio.api;

import java.util.Objects;

/** Immutable description of one Kinect exposed by a Kinect Remold driver module. */
public final class StudioDeviceInfo {
    private final String id;
    private final String nativeId;
    private final String moduleId;
    private final String generation;
    private final String label;
    private final String cameraEndpoint;
    private final String capabilities;
    private final int colorWidth, colorHeight, depthWidth, depthHeight, infraredWidth, infraredHeight, colorFps, depthFps;

    public StudioDeviceInfo(String id, String label, String cameraEndpoint) {
        this(id, id, "", "", label, cameraEndpoint, "", 0,0,0,0,0,0,0,0);
    }

    public StudioDeviceInfo(String id, String nativeId, String moduleId, String generation, String label, String cameraEndpoint) {
        this(id,nativeId,moduleId,generation,label,cameraEndpoint,"",0,0,0,0,0,0,0,0);
    }

    public StudioDeviceInfo(String id, String nativeId, String moduleId, String generation, String label, String cameraEndpoint,
                            String capabilities, int colorWidth, int colorHeight, int depthWidth, int depthHeight,
                            int infraredWidth, int infraredHeight, int colorFps, int depthFps) {
        this.id = Objects.requireNonNullElse(id, "");
        this.nativeId = Objects.requireNonNullElse(nativeId, "");
        this.moduleId = Objects.requireNonNullElse(moduleId, "");
        this.generation = Objects.requireNonNullElse(generation, "");
        this.label = Objects.requireNonNullElse(label, this.id);
        this.cameraEndpoint = Objects.requireNonNullElse(cameraEndpoint, "");
        this.capabilities = Objects.requireNonNullElse(capabilities, "");
        this.colorWidth = Math.max(0,colorWidth); this.colorHeight = Math.max(0,colorHeight);
        this.depthWidth = Math.max(0,depthWidth); this.depthHeight = Math.max(0,depthHeight);
        this.infraredWidth = Math.max(0,infraredWidth); this.infraredHeight = Math.max(0,infraredHeight);
        this.colorFps = Math.max(0,colorFps); this.depthFps = Math.max(0,depthFps);
    }

    /** Studio-stable identity, qualified by driver module. */
    public String id() { return id; }
    /** Device identity understood by the owning native driver module. */
    public String nativeId() { return nativeId; }
    public String moduleId() { return moduleId; }
    public String generation() { return generation; }
    public String label() { return label; }
    public String cameraEndpoint() { return cameraEndpoint; }
    public String capabilities() { return capabilities; }
    public boolean hasCapability(String capability) {
        if (capability == null || capability.isBlank()) return false;
        String c = capability.trim().toLowerCase().replace(" ", "");
        String normalized = "," + capabilities.toLowerCase().replace(" ", "") + ",";
        return normalized.contains("," + c + ",");
    }
    public int colorWidth() { return colorWidth; }
    public int colorHeight() { return colorHeight; }
    public int depthWidth() { return depthWidth; }
    public int depthHeight() { return depthHeight; }
    public int infraredWidth() { return infraredWidth; }
    public int infraredHeight() { return infraredHeight; }
    public int colorFps() { return colorFps; }
    public int depthFps() { return depthFps; }

    @Override public String toString() {
        return label.isEmpty() ? id : label + " [" + id + "]";
    }
}
