// ===== SynKinect Studio / 3D Scanner / HighQualityReconstruction.pde =====
class HighQualityKeyframe {
  final DepthFrame depth;
  final byte[] colorData;final int colorWidth,colorHeight,colorPixelFormat;final float colorQuality;

  final long rgbFrameNumber,rgbTimestampUs,rawSkewUs,residualUs;
  final RigidTransform initialPose;
  final float targetDepthM,bandM,sweepDeg,signedAngleDeg;
  final PVector turntablePivotWorld,turntableAxisWorld;

  HighQualityKeyframe(RgbdFramePair pair,RawRgbFrame preferredColor,RigidTransform pose,float targetDepthM,float bandM,float sweepDeg,float signedAngleDeg,PVector turntablePivotWorld,PVector turntableAxisWorld,AppConfig cfg){
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
    this.targetDepthM=targetDepthM;this.bandM=bandM;this.sweepDeg=sweepDeg;this.signedAngleDeg=signedAngleDeg;
    this.turntablePivotWorld=turntablePivotWorld==null?null:turntablePivotWorld.copy();
    this.turntableAxisWorld=turntableAxisWorld==null?null:turntableAxisWorld.copy();
    if(this.turntableAxisWorld!=null&&this.turntableAxisWorld.magSq()>1e-7f)this.turntableAxisWorld.normalize();
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

  synchronized boolean wouldOffer(RigidTransform pose,float sweepDeg){
    if(pose==null||frames.size()>=cfg.hqMaxKeyframes)return false;
    if(frames.isEmpty())return true;
    HighQualityKeyframe last=frames.get(frames.size()-1);
    float rot=rotationDeltaDeg(last.initialPose,pose),trans=translationDelta(last.initialPose,pose),sweepDelta=abs(sweepDeg-last.sweepDeg);
    if(!scannerFusionMode()){
      // Reserve enough archive capacity for the complete 360 degrees. A small
      // keyframe angle plus a hard max used to fill the archive before the last
      // quarter turn, producing missing sectors and a layered seam at closure.
      float budgetDeg=cfg.scanFullTurnDeg/max(24.0f,cfg.hqMaxKeyframes-10.0f);
      float minSweep=max(cfg.hqKeyframeMinRotationDeg,budgetDeg);
      return sweepDelta>=minSweep||(trans>=cfg.hqKeyframeMinTranslationM&&sweepDelta>=minSweep*.55f);
    }
    return rot>=cfg.hqKeyframeMinRotationDeg||trans>=cfg.hqKeyframeMinTranslationM;
  }

  synchronized boolean offer(RgbdFramePair pair,RawRgbFrame preferredColor,RigidTransform pose,float targetDepthM,float bandM,float sweepDeg,float signedAngleDeg,PVector turntablePivotWorld,PVector turntableAxisWorld){
    if(pair==null||pair.depth==null||pose==null||!wouldOffer(pose,sweepDeg))return false;
    frames.add(new HighQualityKeyframe(pair,preferredColor,pose,targetDepthM,bandM,sweepDeg,signedAngleDeg,turntablePivotWorld,turntableAxisWorld,cfg));
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
  ArrayList<PointCloud> clouds;
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
  final RgbDepthRegistration registration;final RobustIcpRefiner refiner;final MultiFrameDepthSuperResolver superResolver;final ScannerFullQualityEngine fullQualityCore;

  int[] rgbPixels;ColorReference colorReference;DepthSuperResolutionStats lastSuperResolutionStats=null;

  HighQualityReconstructor(AppConfig cfg,Calibration calibration,PointCloudBuilder builder,RgbDepthRegistration registration){this.cfg=cfg;
    this.calibration=calibration;this.builder=builder;this.registration=registration;
    this.refiner=new RobustIcpRefiner(cfg);this.superResolver=new MultiFrameDepthSuperResolver(cfg,calibration,builder,registration);
    this.fullQualityCore=new ScannerFullQualityEngine(cfg,calibration,registration,this);
    }

  Mesh3D reconstruct(ArrayList<HighQualityKeyframe> frames){return reconstruct(frames,true);}

  Mesh3D reconstruct(ArrayList<HighQualityKeyframe> frames,boolean highQuality){
    if(frames==null||frames.size()<cfg.hqMinimumKeyframes)return null;
    int finalizeLimit=highQuality?cfg.hqFinalizeMaxKeyframes:min(cfg.hqFinalizeMaxKeyframes,max(cfg.hqMinimumKeyframes,72));
    frames=selectFinalizeFrames(frames,finalizeLimit);
    HqProgressTracker tracker=scannerState().hqTracker;final long token=tracker.begin();
    scannerState().hqBusy=true;scannerState().hqProgress=0;
    try{
      // The imported v1.0 FULL QUALITY core is authoritative for an offline HQ
      // rebuild: organized point-to-plane ICP, robust SE(3) pose graph and the
      // sparse normal-oriented Surface-SDF. The lower-cost TSDF path below is
      // also offline and is used only when Build Mesh is explicitly requested.
      if(highQuality){
        scannerState().hqTracker.set(scannerState().hqTracker.PREPARE,0);
        return fullQualityCore.reconstruct(frames,scannerFusionMode());
      }
      return reconstructQuickMesh(frames,tracker);
    }finally{
      // Only the task that owns the tracker may clear the busy flag: a cancelled
      // run that finishes late must not hide a newer run's progress.
      if(token==tracker.token){scannerState().hqBusy=false;tracker.end(token);}
    }
  }


  Mesh3D reconstructQuickMesh(ArrayList<HighQualityKeyframe> frames,HqProgressTracker tracker){
    GlobalPoseRecoveryResult quick=recoverQuickPoses(frames);if(Thread.currentThread().isInterrupted())return null;
    if(quick==null||quick.acceptedCount()<max(3,min(cfg.hqMinimumKeyframes,frames.size())/2))return null;
    tracker.set(tracker.FUSE,0);
    ArrayList<RigidTransform> poses=quick.poses;

    colorReference=cfg.rgbPhotometricNormalize?ColorReference.fromFrames(frames):null;
    int volumeSize=max(cfg.volumeSize,160);
    float voxelSize=cfg.voxelSizeM;
    float truncation=max(cfg.truncationM,voxelSize*3.0f);
    int meshWeight=cfg.meshMinWeight;
    TSDFVolume volume=new TSDFVolume(volumeSize,voxelSize,truncation,cfg.rgbTemporalColorWeightMax);volume.setProjection(calibration,cfg);

    boolean initialized=false;ArrayList<Integer> anchors=allIntegrationAnchors(frames.size());
    int integrated=0;
    for(int ai=0;ai<anchors.size();ai++){
      int i=anchors.get(ai);if(i<0||i>=quick.accepted.length||!quick.accepted[i])continue;
      HighQualityKeyframe k=frames.get(i);PointCloud cloud=(quick.clouds!=null&&i<quick.clouds.size())?quick.clouds.get(i):null;
      if(cloud==null){RgbSnapshot rgb=rgbSnapshot(k);cloud=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,rgb);}
      if(scannerState().boundingBox!=null&&!scannerFusionMode()){
        cloud=scannerState().boundingBox.filter(cloud,false);
        cloud=scannerState().boundingBox.filterWorld(cloud,poses.get(i));
      }
      if(cloud==null||cloud.size()<cfg.minimumTrackingPoints)continue;
      if(!initialized){volume.resetAround(cloud.centroidTransformed(poses.get(i)));initialized=true;}
      float health=constrain(keyframeHealthScore(k),0,1);
      float support=Float.isFinite(quick.support[i])?constrain(quick.support[i],0,1):0.55f;
      float rms=quick.rms[i];float rmsQ=Float.isFinite(rms)?constrain(1.0f-rms/max(cfg.hqGlobalRecoveryMaxRmsM,0.001f),0,1):0.5f;
      float poseWeight=i==0?1.0f:constrain(0.16f+0.84f*(0.45f*health+0.35f*support+0.20f*rmsQ),0.08f,1.0f);
      volume.integrate(cloud,poses.get(i),1,true,poseWeight,0.05f,1.0f);integrated++;
      tracker.set(tracker.FUSE,(ai+1)/(float)max(1,anchors.size()));
      Thread.yield();
      if(Thread.currentThread().isInterrupted())return null;
    }
    if(!initialized||integrated<3)return null;
    tracker.set(tracker.MESH,0);
    Mesh3D raw=volume.extractMesh(meshWeight);if(raw==null||raw.triangleCount()==0)return null;
    tracker.set(tracker.MESH,0.45f);
    Mesh3D result=scannerState().meshEditor.prepareGeneratedMesh(raw);
    tracker.set(tracker.MESH,1);return result;
  }

  GlobalPoseRecoveryResult recoverQuickPoses(ArrayList<HighQualityKeyframe> frames){
    int n=frames.size();GlobalPoseRecoveryResult result=new GlobalPoseRecoveryResult(n);
    ArrayList<PointCloud> clouds=new ArrayList<PointCloud>(n);result.clouds=clouds;
    for(int i=0;i<n;i++){
      HighQualityKeyframe k=frames.get(i);PointCloud c=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,rgbSnapshot(k));
      if(scannerState().boundingBox!=null&&!scannerFusionMode())c=scannerState().boundingBox.filter(c,false);
      clouds.add(c);scannerState().hqTracker.set(scannerState().hqTracker.PREPARE,(i+1)/(float)max(1,n));
      if((i&3)==0)Thread.yield();if(Thread.currentThread().isInterrupted())return result;
    }
    return scannerFusionMode()?recoverQuickFusion(frames,clouds,result):recoverQuickTurntable(frames,clouds,result);
  }

  GlobalPoseRecoveryResult recoverQuickTurntable(ArrayList<HighQualityKeyframe> frames,ArrayList<PointCloud> clouds,GlobalPoseRecoveryResult result){
    int n=frames.size();RigidTransform anchor=new RigidTransform();anchor.set(frames.get(0).initialPose);
    PVector pivot=estimateRecoveryPivot(frames,clouds),axis=estimateRecoveryAxis(frames);float baseAngle=frames.get(0).signedAngleDeg;
    float localTranslation=max(0.012f,min(0.035f,cfg.turntableConstraintTranslationM*1.35f));
    for(int i=0;i<n;i++){
      HighQualityKeyframe k=frames.get(i);PointCloud current=clouds.get(i);float yaw=k.signedAngleDeg-baseAngle;
      RigidTransform canonical=rotationAroundPivotAxis(pivot,axis,yaw).multiply(anchor),pose=new RigidTransform();pose.set(canonical);
      boolean usable=current!=null&&current.size()>=cfg.hqIcpMinimumMatches;float support=usable?1.0f:0.0f,rms=usable?0.0f:Float.POSITIVE_INFINITY;
      if(i>0&&usable){
        PointCloud reference=recoveryReference(i,clouds,result.poses,result.accepted,min(2,cfg.hqGlobalRecoveryNeighborFrames));
        if(reference.size()>=cfg.hqIcpMinimumMatches){
          RobustIcpResult refined=refiner.refine(current,reference,canonical,max(0.032f,cfg.hqGlobalRecoveryFineDistanceM),max(6,cfg.hqIcpIterations-4),cfg.hqGlobalRecoveryMaxRmsM*1.45f);
          if(refined!=null&&refined.matches>=cfg.hqIcpMinimumMatches){
            // Preserve the platform's measured angular phase, but allow a small
            // robust XYZ correction. This lets torso sway/respiration/clothing
            // deformation align without letting changing limbs drag the global
            // turntable axis into a spiral or a second shell.
            float dx=refined.pose.m[3]-canonical.m[3],dy=refined.pose.m[7]-canonical.m[7],dz=refined.pose.m[11]-canonical.m[11];float d=sqrt(dx*dx+dy*dy+dz*dz);
            if(d>localTranslation&&d>1e-7f){float q=localTranslation/d;dx*=q;dy*=q;dz*=q;}
            pose.m[3]+=dx;pose.m[7]+=dy;pose.m[11]+=dz;
            PoseSupport ps=evaluatePoseSupport(current,reference,pose,max(0.032f,cfg.hqGlobalRecoveryFineDistanceM));support=ps.support;rms=ps.rms;
            usable=ps.samples>=cfg.hqIcpMinimumMatches&&ps.support>=max(0.18f,cfg.hqGlobalRecoveryMinSupport*.65f)&&ps.rms<=cfg.hqGlobalRecoveryMaxRmsM*1.50f;
          }
        }
      }
      result.poses.add(pose);result.accepted[i]=usable;result.support[i]=support;result.rms[i]=rms;
      scannerState().hqTracker.set(scannerState().hqTracker.ALIGN,(i+1)/(float)max(1,n));
      if((i&3)==0)Thread.yield();if(Thread.currentThread().isInterrupted())return result;
    }
    int first=firstAccepted(result.accepted),last=lastAccepted(result.accepted);
    if(first>=0&&last>first&&abs(frames.get(last).sweepDeg-frames.get(first).sweepDeg)>=cfg.scanCompleteDeg){
      float closure=rotationDeltaAroundAxisDeg(result.poses.get(last),result.poses.get(first),axis);
      // Only phase is distributed. Local per-frame deformation offsets are kept.
      applyDistributedTurntableYawAccepted(result.poses,result.accepted,pivot,axis,closure,first,last);
    }
    for(int i=0;i<n;i++)scannerState().hqTracker.set(scannerState().hqTracker.CONSENSUS,(i+1)/(float)max(1,n));
    return result;
  }

  GlobalPoseRecoveryResult recoverQuickFusion(ArrayList<HighQualityKeyframe> frames,ArrayList<PointCloud> clouds,GlobalPoseRecoveryResult result){
    int n=frames.size();PVector anchorCenter=null;
    for(int i=0;i<n;i++){
      PointCloud current=clouds.get(i);boolean usable=current!=null&&current.size()>=cfg.hqIcpMinimumMatches;RigidTransform pose=new RigidTransform();pose.set(frames.get(i).initialPose);
      float support=0.0f,rms=Float.POSITIVE_INFINITY;
      if(i==0){
        if(usable){anchorCenter=current.centroidTransformed(pose);support=1.0f;rms=0.0f;}
        result.accepted[i]=usable;
      }else if(usable){
        PointCloud reference=recoveryReference(i,clouds,result.poses,result.accepted,min(2,cfg.hqGlobalRecoveryNeighborFrames));
        if(reference.size()>=cfg.hqIcpMinimumMatches){
          RobustIcpResult refined=refiner.refine(current,reference,pose,max(cfg.hqGlobalRecoveryFineDistanceM,cfg.hqVoxelSizeM*3.0f),max(6,cfg.hqIcpIterations-3),cfg.hqGlobalRecoveryMaxRmsM*1.35f);
          if(refined!=null&&refined.matches>=cfg.hqIcpMinimumMatches&&recoveryPoseWithinGuard(frames.get(i).initialPose,refined.pose))pose.set(refined.pose);
          PoseSupport q=evaluatePoseSupport(current,reference,pose,max(cfg.hqGlobalRecoveryFineDistanceM,cfg.hqVoxelSizeM*3.0f));support=q.support;rms=q.rms;
          result.accepted[i]=q.samples>=cfg.hqIcpMinimumMatches&&q.support>=max(0.18f,cfg.hqGlobalRecoveryMinSupport*.72f)&&q.rms<=cfg.hqGlobalRecoveryMaxRmsM*1.35f;
        }else{result.accepted[i]=true;support=0.35f;rms=max(cfg.hqGlobalRecoveryFineDistanceM,cfg.hqVoxelSizeM*3.0f);}
        if(anchorCenter==null)anchorCenter=current.centroidTransformed(pose);
        if(anchorCenter!=null){
          PVector center=current.centroidTransformed(pose);if(center!=null){
            PVector delta=PVector.sub(anchorCenter,center);float drift=delta.mag();
            if(Float.isFinite(drift)&&drift<=0.08f){float alpha=drift<=0.012f?1.0f:0.78f;pose.m[3]+=delta.x*alpha;pose.m[7]+=delta.y*alpha;pose.m[11]+=delta.z*alpha;}
          }
        }
      }else result.accepted[i]=false;
      result.poses.add(pose);result.support[i]=support;result.rms[i]=rms;
      scannerState().hqTracker.set(scannerState().hqTracker.ALIGN,(i+1)/(float)max(1,n));
      if((i&3)==0)Thread.yield();if(Thread.currentThread().isInterrupted())return result;
    }
    for(int i=0;i<n;i++)scannerState().hqTracker.set(scannerState().hqTracker.CONSENSUS,(i+1)/(float)max(1,n));
    return result;
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
      int center=round(target),radius=max(2,ceil(n/(float)keep));
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
    result.clouds=clouds;
    for(int i=0;i<n;i++){
      HighQualityKeyframe k=frames.get(i);PointCloud c=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,rgbSnapshot(k));
      if(scannerState().boundingBox!=null&&!scannerFusionMode())c=scannerState().boundingBox.filter(c,false);clouds.add(c);
      scannerState().hqTracker.set(scannerState().hqTracker.PREPARE,(i+1)/(float)max(1,n));
      if((i&3)==0)Thread.yield();
      if(Thread.currentThread().isInterrupted())return result;
    }

    RigidTransform anchor=new RigidTransform();anchor.set(frames.get(0).initialPose);
    PVector pivot=estimateRecoveryPivot(frames,clouds);
    PVector turntableAxis=estimateRecoveryAxis(frames);
    float baseAngle=frames.get(0).signedAngleDeg;
    // The axial (1-DoF) prior is used only when the realtime tracker actually
    // calibrated the physical pivot. With the default free 6-DoF tracking the
    // realtime frame-to-model poses are the best available estimate; replacing
    // them with seeds built around a guessed pivot would degrade the result.
    boolean axial=!scannerFusionMode()&&hasCalibratedPivot(frames);
    ArrayList<RigidTransform> canonical=new ArrayList<RigidTransform>(n);
    for(int i=0;i<n;i++){
      // The realtime tracker stores a signed cumulative turn angle. Reuse that
      // exact coordinate in HQ instead of re-inferring the turn direction from
      // pose matrices. The pivot rotation is a WORLD transform and therefore
      // left-multiplies the anchor, matching rotateAroundPivotY() in realtime.
      float yaw=frames.get(i).signedAngleDeg-baseAngle;
      RigidTransform seed;
      if(axial)seed=rotationAroundPivotAxis(pivot,turntableAxis,yaw).multiply(anchor);
      else{seed=new RigidTransform();seed.set(frames.get(i).initialPose);}
      canonical.add(seed);
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
          // Once a pose is already comfortably below the good-RMS threshold,
          // repeating the same expensive neighborhood ICP on every later pass adds
          // little value. Keep hard frames in the loop and skip converged ones.
          if(pass>0&&result.accepted[i]&&Float.isFinite(result.rms[i])&&result.rms[i]<=cfg.hqIcpGoodRmsM*0.72f){
            scannerState().hqTracker.set(scannerState().hqTracker.ALIGN,(pass*n+max(0,backward?(n-1-i):i))/(float)max(1,passes*n));
            continue;
          }
          PointCloud reference=recoveryReference(i,clouds,result.poses,result.accepted,cfg.hqGlobalRecoveryNeighborFrames);
          if(reference.size()<cfg.hqIcpMinimumMatches)continue;
          RigidTransform current=result.poses.get(i),seed=canonical.get(i),raw=frames.get(i).initialPose;
          RobustIcpResult best=bestRecoveryCandidate(clouds.get(i),reference,current,seed,raw,maxDistance,pass==0);
          if(best!=null&&recoveryPoseWithinGuard(seed,best.pose)){
            result.poses.get(i).set(best.pose);result.rms[i]=best.rms;result.accepted[i]=true;
          }
          scannerState().hqTracker.set(scannerState().hqTracker.ALIGN,(pass*n+max(0,backward?(n-1-i):i))/(float)max(1,passes*n));
          if((i&3)==0)Thread.yield();
          if(Thread.currentThread().isInterrupted())return result;
        }
      }

      // Consensus validation is intentionally separate from optimization. A bad
      // realtime pose may be corrected by the global pass, but a keyframe that
      // still disagrees with its neighbors must never be fused into the final TSDF.
      boolean[] provisional=Arrays.copyOf(result.accepted,result.accepted.length);
      for(int i=0;i<n;i++){
        scannerState().hqTracker.set(scannerState().hqTracker.CONSENSUS,i/(float)max(1,n));
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
      if(cfg.hqTurntableConsensus&&axial)regularizeTurntablePoses(frames,canonical,result,pivot,turntableAxis);
    }else{
      for(int i=0;i<n;i++){result.poses.get(i).set(frames.get(i).initialPose);result.accepted[i]=true;}
    }

    if(cfg.hqLoopClosure&&n>=cfg.hqMinimumKeyframes){
      int first=firstAccepted(result.accepted),last=lastAccepted(result.accepted);
      if(first>=0&&last>first&&abs(frames.get(last).sweepDeg-frames.get(first).sweepDeg)>=cfg.scanCompleteDeg){
        PointCloud firstWorld=clouds.get(first).transformed(result.poses.get(first),cfg.hqIcpMaxSamples);
        RobustIcpResult closure=refiner.refine(clouds.get(last),firstWorld,result.poses.get(last),cfg.hqGlobalRecoveryCoarseDistanceM,
          max(cfg.hqIcpIterations,16),cfg.hqLoopClosureMaxRmsM);
        if(closure.good&&closure.rms<=cfg.hqLoopClosureMaxRmsM){
          if(axial){
            float yawCorrection=rotationDeltaAroundAxisDeg(result.poses.get(last),closure.pose,turntableAxis);
            applyDistributedTurntableYawAccepted(result.poses,result.accepted,pivot,turntableAxis,yawCorrection,first,last);
          }else{
            // Free 6-DoF trajectory: spread the full rigid loop correction.
            RigidTransform correction=closure.pose.multiply(result.poses.get(last).inverseRigid());
            applyDistributedCorrectionAccepted(result.poses,result.accepted,correction,first,last);
          }}
      }
    }
    scannerState().hqTracker.set(scannerState().hqTracker.CONSENSUS,1);return result;
  }

  void regularizeTurntablePoses(ArrayList<HighQualityKeyframe> frames,ArrayList<RigidTransform> canonical,GlobalPoseRecoveryResult result,PVector pivot,PVector axis){
    for(int i=0;i<result.poses.size();i++){if(!result.accepted[i])continue;
      RigidTransform base=canonical.get(i),refined=result.poses.get(i);
      float support=constrain(result.support[i],0,1);
      float rms=result.rms[i];float rmsQ=Float.isFinite(rms)?constrain(1.0f-rms/max(cfg.hqGlobalRecoveryMaxRmsM,0.001f),0,1):0;
      float evidence=0.65f*support+0.35f*rmsQ;
      // HQ ICP is allowed to refine only the angular phase around the physical
      // turntable axis. XYZ/pitch/roll residuals are discarded so offline refine
      // cannot recreate the vertical spiral removed from realtime capture.
      float keep=constrain((1.0f-cfg.hqTurntableAxisAuthority)+cfg.hqTurntableAxisAuthority*evidence,0.08f,1.0f);
      if(frames.get(i).depth.transportRecovered)keep*=cfg.hqTurntableRecoveredFramePenalty;
      float yawResidual=rotationDeltaAroundAxisDeg(base,refined,axis);
      result.poses.set(i,rotationAroundPivotAxis(pivot,axis,yawResidual*keep).multiply(base));
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

  boolean hasCalibratedPivot(ArrayList<HighQualityKeyframe> frames){
    if(frames==null)return false;int n=0;for(HighQualityKeyframe k:frames)if(k!=null&&k.turntablePivotWorld!=null)n++;
    return n>=max(3,frames.size()/2);
  }
  PVector estimateRecoveryPivot(ArrayList<HighQualityKeyframe> frames,ArrayList<PointCloud> clouds){
    ArrayList<Float> xs=new ArrayList<Float>(),ys=new ArrayList<Float>(),zs=new ArrayList<Float>();
    // Prefer the pivot learned online by the turntable tracker. It is already in
    // world coordinates and directly represents the physical rotation axis.
    for(HighQualityKeyframe k:frames)if(k!=null&&k.turntablePivotWorld!=null){PVector p=k.turntablePivotWorld;xs.add(p.x);ys.add(p.y);zs.add(p.z);}
    // Fallback for archives without a learned pivot: transform each cloud center
    // into the common world frame before taking the robust median. Using local
    // cloud coordinates here would shift the HQ axis when the object is off-center.
    if(xs.isEmpty())for(int i=0;i<clouds.size()&&i<frames.size();i++){PointCloud c=clouds.get(i);if(c==null||c.size()<cfg.hqIcpMinimumMatches)continue;
      PVector p=c.centroidTransformed(frames.get(i).initialPose);xs.add(p.x);ys.add(p.y);zs.add(p.z);}
    if(xs.isEmpty())return new PVector();Collections.sort(xs);Collections.sort(ys);Collections.sort(zs);int m=xs.size()/2;
    return new PVector(xs.get(m),ys.get(m),zs.get(m));
  }

  PVector estimateRecoveryAxis(ArrayList<HighQualityKeyframe> frames){
    PVector sum=new PVector();int n=0;
    for(HighQualityKeyframe k:frames)if(k!=null&&k.turntableAxisWorld!=null&&k.turntableAxisWorld.magSq()>1e-7f){
      PVector a=k.turntableAxisWorld.copy();a.normalize();if(n>0&&sum.dot(a)<0)a.mult(-1);sum.add(a);n++;}
    if(n==0||sum.magSq()<1e-7f)return new PVector(0,1,0);sum.normalize();return sum;
  }
  RigidTransform rotationAroundPivotAxis(PVector pivot,PVector axis,float deg){
    PVector a=axis==null?new PVector(0,1,0):axis.copy();if(a.magSq()<1e-7f)a.set(0,1,0);a.normalize();
    float angle=radians(deg),x=a.x,y=a.y,z=a.z,c=cos(angle),ss=sin(angle),t=1-c;RigidTransform r=new RigidTransform();
    r.m[0]=t*x*x+c;r.m[1]=t*x*y-ss*z;r.m[2]=t*x*z+ss*y;
    r.m[4]=t*x*y+ss*z;r.m[5]=t*y*y+c;r.m[6]=t*y*z-ss*x;
    r.m[8]=t*x*z-ss*y;r.m[9]=t*y*z+ss*x;r.m[10]=t*z*z+c;
    PVector p=pivot==null?new PVector():pivot,rc=r.rotate(p);r.m[3]=p.x-rc.x;r.m[7]=p.y-rc.y;r.m[11]=p.z-rc.z;return r;
  }
  float rotationDeltaAroundAxisDeg(RigidTransform from,RigidTransform to,PVector axis){
    RigidTransform d=to.multiply(from.inverseRigid());PVector a=axis==null?new PVector(0,1,0):axis.copy();if(a.magSq()<1e-7f)a.set(0,1,0);a.normalize();
    float vx=d.m[9]-d.m[6],vy=d.m[2]-d.m[8],vz=d.m[4]-d.m[1];float sin=.5f*(a.x*vx+a.y*vy+a.z*vz);
    float cos=constrain((d.m[0]+d.m[5]+d.m[10]-1.0f)*.5f,-1,1);return degrees(atan2(sin,cos));
  }

  int firstAccepted(boolean[] accepted){for(int i=0;i<accepted.length;i++)if(accepted[i])return i;return -1;}
  int lastAccepted(boolean[] accepted){for(int i=accepted.length-1;i>=0;i--)if(accepted[i])return i;return -1;}

  void applyDistributedTurntableYawAccepted(ArrayList<RigidTransform> poses,boolean[] accepted,PVector pivot,PVector axis,float totalYawDeg,int first,int last){
    if(last<=first)return;for(int i=first+1;i<=last;i++){if(!accepted[i])continue;float a=(i-first)/(float)(last-first);
      poses.set(i,rotationAroundPivotAxis(pivot,axis,totalYawDeg*a).multiply(poses.get(i)));}
  }

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
class TSDFSurfaceHit {
  final PVector point=new PVector(),normal=new PVector();float distance;
  TSDFSurfaceHit(){}
  TSDFSurfaceHit(PVector point,PVector normal,float distance){this.point.set(point);this.normal.set(normal);this.distance=distance;}
}

class TSDFVolume {
  int n;float voxelSize,truncation;int temporalColorWeightMax;short[] tsdf;byte[] weight;
  int[] rgb;byte[] rgbWeight;int[] touched=new int[65536];int touchedCount=0;
  int[] meshCellBits=new int[0],meshCells=new int[65536];int meshCellCount=0;
  PVector origin=new PVector(),center=new PVector();int minX,minY,minZ,maxX,maxY,maxZ;
  SpatialHash surfaceModelHash=null;final HashMap<PVector,PVector> surfaceModelNormals=new HashMap<PVector,PVector>();
  int surfaceModelPoints=0,surfaceModelTouched=-1;long integrationRevision=0,surfaceModelRevision=-1;

  TSDFVolume(int n,float voxelSize,float truncation,int temporalColorWeightMax){this.n=n;
    this.voxelSize=voxelSize;this.truncation=truncation;this.temporalColorWeightMax=max(1,temporalColorWeightMax);
    int count=n*n*n;tsdf=new short[count];weight=new byte[count];rgb=new int[count];
    rgbWeight=new byte[count];resetBounds();}
  void resetBounds(){minX=minY=minZ=n;maxX=maxY=maxZ=-1;}
  void clear(){for(int i=0;i<touchedCount;i++){int id=touched[i];weight[id]=0;rgbWeight[id]=0;
      tsdf[id]=0;rgb[id]=0;}touchedCount=0;resetBounds();integrationRevision=0;invalidateSurfaceModel();}
  void invalidateSurfaceModel(){surfaceModelHash=null;surfaceModelNormals.clear();surfaceModelPoints=0;surfaceModelTouched=-1;surfaceModelRevision=-1;}
  void markTouched(int id){if((weight[id]&255)!=0||(rgbWeight[id]&255)!=0)return;
    if(touchedCount>=touched.length)touched=Arrays.copyOf(touched,max(touchedCount+1,touched.length*2));
    touched[touchedCount++]=id;}
  void resetAround(PVector c){clear();center.set(c);float half=n*voxelSize*0.5f;origin.set(c.x-half,c.y-half,c.z-half);
    }
  void resetAroundTargetCube(PVector c,float side,AppConfig cfg){
    voxelSize=constrain(side/max(1,n-4),cfg.voxelSizeM,cfg.volumeMaxVoxelSizeM);
    truncation=max(cfg.truncationM,voxelSize*3.0f);resetAround(c);
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
  float sampleTsdf(PVector p,int minWeight){return p==null?Float.NaN:sampleTsdf(p.x,p.y,p.z,minWeight);}
  float sampleTsdf(float px,float py,float pz,int minWeight){
    float fx=(px-origin.x)/voxelSize,fy=(py-origin.y)/voxelSize,fz=(pz-origin.z)/voxelSize;int x=floor(fx),y=floor(fy),z=floor(fz);
    if(!inside(x,y,z)||!inside(x+1,y+1,z+1))return Float.NaN;float tx=fx-x,ty=fy-y,tz=fz-z,sum=0,ws=0;
    for(int dz=0;dz<=1;dz++)for(int dy=0;dy<=1;dy++)for(int dx=0;dx<=1;dx++){int id=idx(x+dx,y+dy,z+dz);if((weight[id]&255)<minWeight)continue;
      float wgt=(dx==0?1-tx:tx)*(dy==0?1-ty:ty)*(dz==0?1-tz:tz);sum+=(tsdf[id]/32767.0f)*wgt;ws+=wgt;}
    return ws<0.45f?Float.NaN:sum/ws;
  }
  PVector tsdfNormal(PVector p,int minWeight){if(p==null)return null;PVector out=new PVector();return tsdfNormalInto(p.x,p.y,p.z,minWeight,out)?out:null;}
  boolean tsdfNormalInto(float px,float py,float pz,int minWeight,PVector out){
    float h=max(voxelSize,0.001f),xp=sampleTsdf(px+h,py,pz,minWeight),xm=sampleTsdf(px-h,py,pz,minWeight),
      yp=sampleTsdf(px,py+h,pz,minWeight),ym=sampleTsdf(px,py-h,pz,minWeight),zp=sampleTsdf(px,py,pz+h,minWeight),zm=sampleTsdf(px,py,pz-h,minWeight);
    if(!Float.isFinite(xp)||!Float.isFinite(xm)||!Float.isFinite(yp)||!Float.isFinite(ym)||!Float.isFinite(zp)||!Float.isFinite(zm))return false;
    float nx=xp-xm,ny=yp-ym,nz=zp-zm,mag2=nx*nx+ny*ny+nz*nz;if(mag2<1e-8f)return false;float inv=1.0f/sqrt(mag2);out.set(nx*inv,ny*inv,nz*inv);return true;
  }
  boolean raycastSurfaceInto(float cameraX,float cameraY,float cameraZ,float directionX,float directionY,float directionZ,float expectedDistance,float searchM,int minWeight,float stepScale,TSDFSurfaceHit out){
    if(out==null||touchedCount==0)return false;float mag2=directionX*directionX+directionY*directionY+directionZ*directionZ;if(mag2<1e-8f)return false;float invMag=1.0f/sqrt(mag2),dx=directionX*invMag,dy=directionY*invMag,dz=directionZ*invMag;
    float start=max(0.04f,expectedDistance-max(searchM,truncation*3.0f)),end=expectedDistance+max(searchM,truncation*3.0f),step=max(voxelSize*stepScale,0.0015f),prev=Float.NaN,prevT=start;
    for(float t=start;t<=end;t+=step){float px=cameraX+dx*t,py=cameraY+dy*t,pz=cameraZ+dz*t,v=sampleTsdf(px,py,pz,minWeight);if(!Float.isFinite(v)){prev=Float.NaN;continue;}
      if(Float.isFinite(prev)&&prev>0&&v<=0){float denom=prev-v,alpha=abs(denom)<1e-6f?0.5f:constrain(prev/denom,0,1),hitT=lerp(prevT,t,alpha),hx=cameraX+dx*hitT,hy=cameraY+dy*hitT,hz=cameraZ+dz*hitT;
        if(tsdfNormalInto(hx,hy,hz,minWeight,out.normal)){out.point.set(hx,hy,hz);out.distance=hitT;return true;}}
      prev=v;prevT=t;}
    return false;
  }
  TSDFSurfaceHit raycastSurface(PVector camera,PVector direction,float expectedDistance,float searchM,int minWeight,float stepScale){
    if(camera==null||direction==null)return null;TSDFSurfaceHit out=new TSDFSurfaceHit();return raycastSurfaceInto(camera.x,camera.y,camera.z,direction.x,direction.y,direction.z,expectedDistance,searchM,minWeight,stepScale,out)?out:null;
  }
  boolean voxelNormalInto(int x,int y,int z,int minWeight,PVector out){
    if(out==null||!inside(x-1,y,z)||!inside(x+1,y,z)||!inside(x,y-1,z)||!inside(x,y+1,z)||!inside(x,y,z-1)||!inside(x,y,z+1))return false;
    int xm=idx(x-1,y,z),xp=idx(x+1,y,z),ym=idx(x,y-1,z),yp=idx(x,y+1,z),zm=idx(x,y,z-1),zp=idx(x,y,z+1);
    if((weight[xm]&255)<minWeight||(weight[xp]&255)<minWeight||(weight[ym]&255)<minWeight||(weight[yp]&255)<minWeight||(weight[zm]&255)<minWeight||(weight[zp]&255)<minWeight)return false;
    float nx=tsdf[xp]-tsdf[xm],ny=tsdf[yp]-tsdf[ym],nz=tsdf[zp]-tsdf[zm],m2=nx*nx+ny*ny+nz*nz;if(m2<1e-6f)return false;float inv=1.0f/sqrt(m2);out.set(nx*inv,ny*inv,nz*inv);return true;
  }
  int ensureSurfaceModel(AppConfig cfg){
    if(cfg==null||touchedCount==0)return 0;
    boolean fresh=surfaceModelHash!=null&&surfaceModelPoints>=cfg.fusionPointPlaneMinMatches&&
      integrationRevision-surfaceModelRevision<cfg.fusionModelCacheRefreshIntegrations&&
      touchedCount-surfaceModelTouched<cfg.fusionModelCacheRefreshTouched;
    if(fresh)return surfaceModelPoints;
    int target=max(cfg.fusionPointPlaneMinMatches*3,cfg.fusionModelCacheMaxPoints),stride=max(1,touchedCount/max(1,target*3));
    ArrayList<PVector> pts=new ArrayList<PVector>(min(target,touchedCount));ArrayList<PVector> normals=new ArrayList<PVector>(min(target,touchedCount));PVector normal=new PVector();int nn=n*n;
    for(int i=0;i<touchedCount&&pts.size()<target;i+=stride){int id=touched[i],w=weight[id]&255;if(w<cfg.fusionModelMinWeight)continue;float v=abs(tsdf[id]/32767.0f);if(v>0.32f)continue;int z=id/nn,rem=id-z*nn,y=rem/n,x=rem-y*n;if(!voxelNormalInto(x,y,z,cfg.fusionModelMinWeight,normal))continue;
      // Project the voxel centre onto the implicit surface (tsdf * truncation is the
      // signed distance along the normal). This removes up to half a voxel of bias.
      float sd=(tsdf[id]/32767.0f)*truncation;
      pts.add(new PVector(origin.x+x*voxelSize-normal.x*sd,origin.y+y*voxelSize-normal.y*sd,origin.z+z*voxelSize-normal.z*sd));normals.add(normal.copy());}
    if(pts.size()<cfg.fusionPointPlaneMinMatches){surfaceModelHash=null;surfaceModelNormals.clear();surfaceModelPoints=0;surfaceModelTouched=touchedCount;surfaceModelRevision=integrationRevision;return 0;}
    surfaceModelHash=new SpatialHash(max(cfg.fusionModelCacheCellM,voxelSize*2.5f),pts.size());surfaceModelNormals.clear();
    for(int i=0;i<pts.size();i++){PVector q=pts.get(i);surfaceModelHash.add(q);surfaceModelNormals.put(q,normals.get(i));}
    surfaceModelPoints=pts.size();surfaceModelTouched=touchedCount;surfaceModelRevision=integrationRevision;return surfaceModelPoints;
  }
  PVector nearestSurfaceModel(float x,float y,float z,float maxDist,AppConfig cfg){if(ensureSurfaceModel(cfg)<cfg.fusionPointPlaneMinMatches||surfaceModelHash==null)return null;return surfaceModelHash.nearest(x,y,z,maxDist);}
  PVector surfaceModelNormal(PVector p){return p==null?null:surfaceModelNormals.get(p);}

  float[] raycastConsistency(PointCloud cloud,RigidTransform pose,AppConfig cfg){
    if(cloud==null||pose==null||cfg==null||touchedCount==0)return new float[]{0,Float.POSITIVE_INFINITY};int stride=max(1,cloud.size()/1600),attempted=0,matched=0;double sum=0;float[] m=pose.m;float camX=m[3],camY=m[7],camZ=m[11];TSDFSurfaceHit hit=new TSDFSurfaceHit();
    for(int i=0;i<cloud.size();i+=stride){if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;PVector src=cloud.points.get(i);float wx=m[0]*src.x+m[1]*src.y+m[2]*src.z+m[3],wy=m[4]*src.x+m[5]*src.y+m[6]*src.z+m[7],wz=m[8]*src.x+m[9]*src.y+m[10]*src.z+m[11],rx=wx-camX,ry=wy-camY,rz=wz-camZ,dist2=rx*rx+ry*ry+rz*rz;if(dist2<0.0025f)continue;float dist=sqrt(dist2),inv=1.0f/dist;
      if(!raycastSurfaceInto(camX,camY,camZ,rx*inv,ry*inv,rz*inv,dist,cfg.fusionRaycastSearchM,cfg.fusionModelMinWeight,cfg.fusionRaycastStepScale,hit))continue;float ex=wx-hit.point.x,ey=wy-hit.point.y,ez=wz-hit.point.z,r=ex*hit.normal.x+ey*hit.normal.y+ez*hit.normal.z;sum+=r*r;matched++;}
    return new float[]{attempted<=0?0:matched/(float)attempted,matched<=0?Float.POSITIVE_INFINITY:(float)Math.sqrt(sum/matched)};
  }
  float surfaceConfidenceCoverage(int minWeight,int matureWeight){
    if(touchedCount==0)return 0;int known=0,mature=0;float band=0.40f;
    for(int i=0;i<touchedCount;i++){int id=touched[i],w=weight[id]&255;if(w<minWeight)continue;float v=abs(tsdf[id]/32767.0f);if(v>band)continue;known++;if(w>=matureWeight)mature++;}
    return known==0?0:constrain(mature/(float)known,0,1);
  }
  boolean expandToInclude(PointCloud cloud,RigidTransform pose,AppConfig cfg){
    if(cloud==null||cloud.size()==0||pose==null||cfg==null||touchedCount==0)return false;
    float loX=origin.x+max(0,minX)*voxelSize,loY=origin.y+max(0,minY)*voxelSize,loZ=origin.z+max(0,minZ)*voxelSize;
    float hiX=origin.x+min(n-1,maxX)*voxelSize,hiY=origin.y+min(n-1,maxY)*voxelSize,hiZ=origin.z+min(n-1,maxZ)*voxelSize;int stride=max(1,cloud.size()/8000);
    for(int i=0;i<cloud.size();i+=stride){PVector p=pose.apply(cloud.points.get(i));loX=min(loX,p.x);loY=min(loY,p.y);loZ=min(loZ,p.z);hiX=max(hiX,p.x);hiY=max(hiY,p.y);hiZ=max(hiZ,p.z);}
    float extent=max(hiX-loX,max(hiY-loY,hiZ-loZ))*cfg.volumeAutoFitPadding,needed=extent/max(1,n-4);if(needed<=voxelSize*1.06f)return false;float newVoxel=min(cfg.volumeMaxVoxelSizeM,max(voxelSize,needed));if(newVoxel<=voxelSize*1.01f)return false;
    short[] oldTsdf=tsdf;byte[] oldWeight=weight,oldRgbWeight=rgbWeight;int[] oldRgb=rgb,oldTouched=Arrays.copyOf(touched,touchedCount);int oldCount=touchedCount;float oldVoxel=voxelSize;PVector oldOrigin=origin.copy();
    tsdf=new short[n*n*n];weight=new byte[n*n*n];rgb=new int[n*n*n];rgbWeight=new byte[n*n*n];touched=new int[max(65536,oldCount)];touchedCount=0;resetBounds();voxelSize=newVoxel;truncation=max(cfg.truncationM,voxelSize*3.0f);center.set((loX+hiX)*.5f,(loY+hiY)*.5f,(loZ+hiZ)*.5f);float half=n*voxelSize*.5f;origin.set(center.x-half,center.y-half,center.z-half);
    int nn=n*n;for(int k=0;k<oldCount;k++){int oid=oldTouched[k],oz=oid/nn,rem=oid-oz*nn,oy=rem/n,ox=rem-oy*n;float wx=oldOrigin.x+ox*oldVoxel,wy=oldOrigin.y+oy*oldVoxel,wz=oldOrigin.z+oz*oldVoxel;int x=round((wx-origin.x)/voxelSize),y=round((wy-origin.y)/voxelSize),z=round((wz-origin.z)/voxelSize);if(!inside(x,y,z))continue;int id=idx(x,y,z),ow=oldWeight[oid]&255,nw=weight[id]&255;if(ow>nw){markTouched(id);tsdf[id]=oldTsdf[oid];weight[id]=(byte)ow;rgb[id]=oldRgb[oid];rgbWeight[id]=oldRgbWeight[oid];minX=min(minX,x);minY=min(minY,y);minZ=min(minZ,z);maxX=max(maxX,x);maxY=max(maxY,y);maxZ=max(maxZ,z);}}
    integrationRevision++;invalidateSurfaceModel();return true;
  }
  float[] surfaceConsistency(PointCloud cloud,RigidTransform pose,AppConfig cfg){
    if(cloud==null||pose==null||cfg==null||touchedCount==0)return new float[]{0,1,0};
    int stride=max(1,cloud.size()/2400),attempted=0,known=0,agree=0;double residualSum=0;
    float band=max(voxelSize,cfg.fusionSurfaceAgreementBandM);
    // Structured-light noise grows with range squared, so residuals are judged
    // relative to the expected noise at each point's depth. The reported mean is
    // an equivalent residual at 1 m, keeping fusion.surfaceMaxResidualM meaningful.
    float sigma1m=cfg.depthNoiseBaseM+cfg.depthNoiseQuadM;
    for(int i=0;i<cloud.size();i+=stride){
      if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;
      PVector c=cloud.points.get(i);PVector p=pose.apply(c);
      // Trilinear TSDF value at the sample, not the nearest voxel (which alone is up
      // to half a voxel diagonal away from the point).
      float value=sampleTsdf(p.x,p.y,p.z,cfg.fusionSurfaceMinWeight);if(!Float.isFinite(value))continue;
      known++;float residual=abs(value)*truncation,sigma=cfg.depthNoiseBaseM+cfg.depthNoiseQuadM*c.z*c.z;
      float normalized=residual/max(1e-4f,sigma);residualSum+=min(normalized,4.0f)*sigma1m;
      if(residual<=band||normalized<=2.5f)agree++;
    }
    float knownRatio=attempted<=0?0:known/(float)attempted;
    float agreement=known<=0?1:agree/(float)known;
    float meanResidual=known<=0?0:(float)(residualSum/known);
    return new float[]{knownRatio,agreement,meanResidual};
  }
  void integrate(PointCloud cloud,RigidTransform pose,int pointStep){integrate(cloud,pose,pointStep,false,1.0f);
    }
  void integrate(PointCloud cloud,RigidTransform pose,int pointStep,boolean distanceWeighted){integrate(cloud,pose,pointStep,distanceWeighted,1.0f);}
  void integrate(PointCloud cloud,RigidTransform pose,int pointStep,boolean distanceWeighted,float frameConfidence){integrate(cloud,pose,pointStep,distanceWeighted,frameConfidence,0.05f,1.0f);}
  // ---- Projective TSDF integration (KinectFusion / Skanect style) --------------
  // Every voxel near the observed surface is projected into a z-buffer built from
  // the frame and receives the signed distance measured AT ITS OWN grid position,
  // exactly once per frame. The previous ray-marching splat assigned samples taken
  // anywhere inside a cell to the cell's lower corner, inflating every surface by
  // about half a voxel and aliasing thin detail.
  Calibration projection=null;boolean projectiveEnabled=true;float projectiveCellPx=2.0f;float carveMarginM=0.0f;
  float[] mapZ=new float[0],mapQ=new float[0];int mapW=0,mapH=0;
  int[] blockStamp=new int[0],activeBlocks=new int[4096];int blockStampFrame=0,activeBlockCount=0;
  void setProjection(Calibration c,AppConfig cfg){projection=c;if(cfg!=null){projectiveEnabled=cfg.tsdfProjective;carveMarginM=cfg.tsdfCarveMarginM;marchingCubes=cfg.meshMarchingCubes;}}
  float mapDepthAt(int cx,int cy){
    if(cx<0||cy<0||cx>=mapW||cy>=mapH)return 0;int i=cy*mapW+cx;float z=mapZ[i];if(z>0)return z;
    // Irregular sampling (ray grid vs. cell grid, subsampled clouds) can leave a
    // single empty cell: fill it only from agreeing 4-neighbours.
    float sum=0,lo=Float.MAX_VALUE,hi=0;int n=0;
    if(cx>0&&mapZ[i-1]>0){float q=mapZ[i-1];sum+=q;lo=min(lo,q);hi=max(hi,q);n++;}
    if(cx<mapW-1&&mapZ[i+1]>0){float q=mapZ[i+1];sum+=q;lo=min(lo,q);hi=max(hi,q);n++;}
    if(cy>0&&mapZ[i-mapW]>0){float q=mapZ[i-mapW];sum+=q;lo=min(lo,q);hi=max(hi,q);n++;}
    if(cy<mapH-1&&mapZ[i+mapW]>0){float q=mapZ[i+mapW];sum+=q;lo=min(lo,q);hi=max(hi,q);n++;}
    if(n<2||hi-lo>0.012f+0.004f*lo*lo)return 0;return sum/n;
  }
  float mapConfidenceAt(int cx,int cy){if(cx<0||cy<0||cx>=mapW||cy>=mapH)return 0;int i=cy*mapW+cx;return mapZ[i]>0?mapQ[i]:0.5f;}

  boolean integrateProjective(PointCloud cloud,RigidTransform pose,boolean distanceWeighted,float frameConfidence,float minPointConfidence,float confidenceGamma){
    Calibration c=projection;if(c==null||!c.valid||!projectiveEnabled||cloud==null||cloud.size()==0)return false;
    float cell=max(0.25f,projectiveCellPx),scale=1.0f/cell;
    int w=max(1,ceil(c.depthWidth*scale)),h=max(1,ceil(c.depthHeight*scale));
    if(mapZ.length!=w*h){mapZ=new float[w*h];mapQ=new float[w*h];}else{Arrays.fill(mapZ,0);}mapW=w;mapH=h;
    float fq=constrain(frameConfidence,0.05f,1.0f),minQ=constrain(minPointConfidence,0.05f,0.95f),gamma=max(0.25f,confidenceGamma);
    float[] m=pose.m;
    // 1) Nearest-surface z-buffer in the (pinhole) camera image + world AABB.
    float loX=Float.POSITIVE_INFINITY,loY=Float.POSITIVE_INFINITY,loZ=Float.POSITIVE_INFINITY,hiX=Float.NEGATIVE_INFINITY,hiY=Float.NEGATIVE_INFINITY,hiZ=Float.NEGATIVE_INFINITY;
    int used=0;
    for(int i=0;i<cloud.size();i++){
      float q=cloud.confidenceAt(i);if(q<minQ)continue;PVector p=cloud.points.get(i);if(p.z<=0.05f)continue;
      int cu=round((c.fx*p.x/p.z+c.cx)*scale),cv=round((c.fy*p.y/p.z+c.cy)*scale);if(cu<0||cv<0||cu>=w||cv>=h)continue;
      int id=cv*w+cu;if(mapZ[id]==0||p.z<mapZ[id]){mapZ[id]=p.z;mapQ[id]=(float)Math.pow(constrain(q,0.05f,1.0f),gamma);}
      float wx=m[0]*p.x+m[1]*p.y+m[2]*p.z+m[3],wy=m[4]*p.x+m[5]*p.y+m[6]*p.z+m[7],wz=m[8]*p.x+m[9]*p.y+m[10]*p.z+m[11];
      loX=min(loX,wx);loY=min(loY,wy);loZ=min(loZ,wz);hiX=max(hiX,wx);hiY=max(hiY,wy);hiZ=max(hiZ,wz);used++;
      int color=cloud.colorAt(i);if(((color>>>24)&255)!=0)integrateSurfaceColor(wx,wy,wz,color);
    }
    if(used==0)return true;
    // 2) Activate only the 8^3 voxel blocks crossed by the truncation band (plus
    //    the carve margin in front of it) of each observed ray. Near the surface
    //    this is exactly the full-volume KinectFusion update, at a fraction of the
    //    cost when the frame sees far more than the reconstruction volume.
    final int bs=8;int nb=(n+bs-1)/bs,nb3=nb*nb*nb;
    if(blockStamp.length!=nb3){blockStamp=new int[nb3];blockStampFrame=0;}
    if(++blockStampFrame==Integer.MAX_VALUE){Arrays.fill(blockStamp,0);blockStampFrame=1;}
    activeBlockCount=0;
    float front=truncation+max(0,carveMarginM),back=truncation,step=max(voxelSize,bs*voxelSize*0.5f);
    float invVoxel=1.0f/voxelSize;
    for(int cv=0;cv<h;cv++)for(int cu=0;cu<w;cu++){
      float zc=mapZ[cv*w+cu];if(zc<=0)continue;
      float rx=(cu*cell-c.cx)/c.fx,ry=(cv*cell-c.cy)/c.fy;
      for(float zz=max(0.1f,zc-front);zz<=zc+back+1e-6f;zz+=step){
        float px=rx*zz,py=ry*zz;
        float wx=m[0]*px+m[1]*py+m[2]*zz+m[3],wy=m[4]*px+m[5]*py+m[6]*zz+m[7],wz=m[8]*px+m[9]*py+m[10]*zz+m[11];
        int gx=(int)Math.floor((wx-origin.x)*invVoxel),gy=(int)Math.floor((wy-origin.y)*invVoxel),gz=(int)Math.floor((wz-origin.z)*invVoxel);
        // A sample activates the blocks holding the 8 grid corners around it.
        for(int dz=0;dz<=1;dz++)for(int dy=0;dy<=1;dy++)for(int dx=0;dx<=1;dx++){
          int vx=gx+dx,vy=gy+dy,vz=gz+dz;if(vx<0||vy<0||vz<0||vx>=n||vy>=n||vz>=n)continue;
          int b=(vx/bs)+(vy/bs)*nb+(vz/bs)*nb*nb;if(blockStamp[b]==blockStampFrame)continue;
          blockStamp[b]=blockStampFrame;if(activeBlockCount>=activeBlocks.length)activeBlocks=Arrays.copyOf(activeBlocks,activeBlocks.length*2+64);activeBlocks[activeBlockCount++]=b;
        }
      }
    }
    // 3) Projective update of every voxel of the active blocks: c = R^T (p - t).
    float tx=m[3],ty=m[7],tz=m[11];
    float fxs=c.fx*scale,fys=c.fy*scale,cxs=c.cx*scale,cys=c.cy*scale,invTrunc=1.0f/truncation;
    for(int bi=0;bi<activeBlockCount;bi++){
      int b=activeBlocks[bi],bz=b/(nb*nb),brem=b-bz*nb*nb,by=brem/nb,bx=brem-by*nb;
      int x0=bx*bs,y0=by*bs,z0=bz*bs,x1=min(n,x0+bs),y1=min(n,y0+bs),z1=min(n,z0+bs);
      for(int z=z0;z<z1;z++){float pz=origin.z+z*voxelSize-tz;
        for(int y=y0;y<y1;y++){float py=origin.y+y*voxelSize-ty;int rowBase=y*n+z*n*n;
          for(int x=x0;x<x1;x++){float px=origin.x+x*voxelSize-tx;
            float camZ=m[2]*px+m[6]*py+m[10]*pz;if(camZ<=0.1f)continue;
            float camX=m[0]*px+m[4]*py+m[8]*pz,camY=m[1]*px+m[5]*py+m[9]*pz,inv=1.0f/camZ;
            int cu=(int)(fxs*camX*inv+cxs+0.5f),cv=(int)(fys*camY*inv+cys+0.5f);
            if(cu<0||cv<0||cu>=w||cv>=h)continue;
            float measured=mapDepthAt(cu,cv);if(measured<=0)continue;
            float sdf=measured-camZ;if(sdf<-truncation)continue;       // occluded: no information
            int id=x+rowBase,wOld=weight[id]&255;
            float v;float confidence=mapConfidenceAt(cu,cv)*fq;
            if(sdf>truncation){if(wOld==0)continue;v=1.0f;}           // carve known voxels in free space only
            else v=sdf*invTrunc;
            int sampleWeight=distanceWeighted?depthSampleWeight(measured,confidence):max(1,round(confidence));
            // Behind the surface the observation is less certain; tapering its weight
            // protects thin parts from being eroded by views of their other side.
            if(sdf<0)sampleWeight=max(1,round(sampleWeight*max(0.25f,1.0f+sdf*invTrunc)));
            int accepted=min(sampleWeight,255-wOld);if(accepted<=0)continue;
            markTouched(id);int nw=wOld+accepted;float old=wOld==0?0:tsdf[id]/32767.0f,blended=(old*wOld+v*accepted)/nw;
            tsdf[id]=(short)constrain(round(blended*32767.0f),-32767,32767);weight[id]=(byte)nw;
            if(x<minX)minX=x;if(y<minY)minY=y;if(z<minZ)minZ=z;if(x>maxX)maxX=x;if(y>maxY)maxY=y;if(z>maxZ)maxZ=z;
          }
        }
      }
      if((bi&255)==0&&Thread.currentThread().isInterrupted())break;
    }
    integrationRevision++;return true;
  }

  void integrate(PointCloud cloud,RigidTransform pose,int pointStep,boolean distanceWeighted,float frameConfidence,float minPointConfidence,float confidenceGamma){
    if(integrateProjective(cloud,pose,distanceWeighted,frameConfidence,minPointConfidence,confidenceGamma))return;
    float[] m=pose.m;float camX=m[3],camY=m[7],camZ=m[11];int stride=max(1,pointStep);float fq=constrain(frameConfidence,0.05f,1.0f);
    float minQ=constrain(minPointConfidence,0.05f,0.95f),gamma=max(0.25f,confidenceGamma);

    for(int i=0;i<cloud.size();i+=stride){
      float pointQ=cloud.confidenceAt(i);if(pointQ<minQ)continue;float robustQ=(float)Math.pow(constrain(pointQ,0.05f,1.0f),gamma);
      PVector source=cloud.points.get(i);float surfX=m[0]*source.x+m[1]*source.y+m[2]*source.z+m[3],surfY=m[4]*source.x+m[5]*source.y+m[6]*source.z+m[7],
      surfZ=m[8]*source.x+m[9]*source.y+m[10]*source.z+m[11];int surfaceColor=cloud.colorAt(i);

      float dx=surfX-camX,dy=surfY-camY,dz=surfZ-camZ,dist=sqrt(dx*dx+dy*dy+dz*dz);
      if(dist<0.05f)continue;float inv=1.0f/dist,rayX=dx*inv,rayY=dy*inv,rayZ=dz*inv,from=max(0.05f,dist-truncation),to=dist+truncation;

      int sampleWeight=distanceWeighted?depthSampleWeight(dist,robustQ*fq):max(1,round(robustQ*fq));

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
    integrationRevision++;
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
    PVector[] edgeVertex=new PVector[12];int[] edgeColor=new int[12];
    for(int i=0;i<meshCellCount;i++){int cell=meshCells[i],z=cell/plane,rem=cell-z*plane,y=rem/side,x=rem-y*side;
      boolean complete=true;
      for(int c=0;c<8;c++){int xx=x+corners[c][0],yy=y+corners[c][1],zz=z+corners[c][2],id=idx(xx,yy,zz);
        p[c].set(origin.x+xx*voxelSize,origin.y+yy*voxelSize,origin.z+zz*voxelSize);int wt=weight[id]&255;ww[c]=wt;v[c]=wt==0?1.0f:tsdf[id]/32767.0f;if(wt<minWeight)complete=false;}
      if(marchingCubes){
        // Marching cubes (as in KinectFusion/Skanect): about half the triangles of
        // the 6-tetrahedra split, without its slivers and diagonal bias.
        if(!complete)continue;
        int cube=0;for(int c=0;c<8;c++)if(v[c]<0)cube|=1<<c;
        int edges=MC_EDGE_TABLE[cube];if(edges==0)continue;
        for(int e=0;e<12;e++)if((edges&(1<<e))!=0){int a=MC_EDGE_CORNERS[e][0],b=MC_EDGE_CORNERS[e][1];edgeVertex[e]=interpCanonical(p[a],p[b],v[a],v[b]);edgeColor[e]=sampleColor(edgeVertex[e]);}
        int[] tri=MC_TRI_TABLE[cube];
        for(int k=0;k+2<tri.length;k+=3){int e0=tri[k],e1=tri[k+1],e2=tri[k+2];
          out.addTriangle(edgeVertex[e0].copy(),edgeVertex[e2].copy(),edgeVertex[e1].copy(),edgeColor[e0],edgeColor[e2],edgeColor[e1]);}
        if(out.triangleCount()>=maxTriangles)return out;
      }else{
        for(int[] t:tets){polygonizeTet(out,p,v,ww,t,minWeight);if(out.triangleCount()>=maxTriangles)return out;}
      }
      if((i&1023)==0){if(Thread.currentThread().isInterrupted())return out;Thread.yield();}
    }
    return out;
  }
  boolean marchingCubes=true;
  // Interpolate from the lower grid corner so the shared edge of neighbouring
  // cells yields bit-identical vertices (exact welding, no cracks).
  PVector interpCanonical(PVector a,PVector b,float va,float vb){
    if(a.x+a.y+a.z>b.x+b.y+b.z){PVector tp=a;a=b;b=tp;float tv=va;va=vb;vb=tv;}
    return interp(a,b,va,vb);
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
