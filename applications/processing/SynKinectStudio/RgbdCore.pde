// Shared RGB-D transport boundary for built-in and external Studio modules.
// A session owns its transport, calibration and registration state independently.

class RgbSnapshot {
  final int[] pixels;final int width,height;final long capturedMs,frameNumber,timestampUs;
  final PImage image;
  final float syncResidualMs,rawSkewMs,syncToleranceMs,frameQuality;
  RgbSnapshot(int[] pixels,int width,int height,PImage image,long frameNumber,long timestampUs,long capturedMs,float syncResidualMs,float rawSkewMs,float syncToleranceMs,
    float frameQuality){
    this.pixels=pixels;this.width=width;this.height=height;this.image=image;this.frameNumber=frameNumber;
    this.timestampUs=timestampUs;this.capturedMs=capturedMs;this.syncResidualMs=syncResidualMs;
    this.rawSkewMs=rawSkewMs;this.syncToleranceMs=syncToleranceMs;this.frameQuality=constrain(frameQuality,0.05f,1.0f);
    
  }
}

// Per-frame accelerometer/tilt sample. Identical on Linux and Windows: the
// camera service attaches its latest non-stale sample to every frame, so both
// flags are clear while no fresh status exists (for example during motor travel).
class MotionSample {
  final int FLAG_ACCEL_VALID = 1;
  final int FLAG_TILT_VALID = 2;
  final float COUNTS_PER_G = 819.0f;

  int flags = 0;
  int accelX = 0, accelY = 0, accelZ = 0;
  int tiltTenths = 0;
  long timestampMs = 0;

  boolean accelValid(){ return (flags & FLAG_ACCEL_VALID) != 0; }
  boolean tiltValid(){ return (flags & FLAG_TILT_VALID) != 0; }
  PVector gravityUnit(){
    if (!accelValid()) return null;
    PVector g = new PVector(accelX, accelY, accelZ);
    float m = g.mag();
    if (m < 1e-4f) return null;
    g.div(m);
    return g;
  }

  boolean gravityReliable(){
    if (!accelValid()) return false;
    float counts = sqrt((float)accelX * accelX + (float)accelY * accelY + (float)accelZ * accelZ);
    
    return counts > COUNTS_PER_G * 0.72f && counts < COUNTS_PER_G * 1.28f;
  }
}

class DepthFrame {
  int frameId, width, height, stride, pixelFormat;
  long frameNumber, timestampUs;
  short[] depth; // unsigned millimetres; 0 means invalid / missing packet data
  int validCount = 0;
  int plausibleCount = 0;
  boolean deviceCalibrated = false;
  boolean transportRecovered = false;
  MotionSample motion = new MotionSample();

}

class RawRgbFrame {
 final byte[] data;final int width,height,pixelFormat;final long frameNumber,timestampUs;
  final float quality;
 volatile byte[] nv12Cache=null;
 RawRgbFrame(byte[] data,int width,int height,int pixelFormat,long frameNumber,long timestampUs,float quality){this.data=data;
    this.width=width;this.height=height;this.pixelFormat=pixelFormat;this.frameNumber=frameNumber;
    this.timestampUs=timestampUs;this.quality=quality;}
 boolean highQuality(){return pixelFormat==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8&&width==studio.services.scannerProtocol.RGB_HQ_WIDTH&&height==studio.services.scannerProtocol.RGB_HQ_HEIGHT;
    }
}

class RgbdFramePair {
  final DepthFrame depth;final RawRgbFrame rgb;final RawRgbFrame hq;final long sequence,rawSkewUs,residualUs;
  final float syncQuality;
  RgbdFramePair(DepthFrame d,RawRgbFrame r,RawRgbFrame h,long seq,long raw,long residual,float q){depth=d;
    rgb=r;hq=h;sequence=seq;rawSkewUs=raw;residualUs=residual;syncQuality=q;}
}

class RgbdSession {
  final AppConfig config=new AppConfig();
  final Calibration calibration=new Calibration();
  final DepthCalibrationStore calibrationStore=new DepthCalibrationStore();
  final ModuleI18n i18n;
  final RgbDepthRegistration registration;
  final KinectSource source;

  RgbdSession(ModuleI18n i18n){
    this.i18n=i18n;
    config.load(studio.services.paths.resource("scanner","config.properties"));
    calibration.configure(config);
    registration=new RgbDepthRegistration(config,calibration);
    source=new KinectSource(config,calibration,i18n);
    source.setHqColorRequested(false);
  }
  void selectDevice(KinectDevice device){
    String id=device==null?"":device.id;
    if(Objects.equals(calibration.deviceId,id))return;
    DepthCorrectionProfile profile=id.length()==0?null:calibrationStore.load(id,studio.services.scannerProtocol.WIDTH,studio.services.scannerProtocol.HEIGHT);
    
    calibration.selectDevice(id,profile);
    registration.clearPreparedFrame();
  }
  void setHqColorRequested(boolean enabled){source.setHqColorRequested(enabled);}
  void start(){source.start();}
  void requestStop(){source.requestStop();}
  void requestStop(boolean clearPending){source.requestStop(clearPending);}
  void stop(boolean clearPending){source.stop(clearPending);}
  void clearConsumerPairs(){source.clearConsumerPairs();}
  boolean streamsLive(long staleMs){source.updateLiveness();long now=millis64();return source.running&&source.colorConnected&&source.depthConnected&&source.lastPairedArrivalMs>0&&now-source.lastPairedArrivalMs<=staleMs;
    }
  void updateLiveness(){source.updateLiveness();}
  void requestReconnect(String reason){source.requestReconnect(reason,false);}
  void requestReconnect(String reason,boolean force){source.requestReconnect(reason,force);
    }
  RgbdFramePair latestRgbdPairAfter(long sequence){return source.latestRgbdPairAfter(sequence);
    }
  float syncResidualMs(){return source.latestSyncResidualMs;}
  double syncOffsetMs(){return source.syncOffsetUs/1000.0;}
}
