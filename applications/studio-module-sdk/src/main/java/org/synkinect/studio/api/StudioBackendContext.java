package org.synkinect.studio.api;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;

/** Host services exposed without access to the Processing renderer. */
public interface StudioBackendContext {
    String platform();
    String locale();
    List<StudioDeviceInfo> devices();
    StudioDeviceInfo selectedDevice();
    String audioEndpoint(String deviceId);
    String audioControlEndpoint(String deviceId);
    StudioTransport openTransport(String endpoint) throws IOException;
    StudioBodyTracking bodyTracking(String deviceId);
    Path dataDirectory() throws IOException;
    Thread runAsync(String role, Runnable work);
    void log(String message);
}
