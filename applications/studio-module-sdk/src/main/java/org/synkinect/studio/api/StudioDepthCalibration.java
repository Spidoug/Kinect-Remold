package org.synkinect.studio.api;

import java.util.Arrays;

/** Immutable per-device metric-depth calibration exposed by the Studio host. */
public final class StudioDepthCalibration {
    private final String deviceId;
    private final int width;
    private final int height;
    private final long createdEpochMs;
    private final float coverage;
    private final float trainingRmsBeforeMm;
    private final float trainingRmsAfterMm;
    private final float[] scale;
    private final float[] offsetM;
    private final float[] noiseM;

    public StudioDepthCalibration(String deviceId, int width, int height, long createdEpochMs,
                                  float coverage, float trainingRmsBeforeMm, float trainingRmsAfterMm,
                                  float[] scale, float[] offsetM, float[] noiseM) {
        this.deviceId = deviceId == null ? "" : deviceId;
        this.width = Math.max(0, width);
        this.height = Math.max(0, height);
        this.createdEpochMs = createdEpochMs;
        this.coverage = coverage;
        this.trainingRmsBeforeMm = trainingRmsBeforeMm;
        this.trainingRmsAfterMm = trainingRmsAfterMm;
        this.scale = scale == null ? new float[0] : Arrays.copyOf(scale, scale.length);
        this.offsetM = offsetM == null ? new float[0] : Arrays.copyOf(offsetM, offsetM.length);
        this.noiseM = noiseM == null ? new float[0] : Arrays.copyOf(noiseM, noiseM.length);
    }

    public String deviceId() { return deviceId; }
    public int width() { return width; }
    public int height() { return height; }
    public long createdEpochMs() { return createdEpochMs; }
    public float coverage() { return coverage; }
    public float trainingRmsBeforeMm() { return trainingRmsBeforeMm; }
    public float trainingRmsAfterMm() { return trainingRmsAfterMm; }
    public boolean calibrated() { return width > 0 && height > 0 && scale.length == width * height; }

    public int correctDepthMm(int pixelIndex, int rawMm) {
        if (rawMm <= 0 || pixelIndex < 0 || pixelIndex >= scale.length || pixelIndex >= offsetM.length) return rawMm;
        float meters = rawMm * 0.001f * scale[pixelIndex] + offsetM[pixelIndex];
        if (!Float.isFinite(meters)) return rawMm;
        return Math.max(1, Math.min(10000, Math.round(meters * 1000.0f)));
    }

    public float noiseMeters(int pixelIndex) {
        if (pixelIndex < 0 || pixelIndex >= noiseM.length) return Float.NaN;
        return noiseM[pixelIndex];
    }
}
