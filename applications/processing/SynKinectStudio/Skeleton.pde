// ===== SynKinect Studio / Shared Skeleton Library =====
//
// SynSkeleton is the reusable body-tracking layer used by Studio modules. Sensor
// transport stays outside the tracker: callers provide calibrated metric Depth and
// receive an immutable pose/body-cloud snapshot. SynSkeleton.onnx is the single
// authoritative pose source; canonical Remold anchors are derived from its current
// landmarks, and a light observed-only temporal filter reduces jitter.
class SkeletonConfig {
  String trackingMode="rgb";
  String rgbModelPath="data/skeleton/movenet.onnx";
  String depthModelPath="data/skeleton/SynSkeleton.onnx";
  int minDepthMm=550,maxDepthMm=3800;
  float poseMinCoreConfidence=0.30f,trackingMinCoreCoverage=0.55f,trackingMinBodyConfidence=0.28f;

  int poseOcclusionHoldFrames=12,trackingAcquireFrames=2,trackingReleaseFrames=15;

  float poseFilterMinAlpha=0.16f,poseFilterMaxAlpha=0.92f,poseVelocityAlpha=0.30f,poseMaxSpeedMps=5.5f,poseMaxAccelerationMps2=30.0f;

  float poseOneEuroMinCutoff=1.35f,poseOneEuroBeta=1.75f,poseOneEuroDerivativeCutoff=1.25f;
  // Quality-first refinement intentionally spends additional CPU cycling the pose
  // between metric depth evidence and the articulated model.  This is shared by
  // Windows and Linux so tracking behavior remains platform-independent.
  int qualityRefinementPasses=2,qualityCloudPasses=2;


  float poseInnovationGateM=0.20f,poseJitterRadiusM=0.006f,poseBoneLearnAlpha=0.055f,poseBoneCorrection=0.72f,poseMaxDirectionJumpDeg=76.0f;
  // Depth continuity is evaluated independently from the 2D silhouette. It prevents
  // crossing limbs/background surfaces from stealing a joint merely because their
  // image-space location is close to the expected landmark.
  float poseDepthTemporalGateM=0.34f,poseDepthTemporalWeight=0.72f;
  int poseFullResolutionRefineRadiusPx=6,poseFullResolutionDepthToleranceMm=120;
  int consensusWindow=5;float consensusMadScale=2.8f,consensusMinRadiusM=0.012f,consensusMaxBlend=0.58f;

  float rootMinCutoff=0.72f,rootBeta=0.34f,rootDerivativeCutoff=1.0f,rootMaxCorrectionM=0.055f;

  float identityVelocityAlpha=0.28f,identityMaxPredictionPx=90.0f,identityMaxPredictionM=0.28f;

  float kalmanProcessNoise=0.52f,kalmanMeasurementNoiseM=0.012f,kalmanDepthNoiseScale=0.0045f,kalmanVelocityDamping=0.975f,kalmanPredictionMs=8.0f;
  float motionPriorVelocityAlpha=0.30f,motionPriorLowConfidence=0.46f,motionPriorBlend=0.22f,motionPriorRootBlend=0.58f,motionPriorMaxPredictionM=0.045f;

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
  int bodySampleStep=3,bodyDepthBinMm=80,bodyDepthBandMm=360,bodyDepthHypotheses=6,bodyContinuityMm=180,bodyForwardReachMm=1100;float bodyAttachMaxFraction=0.40f;int bodyMinSamples=90,bodyMinHeightPx=80,bodyHistogramCapSamples=1600,
  bodyBridgeCells=1,bodyRobustDepthRadiusPx=2;
  // Floor plane removal (as NiTE / Kinect SDK): the floor is connected to the
  // feet in depth and would otherwise merge the person with the whole floor.
  // Articulated model-based solver (ArticulatedBody.pde). "legacy" keeps the old Body3D path.
  String solverMode="articulated";
  int articulatedMaxPoints=2600,articulatedTemplateMaxPoints=700,articulatedTorsoIterations=8,articulatedTemplateRefreshFrames=20,articulatedLimbIterations=3,articulatedMinLimbPoints=8;
  float articulatedGeodesicCellM=0.05f,articulatedGeodesicLinkM=0.05f,articulatedTorsoBiasM=0.012f,articulatedAssignGateM=0.07f,articulatedExtremumWeight=3.0f;
  int articulatedGravityPriorDivisor=12;boolean articulatedGenerative=true;float articulatedRefineMaxTurnRad=0.30f;int articulatedPairMaxPoints=320;float articulatedFreeSpaceWeight=0.6f,articulatedReseedMargin=0.10f,articulatedStatureTopOffsetM=0.008f,articulatedGeodesicJumpPenaltyM=0.45f,articulatedGeodesicMaxJumpM=0.45f;float articulatedFilterMinCutoff=1.4f,articulatedFilterBeta=0.9f,articulatedFilterDerivativeCutoff=1.0f;
  boolean floorEnabled=true;float floorClearanceM=0.035f,floorInlierM=0.018f,floorMaxTiltDeg=25.0f,floorMinDepthSpreadM=0.22f;int floorRefreshFrames=15;
  float bodyMaxWidthRatio=0.98f,bodyCenterBias=0.0f,bodyMinAspect=0.65f,bodyMinRowCoverage=0.58f,bodyMinFillRatio=0.055f,bodyTemporalRejectScale=0.68f,
  bodyHumanShapeWeight=0.52f,bodyTemporalMaskWeight=0.70f,bodyEdgeContactPenalty=0.0f,bodyIdentitySwitchMinAffinity=0.055f;
  int bodyIdentitySwitchGraceMisses=3;
  float postureFullLegCoverage=0.62f,postureSeatedLegCoverage=0.28f,postureLowerHoldConfidence=0.34f;
  // Near-field hands/fingers are an optional refinement layer. Body-level hand
  // joints remain authoritative and can be tracked even when no finger is visible.
  boolean handDetailEnabled=true;
  float handDetailMaxDepthM=2.05f,handDetailRadiusM=.125f,handDetailReferenceDistanceM=1.10f;
  int handDetailDepthBandMm=90,handDetailMinSamples=24;
  float handDetailTipMinRadius=.46f,handDetailTipProminence=.024f,handDetailTemporalMatchM=.070f,handDetailNewTipConfidence=.46f;
  // Fine-hand tracking owns its own temporal/kinematic model.  Body filters do not
  // learn from inferred finger landmarks, so a noisy fingertip can never stretch
  // the body skeleton or teach an impossible segment length.
  float handDetailTemporalAlpha=.74f,handDetailMaxTipStepM=.085f,handDetailLengthTolerance=.28f,handDetailPalmScaleMinM=.040f,handDetailPalmScaleMaxM=.145f;
  int handDetailHoldFrames=3;
  float anthropologyHardDeviation=.085f;
  int presentationCloudSampleStep=2;
  float presentationCloudArmReserveM=1.02f,presentationCloudVerticalReserveM=1.18f,presentationCloudDepthReserveM=0.62f,presentationCloudTrackedSupportM=0.078f;
  boolean usesRgb(){return "rgb".equals(trackingMode);}
  void load(File file){
    ConfigRules r=studio.services.configRules;Properties p=r.load(file,"skeleton");
    String selected=p.getProperty("tracking.mode",trackingMode).trim().toLowerCase(java.util.Locale.ROOT);
    if(!selected.equals("rgb")&&!selected.equals("depth"))throw new IllegalArgumentException("tracking.mode must be rgb or depth");
    trackingMode=selected;
    rgbModelPath=p.getProperty("tracking.rgbModel",rgbModelPath).trim();
    depthModelPath=p.getProperty("tracking.depthModel",depthModelPath).trim();
    if(rgbModelPath.isEmpty()||depthModelPath.isEmpty())throw new IllegalArgumentException("Tracking model paths cannot be empty");


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
    bodyAttachMaxFraction=r.decimal(p,"body.attachMaxFraction",bodyAttachMaxFraction,0,1);
    bodyForwardReachMm=r.integer(p,"body.forwardReachMm",bodyForwardReachMm,0,2000);
    floorEnabled=r.flag(p,"floor.enabled",floorEnabled);floorClearanceM=r.decimal(p,"floor.clearanceM",floorClearanceM,0.005f,0.20f);
    floorInlierM=r.decimal(p,"floor.inlierM",floorInlierM,0.004f,0.08f);floorMaxTiltDeg=r.decimal(p,"floor.maxTiltDeg",floorMaxTiltDeg,3.0f,60.0f);
    floorRefreshFrames=r.integer(p,"floor.refreshFrames",floorRefreshFrames,1,600);
    floorMinDepthSpreadM=r.decimal(p,"floor.minDepthSpreadM",floorMinDepthSpreadM,0,2);
    solverMode=r.text(p,"solver.mode",solverMode).toLowerCase(Locale.ROOT);
    articulatedMaxPoints=r.integer(p,"articulated.maxPoints",articulatedMaxPoints,300,12000);
    articulatedTemplateMaxPoints=r.integer(p,"articulated.templateMaxPoints",articulatedTemplateMaxPoints,100,4000);
    articulatedTorsoIterations=r.integer(p,"articulated.torsoIterations",articulatedTorsoIterations,1,30);
    articulatedTemplateRefreshFrames=r.integer(p,"articulated.templateRefreshFrames",articulatedTemplateRefreshFrames,1,600);
    articulatedLimbIterations=r.integer(p,"articulated.limbIterations",articulatedLimbIterations,1,10);
    articulatedMinLimbPoints=r.integer(p,"articulated.minLimbPoints",articulatedMinLimbPoints,2,200);
    articulatedGeodesicCellM=r.decimal(p,"articulated.geodesicCellM",articulatedGeodesicCellM,0.015f,0.15f);
    articulatedGeodesicLinkM=r.decimal(p,"articulated.geodesicLinkM",articulatedGeodesicLinkM,0.01f,0.30f);
    articulatedTorsoBiasM=r.decimal(p,"articulated.torsoBiasM",articulatedTorsoBiasM,-0.05f,0.08f);
    articulatedAssignGateM=r.decimal(p,"articulated.assignGateM",articulatedAssignGateM,0.02f,0.30f);
    articulatedExtremumWeight=r.decimal(p,"articulated.extremumWeight",articulatedExtremumWeight,0,20);
    articulatedGeodesicJumpPenaltyM=r.decimal(p,"articulated.geodesicJumpPenaltyM",articulatedGeodesicJumpPenaltyM,0,3);
    articulatedGeodesicMaxJumpM=r.decimal(p,"articulated.geodesicMaxJumpM",articulatedGeodesicMaxJumpM,0.05f,2);
    articulatedRefineMaxTurnRad=r.decimal(p,"articulated.refineMaxTurnRad",articulatedRefineMaxTurnRad,0.02f,3.2f);
    articulatedGenerative=r.flag(p,"articulated.generative",articulatedGenerative);
    articulatedPairMaxPoints=r.integer(p,"articulated.pairMaxPoints",articulatedPairMaxPoints,50,5000);
    articulatedFreeSpaceWeight=r.decimal(p,"articulated.freeSpaceWeight",articulatedFreeSpaceWeight,0,10);
    articulatedReseedMargin=r.decimal(p,"articulated.reseedMargin",articulatedReseedMargin,-1,2);
    articulatedStatureTopOffsetM=r.decimal(p,"articulated.statureTopOffsetM",articulatedStatureTopOffsetM,0,0.12f);
    articulatedGravityPriorDivisor=r.integer(p,"articulated.gravityPriorDivisor",articulatedGravityPriorDivisor,2,1000);
    articulatedFilterMinCutoff=r.decimal(p,"articulated.filterMinCutoff",articulatedFilterMinCutoff,0.05f,20);
    articulatedFilterBeta=r.decimal(p,"articulated.filterBeta",articulatedFilterBeta,0,20);
    articulatedFilterDerivativeCutoff=r.decimal(p,"articulated.filterDerivativeCutoff",articulatedFilterDerivativeCutoff,0.1f,20);
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
    handDetailEnabled=r.flag(p,"handsFingers.enabled",handDetailEnabled);
    handDetailMaxDepthM=r.decimal(p,"handsFingers.maxDepthM",handDetailMaxDepthM,.55f,3.0f);
    handDetailRadiusM=r.decimal(p,"handsFingers.radiusM",handDetailRadiusM,.05f,.22f);
    handDetailReferenceDistanceM=r.decimal(p,"handsFingers.referenceDistanceM",handDetailReferenceDistanceM,.60f,2.50f);
    handDetailDepthBandMm=r.integer(p,"handsFingers.depthBandMm",handDetailDepthBandMm,40,300);
    handDetailMinSamples=r.integer(p,"handsFingers.minSamples",handDetailMinSamples,12,1200);
    handDetailTipMinRadius=r.decimal(p,"handsFingers.tipMinRadius",handDetailTipMinRadius,.30f,.90f);
    handDetailTipProminence=r.decimal(p,"handsFingers.tipProminence",handDetailTipProminence,.005f,.20f);
    handDetailTemporalMatchM=r.decimal(p,"handsFingers.temporalMatchM",handDetailTemporalMatchM,.025f,.20f);
    handDetailNewTipConfidence=r.decimal(p,"handsFingers.newTipConfidence",handDetailNewTipConfidence,.10f,.85f);
    handDetailTemporalAlpha=r.decimal(p,"handsFingers.temporalAlpha",handDetailTemporalAlpha,.10f,.95f);
    handDetailMaxTipStepM=r.decimal(p,"handsFingers.maxTipStepM",handDetailMaxTipStepM,.015f,.25f);
    handDetailLengthTolerance=r.decimal(p,"handsFingers.lengthTolerance",handDetailLengthTolerance,.08f,.55f);
    handDetailPalmScaleMinM=r.decimal(p,"handsFingers.palmScaleMinM",handDetailPalmScaleMinM,.025f,.10f);
    handDetailPalmScaleMaxM=r.decimal(p,"handsFingers.palmScaleMaxM",handDetailPalmScaleMaxM,handDetailPalmScaleMinM+.01f,.22f);
    handDetailHoldFrames=r.integer(p,"handsFingers.holdFrames",handDetailHoldFrames,0,24);
    anthropologyHardDeviation=r.decimal(p,"anthropometry.hardDeviation",anthropologyHardDeviation,.03f,.25f);
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
  // The configured ONNX backend is shared by all body-tracking modules.
  // RGB uses synchronized RGB-D; depth uses metric depth alone.
  SkeletonProcessingSession createSession(Calibration calibration,RgbDepthRegistration registration,KinectSource source){return new SkeletonProcessingSession(configuration(),calibration,registration,source);}
}

class SkeletonModuleFrame {
  final SkeletonPose3D pose;final PointCloud bodyCloud;final long frameNumber;
  SkeletonModuleFrame(SkeletonPose3D pose,PointCloud cloud,long frameNumber){this.pose=pose;this.bodyCloud=cloud;this.frameNumber=frameNumber;}
}

class SkeletonProcessingSession {
  final SkeletonConfig cfg;final SynSkeletonOnnxTracker model;final SkeletonCalibration3D cal;final SkeletonFloorModel floor;
  SkeletonProcessingSession(SkeletonConfig cfg,Calibration calibration,RgbDepthRegistration registration,KinectSource source){this.cfg=cfg;cal=new SkeletonCalibration3D(calibration,registration);model=new SynSkeletonOnnxTracker(cfg,calibration,registration,source);floor=new SkeletonFloorModel(cfg);}
  void reset(){model.reset();floor.reset();}
  SkeletonFloorModel floorModel(){return floor;}
  String statusReason(){return model==null?"synskeleton_model_missing":model.status();}
  SkeletonModuleFrame process(DepthFrame depth,InfraredFrame infrared,long tick){return process(depth,infrared,null,tick);}
  SkeletonModuleFrame process(DepthFrame depth,InfraredFrame infrared,RawRgbFrame rgb,long tick){
    if(depth==null||depth.depth==null)return new SkeletonModuleFrame(new SkeletonPose3D(),new PointCloud(1),-1);
    floor.update(depth,cal);SkeletonPose3D pose=cfg.usesRgb()?model.trackRgb(depth,rgb,tick):model.track(depth,tick);if(pose!=null)pose.updateOrientations();
    return new SkeletonModuleFrame(pose,bodyCloud(depth,pose),depth.frameNumber);
  }
  // The 3D cloud is selected around the current neural skeleton. It is presentation
  // evidence only and never feeds a second pose solver.
  PointCloud bodyCloud(DepthFrame frame,SkeletonPose3D pose){
    PointCloud cloud=new PointCloud(22000);if(frame==null||frame.depth==null||pose==null||!pose.tracked||cal==null)return cloud;
    int step=max(1,cfg.presentationCloudSampleStep),w=frame.width,h=frame.height;
    for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){int idx=y*w+x;if(idx<0||idx>=frame.depth.length)continue;int mm=frame.depth[idx]&0xffff;
      if(mm>0&&cal.sharedCalibration!=null)mm=cal.sharedCalibration.correctedDepthMm(idx,mm);if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm)continue;
      PVector q=cal.deproject(x,y,mm);if(q==null||!bodyCloudSupport(q,pose))continue;cloud.add(q,0xff58c7f3,bodyCloudConfidence(q,pose));
    }return cloud;
  }
  float segmentDistance(PVector p,PVector a,PVector b){if(p==null||a==null||b==null)return Float.POSITIVE_INFINITY;PVector ab=PVector.sub(b,a);float d=ab.magSq();if(d<1e-8f)return PVector.dist(p,a);float t=constrain(PVector.sub(p,a).dot(ab)/d,0,1);return PVector.dist(p,PVector.add(a,PVector.mult(ab,t)));}
  float jointDistance(PVector p,SkeletonJoint3D j){return j!=null&&j.tracked()?PVector.dist(p,j.world):Float.POSITIVE_INFINITY;}
  float boneDistance(PVector p,SkeletonJoint3D a,SkeletonJoint3D b){return a!=null&&b!=null&&a.tracked()&&b.tracked()?segmentDistance(p,a.world,b.world):Float.POSITIVE_INFINITY;}
  float supportDistance(PVector p,SkeletonPose3D s){float d=Float.POSITIVE_INFINITY;if(p==null||s==null)return d;d=min(d,jointDistance(p,s.head)-.13f);d=min(d,boneDistance(p,s.head,s.shoulderCenter)-.105f);d=min(d,boneDistance(p,s.shoulderCenter,s.spine)-.17f);d=min(d,boneDistance(p,s.spine,s.hipCenter)-.19f);d=min(d,boneDistance(p,s.leftShoulder,s.rightShoulder)-.13f);d=min(d,boneDistance(p,s.leftHip,s.rightHip)-.14f);SkeletonJoint3D[][] bones={{s.leftShoulder,s.leftElbow},{s.leftElbow,s.leftWrist},{s.leftWrist,s.leftHand},{s.rightShoulder,s.rightElbow},{s.rightElbow,s.rightWrist},{s.rightWrist,s.rightHand},{s.leftHip,s.leftKnee},{s.leftKnee,s.leftAnkle},{s.leftAnkle,s.leftFoot},{s.rightHip,s.rightKnee},{s.rightKnee,s.rightAnkle},{s.rightAnkle,s.rightFoot}};for(SkeletonJoint3D[] b:bones)d=min(d,boneDistance(p,b[0],b[1])-.095f);return d;}
  boolean bodyCloudSupport(PVector p,SkeletonPose3D s){float d=supportDistance(p,s);if(d<=cfg.presentationCloudTrackedSupportM)return true;SkeletonJoint3D root=s.spine!=null&&s.spine.tracked()?s.spine:s.hipCenter;if(root==null||!root.tracked())return false;float dz=abs(p.z-s.meanDepthM);if(dz>cfg.presentationCloudDepthReserveM)return false;float armReach=constrain(cfg.presentationCloudArmReserveM*.82f,.58f,.90f);float left=s.leftShoulder!=null&&s.leftShoulder.tracked()?PVector.dist(p,s.leftShoulder.world):Float.POSITIVE_INFINITY,right=s.rightShoulder!=null&&s.rightShoulder.tracked()?PVector.dist(p,s.rightShoulder.world):Float.POSITIVE_INFINITY;float shoulderReach=min(left,right),hipY=s.hipCenter!=null&&s.hipCenter.tracked()?s.hipCenter.world.y:root.world.y+.42f;boolean armDiscovery=shoulderReach<=armReach&&p.y<=hipY+.18f;float dx=abs(p.x-root.world.x),shoulderY=s.shoulderCenter!=null&&s.shoulderCenter.tracked()?s.shoulderCenter.world.y:root.world.y-.28f;boolean coreDiscovery=dx<=.34f&&p.y>=shoulderY-.22f&&p.y<=hipY+.16f&&dz<=cfg.presentationCloudDepthReserveM*.62f;return armDiscovery||coreDiscovery;}
  float bodyCloudConfidence(PVector p,SkeletonPose3D s){float d=max(0,supportDistance(p,s));if(d<=cfg.presentationCloudTrackedSupportM)return constrain(1.0f-d/max(.001f,cfg.presentationCloudTrackedSupportM),.34f,1.0f);SkeletonJoint3D root=s.spine!=null&&s.spine.tracked()?s.spine:s.hipCenter;if(root==null||!root.tracked())return .16f;float depth=abs(p.z-s.meanDepthM)/max(.1f,cfg.presentationCloudDepthReserveM);return constrain(.46f-.14f*depth,.16f,.46f);}
}

class SkeletonHistorySample {final PVector world;final float confidence;final long tickMs;
  SkeletonHistorySample(PVector w,float q,long t){world=w.copy();confidence=q;tickMs=t;
    }}
class SkeletonTemporalConsensus {
  final SkeletonConfig cfg;final HashMap<String,ArrayDeque<SkeletonHistorySample>> history=new HashMap<String,ArrayDeque<SkeletonHistorySample>>();

  SkeletonTemporalConsensus(SkeletonConfig c){cfg=c;}void reset(){history.clear();
    }
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.bodyJoints();}
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
  final SkeletonConfig cfg;final HashMap<String,SkeletonAdaptiveJointState> states=new HashMap<String,SkeletonAdaptiveJointState>();final HashMap<String,Float> priorActivity=new HashMap<String,Float>(),priorReliability=new HashMap<String,Float>();
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
  void observe(SkeletonPose3D pose,long now){}
  void observe(SkeletonJoint3D j,long now){}
  float maturity(String name){return 1.0f;}
  float reliability(String name){return .78f;}
  float learnedActivity(String name){return 0.0f;}
  float response(String name){return baseMobility(name);}
  float speedLimit(String name){return constrain(cfg.poseMaxSpeedMps*baseMobility(name),cfg.poseMaxSpeedMps*.48f,cfg.poseMaxSpeedMps*1.55f);}
  float accelerationLimit(String name){return constrain(cfg.poseMaxAccelerationMps2*baseMobility(name),cfg.poseMaxAccelerationMps2*.48f,cfg.poseMaxAccelerationMps2*1.65f);}
  float jitterScale(String name){return baseJitter(name);}
  float predictionScale(String name){return constrain(.68f+.28f*baseMobility(name),.72f,1.16f);}
}

class SkeletonMotionState {
  PVector position=new PVector(),velocity=new PVector();long tickMs=0;boolean initialized=false;
}
class SkeletonMotionPrior {
  final SkeletonConfig cfg;final SkeletonJointMotionLearner learner;final HashMap<String,SkeletonMotionState> states=new HashMap<String,SkeletonMotionState>();
  SkeletonMotionPrior(SkeletonConfig c,SkeletonJointMotionLearner l){cfg=c;learner=l;}
  void reset(){states.clear();}
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.bodyJoints();}
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

class JointQuaternion {
  float x=0,y=0,z=0,w=1,confidence=0;
  JointQuaternion set(float qx,float qy,float qz,float qw,float qc){x=qx;y=qy;z=qz;w=qw;confidence=constrain(qc,0,1);normalize();return this;}
  void identity(){x=0;y=0;z=0;w=1;confidence=0;}
  void normalize(){float n=sqrt(x*x+y*y+z*z+w*w);if(n<1e-7f){x=0;y=0;z=0;w=1;return;}x/=n;y/=n;z/=n;w/=n;}
  JointQuaternion fromTo(PVector from,PVector to,float confidence){
    JointQuaternion q=new JointQuaternion();if(from==null||to==null||from.magSq()<1e-8f||to.magSq()<1e-8f)return q;
    PVector a=from.copy().normalize(),b=to.copy().normalize();float d=constrain(a.dot(b),-1,1);
    if(d<-0.9999f){PVector axis=abs(a.x)<.8f?a.cross(new PVector(1,0,0)):a.cross(new PVector(0,1,0));if(axis.magSq()<1e-8f)axis=new PVector(0,0,1);axis.normalize();return q.set(axis.x,axis.y,axis.z,0,confidence);}
    PVector c=a.cross(b);return q.set(c.x,c.y,c.z,1.0f+d,confidence);
  }
}

class SkeletonJoint3D {
  static final int LOST=0,INFERRED=1,TRACKED=2,PREDICTED=3,OCCLUDED=4;
  final String name;PVector image=new PVector(),world=new PVector(),velocity=new PVector();final JointQuaternion orientation=new JointQuaternion();float confidence=0;
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
  // Palm is intentionally separate from the 21 finger topology. This means a hand
  // can be identified and used by Interactivity even when no individual finger
  // landmark is available.
  final SkeletonJoint3D palm;
  float confidence=0;String gesture="unknown",source="none";boolean visible=false;int fingerCount=0;
  SkeletonHand3D(String s){side=s;palm=new SkeletonJoint3D(side+"_palm");String[] n={"wrist","thumb_cmc","thumb_mcp","thumb_ip","thumb_tip","index_mcp","index_pip","index_dip","index_tip","middle_mcp","middle_pip","middle_dip","middle_tip","ring_mcp","ring_pip","ring_dip","ring_tip","pinky_mcp","pinky_pip","pinky_dip","pinky_tip"};for(int i=0;i<LANDMARKS;i++)landmarks[i]=new SkeletonJoint3D(side+"_"+n[i]);}
  SkeletonJoint3D wrist(){return landmarks[0];}SkeletonJoint3D thumbTip(){return landmarks[4];}SkeletonJoint3D indexTip(){return landmarks[8];}
  SkeletonJoint3D middleTip(){return landmarks[12];}SkeletonJoint3D ringTip(){return landmarks[16];}SkeletonJoint3D pinkyTip(){return landmarks[20];}
  boolean handTracked(){return palm.tracked()||wrist().tracked();}
  boolean fingersTracked(){return fingerCount>0;}
  boolean detailedTracked(){return handTracked()&&fingerCount>=2;}
  void updateConfidence(){int[] tips={4,8,12,16,20};float anchor=0;int an=0;if(wrist().tracked()){anchor+=wrist().confidence;an++;}if(palm.tracked()){anchor+=palm.confidence;an++;}anchor=an==0?0:anchor/an;float tipSum=0;fingerCount=0;for(int i:tips)if(landmarks[i].tracked()&&landmarks[i].confidence>=.34f){tipSum+=landmarks[i].confidence;fingerCount++;}float tipQ=fingerCount==0?0:tipSum/fingerCount;confidence=constrain(fingerCount==0?anchor*.94f:.68f*anchor+.32f*tipQ,0,1);visible=handTracked();}
}

class SkeletonPose3D {
  boolean tracked=false;long trackingId=0;float confidence=0,torsoConfidence=0,upperBodyConfidence=0,interactionConfidence=0;
  String reason="searching",posture="unknown";int minX,minY,maxX,maxY;float meanDepthM=0,faceWidthPx=0,faceHeightPx=0,postureConfidence=0;
  boolean lowerBodyVisible=false;

  boolean clippedTop=false,clippedBottom=false;
  // Remold body topology keeps explicit shoulder-center and hip-center anchors.
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
  SkeletonJoint3D[] kinectV2_25(){return new SkeletonJoint3D[]{spine,spineShoulder,shoulderCenter,head,leftShoulder,leftElbow,leftWrist,leftHand,rightShoulder,rightElbow,rightWrist,rightHand,leftHip,leftKnee,leftAnkle,leftFoot,rightHip,rightKnee,rightAnkle,rightFoot,hipCenter,leftHandTip,leftThumb,rightHandTip,rightThumb};}
  SkeletonJoint3D[] bodyJoints(){return kinectV2_25();}
  SkeletonJoint3D[] canonicalJoints(){ArrayList<SkeletonJoint3D> out=new ArrayList<SkeletonJoint3D>();Collections.addAll(out,bodyJoints());out.add(leftHandDetail.palm);out.add(rightHandDetail.palm);Collections.addAll(out,leftHandDetail.landmarks);Collections.addAll(out,rightHandDetail.landmarks);return out.toArray(new SkeletonJoint3D[out.size()]);}
  void orientBone(SkeletonJoint3D parent,SkeletonJoint3D child){
    if(parent==null||child==null||!parent.tracked()||!child.tracked()){if(parent!=null)parent.orientation.identity();return;}
    PVector d=PVector.sub(child.world,parent.world);float c=min(parent.confidence,child.confidence);JointQuaternion q=parent.orientation.fromTo(new PVector(0,1,0),d,c);parent.orientation.set(q.x,q.y,q.z,q.w,c);
  }
  void updateOrientations(){
    for(SkeletonJoint3D j:canonicalJoints())if(j!=null)j.orientation.identity();
    orientBone(hipCenter,spine);orientBone(spine,shoulderCenter);orientBone(shoulderCenter,head);
    orientBone(shoulderCenter,leftShoulder);orientBone(leftShoulder,leftElbow);orientBone(leftElbow,leftWrist);orientBone(leftWrist,leftHand);
    orientBone(shoulderCenter,rightShoulder);orientBone(rightShoulder,rightElbow);orientBone(rightElbow,rightWrist);orientBone(rightWrist,rightHand);
    orientBone(hipCenter,leftHip);orientBone(leftHip,leftKnee);orientBone(leftKnee,leftAnkle);orientBone(leftAnkle,leftFoot);
    orientBone(hipCenter,rightHip);orientBone(rightHip,rightKnee);orientBone(rightKnee,rightAnkle);orientBone(rightAnkle,rightFoot);
    orientBone(spineShoulder,leftShoulder);orientBone(spineShoulder,rightShoulder);orientBone(leftHand,leftHandTip);orientBone(rightHand,rightHandTip);
    orientHand(leftHandDetail);orientHand(rightHandDetail);
  }
  void orientHand(SkeletonHand3D h){if(h==null)return;int[][] bones={{0,1},{1,2},{2,3},{3,4},{0,5},{5,6},{6,7},{7,8},{0,9},{9,10},{10,11},{11,12},{0,13},{13,14},{14,15},{15,16},{0,17},{17,18},{18,19},{19,20}};for(int[] b:bones)orientBone(h.landmarks[b[0]],h.landmarks[b[1]]);}
}
class SkeletonCalibration3D {
  final Calibration sharedCalibration;final RgbDepthRegistration sharedRegistration;

  SkeletonCalibration3D(Calibration cal,RgbDepthRegistration reg){sharedCalibration=cal;
    sharedRegistration=reg;}
  // Pixel index uses the device's actual depth frame size (640x480 on Kinect 360, 512x424 on Kinect One).
  int pixelIndex(int u,int v){int w=max(1,sharedCalibration.depthWidth),h=max(1,sharedCalibration.depthHeight);return constrain(v,0,h-1)*w+constrain(u,0,w-1);}
  PVector deproject(int u,int v,int mm){int i=pixelIndex(u,v);float z=mm*sharedCalibration.depthScale;
    return new PVector(sharedRegistration.pointX(i,z),sharedRegistration.pointY(i,z),z);
    }
  PVector projectRgb(int u,int v,int mm){int i=pixelIndex(u,v);float z=mm*sharedCalibration.depthScale;
    RgbProjection q=new RgbProjection();sharedRegistration.project(i,z,q,0,0);return q.valid?new PVector(q.u,q.v):null;
    }
  // Exact inverse of deproject: forward Brown-Conrady distortion, then intrinsics and the
  // same pixel-centre/shift convention used to build the undistorted ray table.
  PVector projectDepth(PVector world){if(world==null||world.z<=0.001f)return null;float[] uv=new float[2];
    return sharedCalibration.projectToPixel(world.x,world.y,world.z,uv)?new PVector(uv[0],uv[1]):null;
    }
  PVector projectWorldRgb(PVector world){PVector d=projectDepth(world);if(d==null)return null;
    int mm=round(world.z/max(1e-9f,sharedCalibration.depthScale));return projectRgb(round(d.x),round(d.y),mm);
    }
}

// SynSkeleton segments the metric-depth person component used by the native Body3D solver.
// Pose joints are solved volumetrically in calibrated 3D and then refined by temporal and
// anthropometric constraints; no silhouette/geodesic pose solver remains.
// The body solver publishes the current Remold metric joint model directly.
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

// Floor plane in camera coordinates: n.p + d, positive above the floor (the
// camera side). Estimated by gravity-guided RANSAC on a sparse depth grid and
// refreshed periodically; the sensor may be moved or tilted between sessions.
class SkeletonFloorModel {
  final SkeletonConfig cfg;final Random random=new Random(0xF100F);
  boolean valid=false;float nx,ny,nz,d;int framesSinceEstimate=1<<20,inliers=0;
  int gravityMisses=0;
  PVector up=null; // accelerometer "up" in camera coordinates, also when no floor is visible
  SkeletonFloorModel(SkeletonConfig c){cfg=c;}
  PVector upVector(){return valid?new PVector(nx,ny,nz):(up!=null?up.copy():null);}
  void reset(){valid=false;framesSinceEstimate=1<<20;}
  float height(PVector p){return nx*p.x+ny*p.y+nz*p.z+d;}
  // With a reliable accelerometer the floor normal is gravity; the offset is the
  // lowest well-populated height mode (a histogram along gravity, 1 cm bins). This
  // is immune to feet, furniture and wall bases that bias a plane fit upward.
  boolean estimateFromGravity(PVector g,float[] xs,float[] ys,float[] zs,int n){
    float ux=-g.x,uy=-g.y,uz=-g.z;if(uy>0){ux=-ux;uy=-uy;uz=-uz;} // up in camera coordinates (camera Y points down)
    // camera Y is down, so "up" has negative Y. Accelerometer reports the reaction to gravity (up) or gravity itself depending on the driver: normalise.
    float bin=.01f,minH=-3.0f;int bins=300;float[] hist=new float[bins];
    for(int i=0;i<n;i++){float h=ux*xs[i]+uy*ys[i]+uz*zs[i];int b=(int)((h-minH)/bin);if(b<0||b>=bins)continue;hist[b]+=1;}
    float total=0,maxc=0;for(float c:hist){total+=c;maxc=max(maxc,c);}
    float need=max(40,n*.035f);int peak=-1;
    // floor = lowest bin (smoothed over 3 bins) that holds a significant population
    for(int b=1;b<bins-1;b++){float c=hist[b-1]+hist[b]+hist[b+1];if(c>=need&&c>=hist[b]*1.0f){ // walk to the local maximum
        int k=b;while(k+1<bins-1&&hist[k]+hist[k+1]+hist[k+2]>hist[k-1]+hist[k]+hist[k+1])k++;peak=k;break;}}
    if(peak<0)return false;
    float centre=minH+(peak+.5f)*bin;
    for(int pass=0;pass<3;pass++){double sum=0;int k=0;float band=pass==0?.04f:.025f;
      for(int i=0;i<n;i++){float h=ux*xs[i]+uy*ys[i]+uz*zs[i];if(abs(h-centre)<=band+.002f*zs[i]*zs[i]){sum+=h;k++;}}
      if(k<20)return false;centre=(float)(sum/k);}
    // A floor is an extended horizontal surface: its points spread along the viewing
    // direction. A horizontal slice of a body, a table edge or the bottom of a wall
    // does not, so without a visible floor no plane is reported.
    {float fx=0,fz=1;float h0=ux*0+uy*0+uz*1;fx=0-ux*h0;float fy=0-uy*h0;fz=1-uz*h0;float fm=sqrt(fx*fx+fy*fy+fz*fz);fx/=fm;fy/=fm;fz/=fm;
      double m1=0,m2=0;int k=0;for(int i=0;i<n;i++){float h=ux*xs[i]+uy*ys[i]+uz*zs[i];if(abs(h-centre)>.03f+.002f*zs[i]*zs[i])continue;double f=fx*xs[i]+fy*ys[i]+fz*zs[i];m1+=f;m2+=f*f;k++;}
      if(k<20)return false;double var=m2/k-(m1/k)*(m1/k);if(Math.sqrt(Math.max(0,var))<cfg.floorMinDepthSpreadM)return false;}
    // plane: height(p) = up.p - centre  (positive above the floor)
    float bd=-centre;if(bd<.2f||bd>2.8f)return false;
    if(valid&&abs(d-bd)<.05f){d=lerp(d,bd,.35f);}else d=bd;
    nx=ux;ny=uy;nz=uz;inliers=(int)(hist[peak]);valid=true;return true;
  }
  void update(DepthFrame depth,SkeletonCalibration3D cal){
    if(!cfg.floorEnabled||depth==null||cal==null)return;
    if(++framesSinceEstimate<(valid?cfg.floorRefreshFrames:5))return;
    framesSinceEstimate=0;
    int w=depth.width,h=depth.height,step=8,cap=(w/step+1)*(h/step+1);
    float[] xs=new float[cap],ys=new float[cap],zs=new float[cap];int n=0;
    for(int v=step/2;v<h;v+=step)for(int u=step/2;u<w;u+=step){int mm=depth.depth[v*w+u]&0xffff;if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm+1500)continue;
      PVector q=cal.deproject(u,v,mm);if(q==null)continue;xs[n]=q.x;ys[n]=q.y;zs[n]=q.z;n++;}
    if(n<120)return;
    PVector g=depth.motion!=null&&depth.motion.gravityReliable()?depth.motion.gravityUnit():null;
    if(g!=null){up=g.copy();if(up.y>0)up.mult(-1);}
    // With gravity the histogram estimator is authoritative: no floor found means no
    // floor visible (close-range/upper-body use), never a RANSAC plane on the body.
    if(g!=null){if(estimateFromGravity(g,xs,ys,zs,n))gravityMisses=0;else if(++gravityMisses>=3)valid=false;return;}
    float minVertical=cos(radians(g!=null?cfg.floorMaxTiltDeg:max(40,cfg.floorMaxTiltDeg)));
    int best=0;float bx=0,by=0,bz=0,bd=0;
    for(int it=0;it<140;it++){
      int a=random.nextInt(n),b=random.nextInt(n),c=random.nextInt(n);if(a==b||b==c||a==c)continue;
      float ux=xs[b]-xs[a],uy=ys[b]-ys[a],uz=zs[b]-zs[a],vx=xs[c]-xs[a],vy=ys[c]-ys[a],vz=zs[c]-zs[a];
      float cx=uy*vz-uz*vy,cy=uz*vx-ux*vz,cz=ux*vy-uy*vx,m=sqrt(cx*cx+cy*cy+cz*cz);if(m<1e-6f)continue;cx/=m;cy/=m;cz/=m;
      float vert=g!=null?abs(cx*g.x+cy*g.y+cz*g.z):abs(cy);if(vert<minVertical)continue;
      float dd=-(cx*xs[a]+cy*ys[a]+cz*zs[a]);if(dd<0){cx=-cx;cy=-cy;cz=-cz;dd=-dd;}
      // The camera is above the floor: normal points toward the camera (up) and the
      // plane lies below the optical centre (camera Y points down).
      if(cy>-0.35f||dd<0.20f||dd>2.8f)continue;
      int count=0;for(int i=0;i<n;i++){float tol=cfg.floorInlierM+0.004f*zs[i]*zs[i];if(abs(cx*xs[i]+cy*ys[i]+cz*zs[i]+dd)<=tol)count++;}
      if(count>best){best=count;bx=cx;by=cy;bz=cz;bd=dd;}
    }
    if(best<max(60,n*0.04f)){if(framesSinceEstimate==0&&!valid)return;return;}
    // Total-least-squares refit (normal and offset) on the inliers, twice with a
    // tightening band: three-point RANSAC normals are too noisy for joint heights.
    for(int pass=0;pass<2;pass++){
      double mx=0,my=0,mz=0;int k=0;float scale=pass==0?1.0f:.6f;
      for(int i=0;i<n;i++){float tol=(cfg.floorInlierM+0.004f*zs[i]*zs[i])*scale;if(abs(bx*xs[i]+by*ys[i]+bz*zs[i]+bd)<=tol){mx+=xs[i];my+=ys[i];mz+=zs[i];k++;}}
      if(k<30)break;mx/=k;my/=k;mz/=k;double[] C=new double[9];
      for(int i=0;i<n;i++){float tol=(cfg.floorInlierM+0.004f*zs[i]*zs[i])*scale;if(abs(bx*xs[i]+by*ys[i]+bz*zs[i]+bd)>tol)continue;double dx=xs[i]-mx,dy=ys[i]-my,dz=zs[i]-mz,wz=1.0/(zs[i]*zs[i]);
        C[0]+=wz*dx*dx;C[1]+=wz*dx*dy;C[2]+=wz*dx*dz;C[4]+=wz*dy*dy;C[5]+=wz*dy*dz;C[8]+=wz*dz*dz;}
      C[3]=C[1];C[6]=C[2];C[7]=C[5];double tr=C[0]+C[4]+C[8];
      // smallest eigenvector of C = dominant eigenvector of (tr*I - C)
      double qx=bx,qy=by,qz=bz;for(int it=0;it<40;it++){double rx=tr*qx-(C[0]*qx+C[1]*qy+C[2]*qz),ry=tr*qy-(C[3]*qx+C[4]*qy+C[5]*qz),rz=tr*qz-(C[6]*qx+C[7]*qy+C[8]*qz);
        double m=Math.sqrt(rx*rx+ry*ry+rz*rz);if(m<1e-12)break;qx=rx/m;qy=ry/m;qz=rz/m;}
      if(qx*bx+qy*by+qz*bz<0){qx=-qx;qy=-qy;qz=-qz;}
      // With a reliable accelerometer the floor normal IS gravity (to ~1 deg); a far
      // floor seen at grazing angles is much less accurate, so only the offset is fitted.
      if(g!=null){double sgn=(g.x*qx+g.y*qy+g.z*qz)<0?-1:1;qx=g.x*sgn;qy=g.y*sgn;qz=g.z*sgn;}
      bx=(float)qx;by=(float)qy;bz=(float)qz;bd=(float)-(qx*mx+qy*my+qz*mz);
    }
    if(valid){float dot=nx*bx+ny*by+nz*bz;if(dot>cos(radians(4))&&abs(d-bd)<0.05f){nx=lerp(nx,bx,.35f);ny=lerp(ny,by,.35f);nz=lerp(nz,bz,.35f);float m=sqrt(nx*nx+ny*ny+nz*nz);nx/=m;ny/=m;nz/=m;d=lerp(d,bd,.35f);inliers=best;return;}}
    nx=bx;ny=by;nz=bz;d=bd;inliers=best;valid=true;
  }
}

class SkeletonDepthPersonSegmenter {
  final SkeletonConfig cfg;final int[] robustSamples=new int[5];
  SkeletonCalibration3D cal;final SkeletonFloorModel floor;long growNs=0,floorNs=0;
  boolean[] previousMask=null;int previousGridW=0,previousGridH=0,segmentationMisses=0;
  SkeletonDepthPersonSegmenter(SkeletonConfig c){cfg=c;floor=new SkeletonFloorModel(c);}
  void reset(){previousMask=null;previousGridW=0;previousGridH=0;segmentationMisses=0;}
  SkeletonDepthBodyMask segment(DepthFrame depth,PVector priorCenter,float priorDepthM){
    int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT,step=max(2,cfg.bodySampleStep);

    if(depth==null||depth.depth==null||depth.depth.length<w*h)return null;
    SkeletonDepthBodyMask out=new SkeletonDepthBodyMask(w,h,step,depth);
    long floorT0=System.nanoTime();floor.update(depth,cal);floorNs+=System.nanoTime()-floorT0;boolean removeFloor=cfg.floorEnabled&&floor.valid&&cal!=null;
    int bins=max(1,(cfg.maxDepthMm-cfg.minDepthMm+cfg.bodyDepthBinMm-1)/cfg.bodyDepthBinMm);
    int[] hist=new int[bins],central=new int[bins];
    for(int gy=0;gy<out.gridH;gy++)for(int gx=0;gx<out.gridW;gx++){
      int x=out.px(gx),y=out.py(gy),mm=robustDepth(depth,x,y,w,h),idx=gy*out.gridW+gx;
      // Floor samples are not person candidates (they would weld the feet to the
      // whole floor). Stored as invalid so every later stage ignores them.
      if(removeFloor&&mm>0){PVector q=cal.deproject(x,y,mm);if(q!=null&&floor.height(q)<cfg.floorClearanceM)mm=0;}
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

      // Shape gates are for acquisition. A component that continues the tracked
      // person (large overlap with the previous mask) stays accepted even when the
      // pose breaks them: T-pose at close range spans the whole image width.
      float continuity=temporalOverlap/(float)max(1,count);
      boolean continuing=priorCenter!=null&&previousMask!=null&&continuity>=.45f&&count>=cfg.bodyMinSamples;
      if(continuing||(count>=cfg.bodyMinSamples&&bh>=cfg.bodyMinHeightPx&&widthRatio<=cfg.bodyMaxWidthRatio&&aspect>=cfg.bodyMinAspect&&rowCoverage>=cfg.bodyMinRowCoverage&&fillRatio>=cfg.bodyMinFillRatio)){

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
    long growT0=System.nanoTime();bestCount+=growForwardLimbs(out,bestDepthMm);growNs+=System.nanoTime()-growT0;
    previousMask=Arrays.copyOf(out.mask,out.mask.length);previousGridW=out.gridW;previousGridH=out.gridH;
    out.samples=bestCount;out.seedDepthMm=bestDepthMm;computeClearance(out);
    int bh=(out.maxGY-out.minGY+1)*step,bw=(out.maxGX-out.minGX+1)*step;float sizeScore=constrain(bestCount/(float)max(cfg.bodyMinSamples*4,1),0,1),shape=constrain((bh/(float)max(1,
      bw)-cfg.bodyMinAspect)/1.4f+.45f,.25f,1);out.confidence=constrain(.38f+.40f*sizeScore+.22f*shape,0,1);
    return out;
  }
  // The depth-band candidates cover the torso depth +-band, and continuity breaks at
  // strongly foreshortened limbs (a knee raised toward the sensor, an arm pointing at
  // it: grazing-angle dropouts and large depth steps). Attach every depth-continuous
  // blob that lies IN FRONT of the chosen body, touches its silhouette and is limb-sized.
  int growForwardLimbs(SkeletonDepthBodyMask out,int bodyDepthMm){
    if(bodyDepthMm<=0)return 0;int n=out.mask.length,added=0,bodyCount=0;for(boolean m:out.mask)if(m)bodyCount++;
    int nearLimit=bodyDepthMm-cfg.bodyForwardReachMm,farLimit=bodyDepthMm+120;
    int[] lab=new int[n];Arrays.fill(lab,-1);int[] queue=new int[n];int comp=0;
    for(int seed=0;seed<n;seed++){if(out.mask[seed]||lab[seed]>=0)continue;int sd=out.mm[seed];if(sd<cfg.minDepthMm||sd<nearLimit||sd>farLimit)continue;
      int qh=0,qt=0;queue[qt++]=seed;lab[seed]=comp;boolean touches=false;int minGX=out.gridW,maxGX=-1,minGY=out.gridH,maxGY=-1;
      while(qh<qt){int at=queue[qh++],gx=at%out.gridW,gy=at/out.gridW,dm=out.mm[at];minGX=min(minGX,gx);maxGX=max(maxGX,gx);minGY=min(minGY,gy);maxGY=max(maxGY,gy);
        for(int oy=-2;oy<=2;oy++)for(int ox=-2;ox<=2;ox++){if(ox==0&&oy==0)continue;int nx=gx+ox,ny=gy+oy;if(nx<0||ny<0||nx>=out.gridW||ny>=out.gridH)continue;int ni=ny*out.gridW+nx;
          // contact with the body silhouette where this blob is in front of (or level with) it
          if(out.mask[ni]){if(dm<=out.mm[ni]+60)touches=true;continue;}
          if(abs(ox)>1||abs(oy)>1)continue;if(lab[ni]>=0)continue;int nd=out.mm[ni];if(nd<cfg.minDepthMm||nd<nearLimit||nd>farLimit)continue;
          if(abs(nd-dm)>cfg.bodyContinuityMm)continue;lab[ni]=comp;queue[qt++]=ni;}}
      int size=qt;boolean limbSized=size<=bodyCount*cfg.bodyAttachMaxFraction&&(maxGX-minGX+1)*out.step<=out.width*.45f;
      if(touches&&limbSized&&size>=3){for(int i=0;i<qt;i++){int at=queue[i];out.mask[at]=true;int gx=at%out.gridW,gy=at/out.gridW;
          out.minGX=min(out.minGX,gx);out.maxGX=max(out.maxGX,gx);out.minGY=min(out.minGY,gy);out.maxGY=max(out.maxGY,gy);}added+=qt;}
      comp++;}
    return added;
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
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.bodyJoints();}
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
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.bodyJoints();}
  void apply(SkeletonPose3D s,long tickMs,SkeletonCalibration3D cal){for(SkeletonJoint3D j:joints(s))filter(j,tickMs,cal);
    }
  void filter(SkeletonJoint3D j,long tickMs,SkeletonCalibration3D cal){if(j==null||!j.tracked()||j.world.z<=0)return;
    SkeletonKalmanState st=states.get(j.name);if(st==null){st=new SkeletonKalmanState();
      states.put(j.name,st);}if(!st.initialized){st.position.set(j.world);st.velocity.set(0,0,0);
      st.tickMs=tickMs;st.p00=.04f;st.p11=.20f;st.initialized=true;return;}float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f),dt2=dt*dt,dt3=dt2*dt,
    dt4=dt2*dt2,q=cfg.kalmanProcessNoise*jointProcessScale(j.name)*constrain(.68f+.52f*learner.response(j.name),.52f,1.90f);PVector predicted=PVector.add(st.position,PVector.mult(st.velocity,dt));
    float p00=st.p00+dt*(st.p01+st.p10)+dt2*st.p11+q*dt4*.25f,p01=st.p01+dt*st.p11+q*dt3*.5f,p10=st.p10+dt*st.p11+q*dt3*.5f,p11=st.p11+q*dt2;
    float depthNoise=cfg.kalmanDepthNoiseScale*j.world.z*j.world.z,measurement=max(.003f,cfg.kalmanMeasurementNoiseM+depthNoise)*lerp(2.6f,.72f,constrain(j.confidence,
      0,1))*lerp(1.22f,.90f,learner.reliability(j.name))*jointMeasurementScale(j.name);float stateNoise=j.state==SkeletonJoint3D.TRACKED?1.0f:(j.state==SkeletonJoint3D.INFERRED?1.8f:(j.state==SkeletonJoint3D.OCCLUDED?3.2f:4.5f));measurement*=stateNoise;float r=measurement*measurement,den=max(1e-7f,p00+r),k0=p00/den,k1=p10/den;
    PVector innovation=PVector.sub(j.world,predicted);st.position.set(PVector.add(predicted,PVector.mult(innovation,k0)));
    st.velocity.set(PVector.add(st.velocity,PVector.mult(innovation,k1)));st.velocity.mult(cfg.kalmanVelocityDamping);
    st.p00=max(1e-7f,(1-k0)*p00);st.p01=(1-k0)*p01;st.p10=p10-k1*p00;st.p11=max(1e-7f,p11-k1*p01);
    st.tickMs=tickMs;float predictionMs=(j.state==SkeletonJoint3D.TRACKED&&j.confidence>=.62f)?0.0f:cfg.kalmanPredictionMs;
    PVector published=PVector.add(st.position,PVector.mult(st.velocity,predictionMs/1000.0f));
    j.world.set(published);PVector uv=cal.projectWorldRgb(j.world);if(uv!=null)j.image.set(uv);
    }
  float jointProcessScale(String name){if(name==null)return 1.0f;String n=name.toLowerCase(Locale.ROOT);if(n.contains("hand")||n.contains("wrist")||n.contains("foot")||n.contains("ankle"))return 1.70f;if(n.contains("elbow")||n.contains("knee"))return 1.38f;if(n.contains("head"))return 1.12f;if(n.contains("spine")||n.contains("hip_center")||n.contains("shoulder_center"))return .72f;return 1.0f;}
  float jointMeasurementScale(String name){if(name==null)return 1.0f;String n=name.toLowerCase(Locale.ROOT);if(n.contains("hand")||n.contains("wrist")||n.contains("foot")||n.contains("ankle"))return .72f;if(n.contains("elbow")||n.contains("knee"))return .82f;if(n.contains("spine")||n.contains("hip_center")||n.contains("shoulder_center"))return 1.18f;return 1.0f;}
}

class SkeletonKinematicOptimizer {
  final SkeletonConfig cfg;final HashMap<String,Float> lengths=new HashMap<String,Float>();final HashMap<String,Integer> lengthSamples=new HashMap<String,Integer>();final HashMap<String,ArrayDeque<Float>> seedSamples=new HashMap<String,ArrayDeque<Float>>();

  SkeletonKinematicOptimizer(SkeletonConfig c){cfg=c;}void reset(){lengths.clear();lengthSamples.clear();seedSamples.clear();
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
  SkeletonJoint3D[] joints(SkeletonPose3D s){return s.bodyJoints();}
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
    Float old=lengths.get(key);if(old==null){ArrayDeque<Float> q=seedSamples.get(key);if(q==null){q=new ArrayDeque<Float>();seedSamples.put(key,q);}q.addLast(observed);while(q.size()>9)q.removeFirst();if(q.size()<5)return;float[] a=new float[q.size()];int k=0;for(Float v:q)a[k++]=v;Arrays.sort(a);float seed=a[a.length/2];lengths.put(key,seed);lengthSamples.put(key,5);return;}int n=lengthSamples.containsKey(key)?lengthSamples.get(key):5;float delta=abs(observed-old)/max(old,.001f);if(n>=cfg.anthropologyWarmupSamples&&delta>cfg.anthropologyMaxDeviation)return;float bounded=constrain(observed,old*(1.0f-cfg.anthropologyMaxDeviation),old*(1.0f+cfg.anthropologyMaxDeviation));
    lengths.put(key,lerp(old,bounded,min(cfg.modelLearnAlpha,cfg.anthropologyLearnAlpha)));lengthSamples.put(key,min(100000,n+1));}
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
  final HashMap<String,PVector> directions=new HashMap<String,PVector>();final HashMap<String,ArrayDeque<Float>> warmup=new HashMap<String,ArrayDeque<Float>>();
  SkeletonAnthropometricModel(SkeletonConfig c){cfg=c;}void reset(){lengths.clear();deviation.clear();samples.clear();warmup.clear();
    directions.clear();}
  float warmMedian(String key,float observed){ArrayDeque<Float> q=warmup.get(key);if(q==null){q=new ArrayDeque<Float>();warmup.put(key,q);}q.addLast(observed);while(q.size()>max(7,min(15,cfg.anthropologyWarmupSamples)))q.removeFirst();if(q.size()<5)return Float.NaN;float[] a=new float[q.size()];int i=0;for(Float v:q)a[i++]=v;Arrays.sort(a);return a[a.length/2];}
  float learned(String key,float observed){
    if(!Float.isFinite(observed)||observed<=0)return lengths.containsKey(key)?lengths.get(key):Float.NaN;
    Float old=lengths.get(key);if(old==null){float seed=warmMedian(key,observed);if(!Float.isFinite(seed))return Float.NaN;lengths.put(key,seed);deviation.put(key,0.0f);samples.put(key,5);return seed;}
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
    float headStem=pairLength("head_stem",s.shoulderCenter,s.head),upperTorso=pairLength("upper_torso",s.shoulderCenter,s.spine),lowerTorso=pairLength("lower_torso",s.spine,s.hipCenter);
    float shoulderHalf=symmetric("shoulder_half",s.shoulderCenter,s.leftShoulder,s.shoulderCenter,s.rightShoulder),hipHalf=symmetric("hip_half",s.hipCenter,s.leftHip,s.hipCenter,s.rightHip);

    correctPair(s.leftShoulder,s.rightShoulder,shoulderWidth,cal);correctPair(s.leftHip,s.rightHip,hipWidth,cal);
    correct(s.shoulderCenter,s.head,"head_stem",headStem,cal);correct(s.shoulderCenter,s.spine,"upper_torso",upperTorso,cal);correct(s.spine,s.hipCenter,"lower_torso",lowerTorso,cal);
    correct(s.shoulderCenter,s.leftShoulder,"lshoulder_half",shoulderHalf,cal);correct(s.shoulderCenter,s.rightShoulder,"rshoulder_half",shoulderHalf,cal);
    correct(s.hipCenter,s.leftHip,"lhip_half",hipHalf,cal);correct(s.hipCenter,s.rightHip,"rhip_half",hipHalf,cal);

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
  void hardStabilize(SkeletonPose3D s,SkeletonCalibration3D cal){
    // Final publication guard: depth evidence may move a distal joint after the
    // iterative model pass, but a published bone may never grow/shrink without
    // bound relative to the robust subject-specific anthropometric model.
    hardBone(s.leftShoulder,s.leftElbow,lengths.get("upper_arm"),cal);hardBone(s.rightShoulder,s.rightElbow,lengths.get("upper_arm"),cal);
    hardBone(s.leftElbow,s.leftWrist,lengths.get("forearm"),cal);hardBone(s.rightElbow,s.rightWrist,lengths.get("forearm"),cal);
    hardBone(s.leftWrist,s.leftHand,lengths.get("hand"),cal);hardBone(s.rightWrist,s.rightHand,lengths.get("hand"),cal);
    hardBone(s.leftHip,s.leftKnee,lengths.get("thigh"),cal);hardBone(s.rightHip,s.rightKnee,lengths.get("thigh"),cal);
    hardBone(s.leftKnee,s.leftAnkle,lengths.get("shin"),cal);hardBone(s.rightKnee,s.rightAnkle,lengths.get("shin"),cal);
    hardBone(s.shoulderCenter,s.head,lengths.get("head_stem"),cal);hardBone(s.shoulderCenter,s.spine,lengths.get("upper_torso"),cal);hardBone(s.spine,s.hipCenter,lengths.get("lower_torso"),cal);
    hardBone(s.shoulderCenter,s.leftShoulder,lengths.get("shoulder_half"),cal);hardBone(s.shoulderCenter,s.rightShoulder,lengths.get("shoulder_half"),cal);
    hardBone(s.hipCenter,s.leftHip,lengths.get("hip_half"),cal);hardBone(s.hipCenter,s.rightHip,lengths.get("hip_half"),cal);
    hardPair(s.leftShoulder,s.rightShoulder,lengths.get("shoulder_width"),cal);hardPair(s.leftHip,s.rightHip,lengths.get("hip_width"),cal);
  }
  void hardBone(SkeletonJoint3D parent,SkeletonJoint3D child,Float targetObj,SkeletonCalibration3D cal){if(parent==null||child==null||!parent.tracked()||!child.tracked()||targetObj==null)return;float target=targetObj;if(target<.025f)return;PVector d=PVector.sub(child.world,parent.world);float len=d.mag();if(len<.001f)return;float lo=target*(1.0f-cfg.anthropologyHardDeviation),hi=target*(1.0f+cfg.anthropologyHardDeviation);if(len>=lo&&len<=hi)return;d.div(len);float bounded=constrain(len,lo,hi);PVector desired=PVector.add(parent.world,PVector.mult(d,bounded));float strength=child.state==SkeletonJoint3D.TRACKED?.72f:.94f;child.world.set(PVector.lerp(child.world,desired,strength));child.confidence*=.96f;PVector uv=cal.projectWorldRgb(child.world);if(uv!=null)child.image.set(uv);}
  void hardPair(SkeletonJoint3D a,SkeletonJoint3D b,Float targetObj,SkeletonCalibration3D cal){if(a==null||b==null||!a.tracked()||!b.tracked()||targetObj==null)return;float target=targetObj;if(target<.04f)return;PVector v=PVector.sub(b.world,a.world);float len=v.mag();if(len<.001f)return;float lo=target*(1.0f-cfg.anthropologyHardDeviation),hi=target*(1.0f+cfg.anthropologyHardDeviation);if(len>=lo&&len<=hi)return;v.div(len);float bounded=constrain(len,lo,hi);PVector mid=PVector.add(a.world,b.world).mult(.5f),half=PVector.mult(v,bounded*.5f);a.world.set(PVector.lerp(a.world,PVector.sub(mid,half),.68f));b.world.set(PVector.lerp(b.world,PVector.add(mid,half),.68f));PVector ua=cal.projectWorldRgb(a.world),ub=cal.projectWorldRgb(b.world);if(ua!=null)a.image.set(ua);if(ub!=null)b.image.set(ub);}
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

class SkeletonHandKinematicStabilizer {
  final SkeletonConfig cfg;final float[] fingerRatio={.82f,1.22f,1.34f,1.27f,1.08f};final int[] ratioSamples={0,0,0,0,0};
  SkeletonHandKinematicStabilizer(SkeletonConfig c){cfg=c;}void reset(){}
  float learnedFingerRatio(int i){return i<0||i>=5?1.0f:fingerRatio[i];}
  void stabilize(SkeletonPose3D pose,SkeletonPose3D prior,SkeletonCalibration3D cal,long tick){if(pose==null)return;stabilizeHand(pose.leftHandDetail,prior==null?null:prior.leftHandDetail,pose.leftWrist,pose.leftHand,cal,tick);stabilizeHand(pose.rightHandDetail,prior==null?null:prior.rightHandDetail,pose.rightWrist,pose.rightHand,cal,tick);}
  void stabilizeHand(SkeletonHand3D h,SkeletonHand3D prior,SkeletonJoint3D bodyWrist,SkeletonJoint3D bodyHand,SkeletonCalibration3D cal,long tick){if(h==null)return;
    // Body wrist/palm are hard anchors. Fine hand tracking is never allowed to pull
    // the body solution away from its metric-depth evidence.
    if(bodyWrist!=null&&bodyWrist.tracked())copyAnchor(h.landmarks[0],bodyWrist,.92f,"body-wrist",cal,tick);
    if(bodyHand!=null&&bodyHand.tracked())copyAnchor(h.palm,bodyHand,.95f,"body-palm",cal,tick);
    if(!h.palm.tracked()||!h.wrist().tracked()){h.updateConfidence();return;}
    float palmScale=constrain(PVector.dist(h.wrist().world,h.palm.world),cfg.handDetailPalmScaleMinM,cfg.handDetailPalmScaleMaxM);
    int[] bases={1,5,9,13,17},tips={4,8,12,16,20};
    for(int f=0;f<5;f++)stabilizeFinger(h,prior,bases[f],tips[f],palmScale,f,cal,tick);
    h.updateConfidence();
  }
  void copyAnchor(SkeletonJoint3D dst,SkeletonJoint3D src,float q,String source,SkeletonCalibration3D cal,long tick){dst.world.set(src.world);dst.image.set(src.image);dst.velocity.set(src.velocity);dst.confidence=constrain(src.confidence*q,0,1);dst.state=src.state;dst.source=source;dst.lastObservedMs=src.lastObservedMs>0?src.lastObservedMs:tick;}
  void stabilizeFinger(SkeletonHand3D h,SkeletonHand3D prior,int base,int tipIndex,float palmScale,int fingerIndex,SkeletonCalibration3D cal,long tick){SkeletonJoint3D tip=h.landmarks[tipIndex],old=prior==null?null:prior.landmarks[tipIndex];float nominal=palmScale*fingerRatio[fingerIndex];
    if(!tip.tracked()){if(old!=null&&old.tracked()&&prior!=null&&prior.palm.tracked()&&old.lastObservedMs>0&&tick-old.lastObservedMs<=cfg.handDetailHoldFrames*34L){PVector delta=PVector.sub(h.palm.world,prior.palm.world);PVector held=PVector.add(old.world,delta);setChain(h,base,held,old.confidence*.72f,SkeletonJoint3D.OCCLUDED,"finger-hold",cal,tick);}return;}
    PVector v=PVector.sub(tip.world,h.palm.world);float len=v.mag();if(len<.008f){tip.state=SkeletonJoint3D.LOST;tip.confidence=0;return;}v.div(len);float lo=nominal*(1.0f-cfg.handDetailLengthTolerance),hi=nominal*(1.0f+cfg.handDetailLengthTolerance);float bounded=constrain(len,lo,hi);PVector measured=PVector.add(h.palm.world,PVector.mult(v,bounded));float correction=abs(len-bounded)/max(nominal,.001f);
    if(old!=null&&old.tracked()&&prior!=null&&prior.palm.tracked()){PVector oldRelative=PVector.sub(old.world,prior.palm.world),predicted=PVector.add(h.palm.world,oldRelative);PVector jump=PVector.sub(measured,predicted);if(jump.mag()>cfg.handDetailMaxTipStepM)measured=PVector.add(predicted,jump.setMag(cfg.handDetailMaxTipStepM));measured=PVector.lerp(predicted,measured,cfg.handDetailTemporalAlpha);}
    float q=tip.confidence*constrain(1.0f-correction*.75f,.45f,1.0f);setChain(h,base,measured,q,SkeletonJoint3D.TRACKED,"hand-kinematic",cal,tick);
  }
  void setChain(SkeletonHand3D h,int base,PVector tip,float q,int tipState,String source,SkeletonCalibration3D cal,long tick){PVector palm=h.palm.world;float[] t={.30f,.55f,.78f,1.0f};for(int k=0;k<4;k++){SkeletonJoint3D j=h.landmarks[base+k];PVector xyz=PVector.lerp(palm,tip,t[k]);PVector uv=cal.projectWorldRgb(xyz);if(uv==null)uv=cal.projectDepth(xyz);if(uv==null)continue;j.world.set(xyz);j.image.set(uv);j.confidence=constrain(q*(k==3?1.0f:.82f),0,1);j.state=k==3?tipState:SkeletonJoint3D.INFERRED;j.source=source;j.lastObservedMs=tick;}}
}

class SkeletonTracker {
  static final int LIMB_ARM=1,LIMB_LEG=2;
  final SkeletonConfig cfg;final SkeletonCalibration3D cal;final SkeletonDepthPersonSegmenter estimator;
  final SkeletonJointMotionLearner jointLearner;final SkeletonTemporalConsensus consensus;final SkeletonKalmanBank kalman;final SkeletonPoseFilter poseFilter;final SkeletonMotionPrior motionPrior;
  final SkeletonRootStabilizer rootFilter;final SkeletonIdentityPredictor identity;
  final SkeletonAnthropometricModel biomechanics;final SkeletonKinematicOptimizer modelOptimizer;final SkeletonHandKinematicStabilizer handKinematics;Body3DFusionEngine body3d; // legacy solver helpers, created on first use
  final ArticulatedBodySolver articulated;final ArticulatedJointFilter articulatedFilter;
  // The presentation cloud is sourced from the exact person component selected by
  // the tracker, never reconstructed from the already-solved skeleton. This breaks
  // a harmful feedback loop where one bad limb could make background geometry look
  // like part of the tracked body.
  SkeletonDepthBodyMask lastBodyMask=null;long segmentNs=0,solveNs=0,finishNs=0;int profFrames=0;
  SkeletonPose3D previous;int identityMissFrames=0,acquireFrames=0,releaseFrames=0;
  long activeTrackingId=0,nextTrackingId=1;volatile String lastReason="searching";
  // Device timestamps may restart after USB/runtime reconnects and can occasionally
  // repeat.  Every temporal filter must see one monotonic clock or a single clock
  // discontinuity becomes a false high-velocity body motion.
  long stableTickMs=0,lastRawTickMs=0,lastHostTickMs=0;

  SkeletonTracker(SkeletonConfig c,Calibration calibration,RgbDepthRegistration registration){cfg=c;
    cal=new SkeletonCalibration3D(calibration,registration);estimator=new SkeletonDepthPersonSegmenter(c);estimator.cal=cal;jointLearner=new SkeletonJointMotionLearner(c);
    consensus=new SkeletonTemporalConsensus(c);kalman=new SkeletonKalmanBank(c,jointLearner);poseFilter=new SkeletonPoseFilter(c,jointLearner);motionPrior=new SkeletonMotionPrior(c,jointLearner);
    rootFilter=new SkeletonRootStabilizer(c);identity=new SkeletonIdentityPredictor(c);
    biomechanics=new SkeletonAnthropometricModel(c);modelOptimizer=new SkeletonKinematicOptimizer(c);handKinematics=new SkeletonHandKinematicStabilizer(c);
    articulated=new ArticulatedBodySolver(c);articulatedFilter=new ArticulatedJointFilter(c);
    }
  void reset(){previous=null;lastBodyMask=null;identityMissFrames=0;acquireFrames=0;releaseFrames=0;
    activeTrackingId=0;stableTickMs=0;lastRawTickMs=0;lastHostTickMs=0;estimator.reset();jointLearner.reset();consensus.reset();kalman.reset();poseFilter.reset();motionPrior.reset();rootFilter.reset();
    identity.reset();biomechanics.reset();modelOptimizer.reset();handKinematics.reset();if(body3d!=null)body3d.reset();articulated.reset();articulatedFilter.reset();lastReason="searching";
    }
  float torsoScale(SkeletonPose3D s){if(s==null||s.shoulderCenter==null||s.hipCenter==null||!s.shoulderCenter.tracked()||!s.hipCenter.tracked())return Float.NaN;return PVector.dist(s.shoulderCenter.world,s.hipCenter.world);}
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
    SkeletonPose3D s=new SkeletonPose3D();if(depthFrame==null||depthFrame.depth==null){lastBodyMask=null;return predictedSkeleton(s,tick,"no_rgbd");}
    boolean broadSearch=identityMissFrames>=cfg.trackingReleaseFrames;PVector priorCenter=broadSearch?null:identity.predictedCenter(tick);
    float priorDepth=broadSearch?0:identity.predictedDepth(tick);long segT0=System.nanoTime();SkeletonDepthBodyMask body=estimator.segment(depthFrame,priorCenter,priorDepth);segmentNs+=System.nanoTime()-segT0;
    lastBodyMask=body;if(body==null)return predictedSkeleton(s,tick,"no_person");
    int top=centralTop(body),bottom=body.py(body.maxGY),height=max(1,bottom-top);
    if(height<cfg.bodyMinHeightPx){lastBodyMask=null;return predictedSkeleton(s,tick,"no_person");}if(activeTrackingId==0)activeTrackingId=nextTrackingId++;

    if(useArticulatedSolver()){
      long solveT0=System.nanoTime();SkeletonPose3D pose=articulated.solve(depthFrame,body,cal,estimator.floor,tick);solveNs+=System.nanoTime()-solveT0;
      if(pose==null)return predictedSkeleton(s,tick,"articulated_"+articulated.lastReason);
      pose.trackingId=activeTrackingId;
      long finT0=System.nanoTime();SkeletonPose3D out=finishArticulatedPose(pose,depthFrame,body,tick,top,bottom,height);finishNs+=System.nanoTime()-finT0;profFrames++;
      if(articulated.debug&&profFrames%40==0)println(String.format(Locale.ROOT,"[track-prof] segment %.2f (floor %.2f grow %.2f)  solve %.2f  finish %.2f ms",segmentNs/1e6/profFrames,estimator.floorNs/1e6/profFrames,estimator.growNs/1e6/profFrames,solveNs/1e6/profFrames,finishNs/1e6/profFrames));
      return out;
    }
    SkeletonPose3D fused=legacyBody3D().solve(depthFrame,infrared,body,cal,previous,tick,activeTrackingId);
    if(fused==null)return predictedSkeleton(s,tick,"body3d_unresolved");
    // Anchor solved joints back onto local metric-depth surfaces before temporal
    // filtering. This rejects RGB-independent silhouette drift and improves hand,
    // elbow, knee and foot Z stability near body edges.
    refinePoseWithMetricDepth(fused,depthFrame,body);
    return finishBody3DPose(fused,depthFrame,body,tick,top,bottom,height);
  }

  Body3DFusionEngine legacyBody3D(){if(body3d==null)body3d=new Body3DFusionEngine(cfg);return body3d;}
  boolean useArticulatedSolver(){return !"legacy".equals(cfg.solverMode);}
  // Lean publication path for the articulated solver: joints are already anatomical
  // centres with fixed bone lengths, so only a light One-Euro filter, topology
  // completion (hand tips/thumbs, spine-shoulder), hand detail and confidences run here.
  SkeletonPose3D finishArticulatedPose(SkeletonPose3D s,DepthFrame depthFrame,SkeletonDepthBodyMask body,long tick,int top,int bottom,int height){
    for(SkeletonJoint3D j:s.bodyJoints()){if(j==null)continue;String n=j.name.toLowerCase(Locale.ROOT);
      articulatedFilter.apply(j,tick,n.contains("hand")||n.contains("wrist")||n.contains("foot")||n.contains("ankle"));
      if(j.tracked()){PVector uv=cal.projectDepth(j.world);if(uv!=null)j.image.set(uv);}}
    augmentCanonicalTopology(s,tick);
    SkeletonJoint3D[] core={s.leftShoulder,s.rightShoulder,s.shoulderCenter,s.spine,s.hipCenter};
    s.torsoConfidence=chainConfidence(core);
    estimateNearHands(s,depthFrame,tick);
    handKinematics.stabilize(s,previous,cal,tick);
    clampSkeleton(s);
    float leftArmQ=chainConfidence(new SkeletonJoint3D[]{s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand}),
      rightArmQ=chainConfidence(new SkeletonJoint3D[]{s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand});
    float headTorsoQ=coverageConfidence(new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.leftShoulder,s.rightShoulder});
    s.upperBodyConfidence=constrain(.58f*headTorsoQ+.42f*max(leftArmQ,rightArmQ),0,1);
    s.interactionConfidence=constrain(.56f*s.torsoConfidence+.44f*max(leftArmQ,rightArmQ),0,1);
    s.lowerBodyConfidence=max(chainConfidence(new SkeletonJoint3D[]{s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot}),
      chainConfidence(new SkeletonJoint3D[]{s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot}));
    s.confidence=constrain(.36f*body.confidence+.39f*s.torsoConfidence+.25f*coverageConfidence(allJoints(s)),0,1);
    float hipY=s.hipCenter.tracked()?s.hipCenter.image.y:top+height*.55f;
    classifyPosture(s,body,hipY,bottom,height,s.leftKnee.observed()&&s.leftAnkle.observed(),s.rightKnee.observed()&&s.rightAnkle.observed());
    boolean evidence=s.torsoConfidence>=cfg.poseMinCoreConfidence*.9f;
    if(evidence){acquireFrames=min(cfg.trackingAcquireFrames+2,acquireFrames+1);releaseFrames=0;}else{releaseFrames++;acquireFrames=max(0,acquireFrames-1);}
    boolean wasTracked=previous!=null&&previous.tracked;
    s.tracked=evidence&&(wasTracked||acquireFrames>=max(1,cfg.trackingAcquireFrames-1));
    if(wasTracked&&!evidence&&releaseFrames<cfg.trackingReleaseFrames)s.tracked=true;
    if(releaseFrames>=cfg.trackingReleaseFrames){articulated.reset();articulatedFilter.reset();}
    s.reason=s.tracked?(evidence?"tracked_3d":"inferred_3d"):"acquiring_3d";lastReason=s.reason;
    if(s.tracked){identityMissFrames=0;deriveBounds(s);s.meanDepthM=meanDepth(s);
      float shoulderPx=PVector.dist(s.leftShoulder.image,s.rightShoulder.image);
      s.faceWidthPx=constrain(shoulderPx*.36f,18,140);s.faceHeightPx=s.faceWidthPx*1.25f;identity.update(s,tick,cal);previous=s;}
    else{identityMissFrames++;identity.miss();}
    return s;
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
    if(pose==null||body==null||body.samples<cfg.bodyMinSamples||pose.spine==null||!pose.spine.tracked())return;
    // Torso-only anchor. Never derive the root correction from the full silhouette
    // width: opening one arm must not move the estimated torso center. Use the
    // currently solved axial body and shoulder span only to define a sampling ROI;
    // metric depth inside the selected person component remains the measurement.
    PVector sc=pose.shoulderCenter!=null&&pose.shoulderCenter.tracked()?cal.projectDepth(pose.shoulderCenter.world):null;
    PVector hc=pose.hipCenter!=null&&pose.hipCenter.tracked()?cal.projectDepth(pose.hipCenter.world):null;
    PVector sp=cal.projectDepth(pose.spine.world);if(sp==null)return;
    float shoulderPx=0;
    if(pose.leftShoulder!=null&&pose.rightShoulder!=null&&pose.leftShoulder.tracked()&&pose.rightShoulder.tracked()){
      PVector l=cal.projectDepth(pose.leftShoulder.world),r=cal.projectDepth(pose.rightShoulder.world);if(l!=null&&r!=null)shoulderPx=PVector.dist(l,r);
    }
    float halfWidth=constrain(shoulderPx*.62f,28.0f,92.0f);
    float topY=sc!=null?sc.y:sp.y-55.0f,bottomY=hc!=null?hc.y:sp.y+70.0f;if(bottomY<topY){float t=topY;topY=bottomY;bottomY=t;}
    topY-=12.0f;bottomY+=10.0f;float centerX=sp.x;
    int x0=round(centerX-halfWidth),x1=round(centerX+halfWidth),y0=round(topY),y1=round(bottomY);
    PVector observed=new PVector();float weight=0;int used=0;
    for(int gy=body.minGY;gy<=body.maxGY;gy++){int py=body.py(gy);if(py<y0||py>y1)continue;for(int gx=body.minGX;gx<=body.maxGX;gx++){int px=body.px(gx);if(px<x0||px>x1)continue;
      int i=gy*body.gridW+gx;if(i<0||i>=body.mask.length||!body.mask[i])continue;int mm=body.mm[i];if(mm<=0)continue;
      PVector q=cal.deproject(px,py,mm);if(q==null)continue;float edge=body.clearance!=null&&i<body.clearance.length?constrain(body.clearance[i]/16.0f,.30f,1.0f):1.0f;
      observed.add(PVector.mult(q,edge));weight+=edge;used++;
    }}
    if(used<8||weight<=0)return;observed.div(weight);
    SkeletonJoint3D[] torso={pose.shoulderCenter,pose.spine,pose.hipCenter,pose.leftShoulder,pose.rightShoulder,pose.leftHip,pose.rightHip};
    PVector solved=new PVector();float sw=0;for(SkeletonJoint3D j:torso)if(j!=null&&j.tracked()&&j.world!=null){float q=max(.12f,j.confidence);solved.add(PVector.mult(j.world,q));sw+=q;}
    if(sw<=0)return;solved.div(sw);PVector delta=PVector.sub(observed,solved);float mag=delta.mag();
    float limit=lerp(.040f,.075f,constrain(body.confidence,0,1));if(mag>limit)delta.mult(limit/max(mag,.0001f));
    float strength=lerp(.28f,.52f,constrain(body.confidence,0,1));delta.mult(strength);if(delta.mag()<.0015f)return;
    for(SkeletonJoint3D j:pose.canonicalJoints())if(j!=null&&j.tracked()&&j.world!=null){j.world.add(delta);PVector uv=cal.projectWorldRgb(j.world);if(uv!=null)j.image.set(uv);}
  }

  SkeletonPose3D finishBody3DPose(SkeletonPose3D s,DepthFrame depthFrame,SkeletonDepthBodyMask body,long tick,int top,int bottom,int height){
    augmentCanonicalTopology(s,tick);
    // Sanitize the raw depth solution BEFORE it can enter any temporal state. A bad
    // hand/elbow candidate must never become Kalman velocity, consensus history or
    // training data and then poison several subsequent frames.
    legacyBody3D().enforcePublicationPose(s,previous,cal);
    validateKinematics(s);
    // Deterministic tracking pipeline: short kinematic prediction, fixed per-joint
    // temporal filtering, one metric-depth correction pass and one articulated
    // publication guard. No online body/motion model is learned from prior errors.
    motionPrior.apply(s,previous,tick,cal);
    kalman.apply(s,tick,cal);poseFilter.apply(s,tick,cal);rootFilter.apply(s,tick,cal);
    refinePoseWithMetricDepth(s,depthFrame,body);
    reanchorPoseToSegmentedTorso(s,body);
    legacyBody3D().anchorDistalLimbsToCloud(s,previous);
    legacyBody3D().enforcePeripheralCloudSupport(s,previous);
    legacyBody3D().enforcePublicationPose(s,previous,cal);
    legacyBody3D().recomputeJointEvidenceConfidence(s,previous);
    legacyBody3D().reproject(s,cal);
    preserveOccludedJoints(s,previous,tick);
    legacyBody3D().enforcePublicationPose(s,previous,cal);
    legacyBody3D().recomputeJointEvidenceConfidence(s,previous);
    legacyBody3D().reproject(s,cal);
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
    // Fine hands/fingers are a near-field refinement. Failure here never removes
    // the ordinary body-level hand joints.
    estimateNearHands(s,depthFrame,tick);
    handKinematics.stabilize(s,previous,cal,tick);
    // Hand refinement must not be able to pull the body-level wrist/hand chain out
    // of its anatomical envelope. Keep body and detailed-hand publication coherent.
    legacyBody3D().enforcePublicationPose(s,previous,cal);
    legacyBody3D().recomputeJointEvidenceConfidence(s,previous);
    clampSkeleton(s);
    leftArmQ=chainConfidence(new SkeletonJoint3D[]{s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand});
    rightArmQ=chainConfidence(new SkeletonJoint3D[]{s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand});
    headTorsoQ=coverageConfidence(new SkeletonJoint3D[]{s.head,s.shoulderCenter,s.spine,s.leftShoulder,s.rightShoulder});
    s.upperBodyConfidence=constrain(.58f*headTorsoQ+.42f*max(leftArmQ,rightArmQ),0,1);
    s.interactionConfidence=constrain(.56f*s.torsoConfidence+.44f*max(leftArmQ,rightArmQ),0,1);
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
    copyOccludedJoint(current.leftHandDetail.palm,prior.leftHandDetail.palm,tick,.90f);copyOccludedJoint(current.rightHandDetail.palm,prior.rightHandDetail.palm,tick,.90f);
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
      biomechanics.reset();modelOptimizer.reset();handKinematics.reset();if(body3d!=null)body3d.reset();
      s.reason=reason;lastReason=reason;return s;
    }
    // A full-body miss remains an occlusion state: preserve the last coherent
    // articulation, use only a bounded inertial prediction, then hold it with
    // decaying confidence until metric depth evidence returns.
    seedPredictedPose(s,previous,tick);
    biomechanics.stabilize(s,cal);biomechanics.hardStabilize(s,cal);legacyBody3D().enforcePublicationPose(s,previous,cal);handKinematics.stabilize(s,previous,cal,tick);clampSkeleton(s);
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
    // Body-level hand identity is independent from finger articulation. Wrist and
    // palm are always allowed to exist without any finger landmark.
    copyJoint(detail.landmarks[0],wrist,.82f,"body-anchor",tick);copyJoint(detail.palm,hand,.88f,"body-hand",tick);detail.source="body";detail.updateConfidence();
  }

  // adapters submit landmarks already registered into depth-image space here; Kinect depth remains authoritative
  // for metric Z, keeping hands in the same calibrated 3-D space as the body.
  void fuseHandLandmarksDepthSpace(SkeletonPose3D pose,SkeletonHand3D hand,float[] depthUvConfidence,DepthFrame depth,long tick){
    if(pose==null||hand==null||depthUvConfidence==null||depth==null||depth.depth==null||depthUvConfidence.length<SkeletonHand3D.LANDMARKS*3)return;
    for(int i=0;i<SkeletonHand3D.LANDMARKS;i++){float u=depthUvConfidence[i*3],v=depthUvConfidence[i*3+1],q=constrain(depthUvConfidence[i*3+2],0,1);if(q<.10f)continue;int du=round(u),dv=round(v);int mm=robustDepthMm(depth,du,dv,3);if(mm<=0)continue;PVector xyz=cal.deproject(du,dv,mm),rgb=cal.projectWorldRgb(xyz);if(rgb==null)rgb=new PVector(u,v);hand.landmarks[i].set(rgb,xyz,q,SkeletonJoint3D.TRACKED,"landmark-provider",tick);}
    hand.updateConfidence();
  }
  int robustDepthMm(DepthFrame d,int u,int v,int radius){if(d==null||d.depth==null||d.width<=0||d.height<=0)return 0;int[] values=new int[(radius*2+1)*(radius*2+1)];int n=0;for(int y=max(0,v-radius);y<=min(d.height-1,v+radius);y++)for(int x=max(0,u-radius);x<=min(d.width-1,u+radius);x++){int mm=d.depth[y*d.width+x]&0xffff;if(mm>=cfg.minDepthMm&&mm<=cfg.maxDepthMm)values[n++]=mm;}if(n==0)return 0;Arrays.sort(values,0,n);return values[n/2];}
  void clearFingerDetail(SkeletonHand3D hand){if(hand==null)return;for(int i=1;i<SkeletonHand3D.LANDMARKS;i++){SkeletonJoint3D j=hand.landmarks[i];j.state=SkeletonJoint3D.LOST;j.confidence=0;j.source="none";}hand.fingerCount=0;hand.updateConfidence();}
  void inferFingerChain(SkeletonHand3D hand,int base,int tipIndex,PVector tip,float q,long tick){if(hand==null||tip==null||!hand.palm.tracked())return;PVector p=hand.palm.world;float[] t={.34f,.58f,.79f,1.0f};for(int k=0;k<4;k++){int idx=base+k;PVector xyz=PVector.lerp(p,tip,t[k]);PVector uv=cal.projectWorldRgb(xyz);if(uv==null)uv=cal.projectDepth(xyz);if(uv==null)continue;int state=k==3?SkeletonJoint3D.TRACKED:SkeletonJoint3D.INFERRED;float cq=q*(k==3?1.0f:.72f);hand.landmarks[idx].set(uv,xyz,cq,state,"near-field-depth",tick);}}
  void estimateNearHandDepth(SkeletonHand3D detail,SkeletonHand3D prior,SkeletonJoint3D bodyWrist,SkeletonJoint3D bodyHand,DepthFrame depth,long tick){
    clearFingerDetail(detail);if(!cfg.handDetailEnabled||detail==null||bodyHand==null||!bodyHand.tracked()||depth==null||depth.depth==null)return;
    float z=bodyHand.world.z;if(z<=0||z>cfg.handDetailMaxDepthM)return;PVector center=cal.projectDepth(bodyHand.world);PVector wrist=bodyWrist!=null&&bodyWrist.tracked()?cal.projectDepth(bodyWrist.world):null;if(center==null)return;
    int cx=round(center.x),cy=round(center.y);float fx=285.0f*(depth.width/320.0f);
    // Fixed 1.10 m reference window: do not auto-zoom the fine-hand detector as
    // the measured hand depth changes. Metric depth still validates every sample.
    // Keep a metric hand window: unlike the old fixed 1.10 m window, scale the
    // image-space radius with measured Z so the same physical hand area is sampled
    // when the user moves toward/away from Kinect.
    float detectionZ=max(.35f,z);
    int radius=constrain(round(fx*cfg.handDetailRadiusM/detectionZ),14,72);int zmm=round(z*1000);
    int bins=96;float[] radial=new float[bins];int[] bx=new int[bins],by=new int[bins];int samples=0;float palmPx=max(5,radius*.26f);
    float armX=wrist==null?0:cx-wrist.x,armY=wrist==null?-1:cy-wrist.y,armLen=sqrt(armX*armX+armY*armY);if(armLen>1){armX/=armLen;armY/=armLen;}
    // Build a local depth-connected hand component before reading contour peaks.
    // A simple depth band alone admits unrelated background pixels at the same Z;
    // connectivity to the solved palm makes the detailed detector obey the same
    // foreground-evidence principle as the body solver.
    int side=radius*2+1,total=side*side;boolean[] valid=new boolean[total],connected=new boolean[total];int[] localMm=new int[total],queue=new int[total];int seed=-1;float seedR=Float.POSITIVE_INFINITY;
    for(int ly=0;ly<side;ly++){int y=cy-radius+ly;if(y<0||y>=depth.height)continue;for(int lx=0;lx<side;lx++){int x=cx-radius+lx;if(x<0||x>=depth.width)continue;float dx=x-cx,dy=y-cy,r=sqrt(dx*dx+dy*dy);if(r>radius)continue;int mm=depth.depth[y*depth.width+x]&0xffff;if(mm<=0||abs(mm-zmm)>cfg.handDetailDepthBandMm)continue;if(wrist!=null&&r>palmPx&&dx*armX+dy*armY<-.10f*radius)continue;int li=ly*side+lx;valid[li]=true;localMm[li]=mm;if(r<seedR&&r<=palmPx*1.35f){seedR=r;seed=li;}}}
    if(seed>=0){int qh=0,qt=0;queue[qt++]=seed;connected[seed]=true;int continuity=max(28,round(cfg.handDetailDepthBandMm*.42f));while(qh<qt){int li=queue[qh++],lx=li%side,ly=li/side,baseMm=localMm[li];for(int oy=-1;oy<=1;oy++)for(int ox=-1;ox<=1;ox++){if(ox==0&&oy==0)continue;int nx=lx+ox,ny=ly+oy;if(nx<0||ny<0||nx>=side||ny>=side)continue;int ni=ny*side+nx;if(!valid[ni]||connected[ni]||abs(localMm[ni]-baseMm)>continuity)continue;connected[ni]=true;queue[qt++]=ni;}}}
    for(int li=0;li<total;li++){if(!connected[li])continue;int lx=li%side,ly=li/side,x=cx-radius+lx,y=cy-radius+ly;float dx=x-cx,dy=y-cy,r=sqrt(dx*dx+dy*dy);if(r<palmPx)continue;samples++;float a=atan2(dy,dx);if(a<0)a+=TWO_PI;int b=constrain(floor(a/TWO_PI*bins),0,bins-1);if(r>radial[b]){radial[b]=r;bx[b]=x;by[b]=y;}}
    if(samples<cfg.handDetailMinSamples){detail.source="body";detail.updateConfidence();return;}
    float[] smooth=new float[bins];for(int b=0;b<bins;b++)smooth[b]=(radial[(b+bins-1)%bins]+2*radial[b]+radial[(b+1)%bins])*.25f;
    ArrayList<Integer> peaks=new ArrayList<Integer>();for(int b=0;b<bins;b++){float r=smooth[b];if(r<radius*cfg.handDetailTipMinRadius)continue;
      float shoulder=(smooth[(b+bins-3)%bins]+smooth[(b+bins-2)%bins]+smooth[(b+2)%bins]+smooth[(b+3)%bins])*.25f;
      if(r-shoulder<radius*cfg.handDetailTipProminence)continue;if(r>=smooth[(b+bins-1)%bins]&&r>smooth[(b+1)%bins])peaks.add(b);}
    Collections.sort(peaks,new Comparator<Integer>(){public int compare(Integer a,Integer b){return Float.compare(smooth[b],smooth[a]);}});ArrayList<Integer> chosen=new ArrayList<Integer>();
    for(Integer b:peaks){boolean near=false;for(Integer c:chosen){int d=abs(b-c);d=min(d,bins-d);if(d<4){near=true;break;}}if(!near)chosen.add(b);if(chosen.size()>=5)break;}
    if(chosen.isEmpty()){detail.source="near-field-hand";detail.updateConfidence();return;}
    // Convert peaks to metric candidates first. Identity is assigned by temporal
    // continuity before image ordering, so fingers do not swap names whenever the
    // hand rotates or two fingertips cross in image space.
    ArrayList<PVector> candidateTips=new ArrayList<PVector>();ArrayList<Float> candidateQ=new ArrayList<Float>(),candidateAngle=new ArrayList<Float>();
    float armAngle=atan2(armY,armX);
    for(Integer b:chosen){int mm=robustDepthMm(depth,bx[b],by[b],2);if(mm<=0)continue;PVector tip=cal.deproject(bx[b],by[b],mm);if(tip==null)continue;candidateTips.add(tip);candidateQ.add(constrain(.40f+.52f*(smooth[b]/max(1,radius)),.38f,.92f));float aa=atan2(by[b]-cy,bx[b]-cx)-armAngle;while(aa>PI)aa-=TWO_PI;while(aa<-PI)aa+=TWO_PI;candidateAngle.add(aa);}
    int[] bases={1,5,9,13,17},tips={4,8,12,16,20},assigned=new int[5];Arrays.fill(assigned,-1);boolean[] used=new boolean[candidateTips.size()],confirmed=new boolean[5];
    if(prior!=null){
      PVector palmDelta=(prior.palm!=null&&prior.palm.tracked()&&detail.palm!=null&&detail.palm.tracked())?PVector.sub(detail.palm.world,prior.palm.world):new PVector();
      // Global nearest-pair assignment is order independent. The old per-finger
      // greedy pass could let an early finger steal the only valid candidate of a
      // later finger and trigger identity swaps on the next frame.
      while(true){float best=cfg.handDetailTemporalMatchM;int bestFinger=-1,bestCandidate=-1;
        for(int f=0;f<5;f++){if(assigned[f]>=0)continue;SkeletonJoint3D old=prior.landmarks[tips[f]];if(old==null||!old.tracked())continue;PVector predictedTip=PVector.add(old.world,palmDelta);
          for(int c=0;c<candidateTips.size();c++){if(used[c])continue;float d=PVector.dist(predictedTip,candidateTips.get(c));if(d<best){best=d;bestFinger=f;bestCandidate=c;}}}
        if(bestFinger<0)break;assigned[bestFinger]=bestCandidate;confirmed[bestFinger]=true;used[bestCandidate]=true;
      }
    }
    ArrayList<Integer> remainCandidates=new ArrayList<Integer>();for(int c=0;c<candidateTips.size();c++)if(!used[c])remainCandidates.add(c);
    // Order new fingertips in the hand-local frame, not by global camera X. This
    // keeps first acquisition usable while the wrist rotates in the image plane.
    Collections.sort(remainCandidates,new Comparator<Integer>(){public int compare(Integer a,Integer b){return Float.compare(candidateAngle.get(a),candidateAngle.get(b));}});
    ArrayList<Integer> remainFingers=new ArrayList<Integer>();for(int f=0;f<5;f++)if(assigned[f]<0)remainFingers.add(f);if("left".equals(detail.side))Collections.reverse(remainFingers);int fill=min(remainCandidates.size(),remainFingers.size());for(int i=0;i<fill;i++)assigned[remainFingers.get(i)]=remainCandidates.get(i);
    for(int f=0;f<5;f++){int c=assigned[f];if(c<0)continue;float q=candidateQ.get(c)*(confirmed[f]?1.0f:cfg.handDetailNewTipConfidence);inferFingerChain(detail,bases[f],tips[f],candidateTips.get(c),q,tick);}
    detail.source="near-field-depth";detail.updateConfidence();
  }
  void estimateNearHands(SkeletonPose3D s,DepthFrame depth,long tick){if(s==null)return;SkeletonHand3D pl=previous==null?null:previous.leftHandDetail,pr=previous==null?null:previous.rightHandDetail;estimateNearHandDepth(s.leftHandDetail,pl,s.leftWrist,s.leftHand,depth,tick);estimateNearHandDepth(s.rightHandDetail,pr,s.rightWrist,s.rightHand,depth,tick);}
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
  SkeletonJoint3D[] allJoints(SkeletonPose3D s){return s.bodyJoints();}
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

