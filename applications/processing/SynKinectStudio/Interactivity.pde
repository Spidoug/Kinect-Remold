// Responsive geometry is supplied by StudioUiMetrics.

// ===== SynKinect Studio / Interactivity =====
// Interactivity owns an independent full-FOV metric-depth session through the shared transport boundary.
// Closing one module cannot stop or reconfigure another module's session.
// The UI consumes immutable snapshots; the 3D tracker runs on its own latest-frame worker.
InteractionModuleState interactionState(){return studio.state(InteractionModuleState.class);
  }

class InteractionModuleState {
  final InteractionTheme theme=new InteractionTheme();
  InteractionConfig config;
  InteractionI18n i18n;
  RgbdSession rgbd;
  InteractionFrameProcessor processor;
  SkeletonProcessingSession skeletonSession;
  InteractionRuntime runtime;
  InteractionDesktopController desktop;
  SkeletonPublisher nuiPublisher;
  InteractionUI ui;
  PImage depthImage;
  volatile PointCloud interactionCloud;
  SkeletonPose3D skeleton;
  long lastProcessedFrame=-1;
  volatile boolean controlEnabled=false;
  volatile String status="";
}

String loadInteractionHandPreference(String defaultHand){
  String value=studio.userPreferences.get("interactivity.cursor.hand",defaultHand).toLowerCase(Locale.ROOT);
  return ("auto".equals(value)||"left".equals(value)||"right".equals(value))?value:defaultHand;
}
void saveInteractionHandPreference(String hand){
  studio.userPreferences.put("interactivity.cursor.hand",hand);
}

boolean interactionDeviceReady(KinectDevice device){
  // Interactivity consumes metric depth. Driver readiness can lag the module
  // session during reconnects, so the UI must key availability to the actual
  // capability and let the runtime surface connection state independently.
  return device!=null&&device.hasCapability("depth");
}
boolean interaction3dLive(){
  InteractionModuleState state=interactionState();
  return state.runtime!=null&&state.runtime.streamsLive();
}
void toggleInteractionControl(){
  InteractionModuleState state=interactionState();
  if(state.controlEnabled){
    state.controlEnabled=false;
    if(state.desktop!=null)state.desktop.setEnabled(false);
    state.status=state.i18n.tr("status.control_off");
    return;
  }
  // Desktop control is a frontend capability, not a camera-readiness safety gate.
  // The controller can be armed before a pose is available and simply waits for
  // valid body/hand observations. This keeps the button deterministic during
  // reconnects and removes the former "disabled for safety" latch.
  if(state.desktop==null||!state.desktop.available()){
    state.controlEnabled=false;
    state.status=state.desktop!=null&&state.desktop.error!=null&&!state.desktop.error.isEmpty()
      ?state.desktop.error:state.i18n.tr("status.desktop_unavailable");
    return;
  }
  state.controlEnabled=true;
  state.desktop.setEnabled(true);
  state.status=state.i18n.tr("status.control_on");
}
void interactivityMousePressed(){
  InteractionModuleState state=interactionState();
  // Module content is rendered below the Studio shell top bar.  Hit testing must
  // use the same content-local coordinate system as drawing/hover feedback.
  if(state.ui!=null)state.ui.handleMouse(studio.ui.pointerX(),studio.ui.pointerY());
}

class InteractionConfig {
  int workerJoinMs=2200,streamStaleMs=1800,previewHz=15,cursorMaxHz=60,cursorLostReleaseMs=800,
      cursorAutoHandSwitchMs=450,doubleClickStableMs=170,doubleClickCooldownMs=700,
      scrollCooldownMs=45,twoHandStableMs=180;
  boolean mirrorX=true;
  String hand="auto";
  float cursorAutoHandScoreMargin=.12f,cursorDeadzonePx=1.6f,cursorStationaryDeadzonePx=4.0f,
        cursorFastAlpha=.68f,cursorSlowAlpha=.14f,cursorFastDistancePx=46f,cursorPredictionMs=8f,
        cursorMaxJumpPx=120f,cursorConfidenceFloor=.25f,cursorSteadySpeedPxPerSec=95f,
        cursorMaxSpeedPxPerSec=4200f,cursorMaxAccelPxPerSec2=22000f,volumeHalfWidthM=.55f,volumeTopM=.42f,
        volumeBottomM=.48f,minHandForwardM=.015f,pressForwardM=.16f,releaseForwardM=.09f,
        scrollThresholdM=.018f,scrollGainPerM=82f,
        bodyViewMinHeightM=.92f,bodyViewMinWidthM=.72f,bodyViewMaxHeightM=2.30f,bodyViewMaxWidthM=2.05f,
        bodyViewCenterYOffsetM=-.03f,bodyViewTargetOccupancy=.84f,bodyViewArmOccupancy=.86f,
        bodyViewZoomOutResponse=.24f,bodyViewEmergencyZoomOutResponse=.72f,bodyViewEmergencyRatio=.82f,
        bodyViewZoomInResponse=.032f,bodyViewCenterResponse=.075f,bodyViewDeadband=.045f;
  int bodyViewShrinkDelayFrames=24;

  void load(File file){
    ConfigRules r=studio.services.configRules;
    Properties p=r.load(file,"interactivity");
    workerJoinMs=r.integer(p,"transport.workerJoinMs",workerJoinMs,250,10000);
    streamStaleMs=r.integer(p,"transport.streamStaleMs",streamStaleMs,250,10000);
    previewHz=r.integer(p,"vision.previewHz",previewHz,1,60);
    mirrorX=r.flag(p,"cursor.mirrorX",mirrorX);
    hand=r.text(p,"cursor.hand",hand).toLowerCase(Locale.ROOT);
    if(!("auto".equals(hand)||"left".equals(hand)||"right".equals(hand)))hand="auto";
    cursorMaxHz=r.integer(p,"cursor.maxHz",cursorMaxHz,10,240);
    cursorLostReleaseMs=r.integer(p,"cursor.lostReleaseMs",cursorLostReleaseMs,100,5000);
    cursorAutoHandSwitchMs=r.integer(p,"cursor.autoHandSwitchMs",cursorAutoHandSwitchMs,50,5000);
    cursorAutoHandScoreMargin=r.decimal(p,"cursor.autoHandScoreMargin",cursorAutoHandScoreMargin,0f,1f);
    cursorDeadzonePx=r.decimal(p,"cursor.deadzonePx",cursorDeadzonePx,0f,50f);
    cursorStationaryDeadzonePx=r.decimal(p,"cursor.stationaryDeadzonePx",cursorStationaryDeadzonePx,0f,80f);
    cursorFastAlpha=r.decimal(p,"cursor.fastAlpha",cursorFastAlpha,.01f,.999f);
    cursorSlowAlpha=r.decimal(p,"cursor.slowAlpha",cursorSlowAlpha,.01f,.999f);
    cursorFastDistancePx=r.decimal(p,"cursor.fastDistancePx",cursorFastDistancePx,1f,1000f);
    cursorPredictionMs=r.decimal(p,"cursor.predictionMs",cursorPredictionMs,0f,100f);
    cursorMaxJumpPx=r.decimal(p,"cursor.maxJumpPx",cursorMaxJumpPx,1f,2000f);
    cursorConfidenceFloor=r.decimal(p,"cursor.confidenceFloor",cursorConfidenceFloor,0f,.99f);
    cursorSteadySpeedPxPerSec=r.decimal(p,"cursor.steadySpeedPxPerSec",cursorSteadySpeedPxPerSec,1f,1000f);
    cursorMaxSpeedPxPerSec=r.decimal(p,"cursor.maxSpeedPxPerSec",cursorMaxSpeedPxPerSec,200f,12000f);
    cursorMaxAccelPxPerSec2=r.decimal(p,"cursor.maxAccelPxPerSec2",cursorMaxAccelPxPerSec2,500f,80000f);
    volumeHalfWidthM=r.decimal(p,"cursor.volumeHalfWidthM",volumeHalfWidthM,.1f,2f);
    volumeTopM=r.decimal(p,"cursor.volumeTopM",volumeTopM,.05f,2f);
    volumeBottomM=r.decimal(p,"cursor.volumeBottomM",volumeBottomM,.05f,2f);
    minHandForwardM=r.decimal(p,"cursor.minHandForwardM",minHandForwardM,0f,.5f);
    pressForwardM=r.decimal(p,"gesture.pressForwardM",pressForwardM,.01f,.8f);
    releaseForwardM=r.decimal(p,"gesture.releaseForwardM",releaseForwardM,0f,pressForwardM);
    twoHandStableMs=r.integer(p,"gesture.twoHandStableMs",twoHandStableMs,0,3000);
    doubleClickStableMs=r.integer(p,"gesture.doubleClickStableMs",doubleClickStableMs,0,3000);
    doubleClickCooldownMs=r.integer(p,"gesture.doubleClickCooldownMs",doubleClickCooldownMs,0,5000);
    scrollCooldownMs=r.integer(p,"gesture.scrollCooldownMs",scrollCooldownMs,0,1000);
    scrollThresholdM=r.decimal(p,"gesture.scrollThresholdM",scrollThresholdM,.001f,.5f);
    scrollGainPerM=r.decimal(p,"gesture.scrollGainPerM",scrollGainPerM,1f,500f);
    bodyViewMinHeightM=r.decimal(p,"view.bodyMinHeightM",bodyViewMinHeightM,.55f,2.20f);
    bodyViewMinWidthM=r.decimal(p,"view.bodyMinWidthM",bodyViewMinWidthM,.45f,1.50f);
    bodyViewMaxHeightM=r.decimal(p,"view.bodyMaxHeightM",bodyViewMaxHeightM,1.20f,3.20f);
    bodyViewMaxWidthM=r.decimal(p,"view.bodyMaxWidthM",bodyViewMaxWidthM,1.20f,3.20f);
    bodyViewTargetOccupancy=r.decimal(p,"view.bodyTargetOccupancy",bodyViewTargetOccupancy,.60f,.94f);
    bodyViewArmOccupancy=r.decimal(p,"view.bodyArmOccupancy",bodyViewArmOccupancy,.65f,.96f);
    bodyViewCenterYOffsetM=r.decimal(p,"view.bodyCenterYOffsetM",bodyViewCenterYOffsetM,-.35f,.35f);
    bodyViewZoomOutResponse=r.decimal(p,"view.autoFit.zoomOutResponse",bodyViewZoomOutResponse,.01f,1f);
    bodyViewEmergencyZoomOutResponse=r.decimal(p,"view.autoFit.emergencyZoomOutResponse",bodyViewEmergencyZoomOutResponse,.10f,1f);
    bodyViewEmergencyRatio=r.decimal(p,"view.autoFit.emergencyRatio",bodyViewEmergencyRatio,.45f,.98f);
    bodyViewZoomInResponse=r.decimal(p,"view.autoFit.zoomInResponse",bodyViewZoomInResponse,.001f,.25f);
    bodyViewCenterResponse=r.decimal(p,"view.autoFit.centerResponse",bodyViewCenterResponse,.001f,.35f);
    bodyViewDeadband=r.decimal(p,"view.autoFit.deadband",bodyViewDeadband,0f,.30f);
    bodyViewShrinkDelayFrames=r.integer(p,"view.autoFit.shrinkDelayFrames",bodyViewShrinkDelayFrames,0,240);
  }
}
void cycleInteractionHand(){
  InteractionModuleState state=interactionState();if(state.config==null)return;
  String current=state.config.hand==null?"auto":state.config.hand;
  String next="auto".equals(current)?"right":("right".equals(current)?"left":"auto");
  state.config.hand=next;
  if(state.desktop!=null)state.desktop.setHandMode(next);
  saveInteractionHandPreference(next);
  state.status=state.i18n.tr("button.hand")+": "+state.i18n.tr("hand."+next);
}

void prepareInteractivityRgbdCore(){
  InteractionModuleState state=interactionState();
  state.rgbd=studio.services.processingBlocks.openRgbd(state.i18n,studio.selectedKinect());
}
void refreshInteractionCalibrationForSelectedDevice(){
  InteractionModuleState state=interactionState();if(state.rgbd==null)return;
  state.rgbd.selectDevice(studio.selectedKinect(),true);if(state.skeletonSession!=null)state.skeletonSession.reset();
}
void setupInteractivityModule(){
  interactionState().config=new InteractionConfig();interactionState().config.load(studio.services.paths.resource("interactivity","config.properties"));
  interactionState().config.hand=loadInteractionHandPreference(interactionState().config.hand);

  interactionState().i18n=new InteractionI18n(studio.currentLanguage());
  prepareInteractivityRgbdCore();
  interactionState().skeletonSession=studio.services.processingBlocks.openSkeleton(interactionState().rgbd);

  interactionState().processor=new InteractionFrameProcessor(interactionState().config,interactionState().skeletonSession);

  interactionState().desktop=new InteractionDesktopController(interactionState().config);

  interactionState().nuiPublisher=new SkeletonPublisher();
  interactionState().rgbd.setHqColorRequested(false);
  interactionState().rgbd.setDepthOnlyRequested(true);
  interactionState().runtime=new InteractionRuntime(interactionState().config,interactionState().rgbd,interactionState().processor);

  interactionState().ui=new InteractionUI();interactionState().status=interactionState().i18n.tr("status.ready");

}
void activateInteractivityModule(){
  interactionState().lastProcessedFrame=-1;interactionState().skeleton=null;interactionState().depthImage=null;interactionState().interactionCloud=null;

  if(interactionState().skeletonSession!=null)interactionState().skeletonSession.reset();
  // Interactivity always owns the complete native depth FOV; RGB is not requested.
  if(interactionState().rgbd!=null){interactionState().rgbd.setHqColorRequested(false);interactionState().rgbd.setDepthOnlyRequested(true);}

  if(interactionState().runtime!=null)interactionState().runtime.start();
}
void requestDeactivateInteractivityModule(){
  interactionState().controlEnabled=false;
  if(interactionState().desktop!=null)interactionState().desktop.setEnabled(false);

  if(interactionState().runtime!=null)interactionState().runtime.requestStop();
}
void deactivateInteractivityModule(){
  interactionState().controlEnabled=false;
  if(interactionState().desktop!=null)interactionState().desktop.setEnabled(false);

  if(interactionState().runtime!=null)interactionState().runtime.stop(false);
  if(interactionState().nuiPublisher!=null)interactionState().nuiPublisher.close();

}
void disposeInteractivityModule(){deactivateInteractivityModule();}
void drawInteractivityModule(){background(interactionState().theme.BG);serviceInteractivityFrames();
  if(interactionState().ui!=null)interactionState().ui.draw();}

// UI thread: immutable snapshots only. No transport or CV work executes here.
void serviceInteractivityFrames(){
  InteractionProcessedFrame p=interactionState().processor==null?null:interactionState().processor.latest();

  if(p!=null&&p.frameNumber!=interactionState().lastProcessedFrame){interactionState().lastProcessedFrame=p.frameNumber;
    interactionState().skeleton=p.skeleton;interactionState().interactionCloud=p.bodyCloud;if(interactionState().nuiPublisher!=null)interactionState().nuiPublisher.publish(p.skeleton,p.frameNumber);
    applyInteractionDepthPreview(p.previewPixels,p.previewWidth,p.previewHeight);}
  if(interactionState().desktop!=null){interactionState().desktop.setEnabled(interactionState().controlEnabled);
    // Feed every current pose to the controller while control is enabled. The
    // controller owns tracking gates, hysteresis and release timeouts, so brief
    // confidence changes cannot freeze the OS cursor or leave a button held.
    if(interactionState().controlEnabled)interactionState().desktop.update(interactionState().skeleton);
    }
}
void applyInteractionDepthPreview(int[] pixels,int w,int h){
  if(pixels==null||w<=0||h<=0||pixels.length!=w*h)return;
  if(interactionState().depthImage==null||interactionState().depthImage.width!=w||interactionState().depthImage.height!=h)
    interactionState().depthImage=createImage(w,h,RGB);
  interactionState().depthImage.loadPixels();arrayCopy(pixels,interactionState().depthImage.pixels);
  interactionState().depthImage.updatePixels();
}

class InteractionI18n extends ModuleI18n {InteractionI18n(String requested){super("interactivity",requested);
    }}

class InteractionTheme {
  final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE_ALT=0xFF202832,SURFACE_RAISED=0xFF293440;

  final int BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,ACCENT=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B,BAD=0xFFE17D7D,PREVIEW=0xFF0B0F13,GRID=0xFF35404A;

  final int FONT_TINY=STUDIO_FONT_TINY,FONT_SMALL=STUDIO_FONT_SMALL,FONT_BODY=STUDIO_FONT_BODY,FONT_METRIC=STUDIO_FONT_METRIC,FONT_TITLE=STUDIO_FONT_TITLE;

}

class InteractionVisionSnapshot {
  final DepthFrame depthFrame;final InfraredFrame infraredFrame;final long depthTickMs,sequence;
  InteractionVisionSnapshot(DepthFrame depth,InfraredFrame infrared){
    depthFrame=depth;this.infraredFrame=infrared;depthTickMs=depth==null?0:depth.timestampUs/1000L;
    sequence=depth==null?-1:depth.frameNumber;
  }
  long key(){return sequence;}
}
class InteractionProcessedFrame {long frameNumber=-1;int[] previewPixels;int previewWidth=0,previewHeight=0;SkeletonPose3D skeleton;PointCloud bodyCloud;
  }

class InteractionFrameProcessor {
  final InteractionConfig cfg;final SkeletonProcessingSession skeletonSession;final Object lock=new Object();
  volatile boolean running=false;volatile long runGeneration=0;volatile InteractionProcessedFrame published=null;
  volatile long lastPublishedMs=0;long lastPreviewMs=0;int[] depthPreviewBuffer=null;Thread worker;InteractionVisionSnapshot pending=null;

  InteractionFrameProcessor(InteractionConfig cfg,SkeletonProcessingSession skeletonSession){this.cfg=cfg;
    this.skeletonSession=skeletonSession;}
  void start(){synchronized(lock){if(running)return;running=true;pending=null;published=null;
      final long generation=++runGeneration;worker=studio.services.workers.start("Interaction-3D-Fusion",new Runnable(){public void run(){loop(generation);}
        });}}
  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;pending=null;
      lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread())t.interrupt();
    }
  void stop(){Thread t;synchronized(lock){running=false;++runGeneration;pending=null;
      lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();
      try{t.join(min(1000,cfg.workerJoinMs));}catch(InterruptedException e){Thread.currentThread().interrupt();
        }}}
  void submit(InteractionVisionSnapshot f){if(f==null||f.depthFrame==null||f.depthFrame.depth==null)return;
    synchronized(lock){if(!running)return;pending=f;lock.notifyAll();}}
  InteractionProcessedFrame latest(){return published;}
  void clearPublished(){synchronized(lock){pending=null;published=null;lastPublishedMs=0;
      lastPreviewMs=0;}}
  void loop(long generation){while(true){InteractionVisionSnapshot f;synchronized(lock){while(running&&generation==runGeneration&&pending==null)try{lock.wait();
          }catch(InterruptedException e){if(!running||generation!=runGeneration)return;
          }if(!running||generation!=runGeneration)return;f=pending;pending=null;}try{InteractionProcessedFrame out=new InteractionProcessedFrame();
        SkeletonModuleFrame solved=skeletonSession.process(f.depthFrame,f.infraredFrame,f.depthTickMs>0?f.depthTickMs:millis64());
        out.frameNumber=f.key();out.skeleton=solved.pose;out.bodyCloud=solved.bodyCloud;
        long now=millis64();if(lastPreviewMs==0||now-lastPreviewMs>=1000/max(1,cfg.previewHz)){
          out.previewPixels=metricDepthPreview(f.depthFrame);
          if(out.previewPixels!=null){out.previewWidth=f.depthFrame.width;out.previewHeight=f.depthFrame.height;}
          lastPreviewMs=now;}if(generation==runGeneration){published=out;lastPublishedMs=now;
          }}catch(Exception e){if(generation==runGeneration)println("Interactivity 3D processor warning: "+safeStudioMessage(e));
        }}}
  int[] metricDepthPreview(DepthFrame frame){
    if(frame==null||frame.depth==null||frame.width<=0||frame.height<=0)return null;
    int needed=frame.width*frame.height;if(depthPreviewBuffer==null||depthPreviewBuffer.length!=needed)depthPreviewBuffer=new int[needed];
    int[] out=depthPreviewBuffer;int near=500,far=4500;
    for(int i=0;i<out.length&&i<frame.depth.length;i++){
      int mm=frame.depth[i]&0xffff;if(mm==0){out[i]=0xFF080B10;continue;}
      float t=constrain((mm-near)/(float)(far-near),0,1),lum=constrain(1.0f-.78f*t,.18f,1.0f);
      int r=round(0x58*lum),g=round(0xC7*lum),b=round(0xF3*lum);out[i]=0xFF000000|(r<<16)|(g<<8)|b;
    }
    return out;
  }
}

class InteractionRuntime {
  final InteractionConfig cfg;final RgbdSession rgbd;final InteractionFrameProcessor processor;
  final Object lock=new Object();volatile boolean running=false;volatile long runGeneration=0;
  volatile long lastInputMs=0;Thread connectionWorker;long lastSubmitted=-1;
  InteractionRuntime(InteractionConfig c,RgbdSession s,InteractionFrameProcessor p){cfg=c;
    rgbd=s;processor=p;}
  void start(){synchronized(lock){if(running)return;running=true;final long generation=++runGeneration;
      lastInputMs=millis64();lastSubmitted=-1;rgbd.start();processor.start();connectionWorker=studio.services.workers.start("Interaction-Depth",new Runnable(){
        public void run(){connectionLoop(generation);}});}}
  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;t=connectionWorker;
      connectionWorker=null;}if(t!=null&&t!=Thread.currentThread())t.interrupt();
    processor.requestStop();rgbd.requestStop(true);}
  void stop(boolean keepRgbd){Thread t;synchronized(lock){running=false;++runGeneration;
      t=connectionWorker;connectionWorker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();
      try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();
        }}processor.stop();if(!keepRgbd)rgbd.stop(true);else rgbd.clearConsumerPairs();
    }
  boolean streamsLive(){return rgbd.streamsLive(cfg.streamStaleMs);}
  void connectionLoop(long generation){while(running&&generation==runGeneration){try{rgbd.updateLiveness();
        DepthFrame depth=rgbd.latestDepthAfter(lastSubmitted);if(depth!=null){lastSubmitted=depth.frameNumber;
          lastInputMs=millis64();processor.submit(new InteractionVisionSnapshot(depth,null));
          }Thread.sleep(2);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;
        Thread.currentThread().interrupt();return;}catch(Exception e){if(running&&generation==runGeneration)println("Interactivity depth warning: "+safeStudioMessage(e));
        }}}
}

class InteractionDesktopController {
  final InteractionConfig cfg;Robot robot;Rectangle desktopBounds;
  volatile boolean enabled=false,dragging=false,buttonDown=false,twoHandMode=false;
  volatile String handMode;
  float sx=Float.NaN,sy=Float.NaN,cursorVx=0,cursorVy=0,pointerVx=0,pointerVy=0,lastTargetX=Float.NaN,lastTargetY=Float.NaN;
  long lastMoveMs=0,lastPointerMs=0,lastTrackedMs=0,moveCount=0,doubleClickCount=0,dragCount=0,scrollCount=0;
  volatile int lastX=-1,lastY=-1;String error="";
  long twoHandsSince=0,bothPushedSince=0,lastDoubleMs=0,lastScrollMs=0,autoCandidateSince=0;
  float lastScrollY=Float.NaN;boolean doubleFired=false,autoLeft=false,autoInitialized=false,autoCandidateLeft=false;
  String interactionState="gesture.cloud_only";
  InteractionDesktopController(InteractionConfig cfg){this.cfg=cfg;handMode=cfg.hand;
    try{if(GraphicsEnvironment.isHeadless())throw new AWTException("headless");robot=new Robot();
      robot.setAutoDelay(3);desktopBounds=desktopBounds();}catch(Exception e){error=safeStudioMessage(e);
      robot=null;desktopBounds=new Rectangle(0,0,1,1);}}
  Rectangle desktopBounds(){Rectangle all=null;for(GraphicsDevice gd:GraphicsEnvironment.getLocalGraphicsEnvironment().getScreenDevices()){Rectangle b=gd.getDefaultConfiguration().getBounds();
      all=all==null?new Rectangle(b):all.union(b);}return all==null?new Rectangle(0,0,1920,1080):all;
    }
  boolean available(){return robot!=null;}
  void setEnabled(boolean on){boolean next=on&&available();if(enabled==next)return;
    enabled=next;if(!enabled){releaseDrag();resetGesture();}resetPointerFilter();
    }
  void resetPointerFilter(){sx=sy=Float.NaN;cursorVx=cursorVy=pointerVx=pointerVy=0;lastTargetX=lastTargetY=Float.NaN;
    lastX=lastY=-1;lastPointerMs=0;}
  void resetGesture(){twoHandMode=false;twoHandsSince=bothPushedSince=0;lastScrollY=Float.NaN;
    doubleFired=false;interactionState="gesture.cloud_only";}
  String gestureKey(){if(!enabled)return "gesture.disabled";if(dragging)return "gesture.dragging";
    return interactionState;}
  String cycleHandMode(){String next="auto".equals(handMode)?"right":("right".equals(handMode)?"left":"auto");
    setHandMode(next);return handMode;}
  void setHandMode(String mode){String next=("auto".equals(mode)||"left".equals(mode)||"right".equals(mode))?mode:"auto";
    if(next.equals(handMode))return;releaseDrag();handMode=next;cfg.hand=next;autoInitialized=false;
    autoCandidateSince=0;resetPointerFilter();resetGesture();}
  float handScore(SkeletonPose3D s,boolean left){SkeletonJoint3D h=left?s.leftHand:s.rightHand;
    if(h==null||!h.tracked())return -1;float confidence=constrain(h.confidence,0,1),forward=constrain(forwardDistance(s,h)/.35f,0,1);
    return .78f*confidence+.22f*forward;}
  void updateAutoHand(SkeletonPose3D s,long now){if(!"auto".equals(handMode)||s==null)return;
    boolean lt=s.leftHandTracked(),rt=s.rightHandTracked();if(!lt&&!rt)return;if(!autoInitialized){autoLeft=lt&&(!rt||handScore(s,true)>=handScore(s,false));
      autoInitialized=true;autoCandidateSince=0;return;}if(autoLeft&&!lt&&rt){autoLeft=false;
      autoCandidateSince=0;return;}if(!autoLeft&&!rt&&lt){autoLeft=true;autoCandidateSince=0;
      return;}if(!lt||!rt)return;if(buttonDown||dragging){autoCandidateSince=0;return;
      }float current=handScore(s,autoLeft),other=handScore(s,!autoLeft);boolean challenger=other>current+cfg.cursorAutoHandScoreMargin;
    if(!challenger){autoCandidateSince=0;return;}boolean candidate=!autoLeft;if(autoCandidateSince==0||autoCandidateLeft!=candidate){autoCandidateLeft=candidate;
      autoCandidateSince=now;return;}if(now-autoCandidateSince>=cfg.cursorAutoHandSwitchMs){autoLeft=candidate;
      autoCandidateSince=0;releaseDrag();resetPointerFilter();}}
  boolean primaryLeft(SkeletonPose3D s){if(s==null)return false;if("left".equals(handMode)&&s.leftHandTracked())return true;
    if("right".equals(handMode)&&s.rightHandTracked())return false;if("auto".equals(handMode)){if(autoInitialized&&autoLeft&&s.leftHandTracked())return true;
      if(autoInitialized&&!autoLeft&&s.rightHandTracked())return false;if(s.rightHandTracked()&&!s.leftHandTracked())return false;
      if(s.leftHandTracked()&&!s.rightHandTracked())return true;return handScore(s,true)>handScore(s,false);
      }if(s.rightHandTracked())return false;return s.leftHandTracked();}
  SkeletonJoint3D primaryJoint(SkeletonPose3D s){if(s==null)return null;if(primaryLeft(s)&&s.leftHandTracked())return s.leftHand;
    if(!primaryLeft(s)&&s.rightHandTracked())return s.rightHand;if(s.rightHandTracked())return s.rightHand;
    if(s.leftHandTracked())return s.leftHand;return null;}
  SkeletonJoint3D secondaryJoint(SkeletonPose3D s){if(s==null||!s.rightHandTracked()||!s.leftHandTracked())return null;
    return primaryLeft(s)?s.rightHand:s.leftHand;}
  PVector torsoNormal(SkeletonPose3D s){if(s==null||!s.torsoTracked())return null;
    PVector xAxis=PVector.sub(s.rightShoulder.world,s.leftShoulder.world);if(xAxis.mag()<0.05f)xAxis.set(1,0,0);
    else xAxis.normalize();PVector yAxis=PVector.sub(s.spine.world,s.shoulderCenter.world);
    if(yAxis.mag()<0.04f)yAxis.set(0,1,0);else yAxis.normalize();PVector normal=xAxis.cross(yAxis);
    if(normal.mag()<0.05f)normal.set(0,0,1);else normal.normalize();if(normal.z<0)normal.mult(-1);
    return normal;}
  float forwardDistance(SkeletonPose3D s,SkeletonJoint3D hand){PVector normal=torsoNormal(s);
    if(normal==null||hand==null||!hand.tracked())return -1;return -PVector.sub(hand.world,s.spine.world).dot(normal);
    }
  PVector screenPoint(SkeletonPose3D s,SkeletonJoint3D hand){
    if(s==null||hand==null||!hand.tracked()||!s.torsoTracked())return null;
    PVector xAxis=PVector.sub(s.rightShoulder.world,s.leftShoulder.world);float shoulderWidth=xAxis.mag();if(shoulderWidth<0.05f){xAxis.set(1,0,0);shoulderWidth=.38f;}
    else xAxis.normalize();PVector yAxis=PVector.sub(s.spine.world,s.shoulderCenter.world);
    if(yAxis.mag()<0.04f)yAxis.set(0,1,0);else yAxis.normalize();PVector normal=torsoNormal(s);
    if(normal==null)return null;PVector origin=PVector.lerp(s.spine.world,s.shoulderCenter.world,.28f),rel=PVector.sub(hand.world,origin);
    float lateral=rel.dot(xAxis),vertical=rel.dot(yAxis),forward=-rel.dot(normal);
    // Pointing remains available close to the torso plane. Forward depth is used
    // mainly for press/release gestures, while lateral/vertical hand motion owns
    // cursor position. This makes ordinary arm extension sufficient for mouse use.
    if(forward<cfg.minHandForwardM&&hand.confidence<.55f)return null;float bodyScale=constrain(shoulderWidth/.38f,.76f,1.34f);
    float halfW=cfg.volumeHalfWidthM*bodyScale,top=cfg.volumeTopM*bodyScale,bottom=cfg.volumeBottomM*bodyScale;
    float nx=(lateral+halfW)/(2*halfW),ny=(vertical+top)/max(.05f,top+bottom);
    float reach=1.0f+.28f*constrain((forward-cfg.minHandForwardM)/max(.08f,cfg.pressForwardM),0,1);
    nx=.5f+(nx-.5f)*reach;ny=.5f+(ny-.5f)*lerp(1.0f,1.10f,constrain(forward/.30f,0,1));
    nx=constrain(nx,0,1);ny=constrain(ny,0,1);if(cfg.mirrorX)nx=1-nx;return new PVector(desktopBounds.x+nx*max(1,desktopBounds.width-1),desktopBounds.y+ny*max(1,
      desktopBounds.height-1));
  }
  void update(SkeletonPose3D s){
    long now=millis64();
    boolean usable=s!=null&&s.tracked&&s.torsoTracked()&&(s.leftHandTracked()||s.rightHandTracked());
    if(!enabled||robot==null||!usable){if(enabled&&now-lastTrackedMs>cfg.cursorLostReleaseMs){releaseDrag();
        resetGesture();resetPointerFilter();}return;}
    updateAutoHand(s,now);SkeletonJoint3D primary=primaryJoint(s);if(primary==null)return;
    // The visual skeleton may remain in OCCLUDED state through a short depth
    // dropout, but desktop input requires a live/inferred hand observation.
    // This preserves cursor position without synthesizing clicks or drags from
    // a held pose.
    if(!primary.observed()){if(buttonDown&&now-lastTrackedMs>cfg.cursorLostReleaseMs)releaseDrag();return;}
    lastTrackedMs=now;SkeletonJoint3D secondary=secondaryJoint(s);if(secondary!=null&&!secondary.observed())secondary=null;
    PVector a=screenPoint(s,primary),b=screenPoint(s,secondary);

    if(a==null){if(buttonDown&&forwardDistance(s,primary)<=cfg.releaseForwardM)releaseDrag();interactionState="gesture.cloud_only";return;}
    boolean two=secondary!=null&&b!=null;float pointerQuality=constrain(.72f*primary.confidence+.28f*s.interactionConfidence,0,1);updatePointer(a,now,pointerQuality);
    float pf=forwardDistance(s,primary);boolean pPush=pf>=cfg.pressForwardM,pRelease=pf<=cfg.releaseForwardM;

    if(!two){
      twoHandsSince=0;twoHandMode=false;bothPushedSince=0;doubleFired=false;lastScrollY=Float.NaN;

      if(!buttonDown&&pPush){pressPrimary();dragging=buttonDown;if(buttonDown)dragCount++;
        }else if(buttonDown&&pRelease)releaseDrag();
      interactionState=buttonDown?"gesture.dragging":"gesture.pointer";return;
    }
    if(twoHandsSince==0)twoHandsSince=now;if(now-twoHandsSince>=cfg.twoHandStableMs)twoHandMode=true;
    if(!twoHandMode){interactionState="gesture.two_hand_wait";return;}
    float sf=forwardDistance(s,secondary);boolean sPush=sf>=cfg.pressForwardM;
    if(pPush&&sPush){
      releaseDrag();interactionState="gesture.double_click";if(bothPushedSince==0)bothPushedSince=now;
      if(!doubleFired&&now-bothPushedSince>=cfg.doubleClickStableMs&&now-lastDoubleMs>=cfg.doubleClickCooldownMs){doubleClick();
        doubleFired=true;lastDoubleMs=now;}return;
    }
    bothPushedSince=0;if(!pPush&&!sPush)doubleFired=false;
    if(pPush){if(!buttonDown){pressPrimary();dragging=buttonDown;if(buttonDown)dragCount++;
        }interactionState="gesture.dragging";lastScrollY=Float.NaN;return;}
    if(buttonDown&&pRelease)releaseDrag();
    if(!buttonDown){interactionState="gesture.scroll";updateScroll(s,now);}else interactionState="gesture.two_hand_ready";

  }
  void updatePointer(PVector target,long now,float confidence){
    if(target==null||now-lastMoveMs<1000/max(1,cfg.cursorMaxHz))return;lastMoveMs=now;
    float tx=target.x,ty=target.y,dt=lastPointerMs==0?1.0f/max(30,cfg.cursorMaxHz):constrain((now-lastPointerMs)/1000.0f,.004f,.08f);
    lastPointerMs=now;
    if(Float.isNaN(lastTargetX)){lastTargetX=tx;lastTargetY=ty;}
    float rvx=(tx-lastTargetX)/dt,rvy=(ty-lastTargetY)/dt,rawSpeed=sqrt(rvx*rvx+rvy*rvy);
    lastTargetX=tx;lastTargetY=ty;
    // Low-pass the measured hand velocity first. This prevents a one-frame joint
    // correction from being interpreted as intentional pointer acceleration.
    float va=1-exp(-10.0f*dt);cursorVx=lerp(cursorVx,rvx,va);cursorVy=lerp(cursorVy,rvy,va);
    if(Float.isNaN(sx)){sx=tx;sy=ty;cursorVx=cursorVy=pointerVx=pointerVy=0;}else{
      float jump=dist(sx,sy,tx,ty);if(jump>cfg.cursorMaxJumpPx){float scale=cfg.cursorMaxJumpPx/max(jump,.001f);
        tx=sx+(tx-sx)*scale;ty=sy+(ty-sy)*scale;}
      float d=dist(sx,sy,tx,ty),quality=constrain((confidence-cfg.cursorConfidenceFloor)/max(.001f,1-cfg.cursorConfidenceFloor),0,1);
      // A true pre-filter dead zone anchors the cursor instead of merely suppressing
      // OS mouseMove calls while the internal filtered position slowly drifts.
      float motion=constrain(rawSpeed/max(1,cfg.cursorSteadySpeedPxPerSec),0,1);
      float anchorRadius=lerp(cfg.cursorStationaryDeadzonePx,cfg.cursorDeadzonePx,motion);
      if(d<=anchorRadius){tx=sx;ty=sy;d=0;}else if(d>0){float keep=max(0,d-anchorRadius*.72f)/d;tx=sx+(tx-sx)*keep;ty=sy+(ty-sy)*keep;d=dist(sx,sy,tx,ty);}
      float speedMix=constrain(d/max(1,cfg.cursorFastDistancePx),0,1),prediction=(cfg.cursorPredictionMs/1000.0f)*speedMix*quality;
      float px=tx+cursorVx*prediction,py=ty+cursorVy*prediction,a=lerp(cfg.cursorSlowAlpha,cfg.cursorFastAlpha,speedMix)*lerp(.55f,1.0f,quality);
      a=constrain(a,.025f,.999f);a=1.0f-pow(1.0f-a,constrain(dt/0.0166667f,.25f,5.0f));
      float desiredX=lerp(sx,px,a),desiredY=lerp(sy,py,a);
      // Slew-rate limiting removes residual skeleton spikes without making normal
      // hand motion viscous. Both speed and acceleration are bounded per second,
      // so behavior is stable across 30/60/120 Hz update rates.
      float desiredVx=(desiredX-sx)/dt,desiredVy=(desiredY-sy)/dt,desiredSpeed=sqrt(desiredVx*desiredVx+desiredVy*desiredVy);
      if(desiredSpeed>cfg.cursorMaxSpeedPxPerSec){float k=cfg.cursorMaxSpeedPxPerSec/max(desiredSpeed,.001f);desiredVx*=k;desiredVy*=k;}
      float dvx=desiredVx-pointerVx,dvy=desiredVy-pointerVy,dv=sqrt(dvx*dvx+dvy*dvy),maxDv=cfg.cursorMaxAccelPxPerSec2*dt;
      if(dv>maxDv){float k=maxDv/max(dv,.001f);desiredVx=pointerVx+dvx*k;desiredVy=pointerVy+dvy*k;}
      // Blend toward the bounded output velocity, preserving responsiveness while
      // keeping the velocity estimator independent from a single raw joint sample.
      float outBlend=1-exp(-18.0f*dt);pointerVx=lerp(pointerVx,desiredVx,outBlend);pointerVy=lerp(pointerVy,desiredVy,outBlend);
      sx+=pointerVx*dt;sy+=pointerVy*dt;
    }
    sx=constrain(sx,desktopBounds.x,desktopBounds.x+max(0,desktopBounds.width-1));
    sy=constrain(sy,desktopBounds.y,desktopBounds.y+max(0,desktopBounds.height-1));
    int nxp=round(sx),nyp=round(sy);float movement=lastX<0?Float.MAX_VALUE:dist(lastX,lastY,nxp,nyp),outputSpeed=sqrt(pointerVx*pointerVx+pointerVy*pointerVy);
    float speedMix=constrain(outputSpeed/max(1,cfg.cursorSteadySpeedPxPerSec*4.0f),0,1),deadzone=lerp(cfg.cursorStationaryDeadzonePx,cfg.cursorDeadzonePx,speedMix);
    if(lastX>=0&&movement<deadzone)return;lastX=nxp;lastY=nyp;try{robot.mouseMove(lastX,lastY);
      moveCount++;error="";}catch(Exception e){error=safeStudioMessage(e);}
  }
  void updateScroll(SkeletonPose3D s,long now){
    float avg=(s.leftHand.world.y+s.rightHand.world.y)*0.5f;if(Float.isNaN(lastScrollY)){lastScrollY=avg;
      return;}float delta=avg-lastScrollY;
    if(abs(delta)>=cfg.scrollThresholdM&&now-lastScrollMs>=cfg.scrollCooldownMs){int units=constrain(round(delta*cfg.scrollGainPerM),-5,5);
      if(units!=0){try{robot.mouseWheel(units);scrollCount+=abs(units);}catch(Exception e){error=safeStudioMessage(e);
          }lastScrollY=avg;lastScrollMs=now;}}else if(abs(delta)<cfg.scrollThresholdM*.35f)lastScrollY=lerp(lastScrollY,avg,.08f);

  }
  void pressPrimary(){if(!enabled||robot==null||buttonDown)return;try{robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);
      buttonDown=true;}catch(Exception e){error=safeStudioMessage(e);}}
  void releasePrimary(){if(robot==null||!buttonDown)return;try{robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);
      }catch(Exception e){error=safeStudioMessage(e);}buttonDown=false;}
  void doubleClick(){if(enabled&&robot!=null){try{robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);
        robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);
        robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);doubleClickCount++;}catch(Exception e){error=safeStudioMessage(e);
        }}}
  void releaseDrag(){releasePrimary();dragging=false;}
}

class InteractionUI {
  final StudioUiButton enableButton=new StudioUiButton(),handButton=new StudioUiButton(),releaseButton=new StudioUiButton();
  // Auto-framing state for the Body3D viewport.  These values are deliberately
  // UI-owned: tracking remains metric and camera-space correct, while the view
  // smoothly follows the currently segmented body without feeding display
  // transforms back into the pose solver.
  final StableViewportFilter bodyViewFilter=new StableViewportFilter(); long bodyViewTrackingId=0;

  float statusHeight(){return studio.ui.metricPanelHeight(max(80,width-2*studioUiMargin()),8,false);
    }
  float actionHeight(float panelW){return studio.ui.actionPanelHeight(panelW,3,true);
    }
  void draw(){
    InteractionTheme theme=interactionState().theme;float m=studioUiMargin(),gap=studioUiGap(),w=max(80,width-2*m);
    drawHeader();
    float statusY=studioUiHeaderHeight()+gap,statusH=statusHeight();drawStatus(m,statusY,w,statusH);

    float bodyY=statusY+statusH+gap,bodyH=max(1,studio.contentHeight-bodyY-m),actionsH=actionHeight(w);

    StudioUiRect[] bands=studio.ui.vertical(m,bodyY,w,bodyH,gap,new float[]{220,actionsH},new float[]{80,actionsH},new float[]{1,0});

    drawVision(bands[0].x,bands[0].y,bands[0].w,bands[0].h);
    StudioUiRect actionPanel=bands[1];drawActions(actionPanel.x,actionPanel.y,actionPanel.w,actionPanel.h);

  }
  void drawHeader(){
    studio.ui.renderer.header(interactionState().i18n,interactionState().i18n.tr("app.title"));

  }
  void drawVision(float x,float y,float w,float h){card(x,y,w,h);cardTitle(x,y,w,interactionState().i18n.tr("panel.vision"));
    float px=x+12,py=y+studioUiCardTitleHeight(),pw=max(1,w-24),ph=max(1,h-studioUiCardTitleHeight()-12),g=max(8,studioUiGap()*.65f);
    boolean sideBySide=pw>=780;
    if(sideBySide){
      float depthW=max(1,(pw-g)*.44f),bodyW=max(1,pw-g-depthW);drawDepthView(px,py,depthW,ph);drawSkeleton3DView(px+depthW+g,py,bodyW,ph);
    }else{
      float depthH=max(1,(ph-g)*.40f),bodyH=max(1,ph-g-depthH);drawDepthView(px,py,pw,depthH);drawSkeleton3DView(px,py+depthH+g,pw,bodyH);
    }
  }
  void drawDepthView(float x,float y,float w,float h){
    fill(interactionState().theme.BG);rect(x,y,w,h,10);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,true);textAlign(LEFT,TOP);
    text(interactionState().i18n.tr("panel.metric_depth"),x+10,y+8);
    if(interactionState().depthImage!=null){
      float[] vr=imageRect(interactionState().depthImage,x,y,w,h);
      // Presentation uses the sensor-facing image orientation. Cursor mirroring is
      // intentionally independent so desktop control can remain intuitive.
      image(interactionState().depthImage,vr[0],vr[1],vr[2],vr[3]);
    }else{fill(0xFFAAB6C2);textAlign(CENTER,CENTER);studioText(STUDIO_FONT_BODY,false);
      text(ellipsizeToWidth(interactionState().i18n.tr("waiting.depth"),w-20),x+w/2,y+h/2);}
    textAlign(LEFT,BASELINE);
  }
  void drawSkeleton3DView(float x,float y,float w,float h){
    fill(0xFF0B1117);rect(x,y,w,h,10);pushStyle();clip(x,y,w,h);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,TOP);text("3D",x+10,y+8);
    SkeletonPose3D s=interactionState().skeleton;if(s==null||!s.tracked||s.hipCenter==null||!s.hipCenter.tracked()){
      fill(0xFF81909D);textAlign(CENTER,CENTER);studioText(STUDIO_FONT_SMALL,false);text("XYZ",x+w*.5f,y+h*.5f);noClip();popStyle();return;}
    SkeletonJoint3D root=s.hipCenter;
    if(bodyViewTrackingId!=s.trackingId){bodyViewTrackingId=s.trackingId;bodyViewFilter.reset();}
    // Body3D follows the segmented metric body while the viewport independently
    // auto-fits that geometry, keeping joints and cloud in one camera-space frame.
    float yaw=-0.30f,pitch=.08f;
    Body3DViewFit fit=body3DViewFit(s,interactionState().interactionCloud,root,yaw,pitch);
    // Host-owned framing uses a bounded metric envelope. The backend keeps camera-space
    // tracking untouched; this frontend only decides how that metric pose is presented.
    float postureMinH="full".equals(s.posture)?max(1.48f,interactionState().config.bodyViewMinHeightM):interactionState().config.bodyViewMinHeightM;
    float expectedH=constrain(max(postureMinH,fit.spanY+.18f),interactionState().config.bodyViewMinHeightM,interactionState().config.bodyViewMaxHeightM);
    float expectedW=constrain(max(interactionState().config.bodyViewMinWidthM,fit.spanX+.22f),interactionState().config.bodyViewMinWidthM,interactionState().config.bodyViewMaxWidthM);
    float targetScaleH=(h*interactionState().config.bodyViewTargetOccupancy)/max(.16f,expectedH);
    float targetScaleW=(w*interactionState().config.bodyViewArmOccupancy)/max(.20f,expectedW);
    float targetScale=min(targetScaleH,targetScaleW);
    float minScale=min(w,h)*.36f,maxScale=min(w,h)*1.28f;targetScale=constrain(targetScale,minScale,maxScale);
    float stableCenterX=constrain(fit.centerX,-.32f,.32f);
    float stableCenterY=constrain(fit.centerY+interactionState().config.bodyViewCenterYOffsetM,-.72f,.42f);
    bodyViewFilter.updateFrame(targetScale,stableCenterX,stableCenterY,
      interactionState().config.bodyViewDeadband,interactionState().config.bodyViewZoomOutResponse,
      interactionState().config.bodyViewEmergencyZoomOutResponse,interactionState().config.bodyViewEmergencyRatio,
      interactionState().config.bodyViewZoomInResponse,interactionState().config.bodyViewCenterResponse,
      interactionState().config.bodyViewShrinkDelayFrames);
    float scale=bodyViewFilter.scale,cx=x+w*.50f-bodyViewFilter.centerX*scale,cy=y+h*.51f-bodyViewFilter.centerY*scale;
    // Full-FOV metric point cloud and skeleton share the same metric camera space.
    drawInteractionPointCloud3D(interactionState().interactionCloud,root,cx,cy,scale,yaw,pitch);
    // Ground/depth guides make movement along Z visible even when the body stays centered.
    stroke(0xFF263541);strokeWeight(1);for(int k=-2;k<=2;k++){float gx=k*.25f;PVector a=project3DPoint(gx,.72f,-.55f,cx,cy,scale,yaw,pitch);PVector b=project3DPoint(gx,.72f,.55f,cx,cy,scale,yaw,pitch);line(a.x,a.y,b.x,b.y);}
    for(int k=-2;k<=2;k++){float gz=k*.25f;PVector a=project3DPoint(-.55f,.72f,gz,cx,cy,scale,yaw,pitch);PVector b=project3DPoint(.55f,.72f,gz,cx,cy,scale,yaw,pitch);line(a.x,a.y,b.x,b.y);}
    drawBodyBones3D(s,root,cx,cy,scale,yaw,pitch,0xFF101820,max(5.0f,7.0f*studioUiScale()));
    drawBodyBones3D(s,root,cx,cy,scale,yaw,pitch,0xFF58C7F3,max(2.0f,3.2f*studioUiScale()));
    for(SkeletonJoint3D j:bodyJoints(s))jointNode3D(j,root,cx,cy,scale,yaw,pitch);
    if(s.head.tracked())jointNode3D(s.head,root,cx,cy,scale,yaw,pitch);
    drawControlCloud3D(s,root,cx,cy,scale,yaw,pitch,x,y,w,h);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,false);textAlign(RIGHT,TOP);text(String.format(Locale.US,"Z %.2f m",s.meanDepthM),x+w-10,y+8);
    textAlign(LEFT,TOP);text(interactionState().i18n.tr("posture."+s.posture)+"  "+round(s.postureConfidence*100)+"%",x+10,y+24);
    // Absolute depth ruler: 0.5..4.0 m, so walking toward/away from Kinect is visible as translation.
    float rx=x+w-16,top=y+34,bottom=y+h-18;stroke(0xFF435563);line(rx,top,rx,bottom);
    float zn=constrain((s.meanDepthM-.5f)/3.5f,0,1),ry=lerp(top,bottom,zn);noStroke();fill(0xFFFFB54A);ellipse(rx,ry,8,8);
    noClip();popStyle();textAlign(LEFT,BASELINE);
  }
  class Body3DViewFit {float centerX=0,centerY=0,spanX=.65f,spanY=1.15f;int samples=0;}
  Body3DViewFit body3DViewFit(SkeletonPose3D s,PointCloud cloud,SkeletonJoint3D root,float yaw,float pitch){
    Body3DViewFit fit=new Body3DViewFit();if(root==null||!root.tracked())return fit;
    ArrayList<Float> xs=new ArrayList<Float>(),ys=new ArrayList<Float>();
    if(cloud!=null&&cloud.points!=null&&!cloud.points.isEmpty()){int stride=max(1,cloud.points.size()/2500);for(int i=0;i<cloud.points.size();i+=stride){PVector q=cloud.points.get(i);if(q==null||cloud.confidenceAt(i)<.27f)continue;PVector p=project3DPoint(q.x-root.world.x,q.y-root.world.y,q.z-root.world.z,0,0,1,yaw,pitch);xs.add(p.x);ys.add(p.y);}}
    for(SkeletonJoint3D j:s.canonicalJoints())if(j!=null&&j.tracked()&&j.world!=null){PVector p=project3DPoint(j.world.x-root.world.x,j.world.y-root.world.y,j.world.z-root.world.z,0,0,1,yaw,pitch);xs.add(p.x);ys.add(p.y);}
    if(xs.size()<3)return fit;Collections.sort(xs);Collections.sort(ys);int n=xs.size(),lo=constrain(round((n-1)*.015f),0,n-1),hi=constrain(round((n-1)*.985f),0,n-1);
    float minX=xs.get(lo),maxX=xs.get(hi),minY=ys.get(lo),maxY=ys.get(hi);fit.centerX=(minX+maxX)*.5f;fit.centerY=(minY+maxY)*.5f;fit.spanX=max(.22f,maxX-minX);fit.spanY=max(.32f,maxY-minY);fit.samples=n;return fit;
  }
  PVector project3DPoint(float lx,float ly,float lz,float cx,float cy,float sc,float yaw,float pitch){
    // Observer-facing presentation: invert the previous horizontal view without
    // touching camera-space tracking coordinates used by Body3D or gestures.
    lx=-lx;float c=cos(yaw),sn=sin(yaw),x1=lx*c-lz*sn,z1=lx*sn+lz*c;
    float cp=cos(pitch),sp=sin(pitch),y1=ly*cp-z1*sp;return new PVector(cx+x1*sc,cy+y1*sc,z1);}
  PVector project3DJoint(SkeletonJoint3D j,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){return project3DPoint(j.world.x-root.world.x,j.world.y-root.world.y,j.world.z-root.world.z,cx,cy,sc,yaw,pitch);}
  void drawInteractionPointCloud3D(PointCloud cloud,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){
    if(cloud==null||cloud.points==null||root==null||!root.tracked())return;stroke(0xFF58C7F3,92);strokeWeight(max(1.0f,1.45f*studioUiScale()));
    int stride=max(1,cloud.points.size()/9000);for(int i=0;i<cloud.points.size();i+=stride){PVector q=cloud.points.get(i);if(q==null)continue;
      PVector p=project3DPoint(q.x-root.world.x,q.y-root.world.y,q.z-root.world.z,cx,cy,sc,yaw,pitch);point(p.x,p.y);}
  }
  void drawBodyBones3D(SkeletonPose3D s,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch,int color,float weight){stroke(color,s.tracked?235:150);strokeWeight(weight);strokeCap(ROUND);
    bone3D(s.head,s.shoulderCenter,root,cx,cy,sc,yaw,pitch);bone3D(s.shoulderCenter,s.spine,root,cx,cy,sc,yaw,pitch);bone3D(s.spine,s.hipCenter,root,cx,cy,sc,yaw,pitch);
    bone3D(s.leftShoulder,s.rightShoulder,root,cx,cy,sc,yaw,pitch);bone3D(s.shoulderCenter,s.leftShoulder,root,cx,cy,sc,yaw,pitch);bone3D(s.shoulderCenter,s.rightShoulder,root,cx,cy,sc,yaw,pitch);
    bone3D(s.leftShoulder,s.leftElbow,root,cx,cy,sc,yaw,pitch);bone3D(s.leftElbow,s.leftWrist,root,cx,cy,sc,yaw,pitch);bone3D(s.leftWrist,s.leftHand,root,cx,cy,sc,yaw,pitch);
    bone3D(s.rightShoulder,s.rightElbow,root,cx,cy,sc,yaw,pitch);bone3D(s.rightElbow,s.rightWrist,root,cx,cy,sc,yaw,pitch);bone3D(s.rightWrist,s.rightHand,root,cx,cy,sc,yaw,pitch);
    bone3D(s.hipCenter,s.leftHip,root,cx,cy,sc,yaw,pitch);bone3D(s.hipCenter,s.rightHip,root,cx,cy,sc,yaw,pitch);bone3D(s.leftHip,s.rightHip,root,cx,cy,sc,yaw,pitch);
    if(renderKnees(s)){bone3D(s.leftHip,s.leftKnee,root,cx,cy,sc,yaw,pitch);bone3D(s.rightHip,s.rightKnee,root,cx,cy,sc,yaw,pitch);}
    if(renderLowerLegs(s)){bone3D(s.leftKnee,s.leftAnkle,root,cx,cy,sc,yaw,pitch);bone3D(s.leftAnkle,s.leftFoot,root,cx,cy,sc,yaw,pitch);bone3D(s.rightKnee,s.rightAnkle,root,cx,cy,sc,yaw,pitch);bone3D(s.rightAnkle,s.rightFoot,root,cx,cy,sc,yaw,pitch);}}
  void bone3D(SkeletonJoint3D a,SkeletonJoint3D b,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){if(a==null||b==null||!a.tracked()||!b.tracked())return;
    PVector pa=project3DJoint(a,root,cx,cy,sc,yaw,pitch),pb=project3DJoint(b,root,cx,cy,sc,yaw,pitch);line(pa.x,pa.y,pb.x,pb.y);}
  void jointNode3D(SkeletonJoint3D j,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){if(j==null||!j.tracked())return;PVector p=project3DJoint(j,root,cx,cy,sc,yaw,pitch);
    float d=(j.state==2?8:6)*studioUiScale(),depthScale=constrain(1.0f-p.z*.18f,.72f,1.28f);noStroke();fill(j.state==2?0xFFFFB54A:0xFF9AA9B5,j.state==2?245:155);ellipse(p.x,p.y,d*depthScale,d*depthScale);}
  void drawControlCloud3D(SkeletonPose3D s,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch,float vx,float vy,float vw,float vh){
    InteractionDesktopController dc=interactionState().desktop;if(dc==null)return;SkeletonJoint3D hand=dc.primaryJoint(s);if(hand==null||!hand.tracked())return;
    PVector hp=project3DJoint(hand,root,cx,cy,sc,yaw,pitch),sp=project3DJoint(s.spine,root,cx,cy,sc,yaw,pitch);
    float forward=max(0,dc.forwardDistance(s,hand)),quality=constrain(.55f*hand.confidence+.45f*s.interactionConfidence,0,1);
    float radius=(18+26*constrain(forward/.32f,0,1))*studioUiScale();
    stroke(0xFF68A9E8,70);strokeWeight(max(1,studioUiScale()));line(sp.x,sp.y,hp.x,hp.y);
    noFill();for(int ring=0;ring<3;ring++){float rr=radius*(.52f+ring*.27f);stroke(0xFF68A9E8,70-ring*15);strokeWeight(max(1,studioUiScale()));ellipse(hp.x,hp.y,rr*2,rr*2*.72f);}
    noStroke();float t=millis()*0.001f;for(int i=0;i<30;i++){float a=TWO_PI*i/30.0f+t*(.20f+(i%5)*.025f),rr=radius*(.18f+.78f*((i*37)%29)/28.0f);
      float px=hp.x+cos(a)*rr,py=hp.y+sin(a)*rr*.72f;fill(0xFF68A9E8,70+round(150*quality));ellipse(px,py,max(1.8f,2.8f*studioUiScale()),max(1.8f,2.8f*studioUiScale()));}
    fill(0xFF68A9E8,230);ellipse(hp.x,hp.y,9*studioUiScale(),9*studioUiScale());
    if(dc.enabled&&dc.desktopBounds!=null&&!Float.isNaN(dc.sx)&&!Float.isNaN(dc.sy)){float nx=(dc.sx-dc.desktopBounds.x)/max(1,dc.desktopBounds.width-1.0f),ny=(dc.sy-dc.desktopBounds.y)/max(1,dc.desktopBounds.height-1.0f);
      float mapW=min(118*studioUiScale(),vw*.24f),mapH=mapW*.56f,mx=vx+vw-mapW-18,my=vy+vh-mapH-18;noFill();stroke(0xFF68A9E8,125);rect(mx,my,mapW,mapH,5);
      noStroke();fill(0xFF68A9E8,235);ellipse(mx+constrain(nx,0,1)*mapW,my+constrain(ny,0,1)*mapH,7*studioUiScale(),7*studioUiScale());}
  }
  float[] imageRect(PImage img,float x,float y,float w,float h){float sc=min(w/img.width,h/img.height),dw=img.width*sc,dh=img.height*sc;
    return new float[]{x+(w-dw)/2,y+(h-dh)/2,dw,dh};}
  boolean renderLowerLegs(SkeletonPose3D s){return s!=null&&("full".equals(s.posture)||"partial".equals(s.posture)&&s.lowerBodyVisible);}
  boolean renderKnees(SkeletonPose3D s){return s!=null&&(renderLowerLegs(s)||"seated".equals(s.posture)&&s.lowerBodyVisible);}
  SkeletonJoint3D[] bodyJoints(SkeletonPose3D s){ArrayList<SkeletonJoint3D> j=new ArrayList<SkeletonJoint3D>();Collections.addAll(j,s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,s.leftElbow,
      s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip);if(renderKnees(s))Collections.addAll(j,s.leftKnee,s.rightKnee);
    if(renderLowerLegs(s))Collections.addAll(j,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot);return j.toArray(new SkeletonJoint3D[j.size()]);}
  String xyz(SkeletonJoint3D j){return j==null||!j.tracked()?"—":String.format(Locale.US,"%.2f / %.2f / %.2f m",j.world.x,j.world.y,j.world.z);
    }
  void drawStatus(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,interactionState().i18n.tr("panel.status"));float pad=12;

    String live=interaction3dLive()?interactionState().i18n.tr("state.live"):interactionState().i18n.tr("state.wait");

    String syncValue=interactionState().rgbd!=null&&interactionState().rgbd.source.depthConnected?interactionState().i18n.tr("state.live"):"—";

    String sk=interactionState().skeleton!=null&&interactionState().skeleton.tracked?interactionState().i18n.format("state.tracked",interactionState().skeleton.confidence*100):interactionState().i18n.tr("tracker."+(interactionState().skeletonSession==null?"searching":interactionState().skeletonSession.statusReason()));

    String depth=interactionState().skeleton==null?"—":String.format(Locale.US,"%.2f m",interactionState().skeleton.meanDepthM);

    String mode=interactionState().desktop==null?interactionState().i18n.tr("gesture.disabled"):interactionState().i18n.tr(interactionState().desktop.gestureKey());

    String actions=interactionState().desktop==null?"0 / 0 / 0":interactionState().desktop.doubleClickCount+" / "+interactionState().desktop.dragCount+" / "+interactionState().desktop.scrollCount;

    String[] labels={interactionState().i18n.tr("label.kinect"),interactionState().i18n.tr("label.sync"),interactionState().i18n.tr("label.skeleton"),interactionState().i18n.tr("label.depth"),
      interactionState().i18n.tr("label.right_hand_xyz"),interactionState().i18n.tr("label.left_hand_xyz"),interactionState().i18n.tr("label.mode"),interactionState().i18n.tr("label.actions")}
    ;
    String[] values={live,syncValue,sk,depth,interactionState().skeleton==null?"—":xyz(interactionState().skeleton.rightHand),interactionState().skeleton==null?"—":xyz(interactionState().skeleton.leftHand),
      mode,actions};
    boolean[] active={interaction3dLive(),interactionState().rgbd!=null,interactionState().skeleton!=null&&interactionState().skeleton.tracked,interactionState().skeleton!=null,
      interactionState().skeleton!=null&&interactionState().skeleton.rightHand.tracked(),interactionState().skeleton!=null&&interactionState().skeleton.leftHand.tracked(),
      interactionState().controlEnabled,interactionState().controlEnabled};
    StudioUiMetrics ui=studio.ui.metrics();float ix=x+ui.panelPad,iy=y+ui.cardTitleH+ui.panelPad*.45f,iw=max(1,w-ui.panelPad*2),ih=max(1,h-ui.cardTitleH-ui.panelPad*1.45f);

    studio.ui.drawMetricGrid(labels,values,active,ix,iy,iw,ih);
  }
  void statusMetric(float x,float y,float w,float h,String label,String value,boolean active){studio.ui.renderer.metric(x,y,w,h,label,value,active);
    }
  void drawActions(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,interactionState().i18n.tr("panel.actions"));StudioUiMetrics ui=studio.ui.metrics();
    String handValue=interactionState().i18n.tr("hand."+interactionState().config.hand);
    boolean desktopAvailable=interactionState().desktop!=null&&interactionState().desktop.available();
    // Enable/hand controls remain clickable even when the OS pointer backend is
    // temporarily unavailable. The click then reports the backend reason instead
    // of presenting a visually inert control.
    enableButton.require("").configure(interactionState().i18n.tr(interactionState().controlEnabled?"button.disable":"button.enable"),true,interactionState().controlEnabled,
      false,false);handButton.configure(interactionState().i18n.tr("button.hand")+": "+handValue,true,"auto".equals(interactionState().config.hand),false,false);
    releaseButton.configure(interactionState().i18n.tr("button.release"),interactionState().controlEnabled&&interactionState().desktop!=null&&interactionState().desktop.available(),false,
      false,false);ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();
    items.add(enableButton);items.add(handButton);items.add(releaseButton);float footer=ui.footerH;
    studio.ui.layoutButtons(items,x+ui.panelPad,y+ui.cardTitleH+ui.panelPad*.45f,max(1,w-ui.panelPad*2),max(1,h-ui.cardTitleH-ui.panelPad*1.45f-footer));
    for(StudioUiButton item:items)item.draw();String note=interactionState().status==null?"":interactionState().status;
    studio.ui.renderer.statusFooter(x+ui.panelPad,y+h-footer,w-ui.panelPad*2,footer,note,true);

  }
  void handleMouse(float mx,float my){if(enableButton.hit(mx,my))toggleInteractionControl();
    else if(handButton.hit(mx,my))cycleInteractionHand();else if(releaseButton.hit(mx,my)&&interactionState().desktop!=null)interactionState().desktop.releaseDrag();
    }
  void card(float x,float y,float w,float h){studio.ui.module(interactionState().i18n).panel("",x,y,w,h);
    }void cardTitle(float x,float y,float w,String title){studio.ui.module(interactionState().i18n).panelTitle(x,y,w,title);
    }
}

