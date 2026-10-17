import processing.core.*;
import java.util.*;
import java.io.*;

/**
 * Headless ground-truth harness for the SynKinect 3D Scanner.
 *
 * Renders a synthetic Kinect Xbox 360 depth stream (disparity quantisation,
 * disparity noise, projector shadows, grazing-angle and edge dropouts) of an
 * analytic scene, feeds it through the unmodified Scanner pipeline
 * (processScanFrame -> ICP -> TSDF -> Build Mesh / Refine HQ) and measures the
 * reconstruction against the exact signed-distance ground truth.
 *
 * Usage: java ScanHarness turntable|fusion [seconds] [seed]
 */
public class ScanHarness {
  // ---------------------------------------------------------------- scene
  // Scene frame S: metres, Y up, origin = turntable centre on the table top.
  static final double DISC_R = 0.13, DISC_H = 0.015;

  static double sdSphere(double x, double y, double z, double cx, double cy, double cz, double r) {
    double dx = x - cx, dy = y - cy, dz = z - cz; return Math.sqrt(dx*dx + dy*dy + dz*dz) - r;
  }
  static double sdRoundBox(double x, double y, double z, double cx, double cy, double cz, double hx, double hy, double hz, double r) {
    double qx = Math.abs(x - cx) - (hx - r), qy = Math.abs(y - cy) - (hy - r), qz = Math.abs(z - cz) - (hz - r);
    double ox = Math.max(qx, 0), oy = Math.max(qy, 0), oz = Math.max(qz, 0);
    return Math.sqrt(ox*ox + oy*oy + oz*oz) + Math.min(Math.max(qx, Math.max(qy, qz)), 0) - r;
  }
  static double sdCapsule(double x, double y, double z, double ax, double ay, double az, double bx, double by, double bz, double r) {
    double pax = x - ax, pay = y - ay, paz = z - az, bax = bx - ax, bay = by - ay, baz = bz - az;
    double h = Math.max(0, Math.min(1, (pax*bax + pay*bay + paz*baz) / (bax*bax + bay*bay + baz*baz)));
    double dx = pax - bax*h, dy = pay - bay*h, dz = paz - baz*h; return Math.sqrt(dx*dx + dy*dy + dz*dz) - r;
  }
  static double sdTorusZ(double x, double y, double z, double cx, double cy, double cz, double R, double r) {
    double px = x - cx, py = y - cy, pz = z - cz; double q = Math.sqrt(px*px + py*py) - R; return Math.sqrt(q*q + pz*pz) - r;
  }
  static double sdCylinderY(double x, double y, double z, double r, double y0, double y1) {
    double d0 = Math.sqrt(x*x + z*z) - r, d1 = Math.max(y0 - y, y - y1);
    double ox = Math.max(d0, 0), oy = Math.max(d1, 0); return Math.min(Math.max(d0, d1), 0) + Math.sqrt(ox*ox + oy*oy);
  }
  /** Figurine in object frame (rotates with the turntable). Excludes the disc. */
  static double sdFigure(double x, double y, double z) {
    double b = DISC_H;
    double d = sdRoundBox(x, y, z, 0.010, b + 0.070, 0.0, 0.055, 0.070, 0.036, 0.012);      // body
    d = Math.min(d, sdSphere(x, y, z, 0.010, b + 0.180, 0.0, 0.045));                          // head
    d = Math.min(d, sdSphere(x, y, z, 0.010, b + 0.180, 0.044, 0.012));                        // nose (fine detail)
    d = Math.min(d, sdCapsule(x, y, z, 0.060, b + 0.120, 0.0, 0.098, b + 0.055, 0.034, 0.016)); // arm
    d = Math.min(d, sdTorusZ(x, y, z, -0.070, b + 0.085, 0.0, 0.026, 0.008));                  // handle (thin)
    d = Math.min(d, sdRoundBox(x, y, z, 0.010, b + 0.006, 0.0, 0.070, 0.006, 0.050, 0.003));  // foot plate
    return d;
  }
  static double sdDisc(double x, double y, double z) { return sdCylinderY(x, y, z, DISC_R, 0.0, DISC_H); }
  static double sdTable(double x, double y, double z) { // 1.6 x 1.2 m table top, 3 cm thick
    return sdRoundBox(x, y, z, 0.0, -0.015, -0.1, 0.8, 0.015, 0.6, 0.002);
  }
  static double sdWall(double x, double y, double z) { return (z + 1.1); }            // plane z = -1.1 behind the object
  static double sdBox2(double x, double y, double z) {                                  // extra static prop (fusion scene only)
    return sdRoundBox(x, y, z, 0.0, 0.06, -0.36, 0.07, 0.06, 0.05, 0.005);
  }

  // Turntable yaw of the figure (radians) and whether the prop exists.
  static final double PREVIEW_SECONDS = Double.parseDouble(System.getProperty("harness.preview", "0.6"));
  double yaw = 0; boolean prop = false; static final boolean VERBOSE = Boolean.getBoolean("harness.verbose");

  double objectSdf(double x, double y, double z) { // figure + disc in scene frame at current yaw
    double c = Math.cos(-yaw), s = Math.sin(-yaw); double ox = c*x + s*z, oz = -s*x + c*z;
    return Math.min(sdFigure(ox, y, oz), sdDisc(ox, y, oz));
  }
  double sceneSdf(double x, double y, double z) {
    double d = objectSdf(x, y, z);
    d = Math.min(d, sdTable(x, y, z)); d = Math.min(d, sdWall(x, y, z));
    if (prop) d = Math.min(d, sdBox2(x, y, z));
    return d;
  }

  /** Sphere-trace from o along unit d. Returns hit distance or -1. */
  double trace(double ox, double oy, double oz, double dx, double dy, double dz, double tMax) {
    double t = 0.05;
    for (int i = 0; i < 256 && t < tMax; i++) {
      double h = sceneSdf(ox + dx*t, oy + dy*t, oz + dz*t);
      if (h < 2e-5) return t;
      t += h * 0.98;
    }
    return -1;
  }

  // ---------------------------------------------------------------- camera
  // Kinect frame K: x right, y down, z forward. R = columns [right, down, forward] in S.
  static class Pose { double[] R = new double[9]; double[] t = new double[3]; }
  static Pose lookAt(double cx, double cy, double cz, double tx, double ty, double tz, double rollRad) {
    double fx = tx - cx, fy = ty - cy, fz = tz - cz, fn = Math.sqrt(fx*fx + fy*fy + fz*fz); fx /= fn; fy /= fn; fz /= fn;
    double rx = fy*0 - fz*1, ry = fz*0 - fx*0, rz = fx*1 - fy*0; // forward x up(0,1,0)
    double rn = Math.sqrt(rx*rx + ry*ry + rz*rz); rx /= rn; ry /= rn; rz /= rn;
    double dx = fy*rz - fz*ry, dy = fz*rx - fx*rz, dz = fx*ry - fy*rx; // forward x right = down
    if (rollRad != 0) { // rotate right/down around forward
      double c = Math.cos(rollRad), s = Math.sin(rollRad);
      double nrx = c*rx + s*dx, nry = c*ry + s*dy, nrz = c*rz + s*dz, ndx = -s*rx + c*dx, ndy = -s*ry + c*dy, ndz = -s*rz + c*dz;
      rx = nrx; ry = nry; rz = nrz; dx = ndx; dy = ndy; dz = ndz;
    }
    Pose p = new Pose();
    p.R[0] = rx; p.R[1] = dx; p.R[2] = fx; p.R[3] = ry; p.R[4] = dy; p.R[5] = fy; p.R[6] = rz; p.R[7] = dz; p.R[8] = fz;
    p.t[0] = cx; p.t[1] = cy; p.t[2] = cz; return p;
  }
  static double[] kToS(Pose p, double x, double y, double z) {
    return new double[]{p.t[0] + p.R[0]*x + p.R[1]*y + p.R[2]*z, p.t[1] + p.R[3]*x + p.R[4]*y + p.R[5]*z, p.t[2] + p.R[6]*x + p.R[7]*y + p.R[8]*z};
  }
  static double[] sToK(Pose p, double x, double y, double z) {
    double ax = x - p.t[0], ay = y - p.t[1], az = z - p.t[2];
    return new double[]{p.R[0]*ax + p.R[3]*ay + p.R[6]*az, p.R[1]*ax + p.R[4]*ay + p.R[7]*az, p.R[2]*ax + p.R[5]*ay + p.R[8]*az};
  }

  // Kinect intrinsics (must match config.properties) and structured-light disparity model.
  // sensor=ideal keeps the older clean model; sensor=kinect360 (default) deliberately
  // injects residual calibration/fixed-pattern/temporal/edge errors; sensor=stress is
  // a pessimistic but still plausible Kinect-v1 profile for regression testing.
  static final int W = 640, H = 480;
  double FX, FY, CX, CY; float[] RAYX, RAYY;
  static final double BASELINE = 0.075, IR_F = 580.0, DISP_Q = 1.0 / 8.0;
  static final String SENSOR_PROFILE = System.getProperty("harness.sensor", "kinect360").trim().toLowerCase(Locale.ROOT);
  static final boolean SENSOR_IDEAL = SENSOR_PROFILE.equals("ideal");
  static final boolean SENSOR_STRESS = SENSOR_PROFILE.equals("stress") || SENSOR_PROFILE.equals("kinect360-stress");
  static final double DISP_SIGMA = SENSOR_IDEAL ? 0.075 : (SENSOR_STRESS ? 0.105 : 0.085);
  Random rng;
  long sensorFrameIndex = 0;
  double temporalDispBias = 0;

  // Residual systematic error left after a normal factory/user calibration. Values are
  // intentionally small: enough to stop synthetic ICP from sharing a mathematically
  // perfect camera with the renderer, but not enough to represent a broken calibration.
  double sensorRayX(int u, int v) {
    double rx = RAYX != null ? RAYX[v*W+u] : (u - CX) / FX;
    if (SENSOR_IDEAL) return rx;
    double x = (u-CX)/Math.max(1.0, FX), y = (v-CY)/Math.max(1.0, FY), r2=x*x+y*y;
    double scale = SENSOR_STRESS ? 1.0022 : 1.0012;
    return rx*scale + (SENSOR_STRESS ? 0.00095 : 0.00055) + rx*r2*(SENSOR_STRESS ? 0.0018 : 0.0009);
  }
  double sensorRayY(int u, int v) {
    double ry = RAYY != null ? RAYY[v*W+u] : (v - CY) / FY;
    if (SENSOR_IDEAL) return ry;
    double x = (u-CX)/Math.max(1.0, FX), y = (v-CY)/Math.max(1.0, FY), r2=x*x+y*y;
    double scale = SENSOR_STRESS ? 0.9975 : 0.9987;
    return ry*scale - (SENSOR_STRESS ? 0.00080 : 0.00045) + ry*r2*(SENSOR_STRESS ? 0.0018 : 0.0009);
  }
  static double hash01(long x) {
    x ^= (x >>> 33); x *= 0xff51afd7ed558ccdL; x ^= (x >>> 33); x *= 0xc4ceb9fe1a85ec53L; x ^= (x >>> 33);
    return ((x >>> 11) & ((1L<<53)-1)) * (1.0 / (1L<<53));
  }
  double fixedPatternDisp(int u, int v) {
    if (SENSOR_IDEAL) return 0;
    double radial = (sq((u-CX)/FX) + sq((v-CY)/FY));
    // Kinect-v1 measurements show image-position dependence and weak vertical striping.
    double stripes = 0.018*Math.sin(u*2.0*Math.PI/31.0) + 0.010*Math.sin(u*2.0*Math.PI/7.0);
    double field = (radial-0.18) * (SENSOR_STRESS ? 0.050 : 0.030);
    double pixel = (hash01(((long)v<<32) ^ u ^ 0x6a09e667f3bcc909L)-0.5) * (SENSOR_STRESS ? 0.045 : 0.028);
    return stripes + field + pixel;
  }

  short[] render(Pose cam, double[] gravityK, int[] validOut) {
    short[] depth = new short[W*H]; float[] z = new float[W*H];
    double[] proj = kToS(cam, BASELINE, 0, 0);
    final long frameSeed = rng.nextLong();
    final long fi = sensorFrameIndex++;
    if (!SENSOR_IDEAL) temporalDispBias = 0.88*temporalDispBias + rng.nextGaussian()*(SENSOR_STRESS ? 0.018 : 0.010);
    final double frameDispBias = temporalDispBias;
    final double stripePhase = 2.0*Math.PI*hash01(frameSeed ^ 0x510e527fade682d1L);
    java.util.stream.IntStream.range(0, H).parallel().forEach(v -> { Random rr = new Random(frameSeed * 1000003L + v); for (int u = 0; u < W; u++) {
      // Use the pipeline's own (lens-distortion corrected) pixel rays so the synthetic
      // sensor and the reconstruction share one camera model.
      double rx = sensorRayX(u,v), ry = sensorRayY(u,v), rn = Math.sqrt(rx*rx + ry*ry + 1);
      double dxk = rx / rn, dyk = ry / rn, dzk = 1 / rn;
      double dx = cam.R[0]*dxk + cam.R[1]*dyk + cam.R[2]*dzk, dy = cam.R[3]*dxk + cam.R[4]*dyk + cam.R[5]*dzk, dz = cam.R[6]*dxk + cam.R[7]*dyk + cam.R[8]*dzk;
      double t = trace(cam.t[0], cam.t[1], cam.t[2], dx, dy, dz, 4.2);
      if (t < 0) continue;
      double px = cam.t[0] + dx*t, py = cam.t[1] + dy*t, pz = cam.t[2] + dz*t;
      // Grazing-angle dropout.
      double e = 1e-4, gx = sceneSdf(px+e,py,pz)-sceneSdf(px-e,py,pz), gy = sceneSdf(px,py+e,pz)-sceneSdf(px,py-e,pz), gz = sceneSdf(px,py,pz+e)-sceneSdf(px,py,pz-e);
      double gn = Math.sqrt(gx*gx+gy*gy+gz*gz); if (gn < 1e-12) continue;
      double cosang = Math.abs((gx*dx + gy*dy + gz*dz) / gn); if (cosang < 0.10 + 0.08*rr.nextDouble()) continue;
      // Projector shadow: the IR pattern must reach the point.
      double qx = px - proj[0], qy = py - proj[1], qz = pz - proj[2], ql = Math.sqrt(qx*qx+qy*qy+qz*qz);
      double th = trace(proj[0], proj[1], proj[2], qx/ql, qy/ql, qz/ql, ql + 0.01);
      if (th >= 0 && th < ql - 0.004) continue;
      double zt = t * dzk; if (zt < 0.4 || zt > 4.0) continue;
      double disp = BASELINE * IR_F / zt + rr.nextGaussian() * DISP_SIGMA;
      if (!SENSOR_IDEAL) {
        // Fixed-pattern disparity error + low-frequency frame/row correlation. The
        // resulting axial sigma still grows approximately quadratically with range.
        disp += fixedPatternDisp(u,v) + frameDispBias + (SENSOR_STRESS ? 0.020 : 0.010)*Math.sin(v*0.075 + stripePhase + fi*0.035);
      }
      disp = Math.round(disp / DISP_Q) * DISP_Q; if (disp <= 1) continue;
      z[v*W+u] = (float)(BASELINE * IR_F / disp);
    } });
    // Edge dropouts at depth discontinuities + sparse speckle holes.
    int valid = 0;
    for (int v = 0; v < H; v++) for (int u = 0; u < W; u++) {
      int i = v*W+u; float c = z[i]; if (c <= 0) continue;
      boolean edge = false;
      if (u > 0 && z[i-1] > 0 && Math.abs(z[i-1]-c) > 0.03) edge = true;
      if (u < W-1 && z[i+1] > 0 && Math.abs(z[i+1]-c) > 0.03) edge = true;
      if (v > 0 && z[i-W] > 0 && Math.abs(z[i-W]-c) > 0.03) edge = true;
      if (v < H-1 && z[i+W] > 0 && Math.abs(z[i+W]-c) > 0.03) edge = true;
      if (edge) {
        double er = rng.nextDouble();
        double drop = SENSOR_IDEAL ? 0.45 : (SENSOR_STRESS ? 0.58 : 0.50);
        if (er < drop) continue;
        // Structured-light correspondence can return a foreground/background mixture
        // around discontinuities ("flying pixels") instead of only a clean hole.
        if (!SENSOR_IDEAL && er < drop + (SENSOR_STRESS ? 0.24 : 0.16)) {
          float n = 0; int nn = 0;
          if (u>0 && z[i-1]>0 && Math.abs(z[i-1]-c)>0.03) {n+=z[i-1];nn++;}
          if (u<W-1 && z[i+1]>0 && Math.abs(z[i+1]-c)>0.03) {n+=z[i+1];nn++;}
          if (v>0 && z[i-W]>0 && Math.abs(z[i-W]-c)>0.03) {n+=z[i-W];nn++;}
          if (v<H-1 && z[i+W]>0 && Math.abs(z[i+W]-c)>0.03) {n+=z[i+W];nn++;}
          if (nn>0) { double a = 0.18 + 0.64*rng.nextDouble(); c = (float)((1-a)*c + a*(n/nn)); }
        }
      }
      double holeP = SENSOR_IDEAL ? 0.003 : (SENSOR_STRESS ? 0.010 : 0.006);
      // Sparse holes plus deterministic small clusters mimic weak/ambiguous IR pattern areas.
      if (rng.nextDouble() < holeP) continue;
      if (!SENSOR_IDEAL) {
        long h = ((long)(u/5)<<32) ^ (v/5) ^ (fi/3)*0x9e3779b97f4a7c15L;
        if (hash01(h) < (SENSOR_STRESS ? 0.010 : 0.004)) continue;
      }
      depth[i] = (short)Math.round(c * 1000.0); valid++;
    }
    validOut[0] = valid; return depth;
  }

  // ---------------------------------------------------------------- scenario
  interface Scenario { Pose camera(double t); double yaw(double t); double duration(); boolean prop(); String name(); }

  static class TurntableScenario implements Scenario {
    final double seconds;
    TurntableScenario(double seconds){this.seconds=seconds;}
    public Pose camera(double t){ return lookAt(0.0, 0.33, 0.78, 0.0, 0.11, 0.0, 0); }
    public double yaw(double t){ return Math.toRadians(360.0 * t / 36.0); } // 10 deg/s, like a manual turntable
    public double duration(){ return seconds; }
    public boolean prop(){ return false; }
    public String name(){ return "turntable"; }
  }
  static class FusionScenario implements Scenario {
    final double seconds; final double[] jx, jy, jz; final Random r = new Random(7);
    FusionScenario(double seconds){this.seconds=seconds;jx=noise();jy=noise();jz=noise();}
    double[] noise(){double[] a=new double[8];for(int i=0;i<8;i++)a[i]=r.nextDouble()*Math.PI*2;return a;}
    double wob(double[] ph,double t){double s=0;for(int k=0;k<4;k++)s+=Math.sin(t*(0.7+k*0.9)+ph[k])/(k+1);return s;}
    public Pose camera(double t){
      // Hand-held sweep around the object: 250 degree arc at ~0.8 m with height bob and hand jitter.
      double a = Math.toRadians(-125 + 250 * t / seconds);
      double radius = 0.80 + 0.04*Math.sin(t*0.9);
      double cx = radius*Math.sin(a) + 0.006*wob(jx,t), cz = radius*Math.cos(a) + 0.006*wob(jz,t), cy = 0.38 + 0.08*Math.sin(t*0.45) + 0.005*wob(jy,t);
      return lookAt(cx, cy, cz, 0.004*wob(jz,t*1.3), 0.10, 0.004*wob(jx,t*1.1), Math.toRadians(3.0*Math.sin(t*0.6)));
    }
    public double yaw(double t){ return 0; }
    public double duration(){ return seconds; }
    public boolean prop(){ return true; }
    public String name(){ return "fusion"; }
  }

  // ---------------------------------------------------------------- evaluation helpers
  /** Ground truth in pipeline world coordinates (= Kinect frame of the first processed frame). */
  Pose worldCam; double worldYaw;
  double gtFigureSdfWorld(double wx, double wy, double wz) {
    double[] s = kToS(worldCam, wx, wy, wz);
    double c = Math.cos(-worldYaw), sn = Math.sin(-worldYaw); double ox = c*s[0] + sn*s[2], oz = -sn*s[0] + c*s[2];
    return sdFigure(ox, s[1], oz);
  }
  double gtOtherSdfWorld(double wx, double wy, double wz) {
    double[] s = kToS(worldCam, wx, wy, wz);
    double c = Math.cos(-worldYaw), sn = Math.sin(-worldYaw); double ox = c*s[0] + sn*s[2], oz = -sn*s[0] + c*s[2];
    double d = Math.min(sdDisc(ox, s[1], oz), Math.min(sdTable(s[0], s[1], s[2]), sdWall(s[0], s[1], s[2])));
    if (prop) d = Math.min(d, sdBox2(s[0], s[1], s[2]));
    return d;
  }

  /** Samples of the observable figure surface in object frame (excludes the face resting on the disc). */
  ArrayList<double[]> figureSurfaceSamples(int n) {
    Random r = new Random(1234); ArrayList<double[]> out = new ArrayList<double[]>();
    int guard = 0;
    while (out.size() < n && guard++ < n*400) {
      double x = -0.12 + r.nextDouble()*0.24, y = DISC_H + r.nextDouble()*0.25, z = -0.07 + r.nextDouble()*0.14;
      for (int it = 0; it < 30; it++) {
        double d = sdFigure(x, y, z); if (Math.abs(d) < 1e-7) break;
        double e = 1e-5, gx = (sdFigure(x+e,y,z)-sdFigure(x-e,y,z))/(2*e), gy = (sdFigure(x,y+e,z)-sdFigure(x,y-e,z))/(2*e), gz = (sdFigure(x,y,z+e)-sdFigure(x,y,z-e))/(2*e);
        double g2 = gx*gx+gy*gy+gz*gz; if (g2 < 1e-12) break; x -= d*gx/g2; y -= d*gy/g2; z -= d*gz/g2;
      }
      if (Math.abs(sdFigure(x, y, z)) > 1e-5) continue;
      if (y < DISC_H + 0.0125 + 1e-4) continue;             // underside / foot-plate top face near the disc is barely visible
      if (sdDisc(x, y, z) < 0.003) continue;
      out.add(new double[]{x, y, z});
    }
    return out;
  }

  static class Metrics { int vertices, figureVertices; double meanMm, rmsMm, p50Mm, p90Mm, p99Mm, outlierPct, complete2, complete4, complete8; double signedBiasMm, shell95Mm; int triangles; }

  Metrics evaluate(SynKinectStudio.Mesh3D mesh, ArrayList<double[]> surfaceObj) {
    Metrics m = new Metrics(); if (mesh == null) return m;
    m.triangles = mesh.triangleCount();
    // Unique vertices (quantised) so shared corners are not triple counted.
    HashMap<Long, float[]> verts = new HashMap<Long, float[]>();
    for (SynKinectStudio.Triangle3D t : mesh.triangles) for (PVector p : new PVector[]{t.a, t.b, t.c}) {
      long k = (((long)Math.round(p.x*20000)) * 73856093L) ^ (((long)Math.round(p.y*20000)) * 19349663L) ^ (((long)Math.round(p.z*20000)) * 83492791L);
      verts.put(k, new float[]{p.x, p.y, p.z});
    }
    m.vertices = verts.size();
    ArrayList<Double> err = new ArrayList<Double>();
    ArrayList<Double> signedErr = new ArrayList<Double>();
    ArrayList<float[]> figureVerts = new ArrayList<float[]>();
    int outliers = 0;
    for (float[] p : verts.values()) {
      double df = gtFigureSdfWorld(p[0], p[1], p[2]), dother = gtOtherSdfWorld(p[0], p[1], p[2]);
      if (Math.abs(df) > 0.03) continue;                 // clearly not figure geometry
      if (Math.abs(dother) < Math.abs(df)) continue;     // belongs to disc/table/wall
      if (Math.abs(dother) < 0.006) continue;            // contact region is ambiguous
      double se = df * 1000.0, e = Math.abs(se); err.add(e); signedErr.add(se); figureVerts.add(p); if (e > 5.0) outliers++;
    }
    m.figureVertices = err.size();
    if (!err.isEmpty()) {
      Collections.sort(err); double s = 0, s2 = 0; for (double e : err) { s += e; s2 += e*e; }
      m.meanMm = s / err.size(); m.rmsMm = Math.sqrt(s2 / err.size());
      m.p50Mm = err.get(err.size()/2); m.p90Mm = err.get((int)(err.size()*0.90)); m.p99Mm = err.get(Math.min(err.size()-1,(int)(err.size()*0.99)));
      m.outlierPct = 100.0 * outliers / err.size();
      Collections.sort(signedErr); double ss=0; for(double e:signedErr) ss+=e; m.signedBiasMm=ss/signedErr.size();
      int lo=Math.max(0,(int)Math.floor(signedErr.size()*0.025)), hi=Math.min(signedErr.size()-1,(int)Math.floor(signedErr.size()*0.975));
      m.shell95Mm=signedErr.get(hi)-signedErr.get(lo);
    }
    // Completeness: fraction of GT surface samples with a figure vertex within X mm.
    HashMap<Long, ArrayList<float[]>> grid = new HashMap<Long, ArrayList<float[]>>(); double cell = 0.008;
    for (float[] p : figureVerts) { long k = key(p[0], p[1], p[2], cell); grid.computeIfAbsent(k, kk -> new ArrayList<float[]>()).add(p); }
    int c2 = 0, c4 = 0, c8 = 0;
    for (double[] q : surfaceObj) {
      // object frame -> scene (world yaw) -> world (Kinect frame 0)
      double c = Math.cos(worldYaw), sn = Math.sin(worldYaw); double sx = c*q[0] + sn*q[2], sz = -sn*q[0] + c*q[2];
      double[] w = sToK(worldCam, sx, q[1], sz);
      double best = 1e9;
      int ix = (int)Math.floor(w[0]/cell), iy = (int)Math.floor(w[1]/cell), iz = (int)Math.floor(w[2]/cell);
      for (int a = -1; a <= 1; a++) for (int b = -1; b <= 1; b++) for (int d = -1; d <= 1; d++) {
        ArrayList<float[]> l = grid.get(keyI(ix+a, iy+b, iz+d)); if (l == null) continue;
        for (float[] p : l) { double dx = p[0]-w[0], dy = p[1]-w[1], dz = p[2]-w[2]; best = Math.min(best, dx*dx+dy*dy+dz*dz); }
      }
      best = Math.sqrt(best);
      if (best <= 0.002) c2++; if (best <= 0.004) c4++; if (best <= 0.008) c8++;
    }
    m.complete2 = 100.0*c2/Math.max(1, surfaceObj.size()); m.complete4 = 100.0*c4/Math.max(1, surfaceObj.size()); m.complete8 = 100.0*c8/Math.max(1, surfaceObj.size());
    return m;
  }
  static long key(double x, double y, double z, double cell){ return keyI((int)Math.floor(x/cell),(int)Math.floor(y/cell),(int)Math.floor(z/cell)); }
  static long keyI(int x, int y, int z){ return (((long)x) * 73856093L) ^ (((long)y) * 19349663L) ^ (((long)z) * 83492791L); }

  static String fmt(Metrics m) {
    return String.format(Locale.ROOT, "tris=%d figVerts=%d | err mean=%.2fmm rms=%.2fmm p50=%.2f p90=%.2f p99=%.2f >5mm=%.1f%% | shell95=%.2fmm bias=%+.2fmm | completeness @2mm=%.1f%% @4mm=%.1f%% @8mm=%.1f%%",
      m.triangles, m.figureVertices, m.meanMm, m.rmsMm, m.p50Mm, m.p90Mm, m.p99Mm, m.outlierPct, m.shell95Mm, m.signedBiasMm, m.complete2, m.complete4, m.complete8);
  }

  static void writeObj(SynKinectStudio.Mesh3D mesh, File f) throws IOException {
    try (PrintWriter out = new PrintWriter(new BufferedWriter(new FileWriter(f)))) {
      int i = 1; for (SynKinectStudio.Triangle3D t : mesh.triangles) {
        out.printf(Locale.ROOT, "v %.5f %.5f %.5f%nv %.5f %.5f %.5f%nv %.5f %.5f %.5f%nf %d %d %d%n", t.a.x, -t.a.y, -t.a.z, t.b.x, -t.b.y, -t.b.z, t.c.x, -t.c.y, -t.c.z, i, i+1, i+2); i += 3; }
    }
  }

  // ---------------------------------------------------------------- main
  public static void main(String[] args) throws Exception {
    String mode = args.length > 0 ? args[0] : "turntable";
    double seconds = args.length > 1 ? Double.parseDouble(args[1]) : (mode.equals("fusion") ? 30 : 38);
    long seed = args.length > 2 ? Long.parseLong(args[2]) : 42;
    String outDir = System.getProperty("harness.out", "/home/claude/build/out");
    new File(outDir).mkdirs();
    if (mode.equals("bias")) new ScanHarness().bias(seed); else if (mode.equals("focus")) new ScanHarness().focus(); else
    new ScanHarness().run(mode, seconds, seed, outDir);
    System.exit(0);
  }

  void run(String mode, double seconds, long seed, String outDir) throws Exception {
    rng = new Random(seed);
    Scenario sc = mode.equals("fusion") ? new FusionScenario(seconds) : new TurntableScenario(seconds);
    prop = sc.prop();

    SynKinectStudio app = new SynKinectStudio();
    app.studio = app.new StudioController(app.new StudioServices());
    SynKinectStudio.ScannerModuleState st = app.studio.moduleStates.install(SynKinectStudio.ScannerModuleState.class, app.new ScannerModuleState());
    app.ensureRgbdCore();
    SynKinectStudio.AppConfig cfg = st.config;
    cfg.meshColorEnabled = false; cfg.colorIcpEnabled = false; // geometry-only benchmark
    for (String kv : System.getProperty("harness.cfg", "").split(",")) {       // -Dharness.cfg=icpIterations=30,voxelSizeM=0.002
      if (kv.trim().isEmpty()) continue; String[] a = kv.split("=", 2); java.lang.reflect.Field fl = cfg.getClass().getDeclaredField(a[0].trim()); fl.setAccessible(true);
      Class<?> ty = fl.getType(); String v = a[1].trim();
      if (ty == int.class) fl.setInt(cfg, Integer.parseInt(v)); else if (ty == float.class) fl.setFloat(cfg, Float.parseFloat(v)); else if (ty == boolean.class) fl.setBoolean(cfg, Boolean.parseBoolean(v)); else fl.set(cfg, v);
      System.out.println("override " + a[0] + "=" + v);
    }
    // Wire the processing session exactly like setupScannerModule(), minus UI and worker thread.
    st.processing = app.studio.services.processingBlocks.openScanner(cfg, st.calibration, st.rgbRegistration);
    st.depthAnalyzer = st.processing.depthAnalyzer; st.depthRenderer = st.processing.depthRenderer;
    st.pointCloudBuilder = st.processing.pointCloudBuilder; st.tracker = st.processing.tracker;
    st.boundingBox = st.processing.boundingBox; st.previewPointModel = st.processing.previewPointModel;
    st.meshEditor = st.processing.meshEditor;
    st.scanCoverage = st.processing.scanCoverage; st.depthTarget = st.processing.depthTarget;
    st.hqArchive = st.processing.hqArchive; st.hqReconstructor = st.processing.hqReconstructor; st.cloudStats = st.processing.cloudStats;
    st.mesh = app.new Mesh3D();
    st.scanMode = mode.equals("fusion") ? SynKinectStudio.ScannerModuleState.MODE_FUSION : SynKinectStudio.ScannerModuleState.MODE_TURNTABLE;
    FX = st.calibration.fx; FY = st.calibration.fy; CX = st.calibration.cx; CY = st.calibration.cy; RAYX = st.rgbRegistration.rayX; RAYY = st.rgbRegistration.rayY;
    System.out.printf(Locale.ROOT, "mode=%s seconds=%.0f sensor=%s intrinsics fx=%.1f fy=%.1f cx=%.1f cy=%.1f volume=%d voxel=%.4f trunc=%.4f%n",
      mode, seconds, SENSOR_PROFILE, FX, FY, CX, CY, cfg.volumeSize, cfg.voxelSizeM, cfg.truncationM);

    // ---- stream
    double fps = 30.0; int frames = (int)Math.round(Math.min(seconds, Double.parseDouble(System.getProperty("harness.stopAfter", "1e9"))) * fps);
    double nextAllowedMs = 0; boolean started = false; int processed = 0; long frameNo = 0;
    double sumProcMs = 0; ArrayList<double[]> poseErrors = new ArrayList<double[]>(); ArrayList<SynKinectStudio.RigidTransform> trajectory = new ArrayList<SynKinectStudio.RigidTransform>();
    Pose firstCam = null; double firstYaw = 0;
    boolean useWallClock = !"false".equals(System.getProperty("harness.realtime", "true"));
    for (int f = 0; f < frames; f++) {
      double tSec = f / fps, tMs = tSec * 1000.0;
      if (started && !st.scanActive) { System.out.println("scan stopped by pipeline at t=" + String.format(Locale.ROOT, "%.1f", tSec) + "s: " + st.status); break; }
      if (tMs + 1e-6 < nextAllowedMs) continue;               // frame dropped: worker busy / cadence limit
      yaw = sc.yaw(tSec); Pose cam = sc.camera(tSec);
      // Accelerometer: "up" reaction vector expressed in Kinect coordinates (+/- 1 g = 819 counts).
      double[] upK = new double[]{cam.R[0]*0 + cam.R[3]*1 + cam.R[6]*0, cam.R[1]*0 + cam.R[4]*1 + cam.R[7]*0, cam.R[2]*0 + cam.R[5]*1 + cam.R[8]*0};
      int[] valid = new int[1]; short[] depth = render(cam, upK, valid);
      SynKinectStudio.DepthFrame df = app.new DepthFrame();
      df.width = W; df.height = H; df.stride = W*2; df.depth = depth; df.frameNumber = ++frameNo; df.frameId = (int)frameNo;
      double tsJitterUs = SENSOR_IDEAL ? 0 : rng.nextGaussian()*(SENSOR_STRESS ? 420.0 : 220.0);
      df.timestampUs = (long)(tSec * 1e6 + tsJitterUs); df.validCount = valid[0]; df.plausibleCount = valid[0]; df.deviceCalibrated = true;
      double accelNoise = SENSOR_IDEAL ? 0 : (SENSOR_STRESS ? 3.5 : 1.8);
      double accelBiasX = SENSOR_IDEAL ? 0 : 1.5, accelBiasY = SENSOR_IDEAL ? 0 : -1.0, accelBiasZ = SENSOR_IDEAL ? 0 : 0.8;
      df.motion.flags = 1; df.motion.accelX = (int)Math.round(upK[0]*819 + accelBiasX + rng.nextGaussian()*accelNoise); df.motion.accelY = (int)Math.round(upK[1]*819 + accelBiasY + rng.nextGaussian()*accelNoise); df.motion.accelZ = (int)Math.round(upK[2]*819 + accelBiasZ + rng.nextGaussian()*accelNoise);
      SynKinectStudio.RgbdFramePair pair = app.new RgbdFramePair(df, null, null, null, frameNo, 0, 0, 1.0f);
      st.latestDepth = df; st.latestPair = pair;
      st.latestDepthDiagnostics = st.depthAnalyzer.analyze(df, cfg);
      if (!started && tSec < PREVIEW_SECONDS) {
        // Idle preview before the operator presses Scan: locks support plane and detection volume.
        st.showLiveDetectionCloud = true; app.updateLiveDetectionPreview(pair, null); nextAllowedMs = tMs + 66;
        if (VERBOSE) { SynKinectStudio.DepthTargetEstimate te = st.depthAnalyzer.estimateTarget(df, cfg, Float.NaN);
          System.out.printf(Locale.ROOT, "  preview t=%.2f target=%.3f valid=%s spread=%.3f support=%s locked=%s box=[%.3f..%.3f, %.3f..%.3f, %.3f..%.3f] preview=%d%n", tSec, te.depthM, te.valid, te.spreadM, st.depthAnalyzer.support!=null, st.boundingBox.locked,
            st.boundingBox.minX, st.boundingBox.maxX, st.boundingBox.minY, st.boundingBox.maxY, st.boundingBox.minZ, st.boundingBox.maxZ, st.uiPreviewCloud==null?-1:st.uiPreviewCloud.size()); }
        continue;
      }
      if (!started) {
        app.resetReconstructionState(true);   // startScan(): preserve the previewed detection volume
        st.scanActive = true; st.scanPaused = false; st.showLiveDetectionCloud = false; started = true;
      }
      long t0 = System.nanoTime();
      int keyframesBefore = st.hqArchive.size();
      app.processScanFrame(pair);
      double procMs = (System.nanoTime() - t0) / 1e6; sumProcMs += procMs; processed++;
      if (firstCam == null && !st.tracker.referenceWindow.isEmpty()) { firstCam = cam; firstYaw = yaw; }
      // Emulate the Studio cadence: consumeKinectFrames() queues at most every minInterval and
      // a single-slot worker keeps only the newest frame while busy.
      double minInterval = 1000.0 / Math.max(1, cfg.reconstructionMaxFps);
      if (cfg.reconstructionAdaptiveCadence && st.captureWorkMsEma > 0)
        minInterval = Math.max(minInterval, Math.min(cfg.reconstructionMaxIntervalMs, Math.ceil(st.captureWorkMsEma / Math.max(0.10f, cfg.reconstructionTargetUtilization))));
      nextAllowedMs = tMs + Math.max(minInterval, useWallClock ? procMs : 0);
      if (st.hqArchive.size() > keyframesBefore) { poseErrors.add(new double[]{tSec, yaw}); SynKinectStudio.RigidTransform cp = app.new RigidTransform(); cp.set(st.tracker.pose); trajectory.add(cp); }
      if (VERBOSE && processed % 10 == 3 && !mode.equals("fusion")) cloudComposition(app, st, df, cam);
      if (VERBOSE && mode.equals("fusion") && firstCam != null) { double[] gc = sToK(firstCam, cam.t[0], cam.t[1], cam.t[2]); SynKinectStudio.RigidTransform tp = st.tracker.pose;
        System.out.printf(Locale.ROOT, "  cam gt=(%.3f,%.3f,%.3f) est=(%.3f,%.3f,%.3f) anchor=%s%n", gc[0],gc[1],gc[2], tp.m[3],tp.m[7],tp.m[11], st.tracker.fusionAnchorPose==null?"-":String.format(Locale.ROOT,"(%.3f,%.3f,%.3f)",st.tracker.fusionAnchorPose.m[3],st.tracker.fusionAnchorPose.m[7],st.tracker.fusionAnchorPose.m[11])); }
      if (VERBOSE) System.out.printf(Locale.ROOT, "  f=%d t=%.2f gtYaw=%.1f poseYaw=%.2f trackedTurn=%.1f sweep=%.1f seedYaw=%.2f seedConf=%.2f good=%s rms=%.2f matches=%d ov=%.2f keyframes=%d pivotCal=%s pivotErr=%.1fmm status=%s%n",
        f, tSec, Math.toDegrees(yaw-firstYaw), -st.tracker.turntableDeltaDeg(app.new RigidTransform(), st.tracker.pose), st.scanCoverage.trackedAngleDeg, st.scanCoverage.sweepDeg, st.tracker.turntableSeedYawDeg, st.tracker.turntableSeedConfidence, st.tracker.trackingGood, st.tracker.rms*1000, st.tracker.matches, st.tracker.overlap, st.hqArchive.size(), st.tracker.turntablePivotCalibrated, pivotErrMm(st.tracker.turntablePivotWorld, firstCam), st.status);
      if (processed % 25 == 0) System.out.printf(Locale.ROOT, "t=%5.1fs processed=%d keyframes=%d rejected=%d track=%s rms=%.2fmm prog=%.0f%% proc=%.0fms | %s%n",
        tSec, processed, st.hqArchive.size(), st.rejectedTrackingFrames, app.scannerTrackingStateName(), st.uiIcpRmsMm, st.uiProgress*100, procMs, st.status);
    }
    System.out.printf(Locale.ROOT, "stream done: processed=%d keyframes=%d rejected=%d lossEvents=%d avgProc=%.1fms hqKeyframes=%d%n",
      processed, st.hqArchive.size(), st.rejectedTrackingFrames, st.trackingLossEvents, sumProcMs / Math.max(1, processed), st.hqArchive.size());
    if (firstCam == null) { System.out.println("NO RECONSTRUCTION"); return; }

    // World frame of the pipeline = Kinect frame of the first tracked frame (pose identity).
    // For turntable the equivalent fixed world is the object at its first-frame yaw.
    worldCam = firstCam; worldYaw = firstYaw;
    // In Fusion, pose identity is assigned to the first tracked/keyframed view.
    ArrayList<double[]> surface = figureSurfaceSamples(6000);

    // ---- final pose error (last accepted pose vs ground truth)
    SynKinectStudio.RigidTransform est = trajectory.isEmpty()?null:trajectory.get(trajectory.size()-1);
    if (est != null && !poseErrors.isEmpty()) {
      double[] last = poseErrors.get(poseErrors.size()-1); double tl = last[0];
      Pose camL = sc.camera(tl); double yawL = sc.yaw(tl);
      // GT camera_L -> world0: object-fixed world. Point in camL -> scene -> object(yawL) -> scene(yaw0) -> cam0.
      double[] probe = {0.02, -0.03, 0.8}; double[] ps = kToS(camL, probe[0], probe[1], probe[2]);
      double d = yaw0Shift(ps, yawL, worldYaw); double[] gw = sToK(worldCam, ps[0]*Math.cos(d)+ps[2]*Math.sin(d), ps[1], -ps[0]*Math.sin(d)+ps[2]*Math.cos(d));
      PVector ew = est.apply(new PVector((float)probe[0], (float)probe[1], (float)probe[2]));
      System.out.printf(Locale.ROOT, "final pose probe error (0.8 m ahead): %.2f mm%n", 1000*Math.sqrt(sq(ew.x-gw[0])+sq(ew.y-gw[1])+sq(ew.z-gw[2])));
    }

    // ---- trajectory error: displacement of probe points on the figure (world frame)
    {
      double[][] probesObj = {{0.06,0.03,0.04},{-0.05,0.03,0.04},{0.06,0.03,-0.04},{-0.05,0.03,-0.04},{0.01,0.22,0.0},{0.1,0.08,0.03}};
      double maxE=0,sumE=0; int n=0; StringBuilder sb=new StringBuilder();
      for (int i=0;i<trajectory.size();i++){
        double tl=poseErrors.get(i)[0]; Pose camL=sc.camera(tl); double yawL=sc.yaw(tl); double e=0;
        for (double[] q : probesObj){
          // object point -> scene at yawL -> camera L -> estimated world
          double c=Math.cos(yawL), sn=Math.sin(yawL); double sx=c*q[0]+sn*q[2], sz=-sn*q[0]+c*q[2]; double[] kL=sToK(camL,sx,q[1],sz);
          PVector ew=trajectory.get(i).apply(new PVector((float)kL[0],(float)kL[1],(float)kL[2]));
          double c0=Math.cos(worldYaw), s0=Math.sin(worldYaw); double[] gw=sToK(worldCam, c0*q[0]+s0*q[2], q[1], -s0*q[0]+c0*q[2]);
          e+=Math.sqrt(sq(ew.x-gw[0])+sq(ew.y-gw[1])+sq(ew.z-gw[2]));
        }
        e=1000*e/probesObj.length; maxE=Math.max(maxE,e); sumE+=e; n++;
        if (i % Math.max(1,trajectory.size()/12) == 0) sb.append(String.format(Locale.ROOT," %.0fdeg:%.1f", Math.toDegrees(yawL-worldYaw), e));
      }
      System.out.printf(Locale.ROOT, "TRAJECTORY object-probe error: mean=%.2fmm max=%.2fmm |%s%n", sumE/Math.max(1,n), maxE, sb);
      System.out.printf(Locale.ROOT, "pivot calibrated=%s error=%.1fmm%n", st.tracker.turntablePivotCalibrated, pivotErrMm(st.tracker.turntablePivotWorld, worldCam));
    }
    long t0 = System.nanoTime();
    SynKinectStudio.Mesh3D fast = app.reconstructScannerArchive(false);
    double fastMs = (System.nanoTime() - t0) / 1e6;
    Metrics mf = evaluate(fast, surface);
    System.out.printf(Locale.ROOT, "BUILD MESH (%.0f ms): %s%n", fastMs, fmt(mf));
    writeObj(fast, new File(outDir, mode + "-build.obj"));

    if (!"false".equals(System.getProperty("harness.hq", "true")) && st.hqArchive.size() >= cfg.hqMinimumKeyframes) {
      t0 = System.nanoTime();
      SynKinectStudio.Mesh3D hq = app.reconstructScannerArchive(true);
      double hqMs = (System.nanoTime() - t0) / 1e6;
      Metrics mh = evaluate(hq, surface);
      System.out.printf(Locale.ROOT, "REFINE HQ (%.0f ms): %s%n", hqMs, fmt(mh));
      if (hq != null) writeObj(hq, new File(outDir, mode + "-hq.obj"));
    }
  }
  static double sq(double v){return v*v;}
  SynKinectStudio.RigidTransform gtTurntablePose(SynKinectStudio app, Pose cam, double yawK, double yaw0){
    // camera_k -> world(camera_0 with object at yaw0)
    SynKinectStudio.RigidTransform t = app.new RigidTransform();
    double[] o = sToK(cam, 0,0,0); // not used
    double[][] cols = new double[4][];
    double[][] basis = {{0,0,0},{1,0,0},{0,1,0},{0,0,1}};
    for (int i=0;i<4;i++){ double[] sp = kToS(cam, basis[i][0], basis[i][1], basis[i][2]); double d = yaw0 - yawK;
      double x = Math.cos(d)*sp[0] + Math.sin(d)*sp[2], z = -Math.sin(d)*sp[0] + Math.cos(d)*sp[2]; cols[i] = sToK(cam, x, sp[1], z); }
    for (int r=0;r<3;r++){ t.m[r*4+3]=(float)cols[0][r]; for(int c=0;c<3;c++) t.m[r*4+c]=(float)(cols[c+1][r]-cols[0][r]); }
    return t;
  }
  SynKinectStudio.PointCloud roi(SynKinectStudio app, SynKinectStudio.PointCloud c, Pose cam){
    SynKinectStudio.PointCloud out = app.new PointCloud();
    for (int i=0;i<c.size();i++){ PVector p=c.points.get(i); double[] sp=kToS(cam,p.x,p.y,p.z);
      if (Math.sqrt(sp[0]*sp[0]+sp[2]*sp[2])<0.16 && sp[1]>0.008 && sp[1]<0.32) out.add(p.copy(), c.colorAt(i), c.confidenceAt(i)); }
    return out;
  }
  /** Fast deterministic regression for the idle Turntable autofocus/ROI.
   * A stable 0.90 m subject is periodically occluded by a significant 0.65 m
   * foreground mode. The preview should keep the already-acquired subject rather
   * than rebuilding its depth target from scratch and emptying/shifting the ROI.
   */
  void focus() throws Exception {
    SynKinectStudio app = new SynKinectStudio();
    app.studio = app.new StudioController(app.new StudioServices());
    SynKinectStudio.ScannerModuleState st = app.studio.moduleStates.install(SynKinectStudio.ScannerModuleState.class, app.new ScannerModuleState());
    app.ensureRgbdCore(); SynKinectStudio.AppConfig cfg = st.config;
    cfg.meshColorEnabled=false; cfg.supportPlaneEnabled=false; cfg.boundingBoxEnabled=true;
    st.processing = app.studio.services.processingBlocks.openScanner(cfg, st.calibration, st.rgbRegistration);
    st.depthAnalyzer=st.processing.depthAnalyzer; st.depthRenderer=st.processing.depthRenderer;
    st.pointCloudBuilder=st.processing.pointCloudBuilder; st.tracker=st.processing.tracker;
    st.boundingBox=st.processing.boundingBox; st.previewPointModel=st.processing.previewPointModel;
    st.meshEditor=st.processing.meshEditor; st.scanCoverage=st.processing.scanCoverage;
    st.depthTarget=st.processing.depthTarget; st.hqArchive=st.processing.hqArchive; st.hqReconstructor=st.processing.hqReconstructor; st.cloudStats=st.processing.cloudStats;
    st.scanMode=SynKinectStudio.ScannerModuleState.MODE_TURNTABLE; st.showLiveDetectionCloud=true; st.scanActive=false;

    int tested=0,dropouts=0,minPoints=Integer.MAX_VALUE; float minMedian=Float.POSITIVE_INFINITY,maxMedian=Float.NEGATIVE_INFINITY,lastMedian=Float.NaN,maxJump=0;
    for(int f=0;f<30;f++){
      short[] depth=new short[W*H]; Arrays.fill(depth,(short)1600);
      // Main subject: strong, centered 0.90 m mode.
      for(int y=115;y<395;y++)for(int x=190;x<450;x++)depth[y*W+x]=(short)900;
      // From frame 6 onward, every other frame contains a large nearer mode. It
      // is deliberately >30% of the remaining subject mode so preferNearest would
      // steal focus if preferredDepth is reset to NaN every frame.
      if(f>=6&&(f&1)==0)for(int y=155;y<365;y++)for(int x=190;x<275;x++)depth[y*W+x]=(short)650;
      SynKinectStudio.DepthFrame df=app.new DepthFrame();df.width=W;df.height=H;df.depth=depth;df.deviceCalibrated=true;df.validCount=df.plausibleCount=depth.length;df.timestampUs=f*33333L;df.frameNumber=f;
      st.latestDepthDiagnostics=st.depthAnalyzer.analyze(df,cfg);
      SynKinectStudio.RgbdFramePair pair=app.new RgbdFramePair(df,null,null,null,f,0,0,1.0f);
      app.updateLiveDetectionPreview(pair,null);
      if(f<6)continue;
      tested++;int n=st.uiPreviewCloud==null?0:st.uiPreviewCloud.size();minPoints=Math.min(minPoints,n);if(n<cfg.minimumTrackingPoints){dropouts++;continue;}
      float[] zs=new float[n];for(int i=0;i<n;i++)zs[i]=st.uiPreviewCloud.points.get(i).z;Arrays.sort(zs);float med=zs[n/2];
      minMedian=Math.min(minMedian,med);maxMedian=Math.max(maxMedian,med);if(!Float.isNaN(lastMedian))maxJump=Math.max(maxJump,Math.abs(med-lastMedian));lastMedian=med;
    }
    float range=(Float.isFinite(minMedian)&&Float.isFinite(maxMedian))?(maxMedian-minMedian)*1000.0f:Float.POSITIVE_INFINITY;
    System.out.printf(Locale.ROOT,"FOCUS PREVIEW frames=%d dropouts=%d minPoints=%d medianDepthRange=%.1fmm maxJump=%.1fmm trackerDepth=%s bboxLocked=%s%n",
      tested,dropouts,minPoints==Integer.MAX_VALUE?0:minPoints,range,maxJump*1000.0f,Float.isNaN(st.depthTarget.depthM)?"NaN":String.format(Locale.ROOT,"%.3fm",st.depthTarget.depthM),st.boundingBox.locked);
    boolean pass=dropouts==0&&range<=35.0f&&maxJump*1000.0f<=35.0f&&st.boundingBox.locked;
    System.out.println(pass?"FOCUS RESULT: PASS":"FOCUS RESULT: FAIL");
    if(!pass)throw new IllegalStateException("Idle focus/ROI is unstable");
  }

  void bias(long seed) throws Exception {
    rng = new Random(seed); prop = false;
    SynKinectStudio app = new SynKinectStudio();
    app.studio = app.new StudioController(app.new StudioServices());
    SynKinectStudio.ScannerModuleState st = app.studio.moduleStates.install(SynKinectStudio.ScannerModuleState.class, app.new ScannerModuleState());
    app.ensureRgbdCore(); SynKinectStudio.AppConfig cfg = st.config; cfg.meshColorEnabled=false;
    for (String kv : System.getProperty("harness.cfg", "").split(",")) { if (kv.trim().isEmpty()) continue; String[] a = kv.split("=", 2); java.lang.reflect.Field fl = cfg.getClass().getDeclaredField(a[0].trim()); fl.setAccessible(true); Class<?> ty = fl.getType(); String v = a[1].trim(); if (ty == int.class) fl.setInt(cfg, Integer.parseInt(v)); else if (ty == float.class) fl.setFloat(cfg, Float.parseFloat(v)); else fl.setBoolean(cfg, Boolean.parseBoolean(v)); }
    st.processing = app.studio.services.processingBlocks.openScanner(cfg, st.calibration, st.rgbRegistration);
    st.pointCloudBuilder = st.processing.pointCloudBuilder; st.tracker = st.processing.tracker; st.boundingBox = st.processing.boundingBox;
    st.scanMode = SynKinectStudio.ScannerModuleState.MODE_TURNTABLE;
    FX = st.calibration.fx; FY = st.calibration.fy; CX = st.calibration.cx; CY = st.calibration.cy; RAYX = st.rgbRegistration.rayX; RAYY = st.rgbRegistration.rayY;
    TurntableScenario sc = new TurntableScenario(40); Pose cam = sc.camera(0);
    double[] upK = {cam.R[3], cam.R[4], cam.R[5]};
    double stepDeg = Double.parseDouble(System.getProperty("harness.step", "1.7"));
    int K = Integer.parseInt(System.getProperty("harness.k", "12"));
    SynKinectStudio.SupportPlaneEstimator est = app.new SupportPlaneEstimator(cfg);
    double yaw0 = 0; SynKinectStudio.TSDFVolume vol = app.new TSDFVolume(cfg.volumeSize,cfg.voxelSizeM,cfg.truncationM,cfg.rgbTemporalColorWeightMax); vol.setProjection(st.calibration,cfg); vol.projectiveCellPx=cfg.integrationPointStep; boolean init=false;
    for (int k = 0; k <= K + 6; k++) {
      yaw = Math.toRadians(k * stepDeg); int[] valid = new int[1]; short[] depth = render(cam, upK, valid);
      SynKinectStudio.DepthFrame df = app.new DepthFrame(); df.width=W; df.height=H; df.depth=depth; df.deviceCalibrated=true; df.validCount=df.plausibleCount=valid[0];
      df.motion.flags=1; df.motion.accelX=(int)Math.round(upK[0]*819); df.motion.accelY=(int)Math.round(upK[1]*819); df.motion.accelZ=(int)Math.round(upK[2]*819);
      if (k==0) { st.boundingBox.setSupportPlane(est.estimate(df, st.calibration, st.rgbRegistration, df.motion)); }
      SynKinectStudio.PointCloud cl = st.pointCloudBuilder.build(df, st.calibration, cfg.pointStep, Float.NaN, Float.POSITIVE_INFINITY, null, null);
      cl = roi(app, cl, cam);
      SynKinectStudio.RigidTransform gt = gtTurntablePose(app, cam, yaw, yaw0);
      if (k < K) {
        SynKinectStudio.PointCloud dense = st.pointCloudBuilder.build(df, st.calibration, cfg.integrationPointStep, Float.NaN, Float.POSITIVE_INFINITY, null, null); dense = roi(app, dense, cam);
        if (!init) { vol.resetAroundCloud(dense, gt, cfg); init = true; }
        vol.integrate(dense, gt, 2, true, 1.0f);
        continue;
      }
      if (k == K) {
        worldCam = cam; worldYaw = yaw0;
        vol.ensureSurfaceModel(cfg);
        double se=0, sa=0; int n=0;
        for (java.util.Map.Entry<PVector,PVector> e : vol.surfaceModelNormals.entrySet()) { PVector q=e.getKey(); double d = Math.min(gtFigureSdfWorld(q.x,q.y,q.z), gtOtherSdfWorld(q.x,q.y,q.z)); se+=d; sa+=Math.abs(d); n++; }
        System.out.printf(Locale.ROOT, "model points n=%d mean signed err=%.2fmm mean abs=%.2fmm voxel=%.4f trunc=%.4f%n", n, 1000*se/n, 1000*sa/n, vol.voxelSize, vol.truncation);
        double ce=0, ca=0; int cn=0; for (PVector p : cl.points) { PVector w = gt.apply(p); double d = Math.min(gtFigureSdfWorld(w.x,w.y,w.z), gtOtherSdfWorld(w.x,w.y,w.z)); ce+=d; ca+=Math.abs(d); cn++; }
        for (int ii=0; ii<cl.size(); ii+=cl.size()/6) { PVector p=cl.points.get(ii); PVector w=gt.apply(p); double[] sc0=kToS(cam,p.x,p.y,p.z);
          System.out.printf(Locale.ROOT, "  pt cam=(%.3f,%.3f,%.3f) scene=(%.3f,%.3f,%.3f) sceneSdfNow=%.4f gtWorld=%.4f%n", p.x,p.y,p.z, sc0[0],sc0[1],sc0[2], sceneSdf(sc0[0],sc0[1],sc0[2]), Math.min(gtFigureSdfWorld(w.x,w.y,w.z), gtOtherSdfWorld(w.x,w.y,w.z))); }
        System.out.printf(Locale.ROOT, "frame cloud at GT: n=%d mean signed=%.2fmm mean abs=%.2fmm%n", cn, 1000*ce/cn, 1000*ca/cn);
        SynKinectStudio.Mesh3D mesh = vol.extractMesh(cfg.meshMinWeight); double me=0, ma=0; int mn=0;
        for (SynKinectStudio.Triangle3D t : mesh.triangles) { PVector q=t.a; double d = Math.min(gtFigureSdfWorld(q.x,q.y,q.z), gtOtherSdfWorld(q.x,q.y,q.z)); me+=d; ma+=Math.abs(d); mn++; }
        System.out.printf(Locale.ROOT, "extracted mesh verts n=%d mean signed=%.2fmm mean abs=%.2fmm%n", mn, 1000*me/mn, 1000*ma/mn);
      }
      // Track frame k starting from GT and from GT +/- 1 deg.
      for (double off : new double[]{0, -1.0, 1.0}) {
        SynKinectStudio.RigidTransform start = st.tracker.rotateAroundPivotY(gt, new PVector(0,0,0), 0);
        // rotate about true axis through true pivot (scene origin) in world coords
        double[] a0 = sToK(cam, 0,0,0), a1 = sToK(cam,0,1,0);
        PVector axis = new PVector((float)(a1[0]-a0[0]),(float)(a1[1]-a0[1]),(float)(a1[2]-a0[2]));
        st.tracker.turntableSupportAxis = axis; st.tracker.gravityReference = axis.copy();
        PVector pivot = new PVector((float)a0[0],(float)a0[1],(float)a0[2]);
        start = st.tracker.rotateAroundPivotY(gt, pivot, (float)off);
        SynKinectStudio.RigidTransform r6 = st.tracker.trackAgainstModel(cl, start, vol);
        float e6 = r6==null?Float.NaN:st.tracker.turntableDeltaDeg(gt, r6);
        float t6 = r6==null?Float.NaN:1000*(float)Math.sqrt(sq(r6.m[3]-gt.m[3])+sq(r6.m[7]-gt.m[7])+sq(r6.m[11]-gt.m[11]));
        SynKinectStudio.RigidTransform r1 = st.tracker.trackAgainstModel(cl, start, vol, pivot);
        float e1 = r1==null?Float.NaN:st.tracker.turntableDeltaDeg(gt, r1);
        System.out.printf(Locale.ROOT, "k=%d start=%+.1f  6dof yawErr=%+.3f deg transErr=%.2fmm rms=%.2fmm | 1dof yawErr=%+.3f deg%n", k, off, e6, t6, st.tracker.rms*1000, e1);
      }
    }
  }
  /** Distance from the estimated pivot to the true turntable axis (scene Y axis), in the first camera frame. */
  static double pivotErrMm(PVector p, Pose cam0){
    if(p==null||cam0==null)return Double.NaN; double[] a=sToK(cam0,0,0,0), b=sToK(cam0,0,1,0);
    double dx=b[0]-a[0],dy=b[1]-a[1],dz=b[2]-a[2],px=p.x-a[0],py=p.y-a[1],pz=p.z-a[2],t=px*dx+py*dy+pz*dz;
    return 1000*Math.sqrt(sq(px-t*dx)+sq(py-t*dy)+sq(pz-t*dz));
  }
  void cloudComposition(SynKinectStudio app, SynKinectStudio.ScannerModuleState st, SynKinectStudio.DepthFrame df, Pose cam){
    boolean box = st.boundingBox != null && st.boundingBox.locked;
    SynKinectStudio.PointCloud c = st.pointCloudBuilder.build(df, st.calibration, st.config.pointStep, box?Float.NaN:st.lockedObjectDepth, box?Float.POSITIVE_INFINITY:st.depthTarget.bandM, null, null);
    if (st.boundingBox != null) c = st.boundingBox.filter(c, false);
    int fig=0,disc=0,table=0,wall=0,other=0;
    for (PVector p : c.points) {
      double[] s = kToS(cam, p.x, p.y, p.z); double cc=Math.cos(-yaw), sn=Math.sin(-yaw), ox=cc*s[0]+sn*s[2], oz=-sn*s[0]+cc*s[2];
      double a=Math.abs(sdFigure(ox,s[1],oz)), b=Math.abs(sdDisc(ox,s[1],oz)), t=Math.abs(sdTable(s[0],s[1],s[2])), w=Math.abs(sdWall(s[0],s[1],s[2]));
      double m=Math.min(Math.min(a,b),Math.min(t,w)); if(m>0.01)other++; else if(m==a)fig++; else if(m==b)disc++; else if(m==t)table++; else wall++;
    }
    SynKinectStudio.SupportPlane sp = st.boundingBox.supportPlane;
    if (sp != null) { double[] a0 = kToS(cam,0,0,0); System.out.printf(Locale.ROOT, "  plane n=(%.3f,%.3f,%.3f) d=%.3f inliers=%d ratio=%.2f clearance=%.4f valid=%s target=%.3f%n", sp.nx, sp.ny, sp.nz, sp.d, sp.inliers, sp.inlierRatio, sp.clearance, sp.valid, st.lockedObjectDepth); }
    else System.out.println("  plane: none target=" + st.lockedObjectDepth);
    System.out.printf(Locale.ROOT, "  cloud: n=%d figure=%d disc=%d table=%d wall=%d other=%d boxLocked=%s box=[%.3f..%.3f, %.3f..%.3f, %.3f..%.3f]%n", c.size(), fig, disc, table, wall, other, box,
      st.boundingBox.minX, st.boundingBox.maxX, st.boundingBox.minY, st.boundingBox.maxY, st.boundingBox.minZ, st.boundingBox.maxZ);
  }
  /** Turntable: a scene point observed at yaw L corresponds to object-fixed scene point at yaw 0 rotated by (yaw0 - yawL). */
  static double yaw0Shift(double[] ps, double yawL, double yaw0){ return yaw0 - yawL; }
}
