// ===== SynKinect Studio / Native Body3D Library =====
//
// Dense articulated body fitting implemented inside SynKinect Studio.  The solver
// consumes the segmented metric-depth surface, builds a body-centric 3D frame,
// extracts anatomical support regions in metric space, and fits the public 20-joint
// topology with temporal priors and explicit bone constraints.  No external body
// tracking runtime is required.

class Body3DCloudSample {
  PVector p; int u,v; float lateral,vertical,forward,irQuality=1.0f;
  // Probabilistic body-part labels. This is a lightweight geometric classifier,
  // not the proprietary Microsoft body-part forest. It gives every segmented
  // depth point a normalized likelihood before joints are solved.
  final float[] bodyProb=new float[10];
  Body3DCloudSample(PVector p,int u,int v,float irQuality){this.p=p;this.u=u;this.v=v;this.irQuality=constrain(irQuality,.10f,1.0f);}
}

class Body3DFrame {
  PVector center=new PVector(),right=new PVector(1,0,0),up=new PVector(0,-1,0),forward=new PVector(0,0,1);
  float minL,maxL,minV,maxV,minF,maxF,height,width,depth;
  float rawMinV,rawMaxV,rawHeight;
}


class Body3DFloorModel {
  PVector point=new PVector(),normal=new PVector(0,-1,0);boolean valid=false;float support=0;
  void reset(){point.set(0,0,0);normal.set(0,-1,0);valid=false;support=0;}
  float signedDistance(PVector p){return valid&&p!=null?PVector.sub(p,point).dot(normal):0;}
}

class Body3DAnthropometry {
  final HashMap<String,Float> length=new HashMap<String,Float>();
  final HashMap<String,Float> variance=new HashMap<String,Float>();final HashMap<String,Integer> counts=new HashMap<String,Integer>();
  int observations=0;
  void reset(){length.clear();variance.clear();counts.clear();observations=0;}
  void observe(String key,float value,float alpha,float maxDeviation,int warmup){
    if(!Float.isFinite(value)||value<.035f||value>.95f)return;Float old=length.get(key);
    if(old==null){length.put(key,value);variance.put(key,0.0f);counts.put(key,1);observations++;return;}
    int n=counts.containsKey(key)?counts.get(key):1;float relative=abs(value-old)/max(old,.001f);float varianceAllowance=min(.08f,sqrt(max(0,variance.get(key)))/max(old,.001f));
    float allowed=maxDeviation+varianceAllowance;if(n>=warmup&&relative>allowed)return;float bounded=constrain(value,old*(1.0f-allowed),old*(1.0f+allowed));float delta=bounded-old;
    length.put(key,old+alpha*delta);variance.put(key,lerp(variance.get(key),delta*delta,alpha));counts.put(key,min(100000,n+1));observations++;
  }
  float target(String key,float defaultLength){Float v=length.get(key);return v==null?defaultLength:v;}
  float reliability(String key){Float v=variance.get(key);return v==null?.25f:constrain(1.0f-sqrt(max(0,v))/.12f,.15f,1.0f);}
}

class Body3DFusionEngine {
  static final int PART_HEAD=0,PART_TORSO=1,PART_L_ARM=2,PART_R_ARM=3,PART_L_HAND=4,
    PART_R_HAND=5,PART_L_LEG=6,PART_R_LEG=7,PART_L_FOOT=8,PART_R_FOOT=9;
  final SkeletonConfig cfg;
  final ArrayList<Body3DCloudSample> samples=new ArrayList<Body3DCloudSample>();
  final HashMap<String,Float> learnedBones=new HashMap<String,Float>();
  final Body3DAnthropometry anthropometry=new Body3DAnthropometry();
  final Body3DFloorModel floor=new Body3DFloorModel();
  // Per-joint motion/occlusion state.  Predicted joints are never treated as fresh
  // measurements; cloud evidence must reacquire them before confidence returns.
  final HashMap<String,PVector> jointVelocity=new HashMap<String,PVector>();
  final HashMap<String,PVector> lastJointWorld=new HashMap<String,PVector>();
  final HashMap<String,Integer> occlusionAge=new HashMap<String,Integer>();
  float cloudScaleM=1.70f;boolean cloudScaleInitialized=false;
  float torsoForwardM=0,torsoDepthSpreadM=.10f;
  // Stable torso envelope is intentionally independent from total silhouette width.
  // Extended arms/hands must never redefine where shoulders/hips live.
  float torsoHalfWidthM=.18f,shoulderHalfWidthM=.19f,hipHalfWidthM=.13f;
  Body3DFrame frame=new Body3DFrame();

  Body3DFusionEngine(SkeletonConfig cfg){this.cfg=cfg;}
  void reset(){samples.clear();learnedBones.clear();anthropometry.reset();floor.reset();jointVelocity.clear();lastJointWorld.clear();occlusionAge.clear();cloudScaleM=1.70f;cloudScaleInitialized=false;torsoForwardM=0;torsoDepthSpreadM=.10f;torsoHalfWidthM=.18f;shoulderHalfWidthM=.19f;hipHalfWidthM=.13f;frame=new Body3DFrame();}

  SkeletonPose3D solve(DepthFrame depth,InfraredFrame infrared,SkeletonDepthBodyMask body,SkeletonCalibration3D cal,SkeletonPose3D previous,long tick,long trackingId){
    if(depth==null||depth.depth==null||body==null||body.samples<cfg.bodyMinSamples)return null;
    buildCloud(body,infrared,cal);
    if(samples.size()<max(80,cfg.bodyMinSamples/2))return null;
    if(!buildFrame(previous))return null;
    estimateTorsoDepthLayer();
    estimateTorsoLateralEnvelope();
    classifyBodyPartProbabilities();
    estimateFloor();

    SkeletonPose3D s=new SkeletonPose3D();s.trackingId=trackingId;
    PVector head=regionCenter(.72f,1.04f,-.30f,.30f,true);
    // Torso anchors are solved from the torso depth layer itself rather than from
    // the full cloud centroid. This prevents lowered arms from stretching the
    // normalized body height and pulling the pelvis upward.
    PVector shoulderCenter=torsoRegionCenter(.56f,.84f,.28f,.12f);
    PVector spine=torsoRegionCenter(.36f,.66f,.24f,.10f);
    PVector hipCenter=torsoRegionCenter(.14f,.46f,.22f,.09f);
    PVector ls=shoulderSideRegion(-1,.50f,.86f,.10f,1.00f);
    PVector rs=shoulderSideRegion( 1,.50f,.86f,.10f,1.00f);
    PVector lh=hipSideRegion(-1,.10f,.46f,.05f,.72f);
    PVector rh=hipSideRegion( 1,.10f,.46f,.05f,.72f);

    if(head==null||shoulderCenter==null||spine==null||hipCenter==null||ls==null||rs==null||lh==null||rh==null)return null;

    PVector lhand=extremity(-1,true,ls,hipCenter,previous==null?null:previous.leftHand);
    PVector rhand=extremity(1,true,rs,hipCenter,previous==null?null:previous.rightHand);
    PVector lfoot=extremity(-1,false,lh,hipCenter,previous==null?null:previous.leftFoot);
    PVector rfoot=extremity(1,false,rh,hipCenter,previous==null?null:previous.rightFoot);

    PVector lel=armElbowJoint(ls,lhand,-1,previous==null?null:previous.leftElbow),rel=armElbowJoint(rs,rhand,1,previous==null?null:previous.rightElbow);
    PVector lw=armWristJoint(lel,lhand,-1,previous==null?null:previous.leftWrist),rw=armWristJoint(rel,rhand,1,previous==null?null:previous.rightWrist);
    PVector lk=chainJoint(lh,lfoot,.50f,false,-1,previous==null?null:previous.leftKnee),rk=chainJoint(rh,rfoot,.50f,false,1,previous==null?null:previous.rightKnee);
    PVector la=chainJoint(lh,lfoot,.86f,false,-1,previous==null?null:previous.leftAnkle),ra=chainJoint(rh,rfoot,.86f,false,1,previous==null?null:previous.rightAnkle);

    // Body-part likelihoods are the measurement layer. Kinematic chain points
    // are only seeds; the segmented cloud decides where each joint is supported.
    head=probabilisticJoint(head,previous==null?null:previous.head,null,"head",0,.16f);
    shoulderCenter=probabilisticJoint(shoulderCenter,previous==null?null:previous.shoulderCenter,null,"torso",0,.13f);
    spine=probabilisticJoint(spine,previous==null?null:previous.spine,null,"torso",0,.14f);
    hipCenter=probabilisticJoint(hipCenter,previous==null?null:previous.hipCenter,null,"torso",0,.14f);
    ls=probabilisticJoint(ls,previous==null?null:previous.leftShoulder,shoulderCenter,"shoulder",-1,.16f);
    rs=probabilisticJoint(rs,previous==null?null:previous.rightShoulder,shoulderCenter,"shoulder",1,.16f);
    lh=probabilisticJoint(lh,previous==null?null:previous.leftHip,hipCenter,"hip",-1,.15f);
    rh=probabilisticJoint(rh,previous==null?null:previous.rightHip,hipCenter,"hip",1,.15f);
    lel=probabilisticJoint(lel,previous==null?null:previous.leftElbow,ls,"elbow",-1,.19f);
    rel=probabilisticJoint(rel,previous==null?null:previous.rightElbow,rs,"elbow",1,.19f);
    lw=probabilisticJoint(lw,previous==null?null:previous.leftWrist,lel,"wrist",-1,.18f);
    rw=probabilisticJoint(rw,previous==null?null:previous.rightWrist,rel,"wrist",1,.18f);
    lhand=probabilisticJoint(lhand,previous==null?null:previous.leftHand,lw,"hand",-1,.24f);
    rhand=probabilisticJoint(rhand,previous==null?null:previous.rightHand,rw,"hand",1,.24f);
    lk=probabilisticJoint(lk,previous==null?null:previous.leftKnee,lh,"knee",-1,.20f);
    rk=probabilisticJoint(rk,previous==null?null:previous.rightKnee,rh,"knee",1,.20f);
    la=probabilisticJoint(la,previous==null?null:previous.leftAnkle,lk,"ankle",-1,.18f);
    ra=probabilisticJoint(ra,previous==null?null:previous.rightAnkle,rk,"ankle",1,.18f);
    lfoot=probabilisticJoint(lfoot,previous==null?null:previous.leftFoot,la,"foot",-1,.23f);
    rfoot=probabilisticJoint(rfoot,previous==null?null:previous.rightFoot,ra,"foot",1,.23f);

    head=refineJoint(head,.085f,previous==null?null:previous.head); shoulderCenter=refineJoint(shoulderCenter,.075f,previous==null?null:previous.shoulderCenter);
    spine=refineJoint(spine,.085f,previous==null?null:previous.spine); hipCenter=refineJoint(hipCenter,.085f,previous==null?null:previous.hipCenter);
    ls=refineJoint(ls,.075f,previous==null?null:previous.leftShoulder);rs=refineJoint(rs,.075f,previous==null?null:previous.rightShoulder);
    lh=refineJoint(lh,.075f,previous==null?null:previous.leftHip);rh=refineJoint(rh,.075f,previous==null?null:previous.rightHip);
    lel=refineJoint(lel,.065f,previous==null?null:previous.leftElbow);rel=refineJoint(rel,.065f,previous==null?null:previous.rightElbow);
    lw=refineJoint(lw,.055f,previous==null?null:previous.leftWrist);rw=refineJoint(rw,.055f,previous==null?null:previous.rightWrist);
    lk=refineJoint(lk,.075f,previous==null?null:previous.leftKnee);rk=refineJoint(rk,.075f,previous==null?null:previous.rightKnee);
    la=refineJoint(la,.060f,previous==null?null:previous.leftAnkle);ra=refineJoint(ra,.060f,previous==null?null:previous.rightAnkle);

    set(s.head,"head",head,cal,confidence(head,.90f));
    set(s.shoulderCenter,"shoulder_center",shoulderCenter,cal,confidence(shoulderCenter,.96f));
    set(s.spine,"spine",spine,cal,confidence(spine,.96f));set(s.hipCenter,"hip_center",hipCenter,cal,confidence(hipCenter,.96f));
    set(s.leftShoulder,"left_shoulder",ls,cal,confidence(ls,.92f));set(s.rightShoulder,"right_shoulder",rs,cal,confidence(rs,.92f));
    set(s.leftElbow,"left_elbow",lel,cal,confidence(lel,.82f));set(s.rightElbow,"right_elbow",rel,cal,confidence(rel,.82f));
    set(s.leftWrist,"left_wrist",lw,cal,confidence(lw,.76f));set(s.rightWrist,"right_wrist",rw,cal,confidence(rw,.76f));
    set(s.leftHand,"left_hand",lhand,cal,confidence(lhand,.72f));set(s.rightHand,"right_hand",rhand,cal,confidence(rhand,.72f));
    set(s.leftHip,"left_hip",lh,cal,confidence(lh,.90f));set(s.rightHip,"right_hip",rh,cal,confidence(rh,.90f));
    set(s.leftKnee,"left_knee",lk,cal,confidence(lk,.80f));set(s.rightKnee,"right_knee",rk,cal,confidence(rk,.80f));
    set(s.leftAnkle,"left_ankle",la,cal,confidence(la,.72f));set(s.rightAnkle,"right_ankle",ra,cal,confidence(ra,.72f));
    set(s.leftFoot,"left_foot",lfoot,cal,confidence(lfoot,.68f));set(s.rightFoot,"right_foot",rfoot,cal,confidence(rfoot,.68f));

    // The segmented metric cloud owns body scale.  Fit the articulated model to
    // that scale before temporal recovery so an occlusion cannot shrink a limb.
    conformPoseToCloudScale(s,previous);
    recoverOccluded(s,previous,cal);
    // Fixed geometric priors only: do not let an early tracking mistake become a
    // learned body model. Current segmented depth and static anatomy remain authoritative.
    enforceSymmetry(s);stabilizeTorso(s);enforceAxialBodyProportions(s);clampFeetToFloor(s);fusePoseToCloud(s,previous);
    // A limb joint is useful only when the segmented metric surface supports it.
    // Snap plausible peripheral joints to the nearest same-side body surface and
    // suppress unsupported estimates instead of rendering a confident but false
    // skeleton floating over the point cloud.
    enforcePeripheralCloudSupport(s,previous);
    // Global/learned scale is a prior only. Apply it BEFORE the final metric-cloud
    // limb solve; otherwise it shortens correctly observed arms/legs back toward
    // generic anthropometric proportions.
    conformPoseToCloudScale(s,previous);
    // Final authority belongs to same-side metric depth evidence. Nothing after
    // this stage is allowed to shrink distal joints back toward the torso.
    anchorDistalLimbsToCloud(s,previous);
    // Sanitize once more before confidence/model learning. Raw extremity evidence is
    // allowed to suggest direction, never to teach an impossible limb length.
    enforcePublicationPose(s,previous,cal);
    recomputeJointEvidenceConfidence(s,previous);
    updateJointMotionState(s,previous);
    reproject(s,cal);
    return s;
  }

  void buildCloud(SkeletonDepthBodyMask body,InfraredFrame infrared,SkeletonCalibration3D cal){
    samples.clear();int stride=max(1,body.step<=3?2:1);boolean useIr=infrared!=null&&infrared.samples!=null&&infrared.width>0&&infrared.height>0;
    for(int gy=body.minGY;gy<=body.maxGY;gy+=stride)for(int gx=body.minGX;gx<=body.maxGX;gx+=stride){
      int i=gy*body.gridW+gx;if(!body.mask[i])continue;int mm=body.mm[i];if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm)continue;
      int u=body.px(gx),v=body.py(gy);float irQ=1.0f;
      if(useIr){int iu=constrain(round(u*(infrared.width/(float)max(1,cal.sharedCalibration.depthWidth))),0,infrared.width-1),iv=constrain(round(v*(infrared.height/(float)max(1,cal.sharedCalibration.depthHeight))),0,infrared.height-1);int raw=infrared.samples[iv*infrared.width+iu]&0xffff;irQ=raw<=0?.22f:constrain(.25f+raw/12000.0f,.25f,1.0f);}
      PVector p=cal.deproject(u,v,mm);if(p!=null&&p.z>0)samples.add(new Body3DCloudSample(p,u,v,irQ));
    }
  }

  boolean buildFrame(SkeletonPose3D previous){
    PVector c=trimmedCenter(samples);if(c==null)return false;frame.center.set(c);
    ArrayList<Body3DCloudSample> upper=new ArrayList<Body3DCloudSample>(),lower=new ArrayList<Body3DCloudSample>();
    int minV=99999,maxV=-1;for(Body3DCloudSample s:samples){minV=min(minV,s.v);maxV=max(maxV,s.v);}float split=lerp(minV,maxV,.52f);
    for(Body3DCloudSample s:samples){if(s.v<split)upper.add(s);else lower.add(s);}PVector cu=trimmedCenter(upper),cl=trimmedCenter(lower);
    if(cu==null||cl==null)return false;PVector up=PVector.sub(cu,cl);if(up.magSq()<1e-6f)up.set(0,-1,0);up.normalize();
    // Kinect camera coordinates use +Y downward. Anatomical up must therefore stay
    // in the -Y hemisphere from the very first frame; never let a partial/cropped
    // silhouette bootstrap the body upside-down.
    PVector cameraUp=new PVector(0,-1,0);if(up.dot(cameraUp)<0)up.mult(-1);
    PVector pcaRight=principalAxis(samples,c,up);if(pcaRight==null)pcaRight=new PVector(1,0,0);pcaRight.sub(PVector.mult(up,pcaRight.dot(up)));if(pcaRight.magSq()<1e-6f)pcaRight.set(1,0,0);pcaRight.normalize();
    // Bootstrap the anatomical left/right axis from the calibrated camera frame.
    // PCA is deliberately NOT authoritative on the first pose: raised/open arms,
    // a chair, cropped legs or another silhouette asymmetry can rotate the largest
    // cloud axis by tens of degrees and poison every limb seed that follows.
    PVector cameraRight=new PVector(1,0,0);cameraRight.sub(PVector.mult(up,cameraRight.dot(up)));if(cameraRight.magSq()<1e-6f)cameraRight.set(1,0,0);cameraRight.normalize();
    if(cameraRight.x<0)cameraRight.mult(-1);if(pcaRight.dot(cameraRight)<0)pcaRight.mult(-1);
    // Keep the anatomical frame camera-dominant. Total-cloud PCA changes whenever an
    // arm is raised, a hand leaves the frame or a chair touches the mask; using it as
    // the body basis creates a feedback loop where one bad pose rotates the next one.
    // A small PCA contribution tolerates mild camera roll without giving limbs control.
    up=PVector.lerp(cameraUp,up,.18f);if(up.magSq()<1e-6f)up.set(cameraUp);up.normalize();
    PVector right=PVector.lerp(cameraRight,pcaRight,.08f);right.sub(PVector.mult(up,right.dot(up)));if(right.magSq()<1e-6f)right.set(cameraRight);right.normalize();
    if(previous!=null&&previous.leftShoulder.tracked()&&previous.rightShoulder.tracked()){
      PVector prevRight=PVector.sub(previous.rightShoulder.world,previous.leftShoulder.world);prevRight.sub(PVector.mult(up,prevRight.dot(up)));float span=prevRight.mag();
      if(span>.16f&&span<.72f){prevRight.normalize();if(prevRight.dot(cameraRight)<0)prevRight.mult(-1);right=PVector.lerp(right,prevRight,.22f);right.sub(PVector.mult(up,right.dot(up)));if(right.magSq()>1e-6f)right.normalize();}
    }
    if(right.dot(cameraRight)<0)right.mult(-1);
    PVector forward=right.cross(up);if(forward.magSq()<1e-6f)forward.set(0,0,1);forward.normalize();
    if(previous!=null&&previous.shoulderCenter.tracked()&&previous.hipCenter.tracked()&&previous.leftShoulder.tracked()&&previous.rightShoulder.tracked()){
      PVector pr=PVector.sub(previous.rightShoulder.world,previous.leftShoulder.world);PVector pu=PVector.sub(previous.shoulderCenter.world,previous.hipCenter.world);
      if(pr.magSq()>1e-6f&&pu.magSq()>1e-6f){pr.normalize();pu.normalize();PVector pf=pr.cross(pu);if(pf.magSq()>1e-6f&&forward.dot(pf)<0)forward.mult(-1);}
    } else if(forward.z<0)forward.mult(-1);
    right=up.cross(forward);right.normalize();
    frame.up.set(up);frame.right.set(right);frame.forward.set(forward);
    frame.minL=frame.minV=frame.minF=Float.POSITIVE_INFINITY;frame.maxL=frame.maxV=frame.maxF=Float.NEGATIVE_INFINITY;
    float[] laterals=new float[samples.size()],verticals=new float[samples.size()],forwards=new float[samples.size()];
    int qi=0;
    for(Body3DCloudSample s:samples){PVector d=PVector.sub(s.p,c);s.lateral=d.dot(right);s.vertical=d.dot(up);s.forward=d.dot(forward);
      frame.minL=min(frame.minL,s.lateral);frame.maxL=max(frame.maxL,s.lateral);frame.minV=min(frame.minV,s.vertical);frame.maxV=max(frame.maxV,s.vertical);frame.minF=min(frame.minF,s.forward);frame.maxF=max(frame.maxF,s.forward);
      laterals[qi]=s.lateral;verticals[qi]=s.vertical;forwards[qi]=s.forward;qi++;}
    frame.rawMinV=frame.minV;frame.rawMaxV=frame.maxV;frame.rawHeight=frame.rawMaxV-frame.rawMinV;
    Arrays.sort(laterals);Arrays.sort(verticals);Arrays.sort(forwards);
    if(verticals.length>=24){
      float robustMin=sortedQuantile(verticals,.035f),robustMax=sortedQuantile(verticals,.985f);
      if(robustMax-robustMin>frame.rawHeight*.58f){
        // Lowered hands/forearms are common outliers. Use a robust lower bound so
        // the torso and pelvis stay proportional without letting one depth speckle
        // define the subject height.
        frame.minV=lerp(frame.rawMinV,robustMin,.88f);frame.maxV=lerp(frame.rawMaxV,robustMax,.18f);
      }
      // Chairs/background fragments can be connected to the person mask.  Width and
      // depth therefore use robust support instead of raw extrema; true extended
      // limbs still occupy enough pixels to survive these very mild percentiles.
      float robustMinL=sortedQuantile(laterals,.008f),robustMaxL=sortedQuantile(laterals,.992f);
      if(robustMaxL-robustMinL>.14f){frame.minL=robustMinL;frame.maxL=robustMaxL;}
      float robustMinF=sortedQuantile(forwards,.018f),robustMaxF=sortedQuantile(forwards,.982f);
      if(robustMaxF-robustMinF>.025f){frame.minF=robustMinF;frame.maxF=robustMaxF;}
    }
    frame.height=max(.001f,frame.maxV-frame.minV);frame.width=max(.001f,frame.maxL-frame.minL);frame.depth=max(.001f,frame.maxF-frame.minF);
    return frame.height>.45f&&frame.height<2.6f&&frame.width>.14f&&frame.width<1.6f;
  }

  float sortedQuantile(float[] sorted,float q){
    if(sorted==null||sorted.length==0)return 0;
    q=constrain(q,0,1);float idx=q*(sorted.length-1);int lo=floor(idx),hi=min(sorted.length-1,lo+1);float t=idx-lo;
    return lerp(sorted[lo],sorted[hi],t);
  }

  PVector trimmedCenter(ArrayList<Body3DCloudSample> list){
    if(list==null||list.isEmpty())return null;float sx=0,sy=0,sz=0;int n=0;
    for(Body3DCloudSample s:list){sx+=s.p.x;sy+=s.p.y;sz+=s.p.z;n++;}PVector mean=new PVector(sx/n,sy/n,sz/n);
    float[] d=new float[n];for(int i=0;i<n;i++)d[i]=PVector.dist(list.get(i).p,mean);Arrays.sort(d);float gate=d[min(n-1,round((n-1)*.88f))];
    sx=sy=sz=0;n=0;for(Body3DCloudSample s:list)if(PVector.dist(s.p,mean)<=gate){sx+=s.p.x;sy+=s.p.y;sz+=s.p.z;n++;}
    return n==0?mean:new PVector(sx/n,sy/n,sz/n);
  }

  PVector principalAxis(ArrayList<Body3DCloudSample> list,PVector c,PVector reject){
    float xx=0,xy=0,xz=0,yy=0,yz=0,zz=0;for(Body3DCloudSample s:list){PVector d=PVector.sub(s.p,c);float r=d.dot(reject);d.sub(PVector.mult(reject,r));xx+=d.x*d.x;xy+=d.x*d.y;xz+=d.x*d.z;yy+=d.y*d.y;yz+=d.y*d.z;zz+=d.z*d.z;}
    PVector v=new PVector(1,0,0);for(int k=0;k<12;k++){PVector q=new PVector(xx*v.x+xy*v.y+xz*v.z,xy*v.x+yy*v.y+yz*v.z,xz*v.x+yz*v.y+zz*v.z);if(q.magSq()<1e-12f)break;q.normalize();v=q;}return v;
  }


  float bodyGaussian(float x,float center,float sigma){
    float z=(x-center)/max(.0001f,sigma);return exp(-.5f*z*z);
  }

  void estimateTorsoDepthLayer(){
    ArrayList<Float> f=new ArrayList<Float>();
    for(Body3DCloudSample q:samples){float v=normV(q),l=abs(normL(q));if(v>=.42f&&v<=.80f&&l<=.58f)f.add(q.forward);}
    if(f.size()<8){torsoForwardM=0;torsoDepthSpreadM=max(.06f,frame.depth*.30f);return;}
    Collections.sort(f);int n=f.size();torsoForwardM=f.get(n/2);float q1=f.get(n/4),q3=f.get((n*3)/4);torsoDepthSpreadM=constrain(q3-q1,.045f,.24f);
  }
  void estimateTorsoLateralEnvelope(){
    ArrayList<Float> absL=new ArrayList<Float>();float depthGate=max(.060f,torsoDepthSpreadM*1.35f);
    for(Body3DCloudSample q:samples){float v=normV(q);if(v<.34f||v>.78f||abs(q.forward-torsoForwardM)>depthGate)continue;absL.add(abs(q.lateral));}
    float H=constrain(frame.height,.85f,2.25f);
    if(absL.size()>=12){Collections.sort(absL);float q78=absL.get(constrain(round((absL.size()-1)*.78f),0,absL.size()-1));
      float measured=constrain(q78,H*.075f,H*.19f);torsoHalfWidthM=lerp(torsoHalfWidthM,measured,.48f);
    }else torsoHalfWidthM=constrain(torsoHalfWidthM,H*.075f,H*.19f);
    shoulderHalfWidthM=constrain(torsoHalfWidthM*.96f,H*.105f,H*.235f);
    hipHalfWidthM=constrain(torsoHalfWidthM*.64f,H*.070f,H*.165f);
  }
  float torsoLateralNorm(Body3DCloudSample q){return q==null?0:q.lateral/max(.055f,torsoHalfWidthM);}

  float frontOfTorso(Body3DCloudSample q){return q==null?0:torsoForwardM-q.forward;}
  float armDepthEvidence(Body3DCloudSample q){return constrain((frontOfTorso(q)+.015f)/max(.055f,torsoDepthSpreadM*.72f),0,1);}
  void classifyBodyPartProbabilities(){
    if(samples.isEmpty())return;
    for(Body3DCloudSample q:samples){
      float v=normV(q),l=torsoLateralNorm(q),a=abs(l),sideL=constrain(-l,0,3.2f),sideR=constrain(l,0,3.2f),front=armDepthEvidence(q);
      float center=bodyGaussian(l,0,.42f);
      float outward=constrain((a-.72f)/1.45f,0,1);
      float handOut=constrain((a-1.25f)/1.75f,0,1);
      float legOut=constrain((a-.22f)/1.05f,0,1);
      float head=bodyGaussian(v,.91f,.105f)*bodyGaussian(l,0,.36f);
      float torso=bodyGaussian(v,.56f,.20f)*(0.25f+0.75f*center);
      float armBand=max(bodyGaussian(v,.62f,.25f),bodyGaussian(v,.90f,.22f)*(.40f+.60f*outward));
      // Foreground depth is decisive when an arm crosses the torso in image space.
      // Below the pelvis, arm probability requires either lateral separation or a
      // clear foreground layer so shin/ankle points cannot become lowered arms.
      float lowArmGate=v>=.34f?1.0f:constrain(max(outward*.92f,front),0,1);
      armBand*=lowArmGate*(.62f+.38f*front);
      float legBand=bodyGaussian(v,.24f,.18f)*lerp(1.0f,.58f,front);
      float handBand=max(bodyGaussian(v,.56f,.31f),bodyGaussian(v,.94f,.20f)*(.45f+.55f*handOut))*lowArmGate*(.58f+.42f*front);
      float footBand=bodyGaussian(v,.055f,.085f);
      float leftGate=constrain(sideL/.78f,0,1),rightGate=constrain(sideR/.78f,0,1);
      // Raised forearms and hands legitimately approach or cross the body centerline.
      // Keep a modest bilateral probability there; root-distance and temporal
      // constraints later resolve the side without making overhead poses disappear.
      float overhead=constrain((v-.72f)/.24f,0,1)*bodyGaussian(l,0,.50f);
      float crossed=front*bodyGaussian(l,0,.46f)*constrain((v-.28f)/.28f,0,1);
      leftGate=max(leftGate,max(overhead*.46f,crossed*.62f));rightGate=max(rightGate,max(overhead*.46f,crossed*.62f));

      float[] raw=q.bodyProb;
      raw[PART_HEAD]=head;
      raw[PART_TORSO]=torso;
      raw[PART_L_ARM]=armBand*leftGate*(.22f+.78f*outward);
      raw[PART_R_ARM]=armBand*rightGate*(.22f+.78f*outward);
      raw[PART_L_HAND]=handBand*leftGate*(.10f+.90f*handOut);
      raw[PART_R_HAND]=handBand*rightGate*(.10f+.90f*handOut);
      raw[PART_L_LEG]=legBand*leftGate*(.28f+.72f*legOut);
      raw[PART_R_LEG]=legBand*rightGate*(.28f+.72f*legOut);
      raw[PART_L_FOOT]=footBand*leftGate*(.18f+.82f*legOut);
      raw[PART_R_FOOT]=footBand*rightGate*(.18f+.82f*legOut);

      // IR is confidence evidence, not a class discriminator. Keep a floor so
      // Xbox 360 frames without strong IR response still classify geometrically.
      float ir=.55f+.45f*constrain(q.irQuality,0,1),sum=0;
      for(int k=0;k<raw.length;k++){raw[k]=max(.0001f,raw[k]*ir);sum+=raw[k];}
      if(sum>0)for(int k=0;k<raw.length;k++)raw[k]/=sum;
    }
  }

  float bodyPartProbability(Body3DCloudSample q,String role,int side){
    if(q==null)return 0;
    float[] p=q.bodyProb;float v=normV(q),l=normL(q),sl=side==0?0:l*side;
    if("head".equals(role))return p[PART_HEAD];
    if("torso".equals(role))return p[PART_TORSO];
    if("shoulder".equals(role)){
      float arm=side<0?p[PART_L_ARM]:p[PART_R_ARM];
      return constrain((.48f*p[PART_TORSO]+.52f*arm)*bodyGaussian(v,.72f,.105f)*(.55f+.45f*constrain(sl/.55f,0,1)),0,1);
    }
    if("elbow".equals(role))return side<0?p[PART_L_ARM]:p[PART_R_ARM];
    if("wrist".equals(role)){
      float arm=side<0?p[PART_L_ARM]:p[PART_R_ARM],hand=side<0?p[PART_L_HAND]:p[PART_R_HAND];
      return constrain(.58f*arm+.42f*hand,0,1);
    }
    if("hand".equals(role))return side<0?p[PART_L_HAND]:p[PART_R_HAND];
    if("hip".equals(role)){
      float leg=side<0?p[PART_L_LEG]:p[PART_R_LEG];
      return constrain((.55f*p[PART_TORSO]+.45f*leg)*bodyGaussian(v,.40f,.11f),0,1);
    }
    if("knee".equals(role))return side<0?p[PART_L_LEG]:p[PART_R_LEG];
    if("ankle".equals(role)){
      float leg=side<0?p[PART_L_LEG]:p[PART_R_LEG],foot=side<0?p[PART_L_FOOT]:p[PART_R_FOOT];
      return constrain(.72f*leg+.28f*foot,0,1);
    }
    if("foot".equals(role))return side<0?p[PART_L_FOOT]:p[PART_R_FOOT];
    return 0;
  }

  PVector probabilisticJoint(PVector seed,SkeletonJoint3D prior,PVector parent,String role,int side,float radius){
    if(seed==null||samples.isEmpty())return seed;
    ArrayList<Body3DCloudSample> candidates=new ArrayList<Body3DCloudSample>();
    ArrayList<Float> weights=new ArrayList<Float>();
    float maxW=0;
    for(Body3DCloudSample q:samples){
      if(!sampleFitsAnatomicalRegion(q,role,side))continue;
      float d=PVector.dist(seed,q.p);if(d>radius)continue;
      float classP=bodyPartProbability(q,role,side);if(classP<.015f)continue;
      float spatial=exp(-.5f*(d/max(.018f,radius*.48f))*(d/max(.018f,radius*.48f)));
      float temporal=1.0f;
      if(prior!=null&&prior.tracked()){
        float pd=PVector.dist(prior.world,q.p);
        // Keep identity continuity strong without creating a narrow accept/reject
        // basin.  A wider sigma prevents a real fast-moving hand from vanishing
        // for one frame and then being reacquired on another surface.
        float temporalSigma=("hand".equals(role)||"wrist".equals(role)||"elbow".equals(role))?.18f:.20f;
        temporal=.32f+.68f*exp(-.5f*(pd/temporalSigma)*(pd/temporalSigma));
      }
      float depthChain=1.0f;
      if(parent!=null&&("hand".equals(role)||"wrist".equals(role)||"elbow".equals(role))){
        float pf=PVector.sub(parent,frame.center).dot(frame.forward);
        float df=abs(q.forward-pf),sigma=max(.055f,torsoDepthSpreadM*.95f);
        // Depth continuity is a soft score, never a hard gate.  This retains the
        // correct arm through torso crossings while avoiding threshold chatter.
        depthChain=.58f+.42f*exp(-.5f*(df/sigma)*(df/sigma));
        if(abs(normL(q))<.34f)depthChain*=.90f+.10f*armDepthEvidence(q);
      }
      float bone=1.0f;
      if(parent!=null){
        float target=PVector.dist(parent,seed),observed=PVector.dist(parent,q.p);
        float sigma=max(.045f,target*.30f);
        bone=.40f+.60f*exp(-.5f*((observed-target)/sigma)*((observed-target)/sigma));
      }
      float w=classP*spatial*temporal*depthChain*bone*(.55f+.45f*q.irQuality);
      if(w<=0)continue;candidates.add(q);weights.add(w);maxW=max(maxW,w);
    }
    if(candidates.size()<3||maxW<=0)return seed;
    PVector c=new PVector();float sw=0;int support=0;
    // Keep only the high-likelihood mode, not the full body-part cloud. This
    // prevents an elbow centroid from drifting toward the whole upper arm.
    for(int i=0;i<candidates.size();i++){
      float w=weights.get(i);if(w<maxW*.42f)continue;
      c.add(PVector.mult(candidates.get(i).p,w));sw+=w;support++;
    }
    if(sw<=0||support<2)return seed;c.div(sw);
    float evidence=constrain((support-1)/9.0f,0,1);
    float blend=lerp(.28f,.78f,evidence);
    if("shoulder".equals(role)||"hip".equals(role))blend=min(blend,.62f);
    if("hand".equals(role)||"foot".equals(role))blend=max(blend,.58f);
    return PVector.lerp(seed,c,blend);
  }

  float normV(Body3DCloudSample s){return (s.vertical-frame.minV)/max(1e-5f,frame.height);}float normL(Body3DCloudSample s){return s.lateral/max(.05f,frame.width*.5f);}
  PVector regionCenter(float vlo,float vhi,float llo,float lhi,boolean frontBias){
    ArrayList<Body3DCloudSample> a=new ArrayList<Body3DCloudSample>();for(Body3DCloudSample s:samples){float v=normV(s),l=normL(s);if(v>=vlo&&v<=vhi&&l>=llo&&l<=lhi)a.add(s);}if(a.isEmpty())return null;
    PVector c=trimmedCenter(a);if(frontBias){float best=-Float.MAX_VALUE;PVector bp=c;for(Body3DCloudSample s:a)if(s.forward>best){best=s.forward;bp=s.p;}c=PVector.lerp(c,bp,.14f);}return c;
  }
  PVector torsoRegionCenter(float vlo,float vhi,float lateralLimit,float centerSigma){
    PVector sum=new PVector();float sw=0;int count=0;
    float depthSigma=max(.050f,torsoDepthSpreadM*.82f);
    for(Body3DCloudSample s:samples){
      float v=normV(s),l=normL(s);if(v<vlo||v>vhi||abs(l)>lateralLimit)continue;
      float front=armDepthEvidence(s);
      float w=bodyGaussian(l,0,max(.08f,centerSigma))*bodyGaussian(s.forward,torsoForwardM,depthSigma);
      w*=1.0f-constrain(front*.82f,0,.82f);
      if(v<.22f)w*=constrain((v-.06f)/.16f,0,1);
      if(w<=0)continue;
      sum.add(PVector.mult(s.p,w));sw+=w;count++;
    }
    if(sw>0&&count>=6){sum.div(sw);return sum;}
    return regionCenter(vlo,vhi,-lateralLimit,lateralLimit,false);
  }
  PVector shoulderSideRegion(int side,float vlo,float vhi,float inner,float outer){
    PVector sum=new PVector();float sw=0;int count=0;float target=shoulderHalfWidthM*side,halfBand=max(.045f,torsoHalfWidthM*.42f);
    for(Body3DCloudSample q:samples){float v=normV(q);if(v<vlo||v>vhi)continue;float lateralError=abs(q.lateral-target);if(lateralError>halfBand)continue;
      float w=bodyGaussian(q.lateral,target,max(.030f,halfBand*.42f))*bodyGaussian(q.forward,torsoForwardM,max(.050f,torsoDepthSpreadM*.88f));
      w*=.55f+.45f*q.irQuality;if(w<=0)continue;sum.add(PVector.mult(q.p,w));sw+=w;count++;}
    if(sw>0&&count>=4){sum.div(sw);return sum;}
    PVector c=torsoRegionCenter(vlo,vhi,.30f,.13f);return c==null?null:PVector.add(c,PVector.mult(frame.right,target));
  }
  PVector hipSideRegion(int side,float vlo,float vhi,float inner,float outer){
    PVector sum=new PVector();float sw=0;int count=0;float target=hipHalfWidthM*side,halfBand=max(.040f,torsoHalfWidthM*.34f);
    for(Body3DCloudSample q:samples){float v=normV(q);if(v<vlo||v>vhi)continue;float lateralError=abs(q.lateral-target);if(lateralError>halfBand)continue;float front=armDepthEvidence(q);
      float w=bodyGaussian(q.lateral,target,max(.028f,halfBand*.44f))*bodyGaussian(q.forward,torsoForwardM,max(.048f,torsoDepthSpreadM*.80f));w*=1.0f-constrain(front*.72f,0,.72f);
      if(w<=0)continue;sum.add(PVector.mult(q.p,w));sw+=w;count++;}
    if(sw>0&&count>=4){sum.div(sw);return sum;}
    PVector c=torsoRegionCenter(vlo,vhi,.26f,.12f);return c==null?null:PVector.add(c,PVector.mult(frame.right,target));
  }
  PVector sideRegionCenter(int side,float vlo,float vhi,float inner,float outer){
    ArrayList<Body3DCloudSample> a=new ArrayList<Body3DCloudSample>();for(Body3DCloudSample s:samples){float v=normV(s),l=normL(s)*side;if(v>=vlo&&v<=vhi&&l>=inner&&l<=outer)a.add(s);}return trimmedCenter(a);
  }

  PVector extremity(int side,boolean arm,PVector root,PVector hip,SkeletonJoint3D prior){
    if(root==null)return null;Body3DCloudSample best=null;float bestScore=-Float.MAX_VALUE;
    float H=constrain(frame.height,.90f,2.20f);
    // Reach is a feasibility bound, never a reward.  The previous implementation
    // rewarded the farthest point and could therefore select a shin/chair edge as a
    // hand.  Human limb proportions give us a safe envelope even on frame one.
    float maxReach=arm?constrain(H*.47f,.40f,.88f):constrain(H*.68f,.55f,1.20f);
    float minReach=arm?max(.075f,H*.055f):max(.16f,H*.16f);
    String role=arm?"hand":"foot";
    for(Body3DCloudSample q:samples){
      if(!sampleFitsAnatomicalRegion(q,role,side))continue;
      float v=normV(q),sl=torsoLateralNorm(q)*side,partP=bodyPartProbability(q,role,side),front=armDepthEvidence(q);
      if(partP<(arm?.018f:.016f))continue;
      float reach=PVector.dist(root,q.p);if(reach<minReach||reach>maxReach)continue;
      float score=partP*(arm?.68f:.72f)+q.irQuality*.045f;
      if(arm){score+=front*.10f+constrain(sl+.10f,0,1)*.055f;float normalized=reach/max(maxReach,.001f);score+=.055f*(1.0f-abs(normalized-.68f));}
      else{score+=constrain((.24f-v)/.30f,0,1)*.16f+constrain(sl,0,1)*.035f;}
      if(prior!=null&&prior.tracked()){
        float pd=PVector.dist(prior.world,q.p);if(pd>.46f)continue;
        score+=.30f*(1.0f-constrain(pd/.46f,0,1));
      }
      // Lowered hands near the leg corridor need actual foreground/hand evidence.
      if(arm&&v<.38f&&sl<.24f)score-=.18f*(1.0f-front)*(1.0f-constrain(partP/.16f,0,1));
      if(score>bestScore){bestScore=score;best=q;}
    }
    return best==null?null:best.p.copy();
  }

  float armTargetLength(String key,float defaultLength){
    float learned=anthropometry.target(key,defaultLength);
    return constrain(learned,defaultLength*.72f,defaultLength*1.34f);
  }

  PVector armElbowJoint(PVector shoulder,PVector hand,int side,SkeletonJoint3D prior){
    if(shoulder==null||hand==null)return null;
    float H=constrain(max(.90f,frame.height),.90f,2.20f);
    String prefix=side<0?"l":"r";
    float upper=armTargetLength("upper-arm-"+prefix,H*.185f);
    float fore=armTargetLength("forearm-"+prefix,H*.155f);
    float distal=fore+H*.060f;
    Body3DCloudSample best=null;float bestScore=Float.MAX_VALUE;
    for(Body3DCloudSample q:samples){
      if(!sampleFitsAnatomicalRegion(q,"elbow",side))continue;
      float d0=PVector.dist(shoulder,q.p),d1=PVector.dist(q.p,hand);
      if(d0<upper*.48f||d0>upper*1.58f||d1<distal*.38f||d1>distal*1.75f)continue;
      float score=abs(d0-upper)/max(.05f,upper)+abs(d1-distal)/max(.05f,distal);
      float part=bodyPartProbability(q,"elbow",side);score+=(1.0f-part)*.34f;
      if(prior!=null&&prior.tracked())score+=min(1.2f,PVector.dist(prior.world,q.p)/.30f)*.34f;
      float sl=normL(q)*side,v=normV(q);
      if(v>.72f)score-=constrain(sl+.10f,0,.65f)*.12f;
      if(score<bestScore){bestScore=score;best=q;}
    }
    if(best!=null)return best.p.copy();
    return chainJoint(shoulder,hand,.49f,true,side,prior);
  }

  PVector armWristJoint(PVector elbow,PVector hand,int side,SkeletonJoint3D prior){
    if(elbow==null||hand==null)return null;
    float H=constrain(max(.90f,frame.height),.90f,2.20f);
    String prefix=side<0?"l":"r";
    float fore=armTargetLength("forearm-"+prefix,H*.155f);
    float handLen=H*.060f;
    Body3DCloudSample best=null;float bestScore=Float.MAX_VALUE;
    for(Body3DCloudSample q:samples){
      if(!sampleFitsAnatomicalRegion(q,"wrist",side))continue;
      float d0=PVector.dist(elbow,q.p),d1=PVector.dist(q.p,hand);
      if(d0<fore*.42f||d0>fore*1.62f||d1<.010f||d1>max(.20f,handLen*2.8f))continue;
      float score=abs(d0-fore)/max(.045f,fore)+abs(d1-handLen)/max(.035f,handLen);
      float part=bodyPartProbability(q,"wrist",side);score+=(1.0f-part)*.28f;
      if(prior!=null&&prior.tracked())score+=min(1.2f,PVector.dist(prior.world,q.p)/.26f)*.30f;
      if(score<bestScore){bestScore=score;best=q;}
    }
    if(best!=null)return best.p.copy();
    return chainJoint(elbow,hand,.72f,true,side,prior);
  }

  PVector chainJoint(PVector a,PVector b,float t,boolean arm,int side,SkeletonJoint3D prior){
    if(a==null||b==null)return null;PVector target=PVector.lerp(a,b,t),dir=PVector.sub(b,a);float length=max(.05f,dir.mag());dir.normalize();Body3DCloudSample best=null;float bestScore=Float.MAX_VALUE;
    for(Body3DCloudSample s:samples){float l=normL(s)*side,v=normV(s);if(l<.015f)continue;if(arm&&(v<.10f||v>1.10f))continue;if(!arm&&v>.54f)continue;
      PVector ap=PVector.sub(s.p,a);float along=ap.dot(dir)/length;if(abs(along-t)>.22f)continue;float temporal=0;if(prior!=null&&prior.tracked()){float pd=PVector.dist(prior.world,s.p);if(pd>.38f)continue;temporal=pd*.46f;}
      float score=PVector.dist(s.p,target)+abs(along-t)*.28f+temporal;if(score<bestScore){bestScore=score;best=s;}}
    PVector result=best==null?target:best.p.copy();if(prior!=null&&prior.tracked()&&PVector.dist(result,prior.world)<.24f)result=PVector.lerp(result,prior.world,.10f);return result;
  }

  void estimateFloor(){
    floor.reset();ArrayList<Body3DCloudSample> bottom=new ArrayList<Body3DCloudSample>();
    for(Body3DCloudSample s:samples)if(normV(s)<.10f)bottom.add(s);if(bottom.size()<12)return;
    PVector c=trimmedCenter(bottom);if(c==null)return;float[] offsets=new float[bottom.size()];for(int i=0;i<bottom.size();i++)offsets[i]=PVector.sub(bottom.get(i).p,c).dot(frame.up);Arrays.sort(offsets);
    float median=offsets[offsets.length/2];floor.point.set(PVector.add(c,PVector.mult(frame.up,median)));floor.normal.set(frame.up);floor.valid=true;floor.support=constrain(bottom.size()/80.0f,0,1);
  }

  PVector refineJoint(PVector candidate,float radius,SkeletonJoint3D prior){
    if(candidate==null)return prior!=null&&prior.tracked()?prior.world.copy():null;
    ArrayList<Body3DCloudSample> local=new ArrayList<Body3DCloudSample>();for(Body3DCloudSample s:samples)if(PVector.dist(s.p,candidate)<=radius)local.add(s);
    if(local.size()<3)return candidate;PVector robust=trimmedCenter(local);if(robust==null)return candidate;float dataWeight=constrain(local.size()/18.0f,.18f,.82f);
    PVector out=PVector.lerp(candidate,robust,dataWeight*.55f);if(prior!=null&&prior.tracked()&&PVector.dist(prior.world,out)<.22f)out=PVector.lerp(out,prior.world,.10f);return out;
  }

  void recoverOccluded(SkeletonPose3D current,SkeletonPose3D previous,SkeletonCalibration3D cal){
    if(current==null||previous==null||!current.hipCenter.tracked()||!previous.hipCenter.tracked())return;PVector translation=PVector.sub(current.hipCenter.world,previous.hipCenter.world);
    SkeletonJoint3D[] now=current.canonicalJoints(),old=previous.canonicalJoints();int n=min(now.length,old.length);for(int i=0;i<n;i++){if(now[i]==null||old[i]==null||now[i].tracked()||!old[i].tracked())continue;
      String key=old[i].name;int age=occlusionAge.containsKey(key)?occlusionAge.get(key)+1:1;occlusionAge.put(key,age);if(age>cfg.poseOcclusionHoldFrames)continue;
      PVector predicted=PVector.add(old[i].world,translation);PVector vel=jointVelocity.get(key);if(vel!=null){float decay=pow(.78f,max(0,age-1));PVector step=PVector.mult(vel,decay);if(step.mag()>.045f)step.mult(.045f/step.mag());predicted.add(step);}
      if(PVector.dist(predicted,current.hipCenter.world)>1.45f)continue;
      // Search locally, but only reacquire from the anatomical region belonging to
      // this joint.  With no evidence keep the kinematic prediction instead of
      // snapping to torso/other limb surfaces.
      String role=roleForJoint(key);int side=sideForJoint(key);float reacquireRadius=("hand".equals(role)||"wrist".equals(role))?.165f:("elbow".equals(role)?.145f:.110f);
      PVector evidence=nearestRegionEvidence(predicted,role,side,reacquireRadius);
      boolean reacquired=evidence!=null;PVector out=reacquired?PVector.lerp(predicted,evidence,.68f):predicted;
      PVector image=cal.projectWorldRgb(out);if(image==null)image=cal.projectDepth(out);if(image==null)continue;now[i].world.set(out);now[i].image.set(image);
      now[i].confidence=reacquired?max(.34f,old[i].confidence*.72f):max(.10f,old[i].confidence*pow(.78f,age));now[i].state=reacquired&&now[i].confidence>.62f?2:1;if(reacquired)occlusionAge.put(key,0);
    }
  }

  String roleForJoint(String n){if(n==null)return "";if(n.indexOf("shoulder")>=0)return "shoulder";if(n.indexOf("elbow")>=0)return "elbow";if(n.indexOf("wrist")>=0)return "wrist";if(n.indexOf("hand")>=0)return "hand";if(n.indexOf("hip")>=0)return "hip";if(n.indexOf("knee")>=0)return "knee";if(n.indexOf("ankle")>=0)return "ankle";if(n.indexOf("foot")>=0)return "foot";if(n.indexOf("head")>=0)return "head";return "";}
  int sideForJoint(String n){if(n==null)return 0;if(n.startsWith("left_"))return -1;if(n.startsWith("right_"))return 1;return 0;}
  PVector nearestRegionEvidence(PVector p,String role,int side,float radius){Body3DCloudSample best=null;float bd=radius;for(Body3DCloudSample q:samples){if(!sampleFitsAnatomicalRegion(q,role,side))continue;float d=PVector.dist(p,q.p);if(d<bd){bd=d;best=q;}}return best==null?null:best.p.copy();}

  void conformPoseToCloudScale(SkeletonPose3D s,SkeletonPose3D previous){
    if(s==null||frame==null)return;float measured=constrain(frame.height,.85f,2.25f);
    if(!cloudScaleInitialized){cloudScaleM=measured;cloudScaleInitialized=true;}else cloudScaleM=lerp(cloudScaleM,measured,.12f);float H=cloudScaleM;
    // Human proportions are soft targets, not hard assumptions. Learned reliable
    // lengths win; cloud-derived targets prevent the model collapsing when a limb
    // temporarily disappears.
    cloudBone("upper-arm-l",s.leftShoulder,s.leftElbow,H*.185f,.30f);cloudBone("forearm-l",s.leftElbow,s.leftWrist,H*.155f,.30f);
    cloudBone("upper-arm-r",s.rightShoulder,s.rightElbow,H*.185f,.30f);cloudBone("forearm-r",s.rightElbow,s.rightWrist,H*.155f,.30f);
    cloudBone("thigh-l",s.leftHip,s.leftKnee,H*.255f,.34f);cloudBone("shin-l",s.leftKnee,s.leftAnkle,H*.250f,.34f);
    cloudBone("thigh-r",s.rightHip,s.rightKnee,H*.255f,.34f);cloudBone("shin-r",s.rightKnee,s.rightAnkle,H*.250f,.34f);
    // Shoulder/hip spans follow the current metric silhouette so the skeleton grows
    // and shrinks with the sphere cloud rather than with viewport zoom.
    cloudSpan(s.leftShoulder,s.rightShoulder,s.shoulderCenter,constrain(shoulderHalfWidthM*2.0f,H*.18f,H*.34f),.34f);
    cloudSpan(s.leftHip,s.rightHip,s.hipCenter,constrain(hipHalfWidthM*2.0f,H*.10f,H*.22f),.28f);
  }
  void enforceAxialBodyProportions(SkeletonPose3D s){
    if(s==null||!s.shoulderCenter.tracked()||!s.hipCenter.tracked())return;float H=constrain(max(frame.height,cloudScaleM),.90f,2.25f);
    PVector axis=frame.up.copy();if(axis.magSq()<1e-6f)axis.set(0,-1,0);axis.normalize();
    float torso=PVector.dist(s.shoulderCenter.world,s.hipCenter.world),minTorso=H*.255f,maxTorso=H*.355f;
    if(torso<minTorso||torso>maxTorso){PVector d=PVector.sub(s.shoulderCenter.world,s.hipCenter.world);if(d.magSq()<1e-6f)d.set(axis);d.normalize();if(d.dot(axis)<0)d.mult(-1);float target=constrain(torso,minTorso,maxTorso);s.shoulderCenter.world.set(PVector.add(s.hipCenter.world,PVector.mult(d,target)));}
    // Preserve the measured foot layer while preventing a collapsed lower body.
    axialLeg(s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot,H);axialLeg(s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot,H);
    if(s.spine.tracked()){PVector target=PVector.lerp(s.hipCenter.world,s.shoulderCenter.world,.52f);s.spine.world.set(PVector.lerp(s.spine.world,target,.48f));}
  }
  void axialLeg(SkeletonJoint3D hip,SkeletonJoint3D knee,SkeletonJoint3D ankle,SkeletonJoint3D foot,float H){
    if(hip==null||knee==null||ankle==null||!hip.tracked()||!knee.tracked()||!ankle.tracked())return;
    float thigh=PVector.dist(hip.world,knee.world),shin=PVector.dist(knee.world,ankle.world),minThigh=H*.205f,minShin=H*.205f;
    if(thigh<minThigh){PVector d=PVector.sub(knee.world,hip.world);if(d.magSq()<1e-6f)d=PVector.mult(frame.up,-1);d.normalize();knee.world.set(PVector.add(hip.world,PVector.mult(d,minThigh)));}
    if(shin<minShin){PVector d=PVector.sub(ankle.world,knee.world);if(d.magSq()<1e-6f)d=PVector.mult(frame.up,-1);d.normalize();ankle.world.set(PVector.add(knee.world,PVector.mult(d,minShin)));}
    if(foot!=null&&foot.tracked()&&PVector.dist(ankle.world,foot.world)<H*.055f){PVector d=frame.forward.copy();if(d.magSq()<1e-6f)d.set(0,0,1);d.normalize();foot.world.set(PVector.add(ankle.world,PVector.mult(d,H*.075f)));}
  }

  void cloudBone(String key,SkeletonJoint3D a,SkeletonJoint3D b,float defaultLength,float strength){if(a==null||b==null||!a.tracked()||!b.tracked())return;float len=PVector.dist(a.world,b.world);if(len<1e-5f)return;float learned=anthropometry.target(key,defaultLength);float rel=anthropometry.reliability(key);float target=lerp(defaultLength,learned,rel*.72f);target=constrain(target,defaultLength*.72f,defaultLength*1.35f);PVector d=PVector.sub(b.world,a.world);d.mult(lerp(len,target,strength)/len);b.world.set(PVector.add(a.world,d));}
  void cloudSpan(SkeletonJoint3D a,SkeletonJoint3D b,SkeletonJoint3D center,float target,float strength){if(a==null||b==null||center==null||!a.tracked()||!b.tracked()||!center.tracked())return;PVector axis=PVector.sub(b.world,a.world);if(axis.magSq()<1e-7f)axis.set(frame.right);axis.normalize();if(axis.dot(frame.right)<0)axis.mult(-1);float half=target*.5f;PVector ta=PVector.sub(center.world,PVector.mult(axis,half)),tb=PVector.add(center.world,PVector.mult(axis,half));a.world.set(PVector.lerp(a.world,ta,strength));b.world.set(PVector.lerp(b.world,tb,strength));}
  void updateJointMotionState(SkeletonPose3D s,SkeletonPose3D previous){if(s==null)return;for(SkeletonJoint3D j:s.canonicalJoints()){if(j==null||!j.tracked()||j.name==null)continue;PVector old=lastJointWorld.get(j.name);if(old!=null){PVector dv=PVector.sub(j.world,old);PVector v=jointVelocity.get(j.name);if(v==null)v=new PVector();v=PVector.lerp(v,dv,.34f);if(v.mag()>.12f)v.mult(.12f/v.mag());jointVelocity.put(j.name,v);}lastJointWorld.put(j.name,j.world.copy());if(j.state==2)occlusionAge.put(j.name,0);}}


  void fusePoseToCloud(SkeletonPose3D s,SkeletonPose3D previous){if(s==null||samples.size()<40)return;
    fuseJointCloud(s.leftShoulder,"shoulder",-1,.075f,.22f,.032f);fuseJointCloud(s.rightShoulder,"shoulder",1,.075f,.22f,.032f);
    fuseJointCloud(s.leftElbow,"elbow",-1,.070f,.42f,.042f);fuseJointCloud(s.rightElbow,"elbow",1,.070f,.42f,.042f);
    fuseJointCloud(s.leftWrist,"wrist",-1,.060f,.48f,.045f);fuseJointCloud(s.rightWrist,"wrist",1,.060f,.48f,.045f);
    fuseJointCloud(s.leftHand,"hand",-1,.065f,.58f,.052f);fuseJointCloud(s.rightHand,"hand",1,.065f,.58f,.052f);
    fuseJointCloud(s.leftHip,"hip",-1,.080f,.20f,.030f);fuseJointCloud(s.rightHip,"hip",1,.080f,.20f,.030f);
    fuseJointCloud(s.leftKnee,"knee",-1,.075f,.40f,.042f);fuseJointCloud(s.rightKnee,"knee",1,.075f,.40f,.042f);
    fuseJointCloud(s.leftAnkle,"ankle",-1,.065f,.48f,.045f);fuseJointCloud(s.rightAnkle,"ankle",1,.065f,.48f,.045f);
    fuseJointCloud(s.leftFoot,"foot",-1,.075f,.55f,.050f);fuseJointCloud(s.rightFoot,"foot",1,.075f,.55f,.050f);
    fuseJointCloud(s.head,"head",0,.095f,.18f,.026f);
  }
  void fuseJointCloud(SkeletonJoint3D j,String role,int side,float radius,float strength,float maxShift){if(j==null||!j.tracked()||j.world==null)return;ArrayList<Body3DCloudSample> local=new ArrayList<Body3DCloudSample>();
    for(Body3DCloudSample q:samples)if(PVector.dist(q.p,j.world)<=radius&&sampleFitsAnatomicalRegion(q,role,side))local.add(q);if(local.size()<4)return;PVector target=trimmedCenter(local);if(target==null)return;PVector delta=PVector.sub(target,j.world);float len=delta.mag();if(len>maxShift&&len>1e-6f)delta.mult(maxShift/len);float evidence=constrain(local.size()/14.0f,.18f,1.0f)*lerp(.55f,1.0f,j.confidence);j.world.add(PVector.mult(delta,strength*evidence));j.confidence=constrain(j.confidence+.06f*evidence,0,1);}

  // Anatomical region lock.  Candidate surface points must live in the body zone
  // assigned to the joint before they are allowed to influence it.  This prevents
  // hands/elbows from stealing torso samples and prevents left/right limb swaps.
  boolean sampleFitsAnatomicalRegion(Body3DCloudSample q,String role,int side){if(q==null)return false;float v=normV(q),l=torsoLateralNorm(q);float sl=side==0?0:l*side;
    if("head".equals(role))return v>=.76f&&v<=1.08f&&abs(l)<=1.45f;
    if("shoulder".equals(role))return v>=.56f&&v<=.89f&&sl>=.38f&&sl<=1.65f;
    if("elbow".equals(role)){float front=armDepthEvidence(q);return v>=.18f&&v<=1.08f&&sl>=(v>.72f?-.70f:(v<.38f&&front>.50f?-.42f:.10f));}
    if("wrist".equals(role)){float front=armDepthEvidence(q);return v>=.14f&&v<=1.10f&&sl>=(v>.72f?-.95f:(v<.36f&&front>.48f?-.55f:.12f));}
    if("hand".equals(role)){float front=armDepthEvidence(q);return v>=.10f&&v<=1.12f&&sl>=(v>.72f?-1.15f:(v<.34f&&front>.46f?-.72f:.14f));}
    if("hip".equals(role))return v>=.24f&&v<=.58f&&sl>=.20f&&sl<=1.35f;
    if("knee".equals(role))return v>=.06f&&v<=.50f&&sl>=.08f;
    if("ankle".equals(role))return v>=-.06f&&v<=.29f&&sl>=.05f;
    if("foot".equals(role))return v>=-.09f&&v<=.25f&&sl>=.03f;
    return true;
  }
  SkeletonJoint3D previousJoint(SkeletonPose3D previous,String name){if(previous==null||name==null)return null;for(SkeletonJoint3D j:previous.canonicalJoints())if(j!=null&&name.equals(j.name))return j;return null;}

  void anchorDistalLimbsToCloud(SkeletonPose3D s,SkeletonPose3D previous){
    if(s==null||samples.size()<60)return;
    anchorLimb(s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand,-1,true,previous==null?null:previous.leftHand);
    anchorLimb(s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand,1,true,previous==null?null:previous.rightHand);
    anchorLimb(s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot,-1,false,previous==null?null:previous.leftFoot);
    anchorLimb(s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot,1,false,previous==null?null:previous.rightFoot);
  }
  void anchorLimb(SkeletonJoint3D root,SkeletonJoint3D mid,SkeletonJoint3D nearEnd,SkeletonJoint3D end,int side,boolean arm,SkeletonJoint3D priorEnd){
    if(root==null||!root.tracked()||end==null)return;
    Body3DCloudSample best=null;float bestScore=-Float.MAX_VALUE;
    String endRole=arm?"hand":"foot";float H=constrain(max(.90f,cloudScaleM),.90f,2.20f);
    float maxReach=arm?constrain(H*.47f,.40f,.88f):constrain(H*.68f,.55f,1.20f);
    float minReach=arm?max(.075f,H*.055f):max(.16f,H*.16f);
    boolean currentPlausible=end.tracked()&&PVector.dist(root.world,end.world)<=maxReach*1.08f;
    for(Body3DCloudSample q:samples){
      if(!sampleFitsAnatomicalRegion(q,endRole,side))continue;
      float v=normV(q),sl=torsoLateralNorm(q)*side,partP=bodyPartProbability(q,endRole,side);
      if(partP<(arm?.020f:.018f))continue;
      float reach=PVector.dist(root.world,q.p);if(reach<minReach||reach>maxReach)continue;
      float score=partP*(arm?.66f:.72f)+q.irQuality*.04f;
      if(arm){float front=armDepthEvidence(q);score+=front*.09f+constrain(sl+.12f,0,1)*.045f;if(v<.38f&&sl<.24f)score-=.16f*(1-front);}
      else score+=constrain((.24f-v)/.30f,0,1)*.15f;
      if(priorEnd!=null&&priorEnd.tracked()){
        float pd=PVector.dist(priorEnd.world,q.p);if(pd>.44f)continue;score+=.26f*(1.0f-constrain(pd/.44f,0,1));
      }
      if(currentPlausible){float cd=PVector.dist(end.world,q.p);score+=.12f*(1.0f-constrain(cd/.32f,0,1));}
      if(score>bestScore){bestScore=score;best=q;}
    }
    if(best==null)return;
    PVector target=best.p.copy();float observed=PVector.dist(root.world,target);if(observed<minReach||observed>maxReach)return;
    if(end.tracked()&&PVector.dist(end.world,target)<.020f)return;
    if(!end.tracked()){end.world.set(target);end.state=SkeletonJoint3D.INFERRED;end.confidence=.38f;}
    else{
      // Cloud evidence nudges the endpoint, but never gets permission to teleport
      // a whole limb. The final publication guard below enforces exact reach.
      PVector delta=PVector.sub(target,end.world);float maxShift=arm?.060f:.052f;
      if(delta.mag()>maxShift)delta.setMag(maxShift);end.world.add(PVector.mult(delta,.62f));
    }
    PVector solvedEnd=end.world.copy();
    PVector elbowOrKnee=arm?armElbowJoint(root.world,solvedEnd,side,mid):chainJoint(root.world,solvedEnd,.50f,false,side,mid);
    PVector wristOrAnkle=arm?armWristJoint(elbowOrKnee,solvedEnd,side,nearEnd):chainJoint(root.world,solvedEnd,.86f,false,side,nearEnd);
    if(elbowOrKnee!=null&&mid!=null){mid.world.set(PVector.lerp(mid.world,elbowOrKnee,.56f));mid.state=max(mid.state,SkeletonJoint3D.INFERRED);mid.confidence=max(mid.confidence,.34f);}
    if(wristOrAnkle!=null&&nearEnd!=null){nearEnd.world.set(PVector.lerp(nearEnd.world,wristOrAnkle,.60f));nearEnd.state=max(nearEnd.state,SkeletonJoint3D.INFERRED);nearEnd.confidence=max(nearEnd.confidence,.32f);}
    end.confidence=max(end.confidence,.36f);
  }

  void enforcePeripheralCloudSupport(SkeletonPose3D s,SkeletonPose3D previous){
    if(s==null||samples.size()<40)return;
    supportJoint(s.leftElbow,s.leftShoulder,previousJoint(previous,s.leftElbow.name),"elbow",-1,.25f,.66f);supportJoint(s.rightElbow,s.rightShoulder,previousJoint(previous,s.rightElbow.name),"elbow",1,.25f,.66f);
    supportJoint(s.leftWrist,s.leftElbow,previousJoint(previous,s.leftWrist.name),"wrist",-1,.24f,.70f);supportJoint(s.rightWrist,s.rightElbow,previousJoint(previous,s.rightWrist.name),"wrist",1,.24f,.70f);
    supportJoint(s.leftHand,s.leftWrist,previousJoint(previous,s.leftHand.name),"hand",-1,.28f,.78f);supportJoint(s.rightHand,s.rightWrist,previousJoint(previous,s.rightHand.name),"hand",1,.28f,.78f);
    supportJoint(s.leftKnee,s.leftHip,previousJoint(previous,s.leftKnee.name),"knee",-1,.18f,.48f);supportJoint(s.rightKnee,s.rightHip,previousJoint(previous,s.rightKnee.name),"knee",1,.18f,.48f);
    supportJoint(s.leftAnkle,s.leftKnee,previousJoint(previous,s.leftAnkle.name),"ankle",-1,.19f,.58f);supportJoint(s.rightAnkle,s.rightKnee,previousJoint(previous,s.rightAnkle.name),"ankle",1,.19f,.58f);
    supportJoint(s.leftFoot,s.leftAnkle,previousJoint(previous,s.leftFoot.name),"foot",-1,.21f,.66f);supportJoint(s.rightFoot,s.rightAnkle,previousJoint(previous,s.rightFoot.name),"foot",1,.21f,.66f);
    enforceJointRegion(s.leftShoulder,previousJoint(previous,s.leftShoulder.name),"shoulder",-1);enforceJointRegion(s.rightShoulder,previousJoint(previous,s.rightShoulder.name),"shoulder",1);
    enforceJointRegion(s.leftHip,previousJoint(previous,s.leftHip.name),"hip",-1);enforceJointRegion(s.rightHip,previousJoint(previous,s.rightHip.name),"hip",1);
  }
  void supportJoint(SkeletonJoint3D j,SkeletonJoint3D parent,SkeletonJoint3D prior,String role,int side,float searchRadius,float blend){
    if(j==null||parent==null||!j.tracked()||!parent.tracked()||j.world==null)return;
    Body3DCloudSample best=null;float bestScore=Float.MAX_VALUE;int nearby=0;
    for(Body3DCloudSample q:samples){float d=PVector.dist(q.p,j.world);if(d>searchRadius||!sampleFitsAnatomicalRegion(q,role,side))continue;
      float partP=bodyPartProbability(q,role,side);if(partP<.012f)continue;nearby++;float parentDistance=PVector.dist(q.p,parent.world);float currentBone=PVector.dist(j.world,parent.world);
      float bonePenalty=abs(parentDistance-currentBone)*.48f,temporalPenalty=0;if(prior!=null&&prior.tracked())temporalPenalty=min(.18f,PVector.dist(q.p,prior.world)*.24f);
      float score=d+bonePenalty+temporalPenalty+(1.0f-q.irQuality)*.018f+(1.0f-partP)*.055f;if(score<bestScore){bestScore=score;best=q;}}
    if(best==null||nearby<2){
      if(prior!=null&&prior.tracked()){j.world.set(PVector.lerp(j.world,prior.world,.28f));j.confidence=max(.12f,max(j.confidence*.84f,prior.confidence*.74f));j.state=1;}
      else{j.confidence*=.78f;j.state=j.confidence>.10f?1:0;if(j.state==0)j.confidence=0;}
      return;
    }
    PVector delta=PVector.sub(best.p,j.world);float maxShift=min(searchRadius*.52f,.072f);float len=delta.mag();if(len>maxShift&&len>1e-6f)delta.mult(maxShift/len);
    float evidence=constrain(nearby/10.0f,.25f,1.0f);j.world.add(PVector.mult(delta,blend*evidence));j.confidence=constrain(j.confidence*(.74f+.26f*evidence),0,1);
    enforceJointRegion(j,prior,role,side);
  }
  void enforceJointRegion(SkeletonJoint3D j,SkeletonJoint3D prior,String role,int side){if(j==null||!j.tracked()||j.world==null)return;Body3DCloudSample pseudo=new Body3DCloudSample(j.world,-1,-1,1.0f);PVector d=PVector.sub(j.world,frame.center);pseudo.lateral=d.dot(frame.right);pseudo.vertical=d.dot(frame.up);pseudo.forward=d.dot(frame.forward);
    if(sampleFitsAnatomicalRegion(pseudo,role,side))return;
    if(prior!=null&&prior.tracked()){PVector correction=PVector.sub(prior.world,j.world);if(correction.mag()<=.24f){j.world.set(PVector.lerp(j.world,prior.world,.72f));j.confidence*=.62f;return;}}
    j.confidence*=.28f;if(j.confidence<.34f){j.state=0;j.confidence=0;}
  }

  void stabilizeTorso(SkeletonPose3D s){
    if(!s.shoulderCenter.tracked()||!s.hipCenter.tracked())return;PVector axis=PVector.sub(s.shoulderCenter.world,s.hipCenter.world);if(axis.magSq()<1e-5f)return;axis.normalize();
    if(axis.dot(frame.up)<0)axis.mult(-1);float torso=PVector.dist(s.shoulderCenter.world,s.hipCenter.world);if(torso<.16f||torso>.75f){float target=constrain(torso,.16f,.75f);s.shoulderCenter.world.set(PVector.add(s.hipCenter.world,PVector.mult(axis,target)));}
    if(s.spine.tracked()){PVector target=PVector.lerp(s.hipCenter.world,s.shoulderCenter.world,.53f);s.spine.world.set(PVector.lerp(s.spine.world,target,.32f));}
  }

  void clampFeetToFloor(SkeletonPose3D s){
    if(!floor.valid||floor.support<.15f)return;floorClamp(s.leftAnkle,.10f,.45f);floorClamp(s.rightAnkle,.10f,.45f);floorClamp(s.leftFoot,.04f,.58f);floorClamp(s.rightFoot,.04f,.58f);
  }
  void floorClamp(SkeletonJoint3D j,float desired,float strength){if(j==null||!j.tracked())return;float d=floor.signedDistance(j.world);if(abs(d-desired)>.24f)return;j.world.add(PVector.mult(floor.normal,(desired-d)*strength));}

  void applyAnthropometry(SkeletonPose3D s){
    observeAnthropometry(s);anthroBone("upper-arm-l",s.leftShoulder,s.leftElbow);anthroBone("forearm-l",s.leftElbow,s.leftWrist);anthroBone("upper-arm-r",s.rightShoulder,s.rightElbow);anthroBone("forearm-r",s.rightElbow,s.rightWrist);
    anthroBone("thigh-l",s.leftHip,s.leftKnee);anthroBone("shin-l",s.leftKnee,s.leftAnkle);anthroBone("thigh-r",s.rightHip,s.rightKnee);anthroBone("shin-r",s.rightKnee,s.rightAnkle);
  }
  void observeAnthropometry(SkeletonPose3D s){float a=max(.006f,cfg.anthropologyLearnAlpha);anthroObserve("upper-arm-l",s.leftShoulder,s.leftElbow,a);anthroObserve("forearm-l",s.leftElbow,s.leftWrist,a);anthroObserve("upper-arm-r",s.rightShoulder,s.rightElbow,a);anthroObserve("forearm-r",s.rightElbow,s.rightWrist,a);anthroObserve("thigh-l",s.leftHip,s.leftKnee,a);anthroObserve("shin-l",s.leftKnee,s.leftAnkle,a);anthroObserve("thigh-r",s.rightHip,s.rightKnee,a);anthroObserve("shin-r",s.rightKnee,s.rightAnkle,a);}
  void anthroObserve(String key,SkeletonJoint3D a,SkeletonJoint3D b,float alpha){if(a!=null&&b!=null&&a.state==SkeletonJoint3D.TRACKED&&b.state==SkeletonJoint3D.TRACKED&&min(a.confidence,b.confidence)>=cfg.anthropologyMinConfidence)anthropometry.observe(key,PVector.dist(a.world,b.world),alpha,cfg.anthropologyMaxDeviation,cfg.anthropologyWarmupSamples);}
  void anthroBone(String key,SkeletonJoint3D a,SkeletonJoint3D b){if(a==null||b==null||!a.tracked()||!b.tracked())return;float observed=PVector.dist(a.world,b.world),target=anthropometry.target(key,observed);if(observed<1e-5f)return;float strength=.20f*anthropometry.reliability(key);PVector d=PVector.sub(b.world,a.world);d.mult(lerp(observed,target,strength)/observed);b.world.set(PVector.add(a.world,d));}

  void recomputeJointEvidenceConfidence(SkeletonPose3D s,SkeletonPose3D previous){
    if(s==null||samples.size()<24)return;float H=max(.85f,cloudScaleM);
    evidenceJoint(s.head,s.shoulderCenter,previousJoint(previous,"head"),"head",0,.095f,.05f,H*.23f);
    evidenceJoint(s.shoulderCenter,s.spine,previousJoint(previous,"shoulder_center"),"torso",0,.085f,.04f,H*.34f);
    evidenceJoint(s.spine,s.hipCenter,previousJoint(previous,"spine"),"torso",0,.090f,.04f,H*.34f);
    evidenceJoint(s.hipCenter,s.spine,previousJoint(previous,"hip_center"),"torso",0,.090f,.04f,H*.34f);

    evidenceJoint(s.leftShoulder,s.shoulderCenter,previousJoint(previous,"left_shoulder"),"shoulder",-1,.080f,.045f,H*.22f);
    evidenceJoint(s.rightShoulder,s.shoulderCenter,previousJoint(previous,"right_shoulder"),"shoulder",1,.080f,.045f,H*.22f);
    evidenceJoint(s.leftElbow,s.leftShoulder,previousJoint(previous,"left_elbow"),"elbow",-1,.085f,H*.09f,H*.30f);
    evidenceJoint(s.rightElbow,s.rightShoulder,previousJoint(previous,"right_elbow"),"elbow",1,.085f,H*.09f,H*.30f);
    evidenceJoint(s.leftWrist,s.leftElbow,previousJoint(previous,"left_wrist"),"wrist",-1,.075f,H*.07f,H*.27f);
    evidenceJoint(s.rightWrist,s.rightElbow,previousJoint(previous,"right_wrist"),"wrist",1,.075f,H*.07f,H*.27f);
    evidenceJoint(s.leftHand,s.leftWrist,previousJoint(previous,"left_hand"),"hand",-1,.090f,.012f,H*.13f);
    evidenceJoint(s.rightHand,s.rightWrist,previousJoint(previous,"right_hand"),"hand",1,.090f,.012f,H*.13f);

    evidenceJoint(s.leftHip,s.hipCenter,previousJoint(previous,"left_hip"),"hip",-1,.085f,.035f,H*.19f);
    evidenceJoint(s.rightHip,s.hipCenter,previousJoint(previous,"right_hip"),"hip",1,.085f,.035f,H*.19f);
    evidenceJoint(s.leftKnee,s.leftHip,previousJoint(previous,"left_knee"),"knee",-1,.095f,H*.13f,H*.36f);
    evidenceJoint(s.rightKnee,s.rightHip,previousJoint(previous,"right_knee"),"knee",1,.095f,H*.13f,H*.36f);
    evidenceJoint(s.leftAnkle,s.leftKnee,previousJoint(previous,"left_ankle"),"ankle",-1,.085f,H*.12f,H*.34f);
    evidenceJoint(s.rightAnkle,s.rightKnee,previousJoint(previous,"right_ankle"),"ankle",1,.085f,H*.12f,H*.34f);
    evidenceJoint(s.leftFoot,s.leftAnkle,previousJoint(previous,"left_foot"),"foot",-1,.095f,.015f,H*.16f);
    evidenceJoint(s.rightFoot,s.rightAnkle,previousJoint(previous,"right_foot"),"foot",1,.095f,.015f,H*.16f);
  }

  void evidenceJoint(SkeletonJoint3D j,SkeletonJoint3D parent,SkeletonJoint3D prior,String role,int side,float radius,float minBone,float maxBone){
    if(j==null||!j.tracked()||j.world==null)return;
    int local=0;float residual=0,ir=0,partSum=0;float nearest=Float.POSITIVE_INFINITY;
    for(Body3DCloudSample q:samples){
      if(!sampleFitsAnatomicalRegion(q,role,side))continue;
      float partP=bodyPartProbability(q,role,side);if(partP<.010f)continue;
      float d=PVector.dist(q.p,j.world);if(d<nearest)nearest=d;
      if(d<=radius){local++;residual+=d;ir+=q.irQuality;partSum+=partP;}
    }
    float density=constrain(local/7.0f,0,1);
    float compact=local==0?0:constrain(1.0f-(residual/local)/radius,0,1);
    float irQ=local==0?.35f:constrain(ir/local,0,1);
    float semanticQ=local==0?0:constrain((partSum/local)*2.6f,0,1);
    float boneQ=.72f;
    if(parent!=null&&parent.tracked()){
      float len=PVector.dist(parent.world,j.world);
      if(len<minBone)boneQ=constrain(len/max(.001f,minBone),0,1);
      else if(len>maxBone)boneQ=constrain(maxBone/max(.001f,len),0,1);
      else boneQ=1.0f;
    }
    float temporalQ=.76f;
    if(prior!=null&&prior.tracked()){
      float motion=PVector.dist(prior.world,j.world);
      float allowance=("hand".equals(role)||"wrist".equals(role)||"elbow".equals(role))?.32f:
        ("foot".equals(role)||"ankle".equals(role)||"knee".equals(role))?.26f:.16f;
      temporalQ=constrain(1.0f-motion/max(.04f,allowance),.18f,1.0f);
    }
    float parentQ=parent!=null&&parent.tracked()?constrain(parent.confidence,0,1):.62f;
    float evidence=.25f*density+.17f*compact+.08f*irQ+.20f*semanticQ+.13f*boneQ+.09f*temporalQ+.08f*parentQ;
    // A nearby isolated sample is useful but not enough for high confidence.
    if(local<2)evidence=min(evidence,.42f);
    if(local==0||nearest>radius*1.35f)evidence=min(evidence,.24f);
    float q=constrain(.22f*j.confidence+.78f*evidence,0,1);
    // Confidence is hierarchical: children may be precise, but they should not
    // claim certainty far above an uncertain parent chain.
    if(parent!=null&&parent.tracked())q=min(q,parent.confidence+.16f);
    j.confidence=q;
    if(q>=.68f&&local>=3)j.state=SkeletonJoint3D.TRACKED;
    else if(q>=.14f)j.state=SkeletonJoint3D.INFERRED;
    else{j.state=SkeletonJoint3D.LOST;j.confidence=0;}
  }

  float confidence(PVector p,float base){if(p==null)return 0;int local=0;float residual=0,ir=0;for(Body3DCloudSample s:samples){float d=PVector.dist(s.p,p);if(d<.055f){local++;residual+=d;ir+=s.irQuality;}}float density=min(1,local/12.0f),compact=local==0?0:constrain(1.0f-(residual/local)/.055f,0,1),irQ=local==0?.5f:ir/local;return constrain(base*(.34f+.34f*density+.18f*compact+.14f*irQ),.05f,1);}
  void set(SkeletonJoint3D j,String name,PVector world,SkeletonCalibration3D cal,float q){if(j==null||world==null)return;PVector image=cal.projectWorldRgb(world);if(image==null)image=cal.projectDepth(world);if(image==null)return;j.world.set(world);j.image.set(image);j.confidence=q;j.state=q>.62f?2:1;}

  // Independent publication guard. This layer does not need a trained subject
  // model, so it protects the very first frame as well as reacquisition frames.
  // Depth evidence may change joint direction, but it may not publish an impossible
  // human topology or flip the axial body upside-down.
  void enforcePublicationPose(SkeletonPose3D s,SkeletonPose3D previous,SkeletonCalibration3D cal){
    if(s==null||s.hipCenter==null||!s.hipCenter.tracked())return;
    float measured=frame==null?cloudScaleM:frame.height;
    float H=constrain(max(measured,min(cloudScaleM,measured*1.15f)),.90f,2.25f);
    PVector up=frame!=null?frame.up.copy():new PVector(0,-1,0);if(up.magSq()<1e-7f)up.set(0,-1,0);up.normalize();if(up.y>0)up.mult(-1);
    PVector right=frame!=null?frame.right.copy():new PVector(1,0,0);right.sub(PVector.mult(up,right.dot(up)));if(right.magSq()<1e-7f)right.set(1,0,0);right.normalize();if(right.x<0)right.mult(-1);
    PVector forward=right.cross(up);if(forward.magSq()<1e-7f)forward.set(0,0,1);forward.normalize();if(frame!=null&&forward.dot(frame.forward)<0)forward.mult(-1);

    // Publication is a connected articulated topology, not a bag of independent
    // landmarks.  Rebuild a temporarily missing child from the last valid segment
    // direction (or a deterministic anatomical fallback) before any bone guard is
    // applied.  The synthesized joint is explicitly INFERRED and low-confidence;
    // current metric depth immediately replaces it when evidence returns.
    completePublicationTopology(s,previous,cal,H,up,right,forward);

    float torsoTarget=H*.305f;
    if(s.shoulderCenter.tracked()){
      PVector axial=PVector.sub(s.shoulderCenter.world,s.hipCenter.world);float axialLen=axial.mag(),alignment=axialLen<1e-6f?-1:axial.dot(up)/axialLen;
      if(axialLen<H*.245f||axialLen>H*.370f||alignment<.42f){
        PVector desired=PVector.add(s.hipCenter.world,PVector.mult(up,torsoTarget));
        publicationMove(s.shoulderCenter,desired,.88f);publicationMove(s.spine,PVector.lerp(s.hipCenter.world,desired,.52f),.82f);
      }
    }

    // Central spans are reconstructed around their anchors when their side order or
    // size becomes impossible. This prevents a bad left/right assignment from
    // contaminating every child joint downstream.
    publicationSpan(s.leftShoulder,s.rightShoulder,s.shoulderCenter,right,constrain(shoulderHalfWidthM*2.0f,H*.18f,H*.34f),.46f,H*.16f,H*.34f);
    publicationSpan(s.leftHip,s.rightHip,s.hipCenter,right,constrain(hipHalfWidthM*2.0f,H*.11f,H*.24f),.48f,H*.10f,H*.24f);

    float ua=publicationLength("upper-arm",H*.185f,H*.145f,H*.225f);
    float fa=publicationLength("forearm",H*.155f,H*.120f,H*.195f);
    float hand=H*.060f,thigh=publicationLength("thigh",H*.255f,H*.205f,H*.305f),shin=publicationLength("shin",H*.250f,H*.200f,H*.300f),foot=H*.095f;
    hardPublicationBone(s.leftShoulder,s.leftElbow,previous==null?null:previous.leftElbow,ua,.78f,1.22f,right.copy().mult(-1),cal);
    hardPublicationBone(s.leftElbow,s.leftWrist,previous==null?null:previous.leftWrist,fa,.76f,1.24f,right.copy().mult(-1),cal);
    hardPublicationBone(s.leftWrist,s.leftHand,previous==null?null:previous.leftHand,hand,.55f,1.65f,right.copy().mult(-1),cal);
    hardPublicationBone(s.rightShoulder,s.rightElbow,previous==null?null:previous.rightElbow,ua,.78f,1.22f,right,cal);
    hardPublicationBone(s.rightElbow,s.rightWrist,previous==null?null:previous.rightWrist,fa,.76f,1.24f,right,cal);
    hardPublicationBone(s.rightWrist,s.rightHand,previous==null?null:previous.rightHand,hand,.55f,1.65f,right,cal);

    PVector down=PVector.mult(up,-1);
    hardPublicationBone(s.leftHip,s.leftKnee,previous==null?null:previous.leftKnee,thigh,.78f,1.22f,down,cal);
    hardPublicationBone(s.leftKnee,s.leftAnkle,previous==null?null:previous.leftAnkle,shin,.78f,1.22f,down,cal);
    hardPublicationBone(s.leftAnkle,s.leftFoot,previous==null?null:previous.leftFoot,foot,.45f,1.75f,forward,cal);
    hardPublicationBone(s.rightHip,s.rightKnee,previous==null?null:previous.rightKnee,thigh,.78f,1.22f,down,cal);
    hardPublicationBone(s.rightKnee,s.rightAnkle,previous==null?null:previous.rightAnkle,shin,.78f,1.22f,down,cal);
    hardPublicationBone(s.rightAnkle,s.rightFoot,previous==null?null:previous.rightFoot,foot,.45f,1.75f,forward,cal);

    hardPublicationBone(s.shoulderCenter,s.head,previous==null?null:previous.head,H*.120f,.62f,1.55f,up,cal);
    if(s.spine.tracked())publicationMove(s.spine,PVector.lerp(s.hipCenter.world,s.shoulderCenter.world,.52f),.46f);
    // One second forward pass closes small errors introduced when an upstream joint
    // was corrected after its child. It is intentionally conservative.
    hardPublicationBone(s.leftShoulder,s.leftElbow,previous==null?null:previous.leftElbow,ua,.76f,1.24f,right.copy().mult(-1),cal);
    hardPublicationBone(s.leftElbow,s.leftWrist,previous==null?null:previous.leftWrist,fa,.74f,1.26f,right.copy().mult(-1),cal);
    hardPublicationBone(s.rightShoulder,s.rightElbow,previous==null?null:previous.rightElbow,ua,.76f,1.24f,right,cal);
    hardPublicationBone(s.rightElbow,s.rightWrist,previous==null?null:previous.rightWrist,fa,.74f,1.26f,right,cal);
    hardPublicationBone(s.leftHip,s.leftKnee,previous==null?null:previous.leftKnee,thigh,.76f,1.24f,down,cal);
    hardPublicationBone(s.leftKnee,s.leftAnkle,previous==null?null:previous.leftAnkle,shin,.76f,1.24f,down,cal);
    hardPublicationBone(s.rightHip,s.rightKnee,previous==null?null:previous.rightKnee,thigh,.76f,1.24f,down,cal);
    hardPublicationBone(s.rightKnee,s.rightAnkle,previous==null?null:previous.rightAnkle,shin,.76f,1.24f,down,cal);
    reproject(s,cal);
  }


  void completePublicationTopology(SkeletonPose3D s,SkeletonPose3D previous,SkeletonCalibration3D cal,float H,PVector up,PVector right,PVector forward){
    if(s==null||s.hipCenter==null||!s.hipCenter.tracked())return;
    PVector down=PVector.mult(up,-1);
    float shoulderWidth=constrain(shoulderHalfWidthM*2.0f,H*.18f,H*.34f),hipWidth=constrain(hipHalfWidthM*2.0f,H*.11f,H*.24f);
    ensurePairAroundCenter(s.leftShoulder,s.rightShoulder,s.shoulderCenter,right,shoulderWidth,cal);
    ensurePairAroundCenter(s.leftHip,s.rightHip,s.hipCenter,right,hipWidth,cal);
    ensureChild(s.hipCenter,s.spine,previous==null?null:previous.hipCenter,previous==null?null:previous.spine,H*.155f,up,cal);
    ensureChild(s.spine,s.shoulderCenter,previous==null?null:previous.spine,previous==null?null:previous.shoulderCenter,H*.150f,up,cal);
    ensureChild(s.shoulderCenter,s.head,previous==null?null:previous.shoulderCenter,previous==null?null:previous.head,H*.120f,up,cal);

    float ua=publicationLength("upper-arm",H*.185f,H*.145f,H*.225f),fa=publicationLength("forearm",H*.155f,H*.120f,H*.195f),hand=H*.060f;
    float thigh=publicationLength("thigh",H*.255f,H*.205f,H*.305f),shin=publicationLength("shin",H*.250f,H*.200f,H*.300f),foot=H*.095f;
    ensureChild(s.leftShoulder,s.leftElbow,previous==null?null:previous.leftShoulder,previous==null?null:previous.leftElbow,ua,right.copy().mult(-1),cal);
    ensureChild(s.leftElbow,s.leftWrist,previous==null?null:previous.leftElbow,previous==null?null:previous.leftWrist,fa,right.copy().mult(-1),cal);
    ensureChild(s.leftWrist,s.leftHand,previous==null?null:previous.leftWrist,previous==null?null:previous.leftHand,hand,right.copy().mult(-1),cal);
    ensureChild(s.rightShoulder,s.rightElbow,previous==null?null:previous.rightShoulder,previous==null?null:previous.rightElbow,ua,right,cal);
    ensureChild(s.rightElbow,s.rightWrist,previous==null?null:previous.rightElbow,previous==null?null:previous.rightWrist,fa,right,cal);
    ensureChild(s.rightWrist,s.rightHand,previous==null?null:previous.rightWrist,previous==null?null:previous.rightHand,hand,right,cal);

    ensureChild(s.leftHip,s.leftKnee,previous==null?null:previous.leftHip,previous==null?null:previous.leftKnee,thigh,down,cal);
    ensureChild(s.leftKnee,s.leftAnkle,previous==null?null:previous.leftKnee,previous==null?null:previous.leftAnkle,shin,down,cal);
    ensureChild(s.leftAnkle,s.leftFoot,previous==null?null:previous.leftAnkle,previous==null?null:previous.leftFoot,foot,forward,cal);
    ensureChild(s.rightHip,s.rightKnee,previous==null?null:previous.rightHip,previous==null?null:previous.rightKnee,thigh,down,cal);
    ensureChild(s.rightKnee,s.rightAnkle,previous==null?null:previous.rightKnee,previous==null?null:previous.rightAnkle,shin,down,cal);
    ensureChild(s.rightAnkle,s.rightFoot,previous==null?null:previous.rightAnkle,previous==null?null:previous.rightFoot,foot,forward,cal);
  }

  void ensurePairAroundCenter(SkeletonJoint3D left,SkeletonJoint3D rightJoint,SkeletonJoint3D center,PVector axis,float span,SkeletonCalibration3D cal){
    if(center==null||!center.tracked()||axis==null||axis.magSq()<1e-8f)return;PVector dir=axis.copy().normalize(),half=PVector.mult(dir,span*.5f);
    if(left!=null&&!left.tracked())setInferredJoint(left,PVector.sub(center.world,half),.30f,"kinematic-completion",cal);
    if(rightJoint!=null&&!rightJoint.tracked())setInferredJoint(rightJoint,PVector.add(center.world,half),.30f,"kinematic-completion",cal);
  }

  void ensureChild(SkeletonJoint3D parent,SkeletonJoint3D child,SkeletonJoint3D previousParent,SkeletonJoint3D previousChild,float target,PVector fallbackDir,SkeletonCalibration3D cal){
    if(parent==null||child==null||!parent.tracked()||target<.020f)return;
    if(child.tracked()&&child.world!=null&&Float.isFinite(child.world.x)&&Float.isFinite(child.world.y)&&Float.isFinite(child.world.z))return;
    PVector dir=null;
    if(previousParent!=null&&previousChild!=null&&previousParent.tracked()&&previousChild.tracked())dir=PVector.sub(previousChild.world,previousParent.world);
    if(dir==null||dir.magSq()<1e-8f)dir=fallbackDir==null?new PVector(0,-1,0):fallbackDir.copy();
    if(dir.magSq()<1e-8f)return;dir.normalize();setInferredJoint(child,PVector.add(parent.world,PVector.mult(dir,target)),.27f,"kinematic-completion",cal);
  }

  void setInferredJoint(SkeletonJoint3D joint,PVector world,float confidence,String source,SkeletonCalibration3D cal){
    if(joint==null||world==null)return;PVector uv=cal.projectWorldRgb(world);if(uv==null)uv=cal.projectDepth(world);if(uv==null)return;
    joint.world.set(world);joint.image.set(uv);joint.confidence=constrain(confidence,.08f,.45f);joint.state=SkeletonJoint3D.INFERRED;joint.source=source;
  }

  float publicationLength(String group,float fallback,float lo,float hi){
    float a=fallback,b=fallback;
    if("upper-arm".equals(group)){a=anthropometry.target("upper-arm-l",fallback);b=anthropometry.target("upper-arm-r",fallback);}
    else if("forearm".equals(group)){a=anthropometry.target("forearm-l",fallback);b=anthropometry.target("forearm-r",fallback);}
    else if("thigh".equals(group)){a=anthropometry.target("thigh-l",fallback);b=anthropometry.target("thigh-r",fallback);}
    else if("shin".equals(group)){a=anthropometry.target("shin-l",fallback);b=anthropometry.target("shin-r",fallback);}
    float v=(a+b)*.5f;return constrain(v,lo,hi);
  }

  void publicationSpan(SkeletonJoint3D left,SkeletonJoint3D rightJoint,SkeletonJoint3D center,PVector axis,float target,float tolerance,float minSpan,float maxSpan){
    if(left==null||rightJoint==null||center==null||!center.tracked())return;
    if(!left.tracked()||!rightJoint.tracked())return;
    PVector delta=PVector.sub(rightJoint.world,left.world);float span=delta.mag();float order=span<1e-6f?-1:delta.dot(axis)/span;
    float desired=constrain(target,minSpan,maxSpan),lo=desired*(1.0f-tolerance*.28f),hi=desired*(1.0f+tolerance*.28f);
    if(span>=lo&&span<=hi&&order>.30f)return;
    PVector half=PVector.mult(axis,desired*.5f);PVector lp=PVector.sub(center.world,half),rp=PVector.add(center.world,half);
    publicationMove(left,lp,.82f);publicationMove(rightJoint,rp,.82f);
  }

  void hardPublicationBone(SkeletonJoint3D parent,SkeletonJoint3D child,SkeletonJoint3D prior,float target,float loRatio,float hiRatio,PVector fallbackDir,SkeletonCalibration3D cal){
    if(parent==null||child==null||!parent.tracked()||!child.tracked()||parent.world==null||child.world==null||target<.020f)return;
    PVector d=PVector.sub(child.world,parent.world);float len=d.mag(),lo=target*loRatio,hi=target*hiRatio;if(len>=lo&&len<=hi)return;
    PVector dir=d.copy();if(dir.magSq()<1e-8f&&prior!=null&&prior.tracked())dir=PVector.sub(prior.world,parent.world);
    if(dir.magSq()<1e-8f)dir=fallbackDir==null?new PVector(0,-1,0):fallbackDir.copy();if(dir.magSq()<1e-8f)return;dir.normalize();
    float bounded=constrain(len,lo,hi);if(!Float.isFinite(bounded)||bounded<.005f)bounded=target;
    PVector desired=PVector.add(parent.world,PVector.mult(dir,bounded));float correction=PVector.dist(desired,child.world);
    child.world.set(PVector.lerp(child.world,desired,correction>.10f?.96f:.86f));
    if(correction>.035f){if(child.state==SkeletonJoint3D.TRACKED)child.state=SkeletonJoint3D.INFERRED;child.confidence=constrain(child.confidence*(correction>.10f?.62f:.78f),.08f,.78f);child.source="kinematic-guard";}
    PVector uv=cal.projectWorldRgb(child.world);if(uv==null)uv=cal.projectDepth(child.world);if(uv!=null)child.image.set(uv);
  }

  void publicationMove(SkeletonJoint3D j,PVector desired,float strength){
    if(j==null||desired==null)return;if(!j.tracked()){j.world.set(desired);j.state=SkeletonJoint3D.INFERRED;j.confidence=.30f;return;}
    float d=PVector.dist(j.world,desired);j.world.set(PVector.lerp(j.world,desired,constrain(strength,0,1)));if(d>.045f){if(j.state==SkeletonJoint3D.TRACKED)j.state=SkeletonJoint3D.INFERRED;j.confidence*=.78f;j.source="kinematic-guard";}
  }

  void reproject(SkeletonPose3D s,SkeletonCalibration3D cal){for(SkeletonJoint3D j:s.canonicalJoints()){if(j==null||!j.tracked())continue;PVector image=cal.projectWorldRgb(j.world);if(image==null)image=cal.projectDepth(j.world);if(image!=null)j.image.set(image);}}

  void enforceSymmetry(SkeletonPose3D s){
    symmetricPair(s.leftShoulder,s.rightShoulder,s.shoulderCenter,.16f,.62f);symmetricPair(s.leftHip,s.rightHip,s.hipCenter,.10f,.48f);
    limitChain(s.leftShoulder,s.leftElbow,s.leftWrist,s.leftHand,.12f,.55f);limitChain(s.rightShoulder,s.rightElbow,s.rightWrist,s.rightHand,.12f,.55f);
    limitChain(s.leftHip,s.leftKnee,s.leftAnkle,s.leftFoot,.18f,.72f);limitChain(s.rightHip,s.rightKnee,s.rightAnkle,s.rightFoot,.18f,.72f);
  }
  void symmetricPair(SkeletonJoint3D a,SkeletonJoint3D b,SkeletonJoint3D center,float minLen,float maxLen){if(a==null||b==null||center==null||!a.tracked()||!b.tracked()||!center.tracked())return;float d=PVector.dist(a.world,b.world);if(d<minLen||d>maxLen){PVector axis=PVector.sub(b.world,a.world);if(axis.magSq()<1e-7f)axis.set(frame.right);axis.normalize();float target=constrain(d,minLen,maxLen)*.5f;a.world.set(PVector.sub(center.world,PVector.mult(axis,target)));b.world.set(PVector.add(center.world,PVector.mult(axis,target)));}}
  void limitChain(SkeletonJoint3D a,SkeletonJoint3D b,SkeletonJoint3D c,SkeletonJoint3D d,float min,float max){limitBone(a,b,min,max);limitBone(b,c,min,max);limitBone(c,d,.03f,max*.55f);}
  void limitBone(SkeletonJoint3D a,SkeletonJoint3D b,float min,float max){if(a==null||b==null||!a.tracked()||!b.tracked())return;PVector delta=PVector.sub(b.world,a.world);float len=delta.mag();if(len<1e-5f)return;float target=constrain(len,min,max);if(abs(target-len)>.001f){delta.mult(target/len);b.world.set(PVector.add(a.world,delta));}}

  void learnBones(SkeletonPose3D s){learn("ls-le",s.leftShoulder,s.leftElbow);learn("le-lw",s.leftElbow,s.leftWrist);learn("rs-re",s.rightShoulder,s.rightElbow);learn("re-rw",s.rightElbow,s.rightWrist);learn("lh-lk",s.leftHip,s.leftKnee);learn("lk-la",s.leftKnee,s.leftAnkle);learn("rh-rk",s.rightHip,s.rightKnee);learn("rk-ra",s.rightKnee,s.rightAnkle);}
  void learn(String key,SkeletonJoint3D a,SkeletonJoint3D b){if(a==null||b==null||!a.tracked()||!b.tracked())return;
    // Never let an inferred/weak joint teach the persistent body model.
    if(min(a.confidence,b.confidence)<.68f||a.state!=SkeletonJoint3D.TRACKED||b.state!=SkeletonJoint3D.TRACKED)return;
    float d=PVector.dist(a.world,b.world);if(d<.05f||d>.90f)return;Float old=learnedBones.get(key);learnedBones.put(key,old==null?d:lerp(old,d,cfg.poseBoneLearnAlpha));}
  void applyLearnedBones(SkeletonPose3D s){applyBone("ls-le",s.leftShoulder,s.leftElbow);applyBone("le-lw",s.leftElbow,s.leftWrist);applyBone("rs-re",s.rightShoulder,s.rightElbow);applyBone("re-rw",s.rightElbow,s.rightWrist);applyBone("lh-lk",s.leftHip,s.leftKnee);applyBone("lk-la",s.leftKnee,s.leftAnkle);applyBone("rh-rk",s.rightHip,s.rightKnee);applyBone("rk-ra",s.rightKnee,s.rightAnkle);}
  void applyBone(String key,SkeletonJoint3D a,SkeletonJoint3D b){Float target=learnedBones.get(key);if(target==null||a==null||b==null||!a.tracked()||!b.tracked())return;PVector d=PVector.sub(b.world,a.world);float len=d.mag();if(len<1e-5f)return;float corrected=lerp(len,target,cfg.poseBoneCorrection*.55f);d.mult(corrected/len);b.world.set(PVector.add(a.world,d));}
}
