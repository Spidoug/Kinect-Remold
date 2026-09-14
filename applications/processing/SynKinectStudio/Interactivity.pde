// ===== SynKinect Studio / Interactivity =====
// Interactivity owns its own RGB + metric-Depth transport instance.
// Scanner and Interactivity share calibration math, not a live connection. This keeps
// tab transitions independent: closing one module cannot stop or reconfigure another.
// The UI consumes immutable snapshots; the 3D tracker runs on its own latest-frame worker.
class InteractionModuleState {
  InteractionConfig config;
  InteractionI18n i18n;
  InteractionFrameProcessor processor;
  Nui20SkeletonTracker tracker;
  InteractionRuntime runtime;
  KinectSource source;
  InteractionDesktopController desktop;
  NuiSkeletonPublisher nuiPublisher;
  InteractionOrbCloud cloud;
  InteractionUI ui;
  PImage rgbImage;
  InteractionSkeleton3D skeleton;
  long lastProcessedFrame=-1;
  volatile boolean controlEnabled=false;
  volatile String status="";
}

void setupInteractivityModule(){
  studio.interactionState.config=new InteractionConfig();studio.interactionState.config.load(new File(dataPath("interaction.properties")));
  studio.interactionState.i18n=new InteractionI18n(studio.currentLanguage());
  ensureRgbdCore();
  studio.interactionState.tracker=new Nui20SkeletonTracker(studio.interactionState.config,studio.scannerState.calibration,studio.scannerState.rgbRegistration);
  studio.interactionState.processor=new InteractionFrameProcessor(studio.interactionState.config,studio.interactionState.tracker);
  studio.interactionState.desktop=new InteractionDesktopController(studio.interactionState.config);
  studio.interactionState.nuiPublisher=new NuiSkeletonPublisher();
  studio.interactionState.cloud=new InteractionOrbCloud(studio.interactionState.config);
  studio.interactionState.source=new KinectSource(studio.scannerState.config,studio.scannerState.calibration,studio.scannerState.i18n);
  studio.interactionState.source.setHqColorRequested(false);
  studio.interactionState.runtime=new InteractionRuntime(studio.interactionState.config,studio.interactionState.source,studio.interactionState.processor);
  studio.interactionState.ui=new InteractionUI();studio.interactionState.status=studio.interactionState.i18n.tr("status.ready");
}
void activateInteractivityModule(){
  studio.interactionState.lastProcessedFrame=-1;studio.interactionState.skeleton=null;studio.interactionState.rgbImage=null;
  if(studio.interactionState.tracker!=null)studio.interactionState.tracker.reset();
  // Interactivity always owns a fresh VGA RGB+Depth session.
  if(studio.interactionState.source!=null)studio.interactionState.source.setHqColorRequested(false);
  if(studio.interactionState.runtime!=null)studio.interactionState.runtime.start();
}
void requestDeactivateInteractivityModule(){
  studio.interactionState.controlEnabled=false;
  if(studio.interactionState.desktop!=null)studio.interactionState.desktop.setEnabled(false);
  if(studio.interactionState.cloud!=null)studio.interactionState.cloud.reset();
  if(studio.interactionState.runtime!=null)studio.interactionState.runtime.requestStop();
}
void deactivateInteractivityModule(){
  studio.interactionState.controlEnabled=false;
  if(studio.interactionState.desktop!=null)studio.interactionState.desktop.setEnabled(false);
  if(studio.interactionState.cloud!=null)studio.interactionState.cloud.reset();
  if(studio.interactionState.runtime!=null)studio.interactionState.runtime.stop(false);
  if(studio.interactionState.nuiPublisher!=null)studio.interactionState.nuiPublisher.close();
}
void disposeInteractivityModule(){deactivateInteractivityModule();}
void drawInteractivityModule(){background(studio.services.acousticTheme.BG);serviceInteractivityFrames();if(studio.interactionState.cloud!=null)studio.interactionState.cloud.update(studio.interactionState.skeleton);if(studio.interactionState.ui!=null)studio.interactionState.ui.draw();}

// UI thread: immutable snapshots only. No transport or CV work executes here.
void serviceInteractivityFrames(){
  InteractionProcessedFrame p=studio.interactionState.processor==null?null:studio.interactionState.processor.latest();
  if(p!=null&&p.frameNumber!=studio.interactionState.lastProcessedFrame){studio.interactionState.lastProcessedFrame=p.frameNumber;studio.interactionState.skeleton=p.skeleton;if(studio.interactionState.nuiPublisher!=null)studio.interactionState.nuiPublisher.publish(p.skeleton,p.frameNumber);applyInteractionRgbPreview(p.previewPixels);}
  if(studio.interactionState.desktop!=null){studio.interactionState.desktop.setEnabled(studio.interactionState.controlEnabled);if(studio.interactionState.controlEnabled&&studio.interactionState.skeleton!=null&&studio.interactionState.skeleton.interactionTracked())studio.interactionState.desktop.update(studio.interactionState.skeleton);}
}
void applyInteractionRgbPreview(int[] pixels){if(pixels==null||pixels.length!=studio.services.scannerProtocol.WIDTH*studio.services.scannerProtocol.HEIGHT)return;if(studio.interactionState.rgbImage==null)studio.interactionState.rgbImage=createImage(studio.services.scannerProtocol.WIDTH,studio.services.scannerProtocol.HEIGHT,RGB);studio.interactionState.rgbImage.loadPixels();System.arraycopy(pixels,0,studio.interactionState.rgbImage.pixels,0,pixels.length);studio.interactionState.rgbImage.updatePixels();}
boolean interaction3dLive(){if(studio.interactionState.lastProcessedFrame>=0&&studio.interactionState.processor!=null&&millis64()-studio.interactionState.processor.lastPublishedMs<=studio.interactionState.config.streamStaleMs)return true;return studio.interactionState.runtime!=null&&studio.interactionState.runtime.streamsLive();}
void interactivityMousePressed(){if(studio.interactionState.ui!=null)studio.interactionState.ui.handleMouse(studio.contentMouseX(),studio.contentMouseY());}
void interactivityKeyPressed(){if(key=='e'||key=='E')toggleInteractionControl();}
void toggleInteractionControl(){if(!studio.interactionState.controlEnabled&&(studio.interactionState.desktop==null||!studio.interactionState.desktop.available())){studio.interactionState.controlEnabled=false;studio.interactionState.status=studio.interactionState.i18n.tr("status.desktop_unavailable");return;}studio.interactionState.controlEnabled=!studio.interactionState.controlEnabled;if(studio.interactionState.desktop!=null)studio.interactionState.desktop.setEnabled(studio.interactionState.controlEnabled);studio.interactionState.status=studio.interactionState.i18n.tr(studio.interactionState.controlEnabled?"status.control_on":"status.control_off");}
class InteractionConfig {
  int workerJoinMs=2200,streamStaleMs=1800,previewHz=15;
  int minDepthMm=550,maxDepthMm=3800;
  float poseMinCoreConfidence=0.32f;
  int poseOcclusionHoldFrames=12;
  float poseFilterMinAlpha=0.08f,poseFilterMaxAlpha=0.82f,poseVelocityAlpha=0.24f,poseMaxSpeedMps=4.2f;
  float poseOneEuroMinCutoff=0.90f,poseOneEuroBeta=0.58f,poseOneEuroDerivativeCutoff=1.0f;
  float poseGeodesicDepthPenalty=1.15f,poseMedialPenalty=0.85f,poseCrossBodyPenalty=1.85f,poseTemporalEndpointBias=1.05f,poseMinArmPathRatio=0.52f,poseMinLegPathRatio=0.82f;
  float poseInnovationGateM=0.22f,poseJitterRadiusM=0.010f,poseBoneLearnAlpha=0.075f,poseBoneCorrection=0.68f,poseMaxDirectionJumpDeg=68.0f;
  float bodyTemporalCenterPx=120.0f,bodyTemporalDepthM=0.45f;
  int bodySampleStep=4,bodyDepthBinMm=80,bodyDepthBandMm=520,bodyDepthHypotheses=4,bodyContinuityMm=320,bodyMinSamples=90,bodyMinHeightPx=100,bodyHistogramCapSamples=1400;
  float bodyMaxWidthRatio=0.86f,bodyCenterBias=0.70f,bodyMinAspect=0.82f;
  int handLocalRadiusPx=22,handDepthToleranceMm=150;
  float handOpenRadiusMinPx=10.0f,handOpenRadiusMaxPx=28.0f;
  boolean mirrorX=true;String hand="right";int cursorMaxHz=60,cursorLostReleaseMs=800;float cursorDeadzonePx=1.8f,cursorFastAlpha=0.62f,cursorSlowAlpha=0.20f,cursorFastDistancePx=42;
  float volumeHalfWidthM=0.55f,volumeTopM=0.42f,volumeBottomM=0.48f,minHandForwardM=0.015f;
  float handOpenThreshold=0.62f,handCloseThreshold=0.38f;int twoHandStableMs=180,doubleClickStableMs=170,doubleClickCooldownMs=700,scrollCooldownMs=45;float scrollThresholdM=0.018f,scrollGainPerM=82.0f;
  int cloudParticles=300,cloudTrailSamples=22;float cloudRadiusPx=24,cloudSpring=42,cloudDamping=7,cloudFlow=0.24f,cloudTrailStrength=1,cloudStretchGain=0.020f,cloudMaxStretch=3;
  void load(File file){
    ConfigRules r=studio.services.configRules;Properties p=r.load(file,"interaction");
    workerJoinMs=r.integer(p,"transport.workerJoinMs",workerJoinMs,100,10000);streamStaleMs=r.integer(p,"transport.streamStaleMs",streamStaleMs,250,10000);previewHz=r.integer(p,"vision.previewHz",previewHz,1,30);minDepthMm=r.integer(p,"vision.minDepthMm",minDepthMm,300,6000);maxDepthMm=r.integer(p,"vision.maxDepthMm",maxDepthMm,minDepthMm+100,8000);
    poseMinCoreConfidence=r.decimal(p,"pose.minCoreConfidence",poseMinCoreConfidence,0.05f,0.95f);poseOcclusionHoldFrames=r.integer(p,"pose.occlusionHoldFrames",poseOcclusionHoldFrames,0,30);
    poseFilterMinAlpha=r.decimal(p,"pose.filterMinAlpha",poseFilterMinAlpha,0.03f,0.8f);poseFilterMaxAlpha=r.decimal(p,"pose.filterMaxAlpha",poseFilterMaxAlpha,poseFilterMinAlpha,1.0f);poseVelocityAlpha=r.decimal(p,"pose.velocityAlpha",poseVelocityAlpha,0.01f,0.9f);poseMaxSpeedMps=r.decimal(p,"pose.maxSpeedMps",poseMaxSpeedMps,0.5f,12.0f);
    poseOneEuroMinCutoff=r.decimal(p,"pose.oneEuroMinCutoff",poseOneEuroMinCutoff,0.1f,8.0f);poseOneEuroBeta=r.decimal(p,"pose.oneEuroBeta",poseOneEuroBeta,0.0f,8.0f);poseOneEuroDerivativeCutoff=r.decimal(p,"pose.oneEuroDerivativeCutoff",poseOneEuroDerivativeCutoff,0.1f,8.0f);
    poseGeodesicDepthPenalty=r.decimal(p,"pose.geodesicDepthPenalty",poseGeodesicDepthPenalty,0.0f,6.0f);poseMedialPenalty=r.decimal(p,"pose.medialPenalty",poseMedialPenalty,0.0f,4.0f);poseCrossBodyPenalty=r.decimal(p,"pose.crossBodyPenalty",poseCrossBodyPenalty,1.0f,6.0f);poseTemporalEndpointBias=r.decimal(p,"pose.temporalEndpointBias",poseTemporalEndpointBias,0.0f,4.0f);poseMinArmPathRatio=r.decimal(p,"pose.minArmPathRatio",poseMinArmPathRatio,0.15f,1.5f);poseMinLegPathRatio=r.decimal(p,"pose.minLegPathRatio",poseMinLegPathRatio,0.25f,2.5f);
    poseInnovationGateM=r.decimal(p,"pose.innovationGateM",poseInnovationGateM,0.04f,1.0f);poseJitterRadiusM=r.decimal(p,"pose.jitterRadiusM",poseJitterRadiusM,0.001f,0.08f);poseBoneLearnAlpha=r.decimal(p,"pose.boneLearnAlpha",poseBoneLearnAlpha,0.005f,0.5f);poseBoneCorrection=r.decimal(p,"pose.boneCorrection",poseBoneCorrection,0.0f,1.0f);poseMaxDirectionJumpDeg=r.decimal(p,"pose.maxDirectionJumpDeg",poseMaxDirectionJumpDeg,20.0f,160.0f);bodyTemporalCenterPx=r.decimal(p,"body.temporalCenterPx",bodyTemporalCenterPx,20,500);bodyTemporalDepthM=r.decimal(p,"body.temporalDepthM",bodyTemporalDepthM,0.1f,2.0f);
    bodySampleStep=r.integer(p,"body.sampleStep",bodySampleStep,2,8);bodyDepthBinMm=r.integer(p,"body.depthBinMm",bodyDepthBinMm,40,200);bodyDepthBandMm=r.integer(p,"body.depthBandMm",bodyDepthBandMm,180,900);bodyDepthHypotheses=r.integer(p,"body.depthHypotheses",bodyDepthHypotheses,1,8);bodyContinuityMm=r.integer(p,"body.continuityMm",bodyContinuityMm,80,700);bodyMinSamples=r.integer(p,"body.minSamples",bodyMinSamples,25,2000);bodyMinHeightPx=r.integer(p,"body.minHeightPx",bodyMinHeightPx,50,420);bodyHistogramCapSamples=r.integer(p,"body.histogramCapSamples",bodyHistogramCapSamples,100,10000);bodyMaxWidthRatio=r.decimal(p,"body.maxWidthRatio",bodyMaxWidthRatio,0.30f,1.0f);bodyCenterBias=r.decimal(p,"body.centerBias",bodyCenterBias,0,2.0f);bodyMinAspect=r.decimal(p,"body.minAspect",bodyMinAspect,0.35f,2.0f);
    handLocalRadiusPx=r.integer(p,"hand.localRadiusPx",handLocalRadiusPx,8,48);handDepthToleranceMm=r.integer(p,"hand.depthToleranceMm",handDepthToleranceMm,40,500);handOpenRadiusMinPx=r.decimal(p,"hand.openRadiusMinPx",handOpenRadiusMinPx,4,40);handOpenRadiusMaxPx=r.decimal(p,"hand.openRadiusMaxPx",handOpenRadiusMaxPx,handOpenRadiusMinPx+1,80);
    mirrorX=r.flag(p,"cursor.mirrorX",mirrorX);hand=r.text(p,"cursor.hand",hand).toLowerCase(Locale.ROOT);if(!"left".equals(hand)&&!"right".equals(hand))hand="right";cursorMaxHz=r.integer(p,"cursor.maxHz",cursorMaxHz,10,240);cursorLostReleaseMs=r.integer(p,"cursor.lostReleaseMs",cursorLostReleaseMs,100,5000);cursorDeadzonePx=r.decimal(p,"cursor.deadzonePx",cursorDeadzonePx,0,50);cursorFastAlpha=r.decimal(p,"cursor.fastAlpha",cursorFastAlpha,0.01f,1);cursorSlowAlpha=r.decimal(p,"cursor.slowAlpha",cursorSlowAlpha,0.01f,1);cursorFastDistancePx=r.decimal(p,"cursor.fastDistancePx",cursorFastDistancePx,1,300);volumeHalfWidthM=r.decimal(p,"cursor.volumeHalfWidthM",volumeHalfWidthM,.1f,2);volumeTopM=r.decimal(p,"cursor.volumeTopM",volumeTopM,.05f,2);volumeBottomM=r.decimal(p,"cursor.volumeBottomM",volumeBottomM,.05f,2);minHandForwardM=r.decimal(p,"cursor.minHandForwardM",minHandForwardM,-.5f,.5f);
    handOpenThreshold=r.decimal(p,"gesture.openThreshold",handOpenThreshold,.1f,.95f);handCloseThreshold=r.decimal(p,"gesture.closeThreshold",handCloseThreshold,.05f,handOpenThreshold-.02f);twoHandStableMs=r.integer(p,"gesture.twoHandStableMs",twoHandStableMs,0,3000);doubleClickStableMs=r.integer(p,"gesture.doubleClickStableMs",doubleClickStableMs,0,3000);doubleClickCooldownMs=r.integer(p,"gesture.doubleClickCooldownMs",doubleClickCooldownMs,0,5000);scrollCooldownMs=r.integer(p,"gesture.scrollCooldownMs",scrollCooldownMs,0,1000);scrollThresholdM=r.decimal(p,"gesture.scrollThresholdM",scrollThresholdM,.001f,.3f);scrollGainPerM=r.decimal(p,"gesture.scrollGainPerM",scrollGainPerM,1,500);
    cloudParticles=r.integer(p,"cloud.particles",cloudParticles,80,1200);cloudTrailSamples=r.integer(p,"cloud.trailSamples",cloudTrailSamples,6,80);cloudRadiusPx=r.decimal(p,"cloud.radiusPx",cloudRadiusPx,5,120);cloudSpring=r.decimal(p,"cloud.spring",cloudSpring,1,150);cloudDamping=r.decimal(p,"cloud.damping",cloudDamping,.1f,30);cloudFlow=r.decimal(p,"cloud.flow",cloudFlow,0,3);cloudTrailStrength=r.decimal(p,"cloud.trailStrength",cloudTrailStrength,.1f,4);cloudStretchGain=r.decimal(p,"cloud.stretchGain",cloudStretchGain,0,.2f);cloudMaxStretch=r.decimal(p,"cloud.maxStretch",cloudMaxStretch,1,12);
  }
}

class InteractionI18n extends ModuleI18n {InteractionI18n(String requested){super("interaction",requested);}}

class InteractionVisionSnapshot {
  final RawRgbFrame rgbFrame;final DepthFrame depthFrame;final long rgbTickMs,depthTickMs,sequence;
  InteractionVisionSnapshot(RgbdFramePair p){rgbFrame=p.rgb;depthFrame=p.depth;rgbTickMs=p.rgb.timestampUs/1000L;depthTickMs=p.depth.timestampUs/1000L;sequence=p.sequence;}long key(){return sequence;}
}
class InteractionProcessedFrame {long frameNumber=-1;int[] previewPixels;InteractionSkeleton3D skeleton;}

class InteractionFrameProcessor {
  final InteractionConfig cfg;final Nui20SkeletonTracker tracker;final Object lock=new Object();volatile boolean running=false;volatile long runGeneration=0;volatile InteractionProcessedFrame published=null;volatile long lastPublishedMs=0;long lastPreviewMs=0;Thread worker;InteractionVisionSnapshot pending=null;
  InteractionFrameProcessor(InteractionConfig cfg,Nui20SkeletonTracker tracker){this.cfg=cfg;this.tracker=tracker;}
  void start(){synchronized(lock){if(running)return;running=true;pending=null;published=null;final long generation=++runGeneration;worker=studio.services.workers.start("Interaction-3D-Fusion",new Runnable(){public void run(){loop(generation);}});}}
  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;pending=null;lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread())t.interrupt();}
  void stop(){Thread t;synchronized(lock){running=false;++runGeneration;pending=null;lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(min(1000,cfg.workerJoinMs));}catch(InterruptedException e){Thread.currentThread().interrupt();}}}
  void submit(InteractionVisionSnapshot f){if(f==null||f.rgbFrame==null||f.rgbFrame.data==null||f.depthFrame==null)return;synchronized(lock){if(!running)return;pending=f;lock.notifyAll();}}
  InteractionProcessedFrame latest(){return published;}
  void loop(long generation){while(true){InteractionVisionSnapshot f;synchronized(lock){while(running&&generation==runGeneration&&pending==null)try{lock.wait();}catch(InterruptedException e){if(!running||generation!=runGeneration)return;}if(!running||generation!=runGeneration)return;f=pending;pending=null;}try{InteractionProcessedFrame out=new InteractionProcessedFrame();out.frameNumber=f.key();out.skeleton=tracker.track(f);long now=millis64();if(lastPreviewMs==0||now-lastPreviewMs>=1000/max(1,cfg.previewHz)){out.previewPixels=rgbPreview(f.rgbFrame);lastPreviewMs=now;}if(generation==runGeneration){published=out;lastPublishedMs=now;}}catch(Exception e){if(generation==runGeneration)println("Interactivity 3D processor warning: "+safeStudioMessage(e));}}}
  int[] rgbPreview(RawRgbFrame frame){int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT;if(frame==null||frame.data==null||frame.width!=w||frame.height!=h||frame.pixelFormat!=studio.services.scannerProtocol.PIXEL_BAYER_GRBG8||frame.data.length!=w*h)return null;int[] out=new int[w*h];return RgbHqProcessor.decodeBayerGrbg(frame.data,w,h,out)?out:null;}
}

class InteractionRuntime {
  final InteractionConfig cfg;final KinectSource source;final InteractionFrameProcessor processor;final Object lock=new Object();volatile boolean running=false;volatile long runGeneration=0;volatile long lastInputMs=0;Thread connectionWorker;long lastSubmitted=-1;
  InteractionRuntime(InteractionConfig c,KinectSource s,InteractionFrameProcessor p){cfg=c;source=s;processor=p;}
  void start(){synchronized(lock){if(running)return;running=true;final long generation=++runGeneration;lastInputMs=millis64();lastSubmitted=-1;source.start();processor.start();connectionWorker=studio.services.workers.start("Interaction-RGBD",new Runnable(){public void run(){connectionLoop(generation);}});}}
  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;t=connectionWorker;connectionWorker=null;}if(t!=null&&t!=Thread.currentThread())t.interrupt();processor.requestStop();source.requestStop(true);}
  void stop(boolean keepRgbd){Thread t;synchronized(lock){running=false;++runGeneration;t=connectionWorker;connectionWorker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}processor.stop();if(!keepRgbd)source.stop(true);else source.clearConsumerPairs();}
  boolean streamsLive(){source.updateLiveness();long now=millis64();return source.running&&source.colorConnected&&source.depthConnected&&source.lastPairedArrivalMs>0&&now-source.lastPairedArrivalMs<=cfg.streamStaleMs;}
  void connectionLoop(long generation){while(running&&generation==runGeneration){try{source.updateLiveness();RgbdFramePair pair=source.latestRgbdPairAfter(lastSubmitted);if(pair!=null){lastSubmitted=pair.sequence;lastInputMs=millis64();processor.submit(new InteractionVisionSnapshot(pair));}Thread.sleep(2);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;Thread.currentThread().interrupt();return;}catch(Exception e){if(running&&generation==runGeneration)println("Interactivity RGBD warning: "+safeStudioMessage(e));}}}
}

class InteractionJoint3D {
  final String name;PVector image=new PVector(),world=new PVector();float confidence=0;int state=0; // 0 lost, 1 inferred, 2 tracked
  InteractionJoint3D(String n){name=n;}InteractionJoint3D set(PVector uv,PVector xyz,float q,int s){if(uv!=null)image.set(uv);if(xyz!=null)world.set(xyz);confidence=q;state=s;return this;}boolean tracked(){return state>0&&confidence>0;}
}
class InteractionFinger3D {final String name;InteractionJoint3D base,tip;float confidence=0;InteractionFinger3D(String n){name=n;base=new InteractionJoint3D(n+"_base");tip=new InteractionJoint3D(n+"_tip");}}
class InteractionHandPose3D {boolean tracked=false;InteractionJoint3D wrist=new InteractionJoint3D("wrist"),palm=new InteractionJoint3D("palm");InteractionFinger3D[] fingers={new InteractionFinger3D("thumb"),new InteractionFinger3D("index"),new InteractionFinger3D("middle"),new InteractionFinger3D("ring"),new InteractionFinger3D("pinky")};int fingerCount=0;float palmRadiusPx=0,openness=0.5f,grabStrength=0.5f,pinchStrength=0,confidence=0;}
class InteractionSkeleton3D {
  boolean tracked=false;long trackingId=0;float confidence=0,torsoConfidence=0,upperBodyConfidence=0,interactionConfidence=0;String reason="searching";int minX,minY,maxX,maxY;float meanDepthM=0,faceWidthPx=0,faceHeightPx=0;
  boolean clippedTop=false,clippedBottom=false;
  InteractionJoint3D head=new InteractionJoint3D("head"),neck=new InteractionJoint3D("neck"),chest=new InteractionJoint3D("chest"),spine=new InteractionJoint3D("spine");
  InteractionJoint3D leftShoulder=new InteractionJoint3D("left_shoulder"),rightShoulder=new InteractionJoint3D("right_shoulder"),leftElbow=new InteractionJoint3D("left_elbow"),rightElbow=new InteractionJoint3D("right_elbow"),leftWrist=new InteractionJoint3D("left_wrist"),rightWrist=new InteractionJoint3D("right_wrist"),leftHand=new InteractionJoint3D("left_hand"),rightHand=new InteractionJoint3D("right_hand");
  InteractionJoint3D pelvis=new InteractionJoint3D("pelvis"),leftHip=new InteractionJoint3D("left_hip"),rightHip=new InteractionJoint3D("right_hip"),leftKnee=new InteractionJoint3D("left_knee"),rightKnee=new InteractionJoint3D("right_knee"),leftAnkle=new InteractionJoint3D("left_ankle"),rightAnkle=new InteractionJoint3D("right_ankle"),leftFoot=new InteractionJoint3D("left_foot"),rightFoot=new InteractionJoint3D("right_foot");
  InteractionHandPose3D leftPose=new InteractionHandPose3D(),rightPose=new InteractionHandPose3D();float leftOpenness=0.5f,rightOpenness=0.5f;float lowerBodyConfidence=0;
  boolean torsoTracked(){return chest.tracked()&&leftShoulder.tracked()&&rightShoulder.tracked()&&spine.tracked();}
  boolean leftHandTracked(){return leftHand.tracked();}boolean rightHandTracked(){return rightHand.tracked();}
  boolean interactionTracked(){return tracked&&torsoTracked()&&(leftHandTracked()||rightHandTracked())&&interactionConfidence>0;}
  InteractionJoint3D[] nui20(){return new InteractionJoint3D[]{pelvis,spine,neck,head,leftShoulder,leftElbow,leftWrist,leftHand,rightShoulder,rightElbow,rightWrist,rightHand,leftHip,leftKnee,leftAnkle,leftFoot,rightHip,rightKnee,rightAnkle,rightFoot};}
}
class NuiSkeletonPublisher {
  static final int MAGIC=0x49554E52,FRAME_MAGIC=0x46554E52,VERSION=1,ROLE_PUBLISH=2,JOINTS=20,MAX_SKELETONS=6,REPLY_BYTES=20,FRAME_BYTES=2528;
  LocalTransport transport;long retryAfterMs=0;
  boolean supported(){return studio.services.transportFactory.isLinux()||studio.services.transportFactory.isWindows();}
  void ensureConnected()throws IOException{
    if(transport!=null)return;long now=millis64();if(now<retryAfterMs)throw new IOException("NUI skeleton publisher backoff");
    LocalTransport next=null;
    try{
      next=studio.services.transportFactory.open(studio.services.endpoints.skeleton.windowsPath,studio.services.endpoints.skeleton.linuxPath);
      ByteBuffer hello=ByteBuffer.allocate(80).order(ByteOrder.LITTLE_ENDIAN);hello.putInt(MAGIC).putInt(VERSION).putInt(ROLE_PUBLISH).putInt(0);putFixedDeviceId(hello,selectedKinectDeviceId());next.write(hello.array());
      byte[] rb=new byte[REPLY_BYTES];next.readFully(rb);ByteBuffer reply=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
      int magic=reply.getInt(),version=reply.getInt(),result=reply.getInt(),joints=reply.getInt(),maxSkeletons=reply.getInt();
      if(magic!=MAGIC||version!=VERSION||result<0||joints!=JOINTS||maxSkeletons<1)throw new IOException("NUI skeleton publisher rejected: "+result);
      transport=next;next=null;
    }finally{if(next!=null)try{next.close();}catch(IOException ignored){}}
  }
  void publish(InteractionSkeleton3D skeleton,long frameNumber){
    if(!supported())return;
    try{
      ensureConnected();ByteBuffer b=ByteBuffer.allocate(FRAME_BYTES).order(ByteOrder.LITTLE_ENDIAN);
      boolean present=skeleton!=null&&skeleton.trackingId!=0;int bodyCount=present?1:0;
      b.putInt(FRAME_MAGIC).putInt(VERSION).putInt(bodyCount).putInt(0).putLong(frameNumber).putLong(millis64());
      for(int body=0;body<MAX_SKELETONS;body++){
        if(body==0&&present){
          b.putLong(skeleton.trackingId).putInt(skeleton.tracked?2:1).putInt(0);InteractionJoint3D[] joints=skeleton.nui20();
          for(int j=0;j<JOINTS;j++){InteractionJoint3D q=j<joints.length?joints[j]:null;if(q!=null){b.putFloat(q.world.x).putFloat(q.world.y).putFloat(q.world.z).putFloat(q.confidence).putInt(constrain(q.state,0,2));}else putEmptyJoint(b);}
        }else{b.putLong(0).putInt(0).putInt(0);for(int j=0;j<JOINTS;j++)putEmptyJoint(b);}
      }
      transport.write(b.array());
    }catch(IOException e){close();retryAfterMs=millis64()+750;}
  }
  void putEmptyJoint(ByteBuffer b){b.putFloat(0).putFloat(0).putFloat(0).putFloat(0).putInt(0);}
  void close(){if(transport!=null){try{transport.close();}catch(IOException ignored){}transport=null;}}
}

class InteractionCalibration3D {
  final Calibration sharedCalibration;final RgbDepthRegistration sharedRegistration;
  InteractionCalibration3D(Calibration cal,RgbDepthRegistration reg){sharedCalibration=cal;sharedRegistration=reg;}
  PVector deproject(int u,int v,int mm){int uu=constrain(u,0,studio.services.scannerProtocol.WIDTH-1),vv=constrain(v,0,studio.services.scannerProtocol.HEIGHT-1),i=vv*studio.services.scannerProtocol.WIDTH+uu;float z=mm*sharedCalibration.depthScale;return new PVector(sharedRegistration.pointX(i,z),sharedRegistration.pointY(i,z),z);}
  PVector projectRgb(int u,int v,int mm){int uu=constrain(u,0,studio.services.scannerProtocol.WIDTH-1),vv=constrain(v,0,studio.services.scannerProtocol.HEIGHT-1),i=vv*studio.services.scannerProtocol.WIDTH+uu;float z=mm*sharedCalibration.depthScale;RgbProjection q=new RgbProjection();sharedRegistration.project(i,z,q,0,0);return q.valid?new PVector(q.u,q.v):null;}
  PVector projectDepth(PVector world){if(world==null||world.z<=0.001f)return null;return new PVector(sharedCalibration.fx*world.x/world.z+sharedCalibration.cx,sharedCalibration.fy*world.y/world.z+sharedCalibration.cy);}
  PVector projectWorldRgb(PVector world){PVector d=projectDepth(world);if(d==null)return null;int mm=round(world.z/max(1e-9f,sharedCalibration.depthScale));return projectRgb(round(d.x),round(d.y),mm);}
}

class InteractionBodyPoint {
  float x,y,confidence;boolean valid;
  InteractionBodyPoint(){}
  InteractionBodyPoint(float x,float y,float q){this.x=x;this.y=y;confidence=q;valid=true;}
}

// NUI20 Kinematic Fusion is the body model. It estimates a metric-depth person
// component, follows articulated limb paths through the silhouette, projects accepted
// landmarks into calibrated 3D, and then applies temporal and anthropometric constraints.
// The public topology is the Kinect v1/NUI 20-joint order. The upper neck/shoulder
// anchor supplies NUI ShoulderCenter; the lower chest estimate remains internal.
class NuiDepthBodyMask {
  final int width,height,step,gridW,gridH;final boolean[] mask;final int[] mm,clearance;
  int minGX=0,maxGX=0,minGY=0,maxGY=0,samples=0,seedDepthMm=0;float confidence=0,centerX=0,centerY=0;
  NuiDepthBodyMask(int w,int h,int s){width=w;height=h;step=s;gridW=(w+s-1)/s;gridH=(h+s-1)/s;mask=new boolean[gridW*gridH];mm=new int[gridW*gridH];clearance=new int[gridW*gridH];}
  int px(int gx){return constrain(gx*step+step/2,0,width-1);}int py(int gy){return constrain(gy*step+step/2,0,height-1);}
}

class NuiDepthPersonSegmenter {
  final InteractionConfig cfg;NuiDepthPersonSegmenter(InteractionConfig c){cfg=c;}
  NuiDepthBodyMask segment(DepthFrame depth,PVector priorCenter,float priorDepthM){
    int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT,step=max(2,cfg.bodySampleStep);
    if(depth==null||depth.depth==null||depth.depth.length<w*h)return null;
    NuiDepthBodyMask out=new NuiDepthBodyMask(w,h,step);
    int bins=max(1,(cfg.maxDepthMm-cfg.minDepthMm+cfg.bodyDepthBinMm-1)/cfg.bodyDepthBinMm);int[] hist=new int[bins],central=new int[bins];
    for(int gy=0;gy<out.gridH;gy++)for(int gx=0;gx<out.gridW;gx++){
      int x=out.px(gx),y=out.py(gy),mm=depth.depth[y*w+x]&0xffff,idx=gy*out.gridW+gx;out.mm[idx]=mm;
      if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm)continue;int b=constrain((mm-cfg.minDepthMm)/cfg.bodyDepthBinMm,0,bins-1);hist[b]++;
      if(x>=w*.16f&&x<=w*.84f&&y>=h*.06f&&y<=h*.96f)central[b]++;
    }
    // Multi-hypothesis depth segmentation: keep several strong depth modes instead
    // of committing the entire tracker to the single largest histogram peak. This
    // keeps the same person through partial occlusion and prevents a nearer bystander
    // from stealing identity merely because they occupy more depth pixels.
    double[] binScore=new double[bins];Arrays.fill(binScore,-Double.MAX_VALUE);
    for(int b=0;b<bins;b++){
      if(hist[b]<max(16,cfg.bodyMinSamples/3))continue;double z=(cfg.minDepthMm+(b+.5)*cfg.bodyDepthBinMm)/1000.0;double centerRatio=central[b]/(double)max(1,hist[b]);double capped=min(hist[b],cfg.bodyHistogramCapSamples);double temporalDepth=priorDepthM>0?Math.exp(-Math.abs(z-priorDepthM)/max(.05f,cfg.bodyTemporalDepthM)):0;binScore[b]=capped*(1.0+cfg.bodyCenterBias*centerRatio)*(1.0+.95*temporalDepth)/(z*z);
    }
    int keep=min(cfg.bodyDepthHypotheses,bins),minSep=max(1,round(180.0f/max(1,cfg.bodyDepthBinMm)));int[] peaks=new int[keep];Arrays.fill(peaks,-1);boolean[] suppressed=new boolean[bins];int peakCount=0;
    for(int k=0;k<keep;k++){int best=-1;double score=-Double.MAX_VALUE;for(int b=0;b<bins;b++)if(!suppressed[b]&&binScore[b]>score){score=binScore[b];best=b;}if(best<0||score==-Double.MAX_VALUE)break;peaks[peakCount++]=best;for(int b=max(0,best-minSep);b<=min(bins-1,best+minSep);b++)suppressed[b]=true;}
    if(peakCount==0)return null;
    boolean[] candidate=new boolean[out.mask.length];
    for(int i=0;i<candidate.length;i++){int mm=out.mm[i];if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm)continue;for(int k=0;k<peakCount;k++){int seed=cfg.minDepthMm+peaks[k]*cfg.bodyDepthBinMm+cfg.bodyDepthBinMm/2;if(abs(mm-seed)<=cfg.bodyDepthBandMm){candidate[i]=true;break;}}}
    int[] labels=new int[candidate.length];Arrays.fill(labels,-1);int component=0,bestId=-1,bestCount=0,bestDepthMm=0;double bestComponentScore=-1;int[] queue=new int[candidate.length];
    for(int seed=0;seed<candidate.length;seed++){
      if(!candidate[seed]||labels[seed]>=0)continue;int qh=0,qt=0;queue[qt++]=seed;labels[seed]=component;int count=0,minGX=out.gridW,minGY=out.gridH,maxGX=-1,maxGY=-1;long sumX=0,sumY=0,sumD=0;int centerCount=0;
      while(qh<qt){int at=queue[qh++],gx=at%out.gridW,gy=at/out.gridW,dm=out.mm[at];count++;minGX=min(minGX,gx);maxGX=max(maxGX,gx);minGY=min(minGY,gy);maxGY=max(maxGY,gy);sumX+=out.px(gx);sumY+=out.py(gy);sumD+=dm;if(out.px(gx)>=w*.20f&&out.px(gx)<=w*.80f)centerCount++;
        for(int oy=-1;oy<=1;oy++)for(int ox=-1;ox<=1;ox++){if(ox==0&&oy==0)continue;int nx=gx+ox,ny=gy+oy;if(nx<0||ny<0||nx>=out.gridW||ny>=out.gridH)continue;int ni=ny*out.gridW+nx;if(!candidate[ni]||labels[ni]>=0)continue;int nd=out.mm[ni];if(abs(nd-dm)>cfg.bodyContinuityMm)continue;labels[ni]=component;queue[qt++]=ni;}
      }
      int bw=(maxGX-minGX+1)*step,bh=(maxGY-minGY+1)*step;float aspect=bh/(float)max(1,bw),widthRatio=bw/(float)w,centerRatio=centerCount/(float)max(1,count),meanDepth=(float)(sumD/(double)max(1,count));
      if(count>=cfg.bodyMinSamples&&bh>=cfg.bodyMinHeightPx&&widthRatio<=cfg.bodyMaxWidthRatio&&aspect>=cfg.bodyMinAspect){
        float cx=sumX/(float)count,cy=sumY/(float)count;double temporal=0;if(priorCenter!=null&&priorDepthM>0){double centerD=Math.hypot(cx-priorCenter.x,cy-priorCenter.y);double depthD=Math.abs(meanDepth/1000.0-priorDepthM);temporal=Math.exp(-centerD/Math.max(10.0,(double)cfg.bodyTemporalCenterPx))*Math.exp(-depthD/Math.max(.05,(double)cfg.bodyTemporalDepthM));}
        double hypothesis=0;for(int k=0;k<peakCount;k++){int seedMm=cfg.minDepthMm+peaks[k]*cfg.bodyDepthBinMm+cfg.bodyDepthBinMm/2;hypothesis=max((float)hypothesis,(float)Math.exp(-Math.abs(meanDepth-seedMm)/max(80.0f,cfg.bodyDepthBandMm*.55f)));}
        double score=count*(.70+.60*centerRatio)*(1.0+min(1.5f,aspect)*.20)*(1.0+2.35*temporal)*(.82+.18*hypothesis)/(max(.55f,meanDepth/1000.0f));if(priorCenter!=null&&priorDepthM>0&&temporal<.045)score*=.42;
        if(score>bestComponentScore){bestComponentScore=score;bestId=component;bestCount=count;bestDepthMm=round(meanDepth);out.minGX=minGX;out.maxGX=maxGX;out.minGY=minGY;out.maxGY=maxGY;out.centerX=cx;out.centerY=cy;}
      }
      component++;
    }
    if(bestId<0)return null;for(int i=0;i<labels.length;i++)out.mask[i]=labels[i]==bestId;out.samples=bestCount;out.seedDepthMm=bestDepthMm;computeClearance(out);
    int bh=(out.maxGY-out.minGY+1)*step,bw=(out.maxGX-out.minGX+1)*step;float sizeScore=constrain(bestCount/(float)max(cfg.bodyMinSamples*4,1),0,1),shape=constrain((bh/(float)max(1,bw)-cfg.bodyMinAspect)/1.4f+.45f,.25f,1);out.confidence=constrain(.38f+.40f*sizeScore+.22f*shape,0,1);return out;
  }
  void computeClearance(NuiDepthBodyMask b){int inf=1<<20;Arrays.fill(b.clearance,inf);for(int gy=b.minGY;gy<=b.maxGY;gy++)for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i]){b.clearance[i]=0;continue;}boolean edge=gx==0||gy==0||gx==b.gridW-1||gy==b.gridH-1;if(!edge){edge=!b.mask[i-1]||!b.mask[i+1]||!b.mask[i-b.gridW]||!b.mask[i+b.gridW];}if(edge)b.clearance[i]=3;}for(int gy=b.minGY;gy<=b.maxGY;gy++)for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;int v=b.clearance[i];if(gx>0)v=min(v,b.clearance[i-1]+3);if(gy>0)v=min(v,b.clearance[i-b.gridW]+3);if(gx>0&&gy>0)v=min(v,b.clearance[i-b.gridW-1]+4);if(gx+1<b.gridW&&gy>0)v=min(v,b.clearance[i-b.gridW+1]+4);b.clearance[i]=v;}for(int gy=b.maxGY;gy>=b.minGY;gy--)for(int gx=b.maxGX;gx>=b.minGX;gx--){int i=gy*b.gridW+gx;if(!b.mask[i])continue;int v=b.clearance[i];if(gx+1<b.gridW)v=min(v,b.clearance[i+1]+3);if(gy+1<b.gridH)v=min(v,b.clearance[i+b.gridW]+3);if(gx+1<b.gridW&&gy+1<b.gridH)v=min(v,b.clearance[i+b.gridW+1]+4);if(gx>0&&gy+1<b.gridH)v=min(v,b.clearance[i+b.gridW-1]+4);b.clearance[i]=v;}}
}

class InteractionJointFilterState {
  PVector raw=new PVector(),world=new PVector(),velocity=new PVector(),image=new PVector();long tickMs=0;int missing=0;boolean initialized=false;
}
class InteractionPoseFilter {
  final InteractionConfig cfg;final HashMap<String,InteractionJointFilterState> states=new HashMap<String,InteractionJointFilterState>();
  InteractionPoseFilter(InteractionConfig c){cfg=c;}void reset(){states.clear();}
  InteractionJoint3D[] joints(InteractionSkeleton3D s){return new InteractionJoint3D[]{s.head,s.neck,s.chest,s.spine,s.pelvis,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot};}
  void apply(InteractionSkeleton3D s,long tickMs,InteractionCalibration3D cal){for(InteractionJoint3D j:joints(s))filter(j,tickMs,cal);}
  // Biomechanical projection runs after the adaptive filter. Commit only fully
  // observed joints back into the temporal state so the next frame predicts
  // from the pose that was actually published, not from pre-projection geometry.
  void commitMeasured(InteractionSkeleton3D s,long tickMs){for(InteractionJoint3D j:joints(s)){if(j==null||j.state!=2||j.world.z<=0)continue;InteractionJointFilterState st=states.get(j.name);if(st==null){st=new InteractionJointFilterState();states.put(j.name,st);}st.initialized=true;st.raw.set(j.world);st.world.set(j.world);st.image.set(clampUv(j.image));st.tickMs=tickMs;st.missing=0;st.velocity.mult(.90f);}}
  float alpha(float dt,float cutoff){float safe=max(.001f,cutoff),tau=1.0f/(TWO_PI*safe);return 1.0f/(1.0f+tau/max(.001f,dt));}
  void filter(InteractionJoint3D j,long tickMs,InteractionCalibration3D cal){
    if(j==null)return;InteractionJointFilterState st=states.get(j.name);if(st==null){st=new InteractionJointFilterState();states.put(j.name,st);}
    if(j.tracked()&&j.world.z>0){
      if(!st.initialized){st.raw.set(j.world);st.world.set(j.world);st.image.set(clampUv(j.image));st.tickMs=tickMs;st.initialized=true;st.missing=0;j.image.set(st.image);return;}
      float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f);PVector predicted=PVector.add(st.world,PVector.mult(st.velocity,dt));float innovation=PVector.dist(predicted,j.world),gate=max(cfg.poseInnovationGateM,cfg.poseMaxSpeedMps*dt*1.35f);if(innovation>gate){PVector delta=PVector.sub(j.world,predicted);if(delta.mag()>0)delta.setMag(gate);j.world.set(PVector.add(predicted,delta));j.confidence*=constrain(gate/max(innovation,.001f),.35f,1);}
      float residual=PVector.dist(st.world,j.world);if(residual<cfg.poseJitterRadiusM){float blend=constrain(residual/max(cfg.poseJitterRadiusM,.001f),0,1);j.world.set(PVector.lerp(st.world,j.world,.18f+.32f*blend));}
      PVector rawVelocity=PVector.sub(j.world,st.raw);rawVelocity.div(dt);float da=constrain(alpha(dt,cfg.poseOneEuroDerivativeCutoff)*.55f+cfg.poseVelocityAlpha*.45f,.02f,.9f);st.velocity=PVector.lerp(st.velocity,rawVelocity,da);if(st.velocity.mag()>cfg.poseMaxSpeedMps)st.velocity.mult(cfg.poseMaxSpeedMps/st.velocity.mag());
      float cutoff=cfg.poseOneEuroMinCutoff+cfg.poseOneEuroBeta*st.velocity.mag();float a=alpha(dt,cutoff);float confidenceGain=lerp(.55f,1.0f,constrain(j.confidence,0,1));a=constrain(a*confidenceGain,cfg.poseFilterMinAlpha,cfg.poseFilterMaxAlpha);
      st.raw.set(j.world);st.world=PVector.lerp(st.world,j.world,a);PVector uv=cal.projectWorldRgb(st.world);st.image.set(clampUv(uv!=null?uv:j.image));st.tickMs=tickMs;st.missing=0;j.world.set(st.world);j.image.set(st.image);
    }else if(st.initialized&&st.missing<cfg.poseOcclusionHoldFrames){
      st.missing++;float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f);st.velocity.mult(.88f);PVector predicted=PVector.add(st.world,PVector.mult(st.velocity,dt));PVector uv=cal.projectWorldRgb(predicted);
      if(uv!=null&&inside(uv)){st.world.set(predicted);st.raw.set(predicted);st.image.set(clampUv(uv));st.tickMs=tickMs;j.world.set(st.world);j.image.set(st.image);j.confidence=max(.08f,.38f*(1-st.missing/(float)(cfg.poseOcclusionHoldFrames+1)));j.state=1;}
    }else st.missing++;
  }
  boolean inside(PVector p){return p.x>=0&&p.x<studio.services.scannerProtocol.WIDTH&&p.y>=0&&p.y<studio.services.scannerProtocol.HEIGHT;}
  PVector clampUv(PVector p){if(p==null)return new PVector();return new PVector(constrain(p.x,0,studio.services.scannerProtocol.WIDTH-1),constrain(p.y,0,studio.services.scannerProtocol.HEIGHT-1));}
}

class InteractionHandAnalyzer {
  final InteractionConfig cfg;final InteractionCalibration3D cal;
  InteractionHandAnalyzer(InteractionConfig c,InteractionCalibration3D calibration){cfg=c;cal=calibration;}
  class HandCandidate {int x,y,mm;float radius,angle,forward;HandCandidate(int px,int py,int d,float r,float a,float f){x=px;y=py;mm=d;radius=r;angle=a;forward=f;}}
  InteractionHandPose3D analyze(InteractionJoint3D hand,InteractionJoint3D elbow,DepthFrame depth){
    InteractionHandPose3D p=new InteractionHandPose3D();
    if(hand==null||!hand.tracked()||hand.world.z<=0||depth==null||depth.depth==null)return p;
    PVector dp=cal.projectDepth(hand.world);if(dp==null)return p;
    int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT,cx=round(dp.x),cy=round(dp.y),center=depthAt(depth,cx,cy);
    if(center<=0)return p;
    p.tracked=true;p.wrist=copy("wrist",hand);p.confidence=hand.confidence;
    PVector ep=elbow!=null&&elbow.tracked()?cal.projectDepth(elbow.world):null;
    float ox=ep==null?0:cx-ep.x,oy=ep==null?-1:cy-ep.y,olen=sqrt(ox*ox+oy*oy);if(olen<1){ox=0;oy=-1;olen=1;}ox/=olen;oy/=olen;

    int r=max(cfg.handLocalRadiusPx,12),tol=max(55,cfg.handDepthToleranceMm);double sx=0,sy=0,sd=0,sw=0;int samples=0;
    for(int y=max(0,cy-r);y<=min(h-1,cy+r);y+=2)for(int x=max(0,cx-r);x<=min(w-1,cx+r);x+=2){
      int d=depthAt(depth,x,y);if(d<=0||abs(d-center)>tol)continue;float rr=dist(cx,cy,x,y);if(rr>r*1.35f)continue;
      float weight=(float)Math.exp(-(rr*rr)/(2.0f*max(36.0f,r*r*.52f)));sx+=x*weight;sy+=y*weight;sd+=d*weight;sw+=weight;samples++;
    }
    float pcx=sw>0?(float)(sx/sw):cx,pcy=sw>0?(float)(sy/sw):cy;int palmMm=sw>0?round((float)(sd/sw)):center;
    PVector palmImage=cal.projectRgb(round(pcx),round(pcy),palmMm);if(palmImage==null)palmImage=hand.image.copy();
    p.palm=new InteractionJoint3D("palm").set(palmImage,cal.deproject(round(pcx),round(pcy),palmMm),hand.confidence,2);

    ArrayList<HandCandidate> candidates=new ArrayList<HandCandidate>();float maxR=0;
    int scan=max(r+8,round(r*1.35f));
    for(int y=max(0,round(pcy)-scan);y<=min(h-1,round(pcy)+scan);y+=2)for(int x=max(0,round(pcx)-scan);x<=min(w-1,round(pcx)+scan);x+=2){
      int d=depthAt(depth,x,y);if(d<=0||abs(d-palmMm)>tol)continue;float dx=x-pcx,dy=y-pcy,rr=sqrt(dx*dx+dy*dy);if(rr>scan||rr<max(5,cfg.handOpenRadiusMinPx*.45f))continue;
      float forward=(dx*ox+dy*oy)/max(rr,.001f);if(forward<-.32f)continue;
      maxR=max(maxR,rr);float a=atan2(dy,dx);candidates.add(new HandCandidate(x,y,d,rr,a,forward));
    }
    p.palmRadiusPx=maxR;
    Collections.sort(candidates,new Comparator<HandCandidate>(){public int compare(HandCandidate a,HandCandidate b){return Float.compare(b.radius,a.radius);}});
    ArrayList<HandCandidate> tips=new ArrayList<HandCandidate>();
    float minReach=max(cfg.handOpenRadiusMinPx*.78f,maxR*.62f);
    for(HandCandidate c:candidates){
      if(c.radius<minReach)break;boolean separated=true;
      for(HandCandidate t:tips){float da=abs(c.angle-t.angle);da=min(da,TWO_PI-da);if(da<.34f||dist(c.x,c.y,t.x,t.y)<7.5f){separated=false;break;}}
      if(separated){tips.add(c);if(tips.size()>=5)break;}
    }
    Collections.sort(tips,new Comparator<HandCandidate>(){public int compare(HandCandidate a,HandCandidate b){return Float.compare(a.angle,b.angle);}});
    p.fingerCount=tips.size();
    for(int i=0;i<tips.size()&&i<p.fingers.length;i++){
      HandCandidate c=tips.get(i);PVector tipImg=cal.projectRgb(c.x,c.y,c.mm);if(tipImg==null)tipImg=new PVector(c.x,c.y);
      InteractionFinger3D f=p.fingers[i];float fq=hand.confidence*constrain(.58f+.42f*c.forward,.45f,1);
      f.tip.set(tipImg,cal.deproject(c.x,c.y,c.mm),fq,2);
      PVector bw=PVector.lerp(p.palm.world,f.tip.world,.43f),bi=cal.projectWorldRgb(bw);if(bi==null)bi=PVector.lerp(p.palm.image,f.tip.image,.43f);
      f.base.set(bi,bw,fq*.92f,1);f.confidence=fq;
    }
    float radiusOpen=constrain(map(maxR,cfg.handOpenRadiusMinPx,cfg.handOpenRadiusMaxPx,0,1),0,1),fingerOpen=constrain(p.fingerCount/5.0f,0,1);
    p.openness=constrain(radiusOpen*.66f+fingerOpen*.34f,0,1);p.grabStrength=1-p.openness;
    if(tips.size()>=2){
      float closest=Float.MAX_VALUE;
      for(int i=0;i<tips.size();i++)for(int j=i+1;j<tips.size();j++)closest=min(closest,dist(tips.get(i).x,tips.get(i).y,tips.get(j).x,tips.get(j).y));
      p.pinchStrength=constrain(1.0f-map(closest,4,18,0,1),0,1)*(1.0f-p.grabStrength*.45f);
    }
    p.confidence*=constrain(samples/30.0f,.45f,1.0f);
    return p;
  }
  int depthAt(DepthFrame d,int x,int y){if(x<0||y<0||x>=studio.services.scannerProtocol.WIDTH||y>=studio.services.scannerProtocol.HEIGHT)return 0;return d.depth[y*studio.services.scannerProtocol.WIDTH+x]&0xffff;}
  InteractionJoint3D copy(String name,InteractionJoint3D src){return new InteractionJoint3D(name).set(src.image.copy(),src.world.copy(),src.confidence,src.state);}
}

class NuiGraphNode implements Comparable<NuiGraphNode> {
  final int index;final float distance;NuiGraphNode(int i,float d){index=i;distance=d;}
  public int compareTo(NuiGraphNode other){return Float.compare(distance,other.distance);}
}
class NuiLimbPath {
  int[] nodes=new int[0];float[] cumulative=new float[0];float lengthPx=0,confidence=0;boolean valid(){return nodes!=null&&nodes.length>=2&&cumulative!=null&&cumulative.length==nodes.length;}
  InteractionBodyPoint at(NuiDepthBodyMask b,float t,float q){if(!valid())return new InteractionBodyPoint();float target=constrain(t,0,1)*lengthPx;int k=0;while(k+1<cumulative.length&&cumulative[k+1]<target)k++;if(k+1>=nodes.length){int idx=nodes[nodes.length-1];return new InteractionBodyPoint(b.px(idx%b.gridW),b.py(idx/b.gridW),q*confidence);}int ia=nodes[k],ib=nodes[k+1];float a=cumulative[k],z=cumulative[k+1],u=z>a?constrain((target-a)/(z-a),0,1):0;return new InteractionBodyPoint(lerp(b.px(ia%b.gridW),b.px(ib%b.gridW),u),lerp(b.py(ia/b.gridW),b.py(ib/b.gridW),u),q*confidence);}
  InteractionBodyPoint end(NuiDepthBodyMask b,float q){return at(b,1.0f,q);}
}

class NuiAnthropometricModel {
  final InteractionConfig cfg;final HashMap<String,Float> lengths=new HashMap<String,Float>();final HashMap<String,PVector> directions=new HashMap<String,PVector>();
  NuiAnthropometricModel(InteractionConfig c){cfg=c;}void reset(){lengths.clear();directions.clear();}
  float learned(String key,float observed){Float old=lengths.get(key);if(old==null){lengths.put(key,observed);return observed;}float next=lerp(old,observed,cfg.poseBoneLearnAlpha);lengths.put(key,next);return next;}
  float reliable(InteractionJoint3D a,InteractionJoint3D b){return a!=null&&b!=null&&a.state==2&&b.state==2&&a.confidence>=.58f&&b.confidence>=.58f?PVector.dist(a.world,b.world):Float.NaN;}
  float symmetric(String key,InteractionJoint3D la,InteractionJoint3D lb,InteractionJoint3D ra,InteractionJoint3D rb){float l=reliable(la,lb),r=reliable(ra,rb),v=Float.NaN;if(Float.isFinite(l)&&Float.isFinite(r))v=(l+r)*.5f;else if(Float.isFinite(l))v=l;else if(Float.isFinite(r))v=r;return Float.isFinite(v)?learned(key,v):(lengths.containsKey(key)?lengths.get(key):Float.NaN);}
  float pairLength(String key,InteractionJoint3D a,InteractionJoint3D b){float v=reliable(a,b);return Float.isFinite(v)?learned(key,v):(lengths.containsKey(key)?lengths.get(key):Float.NaN);}
  void stabilize(InteractionSkeleton3D s,InteractionCalibration3D cal){
    float shoulderWidth=pairLength("shoulder_width",s.leftShoulder,s.rightShoulder),hipWidth=pairLength("hip_width",s.leftHip,s.rightHip);
    correctPair(s.leftShoulder,s.rightShoulder,shoulderWidth,cal);correctPair(s.leftHip,s.rightHip,hipWidth,cal);
    float ua=symmetric("upper_arm",s.leftShoulder,s.leftElbow,s.rightShoulder,s.rightElbow),fa=symmetric("forearm",s.leftElbow,s.leftWrist,s.rightElbow,s.rightWrist),th=symmetric("thigh",s.leftHip,s.leftKnee,s.rightHip,s.rightKnee),sh=symmetric("shin",s.leftKnee,s.leftAnkle,s.rightKnee,s.rightAnkle);
    correct(s.leftShoulder,s.leftElbow,"lua",ua,cal);correct(s.rightShoulder,s.rightElbow,"rua",ua,cal);correct(s.leftElbow,s.leftWrist,"lfa",fa,cal);correct(s.rightElbow,s.rightWrist,"rfa",fa,cal);correct(s.leftHip,s.leftKnee,"lth",th,cal);correct(s.rightHip,s.rightKnee,"rth",th,cal);correct(s.leftKnee,s.leftAnkle,"lsh",sh,cal);correct(s.rightKnee,s.rightAnkle,"rsh",sh,cal);
    float handTarget=lengths.containsKey("hand")?lengths.get("hand"):Float.NaN;correct(s.leftWrist,s.leftHand,"lh",handTarget,cal);correct(s.rightWrist,s.rightHand,"rh",handTarget,cal);float handL=reliable(s.leftWrist,s.leftHand),handR=reliable(s.rightWrist,s.rightHand);if(Float.isFinite(handL)||Float.isFinite(handR)){float hv=Float.isFinite(handL)&&Float.isFinite(handR)?(handL+handR)*.5f:(Float.isFinite(handL)?handL:handR);learned("hand",hv);}
  }
  void correctPair(InteractionJoint3D a,InteractionJoint3D b,float target,InteractionCalibration3D cal){if(a==null||b==null||!a.tracked()||!b.tracked()||!Float.isFinite(target)||target<.04f)return;PVector v=PVector.sub(b.world,a.world);float d=v.mag();if(d<.001f)return;float err=abs(d-target)/target;if(err<.045f)return;v.div(d);PVector mid=PVector.add(a.world,b.world).mult(.5f),half=PVector.mult(v,target*.5f);PVector da=PVector.sub(mid,half),db=PVector.add(mid,half);float confidence=min(a.confidence,b.confidence),strength=constrain(cfg.poseBoneCorrection*.48f*lerp(.45f,1.0f,1-constrain(confidence,0,1)),.08f,.42f);a.world.set(PVector.lerp(a.world,da,strength));b.world.set(PVector.lerp(b.world,db,strength));PVector ua=cal.projectWorldRgb(a.world),ub=cal.projectWorldRgb(b.world);if(ua!=null)a.image.set(ua);if(ub!=null)b.image.set(ub);}
  void correct(InteractionJoint3D parent,InteractionJoint3D child,String dirKey,float target,InteractionCalibration3D cal){if(parent==null||child==null||!parent.tracked()||!child.tracked()||!Float.isFinite(target)||target<.025f)return;PVector v=PVector.sub(child.world,parent.world);float d=v.mag();if(d<.001f)return;v.div(d);PVector prior=directions.get(dirKey);if(prior!=null&&child.confidence<.82f){float dot=constrain(PVector.dot(prior,v),-1,1),angle=degrees(acos(dot));if(angle>cfg.poseMaxDirectionJumpDeg){float t=constrain(cfg.poseMaxDirectionJumpDeg/max(angle,.001f),0,1);v=PVector.lerp(prior,v,t);if(v.mag()>0)v.normalize();child.confidence*=.88f;}}directions.put(dirKey,v.copy());float err=abs(d-target)/target;if(err>.07f){float strength=cfg.poseBoneCorrection*lerp(.38f,1.0f,1-constrain(child.confidence,0,1));PVector desired=PVector.add(parent.world,PVector.mult(v,target));child.world.set(PVector.lerp(child.world,desired,constrain(strength,.12f,cfg.poseBoneCorrection)));PVector uv=cal.projectWorldRgb(child.world);if(uv!=null)child.image.set(uv);}}
}

class Nui20SkeletonTracker {
  static final int LIMB_ARM=1,LIMB_LEG=2;
  final InteractionConfig cfg;final InteractionCalibration3D cal;final NuiDepthPersonSegmenter estimator;final InteractionPoseFilter poseFilter;final InteractionHandAnalyzer handAnalyzer;final NuiAnthropometricModel biomechanics;InteractionSkeleton3D previous;int identityMissFrames=0;long activeTrackingId=0,nextTrackingId=1;volatile String lastReason="searching";
  Nui20SkeletonTracker(InteractionConfig c,Calibration calibration,RgbDepthRegistration registration){cfg=c;cal=new InteractionCalibration3D(calibration,registration);estimator=new NuiDepthPersonSegmenter(c);poseFilter=new InteractionPoseFilter(c);handAnalyzer=new InteractionHandAnalyzer(c,cal);biomechanics=new NuiAnthropometricModel(c);}
  void reset(){previous=null;identityMissFrames=0;activeTrackingId=0;poseFilter.reset();biomechanics.reset();lastReason="searching";}
  InteractionSkeleton3D track(InteractionVisionSnapshot f){
    InteractionSkeleton3D s=new InteractionSkeleton3D();long tick=f==null?millis64():Math.max(f.rgbTickMs,f.depthTickMs);if(f==null||f.depthFrame==null||f.depthFrame.depth==null)return predictedSkeleton(s,tick,"no_rgbd");PVector priorCenter=previous!=null&&previous.chest.tracked()?cal.projectDepth(previous.chest.world):null;float priorDepth=previous==null?0:previous.meanDepthM;NuiDepthBodyMask body=estimator.segment(f.depthFrame,priorCenter,priorDepth);if(body==null)return predictedSkeleton(s,tick,"no_person");
    int top=centralTop(body),bottom=body.py(body.maxGY),height=max(1,bottom-top);if(height<cfg.bodyMinHeightPx)return predictedSkeleton(s,tick,"no_person");if(activeTrackingId==0)activeTrackingId=nextTrackingId++;s.trackingId=activeTrackingId;
    float centerX=centerAt(body,round(top+height*.46f),max(8,height/16));if(Float.isNaN(centerX))centerX=body.centerX;float torsoWidth=torsoWidth(body,top,height,centerX);if(torsoWidth<22)return predictedSkeleton(s,tick,"low_confidence");
    float q=body.confidence,shoulderY=landmarkRow(body,top,height,.18f,.39f,.27f,torsoWidth*1.12f),pelvisY=landmarkRow(body,top,height,.48f,.67f,.57f,torsoWidth*.78f);float neckY=narrowRow(body,top,height,.12f,.27f,.195f,torsoWidth*.50f);float headY=top+max(body.step,height*.075f),chestY=lerp(shoulderY,pelvisY,.34f),spineY=lerp(shoulderY,pelvisY,.67f);
    float neckX=centerAt(body,round(neckY),max(6,height/40));if(Float.isNaN(neckX))neckX=centerX;float pelvisX=centerAt(body,round(pelvisY),max(8,height/36));if(Float.isNaN(pelvisX))pelvisX=centerX;float shoulderCenter=centerAt(body,round(shoulderY),max(7,height/42));if(Float.isNaN(shoulderCenter))shoulderCenter=neckX;
    float shoulderHalf=constrain(torsoWidth*.50f,14,studio.services.scannerProtocol.WIDTH*.22f),hipHalf=constrain(torsoWidth*.30f,10,studio.services.scannerProtocol.WIDTH*.16f);
    InteractionBodyPoint head=pointNear(body,centerAtOr(body,round(headY),max(5,height/45),centerX),headY,max(10,height/18),q);
    InteractionBodyPoint neck=pointNear(body,neckX,neckY,max(8,height/24),q),chest=pointNear(body,centerAtOr(body,round(chestY),max(8,height/38),centerX),chestY,max(8,height/25),q),spine=pointNear(body,centerAtOr(body,round(spineY),max(8,height/34),centerX),spineY,max(8,height/24),q),pelvis=pointNear(body,pelvisX,pelvisY,max(10,height/24),q);
    InteractionBodyPoint ls=pointNear(body,shoulderCenter-shoulderHalf,shoulderY,max(12,round(torsoWidth*.32f)),q),rs=pointNear(body,shoulderCenter+shoulderHalf,shoulderY,max(12,round(torsoWidth*.32f)),q);InteractionBodyPoint lh=pointNear(body,pelvisX-hipHalf,pelvisY,max(10,round(torsoWidth*.24f)),q),rh=pointNear(body,pelvisX+hipHalf,pelvisY,max(10,round(torsoWidth*.24f)),q);
    NuiLimbPath leftArm=traceLimb(body,ls,-1,LIMB_ARM,pelvisY,centerX,torsoWidth,previous==null?null:previous.leftHand),rightArm=traceLimb(body,rs,1,LIMB_ARM,pelvisY,centerX,torsoWidth,previous==null?null:previous.rightHand);NuiLimbPath leftLeg=traceLimb(body,lh,-1,LIMB_LEG,pelvisY,centerX,torsoWidth,previous==null?null:previous.leftFoot),rightLeg=traceLimb(body,rh,1,LIMB_LEG,pelvisY,centerX,torsoWidth,previous==null?null:previous.rightFoot);
    float leftArmElbowFrac=learnedFraction(previous==null?null:previous.leftShoulder,previous==null?null:previous.leftElbow,previous==null?null:previous.leftWrist,.49f,.38f,.62f),rightArmElbowFrac=learnedFraction(previous==null?null:previous.rightShoulder,previous==null?null:previous.rightElbow,previous==null?null:previous.rightWrist,.49f,.38f,.62f);
    float leftArmWristFrac=learnedChainFraction(previous==null?null:previous.leftShoulder,previous==null?null:previous.leftElbow,previous==null?null:previous.leftWrist,previous==null?null:previous.leftHand,.86f,.72f,.95f),rightArmWristFrac=learnedChainFraction(previous==null?null:previous.rightShoulder,previous==null?null:previous.rightElbow,previous==null?null:previous.rightWrist,previous==null?null:previous.rightHand,.86f,.72f,.95f);
    float leftLegKneeFrac=learnedFraction(previous==null?null:previous.leftHip,previous==null?null:previous.leftKnee,previous==null?null:previous.leftAnkle,.50f,.40f,.62f),rightLegKneeFrac=learnedFraction(previous==null?null:previous.rightHip,previous==null?null:previous.rightKnee,previous==null?null:previous.rightAnkle,.50f,.40f,.62f);
    float leftLegAnkleFrac=learnedChainFraction(previous==null?null:previous.leftHip,previous==null?null:previous.leftKnee,previous==null?null:previous.leftAnkle,previous==null?null:previous.leftFoot,.86f,.72f,.96f),rightLegAnkleFrac=learnedChainFraction(previous==null?null:previous.rightHip,previous==null?null:previous.rightKnee,previous==null?null:previous.rightAnkle,previous==null?null:previous.rightFoot,.86f,.72f,.96f);
    InteractionBodyPoint lhand=leftArm.valid()?leftArm.end(body,q):armFallback(body,ls,-1,pelvisY,torsoWidth,q),rhand=rightArm.valid()?rightArm.end(body,q):armFallback(body,rs,1,pelvisY,torsoWidth,q);InteractionBodyPoint lel=leftArm.valid()?leftArm.at(body,leftArmElbowFrac,q):betweenOnMask(body,ls,lhand,.52f,max(14,round(torsoWidth*.35f)),q*.76f),rel=rightArm.valid()?rightArm.at(body,rightArmElbowFrac,q):betweenOnMask(body,rs,rhand,.52f,max(14,round(torsoWidth*.35f)),q*.76f);InteractionBodyPoint lw=leftArm.valid()?leftArm.at(body,leftArmWristFrac,q):betweenOnMask(body,ls,lhand,.86f,max(10,round(torsoWidth*.25f)),q*.72f),rw=rightArm.valid()?rightArm.at(body,rightArmWristFrac,q):betweenOnMask(body,rs,rhand,.86f,max(10,round(torsoWidth*.25f)),q*.72f);
    InteractionBodyPoint lf=leftLeg.valid()?leftLeg.end(body,q):legFallback(body,-1,top+height*.975f,pelvisX,torsoWidth,q*.65f),rf=rightLeg.valid()?rightLeg.end(body,q):legFallback(body,1,top+height*.975f,pelvisX,torsoWidth,q*.65f);InteractionBodyPoint lk=leftLeg.valid()?leftLeg.at(body,leftLegKneeFrac,q):legFallback(body,-1,top+height*.755f,pelvisX,torsoWidth,q*.72f),rk=rightLeg.valid()?rightLeg.at(body,rightLegKneeFrac,q):legFallback(body,1,top+height*.755f,pelvisX,torsoWidth,q*.72f),la=leftLeg.valid()?leftLeg.at(body,leftLegAnkleFrac,q):legFallback(body,-1,top+height*.915f,pelvisX,torsoWidth,q*.70f),ra=rightLeg.valid()?rightLeg.at(body,rightLegAnkleFrac,q):legFallback(body,1,top+height*.915f,pelvisX,torsoWidth,q*.70f);
    s.head=joint("head",head,body);s.neck=joint("neck",neck,body);s.chest=joint("chest",chest,body);s.spine=joint("spine",spine,body);s.pelvis=joint("pelvis",pelvis,body);s.leftShoulder=joint("left_shoulder",ls,body);s.rightShoulder=joint("right_shoulder",rs,body);s.leftElbow=joint("left_elbow",lel,body);s.rightElbow=joint("right_elbow",rel,body);s.leftWrist=joint("left_wrist",lw,body);s.rightWrist=joint("right_wrist",rw,body);s.leftHand=joint("left_hand",lhand,body);s.rightHand=joint("right_hand",rhand,body);s.leftHip=joint("left_hip",lh,body);s.rightHip=joint("right_hip",rh,body);s.leftKnee=joint("left_knee",lk,body);s.rightKnee=joint("right_knee",rk,body);s.leftAnkle=joint("left_ankle",la,body);s.rightAnkle=joint("right_ankle",ra,body);s.leftFoot=joint("left_foot",lf,body);s.rightFoot=joint("right_foot",rf,body);
    validateKinematics(s);poseFilter.apply(s,tick,cal);biomechanics.stabilize(s,cal);clampSkeleton(s);poseFilter.commitMeasured(s,tick);s.leftPose=handAnalyzer.analyze(s.leftHand,s.leftElbow,f.depthFrame);s.rightPose=handAnalyzer.analyze(s.rightHand,s.rightElbow,f.depthFrame);s.leftOpenness=s.leftPose.openness;s.rightOpenness=s.rightPose.openness;
    s.torsoConfidence=avgTracked(new InteractionJoint3D[]{s.leftShoulder,s.rightShoulder,s.neck,s.chest,s.spine});float leftArmQ=avgTracked(new InteractionJoint3D[]{s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand}),rightArmQ=avgTracked(new InteractionJoint3D[]{s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand});s.upperBodyConfidence=avgTracked(new InteractionJoint3D[]{s.head,s.neck,s.chest,s.spine,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand});s.interactionConfidence=constrain(.66f*s.torsoConfidence+.34f*max(leftArmQ,rightArmQ),0,1);s.lowerBodyConfidence=avgTracked(new InteractionJoint3D[]{s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot});float jointQ=avgTracked(allJoints(s));s.confidence=constrain(.44f*body.confidence+.38f*s.upperBodyConfidence+.18f*jointQ,0,1);s.tracked=s.torsoConfidence>=cfg.poseMinCoreConfidence&&s.interactionConfidence>=cfg.poseMinCoreConfidence*.96f;s.reason=s.tracked?"tracked":"low_confidence";lastReason=s.reason;
    if(s.tracked){identityMissFrames=0;deriveBounds(s);s.meanDepthM=meanDepth(s);s.faceWidthPx=constrain(torsoWidth*.34f,18,120);s.faceHeightPx=s.faceWidthPx*1.22f;previous=s;}else if(previous!=null&&s.torsoConfidence>=cfg.poseMinCoreConfidence*.78f&&s.interactionConfidence>=cfg.poseMinCoreConfidence*.70f){identityMissFrames=0;s.tracked=true;s.reason="inferred";lastReason=s.reason;deriveBounds(s);s.meanDepthM=meanDepth(s);previous=s;}else{identityMissFrames++;if(identityMissFrames>cfg.poseOcclusionHoldFrames){previous=null;activeTrackingId=0;poseFilter.reset();biomechanics.reset();}}return s;
  }
  InteractionSkeleton3D predictedSkeleton(InteractionSkeleton3D s,long tick,String reason){identityMissFrames++;s.trackingId=activeTrackingId;if(identityMissFrames>cfg.poseOcclusionHoldFrames){previous=null;activeTrackingId=0;poseFilter.reset();biomechanics.reset();s.reason=reason;lastReason=reason;return s;}poseFilter.apply(s,tick,cal);biomechanics.stabilize(s,cal);clampSkeleton(s);s.torsoConfidence=avgTracked(new InteractionJoint3D[]{s.leftShoulder,s.rightShoulder,s.neck,s.chest,s.spine});float leftArmQ=avgTracked(new InteractionJoint3D[]{s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand}),rightArmQ=avgTracked(new InteractionJoint3D[]{s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand});s.upperBodyConfidence=avgTracked(new InteractionJoint3D[]{s.head,s.neck,s.chest,s.spine,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand});s.interactionConfidence=constrain(.66f*s.torsoConfidence+.34f*max(leftArmQ,rightArmQ),0,1);s.lowerBodyConfidence=avgTracked(new InteractionJoint3D[]{s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot});s.confidence=constrain(.82f*s.upperBodyConfidence+.18f*avgTracked(allJoints(s)),0,1);s.tracked=s.torsoConfidence>=cfg.poseMinCoreConfidence*.72f&&s.interactionConfidence>=cfg.poseMinCoreConfidence*.62f;s.reason=s.tracked?"inferred":reason;lastReason=s.reason;if(s.tracked){deriveBounds(s);s.meanDepthM=meanDepth(s);if(previous!=null){s.faceWidthPx=previous.faceWidthPx;s.faceHeightPx=previous.faceHeightPx;s.leftOpenness=previous.leftOpenness;s.rightOpenness=previous.rightOpenness;s.leftPose=previous.leftPose;s.rightPose=previous.rightPose;}}return s;}
  float learnedFraction(InteractionJoint3D a,InteractionJoint3D mid,InteractionJoint3D end,float fallback,float lo,float hi){if(a==null||mid==null||end==null||!a.tracked()||!mid.tracked()||!end.tracked())return fallback;float x=PVector.dist(a.world,mid.world),y=PVector.dist(mid.world,end.world);return x+y>.03f?constrain(x/(x+y),lo,hi):fallback;}
  float learnedChainFraction(InteractionJoint3D a,InteractionJoint3D b,InteractionJoint3D c,InteractionJoint3D d,float fallback,float lo,float hi){if(a==null||b==null||c==null||d==null||!a.tracked()||!b.tracked()||!c.tracked()||!d.tracked())return fallback;float x=PVector.dist(a.world,b.world),y=PVector.dist(b.world,c.world),z=PVector.dist(c.world,d.world),sum=x+y+z;return sum>.03f?constrain((x+y)/sum,lo,hi):fallback;}
  float landmarkRow(NuiDepthBodyMask b,int top,int height,float lo,float hi,float preferred,float targetWidth){float bestY=top+height*preferred,best=-Float.MAX_VALUE;for(int y=round(top+height*lo);y<=round(top+height*hi);y+=max(2,b.step)){int[] span=rowSpan(b,y,max(2,b.step));if(span[2]<2)continue;float width=span[1]-span[0]+b.step,widthScore=1.0f-abs(width-targetWidth)/max(12,targetWidth),prior=1.0f-abs(y-(top+height*preferred))/max(1,height*(hi-lo));float score=widthScore*.72f+prior*.28f;if(score>best){best=score;bestY=y;}}return bestY;}
  float narrowRow(NuiDepthBodyMask b,int top,int height,float lo,float hi,float preferred,float targetWidth){float bestY=top+height*preferred,best=-Float.MAX_VALUE;for(int y=round(top+height*lo);y<=round(top+height*hi);y+=max(2,b.step)){int[] span=rowSpan(b,y,max(2,b.step));if(span[2]<2)continue;float width=span[1]-span[0]+b.step,widthScore=1.0f-abs(width-targetWidth)/max(12,targetWidth),prior=1.0f-abs(y-(top+height*preferred))/max(1,height*(hi-lo));float score=widthScore*.78f+prior*.22f;if(score>best){best=score;bestY=y;}}return bestY;}
  NuiLimbPath traceLimb(NuiDepthBodyMask b,InteractionBodyPoint seed,int side,int kind,float pelvisY,float center,float torsoWidth,InteractionJoint3D priorJoint){NuiLimbPath out=new NuiLimbPath();if(seed==null||!seed.valid)return out;int start=nearestMaskIndex(b,seed.x,seed.y,max(8,round(torsoWidth*.35f)));if(start<0)return out;int n=b.mask.length;float[] d=new float[n];int[] parent=new int[n];Arrays.fill(d,Float.POSITIVE_INFINITY);Arrays.fill(parent,-1);PriorityQueue<NuiGraphNode> pq=new PriorityQueue<NuiGraphNode>();d[start]=0;pq.add(new NuiGraphNode(start,0));PVector prior=priorDepth(priorJoint);int best=start;float bestScore=-Float.MAX_VALUE;
    while(!pq.isEmpty()){NuiGraphNode node=pq.poll();int at=node.index;if(node.distance!=d[at])continue;int gx=at%b.gridW,gy=at/b.gridW;float x=b.px(gx),y=b.py(gy);if(limbAllowed(y,kind,pelvisY,torsoWidth)){float score=endpointScore(b,at,start,side,kind,pelvisY,center,torsoWidth,prior);if(score>bestScore){bestScore=score;best=at;}}for(int oy=-1;oy<=1;oy++)for(int ox=-1;ox<=1;ox++){if(ox==0&&oy==0)continue;int nx=gx+ox,ny=gy+oy;if(nx<0||ny<0||nx>=b.gridW||ny>=b.gridH)continue;int ni=ny*b.gridW+nx;if(!b.mask[ni]||!limbAllowed(b.py(ny),kind,pelvisY,torsoWidth))continue;float depthJump=abs(b.mm[ni]-b.mm[at])/(float)max(1,cfg.bodyContinuityMm),clear=max(1,min(b.clearance[at],b.clearance[ni])),medial=1.0f+cfg.poseMedialPenalty/max(1.0f,clear/3.0f),edge=(float)Math.sqrt(ox*ox+oy*oy)*b.step*(1.0f+cfg.poseGeodesicDepthPenalty*constrain(depthJump,0,1))*medial;float nxp=b.px(nx);boolean crosses=side<0?nxp>center+torsoWidth*.15f:nxp<center-torsoWidth*.15f;boolean priorCrossed=prior!=null&&(side<0?prior.x>center:prior.x<center);if(crosses)edge*=priorCrossed?1.08f:cfg.poseCrossBodyPenalty;float nd=node.distance+edge;if(nd<d[ni]){d[ni]=nd;parent[ni]=at;pq.add(new NuiGraphNode(ni,nd));}}}
    float minLength=torsoWidth*(kind==LIMB_ARM?cfg.poseMinArmPathRatio:cfg.poseMinLegPathRatio);if(best==start||!Float.isFinite(d[best])||d[best]<minLength)return out;ArrayList<Integer> rev=new ArrayList<Integer>();for(int at=best;at>=0;at=parent[at]){rev.add(at);if(at==start)break;}if(rev.isEmpty()||rev.get(rev.size()-1)!=start)return out;Collections.reverse(rev);out.nodes=new int[rev.size()];out.cumulative=new float[rev.size()];float physical=0;for(int i=0;i<rev.size();i++){out.nodes[i]=rev.get(i);if(i>0){int a=out.nodes[i-1],z=out.nodes[i];physical+=dist(b.px(a%b.gridW),b.py(a/b.gridW),b.px(z%b.gridW),b.py(z/b.gridW));}out.cumulative[i]=physical;}out.lengthPx=physical;if(physical<minLength)return new NuiLimbPath();float lengthScore=constrain((physical-minLength)/max(torsoWidth*.90f,1)+.55f,.35f,1),sideScore=endpointSideScore(b,best,side,center,torsoWidth);out.confidence=constrain(.48f+.34f*lengthScore+.18f*sideScore,.35f,1);return out;}
  boolean limbAllowed(float y,int kind,float pelvisY,float torsoWidth){return kind==LIMB_ARM?y<=pelvisY+torsoWidth*.20f:y>=pelvisY-torsoWidth*.18f;}
  float endpointScore(NuiDepthBodyMask b,int idx,int start,int side,int kind,float pelvisY,float center,float torsoWidth,PVector prior){int gx=idx%b.gridW,gy=idx/b.gridW,sgx=start%b.gridW,sgy=start/b.gridW;float x=b.px(gx),y=b.py(gy),outward=side<0?center-x:x-center,reach=dist(x,y,b.px(sgx),b.py(sgy)),score=reach;if(kind==LIMB_ARM)score+=max(0,outward)*.42f;else score+=max(0,y-pelvisY)*.68f;if(outward<-torsoWidth*.08f)score-=torsoWidth*.85f;int neighbors=0;for(int oy=-1;oy<=1;oy++)for(int ox=-1;ox<=1;ox++){if(ox==0&&oy==0)continue;int nx=gx+ox,ny=gy+oy;if(nx>=0&&ny>=0&&nx<b.gridW&&ny<b.gridH&&b.mask[ny*b.gridW+nx])neighbors++;}if(neighbors<=5)score+=torsoWidth*.22f;if(prior!=null){float pd=dist(x,y,prior.x,prior.y),near=constrain(1.0f-pd/max(torsoWidth*2.1f,24),0,1);score+=near*torsoWidth*cfg.poseTemporalEndpointBias;}return score;}
  float endpointSideScore(NuiDepthBodyMask b,int idx,int side,float center,float torsoWidth){float x=b.px(idx%b.gridW),outward=side<0?center-x:x-center;return constrain((outward+torsoWidth*.12f)/max(torsoWidth*.62f,1),0,1);}
  PVector priorDepth(InteractionJoint3D j){if(j==null||!j.tracked()||j.world.z<=0)return null;return cal.projectDepth(j.world);}
  int nearestMaskIndex(NuiDepthBodyMask b,float x,float y,int radius){int cg=constrain(round(x/b.step),0,b.gridW-1),cy=constrain(round(y/b.step),0,b.gridH-1),rg=max(1,(radius+b.step-1)/b.step),best=-1;float bestD=Float.MAX_VALUE;for(int gy=max(b.minGY,cy-rg);gy<=min(b.maxGY,cy+rg);gy++)for(int gx=max(b.minGX,cg-rg);gx<=min(b.maxGX,cg+rg);gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;float dx=b.px(gx)-x,dy=b.py(gy)-y,dd=dx*dx+dy*dy;if(dd<bestD){bestD=dd;best=i;}}return best;}
  InteractionBodyPoint armFallback(NuiDepthBodyMask b,InteractionBodyPoint shoulder,int side,float pelvisY,float torsoWidth,float q){if(shoulder==null||!shoulder.valid)return new InteractionBodyPoint();int best=-1;float bestScore=-1,center=b.centerX;for(int gy=b.minGY;gy<=b.maxGY;gy++){float y=b.py(gy);if(y<shoulder.y-torsoWidth*.75f||y>pelvisY+torsoWidth*.18f)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;float x=b.px(gx);if(side<0&&x>center-torsoWidth*.12f)continue;if(side>0&&x<center+torsoWidth*.12f)continue;float dx=x-shoulder.x,dy=y-shoulder.y,dist2=dx*dx+dy*dy;if(dist2<torsoWidth*torsoWidth*.10f)continue;float outward=side<0?max(0,shoulder.x-x):max(0,x-shoulder.x),score=dist2+outward*outward*.55f;if(score>bestScore){bestScore=score;best=i;}}}if(best<0)return pointNear(b,shoulder.x+side*torsoWidth*.18f,shoulder.y+torsoWidth*.70f,max(16,round(torsoWidth*.45f)),q*.55f);return new InteractionBodyPoint(b.px(best%b.gridW),b.py(best/b.gridW),q*.70f);}
  InteractionBodyPoint legFallback(NuiDepthBodyMask b,int side,float y,float center,float torsoWidth,float q){int band=max(8,round((b.py(b.maxGY)-b.py(b.minGY))*.035f));double sx=0,sy=0;int n=0;for(int gy=b.minGY;gy<=b.maxGY;gy++){if(abs(b.py(gy)-y)>band)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;float x=b.px(gx);if(side<0&&x>center-torsoWidth*.035f)continue;if(side>0&&x<center+torsoWidth*.035f)continue;sx+=x;sy+=b.py(gy);n++;}}if(n==0)return pointNear(b,center+side*torsoWidth*.22f,y,max(18,round(torsoWidth*.45f)),q*.55f);return new InteractionBodyPoint((float)(sx/n),(float)(sy/n),q);}
  InteractionJoint3D joint(String name,InteractionBodyPoint p,NuiDepthBodyMask body){InteractionJoint3D j=new InteractionJoint3D(name);if(p==null||!p.valid)return j;int idx=nearestMaskIndex(body,p.x,p.y,max(body.step*2,8));if(idx<0)return j;int base=body.mm[idx];if(base<cfg.minDepthMm||base>cfg.maxDepthMm)return j;boolean extremity=name.indexOf("hand")>=0||name.indexOf("wrist")>=0||name.indexOf("ankle")>=0||name.indexOf("foot")>=0;float radius=extremity?max(6,body.step*1.6f):max(8,body.step*2.4f),sigma=max(4,radius*.62f),sw=0,sx=0,sy=0,sd=0,sd2=0;int localN=0;int gx0=idx%body.gridW,gy0=idx/body.gridW,rg=max(1,ceil(radius/body.step));for(int gy=max(body.minGY,gy0-rg);gy<=min(body.maxGY,gy0+rg);gy++)for(int gx=max(body.minGX,gx0-rg);gx<=min(body.maxGX,gx0+rg);gx++){int i=gy*body.gridW+gx;if(!body.mask[i]||abs(body.mm[i]-base)>max(70,cfg.bodyContinuityMm/2))continue;float dx=body.px(gx)-p.x,dy=body.py(gy)-p.y,dd=dx*dx+dy*dy;if(dd>radius*radius)continue;float w=(float)Math.exp(-dd/(2*sigma*sigma))*(1.0f+.035f*min(18,body.clearance[i]));sw+=w;sx+=w*body.px(gx);sy+=w*body.py(gy);sd+=w*body.mm[i];sd2+=w*body.mm[i]*body.mm[i];localN++;}int u=body.px(gx0),v=body.py(gy0),mm=base;if(sw>0){u=round(lerp(u,sx/sw,extremity?.28f:.48f));v=round(lerp(v,sy/sw,extremity?.28f:.48f));mm=round(sd/sw);}PVector image=cal.projectRgb(u,v,mm);if(image==null)image=new PVector(u,v);float variance=sw>0?max(0,sd2/sw-(sd/sw)*(sd/sw)):0,depthStd=sqrt(variance),surfaceQ=constrain(1.0f-depthStd/max(45.0f,cfg.bodyContinuityMm*.45f),.45f,1.0f),sampleQ=constrain(localN/8.0f,.55f,1.0f),clearQ=extremity?1.0f:constrain(body.clearance[idx]/5.0f,.62f,1.0f),confidence=constrain(p.confidence*surfaceQ*sampleQ*clearQ,.04f,1.0f);return j.set(image,cal.deproject(u,v,mm),confidence,confidence>.55f?2:1);}
  void validateKinematics(InteractionSkeleton3D s){if(!s.leftShoulder.tracked()||!s.rightShoulder.tracked())return;float scale=PVector.dist(s.leftShoulder.world,s.rightShoulder.world);if(scale<.10f||scale>.85f)return;validateArm(s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand,scale);validateArm(s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand,scale);validateLeg(s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot,scale);validateLeg(s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot,scale);}
  void validateArm(InteractionJoint3D shoulder,InteractionJoint3D elbow,InteractionJoint3D wrist,InteractionJoint3D hand,float scale){if(!plausibleBone(shoulder,elbow,scale*.20f,scale*1.25f)){invalidate(elbow);invalidate(wrist);invalidate(hand);return;}if(!plausibleBone(elbow,wrist,scale*.18f,scale*1.25f)){invalidate(wrist);invalidate(hand);return;}if(wrist.tracked()&&hand.tracked()&&!plausibleBone(wrist,hand,scale*.02f,scale*.65f))invalidate(hand);}
  void validateLeg(InteractionJoint3D hip,InteractionJoint3D knee,InteractionJoint3D ankle,InteractionJoint3D foot,float scale){if(!plausibleBone(hip,knee,scale*.34f,scale*1.80f)){invalidate(knee);invalidate(ankle);invalidate(foot);return;}if(!plausibleBone(knee,ankle,scale*.32f,scale*1.85f)){invalidate(ankle);invalidate(foot);return;}if(ankle.tracked()&&foot.tracked()&&!plausibleBone(ankle,foot,scale*.02f,scale*.85f))invalidate(foot);}
  boolean plausibleBone(InteractionJoint3D a,InteractionJoint3D b,float minLen,float maxLen){if(a==null||b==null||!a.tracked()||!b.tracked())return false;float d=PVector.dist(a.world,b.world);return d>=minLen&&d<=maxLen;}
  void invalidate(InteractionJoint3D j){if(j!=null){j.state=0;j.confidence=0;}}
  int centralTop(NuiDepthBodyMask b){float mid=(b.px(b.minGX)+b.px(b.maxGX))*.5f,half=max(18,(b.px(b.maxGX)-b.px(b.minGX))*.22f);for(int gy=b.minGY;gy<=b.maxGY;gy++)for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(b.mask[i]&&abs(b.px(gx)-mid)<=half)return b.py(gy);}return b.py(b.minGY);}
  float centerAtOr(NuiDepthBodyMask b,int y,int band,float fallback){float v=centerAt(b,y,band);return Float.isNaN(v)?fallback:v;}
  float centerAt(NuiDepthBodyMask b,int y,int band){long sum=0;int n=0;for(int gy=b.minGY;gy<=b.maxGY;gy++){int py=b.py(gy);if(abs(py-y)>band)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(b.mask[i]){sum+=b.px(gx);n++;}}}return n==0?Float.NaN:sum/(float)n;}
  float torsoWidth(NuiDepthBodyMask b,int top,int height,float center){ArrayList<Integer> widths=new ArrayList<Integer>();for(int y=round(top+height*.28f);y<=round(top+height*.54f);y+=max(4,b.step)){int[] span=rowSpan(b,y,max(3,b.step));if(span[2]>=2)widths.add(span[1]-span[0]+b.step);}if(widths.isEmpty())return max(20,(b.px(b.maxGX)-b.px(b.minGX))*.36f);Collections.sort(widths);int idx=constrain(round((widths.size()-1)*.36f),0,widths.size()-1);return widths.get(idx);}
  int[] rowSpan(NuiDepthBodyMask b,int y,int band){int lo=b.width,hi=-1,n=0;for(int gy=b.minGY;gy<=b.maxGY;gy++){if(abs(b.py(gy)-y)>band)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;int x=b.px(gx);lo=min(lo,x);hi=max(hi,x);n++;}}return new int[]{lo,hi,n};}
  InteractionBodyPoint pointNear(NuiDepthBodyMask b,float x,float y,int radius,float q){int best=nearestMaskIndex(b,x,y,radius);if(best<0)return new InteractionBodyPoint();return new InteractionBodyPoint(b.px(best%b.gridW),b.py(best/b.gridW),q);}
  InteractionBodyPoint betweenOnMask(NuiDepthBodyMask b,InteractionBodyPoint a,InteractionBodyPoint z,float t,int radius,float q){if(a==null||z==null||!a.valid||!z.valid)return new InteractionBodyPoint();return pointNear(b,lerp(a.x,z.x,t),lerp(a.y,z.y,t),radius,q);}
  void clampSkeleton(InteractionSkeleton3D s){for(InteractionJoint3D j:allJoints(s))if(j!=null&&j.tracked()){j.image.x=constrain(j.image.x,0,studio.services.scannerProtocol.WIDTH-1);j.image.y=constrain(j.image.y,0,studio.services.scannerProtocol.HEIGHT-1);}}
  InteractionJoint3D[] allJoints(InteractionSkeleton3D s){return new InteractionJoint3D[]{s.head,s.neck,s.chest,s.spine,s.pelvis,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot};}
  float avgTracked(InteractionJoint3D[] js){float sum=0;int n=0;for(InteractionJoint3D j:js)if(j!=null&&j.tracked()){sum+=j.confidence;n++;}return n==0?0:sum/n;}
  void deriveBounds(InteractionSkeleton3D s){int minX=studio.services.scannerProtocol.WIDTH-1,minY=studio.services.scannerProtocol.HEIGHT-1,maxX=0,maxY=0;for(InteractionJoint3D j:allJoints(s))if(j.tracked()){minX=min(minX,round(j.image.x));maxX=max(maxX,round(j.image.x));minY=min(minY,round(j.image.y));maxY=max(maxY,round(j.image.y));}s.minX=max(0,minX);s.maxX=min(studio.services.scannerProtocol.WIDTH-1,maxX);s.minY=max(0,minY);s.maxY=min(studio.services.scannerProtocol.HEIGHT-1,maxY);s.clippedTop=s.minY<=1;s.clippedBottom=s.maxY>=studio.services.scannerProtocol.HEIGHT-2;}
  float meanDepth(InteractionSkeleton3D s){float sum=0;int n=0;for(InteractionJoint3D j:allJoints(s))if(j.tracked()&&j.world.z>0){sum+=j.world.z;n++;}return n==0?0:sum/n;}
}

class InteractionOrbCloud {
  final InteractionConfig cfg;final int count,trailCount;float[] x,y,vx,vy,phase,ring,lag;int[] band;float[] histX,histY;long lastMs=0;InteractionSkeleton3D skeleton;float lastHandX=Float.NaN,lastHandY=Float.NaN,handVx=0,handVy=0;
  InteractionOrbCloud(InteractionConfig cfg){
    this.cfg=cfg;count=max(80,cfg.cloudParticles);trailCount=max(6,cfg.cloudTrailSamples);x=new float[count];y=new float[count];vx=new float[count];vy=new float[count];phase=new float[count];ring=new float[count];lag=new float[count];band=new int[count];histX=new float[trailCount];histY=new float[trailCount];
    Random r=new Random(360112);for(int i=0;i<count;i++){phase[i]=r.nextFloat()*TWO_PI;ring[i]=sqrt(r.nextFloat());lag[i]=pow(r.nextFloat(),0.72f);band[i]=min(2,floor(lag[i]*3));x[i]=studio.services.scannerProtocol.WIDTH*0.5f;y[i]=studio.services.scannerProtocol.HEIGHT*0.5f;}
  }
  PVector primaryHand(InteractionSkeleton3D s){if(s==null)return null;if("left".equals(cfg.hand)&&s.leftHandTracked())return s.leftHand.image;if("right".equals(cfg.hand)&&s.rightHandTracked())return s.rightHand.image;if(s.rightHandTracked())return s.rightHand.image;if(s.leftHandTracked())return s.leftHand.image;return null;}
  float primaryOpen(InteractionSkeleton3D s){if(s==null)return 0.5f;if("left".equals(cfg.hand)&&s.leftHandTracked())return s.leftOpenness;if("right".equals(cfg.hand)&&s.rightHandTracked())return s.rightOpenness;if(s.rightHandTracked())return s.rightOpenness;if(s.leftHandTracked())return s.leftOpenness;return 0.5f;}
  void reset(){skeleton=null;lastMs=0;lastHandX=lastHandY=Float.NaN;handVx=handVy=0;Arrays.fill(vx,0);Arrays.fill(vy,0);}
  void seedHistory(float hx,float hy){for(int i=0;i<trailCount;i++){histX[i]=hx;histY[i]=hy;}for(int i=0;i<count;i++){x[i]=hx;y[i]=hy;vx[i]=vy[i]=0;}}
  void pushHistory(float hx,float hy){for(int i=trailCount-1;i>0;i--){histX[i]=histX[i-1];histY[i]=histY[i-1];}histX[0]=hx;histY[0]=hy;}
  void update(InteractionSkeleton3D s){
    skeleton=s;if(s==null||!s.tracked)return;PVector h=primaryHand(s);if(h==null)return;long now=millis64();float dt=lastMs==0?1.0f/60.0f:constrain((now-lastMs)/1000.0f,0.004f,0.040f);lastMs=now;float t=now*0.001f;
    if(Float.isNaN(lastHandX)){lastHandX=h.x;lastHandY=h.y;seedHistory(h.x,h.y);}float rawVx=(h.x-lastHandX)/dt,rawVy=(h.y-lastHandY)/dt;lastHandX=h.x;lastHandY=h.y;float va=1.0f-exp(-10.0f*dt);handVx=lerp(handVx,rawVx,va);handVy=lerp(handVy,rawVy,va);pushHistory(h.x,h.y);
    float speed=sqrt(handVx*handVx+handVy*handVy),ux=speed>5?handVx/speed:1,uy=speed>5?handVy/speed:0,pxAxis=-uy,pyAxis=ux;float stretch=1.0f+min(max(0,cfg.cloudMaxStretch-1.0f),speed*cfg.cloudStretchGain);float openness=primaryOpen(s),baseRadius=cfg.cloudRadiusPx*(0.78f+0.48f*openness);
    for(int i=0;i<count;i++){
      int hi=constrain(round(lag[i]*(trailCount-1)*cfg.cloudTrailStrength),0,trailCount-1);float cx=histX[hi],cy=histY[hi],tailFade=1.0f-0.42f*lag[i];float a=phase[i]+t*(0.52f+0.20f*((i%11)/11.0f));float rr=baseRadius*(0.18f+0.82f*ring[i])*tailFade;
      float longAxis=rr*(1.0f+(stretch-1.0f)*(0.35f+0.65f*lag[i])),shortAxis=rr/max(1.0f,sqrt(stretch));float swirl=sin(a*1.83f+t*0.48f+phase[i])*cfg.cloudFlow*baseRadius*(0.45f+0.55f*lag[i]);
      float localLong=cos(a)*longAxis-swirl*0.20f,localPerp=sin(a)*shortAxis+swirl;float tx=cx+ux*localLong+pxAxis*localPerp,ty=cy+uy*localLong+pyAxis*localPerp;
      float ax=(tx-x[i])*cfg.cloudSpring-vx[i]*cfg.cloudDamping,ay=(ty-y[i])*cfg.cloudSpring-vy[i]*cfg.cloudDamping;vx[i]+=ax*dt;vy[i]+=ay*dt;x[i]+=vx[i]*dt;y[i]+=vy[i]*dt;
    }
  }
  void draw(float sx,float sy){
    if(skeleton==null||!skeleton.tracked||primaryHand(skeleton)==null)return;strokeCap(ROUND);
    for(int b=2;b>=0;b--){int alpha=b==0?228:b==1?156:82;float core=b==0?2.5f:b==1?2.1f:1.7f,glow=core*2.8f;
      stroke(104,169,232,max(18,alpha/4));strokeWeight(glow*studioUiScale());beginShape(POINTS);for(int i=0;i<count;i++){if(band[i]!=b)continue;vertex(x[i]*sx,y[i]*sy);}endShape();
      stroke(104,169,232,alpha);strokeWeight(core*studioUiScale());beginShape(POINTS);for(int i=0;i<count;i++){if(band[i]!=b)continue;vertex(x[i]*sx,y[i]*sy);}endShape();
    }noStroke();
  }
}


class InteractionDesktopController {
  final InteractionConfig cfg;Robot robot;Rectangle desktopBounds;
  volatile boolean enabled=false,dragging=false,buttonDown=false,twoHandMode=false;volatile String handMode;
  float sx=Float.NaN,sy=Float.NaN;long lastMoveMs=0,lastTrackedMs=0,moveCount=0,doubleClickCount=0,dragCount=0,scrollCount=0;volatile int lastX=-1,lastY=-1;String error="";
  long twoHandsSince=0,bothClosedSince=0,lastDoubleMs=0,lastScrollMs=0;float lastScrollY=Float.NaN;boolean doubleFired=false;String interactionState="gesture.cloud_only";
  InteractionDesktopController(InteractionConfig cfg){this.cfg=cfg;handMode=cfg.hand;try{if(GraphicsEnvironment.isHeadless())throw new AWTException("headless");robot=new Robot();robot.setAutoDelay(3);desktopBounds=desktopBounds();}catch(Exception e){error=safeStudioMessage(e);robot=null;desktopBounds=new Rectangle(0,0,1,1);}}
  Rectangle desktopBounds(){Rectangle all=null;for(GraphicsDevice gd:GraphicsEnvironment.getLocalGraphicsEnvironment().getScreenDevices()){Rectangle b=gd.getDefaultConfiguration().getBounds();all=all==null?new Rectangle(b):all.union(b);}return all==null?new Rectangle(0,0,1920,1080):all;}
  boolean available(){return robot!=null;}
  void setEnabled(boolean on){boolean next=on&&available();if(enabled==next)return;enabled=next;if(!enabled){releaseDrag();resetGesture();}sx=Float.NaN;sy=Float.NaN;}
  void resetGesture(){twoHandMode=false;twoHandsSince=bothClosedSince=0;lastScrollY=Float.NaN;doubleFired=false;interactionState="gesture.cloud_only";}
  String gestureKey(){if(!enabled)return "gesture.disabled";if(dragging)return "gesture.dragging";return interactionState;}
  boolean primaryLeft(InteractionSkeleton3D s){if(s==null)return false;if("left".equals(handMode)&&s.leftHandTracked())return true;if("right".equals(handMode)&&s.rightHandTracked())return false;if(s.rightHandTracked())return false;return s.leftHandTracked();}
  InteractionJoint3D primaryJoint(InteractionSkeleton3D s){if(s==null)return null;if(primaryLeft(s)&&s.leftHandTracked())return s.leftHand;if(!primaryLeft(s)&&s.rightHandTracked())return s.rightHand;if(s.rightHandTracked())return s.rightHand;if(s.leftHandTracked())return s.leftHand;return null;}
  InteractionJoint3D secondaryJoint(InteractionSkeleton3D s){if(s==null||!s.rightHandTracked()||!s.leftHandTracked())return null;return primaryLeft(s)?s.rightHand:s.leftHand;}
  float primaryOpen(InteractionSkeleton3D s){if(s==null)return 0.5f;return primaryLeft(s)?s.leftOpenness:(s.rightHandTracked()?s.rightOpenness:s.leftOpenness);}
  float secondaryOpen(InteractionSkeleton3D s){if(s==null||!s.rightHandTracked()||!s.leftHandTracked())return 0.5f;return primaryLeft(s)?s.rightOpenness:s.leftOpenness;}
  PVector screenPoint(InteractionSkeleton3D s,InteractionJoint3D hand){
    if(s==null||hand==null||!hand.tracked()||!s.torsoTracked())return null;
    PVector shoulderMid=PVector.add(s.leftShoulder.world,s.rightShoulder.world).mult(.5f),xAxis=PVector.sub(s.rightShoulder.world,s.leftShoulder.world);if(xAxis.mag()<0.05f)xAxis.set(1,0,0);else xAxis.normalize();PVector upper=s.neck.tracked()?s.neck.world:shoulderMid;PVector yAxis=PVector.sub(s.chest.world,upper);if(yAxis.mag()<0.04f)yAxis.set(0,1,0);else yAxis.normalize();PVector normal=xAxis.cross(yAxis);if(normal.mag()<0.05f)normal.set(0,0,1);else normal.normalize();if(normal.z<0)normal.mult(-1);PVector rel=PVector.sub(hand.world,s.chest.world);float lateral=rel.dot(xAxis),vertical=rel.dot(yAxis),forward=-rel.dot(normal);if(forward<cfg.minHandForwardM)return null;float nx=constrain((lateral+cfg.volumeHalfWidthM)/(2*cfg.volumeHalfWidthM),0,1),ny=constrain((vertical+cfg.volumeTopM)/max(.05f,cfg.volumeTopM+cfg.volumeBottomM),0,1);if(cfg.mirrorX)nx=1-nx;return new PVector(desktopBounds.x+nx*max(1,desktopBounds.width-1),desktopBounds.y+ny*max(1,desktopBounds.height-1));
  }
  void update(InteractionSkeleton3D s){
    long now=millis64();
    if(!enabled||robot==null||s==null||!s.interactionTracked()){if(enabled&&now-lastTrackedMs>cfg.cursorLostReleaseMs){releaseDrag();resetGesture();}return;}
    InteractionJoint3D primary=primaryJoint(s);if(primary==null){return;}lastTrackedMs=now;InteractionJoint3D secondary=secondaryJoint(s);PVector a=screenPoint(s,primary),b=screenPoint(s,secondary);
    if(a==null){return;}boolean two=secondary!=null&&b!=null;
    updatePointer(a,now);
    if(!two){
      twoHandsSince=0;twoHandMode=false;releaseDrag();lastScrollY=Float.NaN;bothClosedSince=0;doubleFired=false;interactionState="gesture.pointer";return;
    }
    if(twoHandsSince==0)twoHandsSince=now;if(now-twoHandsSince>=cfg.twoHandStableMs)twoHandMode=true;
    if(!twoHandMode){interactionState="gesture.two_hand_wait";return;}
    float po=primaryOpen(s),so=secondaryOpen(s);boolean pOpen=po>=cfg.handOpenThreshold,sOpen=so>=cfg.handOpenThreshold,pClosed=po<=cfg.handCloseThreshold,sClosed=so<=cfg.handCloseThreshold;
    if(pClosed&&sClosed){
      releaseDrag();interactionState="gesture.double_click";if(bothClosedSince==0)bothClosedSince=now;if(!doubleFired&&now-bothClosedSince>=cfg.doubleClickStableMs&&now-lastDoubleMs>=cfg.doubleClickCooldownMs){doubleClick();doubleFired=true;lastDoubleMs=now;}
    }else{
      bothClosedSince=0;if(pOpen||sOpen)doubleFired=false;
      if(pClosed&&sOpen){interactionState="gesture.dragging";if(!buttonDown){pressPrimary();dragging=true;dragCount++;}}
      else{if(buttonDown)releaseDrag();if(pOpen&&sOpen){interactionState="gesture.scroll";updateScroll(s,now);}else interactionState="gesture.two_hand_ready";}
    }
  }
  void updatePointer(PVector target,long now){
    if(target==null||now-lastMoveMs<1000/max(1,cfg.cursorMaxHz))return;lastMoveMs=now;float tx=target.x,ty=target.y;
    if(Float.isNaN(sx)){sx=tx;sy=ty;}else{float d=dist(sx,sy,tx,ty);float speed=constrain(d/max(1,cfg.cursorFastDistancePx),0,1);float a=lerp(cfg.cursorSlowAlpha,cfg.cursorFastAlpha,speed);sx=lerp(sx,tx,a);sy=lerp(sy,ty,a);}
    int nxp=round(sx),nyp=round(sy);if(lastX>=0&&dist(lastX,lastY,nxp,nyp)<cfg.cursorDeadzonePx)return;lastX=nxp;lastY=nyp;try{robot.mouseMove(lastX,lastY);moveCount++;error="";}catch(Exception e){error=safeStudioMessage(e);}
  }
  void updateScroll(InteractionSkeleton3D s,long now){
    float avg=(s.leftHand.world.y+s.rightHand.world.y)*0.5f;if(Float.isNaN(lastScrollY)){lastScrollY=avg;return;}float delta=avg-lastScrollY;
    if(abs(delta)>=cfg.scrollThresholdM&&now-lastScrollMs>=cfg.scrollCooldownMs){int units=constrain(round(delta*cfg.scrollGainPerM),-5,5);if(units!=0){try{robot.mouseWheel(units);scrollCount+=abs(units);}catch(Exception e){error=safeStudioMessage(e);}lastScrollY=avg;lastScrollMs=now;}}else if(abs(delta)<cfg.scrollThresholdM*.35f)lastScrollY=lerp(lastScrollY,avg,.08f);
  }
  void pressPrimary(){if(!enabled||robot==null||buttonDown)return;try{robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);buttonDown=true;}catch(Exception e){error=safeStudioMessage(e);}}
  void releasePrimary(){if(robot==null||!buttonDown)return;try{robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);}catch(Exception e){error=safeStudioMessage(e);}buttonDown=false;}
  void doubleClick(){if(enabled&&robot!=null){try{robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);doubleClickCount++;}catch(Exception e){error=safeStudioMessage(e);}}}
  void releaseDrag(){releasePrimary();dragging=false;}
}


class InteractionUI {
  final UiRect enableButton=new UiRect(),releaseButton=new UiRect();
  void draw(){float m=max(10,STUDIO_UI_MARGIN*studioUiScale()),gap=max(8,STUDIO_UI_GAP*studioUiScale()),header=max(58,STUDIO_UI_HEADER_H*studioUiScale());drawHeader(m,header);float y=header+gap,w=max(40,width-2*m),h=max(1,studio.contentHeight-y-m);boolean wide=w>=900&&h>=430;if(wide){float left=w*.68f,right=w-left-gap;drawVision(m,y,left,h);drawControl(m+left+gap,y,right,h);}else{float visionH=max(70,(h-gap)*.56f),controlH=max(55,h-visionH-gap);if(visionH+controlH+gap>h&&h>1){float k=h/(visionH+controlH+gap);visionH*=k;controlH*=k;gap*=k;}drawVision(m,y,w,visionH);drawControl(m,y+visionH+gap,w,controlH);}}
  void drawHeader(float m,float h){
    float bw=constrain(width*.18f,110,220),bh=max(STUDIO_UI_BUTTON_MIN_H,STUDIO_UI_BUTTON_H*studioUiScale()),x=width-m-bw,textW=max(80,x-m-14);
    fill(0xFFF4F7FA);textAlign(LEFT,CENTER);studioText(STUDIO_FONT_TITLE,true);String title=studio.interactionState.i18n.tr("app.title");fitCurrentTextSize(title,STUDIO_FONT_TITLE,10,textW,h*.45f);text(ellipsizeToWidth(title,textW),m,h*.36f);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_SMALL,false);String sub=studio.interactionState.i18n.tr("app.subtitle");fitCurrentTextSize(sub,STUDIO_FONT_SMALL,8,textW,h*.38f);text(ellipsizeToWidth(sub,textW),m,h*.69f);
    enableButton.set(x,max(8,(h-bh)/2),bw,bh);drawButton(enableButton,studio.interactionState.i18n.tr(studio.interactionState.controlEnabled?"button.disable":"button.enable"),true,studio.interactionState.controlEnabled);textAlign(LEFT,BASELINE);
  }
  void drawVision(float x,float y,float w,float h){card(x,y,w,h);cardTitle(x,y,w,studio.interactionState.i18n.tr("panel.vision"));float px=x+12,py=y+STUDIO_UI_CARD_TITLE_H*studioUiScale(),pw=max(10,w-24),ph=max(10,h-(STUDIO_UI_CARD_TITLE_H+12)*studioUiScale());fill(studio.services.acousticTheme.BG);rect(px,py,pw,ph,10);if(studio.interactionState.rgbImage!=null){float[] vr=imageRect(studio.interactionState.rgbImage,px,py,pw,ph);pushMatrix();if(studio.interactionState.config.mirrorX){translate(vr[0]+vr[2],vr[1]);scale(-1,1);image(studio.interactionState.rgbImage,0,0,vr[2],vr[3]);}else image(studio.interactionState.rgbImage,vr[0],vr[1],vr[2],vr[3]);popMatrix();drawSkeletonOverlay(vr[0],vr[1],vr[2],vr[3]);}else{fill(0xFFAAB6C2);textAlign(CENTER,CENTER);studioText(STUDIO_FONT_BODY,false);text(ellipsizeToWidth(studio.interactionState.i18n.tr("waiting.rgbd"),pw-20),px+pw/2,py+ph/2);textAlign(LEFT,BASELINE);}}
  float[] imageRect(PImage img,float x,float y,float w,float h){float sc=min(w/img.width,h/img.height),dw=img.width*sc,dh=img.height*sc;return new float[]{x+(w-dw)/2,y+(h-dh)/2,dw,dh};}
  void drawSkeletonOverlay(float x,float y,float w,float h){
    InteractionSkeleton3D s=studio.interactionState.skeleton;if(s==null||!s.tracked)return;float sx=w/studio.services.scannerProtocol.WIDTH,sy=h/studio.services.scannerProtocol.HEIGHT;clip(x,y,w,h);pushMatrix();translate(x,y);if(studio.interactionState.config.mirrorX){translate(w,0);scale(-1,1);}
    // Articulated virtual-body style: dark cylindrical outline, bright bone core and spherical joints.
    drawBodyBones(s,sx,sy,0xFF101820,max(5.2f,7.5f*studioUiScale()));drawBodyBones(s,sx,sy,0xFF58C7F3,max(2.2f,3.6f*studioUiScale()));
    if(s.head.tracked()){noFill();stroke(0xFF101820,230);strokeWeight(max(3,5*studioUiScale()));ellipse(s.head.image.x*sx,s.head.image.y*sy,s.faceWidthPx*sx,s.faceHeightPx*sy);stroke(0xFF58C7F3,245);strokeWeight(max(1.4f,2.4f*studioUiScale()));ellipse(s.head.image.x*sx,s.head.image.y*sy,s.faceWidthPx*sx,s.faceHeightPx*sy);}
    for(InteractionJoint3D j:bodyJoints(s))jointNode(j,sx,sy);
    if(studio.interactionState.cloud!=null)studio.interactionState.cloud.draw(sx,sy);drawHandPose(s.leftPose,s.leftHand,s.leftOpenness,sx,sy,0xFFD8BCFF);drawHandPose(s.rightPose,s.rightHand,s.rightOpenness,sx,sy,0xFF9ED8FF);popMatrix();noClip();
  }
  InteractionJoint3D[] bodyJoints(InteractionSkeleton3D s){return new InteractionJoint3D[]{s.neck,s.chest,s.spine,s.pelvis,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot};}
  void drawBodyBones(InteractionSkeleton3D s,float sx,float sy,int color,float weight){stroke(color,s.tracked?235:150);strokeWeight(weight);strokeCap(ROUND);bone(s.head,s.neck,sx,sy);bone(s.neck,s.chest,sx,sy);bone(s.chest,s.spine,sx,sy);bone(s.spine,s.pelvis,sx,sy);bone(s.leftShoulder,s.rightShoulder,sx,sy);bone(s.neck,s.leftShoulder,sx,sy);bone(s.neck,s.rightShoulder,sx,sy);bone(s.leftShoulder,s.leftElbow,sx,sy);bone(s.leftElbow,s.leftWrist,sx,sy);bone(s.leftWrist,s.leftHand,sx,sy);bone(s.rightShoulder,s.rightElbow,sx,sy);bone(s.rightElbow,s.rightWrist,sx,sy);bone(s.rightWrist,s.rightHand,sx,sy);bone(s.pelvis,s.leftHip,sx,sy);bone(s.pelvis,s.rightHip,sx,sy);bone(s.leftHip,s.rightHip,sx,sy);bone(s.leftHip,s.leftKnee,sx,sy);bone(s.leftKnee,s.leftAnkle,sx,sy);bone(s.leftAnkle,s.leftFoot,sx,sy);bone(s.rightHip,s.rightKnee,sx,sy);bone(s.rightKnee,s.rightAnkle,sx,sy);bone(s.rightAnkle,s.rightFoot,sx,sy);}
  void bone(InteractionJoint3D a,InteractionJoint3D b,float sx,float sy){if(a!=null&&b!=null&&a.tracked()&&b.tracked())line(a.image.x*sx,a.image.y*sy,b.image.x*sx,b.image.y*sy);}
  void jointNode(InteractionJoint3D j,float sx,float sy){if(j==null||!j.tracked())return;float d=(j.state==2?10:8)*studioUiScale(),alpha=j.state==2?245:150;noStroke();fill(0xFF101820,230);ellipse(j.image.x*sx,j.image.y*sy,d+5*studioUiScale(),d+5*studioUiScale());fill(j.state==2?0xFFFFB54A:0xFF9AA9B5,alpha);ellipse(j.image.x*sx,j.image.y*sy,d,d);}
  void drawHandPose(InteractionHandPose3D p,InteractionJoint3D hand,float openness,float sx,float sy,int c){if(p!=null&&p.tracked&&hand!=null&&hand.tracked()){stroke(c,190);strokeWeight(max(1,1.2f*studioUiScale()));for(int i=0;i<p.fingerCount;i++){InteractionFinger3D f=p.fingers[i];if(f.tip.tracked()){line(hand.image.x*sx,hand.image.y*sy,f.tip.image.x*sx,f.tip.image.y*sy);noStroke();fill(c,235);ellipse(f.tip.image.x*sx,f.tip.image.y*sy,5*studioUiScale(),5*studioUiScale());stroke(c,190);}}noStroke();fill(c,220);float d=(7+7*openness)*studioUiScale();ellipse(hand.image.x*sx,hand.image.y*sy,d,d);}}
  String xyz(InteractionJoint3D j){return j==null||!j.tracked()?"—":String.format(Locale.US,"%.2f / %.2f / %.2f m",j.world.x,j.world.y,j.world.z);}
  void drawControl(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,studio.interactionState.i18n.tr("panel.control"));float px=x+12,py=y+STUDIO_UI_CARD_TITLE_H*studioUiScale(),inner=max(40,w-24);boolean compact=h<390;float row=max(23,(compact?25:30)*studioUiScale());
    String live=interaction3dLive()?studio.interactionState.i18n.tr("state.live"):studio.interactionState.i18n.tr("state.wait");
    String syncValue=studio.interactionState.source==null||Float.isNaN(studio.interactionState.source.latestSyncResidualMs)?"—":studio.interactionState.i18n.format("value.sync",studio.interactionState.source.latestSyncResidualMs,studio.interactionState.source.syncOffsetUs/1000.0);
    String sk=studio.interactionState.skeleton!=null&&studio.interactionState.skeleton.tracked?studio.interactionState.i18n.format("state.tracked",studio.interactionState.skeleton.interactionConfidence*100):studio.interactionState.i18n.tr("tracker."+(studio.interactionState.tracker==null?"searching":studio.interactionState.tracker.lastReason));
    String depth=studio.interactionState.skeleton==null?"—":String.format(Locale.US,"%.2f m",studio.interactionState.skeleton.meanDepthM);
    String fingers=studio.interactionState.skeleton==null?"0 / 0":studio.interactionState.skeleton.leftPose.fingerCount+" / "+studio.interactionState.skeleton.rightPose.fingerCount;
    String mode=studio.interactionState.desktop==null?studio.interactionState.i18n.tr("gesture.disabled"):studio.interactionState.i18n.tr(studio.interactionState.desktop.gestureKey());
    String actions=studio.interactionState.desktop==null?"0 / 0 / 0":studio.interactionState.desktop.doubleClickCount+" / "+studio.interactionState.desktop.dragCount+" / "+studio.interactionState.desktop.scrollCount;
    String[] labels={studio.interactionState.i18n.tr("label.kinect"),studio.interactionState.i18n.tr("label.sync"),studio.interactionState.i18n.tr("label.skeleton"),studio.interactionState.i18n.tr("label.depth"),studio.interactionState.i18n.tr("label.right_hand_xyz"),studio.interactionState.i18n.tr("label.left_hand_xyz"),studio.interactionState.i18n.tr("label.fingers"),studio.interactionState.i18n.tr("label.mode"),studio.interactionState.i18n.tr("label.actions")};
    String[] values={live,syncValue,sk,depth,studio.interactionState.skeleton==null?"—":xyz(studio.interactionState.skeleton.rightHand),studio.interactionState.skeleton==null?"—":xyz(studio.interactionState.skeleton.leftHand),fingers,mode,actions};
    int cols=compact&&inner>470?2:1,rows=(labels.length+cols-1)/cols;float colGap=14*studioUiScale(),colW=(inner-colGap*(cols-1))/cols;
    for(int i=0;i<labels.length;i++){int col=i/rows,rowIndex=i%rows;statusRow(px+col*(colW+colGap),py+rowIndex*row,colW,labels[i],values[i]);}
    py+=rows*row+8*studioUiScale();float bh=max(STUDIO_UI_BUTTON_MIN_H,STUDIO_UI_BUTTON_H*studioUiScale());releaseButton.set(px,py,inner,bh);drawButton(releaseButton,studio.interactionState.i18n.tr("button.release"),studio.interactionState.desktop!=null&&studio.interactionState.desktop.buttonDown,false);py+=bh+9*studioUiScale();
    float available=y+h-py-10;if(available>30){clip(x+8,py-2,w-16,available+2);fill(0xFFAAB6C2);textAlign(LEFT,TOP);studioText(STUDIO_FONT_SMALL,true);String title=studio.interactionState.i18n.tr("label.gesture_help");text(ellipsizeToWidth(title,inner),px,py);py+=18*studioUiScale();fill(0xFFF4F7FA);studioText(STUDIO_FONT_TINY,false);String help=studio.interactionState.i18n.tr("help.two_hand");text(help,px,py,inner,max(20,y+h-py-12));noClip();}textAlign(LEFT,BASELINE);
  }
  void statusRow(float x,float y,float w,String label,String value){fill(0xFFAAB6C2);textAlign(LEFT,CENTER);studioText(STUDIO_FONT_TINY,false);fitCurrentTextSize(label,STUDIO_FONT_TINY,8,w*.43f,24*studioUiScale());text(ellipsizeToWidth(label,w*.43f),x,y+12*studioUiScale());fill(0xFFF4F7FA);textAlign(RIGHT,CENTER);studioText(STUDIO_FONT_TINY,true);fitCurrentTextSize(value,STUDIO_FONT_TINY,8,w*.55f,24*studioUiScale());text(ellipsizeToWidth(value,w*.55f),x+w,y+12*studioUiScale());textAlign(LEFT,BASELINE);}
  void handleMouse(float mx,float my){if(enableButton.hit(mx,my))toggleInteractionControl();else if(releaseButton.hit(mx,my)&&studio.interactionState.desktop!=null)studio.interactionState.desktop.releaseDrag();}
  void drawButton(UiRect r,String label,boolean enabled,boolean primary){boolean hot=enabled&&r.hit(studio.contentMouseX(),studio.contentMouseY());stroke(hot?0xFF68A9E8:0xFF35414D);fill(enabled?(primary?0xFF293440:0xFF202832):0xFF11151A);rect(r.x,r.y,r.w,r.h,9);noStroke();fill(enabled?0xFFF4F7FA:0xFF56616C);textAlign(CENTER,CENTER);studioText(STUDIO_FONT_BUTTON,true);fitCurrentTextSize(label,STUDIO_FONT_BUTTON,8,r.w-12,r.h-8);text(ellipsizeToWidth(label,r.w-12),r.x+r.w/2,r.y+r.h/2);textAlign(LEFT,BASELINE);}
  void card(float x,float y,float w,float h){stroke(0xFF35414D);fill(0xFF181E25);rect(x,y,w,h,STUDIO_UI_RADIUS);noStroke();}void cardTitle(float x,float y,float w,String title){fill(0xFFF4F7FA);textAlign(LEFT,CENTER);studioText(STUDIO_FONT_SMALL,true);fitCurrentTextSize(title,STUDIO_FONT_SMALL,8,w-28,(STUDIO_UI_CARD_TITLE_H-8)*studioUiScale());text(ellipsizeToWidth(title,w-28),x+14,y+(STUDIO_UI_CARD_TITLE_H*0.5f)*studioUiScale());textAlign(LEFT,BASELINE);}
}
