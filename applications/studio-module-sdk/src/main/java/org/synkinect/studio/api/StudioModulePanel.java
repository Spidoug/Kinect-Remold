package org.synkinect.studio.api;

import java.util.List;

/** Declarative panel rendered and resized by SynKinect Studio. */
public final class StudioModulePanel {
    public static final int KIND_TEXT = 0;
    public static final int KIND_METRICS = 1;
    public static final int KIND_ACTIONS = 2;

    private final int kind;
    private final String title;
    private final String text;
    private final List<StudioModuleMetric> metrics;
    private final List<StudioModuleAction> actions;

    private StudioModulePanel(int kind, String title, String text, List<StudioModuleMetric> metrics, List<StudioModuleAction> actions) {
        this.kind = kind;
        this.title = title == null ? "" : title;
        this.text = text == null ? "" : text;
        this.metrics = metrics == null ? List.of() : List.copyOf(metrics);
        this.actions = actions == null ? List.of() : List.copyOf(actions);
    }

    public static StudioModulePanel text(String title, String text) {
        return new StudioModulePanel(KIND_TEXT, title, text, List.of(), List.of());
    }

    public static StudioModulePanel metrics(String title, List<StudioModuleMetric> metrics) {
        return new StudioModulePanel(KIND_METRICS, title, "", metrics, List.of());
    }

    public static StudioModulePanel actions(String title, List<StudioModuleAction> actions) {
        return actions(title, actions, "");
    }

    public static StudioModulePanel actions(String title, List<StudioModuleAction> actions, String status) {
        return new StudioModulePanel(KIND_ACTIONS, title, status, List.of(), actions);
    }

    public int kind() { return kind; }
    public String title() { return title; }
    public String text() { return text; }
    public List<StudioModuleMetric> metrics() { return metrics; }
    public List<StudioModuleAction> actions() { return actions; }
}
