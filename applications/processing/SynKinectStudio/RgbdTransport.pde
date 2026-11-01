// ===== SynKinect Studio / Core (shared by all modules) / KinectSource.pde =====



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
    boolean extensionRequested=false;
    if(nativeOne){byte[] idBytes=requestDevice.id.getBytes(java.nio.charset.StandardCharsets.UTF_8);extensionRequested=idBytes.length<=62;int n=min(extensionRequested?62:63,idBytes.length);req.put(idBytes,0,n);while(req.position()<80)req.put((byte)0);
      if(extensionRequested)req.put(79,(byte)studio.services.scannerProtocol.REPLY_EXTENSION_REQUEST);}
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

    float[] nativeExtension=null;
    if(nativeOne&&extensionRequested&&depthCalibrationValid==studio.services.scannerProtocol.DEPTH_CALIBRATION_NATIVE_EXTENDED){
      byte[] eb=new byte[studio.services.scannerProtocol.REPLY_EXTENSION_BYTES];pipe.readFully(eb);ByteBuffer e=ByteBuffer.wrap(eb).order(ByteOrder.LITTLE_ENDIAN);
      int emagic=e.getInt(),eversion=e.getInt(),ebytes=e.getInt(),eflags=e.getInt();
      if(emagic==studio.services.scannerProtocol.REPLY_EXTENSION_MAGIC&&eversion>=1&&ebytes>=64){nativeExtension=new float[13];nativeExtension[0]=eflags;for(int i=1;i<13;i++)nativeExtension[i]=e.getFloat();}
    }

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

    if(nativeOne&&(depthCalibrationValid==studio.services.scannerProtocol.DEPTH_CALIBRATION_NATIVE||depthCalibrationValid==studio.services.scannerProtocol.DEPTH_CALIBRATION_NATIVE_EXTENDED)){
      calibration.applyNativeIntrinsics(w,h,depthConstShift,depthEmitterDistance,depthReferenceDistance,depthReferencePixelSize);
      if(nativeExtension!=null){int flags=(int)nativeExtension[0];
        // Order on the wire: k1,k2,k3,p1,p2,pixelCenter,colorFx,colorFy,colorCx,colorCy,shiftD,shiftM.
        if((flags&1)!=0)calibration.applyNativeDistortion(nativeExtension[1],nativeExtension[2],nativeExtension[3],nativeExtension[4],nativeExtension[5],nativeExtension[6]);
        if((flags&2)!=0)calibration.applyNativeColorIntrinsics(nativeExtension[7],nativeExtension[8],nativeExtension[9],nativeExtension[10],nativeExtension[11],nativeExtension[12]);}
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
