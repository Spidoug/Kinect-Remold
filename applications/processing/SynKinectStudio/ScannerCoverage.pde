// ===== SynKinect Studio / 3D Scanner / ScanCoverage.pde =====
class ScanCoverageTracker {
  final AppConfig cfg;
  PVector gravityReference=null;
  float directionProbeDeg=0,sweepDeg=0,trackedAngleDeg=0,imuDeviationDeg=0;
  float filteredStepDeg=0,reverseDebtDeg=0,lastAcceptedStepDeg=0,lastCoverageAngleDeg=Float.NaN;
  int direction=0,coveredCount=0,stableMotionFrames=0;
  boolean imuStable=true,objectDetected=false,complete=false;
  boolean[] covered;
  ScanCoverageTracker(AppConfig cfg){this.cfg=cfg;resetBins();}
  void resetBins(){covered=new boolean[max(24,cfg.scanCoverageBins)];coveredCount=0;}
  void reset(){
    gravityReference=null;directionProbeDeg=0;direction=0;sweepDeg=0;trackedAngleDeg=0;
    filteredStepDeg=0;reverseDebtDeg=0;lastAcceptedStepDeg=0;lastCoverageAngleDeg=Float.NaN;stableMotionFrames=0;
    imuDeviationDeg=0;imuStable=true;objectDetected=false;complete=false;resetBins();
  }
  void updateDetection(boolean detected){objectDetected=detected;}

  void updateTracking(RigidTransform pose,MotionSample motion,float signedYawStepDeg){
    updateImu(motion);if(pose==null||complete)return;
    float raw=signedYawStepDeg;
    if(!Float.isFinite(raw)||abs(raw)>cfg.scanRotationMaxStepDeg)return;

    // Suppress sub-deadband jitter without discarding slow real motion forever.
    if(abs(raw)<cfg.scanRotationDeadbandDeg){
      filteredStepDeg*=.65f;stableMotionFrames=max(0,stableMotionFrames-1);return;
    }

    float a=constrain(cfg.scanTurnFilterAlpha,.05f,1.0f);
    if(filteredStepDeg==0||filteredStepDeg*raw>=0)filteredStepDeg=lerp(filteredStepDeg,raw,a);
    else filteredStepDeg=lerp(filteredStepDeg,raw,min(1.0f,a*1.45f));
    float step=lerp(raw,filteredStepDeg,.35f);
    if(abs(step)<cfg.scanRotationDeadbandDeg)return;

    lastAcceptedStepDeg=step;trackedAngleDeg+=step;stableMotionFrames=min(120,stableMotionFrames+1);

    if(direction==0){
      // Direction probe integrates signed evidence, so random +/- jitter cancels.
      directionProbeDeg=constrain(directionProbeDeg+step,-cfg.scanDirectionLockDeg*2.0f,cfg.scanDirectionLockDeg*2.0f);
      if(abs(directionProbeDeg)>=cfg.scanDirectionLockDeg){
        direction=directionProbeDeg>=0?1:-1;
        sweepDeg=abs(directionProbeDeg);
        reverseDebtDeg=0;
      }
      return;
    }

    float aligned=direction*step;
    if(aligned>=0){
      reverseDebtDeg=max(0,reverseDebtDeg-aligned*.85f);
      sweepDeg=min(cfg.scanFullTurnDeg,max(0,sweepDeg+aligned));
    }else{
      float reverse=-aligned;
      // Human scans often produce one-frame opposite yaw from clothing, arms or
      // silhouette changes. Treat bounded reverse motion as jitter rather than
      // allowing it to eat angular coverage or flip the physical turn direction.
      if(reverse<=cfg.scanReverseJitterDeg){reverseDebtDeg=max(0,reverseDebtDeg-reverse*.35f);return;}
      reverseDebtDeg+=reverse;
      // Only sustained reverse motion subtracts progress, and a long deliberate
      // reversal may re-lock direction.
      if(reverseDebtDeg>cfg.scanReverseCommitDeg){
        float committed=min(reverse,reverseDebtDeg-cfg.scanReverseCommitDeg);
        sweepDeg=max(0,sweepDeg-committed);
      }
      if(reverseDebtDeg>=cfg.scanDirectionRelockDeg){
        direction=-direction;
        directionProbeDeg=direction*min(cfg.scanDirectionLockDeg,reverseDebtDeg);
        reverseDebtDeg=0;
        filteredStepDeg=step;
      }
    }
  }

  void confirmAcquisition(){
    if(covered==null||covered.length==0)return;
    // Coverage belongs to acquisition, never to TSDF integration. Fill every
    // angular bin crossed between two accepted tracking poses so fast rotation
    // cannot skip sectors merely because the UI/tracker sampled at a lower rate.
    float robustAngle=direction==0?directionProbeDeg:direction*sweepDeg;
    if(!Float.isFinite(lastCoverageAngleDeg))lastCoverageAngleDeg=robustAngle;
    float delta=robustAngle-lastCoverageAngleDeg;
    float binDeg=360.0f/covered.length;
    int steps=max(1,ceil(abs(delta)/max(0.5f,binDeg*.45f)));
    for(int k=0;k<=steps;k++){
      float a=lerp(lastCoverageAngleDeg,robustAngle,k/(float)steps);
      float wrapped=a%360.0f;if(wrapped<0)wrapped+=360.0f;
      int bin=constrain(floor(wrapped/360.0f*covered.length),0,covered.length-1);
      if(!covered[bin]){covered[bin]=true;coveredCount++;}
    }
    lastCoverageAngleDeg=robustAngle;
    if(coverageFraction()>=cfg.scanCoverageRequired&&sweepDeg>=cfg.scanCompleteDeg){
      sweepDeg=min(cfg.scanFullTurnDeg,max(sweepDeg,cfg.scanCompleteDeg));complete=true;
    }
  }

  void update(RigidTransform pose,MotionSample motion){updateTracking(pose,motion,0);confirmAcquisition();}

  void updateImu(MotionSample motion){
    if(motion==null||!motion.gravityReliable()){imuStable=true;imuDeviationDeg=0;return;}
    PVector g=motion.gravityUnit();if(g==null)return;
    if(gravityReference==null){gravityReference=g.copy();imuStable=true;imuDeviationDeg=0;return;}
    imuDeviationDeg=degrees(acos(constrain(gravityReference.dot(g),-1,1)));imuStable=imuDeviationDeg<=cfg.scanMaxSensorTiltDriftDeg;
  }

  float coverageFraction(){return covered==null||covered.length==0?0:coveredCount/(float)covered.length;}
  float trackingProgress(){if(complete)return 1.0f;return constrain(sweepDeg/max(1.0f,cfg.scanCompleteDeg),0,1);}
  float coverageProgress(){return constrain(coverageFraction()/max(0.01f,cfg.scanCoverageRequired),0,1);}
  float progress(){if(complete)return 1.0f;return min(trackingProgress(),coverageProgress());}
}
