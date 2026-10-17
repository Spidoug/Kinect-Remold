import java.util.*;

/**
 * Ground-truth benchmark for SynKinect Studio metric depth calibration.
 *
 * A Kinect-360-like depth camera (the pipeline's own undistorted rays from
 * Calibration.rays()) looks at a flat wall at 8 distances (0.7-3.5 m) with random
 * tilts of up to +-20 deg. Depth is produced through a raw 11-bit disparity model with
 * a known distortion:
 *   - global scale: measured depth = 1.02 x true depth (unobservable without a reference)
 *   - Herrera-style spatial pattern D(u,v) * exp(-alpha1 * (raw - raw(0.7 m))) in raw
 *     disparity units: radial bowl + low-frequency pattern, decaying with distance
 *   - small fixed per-pixel pattern (speckle bias), per-frame noise sigma ~ 1.4e-3 z^2 m,
 *     integer raw-disparity quantisation, dropouts and finite wall extent.
 * Frames go through the unmodified DepthCalibrationSession (as the calibration window
 * drives it, minus Swing); the old per-pixel affine method is reproduced verbatim for
 * comparison. Corrected depth is then compared with ground truth on held-out planes.
 *
 * Usage: java CalibHarness [seed=7] [testPlanes=12]
 */
public class CalibHarness {
  static final int W = 640, H = 480;
  static final double RAW_A = 3.33, RAW_B = 0.00307;      // z = 1/(RAW_A - RAW_B*raw)
  static final double GT_SCALE = 1.02;                     // measured = GT_SCALE * true
  static final double ALPHA1 = 0.00246;                    // decay per raw unit
  static final double NOISE_RAW = 1.4e-3 / RAW_B;          // sigma_w = 1.4e-3 1/m -> raw units
  static final double FIXED_RAW = 0.10;                    // fixed per-pixel pattern (raw units)

  static SynKinectStudio app;
  static SynKinectStudio.AppConfig cfg;
  static SynKinectStudio.Calibration cal;
  static float[] rx, ry;
  static double[] pattern = new double[W * H], fixedPattern = new double[W * H];
  static Random rnd;

  static class Wall { double d, nx, ny, nz, tiltX, tiltY; }

  static Wall wall(double centerDist, double tiltXDeg, double tiltYDeg) {
    Wall w = new Wall(); double ax = Math.toRadians(tiltXDeg), ay = Math.toRadians(tiltYDeg);
    w.nx = Math.sin(ay) * Math.cos(ax); w.ny = Math.sin(ax); w.nz = Math.cos(ax) * Math.cos(ay);
    w.d = centerDist * w.nz; w.tiltX = tiltXDeg; w.tiltY = tiltYDeg; return w;
  }
  /** True depth of pixel i on the wall, or NaN outside the 4.4 x 3.2 m wall. */
  static double trueDepth(Wall w, int i) {
    double den = w.nx * rx[i] + w.ny * ry[i] + w.nz; if (den <= 1e-6) return Double.NaN;
    double z = w.d / den; double X = rx[i] * z, Y = ry[i] * z, Z = z;
    double cz = w.d / w.nz; double px = X, py = Y, pz = Z - cz;           // offset from the wall centre on the optical axis
    double e1x = w.nz, e1z = -w.nx, l1 = Math.hypot(e1x, e1z); e1x /= l1; e1z /= l1;  // e1 = up x n (horizontal in-plane)
    double e2x = w.ny * e1z, e2y = w.nz * e1x - w.nx * e1z, e2z = -w.ny * e1x;       // e2 = n x e1
    double hx = px * e1x + pz * e1z, vy = px * e2x + py * e2y + pz * e2z;
    if (Math.abs(hx) > 2.2 || Math.abs(vy) > 1.6) return Double.NaN;
    return z;
  }
  static double rawOf(double z) { return (RAW_A - 1.0 / z) / RAW_B; }
  static double zOfRaw(double raw) { double w = RAW_A - RAW_B * raw; return w > 1e-4 ? 1.0 / w : Double.NaN; }
  static final double RAW_NEAR = rawOf(0.7);

  /** Distorted, noise-free raw disparity of pixel i for true depth z. */
  static double distortedRaw(int i, double z) {
    double raw = rawOf(z * GT_SCALE);
    return raw + pattern[i] * Math.exp(-ALPHA1 * (raw - RAW_NEAR)) + fixedPattern[i];
  }
  /** One noisy frame in millimetres (0 = invalid). */
  static short[] frame(Wall w, boolean noise) {
    short[] out = new short[W * H];
    int blobs = noise ? rnd.nextInt(3) : 0; int[] bx = new int[blobs], by = new int[blobs], br = new int[blobs];
    for (int b = 0; b < blobs; b++) { bx[b] = rnd.nextInt(W); by[b] = rnd.nextInt(H); br[b] = 4 + rnd.nextInt(10); }
    for (int v = 0; v < H; v++) for (int u = 0; u < W; u++) {
      int i = v * W + u; double z = trueDepth(w, i); if (!Double.isFinite(z)) continue;
      if (noise && rnd.nextDouble() < 0.01) continue;
      boolean hole = false; for (int b = 0; b < blobs; b++) { int dx = u - bx[b], dy = v - by[b]; if (dx * dx + dy * dy < br[b] * br[b]) hole = true; } if (hole) continue;
      double raw = distortedRaw(i, z) + (noise ? rnd.nextGaussian() * NOISE_RAW : 0);
      double zm = zOfRaw(Math.round(raw)); if (!Double.isFinite(zm) || zm < 0.3 || zm > 8) continue;
      out[i] = (short) Math.round(zm * 1000);
    }
    return out;
  }

  // ---------------------------------------------------------------- old affine method (verbatim port)
  static class OldPlane { float ax, by, c = Float.NaN, rms = Float.POSITIVE_INFINITY; int samples; boolean valid() { return Float.isFinite(c) && samples > 64; } float depthAt(float x, float y) { return ax * x + by * y + c; } }
  static OldPlane oldPlane(float[] depth) { OldPlane f = oldPass(depth, null, Float.POSITIVE_INFINITY); if (!f.valid()) return f; float cut = Math.max(0.004f, Math.min(0.040f, f.rms * 2.5f)); return oldPass(depth, f, cut); }
  static OldPlane oldPass(float[] depth, OldPlane ref, float cutoff) {
    double sxx = 0, syy = 0, sxy = 0, sx = 0, sy = 0, sz = 0, sxz = 0, syz = 0; int n = 0; int step = 3;
    for (int v = 8; v < H - 8; v += step) for (int u = 8; u < W - 8; u += step) { float z = depth[v * W + u]; if (z < 0.35f || z > 3.0f) continue;
      float x = (u - cal.cx) / cal.fx, y = (v - cal.cy) / cal.fy; if (ref != null && Math.abs(z - ref.depthAt(x, y)) > cutoff) continue;
      sxx += x * x; syy += y * y; sxy += x * y; sx += x; sy += y; sz += z; sxz += x * z; syz += y * z; n++; }
    OldPlane out = new OldPlane(); if (n < 128) return out; double[][] a = {{sxx, sxy, sx, sxz}, {sxy, syy, sy, syz}, {sx, sy, n, sz}};
    for (int col = 0; col < 3; col++) { int p = col; for (int r = col + 1; r < 3; r++) if (Math.abs(a[r][col]) > Math.abs(a[p][col])) p = r; if (Math.abs(a[p][col]) < 1e-12) return out;
      double[] t = a[col]; a[col] = a[p]; a[p] = t; double d = a[col][col]; for (int c = col; c < 4; c++) a[col][c] /= d;
      for (int r = 0; r < 3; r++) if (r != col) { double f = a[r][col]; for (int c = col; c < 4; c++) a[r][c] -= f * a[col][c]; } }
    out.ax = (float) a[0][3]; out.by = (float) a[1][3]; out.c = (float) a[2][3]; out.samples = n;
    double e2 = 0; int en = 0; for (int v = 8; v < H - 8; v += step) for (int u = 8; u < W - 8; u += step) { float z = depth[v * W + u]; if (z <= 0) continue;
      float x = (u - cal.cx) / cal.fx, y = (v - cal.cy) / cal.fy, r = z - out.depthAt(x, y); if (ref != null && Math.abs(r) > cutoff) continue; e2 += r * r; en++; }
    out.rms = en == 0 ? Float.POSITIVE_INFINITY : (float) Math.sqrt(e2 / en); return out;
  }
  static class OldAffine { float[] scale = new float[W * H], offset = new float[W * H]; int correct(int i, int mm) { if (mm <= 0) return mm; float m = mm * 0.001f * scale[i] + offset[i]; return Math.max(1, Math.min(10000, Math.round(m * 1000))); } }
  static OldAffine oldFit(List<float[]> means, List<OldPlane> planes) {
    OldAffine o = new OldAffine(); Arrays.fill(o.scale, 1f); int S = means.size(); int validation = S >= 4 ? S - 1 : -1;
    float[] xs = new float[S], ys = new float[S];
    for (int idx = 0; idx < W * H; idx++) { int u = idx % W, v = idx / W; float nx = (u - cal.cx) / cal.fx, ny = (v - cal.cy) / cal.fy; int count = 0;
      for (int s = 0; s < S; s++) { if (s == validation) continue; float m = means.get(s)[idx]; if (m <= 0 || !planes.get(s).valid()) continue; float t = planes.get(s).depthAt(nx, ny); if (t <= 0) continue; xs[count] = m; ys[count] = t; count++; }
      if (count >= cfg.calibrationMinimumStationsPerPixel) { double sx = 0, sy = 0, sxx = 0, sxy = 0; for (int i = 0; i < count; i++) { sx += xs[i]; sy += ys[i]; sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i]; }
        double den = count * sxx - sx * sx; float a = 1, b = 0; if (Math.abs(den) > 1e-10) { a = (float) ((count * sxy - sx * sy) / den); b = (float) ((sy - a * sx) / count); }
        a = Math.max(cfg.calibrationSlopeMin, Math.min(cfg.calibrationSlopeMax, a)); b = Math.max(-cfg.calibrationOffsetMaxM, Math.min(cfg.calibrationOffsetMaxM, b)); o.scale[idx] = a; o.offset[idx] = b; } }
    return o;
  }

  // ---------------------------------------------------------------- evaluation
  interface Corrector { int correct(int index, int mm); }
  static class Err { double s2, sa; int n; ArrayList<Float> abs = new ArrayList<>(); void add(double e) { s2 += e * e; sa += Math.abs(e); n++; if ((n & 3) == 0) abs.add((float) Math.abs(e)); }
    double rms() { return Math.sqrt(s2 / Math.max(1, n)); } double mae() { return sa / Math.max(1, n); } double p95() { if (abs.isEmpty()) return Double.NaN; Collections.sort(abs); return abs.get((int) (abs.size() * 0.95)); } }
  static class TestPlane { Wall wall; short[] mm; }

  /** e[0..3]: all/<1.5/1.5-2.5/>2.5 m absolute; e[4]: all after removing the best single global scale. */
  static Err[] evaluate(List<TestPlane> tests, Corrector c) {
    Err[] e = {new Err(), new Err(), new Err(), new Err(), new Err()};
    double szz = 0, szt = 0;
    for (TestPlane t : tests) for (int i = 0; i < W * H; i += 2) { int mm = t.mm[i] & 0xffff; if (mm == 0) continue; double z = trueDepth(t.wall, i); if (!Double.isFinite(z)) continue;
      double cm = c.correct(i, mm); szz += cm * cm; szt += cm * z * 1000; }
    double k = szt / Math.max(1e-9, szz);
    for (TestPlane t : tests) for (int i = 0; i < W * H; i += 2) { int mm = t.mm[i] & 0xffff; if (mm == 0) continue; double z = trueDepth(t.wall, i); if (!Double.isFinite(z)) continue;
      int cm = c.correct(i, mm); double err = cm - z * 1000; e[0].add(err); e[z < 1.5 ? 1 : (z < 2.5 ? 2 : 3)].add(err); e[4].add(k * cm - z * 1000); }
    return e;
  }
  static String row(String name, Err[] e) { return String.format(Locale.US, "| %-34s | %6.2f | %6.2f | %6.2f | %6.2f | %6.2f | %6.2f | %6.2f |", name, e[0].rms(), e[0].mae(), e[0].p95(), e[1].rms(), e[2].rms(), e[3].rms(), e[4].rms()); }

  /** Storage (v3 round-trip, legacy v2 load) and projection/deprojection consistency. */
  static void selfChecks(SynKinectStudio.DepthCorrectionProfile p, OldAffine old) throws Exception {
    final java.io.File dir = java.nio.file.Files.createTempDirectory("depthcal").toFile();
    SynKinectStudio.DepthCalibrationStore store = app.new DepthCalibrationStore() { java.io.File root() { return dir; } };
    store.save(p); SynKinectStudio.DepthCorrectionProfile q = store.load("harness-kinect", W, H);
    int diff = 0; for (int i = 0; i < W * H; i += 97) for (int mm = 700; mm <= 3500; mm += 350) if (q == null || q.correctMm(i, mm) != p.correctMm(i, mm)) diff++;
    System.out.printf(Locale.US, "%nself-check v3 save/load: %s (%d mismatching samples, key=%s, hash match=%b)%n", q != null && diff == 0 ? "OK" : "FAIL", diff, q == null ? "-" : q.deviceKey, q != null && q.intrinsicsHash == cal.geometryHash);
    SynKinectStudio.DepthCorrectionProfile legacy = app.new DepthCorrectionProfile("legacy-kinect", W, H); legacy.calibrated = true; legacy.coverage = 0.9f;
    System.arraycopy(old.scale, 0, legacy.scale, 0, W * H); System.arraycopy(old.offset, 0, legacy.offsetM, 0, W * H); store.save(legacy);
    SynKinectStudio.DepthCorrectionProfile l2 = store.load("legacy-kinect", W, H); int ld = 0; for (int i = 0; i < W * H; i += 97) if (l2 == null || l2.correctMm(i, 2000) != old.correct(i, 2000)) ld++;
    System.out.printf(Locale.US, "self-check legacy v2 load: %s (model=%d)%n", l2 != null && ld == 0 ? "OK" : "FAIL", l2 == null ? -1 : l2.modelType);
    SynKinectStudio.RgbDepthRegistration reg = app.new RgbDepthRegistration(cfg, cal); SynKinectStudio.SkeletonCalibration3D sc = app.new SkeletonCalibration3D(cal, reg);
    double maxErr = 0; for (int v = 0; v < H; v += 17) for (int u = 0; u < W; u += 13) { processing.core.PVector X = sc.deproject(u, v, 1800); processing.core.PVector px = sc.projectDepth(X); maxErr = Math.max(maxErr, Math.hypot(px.x - u, px.y - v)); }
    System.out.printf(Locale.US, "self-check projectDepth(deproject(u,v)) max error: %.4f px %s%n", maxErr, maxErr < 0.05 ? "OK" : "FAIL");
    SynKinectStudio.Calibration id = app.new Calibration(); id.configure(cfg); int idDiff = 0; for (int i = 0; i < W * H; i += 101) if (id.correctedDepthMm(i, 1234) != 1234) idDiff++;
    System.out.printf(Locale.US, "self-check identity without profile: %s%n", idDiff == 0 ? "OK" : "FAIL");
  }

  public static void main(String[] args) throws Exception {
    long seed = args.length > 0 ? Long.parseLong(args[0]) : 7; int nTests = args.length > 1 ? Integer.parseInt(args[1]) : 12;
    rnd = new Random(seed);
    app = new SynKinectStudio(); app.studio = app.new StudioController(app.new StudioServices());
    cfg = app.new AppConfig(); cfg.load(app.studio.services.paths.resource("scanner", "config.properties"));
    if (System.getProperty("cal.frames") != null) cfg.calibrationFramesPerStation = Integer.getInteger("cal.frames");
    if (System.getProperty("cal.rho") != null) cfg.calibrationRegularization = Float.parseFloat(System.getProperty("cal.rho"));
    cal = app.new Calibration(); cal.configure(cfg); float[][] rays = cal.rays(); rx = rays[0]; ry = rays[1];
    double ph = rnd.nextDouble() * 6.283;
    for (int v = 0; v < H; v++) for (int u = 0; u < W; u++) { double xn = (u - W / 2.0) / (W / 2.0), yn = (v - H / 2.0) / (H / 2.0), r2 = (xn * xn + yn * yn) / 2.0;
      pattern[v * W + u] = 3.0 * r2 * r2 + 1.2 * r2 - 0.9 + 0.8 * Math.sin(1.5 * Math.PI * xn + ph) * Math.cos(Math.PI * yn) + 0.4 * Math.sin(3.0 * Math.PI * yn + 1.3 * ph);
      fixedPattern[v * W + u] = rnd.nextGaussian() * FIXED_RAW; }

    double[] dists = {0.70, 1.10, 1.50, 1.90, 2.30, 2.70, 3.10, 3.50};
    ArrayList<Wall> stations = new ArrayList<>();
    for (double d : dists) stations.add(wall(d, (rnd.nextDouble() * 2 - 1) * 20, (rnd.nextDouble() * 2 - 1) * 20));
    System.out.printf(Locale.US, "seed=%d  stations=%d  framesPerStation=%d  grid=%dx%dx%d%n", seed, stations.size(), cfg.calibrationFramesPerStation, cfg.calibrationGridX, cfg.calibrationGridY, cfg.calibrationDepthBins);

    // --- new method: drive the real session exactly like SensorCalibrationWindow.tick()
    cfg.calibrationStations = stations.size();
    SynKinectStudio.DepthCalibrationSession session = app.new DepthCalibrationSession(cfg, cal, app.new DepthCalibrationStore(), "harness-kinect", false);
    session.start();
    ArrayList<float[]> oldMeans = new ArrayList<>(); ArrayList<OldPlane> oldPlanes = new ArrayList<>();
    int frameId = 0; SynKinectStudio.DepthCorrectionProfile profile = null; long t0 = System.nanoTime(); long fitStart = 0;
    for (int s = 0; s < stations.size(); s++) {
      Wall w = stations.get(s); int before = session.stations.size(); long[] sum = new long[W * H]; int[] cnt = new int[W * H];
      for (int f = 0; f < 200 && session.stations.size() == before && profile == null && !session.fitting; f++) {
        short[] mm = frame(w, true);
        SynKinectStudio.DepthFrame df = app.new DepthFrame(); df.width = W; df.height = H; df.stride = W * 2; df.depth = mm; df.frameId = ++frameId; df.frameNumber = frameId; df.deviceCalibrated = true;
        profile = session.offer(df);
        if (session.accumulator != null || session.stations.size() > before || session.fitting) for (int i = 0; i < mm.length; i++) { int v = mm[i] & 0xffff; if (v > 0) { sum[i] += v; cnt[i]++; } }
      }
      if (session.stations.size() == before && !session.fitting && profile == null) throw new IllegalStateException("station " + (s + 1) + " was not accepted by the session");
      float[] mean = new float[W * H]; for (int i = 0; i < mean.length; i++) if (cnt[i] >= 2) mean[i] = (float) (sum[i] / (double) cnt[i] * 0.001);
      oldMeans.add(mean); oldPlanes.add(oldPlane(mean));
      SynKinectStudio.CalibrationStation st = session.stations.get(session.stations.size() - 1);
      System.out.printf(Locale.US, "  station %d: true %.3f m tilt (%+5.1f,%+5.1f) deg  plane centre %.3f m  rms@1m %.2f mm  valid %d%n", s + 1, w.d / w.nz, w.tiltX, w.tiltY, st.centerDepthM, st.plane.rmsAt1m() * 1000, st.validPixels);
      if (s == stations.size() - 1) fitStart = System.nanoTime();
    }
    if (profile == null) profile = session.awaitResult(120000);
    long fitMs = (System.nanoTime() - fitStart) / 1000000;
    if (profile == null) throw new IllegalStateException("fit did not complete");
    System.out.printf(Locale.US, "new fit: %d ms (after last station), regularisation rho=%.3g, coverage %.1f%%, LOSO planarity RMS %.2f -> %.2f mm%n", fitMs, profile.regularization, profile.coverage * 100, profile.validationRmsBeforeMm, profile.validationRmsAfterMm);
    for (int s = 0; s < profile.stationCenterM.length; s++) System.out.printf(Locale.US, "  LOSO station %d (%.2f m): RMS %.2f -> %.2f  MAE %.2f -> %.2f  p95 %.2f -> %.2f mm%n", s + 1, profile.stationRawCenterM[s],
      profile.stationRmsBeforeMm[s], profile.stationRmsAfterMm[s], profile.stationMaeBeforeMm[s], profile.stationMaeAfterMm[s], profile.stationP95BeforeMm[s], profile.stationP95AfterMm[s]);
    OldAffine old = oldFit(oldMeans, oldPlanes);

    // --- held-out test planes (30-frame average: dithers quantisation so systematic error dominates)
    ArrayList<TestPlane> tests = new ArrayList<>();
    for (int t = 0; t < nTests; t++) { TestPlane tp = new TestPlane(); tp.wall = wall(0.75 + rnd.nextDouble() * 2.7, (rnd.nextDouble() * 2 - 1) * 20, (rnd.nextDouble() * 2 - 1) * 20);
      long[] sum = new long[W * H]; int[] cnt = new int[W * H]; for (int f = 0; f < 30; f++) { short[] mm = frame(tp.wall, true); for (int i = 0; i < mm.length; i++) { int v = mm[i] & 0xffff; if (v > 0) { sum[i] += v; cnt[i]++; } } }
      tp.mm = new short[W * H]; for (int i = 0; i < sum.length; i++) if (cnt[i] >= 15) tp.mm[i] = (short) Math.round(sum[i] / (double) cnt[i]); tests.add(tp); }

    final SynKinectStudio.DepthCorrectionProfile p = profile;
    System.out.println();
    System.out.println("| Method (error vs ground truth, mm)  |  RMS   |  MAE   |  p95   | <1.5 m | 1.5-2.5| >2.5 m | RMS, scale-free |");
    System.out.println("|------------------------------------|--------|--------|--------|--------|--------|--------|--------|");
    System.out.println(row("raw (no correction)", evaluate(tests, (i, mm) -> mm)));
    System.out.println(row("old per-pixel affine (v2)", evaluate(tests, old::correct)));
    p.applyReferences(null, cfg);
    System.out.println(row("new grid, no reference", evaluate(tests, p::correctMm)));
    Random tape = new Random(seed * 31 + 5);
    float ref4 = (float) (stations.get(3).d / stations.get(3).nz + tape.nextGaussian() * 0.002);
    int m1 = p.applyReferences(new float[]{ref4}, cfg);
    System.out.println(row("new grid, 1 tape reference (" + m1 + ")", evaluate(tests, p::correctMm)) + String.format(Locale.US, "  scale %.4f", p.globalScale()));
    float ref1 = (float) (stations.get(1).d / stations.get(1).nz + tape.nextGaussian() * 0.002), ref6 = (float) (stations.get(6).d / stations.get(6).nz + tape.nextGaussian() * 0.002);
    int m2 = p.applyReferences(new float[]{ref1, ref6}, cfg);
    System.out.println(row("new grid, 2 tape references (" + m2 + ")", evaluate(tests, p::correctMm)) + String.format(Locale.US, "  gain %.4f offset %.5f", p.disparityGain, p.disparityOffset));
    selfChecks(p, old);
    System.out.printf(Locale.US, "%ntotal harness time %.1f s%n", (System.nanoTime() - t0) / 1e9);
    System.exit(0);
  }
}
