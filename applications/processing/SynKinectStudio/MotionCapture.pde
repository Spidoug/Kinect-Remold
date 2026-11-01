// ===== SynKinect Studio / Motion Capture module =====
// Built-in module "mocap". Backend: one BodyTrackingSession (BodyTracking.pde),
// a MocapRetargeter and the network sinks / BVH recorder (MocapSinks.pde).
// Frontend: composed only from host UI blocks (header, metric grid, action
// buttons, status footer) plus the shared BodySkeletonPreview block.
//
// Camera ownership: like every single-camera module, Motion Capture owns its
// BodyTrackingSession only while its tab is active. Leaving the tab stops the
// transport, closes the sockets (releasing ports) and finalizes a running BVH
// recording; returning re-opens the sinks that were enabled.

MocapModuleState mocapState(){return studio.state(MocapModuleState.class);}

class MocapConfig {
  String bindAddress="127.0.0.1",vmcHost="127.0.0.1",oscHost="127.0.0.1",jsonHost="127.0.0.1",jsonSpace="unity";
  int vmcPort=39539,oscPort=39542,jsonPort=39541,wsPort=39540,sendRate=60,previewHz=15,workerJoinMs=2200,streamStaleMs=1800;
  int[] vmcPresets={39539,39540};
  boolean mirror=false,centerRoot=true,vmcEnabled=true,oscEnabled=false,jsonEnabled=false,wsEnabled=true;
  void load(File file){
    ConfigRules r=studio.services.configRules;Properties p=r.load(file,"mocap");
    bindAddress=r.text(p,"bindAddress",bindAddress);
    vmcHost=r.text(p,"vmc.host",vmcHost);vmcPort=r.integer(p,"vmc.port",vmcPort,1,65535);
    oscHost=r.text(p,"osc.host",oscHost);oscPort=r.integer(p,"osc.port",oscPort,1,65535);
    jsonHost=r.text(p,"json.host",jsonHost);jsonPort=r.integer(p,"json.port",jsonPort,1,65535);
    wsPort=r.integer(p,"ws.port",wsPort,1,65535);
    jsonSpace="camera".equalsIgnoreCase(r.text(p,"json.space",jsonSpace))?"camera":"unity";
    mirror=r.flag(p,"mirror",mirror);centerRoot=r.flag(p,"root.center",centerRoot);
    sendRate=r.integer(p,"sendRate",sendRate,1,240);previewHz=r.integer(p,"vision.previewHz",previewHz,1,60);
    vmcEnabled=r.flag(p,"vmc.enabled",vmcEnabled);oscEnabled=r.flag(p,"osc.enabled",oscEnabled);jsonEnabled=r.flag(p,"json.enabled",jsonEnabled);wsEnabled=r.flag(p,"ws.enabled",wsEnabled);
    String presets=r.text(p,"vmc.presets","");if(presets.length()>0){ArrayList<Integer> v=new ArrayList<Integer>();
      for(String s:presets.split(","))try{int x=Integer.parseInt(s.trim());if(x>0&&x<65536)v.add(x);}catch(NumberFormatException ignored){}
      if(!v.isEmpty()){vmcPresets=new int[v.size()];for(int i=0;i<v.size();i++)vmcPresets[i]=v.get(i);}}
  }
}

class MocapI18n extends ModuleI18n {MocapI18n(String requested){super("mocap",requested);}}

class MocapModuleState {
  MocapConfig config;MocapI18n i18n;BodyTrackingSession tracking;final MocapRetargeter retargeter=new MocapRetargeter();
  LatestMailbox<BodyFrame> hub;MocapVmcSink vmc;MocapOscSink osc;MocapJsonUdpSink json;MocapWebSocketSink ws;final MocapBvhRecorder bvh=new MocapBvhRecorder();
  // desired sink state (survives tab changes); actual state lives in each sink
  boolean wantVmc,wantOsc,wantJson,wantWs;volatile boolean mirror=false;int vmcPresetIndex=0;
  volatile MocapPose latestPose;volatile float fps=0;long lastFrameMs=0;
  MocapUI ui;PImage depthImage;SkeletonPose3D skeleton;PointCloud cloud;long lastProcessedFrame=-1;volatile String status="";boolean statusGood=true;File lastRecording;
  MocapSink[] sinks(){return new MocapSink[]{vmc,osc,json,ws};}
}

File mocapRecordingDirectory(){return new File(studio.services.paths.appDataRoot("mocap"),"recordings");}

void setupMocapModule(){
  MocapModuleState st=mocapState();
  st.config=new MocapConfig();st.config.load(studio.services.paths.resource("mocap","config.properties"));
  st.i18n=new MocapI18n(studio.currentLanguage());st.mirror=st.config.mirror;st.retargeter.centerRoot=st.config.centerRoot;
  st.wantVmc=st.config.vmcEnabled;st.wantOsc=st.config.oscEnabled;st.wantJson=st.config.jsonEnabled;st.wantWs=st.config.wsEnabled;
  for(int i=0;i<st.config.vmcPresets.length;i++)if(st.config.vmcPresets[i]==st.config.vmcPort)st.vmcPresetIndex=i;
  st.tracking=studio.services.processingBlocks.openBodyTracking(st.i18n,studio.selectedKinect(),
    new BodyTrackingOptions("Mocap","Motion capture",st.config.workerJoinMs,st.config.streamStaleMs,st.config.previewHz));
  buildMocapSinks(st);
  // Retargeting runs on its own thread; the solver only drops frames into this mailbox.
  st.hub=st.tracking.subscribe("Mocap-Retarget",new java.util.function.Consumer<BodyFrame>(){public void accept(BodyFrame f){mocapConsume(f);}});
  st.ui=new MocapUI();st.status=st.i18n.tr("status.ready");
}
void buildMocapSinks(MocapModuleState st){
  MocapConfig c=st.config;int vmcPort=c.vmcPresets.length>0?c.vmcPresets[st.vmcPresetIndex%c.vmcPresets.length]:c.vmcPort;
  st.vmc=new MocapVmcSink(c.bindAddress,c.vmcHost,vmcPort);st.osc=new MocapOscSink(c.bindAddress,c.oscHost,c.oscPort);
  boolean cam="camera".equals(c.jsonSpace);st.json=new MocapJsonUdpSink(c.bindAddress,c.jsonHost,c.jsonPort,cam);st.ws=new MocapWebSocketSink(c.bindAddress,c.wsPort,cam);
  // sendRate caps each sink; >=60 Hz means "every solved frame" (the solver runs at the depth rate).
  int interval=c.sendRate>=60?0:max(0,1000/c.sendRate-2);for(MocapSink s:st.sinks())s.minIntervalMs=interval;
}
void mocapConsume(BodyFrame f){
  MocapModuleState st=mocapState();MocapPose p=st.retargeter.retarget(f,st.mirror);st.latestPose=p;
  long now=millis64();if(st.lastFrameMs>0){float dt=max(1,now-st.lastFrameMs);st.fps=st.fps<=0?1000f/dt:st.fps+(1000f/dt-st.fps)*.1f;}st.lastFrameMs=now;
  for(MocapSink s:st.sinks())if(s!=null)s.offer(p);
  st.bvh.offer(p);
}
void applyMocapSinks(){
  MocapModuleState st=mocapState();boolean[] want={st.wantVmc,st.wantOsc,st.wantJson,st.wantWs};MocapSink[] s=st.sinks();
  for(int i=0;i<s.length;i++){try{s[i].setEnabled(want[i]);}catch(IOException e){
      if(i==0)st.wantVmc=false;else if(i==1)st.wantOsc=false;else if(i==2)st.wantJson=false;else st.wantWs=false;
      st.status=st.i18n.format("status.sink_error",s[i].id,safeStudioMessage(e));st.statusGood=false;}}
}
void closeMocapSinks(){for(MocapSink s:mocapState().sinks())if(s!=null)try{s.setEnabled(false);}catch(IOException ignored){}}
void activateMocapModule(){
  MocapModuleState st=mocapState();st.lastProcessedFrame=-1;st.skeleton=null;st.depthImage=null;st.cloud=null;st.latestPose=null;st.fps=0;st.lastFrameMs=0;
  if(st.ui!=null)st.ui.preview.reset();st.retargeter.reset();if(st.tracking!=null)st.tracking.activate();applyMocapSinks();
}
void requestDeactivateMocapModule(){
  MocapModuleState st=mocapState();if(st.bvh.recording)toggleMocapRecording();
  if(st.tracking!=null)st.tracking.requestStop();closeMocapSinks();
}
void disposeMocapModule(){
  MocapModuleState st=mocapState();if(st.bvh.recording)toggleMocapRecording();closeMocapSinks();
  if(st.tracking!=null)st.tracking.close();
}
void toggleMocapSink(int index){
  MocapModuleState st=mocapState();boolean on;String name;
  if(index==0){on=st.wantVmc=!st.wantVmc;name="VMC";}else if(index==1){on=st.wantOsc=!st.wantOsc;name="OSC";}
  else if(index==2){on=st.wantJson=!st.wantJson;name="JSON UDP";}else{on=st.wantWs=!st.wantWs;name="WebSocket";}
  st.status=st.i18n.format(on?"status.sink_on":"status.sink_off",name,st.sinks()[index].endpoint());st.statusGood=true;applyMocapSinks();
}
void toggleMocapMirror(){MocapModuleState st=mocapState();st.mirror=!st.mirror;st.status=st.i18n.tr(st.mirror?"status.mirror_on":"status.mirror_off");st.statusGood=true;}
void cycleMocapVmcPreset(){
  MocapModuleState st=mocapState();if(st.config.vmcPresets.length==0)return;st.vmcPresetIndex=(st.vmcPresetIndex+1)%st.config.vmcPresets.length;
  boolean was=st.vmc.enabled;try{st.vmc.setEnabled(false);}catch(IOException ignored){}
  st.vmc=new MocapVmcSink(st.config.bindAddress,st.config.vmcHost,st.config.vmcPresets[st.vmcPresetIndex]);st.vmc.minIntervalMs=st.osc.minIntervalMs;
  if(was)applyMocapSinks();st.status=st.i18n.format("status.target",st.vmc.endpoint());st.statusGood=true;
}
void toggleMocapRecording(){
  MocapModuleState st=mocapState();
  if(!st.bvh.recording){MocapPose p=st.latestPose;st.bvh.start(mocapRecordingDirectory(),p==null?st.retargeter.restLengths():p.restLengths);
    st.status=st.i18n.tr("status.recording");st.statusGood=true;return;}
  try{File f=st.bvh.stop();if(f==null){st.status=st.i18n.tr("status.record_empty");st.statusGood=false;}
    else{st.lastRecording=f;st.status=st.i18n.format("status.saved",f.getAbsolutePath());st.statusGood=true;}}
  catch(IOException e){st.status=st.i18n.format("status.record_failed",safeStudioMessage(e));st.statusGood=false;}
}
void refreshMocapDevice(){MocapModuleState st=mocapState();if(st.tracking!=null)st.tracking.selectDevice(studio.selectedKinect());if(st.ui!=null)st.ui.preview.reset();}

void drawMocapModule(){background(0xFF11151A);serviceMocapFrames();if(mocapState().ui!=null)mocapState().ui.draw();}
void serviceMocapFrames(){
  MocapModuleState st=mocapState();BodyProcessedFrame p=st.tracking==null?null:st.tracking.latest();
  if(p!=null&&p.frameNumber!=st.lastProcessedFrame){st.lastProcessedFrame=p.frameNumber;st.skeleton=p.skeleton;st.cloud=p.bodyCloud;
    int[] px=p.previewPixels;int w=p.previewWidth,h=p.previewHeight;
    if(px!=null&&w>0&&h>0&&px.length==w*h){if(st.depthImage==null||st.depthImage.width!=w||st.depthImage.height!=h)st.depthImage=createImage(w,h,RGB);
      st.depthImage.loadPixels();arrayCopy(px,st.depthImage.pixels);st.depthImage.updatePixels();}}
}

class MocapUI {
  final StudioUiButton vmcButton=new StudioUiButton(),oscButton=new StudioUiButton(),jsonButton=new StudioUiButton(),wsButton=new StudioUiButton(),
    recordButton=new StudioUiButton(),mirrorButton=new StudioUiButton(),targetButton=new StudioUiButton();
  final BodySkeletonPreview preview=new BodySkeletonPreview();
  MocapI18n i18n(){return mocapState().i18n;}
  void draw(){
    float m=studioUiMargin(),gap=studioUiGap(),w=max(80,width-2*m);
    studio.ui.renderer.header(i18n(),i18n().tr("app.title"));
    float statusY=studioUiHeaderHeight()+gap,statusH=studio.ui.metricPanelHeight(w,8,false);drawStatus(m,statusY,w,statusH);
    float bodyY=statusY+statusH+gap,bodyH=max(1,studio.contentHeight-bodyY-m),actionsH=studio.ui.actionPanelHeight(w,7,true);
    StudioUiRect[] bands=studio.ui.vertical(m,bodyY,w,bodyH,gap,new float[]{220,actionsH},new float[]{80,actionsH},new float[]{1,0});
    drawVision(bands[0].x,bands[0].y,bands[0].w,bands[0].h);drawActions(bands[1].x,bands[1].y,bands[1].w,bands[1].h);
  }
  String visionLabel(){return mocapState().tracking!=null&&mocapState().tracking.usesRgb()?i18n().tr("panel.rgb"):i18n().tr("panel.metric_depth");}
  String visionWaiting(){return mocapState().tracking!=null&&mocapState().tracking.usesRgb()?i18n().tr("waiting.rgb"):i18n().tr("waiting.depth");}
  void drawVision(float x,float y,float w,float h){
    StudioUiModuleFrontend fe=studio.ui.module(i18n());fe.panel("",x,y,w,h);fe.panelTitle(x,y,w,i18n().tr(mocapState().tracking!=null&&mocapState().tracking.usesRgb()?"panel.vision_rgb":"panel.vision"));
    float px=x+12,py=y+studioUiCardTitleHeight(),pw=max(1,w-24),ph=max(1,h-studioUiCardTitleHeight()-12),g=max(8,studioUiGap()*.65f);
    MocapModuleState st=mocapState();
    if(pw>=780){float dw=max(1,(pw-g)*.44f);preview.drawDepth(st.depthImage,visionLabel(),visionWaiting(),px,py,dw,ph);
      preview.draw(st.skeleton,st.cloud,i18n(),px+dw+g,py,max(1,pw-g-dw),ph,null);}
    else{float dh=max(1,(ph-g)*.40f);preview.drawDepth(st.depthImage,visionLabel(),visionWaiting(),px,py,pw,dh);
      preview.draw(st.skeleton,st.cloud,i18n(),px,py+dh+g,pw,max(1,ph-g-dh),null);}
  }
  void drawStatus(float x,float y,float w,float h){
    MocapModuleState st=mocapState();StudioUiModuleFrontend fe=studio.ui.module(i18n());fe.panel("",x,y,w,h);fe.panelTitle(x,y,w,i18n().tr("panel.status"));
    MocapPose p=st.latestPose;boolean live=st.tracking!=null&&st.tracking.streamsLive();boolean tracked=p!=null&&p.tracked;
    String tracking=!live?i18n().tr("state.wait"):(tracked?i18n().format("state.tracked",p.confidence*100):i18n().tr("tracker."+(st.tracking==null?"searching":st.tracking.statusReason())));
    long packets=0;float latency=-1;for(MocapSink s:st.sinks())if(s!=null&&s.enabled){packets+=s.packets;if(s.latencyMs>=0)latency=latency<0?s.latencyMs:max(latency,s.latencyMs);}
    String[] labels={i18n().tr("label.tracking"),i18n().tr("label.fps"),i18n().tr("label.latency"),i18n().tr("label.packets"),i18n().tr("label.clients"),i18n().tr("label.bvh"),i18n().tr("label.vmc_target"),i18n().tr("label.mirror")};
    String[] values={tracking,live&&st.fps>0?String.format(Locale.ROOT,"%.1f",st.fps):"—",latency<0?"—":String.format(Locale.ROOT,"%.0f ms",latency),String.valueOf(packets),
      st.ws.enabled?String.valueOf(st.ws.clients()):i18n().tr("state.off"),st.bvh.recording?i18n().format("state.frames",(float)st.bvh.frameCount):i18n().tr("state.idle"),
      st.vmc.endpoint(),i18n().tr(st.mirror?"state.on":"state.off")};
    boolean[] active={tracked,live,latency>=0,packets>0,st.ws.clients()>0,st.bvh.recording,st.vmc.enabled,st.mirror};
    StudioUiRect body=studio.ui.panelBody(x,y,w,h,false);studio.ui.drawMetricGrid(labels,values,active,body.x,body.y,body.w,body.h);
  }
  void drawActions(float x,float y,float w,float h){
    MocapModuleState st=mocapState();StudioUiModuleFrontend fe=studio.ui.module(i18n());fe.panel("",x,y,w,h);fe.panelTitle(x,y,w,i18n().tr("panel.actions"));
    vmcButton.configure("VMC",true,st.vmc.enabled,false,false);oscButton.configure("OSC",true,st.osc.enabled,false,false);
    jsonButton.configure("JSON UDP",true,st.json.enabled,false,false);wsButton.configure("WebSocket",true,st.ws.enabled,false,false);
    recordButton.configure(i18n().tr(st.bvh.recording?"button.stop_record":"button.record"),true,st.bvh.recording,true,false);
    mirrorButton.configure(i18n().tr("button.mirror"),true,st.mirror,false,false);
    targetButton.configure(i18n().format("button.target",st.vmc.port),st.config.vmcPresets.length>1,false,false,true);
    ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();Collections.addAll(items,vmcButton,oscButton,jsonButton,wsButton,recordButton,mirrorButton,targetButton);
    StudioUiRect body=studio.ui.panelBody(x,y,w,h,true);fe.buttons(items,body.x,body.y,body.w,body.h);
    StudioUiMetrics ui=studio.ui.metrics();fe.status(x+ui.panelPad,y+h-ui.footerH,w-ui.panelPad*2,ui.footerH,st.status,st.statusGood);
  }
  void handleMouse(float mx,float my){
    if(vmcButton.hit(mx,my))toggleMocapSink(0);else if(oscButton.hit(mx,my))toggleMocapSink(1);else if(jsonButton.hit(mx,my))toggleMocapSink(2);
    else if(wsButton.hit(mx,my))toggleMocapSink(3);else if(recordButton.hit(mx,my))toggleMocapRecording();else if(mirrorButton.hit(mx,my))toggleMocapMirror();
    else if(targetButton.hit(mx,my))cycleMocapVmcPreset();
  }
}

class MocapStudioModule extends StudioModuleBase {
  final MocapModuleState state;
  MocapStudioModule(StudioController owner){super(owner,"mocap","module.mocap","home.mocap");state=owner.moduleStates.install(MocapModuleState.class,new MocapModuleState());}
  @Override public Object localState(){return state;}
  public void setupModule(){setupMocapModule();}
  public void activateModule(){activateMocapModule();}
  public void deactivateModule(){requestDeactivateMocapModule();}
  public void drawModule(){drawMocapModule();}
  public void mousePressedModule(){if(state.ui!=null)state.ui.handleMouse(studio.ui.pointerX(),studio.ui.pointerY());}
  public void contextChanged(org.synkinect.studio.api.StudioContextEvent event){
    if(event.localeChanged()&&state.i18n!=null){state.i18n.setLanguage(event.locale());state.status=state.i18n.tr("status.ready");state.statusGood=true;}
    if(event.depthCalibrationChanged())owner.services.workers.startLowPriority("Mocap-Calibration-Reconcile",new Runnable(){public void run(){refreshMocapDevice();}});
    if(event.devicesChanged()){
      if(state.tracking!=null)state.tracking.requestReconnect(event.selectionChanged()?"device-selection":"device-registry",event.selectionChanged());
      if(event.selectionChanged()){if(state.tracking!=null){state.tracking.clearConsumerPairs();state.tracking.clearPublished();}if(state.ui!=null)state.ui.preview.reset();state.lastProcessedFrame=-1;state.skeleton=null;state.depthImage=null;state.latestPose=null;}
      owner.services.workers.startLowPriority("Mocap-Device-Reconcile",new Runnable(){public void run(){refreshMocapDevice();}});
    }
  }
  public String closeBlockReason(){return "";}
  public int preferredUiFrameRate(){return 60;}
  public void disposeModule(){disposeMocapModule();}
}
