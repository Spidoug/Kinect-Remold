// ===== SynKinect Studio / 3D Scanner / DepthDetection.pde =====
class DepthDiagnostics {
  int totalPixels = 0;
  int nonZeroPixels = 0;
  int plausiblePixels = 0;
  float plausibleRatio = 0;
  int minMm = 0, p05Mm = 0, medianMm = 0, p95Mm = 0, maxMm = 0;
  boolean recoveredTransport = false;
  boolean calibrated = false;

  boolean healthy(AppConfig cfg) {
    return calibrated && plausiblePixels >= cfg.depthMinValidPixels && plausibleRatio >= cfg.depthMinValidRatio;

  }

}

class DepthTargetEstimate {
  boolean valid = false;
  float depthM = Float.NaN;
  float confidence = 0;
  float spreadM = 0;
  int samples = 0;
}

class DepthAnalyzer {
  // Set by the Scanner in Turntable mode once the static support plane is known.
  volatile SupportPlane support=null;
  final Calibration calibration;DepthAnalyzer(Calibration calibration){this.calibration=calibration;
    }
  int metricMm(int index,int rawMm){return calibration!=null?calibration.correctedDepthMm(index,rawMm):rawMm;
    }
  DepthDiagnostics analyze(DepthFrame frame, AppConfig cfg) {
    DepthDiagnostics out = new DepthDiagnostics();
    if (frame == null || frame.depth == null || frame.depth.length == 0) return out;

    out.totalPixels = frame.depth.length;
    out.calibrated = frame.deviceCalibrated;
    out.recoveredTransport = frame.transportRecovered;

    int binMm = max(1, cfg.depthHistogramBinMm);
    int bins = max(1, ((cfg.depthPlausibleMaxMm - cfg.depthPlausibleMinMm) / binMm) + 1);

    int[] hist = new int[bins];
    int minSeen = Integer.MAX_VALUE, maxSeen = 0;

    for (int i = 0; i < frame.depth.length; i++) {
      int mm = frame.depth[i] & 0xFFFF;
      if (mm == 0) continue;mm=metricMm(i,mm);
      out.nonZeroPixels++;
      if (mm < cfg.depthPlausibleMinMm || mm > cfg.depthPlausibleMaxMm) continue;

      out.plausiblePixels++;
      minSeen = min(minSeen, mm);
      maxSeen = max(maxSeen, mm);
      int b = constrain((mm - cfg.depthPlausibleMinMm) / binMm, 0, bins - 1);
      hist[b]++;
    }

    out.plausibleRatio = out.totalPixels > 0 ? out.plausiblePixels / (float)out.totalPixels : 0;

    if (out.plausiblePixels > 0) {
      out.minMm = minSeen; out.maxMm = maxSeen;
      out.p05Mm = percentile(hist, out.plausiblePixels, 0.05f, cfg.depthPlausibleMinMm, binMm);

      out.medianMm = percentile(hist, out.plausiblePixels, 0.50f, cfg.depthPlausibleMinMm, binMm);

      out.p95Mm = percentile(hist, out.plausiblePixels, 0.95f, cfg.depthPlausibleMinMm, binMm);

    }
    return out;
  }

  int percentile(int[] hist, int total, float p, int baseMm, int binMm) {
    if (total <= 0) return 0;
    int target = max(1, ceil(total * p));
    int sum = 0;
    for (int i = 0; i < hist.length; i++) {
      sum += hist[i];
      if (sum >= target) return baseMm + i * binMm + binMm / 2;
    }
    return baseMm + (hist.length - 1) * binMm + binMm / 2;
  }

  DepthTargetEstimate estimateTarget(DepthFrame frame, AppConfig cfg, float preferredDepthM) {
    DepthTargetEstimate out = new DepthTargetEstimate();
    if (frame == null || frame.depth == null || frame.width <= 0 || frame.height <= 0) return out;


    int binMm = max(1, cfg.depthHistogramBinMm);
    int minMm = max(1, round(cfg.minDepthM * 1000.0f));
    int maxMm = max(minMm + binMm, round(cfg.maxDepthM * 1000.0f));
    int bins = max(1, ((maxMm - minMm) / binMm) + 1);
    int[] hist = new int[bins];

    int x0 = constrain(round(frame.width * cfg.depthRoiLeft), 0, frame.width - 1);

    int x1 = constrain(round(frame.width * cfg.depthRoiRight), x0 + 1, frame.width);

    int y0 = constrain(round(frame.height * cfg.depthRoiTop), 0, frame.height - 1);

    int y1 = constrain(round(frame.height * cfg.depthRoiBottom), y0 + 1, frame.height);

    int stride = max(1, cfg.depthRoiSampleStep);
    int samples = 0;

    for (int y = y0; y < y1; y += stride) {
      int row = y * frame.width;
      for (int x = x0; x < x1; x += stride) {
        int index=row+x,mm = frame.depth[index] & 0xFFFF;if(mm!=0)mm=metricMm(index,mm);

        if (mm < minMm || mm > maxMm) continue;
        if (support != null && calibration != null && calibration.valid) {
          // Turntable: the table/floor and anything under it can never be the target.
          float zm = mm * 0.001f;
          if (support.signedDistance((x - calibration.cx) * zm / calibration.fx, (y - calibration.cy) * zm / calibration.fy, zm) < support.clearance) continue;
        }
        hist[constrain((mm - minMm) / binMm, 0, bins - 1)]++;
        samples++;
      }
    }
    out.samples = samples;
    if (samples < cfg.depthTargetMinSamples) return out;

    int requiredMass = max(cfg.depthTargetMinSamples, ceil(samples * cfg.depthTargetMinConfidence));

    ArrayList<Integer> peaks = new ArrayList<Integer>();
    for (int b = 0; b < bins; b++) {
      int left = b > 0 ? hist[b - 1] : -1;
      int right = b + 1 < bins ? hist[b + 1] : -1;
      if (hist[b] < left || hist[b] < right) continue;
      int mass = clusterMass(hist, b, 2);
      if (mass >= requiredMass) peaks.add(b);
    }

    int peak = -1;
    if (!peaks.isEmpty()) {
      if (!Float.isNaN(preferredDepthM)) {
        float bestDistance = Float.MAX_VALUE;
        float windowMm = cfg.depthPreferredTargetWindowM * 1000.0f;
        for (int b : peaks) {
          float centerMm = minMm + b * binMm + binMm * 0.5f;
          float distance = abs(centerMm - preferredDepthM * 1000.0f);
          if (distance <= windowMm && distance < bestDistance) { bestDistance = distance; peak = b; }
        }
      }
      // Fresh acquisition must not snap to the first/nearest tiny foreground
      // island. Pick the strongest significant depth mode, with only a mild
      // near-depth preference as a tie breaker. This keeps hands, chair edges
      // and structured-light speckles from stealing the scan target.
      if (peak < 0 && (support != null || cfg.depthTargetPreferNearest)) {
        // With the support surface removed, the object standing on it is the
        // nearest significant depth mode; a flat background wall often forms the
        // single strongest histogram peak and must not win just by area.
        int strongest=0;for(int b:peaks)strongest=max(strongest,clusterMass(hist,b,2));
        for(int b:peaks){if(clusterMass(hist,b,2)>=strongest*cfg.depthTargetNearestModeFraction){peak=b;break;}}
      }
      if (peak < 0) {
        float bestScore=-Float.MAX_VALUE;
        for(int b:peaks){
          int modeMass=clusterMass(hist,b,2);
          float depthNorm=b/(float)max(1,bins-1);
          float score=modeMass*(1.08f-0.08f*depthNorm);
          if(score>bestScore){bestScore=score;peak=b;}
        }
      }
    } else {
      int bestMass = 0;
      for (int b = 0; b < bins; b++) {
        int mass = clusterMass(hist, b, 2);
        if (mass > bestMass) { bestMass = mass; peak = b; }
      }
    }
    if (peak < 0) return out;

    int lo = max(0, peak - 2), hi = min(bins - 1, peak + 2);
    long weighted = 0; int mass = 0;
    for (int b = lo; b <= hi; b++) {
      int count = hist[b];
      weighted += (long)(minMm + b * binMm + binMm / 2) * count;
      mass += count;
    }
    if (mass <= 0) return out;
    float centerMm = weighted / (float)mass;

    float variance = 0; int spreadMass = 0;
    for (int b = max(0, peak - 8); b <= min(bins - 1, peak + 8); b++) {
      int count = hist[b];
      if (count == 0) continue;
      float mm = minMm + b * binMm + binMm / 2.0f;
      float d = mm - centerMm;
      variance += d * d * count;
      spreadMass += count;
    }

    out.confidence = mass / (float)samples;
    out.depthM = centerMm * 0.001f;
    out.spreadM = spreadMass > 0 ? sqrt(variance / spreadMass) * 0.001f : 0;
    out.valid = out.confidence >= cfg.depthTargetMinConfidence && out.depthM >= cfg.minDepthM && out.depthM <= cfg.maxDepthM;

    return out;
  }

  int clusterMass(int[] hist, int center, int radius) {
    int mass = 0;
    for (int k = max(0, center - radius); k <= min(hist.length - 1, center + radius); k++) mass += hist[k];

    return mass;
  }
}

class DepthPreviewRenderer {
  PImage image;
  PImage render(DepthFrame frame, DepthDiagnostics d) {
    if (frame == null || frame.depth == null) return null;
    if(image==null||image.width!=frame.width||image.height!=frame.height)image=createImage(frame.width,frame.height,RGB);

    image.loadPixels();
    int nearMm = d != null && d.p05Mm > 0 ? d.p05Mm : 500;
    int farMm = d != null && d.p95Mm > nearMm ? d.p95Mm : nearMm + 1500;
    if (farMm - nearMm < 350) {
      int mid = d != null && d.medianMm > 0 ? d.medianMm : (nearMm + farMm) / 2;
      nearMm = max(200, mid - 250); farMm = mid + 250;
    }
    int n = min(image.pixels.length, frame.depth.length);
    float invRange=1.0f/max(1,farMm-nearMm);
    for (int i = 0; i < n; i++) {
      int mm = frame.depth[i] & 0xFFFF;
      if (mm == 0) { image.pixels[i] = 0xFF080B10; continue; }
      float t = constrain((mm - nearMm) * invRange, 0, 1);
      int gray = round(228 - 176 * t);
      image.pixels[i] = 0xFF000000|(gray<<16)|(gray<<8)|gray;
    }
    image.updatePixels();
    return image;
  }
}

class DepthTargetTracker {
  AppConfig cfg;
  DepthAnalyzer analyzer;
  float depthM = Float.NaN, bandM = 0, candidateM = Float.NaN;
  int stableFrames = 0, lostFrames = 0;
  boolean captureLocked=false;
  DepthTargetEstimate latest = new DepthTargetEstimate();

  DepthTargetTracker(AppConfig cfg, DepthAnalyzer analyzer) { this.cfg = cfg; this.analyzer = analyzer;
     bandM = cfg.objectDepthBandM; }

  void reset() { depthM = Float.NaN; bandM = cfg.objectDepthBandM; candidateM = Float.NaN;
     stableFrames = 0; lostFrames = 0; captureLocked=false; latest = new DepthTargetEstimate(); }

  // Once Scan starts, foreground selection becomes a tracking problem rather than
  // repeated scene search.  Keep the object that was already acquired by depth and
  // never jump to a distant wall just because that wall has more histogram mass.
  void lockForCapture(){captureLocked=!Float.isNaN(depthM);candidateM=depthM;stableFrames=cfg.depthTargetStableFrames;lostFrames=0;}
  void unlockCapture(){captureLocked=false;lostFrames=0;candidateM=depthM;}
  boolean locked(){return captureLocked&&!Float.isNaN(depthM);}

  boolean update(DepthFrame frame) {
    latest = analyzer.estimateTarget(frame, cfg, depthM);
    if (!latest.valid || Float.isNaN(latest.depthM)) {
      lostFrames++;
      if(!captureLocked&&lostFrames >= cfg.depthTargetLostFramesForReacquire) { depthM = Float.NaN;
         candidateM = Float.NaN; stableFrames = 0; bandM = cfg.objectDepthBandM; return false;
         }
      // During capture keep the last valid object depth. A temporary occlusion or
      // weak structured-light return must not trigger a new search of the wall.
      return !Float.isNaN(depthM)&&lostFrames<cfg.depthTargetCaptureLostFrames;
    }

    float suggestedBand = max(cfg.objectDepthBandM, latest.spreadM * cfg.depthBandSpreadMultiplier);
    bandM = constrain(lerp(bandM, suggestedBand, captureLocked?0.12f:0.25f), cfg.objectDepthBandM, cfg.maxObjectDepthBandM);

    if (Float.isNaN(depthM)) {
      if (Float.isNaN(candidateM) || abs(latest.depthM - candidateM) > cfg.depthTargetStableToleranceM) { candidateM = latest.depthM;
         stableFrames = 1; }
      else { candidateM = lerp(candidateM, latest.depthM, 0.35f); stableFrames++;
         }
      if (stableFrames >= cfg.depthTargetStableFrames) { depthM = candidateM; lostFrames = 0;
         return true; }
      return false;
    }

    float jump=abs(latest.depthM-depthM);
    float captureJump=max(cfg.depthTargetMaxJumpM,cfg.depthTargetCaptureMaxJumpM);
    if (jump <= (captureLocked?captureJump:cfg.depthTargetMaxJumpM)) {
      // Locked capture follows genuine camera/object distance changes slowly. This
      // is enough for Fusion motion while remaining far too conservative to hop
      // from a foreground object to a background wall.
      float alpha=captureLocked?min(cfg.depthTargetSmoothing,cfg.depthTargetCaptureSmoothing):cfg.depthTargetSmoothing;
      depthM = lerp(depthM, latest.depthM, alpha);
      candidateM = depthM; stableFrames = cfg.depthTargetStableFrames; lostFrames = 0;
       return true;
    }

    lostFrames++;
    if(captureLocked){
      // A stable but distant mode is almost always the background. Do not promote
      // it while Scan is active; reacquisition must occur close to the last object.
      candidateM=Float.NaN;stableFrames=0;
      return lostFrames<cfg.depthTargetCaptureLostFrames;
    }

    if (Float.isNaN(candidateM) || abs(latest.depthM - candidateM) > cfg.depthTargetStableToleranceM) { candidateM = latest.depthM;
       stableFrames = 1; }
    else { candidateM = lerp(candidateM, latest.depthM, 0.35f); stableFrames++; }
    if (stableFrames >= cfg.depthTargetLostFramesForReacquire) { depthM = candidateM;
       bandM = cfg.objectDepthBandM; stableFrames = cfg.depthTargetStableFrames; lostFrames = 0;
       return true; }
    return false;
  }

}

class PointCloudBuildStats {
  int sourcePixels = 0, nonZero = 0, inRange = 0, accepted = 0, rejectedRange = 0, rejectedBand = 0, rejectedSpatial = 0;

  void clear() { sourcePixels = nonZero = inRange = accepted = rejectedRange = rejectedBand = rejectedSpatial = 0;
     }
}
