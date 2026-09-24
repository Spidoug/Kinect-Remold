package org.synkinect.studio.api;

/**
 * Public SynKinect Studio Module API.
 *
 * Implementations are discovered with {@link java.util.ServiceLoader}. A module
 * JAR lists its implementation class in
 * META-INF/services/org.synkinect.studio.api.SynKinectStudioModule.
 */
public interface SynKinectStudioModule {
    int API_VERSION = 1;

    String id();
    String name();
    default String name(String localeTag) { return name(); }
    default String description() { return ""; }
    default String description(String localeTag) { return description(); }
    default int apiVersion() { return API_VERSION; }
    default int order() { return 1000; }
    void setup(StudioModuleContext context) throws Exception;
    default void activate() throws Exception {}
    default void deactivate() throws Exception {}

    /** Receives generic host context changes such as locale/device selection. */
    default void contextChanged(StudioContextEvent event) throws Exception {}

    /**
     * Return a non-empty localized reason to temporarily block Studio shutdown.
     * The host applies the same close policy to every module.
     */
    default String closeBlockReason(String localeTag) throws Exception { return ""; }

    /**
     * Returns a host-rendered UI snapshot. Modules that implement this method
     * do not need Processing drawing, sizing or hit-testing code.
     */
    default StudioModuleUi ui(String localeTag) throws Exception { return null; }

    /** Receives actions declared by {@link #ui(String)}. */
    default void action(String actionId) throws Exception {}

    /** Optional custom renderer for modules that need specialized graphics. */
    default void draw() throws Exception {}
    default void mousePressed(float x, float y, int button) throws Exception {}
    default void mouseDragged(float x, float y, int button) throws Exception {}
    default void mouseReleased(float x, float y, int button) throws Exception {}
    default void mouseWheel(float count) throws Exception {}
    default void keyPressed(char key, int keyCode) throws Exception {}
    default void dispose() throws Exception {}
}
