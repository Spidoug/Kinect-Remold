package org.synkinect.studio.api;

/**
 * Public SynKinect Studio Module API.
 * Software version: 1.
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
    void draw() throws Exception;
    default void mousePressed(float x, float y, int button) throws Exception {}
    default void mouseDragged(float x, float y, int button) throws Exception {}
    default void mouseWheel(float count) throws Exception {}
    default void keyPressed(char key, int keyCode) throws Exception {}
    default void dispose() throws Exception {}
}
