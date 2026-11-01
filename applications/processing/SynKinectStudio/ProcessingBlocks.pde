// ===== SynKinect Studio / Reusable Processing Blocks =====
// Central construction boundary for heavy processing services used by built-in
// modules. Frontends request sessions/engines here instead of reconstructing
// algorithm pipelines themselves. OS-specific transport remains below RgbdSession
// and SpatialAudioSessionRegistry; processing stays platform-neutral.

class StudioProcessingBlocks {
  final SkeletonLibrary skeletons;
  final SpatialAudioSessionRegistry spatialAudioSessions;

  StudioProcessingBlocks(SkeletonLibrary skeletons,SpatialAudioSessionRegistry spatialAudioSessions){
    this.skeletons=skeletons;this.spatialAudioSessions=spatialAudioSessions;
  }

  RgbdSession openRgbd(ModuleI18n i18n,KinectDevice device){
    RgbdSession session=new RgbdSession(i18n);
    session.selectDevice(device);
    return session;
  }

  SkeletonProcessingSession openSkeleton(RgbdSession rgbd){
    if(rgbd==null)throw new IllegalArgumentException("rgbd");
    return skeletons.createSession(rgbd.calibration,rgbd.registration,rgbd.source);
  }

  // Configured RGB-D or depth-only ONNX tracking with a shared body-frame publisher.
  // The caller owns the returned session: activate() when its tab becomes active,
  // requestStop()/stop() when it leaves, close() on dispose.
  BodyTrackingSession openBodyTracking(ModuleI18n i18n,KinectDevice device,BodyTrackingOptions options){
    RgbdSession rgbd=openRgbd(i18n,device);
    return new BodyTrackingSession(options,rgbd,openSkeleton(rgbd),device==null?"":device.registryKey());
  }

  SpatialAudioConfig spatialAudioConfig(){return spatialAudioSessions.config();}
  SpatialAudioEngine newSpatialAudioEngine(SpatialAudioConfig cfg){
    return new SpatialAudioEngine(cfg==null?spatialAudioSessions.config():cfg);
  }
  SpatialAutoSteerer newSpatialAutoSteerer(SpatialAudioConfig cfg){
    return new SpatialAutoSteerer(cfg==null?spatialAudioSessions.config():cfg);
  }
  SpatialAudioDeviceSession attachSpatialAudio(String deviceId,SpatialAudioSessionListener listener){
    return spatialAudioSessions.attach(deviceId,listener);
  }
  ScannerProcessingSession openScanner(AppConfig cfg,Calibration calibration,RgbDepthRegistration registration){
    return new ScannerProcessingSession(cfg,calibration,registration);
  }
}

// Heavy Scanner processing is kept behind one instantiable block. ScannerUI owns
// presentation only; this block owns reconstruction primitives and can be reused
// by another built-in module without importing ScannerUI state.
class ScannerProcessingSession {
  final DepthAnalyzer depthAnalyzer;
  final DepthPreviewRenderer depthRenderer;
  final PointCloudBuilder pointCloudBuilder;
  final IcpTracker tracker;
  final BoundingBoxTracker boundingBox;
  final PointCloudAccumulator previewPointModel;
  final MeshEditor meshEditor;
  final ScanCoverageTracker scanCoverage;
  final DepthTargetTracker depthTarget;
  final HighQualityScanArchive hqArchive;
  final HighQualityReconstructor hqReconstructor;
  final PointCloudBuildStats cloudStats;

  ScannerProcessingSession(AppConfig cfg,Calibration calibration,RgbDepthRegistration registration){
    if(cfg==null||calibration==null||registration==null)throw new IllegalArgumentException("scanner processing dependencies");
    depthAnalyzer=new DepthAnalyzer(calibration);
    depthRenderer=new DepthPreviewRenderer();
    pointCloudBuilder=new PointCloudBuilder(cfg,registration);
    tracker=new IcpTracker(cfg);
    boundingBox=new BoundingBoxTracker(cfg);
    previewPointModel=new PointCloudAccumulator(cfg);
    meshEditor=new MeshEditor(cfg);
    scanCoverage=new ScanCoverageTracker(cfg);
    depthTarget=new DepthTargetTracker(cfg,depthAnalyzer);
    hqArchive=new HighQualityScanArchive(cfg);
    hqReconstructor=new HighQualityReconstructor(cfg,calibration,pointCloudBuilder,registration);
    cloudStats=new PointCloudBuildStats();
  }
}
