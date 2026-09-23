// ===== SynKinect Studio / Shared Skeleton Library =====
//
// SynSkeleton is the reusable body-tracking layer used by Studio modules. It keeps
// sensor transport outside the tracker: callers provide calibrated RGB-D frames and
// receive a 20-joint body pose. Each tracker instance owns its own
// temporal state, so several modules or Kinect devices can track independently.
//
// Design goals: persistent identity, robust depth-person segmentation, articulated
// limb paths, confidence-aware temporal consensus, adaptive low-latency filtering,
// coherent root stabilization, anthropometric constraints and short occlusion hold.
class SkeletonConfig {
  int minDepthMm=550,maxDepthMm=3800;
  float poseMinCoreConfidence=0.30f,trackingMinCoreCoverage=0.55f,trackingMinBodyConfidence=0.28f;
  
  int poseOcclusionHoldFrames=14,trackingAcquireFrames=3,trackingReleaseFrames=6;
  
  float poseFilterMinAlpha=0.08f,poseFilterMaxAlpha=0.82f,poseVelocityAlpha=0.22f,poseMaxSpeedMps=4.2f;
  
  float poseOneEuroMinCutoff=0.90f,poseOneEuroBeta=0.58f,poseOneEuroDerivativeCutoff=1.0f;
  
  float poseGeodesicDepthPenalty=1.15f,poseMedialPenalty=0.85f,poseCrossBodyPenalty=1.85f,poseTemporalEndpointBias=1.05f,poseMinArmPathRatio=0.52f,poseMinLegPathRatio=0.82f;
  
  float poseInnovationGateM=0.22f,poseJitterRadiusM=0.010f,poseBoneLearnAlpha=0.055f,poseBoneCorrection=0.72f,poseMaxDirectionJumpDeg=58.0f;
  int poseFullResolutionRefineRadiusPx=6,poseFullResolutionDepthToleranceMm=120;
  int consensusWindow=5;float consensusMadScale=2.8f,consensusMinRadiusM=0.012f,consensusMaxBlend=0.58f;
  
  float rootMinCutoff=0.72f,rootBeta=0.34f,rootDerivativeCutoff=1.0f,rootMaxCorrectionM=0.055f;
  
  float identityVelocityAlpha=0.28f,identityMaxPredictionPx=90.0f,identityMaxPredictionM=0.28f;
  
  float kalmanProcessNoise=0.38f,kalmanMeasurementNoiseM=0.020f,kalmanDepthNoiseScale=0.0065f,kalmanVelocityDamping=0.985f,kalmanPredictionMs=8.0f;
  
  int modelIterations=8;float modelObservationStiffness=0.58f,modelInferredStiffness=0.18f,modelBoneStiffness=0.72f,modelTorsoStiffness=0.34f,modelMaxCorrectionM=0.075f,
  modelLearnAlpha=0.045f;
  float bodyTemporalCenterPx=120.0f,bodyTemporalDepthM=0.45f;
  int bodySampleStep=4,bodyDepthBinMm=80,bodyDepthBandMm=520,bodyDepthHypotheses=6,bodyContinuityMm=300,bodyMinSamples=70,bodyMinHeightPx=80,bodyHistogramCapSamples=1600,
  bodyBridgeCells=1,bodyRobustDepthRadiusPx=2;
  float bodyMaxWidthRatio=0.90f,bodyCenterBias=0.70f,bodyMinAspect=0.65f,bodyMinRowCoverage=0.58f,bodyMinFillRatio=0.055f,bodyTemporalRejectScale=0.68f,
  bodyHumanShapeWeight=0.32f;
  void load(File file){
    ConfigRules r=studio.services.configRules;Properties p=r.load(file,"skeleton");
    
    minDepthMm=r.integer(p,"vision.minDepthMm",minDepthMm,300,6000);maxDepthMm=r.integer(p,"vision.maxDepthMm",maxDepthMm,minDepthMm+100,8000);
    
    poseMinCoreConfidence=r.decimal(p,"pose.minCoreConfidence",poseMinCoreConfidence,0.05f,0.95f);
    trackingMinCoreCoverage=r.decimal(p,"tracking.minCoreCoverage",trackingMinCoreCoverage,0.20f,1.0f);
    trackingMinBodyConfidence=r.decimal(p,"tracking.minBodyConfidence",trackingMinBodyConfidence,0.05f,0.95f);
    poseOcclusionHoldFrames=r.integer(p,"pose.occlusionHoldFrames",poseOcclusionHoldFrames,0,45);
    trackingAcquireFrames=r.integer(p,"tracking.acquireFrames",trackingAcquireFrames,1,15);
    trackingReleaseFrames=r.integer(p,"tracking.releaseFrames",trackingReleaseFrames,1,30);
    
    poseFilterMinAlpha=r.decimal(p,"pose.filterMinAlpha",poseFilterMinAlpha,0.03f,0.8f);
    poseFilterMaxAlpha=r.decimal(p,"pose.filterMaxAlpha",poseFilterMaxAlpha,poseFilterMinAlpha,1.0f);
    poseVelocityAlpha=r.decimal(p,"pose.velocityAlpha",poseVelocityAlpha,0.01f,0.9f);
    poseMaxSpeedMps=r.decimal(p,"pose.maxSpeedMps",poseMaxSpeedMps,0.5f,12.0f);
    poseOneEuroMinCutoff=r.decimal(p,"pose.oneEuroMinCutoff",poseOneEuroMinCutoff,0.1f,8.0f);
    poseOneEuroBeta=r.decimal(p,"pose.oneEuroBeta",poseOneEuroBeta,0.0f,8.0f);poseOneEuroDerivativeCutoff=r.decimal(p,"pose.oneEuroDerivativeCutoff",poseOneEuroDerivativeCutoff,
      0.1f,8.0f);
    poseGeodesicDepthPenalty=r.decimal(p,"pose.geodesicDepthPenalty",poseGeodesicDepthPenalty,0.0f,6.0f);
    poseMedialPenalty=r.decimal(p,"pose.medialPenalty",poseMedialPenalty,0.0f,4.0f);
    poseCrossBodyPenalty=r.decimal(p,"pose.crossBodyPenalty",poseCrossBodyPenalty,1.0f,6.0f);
    poseTemporalEndpointBias=r.decimal(p,"pose.temporalEndpointBias",poseTemporalEndpointBias,0.0f,4.0f);
    poseMinArmPathRatio=r.decimal(p,"pose.minArmPathRatio",poseMinArmPathRatio,0.15f,1.5f);
    poseMinLegPathRatio=r.decimal(p,"pose.minLegPathRatio",poseMinLegPathRatio,0.25f,2.5f);
    
    poseInnovationGateM=r.decimal(p,"pose.innovationGateM",poseInnovationGateM,0.04f,1.0f);
    poseJitterRadiusM=r.decimal(p,"pose.jitterRadiusM",poseJitterRadiusM,0.001f,0.08f);
    poseBoneLearnAlpha=r.decimal(p,"pose.boneLearnAlpha",poseBoneLearnAlpha,0.005f,0.5f);
    poseBoneCorrection=r.decimal(p,"pose.boneCorrection",poseBoneCorrection,0.0f,1.0f);
    poseMaxDirectionJumpDeg=r.decimal(p,"pose.maxDirectionJumpDeg",poseMaxDirectionJumpDeg,20.0f,160.0f);
    poseFullResolutionRefineRadiusPx=r.integer(p,"pose.fullResolutionRefineRadiusPx",poseFullResolutionRefineRadiusPx,0,14);
    poseFullResolutionDepthToleranceMm=r.integer(p,"pose.fullResolutionDepthToleranceMm",poseFullResolutionDepthToleranceMm,30,350);
    
    consensusWindow=r.integer(p,"consensus.window",consensusWindow,3,9);consensusMadScale=r.decimal(p,"consensus.madScale",consensusMadScale,1.0f,8.0f);
    consensusMinRadiusM=r.decimal(p,"consensus.minRadiusM",consensusMinRadiusM,0.002f,0.08f);
    consensusMaxBlend=r.decimal(p,"consensus.maxBlend",consensusMaxBlend,0.0f,0.9f);
    
    rootMinCutoff=r.decimal(p,"root.minCutoff",rootMinCutoff,0.1f,5.0f);rootBeta=r.decimal(p,"root.beta",rootBeta,0.0f,4.0f);
    rootDerivativeCutoff=r.decimal(p,"root.derivativeCutoff",rootDerivativeCutoff,0.1f,8.0f);
    rootMaxCorrectionM=r.decimal(p,"root.maxCorrectionM",rootMaxCorrectionM,0.005f,0.20f);
    
    identityVelocityAlpha=r.decimal(p,"identity.velocityAlpha",identityVelocityAlpha,0.02f,0.95f);
    identityMaxPredictionPx=r.decimal(p,"identity.maxPredictionPx",identityMaxPredictionPx,10,300);
    identityMaxPredictionM=r.decimal(p,"identity.maxPredictionM",identityMaxPredictionM,0.03f,1.0f);
    
    kalmanProcessNoise=r.decimal(p,"kalman.processNoise",kalmanProcessNoise,0.01f,4.0f);
    kalmanMeasurementNoiseM=r.decimal(p,"kalman.measurementNoiseM",kalmanMeasurementNoiseM,0.003f,0.12f);
    kalmanDepthNoiseScale=r.decimal(p,"kalman.depthNoiseScale",kalmanDepthNoiseScale,0.0f,0.05f);
    kalmanVelocityDamping=r.decimal(p,"kalman.velocityDamping",kalmanVelocityDamping,0.80f,1.0f);
    kalmanPredictionMs=r.decimal(p,"kalman.predictionMs",kalmanPredictionMs,0.0f,35.0f);
    
    modelIterations=r.integer(p,"model.iterations",modelIterations,1,16);modelObservationStiffness=r.decimal(p,"model.observationStiffness",modelObservationStiffness,
      0.05f,1.0f);modelInferredStiffness=r.decimal(p,"model.inferredStiffness",modelInferredStiffness,0.0f,0.8f);
    modelBoneStiffness=r.decimal(p,"model.boneStiffness",modelBoneStiffness,0.05f,1.0f);
    modelTorsoStiffness=r.decimal(p,"model.torsoStiffness",modelTorsoStiffness,0.0f,1.0f);
    modelMaxCorrectionM=r.decimal(p,"model.maxCorrectionM",modelMaxCorrectionM,0.01f,0.25f);
    modelLearnAlpha=r.decimal(p,"model.learnAlpha",modelLearnAlpha,0.005f,0.30f);
    
    bodyTemporalCenterPx=r.decimal(p,"body.temporalCenterPx",bodyTemporalCenterPx,20,500);
    bodyTemporalDepthM=r.decimal(p,"body.temporalDepthM",bodyTemporalDepthM,0.1f,2.0f);
    bodySampleStep=r.integer(p,"body.sampleStep",bodySampleStep,2,8);bodyDepthBinMm=r.integer(p,"body.depthBinMm",bodyDepthBinMm,40,200);
    bodyDepthBandMm=r.integer(p,"body.depthBandMm",bodyDepthBandMm,180,900);bodyDepthHypotheses=r.integer(p,"body.depthHypotheses",bodyDepthHypotheses,
      1,10);bodyContinuityMm=r.integer(p,"body.continuityMm",bodyContinuityMm,80,700);
    bodyMinSamples=r.integer(p,"body.minSamples",bodyMinSamples,25,2000);bodyMinHeightPx=r.integer(p,"body.minHeightPx",bodyMinHeightPx,50,420);
    bodyHistogramCapSamples=r.integer(p,"body.histogramCapSamples",bodyHistogramCapSamples,100,10000);
    bodyBridgeCells=r.integer(p,"body.bridgeCells",bodyBridgeCells,0,2);bodyRobustDepthRadiusPx=r.integer(p,"body.robustDepthRadiusPx",bodyRobustDepthRadiusPx,
      0,6);bodyMaxWidthRatio=r.decimal(p,"body.maxWidthRatio",bodyMaxWidthRatio,0.30f,1.0f);
    bodyCenterBias=r.decimal(p,"body.centerBias",bodyCenterBias,0,2.0f);bodyMinAspect=r.decimal(p,"body.minAspect",bodyMinAspect,0.35f,2.0f);
    bodyMinRowCoverage=r.decimal(p,"body.minRowCoverage",bodyMinRowCoverage,0.20f,1.0f);
    bodyMinFillRatio=r.decimal(p,"body.minFillRatio",bodyMinFillRatio,0.01f,0.60f);
    bodyTemporalRejectScale=r.decimal(p,"body.temporalRejectScale",bodyTemporalRejectScale,0.10f,1.0f);
    bodyHumanShapeWeight=r.decimal(p,"body.humanShapeWeight",bodyHumanShapeWeight,0.0f,1.0f);
    
  }
}

class SkeletonLibrary {
  private SkeletonConfig config;
  synchronized SkeletonConfig configuration(){
    if(config==null){config=new SkeletonConfig();config.load(studio.services.paths.resource("skeleton","config.properties"));
      }
    return config;
  }
  SkeletonTracker createTracker(Calibration calibration,RgbDepthRegistration registration){return new SkeletonTracker(configuration(),calibration,registration);
    }
}

class SkeletonHistorySample {final PVector world;final float confidence;final long tickMs;
  SkeletonHistorySample(PVector w,float q,long t){world=w.copy();confidence=q;tickMs=t;
    }}
class SkeletonTemporalConsensus {
  final SkeletonConfig cfg;final HashMap<String,ArrayDeque<SkeletonHistorySample>> history=new HashMap<String,ArrayDeque<SkeletonHistorySample>>();
  
  SkeletonTemporalConsensus(SkeletonConfig c){cfg=c;}void reset(){history.clear();
    }
  SkeletonJoint3D[] joints(SkeletonPose3D s){return new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,s.leftElbow,
      s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot}
    ;}
  void apply(SkeletonPose3D s,long tickMs){for(SkeletonJoint3D j:joints(s))applyJoint(j,tickMs);
    }
  void applyJoint(SkeletonJoint3D j,long tickMs){
    if(j==null||j.state==0||j.world.z<=0)return;ArrayDeque<SkeletonHistorySample> q=history.get(j.name);
    if(q==null){q=new ArrayDeque<SkeletonHistorySample>();history.put(j.name,q);}q.addLast(new SkeletonHistorySample(j.world,j.confidence,tickMs));
    while(q.size()>cfg.consensusWindow)q.removeFirst();if(q.size()<3)return;
    ArrayList<SkeletonHistorySample> samples=new ArrayList<SkeletonHistorySample>(q);
    float mx=medianAxis(samples,0),my=medianAxis(samples,1),mz=medianAxis(samples,2);
    PVector med=new PVector(mx,my,mz);float[] distv=new float[samples.size()];for(int i=0;i<samples.size();i++)distv[i]=PVector.dist(samples.get(i).world,
      med);Arrays.sort(distv);float mad=distv[distv.length/2],radius=max(cfg.consensusMinRadiusM,cfg.consensusMadScale*max(mad,.001f));
    PVector center=new PVector();float sw=0;int kept=0;for(int i=0;i<samples.size();i++){SkeletonHistorySample a=samples.get(i);
      float d=PVector.dist(a.world,med);if(d>radius&&i<samples.size()-1)continue;
      float recency=.65f+.35f*(i+1)/(float)samples.size(),w=max(.05f,a.confidence)*recency/(1.0f+d/max(radius,.001f));
      center.add(PVector.mult(a.world,w));sw+=w;kept++;}if(sw<=0||kept<2)return;center.div(sw);
    float deviation=PVector.dist(j.world,center),gate=radius*lerp(1.55f,1.05f,constrain(j.confidence,0,1));
    if(deviation>gate){float blend=constrain(cfg.consensusMaxBlend+(deviation-gate)/max(gate,.001f)*.12f,0,cfg.consensusMaxBlend+.18f);
      j.world.set(PVector.lerp(j.world,center,blend));j.confidence*=constrain(gate/max(deviation,.001f),.45f,1.0f);
      if(j.state==2)j.state=1;}else if(deviation<radius){float blend=cfg.consensusMaxBlend*constrain(1.0f-j.confidence*.55f,0.15f,.65f);
      j.world.set(PVector.lerp(j.world,center,blend));}}
  float medianAxis(ArrayList<SkeletonHistorySample> samples,int axis){float[] values=new float[samples.size()];
    for(int i=0;i<values.length;i++){PVector p=samples.get(i).world;values[i]=axis==0?p.x:(axis==1?p.y:p.z);
      }Arrays.sort(values);int n=values.length;return (n&1)==1?values[n/2]:(values[n/2-1]+values[n/2])*.5f;
    }
}

class SkeletonRootStabilizer {
  final SkeletonConfig cfg;PVector root=new PVector(),velocity=new PVector(),raw=new PVector();
  boolean initialized=false;long tickMs=0;
  SkeletonRootStabilizer(SkeletonConfig c){cfg=c;}void reset(){initialized=false;
    root.set(0,0,0);velocity.set(0,0,0);raw.set(0,0,0);tickMs=0;}
  float alpha(float dt,float cutoff){float tau=1.0f/(TWO_PI*max(.001f,cutoff));return 1.0f/(1.0f+tau/max(.001f,dt));
    }
  PVector observedRoot(SkeletonPose3D s){ArrayList<SkeletonJoint3D> js=new ArrayList<SkeletonJoint3D>();
    if(s.hipCenter.tracked())js.add(s.hipCenter);if(s.spine.tracked())js.add(s.spine);
    if(s.leftHip.tracked())js.add(s.leftHip);if(s.rightHip.tracked())js.add(s.rightHip);
    if(js.size()<2)return null;PVector r=new PVector();float w=0;for(SkeletonJoint3D j:js){float q=max(.08f,j.confidence);
      r.add(PVector.mult(j.world,q));w+=q;}return w>0?r.div(w):null;}
  SkeletonJoint3D[] joints(SkeletonPose3D s){return new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,s.leftElbow,
      s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot}
    ;}
  void apply(SkeletonPose3D s,long now,SkeletonCalibration3D cal){PVector observed=observedRoot(s);
    if(observed==null)return;if(!initialized){initialized=true;root.set(observed);
      raw.set(observed);tickMs=now;return;}float dt=constrain((now-tickMs)/1000.0f,.008f,.12f);
    PVector rv=PVector.sub(observed,raw);rv.div(dt);float da=alpha(dt,cfg.rootDerivativeCutoff);
    velocity=PVector.lerp(velocity,rv,da);float cutoff=cfg.rootMinCutoff+cfg.rootBeta*velocity.mag(),a=alpha(dt,cutoff);
    PVector filtered=PVector.lerp(root,observed,a),correction=PVector.sub(filtered,observed);
    float mag=correction.mag();if(mag>cfg.rootMaxCorrectionM)correction.mult(cfg.rootMaxCorrectionM/mag);
    if(correction.mag()>.0001f){for(SkeletonJoint3D j:joints(s))if(j!=null&&j.tracked()){j.world.add(correction);
        PVector uv=cal.projectWorldRgb(j.world);if(uv!=null)j.image.set(uv);}}raw.set(observed);
    root.set(PVector.add(observed,correction));tickMs=now;}
}


class SkeletonIdentityPredictor {
  final SkeletonConfig cfg;
  PVector center=new PVector(),velocity=new PVector();
  float depthM=0,depthVelocity=0;long tickMs=0;boolean initialized=false;
  SkeletonIdentityPredictor(SkeletonConfig c){cfg=c;}
  void reset(){center.set(0,0,0);velocity.set(0,0,0);depthM=0;depthVelocity=0;tickMs=0;
    initialized=false;}
  PVector predictedCenter(long now){
    if(!initialized)return null;
    float dt=constrain((now-tickMs)/1000.0f,0,.18f);
    PVector delta=PVector.mult(velocity,dt);
    if(delta.mag()>cfg.identityMaxPredictionPx)delta.setMag(cfg.identityMaxPredictionPx);
    
    return PVector.add(center,delta);
  }
  float predictedDepth(long now){
    if(!initialized||depthM<=0)return 0;
    float dt=constrain((now-tickMs)/1000.0f,0,.18f);
    return max(.1f,depthM+constrain(depthVelocity*dt,-cfg.identityMaxPredictionM,cfg.identityMaxPredictionM));
    
  }
  void update(SkeletonPose3D s,long now,SkeletonCalibration3D cal){
    if(s==null)return;
    SkeletonJoint3D anchor=s.spine.tracked()?s.spine:(s.hipCenter.tracked()?s.hipCenter:s.shoulderCenter);
    
    if(anchor==null||!anchor.tracked()||anchor.world.z<=0)return;
    PVector uv=cal.projectDepth(anchor.world);if(uv==null)return;
    if(!initialized){center.set(uv);depthM=anchor.world.z;tickMs=now;initialized=true;
      return;}
    float dt=constrain((now-tickMs)/1000.0f,.008f,.18f);
    PVector measuredVelocity=PVector.sub(uv,center);measuredVelocity.div(dt);
    velocity=PVector.lerp(velocity,measuredVelocity,cfg.identityVelocityAlpha);
    float measuredDepthVelocity=(anchor.world.z-depthM)/dt;
    depthVelocity=lerp(depthVelocity,measuredDepthVelocity,cfg.identityVelocityAlpha);
    
    center.set(uv);depthM=anchor.world.z;tickMs=now;
  }
  void miss(){velocity.mult(.82f);depthVelocity*=.82f;}
}

class SkeletonJoint3D {
  final String name;PVector image=new PVector(),world=new PVector();float confidence=0;
  int state=0; // 0 lost, 1 inferred, 2 tracked
  SkeletonJoint3D(String n){name=n;}SkeletonJoint3D set(PVector uv,PVector xyz,float q,int s){if(uv!=null)image.set(uv);
    if(xyz!=null)world.set(xyz);confidence=q;state=s;return this;}boolean tracked(){return state>0&&confidence>0;
    }
}
class SkeletonPose3D {
  boolean tracked=false;long trackingId=0;float confidence=0,torsoConfidence=0,upperBodyConfidence=0,interactionConfidence=0;
  String reason="searching";int minX,minY,maxX,maxY;float meanDepthM=0,faceWidthPx=0,faceHeightPx=0;
  
  boolean clippedTop=false,clippedBottom=false;
  // Kinect Xbox 360/NUI topology and naming: ShoulderCenter and HipCenter are explicit joints.
  SkeletonJoint3D head=new SkeletonJoint3D("head"),shoulderCenter=new SkeletonJoint3D("shoulder_center"),spine=new SkeletonJoint3D("spine");
  
  SkeletonJoint3D leftShoulder=new SkeletonJoint3D("left_shoulder"),rightShoulder=new SkeletonJoint3D("right_shoulder"),leftElbow=new SkeletonJoint3D("left_elbow"),
  rightElbow=new SkeletonJoint3D("right_elbow"),leftWrist=new SkeletonJoint3D("left_wrist"),rightWrist=new SkeletonJoint3D("right_wrist"),leftHand=new SkeletonJoint3D("left_hand"),
  rightHand=new SkeletonJoint3D("right_hand");
  SkeletonJoint3D hipCenter=new SkeletonJoint3D("hip_center"),leftHip=new SkeletonJoint3D("left_hip"),rightHip=new SkeletonJoint3D("right_hip"),leftKnee=new SkeletonJoint3D("left_knee"),
  rightKnee=new SkeletonJoint3D("right_knee"),leftAnkle=new SkeletonJoint3D("left_ankle"),rightAnkle=new SkeletonJoint3D("right_ankle"),leftFoot=new SkeletonJoint3D("left_foot"),
  rightFoot=new SkeletonJoint3D("right_foot");
  float lowerBodyConfidence=0;
  boolean torsoTracked(){return shoulderCenter.tracked()&&spine.tracked()&&hipCenter.tracked()&&leftShoulder.tracked()&&rightShoulder.tracked();
    }
  boolean leftHandTracked(){return leftHand.tracked();}boolean rightHandTracked(){return rightHand.tracked();
    }
  boolean interactionTracked(){return tracked&&torsoTracked()&&(leftHandTracked()||rightHandTracked())&&interactionConfidence>0;
    }
  SkeletonJoint3D[] nui20(){return new SkeletonJoint3D[]{hipCenter,spine,shoulderCenter,head,leftShoulder,leftElbow,leftWrist,leftHand,rightShoulder,rightElbow,
      rightWrist,rightHand,leftHip,leftKnee,leftAnkle,leftFoot,rightHip,rightKnee,rightAnkle,rightFoot};
    }
}
class SkeletonPublisher {
  static final int MAGIC=0x49554E52,FRAME_MAGIC=0x46554E52,VERSION=1,ROLE_PUBLISH=2,JOINTS=20,MAX_SKELETONS=6,REPLY_BYTES=20,FRAME_BYTES=2528;
  
  LocalTransport transport;long retryAfterMs=0;
  boolean supported(){return (studio.services.transportFactory.isLinux()||studio.services.transportFactory.isWindows())&&studio.services.endpoints.skeletonAvailable();
    }
  void ensureConnected()throws IOException{
    if(transport!=null)return;long now=millis64();if(now<retryAfterMs)throw new IOException("NUI skeleton publisher backoff");
    
    LocalTransport next=null;
    try{
      next=studio.services.transportFactory.open(studio.services.endpoints.skeleton.windowsPath,studio.services.endpoints.skeleton.linuxPath);
      
      ByteBuffer hello=ByteBuffer.allocate(80).order(ByteOrder.LITTLE_ENDIAN);hello.putInt(MAGIC).putInt(VERSION).putInt(ROLE_PUBLISH).putInt(0);
      putFixedDeviceId(hello,selectedKinectDeviceId());next.write(hello.array());
      
      byte[] rb=new byte[REPLY_BYTES];next.readFully(rb);ByteBuffer reply=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
      
      int magic=reply.getInt(),version=reply.getInt(),result=reply.getInt(),joints=reply.getInt(),maxSkeletons=reply.getInt();
      
      if(magic!=MAGIC||version!=VERSION||result<0||joints!=JOINTS||maxSkeletons<1)throw new IOException("NUI skeleton publisher rejected: "+result);
      
      transport=next;next=null;
    }finally{if(next!=null)try{next.close();}catch(IOException ignored){}}
  }
  void publish(SkeletonPose3D skeleton,long frameNumber){
    if(!supported())return;
    try{
      ensureConnected();ByteBuffer b=ByteBuffer.allocate(FRAME_BYTES).order(ByteOrder.LITTLE_ENDIAN);
      
      boolean present=skeleton!=null&&skeleton.trackingId!=0;int bodyCount=present?1:0;
      
      b.putInt(FRAME_MAGIC).putInt(VERSION).putInt(bodyCount).putInt(0).putLong(frameNumber).putLong(millis64());
      
      for(int body=0;body<MAX_SKELETONS;body++){
        if(body==0&&present){
          b.putLong(skeleton.trackingId).putInt(skeleton.tracked?2:1).putInt(0);SkeletonJoint3D[] joints=skeleton.nui20();
          
          for(int j=0;j<JOINTS;j++){SkeletonJoint3D q=j<joints.length?joints[j]:null;
            if(q!=null){b.putFloat(q.world.x).putFloat(q.world.y).putFloat(q.world.z).putFloat(q.confidence).putInt(constrain(q.state,0,2));
              }else putEmptyJoint(b);}
        }else{b.putLong(0).putInt(0).putInt(0);for(int j=0;j<JOINTS;j++)putEmptyJoint(b);
          }
      }
      transport.write(b.array());
    }catch(IOException e){close();retryAfterMs=millis64()+750;}
  }
  void putEmptyJoint(ByteBuffer b){b.putFloat(0).putFloat(0).putFloat(0).putFloat(0).putInt(0);
    }
  void close(){if(transport!=null){try{transport.close();}catch(IOException ignored){}transport=null;
      }}
}

class SkeletonCalibration3D {
  final Calibration sharedCalibration;final RgbDepthRegistration sharedRegistration;
  
  SkeletonCalibration3D(Calibration cal,RgbDepthRegistration reg){sharedCalibration=cal;
    sharedRegistration=reg;}
  PVector deproject(int u,int v,int mm){int uu=constrain(u,0,studio.services.scannerProtocol.WIDTH-1),vv=constrain(v,0,studio.services.scannerProtocol.HEIGHT-1),
    i=vv*studio.services.scannerProtocol.WIDTH+uu;float z=mm*sharedCalibration.depthScale;
    return new PVector(sharedRegistration.pointX(i,z),sharedRegistration.pointY(i,z),z);
    }
  PVector projectRgb(int u,int v,int mm){int uu=constrain(u,0,studio.services.scannerProtocol.WIDTH-1),vv=constrain(v,0,studio.services.scannerProtocol.HEIGHT-1),
    i=vv*studio.services.scannerProtocol.WIDTH+uu;float z=mm*sharedCalibration.depthScale;
    RgbProjection q=new RgbProjection();sharedRegistration.project(i,z,q,0,0);return q.valid?new PVector(q.u,q.v):null;
    }
  PVector projectDepth(PVector world){if(world==null||world.z<=0.001f)return null;
    return new PVector(sharedCalibration.fx*world.x/world.z+sharedCalibration.cx,sharedCalibration.fy*world.y/world.z+sharedCalibration.cy);
    }
  PVector projectWorldRgb(PVector world){PVector d=projectDepth(world);if(d==null)return null;
    int mm=round(world.z/max(1e-9f,sharedCalibration.depthScale));return projectRgb(round(d.x),round(d.y),mm);
    }
}

class SkeletonBodyPoint {
  float x,y,confidence;boolean valid;
  SkeletonBodyPoint(){}
  SkeletonBodyPoint(float x,float y,float q){this.x=x;this.y=y;confidence=q;valid=true;
    }
}

// SynSkeleton depth fusion is the body model. It estimates a metric-depth person
// component, follows articulated limb paths through the silhouette, projects accepted
// landmarks into calibrated 3D, and then applies temporal and anthropometric constraints.
// The public topology follows the Kinect Xbox 360/NUI 20-joint order and naming exactly.
class SkeletonDepthBodyMask {
  final int width,height,step,gridW,gridH;final boolean[] mask;final int[] mm,clearance;
  final DepthFrame sourceDepth;
  int minGX=0,maxGX=0,minGY=0,maxGY=0,samples=0,seedDepthMm=0;float confidence=0,centerX=0,centerY=0;
  
  SkeletonDepthBodyMask(int w,int h,int s,DepthFrame depth){width=w;height=h;step=s;
    sourceDepth=depth;gridW=(w+s-1)/s;gridH=(h+s-1)/s;mask=new boolean[gridW*gridH];
    mm=new int[gridW*gridH];clearance=new int[gridW*gridH];}
  int px(int gx){return constrain(gx*step+step/2,0,width-1);}int py(int gy){return constrain(gy*step+step/2,0,height-1);
    }
}

class SkeletonDepthPersonSegmenter {
  final SkeletonConfig cfg;final int[] robustSamples=new int[5];SkeletonDepthPersonSegmenter(SkeletonConfig c){cfg=c;
    }
  SkeletonDepthBodyMask segment(DepthFrame depth,PVector priorCenter,float priorDepthM){
    int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT,step=max(2,cfg.bodySampleStep);
    
    if(depth==null||depth.depth==null||depth.depth.length<w*h)return null;
    SkeletonDepthBodyMask out=new SkeletonDepthBodyMask(w,h,step,depth);
    int bins=max(1,(cfg.maxDepthMm-cfg.minDepthMm+cfg.bodyDepthBinMm-1)/cfg.bodyDepthBinMm);
    int[] hist=new int[bins],central=new int[bins];
    for(int gy=0;gy<out.gridH;gy++)for(int gx=0;gx<out.gridW;gx++){
      int x=out.px(gx),y=out.py(gy),mm=robustDepth(depth,x,y,w,h),idx=gy*out.gridW+gx;
      out.mm[idx]=mm;
      if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm)continue;int b=constrain((mm-cfg.minDepthMm)/cfg.bodyDepthBinMm,0,bins-1);
      hist[b]++;
      if(x>=w*.16f&&x<=w*.84f&&y>=h*.06f&&y<=h*.96f)central[b]++;
    }
    // Multi-hypothesis depth segmentation retains several strong depth modes.
    // The tracker is not committed to the single largest histogram peak. This
    // keeps the same person through partial occlusion and prevents a nearer bystander
    // from stealing identity merely because they occupy more depth pixels.
    double[] binScore=new double[bins];Arrays.fill(binScore,-Double.MAX_VALUE);
    for(int b=0;b<bins;b++){
      if(hist[b]<max(16,cfg.bodyMinSamples/3))continue;double z=(cfg.minDepthMm+(b+.5)*cfg.bodyDepthBinMm)/1000.0;
      double centerRatio=central[b]/(double)max(1,hist[b]);double capped=min(hist[b],cfg.bodyHistogramCapSamples);
      double temporalDepth=priorDepthM>0?Math.exp(-Math.abs(z-priorDepthM)/max(.05f,cfg.bodyTemporalDepthM)):0;
      binScore[b]=capped*(1.0+cfg.bodyCenterBias*centerRatio)*(1.0+.95*temporalDepth)/(z*z);
      
    }
    int keep=min(cfg.bodyDepthHypotheses,bins),minSep=max(1,round(180.0f/max(1,cfg.bodyDepthBinMm)));
    int[] peaks=new int[keep];Arrays.fill(peaks,-1);boolean[] suppressed=new boolean[bins];
    int peakCount=0;
    for(int k=0;k<keep;k++){int best=-1;double score=-Double.MAX_VALUE;for(int b=0;b<bins;b++)if(!suppressed[b]&&binScore[b]>score){score=binScore[b];
        best=b;}if(best<0||score==-Double.MAX_VALUE)break;peaks[peakCount++]=best;
      for(int b=max(0,best-minSep);b<=min(bins-1,best+minSep);b++)suppressed[b]=true;
      }
    if(peakCount==0)return null;
    boolean[] candidate=new boolean[out.mask.length];
    for(int i=0;i<candidate.length;i++){int mm=out.mm[i];if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm)continue;
      for(int k=0;k<peakCount;k++){int seed=cfg.minDepthMm+peaks[k]*cfg.bodyDepthBinMm+cfg.bodyDepthBinMm/2;
        if(abs(mm-seed)<=cfg.bodyDepthBandMm){candidate[i]=true;break;}}}
    int[] labels=new int[candidate.length];Arrays.fill(labels,-1);int component=0,bestId=-1,bestCount=0,bestDepthMm=0;
    double bestComponentScore=-1;int[] queue=new int[candidate.length];
    for(int seed=0;seed<candidate.length;seed++){
      if(!candidate[seed]||labels[seed]>=0)continue;int qh=0,qt=0;queue[qt++]=seed;
      labels[seed]=component;int count=0,minGX=out.gridW,minGY=out.gridH,maxGX=-1,maxGY=-1;
      long sumX=0,sumY=0,sumD=0;int centerCount=0;
      while(qh<qt){int at=queue[qh++],gx=at%out.gridW,gy=at/out.gridW,dm=out.mm[at];
        count++;minGX=min(minGX,gx);maxGX=max(maxGX,gx);minGY=min(minGY,gy);maxGY=max(maxGY,gy);
        sumX+=out.px(gx);sumY+=out.py(gy);sumD+=dm;if(out.px(gx)>=w*.20f&&out.px(gx)<=w*.80f)centerCount++;
        
        for(int oy=-1;oy<=1;oy++)for(int ox=-1;ox<=1;ox++){if(ox==0&&oy==0)continue;
          int nx=gx+ox,ny=gy+oy;if(nx<0||ny<0||nx>=out.gridW||ny>=out.gridH)continue;
          int ni=ny*out.gridW+nx;if(!candidate[ni]||labels[ni]>=0)continue;int nd=out.mm[ni];
          int continuity=round(cfg.bodyContinuityMm*map(constrain((dm+nd)*.5f,cfg.minDepthMm,cfg.maxDepthMm),cfg.minDepthMm,cfg.maxDepthMm,.78f,1.18f));
          if(abs(nd-dm)>continuity)continue;labels[ni]=component;queue[qt++]=ni;}
        // Kinect Xbox 360 depth silhouettes contain narrow invalid seams around clothing,
        // limbs and reflective surfaces. Bridge only short cardinal gaps between
        // valid samples at nearly the same depth; invalid pixels never become joints.
        if(cfg.bodyBridgeCells>0){int[] dx={-1,1,0,0},dy={0,0,-1,1};for(int dir=0;dir<4;dir++)for(int hop=2;hop<=cfg.bodyBridgeCells+1;hop++){int nx=gx+dx[dir]*hop,
            ny=gy+dy[dir]*hop;if(nx<0||ny<0||nx>=out.gridW||ny>=out.gridH)break;int ni=ny*out.gridW+nx;
            if(candidate[ni]){if(labels[ni]<0&&abs(out.mm[ni]-dm)<=round(cfg.bodyContinuityMm*.72f)){labels[ni]=component;
                queue[qt++]=ni;}break;}}}
      }
      int bw=(maxGX-minGX+1)*step,bh=(maxGY-minGY+1)*step;float aspect=bh/(float)max(1,bw),widthRatio=bw/(float)w,centerRatio=centerCount/(float)max(1,
        count),meanDepth=(float)(sumD/(double)max(1,count));
      boolean[] occupiedRows=new boolean[out.gridH];for(int qi=0;qi<qt;qi++)occupiedRows[queue[qi]/out.gridW]=true;
      int rowCount=0;for(int gy=minGY;gy<=maxGY;gy++)if(occupiedRows[gy])rowCount++;
      float rowCoverage=rowCount/(float)max(1,maxGY-minGY+1),fillRatio=count/(float)max(1,(maxGX-minGX+1)*(maxGY-minGY+1));
      
      if(count>=cfg.bodyMinSamples&&bh>=cfg.bodyMinHeightPx&&widthRatio<=cfg.bodyMaxWidthRatio&&aspect>=cfg.bodyMinAspect&&rowCoverage>=cfg.bodyMinRowCoverage&&fillRatio>=cfg.bodyMinFillRatio){
        
        float cx=sumX/(float)count,cy=sumY/(float)count;double temporal=0;if(priorCenter!=null&&priorDepthM>0){double centerD=Math.hypot(cx-priorCenter.x,
            cy-priorCenter.y);double depthD=Math.abs(meanDepth/1000.0-priorDepthM);
          temporal=Math.exp(-centerD/Math.max(10.0,(double)cfg.bodyTemporalCenterPx))*Math.exp(-depthD/Math.max(.05,(double)cfg.bodyTemporalDepthM));
          }
        double hypothesis=0;for(int k=0;k<peakCount;k++){int seedMm=cfg.minDepthMm+peaks[k]*cfg.bodyDepthBinMm+cfg.bodyDepthBinMm/2;
          hypothesis=max((float)hypothesis,(float)Math.exp(-Math.abs(meanDepth-seedMm)/max(80.0f,cfg.bodyDepthBandMm*.55f)));
          }
        double continuityShape=.72+.18*rowCoverage+.10*constrain(fillRatio/.32f,0,1);
        float humanShape=humanShapeScore(out,labels,component,minGX,maxGX,minGY,maxGY);
        double shapeFactor=lerp(1.0f-cfg.bodyHumanShapeWeight*.36f,1.0f+cfg.bodyHumanShapeWeight*.30f,humanShape);
        double score=count*(.70+.60*centerRatio)*(1.0+min(1.5f,aspect)*.20)*(1.0+2.35*temporal)*(.82+.18*hypothesis)*continuityShape*shapeFactor/(max(.55f,
          meanDepth/1000.0f));if(priorCenter!=null&&priorDepthM>0&&temporal<.045)score*=cfg.bodyTemporalRejectScale;
        
        if(score>bestComponentScore){bestComponentScore=score;bestId=component;bestCount=count;
          bestDepthMm=round(meanDepth);out.minGX=minGX;out.maxGX=maxGX;out.minGY=minGY;
          out.maxGY=maxGY;out.centerX=cx;out.centerY=cy;}
      }
      component++;
    }
    if(bestId<0)return null;for(int i=0;i<labels.length;i++)out.mask[i]=labels[i]==bestId;
    out.samples=bestCount;out.seedDepthMm=bestDepthMm;computeClearance(out);
    int bh=(out.maxGY-out.minGY+1)*step,bw=(out.maxGX-out.minGX+1)*step;float sizeScore=constrain(bestCount/(float)max(cfg.bodyMinSamples*4,1),0,1),shape=constrain((bh/(float)max(1,
      bw)-cfg.bodyMinAspect)/1.4f+.45f,.25f,1);out.confidence=constrain(.38f+.40f*sizeScore+.22f*shape,0,1);
    return out;
  }
  int robustDepth(DepthFrame depth,int x,int y,int w,int h){
    int radius=cfg.bodyRobustDepthRadiusPx,n=0;if(radius<=0){int d=depth.depth[y*w+x]&0xffff;
      return d;}
    int[][] off={{0,0},{-radius,0},{radius,0},{0,-radius},{0,radius}};for(int i=0;i<off.length;i++){int xx=constrain(x+off[i][0],0,w-1),yy=constrain(y+off[i][1],
        0,h-1),d=depth.depth[yy*w+xx]&0xffff;if(d>=cfg.minDepthMm&&d<=cfg.maxDepthMm)robustSamples[n++]=d;
      }
    if(n==0)return 0;for(int i=1;i<n;i++){int v=robustSamples[i],j=i-1;while(j>=0&&robustSamples[j]>v){robustSamples[j+1]=robustSamples[j];
        j--;}robustSamples[j+1]=v;}return robustSamples[n/2];
  }
  float humanShapeScore(SkeletonDepthBodyMask b,int[] labels,int component,int minGX,int maxGX,int minGY,int maxGY){
    int rows=max(1,maxGY-minGY+1);float head=componentBandWidth(b,labels,component,minGX,maxGX,minGY,maxGY,.08f,.20f),shoulders=componentBandWidth(b,labels,
      component,minGX,maxGX,minGY,maxGY,.20f,.38f),torso=componentBandWidth(b,labels,component,minGX,maxGX,minGY,maxGY,.38f,.62f),lower=componentBandWidth(b,
      labels,component,minGX,maxGX,minGY,maxGY,.64f,.88f);float score=0,weight=0;
    
    if(head>0&&shoulders>0){score+=softRange(shoulders/max(head,1),.78f,3.6f,.35f)*.28f;
      weight+=.28f;}if(shoulders>0&&torso>0){score+=softRange(torso/max(shoulders,1),.42f,1.42f,.30f)*.26f;
      weight+=.26f;}if(torso>0&&lower>0){score+=softRange(lower/max(torso,1),.34f,1.55f,.38f)*.18f;
      weight+=.18f;}
    float fullW=max(1,(maxGX-minGX+1)*b.step),fullH=max(1,rows*b.step),aspect=fullH/fullW;
    score+=softRange(aspect,.92f,4.8f,.55f)*.28f;weight+=.28f;return weight>0?constrain(score/weight,0,1):.5f;
    
  }
  float componentBandWidth(SkeletonDepthBodyMask b,int[] labels,int component,int minGX,int maxGX,int minGY,int maxGY,float t0,float t1){int y0=minGY+round((maxGY-minGY)*t0),
    y1=minGY+round((maxGY-minGY)*t1),rows=0;float sum=0;for(int gy=max(minGY,y0);gy<=min(maxGY,y1);gy++){int lo=b.gridW,hi=-1;
      for(int gx=minGX;gx<=maxGX;gx++){int i=gy*b.gridW+gx;if(labels[i]==component){lo=min(lo,gx);
          hi=max(hi,gx);}}if(hi>=lo){sum+=(hi-lo+1)*b.step;rows++;}}return rows==0?0:sum/rows;
    }
  float softRange(float v,float lo,float hi,float feather){if(v>=lo&&v<=hi)return 1;
    float d=v<lo?lo-v:v-hi;return constrain(1-d/max(.001f,feather),0,1);}
  void computeClearance(SkeletonDepthBodyMask b){int inf=1<<20;Arrays.fill(b.clearance,inf);
    for(int gy=b.minGY;gy<=b.maxGY;gy++)for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;
      if(!b.mask[i]){b.clearance[i]=0;continue;}boolean edge=gx==0||gy==0||gx==b.gridW-1||gy==b.gridH-1;
      if(!edge){edge=!b.mask[i-1]||!b.mask[i+1]||!b.mask[i-b.gridW]||!b.mask[i+b.gridW];
        }if(edge)b.clearance[i]=3;}for(int gy=b.minGY;gy<=b.maxGY;gy++)for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;
      if(!b.mask[i])continue;int v=b.clearance[i];if(gx>0)v=min(v,b.clearance[i-1]+3);
      if(gy>0)v=min(v,b.clearance[i-b.gridW]+3);if(gx>0&&gy>0)v=min(v,b.clearance[i-b.gridW-1]+4);
      if(gx+1<b.gridW&&gy>0)v=min(v,b.clearance[i-b.gridW+1]+4);b.clearance[i]=v;
      }for(int gy=b.maxGY;gy>=b.minGY;gy--)for(int gx=b.maxGX;gx>=b.minGX;gx--){int i=gy*b.gridW+gx;
      if(!b.mask[i])continue;int v=b.clearance[i];if(gx+1<b.gridW)v=min(v,b.clearance[i+1]+3);
      if(gy+1<b.gridH)v=min(v,b.clearance[i+b.gridW]+3);if(gx+1<b.gridW&&gy+1<b.gridH)v=min(v,b.clearance[i+b.gridW+1]+4);
      if(gx>0&&gy+1<b.gridH)v=min(v,b.clearance[i+b.gridW-1]+4);b.clearance[i]=v;
      }}
}

class SkeletonJointFilterState {
  PVector raw=new PVector(),world=new PVector(),velocity=new PVector(),image=new PVector();
  long tickMs=0;int missing=0;boolean initialized=false;
}
class SkeletonPoseFilter {
  final SkeletonConfig cfg;final HashMap<String,SkeletonJointFilterState> states=new HashMap<String,SkeletonJointFilterState>();
  
  SkeletonPoseFilter(SkeletonConfig c){cfg=c;}void reset(){states.clear();}
  SkeletonJoint3D[] joints(SkeletonPose3D s){return new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,s.leftElbow,
      s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot}
    ;}
  void apply(SkeletonPose3D s,long tickMs,SkeletonCalibration3D cal){for(SkeletonJoint3D j:joints(s))filter(j,tickMs,cal);
    }
  // Biomechanical projection runs after the adaptive filter. Commit only fully
  // observed joints back into the temporal state so the next frame predicts
  // from the pose that was actually published, not from pre-projection geometry.
  void commitMeasured(SkeletonPose3D s,long tickMs){for(SkeletonJoint3D j:joints(s)){if(j==null||j.state!=2||j.world.z<=0)continue;
      SkeletonJointFilterState st=states.get(j.name);if(st==null){st=new SkeletonJointFilterState();
        states.put(j.name,st);}st.initialized=true;st.raw.set(j.world);st.world.set(j.world);
      st.image.set(clampUv(j.image));st.tickMs=tickMs;st.missing=0;st.velocity.mult(.90f);
      }}
  float alpha(float dt,float cutoff){float safe=max(.001f,cutoff),tau=1.0f/(TWO_PI*safe);
    return 1.0f/(1.0f+tau/max(.001f,dt));}
  float jointResponsiveness(String name){if(name==null)return 1.0f;String n=name.toLowerCase(Locale.ROOT);
    if(n.endsWith("_hand")||n.endsWith("_wrist")||n.endsWith("_foot"))return 1.18f;
    if(n.endsWith("_elbow")||n.endsWith("_knee")||n.endsWith("_ankle"))return 1.07f;
    if("head".equals(name)||"shoulder_center".equals(name)||"spine".equals(name)||"hip_center".equals(name))return .82f;
    return .94f;}
  float jointJitterScale(String name){if(name==null)return 1.0f;String n=name.toLowerCase(Locale.ROOT);
    if(n.endsWith("_hand")||n.endsWith("_wrist"))return .78f;if("head".equals(name)||"shoulder_center".equals(name)||"spine".equals(name)||"hip_center".equals(name))return 1.28f;
    return 1.0f;}
  void filter(SkeletonJoint3D j,long tickMs,SkeletonCalibration3D cal){
    if(j==null)return;SkeletonJointFilterState st=states.get(j.name);if(st==null){st=new SkeletonJointFilterState();
      states.put(j.name,st);}
    if(j.tracked()&&j.world.z>0){
      if(!st.initialized){st.raw.set(j.world);st.world.set(j.world);st.image.set(clampUv(j.image));
        st.tickMs=tickMs;st.initialized=true;st.missing=0;j.image.set(st.image);return;
        }
      float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f),response=jointResponsiveness(j.name);
      PVector predicted=PVector.add(st.world,PVector.mult(st.velocity,dt));float innovation=PVector.dist(predicted,j.world),speedLimit=cfg.poseMaxSpeedMps*response,
      gate=max(cfg.poseInnovationGateM*lerp(1.35f,.82f,constrain(j.confidence,0,1)),speedLimit*dt*1.35f);
      if(innovation>gate){PVector delta=PVector.sub(j.world,predicted);if(delta.mag()>0)delta.setMag(gate);
        j.world.set(PVector.add(predicted,delta));j.confidence*=constrain(gate/max(innovation,.001f),.35f,1);
        }
      float jitter=cfg.poseJitterRadiusM*jointJitterScale(j.name)*lerp(1.45f,.82f,constrain(j.confidence,0,1)),residual=PVector.dist(st.world,j.world);
      if(residual<jitter){float blend=constrain(residual/max(jitter,.001f),0,1);j.world.set(PVector.lerp(st.world,j.world,.14f+.36f*blend));
        }
      PVector rawVelocity=PVector.sub(j.world,st.raw);rawVelocity.div(dt);float da=constrain(alpha(dt,cfg.poseOneEuroDerivativeCutoff)*.55f+cfg.poseVelocityAlpha*.45f,
        .02f,.9f);st.velocity=PVector.lerp(st.velocity,rawVelocity,da);if(st.velocity.mag()>speedLimit)st.velocity.mult(speedLimit/st.velocity.mag());
      
      float cutoff=(cfg.poseOneEuroMinCutoff+cfg.poseOneEuroBeta*st.velocity.mag())*response;
      float a=alpha(dt,cutoff);float confidenceGain=lerp(.48f,1.0f,constrain(j.confidence,0,1));
      a=constrain(a*confidenceGain,cfg.poseFilterMinAlpha,cfg.poseFilterMaxAlpha);
      
      st.raw.set(j.world);st.world=PVector.lerp(st.world,j.world,a);PVector uv=cal.projectWorldRgb(st.world);
      st.image.set(clampUv(uv!=null?uv:j.image));st.tickMs=tickMs;st.missing=0;j.world.set(st.world);
      j.image.set(st.image);
    }else if(st.initialized&&st.missing<cfg.poseOcclusionHoldFrames){
      st.missing++;float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f);st.velocity.mult(.88f);
      PVector predicted=PVector.add(st.world,PVector.mult(st.velocity,dt));PVector uv=cal.projectWorldRgb(predicted);
      
      if(uv!=null&&inside(uv)){st.world.set(predicted);st.raw.set(predicted);st.image.set(clampUv(uv));
        st.tickMs=tickMs;j.world.set(st.world);j.image.set(st.image);j.confidence=max(.08f,.38f*(1-st.missing/(float)(cfg.poseOcclusionHoldFrames+1)));
        j.state=1;}
    }else st.missing++;
  }
  boolean inside(PVector p){return p.x>=0&&p.x<studio.services.scannerProtocol.WIDTH&&p.y>=0&&p.y<studio.services.scannerProtocol.HEIGHT;
    }
  PVector clampUv(PVector p){if(p==null)return new PVector();return new PVector(constrain(p.x,0,studio.services.scannerProtocol.WIDTH-1),constrain(p.y,
      0,studio.services.scannerProtocol.HEIGHT-1));}
}

class SkeletonKalmanState {
  PVector position=new PVector(),velocity=new PVector();float p00=1,p01=0,p10=0,p11=1;
  long tickMs=0;boolean initialized=false;
}
class SkeletonKalmanBank {
  final SkeletonConfig cfg;final HashMap<String,SkeletonKalmanState> states=new HashMap<String,SkeletonKalmanState>();
  
  SkeletonKalmanBank(SkeletonConfig c){cfg=c;}void reset(){states.clear();}
  SkeletonJoint3D[] joints(SkeletonPose3D s){return new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,s.leftElbow,
      s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot}
    ;}
  void apply(SkeletonPose3D s,long tickMs,SkeletonCalibration3D cal){for(SkeletonJoint3D j:joints(s))filter(j,tickMs,cal);
    }
  void filter(SkeletonJoint3D j,long tickMs,SkeletonCalibration3D cal){if(j==null||!j.tracked()||j.world.z<=0)return;
    SkeletonKalmanState st=states.get(j.name);if(st==null){st=new SkeletonKalmanState();
      states.put(j.name,st);}if(!st.initialized){st.position.set(j.world);st.velocity.set(0,0,0);
      st.tickMs=tickMs;st.p00=.04f;st.p11=.20f;st.initialized=true;return;}float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f),dt2=dt*dt,dt3=dt2*dt,
    dt4=dt2*dt2,q=cfg.kalmanProcessNoise;PVector predicted=PVector.add(st.position,PVector.mult(st.velocity,dt));
    float p00=st.p00+dt*(st.p01+st.p10)+dt2*st.p11+q*dt4*.25f,p01=st.p01+dt*st.p11+q*dt3*.5f,p10=st.p10+dt*st.p11+q*dt3*.5f,p11=st.p11+q*dt2;
    float depthNoise=cfg.kalmanDepthNoiseScale*j.world.z*j.world.z,measurement=max(.003f,cfg.kalmanMeasurementNoiseM+depthNoise)*lerp(2.6f,.72f,constrain(j.confidence,
      0,1));float r=measurement*measurement,den=max(1e-7f,p00+r),k0=p00/den,k1=p10/den;
    PVector innovation=PVector.sub(j.world,predicted);st.position.set(PVector.add(predicted,PVector.mult(innovation,k0)));
    st.velocity.set(PVector.add(st.velocity,PVector.mult(innovation,k1)));st.velocity.mult(cfg.kalmanVelocityDamping);
    st.p00=max(1e-7f,(1-k0)*p00);st.p01=(1-k0)*p01;st.p10=p10-k1*p00;st.p11=max(1e-7f,p11-k1*p01);
    st.tickMs=tickMs;PVector published=PVector.add(st.position,PVector.mult(st.velocity,cfg.kalmanPredictionMs/1000.0f));
    j.world.set(published);PVector uv=cal.projectWorldRgb(j.world);if(uv!=null)j.image.set(uv);
    }
}

class SkeletonKinematicOptimizer {
  final SkeletonConfig cfg;final HashMap<String,Float> lengths=new HashMap<String,Float>();
  
  SkeletonKinematicOptimizer(SkeletonConfig c){cfg=c;}void reset(){lengths.clear();
    }
  void optimize(SkeletonPose3D s,SkeletonCalibration3D cal){
    SkeletonJoint3D[] js=joints(s);HashMap<String,PVector> observed=new HashMap<String,PVector>();
    for(SkeletonJoint3D j:js)if(j!=null&&j.tracked())observed.put(j.name,j.world.copy());
    learn(s);
    for(int it=0;it<cfg.modelIterations;it++){anchor(js,observed);solve(s);stabilizeTorso(s);
      }
    for(SkeletonJoint3D j:js){if(j==null||!j.tracked())continue;PVector o=observed.get(j.name);
      if(o!=null){PVector delta=PVector.sub(j.world,o);if(delta.mag()>cfg.modelMaxCorrectionM)j.world.set(PVector.add(o,delta.setMag(cfg.modelMaxCorrectionM)));
        }PVector uv=cal.projectWorldRgb(j.world);if(uv!=null)j.image.set(uv);}
  }
  SkeletonJoint3D[] joints(SkeletonPose3D s){return new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,s.leftElbow,
      s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot}
    ;}
  void anchor(SkeletonJoint3D[] js,HashMap<String,PVector> observed){for(SkeletonJoint3D j:js){if(j==null||!j.tracked())continue;
      PVector o=observed.get(j.name);if(o==null)continue;float k=j.state==2?cfg.modelObservationStiffness*lerp(.55f,1.0f,constrain(j.confidence,0,1)):cfg.modelInferredStiffness;
      j.world.set(PVector.lerp(j.world,o,constrain(k,0,1)));}}
  void learn(SkeletonPose3D s){learnSym("shoulders",s.leftShoulder,s.rightShoulder);
    learnSym("hips",s.leftHip,s.rightHip);learnPair("shoulder_center_head",s.shoulderCenter,s.head);
    learnPair("shoulder_center_spine",s.shoulderCenter,s.spine);learnPair("spine_hip_center",s.spine,s.hipCenter);
    learnSymmetricLimb("upper_arm",s.leftShoulder,s.leftElbow,s.rightShoulder,s.rightElbow);
    learnSymmetricLimb("forearm",s.leftElbow,s.leftWrist,s.rightElbow,s.rightWrist);
    learnSymmetricLimb("hand",s.leftWrist,s.leftHand,s.rightWrist,s.rightHand);learnSymmetricLimb("thigh",s.leftHip,s.leftKnee,s.rightHip,s.rightKnee);
    learnSymmetricLimb("shin",s.leftKnee,s.leftAnkle,s.rightKnee,s.rightAnkle);learnSymmetricLimb("foot",s.leftAnkle,s.leftFoot,s.rightAnkle,s.rightFoot);
    learnSymmetricLimb("shoulder_center_shoulder",s.shoulderCenter,s.leftShoulder,s.shoulderCenter,s.rightShoulder);
    learnSymmetricLimb("hip_center_hip",s.hipCenter,s.leftHip,s.hipCenter,s.rightHip);
    }
  void learnSym(String key,SkeletonJoint3D a,SkeletonJoint3D b){learnPair(key,a,b);
    }void learnSymmetricLimb(String key,SkeletonJoint3D a,SkeletonJoint3D b,SkeletonJoint3D c,SkeletonJoint3D d){float x=measure(a,b),y=measure(c,d);
    if(Float.isFinite(x)&&Float.isFinite(y))learnValue(key,(x+y)*.5f);else if(Float.isFinite(x))learnValue(key,x);
    else if(Float.isFinite(y))learnValue(key,y);}
  void learnPair(String key,SkeletonJoint3D a,SkeletonJoint3D b){float v=measure(a,b);
    if(Float.isFinite(v))learnValue(key,v);}float measure(SkeletonJoint3D a,SkeletonJoint3D b){return a!=null&&b!=null&&a.state==2&&b.state==2&&a.confidence>.60f&&b.confidence>.60f?PVector.dist(a.world,
      b.world):Float.NaN;}
  void learnValue(String key,float observed){if(!Float.isFinite(observed)||observed<.015f||observed>1.5f)return;
    Float old=lengths.get(key);if(old==null){lengths.put(key,observed);return;}float bounded=constrain(observed,old*.84f,old*1.18f);
    lengths.put(key,lerp(old,bounded,cfg.modelLearnAlpha));}
  float target(String key,SkeletonJoint3D a,SkeletonJoint3D b){Float v=lengths.get(key);
    if(v!=null)return v;float d=(a!=null&&b!=null&&a.tracked()&&b.tracked())?PVector.dist(a.world,b.world):Float.NaN;
    return d;}
  void solve(SkeletonPose3D s){bone("shoulder_center_head",s.shoulderCenter,s.head);
    bone("shoulder_center_spine",s.shoulderCenter,s.spine);bone("spine_hip_center",s.spine,s.hipCenter);
    bone("shoulders",s.leftShoulder,s.rightShoulder);bone("hips",s.leftHip,s.rightHip);
    bone("shoulder_center_shoulder",s.shoulderCenter,s.leftShoulder);bone("shoulder_center_shoulder",s.shoulderCenter,s.rightShoulder);
    bone("hip_center_hip",s.hipCenter,s.leftHip);bone("hip_center_hip",s.hipCenter,s.rightHip);
    bone("upper_arm",s.leftShoulder,s.leftElbow);bone("upper_arm",s.rightShoulder,s.rightElbow);
    bone("forearm",s.leftElbow,s.leftWrist);bone("forearm",s.rightElbow,s.rightWrist);
    bone("hand",s.leftWrist,s.leftHand);bone("hand",s.rightWrist,s.rightHand);bone("thigh",s.leftHip,s.leftKnee);
    bone("thigh",s.rightHip,s.rightKnee);bone("shin",s.leftKnee,s.leftAnkle);bone("shin",s.rightKnee,s.rightAnkle);
    bone("foot",s.leftAnkle,s.leftFoot);bone("foot",s.rightAnkle,s.rightFoot);}
  void bone(String key,SkeletonJoint3D a,SkeletonJoint3D b){if(a==null||b==null||!a.tracked()||!b.tracked())return;
    float t=target(key,a,b);if(!Float.isFinite(t)||t<.015f)return;PVector d=PVector.sub(b.world,a.world);
    float len=d.mag();if(len<.001f)return;float err=len-t;d.div(len);float ma=mobility(a),mb=mobility(b),sum=max(.001f,ma+mb),corr=err*cfg.modelBoneStiffness;
    a.world.add(PVector.mult(d,corr*ma/sum));b.world.sub(PVector.mult(d,corr*mb/sum));
    }
  float mobility(SkeletonJoint3D j){if(j==null)return 1;if(j.state!=2)return 1.0f;
    return lerp(.92f,.18f,constrain(j.confidence,0,1));}
  void stabilizeTorso(SkeletonPose3D s){if(!s.leftShoulder.tracked()||!s.rightShoulder.tracked()||!s.leftHip.tracked()||!s.rightHip.tracked())return;
    PVector shoulderMid=PVector.add(s.leftShoulder.world,s.rightShoulder.world).mult(.5f),hipMid=PVector.add(s.leftHip.world,s.rightHip.world).mult(.5f);
    if(s.shoulderCenter.tracked())s.shoulderCenter.world.set(PVector.lerp(s.shoulderCenter.world,shoulderMid,cfg.modelTorsoStiffness*.20f));
    if(s.hipCenter.tracked())s.hipCenter.world.set(PVector.lerp(s.hipCenter.world,hipMid,cfg.modelTorsoStiffness*.24f));
    if(s.spine.tracked()){PVector spineTarget=PVector.lerp(shoulderMid,hipMid,.55f);
      s.spine.world.set(PVector.lerp(s.spine.world,spineTarget,cfg.modelTorsoStiffness*.24f));
      }}
}

class SkeletonGraphNode implements Comparable<SkeletonGraphNode> {
  final int index;final float distance;SkeletonGraphNode(int i,float d){index=i;distance=d;
    }
  public int compareTo(SkeletonGraphNode other){return Float.compare(distance,other.distance);
    }
}
class SkeletonLimbPath {
  int[] nodes=new int[0];float[] cumulative=new float[0];float lengthPx=0,confidence=0;
  boolean valid(){return nodes!=null&&nodes.length>=2&&cumulative!=null&&cumulative.length==nodes.length;
    }
  SkeletonBodyPoint at(SkeletonDepthBodyMask b,float t,float q){if(!valid())return new SkeletonBodyPoint();
    float target=constrain(t,0,1)*lengthPx;int k=0;while(k+1<cumulative.length&&cumulative[k+1]<target)k++;
    if(k+1>=nodes.length){int idx=nodes[nodes.length-1];return new SkeletonBodyPoint(b.px(idx%b.gridW),b.py(idx/b.gridW),q*confidence);
      }int ia=nodes[k],ib=nodes[k+1];float a=cumulative[k],z=cumulative[k+1],u=z>a?constrain((target-a)/(z-a),0,1):0;
    return new SkeletonBodyPoint(lerp(b.px(ia%b.gridW),b.px(ib%b.gridW),u),lerp(b.py(ia/b.gridW),b.py(ib/b.gridW),u),q*confidence);
    }
  SkeletonBodyPoint end(SkeletonDepthBodyMask b,float q){return at(b,1.0f,q);}
}

class SkeletonAnthropometricModel {
  final SkeletonConfig cfg;final HashMap<String,Float> lengths=new HashMap<String,Float>();
  final HashMap<String,PVector> directions=new HashMap<String,PVector>();
  SkeletonAnthropometricModel(SkeletonConfig c){cfg=c;}void reset(){lengths.clear();
    directions.clear();}
  float learned(String key,float observed){
    if(!Float.isFinite(observed)||observed<=0)return lengths.containsKey(key)?lengths.get(key):Float.NaN;
    
    Float old=lengths.get(key);
    if(old==null){lengths.put(key,observed);return observed;}
    // Prevent a single bad joint estimate from teaching an invalid body proportion.
    float ratio=observed/max(old,.001f);
    float bounded=observed;
    if(ratio<.72f||ratio>1.38f)bounded=constrain(observed,old*.86f,old*1.16f);
    float next=lerp(old,bounded,cfg.poseBoneLearnAlpha);
    lengths.put(key,next);
    return next;
  }
  float reliable(SkeletonJoint3D a,SkeletonJoint3D b){return a!=null&&b!=null&&a.state==2&&b.state==2&&a.confidence>=.58f&&b.confidence>=.58f?PVector.dist(a.world,
      b.world):Float.NaN;}
  float symmetric(String key,SkeletonJoint3D la,SkeletonJoint3D lb,SkeletonJoint3D ra,SkeletonJoint3D rb){float l=reliable(la,lb),r=reliable(ra,rb),v=Float.NaN;
    if(Float.isFinite(l)&&Float.isFinite(r))v=(l+r)*.5f;else if(Float.isFinite(l))v=l;
    else if(Float.isFinite(r))v=r;return Float.isFinite(v)?learned(key,v):(lengths.containsKey(key)?lengths.get(key):Float.NaN);
    }
  float pairLength(String key,SkeletonJoint3D a,SkeletonJoint3D b){float v=reliable(a,b);
    return Float.isFinite(v)?learned(key,v):(lengths.containsKey(key)?lengths.get(key):Float.NaN);
    }
  void stabilize(SkeletonPose3D s,SkeletonCalibration3D cal){
    float shoulderWidth=pairLength("shoulder_width",s.leftShoulder,s.rightShoulder),hipWidth=pairLength("hip_width",s.leftHip,s.rightHip);
    
    correctPair(s.leftShoulder,s.rightShoulder,shoulderWidth,cal);correctPair(s.leftHip,s.rightHip,hipWidth,cal);
    
    float ua=symmetric("upper_arm",s.leftShoulder,s.leftElbow,s.rightShoulder,s.rightElbow),fa=symmetric("forearm",s.leftElbow,s.leftWrist,s.rightElbow,
      s.rightWrist),th=symmetric("thigh",s.leftHip,s.leftKnee,s.rightHip,s.rightKnee),sh=symmetric("shin",s.leftKnee,s.leftAnkle,s.rightKnee,s.rightAnkle);
    
    correct(s.leftShoulder,s.leftElbow,"lua",ua,cal);correct(s.rightShoulder,s.rightElbow,"rua",ua,cal);
    correct(s.leftElbow,s.leftWrist,"lfa",fa,cal);correct(s.rightElbow,s.rightWrist,"rfa",fa,cal);
    correct(s.leftHip,s.leftKnee,"lth",th,cal);correct(s.rightHip,s.rightKnee,"rth",th,cal);
    correct(s.leftKnee,s.leftAnkle,"lsh",sh,cal);correct(s.rightKnee,s.rightAnkle,"rsh",sh,cal);
    
    float handTarget=lengths.containsKey("hand")?lengths.get("hand"):Float.NaN;correct(s.leftWrist,s.leftHand,"lh",handTarget,cal);
    correct(s.rightWrist,s.rightHand,"rh",handTarget,cal);float handL=reliable(s.leftWrist,s.leftHand),handR=reliable(s.rightWrist,s.rightHand);
    if(Float.isFinite(handL)||Float.isFinite(handR)){float hv=Float.isFinite(handL)&&Float.isFinite(handR)?(handL+handR)*.5f:(Float.isFinite(handL)?handL:handR);
      learned("hand",hv);}
  }
  void correctPair(SkeletonJoint3D a,SkeletonJoint3D b,float target,SkeletonCalibration3D cal){if(a==null||b==null||!a.tracked()||!b.tracked()||!Float.isFinite(target)||target<.04f)return;
    PVector v=PVector.sub(b.world,a.world);float d=v.mag();if(d<.001f)return;float err=abs(d-target)/target;
    if(err<.045f)return;v.div(d);PVector mid=PVector.add(a.world,b.world).mult(.5f),half=PVector.mult(v,target*.5f);
    PVector da=PVector.sub(mid,half),db=PVector.add(mid,half);float confidence=min(a.confidence,b.confidence),strength=constrain(cfg.poseBoneCorrection*.48f*lerp(.45f,
      1.0f,1-constrain(confidence,0,1)),.08f,.42f);a.world.set(PVector.lerp(a.world,da,strength));
    b.world.set(PVector.lerp(b.world,db,strength));PVector ua=cal.projectWorldRgb(a.world),ub=cal.projectWorldRgb(b.world);
    if(ua!=null)a.image.set(ua);if(ub!=null)b.image.set(ub);}
  void correct(SkeletonJoint3D parent,SkeletonJoint3D child,String dirKey,float target,SkeletonCalibration3D cal){if(parent==null||child==null||!parent.tracked()||!child.tracked()||!Float.isFinite(target)||target<.025f)return;
    PVector v=PVector.sub(child.world,parent.world);float d=v.mag();if(d<.001f)return;
    v.div(d);PVector prior=directions.get(dirKey);if(prior!=null&&child.confidence<.82f){float dot=constrain(PVector.dot(prior,v),-1,1),angle=degrees(acos(dot));
      if(angle>cfg.poseMaxDirectionJumpDeg){float t=constrain(cfg.poseMaxDirectionJumpDeg/max(angle,.001f),0,1);
        v=PVector.lerp(prior,v,t);if(v.mag()>0)v.normalize();child.confidence*=.88f;
        }}directions.put(dirKey,v.copy());float err=abs(d-target)/target;if(err>.07f){float strength=cfg.poseBoneCorrection*lerp(.38f,1.0f,1-constrain(child.confidence,
        0,1));PVector desired=PVector.add(parent.world,PVector.mult(v,target));child.world.set(PVector.lerp(child.world,desired,constrain(strength,.12f,
        cfg.poseBoneCorrection)));PVector uv=cal.projectWorldRgb(child.world);if(uv!=null)child.image.set(uv);
      }}
}

class SkeletonTracker {
  static final int LIMB_ARM=1,LIMB_LEG=2;
  final SkeletonConfig cfg;final SkeletonCalibration3D cal;final SkeletonDepthPersonSegmenter estimator;
  final SkeletonTemporalConsensus consensus;final SkeletonKalmanBank kalman;final SkeletonPoseFilter poseFilter;
  final SkeletonRootStabilizer rootFilter;final SkeletonIdentityPredictor identity;
  final SkeletonAnthropometricModel biomechanics;final SkeletonKinematicOptimizer modelOptimizer;
  SkeletonPose3D previous;int identityMissFrames=0,acquireFrames=0,releaseFrames=0;
  long activeTrackingId=0,nextTrackingId=1;volatile String lastReason="searching";
  
  SkeletonTracker(SkeletonConfig c,Calibration calibration,RgbDepthRegistration registration){cfg=c;
    cal=new SkeletonCalibration3D(calibration,registration);estimator=new SkeletonDepthPersonSegmenter(c);
    consensus=new SkeletonTemporalConsensus(c);kalman=new SkeletonKalmanBank(c);poseFilter=new SkeletonPoseFilter(c);
    rootFilter=new SkeletonRootStabilizer(c);identity=new SkeletonIdentityPredictor(c);
    biomechanics=new SkeletonAnthropometricModel(c);modelOptimizer=new SkeletonKinematicOptimizer(c);
    }
  void reset(){previous=null;identityMissFrames=0;acquireFrames=0;releaseFrames=0;
    activeTrackingId=0;consensus.reset();kalman.reset();poseFilter.reset();rootFilter.reset();
    identity.reset();biomechanics.reset();modelOptimizer.reset();lastReason="searching";
    }
  SkeletonPose3D track(RgbdFramePair pair){
    if(pair==null)return track((DepthFrame)null,millis64());
    long tick=Math.max(pair.rgb==null?0:pair.rgb.timestampUs/1000L,pair.depth==null?0:pair.depth.timestampUs/1000L);
    
    return track(pair.depth,tick>0?tick:millis64());
  }
  SkeletonPose3D track(DepthFrame depthFrame,long tick){
    SkeletonPose3D s=new SkeletonPose3D();if(depthFrame==null||depthFrame.depth==null)return predictedSkeleton(s,tick,"no_rgbd");
    boolean broadSearch=identityMissFrames>=cfg.trackingReleaseFrames;PVector priorCenter=broadSearch?null:identity.predictedCenter(tick);
    float priorDepth=broadSearch?0:identity.predictedDepth(tick);SkeletonDepthBodyMask body=estimator.segment(depthFrame,priorCenter,priorDepth);
    if(body==null)return predictedSkeleton(s,tick,"no_person");
    int top=centralTop(body),bottom=body.py(body.maxGY),height=max(1,bottom-top);
    if(height<cfg.bodyMinHeightPx)return predictedSkeleton(s,tick,"no_person");if(activeTrackingId==0)activeTrackingId=nextTrackingId++;
    s.trackingId=activeTrackingId;
    float centerX=centerAt(body,round(top+height*.46f),max(8,height/16));if(Float.isNaN(centerX))centerX=body.centerX;
    float torsoWidth=torsoWidth(body,top,height,centerX);if(torsoWidth<22)return predictedSkeleton(s,tick,"low_confidence");
    
    float q=body.confidence,shoulderY=landmarkRow(body,top,height,.18f,.39f,.27f,torsoWidth*1.12f),hipCenterY=landmarkRow(body,top,height,.48f,.67f,.57f,
      torsoWidth*.78f);float shoulderCenterY=narrowRow(body,top,height,.12f,.27f,.195f,torsoWidth*.50f);
    float headY=top+max(body.step,height*.075f),spineY=lerp(shoulderY,hipCenterY,.55f);
    
    float shoulderCenterX=centerAt(body,round(shoulderCenterY),max(6,height/40));
    if(Float.isNaN(shoulderCenterX))shoulderCenterX=centerX;float hipCenterX=centerAt(body,round(hipCenterY),max(8,height/36));
    if(Float.isNaN(hipCenterX))hipCenterX=centerX;float shoulderRowCenter=centerAt(body,round(shoulderY),max(7,height/42));
    if(Float.isNaN(shoulderRowCenter))shoulderRowCenter=shoulderCenterX;
    float shoulderHalf=constrain(torsoWidth*.50f,14,studio.services.scannerProtocol.WIDTH*.22f),hipHalf=constrain(torsoWidth*.30f,10,studio.services.scannerProtocol.WIDTH*.16f);
    
    SkeletonBodyPoint head=pointNear(body,centerAtOr(body,round(headY),max(5,height/45),centerX),headY,max(10,height/18),q);
    
    SkeletonBodyPoint shoulderCenterPoint=pointNear(body,shoulderCenterX,shoulderCenterY,max(8,height/24),q),spine=pointNear(body,centerAtOr(body,round(spineY),
      max(8,height/34),centerX),spineY,max(8,height/24),q),hipCenterPoint=pointNear(body,hipCenterX,hipCenterY,max(10,height/24),q);
    
    SkeletonBodyPoint ls=pointNear(body,shoulderRowCenter-shoulderHalf,shoulderY,max(12,round(torsoWidth*.32f)),q),rs=pointNear(body,shoulderRowCenter+shoulderHalf,
      shoulderY,max(12,round(torsoWidth*.32f)),q);SkeletonBodyPoint lh=pointNear(body,hipCenterX-hipHalf,hipCenterY,max(10,round(torsoWidth*.24f)),q),rh=pointNear(body,
      hipCenterX+hipHalf,hipCenterY,max(10,round(torsoWidth*.24f)),q);
    SkeletonLimbPath leftArm=traceLimb(body,ls,-1,LIMB_ARM,hipCenterY,centerX,torsoWidth,previous==null?null:previous.leftHand),rightArm=traceLimb(body,
      rs,1,LIMB_ARM,hipCenterY,centerX,torsoWidth,previous==null?null:previous.rightHand);
    SkeletonLimbPath leftLeg=traceLimb(body,lh,-1,LIMB_LEG,hipCenterY,centerX,torsoWidth,previous==null?null:previous.leftFoot),rightLeg=traceLimb(body,
      rh,1,LIMB_LEG,hipCenterY,centerX,torsoWidth,previous==null?null:previous.rightFoot);
    
    float leftArmElbowFrac=learnedFraction(previous==null?null:previous.leftShoulder,previous==null?null:previous.leftElbow,previous==null?null:previous.leftWrist,
      .49f,.38f,.62f),rightArmElbowFrac=learnedFraction(previous==null?null:previous.rightShoulder,previous==null?null:previous.rightElbow,previous==null?null:previous.rightWrist,
      .49f,.38f,.62f);
    float leftArmWristFrac=learnedChainFraction(previous==null?null:previous.leftShoulder,previous==null?null:previous.leftElbow,previous==null?null:previous.leftWrist,
      previous==null?null:previous.leftHand,.86f,.72f,.95f),rightArmWristFrac=learnedChainFraction(previous==null?null:previous.rightShoulder,previous==null?null:previous.rightElbow,
      previous==null?null:previous.rightWrist,previous==null?null:previous.rightHand,.86f,.72f,.95f);
    
    float leftLegKneeFrac=learnedFraction(previous==null?null:previous.leftHip,previous==null?null:previous.leftKnee,previous==null?null:previous.leftAnkle,
      .50f,.40f,.62f),rightLegKneeFrac=learnedFraction(previous==null?null:previous.rightHip,previous==null?null:previous.rightKnee,previous==null?null:previous.rightAnkle,
      .50f,.40f,.62f);
    float leftLegAnkleFrac=learnedChainFraction(previous==null?null:previous.leftHip,previous==null?null:previous.leftKnee,previous==null?null:previous.leftAnkle,
      previous==null?null:previous.leftFoot,.86f,.72f,.96f),rightLegAnkleFrac=learnedChainFraction(previous==null?null:previous.rightHip,previous==null?null:previous.rightKnee,
      previous==null?null:previous.rightAnkle,previous==null?null:previous.rightFoot,.86f,.72f,.96f);
    
    SkeletonBodyPoint lhand=leftArm.valid()?leftArm.end(body,q):armFallback(body,ls,-1,hipCenterY,torsoWidth,q),rhand=rightArm.valid()?rightArm.end(body,
      q):armFallback(body,rs,1,hipCenterY,torsoWidth,q);SkeletonBodyPoint lel=leftArm.valid()?leftArm.at(body,leftArmElbowFrac,q):betweenOnMask(body,ls,
      lhand,.52f,max(14,round(torsoWidth*.35f)),q*.76f),rel=rightArm.valid()?rightArm.at(body,rightArmElbowFrac,q):betweenOnMask(body,rs,rhand,.52f,max(14,
      round(torsoWidth*.35f)),q*.76f);SkeletonBodyPoint lw=leftArm.valid()?leftArm.at(body,leftArmWristFrac,q):betweenOnMask(body,ls,lhand,.86f,max(10,
      round(torsoWidth*.25f)),q*.72f),rw=rightArm.valid()?rightArm.at(body,rightArmWristFrac,q):betweenOnMask(body,rs,rhand,.86f,max(10,round(torsoWidth*.25f)),
      q*.72f);
    SkeletonBodyPoint lf=leftLeg.valid()?leftLeg.end(body,q):legFallback(body,-1,top+height*.975f,hipCenterX,torsoWidth,q*.65f),rf=rightLeg.valid()?rightLeg.end(body,
      q):legFallback(body,1,top+height*.975f,hipCenterX,torsoWidth,q*.65f);SkeletonBodyPoint lk=leftLeg.valid()?leftLeg.at(body,leftLegKneeFrac,q):legFallback(body,
      -1,top+height*.755f,hipCenterX,torsoWidth,q*.72f),rk=rightLeg.valid()?rightLeg.at(body,rightLegKneeFrac,q):legFallback(body,1,top+height*.755f,hipCenterX,
      torsoWidth,q*.72f),la=leftLeg.valid()?leftLeg.at(body,leftLegAnkleFrac,q):legFallback(body,-1,top+height*.915f,hipCenterX,torsoWidth,q*.70f),ra=rightLeg.valid()?rightLeg.at(body,
      rightLegAnkleFrac,q):legFallback(body,1,top+height*.915f,hipCenterX,torsoWidth,q*.70f);
    
    s.head=joint("head",head,body);s.shoulderCenter=joint("shoulder_center",shoulderCenterPoint,body);
    s.spine=joint("spine",spine,body);s.hipCenter=joint("hip_center",hipCenterPoint,body);
    s.leftShoulder=joint("left_shoulder",ls,body);s.rightShoulder=joint("right_shoulder",rs,body);
    s.leftElbow=joint("left_elbow",lel,body);s.rightElbow=joint("right_elbow",rel,body);
    s.leftWrist=joint("left_wrist",lw,body);s.rightWrist=joint("right_wrist",rw,body);
    s.leftHand=joint("left_hand",lhand,body);s.rightHand=joint("right_hand",rhand,body);
    s.leftHip=joint("left_hip",lh,body);s.rightHip=joint("right_hip",rh,body);s.leftKnee=joint("left_knee",lk,body);
    s.rightKnee=joint("right_knee",rk,body);s.leftAnkle=joint("left_ankle",la,body);
    s.rightAnkle=joint("right_ankle",ra,body);s.leftFoot=joint("left_foot",lf,body);
    s.rightFoot=joint("right_foot",rf,body);
    validateKinematics(s);consensus.apply(s,tick);kalman.apply(s,tick,cal);poseFilter.apply(s,tick,cal);
    rootFilter.apply(s,tick,cal);biomechanics.stabilize(s,cal);modelOptimizer.optimize(s,cal);
    clampSkeleton(s);poseFilter.commitMeasured(s,tick);
    SkeletonJoint3D[] core={s.leftShoulder,s.rightShoulder,s.shoulderCenter,s.spine,s.hipCenter};
    s.torsoConfidence=avgTracked(core);float coreCoverage=trackedCount(core)/(float)core.length;
    float leftArmQ=avgTracked(new SkeletonJoint3D[]{s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand}),rightArmQ=avgTracked(new SkeletonJoint3D[]{s.rightShoulder,
        s.rightElbow,s.rightWrist,s.rightHand});s.upperBodyConfidence=avgTracked(new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.leftShoulder,s.rightShoulder,
        s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand});
    s.interactionConfidence=constrain(.66f*s.torsoConfidence+.34f*max(leftArmQ,rightArmQ),0,1);
    s.lowerBodyConfidence=avgTracked(new SkeletonJoint3D[]{s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot}
    );float jointQ=avgTracked(allJoints(s));s.confidence=constrain(.46f*body.confidence+.34f*s.torsoConfidence+.20f*jointQ,0,1);
    
    // Body tracking is intentionally independent from hand/arm quality. Modules that
    // require hands use interactionTracked(); the shared skeleton remains stable when
    // a hand leaves the frame, crosses the torso or is temporarily occluded.
    boolean evidence=body.confidence>=cfg.trackingMinBodyConfidence&&s.torsoConfidence>=cfg.poseMinCoreConfidence&&coreCoverage>=cfg.trackingMinCoreCoverage;
    if(evidence){acquireFrames=min(cfg.trackingAcquireFrames+2,acquireFrames+1);releaseFrames=0;
      }else{releaseFrames++;acquireFrames=max(0,acquireFrames-1);}boolean wasTracked=previous!=null&&previous.tracked;
    s.tracked=evidence&&(wasTracked||acquireFrames>=cfg.trackingAcquireFrames);
    if(wasTracked&&!evidence&&
       releaseFrames<cfg.trackingReleaseFrames&&
       body.confidence>=cfg.trackingMinBodyConfidence*.72f&&
       s.torsoConfidence>=cfg.poseMinCoreConfidence*.58f&&
       coreCoverage>=cfg.trackingMinCoreCoverage*.65f) {
      s.tracked=true;
    }
    s.reason=s.tracked?(evidence?"tracked":"inferred"):"low_confidence";lastReason=s.reason;
    
    if(s.tracked){identityMissFrames=0;deriveBounds(s);s.meanDepthM=meanDepth(s);
      s.faceWidthPx=constrain(torsoWidth*.34f,18,120);s.faceHeightPx=s.faceWidthPx*1.22f;
      identity.update(s,tick,cal);previous=s;}else if(evidence){identityMissFrames=0;
      s.reason="acquiring";lastReason=s.reason;identity.update(s,tick,cal);}else if(previous!=null&&body.confidence>=cfg.trackingMinBodyConfidence*.80f&&s.torsoConfidence>=cfg.poseMinCoreConfidence*.68f&&coreCoverage>=cfg.trackingMinCoreCoverage*.60f){
      identityMissFrames=0;s.tracked=true;s.reason="inferred";lastReason=s.reason;
      deriveBounds(s);s.meanDepthM=meanDepth(s);identity.update(s,tick,cal);previous=s;
      }else{identityMissFrames++;identity.miss();if(identityMissFrames>cfg.poseOcclusionHoldFrames){previous=null;
        activeTrackingId=0;acquireFrames=0;releaseFrames=0;consensus.reset();kalman.reset();
        poseFilter.reset();rootFilter.reset();identity.reset();biomechanics.reset();
        modelOptimizer.reset();}}return s;
  }
  SkeletonPose3D predictedSkeleton(SkeletonPose3D s,long tick,String reason){
    identityMissFrames++;
    identity.miss();
    acquireFrames=0;
    releaseFrames++;
    s.trackingId=activeTrackingId;
    if(identityMissFrames>cfg.poseOcclusionHoldFrames){
      previous=null;activeTrackingId=0;releaseFrames=0;
      consensus.reset();kalman.reset();poseFilter.reset();rootFilter.reset();identity.reset();
      biomechanics.reset();modelOptimizer.reset();
      s.reason=reason;lastReason=reason;return s;
    }
    poseFilter.apply(s,tick,cal);rootFilter.apply(s,tick,cal);biomechanics.stabilize(s,cal);
    modelOptimizer.optimize(s,cal);clampSkeleton(s);
    s.torsoConfidence=avgTracked(new SkeletonJoint3D[]{s.leftShoulder,s.rightShoulder,s.shoulderCenter,s.spine,s.hipCenter});
    
    float leftArmQ=avgTracked(new SkeletonJoint3D[]{s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand}),rightArmQ=avgTracked(new SkeletonJoint3D[]{s.rightShoulder,
        s.rightElbow,s.rightWrist,s.rightHand});
    s.upperBodyConfidence=avgTracked(new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,
        s.rightWrist,s.leftHand,s.rightHand});
    s.interactionConfidence=constrain(.66f*s.torsoConfidence+.34f*max(leftArmQ,rightArmQ),0,1);
    
    s.lowerBodyConfidence=avgTracked(new SkeletonJoint3D[]{s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot}
    );
    s.confidence=constrain(.82f*s.upperBodyConfidence+.18f*avgTracked(allJoints(s)),0,1);
    
    boolean holdEligible=previous!=null&&previous.tracked&&releaseFrames<cfg.trackingReleaseFrames;
    
    SkeletonJoint3D[] predictedCore={s.leftShoulder,s.rightShoulder,s.shoulderCenter,s.spine,s.hipCenter};
    float predictedCoverage=trackedCount(predictedCore)/(float)predictedCore.length;
    
    s.tracked=holdEligible&&s.torsoConfidence>=cfg.poseMinCoreConfidence*.55f&&predictedCoverage>=cfg.trackingMinCoreCoverage*.55f;
    
    s.reason=s.tracked?"inferred":reason;lastReason=s.reason;
    if(s.tracked){deriveBounds(s);s.meanDepthM=meanDepth(s);if(previous!=null){s.faceWidthPx=previous.faceWidthPx;
        s.faceHeightPx=previous.faceHeightPx;}}
    return s;
  }
  float learnedFraction(SkeletonJoint3D a,SkeletonJoint3D mid,SkeletonJoint3D end,float fallback,float lo,float hi){if(a==null||mid==null||end==null||!a.tracked()||!mid.tracked()||!end.tracked())return fallback;
    float x=PVector.dist(a.world,mid.world),y=PVector.dist(mid.world,end.world);return x+y>.03f?constrain(x/(x+y),lo,hi):fallback;
    }
  float learnedChainFraction(SkeletonJoint3D a,SkeletonJoint3D b,SkeletonJoint3D c,SkeletonJoint3D d,float fallback,float lo,float hi){if(a==null||b==null||c==null||d==null||!a.tracked()||!b.tracked()||!c.tracked()||!d.tracked())return fallback;
    float x=PVector.dist(a.world,b.world),y=PVector.dist(b.world,c.world),z=PVector.dist(c.world,d.world),sum=x+y+z;
    return sum>.03f?constrain((x+y)/sum,lo,hi):fallback;}
  float landmarkRow(SkeletonDepthBodyMask b,int top,int height,float lo,float hi,float preferred,float targetWidth){float bestY=top+height*preferred,best=-Float.MAX_VALUE;
    for(int y=round(top+height*lo);y<=round(top+height*hi);y+=max(2,b.step)){int[] span=rowSpan(b,y,max(2,b.step));
      if(span[2]<2)continue;float width=span[1]-span[0]+b.step,widthScore=1.0f-abs(width-targetWidth)/max(12,targetWidth),prior=1.0f-abs(y-(top+height*preferred))/max(1,
        height*(hi-lo));float score=widthScore*.72f+prior*.28f;if(score>best){best=score;
        bestY=y;}}return bestY;}
  float narrowRow(SkeletonDepthBodyMask b,int top,int height,float lo,float hi,float preferred,float targetWidth){float bestY=top+height*preferred,best=-Float.MAX_VALUE;
    for(int y=round(top+height*lo);y<=round(top+height*hi);y+=max(2,b.step)){int[] span=rowSpan(b,y,max(2,b.step));
      if(span[2]<2)continue;float width=span[1]-span[0]+b.step,widthScore=1.0f-abs(width-targetWidth)/max(12,targetWidth),prior=1.0f-abs(y-(top+height*preferred))/max(1,
        height*(hi-lo));float score=widthScore*.78f+prior*.22f;if(score>best){best=score;
        bestY=y;}}return bestY;}
  SkeletonLimbPath traceLimb(SkeletonDepthBodyMask b,SkeletonBodyPoint seed,int side,int kind,float hipCenterY,float center,float torsoWidth,SkeletonJoint3D priorJoint){
    SkeletonLimbPath out=new SkeletonLimbPath();if(seed==null||!seed.valid)return out;
    int start=nearestMaskIndex(b,seed.x,seed.y,max(8,round(torsoWidth*.35f)));if(start<0)return out;
    int n=b.mask.length;float[] d=new float[n];int[] parent=new int[n];Arrays.fill(d,Float.POSITIVE_INFINITY);
    Arrays.fill(parent,-1);PriorityQueue<SkeletonGraphNode> pq=new PriorityQueue<SkeletonGraphNode>();
    d[start]=0;pq.add(new SkeletonGraphNode(start,0));PVector prior=priorDepth(priorJoint);
    int best=start;float bestScore=-Float.MAX_VALUE;
    while(!pq.isEmpty()){SkeletonGraphNode node=pq.poll();int at=node.index;if(node.distance!=d[at])continue;
      int gx=at%b.gridW,gy=at/b.gridW;float x=b.px(gx),y=b.py(gy);if(limbAllowed(y,kind,hipCenterY,torsoWidth)){float score=endpointScore(b,at,start,side,
          kind,hipCenterY,center,torsoWidth,prior);if(score>bestScore){bestScore=score;
          best=at;}}for(int oy=-1;oy<=1;oy++)for(int ox=-1;ox<=1;ox++){if(ox==0&&oy==0)continue;
        int nx=gx+ox,ny=gy+oy;if(nx<0||ny<0||nx>=b.gridW||ny>=b.gridH)continue;int ni=ny*b.gridW+nx;
        if(!b.mask[ni]||!limbAllowed(b.py(ny),kind,hipCenterY,torsoWidth))continue;
        float depthJump=abs(b.mm[ni]-b.mm[at])/(float)max(1,cfg.bodyContinuityMm),clear=max(1,min(b.clearance[at],b.clearance[ni])),medial=1.0f+cfg.poseMedialPenalty/max(1.0f,
          clear/3.0f),edge=(float)Math.sqrt(ox*ox+oy*oy)*b.step*(1.0f+cfg.poseGeodesicDepthPenalty*constrain(depthJump,0,1))*medial;
        float nxp=b.px(nx);boolean crosses=side<0?nxp>center+torsoWidth*.15f:nxp<center-torsoWidth*.15f;
        boolean priorCrossed=prior!=null&&(side<0?prior.x>center:prior.x<center);
        if(crosses)edge*=priorCrossed?1.08f:cfg.poseCrossBodyPenalty;float nd=node.distance+edge;
        if(nd<d[ni]){d[ni]=nd;parent[ni]=at;pq.add(new SkeletonGraphNode(ni,nd));
          }}}
    float minLength=torsoWidth*(kind==LIMB_ARM?cfg.poseMinArmPathRatio:cfg.poseMinLegPathRatio);
    if(best==start||!Float.isFinite(d[best])||d[best]<minLength)return out;ArrayList<Integer> rev=new ArrayList<Integer>();
    for(int at=best;at>=0;at=parent[at]){rev.add(at);if(at==start)break;}if(rev.isEmpty()||rev.get(rev.size()-1)!=start)return out;
    Collections.reverse(rev);out.nodes=new int[rev.size()];out.cumulative=new float[rev.size()];
    float physical=0;for(int i=0;i<rev.size();i++){out.nodes[i]=rev.get(i);if(i>0){int a=out.nodes[i-1],z=out.nodes[i];
        physical+=dist(b.px(a%b.gridW),b.py(a/b.gridW),b.px(z%b.gridW),b.py(z/b.gridW));
        }out.cumulative[i]=physical;}out.lengthPx=physical;if(physical<minLength)return new SkeletonLimbPath();
    float lengthScore=constrain((physical-minLength)/max(torsoWidth*.90f,1)+.55f,.35f,1),sideScore=endpointSideScore(b,best,side,center,torsoWidth);
    out.confidence=constrain(.48f+.34f*lengthScore+.18f*sideScore,.35f,1);return out;
    }
  boolean limbAllowed(float y,int kind,float hipCenterY,float torsoWidth){return kind==LIMB_ARM?y<=hipCenterY+torsoWidth*.20f:y>=hipCenterY-torsoWidth*.18f;
    }
  float endpointScore(SkeletonDepthBodyMask b,int idx,int start,int side,int kind,float hipCenterY,float center,float torsoWidth,PVector prior){int gx=idx%b.gridW,
    gy=idx/b.gridW,sgx=start%b.gridW,sgy=start/b.gridW;float x=b.px(gx),y=b.py(gy),outward=side<0?center-x:x-center,reach=dist(x,y,b.px(sgx),b.py(sgy)),
    score=reach;if(kind==LIMB_ARM)score+=max(0,outward)*.42f;else score+=max(0,y-hipCenterY)*.68f;
    if(outward<-torsoWidth*.08f)score-=torsoWidth*.85f;int neighbors=0;for(int oy=-1;oy<=1;oy++)for(int ox=-1;ox<=1;ox++){if(ox==0&&oy==0)continue;
      int nx=gx+ox,ny=gy+oy;if(nx>=0&&ny>=0&&nx<b.gridW&&ny<b.gridH&&b.mask[ny*b.gridW+nx])neighbors++;
      }if(neighbors<=5)score+=torsoWidth*.22f;if(prior!=null){float pd=dist(x,y,prior.x,prior.y),near=constrain(1.0f-pd/max(torsoWidth*2.1f,24),0,1);
      score+=near*torsoWidth*cfg.poseTemporalEndpointBias;}return score;}
  float endpointSideScore(SkeletonDepthBodyMask b,int idx,int side,float center,float torsoWidth){float x=b.px(idx%b.gridW),outward=side<0?center-x:x-center;
    return constrain((outward+torsoWidth*.12f)/max(torsoWidth*.62f,1),0,1);}
  PVector priorDepth(SkeletonJoint3D j){if(j==null||!j.tracked()||j.world.z<=0)return null;
    return cal.projectDepth(j.world);}
  int nearestMaskIndex(SkeletonDepthBodyMask b,float x,float y,int radius){int cg=constrain(round(x/b.step),0,b.gridW-1),cy=constrain(round(y/b.step),0,
      b.gridH-1),rg=max(1,(radius+b.step-1)/b.step),best=-1;float bestD=Float.MAX_VALUE;
    for(int gy=max(b.minGY,cy-rg);gy<=min(b.maxGY,cy+rg);gy++)for(int gx=max(b.minGX,cg-rg);gx<=min(b.maxGX,cg+rg);gx++){int i=gy*b.gridW+gx;
      if(!b.mask[i])continue;float dx=b.px(gx)-x,dy=b.py(gy)-y,dd=dx*dx+dy*dy;if(dd<bestD){bestD=dd;
        best=i;}}return best;}
  SkeletonBodyPoint armFallback(SkeletonDepthBodyMask b,SkeletonBodyPoint shoulder,int side,float hipCenterY,float torsoWidth,float q){if(shoulder==null||!shoulder.valid)return new SkeletonBodyPoint();
    int best=-1;float bestScore=-1,center=b.centerX;for(int gy=b.minGY;gy<=b.maxGY;gy++){float y=b.py(gy);
      if(y<shoulder.y-torsoWidth*.75f||y>hipCenterY+torsoWidth*.18f)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;
        if(!b.mask[i])continue;float x=b.px(gx);if(side<0&&x>center-torsoWidth*.12f)continue;
        if(side>0&&x<center+torsoWidth*.12f)continue;float dx=x-shoulder.x,dy=y-shoulder.y,dist2=dx*dx+dy*dy;
        if(dist2<torsoWidth*torsoWidth*.10f)continue;float outward=side<0?max(0,shoulder.x-x):max(0,x-shoulder.x),score=dist2+outward*outward*.55f;
        if(score>bestScore){bestScore=score;best=i;}}}if(best<0)return pointNear(b,shoulder.x+side*torsoWidth*.18f,shoulder.y+torsoWidth*.70f,max(16,round(torsoWidth*.45f)),
      q*.55f);return new SkeletonBodyPoint(b.px(best%b.gridW),b.py(best/b.gridW),q*.70f);
    }
  SkeletonBodyPoint legFallback(SkeletonDepthBodyMask b,int side,float y,float center,float torsoWidth,float q){int band=max(8,round((b.py(b.maxGY)-b.py(b.minGY))*.035f));
    double sx=0,sy=0;int n=0;for(int gy=b.minGY;gy<=b.maxGY;gy++){if(abs(b.py(gy)-y)>band)continue;
      for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;
        float x=b.px(gx);if(side<0&&x>center-torsoWidth*.035f)continue;if(side>0&&x<center+torsoWidth*.035f)continue;
        sx+=x;sy+=b.py(gy);n++;}}if(n==0)return pointNear(b,center+side*torsoWidth*.22f,y,max(18,round(torsoWidth*.45f)),q*.55f);
    return new SkeletonBodyPoint((float)(sx/n),(float)(sy/n),q);}
  SkeletonJoint3D joint(String name,SkeletonBodyPoint p,SkeletonDepthBodyMask body){SkeletonJoint3D j=new SkeletonJoint3D(name);
    if(p==null||!p.valid)return j;int idx=nearestMaskIndex(body,p.x,p.y,max(body.step*2,8));
    if(idx<0)return j;int base=body.mm[idx];if(base<cfg.minDepthMm||base>cfg.maxDepthMm)return j;
    boolean extremity=name.indexOf("hand")>=0||name.indexOf("wrist")>=0||name.indexOf("ankle")>=0||name.indexOf("foot")>=0;
    float radius=extremity?max(6,body.step*1.6f):max(8,body.step*2.4f),sigma=max(4,radius*.62f),sw=0,sx=0,sy=0,sd=0,sd2=0;
    int localN=0;int gx0=idx%body.gridW,gy0=idx/body.gridW,rg=max(1,ceil(radius/body.step));
    for(int gy=max(body.minGY,gy0-rg);gy<=min(body.maxGY,gy0+rg);gy++)for(int gx=max(body.minGX,gx0-rg);gx<=min(body.maxGX,gx0+rg);gx++){int i=gy*body.gridW+gx;
      if(!body.mask[i]||abs(body.mm[i]-base)>max(70,cfg.bodyContinuityMm/2))continue;
      float dx=body.px(gx)-p.x,dy=body.py(gy)-p.y,dd=dx*dx+dy*dy;if(dd>radius*radius)continue;
      float w=(float)Math.exp(-dd/(2*sigma*sigma))*(1.0f+.035f*min(18,body.clearance[i]));
      sw+=w;sx+=w*body.px(gx);sy+=w*body.py(gy);sd+=w*body.mm[i];sd2+=w*body.mm[i]*body.mm[i];
      localN++;}int u=body.px(gx0),v=body.py(gy0),mm=base;if(sw>0){u=round(lerp(u,sx/sw,extremity?.28f:.48f));
      v=round(lerp(v,sy/sw,extremity?.28f:.48f));mm=round(sd/sw);}if(cfg.poseFullResolutionRefineRadiusPx>0&&body.sourceDepth!=null&&body.sourceDepth.depth!=null){
      int rr=extremity?max(3,cfg.poseFullResolutionRefineRadiusPx-2):cfg.poseFullResolutionRefineRadiusPx,tol=max(40,cfg.poseFullResolutionDepthToleranceMm),
      fw=body.width,fh=body.height;double fsx=0,fsy=0,fsd=0,fsw=0;for(int yy=max(0,v-rr);yy<=min(fh-1,v+rr);yy++)for(int xx=max(0,u-rr);xx<=min(fw-1,u+rr);xx++){
        int d=body.sourceDepth.depth[yy*fw+xx]&0xffff;if(d<cfg.minDepthMm||d>cfg.maxDepthMm||abs(d-mm)>tol)continue;
        float dx=xx-u,dy=yy-v,dd=dx*dx+dy*dy;if(dd>rr*rr)continue;double ww=Math.exp(-dd/(2.0*Math.max(2.0,rr*rr*.32)));
        fsx+=xx*ww;fsy+=yy*ww;fsd+=d*ww;fsw+=ww;}if(fsw>1.5){u=round((float)(fsx/fsw));
        v=round((float)(fsy/fsw));mm=round((float)(fsd/fsw));}}PVector image=cal.projectRgb(u,v,mm);
    if(image==null)image=new PVector(u,v);float variance=sw>0?max(0,sd2/sw-(sd/sw)*(sd/sw)):0,depthStd=sqrt(variance),surfaceQ=constrain(1.0f-depthStd/max(45.0f,
      cfg.bodyContinuityMm*.45f),.45f,1.0f),sampleQ=constrain(localN/8.0f,.55f,1.0f),clearQ=extremity?1.0f:constrain(body.clearance[idx]/5.0f,.62f,1.0f),
    confidence=constrain(p.confidence*surfaceQ*sampleQ*clearQ,.04f,1.0f);return j.set(image,cal.deproject(u,v,mm),confidence,confidence>.55f?2:1);
    }
  void validateKinematics(SkeletonPose3D s){if(!s.leftShoulder.tracked()||!s.rightShoulder.tracked())return;
    float scale=PVector.dist(s.leftShoulder.world,s.rightShoulder.world);if(scale<.10f||scale>.85f)return;
    validateArm(s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand,scale);validateArm(s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand,scale);
    validateLeg(s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot,scale);validateLeg(s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot,scale);
    }
  void validateArm(SkeletonJoint3D shoulder,SkeletonJoint3D elbow,SkeletonJoint3D wrist,SkeletonJoint3D hand,float scale){if(!plausibleBone(shoulder,elbow,
      scale*.20f,scale*1.25f)){invalidate(elbow);invalidate(wrist);invalidate(hand);
      return;}if(!plausibleBone(elbow,wrist,scale*.18f,scale*1.25f)){invalidate(wrist);
      invalidate(hand);return;}if(wrist.tracked()&&hand.tracked()&&!plausibleBone(wrist,hand,scale*.02f,scale*.65f))invalidate(hand);
    }
  void validateLeg(SkeletonJoint3D hip,SkeletonJoint3D knee,SkeletonJoint3D ankle,SkeletonJoint3D foot,float scale){if(!plausibleBone(hip,knee,scale*.34f,
      scale*1.80f)){invalidate(knee);invalidate(ankle);invalidate(foot);return;}if(!plausibleBone(knee,ankle,scale*.32f,scale*1.85f)){invalidate(ankle);
      invalidate(foot);return;}if(ankle.tracked()&&foot.tracked()&&!plausibleBone(ankle,foot,scale*.02f,scale*.85f))invalidate(foot);
    }
  boolean plausibleBone(SkeletonJoint3D a,SkeletonJoint3D b,float minLen,float maxLen){if(a==null||b==null||!a.tracked()||!b.tracked())return false;
    float d=PVector.dist(a.world,b.world);return d>=minLen&&d<=maxLen;}
  void invalidate(SkeletonJoint3D j){if(j!=null){j.state=0;j.confidence=0;}}
  int centralTop(SkeletonDepthBodyMask b){float mid=(b.px(b.minGX)+b.px(b.maxGX))*.5f,half=max(18,(b.px(b.maxGX)-b.px(b.minGX))*.22f);
    for(int gy=b.minGY;gy<=b.maxGY;gy++)for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;
      if(b.mask[i]&&abs(b.px(gx)-mid)<=half)return b.py(gy);}return b.py(b.minGY);
    }
  float centerAtOr(SkeletonDepthBodyMask b,int y,int band,float fallback){float v=centerAt(b,y,band);
    return Float.isNaN(v)?fallback:v;}
  float centerAt(SkeletonDepthBodyMask b,int y,int band){long sum=0;int n=0;for(int gy=b.minGY;gy<=b.maxGY;gy++){int py=b.py(gy);
      if(abs(py-y)>band)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;
        if(b.mask[i]){sum+=b.px(gx);n++;}}}return n==0?Float.NaN:sum/(float)n;}
  float torsoWidth(SkeletonDepthBodyMask b,int top,int height,float center){ArrayList<Integer> widths=new ArrayList<Integer>();
    for(int y=round(top+height*.28f);y<=round(top+height*.54f);y+=max(4,b.step)){int[] span=rowSpan(b,y,max(3,b.step));
      if(span[2]>=2)widths.add(span[1]-span[0]+b.step);}if(widths.isEmpty())return max(20,(b.px(b.maxGX)-b.px(b.minGX))*.36f);
    Collections.sort(widths);int idx=constrain(round((widths.size()-1)*.36f),0,widths.size()-1);
    return widths.get(idx);}
  int[] rowSpan(SkeletonDepthBodyMask b,int y,int band){int lo=b.width,hi=-1,n=0;
    for(int gy=b.minGY;gy<=b.maxGY;gy++){if(abs(b.py(gy)-y)>band)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;
        if(!b.mask[i])continue;int x=b.px(gx);lo=min(lo,x);hi=max(hi,x);n++;}}return new int[]{lo,hi,n};
    }
  SkeletonBodyPoint pointNear(SkeletonDepthBodyMask b,float x,float y,int radius,float q){int best=nearestMaskIndex(b,x,y,radius);
    if(best<0)return new SkeletonBodyPoint();return new SkeletonBodyPoint(b.px(best%b.gridW),b.py(best/b.gridW),q);
    }
  SkeletonBodyPoint betweenOnMask(SkeletonDepthBodyMask b,SkeletonBodyPoint a,SkeletonBodyPoint z,float t,int radius,float q){if(a==null||z==null||!a.valid||!z.valid)return new SkeletonBodyPoint();
    return pointNear(b,lerp(a.x,z.x,t),lerp(a.y,z.y,t),radius,q);}
  void clampSkeleton(SkeletonPose3D s){for(SkeletonJoint3D j:allJoints(s))if(j!=null&&j.tracked()){j.image.x=constrain(j.image.x,0,studio.services.scannerProtocol.WIDTH-1);
      j.image.y=constrain(j.image.y,0,studio.services.scannerProtocol.HEIGHT-1);}}
  SkeletonJoint3D[] allJoints(SkeletonPose3D s){return new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.hipCenter,s.leftShoulder,s.rightShoulder,
      s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,
      s.rightFoot};}
  int trackedCount(SkeletonJoint3D[] js){int n=0;for(SkeletonJoint3D j:js)if(j!=null&&j.tracked())n++;
    return n;}
  float avgTracked(SkeletonJoint3D[] js){float sum=0;int n=0;for(SkeletonJoint3D j:js)if(j!=null&&j.tracked()){sum+=j.confidence;
      n++;}return n==0?0:sum/n;}
  void deriveBounds(SkeletonPose3D s){int minX=studio.services.scannerProtocol.WIDTH-1,minY=studio.services.scannerProtocol.HEIGHT-1,maxX=0,maxY=0;
    for(SkeletonJoint3D j:allJoints(s))if(j.tracked()){minX=min(minX,round(j.image.x));
      maxX=max(maxX,round(j.image.x));minY=min(minY,round(j.image.y));maxY=max(maxY,round(j.image.y));
      }s.minX=max(0,minX);s.maxX=min(studio.services.scannerProtocol.WIDTH-1,maxX);
    s.minY=max(0,minY);s.maxY=min(studio.services.scannerProtocol.HEIGHT-1,maxY);
    s.clippedTop=s.minY<=1;s.clippedBottom=s.maxY>=studio.services.scannerProtocol.HEIGHT-2;
    }
  float meanDepth(SkeletonPose3D s){float sum=0;int n=0;for(SkeletonJoint3D j:allJoints(s))if(j.tracked()&&j.world.z>0){sum+=j.world.z;
      n++;}return n==0?0:sum/n;}
}

