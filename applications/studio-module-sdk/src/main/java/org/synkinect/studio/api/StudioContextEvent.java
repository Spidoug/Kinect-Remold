package org.synkinect.studio.api;

import java.util.List;

/**
 * Immutable host-context change delivered to every Studio module.
 *
 * Modules react to capabilities/events instead of being special-cased by the
 * Studio controller. More than one flag may be present in a single event.
 */
public final class StudioContextEvent {
    public static final int LOCALE_CHANGED = 1;
    public static final int DEVICES_CHANGED = 1 << 1;
    public static final int SELECTION_CHANGED = 1 << 2;

    private final int flags;
    private final String locale;
    private final long deviceGeneration;
    private final StudioDeviceInfo selectedDevice;
    private final List<StudioDeviceInfo> devices;

    public StudioContextEvent(int flags, String locale, long deviceGeneration,
                              StudioDeviceInfo selectedDevice, List<StudioDeviceInfo> devices) {
        this.flags = flags;
        this.locale = locale == null ? "" : locale;
        this.deviceGeneration = deviceGeneration;
        this.selectedDevice = selectedDevice;
        this.devices = devices == null ? List.of() : List.copyOf(devices);
    }

    public int flags() { return flags; }
    public boolean has(int flag) { return (flags & flag) != 0; }
    public boolean localeChanged() { return has(LOCALE_CHANGED); }
    public boolean devicesChanged() { return has(DEVICES_CHANGED); }
    public boolean selectionChanged() { return has(SELECTION_CHANGED); }
    public String locale() { return locale; }
    public long deviceGeneration() { return deviceGeneration; }
    public StudioDeviceInfo selectedDevice() { return selectedDevice; }
    public List<StudioDeviceInfo> devices() { return devices; }
}
