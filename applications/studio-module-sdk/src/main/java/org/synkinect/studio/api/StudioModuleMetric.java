package org.synkinect.studio.api;

/** One host-rendered metric in a declarative Studio module panel. */
public record StudioModuleMetric(String label, String value, boolean active) {
    public StudioModuleMetric {
        label = label == null ? "" : label;
        value = value == null ? "" : value;
    }
}
