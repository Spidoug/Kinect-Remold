// Responsive geometry is supplied by StudioUiMetrics.

// ===== SynKinect Studio / 3D Scanner / Module.pde =====
ScannerModuleState scannerState(){return studio.state(ScannerModuleState.class);}


class ScannerModuleState {
  final ScannerTheme theme=new ScannerTheme();

  AppConfig config;
  ScannerI18n i18n;
  RgbdSession rgbd;
  ScannerProcessingSession processing;
  KinectSource source;
  Calibration calibration;
  DepthCalibrationStore calibrationStore;
  DepthAnalyzer depthAnalyzer;
  DepthPreviewRenderer depthRenderer;
  PointCloudBuilder pointCloudBuilder;
  RgbDepthRegistration rgbRegistration;
  IcpTracker tracker;
  BoundingBoxTracker boundingBox;
  SupportPlaneEstimator supportPlaneEstimator;
  volatile long lastSupportPlaneMs=0;
  volatile Mesh3D mesh,meshUndo,liveMesh;
  final ArrayDeque<Mesh3D> meshUndoStack=new ArrayDeque<Mesh3D>();
  static final int MESH_UNDO_LIMIT=8;
  ScannerUI ui;
  Scanner3DViewport viewport3D;
  STLExporter stlExporter;
  OBJExporter objExporter;
  PLYExporter plyExporter;
  MeshEditor meshEditor;
  ScanCoverageTracker scanCoverage;
  DepthTargetTracker depthTarget;
  HighQualityScanArchive hqArchive;
  HighQualityReconstructor hqReconstructor;
  PointCloudBuildStats cloudStats;
  DepthDiagnostics latestDepthDiagnostics;
  PImage depthPreview,colorPreview;
  DepthFrame latestDepth;
  volatile RgbdFramePair latestPair;
  volatile float latestRgbDepthSkewMs=Float.NaN;
  final Object reconstructionQueueLock=new Object();
  final Object reconstructionStateLock=new Object();
  volatile boolean reconstructionRun=false,reconstructionBusy=false;
  volatile boolean resetBusy=false;
  volatile long resetGeneration=0;
  Thread reconstructionThread=null;
  final ArrayDeque<ScanWorkItem> reconstructionQueue=new ArrayDeque<ScanWorkItem>();

  volatile long reconstructionQueueOverflows=0;
  volatile float captureWorkMsEma=0.0f,trackingMsEma=0.0f;
  volatile boolean meshBusy=false,exportBusy=false;
  volatile long meshGeneration=0;
  volatile boolean hqBusy=false;
  volatile float hqProgress=0;
  volatile String hqDiagnostic="";
  final HqProgressTracker hqTracker=new HqProgressTracker();
  volatile String meshOperation="";
  Thread meshThread=null,activeExportThread=null;
  volatile int deferredExportPrompt=0;
  static final int MODE_TURNTABLE=0,MODE_FUSION=1;
  volatile int scanMode=MODE_TURNTABLE;
  volatile boolean scanActive=false,scanPaused=false;
  final ArrayDeque<PVector> fusionTrajectory=new ArrayDeque<PVector>();
  static final int FUSION_TRAJECTORY_LIMIT=600;
  volatile boolean solidScanMode=false;
  volatile boolean rgbOverlayEnabled=true;
  volatile boolean rgbFinalized=false;
  volatile boolean meshViewActive=false;
  volatile float lockedObjectDepth=Float.NaN;
  volatile long rejectedTrackingFrames=0;
  // Capture and reconstruction are deliberately decoupled. Scan only records
  // calibrated RGB-D keyframes + lightweight tracking; dense integration happens
  // later, exclusively from Build Mesh / Refine HQ.
  volatile long captureRevision=0;
  volatile long meshSourceCaptureRevision=-1;
  volatile int capturedKeyframes=0;
  volatile PVector fusionCaptureTargetWorld=null;
  volatile float fusionCaptureTargetSideM=Float.NaN;
  static final int TRACK_WARMUP=0,TRACK_OK=1,TRACK_DEGRADED=2,TRACK_LOST=3;
  volatile int trackingState=TRACK_WARMUP,trackingGoodStreak=0,trackingBadStreak=0;
  volatile long trackingLossEvents=0,lastSessionCheckpointFrame=0;
  volatile float uiProgress=0.0f,uiTargetDepthM=Float.NaN,uiIcpRmsMm=Float.NaN,uiScanQuality=0.0f;
  volatile boolean uiScanComplete=false,uiTrackingGood=false;
  volatile PointCloud uiPreviewCloud=null;
  // A short rolling preview retains surfaces lost by a single noisy depth frame.
  final ArrayDeque<PointCloud> idlePreviewFrames=new ArrayDeque<PointCloud>();
  float idlePreviewDepth=Float.NaN;
  static final int IDLE_PREVIEW_HISTORY=4;

  PointCloudAccumulator previewPointModel=null;
  // Live depth-detection preview shown when the Scanner module opens. Scan keeps
  // this foreground-first model and adds only lightweight tracking/keyframes.
  volatile boolean showLiveDetectionCloud=true;
  volatile long lastPreviewRenderMs=0,lastScanQueueMs=0,lastPreviewCloudPublishMs=0;
  final int EXPORT_NONE=0,EXPORT_STL=1,EXPORT_OBJ=2,EXPORT_PLY=3;
  volatile int pendingExport=EXPORT_NONE;
  volatile String status="";
  float previewYaw=-0.42f,previewPitch=0.22f,previewZoom=1.0f;
  float previewPanX=0,previewPanY=0;
  // View state is independent from reconstruction state. autoFitRevision lets a
  // newly-created/replaced surface be framed once without fighting manual orbit.
  long previewAutoFitRevision=0; boolean previewUserAdjusted=false;
}




void ensureRgbdCore(){
  ScannerModuleState state=scannerState();
  if(state.i18n==null)state.i18n=new ScannerI18n(studio.currentLanguage());
  if(state.rgbd==null)state.rgbd=studio.services.processingBlocks.openRgbd(state.i18n,studio.selectedKinect());
  state.config=state.rgbd.config;state.calibration=state.rgbd.calibration;state.calibrationStore=state.rgbd.calibrationStore;
  state.rgbRegistration=state.rgbd.registration;state.source=state.rgbd.source;
  refreshScannerCalibrationForSelectedDevice(false);
}
void ensureScannerSource(){ensureRgbdCore();}


void refreshScannerCalibrationForSelectedDevice(boolean announce){
  if(scannerState().calibration==null||scannerState().calibrationStore==null)return;

  KinectDevice device=studio.selectedKinect();String id=device==null?"":device.id;

  boolean changed=!Objects.equals(scannerState().calibration.deviceId,id);
  if(!changed&&!announce)return;
  int dw=device!=null&&device.depthWidth>0?device.depthWidth:studio.services.scannerProtocol.WIDTH,dh=device!=null&&device.depthHeight>0?device.depthHeight:studio.services.scannerProtocol.HEIGHT;
  DepthCorrectionProfile profile=id.length()==0?null:scannerState().calibrationStore.load(id,dw,dh);

  scannerState().calibration.selectDevice(id,profile);
  if(scannerState().rgbRegistration!=null)scannerState().rgbRegistration.clearPreparedFrame();

  if(announce&&scannerState().i18n!=null){
    if(profile!=null&&profile.calibrated)scannerState().status=scannerState().i18n.format("status.calibration_loaded",profile.coverage*100.0f,(Float.isFinite(profile.validationRmsBeforeMm)?profile.validationRmsBeforeMm:profile.trainingRmsBeforeMm),
      (Float.isFinite(profile.validationRmsAfterMm)?profile.validationRmsAfterMm:profile.trainingRmsAfterMm));
    else scannerState().status=scannerState().i18n.tr("status.calibration_not_found");

  }
}

String depthCalibrationQuality(DepthCorrectionProfile p){
  if(p==null||!p.calibrated)return "missing";
  float after=Float.isFinite(p.validationRmsAfterMm)?p.validationRmsAfterMm:p.trainingRmsAfterMm;
  float before=Float.isFinite(p.validationRmsBeforeMm)?p.validationRmsBeforeMm:p.trainingRmsBeforeMm;
  if(!Float.isFinite(after)||!Float.isFinite(p.coverage))return "poor";float improvement=Float.isFinite(before)?before-after:0;
  if(p.coverage>=0.70f&&after<=8.0f&&improvement>=0)return "good";
  if(p.coverage>=0.50f&&after<=16.0f)return "fair";
  return "poor";
}

String depthCalibrationSummary(){
  DepthCorrectionProfile p=scannerState().calibration==null?null:scannerState().calibration.depthCorrection;
  String q=depthCalibrationQuality(p);
  if(p==null||!p.calibrated)return scannerState().i18n.tr("calibration.quality.missing");
  float before=Float.isFinite(p.validationRmsBeforeMm)?p.validationRmsBeforeMm:p.trainingRmsBeforeMm,after=Float.isFinite(p.validationRmsAfterMm)?p.validationRmsAfterMm:p.trainingRmsAfterMm;
  return scannerState().i18n.format("calibration.quality."+q,p.coverage*100.0f,before,after);
}

void setupScannerModule() {
  ensureScannerSource();
  initializeScannerTypography();
  scannerState().status = scannerState().i18n.tr("status.connecting");

  scannerState().processing = studio.services.processingBlocks.openScanner(scannerState().config,scannerState().calibration,scannerState().rgbRegistration);
  scannerState().depthAnalyzer=scannerState().processing.depthAnalyzer;scannerState().depthRenderer=scannerState().processing.depthRenderer;
  scannerState().pointCloudBuilder=scannerState().processing.pointCloudBuilder;scannerState().tracker=scannerState().processing.tracker;
  scannerState().boundingBox=scannerState().processing.boundingBox;scannerState().previewPointModel=scannerState().processing.previewPointModel;
  scannerState().meshEditor=scannerState().processing.meshEditor;
  scannerState().scanCoverage=scannerState().processing.scanCoverage;scannerState().depthTarget=scannerState().processing.depthTarget;
  scannerState().hqArchive=scannerState().processing.hqArchive;scannerState().hqReconstructor=scannerState().processing.hqReconstructor;
  scannerState().cloudStats=scannerState().processing.cloudStats;

  scannerState().mesh = new Mesh3D();
  scannerState().stlExporter = new STLExporter(scannerState().config); scannerState().objExporter = new OBJExporter(scannerState().config);
   scannerState().plyExporter = new PLYExporter(scannerState().config);
  scannerState().ui = new ScannerUI();
  scannerState().viewport3D = new Scanner3DViewport();

  try {
    ensureScannerSource();
    scannerState().status = scannerState().i18n.tr("status.worker_started");
  } catch (Exception e) {
    scannerState().status = scannerState().i18n.format("status.init_failed", safeExceptionMessage(e));

    println(scannerState().status); e.printStackTrace();
  }
  startReconstructionWorker();
}

void drawScannerModule() {
  background(scannerState().theme.BG);
  consumeKinectFrames();
  serviceDeferredUiActions();
  scannerState().ui.draw();
}

void serviceDeferredUiActions(){
  ScannerModuleState state=scannerState();
  int type=state.deferredExportPrompt;if(type==state.EXPORT_NONE)return;
  if(scannerExclusiveBusy())return;
  state.deferredExportPrompt=state.EXPORT_NONE;
  showScannerExportDialog(type);
}

boolean scannerExclusiveBusy(){
  ScannerModuleState state=scannerState();
  return state.resetBusy||state.meshBusy||state.exportBusy||state.hqBusy;
}

void consumeKinectFrames() {
  if(scannerState().source==null)return;
  scannerState().source.updateLiveness();
  int drained=0;
  RgbdFramePair lastPair=null;
  while(drained<scannerState().config.captureDrainFramesPerDraw){
    RgbdFramePair pair=scannerState().source.pollRgbdPair();
    if(pair==null)break;
    drained++;
    lastPair=pair;
    scannerState().latestDepth=pair.depth;
    scannerState().latestPair=pair;
    scannerState().latestRgbDepthSkewMs=pair.residualUs/1000.0f;

    if(scannerState().scanActive&&!scannerState().scanPaused&&scannerState().calibration.valid){
      if(!pair.depth.deviceCalibrated)scannerState().status=scannerState().i18n.tr("status.depth_uncalibrated_frame");

      else if(!depthFrameHealthy(pair.depth))scannerState().status=scannerState().i18n.tr("status.depth_sparse");

      else {
        long nowMs=System.currentTimeMillis();
        long minInterval=Math.max(1L,1000L/Math.max(1,scannerState().config.reconstructionMaxFps));
        if(scannerState().config.reconstructionAdaptiveCadence&&scannerState().captureWorkMsEma>0){
          long adaptive=(long)Math.ceil(scannerState().captureWorkMsEma/Math.max(0.10f,scannerState().config.reconstructionTargetUtilization));
          minInterval=Math.max(minInterval,Math.min((long)scannerState().config.reconstructionMaxIntervalMs,adaptive));
        }

        if(scannerState().lastScanQueueMs==0||nowMs-scannerState().lastScanQueueMs>=minInterval){
          scannerState().lastScanQueueMs=nowMs;queueScanFrame(pair);
        }
      }
    }
  }

  // Preview work is intentionally performed once for the newest drained pair,
  // never once per queued capture/tracking frame. This keeps the Processing
  // render thread responsive even when capture temporarily arrives in bursts.
  long previewNow=System.currentTimeMillis();
  if(lastPair!=null&&previewNow-scannerState().lastPreviewRenderMs>=66){
    scannerState().lastPreviewRenderMs=previewNow;
    scannerState().latestDepthDiagnostics=scannerState().depthAnalyzer.analyze(lastPair.depth,scannerState().config);

    scannerState().depthPreview=scannerState().depthRenderer.render(lastPair.depth,scannerState().latestDepthDiagnostics);

    RgbSnapshot preview=scannerState().source.rgbPreviewSnapshot(lastPair);
    if(preview!=null&&preview.image!=null)scannerState().colorPreview=preview.image;

    if(scannerState().scanActive&&!scannerState().scanPaused&&!scannerState().latestDepthDiagnostics.healthy(scannerState().config))
      scannerState().status=scannerState().i18n.format("status.depth_unhealthy",scannerState().i18n.format("depth.summary",scannerState().latestDepthDiagnostics.plausiblePixels,
      scannerState().latestDepthDiagnostics.totalPixels,scannerState().latestDepthDiagnostics.plausibleRatio*100.0f,scannerState().latestDepthDiagnostics.p05Mm,
      scannerState().latestDepthDiagnostics.medianMm,scannerState().latestDepthDiagnostics.p95Mm));

    // Before Scan is pressed, expose the newest calibrated depth frame as a
    // live 3D detection cloud. The preview never enters ICP/TSDF.
    updateLiveDetectionPreview(lastPair,preview);

  }
}


// Idle (pre-Scan) detection preview: support plane, subject depth band and the
// locked detection volume that Scan will reuse.
void updateLiveDetectionPreview(RgbdFramePair lastPair,RgbSnapshot preview){
    if(lastPair==null)return;
    if(scannerState().showLiveDetectionCloud&&!scannerState().scanActive&&
       scannerState().calibration.valid&&lastPair.depth!=null&&lastPair.depth.deviceCalibrated&&
       scannerState().latestDepthDiagnostics.healthy(scannerState().config)){
      serviceTurntableSupportPlane(lastPair.depth,false);

      // Idle preview and Scan share ONE temporal target tracker.  The old preview
      // estimated a fresh histogram peak with preferredDepth=NaN on every frame;
      // a hand, chair edge or background mode could therefore steal focus and make
      // the ROI visibly hunt before Scan was even pressed.  DepthTargetTracker adds
      // stable acquisition, jump rejection, smoothing and deliberate re-acquisition.
      boolean targetReady=scannerState().depthTarget.update(lastPair.depth);
      float liveZ=!Float.isNaN(scannerState().depthTarget.depthM)
        ?scannerState().depthTarget.depthM
        :scannerState().depthTarget.candidateM;
      float liveBand=Float.isNaN(liveZ)?Float.POSITIVE_INFINITY:scannerState().depthTarget.bandM;
      scannerState().lockedObjectDepth=targetReady?scannerState().depthTarget.depthM:Float.NaN;
      scannerState().uiTargetDepthM=liveZ;

      PointCloud liveCloud=scannerState().pointCloudBuilder.build(
        lastPair.depth,scannerState().calibration,scannerState().config.pointStep,
        liveZ,liveBand,null,preview);

      // The detection cube is allowed to lock/adapt only after the temporal target
      // itself is stable.  If a target is genuinely lost long enough to reacquire,
      // discard the stale camera-space cube so the next stable target can own it.
      if(scannerState().boundingBox!=null){
        if(targetReady){
          // Once the idle target/cube is stably defined, keep it visually fixed.
          // The operator should not see the preview recenter itself forever while
          // the same object is standing still inside the metric cube.
          if(scannerState().boundingBox.locked)liveCloud=scannerState().boundingBox.filter(liveCloud,false);
          else liveCloud=scannerState().boundingBox.filter(liveCloud,true);
        }else{
          if(Float.isNaN(scannerState().depthTarget.depthM)&&scannerState().boundingBox.locked&&!scannerState().boundingBox.worldLocked)
            scannerState().boundingBox.reset();
          liveCloud=scannerState().boundingBox.removeSupport(liveCloud);
        }
      }
      ScannerModuleState idle=scannerState();
      if(Float.isFinite(liveZ)&&Float.isFinite(idle.idlePreviewDepth)&&
         abs(liveZ-idle.idlePreviewDepth)>max(0.12f,idle.config.objectDepthBandM))
        idle.idlePreviewFrames.clear();
      idle.idlePreviewDepth=liveZ;
      idle.idlePreviewFrames.addLast(liveCloud==null?new PointCloud():liveCloud);
      while(idle.idlePreviewFrames.size()>ScannerModuleState.IDLE_PREVIEW_HISTORY)
        idle.idlePreviewFrames.removeFirst();
      idle.uiPreviewCloud=stableIdlePreview(idle);

    }
}


// Idle visualization only: a rolling voxel average suppresses holes from
// transient depth loss without altering the clouds used for Scan, ICP or TSDF.
PointCloud stableIdlePreview(ScannerModuleState state){
  if(state.idlePreviewFrames.isEmpty())return new PointCloud();
  int budget=max(1,state.config.previewPointDisplayMaxPoints);
  float voxel=max(0.004f,state.config.previewPointVoxelM);
  HashMap<VertexKey,PreviewPointVoxel> accumulated=new HashMap<VertexKey,PreviewPointVoxel>();
  for(PointCloud frame:state.idlePreviewFrames){
    if(frame==null)continue;
    int step=max(1,(frame.size()+budget-1)/budget);
    for(int i=0;i<frame.size();i+=step){
      PVector point=frame.points.get(i);
      if(point==null)continue;
      VertexKey key=new VertexKey(point.x,point.y,point.z,voxel);
      PreviewPointVoxel value=accumulated.get(key);
      if(value!=null)value.add(point,frame.colorAt(i),frame.confidenceAt(i));
      else if(accumulated.size()<budget)accumulated.put(key,new PreviewPointVoxel(point,frame.colorAt(i),frame.confidenceAt(i)));
    }
  }
  PointCloud result=new PointCloud(accumulated.size()+1);
  for(PreviewPointVoxel value:accumulated.values())result.add(value.p.copy(),value.color,value.confidence);
  return result;
}

boolean depthFrameHealthy(DepthFrame frame){
  if(frame==null||frame.depth==null||!frame.deviceCalibrated)return false;
  int total=frame.depth.length;
  return total>0&&frame.plausibleCount>=scannerState().config.depthMinValidPixels&&frame.plausibleCount/(float)total>=scannerState().config.depthMinValidRatio;

}

// Keep the support plane (table/floor) current while the Kinect is idle, so the
// subject is detected and framed without it. Turntable freezes it for the whole
// capture (static sensor). Kinect Fusion only uses it for framing before Scan:
// once the sensor moves, a camera-space plane no longer means anything.
void serviceTurntableSupportPlane(DepthFrame frame,boolean force){
  ScannerModuleState s=scannerState();
  if(frame==null||s.config==null||!s.config.supportPlaneEnabled||s.boundingBox==null)return;
  if(s.boundingBox.worldLocked)return;
  if(scannerFusionMode()&&s.scanActive)return;
  if(s.supportPlaneEstimator==null)s.supportPlaneEstimator=new SupportPlaneEstimator(s.config);
  long now=System.currentTimeMillis();
  if(!force&&s.boundingBox.supportPlane!=null&&now-s.lastSupportPlaneMs<s.config.supportPlaneRefreshMs)return;
  if(force&&s.boundingBox.supportPlane!=null)return;
  // Once the foreground ROI is acquired, do not let routine support-plane
  // re-estimates discard it. Explicit Reset or a newly selected sensor may
  // reacquire the plane; depth changes alone must not restart preview selection.
  if(!force&&s.boundingBox.locked)return;
  s.lastSupportPlaneMs=now;
  SupportPlane plane=s.supportPlaneEstimator.estimate(frame,s.calibration,s.rgbRegistration,frame.motion);
  if(plane!=null){s.boundingBox.setSupportPlane(plane);if(s.depthAnalyzer!=null)s.depthAnalyzer.support=plane;}
}

void startScan() {
  if(scannerState().meshBusy){scannerState().status=scannerState().i18n.tr("status.mesh_busy");
    return;}
  if(scannerState().resetBusy)return;
  if (scannerState().source == null || scannerState().latestDepth == null || scannerState().latestPair == null) { scannerState().status = scannerState().i18n.tr("status.no_depth");
     return; }
  if (!scannerState().latestDepth.deviceCalibrated) { scannerState().status = scannerState().i18n.tr("status.no_metric");
     return; }
  if (scannerState().latestDepthDiagnostics == null || !scannerState().latestDepthDiagnostics.healthy(scannerState().config)) { scannerState().status = scannerState().i18n.tr("status.depth_sparse");
     return; }
  // Scan begins only after the depth foreground target is already stable. This
  // avoids switching from the visible object to a larger background wall at the
  // exact moment the operator presses Scan.
  boolean foregroundReady=scannerState().depthTarget!=null&&scannerState().depthTarget.update(scannerState().latestDepth);
  if(!foregroundReady||Float.isNaN(scannerState().depthTarget.depthM)){
    scannerState().status=scannerState().i18n.tr("status.target_acquiring");return;
  }
  scannerState().lockedObjectDepth=scannerState().depthTarget.depthM;
  scannerState().uiTargetDepthM=scannerState().lockedObjectDepth;
  // Scan owns acquisition from this point forward; the live detection cloud
  // becomes the lightweight tracked/keyframe point-cloud view.
  scannerState().showLiveDetectionCloud=false;
  scannerState().meshViewActive=false;
  // Reset/first-frame queueing must never block Processing's UI thread.
  // A generation-owned worker performs the session transition.
  requestScannerReconstructionReset(true);
}

boolean scannerFusionMode(){return scannerState().scanMode==ScannerModuleState.MODE_FUSION;}
String scannerModeKey(){return scannerFusionMode()?"mode.fusion":"mode.turntable";}
void toggleScannerMode(){
  ScannerModuleState state=scannerState();
  if(state.scanActive||state.resetBusy||state.meshBusy||state.exportBusy||state.hqBusy)return;
  state.scanMode=scannerFusionMode()?ScannerModuleState.MODE_TURNTABLE:ScannerModuleState.MODE_FUSION;
  // A target/ROI acquired for one motion model must never leak into the other.
  // Keep the measured support plane (same physical Kinect), but reacquire subject
  // depth and detection volume with the newly selected scan mode.
  if(state.depthTarget!=null)state.depthTarget.reset();
  if(state.boundingBox!=null)state.boundingBox.reset();
  state.lockedObjectDepth=Float.NaN;state.uiTargetDepthM=Float.NaN;
  if(state.depthAnalyzer!=null)state.depthAnalyzer.support=state.boundingBox!=null?state.boundingBox.supportPlane:null;
  state.status=state.i18n.format("status.mode_changed",state.i18n.tr(scannerModeKey()));
  state.showLiveDetectionCloud=true;state.uiScanComplete=false;state.uiProgress=0;state.fusionTrajectory.clear();
  state.idlePreviewFrames.clear();state.idlePreviewDepth=Float.NaN;
}
void toggleScanControl() {
  ScannerModuleState state=scannerState();
  if(!state.scanActive){startScan();return;}
  state.scanPaused=!state.scanPaused;
  if(state.scanPaused)clearPendingScanWork();
  else {state.lastScanQueueMs=0;state.meshViewActive=false;}
  state.status=state.i18n.tr(state.scanPaused?"status.scan_paused":"status.scan_resumed");
}

void resetScan() {
  if(scannerState().meshBusy||scannerState().hqBusy)cancelScannerMeshTask();
  if(scannerState().resetBusy)return;
  scannerState().idlePreviewFrames.clear();scannerState().idlePreviewDepth=Float.NaN;
  // Reset means "back to ready-to-scan": discard reconstruction and restore
  // the live depth point cloud instead of leaving the 3D viewport empty.
  scannerState().showLiveDetectionCloud=true;
  scannerState().meshViewActive=false;
  requestScannerReconstructionReset(false);
}

void cancelScannerMeshTask(){
  ScannerModuleState state=scannerState();
  state.meshGeneration++;
  Thread worker=state.meshThread;if(worker!=null)worker.interrupt();
  state.meshThread=null;state.meshBusy=false;state.hqBusy=false;state.hqProgress=0;state.meshOperation="";
  state.hqTracker.end(state.hqTracker.token);
}
boolean scannerHqRunning(){ScannerModuleState s=scannerState();return s.meshBusy&&"refine-hq".equals(s.meshOperation);}
boolean scannerBuildRunning(){ScannerModuleState s=scannerState();return s.meshBusy&&"build".equals(s.meshOperation);}
boolean scannerOfflineReconstructionRunning(){ScannerModuleState s=scannerState();return s.meshBusy&&s.hqTracker.active();}
// Non-destructive cancel from the button that started the work: the scan and
// the previous mesh stay untouched (Reset remains the destructive command).
void cancelScannerMeshTaskFromButton(){
  ScannerModuleState s=scannerState();boolean hq=scannerHqRunning();
  cancelScannerMeshTask();
  s.status=s.i18n.tr(hq?"status.hq_cancelled":"status.mesh_cancelled");
}

void requestScannerReconstructionReset(final boolean startAfterReset){
  ScannerModuleState s=scannerState();
  s.scanActive=false;s.scanPaused=false;clearPendingScanWork();
  s.resetBusy=true;final long generation=++s.resetGeneration;
  if(!startAfterReset)s.status=s.i18n.tr("status.scan_reset");
  studio.services.workers.startLowPriority("Scanner-Reconstruction-Reset",new Runnable(){public void run(){
    try{
      resetReconstructionState(startAfterReset);
      if(generation!=scannerState().resetGeneration)return;
      if(startAfterReset){
        if(!studio.isStateActive(scannerState())||!studio.isStateReady(scannerState())||scannerState().source==null)return;
        RgbdFramePair seed=scannerState().latestPair;
        scannerState().scanActive=true;scannerState().scanPaused=false;scannerState().lastScanQueueMs=0;
        if(seed!=null)queueScanFrame(seed);
        scannerState().status=scannerState().i18n.tr("status.scan_started");
      }
    }catch(Exception e){
      if(generation==scannerState().resetGeneration){scannerState().scanActive=false;scannerState().status=safeExceptionMessage(e);}
    }finally{
      if(generation==scannerState().resetGeneration)scannerState().resetBusy=false;
    }
  }});
}

void cancelScannerReconstructionReset(){
  ++scannerState().resetGeneration;scannerState().resetBusy=false;
}

void resetReconstructionState(boolean preserveDetectionVolume) {
  synchronized (scannerState().reconstructionStateLock) {
    scannerState().rejectedTrackingFrames = 0; scannerState().trackingState=ScannerModuleState.TRACK_WARMUP; scannerState().trackingGoodStreak=0; scannerState().trackingBadStreak=0; scannerState().trackingLossEvents=0; scannerState().lastSessionCheckpointFrame=0;
    scannerState().captureRevision=0;scannerState().meshSourceCaptureRevision=-1;scannerState().capturedKeyframes=0;scannerState().fusionCaptureTargetWorld=null;scannerState().fusionCaptureTargetSideM=Float.NaN;
    // Starting Scan preserves the temporally-stable target the operator just saw
    // in the idle point cloud. A destructive Reset still starts acquisition fresh.
    if(preserveDetectionVolume){
      scannerState().lockedObjectDepth=scannerState().depthTarget.depthM;
      scannerState().depthTarget.lockForCapture();
    }else{
      scannerState().lockedObjectDepth=Float.NaN;
      scannerState().depthTarget.reset();
    }
    scannerState().cloudStats.clear(); scannerState().tracker.reset();
     if(scannerState().boundingBox!=null){
       if(preserveDetectionVolume&&scannerState().boundingBox.locked)scannerState().boundingBox.resetWorldLock();
       else scannerState().boundingBox.reset();
     }
     if(preserveDetectionVolume&&!scannerFusionMode()&&scannerState().boundingBox!=null&&scannerState().boundingBox.locked){
       PVector pivotSeed=scannerState().boundingBox.displayCenter(),axisSeed=null;
       if(scannerState().boundingBox.supportPlane!=null&&scannerState().boundingBox.supportPlane.valid)
         axisSeed=new PVector(scannerState().boundingBox.supportPlane.nx,scannerState().boundingBox.supportPlane.ny,scannerState().boundingBox.supportPlane.nz);
       scannerState().tracker.seedTurntablePivot(pivotSeed,axisSeed);
     }
     if(scannerState().previewPointModel!=null)scannerState().previewPointModel.reset();
    if(scannerState().hqArchive!=null)scannerState().hqArchive.clear(); scannerState().hqProgress=0;

    scannerState().latestRgbDepthSkewMs=Float.NaN; scannerState().rgbFinalized=false; scannerState().meshViewActive=false;
    scannerState().mesh = new Mesh3D(); scannerState().meshUndo = null; scannerState().meshUndoStack.clear(); scannerState().liveMesh = new Mesh3D(); scannerState().scanCoverage.reset();
    // Reconstruction reset never owns the viewport camera. The user's orbit,
    // pan and zoom survive Reset/Scan; middle-click remains the explicit view reset.

    scannerState().uiProgress=0.0f; scannerState().fusionTrajectory.clear(); scannerState().uiTargetDepthM=preserveDetectionVolume?scannerState().lockedObjectDepth:Float.NaN; scannerState().uiIcpRmsMm=Float.NaN; scannerState().uiScanQuality=0.0f;
    scannerState().hqDiagnostic="";

    scannerState().uiScanComplete=false; scannerState().uiTrackingGood=false; scannerState().uiPreviewCloud=null;
    scannerState().idlePreviewFrames.clear();scannerState().idlePreviewDepth=Float.NaN;
    scannerState().pendingExport=scannerState().EXPORT_NONE;scannerState().deferredExportPrompt=scannerState().EXPORT_NONE;
    scannerState().lastPreviewCloudPublishMs=0;
    scannerState().captureWorkMsEma=0;scannerState().trackingMsEma=0;

  }
}

void buildMesh(){
  ScannerModuleState state=scannerState();
  if(state.hqArchive==null||state.config==null||state.hqArchive.size()<state.config.hqMinimumKeyframes){
    int have=state.hqArchive==null?0:state.hqArchive.size();
    state.status=state.i18n.format("status.hq_need_keyframes",have,state.config==null?0:state.config.hqMinimumKeyframes);return;
  }
  if(scannerExclusiveBusy()){state.status=state.i18n.tr(state.exportBusy?"status.export_busy":"status.mesh_busy");return;}
  // Mesh is the first heavy stage. Acquisition is frozen, but the captured RGB-D
  // archive remains intact so the operator can resume Scan afterwards if desired.
  if(state.scanActive&&!state.scanPaused){state.scanPaused=true;clearPendingScanWork();}
  state.status=state.i18n.tr("status.mesh_processing");
  startMeshTask("build",null,false);
}

void refineScannerHighQuality(){
  ScannerModuleState state=scannerState();
  if(state.hqArchive==null||state.config==null||state.hqArchive.size()<state.config.hqMinimumKeyframes){
    int have=state.hqArchive==null?0:state.hqArchive.size();
    state.status=state.i18n.format("status.hq_need_keyframes",have,state.config==null?0:state.config.hqMinimumKeyframes);return;
  }
  if(scannerExclusiveBusy()){state.status=state.i18n.tr(state.exportBusy?"status.export_busy":"status.mesh_busy");return;}
  if(state.scanActive&&!state.scanPaused){state.scanPaused=true;clearPendingScanWork();}
  // Refine HQ always goes back to the original keyframes. It is not a second
  // smoothing pass over an already-decimated mesh: it reruns the FULL QUALITY
  // registration/pose-graph/deformation/Surface-SDF engine from source data.
  startMeshTask("refine-hq",state.mesh,false);
}

Mesh3D reconstructScannerArchive(boolean highQuality){
  ScannerModuleState state=scannerState();boolean oldConsensus=state.config.hqTurntableConsensus;
  state.config.hqTurntableConsensus=oldConsensus&&!scannerFusionMode();
  try{return state.hqReconstructor.reconstruct(state.hqArchive.snapshot(),highQuality);}
  finally{state.config.hqTurntableConsensus=oldConsensus;}
}

void startMeshTask(final String operation, final Mesh3D source){startMeshTask(operation,source,false);}
void startMeshTask(final String operation, final Mesh3D source, final boolean resumeCapture){
  ScannerModuleState state=scannerState();
  if(state.meshBusy)return;
  state.meshBusy=true;state.meshOperation=operation;state.status=state.i18n.tr("status.mesh_processing");
  final long generation=++state.meshGeneration;

  state.meshThread=studio.services.workers.startLowPriority("Scanner-Mesh",new Runnable(){public void run(){
    try{
      // Barrier: let any already-running fusion frame leave the state section.
      synchronized(scannerState().reconstructionStateLock){}
      if(Thread.currentThread().isInterrupted()||generation!=scannerState().meshGeneration)return;
      Mesh3D result;
      if("build".equals(operation)){
        // Balanced offline mesh: global recovery and fusion happen only now, never
        // while Scan is running. This keeps acquisition responsive and deterministic.
        result=reconstructScannerArchive(false);
        if(Thread.currentThread().isInterrupted()||generation!=scannerState().meshGeneration)return;
        if(result==null||result.triangleCount()==0)throw new IllegalStateException("Mesh generation produced no surface");
        if(scannerState().solidScanMode)result=scannerState().meshEditor.solidifyOpenSurface(result);
      }else if("refine-hq".equals(operation)){
        // Maximum-quality rebuild from the retained raw RGB-D keyframes. The FULL
        // QUALITY engine performs organized ICP, global pose optimization,
        // deformation graph, Surface-SDF and its own detail-preserving polish.
        result=reconstructScannerArchive(true);
        if(Thread.currentThread().isInterrupted()||generation!=scannerState().meshGeneration)return;
        if(result==null||result.triangleCount()==0)throw new IllegalStateException("HQ reconstruction produced no surface");
        if(scannerState().solidScanMode)result=scannerState().meshEditor.solidifyOpenSurface(result);
      }else if("clean".equals(operation)||"smooth".equals(operation)||"center".equals(operation)){
        Mesh3D editable=source;
        if(editable==null||editable.triangleCount()==0)throw new IllegalStateException("No reconstructed surface is available yet");
        if("clean".equals(operation))result=scannerState().meshEditor.clean(editable);
        else if("smooth".equals(operation))result=scannerState().meshEditor.polish(editable);
        else result=scannerState().meshEditor.center(editable);
        if(scannerState().solidScanMode&&!"center".equals(operation))result=scannerState().meshEditor.solidifyOpenSurface(result);
      }else return;
      if(Thread.currentThread().isInterrupted()||generation!=scannerState().meshGeneration)return;
      // Extraction/editing methods already maintain triangle normals. Recomputing
      // every normal here doubled work on large meshes and caused avoidable GC/CPU.
      synchronized(scannerState().reconstructionStateLock){
        if(generation!=scannerState().meshGeneration)return;
        Mesh3D previous=scannerState().mesh;
        if(operation.startsWith("build")){
          // A generated replacement is a new reconstruction result, not a mesh
          // edit. Do not deep-copy a potentially huge previous mesh into Undo.
          scannerState().meshUndoStack.clear();scannerState().meshUndo=null;
        }else if(previous!=null&&previous.triangleCount()>0&&previous!=result){
          scannerState().meshUndoStack.addLast(previous.deepCopy());
          while(scannerState().meshUndoStack.size()>ScannerModuleState.MESH_UNDO_LIMIT)scannerState().meshUndoStack.removeFirst();
          scannerState().meshUndo=scannerState().meshUndoStack.peekLast();
        }
        scannerState().mesh=result;
        scannerState().meshViewActive=true;
        scannerState().meshSourceCaptureRevision=scannerState().captureRevision;
        scannerState().previewAutoFitRevision++;
        scannerState().previewUserAdjusted=false;
        scannerState().rgbFinalized=result.hasVertexColor();
        if(operation.startsWith("build"))scannerState().liveMesh=result;
      }
      if(operation.startsWith("build")){
        scannerState().status=scannerState().i18n.format("status.mesh_built",result.triangleCount());
      }
      else if("refine-hq".equals(operation)){scannerState().status=scannerState().i18n.format("status.mesh_refined_hq",result.triangleCount());if(scannerState().hqDiagnostic!=null&&scannerState().hqDiagnostic.length()>0)scannerState().status+=" · "+scannerState().hqDiagnostic;}
      else if("clean".equals(operation))scannerState().status=scannerState().i18n.format("status.mesh_clean",source==null?0:source.triangleCount(),result.triangleCount());
      else if("smooth".equals(operation))scannerState().status=scannerState().i18n.format("status.mesh_polished",scannerState().config.meshPolishIterations);
      else scannerState().status=scannerState().i18n.tr("status.mesh_center");
      if(operation.startsWith("build")&&scannerState().pendingExport!=scannerState().EXPORT_NONE){scannerState().deferredExportPrompt=scannerState().pendingExport;scannerState().pendingExport=scannerState().EXPORT_NONE;}
    }catch(Exception e){
      if(generation==scannerState().meshGeneration&&!Thread.currentThread().isInterrupted()){
        // A failed Refine HQ never replaces the current result.
        if("refine-hq".equals(operation))scannerState().status=scannerState().i18n.tr("status.hq_failed");
        else scannerState().status=scannerState().i18n.format("status.mesh_failed",safeExceptionMessage(e));
        println(scannerState().status);e.printStackTrace();
      }
    }finally{
      if(generation==scannerState().meshGeneration){
        if(resumeCapture&&scannerState().scanActive)scannerState().scanPaused=false;
        scannerState().meshBusy=false;scannerState().meshThread=null;scannerState().meshOperation="";
      }
    }
  }});
}

void invalidateScannerViewportAppearance(){
  ScannerModuleState state=scannerState();
  if(state.viewport3D!=null){
    state.viewport3D.cachedMesh=null;
    state.viewport3D.meshChunks.clear();
    state.viewport3D.meshCursor=0;
  }
}


void toggleScannerSurfaceMode(){
  ScannerModuleState state=scannerState();state.solidScanMode=!state.solidScanMode;
  state.status=state.i18n.tr(state.solidScanMode?"status.surface_solid":"status.surface_texture");
  invalidateScannerViewportAppearance();
  // Appearance preference is immediate in the viewport and is applied geometrically
  // the next time Mesh/Refine rebuilds. Never launch reconstruction from a style toggle.
}

void toggleScannerRgbOverlay(){
  ScannerModuleState state=scannerState();
  state.rgbOverlayEnabled=!state.rgbOverlayEnabled;
  invalidateScannerViewportAppearance();
  state.status=state.i18n.tr(state.rgbOverlayEnabled?"status.overlay_on":"status.overlay_off");
}

void requestExport(int type) {
  ScannerModuleState state=scannerState();
  if(state.meshBusy){state.status=state.i18n.tr("status.mesh_busy");return;}
  if(state.exportBusy){state.status=state.i18n.tr("status.export_busy");return;}
  if(state.mesh==null||state.mesh.triangleCount()==0||state.meshSourceCaptureRevision<state.captureRevision){state.pendingExport=type;buildMesh();return;}
  showScannerExportDialog(type);
}

String scannerExportExtension(int type){return type==scannerState().EXPORT_STL?"stl":type==scannerState().EXPORT_OBJ?"obj":"ply";}
String scannerExportTypeName(int type){return type==scannerState().EXPORT_STL?"STL":type==scannerState().EXPORT_OBJ?"OBJ":"PLY";}

File defaultExportFile(int type){
  String extension="."+scannerExportExtension(type);
  String remembered=studio.userPreferences.get("scanner.export.directory","");
  File directory=remembered.isEmpty()?studio.services.paths.dataDirectory("scanner","exports","exports"):new File(remembered);
  if(!directory.isDirectory())directory=studio.services.paths.dataDirectory("scanner","exports","exports");
  return new File(directory,scannerState().config.exportBaseName+extension);
}

File exportFileWithExtension(File selected,int type){
  if(selected==null)return null;
  String extension="."+scannerExportExtension(type);
  String name=selected.getName();
  if(!name.toLowerCase(Locale.ROOT).endsWith(extension)){
    File parent=selected.getAbsoluteFile().getParentFile();
    selected=new File(parent==null?new File("."):parent,name+extension);
  }
  return selected.getAbsoluteFile();
}

void showScannerExportDialog(final int exportType){
  if(exportType==scannerState().EXPORT_NONE)return;
  final File suggested=defaultExportFile(exportType);
  final String title=scannerState().i18n.tr("dialog.export");
  studio.services.workers.startLowPriority("Scanner-Native-Save-Dialog",new Runnable(){public void run(){try{
    File chosen=studio.ui.nativeDialogs.chooseSaveFile(title,suggested);if(chosen==null)return;
    File destination=exportFileWithExtension(chosen,exportType);if(destination==null)return;
    if(destination.exists()){
      final int[] overwrite={JOptionPane.CLOSED_OPTION};
      Runnable confirm=new Runnable(){public void run(){overwrite[0]=JOptionPane.showConfirmDialog(null,destination.getAbsolutePath()+"\n\n"+scannerState().i18n.tr("dialog.overwrite"),title,JOptionPane.YES_NO_OPTION,JOptionPane.WARNING_MESSAGE);}};
      if(SwingUtilities.isEventDispatchThread())confirm.run();else SwingUtilities.invokeAndWait(confirm);
      if(overwrite[0]!=JOptionPane.YES_OPTION)return;
    }
    beginScannerExport(exportType,destination);
  }catch(Exception e){scannerState().status=scannerState().i18n.format("status.export_failed",safeExceptionMessage(e));println(scannerState().status);}}});
}

void beginScannerExport(final int exportType,final File destination){
  ScannerModuleState state=scannerState();
  if(state.exportBusy){state.status=state.i18n.tr("status.export_busy");return;}
  final Mesh3D exportMesh=state.mesh;
  if(exportMesh==null||exportMesh.triangleCount()==0){state.status=state.i18n.tr("status.mesh_required");return;}
  File rememberedDirectory=destination.getParentFile();
  if(rememberedDirectory!=null)studio.userPreferences.put("scanner.export.directory",rememberedDirectory.getAbsolutePath());
  final String type=scannerExportTypeName(exportType);
  state.exportBusy=true;state.status=state.i18n.format("status.exporting",type);
  state.activeExportThread=studio.services.workers.startCritical("Scanner-Export",new Runnable(){public void run(){
    try{
      File parent=destination.getParentFile();
      if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder: "+parent.getAbsolutePath());
      if(parent!=null&&!parent.canWrite())throw new IOException("Export folder is not writable: "+parent.getAbsolutePath());
      if(exportType==scannerState().EXPORT_STL)scannerState().stlExporter.writeBinary(exportMesh,destination);
      else if(exportType==scannerState().EXPORT_OBJ)scannerState().objExporter.write(exportMesh,destination);
      else scannerState().plyExporter.write(exportMesh,destination);
      if(!destination.isFile()||destination.length()==0)throw new IOException("Exporter did not create a valid file: "+destination.getAbsolutePath());
      writeScanExportMetadata(destination,exportMesh,type);
      scannerState().status=scannerState().i18n.format("status.exported_path",type,destination.getAbsolutePath());
      println("Scanner export: "+destination.getAbsolutePath()+" ("+destination.length()+" bytes)");
    }catch(Exception e){
      scannerState().status=scannerState().i18n.format("status.export_failed",safeExceptionMessage(e));
      println(scannerState().status);e.printStackTrace();
    }finally{scannerState().exportBusy=false;scannerState().activeExportThread=null;}
  }});
}


void writeScanExportMetadata(File destination,Mesh3D mesh,String type)throws Exception{
  File sidecar=new File(destination.getAbsolutePath()+".scan.json");
  ScanCoverageTracker coverage=scannerState().scanCoverage;
  boolean fusion=scannerFusionMode();
  float coverageFraction=fusion?fusionCaptureProgress():(coverage==null?0:coverage.coverageFraction());
  float sweepDeg=fusion?0:(coverage==null?0:coverage.sweepDeg);
  int keyframes=scannerState().hqArchive==null?0:scannerState().hqArchive.size();
  boolean complete=fusion?(keyframes>=scannerState().config.hqMinimumKeyframes&&coverageFraction>=0.82f):(coverage!=null&&coverage.complete);
  PVector center=mesh==null?new PVector():mesh.boundsCenter();
  float radius=mesh==null?0:mesh.boundsRadius();
  PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(sidecar)));
  try{
    out.println("{");
    out.println("  \"schema\": \"synkinect-scan-export-v2\",");
    out.println("  \"format\": \""+type+"\",");
    out.println("  \"mode\": \""+(fusion?"fusion":"turntable")+"\",");
    out.println("  \"partial\": "+(!complete)+",");
    out.println("  \"coverage\": "+coverageFraction+",");
    out.println("  \"sweepDeg\": "+sweepDeg+",");
    out.println("  \"capturedKeyframes\": "+keyframes+",");
    out.println("  \"rejectedTrackingFrames\": "+scannerState().rejectedTrackingFrames+",");
    out.println("  \"trackingLossEvents\": "+scannerState().trackingLossEvents+",");
    out.println("  \"trackingState\": \""+scannerTrackingStateName()+"\", ");
    out.println("  \"units\": \"meter\", ");
    out.println("  \"triangles\": "+(mesh==null?0:mesh.triangleCount())+",");
    out.println("  \"centerM\": ["+center.x+", "+center.y+", "+center.z+"],");
    out.println("  \"radiusM\": "+radius+",");
    out.println("  \"createdEpochMs\": "+System.currentTimeMillis());
    out.println("}");
  }finally{out.close();}
}

void runPartialMeshTool(String operation) {
  ScannerModuleState state=scannerState();
  if(state.meshBusy){state.status=state.i18n.tr("status.mesh_busy");return;}
  Mesh3D source=state.mesh;
  if(source==null||source.triangleCount()==0){state.status=state.i18n.tr("status.mesh_required");return;}
  final boolean wasCapturing=state.scanActive&&!state.scanPaused;
  if(wasCapturing){state.scanPaused=true;clearPendingScanWork();}
  startMeshTask(operation,source,false);
}
void cleanMesh(){runPartialMeshTool("clean");}
void smoothMesh(){runPartialMeshTool("smooth");}
void centerMesh(){runPartialMeshTool("center");}
void undoMeshEdit() {
  if(scannerState().meshBusy){scannerState().status=scannerState().i18n.tr("status.mesh_busy");return;}
  Mesh3D undo=scannerState().meshUndoStack.pollLast();if(undo==null){scannerState().status=scannerState().i18n.tr("status.no_undo");return;}
  scannerState().mesh=undo;scannerState().meshUndo=scannerState().meshUndoStack.peekLast();
  scannerState().meshViewActive=true;
  scannerState().previewAutoFitRevision++;
  scannerState().previewUserAdjusted=false;
  scannerState().status=scannerState().i18n.tr("status.undo");
}

boolean scannerHasReconstructionInput(){
  ScannerModuleState state=scannerState();
  return state.hqArchive!=null&&state.config!=null&&state.hqArchive.size()>=state.config.hqMinimumKeyframes;
}
boolean scannerHasMesh(){
  Mesh3D mesh=scannerState().mesh;
  return mesh!=null&&mesh.triangleCount()>0;
}
boolean scannerHasEditableGeometry(){return scannerHasMesh();}

boolean scannerActionAllowed(int action){
  ScannerModuleState state=scannerState();
  // Pause/resume is a capture safety control and stays available for an active
  // scan unless a reset is currently replacing reconstruction state.
  if(action==state.ui.ACTION_START&&state.scanActive)
    return !state.resetBusy&&!state.meshBusy&&!state.exportBusy&&!state.hqBusy;

  // The button that started a long mesh task stays enabled as its Cancel.
  if(action==state.ui.ACTION_HQ&&scannerHqRunning())return true;
  if(action==state.ui.ACTION_MESH&&scannerBuildRunning())return true;
  // Reset doubles as a non-blocking cancel for long mesh/HQ work. Export is not
  // interrupted because it may be writing a user-selected destination file.
  if(action==state.ui.ACTION_RESET&&state.exportBusy==false)return !state.resetBusy;
  if(state.resetBusy||state.meshBusy||state.exportBusy||state.hqBusy)return false;
  if(action==state.ui.ACTION_MODE)return !state.scanActive&&!state.scanPaused;
  if(action==state.ui.ACTION_START){
    KinectDevice d=studio.selectedKinect();
    return d!=null&&d.cameraReady()&&d.hasCapability("depth")
      &&state.latestDepth!=null&&state.latestPair!=null&&state.latestDepth.deviceCalibrated
      &&state.latestDepthDiagnostics!=null&&state.latestDepthDiagnostics.healthy(state.config);
  }

  // Reset and view-mode toggles do not require a reconstruction. Reset is always a
  // valid transition once no destructive background task is active.
  if(action==state.ui.ACTION_RESET||action==state.ui.ACTION_SURFACE_MODE||action==state.ui.ACTION_RGB_OVERLAY)return true;
  if(action==state.ui.ACTION_MESH)return scannerHasReconstructionInput();
  if(action==state.ui.ACTION_HQ)return state.config.hqEnabled&&state.hqArchive!=null&&
    state.hqArchive.size()>=state.config.hqMinimumKeyframes;
  if(action==state.ui.ACTION_CLEAN||action==state.ui.ACTION_SMOOTH||action==state.ui.ACTION_CENTER)
    return scannerHasEditableGeometry();
  if(action==state.ui.ACTION_UNDO)return !state.meshUndoStack.isEmpty();
  if(action==state.ui.ACTION_STL||action==state.ui.ACTION_OBJ||action==state.ui.ACTION_PLY)
    return scannerHasEditableGeometry()||scannerHasReconstructionInput();
  return false;
}

void scannerActionBlockedStatus(int action){
  ScannerModuleState state=scannerState();
  if(state.resetBusy){state.status=state.i18n.tr("status.scan_reset");return;}
  if(state.exportBusy){state.status=state.i18n.tr("status.export_busy");return;}
  if(state.meshBusy&&!scannerHqRunning()){state.status=state.i18n.tr("status.mesh_busy");return;}
  if(scannerHqRunning()){
    int pct=round(constrain(state.hqProgress,0,1)*100.0f);
    state.status=state.i18n.format("status.hq_stage",state.hqTracker.stageLabel(),pct)+" · "+state.i18n.tr("hq.cancel_hint");return;
  }
  if(action==state.ui.ACTION_START){
    if(state.latestDepth==null||state.latestPair==null){state.status=state.i18n.tr("status.no_depth");return;}
    if(!state.latestDepth.deviceCalibrated){state.status=state.i18n.tr("status.no_metric");return;}
    state.status=state.i18n.tr("status.depth_sparse");return;
  }
  if(action==state.ui.ACTION_HQ){
    int have=state.hqArchive==null?0:state.hqArchive.size(),need=state.config.hqMinimumKeyframes;
    state.status=state.i18n.format("status.hq_need_keyframes",have,need);return;
  }
  if(action==state.ui.ACTION_UNDO){state.status=state.i18n.tr("status.no_undo");return;}
  if(action==state.ui.ACTION_MESH){int have=state.hqArchive==null?0:state.hqArchive.size();state.status=state.i18n.format("status.hq_need_keyframes",have,state.config.hqMinimumKeyframes);return;}
  if(action==state.ui.ACTION_CLEAN||action==state.ui.ACTION_SMOOTH||action==state.ui.ACTION_CENTER||
     action==state.ui.ACTION_STL||action==state.ui.ACTION_OBJ||action==state.ui.ACTION_PLY){
    state.status=state.i18n.tr("status.mesh_required");return;
  }
}

void dispatchUiAction(int action) {
  if(!scannerActionAllowed(action)){scannerActionBlockedStatus(action);return;}
  if((action==scannerState().ui.ACTION_HQ&&scannerHqRunning())||(action==scannerState().ui.ACTION_MESH&&scannerBuildRunning())){cancelScannerMeshTaskFromButton();return;}
  if(action==scannerState().ui.ACTION_MODE)toggleScannerMode();
  else if(action==scannerState().ui.ACTION_START)toggleScanControl();
  else if(action==scannerState().ui.ACTION_RESET)resetScan();
  else if(action==scannerState().ui.ACTION_SURFACE_MODE)toggleScannerSurfaceMode();
  else if(action==scannerState().ui.ACTION_RGB_OVERLAY)toggleScannerRgbOverlay();
  else if(action==scannerState().ui.ACTION_MESH)buildMesh();
  else if(action==scannerState().ui.ACTION_HQ)refineScannerHighQuality();
  else if(action==scannerState().ui.ACTION_STL)requestExport(scannerState().EXPORT_STL);
  else if(action==scannerState().ui.ACTION_OBJ)requestExport(scannerState().EXPORT_OBJ);
  else if(action==scannerState().ui.ACTION_PLY)requestExport(scannerState().EXPORT_PLY);
  else if(action==scannerState().ui.ACTION_CLEAN)cleanMesh();
  else if(action==scannerState().ui.ACTION_SMOOTH)smoothMesh();
  else if(action==scannerState().ui.ACTION_CENTER)centerMesh();
  else if(action==scannerState().ui.ACTION_UNDO)undoMeshEdit();
}

void scannerMousePressed() {
  if(scannerState().ui.handleMousePressed(studio.ui.pointerX(),studio.ui.pointerY()))return;
  if(scannerState().ui.isOver3D(studio.ui.pointerX(),studio.ui.pointerY())&&mouseButton==CENTER){
    resetScanner3DView();
  }
}
void resetScanner3DView(){
  ScannerModuleState s=scannerState();s.previewYaw=-0.42f;s.previewPitch=0.22f;s.previewZoom=1.0f;s.previewPanX=0;s.previewPanY=0;s.previewUserAdjusted=false;
}
void scannerMouseDragged() {
  if (scannerState().ui.isOver3D(studio.ui.pointerX(),studio.ui.pointerY())) {
    float dx=studio.ui.pointerX()-studio.ui.previousPointerX(),dy=studio.ui.pointerY()-studio.ui.previousPointerY();
    scannerState().previewUserAdjusted=true;
    if(mouseButton==RIGHT){
      scannerState().previewPanX=constrain(scannerState().previewPanX+dx,-scannerState().ui.previewW*.85f,scannerState().ui.previewW*.85f);
      scannerState().previewPanY=constrain(scannerState().previewPanY+dy,-scannerState().ui.previewH*.85f,scannerState().ui.previewH*.85f);
    }else{
      // Trackball-like orbit: horizontal motion circles Y, vertical circles X.
      float sensitivity=0.0065f;
      scannerState().previewYaw += dx*sensitivity;scannerState().previewPitch += dy*sensitivity;
      scannerState().previewPitch = constrain(scannerState().previewPitch, -1.48f, 1.48f);
    }
  }
}
void scannerMouseWheel(processing.event.MouseEvent event) {
  if(event==null||scannerState().ui==null)return;
  float mx=studio.ui.pointerX(),my=studio.ui.pointerY();
  if(!scannerState().ui.isOver3D(mx,my))return;
  float oldZoom=scannerState().previewZoom;
  float newZoom=constrain(oldZoom*pow(1.08f,-event.getCount()),0.2f,4.0f);
  if(abs(newZoom-oldZoom)<0.0001f)return;
  float factor=newZoom/max(0.0001f,oldZoom);
  // Keep the orbit framing stable while changing camera distance.
  float anchorX=mx-(scannerState().ui.previewX+scannerState().ui.previewW*.5f);
  float anchorY=my-(scannerState().ui.previewY+scannerState().ui.previewH*.5f);
  scannerState().previewPanX=factor*scannerState().previewPanX+(1.0f-factor)*anchorX;
  scannerState().previewPanY=factor*scannerState().previewPanY+(1.0f-factor)*anchorY;
  scannerState().previewPanX=constrain(scannerState().previewPanX,-scannerState().ui.previewW*.85f,scannerState().ui.previewW*.85f);
  scannerState().previewPanY=constrain(scannerState().previewPanY,-scannerState().ui.previewH*.85f,scannerState().ui.previewH*.85f);
  scannerState().previewZoom=newZoom;
  scannerState().previewUserAdjusted=true;
}
void disposeScannerModule() {
  // Stop native capture first, preserve already received frames, move pending
  // depth into reconstruction, then let the reconstruction worker drain its bounded window.
  if (scannerState().source != null) scannerState().source.stop(false);
  flushCapturedDepthForShutdown();
  stopReconstructionWorker();
  Thread mt=scannerState().meshThread;if(mt!=null){mt.interrupt();try{mt.join(scannerState().config.workerJoinMs);
      }catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  Thread et=scannerState().activeExportThread;if(et!=null){try{et.join(scannerState().config.workerJoinMs*2L);
      }catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  if(scannerState().viewport3D!=null)scannerState().viewport3D.dispose();
}

// Refine HQ progress: weighted stages so the percentage advances evenly over the
// real work, plus an elapsed-time based remaining-time estimate for the UI.
class HqProgressTracker {
  final int IDLE=0,PREPARE=1,ALIGN=2,CONSENSUS=3,FUSE=4,MESH=5;
  final float[] stageStart={0,0.00f,0.10f,0.42f,0.48f,0.90f};
  final float[] stageEnd  ={0,0.10f,0.42f,0.48f,0.90f,0.995f};
  final String[] stageKeys={"","hq.stage.prepare","hq.stage.align","hq.stage.consensus","hq.stage.fuse","hq.stage.mesh"};
  volatile int stage=IDLE;volatile float progress=0;volatile long startMs=0,token=0;
  float shown=0;long shownAtMs=0;
  synchronized long begin(){token++;stage=PREPARE;progress=0;startMs=System.currentTimeMillis();shown=0;shownAtMs=0;return token;}
  void set(int s,float fraction){
    if(s<=IDLE||s>=stageKeys.length)return;stage=s;
    float p=lerp(stageStart[s],stageEnd[s],constrain(fraction,0,1));
    if(p>progress)progress=p;   // never runs backwards
    ScannerModuleState state=scannerState();state.hqProgress=progress;
    state.status=state.i18n.format("status.hq_stage",state.i18n.tr(stageKeys[s]),round(progress*100));
  }
  synchronized void end(long t){if(t==token){stage=IDLE;}}
  boolean active(){return stage!=IDLE;}
  String stageLabel(){ScannerModuleState st=scannerState();int s=stage;return s>IDLE&&s<stageKeys.length?st.i18n.tr(stageKeys[s]):"";}
  // Smoothed value for drawing: eases toward the real progress so the bar moves
  // continuously even when a stage reports in coarse steps.
  float displayed(){
    long now=System.currentTimeMillis();float target=progress;
    if(shownAtMs==0){shown=target;}else{float dt=min(0.25f,(now-shownAtMs)/1000.0f);shown+=(target-shown)*min(1,dt*6.0f);}
    shownAtMs=now;return constrain(shown,0,1);
  }
  long remainingMs(){
    float p=progress;long elapsed=System.currentTimeMillis()-startMs;
    if(p<0.04f||elapsed<3000)return -1;
    return (long)(elapsed*(1.0f-p)/max(0.001f,p));
  }
  String remainingLabel(){
    long ms=remainingMs();if(ms<0)return "";long sec=Math.max(1L,ms/1000L);
    String t=sec>=60?(sec/60)+":"+nf((int)(sec%60),2):sec+" s";
    return scannerState().i18n.format("hq.eta",t);
  }
}

class ScanWorkItem {
  final RgbdFramePair pair;
  ScanWorkItem(RgbdFramePair pair){this.pair=pair;}
}

void startReconstructionWorker() {
  if (scannerState().reconstructionRun) return; scannerState().reconstructionRun = true;

  scannerState().reconstructionThread = studio.services.workers.startLowPriority("Scanner-Reconstruction",new Runnable() { public void run() { reconstructionLoop(); }
     });
}
void stopReconstructionWorker() {
  scannerState().reconstructionRun = false;
  synchronized (scannerState().reconstructionQueueLock) { scannerState().reconstructionQueueLock.notifyAll();
     }
  Thread t = scannerState().reconstructionThread; scannerState().reconstructionThread = null;

  if (t != null) {
    // Do not interrupt first: an orderly shutdown must finish all queued fusion work.
    try { t.join(scannerState().config.workerJoinMs*4L); } catch (InterruptedException ignored) { Thread.currentThread().interrupt();
       }
    if(t.isAlive()){t.interrupt();try{t.join(scannerState().config.workerJoinMs);
        }catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  }
}
int reconstructionQueuedFrames(){synchronized(scannerState().reconstructionQueueLock){return scannerState().reconstructionQueue.size();
    }}
boolean queueScanFrame(RgbdFramePair pair) {
  if (!scannerState().reconstructionRun || pair == null || pair.depth == null) return false;

  synchronized (scannerState().reconstructionQueueLock) {
    // Reconstruction is latency-sensitive. A 3D scan benefits from the newest
    // pose, not from replaying stale capture. Keep only the newest pending work;
    // the frame currently being reconstructed is never interrupted.
    while(!scannerState().reconstructionQueue.isEmpty()){
      scannerState().reconstructionQueue.removeFirst();
      scannerState().reconstructionQueueOverflows++;
    }
    scannerState().reconstructionQueue.addLast(new ScanWorkItem(pair));
    scannerState().reconstructionQueueLock.notifyAll();
    return true;
  }
}
void clearPendingScanWork() { synchronized (scannerState().reconstructionQueueLock) { scannerState().reconstructionQueue.clear();
     scannerState().reconstructionQueueLock.notifyAll(); } }
void flushCapturedDepthForShutdown(){
  if(scannerState().source==null||!scannerState().scanActive||scannerState().scanPaused)return;

  while(scannerState().source.queuedRgbdPairs()>0){
    int before=scannerState().source.queuedRgbdPairs();consumeKinectFrames();
    if(scannerState().source.queuedRgbdPairs()>=before){try{Thread.sleep(2);}catch(InterruptedException ignored){Thread.currentThread().interrupt();
        break;}}
  }
}
void reconstructionLoop() {
  while (true) {
    ScanWorkItem work = null;
    synchronized (scannerState().reconstructionQueueLock) {
      while (scannerState().reconstructionRun && scannerState().reconstructionQueue.isEmpty()) {
        try { scannerState().reconstructionQueueLock.wait(100); } catch (InterruptedException ignored) { if(!scannerState().reconstructionRun&&scannerState().reconstructionQueue.isEmpty())return;
           }
      }
      if (!scannerState().reconstructionRun && scannerState().reconstructionQueue.isEmpty()) break;

      if(!scannerState().reconstructionQueue.isEmpty()){work = scannerState().reconstructionQueue.removeFirst();
        scannerState().reconstructionBusy=true;}
    }
    if (work != null) {
      try{processScanFrame(work.pair);}
      finally{scannerState().reconstructionBusy=false;synchronized(scannerState().reconstructionQueueLock){scannerState().reconstructionQueueLock.notifyAll();
          }}
    }
  }
  scannerState().reconstructionBusy=false;
}


float rigidTranslationDelta(RigidTransform a,RigidTransform b){
  if(a==null||b==null)return Float.POSITIVE_INFINITY;
  float dx=a.m[3]-b.m[3],dy=a.m[7]-b.m[7],dz=a.m[11]-b.m[11];
  return sqrt(dx*dx+dy*dy+dz*dz);
}
float rigidRotationDeltaDeg(RigidTransform a,RigidTransform b){
  if(a==null||b==null)return Float.POSITIVE_INFINITY;
  float trace=(a.m[0]*b.m[0]+a.m[4]*b.m[4]+a.m[8]*b.m[8])+
              (a.m[1]*b.m[1]+a.m[5]*b.m[5]+a.m[9]*b.m[9])+
              (a.m[2]*b.m[2]+a.m[6]*b.m[6]+a.m[10]*b.m[10]);
  return degrees(acos(constrain((trace-1.0f)*0.5f,-1.0f,1.0f)));
}
boolean scannerTrackingGate(boolean good){
  ScannerModuleState s=scannerState();
  if(good){s.trackingBadStreak=0;s.trackingGoodStreak++;
    int need=s.trackingState==ScannerModuleState.TRACK_LOST?6:(s.trackingState==ScannerModuleState.TRACK_WARMUP?3:2);
    if(s.trackingGoodStreak>=need)s.trackingState=ScannerModuleState.TRACK_OK;
  }else{s.trackingGoodStreak=0;s.trackingBadStreak++;
    if(s.trackingBadStreak>=4){if(s.trackingState!=ScannerModuleState.TRACK_LOST)s.trackingLossEvents++;s.trackingState=ScannerModuleState.TRACK_LOST;}
    else s.trackingState=ScannerModuleState.TRACK_DEGRADED;
  }
  return good&&s.trackingState==ScannerModuleState.TRACK_OK;
}
String scannerTrackingStateName(){int s=scannerState().trackingState;return s==ScannerModuleState.TRACK_OK?"TRACKING":s==ScannerModuleState.TRACK_DEGRADED?"DEGRADED":s==ScannerModuleState.TRACK_LOST?"LOST":"WARMUP";}

RigidTransform regularizeFusionPoseToLockedTarget(PointCloud cloud,RigidTransform pose){
  if(cloud==null||pose==null||cloud.size()<max(24,scannerState().config.minimumTrackingPoints/3))return pose;
  PVector centroid=cloud.centroidTransformed(pose);if(centroid==null)return pose;
  if(scannerState().fusionCaptureTargetWorld==null){
    scannerState().fusionCaptureTargetWorld=centroid.copy();
    float side=scannerState().config.fusionVolumeMinSideM;
    if(scannerState().boundingBox!=null&&scannerState().boundingBox.locked){float b=scannerState().boundingBox.displayCubeSide();if(Float.isFinite(b)&&b>0)side=max(side,b);}
    scannerState().fusionCaptureTargetSideM=side;
    return pose;
  }
  float dx=scannerState().fusionCaptureTargetWorld.x-centroid.x,dy=scannerState().fusionCaptureTargetWorld.y-centroid.y,dz=scannerState().fusionCaptureTargetWorld.z-centroid.z;
  float drift=sqrt(dx*dx+dy*dy+dz*dz);
  // Gross pose failures must be rejected by the normal ICP gate instead of being
  // teleported onto the object center. Only small centroid drift is regularized.
  float hardLimit=max(0.06f,scannerState().config.icpMaxTranslationStepM*1.55f);
  if(!Float.isFinite(drift)||drift>hardLimit)return pose;
  float alpha=drift<=0.012f?1.0f:0.72f;
  RigidTransform corrected=new RigidTransform();corrected.set(pose);
  corrected.m[3]+=dx*alpha;corrected.m[7]+=dy*alpha;corrected.m[11]+=dz*alpha;
  return corrected;
}

float scannerFrameQuality(RgbdFramePair pair,PointCloud cloud){
  ScannerModuleState state=scannerState();
  float depthQ=0;
  if(state.latestDepthDiagnostics!=null){
    float ratio=state.latestDepthDiagnostics.plausibleRatio;
    depthQ=constrain((ratio-state.config.depthMinValidRatio)/max(0.02f,0.35f-state.config.depthMinValidRatio),0,1);
  }
  float syncQ=pair==null?0:constrain(pair.syncQuality,0,1);
  float irQ=pair!=null&&pair.infrared!=null?pair.infrared.quality:depthQ;
  float trackQ=state.tracker!=null&&state.tracker.trackingGood?constrain(1.0f-state.tracker.rms/max(0.0001f,state.config.icpGoodRmsM),0,1):0;
  float cloudQ=cloud==null?0:constrain(cloud.size()/(float)max(1,state.config.minimumTrackingPoints*4),0,1);
  return constrain(depthQ*0.22f+irQ*0.08f+syncQ*0.17f+trackQ*0.33f+cloudQ*0.20f,0,1);
}

void processScanFrame(RgbdFramePair pair) {
  long frameStartNs=System.nanoTime(),trackingStartNs=0;
  DepthFrame depthFrame=pair==null?null:pair.depth;
  if(!scannerState().scanActive||scannerState().scanPaused||depthFrame==null||!scannerState().calibration.valid)return;
  if(!depthFrameHealthy(depthFrame))return;

  synchronized(scannerState().reconstructionStateLock){
    if(!scannerState().scanActive||scannerState().scanPaused)return;
    final boolean fusionMode=scannerFusionMode();

    // Capture-time work is intentionally limited to target lock, lightweight ICP,
    // angular/view coverage, keyframe selection and a decimated point preview.
    // No TSDF/SDF integration, model raycast, loop optimization or mesh extraction
    // is permitted here. Those stages belong exclusively to Mesh / Refine HQ.
    scannerState().scanCoverage.updateImu(depthFrame.motion);
    if(!fusionMode&&!scannerState().scanCoverage.imuStable){
      scannerState().rejectedTrackingFrames++;
      scannerState().status=scannerState().i18n.format("status.sensor_moved",scannerState().scanCoverage.imuDeviationDeg);
      return;
    }

    if(!fusionMode)serviceTurntableSupportPlane(depthFrame,true);
    else if(scannerState().depthAnalyzer.support!=null)scannerState().depthAnalyzer.support=null;

    boolean detectorReady=scannerState().depthTarget.update(depthFrame);
    scannerState().lockedObjectDepth=scannerState().depthTarget.depthM;
    scannerState().uiTargetDepthM=scannerState().lockedObjectDepth;
    boolean targetReady=detectorReady&&!Float.isNaN(scannerState().lockedObjectDepth);
    scannerState().scanCoverage.updateDetection(targetReady);
    if(!targetReady){
      scannerState().cloudStats.clear();
      scannerState().status=scannerState().i18n.tr("status.target_locked_lost");
      return;
    }

    if(!fusionMode&&scannerState().boundingBox!=null&&scannerState().boundingBox.supportActive()){
      SupportPlane plane=scannerState().boundingBox.supportPlane;
      scannerState().tracker.setTurntableSupportAxis(plane.nx,plane.ny,plane.nz);
    }

    RgbSnapshot trackingRgb=scannerState().config.colorIcpEnabled?scannerState().source.rgbReconstructionSnapshot(pair):null;
    // Both modes are foreground-first. Fusion gets a slightly wider moving depth
    // band, but it still follows the locked object instead of letting a background
    // wall dominate ICP. If the first band is sparse, widen around the SAME depth;
    // never fall back to an unrestricted whole-room cloud.
    float trackingTargetZ=scannerState().lockedObjectDepth;
    float trackingBand=fusionMode?min(max(scannerState().config.maxObjectDepthBandM,scannerState().depthTarget.bandM*1.35f),0.55f):scannerState().depthTarget.bandM;
    PointCloud trackingCloud=scannerState().pointCloudBuilder.build(depthFrame,scannerState().calibration,scannerState().config.pointStep,
      trackingTargetZ,trackingBand,scannerState().cloudStats,trackingRgb);
    if(fusionMode&&trackingCloud.size()<scannerState().config.minimumTrackingPoints){
      float wider=min(max(trackingBand*1.45f,scannerState().config.maxObjectDepthBandM),0.70f);
      trackingCloud=scannerState().pointCloudBuilder.build(depthFrame,scannerState().calibration,scannerState().config.pointStep,
        trackingTargetZ,wider,scannerState().cloudStats,trackingRgb);
    }
    if(!fusionMode&&scannerState().boundingBox!=null)trackingCloud=scannerState().boundingBox.filter(trackingCloud,true);
    if(trackingCloud.size()<scannerState().config.minimumTrackingPoints){
      scannerState().scanCoverage.updateDetection(false);scannerState().rejectedTrackingFrames++;
      scannerState().status=scannerState().i18n.format("status.cloud_sparse",trackingCloud.size());return;
    }
    scannerState().scanCoverage.updateDetection(true);

    boolean oldTurntable=scannerState().config.turntableTracking;
    scannerState().config.turntableTracking=!fusionMode;
    RigidTransform pose;
    trackingStartNs=System.nanoTime();
    try{
      // Rolling cloud ICP is the only live registration path. Global/model-based
      // correction is intentionally deferred to the offline reconstruction engine.
      pose=scannerState().tracker.track(trackingCloud,depthFrame.motion);
      if(fusionMode)pose=regularizeFusionPoseToLockedTarget(trackingCloud,pose);
    }finally{scannerState().config.turntableTracking=oldTurntable;}
    float trackingMs=(System.nanoTime()-trackingStartNs)/1000000.0f;
    scannerState().trackingMsEma=scannerState().trackingMsEma<=0?trackingMs:lerp(scannerState().trackingMsEma,trackingMs,0.12f);

    scannerState().uiTrackingGood=scannerState().tracker.trackingGood;
    scannerState().uiIcpRmsMm=scannerState().tracker.trackingGood?scannerState().tracker.rms*1000.0f:Float.NaN;
    scannerState().uiScanQuality=scannerFrameQuality(pair,trackingCloud);
    boolean gateOk=scannerTrackingGate(scannerState().tracker.trackingGood);
    // The first valid frame establishes the tracking world and is allowed through
    // immediately; subsequent frames use the short hysteresis gate.
    boolean firstFrame=scannerState().hqArchive==null||scannerState().hqArchive.size()==0;
    if(!gateOk&&!(firstFrame&&scannerState().tracker.trackingGood)){
      scannerState().rejectedTrackingFrames++;
      scannerState().status=scannerState().i18n.format("status.icp_wait",scannerState().tracker.matches)+" ["+scannerTrackingStateName()+"]";
      return;
    }

    PointCloud acquisitionCloud=trackingCloud;
    if(!fusionMode&&scannerState().boundingBox!=null){
      if(!scannerState().boundingBox.locked)scannerState().boundingBox.lockFrom(trackingCloud);
      scannerState().boundingBox.lockWorldCube(pose);
      acquisitionCloud=scannerState().boundingBox.filterWorld(trackingCloud,pose);
      if(acquisitionCloud.size()<scannerState().config.minimumTrackingPoints){
        scannerState().rejectedTrackingFrames++;
        scannerState().status=scannerState().i18n.format("status.cloud_sparse",acquisitionCloud.size());return;
      }
    }

    if(!fusionMode){
      scannerState().scanCoverage.updateTracking(pose,depthFrame.motion,scannerState().tracker.lastTrackedYawStepDeg);
      // Coverage is confirmed by tracking itself, not by a later reconstruction.
      scannerState().scanCoverage.confirmAcquisition();
      scannerState().uiProgress=scannerState().scanCoverage.progress();
      scannerState().uiScanComplete=scannerState().scanCoverage.complete;
    }

    RawRgbFrame preferred=pair.hq!=null?pair.hq:scannerState().source.bestHqRgbFor(depthFrame.timestampUs);
    boolean archiveCandidate=scannerState().hqArchive!=null&&scannerState().hqArchive.wouldOffer(pose,fusionMode?0:scannerState().scanCoverage.sweepDeg);
    boolean archiveRejected=false;
    if(fusionMode&&archiveCandidate){
      RigidTransform verified=scannerState().tracker.validateFusionArchivePose(acquisitionCloud,pose,scannerState().hqArchive.size());
      if(verified==null){archiveRejected=true;scannerState().rejectedTrackingFrames++;}
      else pose=verified;
    }
    boolean archived=!archiveRejected&&scannerState().hqArchive!=null&&scannerState().hqArchive.offer(pair,preferred,pose,
      scannerState().lockedObjectDepth,trackingBand,
      fusionMode?0:scannerState().scanCoverage.sweepDeg,
      fusionMode?0:scannerState().scanCoverage.trackedAngleDeg,
      fusionMode?null:scannerState().tracker.calibratedTurntablePivot(),
      fusionMode?null:scannerState().tracker.turntableAxisWorld());

    if(archived){
      scannerState().capturedKeyframes=scannerState().hqArchive.size();
      scannerState().captureRevision++;
      scannerState().rgbFinalized=false;
      if(scannerState().previewPointModel!=null)scannerState().previewPointModel.accumulate(acquisitionCloud,pose);
      if(fusionMode){
        scannerState().tracker.acceptFusionReference(acquisitionCloud,pose);
        if(scannerState().fusionCaptureTargetWorld==null){
          scannerState().fusionCaptureTargetWorld=acquisitionCloud.centroidTransformed(pose);
          float initialSide=scannerState().config.fusionVolumeMinSideM;
          if(scannerState().boundingBox!=null&&scannerState().boundingBox.locked){float b=scannerState().boundingBox.displayCubeSide();if(Float.isFinite(b)&&b>0)initialSide=max(initialSide,b);}
          scannerState().fusionCaptureTargetSideM=initialSide;
        }
        recordFusionTrajectory(pose);
      }
    }else if(scannerState().hqArchive!=null)scannerState().capturedKeyframes=scannerState().hqArchive.size();

    if(fusionMode&&archiveRejected)scannerState().status=scannerState().i18n.tr("status.fusion_pose_rejected");

    long previewPublishNow=System.currentTimeMillis();
    if(scannerState().uiPreviewCloud==null||archived||previewPublishNow-scannerState().lastPreviewCloudPublishMs>=scannerState().config.previewPointRefreshMs){
      scannerState().lastPreviewCloudPublishMs=previewPublishNow;
      PointCloud displayCloud=acquisitionCloud.transformed(pose,scannerState().config.previewPointTransientMaxPoints);
      scannerState().uiPreviewCloud=scannerState().previewPointModel==null?displayCloud:scannerState().previewPointModel.snapshotWithTransient(displayCloud);
    }

    if(fusionMode){
      scannerState().uiProgress=fusionCaptureProgress();
      scannerState().uiScanComplete=false;
    }

    if(!fusionMode&&scannerState().scanCoverage.complete&&scannerState().config.autoPauseOnFullTurn){
      // Full turn simply pauses acquisition. Nothing is reconstructed here.
      scannerState().scanPaused=true;clearPendingScanWork();
      if(scannerState().previewPointModel!=null)scannerState().uiPreviewCloud=scannerState().previewPointModel.snapshot();
      scannerState().status=scannerState().i18n.format("status.full_turn_capture",scannerState().scanCoverage.sweepDeg,scannerState().capturedKeyframes);
    }else if(fusionMode){
      scannerState().status=archiveRejected?scannerState().i18n.tr("status.fusion_pose_rejected"):
        scannerState().i18n.format("status.scanning_fusion_capture",scannerState().capturedKeyframes,round(scannerState().uiProgress*100.0f),round(scannerState().uiScanQuality*100.0f));
    }else{
      scannerState().status=scannerState().i18n.format("status.scanning_capture",round(scannerState().uiProgress*100.0f),scannerState().capturedKeyframes,scannerState().hqArchive==null?0:scannerState().hqArchive.estimatedBytes()/(1024L*1024L));
    }

    float frameMs=(System.nanoTime()-frameStartNs)/1000000.0f;
    scannerState().captureWorkMsEma=scannerState().captureWorkMsEma<=0?frameMs:lerp(scannerState().captureWorkMsEma,frameMs,0.10f);
  }
}

// Fusion capture remains keyframe/trajectory-only; dense volumes are created offline.
void recordFusionTrajectory(RigidTransform pose){
  if(pose==null)return;ScannerModuleState state=scannerState();PVector p=new PVector(pose.m[3],pose.m[7],pose.m[11]);
  PVector last=state.fusionTrajectory.peekLast();if(last!=null&&PVector.dist(last,p)<state.config.fusionTrajectoryMinStepM)return;
  state.fusionTrajectory.addLast(p);while(state.fusionTrajectory.size()>ScannerModuleState.FUSION_TRAJECTORY_LIMIT)state.fusionTrajectory.removeFirst();
}
float fusionCaptureProgress(){
  ScannerModuleState state=scannerState();
  int keyframes=state.hqArchive==null?0:state.hqArchive.size();
  if(keyframes<=0)return 0;
  float keyframeReadiness=constrain(keyframes/(float)max(state.config.hqMinimumKeyframes,24),0,1);
  if(state.fusionTrajectory.size()<2||state.fusionCaptureTargetWorld==null)return keyframeReadiness*.20f;

  int bins=max(8,state.config.fusionCoverageViewBins);boolean[] seen=new boolean[bins];int count=0;
  PVector c=state.fusionCaptureTargetWorld;
  for(PVector p:state.fusionTrajectory){
    float dx=p.x-c.x,dz=p.z-c.z;if(dx*dx+dz*dz<0.0025f)continue;
    float a=atan2(dz,dx);if(a<0)a+=TWO_PI;int b=constrain(floor(a/TWO_PI*bins),0,bins-1);
    if(!seen[b]){seen[b]=true;count++;}
  }
  float views=count/(float)bins;
  // Capture coverage is intentionally independent from any reconstructed surface.
  // Viewpoint diversity is dominant; keyframe count only prevents a few sparse
  // poses from looking complete.
  return constrain(views*.85f+keyframeReadiness*.15f,0,1);
}

String safeExceptionMessage(Exception e) {
  String m = e.getMessage(); return (m == null || m.length() == 0) ? e.getClass().getSimpleName() : m;

}


// ===== SynKinect Studio / 3D Scanner / Localization.pde =====
class ScannerI18n extends ModuleI18n {
  ScannerI18n(String requested){super("scanner",requested);}
}


class ScannerTheme extends StudioPalette {
  // Scanner-specific: the reconstruction viewport uses a neutral CAD-like light
  // environment even though the surrounding Studio chrome remains dark.
  final int FUSION_TRAJECTORY=0xFF9B6CFF;
  final int GRID=0xFFB8BEC5,PREVIEW=0xFFE4E7EA,MESH=0xFF71879A;
  final int SIDEBAR_W=430;
}

void initializeScannerTypography(){if(studioUnicodeRegular==null||studioUnicodeHeading==null)initializeStudioTypography();
  }

void uiText(float size,boolean heading){studioText(size,heading);}
