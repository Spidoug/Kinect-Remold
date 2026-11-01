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
  // Reusable backend block (BodyTracking.pde). rgbd/skeletonSession alias the
  // session's own objects for status presentation and calibration refresh.
  BodyTrackingSession tracking;
  RgbdSession rgbd;
  SkeletonProcessingSession skeletonSession;
  InteractionDesktopController desktop;
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
String loadInteractionTrackingPreference(String defaultMode){
  String value=studio.userPreferences.get("interactivity.tracking.category",defaultMode).toLowerCase(Locale.ROOT);
  return ("auto".equals(value)||"body".equals(value)||"hands_fingers".equals(value))?value:defaultMode;
}
void saveInteractionTrackingPreference(String mode){studio.userPreferences.put("interactivity.tracking.category",mode);}

boolean interactionDeviceReady(KinectDevice device){
  // Interactivity consumes metric depth. Driver readiness can lag the module
  // session during reconnects, so the UI must key availability to the actual
  // capability and let the runtime surface connection state independently.
  return device!=null&&device.hasCapability("depth");
}
boolean interaction3dLive(){
  InteractionModuleState state=interactionState();
  return state.tracking!=null&&state.tracking.streamsLive();
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
void toggleInteractionKeyboard(){
  InteractionModuleState state=interactionState();if(state.desktop==null)return;
  if(!state.desktop.keyboardSupported()){state.status=state.i18n.tr("status.keyboard_unavailable");return;}
  if(state.desktop.keyboardVisible){state.desktop.setKeyboardVisible(false);state.status=state.i18n.tr("status.keyboard_off");return;}
  // The keyboard types through the desktop controller, so it arms control if needed.
  if(!state.controlEnabled)toggleInteractionControl();
  if(!state.controlEnabled)return;
  state.desktop.setKeyboardVisible(true);state.status=state.i18n.tr("status.keyboard_on");
}
void interactivityMousePressed(){
  InteractionModuleState state=interactionState();
  // Module content is rendered below the Studio shell top bar.  Hit testing must
  // use the same content-local coordinate system as drawing/hover feedback.
  if(state.ui!=null)state.ui.handleMouse(studio.ui.pointerX(),studio.ui.pointerY());
}

class InteractionConfig {
  int workerJoinMs=2200,streamStaleMs=1800,previewHz=15,cursorLostReleaseMs=800,
      cursorAutoHandSwitchMs=450,doubleClickWindowMs=600,pressStableMs=60,pressLockLookbackMs=120,
      engageSettleMs=250,pressDirectionWindowMs=150,pressReleaseHoldMs=220,keyboardDwellMs=0,keyboardRepeatDelayMs=520,keyboardRepeatMs=90,keyboardToggleHoldMs=1200;
  boolean rightClickEnabled=true,keyboardGestureToggle=true;
  boolean mirrorX=false;
  String hand="auto",trackingCategory="auto";
  boolean handsFingersAutoRequireSeated=false;
  float handsFingersAutoPersonMaxM=1.65f;
  float cursorAutoHandScoreMargin=.14f,
        cursorMinBodyConfidence=.38f,cursorMinHandConfidence=.34f,cursorFineHandConfidence=.58f,
        // physical interaction zone (fractions of the user's arm length)
        zoneWidthArm=1.05f,zoneHeightArm=.95f,zoneTopArm=.22f,zoneOutwardArm=.10f,
        engageForwardArm=.16f,engageBelowShoulderArm=.95f,engageAboveShoulderArm=.75f,
        // relative push ("press") detection
        pressDeltaArm=.15f,pressReleaseArm=.07f,pressLockFraction=.35f,pressBaselineRiseS=1.2f,pressBaselineFallS=.25f,pressDragUnlock=.07f,pressDirectionRatio=.8f,pressBaselineSidewaysS=.35f,
        pointerMinCutoff=.9f,pointerBeta=.012f,pointerDCutoff=1.0f,dragStartPx=14f,
        scrollRaiseArm=.10f,scrollDeadbandArm=.07f,scrollGainPerArm=70f,scrollMaxNotchesPerSec=14f,
        keyboardWidthFraction=.62f,keyboardSideOffset=.22f,keyboardZoneScale=1.10f,
        bodyViewCenterYOffsetM=-.03f,bodyViewTargetOccupancy=.82f,bodyViewArmOccupancy=.82f,
        bodyViewReferenceDistanceM=1.10f,bodyViewFixedHeightM=2.10f,bodyViewFixedWidthM=2.10f;

  void load(File file){
    ConfigRules r=studio.services.configRules;
    Properties p=r.load(file,"interactivity");
    workerJoinMs=r.integer(p,"transport.workerJoinMs",workerJoinMs,250,10000);
    streamStaleMs=r.integer(p,"transport.streamStaleMs",streamStaleMs,250,10000);
    previewHz=r.integer(p,"vision.previewHz",previewHz,1,60);
    mirrorX=r.flag(p,"cursor.mirrorX",mirrorX);
    hand=r.text(p,"cursor.hand",hand).toLowerCase(Locale.ROOT);
    if(!("auto".equals(hand)||"left".equals(hand)||"right".equals(hand)))hand="auto";
    trackingCategory=r.text(p,"tracking.category",trackingCategory).toLowerCase(Locale.ROOT);
    if(!("auto".equals(trackingCategory)||"body".equals(trackingCategory)||"hands_fingers".equals(trackingCategory)))trackingCategory="auto";
    handsFingersAutoRequireSeated=r.flag(p,"handsFingers.autoRequireSeated",handsFingersAutoRequireSeated);
    handsFingersAutoPersonMaxM=r.decimal(p,"handsFingers.autoPersonMaxM",handsFingersAutoPersonMaxM,.65f,3.5f);
    cursorLostReleaseMs=r.integer(p,"cursor.lostReleaseMs",cursorLostReleaseMs,100,5000);
    cursorAutoHandSwitchMs=r.integer(p,"cursor.autoHandSwitchMs",cursorAutoHandSwitchMs,50,5000);
    cursorAutoHandScoreMargin=r.decimal(p,"cursor.autoHandScoreMargin",cursorAutoHandScoreMargin,0f,1f);
    cursorMinBodyConfidence=r.decimal(p,"cursor.minBodyConfidence",cursorMinBodyConfidence,0f,.99f);
    cursorMinHandConfidence=r.decimal(p,"cursor.minHandConfidence",cursorMinHandConfidence,0f,.99f);
    cursorFineHandConfidence=r.decimal(p,"cursor.fineHandConfidence",cursorFineHandConfidence,0f,.99f);
    zoneWidthArm=r.decimal(p,"zone.widthArm",zoneWidthArm,.3f,3f);zoneHeightArm=r.decimal(p,"zone.heightArm",zoneHeightArm,.3f,3f);
    zoneTopArm=r.decimal(p,"zone.topArm",zoneTopArm,-1f,1.5f);zoneOutwardArm=r.decimal(p,"zone.outwardArm",zoneOutwardArm,-1f,1f);
    engageForwardArm=r.decimal(p,"engage.forwardArm",engageForwardArm,0f,1f);engageBelowShoulderArm=r.decimal(p,"engage.belowShoulderArm",engageBelowShoulderArm,.1f,2f);
    engageAboveShoulderArm=r.decimal(p,"engage.aboveShoulderArm",engageAboveShoulderArm,0f,2f);
    pressDeltaArm=r.decimal(p,"press.deltaArm",pressDeltaArm,.03f,.6f);pressReleaseArm=r.decimal(p,"press.releaseArm",pressReleaseArm,0f,pressDeltaArm);
    pressLockFraction=r.decimal(p,"press.lockFraction",pressLockFraction,0f,1f);pressBaselineRiseS=r.decimal(p,"press.baselineRiseS",pressBaselineRiseS,.05f,10f);
    pressBaselineFallS=r.decimal(p,"press.baselineFallS",pressBaselineFallS,.02f,10f);pressDragUnlock=r.decimal(p,"press.dragUnlock",pressDragUnlock,0f,.5f);
    engageSettleMs=r.integer(p,"engage.settleMs",engageSettleMs,0,3000);pressDirectionWindowMs=r.integer(p,"press.directionWindowMs",pressDirectionWindowMs,50,1000);
    pressDirectionRatio=r.decimal(p,"press.directionRatio",pressDirectionRatio,.1f,5f);
    pressBaselineSidewaysS=r.decimal(p,"press.baselineSidewaysS",pressBaselineSidewaysS,.02f,10f);pressReleaseHoldMs=r.integer(p,"press.releaseHoldMs",pressReleaseHoldMs,0,1000);
    pressStableMs=r.integer(p,"press.stableMs",pressStableMs,0,1000);pressLockLookbackMs=r.integer(p,"press.lockLookbackMs",pressLockLookbackMs,0,600);
    pointerMinCutoff=r.decimal(p,"pointer.minCutoffHz",pointerMinCutoff,.05f,20f);pointerBeta=r.decimal(p,"pointer.beta",pointerBeta,0f,1f);
    pointerDCutoff=r.decimal(p,"pointer.derivativeCutoffHz",pointerDCutoff,.05f,20f);dragStartPx=r.decimal(p,"pointer.dragStartPx",dragStartPx,0f,200f);
    rightClickEnabled=r.flag(p,"gesture.rightClick",rightClickEnabled);doubleClickWindowMs=r.integer(p,"gesture.doubleClickWindowMs",doubleClickWindowMs,50,3000);
    scrollRaiseArm=r.decimal(p,"scroll.raiseArm",scrollRaiseArm,-1f,1f);scrollDeadbandArm=r.decimal(p,"scroll.deadbandArm",scrollDeadbandArm,0f,.5f);
    scrollGainPerArm=r.decimal(p,"scroll.gainPerArm",scrollGainPerArm,1f,500f);scrollMaxNotchesPerSec=r.decimal(p,"scroll.maxNotchesPerSec",scrollMaxNotchesPerSec,1f,60f);
    keyboardWidthFraction=r.decimal(p,"keyboard.widthFraction",keyboardWidthFraction,.3f,1f);keyboardSideOffset=r.decimal(p,"keyboard.sideOffset",keyboardSideOffset,0f,.5f);
    keyboardZoneScale=r.decimal(p,"keyboard.zoneScale",keyboardZoneScale,.4f,3f);keyboardDwellMs=r.integer(p,"keyboard.dwellMs",keyboardDwellMs,0,5000);
    keyboardRepeatDelayMs=r.integer(p,"keyboard.repeatDelayMs",keyboardRepeatDelayMs,100,3000);keyboardRepeatMs=r.integer(p,"keyboard.repeatMs",keyboardRepeatMs,20,1000);
    keyboardGestureToggle=r.flag(p,"keyboard.gestureToggle",keyboardGestureToggle);keyboardToggleHoldMs=r.integer(p,"keyboard.toggleHoldMs",keyboardToggleHoldMs,200,5000);
    bodyViewTargetOccupancy=r.decimal(p,"view.bodyTargetOccupancy",bodyViewTargetOccupancy,.60f,.94f);
    bodyViewArmOccupancy=r.decimal(p,"view.bodyArmOccupancy",bodyViewArmOccupancy,.65f,.96f);
    bodyViewCenterYOffsetM=r.decimal(p,"view.bodyCenterYOffsetM",bodyViewCenterYOffsetM,-.35f,.35f);
    bodyViewReferenceDistanceM=r.decimal(p,"view.referenceDistanceM",bodyViewReferenceDistanceM,.60f,3.0f);
    bodyViewFixedHeightM=r.decimal(p,"view.fixedHeightM",bodyViewFixedHeightM,.70f,2.40f);
    bodyViewFixedWidthM=r.decimal(p,"view.fixedWidthM",bodyViewFixedWidthM,.55f,2.20f);
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
void cycleInteractionTrackingCategory(){
  InteractionModuleState state=interactionState();if(state.config==null)return;String current=state.config.trackingCategory==null?"auto":state.config.trackingCategory;
  String next="auto".equals(current)?"body":("body".equals(current)?"hands_fingers":"auto");state.config.trackingCategory=next;
  if(state.desktop!=null)state.desktop.setTrackingCategory(next);saveInteractionTrackingPreference(next);
  state.status=state.i18n.tr("button.tracking")+": "+state.i18n.tr("tracking."+next);
}

void prepareInteractivityRgbdCore(){
  InteractionModuleState state=interactionState();
  InteractionConfig c=state.config;
  state.tracking=studio.services.processingBlocks.openBodyTracking(state.i18n,studio.selectedKinect(),
    new BodyTrackingOptions("Interaction","Interactivity",c.workerJoinMs,c.streamStaleMs,c.previewHz));
  state.rgbd=state.tracking.rgbd;state.skeletonSession=state.tracking.skeleton;
}
void refreshInteractionCalibrationForSelectedDevice(){
  InteractionModuleState state=interactionState();if(state.tracking==null)return;
  state.tracking.selectDevice(studio.selectedKinect());if(state.ui!=null)state.ui.preview.reset();
}
void setupInteractivityModule(){
  interactionState().config=new InteractionConfig();interactionState().config.load(studio.services.paths.resource("interactivity","config.properties"));
  interactionState().config.hand=loadInteractionHandPreference(interactionState().config.hand);interactionState().config.trackingCategory=loadInteractionTrackingPreference(interactionState().config.trackingCategory);

  interactionState().i18n=new InteractionI18n(studio.currentLanguage());
  prepareInteractivityRgbdCore();

  interactionState().desktop=new InteractionDesktopController(interactionState().config);
  interactionState().desktop.attachKeyboard(interactionState().i18n);


  interactionState().ui=new InteractionUI();interactionState().status=interactionState().i18n.tr("status.ready");

}
void activateInteractivityModule(){
  interactionState().lastProcessedFrame=-1;interactionState().skeleton=null;interactionState().depthImage=null;interactionState().interactionCloud=null;
  if(interactionState().ui!=null)interactionState().ui.preview.reset();

  // Use the shared ONNX tracking mode: synchronized RGB-D or depth only.
  if(interactionState().tracking!=null)interactionState().tracking.activate();
}
void requestDeactivateInteractivityModule(){
  interactionState().controlEnabled=false;
  if(interactionState().desktop!=null)interactionState().desktop.setEnabled(false);

  if(interactionState().tracking!=null)interactionState().tracking.requestStop();
}
void deactivateInteractivityModule(){
  interactionState().controlEnabled=false;
  if(interactionState().desktop!=null)interactionState().desktop.setEnabled(false);

  if(interactionState().tracking!=null)interactionState().tracking.stop(false);

}
void disposeInteractivityModule(){deactivateInteractivityModule();}
void drawInteractivityModule(){background(interactionState().theme.BG);serviceInteractivityFrames();
  if(interactionState().ui!=null)interactionState().ui.draw();}

// UI thread: immutable snapshots only. No transport or CV work executes here.
void serviceInteractivityFrames(){
  BodyProcessedFrame p=interactionState().tracking==null?null:interactionState().tracking.latest();

  if(p!=null&&p.frameNumber!=interactionState().lastProcessedFrame){interactionState().lastProcessedFrame=p.frameNumber;
    interactionState().skeleton=p.skeleton;interactionState().interactionCloud=p.bodyCloud;
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

class InteractionTheme extends StudioPalette {}

// RGB-D session, latest-frame 3D worker and depth preview live in BodyTracking.pde.

class InteractionDesktopController {
  final InteractionConfig cfg;final InteractionInputSink sink;java.awt.Rectangle desktopBounds;
  final InteractionBodyFrame frame=new InteractionBodyFrame();
  final InteractionHand leftHand,rightHand;
  VirtualKeyboardModel keyboard;VirtualKeyboardWindow keyboardWindow;
  volatile boolean enabled=false,dragging=false,buttonDown=false,keyboardVisible=false;
  volatile String handMode,trackingCategory;
  // Cursor position in desktop pixels (shown in the Studio mini-map).
  float sx=Float.NaN,sy=Float.NaN;
  long lastTrackedMs=0,moveCount=0,doubleClickCount=0,dragCount=0,scrollCount=0,rightClickCount=0,keyCount=0;
  volatile int lastX=-1,lastY=-1;String error="";long activeTrackingId=0;
  boolean primaryIsLeft=false,primaryChosen=false,rightClickArmed=false,dragMoved=false;long primaryCandidateSince=0,lastPrimaryPressMs=0;
  float pressX,pressY,scrollAnchor=Float.NaN,scrollAccumulator=0;long lastScrollMs=0,toggleSince=0,lastToggleMs=0;
  String interactionState="gesture.cloud_only";
  InteractionDesktopController(InteractionConfig cfg){this(cfg,new RobotInputSink());}
  InteractionDesktopController(InteractionConfig cfg,InteractionInputSink sink){this.cfg=cfg;this.sink=sink;handMode=cfg.hand;trackingCategory=cfg.trackingCategory;
    desktopBounds=sink.bounds();error=sink.error();leftHand=new InteractionHand(true,cfg);rightHand=new InteractionHand(false,cfg);}
  void attachKeyboard(ModuleI18n i18n){keyboard=new VirtualKeyboardModel(sink,i18n);keyboardWindow=new VirtualKeyboardWindow(keyboard,cfg.keyboardWidthFraction);}
  boolean available(){return sink.available();}
  boolean keyboardSupported(){return available()&&keyboardWindow!=null&&keyboardWindow.supported();}
  void setEnabled(boolean on){boolean next=on&&available();if(enabled==next)return;
    enabled=next;if(!enabled){releaseDrag();resetGesture();setKeyboardVisible(false);}resetPointerFilter();}
  void setKeyboardVisible(boolean on){boolean next=on&&enabled&&keyboardSupported();if(next==keyboardVisible)return;
    releaseDrag();keyboardVisible=next;leftHand.reset();rightHand.reset();if(keyboardWindow!=null)keyboardWindow.setVisible(next);}
  void resetPointerFilter(){sx=sy=Float.NaN;lastX=lastY=-1;leftHand.reset();rightHand.reset();frame.reset();}
  void resetGesture(){rightClickArmed=false;scrollAnchor=Float.NaN;scrollAccumulator=0;toggleSince=0;interactionState="gesture.cloud_only";}
  String gestureKey(){if(!enabled)return "gesture.disabled";if(keyboardVisible)return "gesture.keyboard";if(dragging&&dragMoved)return "gesture.dragging";return interactionState;}
  String cycleHandMode(){String next="auto".equals(handMode)?"right":("right".equals(handMode)?"left":"auto");setHandMode(next);return handMode;}
  void setHandMode(String mode){String next=("auto".equals(mode)||"left".equals(mode)||"right".equals(mode))?mode:"auto";
    if(next.equals(handMode))return;releaseDrag();handMode=next;cfg.hand=next;primaryChosen=false;primaryCandidateSince=0;resetGesture();}
  void setTrackingCategory(String mode){String next=("auto".equals(mode)||"body".equals(mode)||"hands_fingers".equals(mode))?mode:"auto";if(next.equals(trackingCategory))return;releaseDrag();trackingCategory=next;cfg.trackingCategory=next;resetPointerFilter();resetGesture();}
  boolean closeSeatedFineMode(SkeletonPose3D s){if(s==null)return false;boolean near=s.meanDepthM>0&&s.meanDepthM<=cfg.handsFingersAutoPersonMaxM;boolean posture=!cfg.handsFingersAutoRequireSeated||"seated".equals(s.posture);return near&&posture;}
  boolean detailedMode(SkeletonPose3D s){if("hands_fingers".equals(trackingCategory))return true;if("body".equals(trackingCategory))return false;return closeSeatedFineMode(s);}
  SkeletonHand3D detail(SkeletonPose3D s,boolean left){return s==null?null:(left?s.leftHandDetail:s.rightHandDetail);}
  SkeletonJoint3D bodyHand(SkeletonPose3D s,boolean left){return s==null?null:(left?s.leftHand:s.rightHand);}
  // One continuous anatomical anchor per hand: the palm when fine tracking is
  // confident, otherwise the body-level hand joint.
  SkeletonJoint3D controlJoint(SkeletonPose3D s,boolean left){
    SkeletonJoint3D body=bodyHand(s,left);if(!detailedMode(s))return body;SkeletonHand3D d=detail(s,left);
    if(d!=null&&d.palm.tracked()&&d.palm.confidence>=cfg.cursorFineHandConfidence)return d.palm;return body;
  }
  InteractionHand hand(boolean left){return left?leftHand:rightHand;}
  InteractionHand primaryHand(){return hand(primaryIsLeft);}
  InteractionHand secondaryHand(){return hand(!primaryIsLeft);}
  SkeletonJoint3D primaryJoint(SkeletonPose3D s){if(s==null)return null;SkeletonJoint3D j=controlJoint(s,primaryIsLeft);if(j!=null&&j.tracked())return j;j=controlJoint(s,!primaryIsLeft);return j!=null&&j.tracked()?j:null;}
  // Distance of a hand in front of the torso (m), toward the sensor.
  float forwardDistance(SkeletonPose3D s,SkeletonJoint3D hand){
    if(s==null||hand==null||!hand.tracked()||!s.spine.tracked())return -1;if(!frame.ready&&!frame.update(s))return -1;
    return PVector.sub(hand.world,PVector.lerp(s.spine.world,s.shoulderCenter.world,.28f)).dot(frame.toward);}
  // Auto hand: the engaged hand wins; with both engaged the current one is kept
  // unless the other stays clearly more extended for a while.
  void choosePrimary(long now){
    if("left".equals(handMode)){primaryIsLeft=true;return;}if("right".equals(handMode)){primaryIsLeft=false;return;}
    boolean le=leftHand.engaged,re=rightHand.engaged;
    if(!primaryChosen){if(le||re){primaryIsLeft=le&&(!re||leftHand.extent>rightHand.extent);primaryChosen=true;}return;}
    if(buttonDown)return;InteractionHand cur=primaryHand(),oth=secondaryHand();
    if(!cur.engaged&&oth.engaged){if(primaryCandidateSince==0)primaryCandidateSince=now;if(now-primaryCandidateSince>=cfg.cursorAutoHandSwitchMs/2){primaryIsLeft=!primaryIsLeft;primaryCandidateSince=0;primaryHand().fx.reset();primaryHand().fy.reset();}return;}
    if(cur.engaged&&oth.engaged&&oth.extent>cur.extent+cfg.cursorAutoHandScoreMargin){if(primaryCandidateSince==0)primaryCandidateSince=now;if(now-primaryCandidateSince>=cfg.cursorAutoHandSwitchMs){primaryIsLeft=!primaryIsLeft;primaryCandidateSince=0;}return;}
    primaryCandidateSince=0;
  }
  long clockOverride=-1; // test hook: simulated time in ms
  long now(){return clockOverride>=0?clockOverride:millis64();}
  void update(SkeletonPose3D s){
    long now=now();
    boolean usable=s!=null&&s.tracked&&s.torsoTracked()&&s.torsoConfidence>=cfg.cursorMinBodyConfidence;
    if(!enabled||!available()){return;}
    if(!usable){if(now-lastTrackedMs>cfg.cursorLostReleaseMs){releaseDrag();resetGesture();leftHand.reset();rightHand.reset();activeTrackingId=0;}publishKeyboard(now);return;}
    // A new person never inherits a held button, hand choice or keyboard hover.
    if(activeTrackingId!=s.trackingId){releaseDrag();resetGesture();resetPointerFilter();primaryChosen=false;activeTrackingId=s.trackingId;}
    if(!frame.update(s))return;lastTrackedMs=now;
    float kbOffset=keyboardVisible?cfg.keyboardSideOffset:0,kbWidth=keyboardVisible?cfg.keyboardZoneScale:1;
    leftHand.update(s,controlJoint(s,true),frame,now,keyboardVisible?-kbOffset:0,kbWidth);
    rightHand.update(s,controlJoint(s,false),frame,now,keyboardVisible?kbOffset:0,kbWidth);
    updateKeyboardToggleGesture(s,now);
    if(keyboardVisible){updateKeyboard(now);return;}
    choosePrimary(now);updateMouse(now);
  }
  // Both hands held above the head toggles the virtual keyboard.
  void updateKeyboardToggleGesture(SkeletonPose3D s,long now){
    if(!cfg.keyboardGestureToggle||!keyboardSupported()||!s.head.tracked()){toggleSince=0;return;}
    boolean up=s.leftHand.tracked()&&s.rightHand.tracked()&&PVector.sub(s.leftHand.world,s.head.world).dot(frame.up)>.04f&&PVector.sub(s.rightHand.world,s.head.world).dot(frame.up)>.04f;
    if(!up){toggleSince=0;return;}if(toggleSince==0)toggleSince=now;
    if(now-toggleSince>=cfg.keyboardToggleHoldMs&&now-lastToggleMs>1500){setKeyboardVisible(!keyboardVisible);lastToggleMs=now;toggleSince=0;}
  }
  void updateMouse(long now){
    InteractionHand p=primaryHand(),q=secondaryHand();
    if(p.justReleased&&buttonDown){releasePrimary();}
    if(!p.tracked||!p.engaged){if(!p.pressed&&buttonDown)releaseDrag();interactionState=p.tracked?"gesture.cloud_only":"gesture.cloud_only";secondaryGestures(now,p,q);return;}
    // pointer
    float tx=desktopBounds.x+constrain(p.nx,0,1)*max(1,desktopBounds.width-1),ty=desktopBounds.y+constrain(p.ny,0,1)*max(1,desktopBounds.height-1);
    moveTo(tx,ty);
    if(p.justPressed&&!buttonDown){pressPrimary();dragging=buttonDown;dragMoved=false;pressX=tx;pressY=ty;lastPrimaryPressMs=now;}
    if(buttonDown&&!dragMoved&&dist(tx,ty,pressX,pressY)>cfg.dragStartPx){dragMoved=true;dragCount++;}
    interactionState=buttonDown?(dragMoved?"gesture.dragging":"gesture.pressing"):(p.pressProgress>.35f?"gesture.pressing":"gesture.pointer");
    secondaryGestures(now,p,q);
  }
  void secondaryGestures(long now,InteractionHand p,InteractionHand q){
    if(!q.tracked||!q.engaged){rightClickArmed=false;scrollAnchor=Float.NaN;return;}
    // Second-hand push while the primary one is pressed (not dragging) = double click.
    if(q.justPressed&&buttonDown&&!dragMoved&&now-lastPrimaryPressMs<=cfg.doubleClickWindowMs){releasePrimary();clickPrimary();doubleClickCount++;interactionState="gesture.double_click";return;}
    if(q.justPressed&&!buttonDown&&cfg.rightClickEnabled){rightClickArmed=true;}
    if(q.justReleased&&rightClickArmed){rightClickArmed=false;sink.button(InputEvent.BUTTON3_DOWN_MASK,true);sink.button(InputEvent.BUTTON3_DOWN_MASK,false);rightClickCount++;interactionState="gesture.right_click";return;}
    // Joystick scroll: secondary hand raised to shoulder height, moved up or down.
    float L=frame.armLength;boolean raised=q.vertical>-cfg.scrollRaiseArm*L&&!q.pressed&&!buttonDown;
    if(!raised){scrollAnchor=Float.NaN;scrollAccumulator=0;return;}
    if(Float.isNaN(scrollAnchor)){scrollAnchor=q.vertical;lastScrollMs=now;return;}
    float off=(q.vertical-scrollAnchor)/L,dead=cfg.scrollDeadbandArm,dt=constrain((now-lastScrollMs)/1000.0f,0,.2f);lastScrollMs=now;
    if(abs(off)<=dead){scrollAccumulator=0;if(!buttonDown&&"gesture.pointer".equals(interactionState))interactionState="gesture.two_hand_ready";return;}
    float rate=min(cfg.scrollMaxNotchesPerSec,(abs(off)-dead)*cfg.scrollGainPerArm);scrollAccumulator+=rate*dt;
    int n=(int)scrollAccumulator;if(n>0){scrollAccumulator-=n;int units=off>0?-n:n; // hand up = scroll up
      sink.wheel(units);scrollCount+=n;}interactionState="gesture.scroll";
  }
  void updateKeyboard(long now){
    if(keyboard==null)return;
    if(keyboard.closeRequested){keyboard.closeRequested=false;setKeyboardVisible(false);return;}
    boolean any=false;
    synchronized(keyboard){
      for(int i=0;i<2;i++){InteractionHand h=i==0?leftHand:rightHand;keyboard.visible[i]=h.tracked&&h.engaged;
        if(!keyboard.visible[i]){keyboard.hover[i]=null;keyboard.active[i]=null;keyboard.down[i]=false;keyboard.progress[i]=0;continue;}
        float kx=keyboardWindow.keyboardX(constrain(h.nx,-.02f,1.02f)),ky=keyboardWindow.keyboardY(constrain(h.ny,-.02f,1.02f));keyboard.cx[i]=kx;keyboard.cy[i]=ky;
        VirtualKey k=keyboard.keyAt(kx,ky);if(k==null)k=keyboard.nearestKey(kx,ky,keyboard.width*.02f);
        if(k!=keyboard.hover[i]){keyboard.hover[i]=k;keyboard.hoverSince[i]=now;keyboard.dwellFired[i]=false;}
        keyboard.progress[i]=h.pressProgress;keyboard.down[i]=h.pressed;
        if(h.justPressed&&k!=null){keyboard.active[i]=k;keyboard.activeSince[i]=now;keyboard.lastRepeat[i]=now;if(keyboard.activate(k,now,false))keyCount++;any=true;}
        if(h.pressed&&keyboard.active[i]!=null&&keyboard.active[i].repeatable()&&now-keyboard.activeSince[i]>=cfg.keyboardRepeatDelayMs&&now-keyboard.lastRepeat[i]>=cfg.keyboardRepeatMs){keyboard.lastRepeat[i]=now;if(keyboard.activate(keyboard.active[i],now,true))keyCount++;}
        if(h.justReleased)keyboard.active[i]=null;
        // Optional dwell typing (accessibility): hovering still for dwellMs presses once.
        if(cfg.keyboardDwellMs>0&&k!=null&&!h.pressed&&!keyboard.dwellFired[i]){float dwell=(now-keyboard.hoverSince[i])/(float)cfg.keyboardDwellMs;keyboard.progress[i]=max(keyboard.progress[i],constrain(dwell,0,1));
          if(dwell>=1){keyboard.dwellFired[i]=true;if(keyboard.activate(k,now,false))keyCount++;}}
      }
    }
    if(keyboard.closeRequested){keyboard.closeRequested=false;setKeyboardVisible(false);return;}
    keyboardWindow.repaint();
  }
  void publishKeyboard(long now){if(keyboardVisible&&keyboard!=null){synchronized(keyboard){keyboard.visible[0]=keyboard.visible[1]=false;}keyboardWindow.repaint();}}
  void moveTo(float tx,float ty){
    sx=tx;sy=ty;int nx=round(tx),ny=round(ty);if(lastX==nx&&lastY==ny)return;lastX=nx;lastY=ny;sink.move(nx,ny);moveCount++;error=sink.error();
  }
  void pressPrimary(){if(!enabled||buttonDown)return;sink.button(InputEvent.BUTTON1_DOWN_MASK,true);buttonDown=true;}
  void releasePrimary(){if(!buttonDown)return;sink.button(InputEvent.BUTTON1_DOWN_MASK,false);buttonDown=false;dragging=false;}
  void clickPrimary(){sink.button(InputEvent.BUTTON1_DOWN_MASK,true);sink.button(InputEvent.BUTTON1_DOWN_MASK,false);}
  void releaseDrag(){releasePrimary();dragging=false;dragMoved=false;}
}

class InteractionUI {
  final StudioUiButton enableButton=new StudioUiButton(),handButton=new StudioUiButton(),trackingButton=new StudioUiButton(),keyboardButton=new StudioUiButton(),releaseButton=new StudioUiButton();
  // Shared depth + body-centric metric 3D body preview block (BodyTracking.pde).
  final BodySkeletonPreview preview=new BodySkeletonPreview();

  float statusHeight(){return studio.ui.metricPanelHeight(max(80,width-2*studioUiMargin()),12,false);
    }
  float actionHeight(float panelW){return studio.ui.actionPanelHeight(panelW,6,true);
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
  void drawVision(float x,float y,float w,float h){card(x,y,w,h);cardTitle(x,y,w,interactionState().i18n.tr(interactionState().tracking!=null&&interactionState().tracking.usesRgb()?"panel.vision_rgb":"panel.vision"));
    float px=x+12,py=y+studioUiCardTitleHeight(),pw=max(1,w-24),ph=max(1,h-studioUiCardTitleHeight()-12),g=max(8,studioUiGap()*.65f);
    boolean sideBySide=pw>=780;
    if(sideBySide){
      float depthW=max(1,(pw-g)*.44f),bodyW=max(1,pw-g-depthW);drawDepthView(px,py,depthW,ph);drawSkeleton3DView(px+depthW+g,py,bodyW,ph);
    }else{
      float depthH=max(1,(ph-g)*.40f),bodyH=max(1,ph-g-depthH);drawDepthView(px,py,pw,depthH);drawSkeleton3DView(px,py+depthH+g,pw,bodyH);
    }
  }
  void drawDepthView(float x,float y,float w,float h){
    // Presentation uses the sensor-facing image orientation. Cursor mirroring is
    // intentionally independent so desktop control can remain intuitive.
    boolean rgb=interactionState().tracking!=null&&interactionState().tracking.usesRgb();
    preview.drawDepth(interactionState().depthImage,interactionState().i18n.tr(rgb?"panel.rgb":"panel.metric_depth"),interactionState().i18n.tr(rgb?"waiting.rgb":"waiting.depth"),x,y,w,h);
  }
  void drawSkeleton3DView(float x,float y,float w,float h){
    InteractionConfig c=interactionState().config;
    // Interactivity uses a fixed nominal metric frame plus the shared safety-fit/follow transform.
    preview.configure(c.bodyViewFixedHeightM,c.bodyViewFixedWidthM,c.bodyViewTargetOccupancy,c.bodyViewArmOccupancy,c.bodyViewCenterYOffsetM,c.bodyViewReferenceDistanceM);
    preview.draw(interactionState().skeleton,interactionState().interactionCloud,interactionState().i18n,x,y,w,h,new BodyPreviewOverlay(){
      public void draw(BodySkeletonPreview view,SkeletonPose3D s,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch,float vx,float vy,float vw,float vh){
        drawControlCloud3D(s,root,cx,cy,sc,yaw,pitch,vx,vy,vw,vh);}});
  }
  PVector project3DJoint(SkeletonJoint3D j,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){return preview.project3DJoint(j,root,cx,cy,sc,yaw,pitch);}
  void drawControlCloud3D(SkeletonPose3D s,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch,float vx,float vy,float vw,float vh){
    InteractionDesktopController dc=interactionState().desktop;if(dc==null)return;SkeletonJoint3D hand=dc.primaryJoint(s);if(hand==null||!hand.tracked())return;
    PVector hp=project3DJoint(hand,root,cx,cy,sc,yaw,pitch),sp=project3DJoint(s.spine,root,cx,cy,sc,yaw,pitch);
    float forward=max(0,dc.forwardDistance(s,hand)),quality=constrain(.55f*hand.confidence+.45f*s.interactionConfidence,0,1);
    float radius=(18+26*constrain(forward/.32f,0,1))*studioUiScale();
    // Overlay follows the same hard viewport contract as the body cloud. Even a
    // hand at the FOV edge cannot paint rings outside the 3D panel.
    hp=preview.clampToViewport(hp,radius+3);sp=preview.clampToViewport(sp,3);
    stroke(0xFF68A9E8,70);strokeWeight(max(1,studioUiScale()));line(sp.x,sp.y,hp.x,hp.y);
    noFill();for(int ring=0;ring<3;ring++){float rr=radius*(.52f+ring*.27f);stroke(0xFF68A9E8,70-ring*15);strokeWeight(max(1,studioUiScale()));ellipse(hp.x,hp.y,rr*2,rr*2*.72f);}
    noStroke();float t=millis()*0.001f;for(int i=0;i<30;i++){float a=TWO_PI*i/30.0f+t*(.20f+(i%5)*.025f),rr=radius*(.18f+.78f*((i*37)%29)/28.0f);
      float px=hp.x+cos(a)*rr,py=hp.y+sin(a)*rr*.72f;fill(0xFF68A9E8,70+round(150*quality));ellipse(px,py,max(1.8f,2.8f*studioUiScale()),max(1.8f,2.8f*studioUiScale()));}
    fill(0xFF68A9E8,230);ellipse(hp.x,hp.y,9*studioUiScale(),9*studioUiScale());
    if(dc.enabled&&dc.desktopBounds!=null&&!Float.isNaN(dc.sx)&&!Float.isNaN(dc.sy)){float nx=(dc.sx-dc.desktopBounds.x)/max(1,dc.desktopBounds.width-1.0f),ny=(dc.sy-dc.desktopBounds.y)/max(1,dc.desktopBounds.height-1.0f);
      float mapW=min(118*studioUiScale(),vw*.24f),mapH=mapW*.56f,mx=vx+vw-mapW-18,my=vy+vh-mapH-18;noFill();stroke(0xFF68A9E8,125);rect(mx,my,mapW,mapH,5);
      noStroke();fill(0xFF68A9E8,235);ellipse(mx+constrain(nx,0,1)*mapW,my+constrain(ny,0,1)*mapH,7*studioUiScale(),7*studioUiScale());}
  }
  String handState(InteractionHand h,String key){String name=interactionState().i18n.tr(key);
    if(h==null||!h.tracked)return name+" —";if(h.pressed)return name+" ●";if(h.engaged)return name+" "+round(h.pressProgress*100)+"%";return name+" ○";}
  String xyz(SkeletonJoint3D j){return j==null||!j.tracked()?"—":String.format(Locale.US,"%.2f / %.2f / %.2f m",j.world.x,j.world.y,j.world.z);
    }
  void drawStatus(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,interactionState().i18n.tr("panel.status"));float pad=12;

    String live=interaction3dLive()?interactionState().i18n.tr("state.live"):interactionState().i18n.tr("state.wait");

    String syncValue=interactionState().rgbd!=null&&interactionState().rgbd.source.depthConnected?interactionState().i18n.tr("state.live"):"—";

    String sk=interactionState().skeleton!=null&&interactionState().skeleton.tracked?interactionState().i18n.format("state.tracked",interactionState().skeleton.confidence*100):interactionState().i18n.tr("tracker."+(interactionState().skeletonSession==null?"searching":interactionState().skeletonSession.statusReason()));

    String depth=interactionState().skeleton==null?"—":String.format(Locale.US,"%.2f m",interactionState().skeleton.meanDepthM);

    String mode=interactionState().desktop==null?interactionState().i18n.tr("gesture.disabled"):interactionState().i18n.tr(interactionState().desktop.gestureKey());

    String actions=interactionState().desktop==null?"0 / 0 / 0 / 0":interactionState().desktop.doubleClickCount+" / "+interactionState().desktop.rightClickCount+" / "+interactionState().desktop.dragCount+" / "+interactionState().desktop.scrollCount;

    SkeletonPose3D pose=interactionState().skeleton;String category=interactionState().config==null?"auto":interactionState().config.trackingCategory;
    String fingers=pose==null?"—":"L "+pose.leftHandDetail.fingerCount+" / R "+pose.rightHandDetail.fingerCount;
    InteractionDesktopController dc=interactionState().desktop;
    String hands=dc==null?"—":handState(dc.leftHand,"keyboard.hand_left_short")+"  "+handState(dc.rightHand,"keyboard.hand_right_short");
    String kb=dc==null||!dc.keyboardVisible?interactionState().i18n.tr("state.keyboard_off"):interactionState().i18n.format("state.keyboard_on",(float)dc.keyCount);
    String[] labels={interactionState().i18n.tr("label.kinect"),interactionState().i18n.tr("label.sync"),interactionState().i18n.tr("label.skeleton"),interactionState().i18n.tr("label.depth"),
      interactionState().i18n.tr("label.right_hand_xyz"),interactionState().i18n.tr("label.left_hand_xyz"),interactionState().i18n.tr("label.tracking_category"),interactionState().i18n.tr("label.fingers"),interactionState().i18n.tr("label.mode"),interactionState().i18n.tr("label.actions"),
      interactionState().i18n.tr("label.hands_active"),interactionState().i18n.tr("label.keyboard")};
    String[] values={live,syncValue,sk,depth,pose==null?"—":xyz(pose.rightHand),pose==null?"—":xyz(pose.leftHand),interactionState().i18n.tr("tracking."+category),fingers,mode,actions,hands,kb};
    boolean[] active={interaction3dLive(),interactionState().rgbd!=null,pose!=null&&pose.tracked,pose!=null,pose!=null&&pose.rightHand.tracked(),pose!=null&&pose.leftHand.tracked(),
      pose!=null&&interactionState().desktop!=null&&interactionState().desktop.detailedMode(pose),pose!=null&&(pose.leftHandDetail.fingersTracked()||pose.rightHandDetail.fingersTracked()),interactionState().controlEnabled,interactionState().controlEnabled,
      dc!=null&&(dc.leftHand.engaged||dc.rightHand.engaged),dc!=null&&dc.keyboardVisible};
    StudioUiMetrics ui=studio.ui.metrics();float ix=x+ui.panelPad,iy=y+ui.cardTitleH+ui.panelPad*.45f,iw=max(1,w-ui.panelPad*2),ih=max(1,h-ui.cardTitleH-ui.panelPad*1.45f);

    studio.ui.drawMetricGrid(labels,values,active,ix,iy,iw,ih);
  }
  void statusMetric(float x,float y,float w,float h,String label,String value,boolean active){studio.ui.renderer.metric(x,y,w,h,label,value,active);
    }
  void drawActions(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,interactionState().i18n.tr("panel.actions"));StudioUiMetrics ui=studio.ui.metrics();
    String handValue=interactionState().i18n.tr("hand."+interactionState().config.hand);String trackingValue=interactionState().i18n.tr("tracking."+interactionState().config.trackingCategory);
    boolean desktopAvailable=interactionState().desktop!=null&&interactionState().desktop.available();
    // Enable/hand controls remain clickable even when the OS pointer backend is
    // temporarily unavailable. The click then reports the backend reason instead
    // of presenting a visually inert control.
    enableButton.require("").configure(interactionState().i18n.tr(interactionState().controlEnabled?"button.disable":"button.enable"),true,interactionState().controlEnabled,
      false,false);handButton.configure(interactionState().i18n.tr("button.hand")+": "+handValue,true,"auto".equals(interactionState().config.hand),false,false);
    trackingButton.configure(interactionState().i18n.tr("button.tracking")+": "+trackingValue,true,"hands_fingers".equals(interactionState().config.trackingCategory),false,false);
    releaseButton.configure(interactionState().i18n.tr("button.release"),interactionState().controlEnabled&&interactionState().desktop!=null&&interactionState().desktop.available(),false,
      false,false);ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();
    boolean kbOn=interactionState().desktop!=null&&interactionState().desktop.keyboardVisible;
    keyboardButton.configure(interactionState().i18n.tr(kbOn?"button.keyboard_hide":"button.keyboard_show"),desktopAvailable,kbOn,false,false);
    items.add(enableButton);items.add(handButton);items.add(trackingButton);items.add(keyboardButton);items.add(releaseButton);float footer=ui.footerH;
    studio.ui.layoutButtons(items,x+ui.panelPad,y+ui.cardTitleH+ui.panelPad*.45f,max(1,w-ui.panelPad*2),max(1,h-ui.cardTitleH-ui.panelPad*1.45f-footer));
    for(StudioUiButton item:items)item.draw();String note=interactionState().status==null?"":interactionState().status;
    studio.ui.renderer.statusFooter(x+ui.panelPad,y+h-footer,w-ui.panelPad*2,footer,note,true);

  }
  void handleMouse(float mx,float my){if(enableButton.hit(mx,my))toggleInteractionControl();
    else if(handButton.hit(mx,my))cycleInteractionHand();else if(trackingButton.hit(mx,my))cycleInteractionTrackingCategory();else if(keyboardButton.hit(mx,my))toggleInteractionKeyboard();else if(releaseButton.hit(mx,my)&&interactionState().desktop!=null)interactionState().desktop.releaseDrag();
    }
  void card(float x,float y,float w,float h){studio.ui.module(interactionState().i18n).panel("",x,y,w,h);
    }void cardTitle(float x,float y,float w,String title){studio.ui.module(interactionState().i18n).panelTitle(x,y,w,title);
    }
}

