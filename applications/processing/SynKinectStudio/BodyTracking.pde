// ===== SynKinect Studio / Body Tracking block =====
// Reusable backend block: one metric-depth RGB-D session + one SynSkeleton solver
// on a latest-frame worker. Created through StudioProcessingBlocks.openBodyTracking().
//
// Consumers:
//  * frontends poll latest() for an immutable BodyProcessedFrame (depth preview
//    pixels, pose, body cloud) exactly like the former Interactivity runtime;
//  * backends subscribe() and receive immutable BodyFrame snapshots through a
//    latest-only mailbox served by their own thread. A slow consumer only drops
//    its own stale frames; it can never block the solver or other consumers.
//
// Ownership: the module that owns a BodyTrackingSession starts it when its tab
// becomes active and stops it on deactivation (see docs/ARCHITECTURE.md, only the
// active single-camera module owns a live transport).

// Kinect v1 20-joint naming (+ optional Kinect v2 hand tip / thumb). Index order
// is part of the BodyFrame contract.
final String[] BODY_FRAME_JOINTS={"HipCenter","Spine","ShoulderCenter","Head","ShoulderLeft","ElbowLeft","WristLeft","HandLeft",
  "ShoulderRight","ElbowRight","WristRight","HandRight","HipLeft","KneeLeft","AnkleLeft","FootLeft","HipRight","KneeRight","AnkleRight","FootRight",
  "HandTipLeft","ThumbLeft","HandTipRight","ThumbRight"};
final int BJ_HIP_CENTER=0,BJ_SPINE=1,BJ_SHOULDER_CENTER=2,BJ_HEAD=3,BJ_SHOULDER_LEFT=4,BJ_ELBOW_LEFT=5,BJ_WRIST_LEFT=6,BJ_HAND_LEFT=7,
  BJ_SHOULDER_RIGHT=8,BJ_ELBOW_RIGHT=9,BJ_WRIST_RIGHT=10,BJ_HAND_RIGHT=11,BJ_HIP_LEFT=12,BJ_KNEE_LEFT=13,BJ_ANKLE_LEFT=14,BJ_FOOT_LEFT=15,
  BJ_HIP_RIGHT=16,BJ_KNEE_RIGHT=17,BJ_ANKLE_RIGHT=18,BJ_FOOT_RIGHT=19,BJ_HAND_TIP_LEFT=20,BJ_THUMB_LEFT=21,BJ_HAND_TIP_RIGHT=22,BJ_THUMB_RIGHT=23;

// Immutable body snapshot. Positions are metres in Studio camera space
// (+X image right = user's LEFT when facing the sensor, +Y down, +Z away).
final class BodyFrame {
  final String deviceId;final long monotonicMs,inputMs,frameNumber,trackingId;final boolean tracked;final float confidence;
  final boolean floorValid;final float floorD; // floor plane: up·p + floorD = height above floor (valid only when floorValid)
  private final float[] xyz,conf,up;private final int[] states;
  BodyFrame(String deviceId,long monotonicMs,long inputMs,long frameNumber,long trackingId,boolean tracked,float confidence,
    float[] xyz,float[] conf,int[] states,float[] up,boolean floorValid,float floorD){
    this.deviceId=deviceId==null?"":deviceId;this.monotonicMs=monotonicMs;this.inputMs=inputMs;this.frameNumber=frameNumber;this.trackingId=trackingId;
    this.tracked=tracked;this.confidence=confidence;this.xyz=xyz.clone();this.conf=conf.clone();this.states=states.clone();
    this.up=up==null?null:up.clone();this.floorValid=floorValid&&up!=null;this.floorD=floorD;
  }
  int jointCount(){return conf.length;}
  String jointName(int i){return BODY_FRAME_JOINTS[i];}
  float x(int i){return xyz[i*3];}float y(int i){return xyz[i*3+1];}float z(int i){return xyz[i*3+2];}
  float confidence(int i){return conf[i];}
  int state(int i){return states[i];}
  boolean jointTracked(int i){return i>=0&&i<conf.length&&states[i]>SkeletonJoint3D.LOST&&conf[i]>0;}
  PVector position(int i){return new PVector(xyz[i*3],xyz[i*3+1],xyz[i*3+2]);}
  float[] upVector(){return up==null?null:up.clone();}
}

BodyFrame bodyFrameFromPose(String deviceId,SkeletonPose3D s,long frameNumber,long inputMs,long nowMs,PVector up,boolean floorValid,float floorD){
  int n=BODY_FRAME_JOINTS.length;float[] xyz=new float[n*3],conf=new float[n];int[] st=new int[n];
  if(s!=null){
    SkeletonJoint3D[] j={s.hipCenter,s.spine,s.shoulderCenter,s.head,s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand,s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand,
      s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot,s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot,
      firstTracked(s.leftHandTip,s.leftHandDetail==null?null:s.leftHandDetail.middleTip()),firstTracked(s.leftThumb,s.leftHandDetail==null?null:s.leftHandDetail.thumbTip()),
      firstTracked(s.rightHandTip,s.rightHandDetail==null?null:s.rightHandDetail.middleTip()),firstTracked(s.rightThumb,s.rightHandDetail==null?null:s.rightHandDetail.thumbTip())};
    for(int i=0;i<n;i++){SkeletonJoint3D q=j[i];if(q==null||q.world==null)continue;
      if(!Float.isFinite(q.world.x)||!Float.isFinite(q.world.y)||!Float.isFinite(q.world.z))continue;
      xyz[i*3]=q.world.x;xyz[i*3+1]=q.world.y;xyz[i*3+2]=q.world.z;conf[i]=q.confidence;st[i]=q.state;}
  }
  float[] u=null;if(up!=null&&up.magSq()>1e-8f){PVector c=up.copy().normalize();u=new float[]{c.x,c.y,c.z};}
  return new BodyFrame(deviceId,nowMs,inputMs,frameNumber,s==null?0:s.trackingId,s!=null&&s.tracked,s==null?0:s.confidence,xyz,conf,st,u,floorValid,floorD);
}
SkeletonJoint3D firstTracked(SkeletonJoint3D a,SkeletonJoint3D b){if(a!=null&&a.tracked())return a;if(b!=null&&b.tracked())return b;return a;}

// Latest-only mailbox with its own consumer thread. offer() never blocks.
class LatestMailbox<T> implements Closeable {
  final String role;final java.util.function.Consumer<T> consumer;final Object lock=new Object();
  T pending=null;boolean open=true;Thread worker;
  volatile long offered=0,delivered=0,dropped=0;volatile String lastError="";
  LatestMailbox(String role,java.util.function.Consumer<T> consumer){
    if(consumer==null)throw new IllegalArgumentException("consumer");this.role=role;this.consumer=consumer;
    worker=studio.services.workers.start(role,new Runnable(){public void run(){loop();}});
  }
  boolean offer(T value){if(value==null)return false;synchronized(lock){if(!open)return false;if(pending!=null)dropped++;pending=value;offered++;lock.notifyAll();}return true;}
  boolean isOpen(){synchronized(lock){return open;}}
  void loop(){
    while(true){T value;
      synchronized(lock){while(open&&pending==null){try{lock.wait();}catch(InterruptedException e){if(!open)return;}}
        if(!open)return;value=pending;pending=null;}
      try{consumer.accept(value);delivered++;}
      catch(Throwable e){rethrowFatalPluginError(e);lastError=safeStudioMessage(e);println("["+role+"] consumer warning: "+lastError);}
    }
  }
  public void close(){close(0);}
  void close(long joinMs){Thread t;synchronized(lock){open=false;pending=null;lock.notifyAll();t=worker;}
    if(joinMs>0&&t!=null&&t!=Thread.currentThread()){try{t.join(joinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}}
}

class BodyTrackingOptions {
  String role="Body",logLabel="Body tracking";int workerJoinMs=2200,streamStaleMs=1800,previewHz=15;
  BodyTrackingOptions(){}
  BodyTrackingOptions(String role,String logLabel,int workerJoinMs,int streamStaleMs,int previewHz){this.role=role;this.logLabel=logLabel;
    this.workerJoinMs=workerJoinMs;this.streamStaleMs=streamStaleMs;this.previewHz=previewHz;}
}

class BodyVisionSnapshot {
  final DepthFrame depthFrame;final RawRgbFrame rgbFrame;final InfraredFrame infraredFrame;final long depthTickMs,sequence,arrivalMs;
  BodyVisionSnapshot(DepthFrame depth,InfraredFrame infrared,RawRgbFrame rgb,long arrivalMs){
    depthFrame=depth;rgbFrame=rgb;this.infraredFrame=infrared;depthTickMs=depth==null?0:depth.timestampUs/1000L;
    sequence=depth==null?-1:depth.frameNumber;this.arrivalMs=arrivalMs;
  }
  long key(){return sequence;}
}
class BodyProcessedFrame {long frameNumber=-1;int[] previewPixels;int previewWidth=0,previewHeight=0;SkeletonPose3D skeleton;PointCloud bodyCloud;BodyFrame body;}

// Latest-frame solver worker (formerly InteractionFrameProcessor).
class BodyFrameProcessor {
  final BodyTrackingSession owner;final BodyTrackingOptions cfg;final SkeletonProcessingSession skeletonSession;final Object lock=new Object();
  volatile boolean running=false;volatile long runGeneration=0;volatile BodyProcessedFrame published=null;
  volatile long lastPublishedMs=0;long lastPreviewMs=0;int[] depthPreviewBuffer=null,rgbPreviewBuffer=null;Thread worker;BodyVisionSnapshot pending=null;
  volatile long processedFrames=0;

  BodyFrameProcessor(BodyTrackingSession owner,BodyTrackingOptions cfg,SkeletonProcessingSession skeletonSession){this.owner=owner;this.cfg=cfg;
    this.skeletonSession=skeletonSession;}
  void start(){synchronized(lock){if(running)return;running=true;pending=null;published=null;
      final long generation=++runGeneration;worker=studio.services.workers.start(cfg.role+"-3D-Fusion",new Runnable(){public void run(){loop(generation);}
        });}}
  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;pending=null;
      lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread())t.interrupt();
    }
  void stop(){Thread t;synchronized(lock){running=false;++runGeneration;pending=null;
      lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();
      try{t.join(min(1000,cfg.workerJoinMs));}catch(InterruptedException e){Thread.currentThread().interrupt();
        }}}
  void submit(BodyVisionSnapshot f){if(f==null||f.depthFrame==null||f.depthFrame.depth==null)return;
    synchronized(lock){if(!running)return;pending=f;lock.notifyAll();}}
  BodyProcessedFrame latest(){return published;}
  void clearPublished(){synchronized(lock){pending=null;published=null;lastPublishedMs=0;
      lastPreviewMs=0;}}
  void loop(long generation){while(true){BodyVisionSnapshot f;synchronized(lock){while(running&&generation==runGeneration&&pending==null)try{lock.wait();
          }catch(InterruptedException e){if(!running||generation!=runGeneration)return;
          }if(!running||generation!=runGeneration)return;f=pending;pending=null;}try{BodyProcessedFrame out=new BodyProcessedFrame();
        SkeletonModuleFrame solved=skeletonSession.process(f.depthFrame,f.infraredFrame,f.rgbFrame,f.depthTickMs>0?f.depthTickMs:millis64());
        out.frameNumber=f.key();out.skeleton=solved.pose;out.bodyCloud=solved.bodyCloud;
        long now=millis64();if(lastPreviewMs==0||now-lastPreviewMs>=1000/max(1,cfg.previewHz)){
          if(skeletonSession.cfg.usesRgb()){
            RawRgbFrame rgb=f.rgbFrame;
            if(rgb!=null&&rgb.data!=null&&rgb.width>0&&rgb.height>0&&rgb.width<=4096&&rgb.height<=4096){
              int count=rgb.width*rgb.height;
              if(rgbPreviewBuffer==null||rgbPreviewBuffer.length!=count)rgbPreviewBuffer=new int[count];
              if(owner.rgbd.source.decodeRgbPayloadToArgb(rgb.data,rgb.width,rgb.height,rgb.pixelFormat,rgbPreviewBuffer)){
                out.previewPixels=rgbPreviewBuffer.clone();out.previewWidth=rgb.width;out.previewHeight=rgb.height;
              }
            }
          }else{
            int[] depthPixels=metricDepthPreview(f.depthFrame);
            if(depthPixels!=null){out.previewPixels=depthPixels.clone();out.previewWidth=f.depthFrame.width;out.previewHeight=f.depthFrame.height;}
          }
          lastPreviewMs=now;}
        if(owner.hasSubscribers()){SkeletonFloorModel floor=skeletonSession.floorModel();
          PVector up=floor==null?null:floor.upVector();
          out.body=bodyFrameFromPose(owner.deviceId,solved.pose,f.key(),f.arrivalMs,now,up,floor!=null&&floor.valid,floor==null?0:floor.d);}
        if(generation==runGeneration){published=out;lastPublishedMs=now;processedFrames++;if(out.body!=null)owner.publish(out.body);
          }}catch(Exception e){if(generation==runGeneration)println(cfg.logLabel+" 3D processor warning: "+safeStudioMessage(e));
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

// Shared tracking input worker for RGB-D and depth-only inference.
class BodyTrackingRuntime {
  final BodyTrackingOptions cfg;final RgbdSession rgbd;final BodyFrameProcessor processor;
  final Object lock=new Object();volatile boolean running=false;volatile long runGeneration=0;
  volatile long lastInputMs=0;Thread connectionWorker;long lastSubmitted=-1,lastPairSubmitted=-1;
  BodyTrackingRuntime(BodyTrackingOptions c,RgbdSession s,BodyFrameProcessor p){cfg=c;
    rgbd=s;processor=p;}
  void start(){synchronized(lock){if(running)return;running=true;final long generation=++runGeneration;
      lastInputMs=millis64();lastSubmitted=-1;rgbd.start();processor.start();connectionWorker=studio.services.workers.start(cfg.role+"-Tracking",new Runnable(){
        public void run(){connectionLoop(generation);}});}}
  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;t=connectionWorker;
      connectionWorker=null;}if(t!=null&&t!=Thread.currentThread())t.interrupt();
    processor.requestStop();rgbd.requestStop(true);}
  void stop(boolean keepRgbd){Thread t;synchronized(lock){running=false;++runGeneration;
      t=connectionWorker;connectionWorker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();
      try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();
        }}processor.stop();if(!keepRgbd)rgbd.stop(true);else rgbd.clearConsumerPairs();
    }
  boolean streamsLive(){return rgbd.streamsLive(cfg.streamStaleMs) && (!processor.skeletonSession.cfg.usesRgb() || rgbd.colorStreamLive(cfg.streamStaleMs));}
  void connectionLoop(long generation){while(running&&generation==runGeneration){try{rgbd.updateLiveness();
        if(processor.skeletonSession.cfg.usesRgb()){
          RgbdFramePair pair=rgbd.latestRgbdPairAfter(lastPairSubmitted);
          if(pair!=null&&pair.depth!=null&&pair.rgb!=null){lastPairSubmitted=pair.sequence;lastSubmitted=pair.depth.frameNumber;
            lastInputMs=millis64();processor.submit(new BodyVisionSnapshot(pair.depth,null,pair.rgb,lastInputMs));}
        }else{
          DepthFrame depth=rgbd.latestDepthAfter(lastSubmitted);if(depth!=null){lastSubmitted=depth.frameNumber;
            lastInputMs=millis64();processor.submit(new BodyVisionSnapshot(depth,null,null,lastInputMs));}
        }Thread.sleep(2);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;
        Thread.currentThread().interrupt();return;}catch(Exception e){if(running&&generation==runGeneration)println(cfg.logLabel+" tracking warning: "+safeStudioMessage(e));
        }}}
}

class BodyTrackingSession {
  final BodyTrackingOptions cfg;final RgbdSession rgbd;final SkeletonProcessingSession skeleton;
  final BodyFrameProcessor processor;final BodyTrackingRuntime runtime;
  final CopyOnWriteArrayList<LatestMailbox<BodyFrame>> subscribers=new CopyOnWriteArrayList<LatestMailbox<BodyFrame>>();
  volatile String deviceId;volatile boolean active=false;

  BodyTrackingSession(BodyTrackingOptions cfg,RgbdSession rgbd,SkeletonProcessingSession skeleton,String deviceId){
    if(rgbd==null||skeleton==null)throw new IllegalArgumentException("body tracking dependencies");
    this.cfg=cfg==null?new BodyTrackingOptions():cfg;this.rgbd=rgbd;this.skeleton=skeleton;this.deviceId=deviceId==null?"":deviceId;
    processor=new BodyFrameProcessor(this,this.cfg,skeleton);
    // Select RGB-D for RGB inference and depth-only for metric-depth inference.
    rgbd.setHqColorRequested(false);rgbd.setDepthOnlyRequested(!skeleton.cfg.usesRgb());
    runtime=new BodyTrackingRuntime(this.cfg,rgbd,processor);
  }
  // Tab activation resets inference and selects the configured input stream.
  void activate(){skeleton.reset();rgbd.setHqColorRequested(false);rgbd.setDepthOnlyRequested(!skeleton.cfg.usesRgb());active=true;runtime.start();}
  void requestStop(){active=false;runtime.requestStop();}
  void stop(boolean keepRgbd){active=false;runtime.stop(keepRgbd);}
  void close(){stop(false);for(LatestMailbox<BodyFrame> m:subscribers)m.close();subscribers.clear();}
  boolean usesRgb(){return skeleton.cfg.usesRgb();}
  boolean streamsLive(){return runtime.streamsLive();}
  boolean running(){return runtime.running;}
  BodyProcessedFrame latest(){return processor.latest();}
  void clearPublished(){processor.clearPublished();}
  void clearConsumerPairs(){rgbd.clearConsumerPairs();}
  void reset(){skeleton.reset();}
  String statusReason(){return skeleton.statusReason();}
  long lastInputMs(){return runtime.lastInputMs;}
  void selectDevice(KinectDevice device){rgbd.selectDevice(device,true);skeleton.reset();deviceId=device==null?"":device.registryKey();}
  void requestReconnect(String reason,boolean force){rgbd.requestReconnect(reason,force);}
  boolean hasSubscribers(){return !subscribers.isEmpty();}
  LatestMailbox<BodyFrame> subscribe(String role,java.util.function.Consumer<BodyFrame> consumer){
    LatestMailbox<BodyFrame> box=new LatestMailbox<BodyFrame>(role,consumer);subscribers.add(box);return box;}
  void unsubscribe(LatestMailbox<BodyFrame> box){if(box==null)return;subscribers.remove(box);box.close();}
  void publish(BodyFrame frame){for(LatestMailbox<BodyFrame> box:subscribers){if(!box.offer(frame)&&!box.isOpen())subscribers.remove(box);}}
}

// ---------------------------------------------------------------------------
// Reusable presentation block: metric depth preview + body-centric 3D skeleton
// view shared by Interactivity, Motion Capture and any future Body3D frontend.
interface BodyPreviewOverlay {void draw(BodySkeletonPreview view,SkeletonPose3D s,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch,float x,float y,float w,float h);}

// Pure presentation transform shared by every Body3D frontend.  Tracking stays in
// calibrated Kinect camera space; this frame only decides how that metric body is
// fitted into a rectangular UI viewport.
class BodyViewFrame {
  boolean valid=false;final PVector origin=new PVector();
  float cx,cy,scale,yaw,pitch,x,y,w,h,left,top,right,bottom;
  float metricMinX,metricMaxX,metricMinY,metricMaxY,centerErrorPx=Float.NaN,occupancyX=0,occupancyY=0;
  int measuredPoints=0;
  boolean contains(float sx,float sy,float inset){return valid&&sx>=left+inset&&sx<=right-inset&&sy>=top+inset&&sy<=bottom-inset;}
  boolean segmentMayIntersect(PVector a,PVector b,float inset){
    if(!valid||a==null||b==null)return false;float l=left+inset,r=right-inset,t=top+inset,bt=bottom-inset;
    if(a.x<l&&b.x<l)return false;if(a.x>r&&b.x>r)return false;if(a.y<t&&b.y<t)return false;if(a.y>bt&&b.y>bt)return false;return true;
  }
  PVector clamp(PVector p,float inset){if(p==null)return null;float l=left+inset,r=right-inset,t=top+inset,b=bottom-inset;
    return new PVector(constrain(p.x,l,r),constrain(p.y,t,b),p.z);}
}

class BodySkeletonPreview {
  // Presentation state follows the currently segmented body, not the first hip
  // position ever seen for a tracking id.  The old frozen origin made a valid body
  // walk out of the panel and could survive tab/device restarts when ids restarted.
  PVector bodyViewOrigin=null;long bodyViewTrackingId=Long.MIN_VALUE;int bodyViewLostFrames=0;
  float bodyViewPanX=0,bodyViewPanY=0,bodyViewScale=Float.NaN,bodyViewLastW=-1,bodyViewLastH=-1;
  BodyViewFrame activeView=null;
  // Calibrated at runtime from camera projection so Body3D can never silently
  // inherit the wrong Y convention from a registration backend.
  float bodyViewYSign=-1.0f;
  float fixedHeightM=2.10f,fixedWidthM=2.10f,targetOccupancy=.84f,armOccupancy=.86f,centerYOffsetM=-.03f,referenceDistanceM=1.10f;
  BodySkeletonPreview configure(float fixedH,float fixedW,float targetOcc,float armOcc,float centerY,float refDist){
    fixedHeightM=fixedH;fixedWidthM=fixedW;targetOccupancy=targetOcc;armOccupancy=armOcc;centerYOffsetM=centerY;referenceDistanceM=refDist;return this;}
  void reset(){bodyViewOrigin=null;bodyViewTrackingId=Long.MIN_VALUE;bodyViewLostFrames=0;bodyViewPanX=bodyViewPanY=0;bodyViewScale=Float.NaN;bodyViewLastW=bodyViewLastH=-1;activeView=null;}
  void noteMissing(){bodyViewLostFrames++;activeView=null;if(bodyViewLostFrames>18)reset();}

  void drawDepth(PImage img,String label,String waiting,float x,float y,float w,float h){
    fill(0xFF11151A);rect(x,y,w,h,10);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,true);textAlign(LEFT,TOP);
    text(label,x+10,y+8);
    if(img!=null){
      float[] vr=imageRect(img,x,y,w,h);
      // Presentation uses the sensor-facing image orientation.
      image(img,vr[0],vr[1],vr[2],vr[3]);
    }else{fill(0xFFAAB6C2);textAlign(CENTER,CENTER);studioText(STUDIO_FONT_BODY,false);
      text(ellipsizeToWidth(waiting,w-20),x+w/2,y+h/2);}
    textAlign(LEFT,BASELINE);
  }
  float[] imageRect(PImage img,float x,float y,float w,float h){float sc=min(w/img.width,h/img.height),dw=img.width*sc,dh=img.height*sc;
    return new float[]{x+(w-dw)/2,y+(h-dh)/2,dw,dh};}

  // Computes the exact transform later used for cloud, bones, joints and overlays.
  // Keeping this as a separate method lets the benchmark exercise the same framing
  // code without needing to render pixels.
  BodyViewFrame prepareFrame(SkeletonPose3D s,PointCloud cloud,float x,float y,float w,float h){
    BodyViewFrame out=new BodyViewFrame();out.x=x;out.y=y;out.w=w;out.h=h;out.left=x;out.top=y;out.right=x+w;out.bottom=y+h;
    if(s==null||!s.tracked||bodyAnchor(s)==null||w<8||h<8){activeView=null;return out;}
    bodyViewLostFrames=0;boolean idChanged=bodyViewOrigin==null||(s.trackingId!=0&&s.trackingId!=bodyViewTrackingId);
    boolean resized=bodyViewLastW>0&&(abs(w-bodyViewLastW)>max(18,bodyViewLastW*.12f)||abs(h-bodyViewLastH)>max(18,bodyViewLastH*.12f));
    PVector target=bodyAnchor(s);if(target==null)target=s.hipCenter.world.copy();
    if(idChanged||resized||bodyViewOrigin==null){bodyViewOrigin=target.copy();bodyViewPanX=bodyViewPanY=0;bodyViewScale=Float.NaN;}
    else{
      // Follow the torso quickly enough that normal walking cannot leave the panel,
      // while retaining a little temporal inertia to suppress sub-centimetre jitter.
      bodyViewOrigin=PVector.lerp(bodyViewOrigin,target,.68f);
    }
    bodyViewTrackingId=s.trackingId;bodyViewLastW=w;bodyViewLastH=h;
    float yaw=-0.30f,pitch=.08f;
    float minX=Float.POSITIVE_INFINITY,maxX=Float.NEGATIVE_INFINITY,minY=Float.POSITIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY;int n=0;
    // Base camera framing on stable tracked joints, not on the outermost cloud
    // pixels. Depth speckles and temporary occlusion can otherwise resize the
    // entire viewport even while the person's pose stays stationary. The cloud
    // remains rendered below and is not modified or fed back into tracking.
    if(s!=null){for(SkeletonJoint3D j:s.canonicalJoints())if(j!=null&&j.tracked()&&j.world!=null&&plausibleBodyPoint(j.world,bodyViewOrigin)){
      PVector p=project3DLocal(j.world.x-bodyViewOrigin.x,j.world.y-bodyViewOrigin.y,j.world.z-bodyViewOrigin.z,yaw,pitch);
      minX=min(minX,p.x);maxX=max(maxX,p.x);minY=min(minY,p.y);maxY=max(maxY,p.y);n++;}}
    if(n<2||!Float.isFinite(minX)||!Float.isFinite(maxX)||!Float.isFinite(minY)||!Float.isFinite(maxY)){
      minX=-fixedWidthM*.5f;maxX=fixedWidthM*.5f;minY=-fixedHeightM*.5f;maxY=fixedHeightM*.5f;n=0;
    }
    // A small metric safety margin prevents anti-aliased points/joint nodes from
    // touching the card border.  All genuine segmented points still drive the fit.
    float marginX=.055f,marginY=.075f;minX-=marginX;maxX+=marginX;minY-=marginY;maxY+=marginY;
    float spanX=max(.30f,maxX-minX),spanY=max(.55f,maxY-minY),targetPanX=(minX+maxX)*.5f,targetPanY=(minY+maxY)*.5f;
    if(idChanged||resized||!Float.isFinite(bodyViewScale)){bodyViewPanX=targetPanX;bodyViewPanY=targetPanY;}
    else{bodyViewPanX=followPan(bodyViewPanX,targetPanX);bodyViewPanY=followPan(bodyViewPanY,targetPanY);}
    float fixedH=max(.70f,fixedHeightM),fixedW=max(.55f,fixedWidthM);
    float fixedScale=min((h*targetOccupancy)/fixedH,(w*armOccupancy)/fixedW);
    float innerW=max(4,w-12),innerH=max(4,h-12);float fitScale=min(innerW*.94f/spanX,innerH*.94f/spanY);
    float targetScale=max(4,min(fixedScale,fitScale));
    if(!Float.isFinite(bodyViewScale)||idChanged||resized)bodyViewScale=targetScale;
    else if(targetScale<bodyViewScale)bodyViewScale=targetScale; // shrink immediately: never allow escape
    else bodyViewScale=lerp(bodyViewScale,targetScale,.10f);     // zoom-in slowly: no focus hunting
    bodyViewScale=max(4,min(bodyViewScale,fitScale));
    float cx=x+w*.50f-bodyViewPanX*bodyViewScale;
    float cy=y+h*.50f+bodyViewPanY*bodyViewScale-centerYOffsetM*bodyViewScale;
    out.valid=true;out.origin.set(bodyViewOrigin);out.cx=cx;out.cy=cy;out.scale=bodyViewScale;out.yaw=yaw;out.pitch=pitch;
    out.metricMinX=minX;out.metricMaxX=maxX;out.metricMinY=minY;out.metricMaxY=maxY;out.measuredPoints=n;
    float screenMinX=cx+minX*bodyViewScale,screenMaxX=cx+maxX*bodyViewScale;
    float screenTop=cy-maxY*bodyViewScale,screenBottom=cy-minY*bodyViewScale;
    out.centerErrorPx=dist((screenMinX+screenMaxX)*.5f,(screenTop+screenBottom)*.5f,x+w*.5f,y+h*.5f);
    out.occupancyX=(screenMaxX-screenMinX)/max(1,w);out.occupancyY=(screenBottom-screenTop)/max(1,h);
    activeView=out;return out;
  }
  float followPan(float current,float target){float d=target-current;if(abs(d)<.010f)return current;return lerp(current,target,.42f);}
  PVector bodyAnchor(SkeletonPose3D s){if(s==null)return null;PVector c=new PVector();float sum=0;
    sum=addAnchor(c,sum,s.spine,4.0f);sum=addAnchor(c,sum,s.hipCenter,3.0f);sum=addAnchor(c,sum,s.shoulderCenter,3.0f);
    sum=addAnchor(c,sum,s.leftHip,1.0f);sum=addAnchor(c,sum,s.rightHip,1.0f);sum=addAnchor(c,sum,s.leftShoulder,1.0f);sum=addAnchor(c,sum,s.rightShoulder,1.0f);
    return sum>0?c.div(sum):null;}
  float addAnchor(PVector c,float sum,SkeletonJoint3D j,float weight){if(j==null||!j.tracked()||j.world==null||!Float.isFinite(j.world.x)||!Float.isFinite(j.world.y)||!Float.isFinite(j.world.z))return sum;c.add(PVector.mult(j.world,weight));return sum+weight;}
  boolean plausibleBodyPoint(PVector q,PVector origin){if(q==null||origin==null||!Float.isFinite(q.x)||!Float.isFinite(q.y)||!Float.isFinite(q.z)||q.z<=0)return false;
    return abs(q.x-origin.x)<=1.35f&&abs(q.y-origin.y)<=1.45f&&abs(q.z-origin.z)<=1.20f;}

  void draw(SkeletonPose3D s,PointCloud cloud,ModuleI18n i18n,float x,float y,float w,float h,BodyPreviewOverlay overlay){
    fill(0xFF0B1117);rect(x,y,w,h,10);pushStyle();clip(x,y,w,h);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,TOP);text("3D",x+10,y+8);
    BodyViewFrame vf=prepareFrame(s,cloud,x,y,w,h);
    if(!vf.valid){noteMissing();fill(0xFF81909D);textAlign(CENTER,CENTER);studioText(STUDIO_FONT_SMALL,false);text("Waiting for a tracked 3D skeleton",x+w*.5f,y+h*.5f);noClip();popStyle();return;}
    SkeletonJoint3D root=new SkeletonJoint3D("viewport_anchor");root.world.set(vf.origin);root.confidence=1.0f;root.state=SkeletonJoint3D.TRACKED;
    float yaw=vf.yaw,pitch=vf.pitch,scale=vf.scale,cx=vf.cx,cy=vf.cy;
    // Full-FOV metric point cloud and skeleton share one body-centric metric frame.
    drawPointCloud3D(cloud,root,cx,cy,scale,yaw,pitch);
    // Ground/depth guides remain useful after re-centering because absolute Z is
    // still published by the ruler and all downstream BodyFrame consumers.
    stroke(0xFF263541);strokeWeight(1);for(int k=-2;k<=2;k++){float gx=k*.25f;PVector a=project3DPoint(gx,.72f,-.55f,cx,cy,scale,yaw,pitch);PVector b=project3DPoint(gx,.72f,.55f,cx,cy,scale,yaw,pitch);safeLine(a,b);}
    for(int k=-2;k<=2;k++){float gz=k*.25f;PVector a=project3DPoint(-.55f,.72f,gz,cx,cy,scale,yaw,pitch);PVector b=project3DPoint(.55f,.72f,gz,cx,cy,scale,yaw,pitch);safeLine(a,b);}
    drawBodyBones3D(s,root,cx,cy,scale,yaw,pitch,0xFF101820,max(5.0f,7.0f*studioUiScale()));
    drawBodyBones3D(s,root,cx,cy,scale,yaw,pitch,0xFF58C7F3,max(2.0f,3.2f*studioUiScale()));
    for(SkeletonJoint3D j:bodyJoints(s))jointNode3D(j,root,cx,cy,scale,yaw,pitch);
    if(s.head.tracked())jointNode3D(s.head,root,cx,cy,scale,yaw,pitch);
    drawDetailedHand3D(s.leftHandDetail,root,cx,cy,scale,yaw,pitch);drawDetailedHand3D(s.rightHandDetail,root,cx,cy,scale,yaw,pitch);
    if(overlay!=null)overlay.draw(this,s,root,cx,cy,scale,yaw,pitch,x,y,w,h);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,false);textAlign(RIGHT,TOP);text(String.format(Locale.US,"Z %.2f m",s.meanDepthM),x+w-10,y+8);
    textAlign(LEFT,TOP);text((i18n==null?s.posture:i18n.tr("posture."+s.posture))+"  "+round(s.postureConfidence*100)+"%",x+10,y+24);
    float rx=x+w-16,top=y+34,bottom=y+h-18;stroke(0xFF435563);line(rx,top,rx,bottom);
    float refZn=constrain((referenceDistanceM-.5f)/3.5f,0,1),refRy=lerp(top,bottom,refZn);stroke(0xFF5B7180);line(rx-6,refRy,rx+6,refRy);
    float zn=constrain((s.meanDepthM-.5f)/3.5f,0,1),ry=lerp(top,bottom,zn);noStroke();fill(0xFFFFB54A);ellipse(rx,ry,8,8);
    noClip();popStyle();activeView=null;textAlign(LEFT,BASELINE);
  }
  PVector project3DLocal(float lx,float ly,float lz,float yaw,float pitch){float dx=-lx,dy=bodyViewYSign*ly,dz=lz,c=cos(yaw),sn=sin(yaw),x1=dx*c-dz*sn,z1=dx*sn+dz*c;
    float cp=cos(pitch),sp=sin(pitch),y1=dy*cp-z1*sp,z2=dy*sp+z1*cp;return new PVector(x1,y1,z2);}
  PVector project3DPoint(float lx,float ly,float lz,float cx,float cy,float sc,float yaw,float pitch){PVector p=project3DLocal(lx,ly,lz,yaw,pitch);return new PVector(cx+p.x*sc,cy-p.y*sc,p.z);}
  PVector project3DJoint(SkeletonJoint3D j,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){return project3DPoint(j.world.x-root.world.x,j.world.y-root.world.y,j.world.z-root.world.z,cx,cy,sc,yaw,pitch);}
  PVector clampToViewport(PVector p,float inset){return activeView==null?p:activeView.clamp(p,inset);}
  boolean insideViewport(PVector p,float inset){return activeView==null||activeView.contains(p.x,p.y,inset);}
  void safeLine(PVector a,PVector b){if(a==null||b==null)return;if(activeView==null||activeView.segmentMayIntersect(a,b,1))line(a.x,a.y,b.x,b.y);}

  void drawDetailedHand3D(SkeletonHand3D hand,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){if(hand==null||root==null||!root.tracked()||!hand.handTracked())return;int[][] bones={{0,1},{1,2},{2,3},{3,4},{0,5},{5,6},{6,7},{7,8},{0,9},{9,10},{10,11},{11,12},{0,13},{13,14},{14,15},{15,16},{0,17},{17,18},{18,19},{19,20}};stroke(0xFFFFB54A);strokeWeight(max(1.2f,1.8f*studioUiScale()));for(int[] b:bones){SkeletonJoint3D a=hand.landmarks[b[0]],c=hand.landmarks[b[1]];if(a.tracked()&&c.tracked()&&PVector.dist(a.world,c.world)<=.16f){PVector pa=project3DJoint(a,root,cx,cy,sc,yaw,pitch),pc=project3DJoint(c,root,cx,cy,sc,yaw,pitch);safeLine(pa,pc);}}noStroke();fill(0xFFFFB54A);for(SkeletonJoint3D j:hand.landmarks)if(j.tracked()&&(!hand.palm.tracked()||PVector.dist(j.world,hand.palm.world)<=.24f)){PVector p=project3DJoint(j,root,cx,cy,sc,yaw,pitch);if(insideViewport(p,2))ellipse(p.x,p.y,max(3,4*studioUiScale()),max(3,4*studioUiScale()));}}
  void drawPointCloud3D(PointCloud cloud,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){
    if(cloud==null||cloud.points==null||root==null||!root.tracked())return;stroke(0xFF58C7F3,92);strokeWeight(max(1.0f,1.45f*studioUiScale()));
    int stride=max(1,cloud.points.size()/9000);for(int i=0;i<cloud.points.size();i+=stride){PVector q=cloud.points.get(i);if(q==null||!plausibleBodyPoint(q,root.world))continue;
      PVector p=project3DPoint(q.x-root.world.x,q.y-root.world.y,q.z-root.world.z,cx,cy,sc,yaw,pitch);if(insideViewport(p,1))point(p.x,p.y);}
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
    float metric=PVector.dist(a.world,b.world);if(!Float.isFinite(metric)||metric>.82f)return;
    PVector pa=project3DJoint(a,root,cx,cy,sc,yaw,pitch),pb=project3DJoint(b,root,cx,cy,sc,yaw,pitch);safeLine(pa,pb);}
  void jointNode3D(SkeletonJoint3D j,SkeletonJoint3D root,float cx,float cy,float sc,float yaw,float pitch){if(j==null||!j.tracked())return;PVector p=project3DJoint(j,root,cx,cy,sc,yaw,pitch);if(!insideViewport(p,2))return;
    float d=(j.state==2?8:6)*studioUiScale(),depthScale=constrain(1.0f-p.z*.18f,.72f,1.28f);noStroke();fill(j.state==2?0xFFFFB54A:0xFF9AA9B5,j.state==2?245:155);ellipse(p.x,p.y,d*depthScale,d*depthScale);}
  boolean renderLowerLegs(SkeletonPose3D s){return s!=null&&((s.leftKnee!=null&&s.leftKnee.tracked()&&s.leftAnkle!=null&&s.leftAnkle.tracked())||(s.rightKnee!=null&&s.rightKnee.tracked()&&s.rightAnkle!=null&&s.rightAnkle.tracked()));}
  boolean renderKnees(SkeletonPose3D s){return s!=null&&((s.leftKnee!=null&&s.leftKnee.tracked())||(s.rightKnee!=null&&s.rightKnee.tracked()));}
  SkeletonJoint3D[] bodyJoints(SkeletonPose3D s){ArrayList<SkeletonJoint3D> j=new ArrayList<SkeletonJoint3D>();Collections.addAll(j,s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,s.leftElbow,
      s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip);if(renderKnees(s))Collections.addAll(j,s.leftKnee,s.rightKnee);
    if(renderLowerLegs(s))Collections.addAll(j,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot);return j.toArray(new SkeletonJoint3D[j.size()]);}
}
