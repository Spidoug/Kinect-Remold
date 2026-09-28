// Responsive geometry is supplied by StudioUiMetrics.

// ===== SynKinect Studio / Surveillance =====
// Multi-Kinect surveillance is intentionally independent from the Studio's selected
// camera. Each discovered camera owns exactly ONE video stream at a time: RGB in
// normal light or IR in darkness. Surveillance NEVER subscribes to Depth. Motion is
// computed from temporal luma differences in the active RGB/IR image, so arming
// surveillance cannot claim endpoint 0x82 or keep the depth projector alive.

SurveillanceModuleState surveillanceState(){return studio.state(SurveillanceModuleState.class);
  }

class SurveillanceModuleState {
  final SurveillanceTheme theme=new SurveillanceTheme();

  SurveillanceConfig config;
  SurveillanceI18n i18n;
  SurveillanceUI ui;
  final Object cameraLock=new Object();
  final Object eventLock=new Object();
  final LinkedHashMap<String,SurveillanceCamera> cameras=new LinkedHashMap<String,SurveillanceCamera>();

  volatile boolean armed=false,recording=false,recordStarting=false,supervisorRun=false;

  volatile long eventGeneration=0,lastMotionMs=0,lastRegistryGeneration=-1;
  volatile float motionScore=0;
  volatile String status="";
  SurveillanceEventSession eventSession;
  Thread supervisor;
}

void setupSurveillanceModule(){
  SurveillanceModuleState s=surveillanceState();
  s.config=new SurveillanceConfig();s.config.load(studio.services.paths.resource("surveillance","config.properties"));

  s.i18n=new SurveillanceI18n(studio.currentLanguage());initializeSurveillanceTypography();

  s.ui=new SurveillanceUI();s.status=s.i18n.tr("status.disarmed");
  syncSurveillanceDevices();startSurveillanceSupervisor();
}

void activateSurveillanceRuntime(){startSurveillanceSupervisor();syncSurveillanceDevices();
  startSurveillanceCameras();setSurveillanceForeground(true);}
void deactivateSurveillanceRuntime(){
  SurveillanceModuleState s=surveillanceState();
  setSurveillanceForeground(false);
  // A module never keeps ownership of Kinect video after it is left. This avoids
  // RGB/IR arbitration from a hidden Surveillance module blocking Scanner or Interactivity.
  if(s.recording||s.recordStarting)requestStopMotionRecording(false);
  s.armed=false;
  s.status=s.i18n.tr("status.disarmed");
  requestStopSurveillanceCameras(false);
  requestStopSurveillanceSupervisor();
}

void drawSurveillanceModule(){
  background(surveillanceState().theme.BG);
  syncSurveillanceDevices();
  surveillanceState().ui.draw();
}

void startSurveillanceSupervisor(){
  SurveillanceModuleState s=surveillanceState();if(s.supervisorRun)return;s.supervisorRun=true;

  s.supervisor=studio.services.workers.start("Surveillance-Supervisor",new Runnable(){public void run(){
    while(surveillanceState().supervisorRun){
      serviceRecordingTimeout();serviceRecordingHealth();serviceSurveillanceCameraModes();
      try{Thread.sleep(200);}catch(InterruptedException e){if(!surveillanceState().supervisorRun)return;Thread.currentThread().interrupt();return;}
    }
  }});
}

void requestStopSurveillanceSupervisor(){SurveillanceModuleState s=surveillanceState();
  s.supervisorRun=false;Thread t=s.supervisor;s.supervisor=null;if(t!=null)t.interrupt();
  }
void stopSurveillanceSupervisor(){SurveillanceModuleState s=surveillanceState();s.supervisorRun=false;
  Thread t=s.supervisor;if(t!=null){t.interrupt();try{t.join(s.config==null?1800:s.config.workerJoinMs);
      }catch(InterruptedException e){Thread.currentThread().interrupt();}}s.supervisor=null;
  }

void syncSurveillanceDevices(){syncSurveillanceDevices(false);}
void syncSurveillanceDevices(boolean force){
  SurveillanceModuleState s=surveillanceState();if(s.config==null)return;
  studio.services.devices.refreshIfDue();long generation=studio.services.devices.generation;

  if(!force&&generation==s.lastRegistryGeneration)return;
  ArrayList<KinectDevice> found=studio.services.devices.snapshot();HashSet<String> present=new HashSet<String>();

  boolean shouldRun=studio.isStateActive(surveillanceState())||s.armed||s.recording;

  ArrayList<SurveillanceCamera> toStop=new ArrayList<SurveillanceCamera>();
  ArrayList<SurveillanceCamera> toStart=new ArrayList<SurveillanceCamera>();
  ArrayList<SurveillanceCamera> active=new ArrayList<SurveillanceCamera>();
  synchronized(s.cameraLock){
    for(KinectDevice d:found){
      present.add(d.id);SurveillanceCamera c=s.cameras.get(d.id);
      if(c==null||!c.device.endpoint.equals(d.endpoint)){
        if(c!=null)toStop.add(c);
        c=new SurveillanceCamera(d,s.config);s.cameras.put(d.id,c);
      }
      if(d.cameraReady()){
        if(shouldRun)toStart.add(c);
        active.add(c);
      }
    }
    Iterator<Map.Entry<String,SurveillanceCamera>> it=s.cameras.entrySet().iterator();

    while(it.hasNext()){
      Map.Entry<String,SurveillanceCamera> e=it.next();if(present.contains(e.getKey()))continue;

      toStop.add(e.getValue());it.remove();
    }
    s.lastRegistryGeneration=generation;
  }
  // Never join transport/processor threads while cameraLock is held. Motion
  // callbacks can acquire cameraLock through event recording, so joining under
  // that lock creates a lock inversion and can freeze the Processing UI.
  for(SurveillanceCamera c:toStop)c.requestStop(false);
  for(SurveillanceCamera c:toStart)c.start();
  SurveillanceEventSession session=s.eventSession;
  if(s.recording&&session!=null)for(SurveillanceCamera c:active)session.ensureCamera(c);

}

void startSurveillanceCameras(){SurveillanceModuleState s=surveillanceState();ArrayList<SurveillanceCamera> cameras;
  synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());
    }for(SurveillanceCamera c:cameras)c.start();}
void requestStopSurveillanceCameras(boolean clearRetention){SurveillanceModuleState s=surveillanceState();
  ArrayList<SurveillanceCamera> cameras;synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());
    }for(SurveillanceCamera c:cameras)c.requestStop(clearRetention);}
void stopSurveillanceCameras(boolean clearRetention){SurveillanceModuleState s=surveillanceState();
  ArrayList<SurveillanceCamera> cameras;synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());
    }for(SurveillanceCamera c:cameras)c.stop(clearRetention);}
void setSurveillanceForeground(boolean foreground){SurveillanceModuleState s=surveillanceState();
  ArrayList<SurveillanceCamera> cameras;synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());
    }for(SurveillanceCamera c:cameras)c.setForeground(foreground);}

void onSurveillanceMotion(SurveillanceCamera camera,float score,boolean moving,boolean triggered){
  SurveillanceModuleState s=surveillanceState();s.motionScore=max(s.motionScore*0.88f,score);

  if(moving)s.lastMotionMs=millis64();
  if(s.armed&&triggered&&!s.recording&&!s.recordStarting)requestStartMotionRecording();

}

void requestStartMotionRecording(){
  SurveillanceModuleState s=surveillanceState();final long generation;
  synchronized(s.eventLock){
    if(s.recording||s.recordStarting)return;
    s.recordStarting=true;generation=++s.eventGeneration;
  }
  studio.services.workers.startLowPriority("Surveillance-Event-Start",new Runnable(){public void run(){startMotionRecording(generation);}});

}

void startMotionRecording(long generation){
  SurveillanceModuleState s=surveillanceState();SurveillanceEventSession event=null;
  ArrayList<SurveillanceCamera> cameras;
  try{
    synchronized(s.cameraLock){
      cameras=new ArrayList<SurveillanceCamera>();
      for(SurveillanceCamera c:s.cameras.values())if(c.device.cameraReady())cameras.add(c);

    }
    if(cameras.isEmpty())throw new IOException("no Kinect camera transport is ready");

    event=new SurveillanceEventSession(s.config);event.start(cameras);
    synchronized(s.eventLock){
      if(generation!=s.eventGeneration||!s.recordStarting||!studio.isStateActive(surveillanceState())){if(generation==s.eventGeneration)s.recordStarting=false;
        }
      else{
        s.eventSession=event;s.recording=true;s.recordStarting=false;event=null;
        s.lastMotionMs=millis64();s.status=s.i18n.format("status.recording_multi",cameras.size(),s.config.preRollSeconds);

      }
    }
  }catch(Exception e){
    synchronized(s.eventLock){if(generation==s.eventGeneration){s.recordStarting=false;
        s.recording=false;s.eventSession=null;s.status=s.i18n.format("status.record_failed",safeStudioMessage(e));
        }}
  }finally{
    if(event!=null)try{event.stop();}catch(Exception ignored){}
  }
}

void requestStopMotionRecording(boolean timeout){
  SurveillanceModuleState s=surveillanceState();
  SurveillanceEventSession event;final long stopGeneration;final String stoppedKey=timeout?"status.record_stopped_idle_multi":"status.record_stopped_manual_multi";
  synchronized(s.eventLock){
    if(!s.recording&&!s.recordStarting)return;
    stopGeneration=++s.eventGeneration;s.recordStarting=false;s.recording=false;event=s.eventSession;
    s.eventSession=null;s.status=s.i18n.tr(stoppedKey);
  }
  if(event!=null)studio.services.workers.start("Surveillance-Event-Close",new Runnable(){public void run(){
    event.stop();
    synchronized(s.eventLock){
      if(s.eventGeneration!=stopGeneration||s.recording||s.recordStarting)return;
      if(event.failed)s.status=s.i18n.format("status.record_runtime_failed",event.failureMessage());
      else if(event.sessionDir!=null)s.status=s.i18n.format("status.record_saved",event.sessionDir.getAbsolutePath());
      else s.status=s.i18n.tr(stoppedKey);
    }
  }});
}

void submitSurveillancePacket(SurveillanceCamera camera,RetainedVideoFrame frame){
  SurveillanceModuleState s=surveillanceState();if(!s.recording||frame==null)return;

  synchronized(s.eventLock){if(s.eventSession!=null)s.eventSession.submit(camera,frame);
    }
}

void serviceRecordingTimeout(){SurveillanceModuleState s=surveillanceState();if(!s.recording)return;
  long now=millis64();if(now-s.lastMotionMs>=s.config.motionStopAfterMs)requestStopMotionRecording(true);
  }
void serviceRecordingHealth(){SurveillanceModuleState s=surveillanceState();if(!s.recording)return;
  synchronized(s.eventLock){if(s.eventSession!=null&&s.eventSession.hasFailed()){String m=s.eventSession.failureMessage();
      s.recording=false;s.eventSession.stop();s.eventSession=null;s.status=s.i18n.format("status.record_runtime_failed",m.length()==0?s.i18n.tr("error.unknown"):m);
      }}}
void serviceSurveillanceCameraModes(){
  SurveillanceModuleState s=surveillanceState();ArrayList<SurveillanceCamera> cameras;

  synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());
    }
  long now=millis64();for(SurveillanceCamera c:cameras)c.serviceModeTransition(now);

}

void chooseSurveillanceRecordingFolder(){
  studio.ui.nativeDialogs.chooseWritableDirectoryAsync(surveillanceState().i18n.tr("dialog.record_folder"),new StudioDirectorySelection(){
    public void accepted(File selected){
      studio.userPreferences.put("surveillance.record.directory",selected.getAbsolutePath());
      surveillanceState().status=surveillanceState().i18n.tr("status.folder_selected")+": "+selected.getAbsolutePath();
    }
    public void failed(Exception error){surveillanceState().status=surveillanceState().i18n.tr("status.folder_invalid")+": "+safeStudioMessage(error);}
  });
}

void toggleArmed(){SurveillanceModuleState s=surveillanceState();s.armed=!s.armed;
  if(s.armed){syncSurveillanceDevices();startSurveillanceCameras();s.status=s.i18n.tr("status.armed_multi");
    }else{if(s.recording||s.recordStarting)requestStopMotionRecording(false);s.status=s.i18n.tr("status.disarmed");
    if(!studio.isStateActive(surveillanceState()))requestStopSurveillanceCameras(false);
    }}
void manualRecord(){syncSurveillanceDevices();startSurveillanceCameras();requestStartMotionRecording();
  }
void surveillanceMousePressed(){if(surveillanceState().ui!=null)surveillanceState().ui.handleMouse(studio.ui.pointerX(),studio.ui.pointerY());
  }
void disposeSurveillanceModule(){SurveillanceModuleState s=surveillanceState();s.armed=false;
  if(s.recording||s.recordStarting)requestStopMotionRecording(false);stopSurveillanceSupervisor();
  stopSurveillanceCameras(true);synchronized(s.cameraLock){s.cameras.clear();}}
long millis64(){return System.nanoTime()/1000000L;}

class SurveillanceCamera {
  final KinectDevice device;final SurveillanceConfig cfg;final SurveillanceSource source;
  final AppearanceMotionDetector detector;final VideoRetentionBuffer retention;
  volatile boolean processorRun=false;volatile long processorGeneration=0;Thread processor;

  volatile int[] latestPreviewPixels;volatile int previewWidth=0,previewHeight=0;

  volatile long latestPreviewEpochMs=0,lastRetainedEpochMs=0,framesProcessed=0;
  volatile float motionScore=0;volatile String lastError="";
  volatile boolean nightMode=false,rgbProbe=false,rgbProbeFromMotion=false,foreground=false;
  volatile float meanLuma=1.0f;
  int darkFrames=0,brightFrames=0,probeFrames=0,irBrightFrames=0;long lastIrProbeMs=0,lastMotionRgbProbeMs=0,rgbProbeDeadlineMs=0,automaticModeHoldUntilMs=0;

  SurveillanceCamera(KinectDevice device,SurveillanceConfig cfg){this.device=device;
    this.cfg=cfg;source=new SurveillanceSource(device,cfg);detector=new AppearanceMotionDetector(cfg);
    retention=new VideoRetentionBuffer(cfg.retentionMinutes*60000L);}
  synchronized void setForeground(boolean value){
    foreground=value;
    if(!value){rgbProbe=false;rgbProbeFromMotion=false;rgbProbeDeadlineMs=0;source.setInfrared(false);
      }
    else if(nightMode&&!rgbProbe){source.setInfrared(true);}
  }
  boolean canUseInfrared(){return foreground&&studio.isStateActive(surveillanceState());
    }
  boolean automaticModeHoldActive(long now){return now<automaticModeHoldUntilMs;}
  long automaticModeHoldRemainingMs(long now){long remaining=automaticModeHoldUntilMs-now;return remaining>0L?remaining:0L;}
  void armAutomaticModeHold(long now){automaticModeHoldUntilMs=now+cfg.nightMinimumModeHoldMs;}
  synchronized void startRgbProbe(boolean motionDriven){
    long now=millis64();
    if(!canUseInfrared()||!nightMode||rgbProbe||automaticModeHoldActive(now))return;
    if(motionDriven&&now-lastMotionRgbProbeMs<cfg.nightMotionProbeCooldownMs)return;

    rgbProbe=true;rgbProbeFromMotion=motionDriven;probeFrames=0;brightFrames=0;irBrightFrames=0;

    rgbProbeDeadlineMs=now+cfg.nightRgbProbeTimeoutMs;lastIrProbeMs=now;
    if(motionDriven)lastMotionRgbProbeMs=now;
    source.setInfrared(false);detector.reset();
  }
  synchronized void finishRgbProbe(boolean keepRgb){
    if(!rgbProbe)return;
    rgbProbe=false;rgbProbeFromMotion=false;rgbProbeDeadlineMs=0;probeFrames=0;brightFrames=0;
    irBrightFrames=0;
    detector.reset();
    long now=millis64();
    if(keepRgb){nightMode=false;darkFrames=0;armAutomaticModeHold(now);source.setInfrared(false);}
    else{lastIrProbeMs=now;source.setInfrared(canUseInfrared());}
  }
  synchronized void serviceModeTransition(long now){
    if(nightMode&&rgbProbe&&rgbProbeDeadlineMs>0&&now>=rgbProbeDeadlineMs)finishRgbProbe(false);

  }
  synchronized void start(){if(processorRun)return;if(!device.cameraReady()){lastError="camera transport pending";
      return;}source.start();processorRun=true;final long generation=++processorGeneration;
    processor=studio.services.workers.start("Surveillance-"+safeToken(device.id),new Runnable(){public void run(){processLoop(generation);}});
    }
  synchronized void requestStop(boolean clearRetention){processorRun=false;++processorGeneration;
    source.requestStop();Thread t=processor;processor=null;if(t!=null)t.interrupt();
    detector.reset();if(clearRetention)retention.clear();}
  synchronized void stop(boolean clearRetention){processorRun=false;++processorGeneration;
    source.stop();Thread t=processor;if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);
        }catch(InterruptedException e){Thread.currentThread().interrupt();}}processor=null;
    detector.reset();if(clearRetention)retention.clear();}
  void processLoop(long generation){
    while(processorRun&&generation==processorGeneration){SurveillanceFrame f=source.poll();
      if(f==null){try{Thread.sleep(4);}catch(InterruptedException e){if(!processorRun||generation!=processorGeneration)return;
          }continue;}
      try{processFrame(f);}catch(Exception e){lastError=safeStudioMessage(e);}
    }
  }
  void processFrame(SurveillanceFrame f)throws IOException{
    framesProcessed++;long epochMs=System.currentTimeMillis();
    EncodedSurveillanceFrame encoded=null;
    if(f.mode==studio.services.surveillanceProtocol.MODE_RGB){
      meanLuma=surveillanceMeanLuma(f.payload,f.width,f.height);
      float score=detector.detectRgb(f.payload,f.width,f.height);motionScore=score;
      onSurveillanceMotion(this,score,detector.moving(),detector.triggered());
      if(nightMode&&rgbProbe){
        probeFrames++;if(meanLuma>=cfg.nightExitLuma)brightFrames++;else brightFrames=0;

        int requiredFrames=rgbProbeFromMotion?cfg.nightMotionProbeFrames:cfg.nightProbeFrames;

        if(brightFrames>=cfg.nightBrightFrames)finishRgbProbe(true);
        else if(probeFrames>=requiredFrames)finishRgbProbe(false);
      }else if(!nightMode){
        long now=millis64();
        if(automaticModeHoldActive(now)){darkFrames=0;}
        else{
          if(meanLuma<=cfg.nightEnterLuma)darkFrames++;else darkFrames=max(0,darkFrames-1);
          if(darkFrames>=cfg.nightDarkFrames){nightMode=true;rgbProbe=false;irBrightFrames=0;darkFrames=0;
            lastIrProbeMs=now;armAutomaticModeHold(now);source.setInfrared(canUseInfrared());}
        }
      }
      encoded=encodeSurveillanceJpeg(f.payload,f.width,f.height,cfg,epochMs,device.label+" · "+videoModeLabel());

    }else if(f.mode==studio.services.surveillanceProtocol.MODE_IR){
      meanLuma=surveillanceIrMeanLuma(f.payload,f.width,f.height,cfg.motionSampleStep);

      float score=detector.detectIr(f.payload,f.width,f.height);motionScore=score;

      boolean motionTriggered=detector.triggered();onSurveillanceMotion(this,score,detector.moving(),motionTriggered);


      // Motion in IR is an immediate reason to test whether usable color has returned.
      // The probe is bounded by both frame count and time, so a failed RGB transition
      // automatically restores IR instead of leaving surveillance on a blind stream.
      if(motionTriggered&&!automaticModeHoldActive(millis64()))startRgbProbe(true);

      // Ambient-light recovery remains a slower secondary path when no motion occurs.
      if(meanLuma>=cfg.nightIrProbeLuma)irBrightFrames++;else irBrightFrames=max(0,irBrightFrames-1);

      long modeNow=millis64();
      if(canUseInfrared()&&nightMode&&!rgbProbe&&!automaticModeHoldActive(modeNow)&&
         irBrightFrames>=cfg.nightIrProbeFrames&&
         modeNow-lastIrProbeMs>=cfg.nightProbeIntervalMs){
        startRgbProbe(false);
      }
      encoded=encodeSurveillanceIrJpeg(f.payload,f.width,f.height,cfg,epochMs,device.label+" · "+surveillanceState().i18n.tr("mode.ir"));

    }else return;
    long interval=Math.max(1L,1000L/Math.max(1,cfg.retentionFps));if(lastRetainedEpochMs>0&&epochMs-lastRetainedEpochMs<interval)return;
    lastRetainedEpochMs=epochMs;
    if(encoded==null)return;latestPreviewPixels=encoded.previewPixels;previewWidth=cfg.recordWidth;
    previewHeight=cfg.recordHeight;latestPreviewEpochMs=epochMs;
    RetainedVideoFrame packet=new RetainedVideoFrame(epochMs,encoded.jpeg);retention.add(packet);
    submitSurveillancePacket(this,packet);
  }
  String videoModeLabel(){SurveillanceI18n i=surveillanceState().i18n;return rgbProbe?i.tr(rgbProbeFromMotion?"mode.rgb_motion_probe":"mode.rgb_probe"):i.tr(nightMode?"mode.ir":"mode.rgb");
    }
  long retainedBytes(){return retention.bytes();}long retainedDurationMs(){return retention.durationMs();
    }
}

class SurveillanceFrame {int mode,width,height,flags;long frameNumber,tickMs;byte[] payload;
  }

class SurveillanceSource {
  final KinectDevice device;final SurveillanceConfig cfg;final Object frameLock=new Object(),pipeLock=new Object();

  final ArrayDeque<SurveillanceFrame> queue=new ArrayDeque<SurveillanceFrame>();
  final byte[] headerBytes=new byte[studio.services.surveillanceProtocol.FRAME_HEADER_BYTES];

  volatile boolean running=false,connected=false,infrared=false;volatile long runGeneration=0;
  volatile String lastError="";volatile long dropped=0,lastFrameMs=0;Thread worker;
  LocalTransport pipe;
  SurveillanceSource(KinectDevice device,SurveillanceConfig cfg){this.device=device;
    this.cfg=cfg;}
  synchronized void start(){if(running)return;running=true;final long generation=++runGeneration;
    worker=studio.services.workers.start("Surveillance-Port-"+safeToken(device.id),new Runnable(){public void run(){loop(generation);}});
    }
  void requestStop(){Thread t;synchronized(this){running=false;++runGeneration;closeActive();
      t=worker;worker=null;}if(t!=null)t.interrupt();connected=false;synchronized(frameLock){queue.clear();
      }}
  void stop(){Thread t;synchronized(this){running=false;++runGeneration;closeActive();
      t=worker;worker=null;}if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);
        }catch(InterruptedException e){Thread.currentThread().interrupt();}}connected=false;
    synchronized(frameLock){queue.clear();}}
  SurveillanceFrame poll(){synchronized(frameLock){return queue.isEmpty()?null:queue.removeFirst();
      }}
  void setInfrared(boolean value){if(infrared==value)return;infrared=value;closeActive();
    }
  void enqueue(SurveillanceFrame f){synchronized(frameLock){if(queue.size()>=cfg.videoQueueFrames){queue.removeFirst();
        dropped++;}queue.addLast(f);}}
  void loop(long generation){while(running&&generation==runGeneration){LocalTransport local=null;
      try{if(!device.cameraReady())throw new IOException("camera transport pending");
        local=studio.services.transportFactory.openEndpoint(device.endpoint);setActive(local);
        subscribe(local);connected=true;lastError="";while(running&&generation==runGeneration)readFrame(local);
        }catch(Exception e){if(generation==runGeneration){connected=false;if(running)lastError=safeStudioMessage(e);
          }}finally{clearActive(local);close(local);}if(running&&generation==runGeneration)try{Thread.sleep(cfg.reconnectMs);
        }catch(InterruptedException e){if(!running||generation!=runGeneration)return;
        Thread.currentThread().interrupt();return;}}}
  void subscribe(LocalTransport local)throws IOException{int requested=infrared?studio.services.surveillanceProtocol.STREAM_IR:studio.services.surveillanceProtocol.STREAM_RGB;
    boolean nativeOne=device!=null&&"xbox-one".equals(device.generation);ByteBuffer q=ByteBuffer.allocate(nativeOne?80:16).order(ByteOrder.LITTLE_ENDIAN);q.putInt(studio.services.surveillanceProtocol.MAGIC).putInt(studio.services.surveillanceProtocol.VERSION).putInt(studio.services.surveillanceProtocol.CMD_SUBSCRIBE_STREAMS).putInt(requested);
    if(nativeOne){byte[] id=device.id.getBytes(java.nio.charset.StandardCharsets.UTF_8);int n=min(63,id.length);q.put(id,0,n);while(q.position()<80)q.put((byte)0);}
    local.write(q.array());byte[] rb=new byte[studio.services.surveillanceProtocol.REPLY_BYTES];
    local.readFully(rb);ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(),version=r.getInt(),result=r.getInt(),accepted=r.getInt(),w=r.getInt(),h=r.getInt(),caps=r.getInt(),maxPayload=r.getInt();
    if(magic!=studio.services.surveillanceProtocol.MAGIC||
       version!=studio.services.surveillanceProtocol.VERSION||
       result<0||
       accepted!=requested||
       w<=0||h<=0||maxPayload<=0) {
      throw new IOException("surveillance subscribe rejected");
    }
    }
  void readFrame(LocalTransport local)throws IOException{
    local.readFully(headerBytes);
    ByteBuffer h=ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);
    int magic=h.getInt(),version=h.getInt(),mode=h.getInt(),w=h.getInt(),hh=h.getInt(),fmt=h.getInt(),bytes=h.getInt(),flags=h.getInt();
    long frameNo=h.getLong(),tickMs=h.getLong();
    h.position(studio.services.surveillanceProtocol.FRAME_HEADER_BYTES);
    if(magic!=studio.services.surveillanceProtocol.FRAME_MAGIC||version!=studio.services.surveillanceProtocol.VERSION||w<=0||hh<=0)throw new IOException("surveillance frame header");

    boolean rgbRaw=mode==studio.services.surveillanceProtocol.MODE_RGB&&fmt==studio.services.surveillanceProtocol.PIXEL_BAYER_GRBG8&&bytes==w*hh;
    boolean rgbBgra=mode==studio.services.surveillanceProtocol.MODE_RGB&&fmt==studio.services.surveillanceProtocol.PIXEL_BGRA32&&bytes==w*hh*4;
    boolean rgbJpeg=mode==studio.services.surveillanceProtocol.MODE_RGB&&fmt==studio.services.surveillanceProtocol.PIXEL_JPEG&&bytes>256&&bytes<=studio.services.surveillanceProtocol.ABSOLUTE_MAX_PAYLOAD_BYTES;

    boolean irRaw=mode==studio.services.surveillanceProtocol.MODE_IR&&fmt==studio.services.surveillanceProtocol.PIXEL_IR_RAW10_PACKED&&bytes==w*hh*10/8;
    boolean ir16=mode==studio.services.surveillanceProtocol.MODE_IR&&fmt==studio.services.surveillanceProtocol.PIXEL_IR_U16&&bytes==w*hh*2;

    if(!(rgbRaw||rgbBgra||rgbJpeg||irRaw||ir16))throw new IOException("surveillance frame format/size:"+mode+"/"+fmt+"/"+w+"x"+hh+"/"+bytes);

    byte[] payload=new byte[bytes];local.readFully(payload);
    if(rgbRaw){payload=RgbHqProcessor.bayerGrbgToNv12(payload,w,hh);if(payload==null)throw new IOException("surveillance rgb raw decode");}
    else if(rgbBgra){payload=surveillanceBgraToNv12(payload,w,hh);if(payload==null)throw new IOException("surveillance rgb bgra decode");}
    else if(rgbJpeg){payload=surveillanceJpegToNv12(payload,w,hh);if(payload==null)throw new IOException("surveillance rgb jpeg decode");}
    else if(irRaw){payload=unpackIrRaw10(payload,w,hh);if(hh==studio.services.surveillanceProtocol.IR_RAW_HEIGHT)hh=studio.services.surveillanceProtocol.HEIGHT;}
    else if(ir16){for(int j=0;j<payload.length;j+=2){int v=(payload[j]&255)|((payload[j+1]&255)<<8);v>>=6;payload[j]=(byte)v;payload[j+1]=(byte)(v>>8);}}
    SurveillanceFrame f=new SurveillanceFrame();f.mode=mode;f.width=w;f.height=hh;
    f.flags=flags;f.frameNumber=frameNo;f.tickMs=tickMs;f.payload=payload;lastFrameMs=millis64();
    enqueue(f);
  }
  byte[] unpackIrRaw10(byte[] raw,int w,int rawHeight)throws IOException{
    int expected=w*rawHeight*10/8;if(raw==null||raw.length!=expected||rawHeight<studio.services.surveillanceProtocol.HEIGHT+8)throw new IOException("surveillance ir raw decode");

    byte[] out=new byte[w*studio.services.surveillanceProtocol.HEIGHT*2];long buffer=0L;
    int bitsIn=0,src=0;
    int pixels=w*rawHeight;for(int i=0;i<pixels;i++){while(bitsIn<10){buffer=(buffer<<8)|(raw[src++]&0xFFL);
        bitsIn+=8;}bitsIn-=10;int value=(int)((buffer>>bitsIn)&0x3FFL);if(bitsIn==0)buffer=0L;
      else buffer&=(1L<<bitsIn)-1L;int row=i/w;if(row>=4&&row<4+studio.services.surveillanceProtocol.HEIGHT){int dst=((row-4)*w+(i%w))*2;
        out[dst]=(byte)value;out[dst+1]=(byte)(value>>8);}}
    return out;
  }
  void setActive(LocalTransport p){synchronized(pipeLock){pipe=p;}}void clearActive(LocalTransport p){synchronized(pipeLock){if(pipe==p)pipe=null;
      }}void closeActive(){LocalTransport p;synchronized(pipeLock){p=pipe;pipe=null;
      }close(p);}void close(LocalTransport p){if(p!=null)try{p.close();}catch(IOException ignored){}}
}


byte[] surveillanceJpegToNv12(byte[] jpeg,int w,int h){if(jpeg==null||w<=0||h<=0||(w&1)!=0||(h&1)!=0)return null;try{BufferedImage image=ImageIO.read(new ByteArrayInputStream(jpeg));if(image==null)return null;int[] argb=new int[w*h];if(image.getWidth()==w&&image.getHeight()==h)image.getRGB(0,0,w,h,argb,0,w);else{BufferedImage scaled=new BufferedImage(w,h,BufferedImage.TYPE_INT_ARGB);Graphics2D g=scaled.createGraphics();try{g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,RenderingHints.VALUE_INTERPOLATION_BILINEAR);g.drawImage(image,0,0,w,h,null);}finally{g.dispose();}scaled.getRGB(0,0,w,h,argb,0,w);}byte[] out=new byte[w*h*3/2];int uv=w*h;for(int y=0;y<h;y++)for(int x=0;x<w;x++){int c=argb[y*w+x],r=(c>>16)&255,g=(c>>8)&255,b=c&255,yy=(77*r+150*g+29*b)>>8;out[y*w+x]=(byte)constrain(yy,0,255);if((x&1)==0&&(y&1)==0){int u=((-43*r-85*g+128*b)>>8)+128,v=((128*r-107*g-21*b)>>8)+128,q=uv+(y/2)*w+x;out[q]=(byte)constrain(u,0,255);out[q+1]=(byte)constrain(v,0,255);}}return out;}catch(Exception e){return null;}}
byte[] surveillanceBgraToNv12(byte[] bgra,int w,int h){if(bgra==null||bgra.length!=w*h*4||(w&1)!=0||(h&1)!=0)return null;byte[] out=new byte[w*h*3/2];int uv=w*h;for(int y=0;y<h;y++)for(int x=0;x<w;x++){int p=(y*w+x)*4,b=bgra[p]&255,g=bgra[p+1]&255,r=bgra[p+2]&255;int yy=(77*r+150*g+29*b)>>8;out[y*w+x]=(byte)constrain(yy,0,255);if((x&1)==0&&(y&1)==0){int u=((-43*r-85*g+128*b)>>8)+128,v=((128*r-107*g-21*b)>>8)+128;int q=uv+(y/2)*w+x;out[q]=(byte)constrain(u,0,255);out[q+1]=(byte)constrain(v,0,255);}}return out;}
float surveillanceIrMeanLuma(byte[] gray16,int w,int h,int step){
  if(gray16==null||w<=0||h<=0||gray16.length<w*h*2)return 0;
  long sum=0;int count=0;int stride=max(2,step);
  for(int y=stride/2;y<h;y+=stride)for(int x=stride/2;x<w;x+=stride){
    int i=(y*w+x)*2;
    int raw=(gray16[i]&0xff)|((gray16[i+1]&0xff)<<8);
    // IR transport is nominally 10-bit. Clamp so malformed/high flag bits can
    // never make the day/night state machine oscillate.
    int value=min(1023,raw&0x03ff);
    sum+=value;count++;
  }
  return count==0?0:constrain(sum/(count*1023.0f),0,1);
}

class AppearanceMotionDetector {
  final SurveillanceConfig cfg;float[] previous,currentSamples;int previousMode=-1,warmup=0,consecutive=0;
  boolean moving=false,triggered=false;
  AppearanceMotionDetector(SurveillanceConfig cfg){this.cfg=cfg;reset();}
  void reset(){previous=null;currentSamples=null;previousMode=-1;warmup=cfg.motionWarmupFrames;consecutive=0;
    moving=false;triggered=false;}
  float detectRgb(byte[] nv12,int w,int h){return detect(nv12,w,h,studio.services.surveillanceProtocol.MODE_RGB);
    }
  float detectIr(byte[] gray16,int w,int h){return detect(gray16,w,h,studio.services.surveillanceProtocol.MODE_IR);
    }
  float detect(byte[] payload,int w,int h,int mode){
    int step=max(2,cfg.motionSampleStep),cols=(w+step-1)/step,rows=(h+step-1)/step,count=cols*rows;
    if(previous==null||previous.length!=count||previousMode!=mode){previous=new float[count];currentSamples=new float[count];
      Arrays.fill(previous,Float.NaN);previousMode=mode;warmup=cfg.motionWarmupFrames;consecutive=0;moving=false;triggered=false;}
    ByteBuffer ir=mode==studio.services.surveillanceProtocol.MODE_IR?ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN):null;
    int valid=0,n=0;double globalDelta=0;
    for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){
      float current;if(mode==studio.services.surveillanceProtocol.MODE_RGB)current=(payload[y*w+x]&255)/255.0f;
      else{int raw=ir.getShort((y*w+x)*2)&0xffff;current=sqrt(constrain(raw/1023.0f,0,1));}
      currentSamples[n]=current;float old=previous[n];if(!Float.isNaN(old)){globalDelta+=current-old;valid++;}n++;
    }
    float illuminationShift=valid==0?0:constrain((float)(globalDelta/valid),-cfg.motionMaxGlobalShift,cfg.motionMaxGlobalShift);
    int changed=0;
    for(int i=0;i<n;i++){float old=previous[i],current=currentSamples[i];
      if(!Float.isNaN(old)&&abs((current-old)-illuminationShift)>=cfg.motionLumaDelta)changed++;
    }
    float score=valid==0?0:changed/(float)valid;boolean nextMoving=valid>=cfg.motionMinimumValidSamples&&score>=cfg.motionMinimumChangedRatio;
    if(warmup>0){warmup--;nextMoving=false;consecutive=0;triggered=false;}
    else{if(nextMoving){consecutive++;triggered=consecutive>=cfg.motionArmFrames;}else{consecutive=0;triggered=false;}}
    moving=nextMoving;float alpha=moving?cfg.motionActiveAlpha:cfg.motionBackgroundAlpha;
    for(int i=0;i<n;i++){float current=currentSamples[i],old=previous[i];previous[i]=Float.isNaN(old)?current:lerp(old,current,alpha);}
    return score;
  }
  boolean moving(){return moving;}boolean triggered(){return triggered;}
}

class RetainedVideoFrame {final long epochMs;final byte[] jpeg;RetainedVideoFrame(long epochMs,byte[] jpeg){this.epochMs=epochMs;
    this.jpeg=jpeg;}}
class VideoRetentionBuffer {
  final Object lock=new Object();final ArrayDeque<RetainedVideoFrame> frames=new ArrayDeque<RetainedVideoFrame>();
  final long retentionMs;long bytes=0;
  VideoRetentionBuffer(long retentionMs){this.retentionMs=Math.max(1000L,retentionMs);
    }
  void add(RetainedVideoFrame f){synchronized(lock){frames.addLast(f);bytes+=f.jpeg.length;
      long cutoff=f.epochMs-retentionMs;while(!frames.isEmpty()&&frames.peekFirst().epochMs<cutoff){bytes-=frames.removeFirst().jpeg.length;
        }}}
  ArrayList<RetainedVideoFrame> since(long cutoff){synchronized(lock){ArrayList<RetainedVideoFrame> out=new ArrayList<RetainedVideoFrame>();
      for(RetainedVideoFrame f:frames)if(f.epochMs>=cutoff)out.add(f);return out;
      }}
  long bytes(){synchronized(lock){return bytes;}}long durationMs(){synchronized(lock){return frames.size()<2?0:frames.peekLast().epochMs-frames.peekFirst().epochMs;
      }}int size(){synchronized(lock){return frames.size();}}void clear(){synchronized(lock){frames.clear();
      bytes=0;}}
}

class EncodedSurveillanceFrame {
  final byte[] jpeg;
  final int[] previewPixels;
  EncodedSurveillanceFrame(byte[] jpeg,int[] pixels){this.jpeg=jpeg;this.previewPixels=pixels;
    }
}

EncodedSurveillanceFrame encodeSurveillanceJpeg(byte[] nv12,int sw,int sh,SurveillanceConfig cfg,long epochMs,String cameraLabel)throws IOException{
  if(nv12==null||nv12.length!=sw*sh*3/2)return null;
  int tw=cfg.recordWidth,th=cfg.recordHeight;
  int[] pixels=new int[tw*th];
  int ySize=sw*sh;
  for(int y=0;y<th;y++){
    int sy=y*sh/th;
    for(int x=0;x<tw;x++){
      int sx=x*sw/tw;
      int yi=nv12[sy*sw+sx]&255;
      int uv=ySize+(sy/2)*sw+(sx&~1);
      int u=(nv12[uv]&255)-128,v=(nv12[uv+1]&255)-128,c=max(0,yi-16);
      int r=(298*c+409*v+128)>>8,g=(298*c-100*u-208*v+128)>>8,b=(298*c+516*u+128)>>8;

      pixels[y*tw+x]=0xFF000000|(constrain(r,0,255)<<16)|(constrain(g,0,255)<<8)|constrain(b,0,255);

    }
  }
  return encodeSurveillancePixels(pixels,tw,th,cfg,epochMs,cameraLabel);
}

float surveillanceMeanLuma(byte[] nv12,int w,int h){
  if(nv12==null||nv12.length<w*h)return 1;
  long sum=0;int step=8,count=0;
  for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){sum+=nv12[y*w+x]&255;count++;}
  return count==0?1:(sum/(float)count)/255.0f;
}

EncodedSurveillanceFrame encodeSurveillanceIrJpeg(byte[] gray16,int sw,int sh,SurveillanceConfig cfg,long epochMs,String cameraLabel)throws IOException{

  if(gray16==null||gray16.length!=sw*sh*2)return null;
  int tw=cfg.recordWidth,th=cfg.recordHeight;
  int[] pixels=new int[tw*th];
  ByteBuffer src=ByteBuffer.wrap(gray16).order(ByteOrder.LITTLE_ENDIAN);
  for(int y=0;y<th;y++){
    int sy=y*sh/th;
    for(int x=0;x<tw;x++){
      int sx=x*sw/tw;
      int raw=src.getShort((sy*sw+sx)*2)&0xffff;
      float norm=constrain(raw/1023.0f,0,1);
      int v=constrain((int)(sqrt(norm)*255.0f),0,255);
      pixels[y*tw+x]=0xFF000000|(v<<16)|(v<<8)|v;
    }
  }
  return encodeSurveillancePixels(pixels,tw,th,cfg,epochMs,cameraLabel);
}

String fitSurveillanceOverlayText(String value,java.awt.FontMetrics fm,int maxWidth){
  String text=value==null?"":value;
  if(fm.stringWidth(text)<=maxWidth)return text;
  final String suffix="…";
  int keep=text.codePointCount(0,text.length());
  while(keep>1){
    keep--;
    int end=text.offsetByCodePoints(0,keep);
    String candidate=text.substring(0,end)+suffix;
    if(fm.stringWidth(candidate)<=maxWidth)return candidate;
  }
  return suffix;
}

void drawSurveillanceTimestampOverlay(BufferedImage image,SurveillanceConfig cfg,long epochMs,String cameraLabel){
  if(image==null)return;
  Graphics2D g=image.createGraphics();
  try{
    g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING,RenderingHints.VALUE_TEXT_ANTIALIAS_ON);

    g.setRenderingHint(RenderingHints.KEY_RENDERING,RenderingHints.VALUE_RENDER_QUALITY);

    int tw=image.getWidth(),th=image.getHeight();
    int margin=max(4,cfg.timestampMargin);
    int pad=max(6,tw/96);
    int maxBoxWidth=max(40,tw-margin*2);
    int fontSize=max(10,tw/32);
    java.awt.Font font=new java.awt.Font(cfg.uiFontFamily,java.awt.Font.BOLD,fontSize);

    g.setFont(font);
    java.awt.FontMetrics fm=g.getFontMetrics();

    // Date/time is mandatory evidence and is never sacrificed to a long camera name.
    String dateTime=formatSurveillanceTimestamp(epochMs);
    int textLimit=max(16,maxBoxWidth-pad*2);
    while(fontSize>8&&fm.stringWidth(dateTime)>textLimit){
      fontSize--;
      font=new java.awt.Font(cfg.uiFontFamily,java.awt.Font.BOLD,fontSize);
      g.setFont(font);
      fm=g.getFontMetrics();
    }
    String camera=fitSurveillanceOverlayText(cameraLabel,fm,textLimit);
    int textWidth=max(fm.stringWidth(dateTime),fm.stringWidth(camera));
    int lines=(camera==null||camera.length()==0)?1:2;
    int lineGap=max(1,fontSize/8);
    int bw=min(maxBoxWidth,textWidth+pad*2);
    int bh=pad*2+fm.getHeight()*lines+lineGap*(lines-1);
    int x=max(margin,tw-margin-bw);
    int y=max(margin,th-margin-bh);

    g.setColor(new java.awt.Color(0,0,0,190));
    g.fillRoundRect(x,y,bw,bh,max(8,fontSize/2),max(8,fontSize/2));
    g.setColor(java.awt.Color.WHITE);
    int baseline=y+pad+fm.getAscent();
    g.drawString(dateTime,x+pad,baseline);
    if(lines==2)g.drawString(camera,x+pad,baseline+fm.getHeight()+lineGap);
  }finally{
    g.dispose();
  }
}

EncodedSurveillanceFrame encodeSurveillancePixels(int[] pixels,int tw,int th,SurveillanceConfig cfg,long epochMs,String cameraLabel)throws IOException{

  BufferedImage image=new BufferedImage(tw,th,BufferedImage.TYPE_INT_RGB);
  image.setRGB(0,0,tw,th,pixels,0,tw);

  // Surveillance always burns date/time into the evidence frame. The exact same
  // stamped pixels feed the live preview, retention ring and internal MJPEG AVI recording.
  drawSurveillanceTimestampOverlay(image,cfg,epochMs,cameraLabel);

  int[] stampedPixels=new int[tw*th];
  image.getRGB(0,0,tw,th,stampedPixels,0,tw);

  int targetBytes=max(4096,cfg.recordTargetFrameKb*1024);
  float quality=cfg.retentionJpegQuality;byte[] jpeg=null;
  // Adaptive per-frame budget: preserve quality on simple scenes, then step it
  // down only when texture/noise would otherwise make event files balloon.
  // At the default 10 KiB/frame and 5 fps the nominal budget is ~2.9 MiB/min.
  while(true){jpeg=encodeSurveillanceJpegImage(image,quality);if(jpeg.length<=targetBytes||quality<=cfg.retentionJpegMinQuality+.001f)break;
    quality=max(cfg.retentionJpegMinQuality,quality-.05f);}
  return new EncodedSurveillanceFrame(jpeg,stampedPixels);
}

byte[] encodeSurveillanceJpegImage(BufferedImage image,float quality)throws IOException{
  ByteArrayOutputStream out=new ByteArrayOutputStream(max(8192,image.getWidth()*image.getHeight()/8));
  Iterator<ImageWriter> writers=ImageIO.getImageWritersByFormatName("jpeg");if(!writers.hasNext())throw new IOException("JPEG writer unavailable");
  ImageWriter writer=writers.next();ImageOutputStream ios=ImageIO.createImageOutputStream(out);
  try{writer.setOutput(ios);JPEGImageWriteParam p=new JPEGImageWriteParam(Locale.ROOT);
    p.setCompressionMode(JPEGImageWriteParam.MODE_EXPLICIT);p.setCompressionQuality(constrain(quality,.1f,.95f));
    writer.write(null,new IIOImage(image,null,null),p);ios.flush();return out.toByteArray();
    }finally{try{ios.close();}catch(Exception ignored){}writer.dispose();}
}

class SurveillanceEventSession {
  final SurveillanceConfig cfg;final LinkedHashMap<String,CameraEventRecorder> recorders=new LinkedHashMap<String,CameraEventRecorder>();
  final LinkedHashMap<String,String> cameraErrors=new LinkedHashMap<String,String>();
  final Object lock=new Object();File sessionDir;volatile boolean failed=false;volatile String lastError="";
  long startedEpochMs;
  SurveillanceEventSession(SurveillanceConfig cfg){this.cfg=cfg;}
  void start(List<SurveillanceCamera> cameras)throws IOException{File root=cfg.recordingsRoot();
    if(!root.exists()&&!root.mkdirs())throw new IOException("cannot create "+root);
    startedEpochMs=System.currentTimeMillis();String stamp=new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date(startedEpochMs));
    sessionDir=uniqueEventDirectory(root,"event-"+stamp);if(!sessionDir.mkdirs())throw new IOException("cannot create "+sessionDir);
    for(SurveillanceCamera c:cameras)ensureCamera(c);if(recorders.isEmpty())throw new IOException(cameraErrors.isEmpty()?"no camera recorder available":cameraErrors.values().iterator().next());
    writeMetadata("recording");}
  void ensureCamera(SurveillanceCamera camera){if(camera==null||sessionDir==null)return;
    synchronized(lock){if(recorders.containsKey(camera.device.id))return;try{ArrayList<RetainedVideoFrame> pre=camera.retention.since(System.currentTimeMillis()-cfg.preRollSeconds*1000L);
        CameraEventRecorder r=new CameraEventRecorder(camera.device,cfg,new File(sessionDir,"kinect-"+safeToken(camera.device.id)+".avi"),pre);
        recorders.put(camera.device.id,r);cameraErrors.remove(camera.device.id);r.start();
        }catch(Exception e){recorders.remove(camera.device.id);cameraErrors.put(camera.device.id,safeStudioMessage(e));
        }}}
  void submit(SurveillanceCamera camera,RetainedVideoFrame frame){synchronized(lock){CameraEventRecorder r=recorders.get(camera.device.id);
      if(r!=null)r.submit(frame);}}
  void stop(){ArrayList<CameraEventRecorder> copy;synchronized(lock){copy=new ArrayList<CameraEventRecorder>(recorders.values());
      }for(CameraEventRecorder r:copy){r.stop();if(r.failed){synchronized(lock){cameraErrors.put(r.device.id,r.lastError.length()==0?"recording failed":r.lastError);
          }}}failed=healthyRecorderCount()==0&&!cameraErrors.isEmpty();if(failed&&lastError.length()==0)lastError=cameraErrors.values().iterator().next();
    writeMetadata(failed?"failed":(cameraErrors.isEmpty()?"complete":"partial"));
    }
  int healthyRecorderCount(){synchronized(lock){int healthy=0;for(CameraEventRecorder r:recorders.values())if(!r.failed)healthy++;
      return healthy;}}
  boolean hasFailed(){synchronized(lock){int healthy=0,broken=0;for(CameraEventRecorder r:recorders.values()){if(r.failed){broken++;
          cameraErrors.put(r.device.id,r.lastError.length()==0?"recording failed":r.lastError);
          }else healthy++;}if(healthy>0)return false;if(broken>0||!cameraErrors.isEmpty()){failed=true;
        if(lastError.length()==0&&!cameraErrors.isEmpty())lastError=cameraErrors.values().iterator().next();
        return true;}return false;}}
  String failureMessage(){return lastError;}
  void writeMetadata(String state){if(sessionDir==null)return;Properties p=new Properties();
    p.setProperty("state",state);p.setProperty("started.epochMs",String.valueOf(startedEpochMs));
    p.setProperty("updated.epochMs",String.valueOf(System.currentTimeMillis()));p.setProperty("preRoll.seconds",String.valueOf(cfg.preRollSeconds));
    p.setProperty("retention.minutes",String.valueOf(cfg.retentionMinutes));p.setProperty("video.codec","Motion JPEG (MJPEG) / AVI 1.0");
    p.setProperty("video.encoder","SynKinect internal Java AVI writer");p.setProperty("video.targetFrameKB",String.valueOf(cfg.recordTargetFrameKb));
    p.setProperty("video.maxJpegQuality",String.valueOf(cfg.retentionJpegQuality));
    p.setProperty("video.minJpegQuality",String.valueOf(cfg.retentionJpegMinQuality));
    p.setProperty("video.input","JPEG retention ring");p.setProperty("video.timestamp","burned-in");
    p.setProperty("video.timestamp.format",cfg.timestampFormat);p.setProperty("video.timestamp.timezone",TimeZone.getDefault().getID());
    synchronized(lock){p.setProperty("cameras",String.valueOf(recorders.size()+cameraErrors.size()));
      p.setProperty("cameras.recording",String.valueOf(recorders.size()));p.setProperty("cameras.failed",String.valueOf(cameraErrors.size()));
      int i=0;for(CameraEventRecorder r:recorders.values()){p.setProperty("camera."+i+".id",r.device.id);
        p.setProperty("camera."+i+".label",r.device.label);p.setProperty("camera."+i+".file",r.output.getName());
        p.setProperty("camera."+i+".state",r.failed?"failed":"recording");if(r.failed)p.setProperty("camera."+i+".error",r.lastError);
        i++;}for(Map.Entry<String,String> e:cameraErrors.entrySet()){if(recorders.containsKey(e.getKey()))continue;
        p.setProperty("camera."+i+".id",e.getKey());p.setProperty("camera."+i+".state","failed");
        p.setProperty("camera."+i+".error",e.getValue());i++;}}
    File target=new File(sessionDir,"event.properties"),partial=new File(sessionDir,"event.properties.partial");
    try{
      try(OutputStream file=new FileOutputStream(partial);Writer out=new OutputStreamWriter(file,java.nio.charset.StandardCharsets.UTF_8)){
        p.store(out,"SynKinect Surveillance multi-camera event");out.flush();if(file instanceof FileOutputStream)((FileOutputStream)file).getFD().sync();
      }
      moveFileAtomically(partial,target);
    }catch(IOException e){try{Files.deleteIfExists(partial.toPath());}catch(IOException ignored){}println("event-meta: "+safeStudioMessage(e));}
  }
}

class CameraEventRecorder {
  final KinectDevice device;final SurveillanceConfig cfg;final File output,partial;
  final ArrayList<RetainedVideoFrame> preRoll;final ArrayBlockingQueue<RetainedVideoFrame> queue;
  volatile boolean active=false,failed=false;volatile String lastError="";Thread worker;
  MjpegAviWriter writer;long lastEpoch=0,dropped=0;
  CameraEventRecorder(KinectDevice device,SurveillanceConfig cfg,File output,List<RetainedVideoFrame> pre){this.device=device;
    this.cfg=cfg;this.output=output;this.partial=new File(output.getParentFile(),output.getName().replace(".avi",".partial.avi"));
    this.preRoll=new ArrayList<RetainedVideoFrame>(pre);this.queue=new ArrayBlockingQueue<RetainedVideoFrame>(max(24,cfg.recordFps*cfg.recordQueueSeconds));
    }
  void start()throws IOException{writer=new MjpegAviWriter(partial,cfg.recordWidth,cfg.recordHeight,cfg.recordFps);
    active=true;worker=studio.services.workers.start("Surveillance-MJPEG-"+safeToken(device.id),new Runnable(){public void run(){loop();}});
    }
  void submit(RetainedVideoFrame f){if(!active||f==null)return;if(!queue.offer(f)){queue.poll();
      dropped++;queue.offer(f);}}
  void loop(){boolean ok=false;try{for(RetainedVideoFrame f:preRoll)write(f);preRoll.clear();
      while(active||!queue.isEmpty()){RetainedVideoFrame f=queue.poll(200,TimeUnit.MILLISECONDS);
        if(f!=null)write(f);}ok=true;}catch(Exception e){failed=true;lastError=safeStudioMessage(e);
      }finally{active=false;if(writer!=null){try{writer.close();}catch(Exception e){failed=true;
          if(lastError.length()==0)lastError=safeStudioMessage(e);}}
        if(!failed&&ok){
          try{
            if(lastEpoch<=0||!partial.isFile()||partial.length()<256)throw new IOException("Recorded AVI is empty");
            moveFileAtomically(partial,output);
            if(!output.isFile()||output.length()<256)throw new IOException("Recorded AVI was not finalized");
          }catch(IOException e){failed=true;lastError=safeStudioMessage(e);}
        }
        if(failed)try{Files.deleteIfExists(partial.toPath());}catch(IOException ignored){}
      }}
  void write(RetainedVideoFrame f)throws IOException{if(f==null||f.epochMs<=lastEpoch)return;
    writer.addJpeg(f.jpeg);lastEpoch=f.epochMs;}
  void stop(){active=false;Thread t=worker;if(t!=null){try{t.join(cfg.workerJoinMs*4L);
        }catch(InterruptedException e){Thread.currentThread().interrupt();}if(t.isAlive()){t.interrupt();
        try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();
          }}}worker=null;}
}

class AviIndexEntry {final long offset;final int size;AviIndexEntry(long o,int s){offset=o;
    size=s;}}

// Minimal standards-based AVI 1.0 writer.  Every retained JPEG becomes one MJPEG
// keyframe, so no external executable, JNI codec or platform media framework is
// required. Header/index fields are finalized on close and the resulting AVI is
// structured as a conventional indexed MJPEG stream for standard AVI readers.
class MjpegAviWriter implements Closeable {
  final RandomAccessFile out;final int width,height,fps;final ArrayList<AviIndexEntry> index=new ArrayList<AviIndexEntry>();

  long riffSizePos,avihFramesPos,avihMaxBytesPos,strhFramesPos,moviSizePos,moviListStart;
  int maxFrameBytes=0;long payloadBytes=0;boolean closed=false;
  MjpegAviWriter(File target,int width,int height,int fps)throws IOException{this.width=max(2,width);
    this.height=max(2,height);this.fps=max(1,fps);out=new RandomAccessFile(target,"rw");
    out.setLength(0);writeHeader();}
  void writeHeader()throws IOException{
    fourcc("RIFF");riffSizePos=out.getFilePointer();le32(0);fourcc("AVI ");
    long hdrl=beginList("hdrl");
    fourcc("avih");le32(56);le32(1000000/fps);avihMaxBytesPos=out.getFilePointer();
    le32(0);le32(0);le32(0x10);avihFramesPos=out.getFilePointer();le32(0);le32(0);
    le32(1);le32(0);le32(width);le32(height);le32(0);le32(0);le32(0);le32(0);
    long strl=beginList("strl");
    fourcc("strh");le32(56);fourcc("vids");fourcc("MJPG");le32(0);le16(0);le16(0);
    le32(0);le32(1);le32(fps);le32(0);strhFramesPos=out.getFilePointer();le32(0);
    le32(0);le32(-1);le32(0);le16(0);le16(0);le16(width);le16(height);
    fourcc("strf");le32(40);le32(40);le32(width);le32(height);le16(1);le16(24);fourcc("MJPG");
    le32(width*height*3);le32(0);le32(0);le32(0);le32(0);
    endList(strl);
    endList(hdrl);
    fourcc("LIST");moviSizePos=out.getFilePointer();le32(0);moviListStart=out.getFilePointer();
    fourcc("movi");
  }
  synchronized void addJpeg(byte[] jpeg)throws IOException{if(closed)throw new EOFException("AVI recorder closed");
    if(jpeg==null||jpeg.length<4)return;long pos=out.getFilePointer();fourcc("00dc");
    le32(jpeg.length);out.write(jpeg);if((jpeg.length&1)!=0)out.write(0);index.add(new AviIndexEntry(pos,jpeg.length));
    maxFrameBytes=max(maxFrameBytes,jpeg.length);payloadBytes+=jpeg.length;}
  public synchronized void close()throws IOException{if(closed)return;closed=true;
    IOException problem=null;try{
      long moviEnd=out.getFilePointer();patch32(moviSizePos,moviEnd-(moviSizePos+4));
      fourcc("idx1");le32(index.size()*16);for(AviIndexEntry e:index){fourcc("00dc");
        le32(0x10);le32(e.offset-moviListStart);le32(e.size);}long end=out.getFilePointer();
      patch32(avihFramesPos,index.size());patch32(strhFramesPos,index.size());long bytesPerSecond=index.isEmpty()?0:Math.max(maxFrameBytes,(payloadBytes*fps)/Math.max(1,
        index.size()));patch32(avihMaxBytesPos,bytesPerSecond);patch32(riffSizePos,end-8);
      out.getFD().sync();
    }catch(IOException e){problem=e;}finally{try{out.close();}catch(IOException e){if(problem==null)problem=e;
        }}if(problem!=null)throw problem;}
  long beginList(String type)throws IOException{fourcc("LIST");long sizePos=out.getFilePointer();
    le32(0);fourcc(type);return sizePos;}
  void endList(long sizePos)throws IOException{long end=out.getFilePointer();patch32(sizePos,end-(sizePos+4));
    }
  void patch32(long pos,long value)throws IOException{long cur=out.getFilePointer();
    out.seek(pos);le32(value);out.seek(cur);}
  void fourcc(String s)throws IOException{if(s==null||s.length()!=4)throw new IOException("invalid FOURCC");
    out.writeByte(s.charAt(0));out.writeByte(s.charAt(1));out.writeByte(s.charAt(2));
    out.writeByte(s.charAt(3));}
  void le16(long v)throws IOException{out.writeByte((int)(v&255));out.writeByte((int)((v>>>8)&255));
    }
  void le32(long v)throws IOException{out.writeByte((int)(v&255));out.writeByte((int)((v>>>8)&255));
    out.writeByte((int)((v>>>16)&255));out.writeByte((int)((v>>>24)&255));}
}

class SurveillanceConfig {
  int uiFrameRate=30;String uiFontFamily="Segoe UI";int workerJoinMs=1800,reconnectMs=250,videoQueueFrames=48;

  int motionSampleStep=8,motionMinimumValidSamples=400,motionArmFrames=3,motionWarmupFrames=10;
  float motionLumaDelta=0.08f,motionMinimumChangedRatio=0.025f,motionBackgroundAlpha=0.035f,motionActiveAlpha=0.004f,motionMaxGlobalShift=0.18f;long motionStopAfterMs=60000;

  String timestampFormat="yyyy-MM-dd HH:mm:ss";int timestampMargin=14;
  float nightEnterLuma=0.18f,nightExitLuma=0.30f,nightIrProbeLuma=0.78f;int nightDarkFrames=12,nightBrightFrames=4,nightProbeFrames=6,nightMotionProbeFrames=4,
  nightIrProbeFrames=45;long nightProbeIntervalMs=30000,nightMotionProbeCooldownMs=2500,nightRgbProbeTimeoutMs=3000,nightMinimumModeHoldMs=60000;

  int retentionMinutes=10,preRollSeconds=60,retentionFps=5;float retentionJpegQuality=0.40f,retentionJpegMinQuality=0.20f;

  int recordFps=5,recordWidth=320,recordHeight=240,recordQueueSeconds=30,recordTargetFrameKb=10;
  String recordDirectory="recordings";
  void load(File file){Properties p=studio.services.configRules.load(file,"surveillance");
    uiFrameRate=intValue(p,"ui.frameRate",uiFrameRate,10,60);uiFontFamily=textValue(p,"ui.font.family",uiFontFamily);
    workerJoinMs=intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);reconnectMs=intValue(p,"transport.reconnectMs",reconnectMs,50,5000);
    videoQueueFrames=intValue(p,"transport.videoQueueFrames",videoQueueFrames,8,240);
    motionSampleStep=intValue(p,"motion.sampleStep",motionSampleStep,2,32);motionLumaDelta=floatValue(p,"motion.lumaDelta",motionLumaDelta,0.005f,0.80f);
    motionMinimumValidSamples=intValue(p,"motion.minimumValidSamples",motionMinimumValidSamples,20,10000);
    motionMinimumChangedRatio=floatValue(p,"motion.minimumChangedRatio",motionMinimumChangedRatio,0.001f,0.95f);
    motionBackgroundAlpha=floatValue(p,"motion.backgroundAlpha",motionBackgroundAlpha,0.001f,0.50f);
    motionActiveAlpha=floatValue(p,"motion.activeAlpha",motionActiveAlpha,0.0001f,motionBackgroundAlpha);
    motionMaxGlobalShift=floatValue(p,"motion.maxGlobalShift",motionMaxGlobalShift,0.0f,0.6f);
    motionArmFrames=intValue(p,"motion.armFrames",motionArmFrames,1,30);motionWarmupFrames=intValue(p,"motion.warmupFrames",motionWarmupFrames,0,120);
    motionStopAfterMs=longValue(p,"motion.stopAfterMs",motionStopAfterMs,1000,3600000);
    timestampFormat=textValue(p,"overlay.timestamp.format",timestampFormat);timestampMargin=intValue(p,"overlay.timestamp.margin",timestampMargin,4,64);
    nightEnterLuma=floatValue(p,"night.enterLuma",nightEnterLuma,0.02f,0.8f);nightExitLuma=floatValue(p,"night.exitLuma",nightExitLuma,nightEnterLuma,0.95f);
    nightDarkFrames=intValue(p,"night.darkFrames",nightDarkFrames,2,120);nightBrightFrames=intValue(p,"night.brightFrames",nightBrightFrames,1,60);
    nightProbeFrames=intValue(p,"night.probeFrames",nightProbeFrames,2,60);nightMotionProbeFrames=intValue(p,"night.motionProbeFrames",nightMotionProbeFrames,
      2,30);nightIrProbeLuma=floatValue(p,"night.irProbeLuma",nightIrProbeLuma,0.20f,0.98f);
    nightIrProbeFrames=intValue(p,"night.irProbeFrames",nightIrProbeFrames,5,300);
    nightProbeIntervalMs=longValue(p,"night.probeIntervalMs",nightProbeIntervalMs,5000,300000);
    nightMotionProbeCooldownMs=longValue(p,"night.motionProbeCooldownMs",nightMotionProbeCooldownMs,500,60000);
    nightRgbProbeTimeoutMs=longValue(p,"night.rgbProbeTimeoutMs",nightRgbProbeTimeoutMs,500,15000);
    nightMinimumModeHoldMs=longValue(p,"night.minimumModeHoldMs",nightMinimumModeHoldMs,10000,600000);
    retentionMinutes=intValue(p,"retention.minutes",retentionMinutes,1,60);preRollSeconds=intValue(p,"retention.preRollSeconds",preRollSeconds,1,retentionMinutes*60);
    recordFps=intValue(p,"record.fps",recordFps,1,30);retentionFps=intValue(p,"retention.fps",retentionFps,1,recordFps);
    retentionJpegQuality=floatValue(p,"retention.jpegQuality",retentionJpegQuality,0.2f,0.95f);
    retentionJpegMinQuality=floatValue(p,"retention.jpegMinQuality",retentionJpegMinQuality,0.1f,retentionJpegQuality);
    recordWidth=evenValue(p,"record.width",recordWidth,160,640);recordHeight=evenValue(p,"record.height",recordHeight,120,480);
    recordQueueSeconds=intValue(p,"record.queueSeconds",recordQueueSeconds,5,120);
    recordTargetFrameKb=intValue(p,"record.targetFrameKB",recordTargetFrameKb,4,96);
    recordDirectory=textValue(p,"record.directory",recordDirectory);}
  File recordingsRoot(){
    String remembered=studio.userPreferences.get("surveillance.record.directory","");
    File directory=remembered.isEmpty()?studio.services.paths.dataDirectory("surveillance",recordDirectory,"recordings"):new File(remembered);
    return directory;
    }
  String textValue(Properties p,String k,String d){return studio.services.configRules.text(p,k,d);
    }boolean boolValue(Properties p,String k,boolean d){return studio.services.configRules.flag(p,k,d);
    }int intValue(Properties p,String k,int d,int lo,int hi){return studio.services.configRules.integer(p,k,d,lo,hi);
    }int evenValue(Properties p,String k,int d,int lo,int hi){return studio.services.configRules.even(p,k,d,lo,hi);
    }long longValue(Properties p,String k,long d,long lo,long hi){return studio.services.configRules.longNumber(p,k,d,lo,hi);
    }float floatValue(Properties p,String k,float d,float lo,float hi){return studio.services.configRules.decimal(p,k,d,lo,hi);
    }
}

class SurveillanceProtocol {
  final int MAGIC=0x43534D52,FRAME_MAGIC=0x46534D52,VERSION=1,CMD_SUBSCRIBE_STREAMS=1;

  final int WIDTH=640,HEIGHT=480,IR_RAW_HEIGHT=488,MODE_RGB=0,MODE_IR=1,STREAM_RGB=1,STREAM_IR=2;

  final int PIXEL_BAYER_GRBG8=4,PIXEL_IR_RAW10_PACKED=5,PIXEL_BGRA32=0x41524742,PIXEL_IR_U16=1004,PIXEL_JPEG=1005;
  final int ABSOLUTE_MAX_PAYLOAD_BYTES=128*1024*1024;
  final int RGB_RAW_BYTES=WIDTH*HEIGHT,IR_RAW10_BYTES=WIDTH*IR_RAW_HEIGHT*10/8;
  final int MAX_PAYLOAD_BYTES=max(RGB_RAW_BYTES,IR_RAW10_BYTES),REPLY_BYTES=68,FRAME_HEADER_BYTES=76;

}

class SurveillanceI18n extends ModuleI18n {SurveillanceI18n(String requested){super("surveillance",requested);
    }}
class SurveillanceTheme {final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE_ALT=0xFF202832,SURFACE_RAISED=0xFF293440,BORDER=0xFF35414D,TEXT=0xFFF4F7FA,
  MUTED=0xFFAAB6C2,ACCENT=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B,BAD=0xFFE17D7D,PREVIEW=0xFF0B0F13;
  final int FONT_TINY=STUDIO_FONT_TINY,FONT_SMALL=STUDIO_FONT_SMALL,FONT_BODY=STUDIO_FONT_BODY,FONT_METRIC=STUDIO_FONT_METRIC,FONT_TITLE=STUDIO_FONT_TITLE;
  }
void initializeSurveillanceTypography(){if(studioUnicodeRegular==null||studioUnicodeHeading==null)initializeStudioTypography();
  }
void surveillanceText(float size,boolean heading){studioText(size,heading);}
String formatSurveillanceTimestamp(long epochMs){try{return new SimpleDateFormat(surveillanceState().config.timestampFormat,Locale.ROOT).format(new Date(epochMs));
    }catch(Exception e){return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.ROOT).format(new Date(epochMs));
    }}
File uniqueEventDirectory(File root,String base){File f=new File(root,base);for(int i=2;f.exists();i++)f=new File(root,base+"-"+i);
  return f;}
String safeToken(String value){String s=value==null?"kinect":value.replaceAll("[^A-Za-z0-9._-]+","-");
  while(s.startsWith("-"))s=s.substring(1);return s.isEmpty()?"kinect":s;}

class SurveillanceUI {
  final StudioUiButton armButton=new StudioUiButton(),recordButton=new StudioUiButton(),stopButton=new StudioUiButton(),folderButton=new StudioUiButton();
  final HashMap<String,PImage> previewImages=new HashMap<String,PImage>();
  float statusHeight(){return studio.ui.metricPanelHeight(max(80,width-2*studioUiMargin()),7,true);
    }
  float actionHeight(float panelW){return studio.ui.actionPanelHeight(panelW,4,true);
    }
  void draw(){
    SurveillanceModuleState state=surveillanceState();SurveillanceTheme theme=state.theme;

    float m=studioUiMargin(),gap=studioUiGap(),w=max(80,width-2*m);studio.ui.renderer.header(state.i18n,state.i18n.tr("app.title"));

    float statusY=studioUiHeaderHeight()+gap,statusH=statusHeight();drawStatus(m,statusY,w,statusH);

    float bodyY=statusY+statusH+gap,bodyH=max(1,studio.contentHeight-bodyY-m),actionsH=actionHeight(w);

    StudioUiRect[] bands=studio.ui.vertical(m,bodyY,w,bodyH,gap,new float[]{220,actionsH},new float[]{80,actionsH},new float[]{1,0});

    drawPreview(bands[0].x,bands[0].y,bands[0].w,bands[0].h);
    StudioUiRect actionPanel=bands[1];drawButtons(actionPanel.x,actionPanel.y,actionPanel.w,actionPanel.h);

  }
  SurveillanceCamera selectedCamera(){KinectDevice selected=studio.selectedKinect();
    synchronized(surveillanceState().cameraLock){if(selected!=null){SurveillanceCamera c=surveillanceState().cameras.get(selected.id);
        if(c!=null)return c;}return surveillanceState().cameras.isEmpty()?null:surveillanceState().cameras.values().iterator().next();
      }}
  void drawPreview(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,surveillanceState().i18n.tr("panel.preview"));
    float contentY=y+studioUiCardTitleHeight(),contentH=max(1,h-studioUiCardTitleHeight());

    ArrayList<SurveillanceCamera> cameras;synchronized(surveillanceState().cameraLock){cameras=new ArrayList<SurveillanceCamera>(surveillanceState().cameras.values());
      }
    if(cameras.isEmpty()){fill(surveillanceState().theme.MUTED);surveillanceText(STUDIO_FONT_BODY,false);
      textAlign(CENTER,CENTER);text(surveillanceState().i18n.tr("waiting.video"),x+w/2,contentY+contentH/2);
      return;}
    int n=cameras.size(),cols=n<=1?1:(n<=4?2:(n<=9?3:4)),rows=(n+cols-1)/cols;StudioUiMetrics ui=studio.ui.metrics();
    float gap=max(10,ui.gap*.68f),pad=max(12,ui.panelPad),cellW=max(1,(w-pad*2-gap*(cols-1))/cols),cellH=max(1,(contentH-pad*2-gap*(rows-1))/rows);

    KinectDevice selected=studio.selectedKinect();
    for(int index=0;index<n;index++){
      SurveillanceCamera c=cameras.get(index);int col=index%cols,row=index/cols;float cx=x+pad+col*(cellW+gap),cy=contentY+pad+row*(cellH+gap);

      fill(surveillanceState().theme.PREVIEW);stroke(selected!=null&&selected.id.equals(c.device.id)?surveillanceState().theme.ACCENT:surveillanceState().theme.BORDER);
      strokeWeight(selected!=null&&selected.id.equals(c.device.id)?2:1);rect(cx,cy,cellW,cellH,6);
      noStroke();
      int[] src=c.latestPreviewPixels;int pw=c.previewWidth,ph=c.previewHeight;
      if(src!=null&&pw>0&&ph>0){PImage image=previewImages.get(c.device.id);if(image==null||image.width!=pw||image.height!=ph){image=createImage(pw,ph,
            RGB);previewImages.put(c.device.id,image);}image.loadPixels();if(src.length==image.pixels.length)System.arraycopy(src,0,image.pixels,0,src.length);
        image.updatePixels();float labelH=28,scale=min((cellW-8)/pw,max(1,cellH-labelH-8)/ph),dw=pw*scale,dh=ph*scale;
        float ix=cx+(cellW-dw)/2,iy=cy+4+(cellH-labelH-8-dh)/2;pushMatrix();translate(ix+dw,iy);scale(-1,1);image(image,0,0,dw,dh);popMatrix();}
      fill(surveillanceState().theme.TEXT);surveillanceText(STUDIO_FONT_TINY,true);
      textAlign(LEFT,BOTTOM);text(ellipsizeToWidth(c.device.label+" · "+c.videoModeLabel(),cellW-32),cx+8,cy+cellH-7);

      if(surveillanceState().recording){fill(surveillanceState().theme.BAD);ellipse(cx+cellW-13,cy+13,9,9);
        }
    }
    HashSet<String> keepPreviewIds=new HashSet<String>();for(SurveillanceCamera c:cameras)keepPreviewIds.add(c.device.id);
    previewImages.keySet().retainAll(keepPreviewIds);
  }
  void drawStatus(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,surveillanceState().i18n.tr("panel.status"));SurveillanceModuleState state=surveillanceState();

    int count,ready=0;long bytes=0,minDuration=Long.MAX_VALUE;synchronized(state.cameraLock){count=state.cameras.size();
      for(SurveillanceCamera c:state.cameras.values()){if(c.device.cameraReady())ready++;
        bytes+=c.retainedBytes();minDuration=Math.min(minDuration,c.retainedDurationMs());
        }}if(minDuration==Long.MAX_VALUE)minDuration=0;
    SurveillanceCamera selected=selectedCamera();
    String[] labels={state.i18n.tr("label.state"),state.i18n.tr("label.cameras"),state.i18n.tr("label.ram"),state.i18n.tr("label.retention"),state.i18n.tr("label.preroll"),
      state.i18n.tr("label.motion"),state.i18n.tr("label.video_mode")};
    String[] values={state.recording?state.i18n.tr("state.recording"):(state.armed?state.i18n.tr("state.armed"):state.i18n.tr("state.disarmed")),ready+" / "+count,
      formatBytes(bytes),formatDuration(minDuration)+" / "+state.config.retentionMinutes+" min",state.config.preRollSeconds+" s",nf(state.motionScore*100,
        1,2)+"%",selected==null?"—":selected.videoModeLabel()+" · "+nf(selected.meanLuma*100,1,0)+"%"};

    boolean[] active={state.recording||state.armed,ready>0,bytes>0,minDuration>0,state.config.preRollSeconds>0,state.motionScore>=state.config.motionMinimumChangedRatio,
      selected!=null};
    StudioUiMetrics ui=studio.ui.metrics();float footer=ui.footerH,ix=x+ui.panelPad,iy=y+ui.cardTitleH+ui.panelPad*.45f,iw=max(1,w-ui.panelPad*2),ih=max(1,
      h-ui.cardTitleH-ui.panelPad*1.45f-footer);
    studio.ui.drawMetricGrid(labels,values,active,ix,iy,iw,ih);
    fill(state.theme.MUTED);surveillanceText(state.theme.FONT_TINY,false);textAlign(LEFT,CENTER);
    fitCurrentTextSize(state.status,state.theme.FONT_TINY,8,w-28,footer-4);text(ellipsizeToWidth(state.status,w-28),x+14,y+h-footer*.5f);
    textAlign(LEFT,BASELINE);
  }
  void metricTile(float x,float y,float w,float h,String label,String value,boolean active){studio.ui.renderer.metric(x,y,w,h,label,value,active);
    }
  void drawButtons(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,surveillanceState().i18n.tr("panel.actions"));
    StudioUiMetrics ui=studio.ui.metrics();boolean busy=surveillanceState().recording||surveillanceState().recordStarting;
    boolean haveCamera=false;for(KinectDevice d:studio.services.devices.snapshot())if(d.cameraReady()&&d.hasCapability("color")){haveCamera=true;break;}armButton.configure(surveillanceState().armed?surveillanceState().i18n.tr("button.disarm"):surveillanceState().i18n.tr("button.arm"),
      surveillanceState().armed||haveCamera,false,true,false);recordButton.configure(surveillanceState().i18n.tr("button.record"),!busy&&haveCamera,false,
      true,false);stopButton.configure(surveillanceState().i18n.tr("button.stop"),busy,false,true,false);folderButton.configure(surveillanceState().i18n.tr("button.folder"),!busy,false,false,false);
    ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();items.add(armButton);
    items.add(recordButton);items.add(stopButton);items.add(folderButton);float footer=ui.footerH;studio.ui.layoutButtons(items,x+ui.panelPad,y+ui.cardTitleH+ui.panelPad*.45f,
      max(1,w-ui.panelPad*2),max(1,h-ui.cardTitleH-ui.panelPad*1.45f-footer));for(StudioUiButton item:items)item.draw();
    File location=surveillanceState().config.recordingsRoot();
    studio.ui.renderer.locationFooter(x+ui.panelPad,y+h-footer,w-ui.panelPad*2,footer,surveillanceState().i18n.tr("label.recording_folder"),location,location!=null&&(location.canWrite()||(!location.exists()&&location.getParentFile()!=null&&location.getParentFile().canWrite())));

  }
  void cardTitle(float x,float y,float w,String title){studio.ui.module(surveillanceState().i18n).panelTitle(x,y,w,title);
    }
  void button(StudioUiButton r,String label,boolean enabled){r.configure(label,enabled,false,true,false);
    r.draw();}
  void handleMouse(float mx,float my){boolean busy=surveillanceState().recording||surveillanceState().recordStarting;
    if(armButton.hit(mx,my))toggleArmed();else if(recordButton.hit(mx,my)&&!busy)manualRecord();
    else if(stopButton.hit(mx,my)&&busy)requestStopMotionRecording(false);else if(folderButton.hit(mx,my)&&!busy)chooseSurveillanceRecordingFolder();}
  void card(float x,float y,float w,float h){studio.ui.module(surveillanceState().i18n).panel("",x,y,w,h);
     }
  String formatBytes(long bytes){double mb=bytes/(1024.0*1024.0);return mb<1024?String.format(Locale.ROOT,"%.1f MB",mb):String.format(Locale.ROOT,"%.2f GB",
      mb/1024.0);}String formatDuration(long ms){long sec=Math.max(0L,ms/1000),m=sec/60,s=sec%60;
    return String.format(Locale.ROOT,"%02d:%02d",m,s);}
}
