package org.synkinect.studio.api;

/** Creates a fresh backend for each module registration. No shared mutable backend instance is required. */
public interface StudioBackendFactory {
    StudioBackend create();
}
