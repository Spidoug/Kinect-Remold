// ===== SynKinect Studio / Motion-capture retargeter =====
// Converts a BodyFrame (Kinect camera space) into a gravity-aligned, Y-up humanoid
// pose named after Unity HumanBodyBones, with per-bone GLOBAL and LOCAL rotations.
//
// Coordinate conventions (see docs/MOTION-CAPTURE.md):
//  * Studio camera space C: right-handed, +X image right (= user's LEFT when the
//    user faces the sensor), +Y down, +Z away from the sensor, metres.
//  * Gravity alignment: Rg = fromTo(up_C, (0,-1,0)) with up_C from the floor model /
//    accelerometer (identity when unknown). After Rg the camera Y axis is vertical.
//  * Unity space U (left-handed, +X right, +Y up, +Z forward, avatar faces +Z):
//        U = diag(-1,-1,-1) · Rg · C
//    The reflection diag(-1,-1,-1) has det -1, which is exactly the change of
//    handedness right→left; physically it is the same space. The user's LEFT side
//    (+X_C) becomes -X_U, i.e. the avatar's left, and the user's facing direction
//    (toward the sensor, -Z_C) becomes +Z_U (avatar forward). Up (-Y_C) is +Y_U.
//  * All quaternion arithmetic is done on Unity components with the standard
//    Hamilton formulas, which is what UnityEngine.Quaternion implements, so the
//    emitted (x,y,z,w) are directly usable as Transform.rotation/localRotation.
//  * Rest pose: VRM/Unity-normalised T-pose, avatar facing +Z, every bone with
//    identity rotation. Rest bone directions: spine/neck +Y, left arm -X, right arm
//    +X, legs -Y, feet ~(0,-0.4,1). Global rotation G maps the rest frame onto the
//    measured frame: swing takes the rest direction onto the measured bone
//    direction, twist comes from a secondary axis (shoulder/hip line for the torso,
//    elbow/knee bend plane for upper limbs, thumb/foot direction for forearm/shin,
//    hand tip + thumb for hands). Without a usable secondary axis the bone takes the
//    minimal swing from its parent (hinge behaviour). LOCAL = conj(G_parent) · G.
//  * Mirror: reflect across the avatar's sagittal plane (x → -x, quaternion
//    (x,y,z,w) → (x,-y,-z,w)) and swap Left/Right bones.

final String[] MOCAP_BONES={"Hips","Spine","Chest","Neck","Head","LeftShoulder","LeftUpperArm","LeftLowerArm","LeftHand",
  "RightShoulder","RightUpperArm","RightLowerArm","RightHand","LeftUpperLeg","LeftLowerLeg","LeftFoot","RightUpperLeg","RightLowerLeg","RightFoot"};
final int[] MOCAP_PARENT={-1,0,1,2,3,2,5,6,7,2,9,10,11,0,13,14,0,16,17};
final int[] MOCAP_MIRROR={0,1,2,3,4,9,10,11,12,5,6,7,8,16,17,18,13,14,15};
final int MB_HIPS=0,MB_SPINE=1,MB_CHEST=2,MB_NECK=3,MB_HEAD=4,MB_L_SHOULDER=5,MB_L_UPPER_ARM=6,MB_L_LOWER_ARM=7,MB_L_HAND=8,
  MB_R_SHOULDER=9,MB_R_UPPER_ARM=10,MB_R_LOWER_ARM=11,MB_R_HAND=12,MB_L_UPPER_LEG=13,MB_L_LOWER_LEG=14,MB_L_FOOT=15,MB_R_UPPER_LEG=16,MB_R_LOWER_LEG=17,MB_R_FOOT=18;
// Rest segment lengths (symmetric).
final int RL_SPINE_LOW=0,RL_SPINE_UP=1,RL_NECK=2,RL_CLAVICLE=3,RL_UPPER_ARM=4,RL_FOREARM=5,RL_HAND=6,RL_HIP=7,RL_THIGH=8,RL_SHIN=9,RL_FOOT=10,RL_COUNT=11;
final float[] MOCAP_DEFAULT_LENGTHS={.21f,.28f,.19f,.185f,.29f,.255f,.075f,.095f,.44f,.42f,.12f};

// ---------------------------------------------------------------- vector / quaternion math (double precision)
double[] mcV(double x,double y,double z){return new double[]{x,y,z};}
double[] mcSub(double[] a,double[] b){return mcV(a[0]-b[0],a[1]-b[1],a[2]-b[2]);}
double[] mcAdd(double[] a,double[] b){return mcV(a[0]+b[0],a[1]+b[1],a[2]+b[2]);}
double[] mcScale(double[] a,double s){return mcV(a[0]*s,a[1]*s,a[2]*s);}
double mcDot(double[] a,double[] b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}
double[] mcCross(double[] a,double[] b){return mcV(a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]);}
double mcLen(double[] a){return Math.sqrt(mcDot(a,a));}
double[] mcNorm(double[] a){if(a==null)return null;double l=mcLen(a);return l<1e-9?null:mcScale(a,1/l);}
double[] mcLerp(double[] a,double[] b,double t){return mcV(a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t);}
double[] mcQIdentity(){return new double[]{0,0,0,1};}
double[] mcQMul(double[] a,double[] b){
  return new double[]{a[3]*b[0]+a[0]*b[3]+a[1]*b[2]-a[2]*b[1],a[3]*b[1]-a[0]*b[2]+a[1]*b[3]+a[2]*b[0],a[3]*b[2]+a[0]*b[1]-a[1]*b[0]+a[2]*b[3],a[3]*b[3]-a[0]*b[0]-a[1]*b[1]-a[2]*b[2]};}
double[] mcQConj(double[] q){return new double[]{-q[0],-q[1],-q[2],q[3]};}
double[] mcQNorm(double[] q){double n=Math.sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3]);if(n<1e-12)return mcQIdentity();return new double[]{q[0]/n,q[1]/n,q[2]/n,q[3]/n};}
double[] mcQRot(double[] q,double[] v){double[] p={v[0],v[1],v[2],0};double[] r=mcQMul(mcQMul(q,p),mcQConj(q));return mcV(r[0],r[1],r[2]);}
double mcQDot(double[] a,double[] b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]+a[3]*b[3];}
double[] mcQFromTo(double[] from,double[] to){
  double[] a=mcNorm(from),b=mcNorm(to);if(a==null||b==null)return mcQIdentity();double d=mcDot(a,b);
  if(d<-0.999999){double[] axis=mcCross(Math.abs(a[0])<.8?mcV(1,0,0):mcV(0,1,0),a);axis=mcNorm(axis);return new double[]{axis[0],axis[1],axis[2],0};}
  double[] c=mcCross(a,b);return mcQNorm(new double[]{c[0],c[1],c[2],1+d});
}
// Rotation matrix (row-major m[r][c]) -> quaternion.
double[] mcQFromMatrix(double[][] m){
  double tr=m[0][0]+m[1][1]+m[2][2],x,y,z,w;
  if(tr>0){double s=Math.sqrt(tr+1)*2;w=.25*s;x=(m[2][1]-m[1][2])/s;y=(m[0][2]-m[2][0])/s;z=(m[1][0]-m[0][1])/s;}
  else if(m[0][0]>m[1][1]&&m[0][0]>m[2][2]){double s=Math.sqrt(1+m[0][0]-m[1][1]-m[2][2])*2;w=(m[2][1]-m[1][2])/s;x=.25*s;y=(m[0][1]+m[1][0])/s;z=(m[0][2]+m[2][0])/s;}
  else if(m[1][1]>m[2][2]){double s=Math.sqrt(1+m[1][1]-m[0][0]-m[2][2])*2;w=(m[0][2]-m[2][0])/s;x=(m[0][1]+m[1][0])/s;y=.25*s;z=(m[1][2]+m[2][1])/s;}
  else{double s=Math.sqrt(1+m[2][2]-m[0][0]-m[1][1])*2;w=(m[1][0]-m[0][1])/s;x=(m[0][2]+m[2][0])/s;y=(m[1][2]+m[2][1])/s;z=.25*s;}
  return mcQNorm(new double[]{x,y,z,w});
}
double[][] mcQToMatrix(double[] q){double x=q[0],y=q[1],z=q[2],w=q[3];
  return new double[][]{{1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)},{2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)},{2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)}};}
// Rotation taking the rest frame (p0 exact, s0) onto the measured frame (p exact, s orthogonalised).
double[] mcQFromFrames(double[] p0,double[] s0,double[] p,double[] s){
  if(p0==null||s0==null||p==null||s==null)return null;
  double[] a=mcNorm(p0);if(a==null)return null;double[] b=mcNorm(mcSub(s0,mcScale(a,mcDot(s0,a))));if(b==null)return null;double[] c=mcCross(a,b);
  double[] P=mcNorm(p);if(P==null)return null;double[] S=mcNorm(mcSub(s,mcScale(P,mcDot(s,P))));if(S==null)return null;double[] T=mcCross(P,S);
  double[][] m=new double[3][3];
  for(int r=0;r<3;r++)for(int k=0;k<3;k++)m[r][k]=P[r]*a[k]+S[r]*b[k]+T[r]*c[k];
  return mcQFromMatrix(m);
}
double[] mcQSlerp(double[] a,double[] b,double t){
  double d=mcQDot(a,b);double[] bb=b;if(d<0){d=-d;bb=new double[]{-b[0],-b[1],-b[2],-b[3]};}
  if(d>.9995)return mcQNorm(new double[]{a[0]+(bb[0]-a[0])*t,a[1]+(bb[1]-a[1])*t,a[2]+(bb[2]-a[2])*t,a[3]+(bb[3]-a[3])*t});
  double th=Math.acos(d),sn=Math.sin(th),wa=Math.sin((1-t)*th)/sn,wb=Math.sin(t*th)/sn;
  return new double[]{a[0]*wa+bb[0]*wb,a[1]*wa+bb[1]*wb,a[2]*wa+bb[2]*wb,a[3]*wa+bb[3]*wb};
}
double mcSmoothstep(double e0,double e1,double x){double t=Math.max(0,Math.min(1,(x-e0)/(e1-e0)));return t*t*(3-2*t);}
// BVH ZXY Euler (degrees) of rotation matrix R = Rz·Rx·Ry.
double[] mcEulerZXYDeg(double[][] m){
  double sx=Math.max(-1,Math.min(1,m[2][1]));double x=Math.asin(sx),y,z;
  if(Math.abs(sx)<0.99999){z=Math.atan2(-m[0][1],m[1][1]);y=Math.atan2(-m[2][0],m[2][2]);}
  else{y=0;z=Math.atan2(m[1][0],m[0][0]);}
  return new double[]{Math.toDegrees(z),Math.toDegrees(x),Math.toDegrees(y)};
}

// Immutable retargeted pose. Arrays are never modified after construction.
final class MocapPose {
  final String deviceId;final long timeMs,inputMs,frameNumber,trackingId;final boolean tracked,mirrored;final float confidence;
  final float[] globalPos,globalRot,localPos,localRot,boneConf,restLengths;final boolean[] boneValid;final BodyFrame source;
  MocapPose(BodyFrame source,String deviceId,long timeMs,long inputMs,long frameNumber,long trackingId,boolean tracked,boolean mirrored,float confidence,
    float[] globalPos,float[] globalRot,float[] localPos,float[] localRot,float[] boneConf,boolean[] boneValid,float[] restLengths){
    this.source=source;this.deviceId=deviceId;this.timeMs=timeMs;this.inputMs=inputMs;this.frameNumber=frameNumber;this.trackingId=trackingId;this.tracked=tracked;
    this.mirrored=mirrored;this.confidence=confidence;this.globalPos=globalPos;this.globalRot=globalRot;this.localPos=localPos;this.localRot=localRot;
    this.boneConf=boneConf;this.boneValid=boneValid;this.restLengths=restLengths;
  }
  int boneCount(){return MOCAP_BONES.length;}
  String boneName(int i){return MOCAP_BONES[i];}
  MocapPose mirrored(){
    int n=MOCAP_BONES.length;float[] gp=new float[n*3],gr=new float[n*4],lp=new float[n*3],lr=new float[n*4],bc=new float[n];boolean[] bv=new boolean[n];
    for(int i=0;i<n;i++){int s=MOCAP_MIRROR[i];
      gp[i*3]=-globalPos[s*3];gp[i*3+1]=globalPos[s*3+1];gp[i*3+2]=globalPos[s*3+2];
      lp[i*3]=-localPos[s*3];lp[i*3+1]=localPos[s*3+1];lp[i*3+2]=localPos[s*3+2];
      gr[i*4]=globalRot[s*4];gr[i*4+1]=-globalRot[s*4+1];gr[i*4+2]=-globalRot[s*4+2];gr[i*4+3]=globalRot[s*4+3];
      lr[i*4]=localRot[s*4];lr[i*4+1]=-localRot[s*4+1];lr[i*4+2]=-localRot[s*4+2];lr[i*4+3]=localRot[s*4+3];
      bc[i]=boneConf[s];bv[i]=boneValid[s];}
    return new MocapPose(source,deviceId,timeMs,inputMs,frameNumber,trackingId,tracked,!mirrored,confidence,gp,gr,lp,lr,bc,bv,restLengths);
  }
}

class MocapRetargeter {
  final double[] FOOT_REST=mcNorm(mcV(0,-.4,1));
  final double[] X=mcV(1,0,0),NX=mcV(-1,0,0),Y=mcV(0,1,0),NY=mcV(0,-1,0),Z=mcV(0,0,1),NZ=mcV(0,0,-1);
  boolean centerRoot=true;float minConfidence=.05f;
  final float[] lengths=MOCAP_DEFAULT_LENGTHS.clone();final int[] lengthSamples=new int[RL_COUNT];
  double[][] prevLocal=new double[MOCAP_BONES.length][];long lastTrackingId=Long.MIN_VALUE;
  double[] rootOrigin=null;double heightOffset=0;boolean heightInitialized=false;

  MocapRetargeter(){reset();}
  void reset(){for(int i=0;i<prevLocal.length;i++)prevLocal[i]=mcQIdentity();System.arraycopy(MOCAP_DEFAULT_LENGTHS,0,lengths,0,RL_COUNT);
    Arrays.fill(lengthSamples,0);rootOrigin=null;heightInitialized=false;heightOffset=0;}
  float[] restLengths(){return lengths.clone();}

  MocapPose retarget(BodyFrame f,boolean mirror){MocapPose p=retarget(f);return mirror?p.mirrored():p;}

  MocapPose retarget(BodyFrame f){
    int nj=f.jointCount(),nb=MOCAP_BONES.length;
    if(f.trackingId!=lastTrackingId&&f.trackingId!=0){reset();lastTrackingId=f.trackingId;}
    // ---- camera -> gravity aligned -> Unity components
    float[] up=f.upVector();double[] rg=up==null?mcQIdentity():mcQFromTo(mcV(up[0],up[1],up[2]),mcV(0,-1,0));
    double[][] U=new double[nj][];boolean[] t=new boolean[nj];
    for(int i=0;i<nj;i++){t[i]=f.tracked&&f.jointTracked(i)&&f.confidence(i)>=minConfidence;double[] c=mcQRot(rg,mcV(f.x(i),f.y(i),f.z(i)));U[i]=mcV(-c[0],-c[1],-c[2]);}
    if(f.tracked)updateLengths(U,t,f);
    // ---- height: floor plane when known, otherwise feet on the ground / rest leg length
    double target=Double.NaN;
    if(f.floorValid)target=f.floorD;
    else{double minY=Double.POSITIVE_INFINITY;for(int j:new int[]{BJ_FOOT_LEFT,BJ_FOOT_RIGHT,BJ_ANKLE_LEFT,BJ_ANKLE_RIGHT})if(t[j])minY=Math.min(minY,U[j][1]-(j==BJ_ANKLE_LEFT||j==BJ_ANKLE_RIGHT?.07:.03));
      if(Double.isFinite(minY))target=-minY;else if(t[BJ_HIP_CENTER])target=(lengths[RL_THIGH]+lengths[RL_SHIN]+.07)-U[BJ_HIP_CENTER][1];}
    if(Double.isFinite(target)){if(!heightInitialized||f.floorValid){heightOffset=target;heightInitialized=true;}else heightOffset+=(target-heightOffset)*.15;}
    if(centerRoot&&rootOrigin==null&&t[BJ_HIP_CENTER])rootOrigin=mcV(U[BJ_HIP_CENTER][0],0,U[BJ_HIP_CENTER][2]);
    for(int i=0;i<nj;i++){U[i][1]+=heightOffset;if(centerRoot&&rootOrigin!=null){U[i][0]-=rootOrigin[0];U[i][2]-=rootOrigin[2];}}

    double[][] G=new double[nb][];boolean[] valid=new boolean[nb];float[] conf=new float[nb];
    double[] hipSide=dir(U,t,BJ_HIP_LEFT,BJ_HIP_RIGHT),shSide=dir(U,t,BJ_SHOULDER_LEFT,BJ_SHOULDER_RIGHT);
    if(hipSide==null)hipSide=shSide;if(shSide==null)shSide=hipSide;
    // Hips
    double[] hipUp=dir(U,t,BJ_HIP_CENTER,BJ_SPINE);if(hipUp==null)hipUp=dir(U,t,BJ_HIP_CENTER,BJ_SHOULDER_CENTER);
    if(hipUp!=null&&hipSide!=null){G[MB_HIPS]=mcQFromFrames(Y,X,hipUp,hipSide);}
    valid[MB_HIPS]=G[MB_HIPS]!=null;if(!valid[MB_HIPS])G[MB_HIPS]=prevLocal[MB_HIPS];conf[MB_HIPS]=jc(f,t,BJ_HIP_CENTER,BJ_SPINE);
    // Spine / Chest / Neck / Head
    double[] spineUp=dir(U,t,BJ_SPINE,BJ_SHOULDER_CENTER);double[] midSide=hipSide==null?null:mcNorm(mcAdd(hipSide,shSide));
    torso(MB_SPINE,G,valid,conf,spineUp,midSide,f,t,BJ_SPINE,BJ_SHOULDER_CENTER);
    torso(MB_CHEST,G,valid,conf,spineUp,shSide,f,t,BJ_SPINE,BJ_SHOULDER_CENTER);
    torso(MB_NECK,G,valid,conf,dir(U,t,BJ_SHOULDER_CENTER,BJ_HEAD),shSide,f,t,BJ_SHOULDER_CENTER,BJ_HEAD);
    G[MB_HEAD]=G[MB_NECK];valid[MB_HEAD]=valid[MB_NECK];conf[MB_HEAD]=conf[MB_NECK]; // no face orientation: local identity
    G[MB_L_SHOULDER]=G[MB_CHEST];G[MB_R_SHOULDER]=G[MB_CHEST];valid[MB_L_SHOULDER]=valid[MB_R_SHOULDER]=valid[MB_CHEST];conf[MB_L_SHOULDER]=conf[MB_R_SHOULDER]=conf[MB_CHEST];
    // Arms (left rest -X, right rest +X). Elbow flexion in a palms-down T-pose moves the forearm forward (+Z).
    arm(G,valid,conf,U,t,f,true);arm(G,valid,conf,U,t,f,false);
    // Legs (rest -Y). Knee flexion moves the shin backward (-Z); the foot points forward (+Z).
    leg(G,valid,conf,U,t,f,true);leg(G,valid,conf,U,t,f,false);

    // ---- locals, positions
    float[] gr=new float[nb*4],lr=new float[nb*4],lp=new float[nb*3],gp=new float[nb*3];
    double[][] L=new double[nb][];
    for(int i=0;i<nb;i++){int par=MOCAP_PARENT[i];
      double[] local=par<0?G[i]:mcQNorm(mcQMul(mcQConj(G[par]),G[i]));
      if(mcQDot(local,prevLocal[i])<0)local=new double[]{-local[0],-local[1],-local[2],-local[3]};
      if(valid[i]||!f.tracked)prevLocal[i]=local;else local=prevLocal[i];
      L[i]=local;G[i]=par<0?local:mcQNorm(mcQMul(G[par],local));}
    double[][] rest=restOffsets();
    double[][] P=new double[nb][];
    int[] boneJoint={BJ_HIP_CENTER,BJ_SPINE,-1,BJ_SHOULDER_CENTER,BJ_HEAD,-1,BJ_SHOULDER_LEFT,BJ_ELBOW_LEFT,BJ_WRIST_LEFT,-1,BJ_SHOULDER_RIGHT,BJ_ELBOW_RIGHT,BJ_WRIST_RIGHT,
      BJ_HIP_LEFT,BJ_KNEE_LEFT,BJ_ANKLE_LEFT,BJ_HIP_RIGHT,BJ_KNEE_RIGHT,BJ_ANKLE_RIGHT};
    for(int i=0;i<nb;i++){int par=MOCAP_PARENT[i];double[] measured=null;int j=boneJoint[i];
      if(j>=0&&t[j])measured=U[j];
      else if(i==MB_CHEST&&t[BJ_SPINE]&&t[BJ_SHOULDER_CENTER])measured=mcLerp(U[BJ_SPINE],U[BJ_SHOULDER_CENTER],.5);
      else if(i==MB_L_SHOULDER&&t[BJ_SHOULDER_CENTER]&&t[BJ_SHOULDER_LEFT])measured=mcLerp(U[BJ_SHOULDER_CENTER],U[BJ_SHOULDER_LEFT],.25);
      else if(i==MB_R_SHOULDER&&t[BJ_SHOULDER_CENTER]&&t[BJ_SHOULDER_RIGHT])measured=mcLerp(U[BJ_SHOULDER_CENTER],U[BJ_SHOULDER_RIGHT],.25);
      if(par<0)P[i]=measured!=null?measured:mcV(0,lengths[RL_THIGH]+lengths[RL_SHIN]+.07,0);
      else P[i]=measured!=null?measured:mcAdd(P[par],mcQRot(G[par],rest[i]));
      double[] l=par<0?P[i]:rest[i];
      for(int k=0;k<3;k++){gp[i*3+k]=(float)P[i][k];lp[i*3+k]=(float)l[k];}
      for(int k=0;k<4;k++){gr[i*4+k]=(float)G[i][k];lr[i*4+k]=(float)L[i][k];}
    }
    return new MocapPose(f,f.deviceId,f.monotonicMs,f.inputMs,f.frameNumber,f.trackingId,f.tracked,false,f.confidence,gp,gr,lp,lr,conf,valid,lengths.clone());
  }

  // Rest (T-pose) local offsets of each bone in its parent's frame, Unity space, metres.
  double[][] restOffsets(){
    float[] L=lengths;double[][] r=new double[MOCAP_BONES.length][];
    r[MB_HIPS]=mcV(0,0,0);r[MB_SPINE]=mcV(0,L[RL_SPINE_LOW],0);r[MB_CHEST]=mcV(0,L[RL_SPINE_UP]*.5,0);r[MB_NECK]=mcV(0,L[RL_SPINE_UP]*.5,0);r[MB_HEAD]=mcV(0,L[RL_NECK],0);
    for(int s=0;s<2;s++){double sg=s==0?-1:1;int o=s==0?0:4,lo=s==0?0:3;
      r[MB_L_SHOULDER+o]=mcV(sg*.25*L[RL_CLAVICLE],L[RL_SPINE_UP]*.5,0);r[MB_L_UPPER_ARM+o]=mcV(sg*.75*L[RL_CLAVICLE],0,0);
      r[MB_L_LOWER_ARM+o]=mcV(sg*L[RL_UPPER_ARM],0,0);r[MB_L_HAND+o]=mcV(sg*L[RL_FOREARM],0,0);
      r[MB_L_UPPER_LEG+lo]=mcV(sg*L[RL_HIP],0,0);r[MB_L_LOWER_LEG+lo]=mcV(0,-L[RL_THIGH],0);r[MB_L_FOOT+lo]=mcV(0,-L[RL_SHIN],0);}
    return r;
  }

  double[] dir(double[][] U,boolean[] t,int a,int b){return t[a]&&t[b]?mcNorm(mcSub(U[b],U[a])):null;}
  float jc(BodyFrame f,boolean[] t,int a,int b){return t[a]&&t[b]?min(f.confidence(a),f.confidence(b)):0;}
  void torso(int bone,double[][] G,boolean[] valid,float[] conf,double[] p,double[] side,BodyFrame f,boolean[] t,int a,int b){
    double[] q=p==null||side==null?null:mcQFromFrames(Y,X,p,side);
    if(q==null){q=p==null?null:swing(G[MOCAP_PARENT[bone]],Y,p);}
    valid[bone]=q!=null;G[bone]=q!=null?q:mcQNorm(mcQMul(G[MOCAP_PARENT[bone]],prevLocal[bone]));conf[bone]=jc(f,t,a,b);
  }
  // Minimal rotation from the parent's predicted rest direction onto p (no twist).
  double[] swing(double[] parentG,double[] rest,double[] p){return mcQNorm(mcQMul(mcQFromTo(mcQRot(parentG,rest),p),parentG));}
  // Swing from parent blended toward the full frame solution when a twist axis is available.
  double[] limb(int bone,double[][] G,double[] p0,double[] p,double[] s0,double[] s,double w){
    double[] parent=G[MOCAP_PARENT[bone]];double[] q=swing(parent,p0,p);
    if(s!=null&&w>0){double[] fr=mcQFromFrames(p0,s0,p,s);if(fr!=null)q=mcQSlerp(q,fr,w);}
    return mcQNorm(q);
  }
  // Component of v orthogonal to p, with its length (sin of the angle) as weight input.
  double[] perp(double[] v,double[] p){return v==null||p==null?null:mcSub(v,mcScale(p,mcDot(v,p)));}
  void setLimb(int bone,double[][] G,boolean[] valid,float[] conf,double[] q,float c){valid[bone]=q!=null;
    G[bone]=q!=null?q:mcQNorm(mcQMul(G[MOCAP_PARENT[bone]],prevLocal[bone]));conf[bone]=c;}
  void arm(double[][] G,boolean[] valid,float[] conf,double[][] U,boolean[] t,BodyFrame f,boolean left){
    int S=left?BJ_SHOULDER_LEFT:BJ_SHOULDER_RIGHT,E=left?BJ_ELBOW_LEFT:BJ_ELBOW_RIGHT,W=left?BJ_WRIST_LEFT:BJ_WRIST_RIGHT,H=left?BJ_HAND_LEFT:BJ_HAND_RIGHT,
      TIP=left?BJ_HAND_TIP_LEFT:BJ_HAND_TIP_RIGHT,TH=left?BJ_THUMB_LEFT:BJ_THUMB_RIGHT;
    int bU=left?MB_L_UPPER_ARM:MB_R_UPPER_ARM,bL=left?MB_L_LOWER_ARM:MB_R_LOWER_ARM,bH=left?MB_L_HAND:MB_R_HAND;double[] rest=left?NX:X;
    double[] upper=dir(U,t,S,E),fore=dir(U,t,E,W);
    double[] bend=perp(fore,upper);double bw=bend==null?0:mcSmoothstep(.25,.6,mcLen(bend));
    setLimb(bU,G,valid,conf,upper==null?null:limb(bU,G,rest,upper,Z,bend,bw),jc(f,t,S,E));
    double[] thumbV=t[TH]&&t[W]?mcSub(U[TH],U[W]):null;
    double[] th=perp(thumbV,fore);double tw=th==null?0:mcSmoothstep(.01,.03,mcLen(th));
    setLimb(bL,G,valid,conf,fore==null?null:limb(bL,G,rest,fore,Z,th,tw),jc(f,t,E,W));
    double[] hand=t[TIP]?dir(U,t,W,TIP):dir(U,t,W,H);
    double[] th2=perp(thumbV,hand);double tw2=th2==null?0:mcSmoothstep(.01,.03,mcLen(th2));
    setLimb(bH,G,valid,conf,hand==null?null:limb(bH,G,rest,hand,Z,th2,tw2),jc(f,t,W,H));
  }
  void leg(double[][] G,boolean[] valid,float[] conf,double[][] U,boolean[] t,BodyFrame f,boolean left){
    int HP=left?BJ_HIP_LEFT:BJ_HIP_RIGHT,K=left?BJ_KNEE_LEFT:BJ_KNEE_RIGHT,A=left?BJ_ANKLE_LEFT:BJ_ANKLE_RIGHT,F=left?BJ_FOOT_LEFT:BJ_FOOT_RIGHT;
    int bU=left?MB_L_UPPER_LEG:MB_R_UPPER_LEG,bL=left?MB_L_LOWER_LEG:MB_R_LOWER_LEG,bF=left?MB_L_FOOT:MB_R_FOOT;
    double[] thigh=dir(U,t,HP,K),shin=dir(U,t,K,A),foot=dir(U,t,A,F);
    double[] bend=perp(shin,thigh);double bw=bend==null?0:mcSmoothstep(.25,.6,mcLen(bend));
    setLimb(bU,G,valid,conf,thigh==null?null:limb(bU,G,NY,thigh,NZ,bend,bw),jc(f,t,HP,K));
    double[] fp=perp(foot,shin);double fw=fp==null?0:mcSmoothstep(.3,.6,mcLen(fp));
    setLimb(bL,G,valid,conf,shin==null?null:limb(bL,G,NY,shin,Z,fp,fw),jc(f,t,K,A));
    setLimb(bF,G,valid,conf,foot==null?null:swing(G[bL],FOOT_REST,foot),jc(f,t,A,F));
  }
  void updateLengths(double[][] U,boolean[] t,BodyFrame f){
    int[][] seg={{RL_SPINE_LOW,BJ_HIP_CENTER,BJ_SPINE},{RL_SPINE_UP,BJ_SPINE,BJ_SHOULDER_CENTER},{RL_NECK,BJ_SHOULDER_CENTER,BJ_HEAD},
      {RL_CLAVICLE,BJ_SHOULDER_CENTER,BJ_SHOULDER_LEFT},{RL_CLAVICLE,BJ_SHOULDER_CENTER,BJ_SHOULDER_RIGHT},{RL_UPPER_ARM,BJ_SHOULDER_LEFT,BJ_ELBOW_LEFT},{RL_UPPER_ARM,BJ_SHOULDER_RIGHT,BJ_ELBOW_RIGHT},
      {RL_FOREARM,BJ_ELBOW_LEFT,BJ_WRIST_LEFT},{RL_FOREARM,BJ_ELBOW_RIGHT,BJ_WRIST_RIGHT},{RL_HAND,BJ_WRIST_LEFT,BJ_HAND_LEFT},{RL_HAND,BJ_WRIST_RIGHT,BJ_HAND_RIGHT},
      {RL_HIP,BJ_HIP_CENTER,BJ_HIP_LEFT},{RL_HIP,BJ_HIP_CENTER,BJ_HIP_RIGHT},{RL_THIGH,BJ_HIP_LEFT,BJ_KNEE_LEFT},{RL_THIGH,BJ_HIP_RIGHT,BJ_KNEE_RIGHT},
      {RL_SHIN,BJ_KNEE_LEFT,BJ_ANKLE_LEFT},{RL_SHIN,BJ_KNEE_RIGHT,BJ_ANKLE_RIGHT},{RL_FOOT,BJ_ANKLE_LEFT,BJ_FOOT_LEFT},{RL_FOOT,BJ_ANKLE_RIGHT,BJ_FOOT_RIGHT}};
    for(int[] s:seg){if(!t[s[1]]||!t[s[2]]||f.confidence(s[1])<.3f||f.confidence(s[2])<.3f)continue;double d=mcLen(mcSub(U[s[2]],U[s[1]]));
      if(d<.02||d>1.2)continue;int n=lengthSamples[s[0]];
      if(n==0)lengths[s[0]]=(float)d;else if(n<60)lengths[s[0]]+=(float)((d-lengths[s[0]])/(n+1));else lengths[s[0]]+=(float)((d-lengths[s[0]])*.02);
      lengthSamples[s[0]]=n+1;}
  }
}
