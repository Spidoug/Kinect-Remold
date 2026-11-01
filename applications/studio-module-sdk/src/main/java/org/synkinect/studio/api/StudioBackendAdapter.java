package org.synkinect.studio.api;

/** Adapts a backend-only module to the existing Studio plugin lifecycle. */
public final class StudioBackendAdapter implements SynKinectStudioModule {
    private final StudioBackend backend;
    private boolean initialized;
    private boolean active;
    private boolean closed;
    public StudioBackendAdapter(StudioBackend backend) {
        if (backend == null) throw new IllegalArgumentException("backend");
        this.backend = backend;
    }
    @Override public String id() { return backend.id(); }
    @Override public String name() { return backend.name(); }
    @Override public int order() { return backend.order(); }
    @Override public synchronized void setup(final StudioModuleContext context) throws Exception {
        if (closed || initialized) throw new IllegalStateException("Backend already initialized or closed");
        backend.initialize(new StudioBackendContext() {
            public String platform() { return context.platform(); }
            public String locale() { return context.locale(); }
            public java.util.List<StudioDeviceInfo> devices() { return context.devices(); }
            public StudioDeviceInfo selectedDevice() { return context.selectedDevice(); }
            public String audioEndpoint(String id) { return context.audioEndpoint(id); }
            public String audioControlEndpoint(String id) { return context.audioControlEndpoint(id); }
            public StudioTransport openTransport(String endpoint) throws java.io.IOException { return context.openTransport(endpoint); }
            public StudioBodyTracking bodyTracking(String id) { return context.bodyTracking(id); }
            public java.nio.file.Path dataDirectory() throws java.io.IOException { return context.dataDirectory(); }
            public Thread runAsync(String role, Runnable work) { return context.runAsync(role, work); }
            public void log(String message) { context.log(message); }
        });
        initialized = true;
    }
    @Override public synchronized void activate() throws Exception {
        if (closed || !initialized) throw new IllegalStateException("Backend is not initialized");
        if (!active) { backend.activate(); active = true; }
    }
    @Override public synchronized void deactivate() throws Exception {
        if (active) { backend.deactivate(); active = false; }
    }
    @Override public void contextChanged(StudioContextEvent event) throws Exception { backend.contextChanged(event); }
    @Override public StudioModuleUi ui(String locale) throws Exception { return backend.snapshot(locale); }
    @Override public void action(String id) throws Exception { backend.action(id); }
    @Override public String closeBlockReason(String locale) throws Exception { return backend.closeBlockReason(locale); }
    @Override public synchronized void dispose() throws Exception {
        if (closed) return;
        closed = true;
        try { if (active) { backend.deactivate(); active = false; } }
        finally { backend.close(); }
    }
}
