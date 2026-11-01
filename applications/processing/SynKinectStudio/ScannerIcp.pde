// ===== SynKinect Studio / 3D Scanner / IcpTracker.pde =====
class IcpTracker {
  AppConfig cfg;
  RigidTransform pose = new RigidTransform();
  PointCloud reference = null;
  final ArrayDeque<PointCloud> referenceWindow=new ArrayDeque<PointCloud>();
  // Separate histories: tracking follows valid motion continuously; fusion
  // contains only geometry committed to TSDF for anti-ghosting validation.
  final ArrayDeque<PointCloud> fusionReferenceWindow=new ArrayDeque<PointCloud>();
  // Sparse accepted camera poses used only for loss recovery. This mirrors the
  // Camera Pose Finder behavior shown by Kinect Fusion without taxing every frame.
  final ArrayDeque<RigidTransform> fusionPoseFinderPoses=new ArrayDeque<RigidTransform>();
  RigidTransform fusionPoseFinderLastPose=null;
  boolean lastFusionRelocalized=false;
  boolean trackingGood = false;
  float rms = Float.POSITIVE_INFINITY;
  int matches = 0;
  PVector gravityReference = null;
  boolean motionPriorUsed = false;
  final ArrayList<PVector> matchSrc=new ArrayList<PVector>();
  final ArrayList<PVector> matchDst=new ArrayList<PVector>();
  final ArrayList<PVector> candidateSrc=new ArrayList<PVector>();
  final ArrayList<PVector> candidateDst=new ArrayList<PVector>();
  final ArrayList<Float> candidateD2=new ArrayList<Float>();
  final ArrayList<Float> candidateConfidence=new ArrayList<Float>();
  final ArrayList<Float> matchWeights=new ArrayList<Float>();
  final ArrayList<PVector> matchPool=new ArrayList<PVector>();
  final ArrayList<PVector> iterationSource=new ArrayList<PVector>();
  final ArrayList<Integer> iterationColor=new ArrayList<Integer>();
  final ArrayList<Float> iterationConfidence=new ArrayList<Float>();
  final QuaternionFit fitter=new QuaternionFit();
  PVector turntablePivotWorld=null;
  final ArrayDeque<PVector> turntablePivotCandidates=new ArrayDeque<PVector>();
  // The physical rotation axis is not known when a scan starts: the visible
  // surface centroid lies in front of it. Until the pivot is calibrated from the
  // observed rigid motion, Turntable tracking stays unconstrained 6-DoF so the
  // true rotation can be represented at all; afterwards it is projected to 1-DoF.
  boolean turntablePivotCalibrated=false,turntablePivotSeeded=false;
  final ArrayList<PVector> turntablePivotCalibrationSamples=new ArrayList<PVector>();
  PVector turntableSupportAxis=null;
  RigidTransform fusionAnchorPose=null;
  float turntableYawVelocityDeg=0.0f;
  float turntableSeedConfidence=0.0f;
  float turntableSeedYawDeg=0.0f;
  float lastTrackedYawStepDeg=0.0f;
  float overlap=0.0f;
  int trackingFrameCounter=0,referenceHoldFrames=0,referenceRevision=0,cachedReferenceRevision=-1;
  RigidTransform lastReferencePose=null;
  SpatialHash cachedReferenceHash=null;HashMap<PVector,Integer> cachedReferenceColors=null;
  PointCloud turntableLoopAnchorWorld=null;
  int turntableModelRefineCounter=0,turntableLoopClosureCounter=0;
  boolean lastFusionModelRefinementGood=true;
  boolean lastFusionModelTracking=false;
  final RobustIcpRefiner turntableLoopRefiner;
  final RobustIcpRefiner fusionArchiveRefiner;

  IcpTracker(AppConfig cfg){ this.cfg=cfg;turntableLoopRefiner=new RobustIcpRefiner(cfg);fusionArchiveRefiner=new RobustIcpRefiner(cfg); }

  void reset(){ pose.setIdentity(); reference=null; referenceWindow.clear(); fusionReferenceWindow.clear(); fusionPoseFinderPoses.clear();fusionPoseFinderLastPose=null;lastFusionRelocalized=false;trackingGood=false;
     rms=Float.POSITIVE_INFINITY; matches=0; gravityReference=null; motionPriorUsed=false;
     matchSrc.clear();matchDst.clear();candidateSrc.clear();candidateDst.clear();
    candidateD2.clear();candidateConfidence.clear();matchWeights.clear();iterationSource.clear();iterationColor.clear();iterationConfidence.clear();turntablePivotWorld=null;turntablePivotCandidates.clear();fusionAnchorPose=null;turntableYawVelocityDeg=0.0f;turntableSeedConfidence=0.0f;turntableSeedYawDeg=0.0f;lastTrackedYawStepDeg=0.0f;overlap=0.0f;trackingFrameCounter=0;referenceHoldFrames=0;lastReferencePose=null;referenceRevision=0;cachedReferenceRevision=-1;cachedReferenceHash=null;cachedReferenceColors=null;turntableLoopAnchorWorld=null;turntableModelRefineCounter=0;turntableLoopClosureCounter=0;lastFusionModelRefinementGood=true;lastFusionModelTracking=false;turntablePivotCalibrated=false;turntablePivotSeeded=false;turntablePivotCalibrationSamples.clear();turntableSupportAxis=null; }

  PVector transformedSample(int slot,PVector source,RigidTransform estimate){
    while(matchPool.size()<=slot)matchPool.add(new PVector());
    PVector out=matchPool.get(slot);float[] m=estimate.m;
    out.set(m[0]*source.x+m[1]*source.y+m[2]*source.z+m[3],m[4]*source.x+m[5]*source.y+m[6]*source.z+m[7],m[8]*source.x+m[9]*source.y+m[10]*source.z+m[11]);

    return out;
  }

  RigidTransform trackFusion(PointCloud current,MotionSample motion,TSDFVolume volume){
    lastFusionModelTracking=false;lastFusionRelocalized=false;lastFusionModelRefinementGood=true;
    if(!cfg.fusionModelTracking||volume==null||volume.touchedCount<cfg.fusionPointPlaneMinMatches*2)return track(current,motion);

    RigidTransform priorPose=copyTransform(pose);
    ArrayDeque<PointCloud> priorWindow=new ArrayDeque<PointCloud>(referenceWindow);
    RigidTransform priorLastReference=copyTransform(lastReferencePose);
    int priorReferenceHold=referenceHoldFrames,priorRevision=referenceRevision;

    RigidTransform start=copyTransform(pose);start=applyMotionPrior(start,motion);
    RigidTransform estimate=trackAgainstModel(current,start,volume);
    if(estimate!=null){
      float translationStep=rigidTranslationDelta(pose,estimate),rotationStep=rigidRotationDeltaDeg(pose,estimate);
      boolean stepOk=translationStep<=cfg.icpMaxTranslationStepM&&rotationStep<=cfg.icpMaxRotationStepDeg;
      if(stepOk&&matches>=cfg.fusionPointPlaneMinMatches&&overlap>=cfg.fusionPointPlaneMinOverlap&&rms<=cfg.fusionPointPlaneMaxRmsM){
        trackingGood=true;lastTrackedYawStepDeg=0;RigidTransform stable=stabilizeFusionPose(estimate);
        lastFusionModelTracking=true;
        if(shouldAddTrackingReference(stable))addReference(current,stable);return stable;
      }
    }

    // Recovery path: recent accepted geometry gives a wider local capture basin.
    // Snapshot/restore the reference window because addReference() may evict its
    // oldest cloud even when the deque size stays constant; a failed recovery must
    // never poison the following frame's tracker state.
    restoreTrackingReferences(priorWindow,priorLastReference,priorReferenceHold,priorRevision);
    pose.set(priorPose);
    RigidTransform recovered=track(current,motion);
    if(trackingGood){
      float[] model=volume.raycastConsistency(current,recovered,cfg);
      boolean modelOk=model[0]>=cfg.fusionRelocalizeMinOverlap&&model[1]<=cfg.fusionRelocalizeMaxRmsM;
      if(modelOk)return recovered;
    }

    // Local recovery failed or disagreed with the global model. Try sparse
    // accepted keyframe poses (Camera Pose Finder style) before declaring loss.
    restoreTrackingReferences(priorWindow,priorLastReference,priorReferenceHold,priorRevision);
    pose.set(priorPose);
    RigidTransform relocalized=findFusionPose(current,volume);
    if(relocalized!=null)return relocalized;

    trackingGood=false;pose.set(priorPose);
    restoreTrackingReferences(priorWindow,priorLastReference,priorReferenceHold,priorRevision);
    return pose;
  }

  boolean lastTurntableModelTracking=false;
  // KinectFusion-style frame-to-model tracking for a turntable scan. Point-to-plane
  // residuals against the fused TSDF surface are neutral for rotationally
  // symmetric parts (the plate, cylinders), whereas nearest-neighbour
  // point-to-point ICP turns every such point into a false "no motion"
  // constraint and systematically under-measures the rotation.
  RigidTransform trackTurntable(PointCloud current,MotionSample motion,TSDFVolume volume){
    lastTurntableModelTracking=false;
    if(!cfg.turntableModelTracking||volume==null||volume.touchedCount<cfg.fusionPointPlaneMinMatches*2||referenceWindow.isEmpty())return track(current,motion);
    RigidTransform start=new RigidTransform();start.set(pose);
    boolean axial=turntableAxisConstrained()&&cfg.turntablePoseConstraint;
    PVector pivot=axial?turntablePivotWorld.copy():null;
    float predicted=constrain(turntableYawVelocityDeg,-cfg.turntableMaxSeedYawDeg,cfg.turntableMaxSeedYawDeg);
    if(turntablePivotWorld!=null&&abs(predicted)>0.01f)start=rotateAroundPivotY(start,turntablePivotWorld,predicted);
    float oldRms=rms,oldOverlap=overlap;int oldMatches=matches;
    boolean planar=pivot==null&&cfg.turntablePlanarMotion&&turntableSupportAxis!=null;
    RigidTransform estimate=trackAgainstModel(current,start,volume,pivot,planar);
    if(estimate!=null&&trackingGood){
      float translationStep=rigidTranslationDelta(pose,estimate),rotationStep=rigidRotationDeltaDeg(pose,estimate);
      boolean stepOk=translationStep<=cfg.icpMaxTranslationStepM&&rotationStep<=cfg.icpMaxRotationStepDeg;
      if(stepOk&&rms<=cfg.turntableModelTrackingMaxRmsM&&overlap>=cfg.turntableModelTrackingMinOverlap){
        float yawStep=turntableDeltaDeg(pose,estimate);lastTrackedYawStepDeg=yawStep;
        float velocityTarget=constrain(yawStep,turntableYawVelocityDeg-cfg.turntableVelocityClampDeg,turntableYawVelocityDeg+cfg.turntableVelocityClampDeg);
        turntableYawVelocityDeg=lerp(turntableYawVelocityDeg,velocityTarget,1.0f-cfg.turntableMotionAlpha);
        turntableSeedYawDeg=yawStep;turntableSeedConfidence=1.0f;
        pose.set(estimate);calibrateTurntablePivot(pose);trackingGood=true;lastTurntableModelTracking=true;
        if(shouldAddTrackingReference(pose))addReference(current,pose);
        return pose;
      }
    }
    // Model tracking lost its basin (fast turn, large new surface): fall back to
    // the rolling cloud tracker, which has the wider yaw search. Turntable keeps
    // this dedicated axial recovery path because newly exposed object surfaces can
    // legitimately have little overlap with the mature TSDF during a rotation.
    rms=oldRms;overlap=oldOverlap;matches=oldMatches;
    return track(current,motion);
  }

  RigidTransform refineFusionAgainstModel(PointCloud current,RigidTransform candidate,TSDFVolume volume){
    lastFusionModelRefinementGood=true;
    if(!cfg.fusionModelTracking||current==null||candidate==null||volume==null||
       volume.touchedCount<cfg.fusionPointPlaneMinMatches*2)return candidate;

    // Preserve diagnostics from the lightweight rolling ICP until the global
    // keyframe alignment proves that it has a better, coherent world pose.
    float oldRms=rms,oldOverlap=overlap;int oldMatches=matches;boolean oldGood=trackingGood;
    RigidTransform savedPose=new RigidTransform();savedPose.set(candidate);
    RigidTransform refined=trackAgainstModel(current,candidate,volume);
    boolean modelGood=refined!=null&&trackingGood&&
      matches>=cfg.fusionPointPlaneMinMatches&&
      overlap>=cfg.fusionModelRefineMinOverlap&&
      rms<=cfg.fusionModelRefineMaxRmsM;
    if(modelGood){
      float correctionM=rigidTranslationDelta(candidate,refined);
      float correctionDeg=rigidRotationDeltaDeg(candidate,refined);
      modelGood=correctionM<=cfg.fusionModelRefineMaxCorrectionM&&
                correctionDeg<=cfg.fusionModelRefineMaxCorrectionDeg;
    }
    if(modelGood){
      float correctionM=rigidTranslationDelta(candidate,refined);
      float correctionDeg=rigidRotationDeltaDeg(candidate,refined);
      pose.set(refined);trackingGood=true;lastFusionModelRefinementGood=true;
      // Persist global correction into the lightweight temporal tracker. Without
      // this rebase, the next local ICP frame is pulled back toward the drifted
      // coordinate system and global errors re-accumulate.
      if(correctionM>cfg.fusionModelRebaseTranslationM||
         correctionDeg>cfg.fusionModelRebaseRotationDeg)rebaseFusionTrackingReference(current,refined);
      fusionAnchorPose.set(refined);
      return refined;
    }

    // Do not let a failed global attempt corrupt the live temporal tracker. The
    // caller can reject this integration candidate while tracking continues.
    lastFusionModelRefinementGood=false;
    rms=oldRms;overlap=oldOverlap;matches=oldMatches;trackingGood=oldGood;pose.set(savedPose);
    return candidate;
  }

  void rebaseFusionTrackingReference(PointCloud current,RigidTransform corrected){
    if(current==null||corrected==null)return;
    referenceWindow.clear();reference=null;lastReferencePose=null;referenceHoldFrames=0;
    cachedReferenceHash=null;cachedReferenceColors=null;cachedReferenceRevision=-1;
    addReference(current,corrected);
  }

  RigidTransform refineTurntableAgainstModel(PointCloud current,RigidTransform candidate,TSDFVolume volume){
    if(!cfg.turntableModelRefinement||current==null||candidate==null||volume==null||
       volume.touchedCount<cfg.fusionPointPlaneMinMatches*2)return candidate;
    turntableModelRefineCounter++;
    if(cfg.turntableModelRefineEveryFrames>1&&(turntableModelRefineCounter%cfg.turntableModelRefineEveryFrames)!=0)return candidate;

    // Preserve the frame-to-frame tracking diagnostics. Model refinement is a
    // second-stage correction against the geometry already fused into world space.
    float oldRms=rms,oldOverlap=overlap;int oldMatches=matches;boolean oldGood=trackingGood;
    RigidTransform savedPose=new RigidTransform();savedPose.set(candidate);
    RigidTransform refined=trackAgainstModel(current,candidate,volume);
    boolean modelGood=refined!=null&&trackingGood&&
      matches>=cfg.fusionPointPlaneMinMatches&&
      overlap>=cfg.turntableModelRefineMinOverlap&&
      rms<=cfg.turntableModelRefineMaxRmsM;
    if(modelGood){
      float correctionM=rigidTranslationDelta(candidate,refined);
      float correctionDeg=rigidRotationDeltaDeg(candidate,refined);
      modelGood=correctionM<=cfg.turntableModelRefineMaxCorrectionM&&
                correctionDeg<=cfg.turntableModelRefineMaxCorrectionDeg;
    }
    if(modelGood){
      // Turntable is a fixed-axis acquisition problem.  Point-to-plane model
      // refinement may discover a numerically better unrestricted SE(3) pose, but
      // silhouette/self-occlusion changes can make that solution drift vertically
      // or tilt a little on every keyframe.  Project the model correction back to
      // the physical turntable DOF before it can enter the TSDF.
      RigidTransform accepted=refined;
      if(turntableAxisConstrained()){
        float yawCorrection=turntableDeltaDeg(candidate,refined);
        accepted=rotateAroundPivotY(candidate,turntablePivotWorld,yawCorrection);
      }
      float correctionM=rigidTranslationDelta(candidate,accepted);
      float correctionDeg=rigidRotationDeltaDeg(candidate,accepted);
      pose.set(accepted);trackingGood=true;
      if(!turntablePivotCalibrated)calibrateTurntablePivot(accepted);
      // Rebase the temporal reference to the constrained world pose, never to the
      // unrestricted model result.  This prevents a rejected Y/pitch/roll component
      // from returning on the next frame.
      if(correctionM>0.0035f||correctionDeg>0.45f)rebaseTurntableTrackingReference(current,accepted);
      return accepted;
    }
    rms=oldRms;overlap=oldOverlap;matches=oldMatches;trackingGood=oldGood;pose.set(savedPose);
    return candidate;
  }

  void rebaseTurntableTrackingReference(PointCloud current,RigidTransform corrected){
    if(current==null||corrected==null)return;
    referenceWindow.clear();reference=null;lastReferencePose=null;
    cachedReferenceHash=null;cachedReferenceColors=null;cachedReferenceRevision=-1;
    addReference(current,corrected);
  }

  void acceptTurntableLoopAnchor(PointCloud current,RigidTransform acceptedPose){
    if(turntableLoopAnchorWorld!=null||current==null||acceptedPose==null)return;
    // Keep a compact immutable world-space view of the beginning of the scan.
    // It is independent from the rolling ICP window and from the mutable TSDF.
    turntableLoopAnchorWorld=current.transformed(acceptedPose,max(cfg.hqIcpMinimumMatches*2,2200));
  }

  RigidTransform refineTurntableLoopClosure(PointCloud current,RigidTransform candidate,float sweepDeg){
    if(!cfg.turntableLoopClosure||turntableLoopAnchorWorld==null||current==null||candidate==null||
       sweepDeg<cfg.turntableLoopClosureStartDeg)return candidate;
    turntableLoopClosureCounter++;
    if(cfg.turntableLoopClosureEveryFrames>1&&(turntableLoopClosureCounter%cfg.turntableLoopClosureEveryFrames)!=0)return candidate;
    RobustIcpResult loop=turntableLoopRefiner.refine(current,turntableLoopAnchorWorld,candidate,
      cfg.turntableLoopClosureDistanceM,5,cfg.turntableLoopClosureMaxRmsM);
    if(loop==null||!loop.good)return candidate;
    float correctionM=rigidTranslationDelta(candidate,loop.pose);
    float correctionDeg=rigidRotationDeltaDeg(candidate,loop.pose);
    if(correctionM>cfg.turntableLoopClosureMaxCorrectionM||correctionDeg>cfg.turntableLoopClosureMaxCorrectionDeg)return candidate;
    // Loop closure is allowed to correct accumulated ANGLE, not to introduce a
    // six-axis jump at the end of the turn.  Project its correction to the same
    // gravity-aligned fixed axis used by realtime Turntable tracking.
    RigidTransform accepted=loop.pose;
    if(turntableAxisConstrained()){
      float yawCorrection=turntableDeltaDeg(candidate,loop.pose);
      accepted=rotateAroundPivotY(candidate,turntablePivotWorld,yawCorrection);
    }
    pose.set(accepted);trackingGood=true;rms=loop.rms;matches=loop.matches;
    rebaseTurntableTrackingReference(current,accepted);
    return accepted;
  }

  RigidTransform trackAgainstModel(PointCloud current,RigidTransform initial,TSDFVolume volume){return trackAgainstModel(current,initial,volume,null);}
  // axialPivot != null solves only the rotation angle about the calibrated
  // turntable axis (1-DoF point-to-plane), which is exactly the physical motion.
  RigidTransform trackAgainstModel(PointCloud current,RigidTransform initial,TSDFVolume volume,PVector axialPivot){return trackAgainstModel(current,initial,volume,axialPivot,false);}
  // planar=true: the subject moves on its support plane (turntable). Solve only
  // rotation about the plane normal plus translation within the plane (3-DoF).
  // Any rotation about an unknown point of the plane fits this model exactly,
  // so no pivot is needed, while tilt and vertical drift become impossible.
  RigidTransform trackAgainstModel(PointCloud current,RigidTransform initial,TSDFVolume volume,PVector axialPivot,boolean planar){
    if(current==null||current.size()<cfg.fusionPointPlaneMinMatches||volume==null)return null;
    PVector axialAxis=axialPivot==null?null:turntableAxisWorld();
    PVector planeAxis=null,planeU=null,planeV=null,planeRef=null;
    if(planar&&axialAxis==null){planeAxis=turntableAxisWorld();PVector seedDir=abs(planeAxis.x)<0.8f?new PVector(1,0,0):new PVector(0,0,1);
      planeU=planeAxis.cross(seedDir);planeU.normalize();planeV=planeAxis.cross(planeU);planeV.normalize();
      planeRef=current.centroidTransformed(initial);}
    if(volume.ensureSurfaceModel(cfg)<cfg.fusionPointPlaneMinMatches)return null;
    RigidTransform estimate=new RigidTransform();estimate.set(initial);
    int maxSamples=max(cfg.fusionPointPlaneMinMatches,cfg.fusionPointPlaneMaxSamples),stride=max(1,(current.size()+maxSamples-1)/maxSamples);
    float finalRms=Float.POSITIVE_INFINITY;int finalMatches=0;float finalOverlap=0;
    for(int iter=0;iter<cfg.fusionPointPlaneIterations;iter++){
      double[][] ata=new double[6][6];double[] atb=new double[6],a=new double[6];double sum2=0,weightSum=0,axialJJ=0,axialJR=0;int attempted=0,matched=0;
      double[][] pa=planeAxis!=null?new double[3][3]:null;double[] pb=planeAxis!=null?new double[3]:null;
      float phase=cfg.fusionPointPlaneIterations<=1?1.0f:iter/(float)(cfg.fusionPointPlaneIterations-1);
      float residualGate=lerp(max(cfg.fusionPointPlaneMaxRmsM*2.2f,cfg.icpMaxDistanceM*.72f),max(cfg.modelTrackingFinalGateM,volume.voxelSize*2.0f),phase);
      float maxTangential=lerp(max(cfg.modelTrackingMaxTangentialM*3.0f,residualGate),max(cfg.modelTrackingMaxTangentialM,volume.voxelSize*2.5f),phase),maxTangential2=maxTangential*maxTangential;
      float[] em=estimate.m;
      for(int i=0;i<current.size();i+=stride){
        float confidence=current.confidenceAt(i);if(confidence<cfg.pointCloudMinimumConfidence)continue;attempted++;PVector source=current.points.get(i);
        float mx=em[0]*source.x+em[1]*source.y+em[2]*source.z+em[3],my=em[4]*source.x+em[5]*source.y+em[6]*source.z+em[7],mz=em[8]*source.x+em[9]*source.y+em[10]*source.z+em[11];
        PVector modelPoint=volume.nearestSurfaceModel(mx,my,mz,residualGate,cfg);if(modelPoint==null)continue;PVector normal=volume.surfaceModelNormal(modelPoint);if(normal==null)continue;
        float nx=normal.x,ny=normal.y,nz=normal.z,rx=mx-modelPoint.x,ry=my-modelPoint.y,rz=mz-modelPoint.z,residual=rx*nx+ry*ny+rz*nz;if(abs(residual)>residualGate)continue;
        // A sample whose nearest model point lies far to the side of it is on a
        // surface the model has not seen yet (it matches the model's border).
        // Such pairs pull the pose back toward the previous view, so drop them.
        float tangential2=rx*rx+ry*ry+rz*rz-residual*residual;if(tangential2>maxTangential2)continue;
        float robustRadius=max(0.002f,residualGate*cfg.icpRobustK),u=abs(residual)/robustRadius,robust=u>=1.0f?0.05f:(1.0f-u*u)*(1.0f-u*u);double sampleWeight=max(0.01f,confidence)*max(0.05f,robust);
        if(planeAxis!=null){
          float qx=mx-planeRef.x,qy=my-planeRef.y,qz=mz-planeRef.z;
          float cx=planeAxis.y*qz-planeAxis.z*qy,cy=planeAxis.z*qx-planeAxis.x*qz,cz=planeAxis.x*qy-planeAxis.y*qx;
          double j0=cx*nx+cy*ny+cz*nz,j1=planeU.x*nx+planeU.y*ny+planeU.z*nz,j2=planeV.x*nx+planeV.y*ny+planeV.z*nz;double[] jj={j0,j1,j2};
          for(int r=0;r<3;r++){pb[r]+=jj[r]*(-residual)*sampleWeight;for(int c2=0;c2<3;c2++)pa[r][c2]+=jj[r]*jj[c2]*sampleWeight;}
        }else if(axialAxis!=null){
          // d(residual)/d(theta) = n . (axis x (m - pivot))
          float qx=mx-axialPivot.x,qy=my-axialPivot.y,qz=mz-axialPivot.z;
          float cx=axialAxis.y*qz-axialAxis.z*qy,cy=axialAxis.z*qx-axialAxis.x*qz,cz=axialAxis.x*qy-axialAxis.y*qx;
          double j=cx*nx+cy*ny+cz*nz;axialJJ+=j*j*sampleWeight;axialJR+=j*residual*sampleWeight;
        }else{
          a[0]=my*nz-mz*ny;a[1]=mz*nx-mx*nz;a[2]=mx*ny-my*nx;a[3]=nx;a[4]=ny;a[5]=nz;
          for(int r=0;r<6;r++){atb[r]+=a[r]*(-residual)*sampleWeight;for(int c=r;c<6;c++)ata[r][c]+=a[r]*a[c]*sampleWeight;}
        }
        sum2+=residual*residual*sampleWeight;weightSum+=sampleWeight;matched++;
      }
      for(int r=0;r<6;r++)for(int c=0;c<r;c++)ata[r][c]=ata[c][r];finalOverlap=attempted<=0?0:matched/(float)attempted;if(matched<cfg.fusionPointPlaneMinMatches||finalOverlap<cfg.fusionPointPlaneMinOverlap)break;
      if(planeAxis!=null){
        finalMatches=matched;finalRms=(float)Math.sqrt(sum2/Math.max(1e-9,weightSum));
        for(int r=0;r<3;r++)pa[r][r]+=1e-9;
        double det=pa[0][0]*(pa[1][1]*pa[2][2]-pa[1][2]*pa[2][1])-pa[0][1]*(pa[1][0]*pa[2][2]-pa[1][2]*pa[2][0])+pa[0][2]*(pa[1][0]*pa[2][1]-pa[1][1]*pa[2][0]);if(Math.abs(det)<1e-18)break;
        double[] x3=new double[3];for(int k=0;k<3;k++){double[][] t3=new double[3][3];for(int r=0;r<3;r++)for(int c2=0;c2<3;c2++)t3[r][c2]=c2==k?pb[r]:pa[r][c2];
          x3[k]=(t3[0][0]*(t3[1][1]*t3[2][2]-t3[1][2]*t3[2][1])-t3[0][1]*(t3[1][0]*t3[2][2]-t3[1][2]*t3[2][0])+t3[0][2]*(t3[1][0]*t3[2][1]-t3[1][1]*t3[2][0]))/det;}
        float dTheta=(float)x3[0];RigidTransform step=rotateAroundPivotY(new RigidTransform(),planeRef,degrees(dTheta));
        step.m[3]+=(float)(planeU.x*x3[1]+planeV.x*x3[2]);step.m[7]+=(float)(planeU.y*x3[1]+planeV.y*x3[2]);step.m[11]+=(float)(planeU.z*x3[1]+planeV.z*x3[2]);
        estimate=step.multiply(estimate);
        if(abs(degrees(dTheta))<0.01f&&Math.abs(x3[1])+Math.abs(x3[2])<0.00005)break;continue;
      }
      if(axialAxis!=null){
        finalMatches=matched;finalRms=(float)Math.sqrt(sum2/Math.max(1e-9,weightSum));if(axialJJ<1e-12)break;
        float dTheta=(float)(-axialJR/axialJJ);estimate=rotateAroundPivotY(estimate,axialPivot,degrees(dTheta));
        if(abs(degrees(dTheta))<0.01f)break;continue;
      }
      double[] x=solveSymmetric6(ata,atb);if(x==null)break;finalMatches=matched;finalRms=(float)Math.sqrt(sum2/Math.max(1e-9,weightSum));
      PVector omega=new PVector((float)x[0],(float)x[1],(float)x[2]),translation=new PVector((float)x[3],(float)x[4],(float)x[5]);float angle=omega.mag();RigidTransform correction=angle>1e-8f?axisAngle(PVector.div(omega,angle),angle):new RigidTransform();
      correction.m[3]=translation.x;correction.m[7]=translation.y;correction.m[11]=translation.z;estimate=correction.multiply(estimate);if(translation.mag()<0.00005f&&degrees(angle)<0.03f)break;
    }
    rms=finalRms;matches=finalMatches;overlap=finalOverlap;trackingGood=matches>=cfg.fusionPointPlaneMinMatches&&overlap>=cfg.fusionPointPlaneMinOverlap&&rms<=cfg.fusionPointPlaneMaxRmsM;return trackingGood?estimate:null;
  }

  double[] solveSymmetric6(double[][] a,double[] b){
    double[][] m=new double[6][7];for(int r=0;r<6;r++){for(int c=0;c<6;c++)m[r][c]=a[r][c];m[r][r]+=1e-8;m[r][6]=b[r];}
    for(int k=0;k<6;k++){int pivot=k;for(int r=k+1;r<6;r++)if(Math.abs(m[r][k])>Math.abs(m[pivot][k]))pivot=r;if(Math.abs(m[pivot][k])<1e-10)return null;
      if(pivot!=k){double[] tmp=m[k];m[k]=m[pivot];m[pivot]=tmp;}double inv=1.0/m[k][k];for(int c=k;c<7;c++)m[k][c]*=inv;
      for(int r=0;r<6;r++){if(r==k)continue;double f=m[r][k];if(Math.abs(f)<1e-16)continue;for(int c=k;c<7;c++)m[r][c]-=f*m[k][c];}}
    double[] x=new double[6];for(int i=0;i<6;i++)x[i]=m[i][6];return x;
  }

  RigidTransform track(PointCloud current, MotionSample motion) {
    if(referenceWindow.isEmpty()) {
      pose.setIdentity();
      if(motion!=null && motion.gravityReliable()) gravityReference=motion.gravityUnit();

      addReference(current,pose);
      if(turntablePivotWorld==null)turntablePivotWorld=robustCloudCenter(current,pose);
      trackingGood=true; rms=0; matches=reference==null?0:reference.size();overlap=1.0f;
      return pose;
    }

    RigidTransform estimate=new RigidTransform(); estimate.set(pose);
    estimate=applyMotionPrior(estimate,motion);
    float finalRms=Float.POSITIVE_INFINITY; int finalMatches=0;

    ensureReferenceIndex();
    SpatialHash hash=cachedReferenceHash;HashMap<PVector,Integer> referenceColors=cachedReferenceColors;
    if(hash==null)return pose;
    trackingFrameCounter++;
    if(cfg.turntableTracking&&trackingGood&&cfg.turntableSeedSearchEveryFrames>1&&(trackingFrameCounter%cfg.turntableSeedSearchEveryFrames)!=0){
      float predicted=constrain(turntableYawVelocityDeg,-cfg.turntableMaxSeedYawDeg,cfg.turntableMaxSeedYawDeg);
      PVector pivot=turntablePivotWorld==null?robustCloudCenter(current,estimate):turntablePivotWorld;
      estimate=rotateAroundPivotY(estimate,pivot,predicted);
      turntableSeedYawDeg=predicted;turntableSeedConfidence*=0.92f;
    }else estimate=seedTurntableRotation(current,estimate,hash,referenceColors);
    int maxSamples=max(1,cfg.icpMaxSamples);
    int stride=max(1,(current.size()+maxSamples-1)/maxSamples);

    for(int iter=0;iter<cfg.icpIterations;iter++) {
      candidateSrc.clear();candidateDst.clear();candidateD2.clear();candidateConfidence.clear();iterationSource.clear();iterationColor.clear();
      int slot=0,attempted=0;
      float phase=cfg.icpIterations<=1?1.0f:iter/(float)(cfg.icpIterations-1);
      float searchDistance=lerp(cfg.icpMaxDistanceM,cfg.icpFinalDistanceM,phase);
      boolean reciprocalThisIteration=cfg.icpReciprocal&&cfg.icpReciprocalFinalIterations>0&&iter>=max(0,cfg.icpIterations-cfg.icpReciprocalFinalIterations);
      SpatialHash sourceHash=reciprocalThisIteration?new SpatialHash(max(.006f,min(cfg.icpCellSizeM,searchDistance)),max(16,maxSamples)):null;
      iterationConfidence.clear();
      for(int i=0;i<current.size();i+=stride) {
        float confidence=current.confidenceAt(i);if(confidence<cfg.pointCloudMinimumConfidence)continue;attempted++;
        PVector world=transformedSample(slot++,current.points.get(i),estimate);iterationSource.add(world);iterationConfidence.add(confidence);iterationColor.add(current.colorAt(i));if(sourceHash!=null)sourceHash.add(world);
      }
      float reciprocalGate=max(cfg.icpReciprocalToleranceM,searchDistance*.38f);
      for(int i=0;i<iterationSource.size();i++){PVector world=iterationSource.get(i),near=hash.nearest(world,searchDistance);if(near==null)continue;
        if(reciprocalThisIteration){PVector reverse=sourceHash.nearest(near,reciprocalGate);if(reverse==null||PVector.dist(reverse,world)>reciprocalGate)continue;}
        float dx=world.x-near.x,dy=world.y-near.y,dz=world.z-near.z;
        float photo=photometricWeight(iterationColor.get(i),referenceColors.get(near));
        candidateSrc.add(world);candidateDst.add(near);candidateD2.add(dx*dx+dy*dy+dz*dz);candidateConfidence.add(iterationConfidence.get(i)*photo);}
      overlap=attempted<=0?0:candidateSrc.size()/(float)attempted;
      if(candidateSrc.size()<cfg.icpMinimumMatches||overlap<cfg.icpMinimumOverlap)break;

      float trim=cfg.turntableTracking?min(cfg.icpTrimFraction,0.66f):cfg.icpTrimFraction;
      float threshold=trimThreshold(candidateD2,trim,cfg.icpMinimumMatches);
      float robustK=cfg.turntableTracking?min(cfg.icpRobustK,0.56f):cfg.icpRobustK;
      float robustRadius=max(0.001f,searchDistance*robustK);
      matchSrc.clear();matchDst.clear();matchWeights.clear();double weightedSum2=0,weightSum=0;
      for(int i=0;i<candidateSrc.size();i++){float d2=candidateD2.get(i);if(d2>threshold)continue;
        float d=sqrt(d2),u=d/robustRadius,robust=u>=1.0f?0.05f:(1.0f-u*u)*(1.0f-u*u);
        float weight=max(0.01f,candidateConfidence.get(i))*max(0.05f,robust);
        matchSrc.add(candidateSrc.get(i));matchDst.add(candidateDst.get(i));matchWeights.add(weight);weightedSum2+=weight*d2;weightSum+=weight;
        }
      if(matchSrc.size()<cfg.icpMinimumMatches||weightSum<=0)break;
      finalRms=(float)Math.sqrt(weightedSum2/weightSum);finalMatches=matchSrc.size();
      RigidTransform correction=fitter.fitWeighted(matchSrc,matchDst,matchWeights);
      estimate=correction.multiply(estimate);
      if(rigidTranslationDelta(new RigidTransform(),correction)<0.00005f&&rigidRotationDeltaDeg(new RigidTransform(),correction)<0.03f)break;
    }

    // Generic nearest-neighbour ICP can partially erase a small legitimate yaw,
    // especially on smooth or nearly symmetric parts. If the dedicated
    // turntable seed has a distinct basin (geometry and/or RGB texture), retain
    // a bounded portion of that axial motion while preserving the ICP XYZ,
    // pitch and roll solution.
    if(cfg.turntableTracking&&turntableAxisConstrained()&&
       turntableSeedConfidence>=cfg.turntableSeedMinimumConfidence&&
       abs(turntableSeedYawDeg)>=cfg.turntableSeedMinTrackedYawDeg){
      float finalYaw=turntableDeltaDeg(pose,estimate);
      boolean directionCompatible=abs(finalYaw)<cfg.turntableSeedMinTrackedYawDeg||
        finalYaw*turntableSeedYawDeg>=0;
      float retained=abs(turntableSeedYawDeg)*.38f;
      if(directionCompatible&&abs(finalYaw)<retained){
        float confidenceAuthority=constrain((turntableSeedConfidence-cfg.turntableSeedMinimumConfidence)/
          max(.001f,1.0f-cfg.turntableSeedMinimumConfidence),0,1);
        float authority=cfg.turntableSeedPoseAuthority*lerp(.35f,1.0f,confidenceAuthority);
        float targetYaw=lerp(finalYaw,turntableSeedYawDeg,authority);
        estimate=rotateAroundPivotY(estimate,turntablePivotWorld,targetYaw-finalYaw);
      }
    }

    // A target rotating around a fixed vertical axis is much better conditioned
    // than unrestricted frame-to-frame SE(3). Generic ICP can otherwise explain
    // silhouette changes as small translations/pitch/roll and accumulate a
    // double shell. Prefer the axial solution whenever it explains the data
    // almost as well, while retaining only a tightly bounded translation residual.
    if(cfg.turntableTracking&&turntableAxisConstrained()&&cfg.turntablePivotAlpha>0){
      PVector inferred=inferTurntablePivot(pose,estimate,turntablePivotWorld);
      refineTurntablePivot(inferred,abs(turntableDeltaDeg(pose,estimate)));
    }
    if(cfg.turntableTracking&&cfg.turntablePoseConstraint&&turntableAxisConstrained()){
      estimate=stabilizeTurntablePose(current,estimate,hash,referenceColors);
      float[] stabilized=evaluateTurntablePose(current,estimate,hash,stride);
      if(Float.isFinite(stabilized[0])){finalRms=stabilized[0];finalMatches=round(stabilized[1]);overlap=stabilized[2];}
    }

    // Compose the converged metric 3D estimate as a complete SE(3) transform.
    // In turntable mode the converged transform is regularized around the stable
    // rotation axis; free SE(3) remains available when it is measurably better.
    rms=finalRms; matches=finalMatches;lastTrackedYawStepDeg=0;
    trackingGood = matches>=cfg.icpMinimumMatches && rms<cfg.icpGoodRmsM && overlap>=cfg.icpMinimumOverlap;
    if(trackingGood) {
      float translationStep=rigidTranslationDelta(pose,estimate);
      float rotationStep=rigidRotationDeltaDeg(pose,estimate);
      if(translationStep>cfg.icpMaxTranslationStepM||rotationStep>cfg.icpMaxRotationStepDeg)trackingGood=false;
    }
    if(trackingGood) {
      if(!cfg.turntableTracking&&fusionAnchorPose!=null)estimate=stabilizeFusionPose(estimate);
      if(cfg.turntableTracking){
        float yawStep=turntableDeltaDeg(pose,estimate);
        lastTrackedYawStepDeg=yawStep;
        float velocityTarget=constrain(yawStep,turntableYawVelocityDeg-cfg.turntableVelocityClampDeg,turntableYawVelocityDeg+cfg.turntableVelocityClampDeg);
        // Ambiguous/symmetric geometry must not inject a large velocity jump.
        float velocityAuthority=lerp(.22f,1.0f,turntableSeedConfidence);
        turntableYawVelocityDeg=lerp(turntableYawVelocityDeg,velocityTarget,(1.0f-cfg.turntableMotionAlpha)*velocityAuthority);
      }
      pose.set(estimate);
      if(cfg.turntableTracking)calibrateTurntablePivot(pose);
      if(cfg.turntableTracking&&turntablePivotWorld==null){
        // Bootstrap only. Once rotation is observed, inferTurntablePivot() refines
        // the physical axis from rigid motion. Never chase the visible-cloud
        // centroid here: self-occlusion moves that centroid while the real axis
        // stays fixed, which creates false XYZ motion and double-shell fusion.
        turntablePivotWorld=robustCloudCenter(current,pose);
      }
      // Tracking must keep following legitimate motion even when fusion rejects
      // a frame. The TSDF remains protected by a separate accepted-frame gate.
      if(shouldAddTrackingReference(pose))addReference(current,pose);
    }
    return pose;
  }

  RigidTransform stabilizeFusionPose(RigidTransform candidate){
    if(candidate==null)return candidate;
    if(fusionAnchorPose==null){fusionAnchorPose=new RigidTransform();fusionAnchorPose.set(candidate);pose.set(candidate);return pose;}
    float dt=rigidTranslationDelta(fusionAnchorPose,candidate),dr=rigidRotationDeltaDeg(fusionAnchorPose,candidate);
    if(dt<cfg.fusionPoseDeadbandTranslationM&&dr<cfg.fusionPoseDeadbandRotationDeg){
      pose.set(fusionAnchorPose);return pose;
    }
    // Once real motion leaves the deadband, advance the anchor to the measured
    // pose. Slow deliberate motion accumulates against the anchor and is retained;
    // zero-mean ICP noise is discarded instead of becoming random walk.
    fusionAnchorPose.set(candidate);pose.set(candidate);return pose;
  }

  void refineTurntablePivot(PVector inferred,float yawStepDeg){
    if(inferred==null||turntablePivotWorld==null||yawStepDeg<0.9f||turntableSeedConfidence<cfg.turntableSeedMinimumConfidence)return;
    if(PVector.dist(inferred,turntablePivotWorld)>0.12f)return;
    turntablePivotCandidates.addLast(inferred.copy());
    while(turntablePivotCandidates.size()>max(3,cfg.turntablePivotConsensusSamples*2+1))turntablePivotCandidates.removeFirst();
    if(turntablePivotCandidates.size()<cfg.turntablePivotConsensusSamples)return;
    int n=turntablePivotCandidates.size();float[] xs=new float[n],ys=new float[n],zs=new float[n];int i=0;
    for(PVector q:turntablePivotCandidates){xs[i]=q.x;ys[i]=q.y;zs[i]=q.z;i++;}
    Arrays.sort(xs);Arrays.sort(ys);Arrays.sort(zs);PVector median=new PVector(xs[n/2],ys[n/2],zs[n/2]);
    if(PVector.dist(median,turntablePivotWorld)<=0.06f)turntablePivotWorld.lerp(median,cfg.turntablePivotAlpha);
  }

  PVector inferTurntablePivot(RigidTransform from,RigidTransform to,PVector previous){
    RigidTransform d=to.multiply(from.inverseRigid());float angle=rigidRotationDeltaDeg(new RigidTransform(),d);if(angle<0.6f||angle>cfg.scanRotationMaxStepDeg*1.35f)return null;
    PVector axis=gravityReference==null?new PVector(0,1,0):gravityReference.copy();if(axis.magSq()<1e-7f)axis.set(0,1,0);axis.normalize();
    PVector seed=abs(axis.x)<0.8f?new PVector(1,0,0):new PVector(0,0,1);PVector u=axis.cross(seed);if(u.magSq()<1e-8f)return null;u.normalize();PVector v=axis.cross(u);v.normalize();
    PVector au=PVector.sub(u,d.rotate(u)),av=PVector.sub(v,d.rotate(v)),t=new PVector(d.m[3],d.m[7],d.m[11]);
    float g00=au.dot(au),g01=au.dot(av),g11=av.dot(av),r0=au.dot(t),r1=av.dot(t),det=g00*g11-g01*g01;if(abs(det)<1e-7f)return null;
    float a=(r0*g11-r1*g01)/det,b=(g00*r1-g01*r0)/det,h=previous.dot(axis);PVector out=PVector.mult(u,a);out.add(PVector.mult(v,b));out.add(PVector.mult(axis,h));return out;
  }

  RigidTransform stabilizeTurntablePose(PointCloud current,RigidTransform fullEstimate,SpatialHash hash,HashMap<PVector,Integer> referenceColors){
    if(current==null||fullEstimate==null||turntablePivotWorld==null)return fullEstimate;
    float yawStep=turntableDeltaDeg(pose,fullEstimate);
    if(!Float.isFinite(yawStep))return fullEstimate;

    RigidTransform axial=rotateAroundPivotY(pose,turntablePivotWorld,yawStep);
    float fullScore=turntableScore(current,fullEstimate,hash,referenceColors);
    float axialScore=turntableScore(current,axial,hash,referenceColors);
    if(!Float.isFinite(axialScore))return axial;
    // A turntable is a known 1-DoF mechanism. Never accept a numerically better
    // unrestricted SE(3) solution here: changing silhouette/self-occlusion can
    // make free ICP look better while slowly injecting Y drift, pitch or roll.
    // Geometry quality now influences trackingGood via the axial residual score,
    // but the accepted pose itself remains on the physical axis.

    float dx=fullEstimate.m[3]-axial.m[3],dy=fullEstimate.m[7]-axial.m[7],dz=fullEstimate.m[11]-axial.m[11];
    float d=sqrt(dx*dx+dy*dy+dz*dz);
    float maxResidual=max(0.0f,cfg.turntableConstraintTranslationM);
    if(d>maxResidual&&d>1e-7f){float k=maxResidual/d;dx*=k;dy*=k;dz*=k;}
    float authority=constrain(cfg.turntableConstraintTranslationAuthority,0,1);
    // Strong yaw evidence makes the fixed-axis model even more authoritative.
    authority*=lerp(1.0f,0.45f,constrain(turntableSeedConfidence,0,1));
    axial.m[3]+=dx*authority;axial.m[7]+=dy*authority;axial.m[11]+=dz*authority;
    return axial;
  }

  float photometricWeight(int currentColor,Integer referenceColor){
    if(!cfg.colorIcpEnabled||currentColor==0||referenceColor==null||referenceColor.intValue()==0)return 1.0f;
    int rc=referenceColor.intValue();
    float dr=((currentColor>>16)&255)-((rc>>16)&255);
    float dg=((currentColor>>8)&255)-((rc>>8)&255);
    float db=(currentColor&255)-(rc&255);
    float distance=sqrt(dr*dr+dg*dg+db*db)/(441.67296f);
    float similarity=constrain(1.0f-distance,0,1);
    float photo=lerp(1.0f,similarity,cfg.colorIcpWeight);
    if(distance>cfg.colorIcpRejectDistance)photo=min(photo,cfg.colorIcpMinimumWeight);
    return constrain(photo,cfg.colorIcpMinimumWeight,1.0f);
  }


  PointCloud fusionArchiveReferenceCloud(){
    int count=0;for(PointCloud cloud:fusionReferenceWindow)if(cloud!=null)count+=cloud.size();
    PointCloud out=new PointCloud(max(16,count));
    for(PointCloud cloud:fusionReferenceWindow)if(cloud!=null)for(int i=0;i<cloud.size();i++)out.add(cloud.points.get(i),cloud.colorAt(i),cloud.confidenceAt(i));
    return out;
  }

  RigidTransform validateFusionArchivePose(PointCloud current,RigidTransform candidate,int acceptedKeyframes){
    if(!cfg.fusionArchiveGateEnabled||current==null||candidate==null||acceptedKeyframes<cfg.fusionArchiveWarmupKeyframes||fusionReferenceWindow.isEmpty())return copyTransform(candidate);
    PointCloud reference=fusionArchiveReferenceCloud();
    if(reference.size()<max(cfg.hqIcpMinimumMatches,cfg.minimumTrackingPoints))return copyTransform(candidate);
    RobustIcpResult refined=fusionArchiveRefiner.refine(current,reference,candidate,cfg.fusionArchiveRefineDistanceM,cfg.fusionArchiveRefineIterations,cfg.fusionArchiveMaxRmsM*1.20f);
    if(refined==null||refined.matches<cfg.hqIcpMinimumMatches)return null;
    float correctionM=rigidTranslationDelta(candidate,refined.pose),correctionDeg=rigidRotationDeltaDeg(candidate,refined.pose);
    if(correctionM>cfg.fusionArchiveMaxCorrectionM||correctionDeg>cfg.fusionArchiveMaxCorrectionDeg)return null;
    float[] q=fusionArchiveConsistencyAgainst(reference,current,refined.pose);
    if(q[0]<cfg.fusionArchiveMinOverlap||!Float.isFinite(q[1])||q[1]>cfg.fusionArchiveMaxRmsM)return null;
    if(correctionM>cfg.fusionArchiveRebaseTranslationM||correctionDeg>cfg.fusionArchiveRebaseRotationDeg){
      pose.set(refined.pose);if(fusionAnchorPose==null)fusionAnchorPose=new RigidTransform();fusionAnchorPose.set(refined.pose);rebaseFusionTrackingReference(current,refined.pose);
    }
    return copyTransform(refined.pose);
  }

  float[] fusionArchiveConsistencyAgainst(PointCloud reference,PointCloud current,RigidTransform candidate){
    if(reference==null||current==null||candidate==null||reference.size()<24)return new float[]{0,Float.POSITIVE_INFINITY};
    float gate=max(cfg.fusionArchiveMaxRmsM*2.6f,cfg.icpFinalDistanceM);SpatialHash hash=new SpatialHash(gate,reference.size());for(PVector p:reference.points)hash.add(p);
    int maxSamples=min(3200,max(1,cfg.icpMaxSamples*2)),stride=max(1,(current.size()+maxSamples-1)/maxSamples),attempted=0,matched=0;ArrayList<Float> d2=new ArrayList<Float>();
    for(int i=0;i<current.size();i+=stride){if(current.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;PVector w=candidate.apply(current.points.get(i)),q=hash.nearest(w,gate);if(q==null)continue;float dx=w.x-q.x,dy=w.y-q.y,dz=w.z-q.z;d2.add(dx*dx+dy*dy+dz*dz);matched++;}
    float ov=attempted<=0?0:matched/(float)attempted;if(matched<max(24,cfg.icpMinimumMatches/2))return new float[]{ov,Float.POSITIVE_INFINITY};
    Collections.sort(d2);int keep=constrain(round(d2.size()*0.68f),max(16,cfg.icpMinimumMatches/3),d2.size());double sum=0;for(int i=0;i<keep;i++)sum+=d2.get(i);return new float[]{ov,(float)Math.sqrt(sum/keep)};
  }

  float[] fusionReferenceConsistency(PointCloud current,RigidTransform candidate){
    if(current==null||candidate==null||fusionReferenceWindow.isEmpty())return new float[]{0,0};
    int referencePoints=0;for(PointCloud cloud:fusionReferenceWindow)referencePoints+=cloud.size();
    SpatialHash hash=new SpatialHash(max(.006f,cfg.icpCellSizeM),max(16,referencePoints));
    for(PointCloud cloud:fusionReferenceWindow)for(PVector p:cloud.points)hash.add(p);
    int maxSamples=min(2600,max(1,cfg.icpMaxSamples)),stride=max(1,(current.size()+maxSamples-1)/maxSamples),attempted=0,matched=0;
    ArrayList<Float> d2=new ArrayList<Float>();float gate=max(cfg.fusionReferenceMaxRmsM*2.5f,cfg.icpFinalDistanceM);
    for(int i=0;i<current.size();i+=stride){
      if(current.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;PVector w=candidate.apply(current.points.get(i)),q=hash.nearest(w,gate);if(q==null)continue;
      float dx=w.x-q.x,dy=w.y-q.y,dz=w.z-q.z;d2.add(dx*dx+dy*dy+dz*dz);matched++;
    }
    float overlap=attempted<=0?0:matched/(float)attempted;if(matched<max(24,cfg.icpMinimumMatches/3))return new float[]{overlap,Float.POSITIVE_INFINITY};
    Collections.sort(d2);int keep=constrain(round(d2.size()*0.70f),max(12,cfg.icpMinimumMatches/4),d2.size());double sum=0;for(int i=0;i<keep;i++)sum+=d2.get(i);
    return new float[]{overlap,(float)Math.sqrt(sum/keep)};
  }

  void acceptFusionReference(PointCloud current,RigidTransform acceptedPose){
    if(current==null||acceptedPose==null)return;
    addFusionReference(current,acceptedPose);
    rememberFusionPose(acceptedPose);
  }

  void rememberFusionPose(RigidTransform acceptedPose){
    if(!cfg.fusionPoseFinder||acceptedPose==null)return;
    if(fusionPoseFinderLastPose!=null&&
       rigidTranslationDelta(fusionPoseFinderLastPose,acceptedPose)<cfg.fusionPoseFinderMinTranslationM&&
       rigidRotationDeltaDeg(fusionPoseFinderLastPose,acceptedPose)<cfg.fusionPoseFinderMinRotationDeg)return;
    RigidTransform saved=copyTransform(acceptedPose);fusionPoseFinderPoses.addLast(saved);
    fusionPoseFinderLastPose=copyTransform(saved);
    while(fusionPoseFinderPoses.size()>cfg.fusionPoseFinderMaxPoses)fusionPoseFinderPoses.removeFirst();
  }

  RigidTransform findFusionPose(PointCloud current,TSDFVolume volume){
    if(!cfg.fusionPoseFinder||current==null||volume==null||fusionPoseFinderPoses.isEmpty())return null;
    ArrayList<RigidTransform> seeds=new ArrayList<RigidTransform>(fusionPoseFinderPoses);
    int count=min(cfg.fusionPoseFinderMaxCandidates,seeds.size());
    float bestScore=Float.POSITIVE_INFINITY,bestRms=Float.POSITIVE_INFINITY,bestOverlap=0;int bestMatches=0;
    RigidTransform best=null;
    // Sample the history from newest to oldest, spreading probes over the whole
    // accepted trajectory rather than testing only adjacent poses.
    for(int k=0;k<count;k++){
      int idx=count==1?seeds.size()-1:round((seeds.size()-1)*(1.0f-k/(float)(count-1)));
      RigidTransform candidate=trackAgainstModel(current,seeds.get(idx),volume);
      if(candidate==null||!trackingGood||matches<cfg.fusionPointPlaneMinMatches)continue;
      float[] model=volume.raycastConsistency(current,candidate,cfg);
      if(model[0]<cfg.fusionRelocalizeMinOverlap||model[1]>cfg.fusionRelocalizeMaxRmsM)continue;
      float score=model[1]+rms*0.35f+(1.0f-model[0])*0.003f;
      if(score<bestScore){bestScore=score;best=copyTransform(candidate);bestRms=rms;bestOverlap=overlap;bestMatches=matches;}
    }
    if(best==null)return null;
    pose.set(best);trackingGood=true;rms=bestRms;overlap=bestOverlap;matches=bestMatches;lastTrackedYawStepDeg=0;
    if(fusionAnchorPose==null)fusionAnchorPose=new RigidTransform();fusionAnchorPose.set(best);
    rebaseFusionTrackingReference(current,best);
    lastFusionModelTracking=true;lastFusionRelocalized=true;lastFusionModelRefinementGood=true;
    return pose;
  }

  RigidTransform copyTransform(RigidTransform source){
    if(source==null)return null;RigidTransform out=new RigidTransform();out.set(source);return out;
  }
  void restoreTrackingReferences(ArrayDeque<PointCloud> saved,RigidTransform savedLastPose,int savedHold,int savedRevision){
    referenceWindow.clear();if(saved!=null)referenceWindow.addAll(saved);reference=referenceWindow.peekLast();
    lastReferencePose=copyTransform(savedLastPose);referenceHoldFrames=savedHold;referenceRevision=savedRevision;
    cachedReferenceHash=null;cachedReferenceColors=null;cachedReferenceRevision=-1;
  }

  float[] evaluateTurntablePose(PointCloud cloud,RigidTransform candidate,SpatialHash hash,int stride){
    int attempted=0,n=0;ArrayList<Float> residuals=new ArrayList<Float>();float gate=max(cfg.turntableConstrainedEvaluationM,cfg.icpFinalDistanceM*1.35f);
    for(int i=0;i<cloud.size();i+=max(1,stride)){if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;PVector w=candidate.apply(cloud.points.get(i)),q=hash.nearest(w,gate);if(q==null)continue;float dx=w.x-q.x,dy=w.y-q.y,dz=w.z-q.z;residuals.add(dx*dx+dy*dy+dz*dz);n++;}
    float ov=attempted<=0?0:n/(float)attempted;if(n<cfg.icpMinimumMatches)return new float[]{Float.POSITIVE_INFINITY,n,ov};Collections.sort(residuals);int keep=constrain(round(n*cfg.icpTrimFraction),cfg.icpMinimumMatches,n);double sum=0;for(int i=0;i<keep;i++)sum+=residuals.get(i);return new float[]{(float)Math.sqrt(sum/keep),keep,ov};
  }

  RigidTransform seedTurntableRotation(PointCloud current,RigidTransform base,SpatialHash hash,HashMap<PVector,Integer> referenceColors){
    if(!cfg.turntableTracking||current==null||current.size()<cfg.icpMinimumMatches){turntableSeedConfidence=0;turntableSeedYawDeg=0;return base;}
    PVector pivot=turntablePivotWorld==null?robustCloudCenter(current,base):turntablePivotWorld.copy();
    float maxYaw=cfg.turntableMaxSeedYawDeg;
    float predicted=constrain(turntableYawVelocityDeg,-maxYaw,maxYaw);

    RigidTransform predictedPose=rotateAroundPivotY(base,pivot,predicted);
    float predictedGeom=turntableScore(current,predictedPose,hash,referenceColors);
    RigidTransform best=predictedPose;float bestYaw=predicted;
    float bestObjective=turntableSeedObjective(predictedGeom,predicted,predicted,maxYaw);
    float secondObjective=Float.POSITIVE_INFINITY;

    float coarse=max(1.0f,cfg.turntableCoarseStepDeg);
    // Once motion is established, search locally around the velocity prior.
    // A full ±maxYaw sweep is kept for acquisition/recovery only.
    float searchWindow=(trackingGood&&(turntableSeedConfidence>0.10f||abs(turntableYawVelocityDeg)>0.05f))?min(maxYaw,max(coarse*2.0f,cfg.turntableSeedSearchWindowDeg)):maxYaw;
    float searchStart=max(-maxYaw,predicted-searchWindow),searchEnd=min(maxYaw,predicted+searchWindow);
    for(float probe=searchStart;probe<=searchEnd+0.001f;probe+=coarse){
      RigidTransform candidate=rotateAroundPivotY(base,pivot,probe);float geom=turntableScore(current,candidate,hash,referenceColors);
      float objective=turntableSeedObjective(geom,probe,predicted,maxYaw);
      boolean meaningful=Float.isInfinite(predictedGeom)||geom<predictedGeom*(1.0f-cfg.turntableSeedMinGain);
      if(objective<bestObjective&&meaningful){secondObjective=bestObjective;bestObjective=objective;best=candidate;bestYaw=probe;}
      else if(objective<secondObjective&&abs(probe-bestYaw)>coarse*.45f)secondObjective=objective;
    }

    float fine=max(0.25f,cfg.turntableFineStepDeg);RigidTransform fineBest=best;float fineObjective=bestObjective;
    for(float probe=bestYaw-coarse;probe<=bestYaw+coarse+0.001f;probe+=fine){
      probe=constrain(probe,-maxYaw,maxYaw);RigidTransform candidate=rotateAroundPivotY(base,pivot,probe);float geom=turntableScore(current,candidate,hash,referenceColors);
      float objective=turntableSeedObjective(geom,probe,predicted,maxYaw);
      boolean meaningful=Float.isInfinite(predictedGeom)||geom<predictedGeom*(1.0f-cfg.turntableSeedMinGain)||abs(probe-predicted)<=fine*1.1f;
      if(objective<fineObjective&&meaningful){secondObjective=min(secondObjective,fineObjective);fineObjective=objective;fineBest=candidate;bestYaw=probe;}
      else if(objective<secondObjective&&abs(probe-bestYaw)>fine*1.5f)secondObjective=objective;
    }

    // Confidence is the separation between the best yaw basin and its nearest
    // competitor. Symmetric pieces naturally produce lower confidence, so the
    // temporal velocity prior remains dominant instead of jittering between bins.
    if(Float.isInfinite(fineObjective)||Float.isNaN(fineObjective))turntableSeedConfidence=0;
    else if(Float.isInfinite(secondObjective))turntableSeedConfidence=.72f;
    else turntableSeedConfidence=constrain((secondObjective-fineObjective)/max(1e-9f,secondObjective)*7.5f,0,1);
    turntableSeedYawDeg=bestYaw;
    return fineBest;
  }

  float turntableSeedObjective(float geometryScore,float yaw,float predicted,float maxYaw){
    if(Float.isInfinite(geometryScore)||Float.isNaN(geometryScore))return Float.POSITIVE_INFINITY;
    float angularError=abs(yaw-predicted)/max(1.0f,maxYaw);
    return geometryScore*(1.0f+cfg.turntablePredictionWeight*angularError*angularError);
  }
  void seedTurntablePivot(PVector pivot,PVector axis){
    if(pivot==null)return;
    turntablePivotWorld=pivot.copy();turntablePivotSeeded=true;turntablePivotCalibrated=false;turntablePivotCalibrationSamples.clear();turntablePivotCandidates.clear();
    if(axis!=null&&axis.magSq()>1e-7f){PVector a=axis.copy();a.normalize();turntableSupportAxis=a;}
  }

  PVector turntableAxisWorld(){
    // The plate turns about the normal of the surface it stands on. That normal
    // is measured directly from depth and is more precise than the accelerometer
    // (and remains correct on a slightly tilted table).
    PVector axis=turntableSupportAxis!=null?turntableSupportAxis.copy():(gravityReference==null?new PVector(0,1,0):gravityReference.copy());
    if(axis.magSq()<1e-7f)axis.set(0,1,0);axis.normalize();return axis;
  }
  void setTurntableSupportAxis(float nx,float ny,float nz){
    if(turntableSupportAxis!=null)return;
    PVector a=new PVector(nx,ny,nz);if(a.magSq()<1e-7f)return;a.normalize();
    // Keep the historical sign convention (gravity) so yaw signs stay stable.
    if(gravityReference!=null&&a.dot(gravityReference)<0)a.mult(-1);
    turntableSupportAxis=a;
  }
  boolean turntableAxisConstrained(){return turntablePivotWorld!=null&&(turntablePivotCalibrated||turntablePivotSeeded);}
  PVector calibratedTurntablePivot(){return turntableAxisConstrained()?turntablePivotWorld.copy():null;}

  // Screw-axis calibration: with world = first camera frame and a static sensor,
  // the accepted pose after a rotation theta is a rotation about the physical
  // axis, T = R(x-p)+p. Solve p in the plane orthogonal to the axis from several
  // well-conditioned (large angle) poses and lock the median.
  void calibrateTurntablePivot(RigidTransform accepted){
    if(!cfg.turntablePivotCalibrationEnabled||turntablePivotCalibrated||accepted==null||turntablePivotWorld==null)return;
    float total=abs(turntableDeltaDeg(new RigidTransform(),accepted));
    if(total<cfg.turntablePivotCalibrationDeg||total>150.0f)return;
    PVector sample=solveTurntablePivot(new RigidTransform(),accepted,turntablePivotWorld);if(sample==null)return;
    if(PVector.dist(sample,turntablePivotWorld)>cfg.turntablePivotCalibrationMaxShiftM)return;
    turntablePivotCalibrationSamples.add(sample);
    int n=turntablePivotCalibrationSamples.size();if(n<max(3,cfg.turntablePivotConsensusSamples))return;
    float[] xs=new float[n],ys=new float[n],zs=new float[n];for(int i=0;i<n;i++){PVector q=turntablePivotCalibrationSamples.get(i);xs[i]=q.x;ys[i]=q.y;zs[i]=q.z;}
    Arrays.sort(xs);Arrays.sort(ys);Arrays.sort(zs);PVector median=new PVector(xs[n/2],ys[n/2],zs[n/2]);
    float[] dev=new float[n];for(int i=0;i<n;i++)dev[i]=PVector.dist(turntablePivotCalibrationSamples.get(i),median);Arrays.sort(dev);
    if(dev[n/2]>cfg.turntablePivotCalibrationToleranceM&&total<cfg.turntablePivotCalibrationDeg*2.5f)return;
    turntablePivotWorld=median;turntablePivotCalibrated=true;turntablePivotSeeded=false;
    // Frames fused before calibration were tracked in free 6-DoF against the same
    // world frame, so they stay valid; only the regularization changes from here on.
  }
  PVector solveTurntablePivot(RigidTransform from,RigidTransform to,PVector previous){
    RigidTransform d=to.multiply(from.inverseRigid());
    PVector axis=turntableAxisWorld();
    PVector seed=abs(axis.x)<0.8f?new PVector(1,0,0):new PVector(0,0,1);PVector u=axis.cross(seed);if(u.magSq()<1e-8f)return null;u.normalize();PVector v=axis.cross(u);v.normalize();
    PVector au=PVector.sub(u,d.rotate(u)),av=PVector.sub(v,d.rotate(v)),t=new PVector(d.m[3],d.m[7],d.m[11]);
    float g00=au.dot(au),g01=au.dot(av),g11=av.dot(av),r0=au.dot(t),r1=av.dot(t),det=g00*g11-g01*g01;if(abs(det)<1e-7f)return null;
    float a=(r0*g11-r1*g01)/det,b=(g00*r1-g01*r0)/det,h=previous.dot(axis);PVector out=PVector.mult(u,a);out.add(PVector.mult(v,b));out.add(PVector.mult(axis,h));return out;
  }
  RigidTransform rotateAroundPivotY(RigidTransform base,PVector pivot,float yawDeg){
    // Use the Kinect gravity vector when available so a physically tilted sensor
    // still rotates the target around the real vertical axis, not camera-space Y.
    PVector axis=turntableAxisWorld();
    RigidTransform r=axisAngle(axis,radians(yawDeg));PVector rc=r.rotate(pivot);r.m[3]=pivot.x-rc.x;r.m[7]=pivot.y-rc.y;r.m[11]=pivot.z-rc.z;return r.multiply(base);
  }
  float turntableDeltaDeg(RigidTransform from,RigidTransform to){
    RigidTransform d=to.multiply(from.inverseRigid());PVector axis=turntableAxisWorld();
    float vx=d.m[9]-d.m[6],vy=d.m[2]-d.m[8],vz=d.m[4]-d.m[1];float sin=.5f*(axis.x*vx+axis.y*vy+axis.z*vz);float cos=constrain((d.m[0]+d.m[5]+d.m[10]-1.0f)*.5f,-1,1);return degrees(atan2(sin,cos));
  }
  float turntableScore(PointCloud cloud,RigidTransform t,SpatialHash hash,HashMap<PVector,Integer> referenceColors){
    int step=max(1,(cloud.size()+max(1,cfg.turntableSeedMaxSamples)-1)/max(1,cfg.turntableSeedMaxSamples)),attempted=0,n=0;float maxD=max(cfg.icpMaxDistanceM,.035f);
    ArrayList<Float> residuals=new ArrayList<Float>();
    float wy=constrain(cfg.turntableVerticalResidualWeight,0.02f,1.0f);
    for(int i=0;i<cloud.size();i+=step){
      if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;attempted++;
      PVector w=t.apply(cloud.points.get(i)),q=hash.nearest(w,maxD);if(q==null)continue;
      float dx=w.x-q.x,dy=w.y-q.y,dz=w.z-q.z;
      // Y is retained only weakly for correspondence quality. When registered
      // RGB exists, texture on the object/turntable adds bounded angular evidence.
      float metric=dx*dx+dz*dz+wy*dy*dy;
      if(cfg.colorIcpEnabled&&referenceColors!=null){
        Integer rc=referenceColors.get(q);int cc=cloud.colorAt(i);
        if(rc!=null&&rc.intValue()!=0&&cc!=0){
          int rv=rc.intValue();float dr=((cc>>16)&255)-((rv>>16)&255),dg=((cc>>8)&255)-((rv>>8)&255),db=(cc&255)-(rv&255);
          float cd=sqrt(dr*dr+dg*dg+db*db)/441.67296f;
          metric*=1.0f+cfg.colorIcpWeight*constrain(cd,0,1)*0.75f;
        }
      }
      residuals.add(metric);n++;
    }
    float ov=attempted<=0?0:n/(float)attempted;
    if(n<cfg.icpMinimumMatches||ov<cfg.icpMinimumOverlap)return Float.POSITIVE_INFINITY;
    Collections.sort(residuals);
    int keep=constrain(round(residuals.size()*min(cfg.icpTrimFraction,0.70f)),cfg.icpMinimumMatches,residuals.size());
    double sum=0;for(int i=0;i<keep;i++)sum+=residuals.get(i);
    float mse=(float)(sum/keep);return mse*(1.0f+2.0f*(1.0f-ov));
  }

  PVector robustCloudCenter(PointCloud cloud,RigidTransform transform){
    if(cloud==null||cloud.size()==0)return new PVector();int step=max(1,cloud.size()/1200),n=0;float[] xs=new float[(cloud.size()+step-1)/step],ys=new float[xs.length],zs=new float[xs.length];
    for(int i=0;i<cloud.size();i+=step){if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;PVector p=transform.apply(cloud.points.get(i));xs[n]=p.x;ys[n]=p.y;zs[n]=p.z;n++;}
    if(n==0)return cloud.centroidTransformed(transform);Arrays.sort(xs,0,n);Arrays.sort(ys,0,n);Arrays.sort(zs,0,n);int lo=constrain(round((n-1)*0.20f),0,n-1),hi=constrain(round((n-1)*0.80f),lo,n-1),mid=n/2;return new PVector((xs[lo]+xs[hi])*0.5f,ys[mid],(zs[lo]+zs[hi])*0.5f);
  }
  float yawDeltaDeg(RigidTransform from,RigidTransform to){RigidTransform d=to.multiply(from.inverseRigid());return degrees(atan2(d.m[2],d.m[0]));}

  float trimThreshold(ArrayList<Float> values,float fraction,int minimum){
    int n=values.size();if(n==0)return Float.POSITIVE_INFINITY;float[] sorted=new float[n];
    for(int i=0;i<n;i++)sorted[i]=values.get(i);Arrays.sort(sorted);
    int keep=max(minimum,round(n*constrain(fraction,0.50f,1.0f)));keep=constrain(keep,1,n);
    return sorted[keep-1];
  }

  void ensureReferenceIndex(){
    if(cachedReferenceHash!=null&&cachedReferenceRevision==referenceRevision)return;
    int referencePoints=0;for(PointCloud cloud:referenceWindow)referencePoints+=cloud.size();
    cachedReferenceHash=new SpatialHash(cfg.icpCellSizeM,max(16,referencePoints));cachedReferenceColors=new HashMap<PVector,Integer>(max(16,referencePoints*2));
    for(PointCloud cloud:referenceWindow)for(int ri=0;ri<cloud.size();ri++){PVector rp=cloud.points.get(ri);cachedReferenceHash.add(rp);cachedReferenceColors.put(rp,cloud.colorAt(ri));}
    cachedReferenceRevision=referenceRevision;
  }

  boolean shouldAddTrackingReference(RigidTransform transform){
    referenceHoldFrames++;if(transform==null)return false;if(lastReferencePose==null)return true;
    float translation=rigidTranslationDelta(lastReferencePose,transform),rotation=rigidRotationDeltaDeg(lastReferencePose,transform);
    return translation>=0.0025f||rotation>=1.15f||referenceHoldFrames>=3;
  }

  void addFusionReference(PointCloud current,RigidTransform transform){
    int frames=max(2,cfg.fusionArchiveReferenceFrames),perFrame=max(cfg.icpMinimumMatches,max(cfg.icpReferenceMaxPoints,9000)/frames);
    PointCloud world=current.transformed(transform,perFrame);fusionReferenceWindow.addLast(world);
    while(fusionReferenceWindow.size()>frames)fusionReferenceWindow.removeFirst();
  }

  void addReference(PointCloud current,RigidTransform transform){
    int frames=max(1,cfg.icpReferenceFrames),perFrame=max(cfg.icpMinimumMatches,cfg.icpReferenceMaxPoints/frames);

    PointCloud world=current.transformed(transform,perFrame);reference=world;referenceWindow.addLast(world);
    while(referenceWindow.size()>frames)referenceWindow.removeFirst();
    if(lastReferencePose==null)lastReferencePose=new RigidTransform();lastReferencePose.set(transform);referenceHoldFrames=0;referenceRevision++;
  }

  RigidTransform applyMotionPrior(RigidTransform estimate, MotionSample motion){
    motionPriorUsed=false;
    if(motion==null || !motion.gravityReliable()) return estimate;
    PVector g=motion.gravityUnit();
    if(g==null) return estimate;
    if(gravityReference==null){ gravityReference=g.copy(); return estimate; }

    PVector currentWorld=estimate.rotate(g);
    if(currentWorld.magSq()<1e-8f) return estimate;
    currentWorld.normalize();
    PVector target=gravityReference.copy(); target.normalize();
    RigidTransform correction=rotationBetween(currentWorld,target);
    RigidTransform corrected=correction.multiply(estimate);
    corrected.m[3]=estimate.m[3]; corrected.m[7]=estimate.m[7]; corrected.m[11]=estimate.m[11];

    motionPriorUsed=true;
    return corrected;
  }

  RigidTransform rotationBetween(PVector from, PVector to){
    PVector a=from.copy(); PVector b=to.copy();
    if(a.magSq()<1e-8f || b.magSq()<1e-8f) return new RigidTransform();
    a.normalize(); b.normalize();
    float c=constrain(a.dot(b),-1.0f,1.0f);
    PVector axis=a.cross(b);float magnitude=axis.mag();
    if(magnitude<1e-6f){
      if(c>0) return new RigidTransform();
      axis=abs(a.x)<0.8f?a.cross(new PVector(1,0,0)):a.cross(new PVector(0,1,0));
      axis.normalize();return axisAngle(axis,PI);
    }
    axis.div(magnitude);return axisAngle(axis,atan2(magnitude,c));
  }

  RigidTransform axisAngle(PVector a,float angle){
    float x=a.x,y=a.y,z=a.z,c=cos(angle),ss=sin(angle),t=1-c;
    float[][] R={{t*x*x+c,t*x*y-ss*z,t*x*z+ss*y},{t*x*y+ss*z,t*y*y+c,t*y*z-ss*x},{t*x*z-ss*y,t*y*z+ss*x,t*z*z+c}};

    return new RigidTransform().fromRotationTranslation(R,new PVector());
  }
}
