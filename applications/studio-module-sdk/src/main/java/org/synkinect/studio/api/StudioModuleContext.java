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
    String audioControlEndpoint();
    String skeletonEndpoint();
    String controlEndpoint();
    String nuiEndpoint();
    String sdkEndpoint();
    StudioTransport openTransport(String endpoint) throws IOException;
    Path dataDirectory() throws IOException;
    Thread runAsync(String role, Runnable task);
    void log(String message);
}
