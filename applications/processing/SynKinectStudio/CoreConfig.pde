// ===== SynKinect Studio / Core (shared by all modules) / AppConfig.pde =====
class AppConfig {
  int uiFrameRate = 30;
  int workerJoinMs = 1500;

  int pointStep = 3;
  int integrationPointStep = 2;
  int minimumTrackingPoints = 220;
  // Real-time fusion refinement: weak/noisy frames contribute less to TSDF
  // instead of being allowed to roughen an otherwise stable surface.
  float fusionMinimumFrameQuality = 0.44f;
  float fusionFullWeightQuality = 0.82f;
  int fusionLowQualityStride = 2;
  // Surface-consistency gate: once the TSDF has evidence at a location, a new
  // frame must agree with that surface before it is allowed to add another shell.
  float fusionSurfaceMinKnownRatio = 0.12f;
  float fusionSurfaceMinAgreement = 0.74f;
  float fusionSurfaceMaxResidualM = 0.0045f;
  float fusionSurfaceAgreementBandM = 0.006f;
  int fusionSurfaceMinWeight = 2;
  float fusionReferenceMinOverlap = 0.12f;
  float fusionReferenceMaxRmsM = 0.010f;
  // Kinect Fusion tracks against the reconstructed TSDF surface first. The
  // rolling cloud map is retained only as a recovery path after model tracking fails.
  boolean fusionModelTracking = true;
  int fusionModelMinWeight = 2;
  int fusionPointPlaneIterations = 7;
  int fusionPointPlaneMaxSamples = 2200;
  int fusionPointPlaneMinMatches = 100;
  float fusionPointPlaneMinOverlap = 0.14f;
  float fusionPointPlaneMaxRmsM = 0.014f;
  float fusionRaycastSearchM = 0.18f;
  float fusionRaycastStepScale = 0.75f;
  int fusionModelCacheMaxPoints = 10000;
  int fusionModelCacheRefreshTouched = 1800;
  int fusionModelCacheRefreshIntegrations = 3;
  float fusionModelCacheCellM = 0.014f;
  float fusionRelocalizeMinOverlap = 0.14f;
  float fusionRelocalizeMaxRmsM = 0.016f;
  // Kinect Fusion-style pose finder: accepted model keyframes become sparse
  // relocalization seeds. They are consulted only after normal model/local ICP
  // recovery fails, so the steady-state tracking cost remains unchanged.
  boolean fusionPoseFinder = true;
  int fusionPoseFinderMaxPoses = 24;
  int fusionPoseFinderMaxCandidates = 10;
  float fusionPoseFinderMinTranslationM = 0.055f;
  float fusionPoseFinderMinRotationDeg = 5.0f;
  int fusionCoverageMatureWeight = 10;
  int fusionCoverageViewBins = 24;
  int fusionCoverageRefreshFrames = 4;
  // Fixed is the normal KinectFusion reconstruction model. Expansion remains
  // available only as a fallback when no pre-scan target volume could be locked.
  boolean fusionDynamicExpansion = false;
  int fusionExpansionCheckFrames = 12;
  // Stationary-pose guard for handheld Fusion. ICP noise below this envelope is
  // snapped to the last stable anchor instead of accumulating into a fake camera path.
  float fusionPoseDeadbandTranslationM = 0.0075f;
  float fusionPoseDeadbandRotationDeg = 0.85f;
  float fusionTrajectoryMinStepM = 0.015f;
  int fusionBootstrapFrames = 3;
  // Heavy model alignment runs only for Fusion keyframes. Corrections outside
  // these limits are treated as loss/relocalization, never fused blindly.
  float fusionModelRefineMaxCorrectionM = 0.10f;
  float fusionModelRefineMaxCorrectionDeg = 10.0f;
  float fusionModelRefineMinOverlap = 0.15f;
  float fusionModelRefineMaxRmsM = 0.014f;
  float fusionModelRebaseTranslationM = 0.0035f;
  float fusionModelRebaseRotationDeg = 0.40f;
  // Anti-layering gate for the capture archive. This is deliberately stricter
  // than live tracking: uncertain poses may keep the preview moving, but they
  // must never become reconstruction keyframes and create a second shell.
  boolean fusionArchiveGateEnabled = true;
  int fusionArchiveWarmupKeyframes = 3;
  int fusionArchiveReferenceFrames = 6;
  int fusionArchiveRefineIterations = 7;
  float fusionArchiveRefineDistanceM = 0.038f;
  float fusionArchiveMinOverlap = 0.20f;
  float fusionArchiveMaxRmsM = 0.013f;
  float fusionArchiveMaxCorrectionM = 0.045f;
  float fusionArchiveMaxCorrectionDeg = 5.5f;
  float fusionArchiveRebaseTranslationM = 0.0025f;
  float fusionArchiveRebaseRotationDeg = 0.30f;

  float minDepthM = 0.20f;
  float maxDepthM = 4.50f;

  // Metric depth intrinsics are externalized so scanner geometry can be tuned
  // without changing source when a calibrated Kinect profile is available.
  float depthFx = 594.2143421192325f;
  float depthFy = 591.0405369687078f;
  float depthCx = 339.30780975300314f;
  float depthCy = 242.73913761751615f;
  float depthScale = 0.001f;

  float objectDepthBandM = 0.20f;
  float maxObjectDepthBandM = 0.34f;
  float depthTargetSmoothing = 0.12f;
  float depthTargetStableToleranceM = 0.12f;
  float depthTargetMaxJumpM = 0.24f;
  int depthTargetStableFrames = 3;
  int depthTargetLostFramesForReacquire = 6;
  // Active Scan keeps the acquired foreground target sticky. These values allow
  // smooth real camera/object motion while refusing background-wall focus jumps.
  int depthTargetCaptureLostFrames = 18;
  float depthTargetCaptureMaxJumpM = 0.32f;
  float depthTargetCaptureSmoothing = 0.08f;
  int depthTargetMinSamples = 80;
  float depthTargetMinConfidence = 0.040f;
  int depthHistogramBinMm = 20;
  float depthRoiLeft = 0.24f;
  float depthRoiRight = 0.76f;
  float depthRoiTop = 0.20f;
  float depthRoiBottom = 0.80f;
  int depthRoiSampleStep = 2;
  float depthPreferredTargetWindowM = 0.30f;
  // Foreground segmentation is deliberately narrower than the raw depth range.
  // A Kinect scan should lock one coherent object, not merge the support/table
  // or a distant wall simply because both happen to fall inside a broad Z band.
  float depthBandSpreadMultiplier = 1.80f;
  float targetSegmentationMargin = 0.10f;

  // Turntable scanning is volume-of-interest tracking. The first valid target
  // locks a metric 3D box in camera space; background outside it never reaches ICP.
  boolean boundingBoxEnabled = true;
  float boundingBoxMarginM = 0.045f;
  float boundingBoxDepthMarginM = 0.035f;
  float boundingBoxBaseExtraM = 0.075f;
  float boundingBoxMinWidthM = 0.24f;
  float boundingBoxMinHeightM = 0.24f;
  float boundingBoxMinDepthM = 0.16f;
  float boundingBoxMaxWidthM = 0.90f;
  float boundingBoxMaxHeightM = 1.20f;
  float boundingBoxMaxDepthM = 0.70f;
  float boundingBoxCenterFollowAlpha = 0.015f;
  float boundingBoxMaxCenterCorrectionM = 0.035f;
  int boundingBoxMinPoints = 140;
  // Turntable support-plane (table/floor) removal. See SupportPlaneEstimator.
  boolean supportPlaneEnabled = true;
  int supportPlaneSampleStep = 6;
  int supportPlaneIterations = 160;
  float supportPlaneMaxTiltDeg = 25.0f;
  float supportPlaneInlierM = 0.006f;
  int supportPlaneMinInliers = 350;
  float supportPlaneMinInlierRatio = 0.06f;
  float supportPlaneClearanceM = 0.008f;
  int supportPlaneRefreshMs = 900;
  // Turntable uses the metric target cube as an immediate axis/pivot seed. Robust
  // ICP may still absorb a small XYZ residual for people/clothing/body sway, while
  // consensus pivot calibration tightens the physical axis as the turn develops.
  boolean turntablePivotCalibrationEnabled = true;
  float turntablePivotCalibrationDeg = 38.0f;
  boolean tsdfProjective = true;
  boolean fusionTargetVolume = true;
  float fusionVolumeMinSideM = 0.50f;
  float fusionVolumePadding = 1.25f;
  float fusionTrackingVolumePadding = 1.65f;
  // Kinect v1 depth noise model sigma(z) = base + quad * z^2 (metres).
  float depthNoiseBaseM = 0.0008f;
  float depthNoiseQuadM = 0.0019f;
  boolean meshMarchingCubes = true;
  float depthTargetNearestModeFraction = 0.30f;
  boolean depthTargetPreferNearest = true;
  float modelTrackingFinalGateM = 0.010f;
  float modelTrackingMaxTangentialM = 0.006f;
  float tsdfCarveMarginM = 0.012f;
  boolean turntableModelTracking = true;
  boolean turntablePlanarMotion = true;
  float turntableModelTrackingMaxRmsM = 0.0065f;
  float turntableModelTrackingMinOverlap = 0.30f;
  float turntablePivotCalibrationToleranceM = 0.006f;
  float turntablePivotCalibrationMaxShiftM = 0.16f;


  int depthMinValidPixels = 1200;
  float depthMinValidRatio = 0.004f;
  int depthPlausibleMinMm = 180;
  int depthPlausibleMaxMm = 6000;
  long streamStaleTimeoutMs = 1200;
  long connectionStaleTimeoutMs = 2500;
  int reconnectDelayMs = 250;
  int captureDrainFramesPerDraw = 8;
  int reconstructionQueueFrames = 1;
  int reconstructionMaxFps = 20;
  boolean reconstructionAdaptiveCadence = true;
  float reconstructionTargetUtilization = 0.72f;
  int reconstructionMaxIntervalMs = 220;

  boolean pointCloudSpatialFilter = true;
  float pointCloudNeighborToleranceM = 0.045f;
  float pointCloudMinimumConfidence = 0.18f;
  float pointCloudEdgeSoftM = 0.010f;
  float pointCloudEdgeRejectM = 0.026f;
  float pointCloudSurfaceNoiseM = 0.012f;
  float pointCloudMinimumSupport = 0.55f;
  boolean pointCloudConnectedTarget = true;
  int pointCloudComponentMinSamples = 70;
  float pointCloudComponentDepthLinkM = 0.045f;
  float pointCloudComponentBorderPenalty = 0.42f;

  // Stable Scanner viewport auto-fit. Expansion is allowed relatively quickly
  // so geometry is never clipped; zoom-in and recentering are intentionally
  // slow/dead-banded to prevent frame-by-frame breathing.
  float previewAutoFitZoomOutResponse = 0.14f;
  float previewAutoFitZoomInResponse = 0.022f;
  float previewAutoFitCenterResponse = 0.050f;
  float previewAutoFitDeadband = 0.070f;
  int previewAutoFitShrinkDelayFrames = 24;

  int volumeSize = 160;
  float voxelSizeM = 0.0045f;
  float truncationM = 0.022f;
  int meshMinWeight = 2;
  int previewMeshMinWeight = 2;
  int previewMeshRefreshFrames = 6;
  int previewMeshRefreshMs = 350;
  int previewMeshMaxTriangles = 90000;
  // Capture preview uses a persistent ICP-registered point model instead of a
  // periodically extracted textured mesh.
  float previewPointVoxelM = 0.0040f;
  int previewPointMaxPoints = 52000;
  int previewPointDisplayMaxPoints = 16000;
  int previewPointTransientMaxPoints = 1800;
  int previewPointRefreshMs = 120;

  int icpIterations = 7;
  int icpMinimumMatches = 50;
  float icpCellSizeM = 0.075f;
  float icpMaxDistanceM = 0.075f;
  float icpFinalDistanceM = 0.024f;
  int icpMaxSamples = 2400;
  float icpGoodRmsM = 0.045f;
  int icpReferenceFrames = 3;
  int icpReferenceMaxPoints = 6000;
  float icpTrimFraction = 0.72f;
  float icpMinimumOverlap = 0.24f;
  float icpRobustK = 0.65f;
  boolean icpReciprocal = true;
  int icpReciprocalFinalIterations = 2;
  float icpReciprocalToleranceM = 0.015f;
  int turntableSeedSearchEveryFrames = 1;
  float icpMaxTranslationStepM = 0.12f;
  float icpMaxRotationStepDeg = 32.0f;
  boolean turntableTracking = true;
  // ICP always composes the complete SE(3) pose. Turntable yaw search is only
  // an initialization aid and never replaces the converged rigid transform.
  float turntableMaxSeedYawDeg = 36.0f;
  float turntableSeedSearchWindowDeg = 16.0f;
  int turntableSeedMaxSamples = 1100;
  float turntableCoarseStepDeg = 3.0f;
  float turntableFineStepDeg = 0.50f;
  float turntableMotionAlpha = 0.40f;
  float turntablePredictionWeight = 0.30f;
  float turntableSeedMinGain = 0.0025f;
  float turntableSeedMinimumConfidence = 0.07f;
  float turntableSeedPoseAuthority = 0.82f;
  float turntableSeedMinTrackedYawDeg = 0.06f;
  float turntableVelocityClampDeg = 8.0f;
  float turntablePivotAlpha = 0.035f;
  float turntableConstrainedEvaluationM = 0.040f;
  boolean turntablePoseConstraint = true;
  // Human/object turntable scans are not ideal rotations around a mathematical
  // axis. The axial model is only a yaw prior; the accumulated TSDF then refines
  // the frame in full SE(3), compensating chair/body eccentricity and sway.
  boolean turntableModelRefinement = true;
  // Global model refinement is intentionally keyframe-paced. Running TSDF ICP on
  // every tracking frame wastes CPU and makes capture cadence collapse.
  int turntableModelRefineEveryFrames = 3;
  float turntableModelRefineMaxCorrectionM = 0.16f;
  float turntableModelRefineMaxCorrectionDeg = 16.0f;
  float turntableModelRefineMinOverlap = 0.08f;
  float turntableModelRefineMaxRmsM = 0.022f;
  // Near the end of a full revolution, explicitly close the loop against the
  // first accepted view so residual drift cannot become a second shell.
  boolean turntableLoopClosure = true;
  float turntableLoopClosureStartDeg = 318.0f;
  int turntableLoopClosureEveryFrames = 4;
  float turntableLoopClosureDistanceM = 0.050f;
  float turntableLoopClosureMaxRmsM = 0.020f;
  float turntableLoopClosureMaxCorrectionM = 0.12f;
  float turntableLoopClosureMaxCorrectionDeg = 14.0f;
  float turntableConstraintScoreSlack = 0.12f;
  float turntableConstraintTranslationM = 0.022f;
  float turntableConstraintTranslationAuthority = 0.42f;
  // Turntable integrates angular progress only. Residual XYZ from silhouette/ICP
  // is not a reason to fuse another frame while the object has not actually rotated.
  float turntableIntegrationMinYawDeg = 0.65f;
  int turntablePivotConsensusSamples = 5;
  // Y variation carries little information about yaw. Keep it for 6DoF ICP,
  // but strongly down-weight it while choosing the turntable yaw seed.
  float turntableVerticalResidualWeight = 0.55f;
  // Photometric evidence is a correspondence weight, never a replacement for
  // metric geometry. Missing/unsynchronised RGB automatically falls back to depth ICP.
  boolean colorIcpEnabled = true;
  float colorIcpWeight = 0.28f;
  float colorIcpRejectDistance = 0.62f;
  float colorIcpMinimumWeight = 0.22f;

  // Fusion keyframe spacing. These are intentionally above the stationary ICP
  // noise floor so a Kinect sitting still does not create work or a fake path.
  float integrationMinTranslationM = 0.0060f;
  float integrationMinRotationDeg = 0.80f;
  int integrationMaxIdleFrames = 30; // retained for config compatibility; Fusion no longer uses idle refresh.
  int scanCoverageBins = 72;
  float scanCoverageRequired = 0.98f;
  boolean volumeAutoFit = true;
  float volumeAutoFitPadding = 1.15f;
  float volumeMaxVoxelSizeM = 0.008f;

  // Turntable HQ profile: conservative evidence, fixed-axis poses and a finer final TSDF.
  // High-quality offline reconstruction. Realtime fusion remains the responsive
  // preview; final mesh generation can re-register retained keyframes and
  // re-integrate them at higher spatial resolution.
  boolean hqEnabled = true;
  int hqMaxKeyframes = 192;
  int hqFinalizeMaxKeyframes = 120;
  float hqKeyframeMinRotationDeg = 1.5f;
  float hqKeyframeMinTranslationM = 0.004f;
  int hqMinimumKeyframes = 12;
  int hqIntegrationStep = 1;
  int hqVolumeSize = 240;
  float hqVoxelSizeM = 0.0021f;
  float hqTruncationM = 0.0075f;
  int hqMeshMinWeight = 4;
  int hqIcpIterations = 15;
  int hqIcpMaxSamples = 16000;
  int hqIcpMinimumMatches = 280;
  float hqIcpMaxDistanceM = 0.024f;
  float hqIcpTrimFraction = 0.72f;
  float hqIcpGoodRmsM = 0.0095f;
  boolean hqGlobalRecovery = true;
  int hqGlobalRecoveryPasses = 3;
  int hqGlobalRecoveryNeighborFrames = 5;
  float hqGlobalRecoveryCoarseDistanceM = 0.070f;
  float hqGlobalRecoveryFineDistanceM = 0.020f;
  float hqGlobalRecoveryMaxTranslationM = 0.16f;
  float hqGlobalRecoveryMaxRotationDeg = 32.0f;
  float hqGlobalRecoveryMinSupport = 0.34f;
  float hqGlobalRecoveryMaxRmsM = 0.012f;
  boolean hqLoopClosure = true;
  float hqLoopClosureMaxRmsM = 0.013f;
  // Turntable-specific offline reconstruction. The sweep angle is treated as a
  // strong geometric prior, while reliable ICP evidence is still allowed to
  // correct small axis/pivot errors. Weak scans are rejected instead of being
  // allowed to create a second shell in the final TSDF.
  boolean hqTurntableConsensus = true;
  float hqTurntableAxisAuthority = 0.90f;
  float hqTurntableRescueMinSupport = 0.44f;
  float hqTurntableRescueMaxRmsM = 0.009f;
  float hqTurntableRecoveredFramePenalty = 0.45f;
  int hqDepthFilterRadius = 2;
  float hqDepthEdgeToleranceM = 0.018f;
  int hqHoleFillMinimumNeighbors = 14;
  boolean hqDistanceWeightedTsdf = true;
  // HQ integrates only stable depth evidence. Confidence is non-linear so
  // edge/speckle samples cannot thicken the final surface merely by repetition.
  float hqTsdfMinimumPointConfidence = 0.30f;
  float hqTsdfConfidenceGamma = 1.75f;
  // Multi-frame depth super-resolution. Neighboring keyframes are reprojected
  // into a supersampled anchor view after pose refinement, then fused with
  // confidence weighting, robust outlier rejection and foreground z-buffering.
  boolean hqDepthSuperResolution = true;
  int hqDepthSrScale = 2;
  int hqDepthSrWindowFrames = 7;
  int hqDepthSrAnchorStride = 2;
  float hqDepthSrMaxRotationDeg = 6.0f;
  float hqDepthSrMaxTranslationM = 0.030f;
  float hqDepthSrOcclusionToleranceM = 0.010f;
  float hqDepthSrOutlierToleranceM = 0.007f;
  int hqDepthSrMinimumViews = 3;
  int hqDepthSrMaxPoints = 520000;
  int hqMeshPolishIterations = 1;
  float hqMeshPolishLambda = 0.14f;
  float hqMeshPolishMu = -0.145f;

  boolean calibrationEnabled = true;
  int calibrationStations = 5;
  int calibrationFramesPerStation = 30;
  int calibrationMinimumStationsPerPixel = 3;
  float calibrationDistanceSeparationM = 0.16f;
  float calibrationStabilityToleranceM = 0.018f;
  float calibrationPlaneResidualMaxM = 0.030f;
  float calibrationSlopeMin = 0.92f;
  float calibrationSlopeMax = 1.08f;
  float calibrationOffsetMaxM = 0.060f;
  float calibrationNoiseFloorM = 0.0015f;
  float calibrationNoiseCeilingM = 0.030f;
  // Distance-aware correction model (see docs/SENSOR-CALIBRATION.md).
  float calibrationTrimFraction = 0.20f;
  float calibrationFlyingPixelSigma = 6.0f;
  int calibrationGridX = 40;
  int calibrationGridY = 30;
  int calibrationDepthBins = 8;
  float calibrationRegularization = 0.0f; // 0 = automatic (leave-one-station-out)
  float calibrationReferenceMatchTolerance = 0.12f;
  float calibrationReferenceMaxScaleError = 0.10f;

  float scanFullTurnDeg = 360.0f;
  float scanCompleteDeg = 358.0f;
  float scanRotationDeadbandDeg = 0.05f;
  float scanRotationMaxStepDeg = 24.0f;
  float scanDirectionLockDeg = 1.2f;
  float scanTurnFilterAlpha = 0.52f;
  float scanReverseJitterDeg = 1.20f;
  float scanReverseCommitDeg = 4.0f;
  float scanDirectionRelockDeg = 20.0f;
  float scanMaxSensorTiltDriftDeg = 10.0f;
  boolean autoPauseOnFullTurn = true;

  float meshCleanupMaxEdgeM = 0.10f;
  float meshCleanupMinAreaM2 = 0.00000010f;
  float meshWeldToleranceM = 0.0010f;
  int meshSmoothIterations = 2;
  float meshSmoothLambda = 0.30f;
  int meshPolishIterations = 3;
  float meshPolishLambda = 0.22f;
  float meshPolishMu = -0.225f;
  boolean meshHoleFillEnabled = true;
  int meshHoleFillMaxEdges = 18;
  float meshHoleFillMaxDiameterM = 0.030f;
  float meshHoleFillMaxPerimeterM = 0.090f;
  int meshMinimumComponentTriangles = 32;
  float meshMinimumComponentRatio = 0.002f;
  boolean meshColorEnabled = true;

  // RGB/depth registration. The intrinsic/extrinsic defaults are a representative
  // Kinect Xbox 360 stereo calibration profile; every value remains externalized so a
  // per-device calibration can provide device-specific values from configuration.
  float rgbFx = 529.215081f, rgbFy = 525.563936f, rgbCx = 328.942720f, rgbCy = 267.480682f;

  float depthK1 = -0.263864f, depthK2 = 0.999668f, depthP1 = -0.000762f, depthP2 = 0.005035f, depthK3 = -1.305362f;
  // Depth pixel convention: distorted normalized x = (u + depthPixelCenter + depthShiftU - cx) / fx.
  // depthShiftU/V model the Kinect 360 depth-to-IR image offset (IR pixel = depth pixel + shift);
  // leave 0 unless cx/cy were calibrated on the IR image and the offset was measured.
  float depthPixelCenter = 0.0f, depthShiftU = 0.0f, depthShiftV = 0.0f;

  float rgbK1 = 0.207966f, rgbK2 = -0.586138f, rgbP1 = 0.000722f, rgbP2 = 0.001048f, rgbK3 = 0.498570f;

  float regR00=0.9998463f, regR01=0.0012635f, regR02=-0.0174872f;
  float regR10=-0.0014779f, regR11=0.9999239f, regR12=-0.0122514f;
  float regR20=0.0174704f, regR21=0.0122753f, regR22=0.9997720f;
  float regTx=0.01998524f, regTy=-0.00074424f, regTz=-0.01091674f;
  float colorRegistrationOffsetX = 0.0f;
  float colorRegistrationOffsetY = 0.0f;
  float rgbMaxSyncSkewMs = 24.0f;
  int rgbdQueueFrames = 8;
  int rgbdSyncHistoryFrames = 10;
  float rgbdSyncMaxResidualMs = 24.0f;
  float rgbdSyncBootstrapMaxSkewMs = 180.0f;
  float rgbdSyncOffsetAlpha = 0.08f;
  boolean rgbOcclusionFilter = true;
  float rgbOcclusionToleranceM = 0.025f;
  boolean rgbAutoRefine = true;
  int rgbRefineEveryFrames = 8;
  int rgbRefineSearchPx = 4;
  int rgbRefineSampleStep = 10;
  int rgbRefineEdgeThresholdMm = 65;
  int rgbRefineMinimumEdges = 36;
  float rgbRefineAlpha = 0.12f;
  float rgbRefineMaxOffsetPx = 8.0f;
  int rgbExposureLowLuma = 24;
  int rgbExposureHighLuma = 235;
  int rgbTemporalColorWeightMax = 8;
  int rgbHqHistoryFrames = 8;
  float rgbHqMaxSyncSkewMs = 90.0f;
  float rgbHqMinimumFrameQuality = 0.22f;
  boolean rgbPhotometricNormalize = true;
  float rgbPhotometricGainMin = 0.72f;
  float rgbPhotometricGainMax = 1.38f;
  float rgbHqSharpenAmount = 0.16f;

  String exportBaseName = "SynKinectScan";
  float exportWeldToleranceM = 0.0010f;
  float exportMaxWeldToleranceM = 0.004f;
  int exportMaxTriangles = 600000;

  void load(File file) {
    Properties p=studio.services.configRules.load(file,"scanner");
      uiFrameRate = intValue(p, "ui.frameRate", uiFrameRate, 10, 120);
      workerJoinMs = intValue(p, "lifecycle.workerJoinMs", workerJoinMs, 250, 10000);

      pointStep = intValue(p, "cloud.previewStep", pointStep, 1, 16);
      integrationPointStep = intValue(p, "cloud.integrationStep", integrationPointStep, 1, 16);
      fusionMinimumFrameQuality = floatValue(p,"fusion.minimumFrameQuality",fusionMinimumFrameQuality,0.05f,0.90f);
      fusionFullWeightQuality = floatValue(p,"fusion.fullWeightQuality",fusionFullWeightQuality,fusionMinimumFrameQuality,1.0f);
      fusionLowQualityStride = intValue(p,"fusion.lowQualityStride",fusionLowQualityStride,1,6);
      fusionSurfaceMinKnownRatio = floatValue(p,"fusion.surfaceMinKnownRatio",fusionSurfaceMinKnownRatio,0.02f,0.90f);
      fusionSurfaceMinAgreement = floatValue(p,"fusion.surfaceMinAgreement",fusionSurfaceMinAgreement,0.10f,1.0f);
      fusionSurfaceMaxResidualM = floatValue(p,"fusion.surfaceMaxResidualM",fusionSurfaceMaxResidualM,0.002f,0.050f);
      fusionSurfaceAgreementBandM = floatValue(p,"fusion.surfaceAgreementBandM",fusionSurfaceAgreementBandM,0.003f,0.060f);
      fusionSurfaceMinWeight = intValue(p,"fusion.surfaceMinWeight",fusionSurfaceMinWeight,1,32);
      fusionReferenceMinOverlap = floatValue(p,"fusion.referenceMinOverlap",fusionReferenceMinOverlap,0.02f,0.80f);
      fusionReferenceMaxRmsM = floatValue(p,"fusion.referenceMaxRmsM",fusionReferenceMaxRmsM,0.003f,0.050f);
      fusionModelTracking = boolValue(p,"fusion.modelTracking.enabled",fusionModelTracking);
      fusionModelMinWeight = intValue(p,"fusion.modelTracking.minWeight",fusionModelMinWeight,1,32);
      fusionPointPlaneIterations = intValue(p,"fusion.modelTracking.iterations",fusionPointPlaneIterations,1,20);
      fusionPointPlaneMaxSamples = intValue(p,"fusion.modelTracking.maxSamples",fusionPointPlaneMaxSamples,200,12000);
      fusionPointPlaneMinMatches = intValue(p,"fusion.modelTracking.minMatches",fusionPointPlaneMinMatches,20,5000);
      fusionPointPlaneMinOverlap = floatValue(p,"fusion.modelTracking.minOverlap",fusionPointPlaneMinOverlap,0.02f,0.90f);
      fusionPointPlaneMaxRmsM = floatValue(p,"fusion.modelTracking.maxRmsM",fusionPointPlaneMaxRmsM,0.002f,0.080f);
      fusionRaycastSearchM = floatValue(p,"fusion.modelTracking.raycastSearchM",fusionRaycastSearchM,0.03f,0.60f);
      fusionRaycastStepScale = floatValue(p,"fusion.modelTracking.raycastStepScale",fusionRaycastStepScale,0.25f,2.0f);
      fusionModelCacheMaxPoints = intValue(p,"fusion.modelTracking.cacheMaxPoints",fusionModelCacheMaxPoints,1000,60000);
      fusionModelCacheRefreshTouched = intValue(p,"fusion.modelTracking.cacheRefreshTouched",fusionModelCacheRefreshTouched,128,50000);
      fusionModelCacheRefreshIntegrations = intValue(p,"fusion.modelTracking.cacheRefreshIntegrations",fusionModelCacheRefreshIntegrations,1,30);
      fusionModelCacheCellM = floatValue(p,"fusion.modelTracking.cacheCellM",fusionModelCacheCellM,0.003f,0.080f);
      fusionRelocalizeMinOverlap = floatValue(p,"fusion.relocalize.minOverlap",fusionRelocalizeMinOverlap,0.02f,0.80f);
      fusionRelocalizeMaxRmsM = floatValue(p,"fusion.relocalize.maxRmsM",fusionRelocalizeMaxRmsM,0.003f,0.080f);
      fusionPoseFinder = boolValue(p,"fusion.poseFinder.enabled",fusionPoseFinder);
      fusionPoseFinderMaxPoses = intValue(p,"fusion.poseFinder.maxPoses",fusionPoseFinderMaxPoses,4,96);
      fusionPoseFinderMaxCandidates = intValue(p,"fusion.poseFinder.maxCandidates",fusionPoseFinderMaxCandidates,2,32);
      fusionPoseFinderMinTranslationM = floatValue(p,"fusion.poseFinder.minTranslationM",fusionPoseFinderMinTranslationM,0.005f,0.50f);
      fusionPoseFinderMinRotationDeg = floatValue(p,"fusion.poseFinder.minRotationDeg",fusionPoseFinderMinRotationDeg,0.5f,45.0f);
      fusionCoverageMatureWeight = intValue(p,"fusion.coverage.matureWeight",fusionCoverageMatureWeight,2,64);
      fusionCoverageViewBins = intValue(p,"fusion.coverage.viewBins",fusionCoverageViewBins,8,96);
      fusionCoverageRefreshFrames = intValue(p,"fusion.coverage.refreshFrames",fusionCoverageRefreshFrames,1,60);
      fusionDynamicExpansion = boolValue(p,"fusion.dynamicExpansion",fusionDynamicExpansion);
      fusionExpansionCheckFrames = intValue(p,"fusion.dynamicExpansionCheckFrames",fusionExpansionCheckFrames,1,120);
      fusionPoseDeadbandTranslationM = floatValue(p,"fusion.poseDeadbandTranslationM",fusionPoseDeadbandTranslationM,0.0f,0.05f);
      fusionPoseDeadbandRotationDeg = floatValue(p,"fusion.poseDeadbandRotationDeg",fusionPoseDeadbandRotationDeg,0.0f,8.0f);
      fusionTrajectoryMinStepM = floatValue(p,"fusion.trajectoryMinStepM",fusionTrajectoryMinStepM,0.001f,0.20f);
      fusionBootstrapFrames = intValue(p,"fusion.bootstrapFrames",fusionBootstrapFrames,0,12);
      fusionModelRefineMaxCorrectionM = floatValue(p,"fusion.keyframeModel.maxCorrectionM",fusionModelRefineMaxCorrectionM,0.01f,0.50f);
      fusionModelRefineMaxCorrectionDeg = floatValue(p,"fusion.keyframeModel.maxCorrectionDeg",fusionModelRefineMaxCorrectionDeg,1.0f,45.0f);
      fusionModelRefineMinOverlap = floatValue(p,"fusion.keyframeModel.minOverlap",fusionModelRefineMinOverlap,0.02f,0.90f);
      fusionModelRefineMaxRmsM = floatValue(p,"fusion.keyframeModel.maxRmsM",fusionModelRefineMaxRmsM,0.002f,0.080f);
      fusionModelRebaseTranslationM = floatValue(p,"fusion.keyframeModel.rebaseTranslationM",fusionModelRebaseTranslationM,0.0005f,0.05f);
      fusionModelRebaseRotationDeg = floatValue(p,"fusion.keyframeModel.rebaseRotationDeg",fusionModelRebaseRotationDeg,0.05f,8.0f);
      fusionArchiveGateEnabled = boolValue(p,"fusion.archiveGate.enabled",fusionArchiveGateEnabled);
      fusionArchiveWarmupKeyframes = intValue(p,"fusion.archiveGate.warmupKeyframes",fusionArchiveWarmupKeyframes,1,12);
      fusionArchiveReferenceFrames = intValue(p,"fusion.archiveGate.referenceFrames",fusionArchiveReferenceFrames,2,16);
      fusionArchiveRefineIterations = intValue(p,"fusion.archiveGate.refineIterations",fusionArchiveRefineIterations,3,20);
      fusionArchiveRefineDistanceM = floatValue(p,"fusion.archiveGate.refineDistanceM",fusionArchiveRefineDistanceM,0.010f,0.12f);
      fusionArchiveMinOverlap = floatValue(p,"fusion.archiveGate.minOverlap",fusionArchiveMinOverlap,0.05f,0.80f);
      fusionArchiveMaxRmsM = floatValue(p,"fusion.archiveGate.maxRmsM",fusionArchiveMaxRmsM,0.003f,0.05f);
      fusionArchiveMaxCorrectionM = floatValue(p,"fusion.archiveGate.maxCorrectionM",fusionArchiveMaxCorrectionM,0.005f,0.20f);
      fusionArchiveMaxCorrectionDeg = floatValue(p,"fusion.archiveGate.maxCorrectionDeg",fusionArchiveMaxCorrectionDeg,0.5f,25.0f);
      fusionArchiveRebaseTranslationM = floatValue(p,"fusion.archiveGate.rebaseTranslationM",fusionArchiveRebaseTranslationM,0.0005f,0.03f);
      fusionArchiveRebaseRotationDeg = floatValue(p,"fusion.archiveGate.rebaseRotationDeg",fusionArchiveRebaseRotationDeg,0.05f,5.0f);

      minimumTrackingPoints = intValue(p, "tracking.minimumPoints", minimumTrackingPoints, 50, 20000);

      minDepthM = floatValue(p, "depth.minM", minDepthM, 0.10f, 9.0f);
      maxDepthM = floatValue(p, "depth.maxM", maxDepthM, minDepthM + 0.10f, 10.0f);

      depthFx = floatValue(p, "calibration.depth.fx", depthFx, 100.0f, 2000.0f);
      depthFy = floatValue(p, "calibration.depth.fy", depthFy, 100.0f, 2000.0f);
      depthCx = floatValue(p, "calibration.depth.cx", depthCx, 0.0f, studio.services.scannerProtocol.WIDTH);

      depthCy = floatValue(p, "calibration.depth.cy", depthCy, 0.0f, studio.services.scannerProtocol.HEIGHT);

      depthScale = floatValue(p, "calibration.depth.scale", depthScale, 0.00001f, 0.10f);

      objectDepthBandM = floatValue(p, "target.bandM", objectDepthBandM, 0.03f, 2.0f);

      maxObjectDepthBandM = floatValue(p, "target.maxBandM", maxObjectDepthBandM, objectDepthBandM, 3.0f);

      depthTargetSmoothing = floatValue(p, "target.smoothing", depthTargetSmoothing, 0.01f, 1.0f);

      depthTargetStableToleranceM = floatValue(p, "target.stableToleranceM", depthTargetStableToleranceM, 0.01f, 1.0f);

      depthTargetMaxJumpM = floatValue(p, "target.maxJumpM", depthTargetMaxJumpM, 0.05f, 3.0f);

      depthTargetStableFrames = intValue(p, "target.stableFrames", depthTargetStableFrames, 1, 60);

      depthTargetLostFramesForReacquire = intValue(p, "target.reacquireFrames", depthTargetLostFramesForReacquire, 1, 120);
      depthTargetCaptureLostFrames = intValue(p, "target.captureLostFrames", depthTargetCaptureLostFrames, 3, 240);
      depthTargetCaptureMaxJumpM = floatValue(p, "target.captureMaxJumpM", depthTargetCaptureMaxJumpM, 0.05f, 1.50f);
      depthTargetCaptureSmoothing = floatValue(p, "target.captureSmoothing", depthTargetCaptureSmoothing, 0.01f, 0.50f);

      depthTargetMinSamples = intValue(p, "target.minimumSamples", depthTargetMinSamples, 16, 50000);

      depthTargetMinConfidence = floatValue(p, "target.minimumConfidence", depthTargetMinConfidence, 0.001f, 0.80f);

      depthHistogramBinMm = intValue(p, "depth.histogramBinMm", depthHistogramBinMm, 5, 200);

      depthRoiLeft = floatValue(p, "target.roi.left", depthRoiLeft, 0.0f, 0.90f);

      depthRoiRight = floatValue(p, "target.roi.right", depthRoiRight, depthRoiLeft + 0.05f, 1.0f);

      depthRoiTop = floatValue(p, "target.roi.top", depthRoiTop, 0.0f, 0.90f);
      depthRoiBottom = floatValue(p, "target.roi.bottom", depthRoiBottom, depthRoiTop + 0.05f, 1.0f);

      depthRoiSampleStep = intValue(p, "target.roi.sampleStep", depthRoiSampleStep, 1, 8);

      depthPreferredTargetWindowM = floatValue(p, "target.preferredWindowM", depthPreferredTargetWindowM, 0.05f, 3.0f);
      depthBandSpreadMultiplier = floatValue(p,"target.bandSpreadMultiplier",depthBandSpreadMultiplier,1.0f,3.0f);
      targetSegmentationMargin = floatValue(p,"target.segmentationMargin",targetSegmentationMargin,0.0f,0.30f);
      boundingBoxEnabled = boolValue(p,"tracking.boundingBox.enabled",boundingBoxEnabled);
      boundingBoxMarginM = floatValue(p,"tracking.boundingBox.marginM",boundingBoxMarginM,0.005f,0.30f);
      boundingBoxDepthMarginM = floatValue(p,"tracking.boundingBox.depthMarginM",boundingBoxDepthMarginM,0.005f,0.30f);
      boundingBoxBaseExtraM = floatValue(p,"tracking.boundingBox.baseExtraM",boundingBoxBaseExtraM,0.0f,0.30f);
      boundingBoxMinWidthM = floatValue(p,"tracking.boundingBox.minWidthM",boundingBoxMinWidthM,0.05f,2.0f);
      boundingBoxMinHeightM = floatValue(p,"tracking.boundingBox.minHeightM",boundingBoxMinHeightM,0.05f,2.0f);
      boundingBoxMinDepthM = floatValue(p,"tracking.boundingBox.minDepthM",boundingBoxMinDepthM,0.05f,2.0f);
      boundingBoxMaxWidthM = floatValue(p,"tracking.boundingBox.maxWidthM",boundingBoxMaxWidthM,boundingBoxMinWidthM,3.0f);
      boundingBoxMaxHeightM = floatValue(p,"tracking.boundingBox.maxHeightM",boundingBoxMaxHeightM,boundingBoxMinHeightM,3.0f);
      boundingBoxMaxDepthM = floatValue(p,"tracking.boundingBox.maxDepthM",boundingBoxMaxDepthM,boundingBoxMinDepthM,3.0f);
      boundingBoxCenterFollowAlpha = floatValue(p,"tracking.boundingBox.centerFollowAlpha",boundingBoxCenterFollowAlpha,0.0f,0.15f);
      boundingBoxMaxCenterCorrectionM = floatValue(p,"tracking.boundingBox.maxCenterCorrectionM",boundingBoxMaxCenterCorrectionM,0.0f,0.20f);
      boundingBoxMinPoints = intValue(p,"tracking.boundingBox.minPoints",boundingBoxMinPoints,40,10000);
      supportPlaneEnabled = boolValue(p,"tracking.supportPlane.enabled",supportPlaneEnabled);
      supportPlaneSampleStep = intValue(p,"tracking.supportPlane.sampleStep",supportPlaneSampleStep,2,16);
      supportPlaneIterations = intValue(p,"tracking.supportPlane.iterations",supportPlaneIterations,20,1000);
      supportPlaneMaxTiltDeg = floatValue(p,"tracking.supportPlane.maxTiltDeg",supportPlaneMaxTiltDeg,3.0f,60.0f);
      supportPlaneInlierM = floatValue(p,"tracking.supportPlane.inlierM",supportPlaneInlierM,0.002f,0.030f);
      supportPlaneMinInliers = intValue(p,"tracking.supportPlane.minInliers",supportPlaneMinInliers,50,100000);
      supportPlaneMinInlierRatio = floatValue(p,"tracking.supportPlane.minInlierRatio",supportPlaneMinInlierRatio,0.01f,0.90f);
      supportPlaneClearanceM = floatValue(p,"tracking.supportPlane.clearanceM",supportPlaneClearanceM,0.002f,0.050f);
      supportPlaneRefreshMs = intValue(p,"tracking.supportPlane.refreshMs",supportPlaneRefreshMs,100,10000);
      turntablePivotCalibrationEnabled = boolValue(p,"tracking.turntable.pivotCalibration.enabled",turntablePivotCalibrationEnabled);
      turntablePivotCalibrationDeg = floatValue(p,"tracking.turntable.pivotCalibrationDeg",turntablePivotCalibrationDeg,4.0f,150.0f);
      tsdfProjective = boolValue(p,"fusion.projectiveIntegration",tsdfProjective);
      fusionTargetVolume = boolValue(p,"fusion.targetVolume.enabled",fusionTargetVolume);
      fusionVolumeMinSideM = floatValue(p,"fusion.targetVolume.minSideM",fusionVolumeMinSideM,0.20f,4.0f);
      fusionVolumePadding = floatValue(p,"fusion.targetVolume.padding",fusionVolumePadding,1.0f,3.0f);
      fusionTrackingVolumePadding = floatValue(p,"fusion.targetVolume.trackingPadding",fusionTrackingVolumePadding,1.0f,4.0f);
      depthNoiseBaseM = floatValue(p,"depth.noiseBaseM",depthNoiseBaseM,0.0001f,0.02f);
      depthNoiseQuadM = floatValue(p,"depth.noiseQuadM",depthNoiseQuadM,0.0001f,0.02f);
      meshMarchingCubes = boolValue(p,"mesh.marchingCubes",meshMarchingCubes);
      depthTargetNearestModeFraction = floatValue(p,"target.nearestModeFraction",depthTargetNearestModeFraction,0.05f,1.0f);
      depthTargetPreferNearest = boolValue(p,"target.preferNearest",depthTargetPreferNearest);
      modelTrackingFinalGateM = floatValue(p,"fusion.modelTracking.finalGateM",modelTrackingFinalGateM,0.003f,0.080f);
      modelTrackingMaxTangentialM = floatValue(p,"fusion.modelTracking.maxTangentialM",modelTrackingMaxTangentialM,0.002f,0.080f);
      tsdfCarveMarginM = floatValue(p,"fusion.carveMarginM",tsdfCarveMarginM,0.0f,0.20f);
      turntableModelTracking = boolValue(p,"tracking.turntable.modelTracking.enabled",turntableModelTracking);
      turntablePlanarMotion = boolValue(p,"tracking.turntable.planarMotion",turntablePlanarMotion);
      turntableModelTrackingMaxRmsM = floatValue(p,"tracking.turntable.modelTracking.maxRmsM",turntableModelTrackingMaxRmsM,0.001f,0.030f);
      turntableModelTrackingMinOverlap = floatValue(p,"tracking.turntable.modelTracking.minOverlap",turntableModelTrackingMinOverlap,0.05f,0.95f);
      turntablePivotCalibrationToleranceM = floatValue(p,"tracking.turntable.pivotCalibrationToleranceM",turntablePivotCalibrationToleranceM,0.001f,0.050f);
      turntablePivotCalibrationMaxShiftM = floatValue(p,"tracking.turntable.pivotCalibrationMaxShiftM",turntablePivotCalibrationMaxShiftM,0.02f,0.50f);

      depthMinValidPixels = intValue(p, "depth.minimumValidPixels", depthMinValidPixels, 1, studio.services.scannerProtocol.WIDTH * studio.services.scannerProtocol.HEIGHT);

      depthMinValidRatio = floatValue(p, "depth.minimumValidRatio", depthMinValidRatio, 0.0001f, 1.0f);

      depthPlausibleMinMm = intValue(p, "depth.plausibleMinMm", depthPlausibleMinMm, 1, 9999);

      depthPlausibleMaxMm = intValue(p, "depth.plausibleMaxMm", depthPlausibleMaxMm, depthPlausibleMinMm + 1, 10000);

      streamStaleTimeoutMs = longValue(p, "transport.streamStaleMs", streamStaleTimeoutMs, 100, 30000);

      connectionStaleTimeoutMs = longValue(p, "transport.connectionStaleMs", connectionStaleTimeoutMs, streamStaleTimeoutMs, 60000);

      reconnectDelayMs = intValue(p, "transport.reconnectMs", reconnectDelayMs, 50, 5000);

      rgbdQueueFrames = intValue(p,"transport.rgbdQueueFrames",rgbdQueueFrames,4,120);

      rgbdSyncHistoryFrames = intValue(p,"transport.rgbdSyncHistoryFrames",rgbdSyncHistoryFrames,4,60);

      rgbdSyncMaxResidualMs = floatValue(p,"transport.rgbdSyncMaxResidualMs",rgbdSyncMaxResidualMs,1.0f,120.0f);

      rgbdSyncBootstrapMaxSkewMs = floatValue(p,"transport.rgbdSyncBootstrapMaxSkewMs",rgbdSyncBootstrapMaxSkewMs,rgbdSyncMaxResidualMs,500.0f);

      rgbdSyncOffsetAlpha = floatValue(p,"transport.rgbdSyncOffsetAlpha",rgbdSyncOffsetAlpha,0.001f,0.50f);

      captureDrainFramesPerDraw = intValue(p, "transport.drainFramesPerDraw", captureDrainFramesPerDraw, 1, 60);

      reconstructionQueueFrames = intValue(p, "fusion.queueFrames", reconstructionQueueFrames, 1, 120);

      reconstructionMaxFps = intValue(p, "fusion.maxFps", reconstructionMaxFps, 2, 30);
      reconstructionAdaptiveCadence = boolValue(p,"fusion.adaptiveCadence",reconstructionAdaptiveCadence);
      reconstructionTargetUtilization = floatValue(p,"fusion.targetUtilization",reconstructionTargetUtilization,0.35f,0.95f);
      reconstructionMaxIntervalMs = intValue(p,"fusion.maxAdaptiveIntervalMs",reconstructionMaxIntervalMs,50,1000);

      pointCloudSpatialFilter = boolValue(p, "cloud.spatialFilter", pointCloudSpatialFilter);

      pointCloudNeighborToleranceM = floatValue(p, "cloud.neighborToleranceM", pointCloudNeighborToleranceM, 0.005f, 1.0f);

      pointCloudMinimumConfidence = floatValue(p, "cloud.minimumConfidence", pointCloudMinimumConfidence, 0.01f, 1.0f);

      pointCloudEdgeSoftM = floatValue(p, "cloud.edgeSoftM", pointCloudEdgeSoftM, 0.001f, 0.10f);

      pointCloudEdgeRejectM = floatValue(p, "cloud.edgeRejectM", pointCloudEdgeRejectM, pointCloudEdgeSoftM, 0.25f);
      pointCloudSurfaceNoiseM = floatValue(p,"cloud.surfaceNoiseM",pointCloudSurfaceNoiseM,0.002f,0.08f);
      pointCloudMinimumSupport = floatValue(p,"cloud.minimumSupport",pointCloudMinimumSupport,0.20f,1.0f);
      pointCloudConnectedTarget = boolValue(p,"cloud.connectedTarget",pointCloudConnectedTarget);
      pointCloudComponentMinSamples = intValue(p,"cloud.componentMinSamples",pointCloudComponentMinSamples,12,20000);
      pointCloudComponentDepthLinkM = floatValue(p,"cloud.componentDepthLinkM",pointCloudComponentDepthLinkM,0.005f,0.20f);
      pointCloudComponentBorderPenalty = floatValue(p,"cloud.componentBorderPenalty",pointCloudComponentBorderPenalty,0.0f,0.95f);
      previewAutoFitZoomOutResponse = floatValue(p,"preview.autoFit.zoomOutResponse",previewAutoFitZoomOutResponse,0.01f,1.0f);
      previewAutoFitZoomInResponse = floatValue(p,"preview.autoFit.zoomInResponse",previewAutoFitZoomInResponse,0.001f,0.25f);
      previewAutoFitCenterResponse = floatValue(p,"preview.autoFit.centerResponse",previewAutoFitCenterResponse,0.001f,0.30f);
      previewAutoFitDeadband = floatValue(p,"preview.autoFit.deadband",previewAutoFitDeadband,0.0f,0.30f);
      previewAutoFitShrinkDelayFrames = intValue(p,"preview.autoFit.shrinkDelayFrames",previewAutoFitShrinkDelayFrames,0,240);

      volumeSize = intValue(p, "fusion.volumeSize", volumeSize, 48, 384);
      voxelSizeM = floatValue(p, "fusion.voxelSizeM", voxelSizeM, 0.001f, 0.05f);

      truncationM = floatValue(p, "fusion.truncationM", truncationM, voxelSizeM, 0.20f);

      meshMinWeight = intValue(p, "mesh.minimumWeight", meshMinWeight, 1, 255);
      previewMeshMinWeight = intValue(p, "preview.meshMinimumWeight", previewMeshMinWeight, 1, 255);
      previewMeshRefreshFrames = intValue(p, "preview.meshRefreshFrames", previewMeshRefreshFrames, 1, 120);
      previewMeshRefreshMs = intValue(p, "preview.meshRefreshMs", previewMeshRefreshMs, 50, 5000);
      previewMeshMaxTriangles = intValue(p, "preview.meshMaxTriangles", previewMeshMaxTriangles, 1000, 500000);
      previewPointVoxelM = floatValue(p,"preview.pointVoxelM",previewPointVoxelM,0.001f,0.020f);
      previewPointMaxPoints = intValue(p,"preview.pointMaxPoints",previewPointMaxPoints,5000,300000);
      previewPointDisplayMaxPoints = intValue(p,"preview.pointDisplayMaxPoints",previewPointDisplayMaxPoints,3000,150000);
      previewPointTransientMaxPoints = intValue(p,"preview.pointTransientMaxPoints",previewPointTransientMaxPoints,500,30000);
      previewPointRefreshMs = intValue(p,"preview.pointRefreshMs",previewPointRefreshMs,33,1000);
      icpIterations = intValue(p, "tracking.icpIterations", icpIterations, 1, 50);

      icpMinimumMatches = intValue(p, "tracking.icpMinimumMatches", icpMinimumMatches, 12, 5000);

      icpCellSizeM = floatValue(p, "tracking.icpCellSizeM", icpCellSizeM, 0.002f, 0.50f);

      icpMaxDistanceM = floatValue(p, "tracking.icpMaxDistanceM", icpMaxDistanceM, 0.005f, 1.0f);
      icpFinalDistanceM = floatValue(p,"tracking.icpFinalDistanceM",icpFinalDistanceM,0.003f,icpMaxDistanceM);

      icpMaxSamples = intValue(p, "tracking.icpMaxSamples", icpMaxSamples, 100, 50000);

      icpGoodRmsM = floatValue(p, "tracking.icpGoodRmsM", icpGoodRmsM, 0.001f, 0.50f);

      icpReferenceFrames = intValue(p, "tracking.icpReferenceFrames", icpReferenceFrames, 1, 12);

      icpReferenceMaxPoints = intValue(p, "tracking.icpReferenceMaxPoints", icpReferenceMaxPoints, 500, 60000);

      icpTrimFraction = floatValue(p, "tracking.icpTrimFraction", icpTrimFraction, 0.50f, 1.0f);
      icpMinimumOverlap = floatValue(p,"tracking.icpMinimumOverlap",icpMinimumOverlap,0.05f,0.95f);
      icpRobustK = floatValue(p,"tracking.icpRobustK",icpRobustK,0.20f,1.0f);
      icpReciprocal = boolValue(p,"tracking.icpReciprocal",icpReciprocal);
      icpReciprocalFinalIterations = intValue(p,"tracking.icpReciprocalFinalIterations",icpReciprocalFinalIterations,0,20);
      icpReciprocalToleranceM = floatValue(p,"tracking.icpReciprocalToleranceM",icpReciprocalToleranceM,0.002f,0.10f);
      turntableSeedSearchEveryFrames = intValue(p,"tracking.turntable.seedSearchEveryFrames",turntableSeedSearchEveryFrames,1,8);
      icpMaxTranslationStepM = floatValue(p,"tracking.maxTranslationStepM",icpMaxTranslationStepM,0.005f,0.75f);
      icpMaxRotationStepDeg = floatValue(p,"tracking.maxRotationStepDeg",icpMaxRotationStepDeg,1.0f,90.0f);
      turntableTracking = boolValue(p,"tracking.turntable.enabled",turntableTracking);
      turntableMaxSeedYawDeg = floatValue(p,"tracking.turntable.maxSeedYawDeg",turntableMaxSeedYawDeg,4.0f,90.0f);
      turntableSeedSearchWindowDeg = floatValue(p,"tracking.turntable.seedSearchWindowDeg",turntableSeedSearchWindowDeg,2.0f,90.0f);
      turntableSeedMaxSamples = intValue(p,"tracking.turntable.seedMaxSamples",turntableSeedMaxSamples,200,5000);
      turntableCoarseStepDeg = floatValue(p,"tracking.turntable.coarseStepDeg",turntableCoarseStepDeg,1.0f,20.0f);
      turntableFineStepDeg = floatValue(p,"tracking.turntable.fineStepDeg",turntableFineStepDeg,0.25f,8.0f);
      turntableMotionAlpha = floatValue(p,"tracking.turntable.motionAlpha",turntableMotionAlpha,0.0f,0.95f);
      turntablePredictionWeight = floatValue(p,"tracking.turntable.predictionWeight",turntablePredictionWeight,0.0f,1.5f);
      turntableSeedMinGain = floatValue(p,"tracking.turntable.seedMinGain",turntableSeedMinGain,0.0f,0.30f);
      turntableSeedMinimumConfidence = floatValue(p,"tracking.turntable.seedMinimumConfidence",turntableSeedMinimumConfidence,0.0f,1.0f);
      turntableSeedPoseAuthority = floatValue(p,"tracking.turntable.seedPoseAuthority",turntableSeedPoseAuthority,0.0f,1.0f);
      turntableSeedMinTrackedYawDeg = floatValue(p,"tracking.turntable.seedMinTrackedYawDeg",turntableSeedMinTrackedYawDeg,0.0f,5.0f);
      turntableVelocityClampDeg = floatValue(p,"tracking.turntable.velocityClampDeg",turntableVelocityClampDeg,1.0f,45.0f);
      turntablePivotAlpha = floatValue(p,"tracking.turntable.pivotAlpha",turntablePivotAlpha,0.0f,0.25f);
      turntableConstrainedEvaluationM = floatValue(p,"tracking.turntable.evaluationDistanceM",turntableConstrainedEvaluationM,0.010f,0.12f);
      turntablePoseConstraint = boolValue(p,"tracking.turntable.poseConstraint",turntablePoseConstraint);
      turntableModelRefinement = boolValue(p,"tracking.turntable.modelRefinement.enabled",turntableModelRefinement);
      turntableModelRefineEveryFrames = intValue(p,"tracking.turntable.modelRefinement.everyFrames",turntableModelRefineEveryFrames,1,12);
      turntableModelRefineMaxCorrectionM = floatValue(p,"tracking.turntable.modelRefinement.maxCorrectionM",turntableModelRefineMaxCorrectionM,0.01f,0.40f);
      turntableModelRefineMaxCorrectionDeg = floatValue(p,"tracking.turntable.modelRefinement.maxCorrectionDeg",turntableModelRefineMaxCorrectionDeg,1.0f,45.0f);
      turntableModelRefineMinOverlap = floatValue(p,"tracking.turntable.modelRefinement.minOverlap",turntableModelRefineMinOverlap,0.02f,0.80f);
      turntableModelRefineMaxRmsM = floatValue(p,"tracking.turntable.modelRefinement.maxRmsM",turntableModelRefineMaxRmsM,0.003f,0.08f);
      turntableLoopClosure = boolValue(p,"tracking.turntable.loopClosure.enabled",turntableLoopClosure);
      turntableLoopClosureStartDeg = floatValue(p,"tracking.turntable.loopClosure.startDeg",turntableLoopClosureStartDeg,240.0f,359.0f);
      turntableLoopClosureEveryFrames = intValue(p,"tracking.turntable.loopClosure.everyFrames",turntableLoopClosureEveryFrames,1,20);
      turntableLoopClosureDistanceM = floatValue(p,"tracking.turntable.loopClosure.distanceM",turntableLoopClosureDistanceM,0.015f,0.12f);
      turntableLoopClosureMaxRmsM = floatValue(p,"tracking.turntable.loopClosure.maxRmsM",turntableLoopClosureMaxRmsM,0.004f,0.06f);
      turntableLoopClosureMaxCorrectionM = floatValue(p,"tracking.turntable.loopClosure.maxCorrectionM",turntableLoopClosureMaxCorrectionM,0.01f,0.30f);
      turntableLoopClosureMaxCorrectionDeg = floatValue(p,"tracking.turntable.loopClosure.maxCorrectionDeg",turntableLoopClosureMaxCorrectionDeg,1.0f,35.0f);
      turntableConstraintScoreSlack = floatValue(p,"tracking.turntable.constraintScoreSlack",turntableConstraintScoreSlack,0.0f,0.60f);
      turntableConstraintTranslationM = floatValue(p,"tracking.turntable.constraintTranslationM",turntableConstraintTranslationM,0.0f,0.05f);
      turntableConstraintTranslationAuthority = floatValue(p,"tracking.turntable.constraintTranslationAuthority",turntableConstraintTranslationAuthority,0.0f,1.0f);
      turntableIntegrationMinYawDeg = floatValue(p,"tracking.turntable.integrationMinYawDeg",turntableIntegrationMinYawDeg,0.05f,8.0f);
      turntablePivotConsensusSamples = intValue(p,"tracking.turntable.pivotConsensusSamples",turntablePivotConsensusSamples,3,15);
      turntableVerticalResidualWeight = floatValue(p,"tracking.turntable.verticalResidualWeight",turntableVerticalResidualWeight,0.02f,1.0f);
      colorIcpEnabled = boolValue(p,"tracking.colorIcp.enabled",colorIcpEnabled);
      colorIcpWeight = floatValue(p,"tracking.colorIcp.weight",colorIcpWeight,0.0f,0.80f);
      colorIcpRejectDistance = floatValue(p,"tracking.colorIcp.rejectDistance",colorIcpRejectDistance,0.10f,1.73f);
      colorIcpMinimumWeight = floatValue(p,"tracking.colorIcp.minimumWeight",colorIcpMinimumWeight,0.05f,1.0f);
      integrationMinTranslationM = floatValue(p,"fusion.minimumTranslationM",integrationMinTranslationM,0.0f,0.05f);
      integrationMinRotationDeg = floatValue(p,"fusion.minimumRotationDeg",integrationMinRotationDeg,0.0f,10.0f);
      integrationMaxIdleFrames = intValue(p,"fusion.maximumIdleFrames",integrationMaxIdleFrames,1,60);
      scanCoverageBins = intValue(p,"scan.coverageBins",scanCoverageBins,24,360);
      scanCoverageRequired = floatValue(p,"scan.coverageRequired",scanCoverageRequired,0.50f,1.0f);
      volumeAutoFit = boolValue(p,"fusion.autoFit",volumeAutoFit);
      volumeAutoFitPadding = floatValue(p,"fusion.autoFitPadding",volumeAutoFitPadding,1.0f,2.0f);
      volumeMaxVoxelSizeM = floatValue(p,"fusion.maxVoxelSizeM",volumeMaxVoxelSizeM,voxelSizeM,0.03f);

      hqEnabled = boolValue(p,"quality.enabled",hqEnabled);
      hqMaxKeyframes = intValue(p,"quality.keyframes.max",hqMaxKeyframes,12,600);
      hqFinalizeMaxKeyframes = intValue(p,"quality.finalizeMaxKeyframes",hqFinalizeMaxKeyframes,12,hqMaxKeyframes);

      hqKeyframeMinRotationDeg = floatValue(p,"quality.keyframes.minRotationDeg",hqKeyframeMinRotationDeg,0.1f,30.0f);

      hqKeyframeMinTranslationM = floatValue(p,"quality.keyframes.minTranslationM",hqKeyframeMinTranslationM,0.0005f,0.20f);

      hqMinimumKeyframes = intValue(p,"quality.keyframes.minimum",hqMinimumKeyframes,3,hqMaxKeyframes);

      hqIntegrationStep = intValue(p,"quality.integrationStep",hqIntegrationStep,1,4);

      hqVolumeSize = intValue(p,"quality.volumeSize",hqVolumeSize,128,384);
      hqVoxelSizeM = floatValue(p,"quality.voxelSizeM",hqVoxelSizeM,0.001f,0.010f);

      hqTruncationM = floatValue(p,"quality.truncationM",hqTruncationM,hqVoxelSizeM*2.0f,0.050f);

      hqMeshMinWeight = intValue(p,"quality.meshMinimumWeight",hqMeshMinWeight,1,255);

      hqIcpIterations = intValue(p,"quality.icpIterations",hqIcpIterations,2,40);

      hqIcpMaxSamples = intValue(p,"quality.icpMaxSamples",hqIcpMaxSamples,1000,50000);

      hqIcpMinimumMatches = intValue(p,"quality.icpMinimumMatches",hqIcpMinimumMatches,30,10000);

      hqIcpMaxDistanceM = floatValue(p,"quality.icpMaxDistanceM",hqIcpMaxDistanceM,0.003f,0.15f);

      hqIcpTrimFraction = floatValue(p,"quality.icpTrimFraction",hqIcpTrimFraction,0.40f,1.0f);

      hqIcpGoodRmsM = floatValue(p,"quality.icpGoodRmsM",hqIcpGoodRmsM,0.001f,0.10f);
      hqGlobalRecovery = boolValue(p,"quality.globalRecovery.enabled",hqGlobalRecovery);
      hqGlobalRecoveryPasses = intValue(p,"quality.globalRecovery.passes",hqGlobalRecoveryPasses,1,8);
      hqGlobalRecoveryNeighborFrames = intValue(p,"quality.globalRecovery.neighborFrames",hqGlobalRecoveryNeighborFrames,1,12);
      hqGlobalRecoveryCoarseDistanceM = floatValue(p,"quality.globalRecovery.coarseDistanceM",hqGlobalRecoveryCoarseDistanceM,0.015f,0.20f);
      hqGlobalRecoveryFineDistanceM = floatValue(p,"quality.globalRecovery.fineDistanceM",hqGlobalRecoveryFineDistanceM,0.005f,hqGlobalRecoveryCoarseDistanceM);
      hqGlobalRecoveryMaxTranslationM = floatValue(p,"quality.globalRecovery.maxTranslationM",hqGlobalRecoveryMaxTranslationM,0.02f,0.40f);
      hqGlobalRecoveryMaxRotationDeg = floatValue(p,"quality.globalRecovery.maxRotationDeg",hqGlobalRecoveryMaxRotationDeg,5.0f,90.0f);
      hqGlobalRecoveryMinSupport = floatValue(p,"quality.globalRecovery.minSupport",hqGlobalRecoveryMinSupport,0.05f,0.90f);
      hqGlobalRecoveryMaxRmsM = floatValue(p,"quality.globalRecovery.maxRmsM",hqGlobalRecoveryMaxRmsM,0.003f,0.08f);

      hqLoopClosure = boolValue(p,"quality.loopClosure",hqLoopClosure);
      hqLoopClosureMaxRmsM = floatValue(p,"quality.loopClosureMaxRmsM",hqLoopClosureMaxRmsM,0.001f,0.10f);
      hqTurntableConsensus = boolValue(p,"quality.turntableConsensus.enabled",hqTurntableConsensus);
      hqTurntableAxisAuthority = floatValue(p,"quality.turntableConsensus.axisAuthority",hqTurntableAxisAuthority,0.0f,0.98f);
      hqTurntableRescueMinSupport = floatValue(p,"quality.turntableConsensus.rescueMinSupport",hqTurntableRescueMinSupport,0.10f,0.90f);
      hqTurntableRescueMaxRmsM = floatValue(p,"quality.turntableConsensus.rescueMaxRmsM",hqTurntableRescueMaxRmsM,0.002f,0.05f);
      hqTurntableRecoveredFramePenalty = floatValue(p,"quality.turntableConsensus.recoveredFramePenalty",hqTurntableRecoveredFramePenalty,0.05f,1.0f);

      hqDepthFilterRadius = intValue(p,"quality.depthFilterRadius",hqDepthFilterRadius,1,3);

      hqDepthEdgeToleranceM = floatValue(p,"quality.depthEdgeToleranceM",hqDepthEdgeToleranceM,0.003f,0.10f);

      hqHoleFillMinimumNeighbors = intValue(p,"quality.holeFillMinimumNeighbors",hqHoleFillMinimumNeighbors,3,48);

      hqDistanceWeightedTsdf = boolValue(p,"quality.distanceWeightedTsdf",hqDistanceWeightedTsdf);
      hqTsdfMinimumPointConfidence = floatValue(p,"quality.tsdf.minimumPointConfidence",hqTsdfMinimumPointConfidence,0.05f,0.95f);
      hqTsdfConfidenceGamma = floatValue(p,"quality.tsdf.confidenceGamma",hqTsdfConfidenceGamma,0.5f,4.0f);

      hqDepthSuperResolution = boolValue(p,"quality.depthSuperResolution.enabled",hqDepthSuperResolution);

      hqDepthSrScale = intValue(p,"quality.depthSuperResolution.scale",hqDepthSrScale,1,3);

      hqDepthSrWindowFrames = intValue(p,"quality.depthSuperResolution.windowFrames",hqDepthSrWindowFrames,1,11);

      if((hqDepthSrWindowFrames&1)==0)hqDepthSrWindowFrames++;
      hqDepthSrAnchorStride = intValue(p,"quality.depthSuperResolution.anchorStride",hqDepthSrAnchorStride,1,8);

      hqDepthSrMaxRotationDeg = floatValue(p,"quality.depthSuperResolution.maxRotationDeg",hqDepthSrMaxRotationDeg,0.1f,20.0f);

      hqDepthSrMaxTranslationM = floatValue(p,"quality.depthSuperResolution.maxTranslationM",hqDepthSrMaxTranslationM,0.001f,0.15f);

      hqDepthSrOcclusionToleranceM = floatValue(p,"quality.depthSuperResolution.occlusionToleranceM",hqDepthSrOcclusionToleranceM,0.002f,0.08f);

      hqDepthSrOutlierToleranceM = floatValue(p,"quality.depthSuperResolution.outlierToleranceM",hqDepthSrOutlierToleranceM,0.001f,hqDepthSrOcclusionToleranceM);

      hqDepthSrMinimumViews = intValue(p,"quality.depthSuperResolution.minimumViews",hqDepthSrMinimumViews,1,hqDepthSrWindowFrames);

      hqDepthSrMaxPoints = intValue(p,"quality.depthSuperResolution.maxPoints",hqDepthSrMaxPoints,50000,1200000);

      hqMeshPolishIterations = intValue(p,"quality.meshPolishIterations",hqMeshPolishIterations,0,8);

      hqMeshPolishLambda = floatValue(p,"quality.meshPolishLambda",hqMeshPolishLambda,0.01f,0.60f);

      hqMeshPolishMu = floatValue(p,"quality.meshPolishMu",hqMeshPolishMu,-0.60f,-0.01f);

      calibrationEnabled = boolValue(p,"calibration.depthCorrection.enabled",calibrationEnabled);

      calibrationStations = intValue(p,"calibration.depthCorrection.stations",calibrationStations,3,12);

      calibrationFramesPerStation = intValue(p,"calibration.depthCorrection.framesPerStation",calibrationFramesPerStation,3,60);

      calibrationMinimumStationsPerPixel = intValue(p,"calibration.depthCorrection.minimumStationsPerPixel",calibrationMinimumStationsPerPixel,2,calibrationStations);

      calibrationDistanceSeparationM = floatValue(p,"calibration.depthCorrection.distanceSeparationM",calibrationDistanceSeparationM,0.05f,0.60f);

      calibrationStabilityToleranceM = floatValue(p,"calibration.depthCorrection.stabilityToleranceM",calibrationStabilityToleranceM,0.003f,0.10f);

      calibrationPlaneResidualMaxM = floatValue(p,"calibration.depthCorrection.planeResidualMaxM",calibrationPlaneResidualMaxM,0.005f,0.10f);

      calibrationSlopeMin = floatValue(p,"calibration.depthCorrection.slopeMin",calibrationSlopeMin,0.70f,1.0f);

      calibrationSlopeMax = floatValue(p,"calibration.depthCorrection.slopeMax",calibrationSlopeMax,1.0f,1.30f);

      calibrationOffsetMaxM = floatValue(p,"calibration.depthCorrection.offsetMaxM",calibrationOffsetMaxM,0.005f,0.20f);

      calibrationNoiseFloorM = floatValue(p,"calibration.depthCorrection.noiseFloorM",calibrationNoiseFloorM,0.0002f,0.02f);

      calibrationNoiseCeilingM = floatValue(p,"calibration.depthCorrection.noiseCeilingM",calibrationNoiseCeilingM,calibrationNoiseFloorM,0.10f);
      calibrationTrimFraction = floatValue(p,"calibration.depthCorrection.trimFraction",calibrationTrimFraction,0.0f,0.40f);
      calibrationFlyingPixelSigma = floatValue(p,"calibration.depthCorrection.flyingPixelSigma",calibrationFlyingPixelSigma,2.0f,50.0f);
      calibrationGridX = intValue(p,"calibration.depthCorrection.gridX",calibrationGridX,4,160);
      calibrationGridY = intValue(p,"calibration.depthCorrection.gridY",calibrationGridY,3,120);
      calibrationDepthBins = intValue(p,"calibration.depthCorrection.depthBins",calibrationDepthBins,2,24);
      calibrationRegularization = floatValue(p,"calibration.depthCorrection.regularization",calibrationRegularization,0.0f,1000.0f);
      calibrationReferenceMatchTolerance = floatValue(p,"calibration.depthCorrection.referenceMatchTolerance",calibrationReferenceMatchTolerance,0.01f,0.50f);
      calibrationReferenceMaxScaleError = floatValue(p,"calibration.depthCorrection.referenceMaxScaleError",calibrationReferenceMaxScaleError,0.005f,0.30f);

      scanFullTurnDeg = floatValue(p, "scan.fullTurnDeg", scanFullTurnDeg, 90.0f, 720.0f);

      scanCompleteDeg = floatValue(p, "scan.completeDeg", scanCompleteDeg, 30.0f, scanFullTurnDeg);

      scanRotationDeadbandDeg = floatValue(p, "scan.rotationDeadbandDeg", scanRotationDeadbandDeg, 0.0f, 10.0f);

      scanRotationMaxStepDeg = floatValue(p, "scan.rotationMaxStepDeg", scanRotationMaxStepDeg, 1.0f, 90.0f);

      scanDirectionLockDeg = floatValue(p, "scan.directionLockDeg", scanDirectionLockDeg, 0.1f, 45.0f);
          scanTurnFilterAlpha = floatValue(p,"scan.turnFilterAlpha",scanTurnFilterAlpha,0.05f,1.0f);
      scanReverseJitterDeg = floatValue(p,"scan.reverseJitterDeg",scanReverseJitterDeg,0.0f,10.0f);
      scanReverseCommitDeg = floatValue(p,"scan.reverseCommitDeg",scanReverseCommitDeg,scanReverseJitterDeg,30.0f);
      scanDirectionRelockDeg = floatValue(p,"scan.directionRelockDeg",scanDirectionRelockDeg,scanReverseCommitDeg,90.0f);


      scanMaxSensorTiltDriftDeg = floatValue(p, "scan.maxSensorTiltDriftDeg", scanMaxSensorTiltDriftDeg, 0.5f, 45.0f);

      autoPauseOnFullTurn = boolValue(p, "scan.autoPauseOnFullTurn", autoPauseOnFullTurn);

      meshCleanupMaxEdgeM = floatValue(p, "mesh.cleanupMaxEdgeM", meshCleanupMaxEdgeM, voxelSizeM, 2.0f);

      meshCleanupMinAreaM2 = floatValue(p, "mesh.cleanupMinAreaM2", meshCleanupMinAreaM2, 0.000000001f, 0.01f);

      meshWeldToleranceM = floatValue(p, "mesh.weldToleranceM", meshWeldToleranceM, 0.00001f, 0.05f);

      meshSmoothIterations = intValue(p, "mesh.smoothIterations", meshSmoothIterations, 0, 100);

      meshSmoothLambda = floatValue(p, "mesh.smoothLambda", meshSmoothLambda, 0.01f, 1.0f);

      meshPolishIterations = intValue(p, "mesh.polishIterations", meshPolishIterations, 0, 20);

      meshPolishLambda = floatValue(p, "mesh.polishLambda", meshPolishLambda, 0.01f, 0.95f);

      meshPolishMu = floatValue(p, "mesh.polishMu", meshPolishMu, -0.95f, -0.01f);
      meshHoleFillEnabled = boolValue(p, "mesh.holeFill.enabled", meshHoleFillEnabled);
      meshHoleFillMaxEdges = intValue(p, "mesh.holeFill.maxEdges", meshHoleFillMaxEdges, 3, 128);
      meshHoleFillMaxDiameterM = floatValue(p, "mesh.holeFill.maxDiameterM", meshHoleFillMaxDiameterM, 0.001f, 0.25f);
      meshHoleFillMaxPerimeterM = floatValue(p, "mesh.holeFill.maxPerimeterM", meshHoleFillMaxPerimeterM, 0.003f, 1.0f);

      meshMinimumComponentTriangles = intValue(p, "mesh.minimumComponentTriangles", meshMinimumComponentTriangles, 1, 1000000);

      meshMinimumComponentRatio = floatValue(p, "mesh.minimumComponentRatio", meshMinimumComponentRatio, 0.0f, 0.25f);

      meshColorEnabled = boolValue(p, "mesh.rgb.enabled", meshColorEnabled);
      rgbFx = floatValue(p, "calibration.rgb.fx", rgbFx, 100.0f, 2000.0f);
      rgbFy = floatValue(p, "calibration.rgb.fy", rgbFy, 100.0f, 2000.0f);
      rgbCx = floatValue(p, "calibration.rgb.cx", rgbCx, -1000.0f, 2000.0f);
      rgbCy = floatValue(p, "calibration.rgb.cy", rgbCy, -1000.0f, 2000.0f);
      depthK1=floatValue(p,"calibration.depth.k1",depthK1,-5.0f,5.0f); depthK2=floatValue(p,"calibration.depth.k2",depthK2,-5.0f,5.0f);

      depthP1=floatValue(p,"calibration.depth.p1",depthP1,-1.0f,1.0f); depthP2=floatValue(p,"calibration.depth.p2",depthP2,-1.0f,1.0f);
     depthK3=floatValue(p,"calibration.depth.k3",depthK3,-10.0f,10.0f);
      depthPixelCenter=floatValue(p,"calibration.depth.pixelCenter",depthPixelCenter,0.0f,1.0f);
      depthShiftU=floatValue(p,"calibration.depthShiftU",depthShiftU,-16.0f,16.0f);depthShiftV=floatValue(p,"calibration.depthShiftV",depthShiftV,-16.0f,16.0f);
      rgbK1=floatValue(p,"calibration.rgb.k1",rgbK1,-5.0f,5.0f); rgbK2=floatValue(p,"calibration.rgb.k2",rgbK2,-5.0f,5.0f);

      rgbP1=floatValue(p,"calibration.rgb.p1",rgbP1,-1.0f,1.0f); rgbP2=floatValue(p,"calibration.rgb.p2",rgbP2,-1.0f,1.0f);
     rgbK3=floatValue(p,"calibration.rgb.k3",rgbK3,-10.0f,10.0f);
      regR00=floatValue(p,"calibration.depthToRgb.r00",regR00,-2.0f,2.0f); regR01=floatValue(p,"calibration.depthToRgb.r01",regR01,-2.0f,2.0f);
     regR02=floatValue(p,"calibration.depthToRgb.r02",regR02,-2.0f,2.0f);
      regR10=floatValue(p,"calibration.depthToRgb.r10",regR10,-2.0f,2.0f); regR11=floatValue(p,"calibration.depthToRgb.r11",regR11,-2.0f,2.0f);
     regR12=floatValue(p,"calibration.depthToRgb.r12",regR12,-2.0f,2.0f);
      regR20=floatValue(p,"calibration.depthToRgb.r20",regR20,-2.0f,2.0f); regR21=floatValue(p,"calibration.depthToRgb.r21",regR21,-2.0f,2.0f);
     regR22=floatValue(p,"calibration.depthToRgb.r22",regR22,-2.0f,2.0f);
      regTx=floatValue(p,"calibration.depthToRgb.tx",regTx,-0.20f,0.20f); regTy=floatValue(p,"calibration.depthToRgb.ty",regTy,-0.20f,0.20f);
     regTz=floatValue(p,"calibration.depthToRgb.tz",regTz,-0.20f,0.20f);
      colorRegistrationOffsetX = floatValue(p, "mesh.rgb.offsetX", colorRegistrationOffsetX, -32.0f, 32.0f);

      colorRegistrationOffsetY = floatValue(p, "mesh.rgb.offsetY", colorRegistrationOffsetY, -32.0f, 32.0f);

      rgbMaxSyncSkewMs=floatValue(p,"mesh.rgb.maxSyncSkewMs",rgbMaxSyncSkewMs,1.0f,200.0f);

      rgbOcclusionFilter=boolValue(p,"mesh.rgb.occlusionFilter",rgbOcclusionFilter);

      rgbOcclusionToleranceM=floatValue(p,"mesh.rgb.occlusionToleranceM",rgbOcclusionToleranceM,0.001f,0.25f);

      rgbAutoRefine=boolValue(p,"mesh.rgb.autoRefine",rgbAutoRefine);
      rgbRefineEveryFrames=intValue(p,"mesh.rgb.refineEveryFrames",rgbRefineEveryFrames,1,120);

      rgbRefineSearchPx=intValue(p,"mesh.rgb.refineSearchPx",rgbRefineSearchPx,0,16);

      rgbRefineSampleStep=intValue(p,"mesh.rgb.refineSampleStep",rgbRefineSampleStep,2,32);

      rgbRefineEdgeThresholdMm=intValue(p,"mesh.rgb.refineEdgeThresholdMm",rgbRefineEdgeThresholdMm,5,1000);

      rgbRefineMinimumEdges=intValue(p,"mesh.rgb.refineMinimumEdges",rgbRefineMinimumEdges,8,10000);

      rgbRefineAlpha=floatValue(p,"mesh.rgb.refineAlpha",rgbRefineAlpha,0.01f,1.0f);

      rgbRefineMaxOffsetPx=floatValue(p,"mesh.rgb.refineMaxOffsetPx",rgbRefineMaxOffsetPx,0.0f,32.0f);

      rgbExposureLowLuma=intValue(p,"mesh.rgb.exposureLowLuma",rgbExposureLowLuma,1,127);

      rgbExposureHighLuma=intValue(p,"mesh.rgb.exposureHighLuma",rgbExposureHighLuma,128,254);

      rgbTemporalColorWeightMax=intValue(p,"mesh.rgb.temporalColorWeightMax",rgbTemporalColorWeightMax,1,32);

      rgbHqHistoryFrames=intValue(p,"mesh.rgb.hq.historyFrames",rgbHqHistoryFrames,2,24);

      rgbHqMaxSyncSkewMs=floatValue(p,"mesh.rgb.hq.maxSyncSkewMs",rgbHqMaxSyncSkewMs,10.0f,250.0f);

      rgbHqMinimumFrameQuality=floatValue(p,"mesh.rgb.hq.minimumFrameQuality",rgbHqMinimumFrameQuality,0.0f,1.0f);

      rgbPhotometricNormalize=boolValue(p,"mesh.rgb.hq.photometricNormalize",rgbPhotometricNormalize);

      rgbPhotometricGainMin=floatValue(p,"mesh.rgb.hq.gainMin",rgbPhotometricGainMin,0.30f,1.0f);

      rgbPhotometricGainMax=floatValue(p,"mesh.rgb.hq.gainMax",rgbPhotometricGainMax,1.0f,3.0f);

      rgbHqSharpenAmount=floatValue(p,"mesh.rgb.hq.sharpenAmount",rgbHqSharpenAmount,0.0f,0.60f);




      exportBaseName = textValue(p, "export.baseName", exportBaseName);
      exportWeldToleranceM = floatValue(p, "export.weldToleranceM", exportWeldToleranceM, 0.00001f, 0.05f);

      exportMaxWeldToleranceM = floatValue(p, "export.maxWeldToleranceM", exportMaxWeldToleranceM, exportWeldToleranceM, 0.10f);

      exportMaxTriangles = intValue(p, "export.maxTriangles", exportMaxTriangles, 1000, 5000000);



  }

  String textValue(Properties p,String key,String defaultValue){return studio.services.configRules.text(p,key,defaultValue);
    }
  boolean boolValue(Properties p,String key,boolean defaultValue){return studio.services.configRules.flag(p,key,defaultValue);
    }
  int intValue(Properties p,String key,int defaultValue,int lo,int hi){return studio.services.configRules.integer(p,key,defaultValue,lo,hi);
    }
  long longValue(Properties p,String key,long defaultValue,long lo,long hi){return studio.services.configRules.longNumber(p,key,defaultValue,lo,hi);
    }
  float floatValue(Properties p,String key,float defaultValue,float lo,float hi){return studio.services.configRules.decimal(p,key,defaultValue,lo,hi);
    }
}
