// Responsive geometry is supplied by StudioUiMetrics.

// ===== SynKinect Studio / Interactivity =====
// Interactivity owns an independent RGB-D session through the shared transport boundary.
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
  SkeletonTracker tracker;
  InteractionRuntime runtime;
  InteractionDesktopController desktop;
  SkeletonPublisher nuiPublisher;
  InteractionOrbCloud cloud;
  InteractionUI ui;
  PImage rgbImage;
  SkeletonPose3D skeleton;
  long lastProcessedFrame=-1;
  volatile boolean controlEnabled=false;
  volatile String status="";
}

String loadInteractionHandPreference(String fallback){
  File file=studio.services.paths.dataFile("interactivity","preferences.properties");
  
  Properties p=studio.services.configRules.load(file,"interactivity-preferences");
  
  String value=studio.services.configRules.text(p,"cursor.hand",fallback).toLowerCase(Locale.ROOT);
  
  return ("auto".equals(value)||"left".equals(value)||"right".equals(value))?value:fallback;
  
}
void saveInteractionHandPreference(String hand){
  File file=studio.services.paths.dataFile("interactivity","preferences.properties"),parent=file.getParentFile();
  
  if(parent!=null&&!parent.exists()&&!parent.mkdirs())return;
  Properties p=studio.services.configRules.load(file,"interactivity-preferences");
  p.setProperty("cursor.hand",hand);File tmp=new File(file.getAbsolutePath()+".tmp");
  
  try(Writer out=new OutputStreamWriter(new FileOutputStream(tmp),java.nio.charset.StandardCharsets.UTF_8)){
    p.store(out,"SynKinect Interactivity preferences");
    try{Files.move(tmp.toPath(),file.toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);
      }catch(AtomicMoveNotSupportedException e){Files.move(tmp.toPath(),file.toPath(),StandardCopyOption.REPLACE_EXISTING);
      }
  }catch(IOException e){tmp.delete();}
}
void cycleInteractionHand(){
  if(interactionState().desktop==null)return;String next=interactionState().desktop.cycleHandMode();
  interactionState().config.hand=next;saveInteractionHandPreference(next);
  interactionState().status=interactionState().i18n.tr("button.hand")+": "+interactionState().i18n.tr("hand."+next);
  
}

void prepareInteractivityRgbdCore(){
  InteractionModuleState state=interactionState();
  state.rgbd=new RgbdSession(state.i18n);
  state.rgbd.selectDevice(studio.selectedKinect());
}
void refreshInteractionCalibrationForSelectedDevice(){
  InteractionModuleState state=interactionState();
  if(state.rgbd==null)return;
  String before=state.rgbd.calibration.deviceId;
  state.rgbd.selectDevice(studio.selectedKinect());
  if(!Objects.equals(before,state.rgbd.calibration.deviceId)&&state.tracker!=null)state.tracker.reset();
  
}
void setupInteractivityModule(){
  interactionState().config=new InteractionConfig();interactionState().config.load(studio.services.paths.resource("interactivity","config.properties"));
  interactionState().config.hand=loadInteractionHandPreference(interactionState().config.hand);
  
  interactionState().i18n=new InteractionI18n(studio.currentLanguage());
  prepareInteractivityRgbdCore();
  interactionState().tracker=studio.services.skeletons.createTracker(interactionState().rgbd.calibration,interactionState().rgbd.registration);
  
  interactionState().processor=new InteractionFrameProcessor(interactionState().config,interactionState().tracker);
  
  interactionState().desktop=new InteractionDesktopController(interactionState().config);
  
  interactionState().nuiPublisher=new SkeletonPublisher();
  interactionState().cloud=new InteractionOrbCloud(interactionState().config);
  interactionState().rgbd.setHqColorRequested(false);
  interactionState().runtime=new InteractionRuntime(interactionState().config,interactionState().rgbd,interactionState().processor);
  
  interactionState().ui=new InteractionUI();interactionState().status=interactionState().i18n.tr("status.ready");
  
}
void activateInteractivityModule(){
  interactionState().lastProcessedFrame=-1;interactionState().skeleton=null;interactionState().rgbImage=null;
  
  if(interactionState().tracker!=null)interactionState().tracker.reset();
  // Interactivity always owns a fresh VGA RGB+Depth session.
  if(interactionState().rgbd!=null)interactionState().rgbd.setHqColorRequested(false);
  
  if(interactionState().runtime!=null)interactionState().runtime.start();
}
void requestDeactivateInteractivityModule(){
  interactionState().controlEnabled=false;
  if(interactionState().desktop!=null)interactionState().desktop.setEnabled(false);
  
  if(interactionState().cloud!=null)interactionState().cloud.reset();
  if(interactionState().runtime!=null)interactionState().runtime.requestStop();
}
void deactivateInteractivityModule(){
  interactionState().controlEnabled=false;
  if(interactionState().desktop!=null)interactionState().desktop.setEnabled(false);
  
  if(interactionState().cloud!=null)interactionState().cloud.reset();
  if(interactionState().runtime!=null)interactionState().runtime.stop(false);
  if(interactionState().nuiPublisher!=null)interactionState().nuiPublisher.close();
  
}
void disposeInteractivityModule(){deactivateInteractivityModule();}
void drawInteractivityModule(){background(interactionState().theme.BG);serviceInteractivityFrames();
  if(interactionState().cloud!=null)interactionState().cloud.update(interactionState().skeleton);
  if(interactionState().ui!=null)interactionState().ui.draw();}

// UI thread: immutable snapshots only. No transport or CV work executes here.
void serviceInteractivityFrames(){
  InteractionProcessedFrame p=interactionState().processor==null?null:interactionState().processor.latest();
  
  if(p!=null&&p.frameNumber!=interactionState().lastProcessedFrame){interactionState().lastProcessedFrame=p.frameNumber;
    interactionState().skeleton=p.skeleton;if(interactionState().nuiPublisher!=null)interactionState().nuiPublisher.publish(p.skeleton,p.frameNumber);
    applyInteractionRgbPreview(p.previewPixels);}
  if(interactionState().desktop!=null){interactionState().desktop.setEnabled(interactionState().controlEnabled);
    if(interactionState().controlEnabled&&interactionState().skeleton!=null&&interactionState().skeleton.interactionTracked())interactionState().desktop.update(interactionState().skeleton);
    }
}
void applyInteractionRgbPreview(int[] pixels){if(pixels==null||pixels.length!=studio.services.scannerProtocol.WIDTH*studio.services.scannerProtocol.HEIGHT)return;
  if(interactionState().rgbImage==null)interactionState().rgbImage=createImage(studio.services.scannerProtocol.WIDTH,studio.services.scannerProtocol.HEIGHT,
    RGB);interactionState().rgbImage.loadPixels();System.arraycopy(pixels,0,interactionState().rgbImage.pixels,0,pixels.length);
  interactionState().rgbImage.updatePixels();}
boolean interaction3dLive(){if(interactionState().lastProcessedFrame>=0&&interactionState().processor!=null&&millis64()-interactionState().processor.lastPublishedMs<=interactionState().config.streamStaleMs)return true;
  return interactionState().runtime!=null&&interactionState().runtime.streamsLive();
  }
void interactivityMousePressed(){if(interactionState().ui!=null)interactionState().ui.handleMouse(studio.contentMouseX(),studio.contentMouseY());
  }
void toggleInteractionControl(){KinectDevice kd=studio.selectedKinect();if(!interactionState().controlEnabled&&(kd==null||!kd.cameraReady())){interactionState().controlEnabled=false;
    interactionState().status=interactionState().i18n.tr("status.ready");return;}if(!interactionState().controlEnabled&&(interactionState().desktop==null||!interactionState().desktop.available())){
    interactionState().controlEnabled=false;interactionState().status=interactionState().i18n.tr("status.desktop_unavailable");
    return;}interactionState().controlEnabled=!interactionState().controlEnabled;
  if(interactionState().desktop!=null)interactionState().desktop.setEnabled(interactionState().controlEnabled);
  interactionState().status=interactionState().i18n.tr(interactionState().controlEnabled?"status.control_on":"status.control_off");
  }
class InteractionConfig {
  int workerJoinMs=2200,streamStaleMs=1800,previewHz=15;
  boolean mirrorX=true;String hand="auto";int cursorMaxHz=60,cursorLostReleaseMs=800,cursorAutoHandSwitchMs=450;
  float cursorAutoHandScoreMargin=0.12f,cursorDeadzonePx=1.8f,cursorStationaryDeadzonePx=3.0f,cursorFastAlpha=0.62f,cursorSlowAlpha=0.20f,cursorFastDistancePx=42,
  cursorPredictionMs=10.0f,cursorMaxJumpPx=140.0f,cursorConfidenceFloor=0.25f;
  float volumeHalfWidthM=0.55f,volumeTopM=0.42f,volumeBottomM=0.48f,minHandForwardM=0.015f;
  
  float pressForwardM=0.16f,releaseForwardM=0.09f;int twoHandStableMs=180,doubleClickStableMs=170,doubleClickCooldownMs=700,scrollCooldownMs=45;
  float scrollThresholdM=0.018f,scrollGainPerM=82.0f;
  int cloudParticles=300,cloudTrailSamples=22;float cloudRadiusPx=24,cloudSpring=42,cloudDamping=7,cloudFlow=0.24f,cloudTrailStrength=1,cloudStretchGain=0.020f,
  cloudMaxStretch=3;
  void load(File file){
    ConfigRules r=studio.services.configRules;Properties p=r.load(file,"interaction");
    
    workerJoinMs=r.integer(p,"transport.workerJoinMs",workerJoinMs,100,10000);streamStaleMs=r.integer(p,"transport.streamStaleMs",streamStaleMs,250,10000);
    previewHz=r.integer(p,"vision.previewHz",previewHz,1,30);
    mirrorX=r.flag(p,"cursor.mirrorX",mirrorX);hand=r.text(p,"cursor.hand",hand).toLowerCase(Locale.ROOT);
    if(!"auto".equals(hand)&&!"left".equals(hand)&&!"right".equals(hand))hand="auto";
    cursorMaxHz=r.integer(p,"cursor.maxHz",cursorMaxHz,10,240);cursorLostReleaseMs=r.integer(p,"cursor.lostReleaseMs",cursorLostReleaseMs,100,5000);
    cursorAutoHandSwitchMs=r.integer(p,"cursor.autoHandSwitchMs",cursorAutoHandSwitchMs,0,3000);
    cursorAutoHandScoreMargin=r.decimal(p,"cursor.autoHandScoreMargin",cursorAutoHandScoreMargin,0,1);
    cursorDeadzonePx=r.decimal(p,"cursor.deadzonePx",cursorDeadzonePx,0,50);cursorStationaryDeadzonePx=r.decimal(p,"cursor.stationaryDeadzonePx",cursorStationaryDeadzonePx,
      cursorDeadzonePx,80);cursorFastAlpha=r.decimal(p,"cursor.fastAlpha",cursorFastAlpha,0.01f,1);
    cursorSlowAlpha=r.decimal(p,"cursor.slowAlpha",cursorSlowAlpha,0.01f,1);cursorFastDistancePx=r.decimal(p,"cursor.fastDistancePx",cursorFastDistancePx,
      1,300);cursorPredictionMs=r.decimal(p,"cursor.predictionMs",cursorPredictionMs,0,40);
    cursorMaxJumpPx=r.decimal(p,"cursor.maxJumpPx",cursorMaxJumpPx,10,1000);cursorConfidenceFloor=r.decimal(p,"cursor.confidenceFloor",cursorConfidenceFloor,
      0.05f,1.0f);volumeHalfWidthM=r.decimal(p,"cursor.volumeHalfWidthM",volumeHalfWidthM,.1f,2);
    volumeTopM=r.decimal(p,"cursor.volumeTopM",volumeTopM,.05f,2);volumeBottomM=r.decimal(p,"cursor.volumeBottomM",volumeBottomM,.05f,2);
    minHandForwardM=r.decimal(p,"cursor.minHandForwardM",minHandForwardM,-.5f,.5f);
    
    pressForwardM=r.decimal(p,"gesture.pressForwardM",pressForwardM,.03f,.45f);releaseForwardM=r.decimal(p,"gesture.releaseForwardM",releaseForwardM,.01f,
      pressForwardM-.01f);twoHandStableMs=r.integer(p,"gesture.twoHandStableMs",twoHandStableMs,0,3000);
    doubleClickStableMs=r.integer(p,"gesture.doubleClickStableMs",doubleClickStableMs,0,3000);
    doubleClickCooldownMs=r.integer(p,"gesture.doubleClickCooldownMs",doubleClickCooldownMs,0,5000);
    scrollCooldownMs=r.integer(p,"gesture.scrollCooldownMs",scrollCooldownMs,0,1000);
    scrollThresholdM=r.decimal(p,"gesture.scrollThresholdM",scrollThresholdM,.001f,.3f);
    scrollGainPerM=r.decimal(p,"gesture.scrollGainPerM",scrollGainPerM,1,500);
    cloudParticles=r.integer(p,"cloud.particles",cloudParticles,80,1200);cloudTrailSamples=r.integer(p,"cloud.trailSamples",cloudTrailSamples,6,80);
    cloudRadiusPx=r.decimal(p,"cloud.radiusPx",cloudRadiusPx,5,120);cloudSpring=r.decimal(p,"cloud.spring",cloudSpring,1,150);
    cloudDamping=r.decimal(p,"cloud.damping",cloudDamping,.1f,30);cloudFlow=r.decimal(p,"cloud.flow",cloudFlow,0,3);
    cloudTrailStrength=r.decimal(p,"cloud.trailStrength",cloudTrailStrength,.1f,4);
    cloudStretchGain=r.decimal(p,"cloud.stretchGain",cloudStretchGain,0,.2f);cloudMaxStretch=r.decimal(p,"cloud.maxStretch",cloudMaxStretch,1,12);
    
  }
}

class InteractionI18n extends ModuleI18n {InteractionI18n(String requested){super("interactivity",requested);
    }}

class InteractionTheme {
  final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE_ALT=0xFF202832,SURFACE_RAISED=0xFF293440;
  
  final int BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,ACCENT=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B,BAD=0xFFE17D7D,PREVIEW=0xFF0B0F13,GRID=0xFF35404A;
  
  final int FONT_TINY=STUDIO_FONT_TINY,FONT_SMALL=STUDIO_FONT_SMALL,FONT_BODY=STUDIO_FONT_BODY,FONT_METRIC=STUDIO_FONT_METRIC,FONT_TITLE=STUDIO_FONT_TITLE;
  
}

class InteractionVisionSnapshot {
  final RawRgbFrame rgbFrame;final DepthFrame depthFrame;final long rgbTickMs,depthTickMs,sequence;
  
  InteractionVisionSnapshot(RgbdFramePair p){rgbFrame=p.rgb;depthFrame=p.depth;rgbTickMs=p.rgb.timestampUs/1000L;
    depthTickMs=p.depth.timestampUs/1000L;sequence=p.sequence;}long key(){return sequence;
    }
}
class InteractionProcessedFrame {long frameNumber=-1;int[] previewPixels;SkeletonPose3D skeleton;
  }

class InteractionFrameProcessor {
  final InteractionConfig cfg;final SkeletonTracker tracker;final Object lock=new Object();
  volatile boolean running=false;volatile long runGeneration=0;volatile InteractionProcessedFrame published=null;
  volatile long lastPublishedMs=0;long lastPreviewMs=0;Thread worker;InteractionVisionSnapshot pending=null;
  
  InteractionFrameProcessor(InteractionConfig cfg,SkeletonTracker tracker){this.cfg=cfg;
    this.tracker=tracker;}
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
  void submit(InteractionVisionSnapshot f){if(f==null||f.rgbFrame==null||f.rgbFrame.data==null||f.depthFrame==null)return;
    synchronized(lock){if(!running)return;pending=f;lock.notifyAll();}}
  InteractionProcessedFrame latest(){return published;}
  void clearPublished(){synchronized(lock){pending=null;published=null;lastPublishedMs=0;
      lastPreviewMs=0;}}
  void loop(long generation){while(true){InteractionVisionSnapshot f;synchronized(lock){while(running&&generation==runGeneration&&pending==null)try{lock.wait();
          }catch(InterruptedException e){if(!running||generation!=runGeneration)return;
          }if(!running||generation!=runGeneration)return;f=pending;pending=null;}try{InteractionProcessedFrame out=new InteractionProcessedFrame();
        out.frameNumber=f.key();out.skeleton=tracker.track(f.depthFrame,Math.max(f.rgbTickMs,f.depthTickMs));
        long now=millis64();if(lastPreviewMs==0||now-lastPreviewMs>=1000/max(1,cfg.previewHz)){out.previewPixels=rgbPreview(f.rgbFrame);
          lastPreviewMs=now;}if(generation==runGeneration){published=out;lastPublishedMs=now;
          }}catch(Exception e){if(generation==runGeneration)println("Interactivity 3D processor warning: "+safeStudioMessage(e));
        }}}
  int[] rgbPreview(RawRgbFrame frame){int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT;
    if(frame==null||frame.data==null||frame.width!=w||frame.height!=h||frame.pixelFormat!=studio.services.scannerProtocol.PIXEL_BAYER_GRBG8||frame.data.length!=w*h)return null;
    int[] out=new int[w*h];return RgbHqProcessor.decodeBayerGrbg(frame.data,w,h,out)?out:null;
    }
}

class InteractionRuntime {
  final InteractionConfig cfg;final RgbdSession rgbd;final InteractionFrameProcessor processor;
  final Object lock=new Object();volatile boolean running=false;volatile long runGeneration=0;
  volatile long lastInputMs=0;Thread connectionWorker;long lastSubmitted=-1;
  InteractionRuntime(InteractionConfig c,RgbdSession s,InteractionFrameProcessor p){cfg=c;
    rgbd=s;processor=p;}
  void start(){synchronized(lock){if(running)return;running=true;final long generation=++runGeneration;
      lastInputMs=millis64();lastSubmitted=-1;rgbd.start();processor.start();connectionWorker=studio.services.workers.start("Interaction-RGBD",new Runnable(){
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
        RgbdFramePair pair=rgbd.latestRgbdPairAfter(lastSubmitted);if(pair!=null){lastSubmitted=pair.sequence;
          lastInputMs=millis64();processor.submit(new InteractionVisionSnapshot(pair));
          }Thread.sleep(2);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;
        Thread.currentThread().interrupt();return;}catch(Exception e){if(running&&generation==runGeneration)println("Interactivity RGBD warning: "+safeStudioMessage(e));
        }}}
}

class InteractionOrbCloud {
  final InteractionConfig cfg;final int count,trailCount;float[] x,y,vx,vy,phase,ring,lag;
  int[] band;float[] histX,histY;long lastMs=0;SkeletonPose3D skeleton;float lastHandX=Float.NaN,lastHandY=Float.NaN,handVx=0,handVy=0;
  
  InteractionOrbCloud(InteractionConfig cfg){
    this.cfg=cfg;count=max(80,cfg.cloudParticles);trailCount=max(6,cfg.cloudTrailSamples);
    x=new float[count];y=new float[count];vx=new float[count];vy=new float[count];
    phase=new float[count];ring=new float[count];lag=new float[count];band=new int[count];
    histX=new float[trailCount];histY=new float[trailCount];
    Random r=new Random(360112);for(int i=0;i<count;i++){phase[i]=r.nextFloat()*TWO_PI;
      ring[i]=sqrt(r.nextFloat());lag[i]=pow(r.nextFloat(),0.72f);band[i]=min(2,floor(lag[i]*3));
      x[i]=studio.services.scannerProtocol.WIDTH*0.5f;y[i]=studio.services.scannerProtocol.HEIGHT*0.5f;
      }
  }
  boolean useLeft(SkeletonPose3D s){if(s==null)return false;if(interactionState().desktop!=null)return interactionState().desktop.primaryLeft(s);
    if("left".equals(cfg.hand)&&s.leftHandTracked())return true;if("right".equals(cfg.hand)&&s.rightHandTracked())return false;
    return s.leftHandTracked()&&!s.rightHandTracked();}
  PVector primaryHand(SkeletonPose3D s){if(s==null)return null;boolean left=useLeft(s);
    if(left&&s.leftHandTracked())return s.leftHand.image;if(!left&&s.rightHandTracked())return s.rightHand.image;
    if(s.rightHandTracked())return s.rightHand.image;if(s.leftHandTracked())return s.leftHand.image;
    return null;}
  void reset(){skeleton=null;lastMs=0;lastHandX=lastHandY=Float.NaN;handVx=handVy=0;
    Arrays.fill(vx,0);Arrays.fill(vy,0);}
  void seedHistory(float hx,float hy){for(int i=0;i<trailCount;i++){histX[i]=hx;histY[i]=hy;
      }for(int i=0;i<count;i++){x[i]=hx;y[i]=hy;vx[i]=vy[i]=0;}}
  void pushHistory(float hx,float hy){for(int i=trailCount-1;i>0;i--){histX[i]=histX[i-1];
      histY[i]=histY[i-1];}histX[0]=hx;histY[0]=hy;}
  void update(SkeletonPose3D s){
    skeleton=s;if(s==null||!s.tracked)return;PVector h=primaryHand(s);if(h==null)return;
    long now=millis64();float dt=lastMs==0?1.0f/60.0f:constrain((now-lastMs)/1000.0f,0.004f,0.040f);
    lastMs=now;float t=now*0.001f;
    if(Float.isNaN(lastHandX)){lastHandX=h.x;lastHandY=h.y;seedHistory(h.x,h.y);}float rawVx=(h.x-lastHandX)/dt,rawVy=(h.y-lastHandY)/dt;
    lastHandX=h.x;lastHandY=h.y;float va=1.0f-exp(-10.0f*dt);handVx=lerp(handVx,rawVx,va);
    handVy=lerp(handVy,rawVy,va);pushHistory(h.x,h.y);
    float speed=sqrt(handVx*handVx+handVy*handVy),ux=speed>5?handVx/speed:1,uy=speed>5?handVy/speed:0,pxAxis=-uy,pyAxis=ux;
    float stretch=1.0f+min(max(0,cfg.cloudMaxStretch-1.0f),speed*cfg.cloudStretchGain);
    float baseRadius=cfg.cloudRadiusPx*(0.92f+0.08f*constrain(speed/700.0f,0,1));
    
    for(int i=0;i<count;i++){
      int hi=constrain(round(lag[i]*(trailCount-1)*cfg.cloudTrailStrength),0,trailCount-1);
      float cx=histX[hi],cy=histY[hi],tailFade=1.0f-0.42f*lag[i];float a=phase[i]+t*(0.52f+0.20f*((i%11)/11.0f));
      float rr=baseRadius*(0.18f+0.82f*ring[i])*tailFade;
      float longAxis=rr*(1.0f+(stretch-1.0f)*(0.35f+0.65f*lag[i])),shortAxis=rr/max(1.0f,sqrt(stretch));
      float swirl=sin(a*1.83f+t*0.48f+phase[i])*cfg.cloudFlow*baseRadius*(0.45f+0.55f*lag[i]);
      
      float localLong=cos(a)*longAxis-swirl*0.20f,localPerp=sin(a)*shortAxis+swirl;
      float tx=cx+ux*localLong+pxAxis*localPerp,ty=cy+uy*localLong+pyAxis*localPerp;
      
      float ax=(tx-x[i])*cfg.cloudSpring-vx[i]*cfg.cloudDamping,ay=(ty-y[i])*cfg.cloudSpring-vy[i]*cfg.cloudDamping;
      vx[i]+=ax*dt;vy[i]+=ay*dt;x[i]+=vx[i]*dt;y[i]+=vy[i]*dt;
    }
  }
  void draw(float sx,float sy){
    if(skeleton==null||!skeleton.tracked||primaryHand(skeleton)==null)return;strokeCap(ROUND);
    
    for(int b=2;b>=0;b--){int alpha=b==0?228:b==1?156:82;float core=b==0?2.5f:b==1?2.1f:1.7f,glow=core*2.8f;
      
      stroke(104,169,232,max(18,alpha/4));strokeWeight(glow*studioUiScale());beginShape(POINTS);
      for(int i=0;i<count;i++){if(band[i]!=b)continue;vertex(x[i]*sx,y[i]*sy);}endShape();
      
      stroke(104,169,232,alpha);strokeWeight(core*studioUiScale());beginShape(POINTS);
      for(int i=0;i<count;i++){if(band[i]!=b)continue;vertex(x[i]*sx,y[i]*sy);}endShape();
      
    }noStroke();
  }
}


class InteractionDesktopController {
  final InteractionConfig cfg;Robot robot;Rectangle desktopBounds;
  volatile boolean enabled=false,dragging=false,buttonDown=false,twoHandMode=false;
  volatile String handMode;
  float sx=Float.NaN,sy=Float.NaN,cursorVx=0,cursorVy=0,lastTargetX=Float.NaN,lastTargetY=Float.NaN;
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
  void resetPointerFilter(){sx=sy=Float.NaN;cursorVx=cursorVy=0;lastTargetX=lastTargetY=Float.NaN;
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
    PVector xAxis=PVector.sub(s.rightShoulder.world,s.leftShoulder.world);if(xAxis.mag()<0.05f)xAxis.set(1,0,0);
    else xAxis.normalize();PVector yAxis=PVector.sub(s.spine.world,s.shoulderCenter.world);
    if(yAxis.mag()<0.04f)yAxis.set(0,1,0);else yAxis.normalize();PVector normal=torsoNormal(s);
    if(normal==null)return null;PVector rel=PVector.sub(hand.world,s.spine.world);
    float lateral=rel.dot(xAxis),vertical=rel.dot(yAxis),forward=-rel.dot(normal);
    if(forward<cfg.minHandForwardM)return null;float nx=constrain((lateral+cfg.volumeHalfWidthM)/(2*cfg.volumeHalfWidthM),0,1),ny=constrain((vertical+cfg.volumeTopM)/max(.05f,
      cfg.volumeTopM+cfg.volumeBottomM),0,1);if(cfg.mirrorX)nx=1-nx;return new PVector(desktopBounds.x+nx*max(1,desktopBounds.width-1),desktopBounds.y+ny*max(1,
      desktopBounds.height-1));
  }
  void update(SkeletonPose3D s){
    long now=millis64();
    if(!enabled||robot==null||s==null||!s.interactionTracked()){if(enabled&&now-lastTrackedMs>cfg.cursorLostReleaseMs){releaseDrag();
        resetGesture();resetPointerFilter();}return;}
    updateAutoHand(s,now);SkeletonJoint3D primary=primaryJoint(s);if(primary==null)return;
    lastTrackedMs=now;SkeletonJoint3D secondary=secondaryJoint(s);PVector a=screenPoint(s,primary),b=screenPoint(s,secondary);
    
    if(a==null)return;boolean two=secondary!=null&&b!=null;updatePointer(a,now,primary.confidence);
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
    if(Float.isNaN(lastTargetX)){lastTargetX=tx;lastTargetY=ty;}float rvx=(tx-lastTargetX)/dt,rvy=(ty-lastTargetY)/dt;
    lastTargetX=tx;lastTargetY=ty;float va=1-exp(-12.0f*dt);cursorVx=lerp(cursorVx,rvx,va);
    cursorVy=lerp(cursorVy,rvy,va);
    if(Float.isNaN(sx)){sx=tx;sy=ty;}else{float jump=dist(sx,sy,tx,ty);if(jump>cfg.cursorMaxJumpPx){float scale=cfg.cursorMaxJumpPx/max(jump,.001f);
        tx=sx+(tx-sx)*scale;ty=sy+(ty-sy)*scale;}float d=dist(sx,sy,tx,ty),speed=constrain(d/max(1,cfg.cursorFastDistancePx),0,1),quality=constrain((confidence-cfg.cursorConfidenceFloor)/max(.001f,
        1-cfg.cursorConfidenceFloor),0,1),prediction=(cfg.cursorPredictionMs/1000.0f)*speed*quality;
      float px=tx+cursorVx*prediction,py=ty+cursorVy*prediction,a=lerp(cfg.cursorSlowAlpha,cfg.cursorFastAlpha,speed)*lerp(.62f,1.0f,quality);
      a=constrain(a,.04f,1);sx=lerp(sx,px,a);sy=lerp(sy,py,a);}
    sx=constrain(sx,desktopBounds.x,desktopBounds.x+max(0,desktopBounds.width-1));
    sy=constrain(sy,desktopBounds.y,desktopBounds.y+max(0,desktopBounds.height-1));
    int nxp=round(sx),nyp=round(sy);float movement=lastX<0?Float.MAX_VALUE:dist(lastX,lastY,nxp,nyp),speed=constrain(sqrt(cursorVx*cursorVx+cursorVy*cursorVy)/2200.0f,
      0,1),deadzone=lerp(cfg.cursorStationaryDeadzonePx,cfg.cursorDeadzonePx,speed);
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
    float px=x+12,py=y+studioUiCardTitleHeight(),pw=max(1,w-24),ph=max(1,h-studioUiCardTitleHeight()-12);
    fill(interactionState().theme.BG);rect(px,py,pw,ph,10);if(interactionState().rgbImage!=null){float[] vr=imageRect(interactionState().rgbImage,px,py,
        pw,ph);pushMatrix();if(interactionState().config.mirrorX){translate(vr[0]+vr[2],vr[1]);
        scale(-1,1);image(interactionState().rgbImage,0,0,vr[2],vr[3]);}else image(interactionState().rgbImage,vr[0],vr[1],vr[2],vr[3]);
      popMatrix();drawSkeletonOverlay(vr[0],vr[1],vr[2],vr[3]);}else{fill(0xFFAAB6C2);
      textAlign(CENTER,CENTER);studioText(STUDIO_FONT_BODY,false);text(ellipsizeToWidth(interactionState().i18n.tr("waiting.rgbd"),pw-20),px+pw/2,py+ph/2);
      textAlign(LEFT,BASELINE);}}
  float[] imageRect(PImage img,float x,float y,float w,float h){float sc=min(w/img.width,h/img.height),dw=img.width*sc,dh=img.height*sc;
    return new float[]{x+(w-dw)/2,y+(h-dh)/2,dw,dh};}
  void drawSkeletonOverlay(float x,float y,float w,float h){
    SkeletonPose3D s=interactionState().skeleton;if(s==null||!s.tracked)return;float sx=w/studio.services.scannerProtocol.WIDTH,sy=h/studio.services.scannerProtocol.HEIGHT;
    pushStyle();clip(x,y,w,h);pushMatrix();translate(x,y);if(interactionState().config.mirrorX){translate(w,0);
      scale(-1,1);}
    // Articulated virtual-body style: dark cylindrical outline, bright bone core and spherical joints.
    drawBodyBones(s,sx,sy,0xFF101820,max(5.2f,7.5f*studioUiScale()));drawBodyBones(s,sx,sy,0xFF58C7F3,max(2.2f,3.6f*studioUiScale()));
    
    if(s.head.tracked()){noFill();stroke(0xFF101820,230);strokeWeight(max(3,5*studioUiScale()));
      ellipse(s.head.image.x*sx,s.head.image.y*sy,s.faceWidthPx*sx,s.faceHeightPx*sy);
      stroke(0xFF58C7F3,245);strokeWeight(max(1.4f,2.4f*studioUiScale()));ellipse(s.head.image.x*sx,s.head.image.y*sy,s.faceWidthPx*sx,s.faceHeightPx*sy);
      }
    for(SkeletonJoint3D j:bodyJoints(s))jointNode(j,sx,sy);
    if(interactionState().cloud!=null)interactionState().cloud.draw(sx,sy);popMatrix();
    noClip();popStyle();
  }
  SkeletonJoint3D[] bodyJoints(SkeletonPose3D s){return new SkeletonJoint3D[]{s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,s.leftElbow,
      s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot}
    ;}
  void drawBodyBones(SkeletonPose3D s,float sx,float sy,int color,float weight){stroke(color,s.tracked?235:150);
    strokeWeight(weight);strokeCap(ROUND);bone(s.head,s.shoulderCenter,sx,sy);bone(s.shoulderCenter,s.spine,sx,sy);
    bone(s.spine,s.hipCenter,sx,sy);bone(s.leftShoulder,s.rightShoulder,sx,sy);bone(s.shoulderCenter,s.leftShoulder,sx,sy);
    bone(s.shoulderCenter,s.rightShoulder,sx,sy);bone(s.leftShoulder,s.leftElbow,sx,sy);
    bone(s.leftElbow,s.leftWrist,sx,sy);bone(s.leftWrist,s.leftHand,sx,sy);bone(s.rightShoulder,s.rightElbow,sx,sy);
    bone(s.rightElbow,s.rightWrist,sx,sy);bone(s.rightWrist,s.rightHand,sx,sy);bone(s.hipCenter,s.leftHip,sx,sy);
    bone(s.hipCenter,s.rightHip,sx,sy);bone(s.leftHip,s.rightHip,sx,sy);bone(s.leftHip,s.leftKnee,sx,sy);
    bone(s.leftKnee,s.leftAnkle,sx,sy);bone(s.leftAnkle,s.leftFoot,sx,sy);bone(s.rightHip,s.rightKnee,sx,sy);
    bone(s.rightKnee,s.rightAnkle,sx,sy);bone(s.rightAnkle,s.rightFoot,sx,sy);}
  void bone(SkeletonJoint3D a,SkeletonJoint3D b,float sx,float sy){if(a!=null&&b!=null&&a.tracked()&&b.tracked())line(a.image.x*sx,a.image.y*sy,b.image.x*sx,
      b.image.y*sy);}
  void jointNode(SkeletonJoint3D j,float sx,float sy){if(j==null||!j.tracked())return;
    float d=(j.state==2?10:8)*studioUiScale(),alpha=j.state==2?245:150;noStroke();
    fill(0xFF101820,230);ellipse(j.image.x*sx,j.image.y*sy,d+5*studioUiScale(),d+5*studioUiScale());
    fill(j.state==2?0xFFFFB54A:0xFF9AA9B5,alpha);ellipse(j.image.x*sx,j.image.y*sy,d,d);
    }
  String xyz(SkeletonJoint3D j){return j==null||!j.tracked()?"—":String.format(Locale.US,"%.2f / %.2f / %.2f m",j.world.x,j.world.y,j.world.z);
    }
  void drawStatus(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,interactionState().i18n.tr("panel.status"));float pad=12;
    
    String live=interaction3dLive()?interactionState().i18n.tr("state.live"):interactionState().i18n.tr("state.wait");
    
    String syncValue=interactionState().rgbd==null||Float.isNaN(interactionState().rgbd.syncResidualMs())?"—":interactionState().i18n.format("value.sync",
      interactionState().rgbd.syncResidualMs(),interactionState().rgbd.syncOffsetMs());
    
    String sk=interactionState().skeleton!=null&&interactionState().skeleton.tracked?interactionState().i18n.format("state.tracked",interactionState().skeleton.confidence*100):interactionState().i18n.tr("tracker."+(interactionState().tracker==null?"searching":interactionState().tracker.lastReason));
    
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
    KinectDevice selectedDevice=studio.selectedKinect();boolean cameraAvailable=interactionState().controlEnabled||(selectedDevice!=null&&selectedDevice.cameraReady());
    enableButton.configure(interactionState().i18n.tr(interactionState().controlEnabled?"button.disable":"button.enable"),cameraAvailable,interactionState().controlEnabled,
      true,false);handButton.configure(interactionState().i18n.tr("button.hand")+": "+handValue,true,false,false,false);
    releaseButton.configure(interactionState().i18n.tr("button.release"),interactionState().desktop!=null&&interactionState().desktop.buttonDown,false,
      false,false);ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();
    items.add(enableButton);items.add(handButton);items.add(releaseButton);float footer=ui.footerH;
    studio.ui.layoutButtons(items,x+ui.panelPad,y+ui.cardTitleH+ui.panelPad*.45f,max(1,w-ui.panelPad*2),max(1,h-ui.cardTitleH-ui.panelPad*1.45f-footer));
    for(StudioUiButton item:items)item.draw();String note=interactionState().status==null?"":interactionState().status;
    studio.ui.renderer.statusFooter(x+ui.panelPad,y+h-footer,w-ui.panelPad*2,footer,note,true);
    
  }
  void handleMouse(float mx,float my){if(enableButton.hit(mx,my))toggleInteractionControl();
    else if(handButton.hit(mx,my))cycleInteractionHand();else if(releaseButton.hit(mx,my)&&interactionState().desktop!=null)interactionState().desktop.releaseDrag();
    }
  void card(float x,float y,float w,float h){studio.ui.panel("",x,y,w,h).draw(interactionState().i18n);
    }void cardTitle(float x,float y,float w,String title){studio.ui.renderer.panelTitle(interactionState().i18n,x,y,w,title);
    }
}

