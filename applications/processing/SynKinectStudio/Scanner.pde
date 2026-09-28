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
  DepthCalibrationSession calibrationSession;
  DepthAnalyzer depthAnalyzer;
  DepthPreviewRenderer depthRenderer;
  PointCloudBuilder pointCloudBuilder;
  RgbDepthRegistration rgbRegistration;
  IcpTracker tracker;
  BoundingBoxTracker boundingBox;
  TSDFVolume volume;
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
  volatile boolean meshBusy=false,exportBusy=false;
  volatile boolean hqBusy=false;
  volatile float hqProgress=0;
  Thread meshThread=null,activeExportThread=null;
  volatile int deferredExportPrompt=0;
  volatile boolean scanActive=false,scanPaused=false,volumeInitialized=false;
  volatile boolean solidScanMode=false;
  volatile boolean rgbFinalized=false;
  volatile boolean meshViewActive=false;
  volatile long meshSourceIntegratedFrames=-1;
  volatile boolean autoFinalizePending=false;
  volatile float lockedObjectDepth=Float.NaN;
  volatile long integratedFrames=0,rejectedTrackingFrames=0;
  static final int TRACK_WARMUP=0,TRACK_OK=1,TRACK_DEGRADED=2,TRACK_LOST=3;
  volatile int trackingState=TRACK_WARMUP,trackingGoodStreak=0,trackingBadStreak=0;
  volatile long trackingLossEvents=0,lastSessionCheckpointFrame=0;
  volatile float uiProgress=0.0f,uiTargetDepthM=Float.NaN,uiIcpRmsMm=Float.NaN,uiScanQuality=0.0f;
  volatile boolean uiScanComplete=false,uiTrackingGood=false;
  volatile PointCloud uiPreviewCloud=null;
  PointCloudAccumulator previewPointModel=null;
  // Live depth-detection preview shown when the Scanner module opens. It is
  // display-only: Scan switches to the existing ICP/TSDF acquisition path.
  volatile boolean showLiveDetectionCloud=true;
  RigidTransform lastIntegratedPose=null;
  int integrationIdleFrames=0;
  volatile long lastPreviewRenderMs=0,lastLiveMeshBuildMs=0,lastLiveMeshFrame=0,lastScanQueueMs=0;
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
  scannerState().calibrationSession=null;
  int dw=device!=null&&device.depthWidth>0?device.depthWidth:studio.services.scannerProtocol.WIDTH,dh=device!=null&&device.depthHeight>0?device.depthHeight:studio.services.scannerProtocol.HEIGHT;
  DepthCorrectionProfile profile=id.length()==0?null:scannerState().calibrationStore.load(id,dw,dh);

  scannerState().calibration.selectDevice(id,profile);
  if(scannerState().rgbRegistration!=null)scannerState().rgbRegistration.clearPreparedFrame();

  if(announce&&scannerState().i18n!=null){
    if(profile!=null&&profile.calibrated)scannerState().status=scannerState().i18n.format("status.calibration_loaded",profile.coverage*100.0f,profile.trainingRmsBeforeMm,
      profile.trainingRmsAfterMm);
    else scannerState().status=scannerState().i18n.tr("status.calibration_not_found");

  }
}

String depthCalibrationQuality(DepthCorrectionProfile p){
  if(p==null||!p.calibrated)return "missing";
  if(!Float.isFinite(p.trainingRmsAfterMm)||!Float.isFinite(p.coverage))return "poor";
  float improvement=Float.isFinite(p.trainingRmsBeforeMm)?p.trainingRmsBeforeMm-p.trainingRmsAfterMm:0;
  if(p.coverage>=0.70f&&p.trainingRmsAfterMm<=8.0f&&improvement>=0)return "good";
  if(p.coverage>=0.50f&&p.trainingRmsAfterMm<=16.0f)return "fair";
  return "poor";
}

String depthCalibrationSummary(){
  DepthCorrectionProfile p=scannerState().calibration==null?null:scannerState().calibration.depthCorrection;
  String q=depthCalibrationQuality(p);
  if(p==null||!p.calibrated)return scannerState().i18n.tr("calibration.quality.missing");
  return scannerState().i18n.format("calibration.quality."+q,p.coverage*100.0f,p.trainingRmsBeforeMm,p.trainingRmsAfterMm);
}

boolean clearDepthCalibration(){
  KinectDevice device=studio.selectedKinect();if(device==null||scannerState().calibrationStore==null)return false;
  if(scannerState().calibrationSession!=null)scannerState().calibrationSession.cancel();
  boolean ok=scannerState().calibrationStore.delete(device.id);
  if(ok){scannerState().calibration.selectDevice(device.id,null);if(scannerState().rgbRegistration!=null)scannerState().rgbRegistration.clearPreparedFrame();
    scannerState().status=scannerState().i18n.tr("status.calibration_cleared");studio.notifyDepthCalibrationChanged();}
  return ok;
}

void toggleDepthCalibration(){
  if(scannerState().calibrationSession!=null&&scannerState().calibrationSession.active){
    scannerState().calibrationSession.cancel();scannerState().status=scannerState().i18n.tr("status.calibration_cancelled");
    return;
  }
  if(scannerState().scanActive){scannerState().status=scannerState().i18n.tr("status.calibration_stop_scan");
    return;}
  KinectDevice device=studio.selectedKinect();
  if(device==null||scannerState().latestDepth==null){scannerState().status=scannerState().i18n.tr("status.no_depth");
    return;}
  scannerState().calibrationSession=new DepthCalibrationSession(scannerState().config,scannerState().calibration,scannerState().calibrationStore,device.id);

  scannerState().calibrationSession.start();
  scannerState().status=scannerState().i18n.format("status.calibration_started",scannerState().config.calibrationStations);

}


void serviceDepthCalibration(DepthFrame frame){
  DepthCalibrationSession session=scannerState().calibrationSession;if(session==null||!session.active)return;

  try{
    DepthCorrectionProfile completed=session.offer(frame);
    if(completed!=null){
      scannerState().calibration.selectDevice(session.deviceId,completed);
      if(scannerState().rgbRegistration!=null)scannerState().rgbRegistration.clearPreparedFrame();

      scannerState().status=scannerState().i18n.format("status.calibration_complete",completed.coverage*100.0f,completed.trainingRmsBeforeMm,completed.trainingRmsAfterMm);
      studio.notifyDepthCalibrationChanged();
      return;
    }
    if(session.waitingForDistance)scannerState().status=scannerState().i18n.format("status.calibration_move",session.stations.size(),scannerState().config.calibrationStations,
      scannerState().config.calibrationDistanceSeparationM);
    else scannerState().status=scannerState().i18n.format("status.calibration_capture",session.stations.size()+1,scannerState().config.calibrationStations,
      session.capturedFrames,scannerState().config.calibrationFramesPerStation);
  }catch(Exception e){session.cancel();scannerState().status=scannerState().i18n.format("status.calibration_failed",safeExceptionMessage(e));
    }
}

void setupScannerModule() {
  ensureScannerSource();
  initializeScannerTypography();
  scannerState().status = scannerState().i18n.tr("status.connecting");

  scannerState().processing = studio.services.processingBlocks.openScanner(scannerState().config,scannerState().calibration,scannerState().rgbRegistration);
  scannerState().depthAnalyzer=scannerState().processing.depthAnalyzer;scannerState().depthRenderer=scannerState().processing.depthRenderer;
  scannerState().pointCloudBuilder=scannerState().processing.pointCloudBuilder;scannerState().tracker=scannerState().processing.tracker;
  scannerState().boundingBox=scannerState().processing.boundingBox;scannerState().previewPointModel=scannerState().processing.previewPointModel;
  scannerState().volume=scannerState().processing.volume;scannerState().meshEditor=scannerState().processing.meshEditor;
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
  if(state.autoFinalizePending&&!scannerExclusiveBusy()&&!state.scanActive){
    state.autoFinalizePending=false;
    buildMesh(false);
  }
  int type=state.deferredExportPrompt;if(type==state.EXPORT_NONE)return;
  if(scannerExclusiveBusy())return;
  state.deferredExportPrompt=state.EXPORT_NONE;
  showScannerExportDialog(type);
}

boolean scannerExclusiveBusy(){
  ScannerModuleState state=scannerState();
  return state.resetBusy||state.meshBusy||state.exportBusy||state.hqBusy;
}

boolean scannerCalibrationActive(){
  return scannerState().calibrationSession!=null&&scannerState().calibrationSession.active;
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
    serviceDepthCalibration(pair.depth);

    if(scannerState().scanActive&&!scannerState().scanPaused&&scannerState().calibration.valid){
      if(!pair.depth.deviceCalibrated)scannerState().status=scannerState().i18n.tr("status.depth_uncalibrated_frame");

      else if(!depthFrameHealthy(pair.depth))scannerState().status=scannerState().i18n.tr("status.depth_sparse");

      else {
        long nowMs=System.currentTimeMillis();
        long minInterval=Math.max(1,1000/Math.max(1,scannerState().config.reconstructionMaxFps));

        if(scannerState().lastScanQueueMs==0||nowMs-scannerState().lastScanQueueMs>=minInterval){
          scannerState().lastScanQueueMs=nowMs;queueScanFrame(pair);
        }
      }
    }
  }

  // Preview work is intentionally performed once for the newest drained pair,
  // never once per queued reconstruction frame. This keeps the Processing
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
    if(scannerState().showLiveDetectionCloud&&!scannerState().scanActive&&
       scannerState().calibration.valid&&lastPair.depth!=null&&lastPair.depth.deviceCalibrated&&
       scannerState().latestDepthDiagnostics.healthy(scannerState().config)){
      // Use the same object depth band that Scan will lock onto so preview and
      // reconstruction use consistent subject framing.
      DepthTargetEstimate liveTarget=scannerState().depthAnalyzer.estimateTarget(lastPair.depth,scannerState().config,Float.NaN);
      float liveZ=liveTarget!=null&&liveTarget.valid?liveTarget.depthM:Float.NaN;
      float liveBand=liveTarget!=null&&liveTarget.valid
        ?constrain(max(scannerState().config.objectDepthBandM,liveTarget.spreadM*scannerState().config.depthBandSpreadMultiplier),scannerState().config.objectDepthBandM,scannerState().config.maxObjectDepthBandM)
        :Float.POSITIVE_INFINITY;
      scannerState().uiPreviewCloud=scannerState().pointCloudBuilder.build(
        lastPair.depth,scannerState().calibration,scannerState().config.pointStep,
        liveZ,liveBand,null,preview);
    }

  }
}

boolean depthFrameHealthy(DepthFrame frame){
  if(frame==null||frame.depth==null||!frame.deviceCalibrated)return false;
  int total=frame.depth.length;
  return total>0&&frame.plausibleCount>=scannerState().config.depthMinValidPixels&&frame.plausibleCount/(float)total>=scannerState().config.depthMinValidRatio;

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
  // Scan owns reconstruction from this point forward; the live detection cloud
  // remains a preview only and is replaced by the normal tracking/TSDF view.
  scannerState().showLiveDetectionCloud=false;
  scannerState().meshViewActive=false;
  // Waiting for the current ICP/TSDF state section must never block Processing's
  // UI thread. Reset and first-frame queueing are completed by a generation-owned worker.
  requestScannerReconstructionReset(true);
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
  if(scannerState().meshBusy){scannerState().status=scannerState().i18n.tr("status.mesh_busy");
    return;}
  if(scannerState().resetBusy)return;
  // Reset means "back to ready-to-scan": discard reconstruction and restore
  // the live depth point cloud instead of leaving the 3D viewport empty.
  scannerState().showLiveDetectionCloud=true;
  scannerState().meshViewActive=false;
  requestScannerReconstructionReset(false);
}

void requestScannerReconstructionReset(final boolean startAfterReset){
  ScannerModuleState s=scannerState();
  s.scanActive=false;s.scanPaused=false;clearPendingScanWork();
  s.resetBusy=true;final long generation=++s.resetGeneration;
  if(!startAfterReset)s.status=s.i18n.tr("status.scan_reset");
  studio.services.workers.startLowPriority("Scanner-Reconstruction-Reset",new Runnable(){public void run(){
    try{
      resetReconstructionState();
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

void resetReconstructionState() {
  synchronized (scannerState().reconstructionStateLock) {
    scannerState().integratedFrames = 0; scannerState().rejectedTrackingFrames = 0; scannerState().trackingState=ScannerModuleState.TRACK_WARMUP; scannerState().trackingGoodStreak=0; scannerState().trackingBadStreak=0; scannerState().trackingLossEvents=0; scannerState().lastSessionCheckpointFrame=0;
     scannerState().lockedObjectDepth = Float.NaN;
    scannerState().depthTarget.reset(); scannerState().cloudStats.clear(); scannerState().tracker.reset();
     if(scannerState().boundingBox!=null)scannerState().boundingBox.reset();
     if(scannerState().previewPointModel!=null)scannerState().previewPointModel.reset();
     scannerState().volumeInitialized = false;
    if(scannerState().hqArchive!=null)scannerState().hqArchive.clear(); scannerState().hqProgress=0;

    scannerState().latestRgbDepthSkewMs=Float.NaN; scannerState().rgbFinalized=false; scannerState().meshViewActive=false; scannerState().meshSourceIntegratedFrames=-1;
    scannerState().mesh = new Mesh3D(); scannerState().meshUndo = null; scannerState().meshUndoStack.clear(); scannerState().liveMesh = new Mesh3D(); scannerState().scanCoverage.reset();
    // Reconstruction reset never owns the viewport camera. The user's orbit,
    // pan and zoom survive Reset/Scan; middle-click remains the explicit view reset.

    scannerState().uiProgress=0.0f; scannerState().uiTargetDepthM=Float.NaN; scannerState().uiIcpRmsMm=Float.NaN; scannerState().uiScanQuality=0.0f;

    scannerState().uiScanComplete=false; scannerState().uiTrackingGood=false; scannerState().uiPreviewCloud=null; scannerState().autoFinalizePending=false;
    scannerState().pendingExport=scannerState().EXPORT_NONE;scannerState().deferredExportPrompt=scannerState().EXPORT_NONE;
    scannerState().lastIntegratedPose=null; scannerState().integrationIdleFrames=0; scannerState().lastLiveMeshBuildMs=0; scannerState().lastLiveMeshFrame=0;

  }
}

void buildMesh(){buildMesh(false);}
void buildMesh(boolean allowHighQuality) {
  ScannerModuleState state=scannerState();
  if (!scannerHasReconstructionInput()) { state.status = state.i18n.tr("status.no_volume"); return; }
  if (scannerExclusiveBusy()) { state.status = state.i18n.tr(state.exportBusy?"status.export_busy":"status.mesh_busy"); return; }

  boolean useHq=allowHighQuality&&state.config.hqEnabled&&state.hqArchive!=null&&state.hqArchive.size()>=state.config.hqMinimumKeyframes;
  // Mesh generation is a deterministic mode transition. Capture remains paused
  // after both realtime and HQ builds until the operator explicitly resumes it.
  final boolean wasCapturing=state.scanActive&&!state.scanPaused;
  // Generating a mesh is an explicit transition from acquisition preview to
  // editable geometry. Capture remains paused until the operator presses Resume.
  final boolean resumeCapture=false;
  if(wasCapturing){
    state.scanPaused=true;
    clearPendingScanWork();
    state.status=state.i18n.tr("status.mesh_processing");
  }
  startMeshTask(useHq?"build-hq":"build", null, resumeCapture);
}

void startMeshTask(final String operation, final Mesh3D source){startMeshTask(operation,source,false);}
void startMeshTask(final String operation, final Mesh3D source, final boolean resumeCapture){
  if(scannerState().meshBusy)return;scannerState().meshBusy=true;scannerState().status=scannerState().i18n.tr("status.mesh_processing");

  scannerState().meshThread=studio.services.workers.startLowPriority("Scanner-Mesh",new Runnable(){public void run(){
    try{
      // Barrier: let any already-running fusion frame leave the state section.
      synchronized(scannerState().reconstructionStateLock){}
      Mesh3D result;
      if("build-hq".equals(operation)){
        // Refine HQ is a true offline reconstruction: re-register retained
        // keyframes, reintegrate them at HQ resolution, then polish the result.
        // It must never be a disguised "polish current TSDF" operation.
        if(scannerState().hqArchive==null||scannerState().hqArchive.size()<scannerState().config.hqMinimumKeyframes)
          throw new IllegalStateException("Not enough HQ keyframes");
        result=scannerState().hqReconstructor.reconstruct(scannerState().hqArchive.snapshot(),true);
        if(result==null||result.triangleCount()==0)throw new IllegalStateException("HQ reconstruction produced no surface");
        result=scannerState().meshEditor.clean(result);
        if(scannerState().solidScanMode)result=scannerState().meshEditor.solidifyOpenSurface(result);
      }else if("build".equals(operation)){
        // Build Mesh always reconstructs from retained keyframes. The realtime
        // TSDF is a visualization/acquisition state and never becomes final mesh input.
        if(scannerState().hqArchive==null||scannerState().hqArchive.size()<scannerState().config.hqMinimumKeyframes)
          throw new IllegalStateException("Not enough retained keyframes");
        result=scannerState().hqReconstructor.reconstruct(scannerState().hqArchive.snapshot(),false);
        if(result==null||result.triangleCount()==0)throw new IllegalStateException("Offline mesh reconstruction produced no surface");
        if(scannerState().solidScanMode)result=scannerState().meshEditor.solidifyOpenSurface(result);
      }else if("clean".equals(operation)||"smooth".equals(operation)||"center".equals(operation)){
        // Mesh tools are valid on a partial reconstruction. If no explicit mesh
        // exists yet, take a coherent TSDF snapshot first; never require 360° coverage.
        Mesh3D editable=source;
        if(editable==null||editable.triangleCount()==0){
          Mesh3D raw=scannerState().volume.extractMesh(scannerState().config.meshMinWeight);
          editable=scannerState().meshEditor.prepareGeneratedMesh(raw);
        }
        if(editable==null||editable.triangleCount()==0)throw new IllegalStateException("No reconstructed surface is available yet");
        if("clean".equals(operation))result=scannerState().meshEditor.clean(editable);
        else if("smooth".equals(operation))result=scannerState().meshEditor.polish(editable);
        else result=scannerState().meshEditor.center(editable);
        if(scannerState().solidScanMode&&!"center".equals(operation))result=scannerState().meshEditor.solidifyOpenSurface(result);
      }else return;
      result.recalculateNormals();
      synchronized(scannerState().reconstructionStateLock){
        Mesh3D previous=scannerState().mesh;
        if(previous!=null&&previous.triangleCount()>0&&previous!=result){
          scannerState().meshUndoStack.addLast(previous.deepCopy());
          while(scannerState().meshUndoStack.size()>ScannerModuleState.MESH_UNDO_LIMIT)scannerState().meshUndoStack.removeFirst();
          scannerState().meshUndo=scannerState().meshUndoStack.peekLast();
        }
        scannerState().mesh=result;
        scannerState().meshViewActive=true;
        scannerState().meshSourceIntegratedFrames=scannerState().integratedFrames;
        scannerState().previewAutoFitRevision++;
        scannerState().previewUserAdjusted=false;
        // Both realtime TSDF and HQ meshes retain registered vertex color when
        // available. The frontend decides whether Texture or Solid displays it.
        scannerState().rgbFinalized=result.hasVertexColor();
        if(operation.startsWith("build"))scannerState().liveMesh=result;
      }
      if(operation.startsWith("build"))scannerState().status=scannerState().i18n.format("status.mesh_built",result.triangleCount());
      else if("clean".equals(operation))scannerState().status=scannerState().i18n.format("status.mesh_clean",source==null?0:source.triangleCount(),result.triangleCount());
      else if("smooth".equals(operation))scannerState().status=scannerState().i18n.format("status.mesh_polished",scannerState().config.meshPolishIterations);
      else scannerState().status=scannerState().i18n.tr("status.mesh_center");
      if(operation.startsWith("build")&&scannerState().pendingExport!=scannerState().EXPORT_NONE){scannerState().deferredExportPrompt=scannerState().pendingExport;scannerState().pendingExport=scannerState().EXPORT_NONE;}

    }catch(Exception e){scannerState().status=scannerState().i18n.format("status.mesh_failed",safeExceptionMessage(e));println(scannerState().status);e.printStackTrace();}

    finally{if(resumeCapture&&scannerState().scanActive)scannerState().scanPaused=false;scannerState().meshBusy=false;scannerState().meshThread=null;}
  }});
}


void toggleScannerSurfaceMode(){
  ScannerModuleState state=scannerState();state.solidScanMode=!state.solidScanMode;
  state.status=state.i18n.tr(state.solidScanMode?"status.surface_solid":"status.surface_texture");
  if(scannerHasFusedSurface()&&!state.meshBusy)buildMesh(false);
}

void requestExport(int type) {
  ScannerModuleState state=scannerState();
  if(state.meshBusy){state.status=state.i18n.tr("status.mesh_busy");return;}
  if(state.exportBusy){state.status=state.i18n.tr("status.export_busy");return;}
  if(state.mesh==null||state.mesh.triangleCount()==0||state.meshSourceIntegratedFrames<state.integratedFrames){state.pendingExport=type;buildMesh();return;}
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
  float coverageFraction=coverage==null?0:coverage.coverageFraction();
  float sweepDeg=coverage==null?0:coverage.sweepDeg;
  boolean complete=coverage!=null&&coverage.complete;
  PVector center=mesh==null?new PVector():mesh.boundsCenter();
  float radius=mesh==null?0:mesh.boundsRadius();
  PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(sidecar)));
  try{
    out.println("{");
    out.println("  \"schema\": \"synkinect-scan-export-v2\",");
    out.println("  \"format\": \""+type+"\",");
    out.println("  \"partial\": "+(!complete)+",");
    out.println("  \"coverage\": "+coverageFraction+",");
    out.println("  \"sweepDeg\": "+sweepDeg+",");
    out.println("  \"integratedFrames\": "+scannerState().integratedFrames+",");
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

void saveScannerRecoveryCheckpoint(){
  ScannerModuleState s=scannerState();if(!s.volumeInitialized||s.volume==null)return;
  File dir=studio.services.paths.dataDirectory("scanner","sessions","sessions");
  File tmp=new File(dir,"recovery.remoldscan.tmp"),dst=new File(dir,"recovery.remoldscan");
  DataOutputStream out=null;try{out=new DataOutputStream(new BufferedOutputStream(new FileOutputStream(tmp)));
    out.writeInt(0x524D5343);out.writeInt(1);out.writeInt(s.volume.n);out.writeFloat(s.volume.voxelSize);out.writeFloat(s.volume.truncation);
    out.writeFloat(s.volume.origin.x);out.writeFloat(s.volume.origin.y);out.writeFloat(s.volume.origin.z);out.writeLong(s.integratedFrames);out.writeLong(s.rejectedTrackingFrames);out.writeLong(s.trackingLossEvents);
    out.writeInt(s.volume.touchedCount);for(int i=0;i<s.volume.touchedCount;i++){int id=s.volume.touched[i];out.writeInt(id);out.writeShort(s.volume.tsdf[id]);out.writeByte(s.volume.weight[id]);out.writeInt(s.volume.rgb[id]);out.writeByte(s.volume.rgbWeight[id]);}
    out.flush();out.close();out=null;if(dst.exists()&&!dst.delete())throw new IOException("Cannot replace recovery session");if(!tmp.renameTo(dst))throw new IOException("Cannot commit recovery session");
  }catch(Exception e){println("Scanner recovery checkpoint: "+safeExceptionMessage(e));}finally{if(out!=null)try{out.close();}catch(Exception ignored){}if(tmp.exists()&&dst.exists())tmp.delete();}
}

void runPartialMeshTool(String operation) {
  ScannerModuleState state=scannerState();
  if(state.meshBusy){state.status=state.i18n.tr("status.mesh_busy");return;}
  Mesh3D source=state.mesh;
  if(source!=null&&state.meshSourceIntegratedFrames<state.integratedFrames)source=null;
  if((source==null||source.triangleCount()==0)&&!scannerHasFusedSurface()){state.status=state.i18n.tr("status.mesh_required");return;}
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

boolean scannerHasFusedSurface(){
  ScannerModuleState state=scannerState();
  return state.volumeInitialized&&state.integratedFrames>0;
}
boolean scannerHasReconstructionInput(){
  ScannerModuleState state=scannerState();
  return scannerHasFusedSurface()||(state.hqArchive!=null&&state.config!=null&&state.hqArchive.size()>=state.config.hqMinimumKeyframes);
}
boolean scannerHasMesh(){
  Mesh3D mesh=scannerState().mesh;
  return mesh!=null&&mesh.triangleCount()>0;
}
boolean scannerHasEditableGeometry(){return scannerHasMesh()||scannerHasFusedSurface();}

boolean scannerActionAllowed(int action){
  ScannerModuleState state=scannerState();
  boolean calibration=scannerCalibrationActive();

  // Pause/resume is a capture safety control and stays available for an active
  // scan unless a reset is currently replacing reconstruction state.
  if(action==state.ui.ACTION_START&&state.scanActive)
    return !state.resetBusy&&!state.meshBusy&&!state.exportBusy&&!state.hqBusy;

  if(state.resetBusy||state.meshBusy||state.exportBusy||state.hqBusy)return false;
  if(action==state.ui.ACTION_CALIBRATE)
    return state.config.calibrationEnabled&&!state.scanActive&&state.latestDepth!=null&&!state.autoFinalizePending;
  if(calibration)return false;

  if(action==state.ui.ACTION_START){
    KinectDevice d=studio.selectedKinect();
    return !state.autoFinalizePending&&d!=null&&d.cameraReady()&&d.hasCapability("depth")
      &&state.latestDepth!=null&&state.latestPair!=null&&state.latestDepth.deviceCalibrated
      &&state.latestDepthDiagnostics!=null&&state.latestDepthDiagnostics.healthy(state.config);
  }

  // Reset and surface mode do not require a reconstruction. Reset is always a
  // valid transition once no destructive background task is active.
  if(action==state.ui.ACTION_RESET||action==state.ui.ACTION_SURFACE_MODE)return true;
  if(action==state.ui.ACTION_MESH)return scannerHasReconstructionInput();
  if(action==state.ui.ACTION_HQ)return state.config.hqEnabled&&state.hqArchive!=null&&
    state.hqArchive.size()>=state.config.hqMinimumKeyframes;
  if(action==state.ui.ACTION_CLEAN||action==state.ui.ACTION_SMOOTH||action==state.ui.ACTION_CENTER)
    return scannerHasEditableGeometry();
  if(action==state.ui.ACTION_UNDO)return !state.meshUndoStack.isEmpty();
  if(action==state.ui.ACTION_STL||action==state.ui.ACTION_OBJ||action==state.ui.ACTION_PLY)
    return scannerHasEditableGeometry();
  return false;
}

void scannerActionBlockedStatus(int action){
  ScannerModuleState state=scannerState();
  if(state.resetBusy){state.status=state.i18n.tr("status.scan_reset");return;}
  if(state.exportBusy){state.status=state.i18n.tr("status.export_busy");return;}
  if(state.meshBusy){state.status=state.i18n.tr("status.mesh_busy");return;}
  if(state.hqBusy){
    int pct=round(constrain(state.hqProgress,0,1)*100.0f);
    state.status=state.i18n.format("status.hq_refining",pct);return;
  }
  if(scannerCalibrationActive()&&action!=state.ui.ACTION_CALIBRATE){
    state.status=state.i18n.tr("status.calibration_stop_scan");return;
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
  if(action==state.ui.ACTION_MESH){state.status=state.i18n.tr("status.no_volume");return;}
  if(action==state.ui.ACTION_CLEAN||action==state.ui.ACTION_SMOOTH||action==state.ui.ACTION_CENTER||
     action==state.ui.ACTION_STL||action==state.ui.ACTION_OBJ||action==state.ui.ACTION_PLY){
    state.status=state.i18n.tr("status.mesh_required");return;
  }
}

void dispatchUiAction(int action) {
  if(!scannerActionAllowed(action)){scannerActionBlockedStatus(action);return;}
  if(action==scannerState().ui.ACTION_START)toggleScanControl();
  else if(action==scannerState().ui.ACTION_RESET)resetScan();
  else if(action==scannerState().ui.ACTION_SURFACE_MODE)toggleScannerSurfaceMode();
  else if(action==scannerState().ui.ACTION_MESH)buildMesh(false);
  else if(action==scannerState().ui.ACTION_HQ)buildMesh(true);
  else if(action==scannerState().ui.ACTION_STL)requestExport(scannerState().EXPORT_STL);
  else if(action==scannerState().ui.ACTION_OBJ)requestExport(scannerState().EXPORT_OBJ);
  else if(action==scannerState().ui.ACTION_PLY)requestExport(scannerState().EXPORT_PLY);
  else if(action==scannerState().ui.ACTION_CLEAN)cleanMesh();
  else if(action==scannerState().ui.ACTION_SMOOTH)smoothMesh();
  else if(action==scannerState().ui.ACTION_CENTER)centerMesh();
  else if(action==scannerState().ui.ACTION_UNDO)undoMeshEdit();
  else if(action==scannerState().ui.ACTION_CALIBRATE)toggleDepthCalibration();
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
    // Reconstruction is latency-sensitive. When capture outruns fusion, retain
    // a bounded window containing the most recent frames to keep latency low.
    while(scannerState().reconstructionQueue.size()>=scannerState().config.reconstructionQueueFrames){
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
boolean shouldIntegrateScannerPose(RigidTransform pose){
  ScannerModuleState state=scannerState();
  if(pose==null)return false;
  if(state.lastIntegratedPose==null)return true;
  float translation=rigidTranslationDelta(state.lastIntegratedPose,pose);
  float rotation=rigidRotationDeltaDeg(state.lastIntegratedPose,pose);
  state.integrationIdleFrames++;
  boolean moved=translation>=state.config.integrationMinTranslationM||rotation>=state.config.integrationMinRotationDeg;
  boolean refresh=state.integrationIdleFrames>=state.config.integrationMaxIdleFrames;
  return moved||refresh;
}
void commitIntegratedScannerPose(RigidTransform pose){
  if(pose==null)return;
  ScannerModuleState state=scannerState();
  if(state.lastIntegratedPose==null)state.lastIntegratedPose=new RigidTransform();
  state.lastIntegratedPose.set(pose);
  state.integrationIdleFrames=0;
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
  DepthFrame depthFrame=pair==null?null:pair.depth;
  if (!scannerState().scanActive || scannerState().scanPaused || depthFrame == null || !scannerState().calibration.valid) return;

  if (!depthFrameHealthy(depthFrame)) return;

  synchronized (scannerState().reconstructionStateLock) {
    if (!scannerState().scanActive || scannerState().scanPaused) return;
    scannerState().scanCoverage.updateImu(depthFrame.motion);
    scannerState().uiProgress=scannerState().scanCoverage.trackingProgress();
    scannerState().uiScanComplete=scannerState().scanCoverage.complete;
    if (!scannerState().scanCoverage.imuStable) {
      scannerState().rejectedTrackingFrames++; scannerState().status = scannerState().i18n.format("status.sensor_moved", scannerState().scanCoverage.imuDeviationDeg);
       return;
    }

    boolean detectorReady=scannerState().depthTarget.update(depthFrame);
    boolean boxLocked=scannerState().boundingBox!=null&&scannerState().boundingBox.locked;
    scannerState().lockedObjectDepth=scannerState().depthTarget.depthM;
    scannerState().uiTargetDepthM=scannerState().lockedObjectDepth;
    // The depth detector acquires the object only until the metric Bounding Box
    // is locked. After that, the box is authoritative and normal front/back
    // depth changes caused by rotation must not drop tracking.
    boolean targetReady=boxLocked||(detectorReady&&!Float.isNaN(scannerState().lockedObjectDepth));
    scannerState().scanCoverage.updateDetection(targetReady);
    if(!targetReady){
      scannerState().cloudStats.clear();
      scannerState().status=scannerState().i18n.tr("status.target_acquiring");
      return;
    }

    // Bounding-box turntable mode: decode synchronized RGB only when Color-ICP
    // is enabled. Geometry remains authoritative; missing RGB falls back cleanly.
    RgbSnapshot trackingRgb=scannerState().config.colorIcpEnabled?scannerState().source.rgbReconstructionSnapshot(pair):null;
    float trackingTargetZ=boxLocked?Float.NaN:scannerState().lockedObjectDepth;
    float trackingBand=boxLocked?Float.POSITIVE_INFINITY:scannerState().depthTarget.bandM;
    PointCloud trackingCloud=scannerState().pointCloudBuilder.build(depthFrame,scannerState().calibration,scannerState().config.pointStep,trackingTargetZ,
       trackingBand,scannerState().cloudStats,trackingRgb);
    if(scannerState().boundingBox!=null)trackingCloud=scannerState().boundingBox.filter(trackingCloud,true);
    if (trackingCloud.size() < scannerState().config.minimumTrackingPoints) {
      scannerState().scanCoverage.updateDetection(false); scannerState().rejectedTrackingFrames++;
       scannerState().status = scannerState().i18n.format("status.cloud_sparse", trackingCloud.size());
       return;
    }
    scannerState().scanCoverage.updateDetection(true);

    RigidTransform pose = scannerState().tracker.track(trackingCloud, depthFrame.motion);

    scannerState().uiTrackingGood=scannerState().tracker.trackingGood;
    scannerState().uiIcpRmsMm=scannerState().tracker.trackingGood?scannerState().tracker.rms*1000.0f:Float.NaN;

    scannerState().uiScanQuality=scannerFrameQuality(pair,trackingCloud);
    if (!scannerTrackingGate(scannerState().tracker.trackingGood)) { scannerState().rejectedTrackingFrames++;
       scannerState().status = scannerState().i18n.format("status.icp_wait", scannerState().tracker.matches)+" ["+scannerTrackingStateName()+"]";
       return; }

    // Continuous angular tracking must not depend on TSDF acceptance.
    scannerState().scanCoverage.updateTracking(pose,depthFrame.motion,scannerState().tracker.lastTrackedYawStepDeg);
    scannerState().uiProgress=scannerState().scanCoverage.trackingProgress();

    // Fusion uses the same isolated volume. Color may be present for tracking
    // correspondence weights, but TSDF geometry remains depth-driven.
    RgbSnapshot rgb=trackingRgb;
    boolean rebuildFusion=scannerState().config.integrationPointStep!=scannerState().config.pointStep;
    PointCloud fusionCloud=rebuildFusion
      ? scannerState().pointCloudBuilder.build(depthFrame,scannerState().calibration,scannerState().config.integrationPointStep,trackingTargetZ,
       trackingBand,null,rgb)
      : trackingCloud;
    if(rebuildFusion&&scannerState().boundingBox!=null)fusionCloud=scannerState().boundingBox.filter(fusionCloud,false);
    // Preview remains point-based during capture. The current ICP-aligned frame
    // is composited over the accumulated accepted point model so the operator
    // can see registration quality and reconstruction growth in real time.
    PointCloud displayCloud=(rebuildFusion?fusionCloud:trackingCloud).transformed(pose,scannerState().config.previewPointTransientMaxPoints);
    scannerState().uiPreviewCloud=scannerState().previewPointModel==null
      ?displayCloud:scannerState().previewPointModel.snapshotWithTransient(displayCloud);
    boolean acceptedFusion=false;
    if (shouldIntegrateScannerPose(pose)) {
      if (!scannerState().volumeInitialized) { scannerState().volume.resetAroundCloud(fusionCloud,pose,scannerState().config);
         scannerState().volumeInitialized = true; }
      // Confidence-weighted live refinement. Frames that barely pass tracking no
      // longer have the same authority as clean, well-aligned observations.
      float fusionQ=constrain((scannerState().uiScanQuality-scannerState().config.fusionMinimumFrameQuality)/
        max(0.01f,scannerState().config.fusionFullWeightQuality-scannerState().config.fusionMinimumFrameQuality),0,1);
      if(scannerState().uiScanQuality>=scannerState().config.fusionMinimumFrameQuality){
        float[] surface=scannerState().volume.surfaceConsistency(fusionCloud,pose,scannerState().config);
        float[] referenceCheck=scannerState().tracker.fusionReferenceConsistency(trackingCloud,pose);
        boolean enoughKnown=surface[0]>=scannerState().config.fusionSurfaceMinKnownRatio;
        boolean surfaceOk=!enoughKnown||(surface[1]>=scannerState().config.fusionSurfaceMinAgreement&&surface[2]<=scannerState().config.fusionSurfaceMaxResidualM);
        boolean enoughReference=referenceCheck[0]>=scannerState().config.fusionReferenceMinOverlap;
        boolean referenceOk=!enoughReference||referenceCheck[1]<=scannerState().config.fusionReferenceMaxRmsM;
        if(surfaceOk&&referenceOk){
          int fusionStride=fusionQ<0.45f?scannerState().config.fusionLowQualityStride:1;
          scannerState().volume.integrate(fusionCloud, pose, fusionStride, true, max(0.20f,fusionQ));
          scannerState().integratedFrames++; scannerState().rgbFinalized=false;
          commitIntegratedScannerPose(pose);
          // Only accepted TSDF geometry advances the anti-ghosting history.
          scannerState().tracker.acceptFusionReference(trackingCloud,pose);
          scannerState().scanCoverage.confirmFusion();
          if(scannerState().previewPointModel!=null){
            scannerState().previewPointModel.integrate(fusionCloud,pose);
            scannerState().uiPreviewCloud=scannerState().previewPointModel.snapshotWithTransient(displayCloud);
          }
          acceptedFusion=true;
        }else{
          scannerState().rejectedTrackingFrames++;
          scannerState().status="Surface conflict: frame rejected (TSDF "+nf(surface[1]*100.0f,1,0)+"%, ref "+nf(referenceCheck[0]*100.0f,1,0)+"% / "+nf(referenceCheck[1]*1000.0f,1,1)+" mm)";
        }
      } else { scannerState().rejectedTrackingFrames++; }
      if(scannerState().integratedFrames-scannerState().lastSessionCheckpointFrame>=150){scannerState().lastSessionCheckpointFrame=scannerState().integratedFrames;saveScannerRecoveryCheckpoint();}
    }
    scannerState().uiProgress=scannerState().scanCoverage.trackingProgress();
    scannerState().uiScanComplete=scannerState().scanCoverage.complete;
    // The offline archive is intentionally broader than the live TSDF. A frame
    // rejected from realtime fusion can still contain excellent depth data with
    // a recoverable pose; Build Mesh / Refine HQ globally re-register it later.
    if(scannerState().hqArchive!=null&&trackingCloud.size()>=scannerState().config.minimumTrackingPoints&&scannerState().uiScanQuality>=0.18f)
      scannerState().hqArchive.offer(pair,pair.hq!=null?pair.hq:scannerState().source.bestHqRgbFor(depthFrame.timestampUs),pose,scannerState().lockedObjectDepth,
      scannerState().depthTarget.bandM,scannerState().scanCoverage.sweepDeg);

    if (scannerState().scanCoverage.complete && scannerState().config.autoPauseOnFullTurn) {
      scannerState().scanPaused=true;scannerState().scanActive=false;clearPendingScanWork();
      if(scannerState().previewPointModel!=null)scannerState().uiPreviewCloud=scannerState().previewPointModel.snapshot();
      scannerState().status=scannerState().i18n.format("status.full_turn",scannerState().scanCoverage.sweepDeg);
      // Completion preserves the registered point cloud. Mesh generation is an
      // explicit operator action (Build Mesh / Refine HQ), never an automatic
      // visual mode switch.
      scannerState().autoFinalizePending=false;
    } else {
      float pct=scannerState().scanCoverage.progress()*100.0f;
      if(scannerState().config.hqEnabled&&scannerState().hqArchive!=null){int k=scannerState().hqArchive.size();
        long mb=scannerState().hqArchive.estimatedBytes()/(1024L*1024L);scannerState().status=scannerState().i18n.format("status.scanning_hq",pct,k,mb);
        }
      else scannerState().status = scannerState().i18n.format("status.scanning", pct);

    }
  }
}

void refreshLiveScannerMeshLocked(){refreshLiveScannerMeshLocked(false);}
void refreshLiveScannerMeshLocked(boolean force) {
  ScannerModuleState state=scannerState();
  if(state.scanActive&&!force)return;
  if(!state.volumeInitialized||state.volume==null||state.integratedFrames<=0)return;
  long now=millis();
  if(!force&&state.lastLiveMeshBuildMs>0&&now-state.lastLiveMeshBuildMs<state.config.previewMeshRefreshMs)return;
  if(!force&&state.lastLiveMeshFrame>0&&state.integratedFrames-state.lastLiveMeshFrame<state.config.previewMeshRefreshFrames)return;
  Mesh3D preview=state.volume.extractMesh(state.config.previewMeshMinWeight,state.config.previewMeshMaxTriangles);
  if(preview!=null&&preview.triangleCount()>0){
    preview.recalculateNormals();
    state.liveMesh=preview;
  }
  state.lastLiveMeshBuildMs=now;
  state.lastLiveMeshFrame=state.integratedFrames;
}

String safeExceptionMessage(Exception e) {
  String m = e.getMessage(); return (m == null || m.length() == 0) ? e.getClass().getSimpleName() : m;

}


// ===== SynKinect Studio / 3D Scanner / AppConfig.pde =====
class AppConfig {
  int uiFrameRate = 30;
  int workerJoinMs = 1500;

  int pointStep = 3;
  int integrationPointStep = 2;
  int minimumTrackingPoints = 220;
  // Real-time fusion refinement: weak/noisy frames contribute less to TSDF
  // instead of being allowed to roughen an otherwise stable surface.
  float fusionMinimumFrameQuality = 0.38f;
  float fusionFullWeightQuality = 0.78f;
  int fusionLowQualityStride = 2;
  // Surface-consistency gate: once the TSDF has evidence at a location, a new
  // frame must agree with that surface before it is allowed to add another shell.
  float fusionSurfaceMinKnownRatio = 0.12f;
  float fusionSurfaceMinAgreement = 0.68f;
  float fusionSurfaceMaxResidualM = 0.0045f;
  float fusionSurfaceAgreementBandM = 0.006f;
  int fusionSurfaceMinWeight = 2;
  float fusionReferenceMinOverlap = 0.12f;
  float fusionReferenceMaxRmsM = 0.012f;

  float minDepthM = 0.20f;
  float maxDepthM = 4.50f;

  // Metric depth intrinsics are externalized so scanner geometry can be tuned
  // without changing source when a calibrated Kinect profile is available.
  float depthFx = 594.2143421192325f;
  float depthFy = 591.0405369687078f;
  float depthCx = 339.30780975300314f;
  float depthCy = 242.73913761751615f;
  float depthScale = 0.001f;

  float objectDepthBandM = 0.20f;
  float maxObjectDepthBandM = 0.34f;
  float depthTargetSmoothing = 0.12f;
  float depthTargetStableToleranceM = 0.12f;
  float depthTargetMaxJumpM = 0.24f;
  int depthTargetStableFrames = 3;
  int depthTargetLostFramesForReacquire = 6;
  int depthTargetMinSamples = 80;
  float depthTargetMinConfidence = 0.040f;
  int depthHistogramBinMm = 20;
  float depthRoiLeft = 0.24f;
  float depthRoiRight = 0.76f;
  float depthRoiTop = 0.20f;
  float depthRoiBottom = 0.80f;
  int depthRoiSampleStep = 2;
  float depthPreferredTargetWindowM = 0.30f;
  // Foreground segmentation is deliberately narrower than the raw depth range.
  // A Kinect scan should lock one coherent object, not merge the support/table
  // or a distant wall simply because both happen to fall inside a broad Z band.
  float depthBandSpreadMultiplier = 1.80f;
  float targetSegmentationMargin = 0.10f;

  // Turntable scanning is volume-of-interest tracking. The first valid target
  // locks a metric 3D box in camera space; background outside it never reaches ICP.
  boolean boundingBoxEnabled = true;
  float boundingBoxMarginM = 0.045f;
  float boundingBoxDepthMarginM = 0.035f;
  float boundingBoxBaseExtraM = 0.075f;
  float boundingBoxMinWidthM = 0.24f;
  float boundingBoxMinHeightM = 0.24f;
  float boundingBoxMinDepthM = 0.16f;
  float boundingBoxMaxWidthM = 0.90f;
  float boundingBoxMaxHeightM = 1.20f;
  float boundingBoxMaxDepthM = 0.70f;
  float boundingBoxCenterFollowAlpha = 0.015f;
  float boundingBoxMaxCenterCorrectionM = 0.035f;
  int boundingBoxMinPoints = 140;


  int depthMinValidPixels = 1200;
  float depthMinValidRatio = 0.004f;
  int depthPlausibleMinMm = 180;
  int depthPlausibleMaxMm = 6000;
  long streamStaleTimeoutMs = 1200;
  long connectionStaleTimeoutMs = 2500;
  int reconnectDelayMs = 250;
  int captureDrainFramesPerDraw = 8;
  int reconstructionQueueFrames = 3;
  int reconstructionMaxFps = 8;

  boolean pointCloudSpatialFilter = true;
  float pointCloudNeighborToleranceM = 0.045f;
  float pointCloudMinimumConfidence = 0.18f;
  float pointCloudEdgeSoftM = 0.010f;
  float pointCloudEdgeRejectM = 0.026f;
  float pointCloudSurfaceNoiseM = 0.012f;
  float pointCloudMinimumSupport = 0.55f;
  boolean pointCloudConnectedTarget = true;
  int pointCloudComponentMinSamples = 70;
  float pointCloudComponentDepthLinkM = 0.045f;
  float pointCloudComponentBorderPenalty = 0.42f;

  // Stable Scanner viewport auto-fit. Expansion is allowed relatively quickly
  // so geometry is never clipped; zoom-in and recentering are intentionally
  // slow/dead-banded to prevent frame-by-frame breathing.
  float previewAutoFitZoomOutResponse = 0.14f;
  float previewAutoFitZoomInResponse = 0.022f;
  float previewAutoFitCenterResponse = 0.050f;
  float previewAutoFitDeadband = 0.070f;
  int previewAutoFitShrinkDelayFrames = 24;

  int volumeSize = 160;
  float voxelSizeM = 0.0045f;
  float truncationM = 0.022f;
  int meshMinWeight = 2;
  int previewMeshMinWeight = 2;
  int previewMeshRefreshFrames = 6;
  int previewMeshRefreshMs = 350;
  int previewMeshMaxTriangles = 90000;
  // Capture preview uses a persistent ICP-registered point model instead of a
  // periodically extracted textured mesh.
  float previewPointVoxelM = 0.0040f;
  int previewPointMaxPoints = 90000;
  int previewPointDisplayMaxPoints = 52000;
  int previewPointTransientMaxPoints = 6500;

  int icpIterations = 9;
  int icpMinimumMatches = 50;
  float icpCellSizeM = 0.075f;
  float icpMaxDistanceM = 0.075f;
  float icpFinalDistanceM = 0.024f;
  int icpMaxSamples = 4200;
  float icpGoodRmsM = 0.045f;
  int icpReferenceFrames = 4;
  int icpReferenceMaxPoints = 9000;
  float icpTrimFraction = 0.72f;
  float icpMinimumOverlap = 0.24f;
  float icpRobustK = 0.65f;
  boolean icpReciprocal = true;
  float icpReciprocalToleranceM = 0.015f;
  float icpMaxTranslationStepM = 0.12f;
  float icpMaxRotationStepDeg = 32.0f;
  boolean turntableTracking = true;
  // ICP always composes the complete SE(3) pose. Turntable yaw search is only
  // an initialization aid and never replaces the converged rigid transform.
  float turntableMaxSeedYawDeg = 36.0f;
  float turntableCoarseStepDeg = 4.0f;
  float turntableFineStepDeg = 0.75f;
  float turntableMotionAlpha = 0.48f;
  float turntablePredictionWeight = 0.22f;
  float turntableSeedMinGain = 0.004f;
  float turntableSeedMinimumConfidence = 0.10f;
  float turntableSeedPoseAuthority = 0.72f;
  float turntableSeedMinTrackedYawDeg = 0.10f;
  float turntableVelocityClampDeg = 10.0f;
  float turntablePivotAlpha = 0.0f;
  float turntableConstrainedEvaluationM = 0.040f;
  boolean turntablePoseConstraint = true;
  float turntableConstraintScoreSlack = 0.12f;
  float turntableConstraintTranslationM = 0.006f;
  float turntableConstraintTranslationAuthority = 0.18f;
  // Y variation carries little information about yaw. Keep it for 6DoF ICP,
  // but strongly down-weight it while choosing the turntable yaw seed.
  float turntableVerticalResidualWeight = 0.16f;
  // Photometric evidence is a correspondence weight, never a replacement for
  // metric geometry. Missing/unsynchronised RGB automatically falls back to depth ICP.
  boolean colorIcpEnabled = true;
  float colorIcpWeight = 0.28f;
  float colorIcpRejectDistance = 0.62f;
  float colorIcpMinimumWeight = 0.22f;

  float integrationMinTranslationM = 0.0015f;
  float integrationMinRotationDeg = 0.55f;
  int integrationMaxIdleFrames = 4;
  int scanCoverageBins = 72;
  float scanCoverageRequired = 0.98f;
  boolean volumeAutoFit = true;
  float volumeAutoFitPadding = 1.15f;
  float volumeMaxVoxelSizeM = 0.008f;

  // High-quality offline reconstruction. Realtime fusion remains the responsive
  // preview; final mesh generation can re-register retained keyframes and
  // re-integrate them at higher spatial resolution.
  boolean hqEnabled = true;
  int hqMaxKeyframes = 160;
  int hqFinalizeMaxKeyframes = 96;
  float hqKeyframeMinRotationDeg = 2.0f;
  float hqKeyframeMinTranslationM = 0.004f;
  int hqMinimumKeyframes = 12;
  int hqIntegrationStep = 1;
  int hqVolumeSize = 224;
  float hqVoxelSizeM = 0.0023f;
  float hqTruncationM = 0.009f;
  int hqMeshMinWeight = 3;
  int hqIcpIterations = 12;
  int hqIcpMaxSamples = 12000;
  int hqIcpMinimumMatches = 220;
  float hqIcpMaxDistanceM = 0.030f;
  float hqIcpTrimFraction = 0.78f;
  float hqIcpGoodRmsM = 0.012f;
  boolean hqGlobalRecovery = true;
  int hqGlobalRecoveryPasses = 3;
  int hqGlobalRecoveryNeighborFrames = 5;
  float hqGlobalRecoveryCoarseDistanceM = 0.070f;
  float hqGlobalRecoveryFineDistanceM = 0.026f;
  float hqGlobalRecoveryMaxTranslationM = 0.16f;
  float hqGlobalRecoveryMaxRotationDeg = 32.0f;
  float hqGlobalRecoveryMinSupport = 0.28f;
  float hqGlobalRecoveryMaxRmsM = 0.016f;
  boolean hqLoopClosure = true;
  float hqLoopClosureMaxRmsM = 0.018f;
  // Turntable-specific offline reconstruction. The sweep angle is treated as a
  // strong geometric prior, while reliable ICP evidence is still allowed to
  // correct small axis/pivot errors. Weak scans are rejected instead of being
  // allowed to create a second shell in the final TSDF.
  boolean hqTurntableConsensus = true;
  float hqTurntableAxisAuthority = 0.82f;
  float hqTurntableRescueMinSupport = 0.38f;
  float hqTurntableRescueMaxRmsM = 0.011f;
  float hqTurntableRecoveredFramePenalty = 0.45f;
  int hqDepthFilterRadius = 2;
  float hqDepthEdgeToleranceM = 0.028f;
  int hqHoleFillMinimumNeighbors = 12;
  boolean hqDistanceWeightedTsdf = true;
  // Multi-frame depth super-resolution. Neighboring keyframes are reprojected
  // into a supersampled anchor view after pose refinement, then fused with
  // confidence weighting, robust outlier rejection and foreground z-buffering.
  boolean hqDepthSuperResolution = true;
  int hqDepthSrScale = 2;
  int hqDepthSrWindowFrames = 5;
  int hqDepthSrAnchorStride = 2;
  float hqDepthSrMaxRotationDeg = 6.0f;
  float hqDepthSrMaxTranslationM = 0.030f;
  float hqDepthSrOcclusionToleranceM = 0.014f;
  float hqDepthSrOutlierToleranceM = 0.010f;
  int hqDepthSrMinimumViews = 2;
  int hqDepthSrMaxPoints = 420000;
  int hqMeshPolishIterations = 1;
  float hqMeshPolishLambda = 0.18f;
  float hqMeshPolishMu = -0.19f;

  boolean calibrationEnabled = true;
  int calibrationStations = 5;
  int calibrationFramesPerStation = 10;
  int calibrationMinimumStationsPerPixel = 3;
  float calibrationDistanceSeparationM = 0.16f;
  float calibrationStabilityToleranceM = 0.018f;
  float calibrationPlaneResidualMaxM = 0.030f;
  float calibrationSlopeMin = 0.92f;
  float calibrationSlopeMax = 1.08f;
  float calibrationOffsetMaxM = 0.060f;
  float calibrationNoiseFloorM = 0.0015f;
  float calibrationNoiseCeilingM = 0.030f;

  float scanFullTurnDeg = 360.0f;
  float scanCompleteDeg = 358.0f;
  float scanRotationDeadbandDeg = 0.08f;
  float scanRotationMaxStepDeg = 24.0f;
  float scanDirectionLockDeg = 2.0f;
  float scanTurnFilterAlpha = 0.38f;
  float scanReverseJitterDeg = 1.20f;
  float scanReverseCommitDeg = 3.0f;
  float scanDirectionRelockDeg = 14.0f;
  float scanMaxSensorTiltDriftDeg = 10.0f;
  boolean autoPauseOnFullTurn = true;
  boolean autoFinalizeOnFullTurn = false;

  float meshCleanupMaxEdgeM = 0.10f;
  float meshCleanupMinAreaM2 = 0.00000010f;
  float meshWeldToleranceM = 0.0010f;
  int meshSmoothIterations = 2;
  float meshSmoothLambda = 0.30f;
  int meshPolishIterations = 3;
  float meshPolishLambda = 0.22f;
  float meshPolishMu = -0.225f;
  boolean meshHoleFillEnabled = true;
  int meshHoleFillMaxEdges = 18;
  float meshHoleFillMaxDiameterM = 0.030f;
  float meshHoleFillMaxPerimeterM = 0.090f;
  int meshMinimumComponentTriangles = 32;
  float meshMinimumComponentRatio = 0.002f;
  boolean meshColorEnabled = true;

  // RGB/depth registration. The intrinsic/extrinsic defaults are a representative
  // Kinect Xbox 360 stereo calibration profile; every value remains externalized so a
  // per-device calibration can provide device-specific values from configuration.
  float rgbFx = 529.215081f, rgbFy = 525.563936f, rgbCx = 328.942720f, rgbCy = 267.480682f;

  float depthK1 = -0.263864f, depthK2 = 0.999668f, depthP1 = -0.000762f, depthP2 = 0.005035f, depthK3 = -1.305362f;

  float rgbK1 = 0.207966f, rgbK2 = -0.586138f, rgbP1 = 0.000722f, rgbP2 = 0.001048f, rgbK3 = 0.498570f;

  float regR00=0.9998463f, regR01=0.0012635f, regR02=-0.0174872f;
  float regR10=-0.0014779f, regR11=0.9999239f, regR12=-0.0122514f;
  float regR20=0.0174704f, regR21=0.0122753f, regR22=0.9997720f;
  float regTx=0.01998524f, regTy=-0.00074424f, regTz=-0.01091674f;
  float colorRegistrationOffsetX = 0.0f;
  float colorRegistrationOffsetY = 0.0f;
  float rgbMaxSyncSkewMs = 24.0f;
  int rgbdQueueFrames = 8;
  int rgbdSyncHistoryFrames = 10;
  float rgbdSyncMaxResidualMs = 24.0f;
  float rgbdSyncBootstrapMaxSkewMs = 180.0f;
  float rgbdSyncOffsetAlpha = 0.08f;
  boolean rgbOcclusionFilter = true;
  float rgbOcclusionToleranceM = 0.025f;
  boolean rgbAutoRefine = true;
  int rgbRefineEveryFrames = 8;
  int rgbRefineSearchPx = 4;
  int rgbRefineSampleStep = 10;
  int rgbRefineEdgeThresholdMm = 65;
  int rgbRefineMinimumEdges = 36;
  float rgbRefineAlpha = 0.12f;
  float rgbRefineMaxOffsetPx = 8.0f;
  int rgbExposureLowLuma = 24;
  int rgbExposureHighLuma = 235;
  int rgbTemporalColorWeightMax = 8;
  int rgbHqHistoryFrames = 8;
  float rgbHqMaxSyncSkewMs = 90.0f;
  float rgbHqMinimumFrameQuality = 0.22f;
  boolean rgbPhotometricNormalize = true;
  float rgbPhotometricGainMin = 0.72f;
  float rgbPhotometricGainMax = 1.38f;
  float rgbHqSharpenAmount = 0.16f;

  String exportBaseName = "SynKinectScan";
  float exportWeldToleranceM = 0.0010f;
  float exportMaxWeldToleranceM = 0.004f;
  int exportMaxTriangles = 600000;

  void load(File file) {
    Properties p=studio.services.configRules.load(file,"scanner");
      uiFrameRate = intValue(p, "ui.frameRate", uiFrameRate, 10, 120);
      workerJoinMs = intValue(p, "lifecycle.workerJoinMs", workerJoinMs, 250, 10000);

      pointStep = intValue(p, "cloud.previewStep", pointStep, 1, 16);
      integrationPointStep = intValue(p, "cloud.integrationStep", integrationPointStep, 1, 16);
      fusionMinimumFrameQuality = floatValue(p,"fusion.minimumFrameQuality",fusionMinimumFrameQuality,0.05f,0.90f);
      fusionFullWeightQuality = floatValue(p,"fusion.fullWeightQuality",fusionFullWeightQuality,fusionMinimumFrameQuality,1.0f);
      fusionLowQualityStride = intValue(p,"fusion.lowQualityStride",fusionLowQualityStride,1,6);
      fusionSurfaceMinKnownRatio = floatValue(p,"fusion.surfaceMinKnownRatio",fusionSurfaceMinKnownRatio,0.02f,0.90f);
      fusionSurfaceMinAgreement = floatValue(p,"fusion.surfaceMinAgreement",fusionSurfaceMinAgreement,0.10f,1.0f);
      fusionSurfaceMaxResidualM = floatValue(p,"fusion.surfaceMaxResidualM",fusionSurfaceMaxResidualM,0.002f,0.050f);
      fusionSurfaceAgreementBandM = floatValue(p,"fusion.surfaceAgreementBandM",fusionSurfaceAgreementBandM,0.003f,0.060f);
      fusionSurfaceMinWeight = intValue(p,"fusion.surfaceMinWeight",fusionSurfaceMinWeight,1,32);
      fusionReferenceMinOverlap = floatValue(p,"fusion.referenceMinOverlap",fusionReferenceMinOverlap,0.02f,0.80f);
      fusionReferenceMaxRmsM = floatValue(p,"fusion.referenceMaxRmsM",fusionReferenceMaxRmsM,0.003f,0.050f);

      minimumTrackingPoints = intValue(p, "tracking.minimumPoints", minimumTrackingPoints, 50, 20000);

      minDepthM = floatValue(p, "depth.minM", minDepthM, 0.10f, 9.0f);
      maxDepthM = floatValue(p, "depth.maxM", maxDepthM, minDepthM + 0.10f, 10.0f);

      depthFx = floatValue(p, "calibration.depth.fx", depthFx, 100.0f, 2000.0f);
      depthFy = floatValue(p, "calibration.depth.fy", depthFy, 100.0f, 2000.0f);
      depthCx = floatValue(p, "calibration.depth.cx", depthCx, 0.0f, studio.services.scannerProtocol.WIDTH);

      depthCy = floatValue(p, "calibration.depth.cy", depthCy, 0.0f, studio.services.scannerProtocol.HEIGHT);

      depthScale = floatValue(p, "calibration.depth.scale", depthScale, 0.00001f, 0.10f);

      objectDepthBandM = floatValue(p, "target.bandM", objectDepthBandM, 0.03f, 2.0f);

      maxObjectDepthBandM = floatValue(p, "target.maxBandM", maxObjectDepthBandM, objectDepthBandM, 3.0f);

      depthTargetSmoothing = floatValue(p, "target.smoothing", depthTargetSmoothing, 0.01f, 1.0f);

      depthTargetStableToleranceM = floatValue(p, "target.stableToleranceM", depthTargetStableToleranceM, 0.01f, 1.0f);

      depthTargetMaxJumpM = floatValue(p, "target.maxJumpM", depthTargetMaxJumpM, 0.05f, 3.0f);

      depthTargetStableFrames = intValue(p, "target.stableFrames", depthTargetStableFrames, 1, 60);

      depthTargetLostFramesForReacquire = intValue(p, "target.reacquireFrames", depthTargetLostFramesForReacquire, 1, 120);

      depthTargetMinSamples = intValue(p, "target.minimumSamples", depthTargetMinSamples, 16, 50000);

      depthTargetMinConfidence = floatValue(p, "target.minimumConfidence", depthTargetMinConfidence, 0.001f, 0.80f);

      depthHistogramBinMm = intValue(p, "depth.histogramBinMm", depthHistogramBinMm, 5, 200);

      depthRoiLeft = floatValue(p, "target.roi.left", depthRoiLeft, 0.0f, 0.90f);

      depthRoiRight = floatValue(p, "target.roi.right", depthRoiRight, depthRoiLeft + 0.05f, 1.0f);

      depthRoiTop = floatValue(p, "target.roi.top", depthRoiTop, 0.0f, 0.90f);
      depthRoiBottom = floatValue(p, "target.roi.bottom", depthRoiBottom, depthRoiTop + 0.05f, 1.0f);

      depthRoiSampleStep = intValue(p, "target.roi.sampleStep", depthRoiSampleStep, 1, 8);

      depthPreferredTargetWindowM = floatValue(p, "target.preferredWindowM", depthPreferredTargetWindowM, 0.05f, 3.0f);
      depthBandSpreadMultiplier = floatValue(p,"target.bandSpreadMultiplier",depthBandSpreadMultiplier,1.0f,3.0f);
      targetSegmentationMargin = floatValue(p,"target.segmentationMargin",targetSegmentationMargin,0.0f,0.30f);
      boundingBoxEnabled = boolValue(p,"tracking.boundingBox.enabled",boundingBoxEnabled);
      boundingBoxMarginM = floatValue(p,"tracking.boundingBox.marginM",boundingBoxMarginM,0.005f,0.30f);
      boundingBoxDepthMarginM = floatValue(p,"tracking.boundingBox.depthMarginM",boundingBoxDepthMarginM,0.005f,0.30f);
      boundingBoxBaseExtraM = floatValue(p,"tracking.boundingBox.baseExtraM",boundingBoxBaseExtraM,0.0f,0.30f);
      boundingBoxMinWidthM = floatValue(p,"tracking.boundingBox.minWidthM",boundingBoxMinWidthM,0.05f,2.0f);
      boundingBoxMinHeightM = floatValue(p,"tracking.boundingBox.minHeightM",boundingBoxMinHeightM,0.05f,2.0f);
      boundingBoxMinDepthM = floatValue(p,"tracking.boundingBox.minDepthM",boundingBoxMinDepthM,0.05f,2.0f);
      boundingBoxMaxWidthM = floatValue(p,"tracking.boundingBox.maxWidthM",boundingBoxMaxWidthM,boundingBoxMinWidthM,3.0f);
      boundingBoxMaxHeightM = floatValue(p,"tracking.boundingBox.maxHeightM",boundingBoxMaxHeightM,boundingBoxMinHeightM,3.0f);
      boundingBoxMaxDepthM = floatValue(p,"tracking.boundingBox.maxDepthM",boundingBoxMaxDepthM,boundingBoxMinDepthM,3.0f);
      boundingBoxCenterFollowAlpha = floatValue(p,"tracking.boundingBox.centerFollowAlpha",boundingBoxCenterFollowAlpha,0.0f,0.15f);
      boundingBoxMaxCenterCorrectionM = floatValue(p,"tracking.boundingBox.maxCenterCorrectionM",boundingBoxMaxCenterCorrectionM,0.0f,0.20f);
      boundingBoxMinPoints = intValue(p,"tracking.boundingBox.minPoints",boundingBoxMinPoints,40,10000);

      depthMinValidPixels = intValue(p, "depth.minimumValidPixels", depthMinValidPixels, 1, studio.services.scannerProtocol.WIDTH * studio.services.scannerProtocol.HEIGHT);

      depthMinValidRatio = floatValue(p, "depth.minimumValidRatio", depthMinValidRatio, 0.0001f, 1.0f);

      depthPlausibleMinMm = intValue(p, "depth.plausibleMinMm", depthPlausibleMinMm, 1, 9999);

      depthPlausibleMaxMm = intValue(p, "depth.plausibleMaxMm", depthPlausibleMaxMm, depthPlausibleMinMm + 1, 10000);

      streamStaleTimeoutMs = longValue(p, "transport.streamStaleMs", streamStaleTimeoutMs, 100, 30000);

      connectionStaleTimeoutMs = longValue(p, "transport.connectionStaleMs", connectionStaleTimeoutMs, streamStaleTimeoutMs, 60000);

      reconnectDelayMs = intValue(p, "transport.reconnectMs", reconnectDelayMs, 50, 5000);

      rgbdQueueFrames = intValue(p,"transport.rgbdQueueFrames",rgbdQueueFrames,4,120);

      rgbdSyncHistoryFrames = intValue(p,"transport.rgbdSyncHistoryFrames",rgbdSyncHistoryFrames,4,60);

      rgbdSyncMaxResidualMs = floatValue(p,"transport.rgbdSyncMaxResidualMs",rgbdSyncMaxResidualMs,1.0f,120.0f);

      rgbdSyncBootstrapMaxSkewMs = floatValue(p,"transport.rgbdSyncBootstrapMaxSkewMs",rgbdSyncBootstrapMaxSkewMs,rgbdSyncMaxResidualMs,500.0f);

      rgbdSyncOffsetAlpha = floatValue(p,"transport.rgbdSyncOffsetAlpha",rgbdSyncOffsetAlpha,0.001f,0.50f);

      captureDrainFramesPerDraw = intValue(p, "transport.drainFramesPerDraw", captureDrainFramesPerDraw, 1, 60);

      reconstructionQueueFrames = intValue(p, "fusion.queueFrames", reconstructionQueueFrames, 2, 120);

      reconstructionMaxFps = intValue(p, "fusion.maxFps", reconstructionMaxFps, 2, 30);

      pointCloudSpatialFilter = boolValue(p, "cloud.spatialFilter", pointCloudSpatialFilter);

      pointCloudNeighborToleranceM = floatValue(p, "cloud.neighborToleranceM", pointCloudNeighborToleranceM, 0.005f, 1.0f);

      pointCloudMinimumConfidence = floatValue(p, "cloud.minimumConfidence", pointCloudMinimumConfidence, 0.01f, 1.0f);

      pointCloudEdgeSoftM = floatValue(p, "cloud.edgeSoftM", pointCloudEdgeSoftM, 0.001f, 0.10f);

      pointCloudEdgeRejectM = floatValue(p, "cloud.edgeRejectM", pointCloudEdgeRejectM, pointCloudEdgeSoftM, 0.25f);
      pointCloudSurfaceNoiseM = floatValue(p,"cloud.surfaceNoiseM",pointCloudSurfaceNoiseM,0.002f,0.08f);
      pointCloudMinimumSupport = floatValue(p,"cloud.minimumSupport",pointCloudMinimumSupport,0.20f,1.0f);
      pointCloudConnectedTarget = boolValue(p,"cloud.connectedTarget",pointCloudConnectedTarget);
      pointCloudComponentMinSamples = intValue(p,"cloud.componentMinSamples",pointCloudComponentMinSamples,12,20000);
      pointCloudComponentDepthLinkM = floatValue(p,"cloud.componentDepthLinkM",pointCloudComponentDepthLinkM,0.005f,0.20f);
      pointCloudComponentBorderPenalty = floatValue(p,"cloud.componentBorderPenalty",pointCloudComponentBorderPenalty,0.0f,0.95f);
      previewAutoFitZoomOutResponse = floatValue(p,"preview.autoFit.zoomOutResponse",previewAutoFitZoomOutResponse,0.01f,1.0f);
      previewAutoFitZoomInResponse = floatValue(p,"preview.autoFit.zoomInResponse",previewAutoFitZoomInResponse,0.001f,0.25f);
      previewAutoFitCenterResponse = floatValue(p,"preview.autoFit.centerResponse",previewAutoFitCenterResponse,0.001f,0.30f);
      previewAutoFitDeadband = floatValue(p,"preview.autoFit.deadband",previewAutoFitDeadband,0.0f,0.30f);
      previewAutoFitShrinkDelayFrames = intValue(p,"preview.autoFit.shrinkDelayFrames",previewAutoFitShrinkDelayFrames,0,240);

      volumeSize = intValue(p, "fusion.volumeSize", volumeSize, 48, 384);
      voxelSizeM = floatValue(p, "fusion.voxelSizeM", voxelSizeM, 0.001f, 0.05f);

      truncationM = floatValue(p, "fusion.truncationM", truncationM, voxelSizeM, 0.20f);

      meshMinWeight = intValue(p, "mesh.minimumWeight", meshMinWeight, 1, 255);
      previewMeshMinWeight = intValue(p, "preview.meshMinimumWeight", previewMeshMinWeight, 1, 255);
      previewMeshRefreshFrames = intValue(p, "preview.meshRefreshFrames", previewMeshRefreshFrames, 1, 120);
      previewMeshRefreshMs = intValue(p, "preview.meshRefreshMs", previewMeshRefreshMs, 50, 5000);
      previewMeshMaxTriangles = intValue(p, "preview.meshMaxTriangles", previewMeshMaxTriangles, 1000, 500000);
      previewPointVoxelM = floatValue(p,"preview.pointVoxelM",previewPointVoxelM,0.001f,0.020f);
      previewPointMaxPoints = intValue(p,"preview.pointMaxPoints",previewPointMaxPoints,5000,300000);
      previewPointDisplayMaxPoints = intValue(p,"preview.pointDisplayMaxPoints",previewPointDisplayMaxPoints,3000,150000);
      previewPointTransientMaxPoints = intValue(p,"preview.pointTransientMaxPoints",previewPointTransientMaxPoints,500,30000);
      icpIterations = intValue(p, "tracking.icpIterations", icpIterations, 1, 50);

      icpMinimumMatches = intValue(p, "tracking.icpMinimumMatches", icpMinimumMatches, 12, 5000);

      icpCellSizeM = floatValue(p, "tracking.icpCellSizeM", icpCellSizeM, 0.002f, 0.50f);

      icpMaxDistanceM = floatValue(p, "tracking.icpMaxDistanceM", icpMaxDistanceM, 0.005f, 1.0f);
      icpFinalDistanceM = floatValue(p,"tracking.icpFinalDistanceM",icpFinalDistanceM,0.003f,icpMaxDistanceM);

      icpMaxSamples = intValue(p, "tracking.icpMaxSamples", icpMaxSamples, 100, 50000);

      icpGoodRmsM = floatValue(p, "tracking.icpGoodRmsM", icpGoodRmsM, 0.001f, 0.50f);

      icpReferenceFrames = intValue(p, "tracking.icpReferenceFrames", icpReferenceFrames, 1, 12);

      icpReferenceMaxPoints = intValue(p, "tracking.icpReferenceMaxPoints", icpReferenceMaxPoints, 500, 60000);

      icpTrimFraction = floatValue(p, "tracking.icpTrimFraction", icpTrimFraction, 0.50f, 1.0f);
      icpMinimumOverlap = floatValue(p,"tracking.icpMinimumOverlap",icpMinimumOverlap,0.05f,0.95f);
      icpRobustK = floatValue(p,"tracking.icpRobustK",icpRobustK,0.20f,1.0f);
      icpReciprocal = boolValue(p,"tracking.icpReciprocal",icpReciprocal);
      icpReciprocalToleranceM = floatValue(p,"tracking.icpReciprocalToleranceM",icpReciprocalToleranceM,0.002f,0.10f);
      icpMaxTranslationStepM = floatValue(p,"tracking.maxTranslationStepM",icpMaxTranslationStepM,0.005f,0.75f);
      icpMaxRotationStepDeg = floatValue(p,"tracking.maxRotationStepDeg",icpMaxRotationStepDeg,1.0f,90.0f);
      turntableTracking = boolValue(p,"tracking.turntable.enabled",turntableTracking);
      turntableMaxSeedYawDeg = floatValue(p,"tracking.turntable.maxSeedYawDeg",turntableMaxSeedYawDeg,4.0f,90.0f);
      turntableCoarseStepDeg = floatValue(p,"tracking.turntable.coarseStepDeg",turntableCoarseStepDeg,1.0f,20.0f);
      turntableFineStepDeg = floatValue(p,"tracking.turntable.fineStepDeg",turntableFineStepDeg,0.25f,8.0f);
      turntableMotionAlpha = floatValue(p,"tracking.turntable.motionAlpha",turntableMotionAlpha,0.0f,0.95f);
      turntablePredictionWeight = floatValue(p,"tracking.turntable.predictionWeight",turntablePredictionWeight,0.0f,1.5f);
      turntableSeedMinGain = floatValue(p,"tracking.turntable.seedMinGain",turntableSeedMinGain,0.0f,0.30f);
      turntableSeedMinimumConfidence = floatValue(p,"tracking.turntable.seedMinimumConfidence",turntableSeedMinimumConfidence,0.0f,1.0f);
      turntableSeedPoseAuthority = floatValue(p,"tracking.turntable.seedPoseAuthority",turntableSeedPoseAuthority,0.0f,1.0f);
      turntableSeedMinTrackedYawDeg = floatValue(p,"tracking.turntable.seedMinTrackedYawDeg",turntableSeedMinTrackedYawDeg,0.0f,5.0f);
      turntableVelocityClampDeg = floatValue(p,"tracking.turntable.velocityClampDeg",turntableVelocityClampDeg,1.0f,45.0f);
      turntablePivotAlpha = floatValue(p,"tracking.turntable.pivotAlpha",turntablePivotAlpha,0.0f,0.25f);
      turntableConstrainedEvaluationM = floatValue(p,"tracking.turntable.evaluationDistanceM",turntableConstrainedEvaluationM,0.010f,0.12f);
      turntablePoseConstraint = boolValue(p,"tracking.turntable.poseConstraint",turntablePoseConstraint);
      turntableConstraintScoreSlack = floatValue(p,"tracking.turntable.constraintScoreSlack",turntableConstraintScoreSlack,0.0f,0.60f);
      turntableConstraintTranslationM = floatValue(p,"tracking.turntable.constraintTranslationM",turntableConstraintTranslationM,0.0f,0.05f);
      turntableConstraintTranslationAuthority = floatValue(p,"tracking.turntable.constraintTranslationAuthority",turntableConstraintTranslationAuthority,0.0f,1.0f);
      turntableVerticalResidualWeight = floatValue(p,"tracking.turntable.verticalResidualWeight",turntableVerticalResidualWeight,0.02f,1.0f);
      colorIcpEnabled = boolValue(p,"tracking.colorIcp.enabled",colorIcpEnabled);
      colorIcpWeight = floatValue(p,"tracking.colorIcp.weight",colorIcpWeight,0.0f,0.80f);
      colorIcpRejectDistance = floatValue(p,"tracking.colorIcp.rejectDistance",colorIcpRejectDistance,0.10f,1.73f);
      colorIcpMinimumWeight = floatValue(p,"tracking.colorIcp.minimumWeight",colorIcpMinimumWeight,0.05f,1.0f);
      integrationMinTranslationM = floatValue(p,"fusion.minimumTranslationM",integrationMinTranslationM,0.0f,0.05f);
      integrationMinRotationDeg = floatValue(p,"fusion.minimumRotationDeg",integrationMinRotationDeg,0.0f,10.0f);
      integrationMaxIdleFrames = intValue(p,"fusion.maximumIdleFrames",integrationMaxIdleFrames,1,60);
      scanCoverageBins = intValue(p,"scan.coverageBins",scanCoverageBins,24,360);
      scanCoverageRequired = floatValue(p,"scan.coverageRequired",scanCoverageRequired,0.50f,1.0f);
      volumeAutoFit = boolValue(p,"fusion.autoFit",volumeAutoFit);
      volumeAutoFitPadding = floatValue(p,"fusion.autoFitPadding",volumeAutoFitPadding,1.0f,2.0f);
      volumeMaxVoxelSizeM = floatValue(p,"fusion.maxVoxelSizeM",volumeMaxVoxelSizeM,voxelSizeM,0.03f);

      hqEnabled = boolValue(p,"quality.enabled",hqEnabled);
      hqMaxKeyframes = intValue(p,"quality.keyframes.max",hqMaxKeyframes,12,600);
      hqFinalizeMaxKeyframes = intValue(p,"quality.finalizeMaxKeyframes",hqFinalizeMaxKeyframes,12,hqMaxKeyframes);

      hqKeyframeMinRotationDeg = floatValue(p,"quality.keyframes.minRotationDeg",hqKeyframeMinRotationDeg,0.1f,30.0f);

      hqKeyframeMinTranslationM = floatValue(p,"quality.keyframes.minTranslationM",hqKeyframeMinTranslationM,0.0005f,0.20f);

      hqMinimumKeyframes = intValue(p,"quality.keyframes.minimum",hqMinimumKeyframes,3,hqMaxKeyframes);

      hqIntegrationStep = intValue(p,"quality.integrationStep",hqIntegrationStep,1,4);

      hqVolumeSize = intValue(p,"quality.volumeSize",hqVolumeSize,128,384);
      hqVoxelSizeM = floatValue(p,"quality.voxelSizeM",hqVoxelSizeM,0.001f,0.010f);

      hqTruncationM = floatValue(p,"quality.truncationM",hqTruncationM,hqVoxelSizeM*2.0f,0.050f);

      hqMeshMinWeight = intValue(p,"quality.meshMinimumWeight",hqMeshMinWeight,1,255);

      hqIcpIterations = intValue(p,"quality.icpIterations",hqIcpIterations,2,40);

      hqIcpMaxSamples = intValue(p,"quality.icpMaxSamples",hqIcpMaxSamples,1000,50000);

      hqIcpMinimumMatches = intValue(p,"quality.icpMinimumMatches",hqIcpMinimumMatches,30,10000);

      hqIcpMaxDistanceM = floatValue(p,"quality.icpMaxDistanceM",hqIcpMaxDistanceM,0.003f,0.15f);

      hqIcpTrimFraction = floatValue(p,"quality.icpTrimFraction",hqIcpTrimFraction,0.40f,1.0f);

      hqIcpGoodRmsM = floatValue(p,"quality.icpGoodRmsM",hqIcpGoodRmsM,0.001f,0.10f);
      hqGlobalRecovery = boolValue(p,"quality.globalRecovery.enabled",hqGlobalRecovery);
      hqGlobalRecoveryPasses = intValue(p,"quality.globalRecovery.passes",hqGlobalRecoveryPasses,1,8);
      hqGlobalRecoveryNeighborFrames = intValue(p,"quality.globalRecovery.neighborFrames",hqGlobalRecoveryNeighborFrames,1,12);
      hqGlobalRecoveryCoarseDistanceM = floatValue(p,"quality.globalRecovery.coarseDistanceM",hqGlobalRecoveryCoarseDistanceM,0.015f,0.20f);
      hqGlobalRecoveryFineDistanceM = floatValue(p,"quality.globalRecovery.fineDistanceM",hqGlobalRecoveryFineDistanceM,0.005f,hqGlobalRecoveryCoarseDistanceM);
      hqGlobalRecoveryMaxTranslationM = floatValue(p,"quality.globalRecovery.maxTranslationM",hqGlobalRecoveryMaxTranslationM,0.02f,0.40f);
      hqGlobalRecoveryMaxRotationDeg = floatValue(p,"quality.globalRecovery.maxRotationDeg",hqGlobalRecoveryMaxRotationDeg,5.0f,90.0f);
      hqGlobalRecoveryMinSupport = floatValue(p,"quality.globalRecovery.minSupport",hqGlobalRecoveryMinSupport,0.05f,0.90f);
      hqGlobalRecoveryMaxRmsM = floatValue(p,"quality.globalRecovery.maxRmsM",hqGlobalRecoveryMaxRmsM,0.003f,0.08f);

      hqLoopClosure = boolValue(p,"quality.loopClosure",hqLoopClosure);
      hqLoopClosureMaxRmsM = floatValue(p,"quality.loopClosureMaxRmsM",hqLoopClosureMaxRmsM,0.001f,0.10f);
      hqTurntableConsensus = boolValue(p,"quality.turntableConsensus.enabled",hqTurntableConsensus);
      hqTurntableAxisAuthority = floatValue(p,"quality.turntableConsensus.axisAuthority",hqTurntableAxisAuthority,0.0f,0.98f);
      hqTurntableRescueMinSupport = floatValue(p,"quality.turntableConsensus.rescueMinSupport",hqTurntableRescueMinSupport,0.10f,0.90f);
      hqTurntableRescueMaxRmsM = floatValue(p,"quality.turntableConsensus.rescueMaxRmsM",hqTurntableRescueMaxRmsM,0.002f,0.05f);
      hqTurntableRecoveredFramePenalty = floatValue(p,"quality.turntableConsensus.recoveredFramePenalty",hqTurntableRecoveredFramePenalty,0.05f,1.0f);

      hqDepthFilterRadius = intValue(p,"quality.depthFilterRadius",hqDepthFilterRadius,1,3);

      hqDepthEdgeToleranceM = floatValue(p,"quality.depthEdgeToleranceM",hqDepthEdgeToleranceM,0.003f,0.10f);

      hqHoleFillMinimumNeighbors = intValue(p,"quality.holeFillMinimumNeighbors",hqHoleFillMinimumNeighbors,3,48);

      hqDistanceWeightedTsdf = boolValue(p,"quality.distanceWeightedTsdf",hqDistanceWeightedTsdf);

      hqDepthSuperResolution = boolValue(p,"quality.depthSuperResolution.enabled",hqDepthSuperResolution);

      hqDepthSrScale = intValue(p,"quality.depthSuperResolution.scale",hqDepthSrScale,1,3);

      hqDepthSrWindowFrames = intValue(p,"quality.depthSuperResolution.windowFrames",hqDepthSrWindowFrames,1,11);

      if((hqDepthSrWindowFrames&1)==0)hqDepthSrWindowFrames++;
      hqDepthSrAnchorStride = intValue(p,"quality.depthSuperResolution.anchorStride",hqDepthSrAnchorStride,1,8);

      hqDepthSrMaxRotationDeg = floatValue(p,"quality.depthSuperResolution.maxRotationDeg",hqDepthSrMaxRotationDeg,0.1f,20.0f);

      hqDepthSrMaxTranslationM = floatValue(p,"quality.depthSuperResolution.maxTranslationM",hqDepthSrMaxTranslationM,0.001f,0.15f);

      hqDepthSrOcclusionToleranceM = floatValue(p,"quality.depthSuperResolution.occlusionToleranceM",hqDepthSrOcclusionToleranceM,0.002f,0.08f);

      hqDepthSrOutlierToleranceM = floatValue(p,"quality.depthSuperResolution.outlierToleranceM",hqDepthSrOutlierToleranceM,0.001f,hqDepthSrOcclusionToleranceM);

      hqDepthSrMinimumViews = intValue(p,"quality.depthSuperResolution.minimumViews",hqDepthSrMinimumViews,1,hqDepthSrWindowFrames);

      hqDepthSrMaxPoints = intValue(p,"quality.depthSuperResolution.maxPoints",hqDepthSrMaxPoints,50000,1200000);

      hqMeshPolishIterations = intValue(p,"quality.meshPolishIterations",hqMeshPolishIterations,0,8);

      hqMeshPolishLambda = floatValue(p,"quality.meshPolishLambda",hqMeshPolishLambda,0.01f,0.60f);

      hqMeshPolishMu = floatValue(p,"quality.meshPolishMu",hqMeshPolishMu,-0.60f,-0.01f);

      calibrationEnabled = boolValue(p,"calibration.depthCorrection.enabled",calibrationEnabled);

      calibrationStations = intValue(p,"calibration.depthCorrection.stations",calibrationStations,3,12);

      calibrationFramesPerStation = intValue(p,"calibration.depthCorrection.framesPerStation",calibrationFramesPerStation,3,60);

      calibrationMinimumStationsPerPixel = intValue(p,"calibration.depthCorrection.minimumStationsPerPixel",calibrationMinimumStationsPerPixel,2,calibrationStations);

      calibrationDistanceSeparationM = floatValue(p,"calibration.depthCorrection.distanceSeparationM",calibrationDistanceSeparationM,0.05f,0.60f);

      calibrationStabilityToleranceM = floatValue(p,"calibration.depthCorrection.stabilityToleranceM",calibrationStabilityToleranceM,0.003f,0.10f);

      calibrationPlaneResidualMaxM = floatValue(p,"calibration.depthCorrection.planeResidualMaxM",calibrationPlaneResidualMaxM,0.005f,0.10f);

      calibrationSlopeMin = floatValue(p,"calibration.depthCorrection.slopeMin",calibrationSlopeMin,0.70f,1.0f);

      calibrationSlopeMax = floatValue(p,"calibration.depthCorrection.slopeMax",calibrationSlopeMax,1.0f,1.30f);

      calibrationOffsetMaxM = floatValue(p,"calibration.depthCorrection.offsetMaxM",calibrationOffsetMaxM,0.005f,0.20f);

      calibrationNoiseFloorM = floatValue(p,"calibration.depthCorrection.noiseFloorM",calibrationNoiseFloorM,0.0002f,0.02f);

      calibrationNoiseCeilingM = floatValue(p,"calibration.depthCorrection.noiseCeilingM",calibrationNoiseCeilingM,calibrationNoiseFloorM,0.10f);

      scanFullTurnDeg = floatValue(p, "scan.fullTurnDeg", scanFullTurnDeg, 90.0f, 720.0f);

      scanCompleteDeg = floatValue(p, "scan.completeDeg", scanCompleteDeg, 30.0f, scanFullTurnDeg);

      scanRotationDeadbandDeg = floatValue(p, "scan.rotationDeadbandDeg", scanRotationDeadbandDeg, 0.0f, 10.0f);

      scanRotationMaxStepDeg = floatValue(p, "scan.rotationMaxStepDeg", scanRotationMaxStepDeg, 1.0f, 90.0f);

      scanDirectionLockDeg = floatValue(p, "scan.directionLockDeg", scanDirectionLockDeg, 0.1f, 45.0f);
          scanTurnFilterAlpha = floatValue(p,"scan.turnFilterAlpha",scanTurnFilterAlpha,0.05f,1.0f);
      scanReverseJitterDeg = floatValue(p,"scan.reverseJitterDeg",scanReverseJitterDeg,0.0f,10.0f);
      scanReverseCommitDeg = floatValue(p,"scan.reverseCommitDeg",scanReverseCommitDeg,scanReverseJitterDeg,30.0f);
      scanDirectionRelockDeg = floatValue(p,"scan.directionRelockDeg",scanDirectionRelockDeg,scanReverseCommitDeg,90.0f);


      scanMaxSensorTiltDriftDeg = floatValue(p, "scan.maxSensorTiltDriftDeg", scanMaxSensorTiltDriftDeg, 0.5f, 45.0f);

      autoPauseOnFullTurn = boolValue(p, "scan.autoPauseOnFullTurn", autoPauseOnFullTurn);
      autoFinalizeOnFullTurn = boolValue(p, "scan.autoFinalizeOnFullTurn", autoFinalizeOnFullTurn);

      meshCleanupMaxEdgeM = floatValue(p, "mesh.cleanupMaxEdgeM", meshCleanupMaxEdgeM, voxelSizeM, 2.0f);

      meshCleanupMinAreaM2 = floatValue(p, "mesh.cleanupMinAreaM2", meshCleanupMinAreaM2, 0.000000001f, 0.01f);

      meshWeldToleranceM = floatValue(p, "mesh.weldToleranceM", meshWeldToleranceM, 0.00001f, 0.05f);

      meshSmoothIterations = intValue(p, "mesh.smoothIterations", meshSmoothIterations, 0, 100);

      meshSmoothLambda = floatValue(p, "mesh.smoothLambda", meshSmoothLambda, 0.01f, 1.0f);

      meshPolishIterations = intValue(p, "mesh.polishIterations", meshPolishIterations, 0, 20);

      meshPolishLambda = floatValue(p, "mesh.polishLambda", meshPolishLambda, 0.01f, 0.95f);

      meshPolishMu = floatValue(p, "mesh.polishMu", meshPolishMu, -0.95f, -0.01f);
      meshHoleFillEnabled = boolValue(p, "mesh.holeFill.enabled", meshHoleFillEnabled);
      meshHoleFillMaxEdges = intValue(p, "mesh.holeFill.maxEdges", meshHoleFillMaxEdges, 3, 128);
      meshHoleFillMaxDiameterM = floatValue(p, "mesh.holeFill.maxDiameterM", meshHoleFillMaxDiameterM, 0.001f, 0.25f);
      meshHoleFillMaxPerimeterM = floatValue(p, "mesh.holeFill.maxPerimeterM", meshHoleFillMaxPerimeterM, 0.003f, 1.0f);

      meshMinimumComponentTriangles = intValue(p, "mesh.minimumComponentTriangles", meshMinimumComponentTriangles, 1, 1000000);

      meshMinimumComponentRatio = floatValue(p, "mesh.minimumComponentRatio", meshMinimumComponentRatio, 0.0f, 0.25f);

      meshColorEnabled = boolValue(p, "mesh.rgb.enabled", meshColorEnabled);
      rgbFx = floatValue(p, "calibration.rgb.fx", rgbFx, 100.0f, 2000.0f);
      rgbFy = floatValue(p, "calibration.rgb.fy", rgbFy, 100.0f, 2000.0f);
      rgbCx = floatValue(p, "calibration.rgb.cx", rgbCx, -1000.0f, 2000.0f);
      rgbCy = floatValue(p, "calibration.rgb.cy", rgbCy, -1000.0f, 2000.0f);
      depthK1=floatValue(p,"calibration.depth.k1",depthK1,-5.0f,5.0f); depthK2=floatValue(p,"calibration.depth.k2",depthK2,-5.0f,5.0f);

      depthP1=floatValue(p,"calibration.depth.p1",depthP1,-1.0f,1.0f); depthP2=floatValue(p,"calibration.depth.p2",depthP2,-1.0f,1.0f);
     depthK3=floatValue(p,"calibration.depth.k3",depthK3,-10.0f,10.0f);
      rgbK1=floatValue(p,"calibration.rgb.k1",rgbK1,-5.0f,5.0f); rgbK2=floatValue(p,"calibration.rgb.k2",rgbK2,-5.0f,5.0f);

      rgbP1=floatValue(p,"calibration.rgb.p1",rgbP1,-1.0f,1.0f); rgbP2=floatValue(p,"calibration.rgb.p2",rgbP2,-1.0f,1.0f);
     rgbK3=floatValue(p,"calibration.rgb.k3",rgbK3,-10.0f,10.0f);
      regR00=floatValue(p,"calibration.depthToRgb.r00",regR00,-2.0f,2.0f); regR01=floatValue(p,"calibration.depthToRgb.r01",regR01,-2.0f,2.0f);
     regR02=floatValue(p,"calibration.depthToRgb.r02",regR02,-2.0f,2.0f);
      regR10=floatValue(p,"calibration.depthToRgb.r10",regR10,-2.0f,2.0f); regR11=floatValue(p,"calibration.depthToRgb.r11",regR11,-2.0f,2.0f);
     regR12=floatValue(p,"calibration.depthToRgb.r12",regR12,-2.0f,2.0f);
      regR20=floatValue(p,"calibration.depthToRgb.r20",regR20,-2.0f,2.0f); regR21=floatValue(p,"calibration.depthToRgb.r21",regR21,-2.0f,2.0f);
     regR22=floatValue(p,"calibration.depthToRgb.r22",regR22,-2.0f,2.0f);
      regTx=floatValue(p,"calibration.depthToRgb.tx",regTx,-0.20f,0.20f); regTy=floatValue(p,"calibration.depthToRgb.ty",regTy,-0.20f,0.20f);
     regTz=floatValue(p,"calibration.depthToRgb.tz",regTz,-0.20f,0.20f);
      colorRegistrationOffsetX = floatValue(p, "mesh.rgb.offsetX", colorRegistrationOffsetX, -32.0f, 32.0f);

      colorRegistrationOffsetY = floatValue(p, "mesh.rgb.offsetY", colorRegistrationOffsetY, -32.0f, 32.0f);

      rgbMaxSyncSkewMs=floatValue(p,"mesh.rgb.maxSyncSkewMs",rgbMaxSyncSkewMs,1.0f,200.0f);

      rgbOcclusionFilter=boolValue(p,"mesh.rgb.occlusionFilter",rgbOcclusionFilter);

      rgbOcclusionToleranceM=floatValue(p,"mesh.rgb.occlusionToleranceM",rgbOcclusionToleranceM,0.001f,0.25f);

      rgbAutoRefine=boolValue(p,"mesh.rgb.autoRefine",rgbAutoRefine);
      rgbRefineEveryFrames=intValue(p,"mesh.rgb.refineEveryFrames",rgbRefineEveryFrames,1,120);

      rgbRefineSearchPx=intValue(p,"mesh.rgb.refineSearchPx",rgbRefineSearchPx,0,16);

      rgbRefineSampleStep=intValue(p,"mesh.rgb.refineSampleStep",rgbRefineSampleStep,2,32);

      rgbRefineEdgeThresholdMm=intValue(p,"mesh.rgb.refineEdgeThresholdMm",rgbRefineEdgeThresholdMm,5,1000);

      rgbRefineMinimumEdges=intValue(p,"mesh.rgb.refineMinimumEdges",rgbRefineMinimumEdges,8,10000);

      rgbRefineAlpha=floatValue(p,"mesh.rgb.refineAlpha",rgbRefineAlpha,0.01f,1.0f);

      rgbRefineMaxOffsetPx=floatValue(p,"mesh.rgb.refineMaxOffsetPx",rgbRefineMaxOffsetPx,0.0f,32.0f);

      rgbExposureLowLuma=intValue(p,"mesh.rgb.exposureLowLuma",rgbExposureLowLuma,1,127);

      rgbExposureHighLuma=intValue(p,"mesh.rgb.exposureHighLuma",rgbExposureHighLuma,128,254);

      rgbTemporalColorWeightMax=intValue(p,"mesh.rgb.temporalColorWeightMax",rgbTemporalColorWeightMax,1,32);

      rgbHqHistoryFrames=intValue(p,"mesh.rgb.hq.historyFrames",rgbHqHistoryFrames,2,24);

      rgbHqMaxSyncSkewMs=floatValue(p,"mesh.rgb.hq.maxSyncSkewMs",rgbHqMaxSyncSkewMs,10.0f,250.0f);

      rgbHqMinimumFrameQuality=floatValue(p,"mesh.rgb.hq.minimumFrameQuality",rgbHqMinimumFrameQuality,0.0f,1.0f);

      rgbPhotometricNormalize=boolValue(p,"mesh.rgb.hq.photometricNormalize",rgbPhotometricNormalize);

      rgbPhotometricGainMin=floatValue(p,"mesh.rgb.hq.gainMin",rgbPhotometricGainMin,0.30f,1.0f);

      rgbPhotometricGainMax=floatValue(p,"mesh.rgb.hq.gainMax",rgbPhotometricGainMax,1.0f,3.0f);

      rgbHqSharpenAmount=floatValue(p,"mesh.rgb.hq.sharpenAmount",rgbHqSharpenAmount,0.0f,0.60f);




      exportBaseName = textValue(p, "export.baseName", exportBaseName);
      exportWeldToleranceM = floatValue(p, "export.weldToleranceM", exportWeldToleranceM, 0.00001f, 0.05f);

      exportMaxWeldToleranceM = floatValue(p, "export.maxWeldToleranceM", exportMaxWeldToleranceM, exportWeldToleranceM, 0.10f);

      exportMaxTriangles = intValue(p, "export.maxTriangles", exportMaxTriangles, 1000, 5000000);



  }

  String textValue(Properties p,String key,String defaultValue){return studio.services.configRules.text(p,key,defaultValue);
    }
  boolean boolValue(Properties p,String key,boolean defaultValue){return studio.services.configRules.flag(p,key,defaultValue);
    }
  int intValue(Properties p,String key,int defaultValue,int lo,int hi){return studio.services.configRules.integer(p,key,defaultValue,lo,hi);
    }
  long longValue(Properties p,String key,long defaultValue,long lo,long hi){return studio.services.configRules.longNumber(p,key,defaultValue,lo,hi);
    }
  float floatValue(Properties p,String key,float defaultValue,float lo,float hi){return studio.services.configRules.decimal(p,key,defaultValue,lo,hi);
    }
}


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
  DepthTargetEstimate latest = new DepthTargetEstimate();

  DepthTargetTracker(AppConfig cfg, DepthAnalyzer analyzer) { this.cfg = cfg; this.analyzer = analyzer;
     bandM = cfg.objectDepthBandM; }

  void reset() { depthM = Float.NaN; bandM = cfg.objectDepthBandM; candidateM = Float.NaN;
     stableFrames = 0; lostFrames = 0; latest = new DepthTargetEstimate(); }

  boolean update(DepthFrame frame) {
    latest = analyzer.estimateTarget(frame, cfg, depthM);
    if (!latest.valid || Float.isNaN(latest.depthM)) {
      lostFrames++;
      if (lostFrames >= cfg.depthTargetLostFramesForReacquire) { depthM = Float.NaN;
         candidateM = Float.NaN; stableFrames = 0; bandM = cfg.objectDepthBandM; return false;
         }
      return !Float.isNaN(depthM);
    }

    float suggestedBand = max(cfg.objectDepthBandM, latest.spreadM * cfg.depthBandSpreadMultiplier);
    bandM = constrain(lerp(bandM, suggestedBand, 0.25f), cfg.objectDepthBandM, cfg.maxObjectDepthBandM);


    if (Float.isNaN(depthM)) {
      if (Float.isNaN(candidateM) || abs(latest.depthM - candidateM) > cfg.depthTargetStableToleranceM) { candidateM = latest.depthM;
         stableFrames = 1; }
      else { candidateM = lerp(candidateM, latest.depthM, 0.35f); stableFrames++;
         }
      if (stableFrames >= cfg.depthTargetStableFrames) { depthM = candidateM; lostFrames = 0;
         return true; }
      return false;
    }

    if (abs(latest.depthM - depthM) <= cfg.depthTargetMaxJumpM) {
      depthM = lerp(depthM, latest.depthM, cfg.depthTargetSmoothing);
      candidateM = depthM; stableFrames = cfg.depthTargetStableFrames; lostFrames = 0;
       return true;
    }

    lostFrames++;
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


// ===== SynKinect Studio / 3D Scanner / Exporters.pde =====
class ExportSpace {
  PVector position(PVector p) { return new PVector(p.x, -p.y, p.z); }
  Triangle3D triangle(Triangle3D t) {
    // Y reflection reverses handedness; swapping B/C preserves outward winding.
    return new Triangle3D(position(t.a), position(t.c), position(t.b), t.ca, t.cc, t.cb);

  }
}

class VertexKey {
  final long x,y,z;
  VertexKey(float px,float py,float pz,float q){x=Math.round(px/q);y=Math.round(py/q);z=Math.round(pz/q);}
  public int hashCode(){long h=x*73856093L^y*19349663L^z*83492791L;return(int)(h^(h>>>32));}
  public boolean equals(Object o){if(!(o instanceof VertexKey))return false;VertexKey k=(VertexKey)o;return x==k.x&&y==k.y&&z==k.z;}
}
class FaceKey {
  final int a,b,c;
  FaceKey(int x,int y,int z){
    int lo=Math.min(x,Math.min(y,z)),hi=Math.max(x,Math.max(y,z));
    a=lo;c=hi;b=x+y+z-lo-hi;
  }
  public int hashCode(){return (a*73856093)^(b*19349663)^(c*83492791);}
  public boolean equals(Object o){if(!(o instanceof FaceKey))return false;FaceKey k=(FaceKey)o;return a==k.a&&b==k.b&&c==k.c;}
}
class VertexAccum {
  float x,y,z;long a,r,g,b;int count;
  void add(float px,float py,float pz,int colorValue){x+=px;y+=py;z+=pz;a+=(colorValue>>>24)&255;r+=(colorValue>>16)&255;g+=(colorValue>>8)&255;b+=colorValue&255;count++;}
  PVector point(){float n=Math.max(1,count);return new PVector(x/n,y/n,z/n);}
  int colorValue(){int n=Math.max(1,count),aa=(int)(a/n),rr=(int)(r/n),gg=(int)(g/n),bb=(int)(b/n);return ((aa&255)<<24)|((rr&255)<<16)|((gg&255)<<8)|(bb&255);}
}
class IndexedFace {
  int a,b,c;Triangle3D source;
  IndexedFace(int a,int b,int c,Triangle3D source){this.a=a;this.b=b;this.c=c;this.source=source;}
}
class IndexedMesh {
  ArrayList<PVector> vertices=new ArrayList<PVector>();
  ArrayList<PVector> normals=new ArrayList<PVector>();
  ArrayList<Integer> colors=new ArrayList<Integer>();
  ArrayList<IndexedFace> faces=new ArrayList<IndexedFace>();
  float toleranceM;
}
class MeshCompactor {
  AppConfig cfg;
  MeshCompactor(AppConfig cfg){this.cfg=cfg;}
  IndexedMesh compact(Mesh3D source){
    float base=Math.max(0.00001f,cfg.exportWeldToleranceM),limit=Math.max(base,cfg.exportMaxWeldToleranceM);
    int sourceFaces=source==null?0:source.triangleCount();
    if(sourceFaces==0)return compactAt(source,base);
    // Surface complexity scales approximately with 1/q^2. Start near the useful
    // tolerance instead of rebuilding the complete mesh six times in tiny steps.
    float q=base;
    if(sourceFaces>cfg.exportMaxTriangles){
      float ratio=sourceFaces/(float)Math.max(1,cfg.exportMaxTriangles);
      q=Math.min(limit,Math.max(base,base*(float)Math.sqrt(ratio)*0.90f));
    }
    IndexedMesh best=compactAt(source,q);
    for(int pass=0;pass<2&&best.faces.size()>cfg.exportMaxTriangles&&q<limit-0.0000001f;pass++){
      float ratio=best.faces.size()/(float)Math.max(1,cfg.exportMaxTriangles);
      float next=Math.min(limit,Math.max(q*1.20f,q*(float)Math.sqrt(ratio)*1.05f));
      if(next<=q+0.0000001f)next=limit;
      q=next;best=compactAt(source,q);
    }
    return best;
  }
  IndexedMesh compactAt(Mesh3D source,float q){
    IndexedMesh out=new IndexedMesh();out.toleranceM=q;
    if(source==null||source.triangles.isEmpty())return out;
    int expected=Math.max(16,Math.min(source.triangleCount()*2,1500000));
    HashMap<VertexKey,Integer> indices=new HashMap<VertexKey,Integer>(expected);
    ArrayList<VertexAccum> accum=new ArrayList<VertexAccum>(Math.min(expected,1000000));
    HashSet<FaceKey> seenFaces=new HashSet<FaceKey>(Math.max(16,Math.min(source.triangleCount(),1000000)));
    out.faces.ensureCapacity(Math.min(source.triangleCount(),cfg.exportMaxTriangles*2));
    for(Triangle3D t:source.triangles){
      // ExportSpace reflects Y and swaps B/C to preserve winding, performed here
      // without allocating a temporary Triangle3D and three temporary PVectors.
      int ia=indexFor(t.a.x,-t.a.y,t.a.z,t.ca,q,indices,accum);
      int ib=indexFor(t.c.x,-t.c.y,t.c.z,t.cc,q,indices,accum);
      int ic=indexFor(t.b.x,-t.b.y,t.b.z,t.cb,q,indices,accum);
      if(ia==ib||ib==ic||ia==ic)continue;
      FaceKey fk=new FaceKey(ia,ib,ic);if(!seenFaces.add(fk))continue;
      out.faces.add(new IndexedFace(ia,ib,ic,t));
    }
    out.vertices.ensureCapacity(accum.size());out.colors.ensureCapacity(accum.size());out.normals.ensureCapacity(accum.size());
    for(VertexAccum v:accum){out.vertices.add(v.point());out.colors.add(v.colorValue());out.normals.add(new PVector());}
    for(IndexedFace f:out.faces){
      PVector a=out.vertices.get(f.a),b=out.vertices.get(f.b),c=out.vertices.get(f.c);
      float ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z;
      float nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx,magSq=nx*nx+ny*ny+nz*nz;
      if(magSq<=1e-12f)continue;
      float inv=1.0f/(float)Math.sqrt(magSq);nx*=inv;ny*=inv;nz*=inv;
      PVector na=out.normals.get(f.a),nb=out.normals.get(f.b),nc=out.normals.get(f.c);
      na.x+=nx;na.y+=ny;na.z+=nz;nb.x+=nx;nb.y+=ny;nb.z+=nz;nc.x+=nx;nc.y+=ny;nc.z+=nz;
    }
    for(PVector n:out.normals){float m=n.x*n.x+n.y*n.y+n.z*n.z;if(m>1e-12f){float inv=1.0f/(float)Math.sqrt(m);n.x*=inv;n.y*=inv;n.z*=inv;}}
    return out;
  }
  int indexFor(float x,float y,float z,int c,float q,HashMap<VertexKey,Integer> indices,ArrayList<VertexAccum> accum){
    VertexKey key=new VertexKey(x,y,z,q);Integer idx=indices.get(key);
    if(idx==null){idx=accum.size();indices.put(key,idx);accum.add(new VertexAccum());}
    accum.get(idx).add(x,y,z,c);return idx;
  }
}

// Export-space convention shared by STL, OBJ and PLY.
// Scanner/Processing reconstruction uses screen-style +Y downward. External
// 3D/CAD files use +Y upward, so reflect Y only at serialization time.
// Reflection changes handedness; face winding is reversed by each exporter.
class ScannerExportSpace {
  static PVector point(PVector p){return new PVector(p.x,-p.y,p.z);}
  static PVector normal(PVector n){PVector out=new PVector(n.x,-n.y,n.z);if(out.magSq()>1e-12f)out.normalize();return out;}
}

class STLExporter {
  AppConfig cfg;MeshCompactor compactor;
  STLExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void writeBinary(Mesh3D mesh, File file) throws Exception {
    IndexedMesh indexed=compactor.compact(mesh);
    File parent=file.getParentFile();if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder");

    DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(file)));

    try {
      byte[] header = new byte[80]; String text="SynKinect Studio compact STL; weld="+indexed.toleranceM+"m";
      byte[] title=text.getBytes("US-ASCII");
      System.arraycopy(title,0,header,0,Math.min(title.length,80)); out.write(header);
       writeLEInt(out,indexed.faces.size());
      for(IndexedFace f:indexed.faces){PVector a=ScannerExportSpace.point(indexed.vertices.get(f.a)),b=ScannerExportSpace.point(indexed.vertices.get(f.b)),c=ScannerExportSpace.point(indexed.vertices.get(f.c));
        // Y reflection reverses handedness: serialize A,C,B to preserve outward winding.
        PVector n=PVector.sub(c,a).cross(PVector.sub(b,a));if(n.magSq()>1e-12f)n.normalize();
        writeVec(out,n,false);writeVec(out,a,true);writeVec(out,c,true);writeVec(out,b,true);
        writeLEShort(out,0);}
    } finally { out.close(); }
  }
  void writeVec(DataOutputStream out,PVector v,boolean millimeters)throws Exception{float scale=millimeters?1000.0f:1.0f;
    writeLEFloat(out,v.x*scale);writeLEFloat(out,v.y*scale);writeLEFloat(out,v.z*scale);
    }
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));
    }
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);
    out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);
    }
  void writeLEShort(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);
    out.writeByte((value>>8)&255);}
}

class OBJExporter {
  AppConfig cfg;MeshCompactor compactor;
  OBJExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void write(Mesh3D mesh,File obj)throws Exception{
    IndexedMesh indexed=compactor.compact(mesh);
    File folder=obj.getParentFile();if(folder!=null&&!folder.exists()&&!folder.mkdirs())throw new IOException("Could not create export folder: "+folder.getAbsolutePath());
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(obj)));
    try{
      out.println("## SynKinect Studio indexed mesh");
      out.println("# coordinate_system: right-handed; +X right; +Y up; +Z forward; units: meters");
      out.println("# export_transform: scanner +Y-down converted to +Y-up; winding preserved");
      for(int i=0;i<indexed.vertices.size();i++)writeVertex(out,ScannerExportSpace.point(indexed.vertices.get(i)),indexed.colors.get(i));
      for(PVector n:indexed.normals){PVector en=ScannerExportSpace.normal(n);out.println("vn "+en.x+" "+en.y+" "+en.z);}
      for(IndexedFace f:indexed.faces)out.println("f "+(f.a+1)+"//"+(f.a+1)+" "+(f.c+1)+"//"+(f.c+1)+" "+(f.b+1)+"//"+(f.b+1));
    }finally{out.close();}
  }
  void writeVertex(PrintWriter out,PVector p,int c){
    float r=((c>>16)&255)/255.0f,g=((c>>8)&255)/255.0f,b=(c&255)/255.0f;
    out.println("v "+p.x+" "+p.y+" "+p.z+" "+r+" "+g+" "+b);
  }
}

class PLYExporter {
  AppConfig cfg;MeshCompactor compactor;
  PLYExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void write(Mesh3D mesh,File file)throws Exception{
    IndexedMesh indexed=compactor.compact(mesh);File parent=file.getParentFile();
    if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder");

    BufferedOutputStream raw=new BufferedOutputStream(new FileOutputStream(file));
    DataOutputStream out=new DataOutputStream(raw);
    try{
      String header=
        "ply\n"+
        "format binary_little_endian 1.0\n"+
        "comment SynKinect Studio compact indexed mesh\n"+
         "comment coordinate_system right-handed +X right +Y up +Z forward units meters\n"+
        "comment export_transform scanner +Y-down converted to +Y-up winding preserved\n"+
        "element vertex "+indexed.vertices.size()+"\n"+
        "property float x\n"+
        "property float y\n"+
        "property float z\n"+
        "property float nx\n"+
        "property float ny\n"+
        "property float nz\n"+
        "property uchar red\n"+
        "property uchar green\n"+
        "property uchar blue\n"+
        "property uchar alpha\n"+
        "element face "+indexed.faces.size()+"\n"+
        "property list uchar int vertex_indices\n"+
        "end_header\n";

      out.write(header.getBytes("US-ASCII"));
      for(int i=0;i<indexed.vertices.size();i++){PVector v=ScannerExportSpace.point(indexed.vertices.get(i)),n=ScannerExportSpace.normal(indexed.normals.get(i));
        int c=indexed.colors.get(i);writeLEFloat(out,v.x);writeLEFloat(out,v.y);writeLEFloat(out,v.z);
        writeLEFloat(out,n.x);writeLEFloat(out,n.y);writeLEFloat(out,n.z);
        out.writeByte((c>>16)&255);out.writeByte((c>>8)&255);out.writeByte(c&255);out.writeByte((c>>>24)&255);
        }
      for(IndexedFace f:indexed.faces){out.writeByte(3);writeLEInt(out,f.a);writeLEInt(out,f.c);
        writeLEInt(out,f.b);}
    }finally{out.close();}
  }
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));
    }
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);
    out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);
    }
}


// ===== SynKinect Studio / 3D Scanner / FrameTypes.pde =====



// ===== SynKinect Studio / 3D Scanner / Per-device depth calibration =====
class PlaneModel {
  float ax=0,by=0,c=Float.NaN,rms=Float.POSITIVE_INFINITY;int samples=0;
  boolean valid(){return Float.isFinite(c)&&samples>64;}
  float depthAt(float nx,float ny){return ax*nx+by*ny+c;}
}

class CalibrationStation {
  final int width,height;final float[] meanM,sigmaM;final PlaneModel plane;final float centerDepthM;

  CalibrationStation(int width,int height,float[] meanM,float[] sigmaM,PlaneModel plane,float centerDepthM){this.width=width;
    this.height=height;this.meanM=meanM;this.sigmaM=sigmaM;this.plane=plane;this.centerDepthM=centerDepthM;
    }
}

class DepthCorrectionProfile {
  final String deviceId;final int width,height;final float[] scale,offsetM,noiseM;

  boolean calibrated=false;float coverage=0,trainingRmsBeforeMm=Float.NaN,trainingRmsAfterMm=Float.NaN;
  long createdEpochMs=System.currentTimeMillis();
  DepthCorrectionProfile(String deviceId,int width,int height){this.deviceId=deviceId==null?"":deviceId;
    this.width=width;this.height=height;int n=width*height;scale=new float[n];offsetM=new float[n];
    noiseM=new float[n];Arrays.fill(scale,1.0f);Arrays.fill(noiseM,0.004f);}
  int correctMm(int index,int rawMm){if(rawMm<=0||index<0||index>=scale.length)return rawMm;
    float m=rawMm*0.001f*scale[index]+offsetM[index];return constrain(round(m*1000.0f),1,10000);
    }
  float noiseAt(int index,float depthM,AppConfig cfg){float empirical=(index>=0&&index<noiseM.length)?noiseM[index]:cfg.calibrationNoiseFloorM;
    float z=max(0.35f,depthM);float range=cfg.calibrationNoiseFloorM*(0.55f+0.45f*z*z);
    return constrain(max(empirical,range),cfg.calibrationNoiseFloorM,cfg.calibrationNoiseCeilingM);
    }
  float confidenceAt(int index,float depthM,AppConfig cfg){float sigma=noiseAt(index,depthM,cfg);
    return constrain(cfg.calibrationNoiseFloorM/max(cfg.calibrationNoiseFloorM,sigma),0.20f,1.0f);
    }

  DepthCorrectionProfile fit(ArrayList<CalibrationStation> stations,Calibration calibration,AppConfig cfg){
    if(stations==null||stations.size()<3)throw new IllegalArgumentException("at least three calibration stations are required");

    int w=width,h=height,n=w*h;DepthCorrectionProfile out=this;int calibratedPixels=0;
    double before2=0,after2=0;long residualN=0;
    float[] xs=new float[stations.size()],ys=new float[stations.size()],ns=new float[stations.size()];

    for(int idx=0;idx<n;idx++){
      int u=idx%w,v=idx/w;float nx=(u-calibration.cx)/calibration.fx,ny=(v-calibration.cy)/calibration.fy;
      int count=0;float noiseSum=0;
      for(CalibrationStation st:stations){float measured=st.meanM[idx];if(measured<=0||!st.plane.valid())continue;
        float target=st.plane.depthAt(nx,ny);if(target<=0)continue;xs[count]=measured;
        ys[count]=target;ns[count]=st.sigmaM[idx];noiseSum+=st.sigmaM[idx];count++;
        }
      if(count>=cfg.calibrationMinimumStationsPerPixel){
        double sx=0,sy=0,sxx=0,sxy=0;for(int i=0;i<count;i++){sx+=xs[i];sy+=ys[i];
          sxx+=xs[i]*xs[i];sxy+=xs[i]*ys[i];}double den=count*sxx-sx*sx;float a=1,b=0;
        if(Math.abs(den)>1e-10){a=(float)((count*sxy-sx*sy)/den);b=(float)((sy-a*sx)/count);
          }a=constrain(a,cfg.calibrationSlopeMin,cfg.calibrationSlopeMax);b=constrain(b,-cfg.calibrationOffsetMaxM,cfg.calibrationOffsetMaxM);
        out.scale[idx]=a;out.offsetM[idx]=b;out.noiseM[idx]=constrain(noiseSum/count,cfg.calibrationNoiseFloorM,cfg.calibrationNoiseCeilingM);
        calibratedPixels++;
        if((u&1)==0&&(v&1)==0)for(int i=0;i<count;i++){double eb=xs[i]-ys[i],ea=(a*xs[i]+b)-ys[i];
          before2+=eb*eb;after2+=ea*ea;residualN++;}
      }
    }
    out.coverage=calibratedPixels/(float)Math.max(1,n);out.calibrated=out.coverage>=0.35f;

    if(residualN>0){out.trainingRmsBeforeMm=(float)(Math.sqrt(before2/residualN)*1000.0);
      out.trainingRmsAfterMm=(float)(Math.sqrt(after2/residualN)*1000.0);}
    if(!out.calibrated)throw new IllegalStateException("insufficient calibrated-pixel coverage: "+out.coverage);

    return out;
  }
}

class DepthCalibrationStore {
  static final int MAGIC=0x314C4143,VERSION=1;
  File root(){return studio.services.paths.dataDirectory("core/rgbd","calibration","calibration");
    }
  String safeId(String id){String s=id==null?"kinect":id.replaceAll("[^A-Za-z0-9._-]","_");
    if(s.length()>80)s=s.substring(0,64)+"_"+Integer.toHexString(id.hashCode());return s;
    }
  File fileFor(String id){return new File(root(),safeId(id)+".depthcal");}
  boolean delete(String id){
    File f=fileFor(id);return !f.exists()||f.delete();
  }
  void save(DepthCorrectionProfile p)throws IOException{File dir=root();if(!dir.exists()&&!dir.mkdirs())throw new IOException("cannot create calibration directory: "+dir);
    File target=fileFor(p.deviceId),tmp=new File(target.getAbsolutePath()+".tmp");
    try(DataOutputStream out=new DataOutputStream(new BufferedOutputStream(new FileOutputStream(tmp)))){out.writeInt(MAGIC);
      out.writeInt(VERSION);out.writeUTF(p.deviceId);out.writeInt(p.width);out.writeInt(p.height);
      out.writeLong(p.createdEpochMs);out.writeBoolean(p.calibrated);out.writeFloat(p.coverage);
      out.writeFloat(p.trainingRmsBeforeMm);out.writeFloat(p.trainingRmsAfterMm);
      for(float v:p.scale)out.writeFloat(v);for(float v:p.offsetM)out.writeFloat(v);
      for(float v:p.noiseM)out.writeFloat(v);}try{Files.move(tmp.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);
      }catch(AtomicMoveNotSupportedException e){Files.move(tmp.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING);
      }}
  DepthCorrectionProfile load(String id,int width,int height){File f=fileFor(id);
    if(!f.isFile())return null;try(DataInputStream in=new DataInputStream(new BufferedInputStream(new FileInputStream(f)))){if(in.readInt()!=MAGIC||in.readInt()!=VERSION)return null;
      String stored=in.readUTF();int w=in.readInt(),h=in.readInt();if(!Objects.equals(stored,id)||w!=width||h!=height)return null;
      DepthCorrectionProfile p=new DepthCorrectionProfile(stored,w,h);p.createdEpochMs=in.readLong();
      p.calibrated=in.readBoolean();p.coverage=in.readFloat();p.trainingRmsBeforeMm=in.readFloat();
      p.trainingRmsAfterMm=in.readFloat();for(int i=0;i<p.scale.length;i++)p.scale[i]=in.readFloat();
      for(int i=0;i<p.offsetM.length;i++)p.offsetM[i]=in.readFloat();for(int i=0;i<p.noiseM.length;i++)p.noiseM[i]=in.readFloat();
      return p.calibrated?p:null;}catch(Exception e){return null;}}
}

class CalibrationAccumulator {
  final int width,height;final long[] sumMm,sumSqMm;final short[] count;int frames=0;

  CalibrationAccumulator(int width,int height){this.width=width;this.height=height;
    int n=width*height;sumMm=new long[n];sumSqMm=new long[n];count=new short[n];}
  void add(DepthFrame f){for(int i=0;i<f.depth.length;i++){int mm=f.depth[i]&0xffff;
      if(mm<=0)continue;sumMm[i]+=mm;sumSqMm[i]+=(long)mm*mm;if(count[i]<Short.MAX_VALUE)count[i]++;
      }frames++;}
  CalibrationStation finish(Calibration calibration){int n=width*height;float[] mean=new float[n],sigma=new float[n];
    for(int i=0;i<n;i++){int c=count[i]&0xffff;if(c<max(2,frames/2))continue;double m=sumMm[i]/(double)c;
      double variance=Math.max(0,sumSqMm[i]/(double)c-m*m);mean[i]=(float)(m*0.001);
      sigma[i]=(float)(Math.sqrt(variance)*0.001);}PlaneModel plane=fitCalibrationPlane(mean,width,height,calibration);
    float center=medianCalibrationDepth(mean,width,height);return new CalibrationStation(width,height,mean,sigma,plane,center);
    }
}

PlaneModel fitCalibrationPlane(float[] depth,int width,int height,Calibration calibration){
  PlaneModel first=fitCalibrationPlanePass(depth,width,height,calibration,null,Float.POSITIVE_INFINITY);
  if(!first.valid())return first;float cutoff=max(0.004f,min(0.040f,first.rms*2.5f));
  return fitCalibrationPlanePass(depth,width,height,calibration,first,cutoff);
}
PlaneModel fitCalibrationPlanePass(float[] depth,int width,int height,Calibration calibration,PlaneModel reference,float cutoff){
  double sxx=0,syy=0,sxy=0,sx=0,sy=0,sz=0,sxz=0,syz=0;int n=0;int step=3;
  for(int v=8;v<height-8;v+=step)for(int u=8;u<width-8;u+=step){int i=v*width+u;float z=depth[i];
    if(z<0.35f||z>3.0f)continue;float x=(u-calibration.cx)/calibration.fx,y=(v-calibration.cy)/calibration.fy;
    if(reference!=null&&abs(z-reference.depthAt(x,y))>cutoff)continue;sxx+=x*x;syy+=y*y;
    sxy+=x*y;sx+=x;sy+=y;sz+=z;sxz+=x*z;syz+=y*z;n++;}
  PlaneModel out=new PlaneModel();if(n<128)return out;double[][] a={{sxx,sxy,sx,sxz},{sxy,syy,sy,syz},{sx,sy,n,sz}};
  for(int col=0;col<3;col++){int pivot=col;for(int r=col+1;r<3;r++)if(Math.abs(a[r][col])>Math.abs(a[pivot][col]))pivot=r;
    if(Math.abs(a[pivot][col])<1e-12)return out;double[] tmp=a[col];a[col]=a[pivot];
    a[pivot]=tmp;double d=a[col][col];for(int c=col;c<4;c++)a[col][c]/=d;for(int r=0;r<3;r++)if(r!=col){double f=a[r][col];
      for(int c=col;c<4;c++)a[r][c]-=f*a[col][c];}}
  out.ax=(float)a[0][3];out.by=(float)a[1][3];out.c=(float)a[2][3];out.samples=n;
  double e2=0;int en=0;for(int v=8;v<height-8;v+=step)for(int u=8;u<width-8;u+=step){float z=depth[v*width+u];
    if(z<=0)continue;float x=(u-calibration.cx)/calibration.fx,y=(v-calibration.cy)/calibration.fy,r=z-out.depthAt(x,y);
    if(reference!=null&&abs(r)>cutoff)continue;e2+=r*r;en++;}out.rms=en==0?Float.POSITIVE_INFINITY:(float)Math.sqrt(e2/en);
  return out;
}
float medianCalibrationDepth(float[] depth,int width,int height){int x0=width*3/8,x1=width*5/8,y0=height*3/8,y1=height*5/8;
  float[] scratch=new float[(x1-x0)*(y1-y0)/16+64];int n=0;for(int y=y0;y<y1;y+=4)for(int x=x0;x<x1;x+=4){float z=depth[y*width+x];
    if(z>0){if(n>=scratch.length)scratch=Arrays.copyOf(scratch,scratch.length*2);
      scratch[n++]=z;}}if(n==0)return Float.NaN;Arrays.sort(scratch,0,n);return scratch[n/2];
  }

class DepthCalibrationSession {
  final AppConfig cfg;final Calibration calibration;final DepthCalibrationStore store;
  final String deviceId;final ArrayList<CalibrationStation> stations=new ArrayList<CalibrationStation>();
  final boolean autoSave;
  boolean active=false,waitingForDistance=false;int capturedFrames=0,lastFrameId=-1;
  float anchorDepthM=Float.NaN;CalibrationAccumulator accumulator=null;float[] quickDepth=null;

  DepthCalibrationSession(AppConfig cfg,Calibration calibration,DepthCalibrationStore store,String deviceId){this(cfg,calibration,store,deviceId,true);}
  DepthCalibrationSession(AppConfig cfg,Calibration calibration,DepthCalibrationStore store,String deviceId,boolean autoSave){this.cfg=cfg;
    this.calibration=calibration;this.store=store;this.deviceId=deviceId;this.autoSave=autoSave;}
  void start(){active=true;waitingForDistance=false;capturedFrames=0;anchorDepthM=Float.NaN;
    accumulator=null;stations.clear();}
  void cancel(){active=false;accumulator=null;}
  DepthCorrectionProfile offer(DepthFrame frame)throws IOException{
    if(!active||frame==null||frame.depth==null||frame.frameId==lastFrameId)return null;
    lastFrameId=frame.frameId;
    if(quickDepth==null||quickDepth.length!=frame.depth.length)quickDepth=new float[frame.depth.length];
    for(int i=0;i<quickDepth.length;i++){int mm=frame.depth[i]&0xffff;quickDepth[i]=mm>0?mm*0.001f:0;
      }PlaneModel plane=fitCalibrationPlane(quickDepth,frame.width,frame.height,calibration);
    float center=medianCalibrationDepth(quickDepth,frame.width,frame.height);if(!plane.valid()||!Float.isFinite(center)||plane.rms>cfg.calibrationPlaneResidualMaxM)return null;

    if(waitingForDistance){float previous=stations.get(stations.size()-1).centerDepthM;
      if(abs(center-previous)<cfg.calibrationDistanceSeparationM)return null;waitingForDistance=false;
      anchorDepthM=center;accumulator=new CalibrationAccumulator(frame.width,frame.height);
      capturedFrames=0;}
    if(accumulator==null){anchorDepthM=center;accumulator=new CalibrationAccumulator(frame.width,frame.height);
      }
    if(abs(center-anchorDepthM)>cfg.calibrationStabilityToleranceM){accumulator=null;
      capturedFrames=0;anchorDepthM=Float.NaN;return null;}
    accumulator.add(frame);capturedFrames++;
    if(capturedFrames<cfg.calibrationFramesPerStation)return null;
    CalibrationStation station=accumulator.finish(calibration);accumulator=null;capturedFrames=0;
    anchorDepthM=Float.NaN;if(!station.plane.valid()||station.plane.rms>cfg.calibrationPlaneResidualMaxM)return null;
    stations.add(station);
    if(stations.size()<cfg.calibrationStations){waitingForDistance=true;return null;
      }
    DepthCorrectionProfile profile=new DepthCorrectionProfile(deviceId,calibration.depthWidth,calibration.depthHeight).fit(stations,calibration,cfg);
    if(autoSave)store.save(profile);active=false;return profile;
  }
}

class Calibration {
  volatile boolean valid = false;
  int depthWidth = studio.services.scannerProtocol.WIDTH;
  int depthHeight = studio.services.scannerProtocol.HEIGHT;
  float fx, fy, cx, cy, depthScale;
  String deviceId="";DepthCorrectionProfile depthCorrection=null;AppConfig cfg;

  void configure(AppConfig cfg) {
    this.cfg=cfg;if (cfg == null) { valid = false; return; }
    depthWidth = studio.services.scannerProtocol.WIDTH;
    depthHeight = studio.services.scannerProtocol.HEIGHT;
    fx = cfg.depthFx; fy = cfg.depthFy; cx = cfg.depthCx; cy = cfg.depthCy; depthScale = cfg.depthScale;

    valid = fx > 0 && fy > 0 && depthScale > 0;
  }
  void selectDevice(String id,DepthCorrectionProfile profile){deviceId=id==null?"":id;
    depthCorrection=profile;}
  void applyNativeIntrinsics(int width,int height,double nativeFx,double nativeFy,double nativeCx,double nativeCy){
    if(width<=0||height<=0||!Double.isFinite(nativeFx)||!Double.isFinite(nativeFy)||!Double.isFinite(nativeCx)||!Double.isFinite(nativeCy)||nativeFx<=1||nativeFy<=1)return;
    depthWidth=width;depthHeight=height;fx=(float)nativeFx;fy=(float)nativeFy;cx=(float)nativeCx;cy=(float)nativeCy;depthScale=0.001f;valid=true;
    if(depthCorrection!=null&&(depthCorrection.width!=width||depthCorrection.height!=height))depthCorrection=null;
  }
  boolean hasDepthCorrection(){return cfg!=null&&cfg.calibrationEnabled&&depthCorrection!=null&&depthCorrection.calibrated;
    }
  int correctedDepthMm(int index,int rawMm){return hasDepthCorrection()?depthCorrection.correctMm(index,rawMm):rawMm;
    }
  float depthConfidence(int index,float depthM){return hasDepthCorrection()?depthCorrection.confidenceAt(index,depthM,cfg):1.0f;
    }
}




// ===== SynKinect Studio / 3D Scanner / IcpTracker.pde =====
class IcpTracker {
  AppConfig cfg;
  RigidTransform pose = new RigidTransform();
  PointCloud reference = null;
  final ArrayDeque<PointCloud> referenceWindow=new ArrayDeque<PointCloud>();
  // Separate histories: tracking follows valid motion continuously; fusion
  // contains only geometry committed to TSDF for anti-ghosting validation.
  final ArrayDeque<PointCloud> fusionReferenceWindow=new ArrayDeque<PointCloud>();
  boolean trackingGood = false;
  float rms = Float.POSITIVE_INFINITY;
  int matches = 0;
  PVector gravityReference = null;
  boolean motionPriorUsed = false;
  final ArrayList<PVector> matchSrc=new ArrayList<PVector>();
  final ArrayList<PVector> matchDst=new ArrayList<PVector>();
  final ArrayList<PVector> candidateSrc=new ArrayList<PVector>();
  final ArrayList<PVector> candidateDst=new ArrayList<PVector>();
  final ArrayList<Float> candidateD2=new ArrayList<Float>();
  final ArrayList<Float> candidateConfidence=new ArrayList<Float>();
  final ArrayList<Float> matchWeights=new ArrayList<Float>();
  final ArrayList<PVector> matchPool=new ArrayList<PVector>();
  final ArrayList<PVector> iterationSource=new ArrayList<PVector>();
  final ArrayList<Integer> iterationColor=new ArrayList<Integer>();
  final QuaternionFit fitter=new QuaternionFit();
  PVector turntablePivotWorld=null;
  float turntableYawVelocityDeg=0.0f;
  float turntableSeedConfidence=0.0f;
  float turntableSeedYawDeg=0.0f;
  float lastTrackedYawStepDeg=0.0f;
  float overlap=0.0f;

  IcpTracker(AppConfig cfg){ this.cfg=cfg; }

  void reset(){ pose.setIdentity(); reference=null; referenceWindow.clear(); fusionReferenceWindow.clear(); trackingGood=false;
     rms=Float.POSITIVE_INFINITY; matches=0; gravityReference=null; motionPriorUsed=false;
     matchSrc.clear();matchDst.clear();candidateSrc.clear();candidateDst.clear();
    candidateD2.clear();candidateConfidence.clear();matchWeights.clear();iterationSource.clear();iterationColor.clear();turntablePivotWorld=null;turntableYawVelocityDeg=0.0f;turntableSeedConfidence=0.0f;turntableSeedYawDeg=0.0f;lastTrackedYawStepDeg=0.0f;overlap=0.0f; }

  PVector transformedSample(int slot,PVector source,RigidTransform estimate){
    while(matchPool.size()<=slot)matchPool.add(new PVector());
    PVector out=matchPool.get(slot);float[] m=estimate.m;
    out.set(m[0]*source.x+m[1]*source.y+m[2]*source.z+m[3],m[4]*source.x+m[5]*source.y+m[6]*source.z+m[7],m[8]*source.x+m[9]*source.y+m[10]*source.z+m[11]);

    return out;
  }

  RigidTransform track(PointCloud current, MotionSample motion) {
    if(referenceWindow.isEmpty()) {
      pose.setIdentity();
      if(motion!=null && motion.gravityReliable()) gravityReference=motion.gravityUnit();

      addReference(current,pose);
      turntablePivotWorld=robustCloudCenter(current,pose);
      trackingGood=true; rms=0; matches=reference==null?0:reference.size();overlap=1.0f;
      return pose;
    }

    RigidTransform estimate=new RigidTransform(); estimate.set(pose);
    estimate=applyMotionPrior(estimate,motion);
    float finalRms=Float.POSITIVE_INFINITY; int finalMatches=0;

    int referencePoints=0;for(PointCloud cloud:referenceWindow)referencePoints+=cloud.size();

    SpatialHash hash=new SpatialHash(cfg.icpCellSizeM,max(16,referencePoints));
    HashMap<PVector,Integer> referenceColors=new HashMap<PVector,Integer>(max(16,referencePoints*2));
    for(PointCloud cloud:referenceWindow)for(int ri=0;ri<cloud.size();ri++){
      PVector rp=cloud.points.get(ri);hash.add(rp);referenceColors.put(rp,cloud.colorAt(ri));
    }
    estimate=seedTurntableRotation(current,estimate,hash,referenceColors);
    int maxSamples=max(1,cfg.icpMaxSamples);
    int stride=max(1,(current.size()+maxSamples-1)/maxSamples);

    for(int iter=0;iter<cfg.icpIterations;iter++) {
      candidateSrc.clear();candidateDst.clear();candidateD2.clear();candidateConfidence.clear();iterationSource.clear();iterationColor.clear();
      int slot=0,attempted=0;
      float phase=cfg.icpIterations<=1?1.0f:iter/(float)(cfg.icpIterations-1);
      float searchDistance=lerp(cfg.icpMaxDistanceM,cfg.icpFinalDistanceM,phase);
      SpatialHash sourceHash=new SpatialHash(max(.006f,min(cfg.icpCellSizeM,searchDistance)),max(16,maxSamples));
      ArrayList<Float> iterationConfidence=new ArrayList<Float>();
      for(int i=0;i<current.size();i+=stride) {
        float confidence=current.confidenceAt(i);if(confidence<cfg.pointCloudMinimumConfidence)continue;attempted++;
        PVector world=transformedSample(slot++,current.points.get(i),estimate);iterationSource.add(world);iterationConfidence.add(confidence);iterationColor.add(current.colorAt(i));sourceHash.add(world);
      }
      float reciprocalGate=max(cfg.icpReciprocalToleranceM,searchDistance*.38f);
      for(int i=0;i<iterationSource.size();i++){PVector world=iterationSource.get(i),near=hash.nearest(world,searchDistance);if(near==null)continue;
        if(cfg.icpReciprocal){PVector reverse=sourceHash.nearest(near,reciprocalGate);if(reverse==null||PVector.dist(reverse,world)>reciprocalGate)continue;}
        float dx=world.x-near.x,dy=world.y-near.y,dz=world.z-near.z;
        float photo=photometricWeight(iterationColor.get(i),referenceColors.get(near));
        candidateSrc.add(world);candidateDst.add(near);candidateD2.add(dx*dx+dy*dy+dz*dz);candidateConfidence.add(iterationConfidence.get(i)*photo);}
      overlap=attempted<=0?0:candidateSrc.size()/(float)attempted;
      if(candidateSrc.size()<cfg.icpMinimumMatches||overlap<cfg.icpMinimumOverlap)break;

      float threshold=trimThreshold(candidateD2,cfg.icpTrimFraction,cfg.icpMinimumMatches);
      float robustRadius=max(0.001f,searchDistance*cfg.icpRobustK);
      matchSrc.clear();matchDst.clear();matchWeights.clear();double weightedSum2=0,weightSum=0;
      for(int i=0;i<candidateSrc.size();i++){float d2=candidateD2.get(i);if(d2>threshold)continue;
        float d=sqrt(d2),u=d/robustRadius,robust=u>=1.0f?0.05f:(1.0f-u*u)*(1.0f-u*u);
        float weight=max(0.01f,candidateConfidence.get(i))*max(0.05f,robust);
        matchSrc.add(candidateSrc.get(i));matchDst.add(candidateDst.get(i));matchWeights.add(weight);weightedSum2+=weight*d2;weightSum+=weight;
        }
      if(matchSrc.size()<cfg.icpMinimumMatches||weightSum<=0)break;
      finalRms=(float)Math.sqrt(weightedSum2/weightSum);finalMatches=matchSrc.size();
      RigidTransform correction=fitter.fitWeighted(matchSrc,matchDst,matchWeights);
      estimate=correction.multiply(estimate);
      if(rigidTranslationDelta(new RigidTransform(),correction)<0.00005f&&rigidRotationDeltaDeg(new RigidTransform(),correction)<0.03f)break;
    }

    // Generic nearest-neighbour ICP can partially erase a small legitimate yaw,
    // especially on smooth or nearly symmetric parts. If the dedicated
    // turntable seed has a distinct basin (geometry and/or RGB texture), retain
    // a bounded portion of that axial motion while preserving the ICP XYZ,
    // pitch and roll solution.
    if(cfg.turntableTracking&&turntablePivotWorld!=null&&
       turntableSeedConfidence>=cfg.turntableSeedMinimumConfidence&&
       abs(turntableSeedYawDeg)>=cfg.turntableSeedMinTrackedYawDeg){
      float finalYaw=turntableDeltaDeg(pose,estimate);
      boolean directionCompatible=abs(finalYaw)<cfg.turntableSeedMinTrackedYawDeg||
        finalYaw*turntableSeedYawDeg>=0;
      float retained=abs(turntableSeedYawDeg)*.38f;
      if(directionCompatible&&abs(finalYaw)<retained){
        float confidenceAuthority=constrain((turntableSeedConfidence-cfg.turntableSeedMinimumConfidence)/
          max(.001f,1.0f-cfg.turntableSeedMinimumConfidence),0,1);
        float authority=cfg.turntableSeedPoseAuthority*lerp(.35f,1.0f,confidenceAuthority);
        float targetYaw=lerp(finalYaw,turntableSeedYawDeg,authority);
        estimate=rotateAroundPivotY(estimate,turntablePivotWorld,targetYaw-finalYaw);
      }
    }

    // A target rotating around a fixed vertical axis is much better conditioned
    // than unrestricted frame-to-frame SE(3). Generic ICP can otherwise explain
    // silhouette changes as small translations/pitch/roll and accumulate a
    // double shell. Prefer the axial solution whenever it explains the data
    // almost as well, while retaining only a tightly bounded translation residual.
    if(cfg.turntableTracking&&cfg.turntablePoseConstraint&&turntablePivotWorld!=null){
      estimate=stabilizeTurntablePose(current,estimate,hash,referenceColors);
      float[] stabilized=evaluateTurntablePose(current,estimate,hash,stride);
      if(Float.isFinite(stabilized[0])){finalRms=stabilized[0];finalMatches=round(stabilized[1]);overlap=stabilized[2];}
    }

    // Compose the converged metric 3D estimate as a complete SE(3) transform.
    // In turntable mode the converged transform is regularized around the stable
    // rotation axis; free SE(3) remains available when it is measurably better.
    rms=finalRms; matches=finalMatches;lastTrackedYawStepDeg=0;
    trackingGood = matches>=cfg.icpMinimumMatches && rms<cfg.icpGoodRmsM && overlap>=cfg.icpMinimumOverlap;
    if(trackingGood) {
      float translationStep=rigidTranslationDelta(pose,estimate);
      float rotationStep=rigidRotationDeltaDeg(pose,estimate);
      if(translationStep>cfg.icpMaxTranslationStepM||rotationStep>cfg.icpMaxRotationStepDeg)trackingGood=false;
    }
    if(trackingGood) {
      float yawStep=turntableDeltaDeg(pose,estimate);
      lastTrackedYawStepDeg=yawStep;
      float velocityTarget=constrain(yawStep,turntableYawVelocityDeg-cfg.turntableVelocityClampDeg,turntableYawVelocityDeg+cfg.turntableVelocityClampDeg);
      // Ambiguous/symmetric geometry must not inject a large velocity jump.
      float velocityAuthority=lerp(.22f,1.0f,turntableSeedConfidence);
      turntableYawVelocityDeg=lerp(turntableYawVelocityDeg,velocityTarget,(1.0f-cfg.turntableMotionAlpha)*velocityAuthority);
      pose.set(estimate);
      PVector observedCenter=robustCloudCenter(current,pose);
      if(turntablePivotWorld==null)turntablePivotWorld=observedCenter;
      else if(cfg.turntablePivotAlpha>0){float a=cfg.turntablePivotAlpha;PVector delta=PVector.sub(observedCenter,turntablePivotWorld);float horizontal=sqrt(delta.x*delta.x+delta.z*delta.z);
        // Only tiny, high-confidence pivot corrections are permitted.  Large
        // centroid changes are normally occlusion/new surface, not a moving axis.
        if(horizontal<.025f&&abs(delta.y)<.018f){turntablePivotWorld.x=lerp(turntablePivotWorld.x,observedCenter.x,a);turntablePivotWorld.y=lerp(turntablePivotWorld.y,observedCenter.y,a*.20f);turntablePivotWorld.z=lerp(turntablePivotWorld.z,observedCenter.z,a);}}
      // Tracking must keep following a legitimate rotation even when fusion
      // rejects a frame. Freezing this window makes ICP compare against an old
      // view until the turn can no longer be detected.
      addReference(current,pose);
    }
    return pose;
  }

  RigidTransform stabilizeTurntablePose(PointCloud current,RigidTransform fullEstimate,SpatialHash hash,HashMap<PVector,Integer> referenceColors){
    if(current==null||fullEstimate==null||turntablePivotWorld==null)return fullEstimate;
    float yawStep=turntableDeltaDeg(pose,fullEstimate);
    if(!Float.isFinite(yawStep))return fullEstimate;

    RigidTransform axial=rotateAroundPivotY(pose,turntablePivotWorld,yawStep);
    float fullScore=turntableScore(current,fullEstimate,hash,referenceColors);
    float axialScore=turntableScore(current,axial,hash,referenceColors);
    if(!Float.isFinite(axialScore))return fullEstimate;
    if(Float.isFinite(fullScore)&&axialScore>fullScore*(1.0f+cfg.turntableConstraintScoreSlack))return fullEstimate;

    float dx=fullEstimate.m[3]-axial.m[3],dy=fullEstimate.m[7]-axial.m[7],dz=fullEstimate.m[11]-axial.m[11];
    float d=sqrt(dx*dx+dy*dy+dz*dz);
    float maxResidual=max(0.0f,cfg.turntableConstraintTranslationM);
    if(d>maxResidual&&d>1e-7f){float k=maxResidual/d;dx*=k;dy*=k;dz*=k;}
    float authority=constrain(cfg.turntableConstraintTranslationAuthority,0,1);
    // Strong yaw evidence makes the fixed-axis model even more authoritative.
    authority*=lerp(1.0f,0.45f,constrain(turntableSeedConfidence,0,1));
    axial.m[3]+=dx*authority;axial.m[7]+=dy*authority;axial.m[11]+=dz*authority;
    return axial;
  }

  float photometricWeight(int currentColor,Integer referenceColor){
    if(!cfg.colorIcpEnabled||currentColor==0||referenceColor==null||referenceColor.intValue()==0)return 1.0f;
    int rc=referenceColor.intValue();
    float dr=((currentColor>>16)&255)-((rc>>16)&255);
    float dg=((currentColor>>8)&255)-((rc>>8)&255);
    float db=(currentColor&255)-(rc&255);
    float distance=sqrt(dr*dr+dg*dg+db*db)/(441.67296f);
    float similarity=constrain(1.0f-distance,0,1);
    float photo=lerp(1.0f,similarity,cfg.colorIcpWeight);
    if(distance>cfg.colorIcpRejectDistance)photo=min(photo,cfg.colorIcpMinimumWeight);
    return constrain(photo,cfg.colorIcpMinimumWeight,1.0f);
  }


  float[] fusionReferenceConsistency(PointCloud current,RigidTransform candidate){
    if(current==null||candidate==null||fusionReferenceWindow.isEmpty())return new float[]{0,0};
    int referencePoints=0;for(PointCloud cloud:fusionReferenceWindow)referencePoints+=cloud.size();
    SpatialHash hash=new SpatialHash(max(.006f,cfg.icpCellSizeM),max(16,referencePoints));
    for(PointCloud cloud:fusionReferenceWindow)for(PVector p:cloud.points)hash.add(p);
    int maxSamples=min(2600,max(1,cfg.icpMaxSamples)),stride=max(1,(current.size()+maxSamples-1)/maxSamples),attempted=0,matched=0;
    ArrayList<Float> d2=new ArrayList<Float>();float gate=max(cfg.fusionReferenceMaxRmsM*2.5f,cfg.icpFinalDistanceM);
    for(int i=0;i<current.size();i+=stride){
      if(current.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;PVector w=candidate.apply(current.points.get(i)),q=hash.nearest(w,gate);if(q==null)continue;
      float dx=w.x-q.x,dy=w.y-q.y,dz=w.z-q.z;d2.add(dx*dx+dy*dy+dz*dz);matched++;
    }
    float overlap=attempted<=0?0:matched/(float)attempted;if(matched<max(24,cfg.icpMinimumMatches/3))return new float[]{overlap,Float.POSITIVE_INFINITY};
    Collections.sort(d2);int keep=constrain(round(d2.size()*0.70f),max(12,cfg.icpMinimumMatches/4),d2.size());double sum=0;for(int i=0;i<keep;i++)sum+=d2.get(i);
    return new float[]{overlap,(float)Math.sqrt(sum/keep)};
  }

  void acceptFusionReference(PointCloud current,RigidTransform acceptedPose){
    if(current==null||acceptedPose==null)return;
    addFusionReference(current,acceptedPose);
  }

  float[] evaluateTurntablePose(PointCloud cloud,RigidTransform candidate,SpatialHash hash,int stride){
    int attempted=0,n=0;ArrayList<Float> residuals=new ArrayList<Float>();float gate=max(cfg.turntableConstrainedEvaluationM,cfg.icpFinalDistanceM*1.35f);
    for(int i=0;i<cloud.size();i+=max(1,stride)){if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;PVector w=candidate.apply(cloud.points.get(i)),q=hash.nearest(w,gate);if(q==null)continue;float dx=w.x-q.x,dy=w.y-q.y,dz=w.z-q.z;residuals.add(dx*dx+dy*dy+dz*dz);n++;}
    float ov=attempted<=0?0:n/(float)attempted;if(n<cfg.icpMinimumMatches)return new float[]{Float.POSITIVE_INFINITY,n,ov};Collections.sort(residuals);int keep=constrain(round(n*cfg.icpTrimFraction),cfg.icpMinimumMatches,n);double sum=0;for(int i=0;i<keep;i++)sum+=residuals.get(i);return new float[]{(float)Math.sqrt(sum/keep),keep,ov};
  }

  RigidTransform seedTurntableRotation(PointCloud current,RigidTransform base,SpatialHash hash,HashMap<PVector,Integer> referenceColors){
    if(!cfg.turntableTracking||current==null||current.size()<cfg.icpMinimumMatches){turntableSeedConfidence=0;turntableSeedYawDeg=0;return base;}
    PVector pivot=turntablePivotWorld==null?robustCloudCenter(current,base):turntablePivotWorld.copy();
    float maxYaw=cfg.turntableMaxSeedYawDeg;
    float predicted=constrain(turntableYawVelocityDeg,-maxYaw,maxYaw);

    RigidTransform predictedPose=rotateAroundPivotY(base,pivot,predicted);
    float predictedGeom=turntableScore(current,predictedPose,hash,referenceColors);
    RigidTransform best=predictedPose;float bestYaw=predicted;
    float bestObjective=turntableSeedObjective(predictedGeom,predicted,predicted,maxYaw);
    float secondObjective=Float.POSITIVE_INFINITY;

    float coarse=max(1.0f,cfg.turntableCoarseStepDeg);
    for(float probe=-maxYaw;probe<=maxYaw+0.001f;probe+=coarse){
      RigidTransform candidate=rotateAroundPivotY(base,pivot,probe);float geom=turntableScore(current,candidate,hash,referenceColors);
      float objective=turntableSeedObjective(geom,probe,predicted,maxYaw);
      boolean meaningful=Float.isInfinite(predictedGeom)||geom<predictedGeom*(1.0f-cfg.turntableSeedMinGain);
      if(objective<bestObjective&&meaningful){secondObjective=bestObjective;bestObjective=objective;best=candidate;bestYaw=probe;}
      else if(objective<secondObjective&&abs(probe-bestYaw)>coarse*.45f)secondObjective=objective;
    }

    float fine=max(0.25f,cfg.turntableFineStepDeg);RigidTransform fineBest=best;float fineObjective=bestObjective;
    for(float probe=bestYaw-coarse;probe<=bestYaw+coarse+0.001f;probe+=fine){
      probe=constrain(probe,-maxYaw,maxYaw);RigidTransform candidate=rotateAroundPivotY(base,pivot,probe);float geom=turntableScore(current,candidate,hash,referenceColors);
      float objective=turntableSeedObjective(geom,probe,predicted,maxYaw);
      boolean meaningful=Float.isInfinite(predictedGeom)||geom<predictedGeom*(1.0f-cfg.turntableSeedMinGain)||abs(probe-predicted)<=fine*1.1f;
      if(objective<fineObjective&&meaningful){secondObjective=min(secondObjective,fineObjective);fineObjective=objective;fineBest=candidate;bestYaw=probe;}
      else if(objective<secondObjective&&abs(probe-bestYaw)>fine*1.5f)secondObjective=objective;
    }

    // Confidence is the separation between the best yaw basin and its nearest
    // competitor. Symmetric pieces naturally produce lower confidence, so the
    // temporal velocity prior remains dominant instead of jittering between bins.
    if(Float.isInfinite(fineObjective)||Float.isNaN(fineObjective))turntableSeedConfidence=0;
    else if(Float.isInfinite(secondObjective))turntableSeedConfidence=.72f;
    else turntableSeedConfidence=constrain((secondObjective-fineObjective)/max(1e-9f,secondObjective)*7.5f,0,1);
    turntableSeedYawDeg=bestYaw;
    return fineBest;
  }

  float turntableSeedObjective(float geometryScore,float yaw,float predicted,float maxYaw){
    if(Float.isInfinite(geometryScore)||Float.isNaN(geometryScore))return Float.POSITIVE_INFINITY;
    float angularError=abs(yaw-predicted)/max(1.0f,maxYaw);
    return geometryScore*(1.0f+cfg.turntablePredictionWeight*angularError*angularError);
  }
  RigidTransform rotateAroundPivotY(RigidTransform base,PVector pivot,float yawDeg){
    // Use the Kinect gravity vector when available so a physically tilted sensor
    // still rotates the target around the real vertical axis, not camera-space Y.
    PVector axis=gravityReference==null?new PVector(0,1,0):gravityReference.copy();if(axis.magSq()<1e-7f)axis.set(0,1,0);axis.normalize();
    RigidTransform r=axisAngle(axis,radians(yawDeg));PVector rc=r.rotate(pivot);r.m[3]=pivot.x-rc.x;r.m[7]=pivot.y-rc.y;r.m[11]=pivot.z-rc.z;return r.multiply(base);
  }
  float turntableDeltaDeg(RigidTransform from,RigidTransform to){
    RigidTransform d=to.multiply(from.inverseRigid());PVector axis=gravityReference==null?new PVector(0,1,0):gravityReference.copy();if(axis.magSq()<1e-7f)axis.set(0,1,0);axis.normalize();
    float vx=d.m[9]-d.m[6],vy=d.m[2]-d.m[8],vz=d.m[4]-d.m[1];float sin=.5f*(axis.x*vx+axis.y*vy+axis.z*vz);float cos=constrain((d.m[0]+d.m[5]+d.m[10]-1.0f)*.5f,-1,1);return degrees(atan2(sin,cos));
  }
  float turntableScore(PointCloud cloud,RigidTransform t,SpatialHash hash,HashMap<PVector,Integer> referenceColors){
    int step=max(1,cloud.size()/1800),attempted=0,n=0;float maxD=max(cfg.icpMaxDistanceM,.035f);
    ArrayList<Float> residuals=new ArrayList<Float>();
    float wy=constrain(cfg.turntableVerticalResidualWeight,0.02f,1.0f);
    for(int i=0;i<cloud.size();i+=step){
      if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;
      PVector w=t.apply(cloud.points.get(i)),q=hash.nearest(w,maxD);if(q==null)continue;
      float dx=w.x-q.x,dy=w.y-q.y,dz=w.z-q.z;
      // Y is retained only weakly for correspondence quality. When registered
      // RGB exists, texture on the object/turntable adds bounded angular evidence.
      float metric=dx*dx+dz*dz+wy*dy*dy;
      if(cfg.colorIcpEnabled&&referenceColors!=null){
        Integer rc=referenceColors.get(q);int cc=cloud.colorAt(i);
        if(rc!=null&&rc.intValue()!=0&&cc!=0){
          int rv=rc.intValue();float dr=((cc>>16)&255)-((rv>>16)&255),dg=((cc>>8)&255)-((rv>>8)&255),db=(cc&255)-(rv&255);
          float cd=sqrt(dr*dr+dg*dg+db*db)/441.67296f;
          metric*=1.0f+cfg.colorIcpWeight*constrain(cd,0,1)*0.75f;
        }
      }
      residuals.add(metric);n++;
    }
    float ov=attempted<=0?0:n/(float)attempted;
    if(n<cfg.icpMinimumMatches||ov<cfg.icpMinimumOverlap)return Float.POSITIVE_INFINITY;
    Collections.sort(residuals);
    int keep=constrain(round(residuals.size()*min(cfg.icpTrimFraction,0.70f)),cfg.icpMinimumMatches,residuals.size());
    double sum=0;for(int i=0;i<keep;i++)sum+=residuals.get(i);
    float mse=(float)(sum/keep);return mse*(1.0f+2.0f*(1.0f-ov));
  }

  PVector robustCloudCenter(PointCloud cloud,RigidTransform transform){
    if(cloud==null||cloud.size()==0)return new PVector();int step=max(1,cloud.size()/1200),n=0;float[] xs=new float[(cloud.size()+step-1)/step],ys=new float[xs.length],zs=new float[xs.length];
    for(int i=0;i<cloud.size();i+=step){if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;PVector p=transform.apply(cloud.points.get(i));xs[n]=p.x;ys[n]=p.y;zs[n]=p.z;n++;}
    if(n==0)return cloud.centroidTransformed(transform);Arrays.sort(xs,0,n);Arrays.sort(ys,0,n);Arrays.sort(zs,0,n);int lo=constrain(round((n-1)*0.20f),0,n-1),hi=constrain(round((n-1)*0.80f),lo,n-1),mid=n/2;return new PVector((xs[lo]+xs[hi])*0.5f,ys[mid],(zs[lo]+zs[hi])*0.5f);
  }
  float yawDeltaDeg(RigidTransform from,RigidTransform to){RigidTransform d=to.multiply(from.inverseRigid());return degrees(atan2(d.m[2],d.m[0]));}

  float trimThreshold(ArrayList<Float> values,float fraction,int minimum){
    int n=values.size();if(n==0)return Float.POSITIVE_INFINITY;float[] sorted=new float[n];
    for(int i=0;i<n;i++)sorted[i]=values.get(i);Arrays.sort(sorted);
    int keep=max(minimum,round(n*constrain(fraction,0.50f,1.0f)));keep=constrain(keep,1,n);
    return sorted[keep-1];
  }

  void addFusionReference(PointCloud current,RigidTransform transform){
    int frames=max(2,cfg.icpReferenceFrames),perFrame=max(cfg.icpMinimumMatches,cfg.icpReferenceMaxPoints/frames);
    PointCloud world=current.transformed(transform,perFrame);fusionReferenceWindow.addLast(world);
    while(fusionReferenceWindow.size()>frames)fusionReferenceWindow.removeFirst();
  }

  void addReference(PointCloud current,RigidTransform transform){
    int frames=max(1,cfg.icpReferenceFrames),perFrame=max(cfg.icpMinimumMatches,cfg.icpReferenceMaxPoints/frames);

    PointCloud world=current.transformed(transform,perFrame);reference=world;referenceWindow.addLast(world);
    while(referenceWindow.size()>frames)referenceWindow.removeFirst();
  }

  RigidTransform applyMotionPrior(RigidTransform estimate, MotionSample motion){
    motionPriorUsed=false;
    if(motion==null || !motion.gravityReliable()) return estimate;
    PVector g=motion.gravityUnit();
    if(g==null) return estimate;
    if(gravityReference==null){ gravityReference=g.copy(); return estimate; }

    PVector currentWorld=estimate.rotate(g);
    if(currentWorld.magSq()<1e-8f) return estimate;
    currentWorld.normalize();
    PVector target=gravityReference.copy(); target.normalize();
    RigidTransform correction=rotationBetween(currentWorld,target);
    RigidTransform corrected=correction.multiply(estimate);
    corrected.m[3]=estimate.m[3]; corrected.m[7]=estimate.m[7]; corrected.m[11]=estimate.m[11];

    motionPriorUsed=true;
    return corrected;
  }

  RigidTransform rotationBetween(PVector from, PVector to){
    PVector a=from.copy(); PVector b=to.copy();
    if(a.magSq()<1e-8f || b.magSq()<1e-8f) return new RigidTransform();
    a.normalize(); b.normalize();
    float c=constrain(a.dot(b),-1.0f,1.0f);
    PVector axis=a.cross(b);float magnitude=axis.mag();
    if(magnitude<1e-6f){
      if(c>0) return new RigidTransform();
      axis=abs(a.x)<0.8f?a.cross(new PVector(1,0,0)):a.cross(new PVector(0,1,0));
      axis.normalize();return axisAngle(axis,PI);
    }
    axis.div(magnitude);return axisAngle(axis,atan2(magnitude,c));
  }

  RigidTransform axisAngle(PVector a,float angle){
    float x=a.x,y=a.y,z=a.z,c=cos(angle),ss=sin(angle),t=1-c;
    float[][] R={{t*x*x+c,t*x*y-ss*z,t*x*z+ss*y},{t*x*y+ss*z,t*y*y+c,t*y*z-ss*x},{t*x*z-ss*y,t*y*z+ss*x,t*z*z+c}};

    return new RigidTransform().fromRotationTranslation(R,new PVector());
  }
}

// ===== SynKinect Studio / 3D Scanner / KinectSource.pde =====



class KinectSource {
  AppConfig config;
  Calibration calibration;
  DepthCalibrationStore calibrationStore;
  DepthCalibrationSession calibrationSession;
  ModuleI18n i18n;

  volatile boolean portReady = false, deviceConnected = false, depthConnected = false, colorConnected = false;

  volatile boolean metricDepthCalibrated = false, running = false, immediateReconnect = false;

  volatile boolean lastDepthRecovered = false;
  volatile boolean depthOnlyRequested = false;
  volatile boolean factoryDepthCalibrationValid = false;
  volatile double factoryDepthConstShift = 0.0, factoryDepthEmitterDistance = 0.0, factoryDepthReferenceDistance = 0.0, factoryDepthReferencePixelSize = 0.0;

  final int[] factoryDepthRawToMm = new int[2048];
  volatile int acceptedStreams = 0, capabilities = 0, negotiatedMaxPayload = 0, activeSessionMask = 0;

  volatile String lastTransportError = "", depthWarning = "";
  volatile long depthFrames = 0, colorFrames = 0, infraredFrames = 0;
  volatile long depthSequenceGaps=0,colorSequenceGaps=0;
  volatile long lastDepthArrivalMs = 0, lastColorArrivalMs = 0, lastAnyArrivalMs = 0;

  volatile long connectedSinceMs = 0, connectionEpoch = 0, reconnectKicks = 0, lastReconnectKickMs = 0;

  volatile MotionSample latestMotion = new MotionSample();

  Thread worker = null;
  volatile long runGeneration = 0;
  volatile LocalTransport activeScannerPipe = null;
 final Object pipeLock = new Object();
 final Object frameLock = new Object();
 final ArrayDeque<DepthFrame> syncDepth = new ArrayDeque<DepthFrame>();
 final ArrayDeque<RawRgbFrame> syncRgb = new ArrayDeque<RawRgbFrame>();
 final ArrayDeque<RawRgbFrame> syncHq = new ArrayDeque<RawRgbFrame>();
 final ArrayDeque<InfraredFrame> syncIr = new ArrayDeque<InfraredFrame>();
 final ArrayDeque<RawRgbFrame> hqRgbHistory = new ArrayDeque<RawRgbFrame>();
 final ArrayDeque<RgbdFramePair> rgbdQueue = new ArrayDeque<RgbdFramePair>();
 volatile RgbdFramePair latestRgbdPair=null;
 volatile DepthFrame latestDepthFrame=null;
 volatile long pairedFrames=0,droppedUnpairedDepthFrames=0,droppedUnpairedRgbFrames=0,droppedRgbdPairs=0,lastPairedArrivalMs=0,hqColorFrames=0;

 volatile boolean hqColorRequested=false,followDriverRgbHq=false;
 volatile String rgbHqSettingDeviceId="";
 volatile float latestSyncResidualMs=Float.NaN,latestRawSyncSkewMs=Float.NaN;
 double syncOffsetUs=0.0;boolean syncOffsetValid=false;long pairSequence=0;
 final byte[] frameHeaderBuffer = new byte[studio.services.scannerProtocol.FRAME_HEADER_BYTES];

 volatile byte[] depthPackedPayloadBuffer = new byte[studio.services.scannerProtocol.DEPTH_RAW11_PACKED_BYTES];

 final long[] lastFrameNumber = new long[]{-1L, -1L, -1L, -1L};
 PImage scannerPreviewImage=null;
 int[] reconstructionRgbPixels=null;

  KinectSource(AppConfig config, Calibration calibration, ModuleI18n i18n) {
    this.config = config; this.calibration = calibration; this.i18n = i18n;
  }

  synchronized void start() {
    if (running) return;
    resetConnectionState(true); droppedUnpairedDepthFrames=0; droppedUnpairedRgbFrames=0;
     droppedRgbdPairs=0; pairedFrames=0; depthSequenceGaps=0; colorSequenceGaps=0;

    running = true;
    final long generation=++runGeneration;
    worker = studio.services.workers.start("Scanner-Port",new Runnable(){ public void run(){ streamWorkerLoop(generation); }});

  }

  void requestStop(boolean clearPending) {
    Thread t;
    synchronized(this){
      running=false; ++runGeneration; closeActivePipe(); t=worker; worker=null;
    }
    if(t!=null)t.interrupt();
    synchronized(pipeLock){activeScannerPipe=null;}
    resetConnectionState(clearPending);
  }
  void requestStop(){requestStop(true);}
  void stop() { stop(true); }
  void stop(boolean clearPending) {
    Thread t;
    synchronized(this){
      if(!running&&worker==null){resetConnectionState(clearPending);return;}
      running=false; ++runGeneration; closeActivePipe(); t=worker; worker=null;
    }
    if(t!=null){
      t.interrupt();
      try{t.join(config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();
        }
      if(t.isAlive()){closeActivePipe();t.interrupt();try{t.join(config.workerJoinMs);
          }catch(InterruptedException ignored){Thread.currentThread().interrupt();
          }}
    }
    synchronized(pipeLock){activeScannerPipe=null;} resetConnectionState(clearPending);

  }

  long monotonicMs() { return System.nanoTime() / 1000000L; }
  void setActivePipe(LocalTransport pipe){ synchronized(pipeLock){ activeScannerPipe=pipe;
       } }
  void clearActivePipe(LocalTransport pipe){ synchronized(pipeLock){ if(activeScannerPipe==pipe) activeScannerPipe=null;
       } }
  LocalTransport detachActivePipe(){ synchronized(pipeLock){LocalTransport pipe=activeScannerPipe;
      activeScannerPipe=null;return pipe;} }
  void closeActivePipe(){closePipe(detachActivePipe());}
  void closePipe(LocalTransport pipe){
    if(pipe==null) return;
    try { pipe.close(); } catch(IOException e) { if(running) println("Scanner pipe close warning: " + e.getMessage());
       }
  }

  void resetConnectionState(boolean clearPending) {
    portReady=false; deviceConnected=false; depthConnected=false; colorConnected=false;
     metricDepthCalibrated=false; lastDepthRecovered=false;
    factoryDepthCalibrationValid=false; factoryDepthConstShift=factoryDepthEmitterDistance=factoryDepthReferenceDistance=factoryDepthReferencePixelSize=0.0;
     Arrays.fill(factoryDepthRawToMm,0);
    acceptedStreams=0; capabilities=0; negotiatedMaxPayload=0; activeSessionMask=0;
     depthWarning="";
    connectedSinceMs=0; lastDepthArrivalMs=0; lastColorArrivalMs=0; lastAnyArrivalMs=0;
    for(int i=0;i<lastFrameNumber.length;i++) lastFrameNumber[i]=-1L;
    synchronized(frameLock){
      // Never pair samples across a transport epoch. Preserve already-published pairs
      // only when reconnecting in place so consumers can drain them deterministically.
      syncDepth.clear();syncRgb.clear();syncHq.clear();hqRgbHistory.clear();syncOffsetUs=0;
      syncOffsetValid=false;latestSyncResidualMs=Float.NaN;latestRawSyncSkewMs=Float.NaN;

      if(clearPending){rgbdQueue.clear();latestRgbdPair=null;latestDepthFrame=null;pairSequence=0;}
    }
  }

  void updateLiveness() {
    long now = monotonicMs();
    colorConnected = lastColorArrivalMs > 0 && now - lastColorArrivalMs <= config.streamStaleTimeoutMs;

    boolean depthFresh = lastDepthArrivalMs > 0 && now - lastDepthArrivalMs <= config.streamStaleTimeoutMs;

    if (!depthFresh) {
      depthConnected = false; metricDepthCalibrated = false; lastDepthRecovered = false;

      if (lastDepthArrivalMs > 0) depthWarning = i18n.tr("transport.depth_stale");

      else if (portReady && colorFrames >= 30) depthWarning = i18n.tr("transport.depth_no_frames");

    }
    deviceConnected = lastAnyArrivalMs > 0 && now - lastAnyArrivalMs <= config.connectionStaleTimeoutMs;

    // A pipe can remain open while its server-side session is no longer producing frames.
    // Start a fresh subscription whenever the active session is no longer usable.
    long anchor = lastAnyArrivalMs > 0 ? lastAnyArrivalMs : connectedSinceMs;
    if (portReady && anchor > 0 && now - anchor > config.connectionStaleTimeoutMs) requestReconnect("stale-session");

  }

  void setDepthOnlyRequested(boolean requested){
    boolean changed=depthOnlyRequested!=requested;depthOnlyRequested=requested;
    if(changed&&running)requestReconnect(requested?"switch-depth-only":"switch-rgbd");
  }

  void setHqColorRequested(boolean requested){
    boolean changed=hqColorRequested!=requested;
    hqColorRequested=requested;
    if(!requested)synchronized(frameLock){hqRgbHistory.clear();}
    // Re-negotiate only when the desired stream set differs from the active set. The Scanner
    // requests HQ before starting its transport, so pressing SCAN never causes this.
    if(changed&&running){
      boolean sessionHasHq=(activeSessionMask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0;

      if(sessionHasHq!=requested)requestReconnect(requested?"switch-hq":"switch-vga");

    }
  }

  void setFollowDriverRgbHq(boolean follow){
    followDriverRgbHq=follow;
    if(!follow)setHqColorRequested(false);
  }

  boolean queryDriverRgbHq(KinectDevice selected){
    if(selected==null||selected.endpoint==null||selected.endpoint.length()==0)return false;
    final boolean cachedValue=selected.id.equals(rgbHqSettingDeviceId)?hqColorRequested:false;
    for(int attempt=0;attempt<3;attempt++){
      LocalTransport settingsPipe=null;
      try{
        settingsPipe=studio.services.transportFactory.openEndpoint(selected.endpoint);
        ByteBuffer req=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);
        req.putInt(studio.services.scannerProtocol.MAGIC);
        req.putInt(studio.services.scannerProtocol.VERSION);
        req.putInt(studio.services.scannerProtocol.CMD_GET_DRIVER_SETTINGS);
        req.putInt(0);
        settingsPipe.write(req.array());
        byte[] rb=new byte[studio.services.scannerProtocol.REPLY_BYTES];
        settingsPipe.readFully(rb);
        ByteBuffer reply=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
        int magic=reply.getInt(),version=reply.getInt(),result=reply.getInt(),settings=reply.getInt();
        if(magic==studio.services.scannerProtocol.MAGIC&&version==studio.services.scannerProtocol.VERSION&&result==0){
          rgbHqSettingDeviceId=selected.id;
          return (settings&studio.services.scannerProtocol.DRIVER_RGB_HQ)!=0;
        }
      }catch(Exception ignored){}
      finally{closePipe(settingsPipe);}
      if(attempt<2)try{Thread.sleep(80);}catch(InterruptedException interrupted){Thread.currentThread().interrupt();break;}
    }
    return cachedValue;
  }

  void applyDriverRgbHq(KinectDevice selected,boolean enabled){
    if(selected==null)return;
    rgbHqSettingDeviceId=selected.id;
    if(followDriverRgbHq)setHqColorRequested(enabled);
  }

  boolean refreshDriverRgbHq(KinectDevice selected){
    boolean enabled=queryDriverRgbHq(selected);
    applyDriverRgbHq(selected,enabled);
    return enabled;
  }

  void requestReconnect(String reason){requestReconnect(reason,false);}
  void requestReconnect(String reason,boolean force){
    if(!running)return;
    long now=monotonicMs();
    if(!force&&now-lastReconnectKickMs<Math.max(100,config.reconnectDelayMs))return;

    lastReconnectKickMs=now; reconnectKicks++; lastTransportError=i18n.format("transport.error",reason);

    if(force)immediateReconnect=true;final LocalTransport reconnectPipe=detachActivePipe();

    studio.services.workers.start("Scanner-Reconnect",new Runnable(){public void run(){closePipe(reconnectPipe);}});

  }

  RgbdFramePair pollRgbdPair(){synchronized(frameLock){return rgbdQueue.isEmpty()?null:rgbdQueue.removeFirst();
      }}
  RgbdFramePair latestRgbdPairAfter(long sequence){synchronized(frameLock){RgbdFramePair p=latestRgbdPair;
      return p!=null&&p.sequence>sequence?p:null;}}
  int queuedRgbdPairs(){synchronized(frameLock){return rgbdQueue.size();}}
  void clearConsumerPairs(){synchronized(frameLock){rgbdQueue.clear();}}
  RgbSnapshot rgbPreviewSnapshot(RgbdFramePair pair){
    if(pair==null)return null;
    if(pair.rgb!=null&&pair.rgb.data!=null){
      int w=pair.rgb.width,h=pair.rgb.height;
      if(scannerPreviewImage==null||scannerPreviewImage.width!=w||scannerPreviewImage.height!=h)scannerPreviewImage=createImage(w,h,RGB);

      scannerPreviewImage.loadPixels();
      boolean decoded=decodeRgbPayloadToArgb(pair.rgb.data,w,h,pair.rgb.pixelFormat,scannerPreviewImage.pixels);
      if(!decoded)return null;
      scannerPreviewImage.updatePixels();
      return new RgbSnapshot(scannerPreviewImage.pixels,w,h,scannerPreviewImage,pair.rgb.frameNumber,pair.rgb.timestampUs,System.currentTimeMillis(),pair.residualUs/1000.0f,
        pair.rawSkewUs/1000.0f,config.rgbMaxSyncSkewMs,pair.rgb.quality);
    }
    if(pair.hq!=null&&pair.hq.data!=null&&pair.hq.highQuality()){
      int w=pair.hq.width/2,h=pair.hq.height/2;
      if(scannerPreviewImage==null||scannerPreviewImage.width!=w||scannerPreviewImage.height!=h)scannerPreviewImage=createImage(w,h,RGB);

      scannerPreviewImage.loadPixels();
      if(!decodeBayerGrbgHalf(pair.hq.data,pair.hq.width,pair.hq.height,scannerPreviewImage.pixels))return null;

      scannerPreviewImage.updatePixels();
      return new RgbSnapshot(scannerPreviewImage.pixels,w,h,scannerPreviewImage,pair.hq.frameNumber,pair.hq.timestampUs,System.currentTimeMillis(),pair.residualUs/1000.0f,
        pair.rawSkewUs/1000.0f,config.rgbHqMaxSyncSkewMs,pair.hq.quality);
    }
    return null;
  }

  boolean decodeBayerGrbgHalf(byte[] data,int w,int h,int[] out){
    if(data==null||w<2||h<2||(w&1)!=0||(h&1)!=0||data.length!=w*h||out==null||out.length<(w/2)*(h/2))return false;

    int ow=w/2,index=0;
    for(int y=0;y<h;y+=2){
      int row0=y*w,row1=(y+1)*w;
      for(int x=0;x<w;x+=2){
        int g0=data[row0+x]&0xff,r=data[row0+x+1]&0xff,b=data[row1+x]&0xff,g1=data[row1+x+1]&0xff;

        int g=(g0+g1+1)>>1;
        out[index++]=0xff000000|(r<<16)|(g<<8)|b;
      }
    }
    return true;
  }
  RgbSnapshot rgbReconstructionSnapshot(RgbdFramePair pair){
    if(pair==null||pair.rgb==null||pair.rgb.data==null)return null;
    int w=pair.rgb.width,h=pair.rgb.height,count=w*h;
    if(reconstructionRgbPixels==null||reconstructionRgbPixels.length!=count)reconstructionRgbPixels=new int[count];

    boolean decoded=decodeRgbPayloadToArgb(pair.rgb.data,w,h,pair.rgb.pixelFormat,reconstructionRgbPixels);
    if(!decoded)return null;
    return new RgbSnapshot(reconstructionRgbPixels,w,h,null,pair.rgb.frameNumber,pair.rgb.timestampUs,System.currentTimeMillis(),pair.residualUs/1000.0f,
      pair.rawSkewUs/1000.0f,config.rgbMaxSyncSkewMs,pair.rgb.quality);
  }
  DepthFrame latestDepthAfter(long frameNumber){
    synchronized(frameLock){
      DepthFrame f=latestDepthFrame;
      return f!=null&&f.frameNumber>frameNumber?f:null;
    }
  }
  void offerDepth(DepthFrame f){synchronized(frameLock){latestDepthFrame=f;syncDepth.addLast(f);trimSyncQueuesLocked();
      pairRgbdLocked();}}
  void offerRgb(RawRgbFrame f){
    synchronized(frameLock){
      syncRgb.addLast(f);
      trimSyncQueuesLocked();pairRgbdLocked();
    }
  }
  void offerHqRgb(RawRgbFrame f){
    synchronized(frameLock){
      syncHq.addLast(f);hqRgbHistory.addLast(f);while(hqRgbHistory.size()>config.rgbHqHistoryFrames)hqRgbHistory.removeFirst();
      hqColorFrames++;trimSyncQueuesLocked();pairRgbdLocked();
    }
  }
  RawRgbFrame bestHqRgbFor(long timestampUs){synchronized(frameLock){RawRgbFrame best=null;
      long bestSkew=Long.MAX_VALUE;for(RawRgbFrame f:hqRgbHistory){long skew=Math.abs(f.timestampUs-timestampUs);
        if(skew<bestSkew){bestSkew=skew;best=f;}}return best!=null&&bestSkew<=Math.round(config.rgbHqMaxSyncSkewMs*1000.0f)?best:null;
      }}
  void offerInfrared(InfraredFrame f){synchronized(frameLock){syncIr.addLast(f);while(syncIr.size()>config.rgbdSyncHistoryFrames)syncIr.removeFirst();infraredFrames++;}}
  InfraredFrame nearestInfraredLocked(long timestampUs){
    InfraredFrame best=null;long bestSkew=Long.MAX_VALUE;
    for(InfraredFrame f:syncIr){long skew=Math.abs(f.timestampUs-timestampUs);if(skew<bestSkew){bestSkew=skew;best=f;}}
    long limit=Math.round(max(config.rgbMaxSyncSkewMs,config.rgbdSyncMaxResidualMs)*1000.0f);
    while(syncIr.size()>1&&syncIr.peekFirst()!=best&&syncIr.peekFirst().timestampUs<timestampUs-limit)syncIr.removeFirst();
    return best!=null&&bestSkew<=limit?best:null;
  }
  void trimSyncQueuesLocked(){
    while(syncDepth.size()>config.rgbdSyncHistoryFrames){syncDepth.removeFirst();
      droppedUnpairedDepthFrames++;}
    while(syncRgb.size()>config.rgbdSyncHistoryFrames){syncRgb.removeFirst();droppedUnpairedRgbFrames++;
      }
    while(syncHq.size()>config.rgbdSyncHistoryFrames){syncHq.removeFirst();droppedUnpairedRgbFrames++;
      }
  }
  RawRgbFrame nearestRgbLocked(long timestampUs){
    RawRgbFrame best=null;long bestSkew=Long.MAX_VALUE;
    for(RawRgbFrame f:syncRgb){long skew=Math.abs(f.timestampUs-timestampUs);if(skew<bestSkew){bestSkew=skew;
        best=f;}}
    if(best==null||bestSkew>Math.round(config.rgbMaxSyncSkewMs*1000.0f))return null;

    while(!syncRgb.isEmpty()&&syncRgb.peekFirst()!=best){syncRgb.removeFirst();droppedUnpairedRgbFrames++;
      }
    if(!syncRgb.isEmpty())syncRgb.removeFirst();
    return best;
  }
  void pairRgbdLocked(){
    boolean hqRequested=(activeSessionMask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0;

    boolean hq=hqRequested&&!syncHq.isEmpty();
    ArrayDeque<RawRgbFrame> colors=hq?syncHq:syncRgb;
    final long maxResidual=(long)((hq?config.rgbHqMaxSyncSkewMs:config.rgbdSyncMaxResidualMs)*1000.0f);

    final long bootstrap=(long)(config.rgbdSyncBootstrapMaxSkewMs*1000.0f);
    while(!syncDepth.isEmpty()&&!colors.isEmpty()){
      DepthFrame bestD=null;RawRgbFrame bestR=null;long bestMetric=Long.MAX_VALUE,bestDelta=0;

      for(DepthFrame d:syncDepth)for(RawRgbFrame r:colors){
        long delta=r.timestampUs-d.timestampUs;
        long metric=Math.abs(delta-(syncOffsetValid?Math.round(syncOffsetUs):0L));

        if(metric<bestMetric){bestMetric=metric;bestDelta=delta;bestD=d;bestR=r;}
      }
      long limit=syncOffsetValid?maxResidual:bootstrap;
      if(bestD!=null&&bestMetric<=limit){
        while(!syncDepth.isEmpty()&&syncDepth.peekFirst()!=bestD){syncDepth.removeFirst();
          droppedUnpairedDepthFrames++;}if(!syncDepth.isEmpty())syncDepth.removeFirst();

        while(!colors.isEmpty()&&colors.peekFirst()!=bestR){colors.removeFirst();
          droppedUnpairedRgbFrames++;}if(!colors.isEmpty())colors.removeFirst();
        RawRgbFrame pairedVga=hq?nearestRgbLocked(bestR.timestampUs):bestR;
        if(!syncOffsetValid){syncOffsetUs=bestDelta;syncOffsetValid=true;}else syncOffsetUs=syncOffsetUs*(1.0-config.rgbdSyncOffsetAlpha)+bestDelta*config.rgbdSyncOffsetAlpha;

        long residual=Math.abs(bestDelta-Math.round(syncOffsetUs)),raw=Math.abs(bestDelta);
        float q=1.0f-constrain(residual/(float)Math.max(1,maxResidual),0,1);
        InfraredFrame pairedIr=nearestInfraredLocked(bestD.timestampUs);
        RgbdFramePair pair=new RgbdFramePair(bestD,pairedVga,hq?bestR:null,pairedIr,++pairSequence,raw,residual,q);

        latestRgbdPair=pair;pairedFrames++;lastPairedArrivalMs=monotonicMs();latestSyncResidualMs=residual/1000.0f;
        latestRawSyncSkewMs=raw/1000.0f;
        if(rgbdQueue.size()>=config.rgbdQueueFrames){rgbdQueue.removeFirst();droppedRgbdPairs++;
          }rgbdQueue.addLast(pair);continue;
      }
      DepthFrame d=syncDepth.peekFirst();RawRgbFrame r=colors.peekFirst();long adjusted=(r.timestampUs-d.timestampUs)-(syncOffsetValid?Math.round(syncOffsetUs):0L);

      if(adjusted>limit){syncDepth.removeFirst();droppedUnpairedDepthFrames++;continue;
        }
      if(adjusted<-limit){colors.removeFirst();droppedUnpairedRgbFrames++;continue;
        }
      break;
    }
  }

  void streamWorkerLoop(long generation){
    while(running&&generation==runGeneration){
      LocalTransport pipe=null;
      try{
        resetConnectionState(false);
        KinectDevice selected=studio.selectedKinect();if(selected==null)throw new IOException("no Kinect detected");

        if(!selected.cameraReady())throw new IOException("Kinect camera transport is still initializing: "+selected.label);

        pipe=studio.services.transportFactory.openEndpoint(selected.endpoint); setActivePipe(pipe);

        if(followDriverRgbHq)setHqColorRequested(queryDriverRgbHq(selected));
        KinectDevice activeDevice=studio.selectedKinect();
        boolean useIr=activeDevice!=null&&activeDevice.hasCapability("infrared")&&"xbox-one".equals(activeDevice.generation);
        int sessionMask=depthOnlyRequested?studio.services.scannerProtocol.STREAM_DEPTH:
          ((hqColorRequested?studio.services.scannerProtocol.STREAM_SESSION_HQ:studio.services.scannerProtocol.STREAM_SESSION)
          |(useIr?studio.services.scannerProtocol.STREAM_IR:0));
        subscribe(pipe,sessionMask);
        activeSessionMask=sessionMask;
        connectedSinceMs=monotonicMs(); connectionEpoch++; lastTransportError="";

        while(running&&generation==runGeneration) readFrame(pipe,sessionMask);
      } catch(Exception e) {
        if(generation==runGeneration){
          resetConnectionState(false);
          if(running) lastTransportError=i18n.format("transport.error", safeMessage(e));

        }
      } finally { clearActivePipe(pipe); closePipe(pipe); }
      if(running&&generation==runGeneration){if(immediateReconnect){immediateReconnect=false;
          continue;}try{Thread.sleep(config.reconnectDelayMs);}catch(InterruptedException ignored){if(!running||generation!=runGeneration)return;
          Thread.currentThread().interrupt();return;}}
    }
  }

  void subscribe(LocalTransport pipe,int mask)throws IOException{
    int coreMask=mask&~studio.services.scannerProtocol.STREAM_IR;
    if(coreMask!=studio.services.scannerProtocol.STREAM_DEPTH&&coreMask!=studio.services.scannerProtocol.STREAM_SESSION&&coreMask!=studio.services.scannerProtocol.STREAM_SESSION_HQ) throw new IOException("protocol/stream-mask:"+mask);

    KinectDevice requestDevice=studio.selectedKinect();
    boolean nativeOne=requestDevice!=null&&"xbox-one".equals(requestDevice.generation);
    ByteBuffer req=ByteBuffer.allocate(nativeOne?80:16).order(ByteOrder.LITTLE_ENDIAN);
    req.putInt(studio.services.scannerProtocol.MAGIC); req.putInt(studio.services.scannerProtocol.VERSION);
    req.putInt(studio.services.scannerProtocol.CMD_SUBSCRIBE_STREAMS); req.putInt(mask);
    if(nativeOne){byte[] idBytes=requestDevice.id.getBytes(java.nio.charset.StandardCharsets.UTF_8);int n=min(63,idBytes.length);req.put(idBytes,0,n);while(req.position()<80)req.put((byte)0);}
    pipe.write(req.array());

    byte[] rb=new byte[studio.services.scannerProtocol.REPLY_BYTES]; pipe.readFully(rb);
     ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(), version=r.getInt(), result=r.getInt(), accepted=r.getInt();

    int w=r.getInt(), h=r.getInt(), caps=r.getInt(), maxPayload=r.getInt();
    int depthCalibrationValid=r.getInt();
    double depthConstShift=r.getDouble(),depthEmitterDistance=r.getDouble(),depthReferenceDistance=r.getDouble(),depthReferencePixelSize=r.getDouble();

    if(magic!=studio.services.scannerProtocol.MAGIC) throw new IOException("protocol/reply-magic");

    if(version!=studio.services.scannerProtocol.VERSION) throw new IOException("protocol/version:"+version);

    if(result<0) throw new IOException("protocol/subscribe:0x"+Integer.toHexString(result));

    if(accepted!=mask) throw new IOException("protocol/accepted-mask:"+accepted+"/"+mask);

    KinectDevice selectedDevice=studio.selectedKinect();boolean xbox360=selectedDevice==null||"xbox-360".equals(selectedDevice.generation);
    if(w<=0||h<=0)throw new IOException("protocol/dimensions:"+w+"x"+h);
    if(xbox360&&(w!=studio.services.scannerProtocol.WIDTH||h!=studio.services.scannerProtocol.HEIGHT))throw new IOException("protocol/dimensions:"+w+"x"+h);
    if(xbox360&&(caps&studio.services.scannerProtocol.REQUIRED_CAPABILITIES)!=studio.services.scannerProtocol.REQUIRED_CAPABILITIES) throw new IOException("protocol/capabilities:0x"+Integer.toHexString(caps));

    if((mask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0&&(caps&studio.services.scannerProtocol.CAP_RGB_HQ)==0) throw new IOException("protocol/rgb-hq-capability");

    int requiredPayload;
    if(xbox360)requiredPayload=(mask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0?studio.services.scannerProtocol.RGB_HQ_BYTES:studio.services.scannerProtocol.DEPTH_RAW11_PACKED_BYTES;
    else{int colorBytes=selectedDevice!=null&&selectedDevice.colorWidth>0&&selectedDevice.colorHeight>0?selectedDevice.colorWidth*selectedDevice.colorHeight*4:0;int depthBytes=w*h*2;requiredPayload=max(1,max(colorBytes,depthBytes));}
    if(maxPayload<requiredPayload) throw new IOException("protocol/max-payload:"+maxPayload+"/"+requiredPayload);

    acceptedStreams=accepted; capabilities=caps; negotiatedMaxPayload=maxPayload;

    if(nativeOne&&depthCalibrationValid==2){
      calibration.applyNativeIntrinsics(w,h,depthConstShift,depthEmitterDistance,depthReferenceDistance,depthReferencePixelSize);
      metricDepthCalibrated=true;factoryDepthCalibrationValid=false;
    }else configureFactoryDepthCalibration(depthCalibrationValid!=0,depthConstShift,depthEmitterDistance,depthReferenceDistance,depthReferencePixelSize);

    portReady=true;
  }

  void configureFactoryDepthCalibration(boolean valid,double constShift,double emitterDistance,double referenceDistance,double referencePixelSize){
    factoryDepthCalibrationValid=valid&&Double.isFinite(constShift)&&Double.isFinite(emitterDistance)&&Double.isFinite(referenceDistance)&&Double.isFinite(referencePixelSize)&&constShift>0&&emitterDistance>0&&referenceDistance>0&&referencePixelSize>0;

    factoryDepthConstShift=constShift;factoryDepthEmitterDistance=emitterDistance;
    factoryDepthReferenceDistance=referenceDistance;factoryDepthReferencePixelSize=referencePixelSize;
    Arrays.fill(factoryDepthRawToMm,0);
    if(!factoryDepthCalibrationValid)return;
    for(int raw=0;raw<2047;raw++){double fixedRefX=((raw-(4.0*constShift))/4.0)-0.375;
      double metric=fixedRefX*referencePixelSize;double denominator=emitterDistance-metric;
      if(Math.abs(denominator)<1e-9)continue;double mm=10.0*((metric*referenceDistance/denominator)+referenceDistance);
      if(Double.isFinite(mm)&&mm>=1.0&&mm<=10000.0)factoryDepthRawToMm[raw]=(int)Math.round(mm);
      }
    factoryDepthRawToMm[2047]=0;metricDepthCalibrated=true;
  }

  void readFrame(LocalTransport input,int sessionMask)throws IOException{
    input.readFully(frameHeaderBuffer);
    ByteBuffer h=ByteBuffer.wrap(frameHeaderBuffer).order(ByteOrder.LITTLE_ENDIAN);

    int magic=h.getInt(), version=h.getInt(), mode=h.getInt(), w=h.getInt(), hh=h.getInt(), fmt=h.getInt(), bytes=h.getInt(), flags=h.getInt();

    long frameNumber=h.getLong(), tickMs=h.getLong();
    MotionSample motion=new MotionSample();
    motion.flags=h.getInt(); motion.accelX=h.getInt(); motion.accelY=h.getInt(); motion.accelZ=h.getInt();
     motion.tiltTenths=h.getInt(); motion.timestampMs=h.getLong();

    if(magic!=studio.services.scannerProtocol.FRAME_MAGIC) throw new IOException("frame/magic");

    if(version!=studio.services.scannerProtocol.VERSION) throw new IOException("frame/version:"+version);

    if(!scannerDimensionsAllowedForMode(mode,w,hh)) throw new IOException("frame/dimensions:"+mode+":"+w+"x"+hh);

    int modeMask=scannerMaskForMode(mode);
    if(modeMask==0 || (sessionMask&modeMask)==0) throw new IOException("frame/mode:"+mode);

    if(bytes<0||bytes>negotiatedMaxPayload||bytes>studio.services.scannerProtocol.ABSOLUTE_MAX_PAYLOAD_BYTES) throw new IOException("frame/payload:"+bytes);

    if((flags&~studio.services.scannerProtocol.KNOWN_FRAME_FLAGS)!=0) throw new IOException("frame/flags:0x"+Integer.toHexString(flags));

    boolean dropOutOfOrder=lastFrameNumber[mode]>=0 && frameNumber<=lastFrameNumber[mode];

    if(lastFrameNumber[mode]>=0 && frameNumber>lastFrameNumber[mode]+1){
      long missed=frameNumber-lastFrameNumber[mode]-1;
      if(mode==studio.services.scannerProtocol.MODE_DEPTH)depthSequenceGaps+=missed;
      else colorSequenceGaps+=missed;
    }
    if(!scannerFormatAllowedForMode(mode,fmt)) throw new IOException("frame/format:"+mode+"/"+fmt);

    if(!scannerPayloadAllowedForMode(mode,fmt,bytes)) throw new IOException("frame/size:"+mode+"/"+fmt+"/"+bytes);


    byte[] payload;
    if(mode==studio.services.scannerProtocol.MODE_DEPTH){if(depthPackedPayloadBuffer==null||depthPackedPayloadBuffer.length!=bytes)depthPackedPayloadBuffer=new byte[bytes];payload=depthPackedPayloadBuffer;}
    else payload=new byte[bytes];
    input.readFully(payload);
    long arrival=monotonicMs(); lastAnyArrivalMs=arrival; deviceConnected=true;
    if(dropOutOfOrder){
      lastTransportError=i18n.format("transport.error","frame-order");
      return;
    }
    lastFrameNumber[mode]=frameNumber;
    lastTransportError="";

    if(mode==studio.services.scannerProtocol.MODE_DEPTH){
      DepthFrame f=new DepthFrame();
      f.frameId=(int)(frameNumber&0x7FFFFFFF); f.frameNumber=frameNumber; f.timestampUs=tickMs*1000L;

      f.width=w; f.height=hh; f.stride=w*2; f.pixelFormat=studio.services.scannerProtocol.DEPTH_FRAME_MM16;
      f.depth=new short[w*hh];f.motion=motion; latestMotion=motion;
      boolean metric16=fmt==studio.services.scannerProtocol.DEPTH_FRAME_MM16;
      f.deviceCalibrated=metric16||factoryDepthCalibrationValid;
      f.transportRecovered=(flags&studio.services.scannerProtocol.FLAG_FRAME_RECOVERED)!=0;
      int valid=0,plausible=0;
      if(metric16){ByteBuffer db=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);for(int i=0;i<f.depth.length;i++){int mm=db.getShort()&0xFFFF;f.depth[i]=(short)mm;if(mm!=0)valid++;if(mm>=config.depthPlausibleMinMm&&mm<=config.depthPlausibleMaxMm)plausible++;}}
      else{int srcIndex=0,bitsIn=0;long bitBuffer=0L;for(int i=0;i<f.depth.length;i++){int raw;while(bitsIn<11){bitBuffer=(bitBuffer<<8)|(payload[srcIndex++]&0xFFL);bitsIn+=8;}bitsIn-=11;raw=(int)((bitBuffer>>bitsIn)&0x7FFL);if(bitsIn==0)bitBuffer=0L;else bitBuffer&=(1L<<bitsIn)-1L;int mm=(raw>=0&&raw<factoryDepthRawToMm.length)?factoryDepthRawToMm[raw]:0;f.depth[i]=(short)(mm&0xFFFF);if(mm!=0)valid++;if(mm>=config.depthPlausibleMinMm&&mm<=config.depthPlausibleMaxMm)plausible++;}}
      f.validCount=valid; f.plausibleCount=plausible;
      float ratio=plausible/(float)f.depth.length;
      depthConnected=f.deviceCalibrated && plausible>=config.depthMinValidPixels && ratio>=config.depthMinValidRatio;

      metricDepthCalibrated=f.deviceCalibrated; lastDepthRecovered=f.transportRecovered;

      depthWarning = depthConnected ? "" : i18n.format(f.deviceCalibrated ? "transport.depth_sparse" : "transport.depth_uncalibrated", plausible, ratio*100.0f);

      offerDepth(f);
      depthFrames++; lastDepthArrivalMs=arrival;
    } else if(mode==studio.services.scannerProtocol.MODE_IR) {
      short[] ir=new short[w*hh];ByteBuffer ib=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);long energy=0;int usable=0;
      for(int i=0;i<ir.length;i++){int v=ib.getShort()&0xffff;ir[i]=(short)v;if(v>0){usable++;energy+=min(v,65535);}}
      float coverage=usable/(float)max(1,ir.length);float mean=usable==0?0:energy/(float)usable;float quality=constrain(coverage*(.35f+.65f*constrain(mean/12000.0f,0,1)),0,1);
      offerInfrared(new InfraredFrame(ir,w,hh,frameNumber,tickMs*1000L,quality));
    } else if(mode==studio.services.scannerProtocol.MODE_RGB) {
      float q=RgbFrameQuality.score(payload,w,hh,fmt);
      offerRgb(new RawRgbFrame(payload,w,hh,fmt,frameNumber,tickMs*1000L,q));
      colorConnected=true; colorFrames++; lastColorArrivalMs=arrival;
    } else if(mode==studio.services.scannerProtocol.MODE_RGB_HQ) {
      float q=RgbFrameQuality.score(payload,w,hh,fmt);
      offerHqRgb(new RawRgbFrame(payload,w,hh,fmt,frameNumber,tickMs*1000L,q));
      colorConnected=true; lastColorArrivalMs=arrival;
    }
  }

  boolean decodeJpegToArgb(byte[] data,int w,int h,int[] out){
    if(data==null||out==null||out.length<w*h)return false;
    try{
      BufferedImage image=ImageIO.read(new ByteArrayInputStream(data));
      if(image==null)return false;
      if(image.getWidth()==w&&image.getHeight()==h){image.getRGB(0,0,w,h,out,0,w);return true;}
      BufferedImage scaled=new BufferedImage(w,h,BufferedImage.TYPE_INT_ARGB);Graphics2D g=scaled.createGraphics();
      try{g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,RenderingHints.VALUE_INTERPOLATION_BILINEAR);g.drawImage(image,0,0,w,h,null);}finally{g.dispose();}
      scaled.getRGB(0,0,w,h,out,0,w);return true;
    }catch(Exception ignored){return false;}
  }

  boolean decodeRgbPayloadToArgb(byte[] data,int w,int h,int fmt,int[] out){
    if(fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8)return RgbHqProcessor.decodeBayerGrbg(data,w,h,out);
    if(fmt==studio.services.scannerProtocol.PIXEL_NV12)return decodeNv12ToArgb(data,w,h,out);
    if(fmt==studio.services.scannerProtocol.PIXEL_BGRA32)return decodeBgra32ToArgb(data,w,h,out);
    if(fmt==studio.services.scannerProtocol.PIXEL_JPEG)return decodeJpegToArgb(data,w,h,out);
    return false;
  }

  boolean decodeNv12ToArgb(byte[] data,int w,int h,int[] out){
    if(data==null||out==null||data.length!=w*h*3/2||out.length<w*h)return false;
    int ySize=w*h;
    for(int y=0;y<h;y++){
      int row=y*w,uvRow=ySize+(y/2)*w;
      for(int x=0;x<w;x++){
        int yi=data[row+x]&0xFF,uv=uvRow+(x&~1),u=(data[uv]&0xFF)-128,v=(data[uv+1]&0xFF)-128;

        int c=max(0,yi-16),rr=(298*c+409*v+128)>>8,gg=(298*c-100*u-208*v+128)>>8,bb=(298*c+516*u+128)>>8;

        out[row+x]=0xFF000000|(constrain(rr,0,255)<<16)|(constrain(gg,0,255)<<8)|constrain(bb,0,255);

      }
    }
    return true;
  }

  String displayError(){
    if(lastTransportError.length()>0)return i18n.tr("transport.unavailable");
    if(droppedRgbdPairs>0)return i18n.format("transport.pairs_dropped",droppedRgbdPairs);

    return depthWarning;
  }
  String safeMessage(Exception e){ String m=e.getMessage(); return(m==null||m.length()==0)?e.getClass().getSimpleName():m;
     }
}


// ===== SynKinect Studio / 3D Scanner / Localization.pde =====
class ScannerI18n extends ModuleI18n {
  ScannerI18n(String requested){super("scanner",requested);}
}


class ScannerTheme {
  // High-contrast dark surfaces with a restrained blue status accent.
  final int BG = 0xFF11151A;
  final int SURFACE = 0xFF181E25;
  final int SURFACE_ALT = 0xFF202832;
  final int SURFACE_RAISED = 0xFF293440;
  final int BORDER = 0xFF35414D;
  final int TEXT = 0xFFF4F7FA;
  final int TEXT_MUTED = 0xFFAAB6C2;
  final int ACCENT = 0xFF68A9E8;
  final int ACCENT_SOFT = 0xFF203A52;
  final int GOOD = 0xFF7CC7A0;
  final int WARN = 0xFFE4B86B;
  final int BAD = 0xFFE17D7D;
  // Reconstruction viewport uses a neutral CAD-like light environment even
  // though the surrounding Studio chrome remains dark.
  final int GRID = 0xFFB8BEC5;
  final int PREVIEW = 0xFFE4E7EA;
  final int MESH = 0xFF71879A;
  final int SIDEBAR_W = 430;

  final int FONT_TINY = STUDIO_FONT_TINY;
  final int FONT_SMALL = STUDIO_FONT_SMALL;
  final int FONT_BODY = STUDIO_FONT_BODY;
  final int FONT_METRIC = STUDIO_FONT_METRIC;
  final int FONT_TITLE = STUDIO_FONT_TITLE;
}

void initializeScannerTypography(){if(studioUnicodeRegular==null||studioUnicodeHeading==null)initializeStudioTypography();
  }

void uiText(float size,boolean heading){studioText(size,heading);}


// ===== SynKinect Studio / 3D Scanner / Math3D.pde =====
class RigidTransform {
  float[] m = new float[16];

  RigidTransform() { setIdentity(); }

  void setIdentity() {
    Arrays.fill(m, 0);
    m[0] = m[5] = m[10] = m[15] = 1;
  }

  void set(RigidTransform o) { arrayCopy(o.m, m); }

  PVector apply(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z + m[3],
      m[4]*p.x + m[5]*p.y + m[6]*p.z + m[7],
      m[8]*p.x + m[9]*p.y + m[10]*p.z + m[11]
    );
  }

  PVector rotate(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z,
      m[4]*p.x + m[5]*p.y + m[6]*p.z,
      m[8]*p.x + m[9]*p.y + m[10]*p.z
    );
  }

  RigidTransform multiply(RigidTransform b) {
    RigidTransform r = new RigidTransform();
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 4; col++) {
        float s = 0;
        for (int k = 0; k < 4; k++) s += m[row*4+k] * b.m[k*4+col];
        r.m[row*4+col] = s;
      }
    }
    return r;
  }

  RigidTransform inverseRigid() {
    RigidTransform r=new RigidTransform();
    r.m[0]=m[0];r.m[1]=m[4];r.m[2]=m[8];
    r.m[4]=m[1];r.m[5]=m[5];r.m[6]=m[9];
    r.m[8]=m[2];r.m[9]=m[6];r.m[10]=m[10];
    r.m[3]=-(r.m[0]*m[3]+r.m[1]*m[7]+r.m[2]*m[11]);
    r.m[7]=-(r.m[4]*m[3]+r.m[5]*m[7]+r.m[6]*m[11]);
    r.m[11]=-(r.m[8]*m[3]+r.m[9]*m[7]+r.m[10]*m[11]);
    return r;
  }

  RigidTransform fromRotationTranslation(float[][] R, PVector t) {
    RigidTransform x = new RigidTransform();
    x.m[0]=R[0][0]; x.m[1]=R[0][1]; x.m[2]=R[0][2]; x.m[3]=t.x;
    x.m[4]=R[1][0]; x.m[5]=R[1][1]; x.m[6]=R[1][2]; x.m[7]=t.y;
    x.m[8]=R[2][0]; x.m[9]=R[2][1]; x.m[10]=R[2][2]; x.m[11]=t.z;
    return x;
  }
}

class QuaternionFit {
  RigidTransform fit(ArrayList<PVector> src, ArrayList<PVector> dst) {
    int n=min(src.size(),dst.size());if(n<3)return new RigidTransform();
    double csx=0,csy=0,csz=0,cdx=0,cdy=0,cdz=0;
    for(int i=0;i<n;i++){PVector a=src.get(i),b=dst.get(i);csx+=a.x;csy+=a.y;csz+=a.z;
      cdx+=b.x;cdy+=b.y;cdz+=b.z;}
    float inv=1.0f/n;float sx=(float)(csx*inv),sy=(float)(csy*inv),sz=(float)(csz*inv),dx=(float)(cdx*inv),dy=(float)(cdy*inv),dz=(float)(cdz*inv);

    float Sxx=0,Sxy=0,Sxz=0,Syx=0,Syy=0,Syz=0,Szx=0,Szy=0,Szz=0;
    for(int i=0;i<n;i++){
      PVector pa=src.get(i),pb=dst.get(i);float ax=pa.x-sx,ay=pa.y-sy,az=pa.z-sz,bx=pb.x-dx,by=pb.y-dy,bz=pb.z-dz;

      Sxx+=ax*bx;Sxy+=ax*by;Sxz+=ax*bz;Syx+=ay*bx;Syy+=ay*by;Syz+=ay*bz;Szx+=az*bx;
      Szy+=az*by;Szz+=az*bz;
    }
    float tr=Sxx+Syy+Szz;
    float n00=tr,n01=Syz-Szy,n02=Szx-Sxz,n03=Sxy-Syx;
    float n11=Sxx-Syy-Szz,n12=Sxy+Syx,n13=Szx+Sxz;
    float n22=-Sxx+Syy-Szz,n23=Syz+Szy,n33=-Sxx-Syy+Szz;
    float q0=1,q1=0,q2=0,q3=0;
    for(int it=0;it<32;it++){
      float a0=n00*q0+n01*q1+n02*q2+n03*q3;
      float a1=n01*q0+n11*q1+n12*q2+n13*q3;
      float a2=n02*q0+n12*q1+n22*q2+n23*q3;
      float a3=n03*q0+n13*q1+n23*q2+n33*q3;
      float norm=sqrt(a0*a0+a1*a1+a2*a2+a3*a3);if(norm<1e-9f)break;float ni=1.0f/norm;
      q0=a0*ni;q1=a1*ni;q2=a2*ni;q3=a3*ni;
    }
    float w=q0,x=q1,y=q2,z=q3;
    float r00=1-2*y*y-2*z*z,r01=2*x*y-2*z*w,r02=2*x*z+2*y*w;
    float r10=2*x*y+2*z*w,r11=1-2*x*x-2*z*z,r12=2*y*z-2*x*w;
    float r20=2*x*z-2*y*w,r21=2*y*z+2*x*w,r22=1-2*x*x-2*y*y;
    RigidTransform out=new RigidTransform();out.m[0]=r00;out.m[1]=r01;out.m[2]=r02;
    out.m[3]=dx-(r00*sx+r01*sy+r02*sz);out.m[4]=r10;out.m[5]=r11;out.m[6]=r12;out.m[7]=dy-(r10*sx+r11*sy+r12*sz);
    out.m[8]=r20;out.m[9]=r21;out.m[10]=r22;out.m[11]=dz-(r20*sx+r21*sy+r22*sz);return out;

  }

  RigidTransform fitWeighted(ArrayList<PVector> src,ArrayList<PVector> dst,ArrayList<Float> weights){
    int n=min(src.size(),min(dst.size(),weights.size()));if(n<3)return new RigidTransform();
    double sw=0,csx=0,csy=0,csz=0,cdx=0,cdy=0,cdz=0;
    for(int i=0;i<n;i++){double w=max(0.0001f,weights.get(i));PVector a=src.get(i),b=dst.get(i);sw+=w;csx+=w*a.x;csy+=w*a.y;csz+=w*a.z;cdx+=w*b.x;cdy+=w*b.y;cdz+=w*b.z;}
    if(sw<1e-8)return new RigidTransform();float sx=(float)(csx/sw),sy=(float)(csy/sw),sz=(float)(csz/sw),dx=(float)(cdx/sw),dy=(float)(cdy/sw),dz=(float)(cdz/sw);
    double Sxx=0,Sxy=0,Sxz=0,Syx=0,Syy=0,Syz=0,Szx=0,Szy=0,Szz=0;
    for(int i=0;i<n;i++){double w=max(0.0001f,weights.get(i));PVector a=src.get(i),b=dst.get(i);double ax=a.x-sx,ay=a.y-sy,az=a.z-sz,bx=b.x-dx,by=b.y-dy,bz=b.z-dz;Sxx+=w*ax*bx;Sxy+=w*ax*by;Sxz+=w*ax*bz;Syx+=w*ay*bx;Syy+=w*ay*by;Syz+=w*ay*bz;Szx+=w*az*bx;Szy+=w*az*by;Szz+=w*az*bz;}
    float fSxx=(float)Sxx,fSxy=(float)Sxy,fSxz=(float)Sxz,fSyx=(float)Syx,fSyy=(float)Syy,fSyz=(float)Syz,fSzx=(float)Szx,fSzy=(float)Szy,fSzz=(float)Szz;
    float tr=fSxx+fSyy+fSzz,n00=tr,n01=fSyz-fSzy,n02=fSzx-fSxz,n03=fSxy-fSyx,n11=fSxx-fSyy-fSzz,n12=fSxy+fSyx,n13=fSzx+fSxz,n22=-fSxx+fSyy-fSzz,n23=fSyz+fSzy,n33=-fSxx-fSyy+fSzz;
    float q0=1,q1=0,q2=0,q3=0;for(int it=0;it<32;it++){float a0=n00*q0+n01*q1+n02*q2+n03*q3,a1=n01*q0+n11*q1+n12*q2+n13*q3,a2=n02*q0+n12*q1+n22*q2+n23*q3,a3=n03*q0+n13*q1+n23*q2+n33*q3,norm=sqrt(a0*a0+a1*a1+a2*a2+a3*a3);if(norm<1e-9f)break;float ni=1.0f/norm;q0=a0*ni;q1=a1*ni;q2=a2*ni;q3=a3*ni;}
    float w=q0,x=q1,y=q2,z=q3,r00=1-2*y*y-2*z*z,r01=2*x*y-2*z*w,r02=2*x*z+2*y*w,r10=2*x*y+2*z*w,r11=1-2*x*x-2*z*z,r12=2*y*z-2*x*w,r20=2*x*z-2*y*w,r21=2*y*z+2*x*w,r22=1-2*x*x-2*y*y;
    RigidTransform out=new RigidTransform();out.m[0]=r00;out.m[1]=r01;out.m[2]=r02;out.m[3]=dx-(r00*sx+r01*sy+r02*sz);out.m[4]=r10;out.m[5]=r11;out.m[6]=r12;out.m[7]=dy-(r10*sx+r11*sy+r12*sz);out.m[8]=r20;out.m[9]=r21;out.m[10]=r22;out.m[11]=dz-(r20*sx+r21*sy+r22*sz);return out;
  }
}

// ===== SynKinect Studio / 3D Scanner / Mesh.pde =====
class Triangle3D {
  PVector a,b,c,n=new PVector();
  int ca,cb,cc;
  Triangle3D(PVector a,PVector b,PVector c){this(a,b,c,0,0,0);}
  Triangle3D(PVector a,PVector b,PVector c,int ca,int cb,int cc){this.a=a;this.b=b;
    this.c=c;this.ca=ca;this.cb=cb;this.cc=cc;recalc();}
  void recalc(){
    float ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z;
    float nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx,magSq=nx*nx+ny*ny+nz*nz;
    if(magSq<=1e-12f){n.set(0,0,0);return;}float inv=1.0f/sqrt(magSq);n.set(nx*inv,ny*inv,nz*inv);
  }
  PVector center(){ return new PVector((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3);
     }
}

class Mesh3D {
  ArrayList<Triangle3D> triangles=new ArrayList<Triangle3D>();
  void clear(){triangles.clear();}
  int triangleCount(){return triangles.size();}
  void addTriangle(PVector a,PVector b,PVector c){addTriangle(a,b,c,0,0,0);}
  void addTriangle(PVector a,PVector b,PVector c,int ca,int cb,int cc){
    float ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z;
    float nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx;
    if(nx*nx+ny*ny+nz*nz>1e-12f)triangles.add(new Triangle3D(a,b,c,ca,cb,cc));
  }
  void recalculateNormals(){for(Triangle3D t:triangles)t.recalc();}
  boolean hasVertexColor(){for(Triangle3D t:triangles)if(((t.ca>>>24)&255)!=0||((t.cb>>>24)&255)!=0||((t.cc>>>24)&255)!=0)return true;return false;}

  Mesh3D deepCopy(){
    Mesh3D copy=new Mesh3D();
    for(Triangle3D t:triangles) copy.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);

    return copy;
  }

  PVector boundsCenter(){
    if(triangles.size()==0) return new PVector();
    float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;

    float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;

    for(Triangle3D t:triangles){
      PVector[] v={t.a,t.b,t.c};
      for(PVector p:v){ minX=min(minX,p.x); minY=min(minY,p.y); minZ=min(minZ,p.z);
         maxX=max(maxX,p.x); maxY=max(maxY,p.y); maxZ=max(maxZ,p.z); }
    }
    return new PVector((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
  }

  float boundsRadius(){
    if(triangles.size()==0) return 0.2f;
    PVector c=boundsCenter();
    float r=0.0f;
    for(Triangle3D t:triangles){
      r=max(r,max(PVector.dist(c,t.a),max(PVector.dist(c,t.b),PVector.dist(c,t.c))));

    }
    return max(r,0.01f);
  }

  // Mesh vertex colors use ARGB. A zero alpha channel means the triangle
  // has no captured color, so the current theme shade is used.
  int renderColor(int c,int defaultColor){ return ((c>>>24)&255)==0 ? defaultColor : c; }

}


// ===== SynKinect Studio / 3D Scanner / MeshEditing.pde =====
class MeshEditor {
 final AppConfig cfg;
  MeshEditor(AppConfig cfg){ this.cfg=cfg; }

  Mesh3D filterGeometry(Mesh3D source){
    Mesh3D filtered=new Mesh3D();if(source==null)return filtered;
    float maxEdgeSq=cfg.meshCleanupMaxEdgeM*cfg.meshCleanupMaxEdgeM,minCrossSq=4.0f*cfg.meshCleanupMinAreaM2*cfg.meshCleanupMinAreaM2;
    for(Triangle3D t:source.triangles){
      float abx=t.b.x-t.a.x,aby=t.b.y-t.a.y,abz=t.b.z-t.a.z;
      float bcx=t.c.x-t.b.x,bcy=t.c.y-t.b.y,bcz=t.c.z-t.b.z;
      float cax=t.a.x-t.c.x,cay=t.a.y-t.c.y,caz=t.a.z-t.c.z;
      if(abx*abx+aby*aby+abz*abz>maxEdgeSq||bcx*bcx+bcy*bcy+bcz*bcz>maxEdgeSq||cax*cax+cay*cay+caz*caz>maxEdgeSq)continue;
      float acx=t.c.x-t.a.x,acy=t.c.y-t.a.y,acz=t.c.z-t.a.z;
      float nx=aby*acz-abz*acy,ny=abz*acx-abx*acz,nz=abx*acy-aby*acx;
      if(nx*nx+ny*ny+nz*nz<minCrossSq)continue;
      filtered.addTriangle(t.a,t.b,t.c,t.ca,t.cb,t.cc);
    }
    return filtered;
  }

  // Scanner output must be a coherent object, not a raw TSDF dump. Perform the
  // topology-safe cleanup automatically at mesh generation/export time: remove
  // implausible triangles, the support/floor band and tiny disconnected islands.
  // Smoothing remains explicit so real surface detail is never silently softened.
  Mesh3D prepareGeneratedMesh(Mesh3D source){
    Mesh3D filtered=filterGeometry(source);
    Mesh3D supportTrimmed=removeFloorAndScanDebris(filtered);
    Mesh3D out=removeSmallComponents(supportTrimmed);out.recalculateNormals();return out;
  }

  Mesh3D clean(Mesh3D source){
    Mesh3D filtered=filterGeometry(source);Mesh3D floorTrimmed=removeFloorAndScanDebris(filtered);
    Mesh3D components=removeSmallComponents(floorTrimmed);components.recalculateNormals();return components;
  }
  Mesh3D removeFloorAndScanDebris(Mesh3D source){
    if(source==null||source.triangleCount()==0)return new Mesh3D();float minY=Float.POSITIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY;
    for(Triangle3D t:source.triangles)for(PVector v:new PVector[]{t.a,t.b,t.c}){minY=min(minY,v.y);maxY=max(maxY,v.y);}
    float span=max(.001f,maxY-minY),floorBand=max(.012f,span*.045f);Mesh3D out=new Mesh3D();
    for(Triangle3D t:source.triangles){PVector c=t.center();if(c.y>maxY-floorBand&&abs(t.n.y)>.72f)continue;
      float ab=PVector.dist(t.a,t.b),bc=PVector.dist(t.b,t.c),ca=PVector.dist(t.c,t.a);if(max(ab,max(bc,ca))>cfg.meshCleanupMaxEdgeM)continue;
      out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}return out;
  }

  Mesh3D smooth(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D work=source.deepCopy();
    for(int i=0;i<cfg.meshSmoothIterations;i++)smoothPass(work,cfg.meshSmoothLambda);

    work.recalculateNormals();return work;
  }

  Mesh3D polish(Mesh3D source){
    Mesh3D work=clean(source);
    // Smooth works identically for a complete scan or the currently reconstructed
    // partial surface. Weld first so topology is coherent enough to identify holes.
    work=weldAndMerge(work);
    // Close only small, bounded holes caused by missing depth samples. Large open
    // boundaries (for example the unfinished side of a partial scan) are preserved.
    if(cfg.meshHoleFillEnabled)work=fillSmallHoles(work);
    // Taubin lambda/mu relaxation removes triangular stair-stepping without the
    // strong shrinkage of ordinary Laplacian smoothing. Open boundaries are pinned.
    // Detail-preserving Taubin polish with an automatic work budget. Large meshes
    // get fewer passes, preventing the UI from appearing frozen while avoiding
    // repeated smoothing that can erase real ridges and corners.
    int polishPasses=cfg.meshPolishIterations;
    if(work.triangleCount()>450000)polishPasses=min(polishPasses,1);
    else if(work.triangleCount()>220000)polishPasses=min(polishPasses,2);
    for(int i=0;i<polishPasses;i++){
      adaptiveSurfacePass(work,cfg.meshPolishLambda);adaptiveSurfacePass(work,cfg.meshPolishMu);
      Thread.yield();
    }
    work=weldAndMerge(work);
    work.recalculateNormals();return work;
  }

  void adaptiveSurfacePass(Mesh3D mesh,float factor){
    if(mesh==null||mesh.triangleCount()==0)return;HashMap<Long,PVector> sum=new HashMap<Long,PVector>();HashMap<Long,Integer> count=new HashMap<Long,Integer>();
    HashMap<Long,PVector> normalSum=new HashMap<Long,PVector>();HashMap<Long,HashSet<Long>> neighbors=new HashMap<Long,HashSet<Long>>();
    for(Triangle3D t:mesh.triangles){long a=key(t.a),b=key(t.b),c=key(t.c);addVertex(sum,count,a,t.a);addVertex(sum,count,b,t.b);addVertex(sum,count,c,t.c);addNormal(normalSum,a,t.n);addNormal(normalSum,b,t.n);addNormal(normalSum,c,t.n);connect(neighbors,a,b);connect(neighbors,b,c);connect(neighbors,c,a);}
    HashMap<Long,PVector> moved=new HashMap<Long,PVector>();
    for(Long k:sum.keySet()){PVector base=sum.get(k).copy();base.div(max(1,count.get(k)));HashSet<Long> ns=neighbors.get(k);if(ns==null||ns.size()<3){moved.put(k,base);continue;}
      PVector avg=new PVector();int n=0;for(Long qk:ns){PVector q=sum.get(qk);Integer qc=count.get(qk);if(q!=null&&qc!=null){avg.add(PVector.div(q.copy(),max(1,qc)));n++;}}if(n<2){moved.put(k,base);continue;}avg.div(n);
      PVector normal=normalSum.get(k);if(normal==null||normal.magSq()<1e-8f){moved.put(k,PVector.lerp(base,avg,abs(factor)));continue;}normal=normal.copy().normalize();float curvature=0;
      for(Long qk:ns){PVector qn=normalSum.get(qk);if(qn!=null&&qn.magSq()>1e-8f)curvature+=1.0f-abs(normal.dot(qn.copy().normalize()));}curvature/=max(1,ns.size());
      float strength=abs(factor)*constrain(1.0f-curvature*2.8f,.18f,1.0f);PVector delta=PVector.sub(avg,base);if(factor<0)delta.mult(-1);moved.put(k,PVector.add(base,PVector.mult(delta,strength)));}
    for(Triangle3D t:mesh.triangles){PVector a=moved.get(key(t.a)),b=moved.get(key(t.b)),c=moved.get(key(t.c));if(a!=null)t.a.set(a);if(b!=null)t.b.set(b);if(c!=null)t.c.set(c);t.recalc();}
  }
  void addNormal(HashMap<Long,PVector> normals,long k,PVector n){PVector v=normals.get(k);if(v==null){v=new PVector();normals.put(k,v);}v.add(n);}
  Mesh3D solidifyOpenSurface(Mesh3D source){
    if(source==null||source.triangleCount()==0)return source==null?new Mesh3D():source;Mesh3D out=weldAndMerge(source);
    HashMap<String,Integer> edgeCount=new HashMap<String,Integer>();HashMap<String,long[]> edgeEnds=new HashMap<String,long[]>();HashMap<Long,PVector> pos=new HashMap<Long,PVector>();
    float maxZ=Float.NEGATIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;for(Triangle3D t:out.triangles){long a=key(t.a),b=key(t.b),c=key(t.c);pos.put(a,t.a);pos.put(b,t.b);pos.put(c,t.c);
      maxZ=max(maxZ,max(t.a.z,max(t.b.z,t.c.z)));minZ=min(minZ,min(t.a.z,min(t.b.z,t.c.z)));addEdge(edgeCount,edgeEnds,a,b);addEdge(edgeCount,edgeEnds,b,c);addEdge(edgeCount,edgeEnds,c,a);}
    HashMap<Long,ArrayList<Long>> boundary=new HashMap<Long,ArrayList<Long>>();for(String ek:edgeCount.keySet())if(edgeCount.get(ek)==1){long[] e=edgeEnds.get(ek);connectBoundary(boundary,e[0],e[1]);}
    if(boundary.isEmpty())return out;float backZ=maxZ+max(.008f,(maxZ-minZ)*.025f);HashSet<Long> visited=new HashSet<Long>();
    for(Long seed:boundary.keySet()){if(visited.contains(seed))continue;ArrayList<Long> loop=traceOpenBoundary(seed,boundary,visited);if(loop.size()<3)continue;PVector center=new PVector();ArrayList<PVector> back=new ArrayList<PVector>();
      for(Long k:loop){PVector v=pos.get(k);if(v==null)continue;PVector bv=new PVector(v.x,v.y,backZ);back.add(bv);center.add(bv);}if(back.size()!=loop.size()||back.size()<3)continue;center.div(back.size());
      for(int i=0;i<back.size();i++){PVector a=pos.get(loop.get(i)),b=pos.get(loop.get((i+1)%loop.size())),ba=back.get(i),bb=back.get((i+1)%back.size());out.addTriangle(a.copy(),b.copy(),bb.copy());out.addTriangle(a.copy(),bb.copy(),ba.copy());out.addTriangle(bb.copy(),center.copy(),ba.copy());}}
    out.recalculateNormals();return out;
  }
  ArrayList<Long> traceOpenBoundary(long seed,HashMap<Long,ArrayList<Long>> g,HashSet<Long> visited){ArrayList<Long> loop=new ArrayList<Long>();long prev=Long.MIN_VALUE,cur=seed;
    for(int guard=0;guard<200000;guard++){if(visited.contains(cur)&&cur!=seed)break;loop.add(cur);visited.add(cur);ArrayList<Long> n=g.get(cur);if(n==null||n.isEmpty())break;long next=n.get(0);if(next==prev&&n.size()>1)next=n.get(1);prev=cur;cur=next;if(cur==seed)break;}return loop;}
  Mesh3D fillSmallHoles(Mesh3D source){
    if(source==null||source.triangleCount()==0)return source==null?new Mesh3D():source;
    HashMap<String,Integer> edgeCount=new HashMap<String,Integer>();
    HashMap<String,long[]> edgeEnds=new HashMap<String,long[]>();
    HashMap<Long,PVector> pos=new HashMap<Long,PVector>();
    HashMap<Long,Integer> colorSumR=new HashMap<Long,Integer>(),colorSumG=new HashMap<Long,Integer>(),colorSumB=new HashMap<Long,Integer>(),colorN=new HashMap<Long,Integer>();
    for(Triangle3D t:source.triangles){
      long ka=key(t.a),kb=key(t.b),kc=key(t.c);pos.put(ka,t.a);pos.put(kb,t.b);pos.put(kc,t.c);
      addColorSample(colorSumR,colorSumG,colorSumB,colorN,ka,t.ca);addColorSample(colorSumR,colorSumG,colorSumB,colorN,kb,t.cb);addColorSample(colorSumR,colorSumG,colorSumB,colorN,kc,t.cc);
      addEdge(edgeCount,edgeEnds,ka,kb);addEdge(edgeCount,edgeEnds,kb,kc);addEdge(edgeCount,edgeEnds,kc,ka);
    }
    HashMap<Long,ArrayList<Long>> boundary=new HashMap<Long,ArrayList<Long>>();
    for(String ek:edgeCount.keySet())if(edgeCount.get(ek)==1){long[] e=edgeEnds.get(ek);connectBoundary(boundary,e[0],e[1]);}
    HashSet<Long> visited=new HashSet<Long>();Mesh3D out=source.deepCopy();
    for(Long seed:boundary.keySet()){
      if(visited.contains(seed))continue;ArrayList<Long> loop=traceBoundaryLoop(seed,boundary,visited);
      if(loop.size()<3||loop.size()>cfg.meshHoleFillMaxEdges)continue;
      float perimeter=0,maxDiameter=0;PVector center=new PVector();boolean valid=true;
      for(int i=0;i<loop.size();i++){PVector a=pos.get(loop.get(i)),b=pos.get(loop.get((i+1)%loop.size()));if(a==null||b==null){valid=false;break;}center.add(a);perimeter+=PVector.dist(a,b);}
      if(!valid)continue;center.div(loop.size());
      for(Long k:loop){PVector a=pos.get(k);maxDiameter=max(maxDiameter,2.0f*PVector.dist(a,center));}
      if(perimeter>cfg.meshHoleFillMaxPerimeterM||maxDiameter>cfg.meshHoleFillMaxDiameterM)continue;
      int cc=averageLoopColor(loop,colorSumR,colorSumG,colorSumB,colorN);
      for(int i=0;i<loop.size();i++){
        long ka=loop.get(i),kb=loop.get((i+1)%loop.size());PVector a=pos.get(ka),b=pos.get(kb);
        int ca=vertexColor(ka,colorSumR,colorSumG,colorSumB,colorN),cb=vertexColor(kb,colorSumR,colorSumG,colorSumB,colorN);
        out.addTriangle(a.copy(),b.copy(),center.copy(),ca,cb,cc);
      }
    }
    out.recalculateNormals();return out;
  }

  void addEdge(HashMap<String,Integer> counts,HashMap<String,long[]> ends,long a,long b){long lo=a<b?a:b,hi=a<b?b:a;String k=lo+":"+hi;counts.put(k,counts.containsKey(k)?counts.get(k)+1:1);if(!ends.containsKey(k))ends.put(k,new long[]{a,b});}
  void connectBoundary(HashMap<Long,ArrayList<Long>> g,long a,long b){ArrayList<Long> aa=g.get(a);if(aa==null){aa=new ArrayList<Long>();g.put(a,aa);}if(!aa.contains(b))aa.add(b);ArrayList<Long> bb=g.get(b);if(bb==null){bb=new ArrayList<Long>();g.put(b,bb);}if(!bb.contains(a))bb.add(a);}
  ArrayList<Long> traceBoundaryLoop(long seed,HashMap<Long,ArrayList<Long>> g,HashSet<Long> visited){ArrayList<Long> loop=new ArrayList<Long>();long prev=Long.MIN_VALUE,cur=seed;for(int guard=0;guard<cfg.meshHoleFillMaxEdges+2;guard++){loop.add(cur);visited.add(cur);ArrayList<Long> n=g.get(cur);if(n==null||n.size()!=2)return new ArrayList<Long>();long next=n.get(0)==prev?n.get(1):n.get(0);prev=cur;cur=next;if(cur==seed)return loop;if(visited.contains(cur))return new ArrayList<Long>();}return new ArrayList<Long>();}
  void addColorSample(HashMap<Long,Integer> r,HashMap<Long,Integer> g,HashMap<Long,Integer> b,HashMap<Long,Integer> n,long k,int c){if(((c>>>24)&255)==0)return;r.put(k,(r.containsKey(k)?r.get(k):0)+((c>>16)&255));g.put(k,(g.containsKey(k)?g.get(k):0)+((c>>8)&255));b.put(k,(b.containsKey(k)?b.get(k):0)+(c&255));n.put(k,(n.containsKey(k)?n.get(k):0)+1);}
  int vertexColor(long k,HashMap<Long,Integer> r,HashMap<Long,Integer> g,HashMap<Long,Integer> b,HashMap<Long,Integer> n){int nn=n.containsKey(k)?n.get(k):0;if(nn<=0)return 0;return 0xff000000|((r.get(k)/nn)<<16)|((g.get(k)/nn)<<8)|(b.get(k)/nn);}
  int averageLoopColor(ArrayList<Long> loop,HashMap<Long,Integer> r,HashMap<Long,Integer> g,HashMap<Long,Integer> b,HashMap<Long,Integer> n){long rr=0,gg=0,bb=0,nn=0;for(Long k:loop){int q=n.containsKey(k)?n.get(k):0;if(q>0){rr+=r.get(k);gg+=g.get(k);bb+=b.get(k);nn+=q;}}if(nn==0)return 0;return 0xff000000|(((int)(rr/nn))<<16)|(((int)(gg/nn))<<8)|((int)(bb/nn));}

  Mesh3D weldAndMerge(Mesh3D source){
    Mesh3D out=new Mesh3D();if(source==null)return out;
    HashMap<Long,PVector> sums=new HashMap<Long,PVector>();HashMap<Long,Integer> counts=new HashMap<Long,Integer>();
    for(Triangle3D t:source.triangles){addVertex(sums,counts,key(t.a),t.a);addVertex(sums,counts,key(t.b),t.b);addVertex(sums,counts,key(t.c),t.c);}
    HashMap<Long,PVector> canonical=new HashMap<Long,PVector>();
    for(Long k:sums.keySet()){PVector v=sums.get(k).copy();v.div(max(1,counts.get(k)));canonical.put(k,v);}
    HashSet<String> faces=new HashSet<String>();
    for(Triangle3D t:source.triangles){long ka=key(t.a),kb=key(t.b),kc=key(t.c);if(ka==kb||kb==kc||kc==ka)continue;
      long[] sk={ka,kb,kc};Arrays.sort(sk);String fk=sk[0]+":"+sk[1]+":"+sk[2];if(!faces.add(fk))continue;
      PVector a=canonical.get(ka),b=canonical.get(kb),c=canonical.get(kc);if(a==null||b==null||c==null)continue;
      PVector ab=PVector.sub(b,a),ac=PVector.sub(c,a);if(ab.cross(ac).magSq()<4.0f*cfg.meshCleanupMinAreaM2*cfg.meshCleanupMinAreaM2)continue;
      out.addTriangle(a.copy(),b.copy(),c.copy(),t.ca,t.cb,t.cc);
    }
    return out;
  }

  Mesh3D polishHighQuality(Mesh3D source){
    Mesh3D work=clean(source);
    for(int i=0;i<cfg.hqMeshPolishIterations;i++){adaptiveSurfacePass(work,cfg.hqMeshPolishLambda);
      adaptiveSurfacePass(work,cfg.hqMeshPolishMu);}
    work.recalculateNormals();return work;
  }

  void smoothPass(Mesh3D mesh,float factor){
    HashMap<Long,PVector> sum=new HashMap<Long,PVector>();
    HashMap<Long,Integer> count=new HashMap<Long,Integer>();
    HashMap<Long,HashSet<Long>> neighbors=new HashMap<Long,HashSet<Long>>();
    for(Triangle3D t:mesh.triangles){
      long ka=key(t.a),kb=key(t.b),kc=key(t.c);
      addVertex(sum,count,ka,t.a);addVertex(sum,count,kb,t.b);addVertex(sum,count,kc,t.c);

      connect(neighbors,ka,kb);connect(neighbors,kb,kc);connect(neighbors,kc,ka);

    }
    // Boundary vertices stay fixed. This prevents smoothing from widening an
    // unfinished partial scan or rounding the rim of a legitimate opening.
    HashMap<String,Integer> smoothEdgeCount=new HashMap<String,Integer>();HashMap<String,long[]> smoothEdgeEnds=new HashMap<String,long[]>();
    for(Triangle3D t:mesh.triangles){addEdge(smoothEdgeCount,smoothEdgeEnds,key(t.a),key(t.b));addEdge(smoothEdgeCount,smoothEdgeEnds,key(t.b),key(t.c));addEdge(smoothEdgeCount,smoothEdgeEnds,key(t.c),key(t.a));}
    HashSet<Long> boundaryVertices=new HashSet<Long>();for(String ek:smoothEdgeCount.keySet())if(smoothEdgeCount.get(ek)==1){long[] e=smoothEdgeEnds.get(ek);boundaryVertices.add(e[0]);boundaryVertices.add(e[1]);}
    HashMap<Long,PVector> center=new HashMap<Long,PVector>(sum.size()*2);
    for(Long k:sum.keySet()){PVector p=sum.get(k).copy();p.div(max(1,count.get(k)));
      center.put(k,p);}
    HashMap<Long,PVector> moved=new HashMap<Long,PVector>(center.size()*2);
    for(Long k:center.keySet()){
      PVector base=center.get(k),avg=new PVector();int n=0;HashSet<Long> adj=neighbors.get(k);
      if(boundaryVertices.contains(k)){moved.put(k,base.copy());continue;}

      if(adj!=null)for(Long other:adj){PVector q=center.get(other);if(q!=null){avg.add(q);
          n++;}}
      if(n<2){moved.put(k,base.copy());continue;}
      avg.div(n);PVector delta=PVector.sub(avg,base);moved.put(k,PVector.add(base,PVector.mult(delta,factor)));

    }
    for(Triangle3D t:mesh.triangles){PVector a=moved.get(key(t.a)),b=moved.get(key(t.b)),c=moved.get(key(t.c));
      if(a!=null)t.a.set(a);if(b!=null)t.b.set(b);if(c!=null)t.c.set(c);}
  }

  Mesh3D removeSmallComponents(Mesh3D source){
    if(source==null||source.triangleCount()==0)return new Mesh3D();
    int n=source.triangleCount();
    HashMap<Long,ArrayList<Integer>> incidence=new HashMap<Long,ArrayList<Integer>>();

    for(int i=0;i<n;i++){
      Triangle3D t=source.triangles.get(i);addIncidence(incidence,key(t.a),i);addIncidence(incidence,key(t.b),i);
      addIncidence(incidence,key(t.c),i);
    }
    boolean[] seen=new boolean[n];ArrayList<ArrayList<Integer>> groups=new ArrayList<ArrayList<Integer>>();
    int largest=0;
    for(int seed=0;seed<n;seed++){
      if(seen[seed])continue;ArrayList<Integer> group=new ArrayList<Integer>();ArrayDeque<Integer> q=new ArrayDeque<Integer>();
      q.add(seed);seen[seed]=true;
      while(!q.isEmpty()){
        int i=q.removeFirst();group.add(i);Triangle3D t=source.triangles.get(i);long[] keys={key(t.a),key(t.b),key(t.c)};

        for(long k:keys){ArrayList<Integer> linked=incidence.get(k);if(linked==null)continue;
          for(Integer other:linked)if(!seen[other]){seen[other]=true;q.addLast(other);
            }}
      }
      groups.add(group);largest=max(largest,group.size());
    }
    int threshold=max(cfg.meshMinimumComponentTriangles,round(largest*cfg.meshMinimumComponentRatio));

    Mesh3D out=new Mesh3D();
    for(ArrayList<Integer> group:groups)if(group.size()>=threshold)for(Integer idx:group){Triangle3D t=source.triangles.get(idx);
      out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    if(out.triangleCount()==0){
      ArrayList<Integer> best=null;for(ArrayList<Integer> group:groups)if(best==null||group.size()>best.size())best=group;

      if(best!=null)for(Integer idx:best){Triangle3D t=source.triangles.get(idx);
        out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    }
    return out;
  }

  Mesh3D center(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D out=source.deepCopy();PVector c=out.boundsCenter();
    for(Triangle3D t:out.triangles){t.a.sub(c);t.b.sub(c);t.c.sub(c);t.recalc();}return out;

  }

  long key(PVector p){
    float q=max(0.000001f,cfg.meshWeldToleranceM);long x=round(p.x/q),y=round(p.y/q),z=round(p.z/q);

    return ((x&0x1FFFFFL)<<42)|((y&0x1FFFFFL)<<21)|(z&0x1FFFFFL);
  }
  void addIncidence(HashMap<Long,ArrayList<Integer>> m,long k,int i){ArrayList<Integer> list=m.get(k);
    if(list==null){list=new ArrayList<Integer>();m.put(k,list);}list.add(i);}
  void addVertex(HashMap<Long,PVector> sum,HashMap<Long,Integer> count,long k,PVector p){PVector acc=sum.get(k);
    if(acc==null){acc=new PVector();sum.put(k,acc);count.put(k,0);}acc.add(p);count.put(k,count.get(k)+1);
    }
  void connect(HashMap<Long,HashSet<Long>> n,long a,long b){if(a==b)return;HashSet<Long> aa=n.get(a);
    if(aa==null){aa=new HashSet<Long>();n.put(a,aa);}aa.add(b);HashSet<Long> bb=n.get(b);
    if(bb==null){bb=new HashSet<Long>();n.put(b,bb);}bb.add(a);}
}


// ===== SynKinect Studio / 3D Scanner / PointCloud.pde =====
class PointCloudBuilder {
  AppConfig cfg;
  RgbDepthRegistration registration;
  final int[] neighborScratch=new int[8];
  final int[] medianScratch=new int[49];
  PointCloudBuilder(AppConfig cfg,RgbDepthRegistration registration) { this.cfg = cfg;
     this.registration=registration; }

  PointCloud build(DepthFrame f, Calibration c, int step, float targetZ, float band, PointCloudBuildStats stats, RgbSnapshot rgb) {
    if (stats != null) stats.clear();
    if (f == null || f.depth == null || c == null || !c.valid) return new PointCloud();

    int safeStep = max(1, step);
    int estimated=((f.width+safeStep-1)/safeStep)*((f.height+safeStep-1)/safeStep);

    PointCloud cloud = new PointCloud(estimated);
    boolean includeColor=(cfg.meshColorEnabled||cfg.colorIcpEnabled)&&registration!=null&&rgb!=null;
    if(includeColor) registration.prepareFrame(f,rgb);
    boolean[] componentMask=cfg.pointCloudConnectedTarget&&(!cfg.boundingBoxEnabled||scannerState().boundingBox==null||!scannerState().boundingBox.locked)&&!Float.isNaN(targetZ)?connectedTargetMask(f,c,safeStep,targetZ,band):null;
    int componentW=(f.width+safeStep-1)/safeStep;
    for (int v = 0; v < f.height; v += safeStep) {
      int row=v*f.width;
      for (int u = 0; u < f.width; u += safeStep) {
        if (stats != null) stats.sourcePixels++;
        int index=row+u;
        if(componentMask!=null&&!componentMask[(v/safeStep)*componentW+(u/safeStep)]){if(stats!=null)stats.rejectedBand++;continue;}
        int raw = f.depth[index] & 0xFFFF;
        if (raw == 0) continue;
        if (stats != null) stats.nonZero++;
        int filteredMm=filteredDepthMm(f,u,v,raw,safeStep,c);
        if(filteredMm<=0){if(stats!=null)stats.rejectedSpatial++;continue;}
        float z = filteredMm * c.depthScale;
        if (z < cfg.minDepthM || z > cfg.maxDepthM) { if (stats != null) stats.rejectedRange++;
           continue; }
        if (stats != null) stats.inRange++;
        if (!Float.isNaN(targetZ) && abs(z - targetZ) > band) { if (stats != null) stats.rejectedBand++;
           continue; }
        float x = registration!=null ? registration.pointX(index,z) : (u-c.cx)*z/c.fx;

        float y = registration!=null ? registration.pointY(index,z) : (v-c.cy)*z/c.fy;

        float confidence=c.depthConfidence(index,z)*edgeConfidence(f,u,v,filteredMm,c)*surfaceConfidence(f,u,v,filteredMm,c);

        if(confidence<cfg.pointCloudMinimumConfidence){if(stats!=null)stats.rejectedSpatial++;
          continue;}
        int rgbColor = includeColor ? registration.colorAt(index,z) : 0;
        cloud.add(new PVector(x,y,z),rgbColor,confidence);
        if (stats != null) stats.accepted++;
      }
    }
    return cloud;
  }

  boolean[] connectedTargetMask(DepthFrame f,Calibration c,int step,float targetZ,float band){
    int gw=(f.width+step-1)/step,gh=(f.height+step-1)/step,n=gw*gh;
    boolean[] candidate=new boolean[n],visited=new boolean[n],bestMask=new boolean[n];
    float[] depth=new float[n];Arrays.fill(depth,Float.NaN);
    float relaxed=band*1.04f;int valid=0;

    // Segmentation uses a slightly expanded version of the acquisition ROI.
    // This still leaves room for the complete object while preventing full-FOV
    // walls/floor/table surfaces from becoming the dominant component.
    float margin=cfg.targetSegmentationMargin;
    int minGX=constrain(floor((cfg.depthRoiLeft-margin)*f.width/step),0,gw-1);
    int maxGX=constrain(ceil((cfg.depthRoiRight+margin)*f.width/step),minGX+1,gw);
    int minGY=constrain(floor((cfg.depthRoiTop-margin)*f.height/step),0,gh-1);
    int maxGY=constrain(ceil((cfg.depthRoiBottom+margin)*f.height/step),minGY+1,gh);
    for(int gy=minGY;gy<maxGY;gy++){
      int v=min(f.height-1,gy*step);
      for(int gx=minGX;gx<maxGX;gx++){
        int u=min(f.width-1,gx*step),index=v*f.width+u,mm=f.depth[index]&0xffff;
        if(mm==0)continue;if(c!=null)mm=c.correctedDepthMm(index,mm);if(mm<=0)continue;
        float z=mm*(c==null?0.001f:c.depthScale);
        if(z<cfg.minDepthM||z>cfg.maxDepthM||abs(z-targetZ)>relaxed)continue;
        int gi=gy*gw+gx;candidate[gi]=true;depth[gi]=z;valid++;
      }
    }
    if(valid<cfg.pointCloudComponentMinSamples)return bestMask;

    int bestCount=0;float bestScore=-Float.MAX_VALUE;
    ArrayDeque<Integer> queue=new ArrayDeque<Integer>();ArrayList<Integer> component=new ArrayList<Integer>();
    float link=max(0.005f,cfg.pointCloudComponentDepthLinkM);
    for(int seed=0;seed<n;seed++){
      if(!candidate[seed]||visited[seed])continue;
      queue.clear();component.clear();queue.add(seed);visited[seed]=true;
      float sx=0,sy=0,depthError=0;int borderHits=0;
      while(!queue.isEmpty()){
        int q=queue.removeFirst();component.add(q);int qx=q%gw,qy=q/gw;sx+=qx;sy+=qy;
        depthError+=abs(depth[q]-targetZ);
        if(qx<=minGX+1||qx>=maxGX-2||qy<=minGY+1||qy>=maxGY-2)borderHits++;
        for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
          if(dx==0&&dy==0)continue;int nx=qx+dx,ny=qy+dy;
          if(nx<minGX||ny<minGY||nx>=maxGX||ny>=maxGY)continue;
          int ni=ny*gw+nx;if(!candidate[ni]||visited[ni])continue;
          // Image adjacency is accepted only when metric depth also represents one continuous 3D surface.
          // Require metric depth continuity so object and support/background do
          // not merge through a one-pixel contact/occlusion boundary.
          float localLink=link*(dx!=0&&dy!=0?1.35f:1.0f);
          if(abs(depth[ni]-depth[q])>localLink)continue;
          visited[ni]=true;queue.addLast(ni);
        }
      }
      int count=component.size();if(count<cfg.pointCloudComponentMinSamples)continue;
      float cx=sx/count,cy=sy/count;
      float centerGX=(minGX+maxGX-1)*.5f,centerGY=(minGY+maxGY-1)*.5f;
      float dx=(cx-centerGX)/max(1,(maxGX-minGX)*.5f),dy=(cy-centerGY)/max(1,(maxGY-minGY)*.5f);
      float centrality=max(0,1.0f-sqrt(dx*dx+dy*dy));
      float meanDepthError=depthError/count;
      float depthAffinity=constrain(1.0f-meanDepthError/max(0.02f,band),0.20f,1.0f);
      float borderRatio=borderHits/(float)count;
      float borderFactor=max(0.08f,1.0f-cfg.pointCloudComponentBorderPenalty*constrain(borderRatio*4.0f,0,1));
      float score=count*(0.62f+0.38f*centrality)*depthAffinity*borderFactor;
      if(score>bestScore){Arrays.fill(bestMask,false);for(Integer q:component)bestMask[q]=true;bestScore=score;bestCount=count;}
    }
    return bestMask;
  }

  float edgeConfidence(DepthFrame f,int u,int v,int centerMm,Calibration calibration){
    if(f==null||f.depth==null||centerMm<=0)return 0;
    float center=centerMm*0.001f,maxDelta=0;int valid=0;
    final int[] dx={-1,1,0,0},dy={0,0,-1,1};
    for(int k=0;k<4;k++){
      int x=u+dx[k],y=v+dy[k];if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int index=y*f.width+x,mm=f.depth[index]&0xffff;if(mm==0)continue;
      if(calibration!=null)mm=calibration.correctedDepthMm(index,mm);if(mm<=0)continue;

      maxDelta=max(maxDelta,abs(mm*0.001f-center));valid++;
    }
    if(valid<2)return 0.45f;
    if(maxDelta>=cfg.pointCloudEdgeRejectM)return 0;
    if(maxDelta<=cfg.pointCloudEdgeSoftM)return 1.0f;
    float span=max(0.0001f,cfg.pointCloudEdgeRejectM-cfg.pointCloudEdgeSoftM);
    return constrain(1.0f-(maxDelta-cfg.pointCloudEdgeSoftM)/span,0.10f,1.0f);
  }

  float surfaceConfidence(DepthFrame f,int u,int v,int centerMm,Calibration calibration){
    if(f==null||f.depth==null||centerMm<=0)return 0;int n=0,coherent=0;float sum=0,sum2=0;
    for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){int x=u+dx,y=v+dy;if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int index=y*f.width+x,mm=f.depth[index]&0xffff;if(mm==0)continue;if(calibration!=null)mm=calibration.correctedDepthMm(index,mm);if(mm<=0)continue;
      float dz=(mm-centerMm)*.001f;if(abs(dz)<=cfg.pointCloudEdgeRejectM){coherent++;sum+=dz;sum2+=dz*dz;}n++;}
    if(n<4)return .55f;float support=coherent/(float)n;if(support<cfg.pointCloudMinimumSupport)return .08f;
    float mean=sum/max(1,coherent),variance=max(0,sum2/max(1,coherent)-mean*mean),sigma=sqrt(variance);
    float noise=constrain(1.0f-sigma/max(.001f,cfg.pointCloudSurfaceNoiseM),.12f,1.0f);
    return constrain(support*noise,.08f,1.0f);
  }

  int filteredDepthMm(DepthFrame f,int u,int v,int centerMm,int step){return filteredDepthMm(f,u,v,centerMm,step,null);
    }
  int filteredDepthMm(DepthFrame f,int u,int v,int centerMm,int step,Calibration calibration){
    int centerIndex=v*f.width+u;if(calibration!=null)centerMm=calibration.correctedDepthMm(centerIndex,centerMm);

    int toleranceMm=max(1,round(cfg.pointCloudNeighborToleranceM*1000.0f));
    int n=0;
    for(int dy=-step;dy<=step;dy+=step)for(int dx=-step;dx<=step;dx+=step){
      if(dx==0&&dy==0)continue;
      int x=u+dx,y=v+dy;
      if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int ni=y*f.width+x,mm=f.depth[ni]&0xffff;if(calibration!=null&&mm!=0)mm=calibration.correctedDepthMm(ni,mm);

      if(mm!=0)neighborScratch[n++]=mm;
    }

    int filtered=centerMm;
    if(n>=3){
      sortSmall(neighborScratch,n);
      int median=neighborScratch[n/2],coherent=0;
      for(int i=0;i<n;i++)if(abs(neighborScratch[i]-median)<=toleranceMm)coherent++;

      int majority=max(3,(n*5+7)/8); // ceil(n * 0.625)
      if(coherent>=majority){
        if(abs(centerMm-median)>toleranceMm)filtered=median;
        else{
          int m=0;medianScratch[m++]=centerMm;
          for(int i=0;i<n;i++)if(abs(neighborScratch[i]-median)<=toleranceMm)medianScratch[m++]=neighborScratch[i];

          sortSmall(medianScratch,m);filtered=medianScratch[m/2];
        }
      }
    }

    if(cfg.pointCloudSpatialFilter&&n>2){
      int consistent=0;
      for(int i=0;i<n;i++)if(abs(neighborScratch[i]-filtered)<=toleranceMm)consistent++;

      if(consistent<max(2,(n+1)/2))return -1;
    }
    return filtered;
  }

  PointCloud buildHighQuality(DepthFrame f, Calibration c, float targetZ, float band, RgbSnapshot rgb) {
    if (f == null || f.depth == null || c == null || !c.valid) return new PointCloud();

    int step=max(1,cfg.hqIntegrationStep);
    int estimated=((f.width+step-1)/step)*((f.height+step-1)/step);
    PointCloud cloud=new PointCloud(estimated);
    boolean includeColor=(cfg.meshColorEnabled||cfg.colorIcpEnabled)&&registration!=null&&rgb!=null;
    if(includeColor)registration.prepareFrame(f,rgb);
    boolean[] componentMask=cfg.pointCloudConnectedTarget&&(!cfg.boundingBoxEnabled||scannerState().boundingBox==null||!scannerState().boundingBox.locked)&&!Float.isNaN(targetZ)?connectedTargetMask(f,c,step,targetZ,band):null;
    int componentW=(f.width+step-1)/step;
    for(int v=0;v<f.height;v+=step){
      int row=v*f.width;
      for(int u=0;u<f.width;u+=step){
        int index=row+u;if(componentMask!=null&&!componentMask[(v/step)*componentW+(u/step)])continue;int raw=f.depth[index]&0xffff;
        int filteredMm=filteredDepthMmHighQuality(f,u,v,raw,c);
        if(filteredMm<=0)continue;
        float z=filteredMm*c.depthScale;
        if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
        if(!Float.isNaN(targetZ)&&abs(z-targetZ)>band)continue;
        float x=registration!=null?registration.pointX(index,z):(u-c.cx)*z/c.fx;
        float y=registration!=null?registration.pointY(index,z):(v-c.cy)*z/c.fy;
        float confidence=c.depthConfidence(index,z)*edgeConfidence(f,u,v,filteredMm,c)*surfaceConfidence(f,u,v,filteredMm,c);

        if(confidence<max(cfg.pointCloudMinimumConfidence,0.22f))continue;
        int color=includeColor?registration.colorAt(index,z):0;
        cloud.add(new PVector(x,y,z),color,confidence);
      }
    }
    return cloud;
  }

  int filteredDepthMmHighQuality(DepthFrame f,int u,int v,int centerMm){return filteredDepthMmHighQuality(f,u,v,centerMm,null);
    }
  int filteredDepthMmHighQuality(DepthFrame f,int u,int v,int centerMm,Calibration calibration){
    int centerIndex=v*f.width+u;if(calibration!=null&&centerMm!=0)centerMm=calibration.correctedDepthMm(centerIndex,centerMm);

    int radius=max(1,cfg.hqDepthFilterRadius),tolerance=max(1,round(cfg.hqDepthEdgeToleranceM*1000.0f));

    int n=0;
    for(int dy=-radius;dy<=radius;dy++)for(int dx=-radius;dx<=radius;dx++){
      int x=u+dx,y=v+dy;if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int ni=y*f.width+x,mm=f.depth[ni]&0xffff;if(mm==0)continue;if(calibration!=null)mm=calibration.correctedDepthMm(ni,mm);

      if(centerMm==0||abs(mm-centerMm)<=tolerance)medianScratch[n++]=mm;
    }
    if(centerMm==0){
      if(n<cfg.hqHoleFillMinimumNeighbors)return -1;
      sortSmall(medianScratch,n);int median=medianScratch[n/2],coherent=0;
      for(int i=0;i<n;i++)if(abs(medianScratch[i]-median)<=tolerance)coherent++;
      if(coherent<cfg.hqHoleFillMinimumNeighbors)return -1;
      return median;
    }
    if(n<3)return centerMm;
    sortSmall(medianScratch,n);
    int median=medianScratch[n/2];
    // Edge-aware median: only samples already close to the center are present,
    // so this suppresses structured-light speckle without bleeding across depth edges.
    return abs(median-centerMm)<=tolerance?median:centerMm;
  }

  void sortSmall(int[] values,int count){
    for(int i=1;i<count;i++){
      int value=values[i],j=i-1;
      while(j>=0&&values[j]>value){values[j+1]=values[j];j--;}
      values[j+1]=value;
    }
  }
}

class PointCloud {
  ArrayList<PVector> points;
  int[] colors;float[] confidence;
  PointCloud(){this(4096);}
  PointCloud(int capacity){int safe=max(16,capacity);points=new ArrayList<PVector>(safe);
    colors=new int[safe];confidence=new float[safe];Arrays.fill(confidence,1.0f);
    }
  int size() { return points.size(); }
  void add(PVector p,int c){add(p,c,1.0f);}
  void add(PVector p,int c,float q){
    int index=points.size();points.add(p);
    if(index>=colors.length){int next=max(index+1,colors.length*2);colors=Arrays.copyOf(colors,next);
      confidence=Arrays.copyOf(confidence,next);}
    colors[index]=c;confidence[index]=constrain(q,0.05f,1.0f);
  }
  int colorAt(int i){return i>=0&&i<points.size()?colors[i]:0;}
  float confidenceAt(int i){return i>=0&&i<points.size()?confidence[i]:1.0f;}

  PVector centroidTransformed(RigidTransform t) {
    if(points.isEmpty())return new PVector();
    double sx=0,sy=0,sz=0;float[] m=t.m;
    for(PVector p:points){sx+=m[0]*p.x+m[1]*p.y+m[2]*p.z+m[3];sy+=m[4]*p.x+m[5]*p.y+m[6]*p.z+m[7];
      sz+=m[8]*p.x+m[9]*p.y+m[10]*p.z+m[11];}
    float inv=1.0f/points.size();return new PVector((float)(sx*inv),(float)(sy*inv),(float)(sz*inv));

  }
  PointCloud transformed(RigidTransform t, int maxPoints) {
    int limit=max(1,maxPoints),stride=max(1,(points.size()+limit-1)/limit);
    PointCloud out = new PointCloud(min(points.size(),limit)+1);
    for (int i = 0; i < points.size(); i += stride) out.add(t.apply(points.get(i)),colorAt(i),confidenceAt(i));
     return out;
  }
}

class PreviewPointVoxel {
  PVector p;int color;float confidence;int count=1;
  PreviewPointVoxel(PVector point,int c,float q){p=point.copy();color=c;confidence=q;}
  void add(PVector point,int c,float q){
    count=min(64,count+1);float a=1.0f/count;p.lerp(point,a);
    confidence=lerp(confidence,q,.20f);
    if(c!=0){if(color==0)color=c;else{
      int ar=(color>>16)&255,ag=(color>>8)&255,ab=color&255;
      int br=(c>>16)&255,bg=(c>>8)&255,bb=c&255;
      color=0xff000000|(round(lerp(ar,br,.18f))<<16)|(round(lerp(ag,bg,.18f))<<8)|round(lerp(ab,bb,.18f));
    }}
  }
}

class PointCloudAccumulator {
  final AppConfig cfg;
  final HashMap<VertexKey,PreviewPointVoxel> voxels=new HashMap<VertexKey,PreviewPointVoxel>();
  PointCloud cached=new PointCloud();boolean dirty=true;
  PointCloudAccumulator(AppConfig c){cfg=c;}
  void reset(){voxels.clear();cached=new PointCloud();dirty=true;}

  void integrate(PointCloud cloud,RigidTransform pose){
    if(cloud==null||pose==null||cloud.size()==0)return;
    int budget=max(1,cfg.previewPointMaxPoints);
    int stride=max(1,(cloud.size()+max(1,cfg.previewPointTransientMaxPoints)-1)/max(1,cfg.previewPointTransientMaxPoints));
    for(int i=0;i<cloud.size();i+=stride){
      if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;
      PVector world=pose.apply(cloud.points.get(i));
      VertexKey key=new VertexKey(world.x,world.y,world.z,cfg.previewPointVoxelM);
      PreviewPointVoxel v=voxels.get(key);
      if(v!=null)v.add(world,cloud.colorAt(i),cloud.confidenceAt(i));
      else if(voxels.size()<budget)voxels.put(key,new PreviewPointVoxel(world,cloud.colorAt(i),cloud.confidenceAt(i)));
    }
    dirty=true;
  }

  PointCloud snapshot(){
    if(!dirty&&cached!=null)return cached;
    int maxDisplay=max(1,cfg.previewPointDisplayMaxPoints);
    int stride=max(1,(voxels.size()+maxDisplay-1)/maxDisplay);
    PointCloud out=new PointCloud(min(maxDisplay,voxels.size())+8);int i=0;
    for(PreviewPointVoxel v:voxels.values()){
      if((i++%stride)!=0)continue;
      out.add(v.p.copy(),v.color,v.confidence);
    }
    cached=out;dirty=false;return cached;
  }

  PointCloud snapshotWithTransient(PointCloud transientCloud){
    PointCloud permanent=snapshot();
    if(transientCloud==null||transientCloud.size()==0)return permanent;
    int transientLimit=max(1,cfg.previewPointTransientMaxPoints);
    int permanentLimit=max(1,cfg.previewPointDisplayMaxPoints-transientLimit);
    int pStride=max(1,(permanent.size()+permanentLimit-1)/permanentLimit);
    PointCloud out=new PointCloud(min(permanent.size(),permanentLimit)+min(transientCloud.size(),transientLimit)+8);
    for(int i=0;i<permanent.size();i+=pStride)out.add(permanent.points.get(i).copy(),permanent.colorAt(i),permanent.confidenceAt(i));
    int tStride=max(1,(transientCloud.size()+transientLimit-1)/transientLimit);
    for(int i=0;i<transientCloud.size();i+=tStride)out.add(transientCloud.points.get(i).copy(),transientCloud.colorAt(i),transientCloud.confidenceAt(i));
    return out;
  }
}


class BoundingBoxTracker {
  final AppConfig cfg;
  boolean locked=false;
  float minX,maxX,minY,maxY,minZ,maxZ;
  BoundingBoxTracker(AppConfig c){cfg=c;}
  void reset(){locked=false;minX=maxX=minY=maxY=minZ=maxZ=0;}

  PointCloud filter(PointCloud input){return filter(input,true);}
  PointCloud filter(PointCloud input,boolean adapt){
    if(input==null)return new PointCloud();
    if(!cfg.boundingBoxEnabled)return input;
    if(!locked)lockFrom(input);
    if(!locked)return input;
    PointCloud out=new PointCloud(max(16,input.size()));
    for(int i=0;i<input.size();i++){
      PVector q=input.points.get(i);
      if(q.x<minX||q.x>maxX||q.y<minY||q.y>maxY||q.z<minZ||q.z>maxZ)continue;
      out.add(q.copy(),input.colorAt(i),input.confidenceAt(i));
    }
    if(adapt&&out.size()>=cfg.boundingBoxMinPoints)adaptCenter(out);
    return out;
  }

  void lockFrom(PointCloud cloud){
    if(cloud==null||cloud.size()<cfg.boundingBoxMinPoints)return;
    int n=cloud.size();float[] xs=new float[n],ys=new float[n],zs=new float[n];int m=0;
    for(int i=0;i<n;i++){
      if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;
      PVector q=cloud.points.get(i);xs[m]=q.x;ys[m]=q.y;zs[m]=q.z;m++;
    }
    if(m<cfg.boundingBoxMinPoints)return;
    Arrays.sort(xs,0,m);Arrays.sort(ys,0,m);Arrays.sort(zs,0,m);
    int lo=constrain(round((m-1)*.035f),0,m-1),hi=constrain(round((m-1)*.965f),lo,m-1);
    float cx=(xs[lo]+xs[hi])*.5f,cy=(ys[lo]+ys[hi])*.5f,cz=(zs[lo]+zs[hi])*.5f;
    float width=constrain((xs[hi]-xs[lo])+2*cfg.boundingBoxMarginM,cfg.boundingBoxMinWidthM,cfg.boundingBoxMaxWidthM);
    float height=constrain((ys[hi]-ys[lo])+2*cfg.boundingBoxMarginM+cfg.boundingBoxBaseExtraM,cfg.boundingBoxMinHeightM,cfg.boundingBoxMaxHeightM);
    float depth=constrain((zs[hi]-zs[lo])+2*cfg.boundingBoxDepthMarginM,cfg.boundingBoxMinDepthM,cfg.boundingBoxMaxDepthM);
    minX=cx-width*.5f;maxX=cx+width*.5f;
    // +Y is down in Kinect camera space; reserve extra room below the object for
    // the rotating plate/visual markers, not for the entire support table.
    minY=cy-height*.5f-cfg.boundingBoxMarginM*.25f;
    maxY=cy+height*.5f+cfg.boundingBoxBaseExtraM*.50f;
    minZ=cz-depth*.5f;maxZ=cz+depth*.5f;
    locked=true;
  }

  void adaptCenter(PointCloud cloud){
    if(!locked||cfg.boundingBoxCenterFollowAlpha<=0||cloud==null||cloud.size()<cfg.boundingBoxMinPoints)return;
    int step=max(1,cloud.size()/900),n=0,cap=(cloud.size()+step-1)/step;
    float[] xs=new float[cap],ys=new float[cap],zs=new float[cap];
    for(int i=0;i<cloud.size();i+=step){PVector q=cloud.points.get(i);xs[n]=q.x;ys[n]=q.y;zs[n]=q.z;n++;}
    if(n<24)return;Arrays.sort(xs,0,n);Arrays.sort(ys,0,n);Arrays.sort(zs,0,n);
    float ox=(minX+maxX)*.5f,oy=(minY+maxY)*.5f,oz=(minZ+maxZ)*.5f;
    float nx=xs[n/2],ny=ys[n/2],nz=zs[n/2];
    float dx=constrain(nx-ox,-cfg.boundingBoxMaxCenterCorrectionM,cfg.boundingBoxMaxCenterCorrectionM);
    float dy=constrain(ny-oy,-cfg.boundingBoxMaxCenterCorrectionM,cfg.boundingBoxMaxCenterCorrectionM);
    float dz=constrain(nz-oz,-cfg.boundingBoxMaxCenterCorrectionM,cfg.boundingBoxMaxCenterCorrectionM);
    float a=cfg.boundingBoxCenterFollowAlpha;
    dx*=a;dy*=a;dz*=a;minX+=dx;maxX+=dx;minY+=dy;maxY+=dy;minZ+=dz;maxZ+=dz;
  }
}


class SpatialHash {
  float cell;
  HashMap<Long, ArrayList<PVector>> buckets;
  SpatialHash(float cell,int expectedPoints) { this.cell = max(0.000001f, cell);buckets=new HashMap<Long,ArrayList<PVector>>(max(16,expectedPoints*2));
     }

  long key(int x,int y,int z) {
    long a=((long)x & 0x1FFFFF), b=((long)y & 0x1FFFFF), c=((long)z & 0x1FFFFF);
    return (a<<42)|(b<<21)|c;
  }
  int cellCoord(float v){ return floor(v/cell); }
  void add(PVector p) {
    long k=key(cellCoord(p.x),cellCoord(p.y),cellCoord(p.z)); ArrayList<PVector> list=buckets.get(k);

    if(list==null){ list=new ArrayList<PVector>(); buckets.put(k,list); } list.add(p);

  }

  PVector nearest(PVector p,float maxDist) {
    int cx=cellCoord(p.x), cy=cellCoord(p.y), cz=cellCoord(p.z);
    int radius=max(1, ceil(maxDist/cell));
    PVector best=null; float best2=maxDist*maxDist;
    for(int dz=-radius;dz<=radius;dz++) for(int dy=-radius;dy<=radius;dy++) for(int dx=-radius;dx<=radius;dx++) {
      ArrayList<PVector> list=buckets.get(key(cx+dx,cy+dy,cz+dz));
      if(list==null) continue;
      for(PVector q:list){float qx=p.x-q.x,qy=p.y-q.y,qz=p.z-q.z,d2=qx*qx+qy*qy+qz*qz;
        if(d2<best2){best2=d2;best=q;}}
    }
    return best;
  }
}

// ===== SynKinect Studio / 3D Scanner / RgbRegistration.pde =====
class RgbProjection { float u,v,z;boolean valid; }

class RgbDepthRegistration {
  final AppConfig cfg;final Calibration depth;
  float[] rayX,rayY,rgbZBuffer;
  int preparedFrameId=-1;long preparedRgbFrameNumber=-1;int prepareCount=0;
  DepthFrame preparedDepth=null;RgbSnapshot preparedRgb=null;
  final RgbProjection sampleProjection=new RgbProjection();
  final float[] refineX=new float[4096],refineY=new float[4096];
  volatile float autoOffsetX=0.0f,autoOffsetY=0.0f,lastSyncSkewMs=Float.NaN,lastRefineGain=1.0f;
  volatile int lastRefineEdges=0;
  float projectionScaleX=1.0f,projectionScaleY=1.0f;

  RgbDepthRegistration(AppConfig cfg,Calibration depth){this.cfg=cfg;this.depth=depth;
    rebuildDepthRays();}
  void rebuildDepthRays(){
    int dw=max(1,depth.depthWidth),dh=max(1,depth.depthHeight),count=dw*dh;
    rayX=new float[count];rayY=new float[count];
    for(int v=0;v<dh;v++)for(int u=0;u<dw;u++){
      float xd=(u-depth.cx)/depth.fx,yd=(v-depth.cy)/depth.fy,x=xd,y=yd;
      for(int it=0;it<5;it++){float r2=x*x+y*y,r4=r2*r2,r6=r4*r2,radial=1.0f+cfg.depthK1*r2+cfg.depthK2*r4+cfg.depthK3*r6;
        if(abs(radial)<1e-6f)break;float ddx=2.0f*cfg.depthP1*x*y+cfg.depthP2*(r2+2.0f*x*x),ddy=cfg.depthP1*(r2+2.0f*y*y)+2.0f*cfg.depthP2*x*y;
        x=(xd-ddx)/radial;y=(yd-ddy)/radial;}
      int i=v*dw+u;rayX[i]=x;rayY[i]=y;
    }
    clearPreparedFrame();
  }
  float pointX(int index,float z){return rayX[index]*z;}float pointY(int index,float z){return rayY[index]*z;
    }
  void project(int index,float z,RgbProjection out,float extraX,float extraY){projectPoint(rayX[index]*z,rayY[index]*z,z,out,extraX,extraY);
    }
  void projectPoint(float xd,float yd,float zd,RgbProjection out,float extraX,float extraY){
    float xc=cfg.regR00*xd+cfg.regR01*yd+cfg.regR02*zd+cfg.regTx,yc=cfg.regR10*xd+cfg.regR11*yd+cfg.regR12*zd+cfg.regTy,zc=cfg.regR20*xd+cfg.regR21*yd+cfg.regR22*zd+cfg.regTz;

    if(zc<=0.001f){out.valid=false;return;}float x=xc/zc,y=yc/zc,r2=x*x+y*y,r4=r2*r2,r6=r4*r2,radial=1.0f+cfg.rgbK1*r2+cfg.rgbK2*r4+cfg.rgbK3*r6;

    float xDist=x*radial+2.0f*cfg.rgbP1*x*y+cfg.rgbP2*(r2+2.0f*x*x),yDist=y*radial+cfg.rgbP1*(r2+2.0f*y*y)+2.0f*cfg.rgbP2*x*y;

    float nominalU=cfg.rgbFx*xDist+cfg.rgbCx+cfg.colorRegistrationOffsetX+autoOffsetX+extraX,nominalV=cfg.rgbFy*yDist+cfg.rgbCy+cfg.colorRegistrationOffsetY+autoOffsetY+extraY;

    out.u=nominalU*projectionScaleX;out.v=nominalV*projectionScaleY;out.z=zc;out.valid=true;

  }
  void clearPreparedFrame(){preparedFrameId=-1;preparedRgbFrameNumber=-1;preparedDepth=null;
    preparedRgb=null;}
  void prepareFrame(DepthFrame frame,RgbSnapshot rgb){
    if(frame!=null&&frame.width>0&&frame.height>0&&(rayX==null||rayX.length!=frame.width*frame.height))rebuildDepthRays();
    if(frame==null||frame.depth==null||rgb==null||rgb.pixels==null){clearPreparedFrame();
      return;}
    if(preparedFrameId==frame.frameId&&preparedRgbFrameNumber==rgb.frameNumber&&preparedRgb==rgb)return;

    prepareCount++;projectionScaleX=rgb.width/(float)max(1,depth.depthWidth);
    projectionScaleY=rgb.height/(float)max(1,depth.depthHeight);
    lastSyncSkewMs=Float.isNaN(rgb.syncResidualMs)?Math.abs(frame.timestampUs-rgb.timestampUs)/1000.0f:rgb.syncResidualMs;

    if(lastSyncSkewMs>rgb.syncToleranceMs){clearPreparedFrame();return;}
    if(cfg.rgbAutoRefine&&cfg.rgbRefineSearchPx>0&&(prepareCount%cfg.rgbRefineEveryFrames)==0)refineFineOffset(frame,rgb);

    int depthPixels=frame.width*frame.height;
    if(cfg.rgbOcclusionFilter){
      int rgbPixels=rgb.width*rgb.height;if(rgbZBuffer==null||rgbZBuffer.length!=rgbPixels)rgbZBuffer=new float[rgbPixels];
      Arrays.fill(rgbZBuffer,Float.POSITIVE_INFINITY);RgbProjection q=new RgbProjection();

      for(int i=0;i<depthPixels;i++){int mm=frame.depth[i]&0xffff;if(mm==0)continue;
        mm=depth.correctedDepthMm(i,mm);float z=mm*depth.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
        project(i,z,q,0,0);if(!q.valid)continue;int x=round(q.u),y=round(q.v);if(x<0||x>=rgb.width||y<0||y>=rgb.height)continue;
        int ri=y*rgb.width+x;if(q.z<rgbZBuffer[ri])rgbZBuffer[ri]=q.z;}
    }
    preparedDepth=frame;preparedRgb=rgb;preparedFrameId=frame.frameId;preparedRgbFrameNumber=rgb.frameNumber;

  }
  int colorAt(int index,float z){
    RgbSnapshot rgb=preparedRgb;if(preparedFrameId<0||rgb==null||preparedDepth==null||index<0||index>=preparedDepth.depth.length)return 0;

    project(index,z,sampleProjection,0,0);return colorFromPreparedProjection(rgb,sampleProjection);

  }
  int colorAtPoint(float x,float y,float z){
    RgbSnapshot rgb=preparedRgb;if(preparedFrameId<0||rgb==null||preparedDepth==null)return 0;

    projectPoint(x,y,z,sampleProjection,0,0);return colorFromPreparedProjection(rgb,sampleProjection);

  }
  int colorFromPreparedProjection(RgbSnapshot rgb,RgbProjection q){
    if(!q.valid||q.u<0||q.v<0||q.u>rgb.width-1.001f||q.v>rgb.height-1.001f)return 0;

    if(cfg.rgbOcclusionFilter&&rgbZBuffer!=null){int zx=constrain(round(q.u),0,rgb.width-1),zy=constrain(round(q.v),0,rgb.height-1);
      float front=rgbZBuffer[zy*rgb.width+zx];if(Float.isFinite(front)&&q.z>front+cfg.rgbOcclusionToleranceM)return 0;
      }
    return sampleBilinearWeighted(rgb,q.u,q.v,lastSyncSkewMs);
  }
  int sampleBilinearWeighted(RgbSnapshot rgb,float u,float v,float syncMs){
    int x0=floor(u),y0=floor(v),x1=min(rgb.width-1,x0+1),y1=min(rgb.height-1,y0+1);
    float fx=u-x0,fy=v-y0;int c00=rgb.pixels[y0*rgb.width+x0],c10=rgb.pixels[y0*rgb.width+x1],c01=rgb.pixels[y1*rgb.width+x0],c11=rgb.pixels[y1*rgb.width+x1];

    float r0=lerp((c00>>16)&255,(c10>>16)&255,fx),r1=lerp((c01>>16)&255,(c11>>16)&255,fx),g0=lerp((c00>>8)&255,(c10>>8)&255,fx),g1=lerp((c01>>8)&255,(c11>>8)&255,
      fx),b0=lerp(c00&255,c10&255,fx),b1=lerp(c01&255,c11&255,fx);
    int r=constrain(round(lerp(r0,r1,fy)),0,255),g=constrain(round(lerp(g0,g1,fy)),0,255),b=constrain(round(lerp(b0,b1,fy)),0,255),luma=(77*r+150*g+29*b)>>8;
    float exposure=1.0f;
    if(luma<cfg.rgbExposureLowLuma)exposure=max(0.05f,luma/(float)max(1,cfg.rgbExposureLowLuma));
    else if(luma>cfg.rgbExposureHighLuma)exposure=max(0.05f,(255-luma)/(float)max(1,255-cfg.rgbExposureHighLuma));
    float sync=1.0f-constrain(syncMs/max(1.0f,rgb.syncToleranceMs),0.0f,1.0f),quality=constrain(exposure*(0.35f+0.65f*sync)*rgb.frameQuality,0.05f,1.0f);
    int alpha=constrain(round(quality*255.0f),1,255);return(alpha<<24)|(r<<16)|(g<<8)|b;

  }
  void refineFineOffset(DepthFrame frame,RgbSnapshot rgb){
    int count=0,step=max(2,cfg.rgbRefineSampleStep),threshold=cfg.rgbRefineEdgeThresholdMm;
    RgbProjection q=new RgbProjection();
    for(int v=step;v<frame.height-step&&count<refineX.length;v+=step)for(int u=step;u<frame.width-step&&count<refineX.length;u+=step){int i=v*frame.width+u,
      mm=frame.depth[i]&0xffff;if(mm==0)continue;mm=depth.correctedDepthMm(i,mm);
      int ri=v*frame.width+min(frame.width-1,u+step),di=min(frame.height-1,v+step)*frame.width+u,mr=frame.depth[ri]&0xffff,md=frame.depth[di]&0xffff;
      if(mr!=0)mr=depth.correctedDepthMm(ri,mr);if(md!=0)md=depth.correctedDepthMm(di,md);
      boolean edge=(mr!=0&&abs(mr-mm)>=threshold)||(md!=0&&abs(md-mm)>=threshold);
      if(!edge)continue;float z=mm*depth.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
      project(i,z,q,0,0);if(!q.valid||q.u<3||q.v<3||q.u>=rgb.width-3||q.v>=rgb.height-3)continue;
      refineX[count]=q.u;refineY[count]=q.v;count++;}
    lastRefineEdges=count;if(count<cfg.rgbRefineMinimumEdges){lastRefineGain=1.0f;
      return;}int search=cfg.rgbRefineSearchPx,bestDx=0,bestDy=0;double base=0,best=-1;

    for(int dy=-search;dy<=search;dy++)for(int dx=-search;dx<=search;dx++){double score=0;
      for(int i=0;i<count;i++)score+=rgbGradient(rgb,round(refineX[i])+dx,round(refineY[i])+dy);
      if(dx==0&&dy==0)base=score;if(score>best){best=score;bestDx=dx;bestDy=dy;}}
    lastRefineGain=(float)(best/Math.max(1.0,base));if((bestDx!=0||bestDy!=0)&&best>base*1.01){autoOffsetX=constrain(autoOffsetX+bestDx*cfg.rgbRefineAlpha,
        -cfg.rgbRefineMaxOffsetPx,cfg.rgbRefineMaxOffsetPx);autoOffsetY=constrain(autoOffsetY+bestDy*cfg.rgbRefineAlpha,-cfg.rgbRefineMaxOffsetPx,cfg.rgbRefineMaxOffsetPx);
      }
  }
  int rgbGradient(RgbSnapshot rgb,int x,int y){if(x<1||x>=rgb.width-1||y<1||y>=rgb.height-1)return 0;
    int lx=luma(rgb.pixels[y*rgb.width+x-1]),rx=luma(rgb.pixels[y*rgb.width+x+1]),uy=luma(rgb.pixels[(y-1)*rgb.width+x]),dy=luma(rgb.pixels[(y+1)*rgb.width+x]);
    return abs(rx-lx)+abs(dy-uy);}int luma(int c){int r=(c>>16)&255,g=(c>>8)&255,b=c&255;
    return(77*r+150*g+29*b)>>8;}
}

// ===== SynKinect Studio / 3D Scanner / ScanCoverage.pde =====
class ScanCoverageTracker {
  final AppConfig cfg;
  PVector gravityReference=null;
  float directionProbeDeg=0,sweepDeg=0,trackedAngleDeg=0,imuDeviationDeg=0;
  float filteredStepDeg=0,reverseDebtDeg=0,lastAcceptedStepDeg=0;
  int direction=0,coveredCount=0,stableMotionFrames=0;
  boolean imuStable=true,objectDetected=false,complete=false;
  boolean[] covered;
  ScanCoverageTracker(AppConfig cfg){this.cfg=cfg;resetBins();}
  void resetBins(){covered=new boolean[max(24,cfg.scanCoverageBins)];coveredCount=0;}
  void reset(){
    gravityReference=null;directionProbeDeg=0;direction=0;sweepDeg=0;trackedAngleDeg=0;
    filteredStepDeg=0;reverseDebtDeg=0;lastAcceptedStepDeg=0;stableMotionFrames=0;
    imuDeviationDeg=0;imuStable=true;objectDetected=false;complete=false;resetBins();
  }
  void updateDetection(boolean detected){objectDetected=detected;}

  void updateTracking(RigidTransform pose,MotionSample motion,float signedYawStepDeg){
    updateImu(motion);if(pose==null||complete)return;
    float raw=signedYawStepDeg;
    if(!Float.isFinite(raw)||abs(raw)>cfg.scanRotationMaxStepDeg)return;

    // Suppress sub-deadband jitter without discarding slow real motion forever.
    if(abs(raw)<cfg.scanRotationDeadbandDeg){
      filteredStepDeg*=.65f;stableMotionFrames=max(0,stableMotionFrames-1);return;
    }

    float a=constrain(cfg.scanTurnFilterAlpha,.05f,1.0f);
    if(filteredStepDeg==0||filteredStepDeg*raw>=0)filteredStepDeg=lerp(filteredStepDeg,raw,a);
    else filteredStepDeg=lerp(filteredStepDeg,raw,min(1.0f,a*1.45f));
    float step=lerp(raw,filteredStepDeg,.35f);
    if(abs(step)<cfg.scanRotationDeadbandDeg)return;

    lastAcceptedStepDeg=step;trackedAngleDeg+=step;stableMotionFrames=min(120,stableMotionFrames+1);

    if(direction==0){
      // Direction probe integrates signed evidence, so random +/- jitter cancels.
      directionProbeDeg=constrain(directionProbeDeg+step,-cfg.scanDirectionLockDeg*2.0f,cfg.scanDirectionLockDeg*2.0f);
      if(abs(directionProbeDeg)>=cfg.scanDirectionLockDeg){
        direction=directionProbeDeg>=0?1:-1;
        sweepDeg=abs(directionProbeDeg);
        reverseDebtDeg=0;
      }
      return;
    }

    float aligned=direction*step;
    if(aligned>=0){
      reverseDebtDeg=max(0,reverseDebtDeg-aligned*.85f);
      sweepDeg=min(cfg.scanFullTurnDeg,max(0,sweepDeg+aligned));
    }else{
      reverseDebtDeg+=-aligned;
      // Ignore short reverse flicker from ICP. Only sustained reverse motion
      // subtracts progress, and a long deliberate reversal may re-lock direction.
      if(reverseDebtDeg>cfg.scanReverseCommitDeg){
        float committed=min(-aligned,reverseDebtDeg-cfg.scanReverseCommitDeg);
        sweepDeg=max(0,sweepDeg-committed);
      }
      if(reverseDebtDeg>=cfg.scanDirectionRelockDeg){
        direction=-direction;
        directionProbeDeg=direction*min(cfg.scanDirectionLockDeg,reverseDebtDeg);
        reverseDebtDeg=0;
        filteredStepDeg=step;
      }
    }
  }

  void confirmFusion(){
    if(covered==null||covered.length==0)return;
    // Fused coverage follows the robust dominant-turn coordinate, not raw yaw
    // jitter. Reverse noise therefore cannot paint false sectors.
    float robustAngle=direction==0?directionProbeDeg:direction*sweepDeg;
    float wrapped=robustAngle%360.0f;if(wrapped<0)wrapped+=360.0f;
    int bin=constrain(floor(wrapped/360.0f*covered.length),0,covered.length-1);
    if(!covered[bin]){covered[bin]=true;coveredCount++;}
    if(coverageFraction()>=cfg.scanCoverageRequired&&sweepDeg>=cfg.scanCompleteDeg){
      sweepDeg=min(cfg.scanFullTurnDeg,max(sweepDeg,cfg.scanCompleteDeg));complete=true;
    }
  }

  void update(RigidTransform pose,MotionSample motion){updateTracking(pose,motion,0);confirmFusion();}

  void updateImu(MotionSample motion){
    if(motion==null||!motion.gravityReliable()){imuStable=true;imuDeviationDeg=0;return;}
    PVector g=motion.gravityUnit();if(g==null)return;
    if(gravityReference==null){gravityReference=g.copy();imuStable=true;imuDeviationDeg=0;return;}
    imuDeviationDeg=degrees(acos(constrain(gravityReference.dot(g),-1,1)));imuStable=imuDeviationDeg<=cfg.scanMaxSensorTiltDriftDeg;
  }

  float coverageFraction(){return covered==null||covered.length==0?0:coveredCount/(float)covered.length;}
  float trackingProgress(){if(complete)return 1.0f;return constrain(sweepDeg/max(1.0f,cfg.scanCompleteDeg),0,1);}
  float fusionProgress(){return constrain(coverageFraction()/max(0.01f,cfg.scanCoverageRequired),0,1);}
  float progress(){return trackingProgress();}
}

// ===== SynKinect Studio / 3D Scanner / ScannerProtocol.pde =====
class ScannerProtocol {
  final int MAGIC = 0x43534D52;
  final int FRAME_MAGIC = 0x46534D52;
  final int VERSION = 1;
  final int CMD_SUBSCRIBE_STREAMS = 1;
  final int CMD_GET_DRIVER_SETTINGS = 2;
  final int DRIVER_RGB_HQ = 1;

  final int WIDTH = 640;
  final int HEIGHT = 480;
  final int RGB_HQ_WIDTH = 1280;
  final int RGB_HQ_HEIGHT = 1024;
  final int MODE_RGB = 0;
  final int MODE_IR = 1;
  final int MODE_DEPTH = 2;
  final int MODE_RGB_HQ = 3;
  final int STREAM_RGB = 1;
  final int STREAM_IR = 2;
  final int STREAM_DEPTH = 4;
  final int STREAM_RGB_HQ = 8;
  final int STREAM_SESSION = STREAM_RGB | STREAM_DEPTH;
  final int STREAM_SESSION_HQ = STREAM_RGB | STREAM_DEPTH | STREAM_RGB_HQ;

  final int CAP_RGB_DEPTH_CONCURRENT = 1;
  final int CAP_EXCLUSIVE_VIDEO_MODE = 2;
  final int CAP_PROJECTOR_REFCOUNTED = 4;
  final int CAP_ACCELEROMETER = 8;
  final int CAP_RGB_HQ = 16;
  final int CAP_RAW_SENSOR_FRAMES = 64;
  final int CAP_PERSISTENT_ISO_SESSION = 128;
  final int REQUIRED_CAPABILITIES = CAP_RGB_DEPTH_CONCURRENT | CAP_EXCLUSIVE_VIDEO_MODE | CAP_PROJECTOR_REFCOUNTED | CAP_RAW_SENSOR_FRAMES;


  final int DEPTH_FRAME_MM16 = 1003;
  final int PIXEL_BAYER_GRBG8 = 4;
  final int PIXEL_NV12 = 0x3231564E;
  final int PIXEL_BGRA32 = 0x41524742;
  final int PIXEL_JPEG = 1005;
  final int PIXEL_IR_RAW10_PACKED = 5;
  final int PIXEL_IR_U16 = 1004;
  final int PIXEL_DEPTH_RAW11_PACKED = 6;
  final int FLAG_FRAME_RECOVERED = 1;
  final int KNOWN_FRAME_FLAGS = FLAG_FRAME_RECOVERED;

  final int RGB_RAW_BYTES = WIDTH * HEIGHT;
  final int DEPTH_RAW11_PACKED_BYTES = WIDTH * HEIGHT * 11 / 8;
  final int RGB_HQ_BYTES = RGB_HQ_WIDTH * RGB_HQ_HEIGHT;
  final int MAX_PAYLOAD_BYTES = RGB_HQ_BYTES;
  final int ABSOLUTE_MAX_PAYLOAD_BYTES = 128 * 1024 * 1024;
  final int REPLY_BYTES = 68;
  final int FRAME_HEADER_BYTES = 76;

}

// Processing merges PDE source files into the sketch class. ScannerProtocol is therefore
// an inner type and must contain constants only; executable protocol helpers
// remain sketch methods in this source file because Processing does not allow them inside that class.
int scannerMaskForMode(int mode) {
  return mode == studio.services.scannerProtocol.MODE_RGB ? studio.services.scannerProtocol.STREAM_RGB
       : mode == studio.services.scannerProtocol.MODE_IR ? studio.services.scannerProtocol.STREAM_IR
       : mode == studio.services.scannerProtocol.MODE_DEPTH ? studio.services.scannerProtocol.STREAM_DEPTH
       : mode == studio.services.scannerProtocol.MODE_RGB_HQ ? studio.services.scannerProtocol.STREAM_RGB_HQ : 0;

}

boolean scannerFormatAllowedForMode(int mode,int fmt) {
  if(mode==studio.services.scannerProtocol.MODE_RGB||mode==studio.services.scannerProtocol.MODE_RGB_HQ)
    return fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8||fmt==studio.services.scannerProtocol.PIXEL_NV12||fmt==studio.services.scannerProtocol.PIXEL_BGRA32||fmt==studio.services.scannerProtocol.PIXEL_JPEG;
  if(mode==studio.services.scannerProtocol.MODE_IR)return fmt==studio.services.scannerProtocol.PIXEL_IR_RAW10_PACKED||fmt==studio.services.scannerProtocol.PIXEL_IR_U16;
  return mode==studio.services.scannerProtocol.MODE_DEPTH&&(fmt==studio.services.scannerProtocol.PIXEL_DEPTH_RAW11_PACKED||fmt==studio.services.scannerProtocol.DEPTH_FRAME_MM16);

}

boolean scannerPayloadAllowedForMode(int mode,int fmt,int bytes) {
  if(mode==studio.services.scannerProtocol.MODE_RGB){int w=scannerExpectedWidthForMode(mode),h=scannerExpectedHeightForMode(mode);if(w<=0||h<=0)return bytes>0;
    if(fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8)return bytes==w*h;
    if(fmt==studio.services.scannerProtocol.PIXEL_NV12)return bytes==w*h*3/2;
    if(fmt==studio.services.scannerProtocol.PIXEL_BGRA32)return bytes==w*h*4;
    if(fmt==studio.services.scannerProtocol.PIXEL_JPEG)return bytes>256&&bytes<=studio.services.scannerProtocol.ABSOLUTE_MAX_PAYLOAD_BYTES;
    return false;
  }

  if(mode==studio.services.scannerProtocol.MODE_IR){int w=scannerExpectedWidthForMode(mode),h=scannerExpectedHeightForMode(mode);if(fmt==studio.services.scannerProtocol.PIXEL_IR_U16)return w<=0||h<=0?bytes>0:bytes==w*h*2;return fmt==studio.services.scannerProtocol.PIXEL_IR_RAW10_PACKED&&(w<=0||h<=0?bytes>0:bytes==w*h*10/8);}
  if(mode==studio.services.scannerProtocol.MODE_DEPTH){int w=scannerExpectedWidthForMode(mode),h=scannerExpectedHeightForMode(mode);
    if(fmt==studio.services.scannerProtocol.DEPTH_FRAME_MM16)return w<=0||h<=0?bytes>0:bytes==w*h*2;
    return fmt==studio.services.scannerProtocol.PIXEL_DEPTH_RAW11_PACKED&&(w<=0||h<=0?bytes>0:bytes==w*h*11/8);
  }

  if(mode==studio.services.scannerProtocol.MODE_RGB_HQ){int w=scannerExpectedWidthForMode(mode),h=scannerExpectedHeightForMode(mode);if(fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8)return bytes==w*h;if(fmt==studio.services.scannerProtocol.PIXEL_NV12)return bytes==w*h*3/2;if(fmt==studio.services.scannerProtocol.PIXEL_BGRA32)return bytes==w*h*4;if(fmt==studio.services.scannerProtocol.PIXEL_JPEG)return bytes>256&&bytes<=studio.services.scannerProtocol.ABSOLUTE_MAX_PAYLOAD_BYTES;}return false;

}
int scannerExpectedWidthForMode(int mode){KinectDevice d=studio.selectedKinect();if(d!=null&&!"xbox-360".equals(d.generation)){if(mode==studio.services.scannerProtocol.MODE_DEPTH&&d.depthWidth>0)return d.depthWidth;if(mode==studio.services.scannerProtocol.MODE_IR&&d.irWidth>0)return d.irWidth;if((mode==studio.services.scannerProtocol.MODE_RGB||mode==studio.services.scannerProtocol.MODE_RGB_HQ)&&d.colorWidth>0)return d.colorWidth;}
  return mode==studio.services.scannerProtocol.MODE_RGB_HQ?studio.services.scannerProtocol.RGB_HQ_WIDTH:studio.services.scannerProtocol.WIDTH;}
int scannerExpectedHeightForMode(int mode){KinectDevice d=studio.selectedKinect();if(d!=null&&!"xbox-360".equals(d.generation)){if(mode==studio.services.scannerProtocol.MODE_DEPTH&&d.depthHeight>0)return d.depthHeight;if(mode==studio.services.scannerProtocol.MODE_IR&&d.irHeight>0)return d.irHeight;if((mode==studio.services.scannerProtocol.MODE_RGB||mode==studio.services.scannerProtocol.MODE_RGB_HQ)&&d.colorHeight>0)return d.colorHeight;}
  return mode==studio.services.scannerProtocol.MODE_RGB_HQ?studio.services.scannerProtocol.RGB_HQ_HEIGHT:studio.services.scannerProtocol.HEIGHT;}
boolean scannerDimensionsAllowedForMode(int mode,int w,int h){if(w<=0||h<=0)return false;KinectDevice d=studio.selectedKinect();if(d==null||"xbox-360".equals(d.generation))return w==scannerExpectedWidthForMode(mode)&&h==scannerExpectedHeightForMode(mode);int ew=scannerExpectedWidthForMode(mode),eh=scannerExpectedHeightForMode(mode);return ew<=0||eh<=0||(w==ew&&h==eh);}




// ===== SynKinect Studio / 3D Scanner / RGB HQ processing =====
static class RgbFrameQuality {
  static float clamp01(float v){return Math.max(0.0f,Math.min(1.0f,v));}
  static float score(byte[] data,int w,int h,int fmt){
    if(data==null||w<=2||h<=2)return 0.0f;
    if(fmt==4&&data.length==w*h)return scoreBayer(data,w,h);
    if(fmt==1005){try{BufferedImage image=ImageIO.read(new ByteArrayInputStream(data));if(image==null)return 0;int iw=image.getWidth(),ih=image.getHeight(),step=Math.max(4,Math.min(iw,ih)/80);long grad=0;int good=0,n=0;for(int y=step;y<ih-step;y+=step)for(int x=step;x<iw-step;x+=step){int c=image.getRGB(x,y),l=image.getRGB(x-step,y),r=image.getRGB(x+step,y),u=image.getRGB(x,y-step),d=image.getRGB(x,y+step);int lum=((c>>16)&255)*54+((c>>8)&255)*183+(c&255)*19;lum>>=8;if(lum>16&&lum<242)good++;int ll=(((l>>16)&255)*54+((l>>8)&255)*183+(l&255)*19)>>8,rr=(((r>>16)&255)*54+((r>>8)&255)*183+(r&255)*19)>>8,uu=(((u>>16)&255)*54+((u>>8)&255)*183+(u&255)*19)>>8,dd=(((d>>16)&255)*54+((d>>8)&255)*183+(d&255)*19)>>8;grad+=Math.abs(rr-ll)+Math.abs(dd-uu);n++;}if(n==0)return 0;return clamp01((good/(float)n)*(.35f+.65f*clamp01((grad/(float)n)/42.0f)));}catch(Exception ignored){return 0;}}
    if(fmt==0x41524742&&data.length==w*h*4)return .70f;
    if((fmt==1||fmt==0x3231564E)&&data.length==w*h*3/2)return .68f;
    return 0.0f;
  }
  static float scoreBayer(byte[] data,int w,int h){
    long grad=0;int samples=0,good=0,clipped=0;int step=Math.max(6,Math.min(w,h)/96);
    if((step&1)!=0)step++;
    for(int y=step;y<h-step;y+=step)for(int x=step;x<w-step;x+=step){int i=y*w+x,v=data[i]&255;
      if(v>=20&&v<=240)good++;if(v<6||v>249)clipped++;int gx=Math.abs((data[i+2]&255)-(data[i-2]&255)),gy=Math.abs((data[i+2*w]&255)-(data[i-2*w]&255));
      grad+=gx+gy;samples++;}
    if(samples==0)return 0;float exposure=clamp01(good/(float)samples)*(1.0f-0.65f*clamp01(clipped/(float)samples));
    float sharp=clamp01((grad/(float)samples)/38.0f);return clamp01(exposure*(0.25f+0.75f*sharp));

  }
}

static class ColorStats {float r,g,b;int samples;boolean valid(){return samples>16&&r>1&&g>1&&b>1;
    }}
static class ColorReference {
  final float r,g,b;final boolean valid;
  ColorReference(float r,float g,float b,boolean valid){this.r=r;this.g=g;this.b=b;
    this.valid=valid;}
  static ColorReference fromFrames(List<HighQualityKeyframe> frames){
    if(frames==null||frames.isEmpty())return new ColorReference(128,128,128,false);

    float[] rs=new float[frames.size()],gs=new float[frames.size()],bs=new float[frames.size()];
    int n=0;
    for(HighQualityKeyframe k:frames){if(k==null||k.colorData==null)continue;ColorStats st=RgbHqProcessor.rawStats(k.colorData,k.colorWidth,k.colorHeight,
        k.colorPixelFormat);if(!st.valid())continue;rs[n]=st.r;gs[n]=st.g;bs[n]=st.b;
      n++;}
    if(n==0)return new ColorReference(128,128,128,false);Arrays.sort(rs,0,n);Arrays.sort(gs,0,n);
    Arrays.sort(bs,0,n);int m=n/2;float r=(n&1)==1?rs[m]:(rs[m-1]+rs[m])*0.5f,g=(n&1)==1?gs[m]:(gs[m-1]+gs[m])*0.5f,b=(n&1)==1?bs[m]:(bs[m-1]+bs[m])*0.5f;
    return new ColorReference(r,g,b,true);
  }
}

static class RgbHqProcessor {
  static int clamp8(int v){return v<0?0:v>255?255:v;}
  static int mirror(int p,int size){if(p<0)p=-p;if(p>=size)p=2*(size-1)-p;return p<0?0:p>=size?size-1:p;
    }
  static int sample(byte[] b,int w,int h,int x,int y){return b[mirror(y,h)*w+mirror(x,w)]&255;
    }
  static int avg2(int a,int b){return(a+b+1)>>1;}static int avg4(int a,int b,int c,int d){return(a+b+c+d+2)>>2;
    }
  static int rgbAt(byte[] b,int w,int h,int x,int y){
    boolean yo=(y&1)!=0,xo=(x&1)!=0;int c=sample(b,w,h,x,y),r=0,g=0,bl=0;
    if(!yo&&xo){r=c;int lh=sample(b,w,h,x-1,y),rh=sample(b,w,h,x+1,y),uv=sample(b,w,h,x,y-1),dv=sample(b,w,h,x,y+1);
      g=Math.abs(lh-rh)<=Math.abs(uv-dv)?avg2(lh,rh):avg2(uv,dv);bl=avg4(sample(b,w,h,x-1,y-1),sample(b,w,h,x+1,y-1),sample(b,w,h,x-1,y+1),sample(b,w,h,
        x+1,y+1));}
    else if(yo&&!xo){bl=c;int lh=sample(b,w,h,x-1,y),rh=sample(b,w,h,x+1,y),uv=sample(b,w,h,x,y-1),dv=sample(b,w,h,x,y+1);
      g=Math.abs(lh-rh)<=Math.abs(uv-dv)?avg2(lh,rh):avg2(uv,dv);r=avg4(sample(b,w,h,x-1,y-1),sample(b,w,h,x+1,y-1),sample(b,w,h,x-1,y+1),sample(b,w,h,
        x+1,y+1));}
    else if(!yo){g=c;r=avg2(sample(b,w,h,x-1,y),sample(b,w,h,x+1,y));bl=avg2(sample(b,w,h,x,y-1),sample(b,w,h,x,y+1));
      }
    else{g=c;r=avg2(sample(b,w,h,x,y-1),sample(b,w,h,x,y+1));bl=avg2(sample(b,w,h,x-1,y),sample(b,w,h,x+1,y));
      }
    return 0xff000000|(r<<16)|(g<<8)|bl;
  }
  static boolean decodeBayerGrbg(byte[] b,int w,int h,int[] out){
    if(b==null||out==null||b.length!=w*h||out.length<w*h)return false;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)out[y*w+x]=rgbAt(b,w,h,x,y);
    return true;
  }
  static byte[] bayerGrbgToNv12(byte[] b,int w,int h){
    if(b==null||w<=0||h<=0||(w&1)!=0||(h&1)!=0||b.length!=w*h)return null;
    int count=w*h;byte[] out=new byte[count*3/2];
    for(int y=0;y<h;y+=2)for(int x=0;x<w;x+=2){
      int c0=rgbAt(b,w,h,x,y),c1=rgbAt(b,w,h,x+1,y),c2=rgbAt(b,w,h,x,y+1),c3=rgbAt(b,w,h,x+1,y+1);

      int r0=(c0>>16)&255,g0=(c0>>8)&255,b0=c0&255,r1=(c1>>16)&255,g1=(c1>>8)&255,b1=c1&255;

      int r2=(c2>>16)&255,g2=(c2>>8)&255,b2=c2&255,r3=(c3>>16)&255,g3=(c3>>8)&255,b3=c3&255;

      out[y*w+x]=(byte)clamp8(((66*r0+129*g0+25*b0+128)>>8)+16);
      out[y*w+x+1]=(byte)clamp8(((66*r1+129*g1+25*b1+128)>>8)+16);
      out[(y+1)*w+x]=(byte)clamp8(((66*r2+129*g2+25*b2+128)>>8)+16);
      out[(y+1)*w+x+1]=(byte)clamp8(((66*r3+129*g3+25*b3+128)>>8)+16);
      int r=(r0+r1+r2+r3+2)>>2,g=(g0+g1+g2+g3+2)>>2,bl=(b0+b1+b2+b3+2)>>2;
      int u=((-38*r-74*g+112*bl+128)>>8)+128,v=((112*r-94*g-18*bl+128)>>8)+128,uv=count+(y/2)*w+x;

      out[uv]=(byte)clamp8(u);out[uv+1]=(byte)clamp8(v);
    }
    return out;
  }
  static ColorStats rawStats(byte[] data,int w,int h,int fmt){
    ColorStats st=new ColorStats();if(data==null||w<=0||h<=0)return st;long sr=0,sg=0,sb=0;
    int n=0,step=Math.max(8,Math.min(w,h)/64);if((step&1)!=0)step++;
    if(fmt==4&&data.length==w*h){for(int y=4;y<h-4;y+=step)for(int x=4;x<w-4;x+=step){int r,g,b;
        if((y&1)==0){r=sample(data,w,h,x|1,y);b=sample(data,w,h,x&~1,y+1);g=avg2(sample(data,w,h,x&~1,y),sample(data,w,h,x|1,y+1));
          }else{r=sample(data,w,h,x|1,y-1);b=sample(data,w,h,x&~1,y);g=avg2(sample(data,w,h,x|1,y),sample(data,w,h,x&~1,y-1));
          }if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}
    else if((fmt==1||fmt==0x3231564E)&&data.length==w*h*3/2){int ySize=w*h;for(int y=2;y<h-2;y+=step)for(int x=2;x<w-2;x+=step){int yy=data[y*w+x]&255,uv=ySize+(y/2)*w+(x&~1),
        u=(data[uv]&255)-128,v=(data[uv+1]&255)-128,c=Math.max(0,yy-16),r=clamp8((298*c+409*v+128)>>8),g=clamp8((298*c-100*u-208*v+128)>>8),b=clamp8((298*c+516*u+128)>>8);
        if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}
    else if(fmt==0x41524742&&data.length==w*h*4){for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){int i=(y*w+x)*4,b=data[i]&255,g=data[i+1]&255,r=data[i+2]&255;if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}
    else if(fmt==1005){try{BufferedImage image=ImageIO.read(new ByteArrayInputStream(data));if(image!=null){int iw=image.getWidth(),ih=image.getHeight();for(int y=0;y<ih;y+=step)for(int x=0;x<iw;x+=step){int c=image.getRGB(x,y),r=(c>>16)&255,g=(c>>8)&255,b=c&255;if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}}catch(Exception ignored){}}
    st.samples=n;if(n>0){st.r=sr/(float)n;st.g=sg/(float)n;st.b=sb/(float)n;}return st;

  }
  static ColorStats decodedStats(int[] pixels){ColorStats st=new ColorStats();if(pixels==null)return st;
    long sr=0,sg=0,sb=0;int n=0,step=Math.max(1,pixels.length/8192);for(int i=0;i<pixels.length;i+=step){int c=pixels[i],r=(c>>16)&255,g=(c>>8)&255,b=c&255;
      if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}st.samples=n;
    if(n>0){st.r=sr/(float)n;st.g=sg/(float)n;st.b=sb/(float)n;}return st;}
  static void normalize(int[] pixels,ColorReference ref,AppConfig cfg){if(pixels==null||ref==null||!ref.valid)return;
    ColorStats cur=decodedStats(pixels);if(!cur.valid())return;float gr=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,ref.r/cur.r)),
    gg=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,ref.g/cur.g)),gb=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,
      ref.b/cur.b));float mean=(gr+gg+gb)/3.0f;gr=0.78f*gr+0.22f*mean;gg=0.78f*gg+0.22f*mean;
    gb=0.78f*gb+0.22f*mean;for(int i=0;i<pixels.length;i++){int c=pixels[i],r=clamp8(Math.round(((c>>16)&255)*gr)),g=clamp8(Math.round(((c>>8)&255)*gg)),
      b=clamp8(Math.round((c&255)*gb));pixels[i]=0xff000000|(r<<16)|(g<<8)|b;}}
  static void sharpen(int[] pixels,int w,int h,float amount){if(pixels==null||w<3||h<3||amount<=0)return;
    int[] prev=new int[w],cur=new int[w],next=new int[w];System.arraycopy(pixels,0,prev,0,w);
    System.arraycopy(pixels,0,cur,0,w);System.arraycopy(pixels,w,next,0,w);for(int y=1;y<h-1;y++){if(y>1){int[] tmp=prev;
        prev=cur;cur=next;next=tmp;System.arraycopy(pixels,(y+1)*w,next,0,w);}for(int x=1;x<w-1;x++){int c=cur[x],l=cur[x-1],r=cur[x+1],u=prev[x],d=next[x];
        int rr=sharpenChannel((c>>16)&255,(l>>16)&255,(r>>16)&255,(u>>16)&255,(d>>16)&255,amount),gg=sharpenChannel((c>>8)&255,(l>>8)&255,(r>>8)&255,(u>>8)&255,
          (d>>8)&255,amount),bb=sharpenChannel(c&255,l&255,r&255,u&255,d&255,amount);
        pixels[y*w+x]=0xff000000|(rr<<16)|(gg<<8)|bb;}}}
  static int sharpenChannel(int c,int l,int r,int u,int d,float amount){float blur=(4*c+l+r+u+d)/8.0f;
    return clamp8(Math.round(c+amount*(c-blur)));}
}

// ===== SynKinect Studio / 3D Scanner / HighQualityReconstruction.pde =====
class HighQualityKeyframe {
  final DepthFrame depth;
  final byte[] colorData;final int colorWidth,colorHeight,colorPixelFormat;final float colorQuality;

  final long rgbFrameNumber,rgbTimestampUs,rawSkewUs,residualUs;
  final RigidTransform initialPose;
  final float targetDepthM,bandM,sweepDeg;

  HighQualityKeyframe(RgbdFramePair pair,RawRgbFrame preferredColor,RigidTransform pose,float targetDepthM,float bandM,float sweepDeg,AppConfig cfg){
    this.depth=copyDepth(pair.depth);
    RawRgbFrame color=preferredColor!=null&&preferredColor.quality>=cfg.rgbHqMinimumFrameQuality?preferredColor:pair.rgb;

    boolean usable=color!=null&&color.data!=null&&color.quality>=cfg.rgbHqMinimumFrameQuality;

    this.colorData=usable?Arrays.copyOf(color.data,color.data.length):null;
    this.colorWidth=usable?color.width:0;this.colorHeight=usable?color.height:0;this.colorPixelFormat=usable?color.pixelFormat:0;
    this.colorQuality=usable?color.quality:0;
    this.rgbFrameNumber=usable?color.frameNumber:0;
    this.rgbTimestampUs=usable?color.timestampUs:0;
    this.rawSkewUs=usable?Math.abs(color.timestampUs-pair.depth.timestampUs):pair.rawSkewUs;
    this.residualUs=this.rawSkewUs;
    this.initialPose=new RigidTransform();this.initialPose.set(pose);
    this.targetDepthM=targetDepthM;this.bandM=bandM;this.sweepDeg=sweepDeg;
  }

  DepthFrame copyDepth(DepthFrame src){
    DepthFrame d=new DepthFrame();d.frameId=src.frameId;d.width=src.width;d.height=src.height;
    d.stride=src.stride;d.pixelFormat=src.pixelFormat;
    d.frameNumber=src.frameNumber;d.timestampUs=src.timestampUs;d.depth=Arrays.copyOf(src.depth,src.depth.length);
    d.validCount=src.validCount;d.plausibleCount=src.plausibleCount;
    d.deviceCalibrated=src.deviceCalibrated;d.transportRecovered=src.transportRecovered;

    MotionSample m=new MotionSample();if(src.motion!=null){m.flags=src.motion.flags;
      m.accelX=src.motion.accelX;m.accelY=src.motion.accelY;m.accelZ=src.motion.accelZ;
      m.tiltTenths=src.motion.tiltTenths;m.timestampMs=src.motion.timestampMs;}d.motion=m;
    return d;
  }

  long estimatedBytes(){return (long)depth.depth.length*2L+(colorData==null?0:colorData.length)+192L;
    }
}

class HighQualityScanArchive {
  final AppConfig cfg;
  final ArrayList<HighQualityKeyframe> frames=new ArrayList<HighQualityKeyframe>();

  HighQualityScanArchive(AppConfig cfg){this.cfg=cfg;}
  synchronized void clear(){frames.clear();}
  synchronized int size(){return frames.size();}
  synchronized long estimatedBytes(){long n=0;for(HighQualityKeyframe f:frames)n+=f.estimatedBytes();
    return n;}
  synchronized ArrayList<HighQualityKeyframe> snapshot(){return new ArrayList<HighQualityKeyframe>(frames);
    }

  synchronized boolean offer(RgbdFramePair pair,RawRgbFrame preferredColor,RigidTransform pose,float targetDepthM,float bandM,float sweepDeg){
    if(pair==null||pair.depth==null||pose==null||frames.size()>=cfg.hqMaxKeyframes)return false;

    if(!frames.isEmpty()){
      HighQualityKeyframe last=frames.get(frames.size()-1);
      float rot=rotationDeltaDeg(last.initialPose,pose),trans=translationDelta(last.initialPose,pose);

      float sweepDelta=abs(sweepDeg-last.sweepDeg);
      if(max(rot,sweepDelta)<cfg.hqKeyframeMinRotationDeg&&trans<cfg.hqKeyframeMinTranslationM)return false;

    }
    frames.add(new HighQualityKeyframe(pair,preferredColor,pose,targetDepthM,bandM,sweepDeg,cfg));
    return true;
  }

  float translationDelta(RigidTransform a,RigidTransform b){float dx=a.m[3]-b.m[3],dy=a.m[7]-b.m[7],dz=a.m[11]-b.m[11];
    return sqrt(dx*dx+dy*dy+dz*dz);}
  float rotationDeltaDeg(RigidTransform a,RigidTransform b){
    float r00=a.m[0]*b.m[0]+a.m[4]*b.m[4]+a.m[8]*b.m[8];
    float r11=a.m[1]*b.m[1]+a.m[5]*b.m[5]+a.m[9]*b.m[9];
    float r22=a.m[2]*b.m[2]+a.m[6]*b.m[6]+a.m[10]*b.m[10];
    float c=constrain((r00+r11+r22-1.0f)*0.5f,-1.0f,1.0f);return degrees(acos(c));

  }
}

class RobustIcpResult {RigidTransform pose=new RigidTransform();float rms=Float.POSITIVE_INFINITY;
  int matches=0;boolean good=false;}
class RobustMatch {final PVector sourceWorld=new PVector();PVector target;float d2,confidence=1.0f;
  }

class RobustIcpRefiner {
  final AppConfig cfg;final QuaternionFit fitter=new QuaternionFit();
  final ArrayList<RobustMatch> pool=new ArrayList<RobustMatch>(),active=new ArrayList<RobustMatch>();

  final ArrayList<PVector> src=new ArrayList<PVector>(),dst=new ArrayList<PVector>();
  final ArrayList<Float> weights=new ArrayList<Float>();

  RobustIcpRefiner(AppConfig cfg){this.cfg=cfg;}
  RobustMatch slot(int i){while(pool.size()<=i)pool.add(new RobustMatch());return pool.get(i);
    }

  RobustIcpResult refine(PointCloud current,PointCloud referenceWorld,RigidTransform initial){
    return refine(current,referenceWorld,initial,cfg.hqIcpMaxDistanceM,cfg.hqIcpIterations,cfg.hqIcpGoodRmsM);
  }

  RobustIcpResult refine(PointCloud current,PointCloud referenceWorld,RigidTransform initial,float maxDistanceM,int iterations,float goodRmsM){
    RobustIcpResult out=new RobustIcpResult();out.pose.set(initial);
    if(current==null||referenceWorld==null||current.size()<cfg.hqIcpMinimumMatches||referenceWorld.size()<cfg.hqIcpMinimumMatches)return out;

    float searchMax=max(cfg.hqVoxelSizeM*3.0f,maxDistanceM);
    SpatialHash hash=new SpatialHash(searchMax,referenceWorld.size());
    for(PVector p:referenceWorld.points)hash.add(p);
    RigidTransform estimate=new RigidTransform();estimate.set(initial);int stride=max(1,(current.size()+cfg.hqIcpMaxSamples-1)/cfg.hqIcpMaxSamples);

    float finalRms=Float.POSITIVE_INFINITY;int finalMatches=0;float finalOverlap=0;
    int count=max(1,iterations);
    for(int iter=0;iter<count;iter++){
      active.clear();int slot=0,attempted=0;float[] m=estimate.m;
      float phase=count<=1?1.0f:iter/(float)(count-1);
      float fineDistance=max(cfg.hqVoxelSizeM*3.0f,searchMax*0.30f);
      float searchDistance=lerp(searchMax,fineDistance,phase);
      for(int i=0;i<current.size();i+=stride){
        float confidence=current.confidenceAt(i);if(confidence<cfg.pointCloudMinimumConfidence)continue;attempted++;
        PVector p=current.points.get(i);RobustMatch rm=slot(slot++);
        rm.sourceWorld.set(m[0]*p.x+m[1]*p.y+m[2]*p.z+m[3],m[4]*p.x+m[5]*p.y+m[6]*p.z+m[7],m[8]*p.x+m[9]*p.y+m[10]*p.z+m[11]);
        PVector near=hash.nearest(rm.sourceWorld,searchDistance);if(near==null)continue;
        float dx=rm.sourceWorld.x-near.x,dy=rm.sourceWorld.y-near.y,dz=rm.sourceWorld.z-near.z;
        rm.target=near;rm.d2=dx*dx+dy*dy+dz*dz;rm.confidence=confidence;active.add(rm);
      }
      float overlap=attempted<=0?0:active.size()/(float)attempted;finalOverlap=overlap;
      if(active.size()<cfg.hqIcpMinimumMatches||overlap<cfg.icpMinimumOverlap)break;
      active.sort(new Comparator<RobustMatch>(){public int compare(RobustMatch a,RobustMatch b){return Float.compare(a.d2,b.d2);}});
      int keep=constrain(round(active.size()*cfg.hqIcpTrimFraction),cfg.hqIcpMinimumMatches,active.size());
      src.clear();dst.clear();weights.clear();double sum2=0,weightSum=0;float robustRadius=max(cfg.hqVoxelSizeM*2.0f,searchDistance*cfg.icpRobustK);
      for(int i=0;i<keep;i++){RobustMatch rm=active.get(i);float d=sqrt(rm.d2),u=d/robustRadius,robust=u>=1.0f?0.05f:(1.0f-u*u)*(1.0f-u*u),weight=max(0.01f,rm.confidence)*max(0.05f,robust);src.add(rm.sourceWorld);dst.add(rm.target);weights.add(weight);sum2+=weight*rm.d2;weightSum+=weight;}
      if(weightSum<=0)break;finalRms=(float)Math.sqrt(sum2/weightSum);finalMatches=keep;
      RigidTransform correction=fitter.fitWeighted(src,dst,weights);estimate=correction.multiply(estimate);
      float move=sqrt(correction.m[3]*correction.m[3]+correction.m[7]*correction.m[7]+correction.m[11]*correction.m[11]);
      float angle=rotationAngle(correction);if(move<0.00005f&&angle<0.03f)break;
    }
    out.pose.set(estimate);out.rms=finalRms;out.matches=finalMatches;out.good=finalMatches>=cfg.hqIcpMinimumMatches&&finalRms<=goodRmsM&&finalOverlap>=cfg.icpMinimumOverlap;
    return out;
  }
  float rotationAngle(RigidTransform t){float c=constrain((t.m[0]+t.m[5]+t.m[10]-1.0f)*0.5f,-1,1);
    return degrees(acos(c));}
}

class DepthSuperResolutionStats {
  int sourceViews=0,sourceSamples=0,acceptedSplats=0,rejectedOcclusion=0,rejectedOutlier=0,outputPoints=0;

  void clear(){sourceViews=sourceSamples=acceptedSplats=rejectedOcclusion=rejectedOutlier=outputPoints=0;
    }
}

class MultiFrameDepthSuperResolver {
  final AppConfig cfg;final Calibration calibration;final PointCloudBuilder builder;
  final RgbDepthRegistration registration;
  float[] sumW,sumZ,sumZ2,frontZ;short[] distinctViews;int[] lastView,touched;int touchedCount=0,sw=0,sh=0;

  final DepthSuperResolutionStats stats=new DepthSuperResolutionStats();
  MultiFrameDepthSuperResolver(AppConfig cfg,Calibration calibration,PointCloudBuilder builder,RgbDepthRegistration registration){this.cfg=cfg;
    this.calibration=calibration;this.builder=builder;this.registration=registration;
    }

  void ensureGrid(int w,int h){
    int scale=max(1,cfg.hqDepthSrScale),nw=w*scale,nh=h*scale,n=nw*nh;if(nw==sw&&nh==sh&&sumW!=null)return;
    sw=nw;sh=nh;
    sumW=new float[n];sumZ=new float[n];sumZ2=new float[n];frontZ=new float[n];distinctViews=new short[n];
    lastView=new int[n];Arrays.fill(lastView,-1);touched=new int[max(65536,min(n,262144))];
    touchedCount=0;
  }
  void clearGrid(){for(int i=0;i<touchedCount;i++){int id=touched[i];sumW[id]=sumZ[id]=sumZ2[id]=frontZ[id]=0;
      distinctViews[id]=0;lastView[id]=-1;}touchedCount=0;stats.clear();}
  void touch(int id){if(sumW[id]!=0||distinctViews[id]!=0)return;if(touchedCount>=touched.length)touched=Arrays.copyOf(touched,max(touchedCount+1,touched.length*2));
    touched[touchedCount++]=id;}
  void resetCell(int id,float z,float w,int viewTag){touch(id);sumW[id]=w;sumZ[id]=z*w;
    sumZ2[id]=z*z*w;frontZ[id]=z;distinctViews[id]=1;lastView[id]=viewTag;stats.acceptedSplats++;
    }
  void addCell(int id,float z,float w,int viewTag){
    if(w<=0.0001f)return;if(sumW[id]<=0){resetCell(id,z,w,viewTag);return;}
    float front=frontZ[id];
    if(z<front-cfg.hqDepthSrOcclusionToleranceM){resetCell(id,z,w,viewTag);return;
      }
    if(z>front+cfg.hqDepthSrOcclusionToleranceM){stats.rejectedOcclusion++;return;
      }
    float mean=sumZ[id]/sumW[id];if(abs(z-mean)>cfg.hqDepthSrOutlierToleranceM){stats.rejectedOutlier++;
      return;}
    touch(id);sumW[id]+=w;sumZ[id]+=z*w;sumZ2[id]+=z*z*w;if(z<frontZ[id])frontZ[id]=z;

    if(lastView[id]!=viewTag){distinctViews[id]=(short)min(Short.MAX_VALUE,(distinctViews[id]&0xffff)+1);
      lastView[id]=viewTag;}stats.acceptedSplats++;
  }
  void splat(float sx,float sy,float z,float baseWeight,int viewTag){
    int x0=floor(sx),y0=floor(sy);float fx=sx-x0,fy=sy-y0;
    for(int dy=0;dy<=1;dy++){int y=y0+dy;if(y<0||y>=sh)continue;float wy=dy==0?1-fy:fy;
      if(wy<=0)continue;int row=y*sw;
      for(int dx=0;dx<=1;dx++){int x=x0+dx;if(x<0||x>=sw)continue;float wx=dx==0?1-fx:fx,w=baseWeight*wx*wy;
        if(w>0.0001f)addCell(row+x,z,w,viewTag);}
    }
  }
  boolean poseNear(RigidTransform a,RigidTransform b){return translationDelta(a,b)<=cfg.hqDepthSrMaxTranslationM&&rotationDeltaDeg(a,b)<=cfg.hqDepthSrMaxRotationDeg;
    }
  float translationDelta(RigidTransform a,RigidTransform b){float dx=a.m[3]-b.m[3],dy=a.m[7]-b.m[7],dz=a.m[11]-b.m[11];
    return sqrt(dx*dx+dy*dy+dz*dz);}
  float rotationDeltaDeg(RigidTransform a,RigidTransform b){float r00=a.m[0]*b.m[0]+a.m[4]*b.m[4]+a.m[8]*b.m[8],r11=a.m[1]*b.m[1]+a.m[5]*b.m[5]+a.m[9]*b.m[9],
    r22=a.m[2]*b.m[2]+a.m[6]*b.m[6]+a.m[10]*b.m[10];return degrees(acos(constrain((r00+r11+r22-1)*0.5f,-1,1)));
    }

  PointCloud fuse(ArrayList<HighQualityKeyframe> frames,ArrayList<RigidTransform> poses,int anchorIndex,RgbSnapshot rgb){
    if(frames==null||poses==null||anchorIndex<0||anchorIndex>=frames.size())return new PointCloud();
    HighQualityKeyframe anchor=frames.get(anchorIndex);DepthFrame anchorDepth=anchor.depth;
    if(anchorDepth==null||anchorDepth.depth==null)return new PointCloud();
    ensureGrid(anchorDepth.width,anchorDepth.height);clearGrid();int scale=max(1,cfg.hqDepthSrScale),half=max(0,cfg.hqDepthSrWindowFrames/2);
    RigidTransform anchorPose=poses.get(anchorIndex),anchorInv=anchorPose.inverseRigid();

    int from=max(0,anchorIndex-half),to=min(frames.size()-1,anchorIndex+half),viewTag=0;

    for(int j=from;j<=to;j++){
      if(!poseNear(anchorPose,poses.get(j)))continue;HighQualityKeyframe k=frames.get(j);
      DepthFrame f=k.depth;if(f==null||f.depth==null||f.width!=anchorDepth.width||f.height!=anchorDepth.height)continue;
      RigidTransform rel=anchorInv.multiply(poses.get(j));float[] m=rel.m;stats.sourceViews++;
      int tag=++viewTag;
      for(int v=0;v<f.height;v++){int row=v*f.width;for(int u=0;u<f.width;u++){int index=row+u,raw=f.depth[index]&0xffff;
          if(raw==0)continue;int mm=builder.filteredDepthMmHighQuality(f,u,v,raw,calibration);
          if(mm<=0)continue;float z=mm*calibration.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
          if(!Float.isNaN(k.targetDepthM)&&abs(z-k.targetDepthM)>k.bandM)continue;

        float conf=calibration.depthConfidence(index,z)*builder.edgeConfidence(f,u,v,mm,calibration);
          if(conf<max(cfg.pointCloudMinimumConfidence,0.22f))continue;stats.sourceSamples++;

        float x=registration!=null?registration.pointX(index,z):(u-calibration.cx)*z/calibration.fx,y=registration!=null?registration.pointY(index,z):(v-calibration.cy)*z/calibration.fy;

        float ax=m[0]*x+m[1]*y+m[2]*z+m[3],ay=m[4]*x+m[5]*y+m[6]*z+m[7],az=m[8]*x+m[9]*y+m[10]*z+m[11];
          if(az<=0.05f)continue;float pu=calibration.fx*ax/az+calibration.cx,pv=calibration.fy*ay/az+calibration.cy;
          if(pu<-0.5f||pv<-0.5f||pu>anchorDepth.width-0.5f||pv>anchorDepth.height-0.5f)continue;

        float rangeWeight=1.0f/(1.0f+0.30f*z*z),baseWeight=max(0.05f,conf*rangeWeight);
          float sx=(pu+0.5f)*scale-0.5f,sy=(pv+0.5f)*scale-0.5f;splat(sx,sy,az,baseWeight,tag);

      }}
    }
    PointCloud out=emit(anchorDepth,rgb,scale);stats.outputPoints=out.size();return out;

  }

  PointCloud emit(DepthFrame anchorDepth,RgbSnapshot rgb,int scale){
    int eligible=0,minViews=max(1,cfg.hqDepthSrMinimumViews);for(int i=0;i<touchedCount;i++){int id=touched[i];
      if((distinctViews[id]&0xffff)<minViews||sumW[id]<=0)continue;float mean=sumZ[id]/sumW[id],var=max(0,sumZ2[id]/sumW[id]-mean*mean);
      if(sqrt(var)<=cfg.hqDepthSrOutlierToleranceM)eligible++;}
    int stride=max(1,(eligible+cfg.hqDepthSrMaxPoints-1)/cfg.hqDepthSrMaxPoints),seen=0;
    PointCloud out=new PointCloud(min(eligible,cfg.hqDepthSrMaxPoints)+16);if(registration!=null&&rgb!=null)registration.prepareFrame(anchorDepth,rgb);

    for(int i=0;i<touchedCount;i++){int id=touched[i],views=distinctViews[id]&0xffff;
      if(views<minViews||sumW[id]<=0)continue;float z=sumZ[id]/sumW[id],var=max(0,sumZ2[id]/sumW[id]-z*z),sigma=sqrt(var);
      if(sigma>cfg.hqDepthSrOutlierToleranceM)continue;if((seen++%stride)!=0)continue;
      int sx=id%sw,sy=id/sw;float u=(sx+0.5f)/scale-0.5f,v=(sy+0.5f)/scale-0.5f,x=(u-calibration.cx)*z/calibration.fx,y=(v-calibration.cy)*z/calibration.fy;
      float support=constrain(views/(float)max(minViews,stats.sourceViews),0.25f,1.0f),consistency=1.0f-constrain(sigma/max(0.0005f,cfg.hqDepthSrOutlierToleranceM),
        0,0.85f),q=constrain((0.30f+0.70f*support)*consistency,0.08f,1.0f);int color=registration!=null&&rgb!=null?registration.colorAtPoint(x,y,z):0;
      out.add(new PVector(x,y,z),color,q);}
    return out;
  }
}


class GlobalPoseRecoveryResult {
  final ArrayList<RigidTransform> poses;
  final boolean[] accepted;
  final float[] support;
  final float[] rms;
  GlobalPoseRecoveryResult(int n){poses=new ArrayList<RigidTransform>(n);accepted=new boolean[n];support=new float[n];rms=new float[n];Arrays.fill(rms,Float.POSITIVE_INFINITY);}
  int acceptedCount(){int n=0;for(boolean v:accepted)if(v)n++;return n;}
}

class PoseSupport {
  float support=0,rms=Float.POSITIVE_INFINITY;int matches=0,samples=0;
}

class HighQualityReconstructor {
  final AppConfig cfg;final Calibration calibration;final PointCloudBuilder builder;
  final RgbDepthRegistration registration;final RobustIcpRefiner refiner;final MultiFrameDepthSuperResolver superResolver;

  int[] rgbPixels;ColorReference colorReference;DepthSuperResolutionStats lastSuperResolutionStats=null;

  HighQualityReconstructor(AppConfig cfg,Calibration calibration,PointCloudBuilder builder,RgbDepthRegistration registration){this.cfg=cfg;
    this.calibration=calibration;this.builder=builder;this.registration=registration;
    this.refiner=new RobustIcpRefiner(cfg);this.superResolver=new MultiFrameDepthSuperResolver(cfg,calibration,builder,registration);
    }

  Mesh3D reconstruct(ArrayList<HighQualityKeyframe> frames){return reconstruct(frames,true);}

  Mesh3D reconstruct(ArrayList<HighQualityKeyframe> frames,boolean highQuality){
    if(frames==null||frames.size()<cfg.hqMinimumKeyframes)return null;
    int finalizeLimit=highQuality?cfg.hqFinalizeMaxKeyframes:min(cfg.hqFinalizeMaxKeyframes,max(cfg.hqMinimumKeyframes,72));
    frames=selectFinalizeFrames(frames,finalizeLimit);
    scannerState().hqBusy=true;scannerState().hqProgress=0;
    try{
      GlobalPoseRecoveryResult recovery=refinePosesGlobal(frames);if(Thread.currentThread().isInterrupted())return null;
      if(recovery==null||recovery.acceptedCount()<max(3,min(cfg.hqMinimumKeyframes,frames.size())/2))return null;
      ArrayList<RigidTransform> poses=recovery.poses;

      colorReference=cfg.rgbPhotometricNormalize?ColorReference.fromFrames(frames):null;
      int volumeSize=highQuality?cfg.hqVolumeSize:max(cfg.volumeSize,192);
      float voxelSize=highQuality?cfg.hqVoxelSizeM:cfg.voxelSizeM;
      float truncation=highQuality?cfg.hqTruncationM:max(cfg.truncationM,voxelSize*3.0f);
      int meshWeight=highQuality?cfg.hqMeshMinWeight:cfg.meshMinWeight;
      TSDFVolume volume=new TSDFVolume(volumeSize,voxelSize,truncation,cfg.rgbTemporalColorWeightMax);

      boolean initialized=false;ArrayList<Integer> anchors=highQuality?integrationAnchors(frames.size()):allIntegrationAnchors(frames.size());
      int integrated=0;
      for(int ai=0;ai<anchors.size();ai++){
        int i=anchors.get(ai);if(i<0||i>=recovery.accepted.length||!recovery.accepted[i])continue;
        HighQualityKeyframe k=frames.get(i);RgbSnapshot rgb=rgbSnapshot(k);PointCloud cloud;
        if(highQuality&&cfg.hqDepthSuperResolution&&cfg.hqDepthSrScale>1){cloud=superResolver.fuse(frames,poses,i,rgb);
          lastSuperResolutionStats=superResolver.stats;if(cloud.size()<cfg.minimumTrackingPoints)cloud=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,rgb);}
        else cloud=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,rgb);
        if(scannerState().boundingBox!=null)cloud=scannerState().boundingBox.filter(cloud,false);
        if(cloud.size()<cfg.minimumTrackingPoints)continue;
        if(!initialized){volume.resetAround(cloud.centroidTransformed(poses.get(i)));initialized=true;}
        float poseWeight=i==0?1.0f:integrationReliability(recovery,i,k);
        if(poseWeight<0.08f)continue;
        volume.integrate(cloud,poses.get(i),1,highQuality?cfg.hqDistanceWeightedTsdf:true,poseWeight);integrated++;
        scannerState().hqProgress=0.55f+0.35f*((ai+1)/(float)max(1,anchors.size()));
        scannerState().status=scannerState().i18n.format("status.hq_integrating",round(scannerState().hqProgress*100));
        if(Thread.currentThread().isInterrupted())return null;
      }
      if(!initialized||integrated<3)return null;
      scannerState().hqProgress=0.93f;scannerState().status=scannerState().i18n.tr("status.hq_meshing");
      Mesh3D raw=volume.extractMesh(meshWeight);if(raw==null||raw.triangleCount()==0)return null;
      Mesh3D result=highQuality?scannerState().meshEditor.polishHighQuality(raw):scannerState().meshEditor.prepareGeneratedMesh(raw);
      scannerState().hqProgress=1.0f;return result;
    }finally{scannerState().hqBusy=false;}
  }


  ArrayList<HighQualityKeyframe> selectFinalizeFrames(ArrayList<HighQualityKeyframe> input,int limit){
    if(input==null||input.size()<=limit)return input;
    int n=input.size(),keep=max(cfg.hqMinimumKeyframes,limit);
    ArrayList<HighQualityKeyframe> out=new ArrayList<HighQualityKeyframe>(keep);
    HashSet<Integer> used=new HashSet<Integer>();
    // Preserve angular coverage, but choose the healthiest frame around each
    // target angle. Uniform decimation alone can accidentally keep a corrupted
    // depth frame and discard a clean neighboring observation of the same side.
    for(int slot=0;slot<keep;slot++){
      float target=slot*(n-1)/(float)max(1,keep-1);
      int center=round(target),radius=max(2,(int)ceil(n/(float)keep));
      int best=-1;float bestScore=-Float.MAX_VALUE;
      for(int d=-radius;d<=radius;d++){int idx=center+d;if(idx<0||idx>=n||used.contains(idx))continue;
        HighQualityKeyframe k=input.get(idx);float score=keyframeHealthScore(k)-0.035f*abs(idx-target);
        if(score>bestScore){bestScore=score;best=idx;}}
      if(best<0){for(int idx=0;idx<n;idx++)if(!used.contains(idx)){best=idx;break;}}
      if(best>=0){used.add(best);out.add(input.get(best));}
    }
    Collections.sort(out,new Comparator<HighQualityKeyframe>(){public int compare(HighQualityKeyframe a,HighQualityKeyframe b){
      return Long.compare(a.depth.frameNumber,b.depth.frameNumber);}});
    return out;
  }

  float keyframeHealthScore(HighQualityKeyframe k){
    if(k==null||k.depth==null)return -10.0f;
    int pixels=max(1,k.depth.width*k.depth.height);
    float valid=constrain(k.depth.validCount/(float)pixels,0,1);
    float plausible=constrain(k.depth.plausibleCount/(float)pixels,0,1);
    float score=0.40f*valid+0.50f*plausible+0.10f*constrain(k.colorQuality,0,1);
    if(k.depth.transportRecovered)score*=cfg.hqTurntableRecoveredFramePenalty;
    if(!k.depth.deviceCalibrated)score*=0.92f;
    return score;
  }

  ArrayList<Integer> integrationAnchors(int count){
    ArrayList<Integer> out=new ArrayList<Integer>();if(count<=0)return out;int stride=cfg.hqDepthSuperResolution?max(1,cfg.hqDepthSrAnchorStride):1;
    for(int i=0;i<count;i+=stride)out.add(i);if(out.get(out.size()-1)!=count-1)out.add(count-1);
    return out;
  }

  ArrayList<Integer> allIntegrationAnchors(int count){
    ArrayList<Integer> out=new ArrayList<Integer>();if(count<=0)return out;int stride=max(1,cfg.hqIntegrationStep);
    for(int i=0;i<count;i+=stride)out.add(i);if(out.get(out.size()-1)!=count-1)out.add(count-1);return out;
  }

  float integrationReliability(GlobalPoseRecoveryResult recovery,int i,HighQualityKeyframe k){
    float support=constrain((recovery.support[i]-cfg.hqGlobalRecoveryMinSupport)/max(0.05f,1.0f-cfg.hqGlobalRecoveryMinSupport),0,1);
    float rms=recovery.rms[i];
    float rmsQuality=Float.isFinite(rms)?constrain(1.0f-rms/max(cfg.hqGlobalRecoveryMaxRmsM,0.001f),0,1):0.25f;
    float health=constrain(keyframeHealthScore(k),0,1);
    float w=0.12f+0.88f*(0.48f*support+0.32f*rmsQuality+0.20f*health);
    if(k.depth.transportRecovered)w*=cfg.hqTurntableRecoveredFramePenalty;
    return constrain(w,0.03f,1.0f);
  }

  GlobalPoseRecoveryResult refinePosesGlobal(ArrayList<HighQualityKeyframe> frames){
    int n=frames.size();GlobalPoseRecoveryResult result=new GlobalPoseRecoveryResult(n);
    ArrayList<PointCloud> clouds=new ArrayList<PointCloud>(n);
    for(int i=0;i<n;i++){
      HighQualityKeyframe k=frames.get(i);PointCloud c=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,rgbSnapshot(k));
      if(scannerState().boundingBox!=null)c=scannerState().boundingBox.filter(c,false);clouds.add(c);
    }

    RigidTransform anchor=new RigidTransform();anchor.set(frames.get(0).initialPose);
    PVector pivot=estimateRecoveryPivot(clouds);
    float sign=inferSweepPoseSign(frames,anchor);
    float baseSweep=frames.get(0).sweepDeg;
    ArrayList<RigidTransform> canonical=new ArrayList<RigidTransform>(n);
    for(int i=0;i<n;i++){
      float yaw=sign*(frames.get(i).sweepDeg-baseSweep);
      RigidTransform seed=anchor.multiply(rotationAroundPivotY(pivot,yaw));canonical.add(seed);
      RigidTransform pose=new RigidTransform();pose.set(cfg.hqGlobalRecovery?seed:frames.get(i).initialPose);result.poses.add(pose);
      result.accepted[i]=clouds.get(i)!=null&&clouds.get(i).size()>=cfg.hqIcpMinimumMatches;
    }
    if(n>0)result.accepted[0]=true;

    if(cfg.hqGlobalRecovery){
      int passes=max(1,cfg.hqGlobalRecoveryPasses);
      for(int pass=0;pass<passes;pass++){
        boolean backward=(pass&1)==1;float maxDistance=pass==0?cfg.hqGlobalRecoveryCoarseDistanceM:cfg.hqGlobalRecoveryFineDistanceM;
        int begin=backward?n-2:1,end=backward?-1:n,step=backward?-1:1;
        for(int i=begin;i!=end;i+=step){
          if(clouds.get(i)==null||clouds.get(i).size()<cfg.hqIcpMinimumMatches){result.accepted[i]=false;continue;}
          PointCloud reference=recoveryReference(i,clouds,result.poses,result.accepted,cfg.hqGlobalRecoveryNeighborFrames);
          if(reference.size()<cfg.hqIcpMinimumMatches)continue;
          RigidTransform current=result.poses.get(i),seed=canonical.get(i),raw=frames.get(i).initialPose;
          RobustIcpResult best=bestRecoveryCandidate(clouds.get(i),reference,current,seed,raw,maxDistance,pass==0);
          if(best!=null&&recoveryPoseWithinGuard(seed,best.pose)){
            result.poses.get(i).set(best.pose);result.rms[i]=best.rms;result.accepted[i]=true;
          }
          scannerState().hqProgress=0.32f*((pass*n+max(0,backward?(n-1-i):i))/(float)max(1,passes*n));
          scannerState().status=scannerState().i18n.format("status.hq_refining",round(scannerState().hqProgress*100));
          if(Thread.currentThread().isInterrupted())return result;
        }
      }

      // Consensus validation is intentionally separate from optimization. A bad
      // realtime pose may be corrected by the global pass, but a keyframe that
      // still disagrees with its neighbors must never be fused into the final TSDF.
      boolean[] provisional=Arrays.copyOf(result.accepted,result.accepted.length);
      for(int i=0;i<n;i++){
        if(i==0){result.accepted[i]=provisional[i];continue;}
        PointCloud reference=recoveryReference(i,clouds,result.poses,provisional,cfg.hqGlobalRecoveryNeighborFrames);
        PoseSupport q=evaluatePoseSupport(clouds.get(i),reference,result.poses.get(i),cfg.hqGlobalRecoveryFineDistanceM);
        result.support[i]=q.support;result.rms[i]=q.rms;
        result.accepted[i]=q.samples>=cfg.hqIcpMinimumMatches&&q.support>=cfg.hqGlobalRecoveryMinSupport&&q.rms<=cfg.hqGlobalRecoveryMaxRmsM;
      }
      // A rejected scan is rescued only when it is independently supported by
      // the neighboring surface. This prevents a single damaged depth frame from
      // producing a duplicate shell merely because its temporal neighbors were good.
      for(int i=1;i<n-1;i++)if(!result.accepted[i]&&result.accepted[i-1]&&result.accepted[i+1]){
        PoseSupport q=new PoseSupport();q.support=result.support[i];q.rms=result.rms[i];
        boolean canonicalClose=rigidTranslationDelta(canonical.get(i),result.poses.get(i))<=cfg.hqGlobalRecoveryMaxTranslationM*0.45f&&
          rigidRotationDeltaDeg(canonical.get(i),result.poses.get(i))<=cfg.hqGlobalRecoveryMaxRotationDeg*0.45f;
        if(canonicalClose&&q.support>=cfg.hqTurntableRescueMinSupport&&q.rms<=cfg.hqTurntableRescueMaxRmsM)result.accepted[i]=true;
      }
      if(cfg.hqTurntableConsensus)regularizeTurntablePoses(frames,canonical,result);
    }else{
      for(int i=0;i<n;i++){result.poses.get(i).set(frames.get(i).initialPose);result.accepted[i]=true;}
    }

    if(cfg.hqLoopClosure&&n>=cfg.hqMinimumKeyframes){
      int first=firstAccepted(result.accepted),last=lastAccepted(result.accepted);
      if(first>=0&&last>first&&abs(frames.get(last).sweepDeg-frames.get(first).sweepDeg)>=cfg.scanCompleteDeg){
        PointCloud firstWorld=clouds.get(first).transformed(result.poses.get(first),cfg.hqIcpMaxSamples);
        RobustIcpResult closure=refiner.refine(clouds.get(last),firstWorld,result.poses.get(last),cfg.hqGlobalRecoveryCoarseDistanceM,
          max(cfg.hqIcpIterations,16),cfg.hqLoopClosureMaxRmsM);
        if(closure.good&&closure.rms<=cfg.hqLoopClosureMaxRmsM){RigidTransform correction=closure.pose.multiply(result.poses.get(last).inverseRigid());
          applyDistributedCorrectionAccepted(result.poses,result.accepted,correction,first,last);}
      }
    }
    scannerState().hqProgress=0.45f;return result;
  }

  void regularizeTurntablePoses(ArrayList<HighQualityKeyframe> frames,ArrayList<RigidTransform> canonical,GlobalPoseRecoveryResult result){
    for(int i=0;i<result.poses.size();i++){if(!result.accepted[i])continue;
      RigidTransform base=canonical.get(i),refined=result.poses.get(i);
      RigidTransform residual=refined.multiply(base.inverseRigid());
      float support=constrain(result.support[i],0,1);
      float rms=result.rms[i];float rmsQ=Float.isFinite(rms)?constrain(1.0f-rms/max(cfg.hqGlobalRecoveryMaxRmsM,0.001f),0,1):0;
      float evidence=0.65f*support+0.35f*rmsQ;
      // Excellent geometric evidence may keep most of its ICP correction. Weak
      // evidence collapses toward the exact fixed-axis sweep prior.
      float keep=constrain((1.0f-cfg.hqTurntableAxisAuthority)+cfg.hqTurntableAxisAuthority*evidence,0.08f,1.0f);
      if(frames.get(i).depth.transportRecovered)keep*=cfg.hqTurntableRecoveredFramePenalty;
      RigidTransform limited=fractional(residual,keep);result.poses.set(i,limited.multiply(base));
    }
  }

  RobustIcpResult bestRecoveryCandidate(PointCloud current,PointCloud reference,RigidTransform currentPose,RigidTransform canonicalPose,RigidTransform rawPose,float maxDistance,boolean multiSeed){
    RobustIcpResult best=null;RigidTransform[] seeds=multiSeed?new RigidTransform[]{currentPose,canonicalPose,rawPose}:new RigidTransform[]{currentPose};
    int iterations=multiSeed?max(8,cfg.hqIcpIterations-2):cfg.hqIcpIterations;
    for(RigidTransform seed:seeds){if(seed==null)continue;RobustIcpResult r=refiner.refine(current,reference,seed,maxDistance,iterations,cfg.hqGlobalRecoveryMaxRmsM*1.35f);
      if(r.matches<cfg.hqIcpMinimumMatches)continue;if(best==null||recoveryResultScore(r)<recoveryResultScore(best))best=r;}
    return best;
  }

  float recoveryResultScore(RobustIcpResult r){if(r==null||r.matches<=0||Float.isInfinite(r.rms)||Float.isNaN(r.rms))return Float.POSITIVE_INFINITY;
    return r.rms*(1.0f+cfg.hqIcpMinimumMatches/(float)max(cfg.hqIcpMinimumMatches,r.matches));}

  boolean recoveryPoseWithinGuard(RigidTransform canonical,RigidTransform pose){return rigidTranslationDelta(canonical,pose)<=cfg.hqGlobalRecoveryMaxTranslationM&&
    rigidRotationDeltaDeg(canonical,pose)<=cfg.hqGlobalRecoveryMaxRotationDeg;}

  PointCloud recoveryReference(int index,ArrayList<PointCloud> clouds,ArrayList<RigidTransform> poses,boolean[] accepted,int radius){
    int from=max(0,index-radius),to=min(clouds.size()-1,index+radius),count=0;
    for(int j=from;j<=to;j++)if(j!=index&&accepted[j]&&clouds.get(j)!=null)count++;
    int per=max(700,cfg.hqIcpMaxSamples/max(1,count));PointCloud out=new PointCloud(max(32,count*per));
    for(int j=from;j<=to;j++){if(j==index||!accepted[j])continue;PointCloud c=clouds.get(j);if(c==null||c.size()==0)continue;
      PointCloud world=c.transformed(poses.get(j),per);for(int k=0;k<world.size();k++)out.add(world.points.get(k),world.colorAt(k),world.confidenceAt(k));}
    return out;
  }

  PoseSupport evaluatePoseSupport(PointCloud current,PointCloud reference,RigidTransform pose,float maxDistance){
    PoseSupport out=new PoseSupport();if(current==null||reference==null||reference.size()<cfg.hqIcpMinimumMatches)return out;
    SpatialHash hash=new SpatialHash(maxDistance,reference.size());for(PVector p:reference.points)hash.add(p);
    int maxSamples=min(cfg.hqIcpMaxSamples,5000),stride=max(1,(current.size()+maxSamples-1)/maxSamples);double sum2=0;
    for(int i=0;i<current.size();i+=stride){if(current.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;out.samples++;PVector w=pose.apply(current.points.get(i));
      PVector q=hash.nearest(w,maxDistance);if(q==null)continue;float dx=w.x-q.x,dy=w.y-q.y,dz=w.z-q.z;sum2+=dx*dx+dy*dy+dz*dz;out.matches++;}
    out.support=out.samples<=0?0:out.matches/(float)out.samples;out.rms=out.matches<=0?Float.POSITIVE_INFINITY:(float)Math.sqrt(sum2/out.matches);return out;
  }

  PVector estimateRecoveryPivot(ArrayList<PointCloud> clouds){
    ArrayList<Float> xs=new ArrayList<Float>(),ys=new ArrayList<Float>(),zs=new ArrayList<Float>();
    for(PointCloud c:clouds){if(c==null||c.size()<cfg.hqIcpMinimumMatches)continue;PVector p=c.centroidTransformed(new RigidTransform());xs.add(p.x);ys.add(p.y);zs.add(p.z);}
    if(xs.isEmpty())return new PVector();Collections.sort(xs);Collections.sort(ys);Collections.sort(zs);int m=xs.size()/2;
    return new PVector(xs.get(m),ys.get(m),zs.get(m));
  }

  float inferSweepPoseSign(ArrayList<HighQualityKeyframe> frames,RigidTransform anchor){
    double score=0;RigidTransform inv=anchor.inverseRigid();float base=frames.get(0).sweepDeg;
    for(int i=1;i<frames.size();i++){float sweep=frames.get(i).sweepDeg-base;if(abs(sweep)<4.0f)continue;RigidTransform rel=inv.multiply(frames.get(i).initialPose);
      float yaw=degrees(atan2(rel.m[2],rel.m[0]));while(yaw>180)yaw-=360;while(yaw<-180)yaw+=360;float sw=sweep;while(sw>180)sw-=360;while(sw<-180)sw+=360;score+=yaw*sw;}
    return score<0?-1.0f:1.0f;
  }

  RigidTransform rotationAroundPivotY(PVector pivot,float deg){
    float a=radians(deg),c=cos(a),s=sin(a);RigidTransform r=new RigidTransform();r.m[0]=c;r.m[2]=s;r.m[8]=-s;r.m[10]=c;
    r.m[3]=pivot.x-(c*pivot.x+s*pivot.z);r.m[7]=0;r.m[11]=pivot.z-(-s*pivot.x+c*pivot.z);return r;
  }

  int firstAccepted(boolean[] accepted){for(int i=0;i<accepted.length;i++)if(accepted[i])return i;return -1;}
  int lastAccepted(boolean[] accepted){for(int i=accepted.length-1;i>=0;i--)if(accepted[i])return i;return -1;}

  void applyDistributedCorrectionAccepted(ArrayList<RigidTransform> poses,boolean[] accepted,RigidTransform correction,int first,int last){
    if(last<=first)return;for(int i=first+1;i<=last;i++){if(!accepted[i])continue;float a=(i-first)/(float)(last-first);RigidTransform f=fractional(correction,a);poses.set(i,f.multiply(poses.get(i)));}
  }


  RigidTransform fractional(RigidTransform t,float alpha){
    alpha=constrain(alpha,0,1);float trace=t.m[0]+t.m[5]+t.m[10],qw,qx,qy,qz;
    if(trace>0){float s=sqrt(trace+1.0f)*2.0f;qw=0.25f*s;qx=(t.m[9]-t.m[6])/s;qy=(t.m[2]-t.m[8])/s;
      qz=(t.m[4]-t.m[1])/s;}
    else if(t.m[0]>t.m[5]&&t.m[0]>t.m[10]){float s=sqrt(1.0f+t.m[0]-t.m[5]-t.m[10])*2.0f;
      qw=(t.m[9]-t.m[6])/s;qx=0.25f*s;qy=(t.m[1]+t.m[4])/s;qz=(t.m[2]+t.m[8])/s;}
    else if(t.m[5]>t.m[10]){float s=sqrt(1.0f+t.m[5]-t.m[0]-t.m[10])*2.0f;qw=(t.m[2]-t.m[8])/s;
      qx=(t.m[1]+t.m[4])/s;qy=0.25f*s;qz=(t.m[6]+t.m[9])/s;}
    else{float s=sqrt(1.0f+t.m[10]-t.m[0]-t.m[5])*2.0f;qw=(t.m[4]-t.m[1])/s;qx=(t.m[2]+t.m[8])/s;
      qy=(t.m[6]+t.m[9])/s;qz=0.25f*s;}
    if(qw<0){qw=-qw;qx=-qx;qy=-qy;qz=-qz;}float angle=2.0f*acos(constrain(qw,-1,1)),sinHalf=sqrt(max(0,1-qw*qw));
    float ax=1,ay=0,az=0;if(sinHalf>1e-6f){ax=qx/sinHalf;ay=qy/sinHalf;az=qz/sinHalf;
      }
    float h=angle*alpha*0.5f,w=cos(h),ss=sin(h),x=ax*ss,y=ay*ss,z=az*ss;RigidTransform r=new RigidTransform();

    r.m[0]=1-2*y*y-2*z*z;r.m[1]=2*x*y-2*z*w;r.m[2]=2*x*z+2*y*w;
    r.m[4]=2*x*y+2*z*w;r.m[5]=1-2*x*x-2*z*z;r.m[6]=2*y*z-2*x*w;
    r.m[8]=2*x*z-2*y*w;r.m[9]=2*y*z+2*x*w;r.m[10]=1-2*x*x-2*y*y;
    r.m[3]=t.m[3]*alpha;r.m[7]=t.m[7]*alpha;r.m[11]=t.m[11]*alpha;return r;
  }

  RgbSnapshot rgbSnapshot(HighQualityKeyframe k){
    if(k.colorData==null||k.colorWidth<=0||k.colorHeight<=0)return null;int count=k.colorWidth*k.colorHeight;
    if(rgbPixels==null||rgbPixels.length!=count)rgbPixels=new int[count];
    boolean ok=k.colorPixelFormat==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8?RgbHqProcessor.decodeBayerGrbg(k.colorData,k.colorWidth,k.colorHeight,
      rgbPixels):decodeNv12(k.colorData,k.colorWidth,k.colorHeight,rgbPixels);
    if(!ok)return null;if(cfg.rgbPhotometricNormalize)RgbHqProcessor.normalize(rgbPixels,colorReference,cfg);
    if(cfg.rgbHqSharpenAmount>0)RgbHqProcessor.sharpen(rgbPixels,k.colorWidth,k.colorHeight,cfg.rgbHqSharpenAmount);

    float tolerance=k.colorPixelFormat==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8?cfg.rgbHqMaxSyncSkewMs:cfg.rgbMaxSyncSkewMs;

    return new RgbSnapshot(rgbPixels,k.colorWidth,k.colorHeight,null,k.rgbFrameNumber,k.rgbTimestampUs,System.currentTimeMillis(),k.residualUs/1000.0f,
      k.rawSkewUs/1000.0f,tolerance,k.colorQuality);
  }
  boolean decodeNv12(byte[] data,int w,int h,int[] out){
    if(data==null||data.length!=w*h*3/2||out==null||out.length<w*h)return false;int ySize=w*h;

    for(int y=0;y<h;y++){int row=y*w,uvRow=ySize+(y/2)*w;for(int x=0;x<w;x++){int yi=data[row+x]&255,uv=uvRow+(x&~1),u=(data[uv]&255)-128,v=(data[uv+1]&255)-128,
        c=max(0,yi-16),rr=(298*c+409*v+128)>>8,gg=(298*c-100*u-208*v+128)>>8,bb=(298*c+516*u+128)>>8;
        out[row+x]=0xff000000|(constrain(rr,0,255)<<16)|(constrain(gg,0,255)<<8)|constrain(bb,0,255);
        }}return true;
  }
}

// ===== SynKinect Studio / 3D Scanner / TSDFVolume.pde =====
class TSDFVolume {
  int n;float voxelSize,truncation;int temporalColorWeightMax;short[] tsdf;byte[] weight;
  int[] rgb;byte[] rgbWeight;int[] touched=new int[65536];int touchedCount=0;
  int[] meshCellBits=new int[0],meshCells=new int[65536];int meshCellCount=0;
  PVector origin=new PVector(),center=new PVector();int minX,minY,minZ,maxX,maxY,maxZ;

  TSDFVolume(int n,float voxelSize,float truncation,int temporalColorWeightMax){this.n=n;
    this.voxelSize=voxelSize;this.truncation=truncation;this.temporalColorWeightMax=max(1,temporalColorWeightMax);
    int count=n*n*n;tsdf=new short[count];weight=new byte[count];rgb=new int[count];
    rgbWeight=new byte[count];resetBounds();}
  void resetBounds(){minX=minY=minZ=n;maxX=maxY=maxZ=-1;}
  void clear(){for(int i=0;i<touchedCount;i++){int id=touched[i];weight[id]=0;rgbWeight[id]=0;
      tsdf[id]=0;rgb[id]=0;}touchedCount=0;resetBounds();}
  void markTouched(int id){if((weight[id]&255)!=0||(rgbWeight[id]&255)!=0)return;
    if(touchedCount>=touched.length)touched=Arrays.copyOf(touched,max(touchedCount+1,touched.length*2));
    touched[touchedCount++]=id;}
  void resetAround(PVector c){clear();center.set(c);float half=n*voxelSize*0.5f;origin.set(c.x-half,c.y-half,c.z-half);
    }
  void resetAroundCloud(PointCloud cloud,RigidTransform pose,AppConfig cfg){
    if(cloud==null||cloud.size()==0||pose==null||cfg==null){resetAround(new PVector(0,0,0.75f));return;}
    float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;
    float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;
    int stride=max(1,cloud.size()/12000);
    for(int i=0;i<cloud.size();i+=stride){
      PVector p=pose.apply(cloud.points.get(i));
      minX=min(minX,p.x);minY=min(minY,p.y);minZ=min(minZ,p.z);
      maxX=max(maxX,p.x);maxY=max(maxY,p.y);maxZ=max(maxZ,p.z);
    }
    if(minX==Float.POSITIVE_INFINITY){resetAround(cloud.centroidTransformed(pose));return;}
    PVector c=new PVector((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
    if(cfg.volumeAutoFit){
      float extent=max(maxX-minX,max(maxY-minY,maxZ-minZ))*cfg.volumeAutoFitPadding;
      float fitted=extent/max(1,n-4);
      voxelSize=constrain(max(cfg.voxelSizeM,fitted),cfg.voxelSizeM,cfg.volumeMaxVoxelSizeM);
      truncation=max(cfg.truncationM,voxelSize*3.0f);
    }else{voxelSize=cfg.voxelSizeM;truncation=cfg.truncationM;}
    resetAround(c);
  }
  int idx(int x,int y,int z){return x+y*n+z*n*n;}boolean inside(int x,int y,int z){return x>=0&&y>=0&&z>=0&&x<n&&y<n&&z<n;
    }
  float[] surfaceConsistency(PointCloud cloud,RigidTransform pose,AppConfig cfg){
    if(cloud==null||pose==null||cfg==null||touchedCount==0)return new float[]{0,1,0};
    int stride=max(1,cloud.size()/2400),attempted=0,known=0,agree=0;double residualSum=0;
    float band=max(voxelSize,cfg.fusionSurfaceAgreementBandM);
    for(int i=0;i<cloud.size();i+=stride){
      if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;
      PVector p=pose.apply(cloud.points.get(i));
      int x=round((p.x-origin.x)/voxelSize),y=round((p.y-origin.y)/voxelSize),z=round((p.z-origin.z)/voxelSize);
      if(!inside(x,y,z))continue;int id=idx(x,y,z);if((weight[id]&255)<cfg.fusionSurfaceMinWeight)continue;
      known++;float residual=abs(tsdf[id]/32767.0f)*truncation;residualSum+=residual;if(residual<=band)agree++;
    }
    float knownRatio=attempted<=0?0:known/(float)attempted;
    float agreement=known<=0?1:agree/(float)known;
    float meanResidual=known<=0?0:(float)(residualSum/known);
    return new float[]{knownRatio,agreement,meanResidual};
  }
  void integrate(PointCloud cloud,RigidTransform pose,int pointStep){integrate(cloud,pose,pointStep,false,1.0f);
    }
  void integrate(PointCloud cloud,RigidTransform pose,int pointStep,boolean distanceWeighted){integrate(cloud,pose,pointStep,distanceWeighted,1.0f);}
  void integrate(PointCloud cloud,RigidTransform pose,int pointStep,boolean distanceWeighted,float frameConfidence){
    float[] m=pose.m;float camX=m[3],camY=m[7],camZ=m[11];int stride=max(1,pointStep);float fq=constrain(frameConfidence,0.05f,1.0f);

    for(int i=0;i<cloud.size();i+=stride){
      PVector source=cloud.points.get(i);float surfX=m[0]*source.x+m[1]*source.y+m[2]*source.z+m[3],surfY=m[4]*source.x+m[5]*source.y+m[6]*source.z+m[7],
      surfZ=m[8]*source.x+m[9]*source.y+m[10]*source.z+m[11];int surfaceColor=cloud.colorAt(i);

      float dx=surfX-camX,dy=surfY-camY,dz=surfZ-camZ,dist=sqrt(dx*dx+dy*dy+dz*dz);
      if(dist<0.05f)continue;float inv=1.0f/dist,rayX=dx*inv,rayY=dy*inv,rayZ=dz*inv,from=max(0.05f,dist-truncation),to=dist+truncation;

      int sampleWeight=distanceWeighted?depthSampleWeight(dist,cloud.confidenceAt(i)*fq):max(1,round(fq));

      for(float t=from;t<=to;t+=voxelSize){float px=camX+rayX*t,py=camY+rayY*t,pz=camZ+rayZ*t;
        int x=floor((px-origin.x)/voxelSize),y=floor((py-origin.y)/voxelSize),z=floor((pz-origin.z)/voxelSize);
        if(!inside(x,y,z))continue;float v=constrain((dist-t)/truncation,-1,1);int id=idx(x,y,z),w=weight[id]&255;
        markTouched(id);int accepted=min(sampleWeight,255-w);if(accepted<=0)continue;
        int nw=w+accepted;float old=w==0?0:tsdf[id]/32767.0f,blended=(old*w+v*accepted)/nw;
        tsdf[id]=(short)constrain(round(blended*32767.0f),-32767,32767);weight[id]=(byte)nw;
        minX=min(minX,x);minY=min(minY,y);minZ=min(minZ,z);maxX=max(maxX,x);maxY=max(maxY,y);
        maxZ=max(maxZ,z);}
      if(((surfaceColor>>>24)&255)!=0)integrateSurfaceColor(surfX,surfY,surfZ,surfaceColor);

    }
  }
  int depthSampleWeight(float depthM){return depthSampleWeight(depthM,1.0f);}
  int depthSampleWeight(float depthM,float confidence){
    // Range-dependent structured-light noise is combined with the empirical
    // per-pixel confidence learned during flat-wall calibration.
    float z=max(0.35f,depthM),z2=z*z,z4=z2*z2,base=4.0f/max(0.35f,z4);return constrain(round(base*constrain(confidence,0.20f,1.0f)),1,8);

  }
  void integrateSurfaceColor(float px,float py,float pz,int colorValue){int x=round((px-origin.x)/voxelSize),y=round((py-origin.y)/voxelSize),z=round((pz-origin.z)/voxelSize);
    if(!inside(x,y,z))return;int id=idx(x,y,z),w=rgbWeight[id]&255,confidence=(colorValue>>>24)&255,sampleWeight=constrain(round((confidence/255.0f)*temporalColorWeightMax),
      1,temporalColorWeightMax),accepted=min(sampleWeight,255-w);if(accepted<=0)return;
    markTouched(id);int nw=w+accepted,old=rgb[id],or=(old>>16)&255,og=(old>>8)&255,ob=old&255,nr=(colorValue>>16)&255,ng=(colorValue>>8)&255,nb=colorValue&255;
    int r=(or*w+nr*accepted)/nw,g=(og*w+ng*accepted)/nw,b=(ob*w+nb*accepted)/nw;rgb[id]=0xff000000|(r<<16)|(g<<8)|b;
    rgbWeight[id]=(byte)nw;}
  float value(int x,int y,int z){int id=idx(x,y,z);return(weight[id]&255)==0?1.0f:tsdf[id]/32767.0f;
    }int w(int x,int y,int z){return weight[idx(x,y,z)]&255;}PVector pos(int x,int y,int z){return new PVector(origin.x+x*voxelSize,origin.y+y*voxelSize,
      origin.z+z*voxelSize);}
  int sampleColor(PVector p){
    int cx=round((p.x-origin.x)/voxelSize),cy=round((p.y-origin.y)/voxelSize),cz=round((p.z-origin.z)/voxelSize);
    if(!inside(cx,cy,cz))return 0;int id=idx(cx,cy,cz),bestWeight=rgbWeight[id]&255;if(bestWeight>0)return rgb[id];
    int best=0;final int[] ox={-1,1,0,0,0,0},oy={0,0,-1,1,0,0},oz={0,0,0,0,-1,1};
    for(int i=0;i<6;i++){int x=cx+ox[i],y=cy+oy[i],z=cz+oz[i];if(!inside(x,y,z))continue;id=idx(x,y,z);int cw=rgbWeight[id]&255;
      if(cw>bestWeight){bestWeight=cw;best=rgb[id];}}
    return best;
  }
  void addMeshCell(int x,int y,int z,int side){
    if(x<0||y<0||z<0||x>=side||y>=side||z>=side)return;int cell=x+y*side+z*side*side,word=cell>>>5,mask=1<<(cell&31);
    if((meshCellBits[word]&mask)!=0)return;meshCellBits[word]|=mask;
    if(meshCellCount>=meshCells.length)meshCells=Arrays.copyOf(meshCells,max(meshCellCount+1,meshCells.length*2));meshCells[meshCellCount++]=cell;
  }
  Mesh3D extractMesh(int minWeight){return extractMesh(minWeight,Integer.MAX_VALUE);}
  Mesh3D extractMesh(int minWeight,int maxTriangles){
    Mesh3D out=new Mesh3D();maxTriangles=max(1,maxTriangles);if(maxX<0||touchedCount==0)return out;int side=n-1,totalCells=side*side*side,words=(totalCells+31)>>>5;
    if(meshCellBits.length<words)meshCellBits=new int[words];else Arrays.fill(meshCellBits,0,words,0);meshCellCount=0;
    // A cell can only create a surface if at least one of its eight corners has
    // enough TSDF evidence. Build that sparse candidate set directly from the
    // touched voxels instead of scanning the full occupied bounding box.
    int nn=n*n;
    for(int i=0;i<touchedCount;i++){int id=touched[i];if((weight[id]&255)<minWeight)continue;int z=id/nn,rem=id-z*nn,y=rem/n,x=rem-y*n;
      addMeshCell(x-1,y-1,z-1,side);addMeshCell(x,y-1,z-1,side);addMeshCell(x-1,y,z-1,side);addMeshCell(x,y,z-1,side);
      addMeshCell(x-1,y-1,z,side);addMeshCell(x,y-1,z,side);addMeshCell(x-1,y,z,side);addMeshCell(x,y,z,side);
    }
    int[][] corners={{0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1}},tets={{0,5,1,6},{0,1,2,6},{0,2,3,6},{0,3,7,6},{0,7,4,6},{0,4,5,6}};
    PVector[] p=new PVector[8];float[] v=new float[8];int[] ww=new int[8];for(int i=0;i<8;i++)p[i]=new PVector();int plane=side*side;
    for(int i=0;i<meshCellCount;i++){int cell=meshCells[i],z=cell/plane,rem=cell-z*plane,y=rem/side,x=rem-y*side;
      for(int c=0;c<8;c++){int xx=x+corners[c][0],yy=y+corners[c][1],zz=z+corners[c][2],id=idx(xx,yy,zz);
        p[c].set(origin.x+xx*voxelSize,origin.y+yy*voxelSize,origin.z+zz*voxelSize);int wt=weight[id]&255;ww[c]=wt;v[c]=wt==0?1.0f:tsdf[id]/32767.0f;}
      for(int[] t:tets){polygonizeTet(out,p,v,ww,t,minWeight);if(out.triangleCount()>=maxTriangles){out.recalculateNormals();return out;}}
    }
    out.recalculateNormals();return out;
  }
  PVector interp(PVector a,PVector b,float va,float vb){float d=va-vb,t=abs(d)<1e-7f?0.5f:constrain(va/d,0,1);
    return new PVector(lerp(a.x,b.x,t),lerp(a.y,b.y,t),lerp(a.z,b.z,t));}
  void polygonizeTet(Mesh3D out,PVector[] p,float[] v,int[] ww,int[] t,int minWeight){
    int i0=-1,i1=-1,i2=-1,o0=-1,o1=-1,o2=-1,ni=0,no=0;
    for(int k=0;k<4;k++){int q=t[k];if(ww[q]<minWeight)return;if(v[q]<0){if(ni==0)i0=q;else if(ni==1)i1=q;else i2=q;ni++;}
      else{if(no==0)o0=q;else if(no==1)o1=q;else o2=q;no++;}}
    if(ni==0||ni==4)return;
    if(ni==1){emitTetTriangle(out,p,v,i0,o0,o1,o2,false);return;}
    if(ni==3){emitTetTriangle(out,p,v,o0,i0,i1,i2,true);return;}
    PVector ac=interp(p[i0],p[o0],v[i0],v[o0]),ad=interp(p[i0],p[o1],v[i0],v[o1]);
    PVector bc=interp(p[i1],p[o0],v[i1],v[o0]),bd=interp(p[i1],p[o1],v[i1],v[o1]);
    int cac=sampleColor(ac),cad=sampleColor(ad),cbc=sampleColor(bc),cbd=sampleColor(bd);
    out.addTriangle(ac,bc,ad,cac,cbc,cad);out.addTriangle(ad,bc,bd,cad,cbc,cbd);
  }
  void emitTetTriangle(Mesh3D out,PVector[] p,float[] v,int center,int e0,int e1,int e2,boolean invert){
    PVector p0=interp(p[center],p[e0],v[center],v[e0]),p1=interp(p[center],p[e1],v[center],v[e1]),p2=interp(p[center],p[e2],v[center],v[e2]);
    int c0=sampleColor(p0),c1=sampleColor(p1),c2=sampleColor(p2);
    if(invert)out.addTriangle(p0,p2,p1,c0,c2,c1);else out.addTriangle(p0,p1,p2,c0,c1,c2);
  }
}

// ===== SynKinect Studio / 3D Scanner / UI.pde =====
class ScannerUI {
  final int ACTION_START=0, ACTION_RESET=1, ACTION_MESH=2, ACTION_STL=3, ACTION_OBJ=4, ACTION_PLY=5;
  final int ACTION_CLEAN=6, ACTION_SMOOTH=7, ACTION_CENTER=8, ACTION_UNDO=9, ACTION_CALIBRATE=10, ACTION_HQ=11, ACTION_SURFACE_MODE=12;

  final int BUTTON_NORMAL=0, BUTTON_PRIMARY=1, BUTTON_QUIET=2;

 final ArrayList<UiButton> buttons = new ArrayList<UiButton>();
 final ArrayList<UiActionGroup> groups = new ArrayList<UiActionGroup>();
  float previewX, previewY, previewW, previewH;

  ScannerUI() {
    UiActionGroup capture = group("group.capture");
    capture.add(button("button.start", ACTION_START, BUTTON_PRIMARY));
    capture.add(button("button.reset", ACTION_RESET, BUTTON_QUIET));
    capture.add(button("button.surface_mode", ACTION_SURFACE_MODE, BUTTON_NORMAL));

    UiActionGroup meshGroup = group("group.mesh");
    meshGroup.add(button("button.mesh", ACTION_MESH, BUTTON_PRIMARY));
    meshGroup.add(button("button.refine", ACTION_HQ, BUTTON_NORMAL));

    UiActionGroup editGroup = group("group.edit");
    editGroup.add(button("button.clean", ACTION_CLEAN, BUTTON_NORMAL));
    editGroup.add(button("button.smooth", ACTION_SMOOTH, BUTTON_NORMAL));
    editGroup.add(button("button.center", ACTION_CENTER, BUTTON_NORMAL));
    editGroup.add(button("button.undo", ACTION_UNDO, BUTTON_QUIET));

    UiActionGroup exportGroup = group("group.export");
    exportGroup.add(button("button.stl", ACTION_STL, BUTTON_NORMAL));
    exportGroup.add(button("button.obj", ACTION_OBJ, BUTTON_NORMAL));
    exportGroup.add(button("button.ply", ACTION_PLY, BUTTON_NORMAL));

  }

  UiActionGroup group(String key) { UiActionGroup g=new UiActionGroup(key); groups.add(g);
     return g; }
  UiButton button(String key,int action,int style) { UiButton b=new UiButton(key,action,style);
     buttons.add(b); return b; }

  float statusHeight(){return studio.ui.metricPanelHeight(max(80,width-2*studioUiMargin()),8,true);
    }

  void draw() {
    drawHeader();
    ScannerTheme theme=scannerState().theme;
    float m=studioUiMargin(),gap=studioUiGap(),w=max(80,width-2*m);
    float statusY=studioUiHeaderHeight()+gap,statusH=statusHeight(),toolbarH=toolbarHeight(w);

    float available=max(1,studio.contentHeight-statusY-m);
    StudioUiRect[] bands=studio.ui.vertical(m,statusY,w,available,gap,new float[]{statusH,180,toolbarH},new float[]{statusH,90,toolbarH},new float[]{0,
        1,0});
    StudioUiRect statusBand=bands[0],bodyBand=bands[1],toolbarBand=bands[2];
    drawSystemStatus(statusBand.x,statusBand.y,statusBand.w,statusBand.h);
    float bodyY=bodyBand.y,bodyH=bodyBand.h,toolbarY=toolbarBand.y;toolbarH=toolbarBand.h;

    // RGB Camera and Metric Depth are diagnostics, not Scanner work surfaces.
    // Give the complete body area to the 3D reconstruction.
    drawReconstructionCard(m,bodyY,w,bodyH);
    drawToolbar(m,toolbarY,w,toolbarH);
  }

  void drawSystemStatus(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,scannerState().i18n.tr("panel.system"));
    KinectSource source=scannerState().source;
    boolean rgb=source!=null&&source.colorConnected,depth=source!=null&&source.depthConnected;

    String[] labels={scannerState().i18n.tr("label.rgbShort"),scannerState().i18n.tr("label.depthShort"),scannerState().i18n.tr("label.target"),scannerState().i18n.tr("label.icp"),
      scannerState().i18n.tr("label.turn"),scannerState().i18n.tr("label.integrated"),scannerState().i18n.tr("label.progress"),scannerState().i18n.tr("label.quality")};

    String[] values={source==null?"0":String.valueOf(source.colorFrames),source==null?"0":String.valueOf(source.depthFrames),targetValue(),icpValue(),
      nf(scannerState().scanCoverage==null?0:scannerState().scanCoverage.sweepDeg,1,1)+"°",String.valueOf(scannerState().integratedFrames),
      nf(constrain(scannerState().uiProgress,0,1)*100,1,0)+"%",nf(constrain(scannerState().uiScanQuality,0,1)*100,1,0)+"%"};
    boolean[] active={rgb,depth,!Float.isNaN(scannerState().uiTargetDepthM),scannerState().uiTrackingGood,
      scannerState().scanCoverage!=null&&scannerState().scanCoverage.sweepDeg>0.1f,scannerState().integratedFrames>0,
      scannerState().scanActive,scannerState().uiScanQuality>=0.55f};
    StudioUiMetrics ui=studio.ui.metrics();float footer=ui.footerH,ix=x+ui.panelPad,iy=y+ui.cardTitleH+ui.panelPad*.45f,iw=max(1,w-ui.panelPad*2),ih=max(1,
      h-ui.cardTitleH-ui.panelPad*1.45f-footer);
    studio.ui.drawMetricGrid(labels,values,active,ix,iy,iw,ih);
    String sourceStatus=source==null?"":source.displayError(),message=sourceStatus.length()>0?sourceStatus:scannerState().status;
    if(message==null||message.length()==0)message=scannerState().i18n.tr("status.ready");

    float footerY=y+h-footer*.5f;fill(sourceStatus.length()>0?scannerState().theme.WARN:scannerState().theme.TEXT_MUTED);
    noStroke();ellipse(x+15,footerY,6,6);fill(scannerState().theme.TEXT_MUTED);uiText(scannerState().theme.FONT_TINY,false);
    textAlign(LEFT,CENTER);fitCurrentTextSize(message,scannerState().theme.FONT_TINY,8,w-42,footer-4);
    text(ellipsizeToWidth(message,w-42),x+25,footerY);textAlign(LEFT,BASELINE);
  }

  void drawHeader() {
    studio.ui.renderer.header(scannerState().i18n,scannerState().i18n.tr("app.title"));

  }

  void drawRgbCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,scannerState().i18n.tr("panel.rgb"));
    float px=x+10, py=y+studioUiCardTitleHeight(), pw=max(1,w-20), ph=max(1,h-studioUiCardTitleHeight()-42);

    previewSurface(px,py,pw,ph);
    if(scannerState().colorPreview!=null) imageFit(scannerState().colorPreview,px,py,pw,ph);
     else drawWaiting(px,py,pw,ph,scannerState().i18n.tr("waiting.rgb"));
    boolean rgb=scannerState().source!=null&&scannerState().source.colorConnected;

    drawCompactFooter(x,y,w,h,scannerState().i18n.tr("chip.rgb"),rgb,rgbFooterValue());

  }

  String rgbFooterValue(){
    String frames=scannerState().source==null?"0":String.valueOf(scannerState().source.colorFrames);

    if(scannerState().source!=null)frames+="  ·  pairs "+scannerState().source.queuedRgbdPairs()+"/"+scannerState().config.rgbdQueueFrames;

    if(Float.isNaN(scannerState().latestRgbDepthSkewMs))return frames;
    String value=frames+"  ·  "+scannerState().i18n.tr("chip.sync")+" "+nf(scannerState().latestRgbDepthSkewMs,1,1)+" ms";

    if(scannerState().rgbRegistration!=null&&(abs(scannerState().rgbRegistration.autoOffsetX)>0.05f||abs(scannerState().rgbRegistration.autoOffsetY)>0.05f))
      value+="  ·  Δxy "+nf(scannerState().rgbRegistration.autoOffsetX,1,1)+","+nf(scannerState().rgbRegistration.autoOffsetY,1,1);

    return value;
  }

  void drawDepthCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,scannerState().i18n.tr("panel.depth"));
    float footerH=64;
    float px=x+10,py=y+studioUiCardTitleHeight(),pw=max(1,w-20),ph=max(1,h-studioUiCardTitleHeight()-footerH-8);

    previewSurface(px,py,pw,ph);
    if(scannerState().depthPreview!=null) imageFit(scannerState().depthPreview,px,py,pw,ph);
     else drawWaiting(px,py,pw,ph,scannerState().i18n.tr("waiting.depth"));

    boolean depthOk=scannerState().source!=null&&scannerState().source.depthConnected;

    boolean metric=scannerState().latestDepth!=null&&scannerState().latestDepth.deviceCalibrated;

    float fy=py+ph+9,chipGap=6,chipW=max(24,(w-20-chipGap*2)/3.0f);
    miniState(x+10,fy,chipW,scannerState().i18n.tr("chip.depth"),depthOk);
    miniState(x+10+chipW+chipGap,fy,chipW,scannerState().i18n.tr("chip.metric"),metric);

    boolean profile=scannerState().calibration!=null&&scannerState().calibration.hasDepthCorrection();

    miniState(x+10+(chipW+chipGap)*2,fy,chipW,scannerState().i18n.tr("chip.profile"),profile);


    String value="—";
    if(scannerState().latestDepthDiagnostics!=null&&scannerState().latestDepthDiagnostics.plausiblePixels>0){
      value=nf(scannerState().latestDepthDiagnostics.medianMm/1000.0f,1,2)+" m  ·  "+nf(scannerState().latestDepthDiagnostics.plausibleRatio*100.0f,1,1)+"%";

      if(scannerState().source!=null)value+="  ·  q "+scannerState().source.queuedRgbdPairs()+"/"+scannerState().config.rgbdQueueFrames+" → "+reconstructionQueuedFrames()+"/"+scannerState().config.reconstructionQueueFrames;

    }
    fill(scannerState().theme.TEXT_MUTED); uiText(scannerState().theme.FONT_SMALL,false);
     textAlign(scannerState().i18n.startAlign(),CENTER);
    fitCurrentTextSize(value,scannerState().theme.FONT_SMALL,7,w-20,24);text(ellipsizeToWidth(value,w-20),scannerState().i18n.rtl?x+w-10:x+10,y+h-16);
     textAlign(LEFT,BASELINE);
  }

  void drawCompactFooter(float x,float y,float w,float h,String label,boolean active,String value) {
    float cy=y+h-20;
    noStroke(); fill(active?scannerState().theme.ACCENT:scannerState().theme.BORDER);
     ellipse(x+16,cy,7,7);
    fill(scannerState().theme.TEXT_MUTED); uiText(scannerState().theme.FONT_SMALL,false);
     textAlign(LEFT,CENTER);String footer=label+"  "+value;fitCurrentTextSize(footer,scannerState().theme.FONT_SMALL,7,w-41,24);
    text(ellipsizeToWidth(footer,w-41),x+27,cy); textAlign(LEFT,BASELINE);
  }

  void miniState(float x,float y,float w,String label,boolean active) {
    noStroke(); fill(scannerState().theme.SURFACE_ALT); rect(x,y,w,24,7);
    fill(active?scannerState().theme.ACCENT:scannerState().theme.TEXT_MUTED); ellipse(x+11,y+12,6,6);

    fill(scannerState().theme.TEXT_MUTED); uiText(scannerState().theme.FONT_TINY,false);
     textAlign(LEFT,CENTER);fitCurrentTextSize(label,scannerState().theme.FONT_TINY,7,w-26,20);
    text(ellipsizeToWidth(label,w-26),x+20,y+12); textAlign(LEFT,BASELINE);
  }

  void drawReconstructionCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,scannerState().i18n.tr("panel.reconstruction"));

    previewX=x+10; previewY=y+studioUiCardTitleHeight(); previewW=max(1,w-20); previewH=max(1,h-studioUiCardTitleHeight()-10);

    previewSurface(previewX,previewY,previewW,previewH);
    draw3DPreview(previewX,previewY,previewW,previewH);
    drawPreviewOverlay(previewX,previewY,previewW,previewH);
  }

  void drawPreviewOverlay(float x,float y,float w,float h) {
    boolean complete=scannerState().uiScanComplete;
    String scanState=complete?scannerState().i18n.tr("scan.complete"):(scannerState().scanActive?(scannerState().scanPaused?scannerState().i18n.tr("scan.paused"):scannerState().i18n.tr("scan.active")):scannerState().i18n.tr("scan.idle"));

    drawChip(x+w-132,y+10,122,28,scanState,scannerState().scanActive&&!scannerState().scanPaused,scannerState().theme.ACCENT);

    fill(scannerState().theme.TEXT_MUTED); uiText(scannerState().theme.FONT_TINY,false);
     textAlign(LEFT,CENTER);String orbitHint=scannerState().i18n.tr("hint.orbit.short");
    fitCurrentTextSize(orbitHint,scannerState().theme.FONT_TINY,7,max(40,w-160),24);
    text(ellipsizeToWidth(orbitHint,max(40,w-160)),x+12,y+24); textAlign(LEFT,BASELINE);
    drawCoverageStrip(x+12,y+h-18,max(40,w-24),7);

  }


  void drawCoverageStrip(float x,float y,float w,float h){
    ScanCoverageTracker coverage=scannerState().scanCoverage;
    if(coverage==null||coverage.covered==null||coverage.covered.length==0)return;
    int bins=coverage.covered.length;float gap=1.0f,segment=max(1,(w-gap*(bins-1))/bins);noStroke();
    for(int i=0;i<bins;i++){fill(coverage.covered[i]?scannerState().theme.ACCENT:scannerState().theme.BORDER);rect(x+i*(segment+gap),y,segment,h,2);}
  }


  String targetValue() {
    float depth=scannerState().uiTargetDepthM;
    if(Float.isNaN(depth)) return "—";
    return nf(depth,1,2)+" m";
  }

  String icpValue() {
    float rms=scannerState().uiIcpRmsMm;
    if(!scannerState().uiTrackingGood||Float.isNaN(rms)) return "—";
    return nf(rms,1,1)+" mm";
  }

  void metricTile(float x,float y,float w,float h,String label,String value){metricTile(x,y,w,h,label,value,true);
    }
  void metricTile(float x,float y,float w,float h,String label,String value,boolean active) {studio.ui.renderer.metric(x,y,w,h,label,value,active);
    }


  float actionPanelPreferredHeight(UiActionGroup group,float panelW){return studio.ui.actionPanelHeight(panelW,max(1,group.items.size()),false);
    }
  float toolbarHeight(float totalW){
    float gap=studioUiGap();boolean fourColumns=totalW>=1120;int columns=fourColumns?4:2;int rows=(groups.size()+columns-1)/columns;
    float panelW=max(1,(totalW-gap*(columns-1))/columns),rowH=0;
    for(UiActionGroup group:groups)rowH=max(rowH,actionPanelPreferredHeight(group,panelW));
    return rows*rowH+max(0,rows-1)*gap;
  }
  void drawToolbar(float x,float y,float w,float h){
    float gap=studioUiGap();int columns=w>=1120?4:2;int rows=(groups.size()+columns-1)/columns;
    float rowH=max(1,(h-gap*max(0,rows-1))/rows),panelW=max(1,(w-gap*(columns-1))/columns);
    for(int i=0;i<groups.size();i++){
      int row=i/columns,col=i%columns;float px=x+col*(panelW+gap),py=y+row*(rowH+gap);
      drawActionPanel(groups.get(i),px,py,panelW,rowH);
    }
  }
  void drawActionPanel(UiActionGroup group,float x,float y,float w,float h){card(x,y,w,h);
    studio.ui.module(scannerState().i18n).panelTitle(x,y,w,scannerState().i18n.tr(group.labelKey));
    StudioUiMetrics ui=studio.ui.metrics();ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();
    for(UiButton item:group.items){item.configure(item.label(),item.enabled(),false,item.style==scannerState().ui.BUTTON_PRIMARY,item.style==scannerState().ui.BUTTON_QUIET);
      items.add(item);}studio.ui.layoutButtons(items,x+ui.panelPad,y+ui.cardTitleH+ui.panelPad*.45f,max(1,w-ui.panelPad*2),max(1,h-ui.cardTitleH-ui.panelPad*1.45f));
    for(StudioUiButton item:items)item.draw();}


  void card(float x,float y,float w,float h) { studio.ui.module(scannerState().i18n).panel("",x,y,w,h);
     }
  void cardTitle(float x,float y,float w,String title) { studio.ui.module(scannerState().i18n).panelTitle(x,y,w,title);
     }
  void previewSurface(float x,float y,float w,float h) { noStroke(); fill(scannerState().theme.PREVIEW);
     rect(x,y,w,h,9); }
  void drawWaiting(float x,float y,float w,float h,String message) { fill(scannerState().theme.TEXT_MUTED);
     textAlign(CENTER,CENTER); uiText(scannerState().theme.FONT_BODY,false);fitCurrentTextSize(message,scannerState().theme.FONT_BODY,8,w-18,h-12);
    text(ellipsizeToWidth(message,w-18),x+w/2,y+h/2); textAlign(LEFT,BASELINE); }
  void imageFit(PImage img,float x,float y,float w,float h) {
    if(img==null||img.width<=0||img.height<=0)return;
    float s=min(w/img.width,h/img.height),dw=img.width*s,dh=img.height*s,dx=x+(w-dw)/2,dy=y+(h-dh)/2;
    pushMatrix();translate(dx+dw,dy);scale(-1,1);image(img,0,0,dw,dh);popMatrix();

  }

  void draw3DPreview(float x,float y,float w,float h) {
    Mesh3D renderMesh=scannerState().mesh;
    if((renderMesh==null||renderMesh.triangleCount()==0)&&scannerState().liveMesh!=null&&scannerState().liveMesh.triangleCount()>0)
      renderMesh=scannerState().liveMesh;
    PointCloud ref=null;

    // While scanning (including manual pause), the viewport remains an
    // ICP-registered point reconstruction. A mesh is shown only after an
    // explicit mesh command. After full-turn auto-pause, keep the point model
    // visible until such a mesh exists.
    boolean explicitMesh=scannerState().meshViewActive&&renderMesh!=null&&renderMesh.triangleCount()>0;
    if(!explicitMesh)renderMesh=null;
    // An explicit Build Mesh / Refine HQ result always owns the viewport. Capture
    // may remain paused/active in the background, but it must never force the UI
    // back to the point cloud after a mesh has been requested.
    boolean pointMode=!explicitMesh&&(scannerState().showLiveDetectionCloud||scannerState().scanActive||scannerState().uiPreviewCloud!=null);
    if(pointMode){ref=scannerState().uiPreviewCloud;renderMesh=null;}

    if(scannerState().viewport3D==null)scannerState().viewport3D=new Scanner3DViewport();
    scannerState().viewport3D.draw(x,y,w,h,renderMesh,ref);
  }

  void drawChip(float x,float y,float w,float h,String label,boolean active,int tint) {
    noStroke(); fill(active?scannerState().theme.SURFACE_RAISED:scannerState().theme.SURFACE_ALT);
     rect(x,y,w,h,h/2);
    fill(active?tint:scannerState().theme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(scannerState().theme.FONT_TINY,true);
    fitCurrentTextSize(label,scannerState().theme.FONT_TINY,7,w-10,h-6);text(ellipsizeToWidth(label,w-10),x+w/2,y+h/2);
     textAlign(LEFT,BASELINE);
  }

  String ellipsize(String s,int limit) { if(s==null)return ""; return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…";
     }
  boolean isOver3D(float mx,float my){ return mx>=previewX&&mx<=previewX+previewW&&my>=previewY&&my<=previewY+previewH;
     }
  boolean handleMousePressed(float mx,float my){
    for(UiButton b:buttons)if(b.hit(mx,my)){
      if(b.enabled())b.fire();else scannerActionBlockedStatus(b.action);
      return true;
    }
    return false;
  }
}

class Scanner3DViewport {
  PGraphics buffer=null;
  int bufferWidth=0,bufferHeight=0;
  Mesh3D cachedMesh=null;
  final ArrayList<PShape> meshChunks=new ArrayList<PShape>();
  int meshCursor=0;
  Object framedGeometry=null;
  int framedKind=0;
  long framedRevision=-1;
  final StableViewportFilter sceneFit=new StableViewportFilter();
  final StableViewportFilter frameFit=new StableViewportFilter();
  final int meshChunkTriangles=10000;

  void dispose(){buffer=null;bufferWidth=0;bufferHeight=0;cachedMesh=null;framedGeometry=null;framedKind=0;framedRevision=-1;meshChunks.clear();
    meshCursor=0;sceneFit.reset();frameFit.reset();}

  void ensureBuffer(int w,int h){
    w=max(64,w);h=max(64,h);
    if(buffer!=null&&bufferWidth==w&&bufferHeight==h)return;
    buffer=createGraphics(w,h,P3D);
    bufferWidth=w;bufferHeight=h;
    cachedMesh=null;meshChunks.clear();meshCursor=0;
  }

  void resetMeshCache(Mesh3D mesh){
    if(cachedMesh==mesh)return;
    cachedMesh=mesh;meshChunks.clear();meshCursor=0;
  }

  void buildNextMeshChunk(Mesh3D mesh){
    if(buffer==null||mesh==null||meshCursor>=mesh.triangles.size())return;
    int end=min(mesh.triangles.size(),meshCursor+meshChunkTriangles);
    PShape chunk=buffer.createShape();
    chunk.beginShape(TRIANGLES);chunk.noStroke();
    boolean textured=!scannerState().solidScanMode&&scannerState().rgbFinalized;
    for(int i=meshCursor;i<end;i++){
      Triangle3D tri=mesh.triangles.get(i);
      chunk.normal(tri.n.x,tri.n.y,tri.n.z);
      chunk.fill(textured?mesh.renderColor(tri.ca,scannerState().theme.ACCENT):scannerState().theme.ACCENT);chunk.vertex(tri.a.x,tri.a.y,tri.a.z);

      chunk.fill(textured?mesh.renderColor(tri.cb,scannerState().theme.ACCENT):scannerState().theme.ACCENT);chunk.vertex(tri.b.x,tri.b.y,tri.b.z);

      chunk.fill(textured?mesh.renderColor(tri.cc,scannerState().theme.ACCENT):scannerState().theme.ACCENT);chunk.vertex(tri.c.x,tri.c.y,tri.c.z);

    }
    chunk.endShape();meshChunks.add(chunk);meshCursor=end;
  }

  void draw(float x,float y,float w,float h,Mesh3D renderMesh,PointCloud ref){
    int bw=max(64,round(w));int bh=max(64,round(h));
    ensureBuffer(bw,bh);resetMeshCache(renderMesh);

    PVector rawFocusCenter=new PVector(0,0,0.75f);
    float rawSceneRadius=0.20f;
    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      rawFocusCenter=renderMesh.boundsCenter();rawSceneRadius=max(0.05f,renderMesh.boundsRadius());
    }else if(ref!=null&&ref.points!=null&&!ref.points.isEmpty()){
      float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;
      float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;
      for(PVector point:ref.points){
        if(point==null)continue;
        minX=min(minX,point.x);minY=min(minY,point.y);minZ=min(minZ,point.z);
        maxX=max(maxX,point.x);maxY=max(maxY,point.y);maxZ=max(maxZ,point.z);
      }
      if(minX<Float.POSITIVE_INFINITY){
        rawFocusCenter.set((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
        rawSceneRadius=max(0.05f,dist(minX,minY,minZ,maxX,maxY,maxZ)*0.5f);
      }
    }

    int geometryKind=(renderMesh!=null&&renderMesh.triangleCount()>0)?2:(ref!=null?1:0);
    Object geometryIdentity=(geometryKind==2)?renderMesh:ref;
    // PointCloud is rebuilt every frame, so object identity must NOT be treated
    // as a new scene. Reset framing only when the viewport actually changes
    // mode (live cloud <-> reconstructed mesh).
    long revision=scannerState().previewAutoFitRevision;
    if(geometryKind!=0&&(geometryKind!=framedKind||revision!=framedRevision)){
      framedKind=geometryKind;framedGeometry=geometryIdentity;framedRevision=revision;sceneFit.reset();frameFit.reset();
      if(!scannerState().previewUserAdjusted){scannerState().previewPanX=0;scannerState().previewPanY=0;scannerState().previewZoom=1.0f;}
    }

    AppConfig viewCfg=scannerState().config;
    sceneFit.updateScene(rawFocusCenter,rawSceneRadius,viewCfg.previewAutoFitDeadband,
      viewCfg.previewAutoFitZoomOutResponse,viewCfg.previewAutoFitZoomInResponse,
      viewCfg.previewAutoFitCenterResponse,viewCfg.previewAutoFitShrinkDelayFrames);
    PVector focusCenter=sceneFit.focus.copy();float sceneRadius=max(.05f,sceneFit.radius);

    float meshDisplayOffsetY=0.0f;
    float floorY=focusCenter.y+sceneRadius*1.05f;
    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      float meshBottomY=meshMaxY(renderMesh);
      if(Float.isFinite(meshBottomY))meshDisplayOffsetY=floorY-meshBottomY;
    }

    ScannerViewFit fit=scannerViewFit(renderMesh,ref,focusCenter,scannerState().previewYaw,scannerState().previewPitch,meshDisplayOffsetY);
    float targetViewScale=min((bw*.90f)/max(.04f,fit.spanX),(bh*.86f)/max(.04f,fit.spanY));
    if(!Float.isFinite(targetViewScale)||targetViewScale<=0)targetViewScale=max(1.0f,min(bw,bh)*0.40f/max(sceneRadius,0.02f));
    targetViewScale=constrain(targetViewScale,20.0f,max(80.0f,min(bw,bh)*8.0f));
    frameFit.updateFrame(targetViewScale,fit.centerX,fit.centerY,viewCfg.previewAutoFitDeadband,
      viewCfg.previewAutoFitZoomOutResponse,viewCfg.previewAutoFitZoomInResponse,
      viewCfg.previewAutoFitCenterResponse,viewCfg.previewAutoFitShrinkDelayFrames);
    float viewScale=frameFit.scale*scannerState().previewZoom;
    float worldStroke=1.0f/max(1.0f,viewScale);
    float axisLen=max(sceneRadius*1.05f,0.08f);
    float panWorldX=scannerState().previewPanX/max(1.0f,viewScale);
    float panWorldY=scannerState().previewPanY/max(1.0f,viewScale);

    buffer.beginDraw();
    buffer.background(scannerState().theme.PREVIEW);
    buffer.hint(ENABLE_DEPTH_TEST);
    buffer.ortho(-bw*0.5f,bw*0.5f,-bh*0.5f,bh*0.5f,-10000,10000);
    buffer.translate(bw*0.5f-frameFit.centerX*viewScale,bh*0.5f-frameFit.centerY*viewScale,0);
    buffer.ambientLight(92,92,100);
    buffer.directionalLight(224,224,224,-0.4f,0.6f,-1.0f);
    buffer.directionalLight(112,126,150,0.5f,-0.3f,-0.2f);
    buffer.scale(viewScale);
    buffer.translate(panWorldX,panWorldY,0);
    buffer.rotateX(scannerState().previewPitch);
    // Kinect points extend along +Z. The half turn presents the cloud from the
    // sensor-facing side and keeps left/right consistent with the RGB preview.
    buffer.rotateY(PI+scannerState().previewYaw);
    // The half-turn gives a front view; the X reflection removes the mirrored
    // left/right presentation. Reconstruction coordinates remain unchanged.
    buffer.scale(-1,1,1);
    buffer.translate(-focusCenter.x,-focusCenter.y,-focusCenter.z);

    PVector floorCenter=new PVector(focusCenter.x,floorY,focusCenter.z);
    drawClassicGrid(floorCenter,sceneRadius,worldStroke);
    drawClassicAxes(focusCenter,axisLen,worldStroke);

    buffer.stroke(scannerState().theme.GRID);buffer.strokeWeight(worldStroke);buffer.noFill();
    buffer.pushMatrix();buffer.translate(focusCenter.x,focusCenter.y,focusCenter.z);
    buffer.box(sceneRadius*2.1f,sceneRadius*2.1f,sceneRadius*2.1f);buffer.popMatrix();

    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      if(meshCursor<renderMesh.triangles.size())buildNextMeshChunk(renderMesh);
      buffer.pushMatrix();buffer.translate(0,meshDisplayOffsetY,0);
      for(PShape chunk:meshChunks)buffer.shape(chunk);
      buffer.popMatrix();
    }else if(ref!=null&&ref.points!=null){
      // Original Scanner appearance: a coherent, uniform point cloud. RGB is
      // still retained in PointCloud for reconstruction/mesh/export; it is not
      // used to visually fragment the live geometry.
      buffer.stroke(scannerState().theme.ACCENT);
      buffer.strokeWeight(worldStroke*2.0f);
      buffer.beginShape(POINTS);
      for(PVector point:ref.points)if(point!=null)buffer.vertex(point.x,point.y,point.z);
      buffer.endShape();
    }

    buffer.noLights();buffer.hint(DISABLE_DEPTH_TEST);buffer.endDraw();
    image(buffer,x,y,w,h);
  }

  class ScannerViewFit {float centerX=0,centerY=0,spanX=.4f,spanY=.4f;int samples=0;}
  PVector scannerViewProject(PVector point,PVector center,float yaw,float pitch){
    float x=-(point.x-center.x),y=point.y-center.y,z=point.z-center.z;float a=PI+yaw,cy=cos(a),sy=sin(a);
    float x1=x*cy+z*sy,z1=-x*sy+z*cy,cp=cos(pitch),sp=sin(pitch),y1=y*cp-z1*sp;return new PVector(x1,y1,z1);
  }
  ScannerViewFit scannerViewFit(Mesh3D mesh,PointCloud ref,PVector center,float yaw,float pitch,float meshOffsetY){
    ScannerViewFit fit=new ScannerViewFit();ArrayList<Float> xs=new ArrayList<Float>(),ys=new ArrayList<Float>();
    if(mesh!=null&&mesh.triangleCount()>0){int stride=max(1,mesh.triangles.size()/3500);for(int i=0;i<mesh.triangles.size();i+=stride){Triangle3D t=mesh.triangles.get(i);PVector[] vv={t.a,t.b,t.c};for(PVector v:vv){PVector shifted=new PVector(v.x,v.y+meshOffsetY,v.z);PVector q=scannerViewProject(shifted,center,yaw,pitch);xs.add(q.x);ys.add(q.y);}}}
    else if(ref!=null&&ref.points!=null&&!ref.points.isEmpty()){int stride=max(1,ref.points.size()/5000);for(int i=0;i<ref.points.size();i+=stride){PVector v=ref.points.get(i);if(v==null)continue;PVector q=scannerViewProject(v,center,yaw,pitch);xs.add(q.x);ys.add(q.y);}}
    if(xs.size()<3)return fit;Collections.sort(xs);Collections.sort(ys);int n=xs.size(),lo=constrain(round((n-1)*.01f),0,n-1),hi=constrain(round((n-1)*.99f),0,n-1);
    float minX=xs.get(lo),maxX=xs.get(hi),minY=ys.get(lo),maxY=ys.get(hi);fit.centerX=(minX+maxX)*.5f;fit.centerY=(minY+maxY)*.5f;fit.spanX=max(.04f,maxX-minX);fit.spanY=max(.04f,maxY-minY);fit.samples=n;return fit;
  }

  float meshMaxY(Mesh3D mesh){
    if(mesh==null||mesh.triangleCount()==0)return Float.NaN;
    float maxY=Float.NEGATIVE_INFINITY;
    for(Triangle3D t:mesh.triangles){
      maxY=max(maxY,max(t.a.y,max(t.b.y,t.c.y)));
    }
    return maxY;
  }

  void drawClassicGrid(PVector center,float radius,float strokeWorld){
    float size=max(radius*1.6f,0.18f);int lines=10;float step=(size*2.0f)/lines;
    buffer.stroke(scannerState().theme.BORDER);buffer.strokeWeight(strokeWorld);
    for(int i=0;i<=lines;i++){
      float d=-size+i*step;
      buffer.line(center.x-size,center.y,center.z+d,center.x+size,center.y,center.z+d);
      buffer.line(center.x+d,center.y,center.z-size,center.x+d,center.y,center.z+size);
    }
  }

  void drawClassicAxes(PVector center,float axisLen,float strokeWorld){
    buffer.strokeWeight(strokeWorld*1.7f);
    buffer.stroke(220,92,92);buffer.line(center.x,center.y,center.z,center.x+axisLen,center.y,center.z);
    buffer.stroke(92,220,140);buffer.line(center.x,center.y,center.z,center.x,center.y-axisLen,center.z);
    buffer.stroke(92,150,232);buffer.line(center.x,center.y,center.z,center.x,center.y,center.z+axisLen);
  }

}
class UiActionGroup {
 final String labelKey; final ArrayList<UiButton> items=new ArrayList<UiButton>();

  UiActionGroup(String key){labelKey=key;}
  void add(UiButton button){items.add(button);}
}

class UiButton extends StudioUiButton {
  final String labelKey; final int action,style;
  UiButton(String labelKey,int action,int style){this.labelKey=labelKey;this.action=action;
    this.style=style;}
  void setBounds(float x,float y,float w,float h){place(x,y,w,h);}
  String label(){
    if(action==scannerState().ui.ACTION_START&&scannerState().scanActive)return scannerState().i18n.tr(scannerState().scanPaused?"button.resume":"button.pause");
    if(action==scannerState().ui.ACTION_CALIBRATE&&scannerState().calibrationSession!=null&&scannerState().calibrationSession.active)return scannerState().i18n.tr("button.calibrate.cancel");
    if(action==scannerState().ui.ACTION_SURFACE_MODE)return scannerState().i18n.tr(scannerState().solidScanMode?"mode.solid":"mode.texture");
    if(action==scannerState().ui.ACTION_HQ&&scannerState().config!=null&&scannerState().hqArchive!=null){
      int have=scannerState().hqArchive.size(),need=scannerState().config.hqMinimumKeyframes;
      if(have<need)return scannerState().i18n.tr(labelKey)+" · "+have+"/"+need;
    }
    return scannerState().i18n.tr(labelKey);
  }
  boolean enabled(){return scannerActionAllowed(action);}
  void draw(){
    boolean en=enabled();
    boolean selected=(action==scannerState().ui.ACTION_CALIBRATE&&scannerState().calibrationSession!=null&&scannerState().calibrationSession.active)
      ||(action==scannerState().ui.ACTION_START&&scannerState().scanActive)
      ||(action==scannerState().ui.ACTION_HQ&&scannerState().hqBusy)
      ||(action==scannerState().ui.ACTION_SURFACE_MODE&&scannerState().solidScanMode);

    configure(label(),en,selected,style==scannerState().ui.BUTTON_PRIMARY,style==scannerState().ui.BUTTON_QUIET);
    super.draw();
  }
  void fire(){dispatchUiAction(action);}
}


