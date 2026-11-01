package org.synkinect.studio.api;

/** Processing-independent backend contract. Each instance owns its mutable state. */
public interface StudioBackend {
    String id();
    String name();
    default int order() { return 1000; }
    void initialize(StudioBackendContext context) throws Exception;
    default void activate() throws Exception {}
    default void deactivate() throws Exception {}
    default void contextChanged(StudioContextEvent event) throws Exception {}
    default StudioModuleUi snapshot(String localeTag) throws Exception { return null; }
    default void action(String actionId) throws Exception {}
    default String closeBlockReason(String localeTag) throws Exception { return ""; }
    default void close() throws Exception {}
}
