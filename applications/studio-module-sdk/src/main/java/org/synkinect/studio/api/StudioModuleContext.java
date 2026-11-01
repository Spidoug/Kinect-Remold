package org.synkinect.studio.api;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import processing.core.PApplet;

/** Stable host services available to third-party SynKinect Studio modules. */
public interface StudioModuleContext {
    int apiVersion();
    String studioVersion();
    PApplet applet();
    int contentWidth();
    int contentHeight();
    float uiScale();
    String locale();
    String platform();
    long deviceGeneration();
    StudioDeviceInfo selectedDevice();
    List<StudioDeviceInfo> devices();
    String audioEndpoint();
    String audioEndpoint(String deviceId);
    String audioControlEndpoint();
    String audioControlEndpoint(String deviceId);
    String controlEndpoint();
    String sdkEndpoint();
    StudioTransport openTransport(String endpoint) throws IOException;
    /** Returns the saved metric-depth calibration for the selected Kinect, or null. */
    default StudioDepthCalibration depthCalibration() { return null; }
    /** Returns the saved metric-depth calibration for one Studio-qualified Kinect ID, or null. */
    default StudioDepthCalibration depthCalibration(String deviceId) { return null; }
    /**
     * Opens a host body-tracking session (depth + skeleton solver) for a Studio-qualified
     * Kinect ID; null or empty selects the currently selected Kinect. Returns null when the
     * host or device does not provide body tracking. The session follows the module's
     * activation (camera ownership) and must be closed by the module.
     */
    default StudioBodyTracking bodyTracking(String deviceId) { return null; }
    Path dataDirectory() throws IOException;
    Thread runAsync(String role, Runnable task);
    void log(String message);
}
