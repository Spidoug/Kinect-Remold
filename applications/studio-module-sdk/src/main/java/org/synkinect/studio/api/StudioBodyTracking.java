package org.synkinect.studio.api;

import java.util.function.Consumer;

/**
 * Host-owned body tracking session for one Kinect, obtained from
 * {@link StudioModuleContext#bodyTracking(String)}.
 *
 * <p>The host runs depth acquisition and the skeleton solver. Each subscriber gets its own
 * latest-only mailbox and delivery thread: a slow consumer only skips stale frames, it never
 * blocks the solver or other consumers. The camera transport is owned only while the module
 * that opened the session is the active Studio module; frames stop while it is inactive and
 * resume on re-activation.</p>
 */
public interface StudioBodyTracking extends AutoCloseable {
    /** Studio-qualified device ID this session tracks. */
    String deviceId();

    /** True while depth frames are arriving. */
    boolean live();

    /**
     * Registers a consumer called on a host delivery thread for each (latest) frame.
     * Close the returned handle to unsubscribe.
     */
    AutoCloseable subscribe(Consumer<StudioBodyFrame> consumer);

    /** Stops tracking and releases the camera transport and all subscriptions. */
    @Override void close();
}
