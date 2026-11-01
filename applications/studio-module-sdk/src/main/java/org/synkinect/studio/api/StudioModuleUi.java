package org.synkinect.studio.api;

import java.util.List;

/** Immutable declarative UI snapshot rendered by the Studio host. */
public final class StudioModuleUi {
    private final String status;
    private final List<StudioModulePanel> panels;

    public StudioModuleUi(String status, List<StudioModulePanel> panels) {
        this.status = status == null ? "" : status;
        this.panels = panels == null ? List.of() : List.copyOf(panels);
    }

    public static StudioModuleUi of(List<StudioModulePanel> panels) {
        return new StudioModuleUi("", panels);
    }

    public String status() { return status; }
    public List<StudioModulePanel> panels() { return panels; }
}
