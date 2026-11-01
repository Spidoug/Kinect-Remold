package org.synkinect.studio.api;

/** One host-rendered action in a declarative Studio module panel. */
public record StudioModuleAction(String id, String label, boolean enabled, boolean selected, boolean primary, boolean quiet) {
    public StudioModuleAction {
        id = id == null ? "" : id;
        label = label == null ? "" : label;
    }

    public static StudioModuleAction action(String id, String label) {
        return new StudioModuleAction(id, label, true, false, false, false);
    }

    public static StudioModuleAction primary(String id, String label) {
        return new StudioModuleAction(id, label, true, false, true, false);
    }
}
