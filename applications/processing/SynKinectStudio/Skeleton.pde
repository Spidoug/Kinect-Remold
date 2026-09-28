// ===== SynKinect Studio / Shared Skeleton Library =====
//
// SynSkeleton is the reusable body-tracking layer used by Studio modules. It keeps
// sensor transport outside the tracker: callers provide calibrated RGB-D frames and
// receive an immutable pose/body-cloud snapshot. All body-analysis, adaptive motion
// learning, anthropometry, filtering and metric body-cloud extraction live here.
// Frontends (including Interactivity) consume the result and must not reimplement tracking.
//
// Design goals: persistent identity, robust depth-person segmentation, articulated
// limb paths, confidence-aware temporal consensus, adaptive low-latency filtering,
// coherent root stabilization, anthropometric constraints and short occlusion hold.
class SkeletonConfig {
  int minDepthMm=550,maxDepthMm=3800;
  float poseMinCoreConfidence=0.30f,trackingMinCoreCoverage=0.55f,trackingMinBodyConfidence=0.28f;

  int poseOcclusionHoldFrames=36,trackingAcquireFrames=3,trackingReleaseFrames=18;

  float poseFilterMinAlpha=0.08f,poseFilterMaxAlpha=0.82f,poseVelocityAlpha=0.22f,poseMaxSpeedMps=5.5f,poseMaxAccelerationMps2=24.0f;

  float poseOneEuroMinCutoff=0.90f,poseOneEuroBeta=1.35f,poseOneEuroDerivativeCutoff=1.0f;
  // Quality-first refinement intentionally spends additional CPU cycling the pose
  // between metric depth evidence and the articulated model.  This is shared by
  // Windows and Linux so tracking behavior remains platform-independent.
  int qualityRefinementPasses=3,qualityCloudPasses=2;


  float poseInnovationGateM=0.26f,poseJitterRadiusM=0.010f,poseBoneLearnAlpha=0.055f,poseBoneCorrection=0.72f,poseMaxDirectionJumpDeg=68.0f;
  // Depth continuity is evaluated independently from the 2D silhouette. It prevents
  // crossing limbs/background surfaces from stealing a joint merely because their
  // image-space location is close to the expected landmark.
  float poseDepthTemporalGateM=0.34f,poseDepthTemporalWeight=0.72f;
  int poseFullResolutionRefineRadiusPx=6,poseFullResolutionDepthToleranceMm=120;
  int consensusWindow=5;float consensusMadScale=2.8f,consensusMinRadiusM=0.012f,consensusMaxBlend=0.58f;

  float rootMinCutoff=0.72f,rootBeta=0.34f,rootDerivativeCutoff=1.0f,rootMaxCorrectionM=0.055f;

  float identityVelocityAlpha=0.28f,identityMaxPredictionPx=90.0f,identityMaxPredictionM=0.28f;

  float kalmanProcessNoise=0.38f,kalmanMeasurementNoiseM=0.020f,kalmanDepthNoiseScale=0.0065f,kalmanVelocityDamping=0.985f,kalmanPredictionMs=22.0f;
  float motionPriorVelocityAlpha=0.34f,motionPriorLowConfidence=0.58f,motionPriorBlend=0.46f,motionPriorRootBlend=0.72f,motionPriorMaxPredictionM=0.09f;

  // Per-joint online motion learning.  The learner only adapts bounded envelopes;
  // it never creates pose evidence. Distal joints are allowed to react faster while
  // torso/root joints remain deliberately conservative.
  float jointLearningAlpha=0.045f,jointConfidenceAlpha=0.060f,jointMotionMinConfidence=0.48f,jointLearnedEnvelope=0.55f;
  int jointLearningWarmupFrames=24;
  float anthropologyMinConfidence=0.72f,anthropologyLearnAlpha=0.030f,anthropologyMaxDeviation=0.12f;
  int anthropologyWarmupSamples=18;

  int modelIterations=8;float modelObservationStiffness=0.58f,modelInferredStiffness=0.18f,modelBoneStiffness=0.72f,modelTorsoStiffness=0.34f,modelMaxCorrectionM=0.075f,
  modelLearnAlpha=0.045f;
  float bodyTemporalCenterPx=120.0f,bodyTemporalDepthM=0.45f;
  int bodySampleStep=3,bodyDepthBinMm=80,bodyDepthBandMm=360,bodyDepthHypotheses=6,bodyContinuityMm=180,bodyMinSamples=90,bodyMinHeightPx=80,bodyHistogramCapSamples=1600,
  bodyBridgeCells=1,bodyRobustDepthRadiusPx=2;
  float bodyMaxWidthRatio=0.98f,bodyCenterBias=0.0f,bodyMinAspect=0.65f,bodyMinRowCoverage=0.58f,bodyMinFillRatio=0.055f,bodyTemporalRejectScale=0.68f,
  bodyHumanShapeWeight=0.52f,bodyTemporalMaskWeight=0.70f,bodyEdgeContactPenalty=0.0f,bodyIdentitySwitchMinAffinity=0.055f;
  int bodyIdentitySwitchGraceMisses=3;
  float postureFullLegCoverage=0.62f,postureSeatedLegCoverage=0.28f,postureLowerHoldConfidence=0.34f;
  int presentationCloudSampleStep=2;
  float presentationCloudArmReserveM=1.02f,presentationCloudVerticalReserveM=1.18f,presentationCloudDepthReserveM=0.62f,presentationCloudTrackedSupportM=0.078f;
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
    poseMaxAccelerationMps2=r.decimal(p,"pose.maxAccelerationMps2",poseMaxAccelerationMps2,4.0f,80.0f);
    qualityRefinementPasses=r.integer(p,"quality.refinementPasses",qualityRefinementPasses,1,5);
    qualityCloudPasses=r.integer(p,"quality.cloudPasses",qualityCloudPasses,1,4);
    poseOneEuroMinCutoff=r.decimal(p,"pose.oneEuroMinCutoff",poseOneEuroMinCutoff,0.1f,8.0f);
    poseOneEuroBeta=r.decimal(p,"pose.oneEuroBeta",poseOneEuroBeta,0.0f,8.0f);poseOneEuroDerivativeCutoff=r.decimal(p,"pose.oneEuroDerivativeCutoff",poseOneEuroDerivativeCutoff,
      0.1f,8.0f);

    poseInnovationGateM=r.decimal(p,"pose.innovationGateM",poseInnovationGateM,0.04f,1.0f);
    poseJitterRadiusM=r.decimal(p,"pose.jitterRadiusM",poseJitterRadiusM,0.001f,0.08f);
    poseBoneLearnAlpha=r.decimal(p,"pose.boneLearnAlpha",poseBoneLearnAlpha,0.005f,0.5f);
    poseBoneCorrection=r.decimal(p,"pose.boneCorrection",poseBoneCorrection,0.0f,1.0f);
    poseMaxDirectionJumpDeg=r.decimal(p,"pose.maxDirectionJumpDeg",poseMaxDirectionJumpDeg,20.0f,160.0f);
    poseDepthTemporalGateM=r.decimal(p,"pose.depthTemporalGateM",poseDepthTemporalGateM,0.08f,1.20f);
    poseDepthTemporalWeight=r.decimal(p,"pose.depthTemporalWeight",poseDepthTemporalWeight,0.0f,2.5f);
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
    motionPriorVelocityAlpha=r.decimal(p,"motionPrior.velocityAlpha",motionPriorVelocityAlpha,0.02f,0.95f);
    motionPriorLowConfidence=r.decimal(p,"motionPrior.lowConfidence",motionPriorLowConfidence,0.15f,0.95f);
    motionPriorBlend=r.decimal(p,"motionPrior.blend",motionPriorBlend,0.0f,0.95f);
    motionPriorRootBlend=r.decimal(p,"motionPrior.rootBlend",motionPriorRootBlend,0.0f,1.0f);
    motionPriorMaxPredictionM=r.decimal(p,"motionPrior.maxPredictionM",motionPriorMaxPredictionM,0.01f,0.40f);
    jointLearningAlpha=r.decimal(p,"jointLearning.alpha",jointLearningAlpha,0.005f,0.30f);
    jointConfidenceAlpha=r.decimal(p,"jointLearning.confidenceAlpha",jointConfidenceAlpha,0.005f,0.30f);
    jointMotionMinConfidence=r.decimal(p,"jointLearning.minConfidence",jointMotionMinConfidence,0.15f,0.95f);
    jointLearnedEnvelope=r.decimal(p,"jointLearning.envelope",jointLearnedEnvelope,0.0f,1.0f);
    jointLearningWarmupFrames=r.integer(p,"jointLearning.warmupFrames",jointLearningWarmupFrames,4,180);
    anthropologyMinConfidence=r.decimal(p,"anthropometry.minConfidence",anthropologyMinConfidence,0.50f,0.95f);
    anthropologyLearnAlpha=r.decimal(p,"anthropometry.learnAlpha",anthropologyLearnAlpha,0.003f,0.15f);
    anthropologyMaxDeviation=r.decimal(p,"anthropometry.maxDeviation",anthropologyMaxDeviation,0.03f,0.30f);
    anthropologyWarmupSamples=r.integer(p,"anthropometry.warmupSamples",anthropologyWarmupSamples,4,120);

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
    bodyTemporalMaskWeight=r.decimal(p,"body.temporalMaskWeight",bodyTemporalMaskWeight,0.0f,2.0f);
    bodyEdgeContactPenalty=r.decimal(p,"body.edgeContactPenalty",bodyEdgeContactPenalty,0.0f,1.0f);
    bodyIdentitySwitchMinAffinity=r.decimal(p,"body.identitySwitchMinAffinity",bodyIdentitySwitchMinAffinity,0.0f,0.50f);
    bodyIdentitySwitchGraceMisses=r.integer(p,"body.identitySwitchGraceMisses",bodyIdentitySwitchGraceMisses,0,12);
    postureFullLegCoverage=r.decimal(p,"posture.fullLegCoverage",postureFullLegCoverage,0.30f,0.95f);
    postureSeatedLegCoverage=r.decimal(p,"posture.seatedLegCoverage",postureSeatedLegCoverage,0.05f,0.70f);
    postureLowerHoldConfidence=r.decimal(p,"posture.lowerHoldConfidence",postureLowerHoldConfidence,0.05f,0.80f);
    presentationCloudSampleStep=r.integer(p,"cloud.sampleStep",presentationCloudSampleStep,1,6);
    presentationCloudArmReserveM=r.decimal(p,"cloud.armReserveM",presentationCloudArmReserveM,.55f,1.60f);
    presentationCloudVerticalReserveM=r.decimal(p,"cloud.verticalReserveM",presentationCloudVerticalReserveM,.65f,1.60f);
    presentationCloudDepthReserveM=r.decimal(p,"cloud.depthReserveM",presentationCloudDepthReserveM,.25f,1.20f);
    presentationCloudTrackedSupportM=r.decimal(p,"cloud.trackedSupportM",presentationCloudTrackedSupportM,.02f,.20f);

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
  SkeletonProcessingSession createSession(Calibration calibration,RgbDepthRegistration registration){return new SkeletonProcessingSession(configuration(),calibration,registration);}
}

class SkeletonModuleFrame {
  final SkeletonPose3D pose;final PointCloud bodyCloud;final long frameNumber;
  SkeletonModuleFrame(SkeletonPose3D pose,PointCloud cloud,long frameNumber){this.pose=pose;this.bodyCloud=cloud;this.frameNumber=frameNumber;}
}

class SkeletonProcessingSession {
  final SkeletonConfig cfg;final SkeletonTracker tracker;
  SkeletonProcessingSession(SkeletonConfig cfg,Calibration calibration,RgbDepthRegistration registration){this.cfg=cfg;tracker=new SkeletonTracker(cfg,calibration,registration);}
  void reset(){tracker.reset();}
  String statusReason(){return tracker==null?"searching":tracker.lastReason;}
  SkeletonModuleFrame process(DepthFrame depth,InfraredFrame infrared,long tick){
    if(depth==null||depth.depth==null)return new SkeletonModuleFrame(new SkeletonPose3D(),new PointCloud(1),-1);
    SkeletonPose3D pose=tracker.track(depth,infrared,tick);
    return new SkeletonModuleFrame(pose,bodyCloud(depth,pose),depth.frameNumber);
  }
  PointCloud bodyCloud(DepthFrame frame,SkeletonPose3D pose){
    PointCloud cloud=new PointCloud(22000);if(frame==null||frame.depth==null||tracker.cal==null)return cloud;
    float centerZ=pose!=null&&pose.tracked?pose.meanDepthM:Float.NaN;int step=max(1,cfg.presentationCloudSampleStep);
    boolean locked=pose!=null&&pose.tracked&&pose.hipCenter!=null&&pose.hipCenter.tracked();
    float minWX=-Float.MAX_VALUE,maxWX=Float.MAX_VALUE,minWY=-Float.MAX_VALUE,maxWY=Float.MAX_VALUE;
    if(locked){PVector anchor=pose.spine!=null&&pose.spine.tracked()?pose.spine.world:pose.hipCenter.world;
      minWX=anchor.x-cfg.presentationCloudArmReserveM;maxWX=anchor.x+cfg.presentationCloudArmReserveM;
      minWY=anchor.y-cfg.presentationCloudVerticalReserveM;maxWY=anchor.y+cfg.presentationCloudVerticalReserveM;}
    for(int v=0;v<frame.height;v+=step)for(int u=0;u<frame.width;u+=step){int idx=v*frame.width+u,mm=frame.depth[idx]&0xffff;if(mm==0)continue;
      if(tracker.cal.sharedCalibration!=null)mm=tracker.cal.sharedCalibration.correctedDepthMm(idx,mm);if(mm<450||mm>4500)continue;
      float z=mm*.001f;if(!Float.isNaN(centerZ)&&abs(z-centerZ)>(locked?cfg.presentationCloudDepthReserveM:.72f))continue;
      PVector q=tracker.cal.deproject(u,v,mm);if(q==null)continue;if(locked&&(q.x<minWX||q.x>maxWX||q.y<minWY||q.y>maxWY))continue;
      if(locked&&!bodyCloudSupport(q,pose))continue;float confidence=locked?bodyCloudConfidence(q,pose):1.0f;cloud.add(q,0xff58c7f3,confidence);}
    return cloud;
  }
  float segmentDistance(PVector p,PVector a,PVector b){if(p==null||a==null||b==null)return Float.POSITIVE_INFINITY;PVector ab=PVector.sub(b,a);float d=ab.magSq();if(d<1e-8f)return PVector.dist(p,a);float t=constrain(PVector.sub(p,a).dot(ab)/d,0,1);return PVector.dist(p,PVector.add(a,PVector.mult(ab,t)));}
  float jointDistance(PVector p,SkeletonJoint3D j){return j!=null&&j.tracked()?PVector.dist(p,j.world):Float.POSITIVE_INFINITY;}
  float boneDistance(PVector p,SkeletonJoint3D a,SkeletonJoint3D b){return a!=null&&b!=null&&a.tracked()&&b.tracked()?segmentDistance(p,a.world,b.world):Float.POSITIVE_INFINITY;}
  float supportDistance(PVector p,SkeletonPose3D s){float d=Float.POSITIVE_INFINITY;if(p==null||s==null)return d;d=min(d,jointDistance(p,s.head)-.13f);d=min(d,boneDistance(p,s.head,s.shoulderCenter)-.105f);d=min(d,boneDistance(p,s.shoulderCenter,s.spine)-.17f);d=min(d,boneDistance(p,s.spine,s.hipCenter)-.19f);d=min(d,boneDistance(p,s.leftShoulder,s.rightShoulder)-.13f);d=min(d,boneDistance(p,s.leftHip,s.rightHip)-.14f);SkeletonJoint3D[][] bones={{s.leftShoulder,s.leftElbow},{s.leftElbow,s.leftWrist},{s.leftWrist,s.leftHand},{s.rightShoulder,s.rightElbow},{s.rightElbow,s.rightWrist},{s.rightWrist,s.rightHand},{s.leftHip,s.leftKnee},{s.leftKnee,s.leftAnkle},{s.leftAnkle,s.leftFoot},{s.rightHip,s.rightKnee},{s.rightKnee,s.rightAnkle},{s.rightAnkle,s.rightFoot}};for(SkeletonJoint3D[] b:bones)d=min(d,boneDistance(p,b[0],b[1])-.095f);return d;}
  boolean bodyCloudSupport(PVector p,SkeletonPose3D s){float d=supportDistance(p,s);if(d<=cfg.presentationCloudTrackedSupportM)return true;SkeletonJoint3D root=s.spine!=null&&s.spine.tracked()?s.spine:s.hipCenter;if(root==null||!root.tracked())return false;float dz=abs(p.z-s.meanDepthM);if(dz>cfg.presentationCloudDepthReserveM)return false;float armReach=constrain(cfg.presentationCloudArmReserveM*.82f,.58f,.90f);float left=s.leftShoulder!=null&&s.leftShoulder.tracked()?PVector.dist(p,s.leftShoulder.world):Float.POSITIVE_INFINITY,right=s.rightShoulder!=null&&s.rightShoulder.tracked()?PVector.dist(p,s.rightShoulder.world):Float.POSITIVE_INFINITY;float shoulderReach=min(left,right),hipY=s.hipCenter!=null&&s.hipCenter.tracked()?s.hipCenter.world.y:root.world.y+.42f;boolean armDiscovery=shoulderReach<=armReach&&p.y<=hipY+.18f;float dx=abs(p.x-root.world.x),shoulderY=s.shoulderCenter!=null&&s.shoulderCenter.tracked()?s.shoulderCenter.world.y:root.world.y-.28f;boolean coreDiscovery=dx<=.34f&&p.y>=shoulderY-.22f&&p.y<=hipY+.16f&&dz<=cfg.presentationCloudDepthReserveM*.62f;return armDiscovery||coreDiscovery;}
  float bodyCloudConfidence(PVector p,SkeletonPose3D s){float d=max(0,supportDistance(p,s));if(d<=cfg.presentationCloudTrackedSupportM)return constrain(1.0f-d/max(.001f,cfg.presentationCloudTrackedSupportM),.34f,1.0f);SkeletonJoint3D root=s.spine!=null&&s.spine.tracked()?s.spine:s.hipCenter;if(root==null||!root.tracked())return .16f;float armReach=constrain(cfg.presentationCloudArmReserveM*.82f,.58f,.90f),shoulderReach=Float.POSITIVE_INFINITY;if(s.leftShoulder!=null&&s.leftShoulder.tracked())shoulderReach=min(shoulderReach,PVector.dist(p,s.leftShoulder.world));if(s.rightShoulder!=null&&s.rightShoulder.tracked())shoulderReach=min(shoulderReach,PVector.dist(p,s.rightShoulder.world));float depth=abs(p.z-s.meanDepthM)/max(.1f,cfg.presentationCloudDepthReserveM),reach=shoulderReach==Float.POSITIVE_INFINITY?1.0f:shoulderReach/max(.1f,armReach);return constrain(.52f-.18f*reach-.14f*depth,.16f,.48f);}
}

class SkeletonHistorySample {final PVector world;final float confidence;final long tickMs;
  SkeletonHistorySample(PVector w,float q,long t){world=w.copy();confidence=q;tickMs=t;
    }}
class SkeletonTemporalConsensus {
  final SkeletonConfig cfg;final HashMap<String,ArrayDeque<SkeletonHistorySample>> history=new HashMap<String,ArrayDeque<SkeletonHistorySample>>();

  SkeletonTemporalConsensus(SkeletonConfig c){cfg=c;}void reset(){history.clear();
    }
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.canonicalJoints()
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
    float motion=0;if(samples.size()>=2){SkeletonHistorySample a=samples.get(samples.size()-2),b=samples.get(samples.size()-1);float dt=max(.008f,(b.tickMs-a.tickMs)/1000.0f);motion=PVector.dist(a.world,b.world)/dt;}
    float motionScale=lerp(1.0f,.28f,constrain(motion/1.6f,0,1));
    if(deviation>gate){float blend=constrain((cfg.consensusMaxBlend+(deviation-gate)/max(gate,.001f)*.12f)*motionScale,0,cfg.consensusMaxBlend+.18f);
      j.world.set(PVector.lerp(j.world,center,blend));j.confidence*=constrain(gate/max(deviation,.001f),.45f,1.0f);
      if(j.state==2&&blend>.18f)j.state=1;}else if(deviation<radius){float blend=cfg.consensusMaxBlend*constrain(1.0f-j.confidence*.55f,0.15f,.65f)*motionScale;
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
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.canonicalJoints()
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
    float velocityAlpha=1.0f-pow(1.0f-constrain(cfg.identityVelocityAlpha,.001f,.999f),constrain(dt/.0166667f,.25f,8.0f));
    velocity=PVector.lerp(velocity,measuredVelocity,velocityAlpha);
    float measuredDepthVelocity=(anchor.world.z-depthM)/dt;
    depthVelocity=lerp(depthVelocity,measuredDepthVelocity,velocityAlpha);

    center.set(uv);depthM=anchor.world.z;tickMs=now;
  }
  void miss(){velocity.mult(.82f);depthVelocity*=.82f;}
}

class SkeletonAdaptiveJointState {
  PVector position=new PVector(),velocity=new PVector();float speedEma=0,accelEma=0,confidenceEma=.5f,innovationEma=0;
  long tickMs=0;int samples=0;boolean initialized=false;
}
class SkeletonJointMotionLearner {
  final SkeletonConfig cfg;final HashMap<String,SkeletonAdaptiveJointState> states=new HashMap<String,SkeletonAdaptiveJointState>();
  SkeletonJointMotionLearner(SkeletonConfig c){cfg=c;}void reset(){states.clear();}
  SkeletonAdaptiveJointState state(String name){SkeletonAdaptiveJointState st=states.get(name);if(st==null){st=new SkeletonAdaptiveJointState();states.put(name,st);}return st;}
  float baseMobility(String name){if(name==null)return 1.0f;String n=name.toLowerCase(Locale.ROOT);
    if(n.contains("hand_tip")||n.contains("thumb")||n.contains("index_")||n.contains("middle_")||n.contains("ring_")||n.contains("pinky_"))return 1.48f;
    if(n.endsWith("_hand")||n.endsWith("_wrist"))return 1.36f;
    if(n.endsWith("_foot")||n.endsWith("_ankle"))return 1.18f;
    if(n.endsWith("_elbow"))return 1.20f;if(n.endsWith("_knee"))return 1.08f;
    if(n.endsWith("_shoulder")||n.endsWith("_hip"))return .82f;
    if("head".equals(n))return .78f;
    if("shoulder_center".equals(n)||"spine_shoulder".equals(n)||"spine".equals(n)||"hip_center".equals(n))return .62f;
    return 1.0f;
  }
  float baseJitter(String name){float m=baseMobility(name);return constrain(1.28f-.36f*(m-.62f)/.86f,.72f,1.32f);}
  void observe(SkeletonPose3D pose,long now){if(pose==null)return;for(SkeletonJoint3D j:pose.canonicalJoints())observe(j,now);}
  void observe(SkeletonJoint3D j,long now){if(j==null)return;SkeletonAdaptiveJointState st=state(j.name);
    float ca=cfg.jointConfidenceAlpha;st.confidenceEma=lerp(st.confidenceEma,constrain(j.confidence,0,1),ca);
    if(!j.observed()||j.world==null||j.world.z<=0||j.confidence<cfg.jointMotionMinConfidence)return;
    if(!st.initialized){st.position.set(j.world);st.velocity.set(0,0,0);st.tickMs=now;st.initialized=true;st.samples=1;return;}
    float dt=constrain((now-st.tickMs)/1000.0f,.008f,.12f);PVector v=PVector.sub(j.world,st.position);v.div(dt);
    float hard=cfg.poseMaxSpeedMps*baseMobility(j.name)*1.7f;if(v.mag()>hard)v.setMag(hard);
    PVector dv=PVector.sub(v,st.velocity);float accel=dv.mag()/max(dt,.001f),speed=v.mag();
    float a=1.0f-pow(1.0f-constrain(cfg.jointLearningAlpha,.001f,.999f),constrain(dt/.033333f,.25f,4.0f));
    st.speedEma=lerp(st.speedEma,speed,a);st.accelEma=lerp(st.accelEma,min(accel,cfg.poseMaxAccelerationMps2*2.2f),a);
    PVector predicted=PVector.add(st.position,PVector.mult(st.velocity,dt));st.innovationEma=lerp(st.innovationEma,PVector.dist(predicted,j.world),a);
    st.velocity=PVector.lerp(st.velocity,v,constrain(a*1.6f,.04f,.65f));st.position.set(j.world);st.tickMs=now;st.samples=min(100000,st.samples+1);
  }
  float maturity(String name){SkeletonAdaptiveJointState st=states.get(name);return st==null?0:constrain(st.samples/(float)max(1,cfg.jointLearningWarmupFrames),0,1);}
  float reliability(String name){SkeletonAdaptiveJointState st=states.get(name);if(st==null)return .55f;float stable=1.0f-constrain(st.innovationEma/.12f,0,1);return constrain(.15f+.60f*st.confidenceEma+.25f*stable,.12f,1.0f);}
  float learnedActivity(String name){SkeletonAdaptiveJointState st=states.get(name);if(st==null)return 0;float ref=.85f*baseMobility(name);return constrain(st.speedEma/max(.20f,ref),0,1.8f);}
  float response(String name){float base=baseMobility(name),m=maturity(name),activity=learnedActivity(name);float learned=lerp(.88f,1.22f,constrain(activity/1.4f,0,1));return base*lerp(1.0f,learned,m*cfg.jointLearnedEnvelope);}
  float speedLimit(String name){float r=response(name);SkeletonAdaptiveJointState st=states.get(name);float empirical=st==null?0:st.speedEma*3.2f;return constrain(max(cfg.poseMaxSpeedMps*r*.72f,empirical),cfg.poseMaxSpeedMps*.42f,cfg.poseMaxSpeedMps*1.72f);}
  float accelerationLimit(String name){float r=response(name);SkeletonAdaptiveJointState st=states.get(name);float empirical=st==null?0:st.accelEma*2.8f;return constrain(max(cfg.poseMaxAccelerationMps2*r*.72f,empirical),cfg.poseMaxAccelerationMps2*.40f,cfg.poseMaxAccelerationMps2*1.85f);}
  float jitterScale(String name){float rel=reliability(name),base=baseJitter(name);return base*lerp(1.22f,.82f,rel);}
  float predictionScale(String name){return constrain(.62f+.42f*response(name),.55f,1.28f);}
}

class SkeletonMotionState {
  PVector position=new PVector(),velocity=new PVector();long tickMs=0;boolean initialized=false;
}
class SkeletonMotionPrior {
  final SkeletonConfig cfg;final SkeletonJointMotionLearner learner;final HashMap<String,SkeletonMotionState> states=new HashMap<String,SkeletonMotionState>();
  SkeletonMotionPrior(SkeletonConfig c,SkeletonJointMotionLearner l){cfg=c;learner=l;}
  void reset(){states.clear();}
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.canonicalJoints();}
  PVector root(SkeletonPose3D s){if(s==null)return null;if(s.spine.tracked())return s.spine.world;if(s.hipCenter.tracked())return s.hipCenter.world;
    return s.shoulderCenter.tracked()?s.shoulderCenter.world:null;}
  SkeletonJoint3D find(SkeletonPose3D s,String name){if(s==null)return null;for(SkeletonJoint3D j:joints(s))if(j!=null&&j.name.equals(name))return j;return null;}
  void apply(SkeletonPose3D current,SkeletonPose3D previous,long now,SkeletonCalibration3D cal){
    if(current==null)return;PVector cr=root(current),pr=root(previous),rootDelta=new PVector();if(cr!=null&&pr!=null)rootDelta=PVector.sub(cr,pr);
    for(SkeletonJoint3D joint:joints(current)){
      SkeletonMotionState st=states.get(joint.name);if(st==null){st=new SkeletonMotionState();states.put(joint.name,st);}SkeletonJoint3D prior=find(previous,joint.name);
      float dt=st.initialized?constrain((now-st.tickMs)/1000.0f,.008f,.12f):1.0f/30.0f;
      PVector predicted=null;if(st.initialized){predicted=PVector.add(st.position,PVector.mult(st.velocity,dt));predicted.add(PVector.mult(rootDelta,cfg.motionPriorRootBlend));
        float predictionLimit=cfg.motionPriorMaxPredictionM*learner.predictionScale(joint.name);PVector delta=PVector.sub(predicted,st.position);if(delta.mag()>predictionLimit)predicted=PVector.add(st.position,delta.setMag(predictionLimit));}
      else if(prior!=null&&prior.tracked())predicted=PVector.add(prior.world,PVector.mult(rootDelta,cfg.motionPriorRootBlend));
      if(joint.tracked()&&joint.world.z>0){
        if(predicted!=null&&joint.confidence<cfg.motionPriorLowConfidence){float weakness=constrain((cfg.motionPriorLowConfidence-joint.confidence)/max(.01f,cfg.motionPriorLowConfidence),0,1);
          float predictionLimit=cfg.motionPriorMaxPredictionM*learner.predictionScale(joint.name);float blend=cfg.motionPriorBlend*weakness*lerp(1.12f,.82f,learner.reliability(joint.name));float distance=PVector.dist(joint.world,predicted);if(distance<predictionLimit*2.2f){joint.world.set(PVector.lerp(joint.world,predicted,blend));
            joint.confidence=constrain(joint.confidence+.10f*weakness,0,1);PVector uv=cal.projectWorldRgb(joint.world);if(uv!=null)joint.image.set(uv);}}
        if(!st.initialized){st.position.set(joint.world);st.velocity.set(0,0,0);st.initialized=true;}else{PVector measured=PVector.sub(joint.world,st.position);measured.div(dt);
          float a=1.0f-pow(1.0f-constrain(cfg.motionPriorVelocityAlpha,.001f,.999f),constrain(dt/.0166667f,.25f,8.0f));st.velocity=PVector.lerp(st.velocity,measured,a);
          float vlim=learner.speedLimit(joint.name);if(st.velocity.mag()>vlim)st.velocity.setMag(vlim);st.position.set(joint.world);}st.tickMs=now;
      }else if(predicted!=null&&prior!=null&&prior.tracked()){
        joint.world.set(predicted);PVector uv=cal.projectWorldRgb(joint.world);if(uv!=null){joint.image.set(uv);joint.state=1;joint.confidence=max(.08f,prior.confidence*.70f);}
      }
    }
  }
}

class SkeletonJoint3D {
  static final int LOST=0,INFERRED=1,TRACKED=2,PREDICTED=3,OCCLUDED=4;
  final String name;PVector image=new PVector(),world=new PVector(),velocity=new PVector();float confidence=0;
  int state=LOST;long lastObservedMs=0;String source="none";
  SkeletonJoint3D(String n){name=n;}
  SkeletonJoint3D set(PVector uv,PVector xyz,float q,int s){return set(uv,xyz,q,s,"fusion",millis64());}
  SkeletonJoint3D set(PVector uv,PVector xyz,float q,int s,String src,long tick){
    if(uv!=null)image.set(uv);if(xyz!=null){if(lastObservedMs>0&&tick>lastObservedMs){float dt=max(.001f,(tick-lastObservedMs)/1000.0f);PVector measured=PVector.sub(xyz,world);measured.div(dt);velocity=PVector.lerp(velocity,measured,.28f);}world.set(xyz);}
    confidence=constrain(q,0,1);state=s;source=src==null?"fusion":src;if(s==TRACKED||s==INFERRED)lastObservedMs=tick;return this;
  }
  boolean tracked(){return state>LOST&&confidence>0;}
  boolean observed(){return state==TRACKED||state==INFERRED;}
}

// Canonical hand topology follows the 21-landmark convention used by modern hand
// trackers: wrist + four joints for each of thumb/index/middle/ring/pinky.  The
// wrist aliases the body wrist conceptually but remains independent so a neural
// hand provider can be fused/rejected without corrupting the body solution.
class SkeletonHand3D {
  static final int LANDMARKS=21;final String side;final SkeletonJoint3D[] landmarks=new SkeletonJoint3D[LANDMARKS];
  float confidence=0;String gesture="unknown",source="none";boolean visible=false;
  SkeletonHand3D(String s){side=s;String[] n={"wrist","thumb_cmc","thumb_mcp","thumb_ip","thumb_tip","index_mcp","index_pip","index_dip","index_tip","middle_mcp","middle_pip","middle_dip","middle_tip","ring_mcp","ring_pip","ring_dip","ring_tip","pinky_mcp","pinky_pip","pinky_dip","pinky_tip"};for(int i=0;i<LANDMARKS;i++)landmarks[i]=new SkeletonJoint3D(side+"_"+n[i]);}
  SkeletonJoint3D wrist(){return landmarks[0];}SkeletonJoint3D thumbTip(){return landmarks[4];}SkeletonJoint3D indexTip(){return landmarks[8];}
  SkeletonJoint3D middleTip(){return landmarks[12];}SkeletonJoint3D ringTip(){return landmarks[16];}SkeletonJoint3D pinkyTip(){return landmarks[20];}
  void updateConfidence(){float sum=0;int n=0;for(SkeletonJoint3D j:landmarks)if(j.tracked()){sum+=j.confidence;n++;}confidence=n==0?0:sum/n;visible=n>=6&&confidence>.18f;}
}

class SkeletonPose3D {
  boolean tracked=false;long trackingId=0;float confidence=0,torsoConfidence=0,upperBodyConfidence=0,interactionConfidence=0;
  String reason="searching",posture="unknown";int minX,minY,maxX,maxY;float meanDepthM=0,faceWidthPx=0,faceHeightPx=0,postureConfidence=0;
  boolean lowerBodyVisible=false;

  boolean clippedTop=false,clippedBottom=false;
  // Kinect Xbox 360/NUI topology and naming: ShoulderCenter and HipCenter are explicit joints.
  SkeletonJoint3D head=new SkeletonJoint3D("head"),shoulderCenter=new SkeletonJoint3D("shoulder_center"),spine=new SkeletonJoint3D("spine");

  SkeletonJoint3D leftShoulder=new SkeletonJoint3D("left_shoulder"),rightShoulder=new SkeletonJoint3D("right_shoulder"),leftElbow=new SkeletonJoint3D("left_elbow"),
  rightElbow=new SkeletonJoint3D("right_elbow"),leftWrist=new SkeletonJoint3D("left_wrist"),rightWrist=new SkeletonJoint3D("right_wrist"),leftHand=new SkeletonJoint3D("left_hand"),
  rightHand=new SkeletonJoint3D("right_hand");
  SkeletonJoint3D hipCenter=new SkeletonJoint3D("hip_center"),leftHip=new SkeletonJoint3D("left_hip"),rightHip=new SkeletonJoint3D("right_hip"),leftKnee=new SkeletonJoint3D("left_knee"),
  rightKnee=new SkeletonJoint3D("right_knee"),leftAnkle=new SkeletonJoint3D("left_ankle"),rightAnkle=new SkeletonJoint3D("right_ankle"),leftFoot=new SkeletonJoint3D("left_foot"),
  rightFoot=new SkeletonJoint3D("right_foot");
  // Kinect v2 native superset. These remain optional on Kinect v1 geometric tracking.
  SkeletonJoint3D spineShoulder=new SkeletonJoint3D("spine_shoulder"),leftHandTip=new SkeletonJoint3D("left_hand_tip"),rightHandTip=new SkeletonJoint3D("right_hand_tip"),
    leftThumb=new SkeletonJoint3D("left_thumb"),rightThumb=new SkeletonJoint3D("right_thumb");
  final SkeletonHand3D leftHandDetail=new SkeletonHand3D("left"),rightHandDetail=new SkeletonHand3D("right");
  String poseSource="depth-fusion";float lowerBodyConfidence=0;
  boolean torsoTracked(){return shoulderCenter.tracked()&&spine.tracked()&&hipCenter.tracked()&&leftShoulder.tracked()&&rightShoulder.tracked();
    }
  boolean leftHandTracked(){return leftHand.tracked();}boolean rightHandTracked(){return rightHand.tracked();
    }
  boolean interactionTracked(){return tracked&&torsoTracked()&&(leftHandTracked()||rightHandTracked())&&interactionConfidence>0;
    }
  SkeletonJoint3D[] nui20(){return new SkeletonJoint3D[]{hipCenter,spine,shoulderCenter,head,leftShoulder,leftElbow,leftWrist,leftHand,rightShoulder,rightElbow,
      rightWrist,rightHand,leftHip,leftKnee,leftAnkle,leftFoot,rightHip,rightKnee,rightAnkle,rightFoot};
    }
  SkeletonJoint3D[] kinectV2_25(){return new SkeletonJoint3D[]{spine,spineShoulder,shoulderCenter,head,leftShoulder,leftElbow,leftWrist,leftHand,rightShoulder,rightElbow,rightWrist,rightHand,leftHip,leftKnee,leftAnkle,leftFoot,rightHip,rightKnee,rightAnkle,rightFoot,hipCenter,leftHandTip,leftThumb,rightHandTip,rightThumb};}
  SkeletonJoint3D[] canonicalJoints(){ArrayList<SkeletonJoint3D> out=new ArrayList<SkeletonJoint3D>();Collections.addAll(out,kinectV2_25());Collections.addAll(out,leftHandDetail.landmarks);Collections.addAll(out,rightHandDetail.landmarks);return out.toArray(new SkeletonJoint3D[out.size()]);}
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

// SynSkeleton segments the metric-depth person component used by the native Body3D solver.
// Pose joints are solved volumetrically in calibrated 3D and then refined by temporal and
// anthropometric constraints; no silhouette/geodesic pose solver remains.
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
  final SkeletonConfig cfg;final int[] robustSamples=new int[5];
  boolean[] previousMask=null;int previousGridW=0,previousGridH=0,segmentationMisses=0;
  SkeletonDepthPersonSegmenter(SkeletonConfig c){cfg=c;}
  void reset(){previousMask=null;previousGridW=0;previousGridH=0;segmentationMisses=0;}
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
      // Interactivity deliberately uses the complete Kinect depth FOV. Do not
      // privilege the center: people entering from any edge remain candidates.
      central[b]++;
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
    double bestComponentScore=-1,bestTemporalAffinity=1.0;float bestOverlapRatio=1.0f;int[] queue=new int[candidate.length];
    for(int seed=0;seed<candidate.length;seed++){
      if(!candidate[seed]||labels[seed]>=0)continue;int qh=0,qt=0;queue[qt++]=seed;
      labels[seed]=component;int count=0,minGX=out.gridW,minGY=out.gridH,maxGX=-1,maxGY=-1;
      long sumX=0,sumY=0,sumD=0;int centerCount=0,sideEdgeCount=0,temporalOverlap=0;
      while(qh<qt){int at=queue[qh++],gx=at%out.gridW,gy=at/out.gridW,dm=out.mm[at];
        count++;minGX=min(minGX,gx);maxGX=max(maxGX,gx);minGY=min(minGY,gy);maxGY=max(maxGY,gy);
        sumX+=out.px(gx);sumY+=out.py(gy);sumD+=dm;if(out.px(gx)>=w*.20f&&out.px(gx)<=w*.80f)centerCount++;
        if(gx<=1||gx>=out.gridW-2||gy<=1)sideEdgeCount++;
        if(priorCenter!=null&&previousMask!=null&&previousGridW==out.gridW&&previousGridH==out.gridH&&at<previousMask.length&&previousMask[at])temporalOverlap++;

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
        double shapeFactor=lerp(1.0f-cfg.bodyHumanShapeWeight*.42f,1.0f+cfg.bodyHumanShapeWeight*.38f,humanShape);
        float overlapRatio=temporalOverlap/(float)max(1,count),edgeRatio=sideEdgeCount/(float)max(1,count);
        double temporalMaskFactor=1.0+cfg.bodyTemporalMaskWeight*constrain(overlapRatio*3.0f,0,1);
        double edgeFactor=Math.max(0.20,1.0-cfg.bodyEdgeContactPenalty*constrain(edgeRatio*4.0f,0,1));
        double score=count*(1.0+min(1.5f,aspect)*.20)*(1.0+2.35*temporal)*(.82+.18*hypothesis)*continuityShape*shapeFactor*temporalMaskFactor*edgeFactor/(max(.55f,
          meanDepth/1000.0f));if(priorCenter!=null&&priorDepthM>0&&temporal<.045)score*=cfg.bodyTemporalRejectScale;

        if(score>bestComponentScore){bestComponentScore=score;bestId=component;bestCount=count;bestTemporalAffinity=priorCenter!=null&&priorDepthM>0?temporal:1.0;bestOverlapRatio=overlapRatio;
          bestDepthMm=round(meanDepth);out.minGX=minGX;out.maxGX=maxGX;out.minGY=minGY;
          out.maxGY=maxGY;out.centerX=cx;out.centerY=cy;}
      }
      component++;
    }
    if(bestId<0){segmentationMisses++;if(segmentationMisses>=6)reset();return null;}
    // Do not hand identity to a different depth component on one ambiguous frame.
    // A genuine re-acquisition is allowed after a short bounded grace interval.
    boolean identityGuard=priorCenter!=null&&priorDepthM>0&&previousMask!=null&&previousGridW==out.gridW&&previousGridH==out.gridH;
    boolean lowAffinity=bestTemporalAffinity<cfg.bodyIdentitySwitchMinAffinity&&bestOverlapRatio<.025f;
    if(identityGuard&&lowAffinity&&segmentationMisses<cfg.bodyIdentitySwitchGraceMisses){segmentationMisses++;return null;}
    segmentationMisses=0;for(int i=0;i<labels.length;i++)out.mask[i]=labels[i]==bestId;
    previousMask=Arrays.copyOf(out.mask,out.mask.length);previousGridW=out.gridW;previousGridH=out.gridH;
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
  final SkeletonConfig cfg;final SkeletonJointMotionLearner learner;final HashMap<String,SkeletonJointFilterState> states=new HashMap<String,SkeletonJointFilterState>();

  SkeletonPoseFilter(SkeletonConfig c,SkeletonJointMotionLearner l){cfg=c;learner=l;}void reset(){states.clear();}
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.canonicalJoints()
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
  float jointResponsiveness(String name){return learner.response(name);}
  float jointJitterScale(String name){return learner.jitterScale(name);}
  void filter(SkeletonJoint3D j,long tickMs,SkeletonCalibration3D cal){
    if(j==null)return;SkeletonJointFilterState st=states.get(j.name);if(st==null){st=new SkeletonJointFilterState();
      states.put(j.name,st);}
    if(j.tracked()&&j.world.z>0){
      if(!st.initialized){st.raw.set(j.world);st.world.set(j.world);st.image.set(clampUv(j.image));
        st.tickMs=tickMs;st.initialized=true;st.missing=0;j.image.set(st.image);return;
        }
      float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f),response=jointResponsiveness(j.name);
      PVector predicted=PVector.add(st.world,PVector.mult(st.velocity,dt));float innovation=PVector.dist(predicted,j.world),speedLimit=learner.speedLimit(j.name),
      gate=max(cfg.poseInnovationGateM*lerp(1.35f,.82f,constrain(j.confidence,0,1)),speedLimit*dt*1.35f);
      if(innovation>gate){PVector delta=PVector.sub(j.world,predicted);if(delta.mag()>0)delta.setMag(gate);
        j.world.set(PVector.add(predicted,delta));j.confidence*=constrain(gate/max(innovation,.001f),.35f,1);
        }
      float jitter=cfg.poseJitterRadiusM*jointJitterScale(j.name)*lerp(1.45f,.82f,constrain(j.confidence,0,1)),residual=PVector.dist(st.world,j.world);
      if(residual<jitter){float blend=constrain(residual/max(jitter,.001f),0,1);j.world.set(PVector.lerp(st.world,j.world,.14f+.36f*blend));
        }
      PVector rawVelocity=PVector.sub(j.world,st.raw);rawVelocity.div(dt);
      // Depth-edge mistakes can look like physically impossible instantaneous limb
      // acceleration.  Clamp velocity change before it reaches the adaptive filter;
      // real fast motion remains available up to the configured acceleration envelope.
      PVector dv=PVector.sub(rawVelocity,st.velocity);float maxDv=learner.accelerationLimit(j.name)*dt;
      if(dv.mag()>maxDv&&maxDv>0)rawVelocity.set(PVector.add(st.velocity,dv.setMag(maxDv)));
      float da=constrain(alpha(dt,cfg.poseOneEuroDerivativeCutoff)*.55f+cfg.poseVelocityAlpha*.45f,
        .02f,.9f);st.velocity=PVector.lerp(st.velocity,rawVelocity,da);if(st.velocity.mag()>speedLimit)st.velocity.mult(speedLimit/st.velocity.mag());

      float cutoff=(cfg.poseOneEuroMinCutoff+cfg.poseOneEuroBeta*st.velocity.mag())*response;
      float a=alpha(dt,cutoff);float stateGain=j.state==SkeletonJoint3D.TRACKED?1.0f:(j.state==SkeletonJoint3D.INFERRED?.62f:(j.state==SkeletonJoint3D.OCCLUDED?.38f:.28f));
      float historyReliability=learner.reliability(j.name);float confidenceGain=lerp(.30f,1.0f,constrain(j.confidence*stateGain*lerp(.72f,1.08f,historyReliability),0,1));
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
  final SkeletonConfig cfg;final SkeletonJointMotionLearner learner;final HashMap<String,SkeletonKalmanState> states=new HashMap<String,SkeletonKalmanState>();

  SkeletonKalmanBank(SkeletonConfig c,SkeletonJointMotionLearner l){cfg=c;learner=l;}void reset(){states.clear();}
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.canonicalJoints()
    ;}
  void apply(SkeletonPose3D s,long tickMs,SkeletonCalibration3D cal){for(SkeletonJoint3D j:joints(s))filter(j,tickMs,cal);
    }
  void filter(SkeletonJoint3D j,long tickMs,SkeletonCalibration3D cal){if(j==null||!j.tracked()||j.world.z<=0)return;
    SkeletonKalmanState st=states.get(j.name);if(st==null){st=new SkeletonKalmanState();
      states.put(j.name,st);}if(!st.initialized){st.position.set(j.world);st.velocity.set(0,0,0);
      st.tickMs=tickMs;st.p00=.04f;st.p11=.20f;st.initialized=true;return;}float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f),dt2=dt*dt,dt3=dt2*dt,
    dt4=dt2*dt2,q=cfg.kalmanProcessNoise*constrain(.72f+.38f*learner.response(j.name),.55f,1.55f);PVector predicted=PVector.add(st.position,PVector.mult(st.velocity,dt));
    float p00=st.p00+dt*(st.p01+st.p10)+dt2*st.p11+q*dt4*.25f,p01=st.p01+dt*st.p11+q*dt3*.5f,p10=st.p10+dt*st.p11+q*dt3*.5f,p11=st.p11+q*dt2;
    float depthNoise=cfg.kalmanDepthNoiseScale*j.world.z*j.world.z,measurement=max(.003f,cfg.kalmanMeasurementNoiseM+depthNoise)*lerp(2.6f,.72f,constrain(j.confidence,
      0,1))*lerp(1.22f,.90f,learner.reliability(j.name));float stateNoise=j.state==SkeletonJoint3D.TRACKED?1.0f:(j.state==SkeletonJoint3D.INFERRED?1.8f:(j.state==SkeletonJoint3D.OCCLUDED?3.2f:4.5f));measurement*=stateNoise;float r=measurement*measurement,den=max(1e-7f,p00+r),k0=p00/den,k1=p10/den;
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
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.canonicalJoints()
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
    if(Float.isFinite(v))learnValue(key,v);}float measure(SkeletonJoint3D a,SkeletonJoint3D b){return a!=null&&b!=null&&a.state==2&&b.state==2&&a.confidence>=cfg.anthropologyMinConfidence&&b.confidence>=cfg.anthropologyMinConfidence?PVector.dist(a.world,
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

class SkeletonAnthropometricModel {
  final SkeletonConfig cfg;final HashMap<String,Float> lengths=new HashMap<String,Float>();final HashMap<String,Float> deviation=new HashMap<String,Float>();final HashMap<String,Integer> samples=new HashMap<String,Integer>();
  final HashMap<String,PVector> directions=new HashMap<String,PVector>();
  SkeletonAnthropometricModel(SkeletonConfig c){cfg=c;}void reset(){lengths.clear();deviation.clear();samples.clear();
    directions.clear();}
  float learned(String key,float observed){
    if(!Float.isFinite(observed)||observed<=0)return lengths.containsKey(key)?lengths.get(key):Float.NaN;
    Float old=lengths.get(key);if(old==null){lengths.put(key,observed);deviation.put(key,0.0f);samples.put(key,1);return observed;}
    int n=samples.containsKey(key)?samples.get(key):1;float dev=deviation.containsKey(key)?deviation.get(key):0;float delta=abs(observed-old)/max(old,.001f);
    // During warm-up accept normal variation; once mature, reject measurements that
    // disagree with the learned body by more than the configured relative envelope.
    float allowed=cfg.anthropologyMaxDeviation+min(.10f,dev*2.0f);if(n>=cfg.anthropologyWarmupSamples&&delta>allowed)return old;
    float bounded=constrain(observed,old*(1.0f-allowed),old*(1.0f+allowed));float a=cfg.anthropologyLearnAlpha*lerp(1.35f,.65f,constrain(n/(float)cfg.anthropologyWarmupSamples,0,1));
    float next=lerp(old,bounded,a);deviation.put(key,lerp(dev,abs(bounded-next)/max(next,.001f),a));lengths.put(key,next);samples.put(key,min(100000,n+1));return next;
  }
  float reliable(SkeletonJoint3D a,SkeletonJoint3D b){return a!=null&&b!=null&&a.state==2&&b.state==2&&a.confidence>=cfg.anthropologyMinConfidence&&b.confidence>=cfg.anthropologyMinConfidence?PVector.dist(a.world,
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
    v.div(d);PVector prior=directions.get(dirKey);boolean inferred=child.state!=SkeletonJoint3D.TRACKED;
    if(prior!=null&&inferred&&child.confidence<.72f){float dot=constrain(PVector.dot(prior,v),-1,1),angle=degrees(acos(dot));
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
  final SkeletonJointMotionLearner jointLearner;final SkeletonTemporalConsensus consensus;final SkeletonKalmanBank kalman;final SkeletonPoseFilter poseFilter;final SkeletonMotionPrior motionPrior;
  final SkeletonRootStabilizer rootFilter;final SkeletonIdentityPredictor identity;
  final SkeletonAnthropometricModel biomechanics;final SkeletonKinematicOptimizer modelOptimizer;final Body3DFusionEngine body3d;
  SkeletonPose3D previous;int identityMissFrames=0,acquireFrames=0,releaseFrames=0;
  long activeTrackingId=0,nextTrackingId=1;volatile String lastReason="searching";
  // Device timestamps may restart after USB/runtime reconnects and can occasionally
  // repeat.  Every temporal filter must see one monotonic clock or a single clock
  // discontinuity becomes a false high-velocity body motion.
  long stableTickMs=0,lastRawTickMs=0,lastHostTickMs=0;

  SkeletonTracker(SkeletonConfig c,Calibration calibration,RgbDepthRegistration registration){cfg=c;
    cal=new SkeletonCalibration3D(calibration,registration);estimator=new SkeletonDepthPersonSegmenter(c);jointLearner=new SkeletonJointMotionLearner(c);
    consensus=new SkeletonTemporalConsensus(c);kalman=new SkeletonKalmanBank(c,jointLearner);poseFilter=new SkeletonPoseFilter(c,jointLearner);motionPrior=new SkeletonMotionPrior(c,jointLearner);
    rootFilter=new SkeletonRootStabilizer(c);identity=new SkeletonIdentityPredictor(c);
    biomechanics=new SkeletonAnthropometricModel(c);modelOptimizer=new SkeletonKinematicOptimizer(c);body3d=new Body3DFusionEngine(c);
    }
  void reset(){previous=null;identityMissFrames=0;acquireFrames=0;releaseFrames=0;
    activeTrackingId=0;stableTickMs=0;lastRawTickMs=0;lastHostTickMs=0;estimator.reset();jointLearner.reset();consensus.reset();kalman.reset();poseFilter.reset();motionPrior.reset();rootFilter.reset();
    identity.reset();biomechanics.reset();modelOptimizer.reset();body3d.reset();lastReason="searching";
    }
  long stableTick(long rawTickMs){
    long host=System.nanoTime()/1000000L;
    if(stableTickMs<=0){stableTickMs=rawTickMs>0?rawTickMs:host;lastRawTickMs=rawTickMs;lastHostTickMs=host;return stableTickMs;}
    long hostDelta=constrainLong(host-lastHostTickMs,1,100);
    long rawDelta=rawTickMs>0&&lastRawTickMs>0?rawTickMs-lastRawTickMs:0;
    // 250 ms is deliberately above normal Kinect frame intervals but below a
    // reconnect/pause discontinuity.  Use host elapsed time for bad device deltas.
    long delta=(rawDelta>0&&rawDelta<=250)?rawDelta:hostDelta;
    stableTickMs+=constrainLong(delta,1,100);lastRawTickMs=rawTickMs;lastHostTickMs=host;return stableTickMs;
  }
  long constrainLong(long value,long lo,long hi){return Math.max(lo,Math.min(hi,value));}

  SkeletonPose3D track(RgbdFramePair pair){
    if(pair==null)return track((DepthFrame)null,millis64());
    long tick=Math.max(pair.rgb==null?0:pair.rgb.timestampUs/1000L,pair.depth==null?0:pair.depth.timestampUs/1000L);

    return track(pair.depth,pair.infrared,tick>0?tick:millis64());
  }
  SkeletonPose3D track(DepthFrame depthFrame,long tick){return track(depthFrame,null,tick);}
  SkeletonPose3D track(DepthFrame depthFrame,InfraredFrame infrared,long tick){
    tick=stableTick(tick);
    SkeletonPose3D s=new SkeletonPose3D();if(depthFrame==null||depthFrame.depth==null)return predictedSkeleton(s,tick,"no_rgbd");
    boolean broadSearch=identityMissFrames>=cfg.trackingReleaseFrames;PVector priorCenter=broadSearch?null:identity.predictedCenter(tick);
    float priorDepth=broadSearch?0:identity.predictedDepth(tick);SkeletonDepthBodyMask body=estimator.segment(depthFrame,priorCenter,priorDepth);
    if(body==null)return predictedSkeleton(s,tick,"no_person");
    int top=centralTop(body),bottom=body.py(body.maxGY),height=max(1,bottom-top);
    if(height<cfg.bodyMinHeightPx)return predictedSkeleton(s,tick,"no_person");if(activeTrackingId==0)activeTrackingId=nextTrackingId++;

    SkeletonPose3D fused=body3d.solve(depthFrame,infrared,body,cal,previous,tick,activeTrackingId);
    if(fused==null)return predictedSkeleton(s,tick,"body3d_unresolved");
    // Anchor solved joints back onto local metric-depth surfaces before temporal
    // filtering. This rejects RGB-independent silhouette drift and improves hand,
    // elbow, knee and foot Z stability near body edges.
    refinePoseWithMetricDepth(fused,depthFrame,body);
    return finishBody3DPose(fused,depthFrame,body,tick,top,bottom,height);
  }

  void refinePoseWithMetricDepth(SkeletonPose3D pose,DepthFrame depth,SkeletonDepthBodyMask body){
    if(pose==null||depth==null||depth.depth==null)return;
    SkeletonJoint3D[] joints=allJoints(pose);
    int radius=max(1,cfg.poseFullResolutionRefineRadiusPx),diameter=radius*2+1;
    int[] samples=new int[diameter*diameter];
    for(SkeletonJoint3D joint:joints){
      if(joint==null||!joint.tracked()||joint.image==null)continue;
      int cx=round(joint.image.x),cy=round(joint.image.y),n=0;
      int expectedMm=joint.world!=null&&joint.world.z>0?round(joint.world.z*1000.0f):0;
      for(int oy=-radius;oy<=radius;oy++)for(int ox=-radius;ox<=radius;ox++){
        if(ox*ox+oy*oy>radius*radius)continue;
        int x=cx+ox,y=cy+oy;if(x<0||y<0||x>=depth.width||y>=depth.height)continue;
        int index=y*depth.width+x,mm=depth.depth[index]&0xffff;
        if(mm==0)continue;
        if(cal.sharedCalibration!=null)mm=cal.sharedCalibration.correctedDepthMm(index,mm);
        if(mm<=0)continue;
        // Reject a second surface behind/in front of the expected articulation.
        // This is especially important at wrists, elbows, knees and silhouette edges.
        if(expectedMm>0&&abs(mm-expectedMm)>cfg.poseFullResolutionDepthToleranceMm)continue;
        // A local sample must belong to the segmented person component.
        if(body!=null){
          int gx=constrain(x/max(1,body.step),0,body.gridW-1),gy=constrain(y/max(1,body.step),0,body.gridH-1);
          if(!body.mask[gy*body.gridW+gx])continue;
        }
        samples[n++]=mm;
      }
      if(n<4)continue;
      Arrays.sort(samples,0,n);int mm=samples[n/2];
      PVector measured=cal.deproject(cx,cy,mm);
      if(measured==null)continue;
      float dz=joint.world==null?0:abs(measured.z-joint.world.z);
      if(joint.world==null||dz<=0.32f){
        if(joint.world==null)joint.world=measured;
        else{
          float depthWeight=constrain(.58f+.30f*joint.confidence,.58f,.86f);
          joint.world.x=lerp(joint.world.x,measured.x,depthWeight);
          joint.world.y=lerp(joint.world.y,measured.y,depthWeight);
          joint.world.z=lerp(joint.world.z,measured.z,depthWeight);
        }
      }
    }
  }

  void reanchorPoseToSegmentedTorso(SkeletonPose3D pose,SkeletonDepthBodyMask body){
    if(pose==null||body==null||body.samples<cfg.bodyMinSamples)return;
    int bodyRows=max(1,body.maxGY-body.minGY),bodyCols=max(1,body.maxGX-body.minGX);
    int y0=body.minGY+round(bodyRows*.28f),y1=body.minGY+round(bodyRows*.62f);
    int x0=body.minGX+round(bodyCols*.12f),x1=body.maxGX-round(bodyCols*.12f);
    PVector observed=new PVector();float weight=0;int used=0;
    for(int gy=max(body.minGY,y0);gy<=min(body.maxGY,y1);gy++)for(int gx=max(body.minGX,x0);gx<=min(body.maxGX,x1);gx++){
      int i=gy*body.gridW+gx;if(i<0||i>=body.mask.length||!body.mask[i])continue;int mm=body.mm[i];if(mm<=0)continue;
      PVector p=cal.deproject(body.px(gx),body.py(gy),mm);if(p==null)continue;float edge=body.clearance!=null&&i<body.clearance.length?constrain(body.clearance[i]/18.0f,.25f,1.0f):1.0f;
      observed.add(PVector.mult(p,edge));weight+=edge;used++;
    }
    if(used<10||weight<=0)return;observed.div(weight);
    SkeletonJoint3D[] torso={pose.shoulderCenter,pose.spine,pose.hipCenter,pose.leftShoulder,pose.rightShoulder,pose.leftHip,pose.rightHip};
    PVector solved=new PVector();float sw=0;for(SkeletonJoint3D j:torso)if(j!=null&&j.tracked()&&j.world!=null){float q=max(.12f,j.confidence);solved.add(PVector.mult(j.world,q));sw+=q;}
    if(sw<=0)return;solved.div(sw);PVector delta=PVector.sub(observed,solved);float mag=delta.mag();
    float limit=lerp(.075f,.125f,constrain(body.confidence,0,1));if(mag>limit)delta.mult(limit/max(mag,.0001f));
    float strength=lerp(.48f,.76f,constrain(body.confidence,0,1));delta.mult(strength);if(delta.mag()<.0015f)return;
    for(SkeletonJoint3D j:pose.canonicalJoints())if(j!=null&&j.tracked()&&j.world!=null){j.world.add(delta);PVector uv=cal.projectWorldRgb(j.world);if(uv!=null)j.image.set(uv);}
  }

  SkeletonPose3D finishBody3DPose(SkeletonPose3D s,DepthFrame depthFrame,SkeletonDepthBodyMask body,long tick,int top,int bottom,int height){
    augmentCanonicalTopology(s,tick);
    validateKinematics(s);
    // Learn only from the current depth-derived observation, before prediction or
    // smoothing can feed its own output back as "training" evidence.
    jointLearner.observe(s,tick);
    motionPrior.apply(s,previous,tick,cal);consensus.apply(s,tick);kalman.apply(s,tick,cal);poseFilter.apply(s,tick,cal);
    rootFilter.apply(s,tick,cal);
    // Quality-first alternating projection.  Each iteration constrains proportions,
    // then returns joints to measured depth/body-cloud evidence.  Repeating this is
    // intentionally more expensive than a single pass, but converges peripheral
    // joints without allowing the kinematic model to drift off the real surface.
    for(int pass=0;pass<cfg.qualityRefinementPasses;pass++){
      biomechanics.stabilize(s,cal);modelOptimizer.optimize(s,cal);
      refinePoseWithMetricDepth(s,depthFrame,body);
      reanchorPoseToSegmentedTorso(s,body);
      int cloudPasses=pass==cfg.qualityRefinementPasses-1?cfg.qualityCloudPasses:1;
      for(int cp=0;cp<cloudPasses;cp++){
        body3d.anchorDistalLimbsToCloud(s,previous);
        body3d.enforcePeripheralCloudSupport(s,previous);
        body3d.recomputeJointEvidenceConfidence(s,previous);
      }
      body3d.reproject(s,cal);
    }
    // A transient depth hole must not collapse an articulated chain. Keep the
    // last coherent joint as an occluded/predicted observation until either
    // current evidence returns or the bounded hold interval expires.
    preserveOccludedJoints(s,previous,tick);
    body3d.reproject(s,cal);
    clampSkeleton(s);poseFilter.commitMeasured(s,tick);

    SkeletonJoint3D[] core={s.leftShoulder,s.rightShoulder,s.shoulderCenter,s.spine,s.hipCenter};
    s.torsoConfidence=chainConfidence(core);float coreCoverage=trackedCount(core)/(float)core.length;
    float leftArmQ=chainConfidence(new SkeletonJoint3D[]{s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand}),
      rightArmQ=chainConfidence(new SkeletonJoint3D[]{s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand});
    float headTorsoQ=coverageConfidence(new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.leftShoulder,s.rightShoulder});
    s.upperBodyConfidence=constrain(.58f*headTorsoQ+.42f*max(leftArmQ,rightArmQ),0,1);
    s.interactionConfidence=constrain(.56f*s.torsoConfidence+.44f*max(leftArmQ,rightArmQ),0,1);
    s.lowerBodyConfidence=max(
      chainConfidence(new SkeletonJoint3D[]{s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot}),
      chainConfidence(new SkeletonJoint3D[]{s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot}));

    float hipY=s.hipCenter.tracked()?s.hipCenter.image.y:top+height*.55f;
    // "Measured" excludes the short occlusion-hold state. Posture must be
    // classified from current depth evidence, while held joints remain available
    // to the renderer/filters for continuity.
    boolean leftMeasured=s.leftKnee.observed()&&s.leftAnkle.observed(),rightMeasured=s.rightKnee.observed()&&s.rightAnkle.observed();
    classifyPosture(s,body,hipY,bottom,height,leftMeasured,rightMeasured);
    s.lowerBodyConfidence=max(
      chainConfidence(new SkeletonJoint3D[]{s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot}),
      chainConfidence(new SkeletonJoint3D[]{s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot}));
    float jointQ=coverageConfidence(allJoints(s));s.confidence=constrain(.36f*body.confidence+.39f*s.torsoConfidence+.25f*jointQ,0,1);

    boolean evidence=body.confidence>=cfg.trackingMinBodyConfidence*.88f&&
      s.torsoConfidence>=cfg.poseMinCoreConfidence*.90f&&coreCoverage>=cfg.trackingMinCoreCoverage*.90f;
    if(evidence){acquireFrames=min(cfg.trackingAcquireFrames+2,acquireFrames+1);releaseFrames=0;}
    else{releaseFrames++;acquireFrames=max(0,acquireFrames-1);}
    boolean wasTracked=previous!=null&&previous.tracked;
    s.tracked=evidence&&(wasTracked||acquireFrames>=max(1,cfg.trackingAcquireFrames-1));
    if(wasTracked&&!evidence&&releaseFrames<cfg.trackingReleaseFrames&&s.torsoConfidence>=cfg.poseMinCoreConfidence*.56f)s.tracked=true;
    s.reason=s.tracked?(evidence?"tracked_3d":"inferred_3d"):"acquiring_3d";lastReason=s.reason;

    if(s.tracked){
      identityMissFrames=0;deriveBounds(s);s.meanDepthM=meanDepth(s);
      float shoulderPx=s.leftShoulder.tracked()&&s.rightShoulder.tracked()?PVector.dist(s.leftShoulder.image,s.rightShoulder.image):60;
      s.faceWidthPx=constrain(shoulderPx*.36f,18,140);s.faceHeightPx=s.faceWidthPx*1.25f;
      identity.update(s,tick,cal);previous=s;
    }else if(evidence){
      identityMissFrames=0;identity.update(s,tick,cal);
    }else{
      identityMissFrames++;identity.miss();
    }
    return s;
  }

  long occlusionHoldMs(){return Math.max(250L,(long)cfg.poseOcclusionHoldFrames*34L);}
  void copyOccludedJoint(SkeletonJoint3D dst,SkeletonJoint3D src,long tick,float confidenceScale){
    if(dst==null||src==null||!src.tracked()||src.world==null||src.world.z<=0)return;
    long age=src.lastObservedMs>0?Math.max(0L,tick-src.lastObservedMs):0L;if(age>occlusionHoldMs())return;
    float seconds=min(.20f,age/1000.0f),motionDamping=exp(-age/520.0f);
    PVector predicted=PVector.add(src.world,PVector.mult(src.velocity,seconds*motionDamping));
    PVector delta=PVector.sub(predicted,src.world);if(delta.mag()>.10f)predicted=PVector.add(src.world,delta.setMag(.10f));
    PVector uv=cal.projectWorldRgb(predicted);if(uv==null)uv=cal.projectDepth(predicted);
    dst.world.set(predicted);if(uv!=null)dst.image.set(uv);dst.velocity.set(PVector.mult(src.velocity,motionDamping));
    float ageFactor=constrain(1.0f-age/(float)Math.max(1L,occlusionHoldMs()),0,1);
    dst.confidence=max(.055f,src.confidence*confidenceScale*lerp(.48f,1.0f,ageFactor));
    dst.state=SkeletonJoint3D.OCCLUDED;dst.source="occlusion-hold";dst.lastObservedMs=src.lastObservedMs;
  }
  void preserveOccludedJoints(SkeletonPose3D current,SkeletonPose3D prior,long tick){
    if(current==null||prior==null)return;SkeletonJoint3D[] now=current.canonicalJoints(),before=prior.canonicalJoints();int n=min(now.length,before.length);
    for(int i=0;i<n;i++){SkeletonJoint3D dst=now[i],src=before[i];if(src==null||!src.tracked())continue;
      if(dst!=null&&dst.tracked()){
        // Reacquisition may briefly jump to another depth surface. Low-confidence
        // measurements are blended toward the last coherent limb instead of
        // allowing a one-frame skeleton rebuild.
        float d=PVector.dist(dst.world,src.world);
        if(dst.confidence<.42f&&d>cfg.poseInnovationGateM*.72f&&d<cfg.poseInnovationGateM*2.2f){
          float blend=constrain(.30f+(d-cfg.poseInnovationGateM*.72f)/max(.01f,cfg.poseInnovationGateM)*.22f,.30f,.62f);
          dst.world.set(PVector.lerp(dst.world,src.world,blend));PVector uv=cal.projectWorldRgb(dst.world);if(uv!=null)dst.image.set(uv);
          dst.confidence=max(dst.confidence,src.confidence*.46f);
        }
        continue;
      }
      copyOccludedJoint(dst,src,tick,.90f);
    }
  }
  void seedPredictedPose(SkeletonPose3D current,SkeletonPose3D prior,long tick){
    if(current==null||prior==null)return;current.trackingId=prior.trackingId;current.poseSource=prior.poseSource;current.posture=prior.posture;
    current.postureConfidence=prior.postureConfidence;current.lowerBodyVisible=prior.lowerBodyVisible;current.clippedTop=prior.clippedTop;current.clippedBottom=prior.clippedBottom;
    SkeletonJoint3D[] now=current.canonicalJoints(),before=prior.canonicalJoints();for(int i=0;i<min(now.length,before.length);i++)copyOccludedJoint(now[i],before[i],tick,.94f);
    current.leftHandDetail.gesture=prior.leftHandDetail.gesture;current.rightHandDetail.gesture=prior.rightHandDetail.gesture;
    current.leftHandDetail.source=prior.leftHandDetail.source;current.rightHandDetail.source=prior.rightHandDetail.source;
    current.leftHandDetail.updateConfidence();current.rightHandDetail.updateConfidence();
  }

  SkeletonPose3D predictedSkeleton(SkeletonPose3D s,long tick,String reason){
    identityMissFrames++;
    identity.miss();
    acquireFrames=0;
    releaseFrames++;
    s.trackingId=activeTrackingId;
    if(identityMissFrames>cfg.poseOcclusionHoldFrames){
      previous=null;activeTrackingId=0;releaseFrames=0;
      consensus.reset();kalman.reset();poseFilter.reset();motionPrior.reset();rootFilter.reset();identity.reset();
      biomechanics.reset();modelOptimizer.reset();body3d.reset();
      s.reason=reason;lastReason=reason;return s;
    }
    // A full-body miss remains an occlusion state: preserve the last coherent
    // articulation, use only a bounded inertial prediction, then hold it with
    // decaying confidence until metric depth evidence returns.
    seedPredictedPose(s,previous,tick);
    biomechanics.stabilize(s,cal);clampSkeleton(s);
    s.torsoConfidence=chainConfidence(new SkeletonJoint3D[]{s.leftShoulder,s.rightShoulder,s.shoulderCenter,s.spine,s.hipCenter});

    float leftArmQ=chainConfidence(new SkeletonJoint3D[]{s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand}),
      rightArmQ=chainConfidence(new SkeletonJoint3D[]{s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand});
    float headTorsoQ=coverageConfidence(new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.leftShoulder,s.rightShoulder});
    s.upperBodyConfidence=constrain(.62f*headTorsoQ+.38f*max(leftArmQ,rightArmQ),0,1);
    s.interactionConfidence=constrain(.62f*s.torsoConfidence+.38f*max(leftArmQ,rightArmQ),0,1);

    s.lowerBodyConfidence=max(chainConfidence(new SkeletonJoint3D[]{s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot}),
      chainConfidence(new SkeletonJoint3D[]{s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot}));
    if(previous!=null){s.posture=previous.posture;s.postureConfidence=previous.postureConfidence*.92f;s.lowerBodyVisible=previous.lowerBodyVisible;}
    s.confidence=constrain(.82f*s.upperBodyConfidence+.18f*avgTracked(allJoints(s)),0,1);

    boolean holdEligible=previous!=null&&previous.tracked&&releaseFrames<=cfg.poseOcclusionHoldFrames;

    SkeletonJoint3D[] predictedCore={s.leftShoulder,s.rightShoulder,s.shoulderCenter,s.spine,s.hipCenter};
    float predictedCoverage=trackedCount(predictedCore)/(float)predictedCore.length;

    s.tracked=holdEligible&&s.torsoConfidence>=cfg.poseMinCoreConfidence*.55f&&predictedCoverage>=cfg.trackingMinCoreCoverage*.55f;

    s.reason=s.tracked?"inferred":reason;lastReason=s.reason;
    if(s.tracked){deriveBounds(s);s.meanDepthM=meanDepth(s);if(previous!=null){s.faceWidthPx=previous.faceWidthPx;
        s.faceHeightPx=previous.faceHeightPx;}}
    return s;
  }
  float kneeAngleDeg(SkeletonJoint3D hip,SkeletonJoint3D knee,SkeletonJoint3D ankle){
    if(hip==null||knee==null||ankle==null||!hip.tracked()||!knee.tracked()||!ankle.tracked())return Float.NaN;
    PVector a=PVector.sub(hip.world,knee.world),b=PVector.sub(ankle.world,knee.world);
    float ma=a.mag(),mb=b.mag();if(ma<.035f||mb<.035f)return Float.NaN;
    float c=constrain(a.dot(b)/(ma*mb),-1,1);return degrees(acos(c));
  }
  boolean seatedLegGeometry(SkeletonJoint3D hip,SkeletonJoint3D knee,SkeletonJoint3D ankle){
    if(hip==null||knee==null||!hip.tracked()||!knee.tracked())return false;
    if(ankle!=null&&ankle.tracked()){
      float angle=kneeAngleDeg(hip,knee,ankle);
      if(Float.isFinite(angle))return angle>=48f&&angle<=148f;
    }
    // With an occluded lower leg, accept seated evidence only when the thigh is
    // clearly projected forward/sideways rather than almost vertical.
    PVector thigh=PVector.sub(knee.world,hip.world);float vertical=abs(thigh.y),horizontal=sqrt(thigh.x*thigh.x+thigh.z*thigh.z);
    return thigh.mag()>.12f&&horizontal>max(.10f,vertical*.62f);
  }
  boolean standingLegGeometry(SkeletonJoint3D hip,SkeletonJoint3D knee,SkeletonJoint3D ankle){
    float angle=kneeAngleDeg(hip,knee,ankle);if(!Float.isFinite(angle))return false;
    PVector thigh=PVector.sub(knee.world,hip.world),shin=PVector.sub(ankle.world,knee.world);
    return angle>=154f&&thigh.y>0&&shin.y>0;
  }

  void classifyPosture(SkeletonPose3D s,SkeletonDepthBodyMask body,float hipY,float bottom,float height,boolean leftLegMeasured,boolean rightLegMeasured){
    float lowerCoverage=max(0,bottom-hipY)/max(1.0f,height);
    int measuredLegs=(leftLegMeasured?1:0)+(rightLegMeasured?1:0);
    int lowerTracked=trackedCount(new SkeletonJoint3D[]{s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot});
    float lowerJointCoverage=lowerTracked/6.0f;
    boolean bottomAtFrame=bottom>=studio.services.scannerProtocol.HEIGHT-max(4,body.step*2);
    boolean kneesPresent=s.leftKnee.tracked()||s.rightKnee.tracked();
    // Missing lower limbs are occlusion/partial-body evidence, never positive seated evidence.
    // A seated label now requires actual 3D flexion/forward-thigh geometry. This
    // prevents a standing subject with temporarily lost ankles from collapsing
    // into the old high-confidence "seated" state.
    float silhouetteLower=lowerCoverage;
    boolean leftBent=leftLegMeasured&&seatedLegGeometry(s.leftHip,s.leftKnee,s.leftAnkle);
    boolean rightBent=rightLegMeasured&&seatedLegGeometry(s.rightHip,s.rightKnee,s.rightAnkle);
    boolean leftExtended=leftLegMeasured&&standingLegGeometry(s.leftHip,s.leftKnee,s.leftAnkle);
    boolean rightExtended=rightLegMeasured&&standingLegGeometry(s.rightHip,s.rightKnee,s.rightAnkle);
    boolean standingSilhouette=silhouetteLower>=cfg.postureFullLegCoverage*.82f&&!bottomAtFrame;
    boolean standingGeometry=leftExtended||rightExtended;
    boolean priorSeated=previous!=null&&"seated".equals(previous.posture);
    boolean bentEvidence=(leftBent&&rightBent)||priorSeated&&(leftBent||rightBent)||
      (leftBent||rightBent)&&lowerCoverage<cfg.postureFullLegCoverage*.74f;
    boolean seatedGeometry=!standingSilhouette&&!standingGeometry&&measuredLegs>=1&&kneesPresent&&
      bentEvidence&&lowerCoverage>=cfg.postureSeatedLegCoverage*.82f;
    boolean full=(standingSilhouette||standingGeometry||measuredLegs>=1&&lowerCoverage>=cfg.postureFullLegCoverage)&&
      (lowerJointCoverage>=.34f||standingSilhouette||standingGeometry);

    // Posture is presentation/state metadata only. Never destroy valid joints as a
    // side effect of a one-frame posture decision; that previously fed the next
    // frame an artificially incomplete body and caused full/seated/upper oscillation.
    String priorPosture=previous==null?"":previous.posture;
    if(full){s.posture="full";s.postureConfidence=constrain(.55f*lowerCoverage+.25f*max(lowerJointCoverage,standingSilhouette?.45f:0)+.20f*max(measuredLegs/2.0f,standingSilhouette?.55f:0),0,1);s.lowerBodyVisible=true;return;}
    if(seatedGeometry){s.posture="seated";s.postureConfidence=constrain(.45f*s.torsoConfidence+.35f*max(lowerJointCoverage,.35f)+.20f*(1.0f-constrain(lowerCoverage-cfg.postureSeatedLegCoverage,0,1)),0,1);s.lowerBodyVisible=kneesPresent;return;}
    if(bottomAtFrame||lowerCoverage<cfg.postureSeatedLegCoverage||measuredLegs==0){
      if(previous!=null&&("full".equals(priorPosture)||"partial".equals(priorPosture))&&lowerJointCoverage>.28f&&!bottomAtFrame){
        s.posture="partial";s.postureConfidence=constrain(.58f*previous.postureConfidence+.42f*lowerJointCoverage,0,1);s.lowerBodyVisible=true;return;
      }
      s.posture="upper";s.postureConfidence=constrain(.65f*s.torsoConfidence+.35f*(1.0f-lowerJointCoverage),0,1);s.lowerBodyVisible=false;return;
    }
    s.posture="partial";s.postureConfidence=constrain(.55f*s.torsoConfidence+.45f*lowerJointCoverage,0,1);s.lowerBodyVisible=lowerJointCoverage>.20f;
  }

  // Populate the Kinect-v2 superset without inventing finger articulation.  These
  // points are conservative, low-confidence geometric priors until a native or
  // neural provider overwrites them.  Full 21-point hands stay empty unless they
  // are actually observed.
  void augmentCanonicalTopology(SkeletonPose3D s,long tick){
    if(s==null)return;
    if(!s.spineShoulder.tracked()&&s.shoulderCenter.tracked())copyJoint(s.spineShoulder,s.shoulderCenter,.92f,"canonical-prior",tick);
    seedHandTopology(s.leftWrist,s.leftHand,s.leftHandTip,s.leftThumb,s.leftHandDetail,tick);
    seedHandTopology(s.rightWrist,s.rightHand,s.rightHandTip,s.rightThumb,s.rightHandDetail,tick);
  }
  void copyJoint(SkeletonJoint3D dst,SkeletonJoint3D src,float qScale,String source,long tick){if(dst==null||src==null||!src.tracked())return;dst.set(src.image,src.world,src.confidence*qScale,SkeletonJoint3D.INFERRED,source,tick);}
  void seedHandTopology(SkeletonJoint3D wrist,SkeletonJoint3D hand,SkeletonJoint3D tip,SkeletonJoint3D thumb,SkeletonHand3D detail,long tick){
    if(wrist==null||hand==null||!wrist.tracked()||!hand.tracked())return;PVector axis=PVector.sub(hand.world,wrist.world);float len=axis.mag();if(len<.015f)return;axis.normalize();
    if(!tip.tracked()){PVector p=PVector.add(hand.world,PVector.mult(axis,constrain(len*.55f,.025f,.075f)));PVector uv=cal.projectWorldRgb(p);if(uv==null)uv=cal.projectDepth(p);if(uv!=null)tip.set(uv,p,min(wrist.confidence,hand.confidence)*.52f,SkeletonJoint3D.INFERRED,"canonical-prior",tick);}
    // Only seed the detailed wrist/center anchors. Individual fingers require a
    // real hand landmark provider; fabricating them harms gesture reliability.
    copyJoint(detail.landmarks[0],wrist,.82f,"body-anchor",tick);copyJoint(detail.landmarks[9],hand,.48f,"body-anchor",tick);detail.updateConfidence();
  }

  // adapters submit landmarks already registered into depth-image space here; Kinect depth remains authoritative
  // for metric Z, keeping hands in the same calibrated 3-D space as the body.
  void fuseHandLandmarksDepthSpace(SkeletonPose3D pose,SkeletonHand3D hand,float[] depthUvConfidence,DepthFrame depth,long tick){
    if(pose==null||hand==null||depthUvConfidence==null||depth==null||depth.depth==null||depthUvConfidence.length<SkeletonHand3D.LANDMARKS*3)return;
    for(int i=0;i<SkeletonHand3D.LANDMARKS;i++){float u=depthUvConfidence[i*3],v=depthUvConfidence[i*3+1],q=constrain(depthUvConfidence[i*3+2],0,1);if(q<.10f)continue;int du=round(u),dv=round(v);int mm=robustDepthMm(depth,du,dv,3);if(mm<=0)continue;PVector xyz=cal.deproject(du,dv,mm),rgb=cal.projectWorldRgb(xyz);if(rgb==null)rgb=new PVector(u,v);hand.landmarks[i].set(rgb,xyz,q,SkeletonJoint3D.TRACKED,"landmark-provider",tick);}
    hand.updateConfidence();
  }
  int robustDepthMm(DepthFrame d,int u,int v,int radius){if(d==null||d.depth==null||d.width<=0||d.height<=0)return 0;int[] values=new int[(radius*2+1)*(radius*2+1)];int n=0;for(int y=max(0,v-radius);y<=min(d.height-1,v+radius);y++)for(int x=max(0,u-radius);x<=min(d.width-1,u+radius);x++){int mm=d.depth[y*d.width+x]&0xffff;if(mm>=cfg.minDepthMm&&mm<=cfg.maxDepthMm)values[n++]=mm;}if(n==0)return 0;Arrays.sort(values,0,n);return values[n/2];}
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
  void clampSkeleton(SkeletonPose3D s){for(SkeletonJoint3D j:allJoints(s))if(j!=null&&j.tracked()){j.image.x=constrain(j.image.x,0,studio.services.scannerProtocol.WIDTH-1);
      j.image.y=constrain(j.image.y,0,studio.services.scannerProtocol.HEIGHT-1);}}
  SkeletonJoint3D[] allJoints(SkeletonPose3D s){return s.canonicalJoints();}
  int trackedCount(SkeletonJoint3D[] js){int n=0;for(SkeletonJoint3D j:js)if(j!=null&&j.tracked())n++;
    return n;}
  float coverageConfidence(SkeletonJoint3D[] js){
    if(js==null||js.length==0)return 0;float sum=0;int tracked=0;
    for(SkeletonJoint3D j:js)if(j!=null&&j.tracked()){sum+=j.confidence;tracked++;}
    float avgAll=sum/js.length,coverage=tracked/(float)js.length;
    return constrain(avgAll*(.72f+.28f*coverage),0,1);
  }
  float chainConfidence(SkeletonJoint3D[] js){
    if(js==null||js.length==0)return 0;float sum=0,weakest=1;int tracked=0;
    for(SkeletonJoint3D j:js){
      float q=(j!=null&&j.tracked())?constrain(j.confidence,0,1):0;
      sum+=q;weakest=min(weakest,q);if(q>0)tracked++;
    }
    float avg=sum/js.length,coverage=tracked/(float)js.length;
    return constrain(.62f*avg+.23f*weakest+.15f*coverage*avg,0,1);
  }

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

