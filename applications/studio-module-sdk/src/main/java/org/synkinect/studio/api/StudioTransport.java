package org.synkinect.studio.api;

import java.io.Closeable;
import java.io.IOException;

/** Cross-platform local Remold transport opened by the Studio host. */
public interface StudioTransport extends Closeable {
    void write(byte[] data) throws IOException;
    void readFully(byte[] data) throws IOException;
    @Override void close() throws IOException;
}
