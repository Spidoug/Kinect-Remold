// ===== SynKinect Studio / SynSkeleton / Articulated body solver =====
//
// Dependency-free, model-based 20-joint body tracker for Kinect depth, in the
// spirit of the generative trackers used alongside OpenNI/NiTE and the Kinect
// SDK (which themselves combine a per-frame detector with temporal fitting):
//
//  1. Anthropometric body model (capsules) scaled from the measured user height.
//  2. Accumulative geodesic extrema (AGEX) over the depth-connected body surface
//     locate head, hands and feet independently of the previous pose; the
//     geodesic path back to the torso tells which shoulder an arm belongs to,
//     so crossed arms and hands in front of the chest keep their identity.
//  3. The torso is a rigid body tracked frame-to-frame by trimmed ICP against a
//     torso surface template captured from the user.
//  4. Limbs are fitted hierarchically (upper segment, then lower) to the points
//     they explain. Visible skin points are pushed back along the viewing ray by
//     the limb radius, so joints are anatomical centres (Kinect SDK semantics),
//     not skin-surface points.
//  5. Joint side follows the Kinect SDK convention: "left" is the user's
//     anatomical left (image right on the un-mirrored depth stream).
//
// All coordinates are Kinect camera space (metres, +X right, +Y down, +Z forward).

class ArticulatedBodyModel {
  float height=1.72f;
  float torsoLen,spineRatio=.43f,neckToHead,shoulderHalf,hipHalf,upperArm,forearm,handLen,handTip,thigh,shin,footLen,ankleHeight;
  float footR,upperArmR,forearmR,handR,thighR,shinR,torsoHalfWidth,torsoHalfDepth,headR;
  int samples=0;
  ArticulatedBodyModel(){fromHeight(1.72f);}
  // Segment proportions after Drillis & Contini / Winter (fractions of stature).
  void fromHeight(float h){
    height=constrain(h,1.20f,2.10f);float H=height;
    torsoLen=.285f*H;neckToHead=.110f*H;shoulderHalf=.1070f*H;hipHalf=.0540f*H;
    upperArm=.168f*H;forearm=.148f*H;handLen=.044f*H;handTip=.100f*H;thigh=.252f*H;shin=.241f*H;footLen=.064f*H;ankleHeight=.046f*H;
    upperArmR=.030f*H;forearmR=.024f*H;handR=.021f*H;thighR=.043f*H;shinR=.032f*H;torsoHalfWidth=.096f*H;torsoHalfDepth=.060f*H;headR=.060f*H;footR=.022f*H;
  }
  float armReach(){return upperArm+forearm+handTip;}
  float legLen(){return thigh+shin;}
}

class ArticulatedLimb {
  final boolean left,arm;PVector upper=new PVector(),lower=new PVector();
  float upperQ=0,lowerQ=0;int support=0,lostFrames=0;boolean valid=false;
  ArticulatedLimb(boolean left,boolean arm){this.left=left;this.arm=arm;}
}

class AgexExtremum {PVector point;float geodesic;int node;float side;boolean used=false;String label="";AgexExtremum(PVector p,float g,int n){point=p;geodesic=g;node=n;}}

class ArticulatedBodySolver {
  final SkeletonConfig cfg;final ArticulatedBodyModel model=new ArticulatedBodyModel();
  boolean initialized=false;int stableFrames=0,lostFrames=0;
  // Torso rigid pose: origin = hip centre; axes: left (user's left), up, fwd (toward camera).
  PVector root=new PVector(),axLeft=new PVector(1,0,0),axUp=new PVector(0,-1,0),axFwd=new PVector(0,0,-1);
  PVector rootVel=new PVector();
  final ArrayList<PVector> torsoTemplate=new ArrayList<PVector>(); // torso-local surface samples
  final ArticulatedLimb leftArm=new ArticulatedLimb(true,true),rightArm=new ArticulatedLimb(false,true),leftLeg=new ArticulatedLimb(true,false),rightLeg=new ArticulatedLimb(false,false);
  PVector headOffset=null; // head centre in torso-local coordinates
  // Per-frame working data
  ArrayList<PVector> pts=new ArrayList<PVector>();ArrayList<PVector> axisPts=new ArrayList<PVector>();int[] ptNode=new int[0];
  final ArrayList<AgexExtremum> extrema=new ArrayList<AgexExtremum>();
  float lastTorsoRms=0,lastTorsoOverlap=0;String lastReason="";

  SkeletonFloorModel lastFloor;DepthFrame lastDepth;
  final long debugFrom=Long.getLong("articulated.debugFrom",-1L),debugTo=Long.getLong("articulated.debugTo",Long.MAX_VALUE);
  final boolean debug=System.getProperty("articulated.debug")!=null;boolean dbgFrame=false;long firstTick=-1;final long[] prof=new long[5];int profN=0;
  ArticulatedBodySolver(SkeletonConfig c){cfg=c;}
  void debugDump(){
    if(!debug)return;
    if(profN>0)println(String.format(Locale.ROOT,"[prof] points %.2f  geodesic %.2f  torso %.2f  limbs %.2f  rest %.2f ms (n=%d, nodes=%d)",prof[0]/1e6/profN,prof[1]/1e6/profN,prof[2]/1e6/profN,prof[3]/1e6/profN,prof[4]/1e6/profN,profN,nodeCount));
    println(String.format(Locale.ROOT,"[artic] H=%.3f pts=%d nodes=%d extrema=%d rms=%.3f ovl=%.2f root=(%.3f,%.3f,%.3f) up=(%.2f,%.2f,%.2f) fwd=(%.2f,%.2f,%.2f)",model.height,pts.size(),nodeCount,extrema.size(),lastTorsoRms,lastTorsoOverlap,root.x,root.y,root.z,axUp.x,axUp.y,axUp.z,axFwd.x,axFwd.y,axFwd.z));
    if(maskRef!=null){int inMask=0,all=0;for(int i=0;i<maskRef.mm.length;i++){int mm=maskRef.mm[i];if(mm>0&&mm<2350){all++;if(maskRef.mask[i])inMask++;}}println("   near<2.35m cells: all="+all+" inMask="+inMask+" seedDepth="+maskRef.seedDepthMm);}
    {int fw=0,cf=0;for(PVector p:pts)if(local(p).z>.2f)fw++;for(PVector q:cellPts)if(q!=null&&local(q).z>.2f)cf++;println("   forwardPts="+fw+" forwardCells="+cf+" maskSamples="+(maskRef==null?0:maskRef.samples));}
    if(lastFloor!=null)println(String.format(Locale.ROOT,"   rootHeight=%.3f (%.3fH) headH=%.3f",lastFloor.height(root),lastFloor.height(root)/model.height,lastFloor.height(head())));
    if(lastFloor!=null){PVector g=lastDepth!=null&&lastDepth.motion!=null?lastDepth.motion.gravityUnit():null;println(String.format(Locale.ROOT,"   floor valid=%s n=(%.3f,%.3f,%.3f) d=%.3f inl=%d grav=%s",lastFloor.valid,lastFloor.nx,lastFloor.ny,lastFloor.nz,lastFloor.d,lastFloor.inliers,g==null?"-":String.format(Locale.ROOT,"(%.3f,%.3f,%.3f)",g.x,g.y,g.z)));}
    for(AgexExtremum e:extrema){PVector l=local(e.point);println(String.format(Locale.ROOT,"   ext %-11s geo=%.2f local=(%.2f,%.2f,%.2f) side=%.2f",e.label,e.geodesic,l.x,l.y,l.z,e.side));}
    for(ArticulatedLimb l:limbs())println(String.format(Locale.ROOT,"   limb %s%s sup=%d up=(%.2f,%.2f,%.2f) lo=(%.2f,%.2f,%.2f)",l.left?"L":"R",l.arm?"arm":"leg",l.support,l.upper.dot(axLeft),l.upper.dot(axUp),l.upper.dot(axFwd),l.lower.dot(axLeft),l.lower.dot(axUp),l.lower.dot(axFwd)));
  }
  void reset(){initialized=false;stableFrames=0;lostFrames=0;torsoTemplate.clear();headOffset=null;rootVel.set(0,0,0);
    for(ArticulatedLimb l:limbs()){l.valid=false;l.support=0;l.lostFrames=0;}model.samples=0;}
  ArticulatedLimb[] limbs(){return new ArticulatedLimb[]{leftArm,rightArm,leftLeg,rightLeg};}

  // ---------------------------------------------------------------- geometry helpers
  PVector local(PVector p){PVector d=PVector.sub(p,root);return new PVector(d.dot(axLeft),d.dot(axUp),d.dot(axFwd));}
  PVector world(float l,float u,float f){return new PVector(root.x+axLeft.x*l+axUp.x*u+axFwd.x*f,root.y+axLeft.y*l+axUp.y*u+axFwd.y*f,root.z+axLeft.z*l+axUp.z*u+axFwd.z*f);}
  PVector world(PVector loc){return world(loc.x,loc.y,loc.z);}
  PVector hipCenter(){return root.copy();}
  PVector shoulderCenter(){return world(0,model.torsoLen,0);}
  PVector spine(){return world(0,model.torsoLen*model.spineRatio,0);}
  PVector shoulder(boolean left){return world(left?model.shoulderHalf:-model.shoulderHalf,model.torsoLen-.018f*model.height,0);}
  PVector hip(boolean left){return world(left?model.hipHalf:-model.hipHalf,-.012f*model.height,0);}
  PVector head(){return headOffset!=null?world(headOffset):world(0,model.torsoLen+model.neckToHead,0);}
  static float segDist(PVector p,PVector a,PVector b){float abx=b.x-a.x,aby=b.y-a.y,abz=b.z-a.z,apx=p.x-a.x,apy=p.y-a.y,apz=p.z-a.z,d=abx*abx+aby*aby+abz*abz;
    float t=d<1e-9f?0:constrain((apx*abx+apy*aby+apz*abz)/d,0,1);float dx=apx-abx*t,dy=apy-aby*t,dz=apz-abz*t;return sqrt(dx*dx+dy*dy+dz*dz);}
  // Visible skin sample pushed back along the viewing ray to the approximate bone axis.
  static PVector pushBack(PVector p,float r){float m=p.mag();if(m<1e-6f)return p.copy();return new PVector(p.x+p.x/m*r,p.y+p.y/m*r,p.z+p.z/m*r);}

  // ---------------------------------------------------------------- main entry
  SkeletonPose3D solve(DepthFrame depth,SkeletonDepthBodyMask body,SkeletonCalibration3D cal,SkeletonFloorModel floor,long tick){
    if(body==null||cal==null)return null;
    long t0=System.nanoTime();if(firstTick<0)firstTick=tick;long rel=tick-firstTick;dbgFrame=debug&&debugFrom>=0&&rel>=debugFrom&&rel<=debugTo;
    lastFloor=floor;lastDepth=depth;buildPoints(body,cal);
    gravityUp=floor!=null?floor.upVector():null;
    if(pts.size()<60){lastReason="sparse";return null;}
    long t1=System.nanoTime();computeGeodesicExtrema(body,cal);long t2=System.nanoTime();
    boolean fresh=!initialized;
    if(!initialized){if(!initialize(floor)){lastReason="initializing";return null;}}
    else{predict();trackTorso();}
    long t3=System.nanoTime();
    assignExtrema();
    fitLimbs(fresh);long t4=System.nanoTime();
    fitHead();
    enforceFloor(floor);
    learnModel(floor);
    if(debug){prof[0]+=t1-t0;prof[1]+=t2-t1;prof[2]+=t3-t2;prof[3]+=t4-t3;prof[4]+=System.nanoTime()-t4;profN++;}
    initialized=true;stableFrames++;
    if(debug&&(debugFrom<0?stableFrames%10==6:dbgFrame)){println("[tick "+(tick-firstTick)+"]");debugDump();}
    return publish(cal,tick);
  }

  // ---------------------------------------------------------------- points
  SkeletonDepthBodyMask maskRef;PVector[] cellPts=new PVector[0];SkeletonCalibration3D calRef;
  void buildPoints(SkeletonDepthBodyMask b,SkeletonCalibration3D cal){
    pts.clear();maskRef=b;calRef=cal;if(cellPts.length!=b.gridW*b.gridH)cellPts=new PVector[b.gridW*b.gridH];else Arrays.fill(cellPts,null);
    int target=cfg.articulatedMaxPoints,cells=max(1,b.samples),stride=max(1,round(sqrt(cells/(float)max(1,target))));
    for(int gy=b.minGY;gy<=b.maxGY;gy++)for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(i<0||i>=b.mask.length||!b.mask[i])continue;int mm=b.mm[i];if(mm<=0)continue;
      PVector q=cal.deproject(b.px(gx),b.py(gy),mm);if(q==null)continue;cellPts[i]=q;if(gx%stride==0&&gy%stride==0)pts.add(q);}
  }
  // Projective data association (as in KinectFusion): project the model point into
  // the depth grid and search a small window. O(1) per query, no spatial hash.
  PVector nearestProjective(PVector p,float maxD){
    if(maskRef==null||calRef==null||p.z<=.05f)return null;PVector uv=calRef.projectDepth(p);if(uv==null)return null;
    SkeletonDepthBodyMask b=maskRef;int gx=round((uv.x-b.step*.5f)/b.step),gy=round((uv.y-b.step*.5f)/b.step);
    float pxPerM=calRef.sharedCalibration.fx/max(.3f,p.z);int r=constrain(ceil(maxD*pxPerM/b.step),1,4);
    PVector best=null;float bd=maxD*maxD;
    for(int y=max(0,gy-r);y<=min(b.gridH-1,gy+r);y++)for(int x=max(0,gx-r);x<=min(b.gridW-1,gx+r);x++){PVector q=cellPts[y*b.gridW+x];if(q==null)continue;
      float dx=q.x-p.x,dy=q.y-p.y,dz=q.z-p.z,d=dx*dx+dy*dy+dz*dz;if(d<bd){bd=d;best=q;}}
    return best;
  }
  // Highest body point above the floor, using every mask cell (not the strided set).
  float measureTop(SkeletonFloorModel floor,PVector axisPoint,float radius){
    // Only cells around the head column count: a raised hand is not the stature.
    PVector n=new PVector(floor.nx,floor.ny,floor.nz);float top=-Float.MAX_VALUE;
    for(PVector q:cellPts){if(q==null)continue;if(axisPoint!=null){PVector d=PVector.sub(q,axisPoint);d.sub(PVector.mult(n,d.dot(n)));if(d.mag()>radius)continue;}top=max(top,floor.height(q));}
    float cellM=maskRef==null?0:maskRef.step*(root.z>0?root.z:2.5f)/calRef.sharedCalibration.fx;return top+cellM*.5f+cfg.articulatedStatureTopOffsetM;}
  float measureBottom(SkeletonFloorModel floor){float b=Float.MAX_VALUE;for(PVector q:cellPts)if(q!=null)b=min(b,floor.height(q));return b;}

  // ---------------------------------------------------------------- AGEX
  // Graph over a coarse mask grid, edges only between depth-continuous neighbours,
  // so an arm in front of the chest is NOT a shortcut into the torso.
  int gw,gh,gstep;int[] nodeIndex;PVector[] nodePos;int nodeCount;float[] geo;int[] parent;int centerNode=-1;
  void computeGeodesicExtrema(SkeletonDepthBodyMask b,SkeletonCalibration3D cal){
    // metric node spacing (~5 cm on the body at any distance)
    float seedZ=b.seedDepthMm>0?b.seedDepthMm/1000.0f:2.5f;float cellPx=cfg.articulatedGeodesicCellM*cal.sharedCalibration.fx/max(.5f,seedZ);
    extrema.clear();gstep=max(1,round(cellPx/(float)b.step));
    gw=(b.maxGX-b.minGX)/gstep+1;gh=(b.maxGY-b.minGY)/gstep+1;if(gw<=1||gh<=1)return;
    nodeIndex=new int[gw*gh];Arrays.fill(nodeIndex,-1);ArrayList<PVector> nodes=new ArrayList<PVector>();
    int best=-1,bestClear=-1;
    for(int cy=0;cy<gh;cy++)for(int cx=0;cx<gw;cx++){int gx=b.minGX+cx*gstep,gy=b.minGY+cy*gstep,i=gy*b.gridW+gx;if(i<0||i>=b.mask.length||!b.mask[i]||b.mm[i]<=0)continue;
      PVector q=cal.deproject(b.px(gx),b.py(gy),b.mm[i]);if(q==null)continue;nodeIndex[cy*gw+cx]=nodes.size();nodes.add(q);
      int c=b.clearance!=null&&i<b.clearance.length?b.clearance[i]:0;if(c>bestClear&&c<(1<<19)){bestClear=c;best=nodes.size()-1;}}
    nodeCount=nodes.size();if(nodeCount<20)return;nodePos=nodes.toArray(new PVector[nodeCount]);
    // Start from the torso: the current torso centre when tracking, otherwise the
    // thickest silhouette point (maximum distance-transform value).
    centerNode=best;
    if(initialized){PVector c=world(0,model.torsoLen*.45f,model.torsoHalfDepth);float bd=Float.MAX_VALUE;for(int i=0;i<nodeCount;i++){float d=PVector.dist(nodePos[i],c);if(d<bd){bd=d;centerNode=i;}}}
    if(centerNode<0)return;
    geo=new float[nodeCount];Arrays.fill(geo,Float.POSITIVE_INFINITY);parent=new int[nodeCount];Arrays.fill(parent,-1);
    dijkstra(centerNode,true);
    float[] centerGeo=Arrays.copyOf(geo,nodeCount);
    int maxExtrema=8;float minGeo=.22f*model.height;
    for(int k=0;k<maxExtrema;k++){
      int far=-1;float fd=-1;for(int i=0;i<nodeCount;i++)if(geo[i]<Float.POSITIVE_INFINITY&&geo[i]>fd){fd=geo[i];far=i;}
      if(far<0||fd<minGeo*(k==0?1:.7f))break;
      extrema.add(new AgexExtremum(nodePos[far].copy(),centerGeo[far],far));
      dijkstra(far,false);
    }
    // restore the torso-rooted distances/parents for path queries
    System.arraycopy(centerGeo,0,geo,0,nodeCount);
    // An extremum lying on the torso-rooted path of a geodesically farther extremum is
    // an intermediate point of the same limb (elbow/knee), not a separate body end.
    ArrayList<AgexExtremum> keep=new ArrayList<AgexExtremum>();
    for(AgexExtremum e:extrema){boolean inner=false;
      for(AgexExtremum o:extrema){if(o==e||o.geodesic<=e.geodesic)continue;int n=o.node,guard=0;
        while(n>=0&&guard++<4000){if(PVector.dist(nodePos[n],e.point)<cfg.articulatedGeodesicLinkM*1.6f){inner=true;break;}n=parent[n];}
        if(inner)break;}
      if(!inner)keep.add(e);}
    extrema.clear();extrema.addAll(keep);
  }
  int[] dx8={-1,1,0,0,-1,1,-1,1},dy8={0,0,-1,1,-1,-1,1,1};
  void dijkstra(int source,boolean resetParents){
    // incremental multi-source: only lowers distances
    java.util.PriorityQueue<long[]> q=new java.util.PriorityQueue<long[]>(64,new java.util.Comparator<long[]>(){public int compare(long[] a,long[] b){return Long.compare(a[0],b[0]);}});
    geo[source]=0;if(resetParents)parent[source]=-1;q.add(new long[]{0,source});
    float link=cfg.articulatedGeodesicLinkM;int[] pos=new int[nodeCount];
    // node -> grid position lookup
    for(int cy=0;cy<gh;cy++)for(int cx=0;cx<gw;cx++){int n=nodeIndex[cy*gw+cx];if(n>=0)pos[n]=cy*gw+cx;}
    while(!q.isEmpty()){long[] top=q.poll();int u=(int)top[1];float du=top[0]/1e6f;if(du>geo[u]+1e-6f)continue;int cell=pos[u],cx=cell%gw,cy=cell/gw;
      for(int k=0;k<8;k++){int nx=cx+dx8[k],ny=cy+dy8[k];if(nx<0||ny<0||nx>=gw||ny>=gh)continue;int v=nodeIndex[ny*gw+nx];if(v<0)continue;
        // Depth discontinuities are not forbidden (an arm pointing at the sensor is a chain
        // of them) but carry a large penalty, so a hand resting on the chest does not
        // become a geodesic shortcut into the torso.
        float d=PVector.dist(nodePos[u],nodePos[v]);if(abs(nodePos[u].z-nodePos[v].z)>link*(k>=4?1.4f:1.0f)){if(d>cfg.articulatedGeodesicMaxJumpM)continue;float jump=abs(nodePos[u].z-nodePos[v].z)-link;d+=cfg.articulatedGeodesicJumpPenaltyM*constrain(jump/.20f,.15f,1);}
        float nd=du+d;if(nd<geo[v]){geo[v]=nd;if(resetParents)parent[v]=u;q.add(new long[]{(long)(nd*1e6f),v});}}}
  }
  // Lateral side (+ = user's left) at which a node's geodesic path enters the torso.
  float pathEntrySide(int node){
    if(parent==null||node<0)return 0;int n=node,guard=0;PVector last=nodePos[n];
    while(n>=0&&guard++<4000){PVector l=local(nodePos[n]);
      boolean inTorso=l.y>-.02f*model.height&&l.y<model.torsoLen*1.02f&&abs(l.x)<model.torsoHalfWidth*.92f;
      if(inTorso)return local(last).x;last=nodePos[n];n=parent[n];}
    return local(last).x;
  }
  // Point on the torso-rooted geodesic path at a given arc length back from a node.
  PVector alongPath(int node,float arc){if(parent==null||node<0)return null;int n=node,guard=0;float acc=0;PVector prev=nodePos[n];
    while(parent[n]>=0&&guard++<4000){int p=parent[n];acc+=PVector.dist(nodePos[n],nodePos[p]);n=p;if(acc>=arc)return nodePos[n].copy();}return null;}

  // ---------------------------------------------------------------- initialisation
  boolean initialize(SkeletonFloorModel floor){
    if(extrema.isEmpty()||centerNode<0){if(debug)println("[artic] init: extrema="+extrema.size()+" centre="+centerNode+" nodes="+nodeCount+" pts="+pts.size());return false;}
    // Up axis from the floor when available (independent of the camera tilt).
    PVector up=floor!=null?floor.upVector():null;if(up==null)up=new PVector(0,-1,0);up.normalize();
    // Height: top of the body above the floor, when the feet are visible.
    boolean hasFloor=floor!=null&&floor.valid;float bottom=hasFloor?measureBottom(floor):1;
    boolean feetOnFloor=hasFloor&&bottom<.16f;
    float stature=feetOnFloor?measureTop(floor,nodePos[centerNode],.13f):(model.samples>0?model.height:1.72f);
    // Refuse to calibrate on a pose that is clearly not upright (crouching etc.).
    if(feetOnFloor&&(stature<1.20f||stature>2.15f))return false;
    model.fromHeight(stature);
    PVector c=nodePos[centerNode];PVector toCam=PVector.mult(c,-1);PVector fwd=PVector.sub(toCam,PVector.mult(up,toCam.dot(up)));if(fwd.mag()<1e-4f)fwd.set(0,0,-1);fwd.normalize();
    axUp.set(up);axFwd.set(fwd);axLeft=up.cross(fwd);axLeft.normalize();
    // Torso centre: thickest silhouette point pushed to the torso axis; hips from stature.
    PVector centre=pushBack(c,model.torsoHalfDepth);
    if(feetOnFloor){float hc=floor.height(centre),hipH=.540f*model.height;root=PVector.sub(centre,PVector.mult(axUp,hc-hipH));}
    else{
      // No visible floor (close range / seated): anchor the hips from the top of the
      // head, which is almost always in view. Top of the head = stature above floor.
      float top=-Float.MAX_VALUE;PVector cc=nodePos[centerNode];
      for(PVector q:cellPts){if(q==null)continue;PVector d=PVector.sub(q,cc);float along=d.dot(up);PVector hz=PVector.sub(d,PVector.mult(up,along));if(hz.mag()>.13f)continue;top=max(top,along);}
      float cellM=maskRef.step*max(.5f,cc.z)/calRef.sharedCalibration.fx;
      if(top>-1e8f){float topAbove=top+cellM*.5f+cfg.articulatedStatureTopOffsetM;root=PVector.add(cc,PVector.mult(up,topAbove-(1-.540f)*model.height));
        root=PVector.add(root,PVector.mult(fwd,-model.torsoHalfDepth));} // cc is on the front surface
      else root=PVector.sub(centre,PVector.mult(axUp,model.torsoLen*.40f));
    }
    refineTorsoLateral();
    captureTorsoTemplate(true);lastRootFinal=null;angAxis=null;angRate=0;rootVel.set(0,0,0);
    for(ArticulatedLimb l:limbs()){l.valid=false;l.lostFrames=0;setRestPose(l);}
    headOffset=null;initialized=true;stableFrames=0;return true;
  }
  void setRestPose(ArticulatedLimb l){float s=l.left?1:-1;PVector d=PVector.add(PVector.mult(axUp,-1),PVector.mult(axLeft,s*(l.arm?.18f:.03f)));d.normalize();l.upper.set(d);l.lower.set(d);}
  // Centre the torso laterally/depth-wise on the points of the torso band.
  void refineTorsoLateral(){
    for(int it=0;it<3;it++){float sx=0,sf=0;int n=0;ArrayList<Float> fs=new ArrayList<Float>();
      for(PVector p:pts){PVector l=local(p);if(l.y<model.torsoLen*.15f||l.y>model.torsoLen*.85f||abs(l.x)>model.torsoHalfWidth*1.25f)continue;sx+=l.x;fs.add(l.z);n++;}
      if(n<30)return;Collections.sort(fs);float front=fs.get(fs.size()*9/10);
      root=world(sx/n,0,front-model.torsoHalfDepth);}
  }
  void captureTorsoTemplate(boolean replace){
    if(replace)torsoTemplate.clear();HashSet<Long> seen=new HashSet<Long>();float cell=.025f;
    for(PVector t:torsoTemplate)seen.add(voxelKey(t,cell));
    for(PVector p:pts){PVector l=local(p);if(l.y<-.02f*model.height||l.y>model.torsoLen*1.02f||abs(l.x)>model.torsoHalfWidth*1.02f||l.z<-model.torsoHalfDepth*1.4f||l.z>model.torsoHalfDepth*1.6f)continue;
      // Never learn a limb lying in front of the torso as torso surface.
      if(l.z>model.torsoHalfDepth*1.35f)continue;
      long k=voxelKey(l,cell);if(seen.add(k))torsoTemplate.add(l);}
    while(torsoTemplate.size()>cfg.articulatedTemplateMaxPoints)torsoTemplate.remove((int)(Math.random()*torsoTemplate.size()));
  }
  long voxelKey(PVector p,float cell){long x=(long)Math.floor(p.x/cell)&0x1FFFFF,y=(long)Math.floor(p.y/cell)&0x1FFFFF,z=(long)Math.floor(p.z/cell)&0x1FFFFF;return (x<<42)|(y<<21)|z;}

  // ---------------------------------------------------------------- torso tracking
  PVector gravityUp=null;
  // Constant-velocity prediction of the torso (translation and rotation), damped.
  PVector lastRootFinal=null,lastL=null,lastU=null,lastF=null,angAxis=null;float angRate=0;
  void predict(){
    root.add(PVector.mult(rootVel,.6f));
    if(angAxis!=null&&angRate>1e-3f){float a=min(angRate,.35f)*.7f;axLeft=rotateAbout(axLeft,angAxis,a);axUp=rotateAbout(axUp,angAxis,a);axFwd=rotateAbout(axFwd,angAxis,a);orthonormalize();}
  }
  void updateMotion(){
    if(lastRootFinal!=null){rootVel.lerp(PVector.sub(root,lastRootFinal),.6f);
      // R = sum cur_i (x) last_i ; axis-angle of R
      float[] R=new float[9];PVector[] c={axLeft,axUp,axFwd},l={lastL,lastU,lastF};
      for(int k=0;k<3;k++){R[0]+=c[k].x*l[k].x;R[1]+=c[k].x*l[k].y;R[2]+=c[k].x*l[k].z;R[3]+=c[k].y*l[k].x;R[4]+=c[k].y*l[k].y;R[5]+=c[k].y*l[k].z;R[6]+=c[k].z*l[k].x;R[7]+=c[k].z*l[k].y;R[8]+=c[k].z*l[k].z;}
      float ang=acos(constrain((R[0]+R[4]+R[8]-1)*.5f,-1,1));PVector ax=new PVector(R[7]-R[5],R[2]-R[6],R[3]-R[1]);
      if(ang>1e-3f&&ax.mag()>1e-6f){ax.normalize();angAxis=ax;angRate=lerp(angRate,ang,.6f);}else angRate*=.4f;}
    lastRootFinal=root.copy();lastL=axLeft.copy();lastU=axUp.copy();lastF=axFwd.copy();
  }
  void trackTorso(){
    if(torsoTemplate.size()<40){refineTorsoLateral();captureTorsoTemplate(true);return;}
    PVector prevRoot=root.copy();
    for(int it=0;it<cfg.articulatedTorsoIterations;it++){
      float gate=lerp(.10f,.035f,it/(float)max(1,cfg.articulatedTorsoIterations-1));
      ArrayList<PVector> src=new ArrayList<PVector>(),dst=new ArrayList<PVector>();ArrayList<Float> d2=new ArrayList<Float>();
      for(PVector t:torsoTemplate){PVector w=world(t);PVector q=nearestProjective(w,gate);if(q==null)continue;src.add(w);dst.add(q);d2.add(PVector.dist(w,q));}
      if(src.size()<Math.max(25,torsoTemplate.size()/8)){lastTorsoOverlap=src.size()/(float)torsoTemplate.size();break;}
      // trimmed: keep the best 75%
      float[] sorted=new float[d2.size()];for(int i=0;i<sorted.length;i++)sorted[i]=d2.get(i);Arrays.sort(sorted);float thr=sorted[max(0,sorted.length*3/4-1)];
      ArrayList<PVector> a=new ArrayList<PVector>(),b=new ArrayList<PVector>();double rms=0;for(int i=0;i<src.size();i++)if(d2.get(i)<=thr){a.add(src.get(i));b.add(dst.get(i));rms+=d2.get(i)*d2.get(i);}
      lastTorsoRms=(float)Math.sqrt(rms/max(1,a.size()));lastTorsoOverlap=src.size()/(float)torsoTemplate.size();
      // Weak gravity prior: virtual correspondences pull the torso's up axis toward the
      // floor normal. Real leaning still wins (it is backed by hundreds of points),
      // but slow roll/pitch drift of a nearly symmetric torso is removed.
      if(gravityUp!=null){int k=max(2,a.size()/cfg.articulatedGravityPriorDivisor);float L=model.torsoLen*.6f;PVector c0=centroid(a),dc=PVector.sub(centroid(b),c0);
        for(int i=0;i<k;i++){float sg=(i&1)==0?1:-1;a.add(PVector.add(c0,PVector.mult(axUp,sg*L)));b.add(PVector.add(PVector.add(c0,dc),PVector.mult(gravityUp,sg*L)));}}
      float[] R=kabsch(a,b);if(R==null)break;
      // apply: new = R*(x - ca) + cb, for root and axes
      PVector ca=centroid(a),cb=centroid(b);
      root=PVector.add(rotate(R,PVector.sub(root,ca)),cb);axLeft=rotate(R,axLeft);axUp=rotate(R,axUp);axFwd=rotate(R,axFwd);orthonormalize();
      if(PVector.dist(ca,cb)<.0005f)break;
    }
    // Keep the body upright-ish: a standing/sitting user leans, but never flips.
    updateMotion();
    if(stableFrames%cfg.articulatedTemplateRefreshFrames==0)captureTorsoTemplate(false);
  }
  PVector nearest(HashMap<Long,ArrayList<PVector>> grid,PVector p,float maxD,float cell){
    long cx=(long)Math.floor(p.x/cell),cy=(long)Math.floor(p.y/cell),cz=(long)Math.floor(p.z/cell);PVector best=null;float bd=maxD*maxD;int r=max(1,ceil(maxD/cell));
    for(long dz=-r;dz<=r;dz++)for(long dy=-r;dy<=r;dy++)for(long dx=-r;dx<=r;dx++){ArrayList<PVector> l=grid.get((((cx+dx)&0x1FFFFF)<<42)|(((cy+dy)&0x1FFFFF)<<21)|((cz+dz)&0x1FFFFF));if(l==null)continue;
      for(PVector q:l){float ddx=q.x-p.x,ddy=q.y-p.y,ddz=q.z-p.z,d=ddx*ddx+ddy*ddy+ddz*ddz;if(d<bd){bd=d;best=q;}}}
    return best;
  }
  PVector centroid(ArrayList<PVector> l){PVector c=new PVector();for(PVector p:l)c.add(p);c.div(max(1,l.size()));return c;}
  PVector rotate(float[] R,PVector v){return new PVector(R[0]*v.x+R[1]*v.y+R[2]*v.z,R[3]*v.x+R[4]*v.y+R[5]*v.z,R[6]*v.x+R[7]*v.y+R[8]*v.z);}
  void orthonormalize(){axUp.normalize();axFwd=PVector.sub(axFwd,PVector.mult(axUp,axFwd.dot(axUp)));axFwd.normalize();axLeft=axUp.cross(axFwd);axLeft.normalize();}
  // Rotation that best maps a onto b (Horn quaternion method).
  float[] kabsch(ArrayList<PVector> a,ArrayList<PVector> b){
    int n=min(a.size(),b.size());if(n<3)return null;PVector ca=centroid(a),cb=centroid(b);double[][] S=new double[3][3];
    for(int i=0;i<n;i++){PVector p=a.get(i),q=b.get(i);double px=p.x-ca.x,py=p.y-ca.y,pz=p.z-ca.z,qx=q.x-cb.x,qy=q.y-cb.y,qz=q.z-cb.z;
      S[0][0]+=px*qx;S[0][1]+=px*qy;S[0][2]+=px*qz;S[1][0]+=py*qx;S[1][1]+=py*qy;S[1][2]+=py*qz;S[2][0]+=pz*qx;S[2][1]+=pz*qy;S[2][2]+=pz*qz;}
    double[][] N={{S[0][0]+S[1][1]+S[2][2],S[1][2]-S[2][1],S[2][0]-S[0][2],S[0][1]-S[1][0]},{S[1][2]-S[2][1],S[0][0]-S[1][1]-S[2][2],S[0][1]+S[1][0],S[2][0]+S[0][2]},
      {S[2][0]-S[0][2],S[0][1]+S[1][0],-S[0][0]+S[1][1]-S[2][2],S[1][2]+S[2][1]},{S[0][1]-S[1][0],S[2][0]+S[0][2],S[1][2]+S[2][1],-S[0][0]-S[1][1]+S[2][2]}};
    // power iteration on the shifted matrix for the dominant eigenvector
    double shift=0;for(int i=0;i<4;i++)for(int j=0;j<4;j++)shift=Math.max(shift,Math.abs(N[i][j]));shift*=4;
    double[] q={1,0,0,0};for(int it=0;it<60;it++){double[] r=new double[4];for(int i=0;i<4;i++){r[i]=shift*q[i];for(int j=0;j<4;j++)r[i]+=N[i][j]*q[j];}
      double m=Math.sqrt(r[0]*r[0]+r[1]*r[1]+r[2]*r[2]+r[3]*r[3]);if(m<1e-18)return null;for(int i=0;i<4;i++)q[i]=r[i]/m;}
    double w=q[0],x=q[1],y=q[2],z=q[3];
    return new float[]{(float)(w*w+x*x-y*y-z*z),(float)(2*(x*y-w*z)),(float)(2*(x*z+w*y)),(float)(2*(x*y+w*z)),(float)(w*w-x*x+y*y-z*z),(float)(2*(y*z-w*x)),(float)(2*(x*z-w*y)),(float)(2*(y*z+w*x)),(float)(w*w-x*x-y*y+z*z)};
  }

  // ---------------------------------------------------------------- extrema labelling
  PVector[] elbowHint=new PVector[2];
  AgexExtremum headX,handX[]=new AgexExtremum[2],footX[]=new AgexExtremum[2]; // [0]=left,[1]=right
  void assignExtrema(){
    headX=null;handX[0]=handX[1]=null;footX[0]=footX[1]=null;
    for(AgexExtremum e:extrema){e.used=false;e.side=pathEntrySide(e.node);}
    // head: high, central extremum
    float bestH=-1;for(AgexExtremum e:extrema){PVector l=local(e.point);if(l.y>model.torsoLen*.92f&&abs(l.x)<model.shoulderHalf*.95f&&l.y<model.torsoLen+model.neckToHead*1.9f&&l.y>bestH){bestH=l.y;headX=e;}}
    if(headX!=null){headX.used=true;headX.label="head";}
    // feet: extrema well below the hips
    for(AgexExtremum e:extrema){if(e.used)continue;PVector l=local(e.point);if(l.y>-model.legLen()*.55f)continue;int side=l.x>=0?0:1;
      if(footX[side]==null||local(footX[side].point).y>l.y){footX[side]=e;}}
    for(int s=0;s<2;s++)if(footX[s]!=null){footX[s].used=true;footX[s].label=s==0?"left_foot":"right_foot";}
    // hands: remaining far extrema. Side = shoulder at which the geodesic path enters
    // the torso (robust to crossed arms), with temporal continuity as tie breaker.
    ArrayList<AgexExtremum> cand=new ArrayList<AgexExtremum>();
    for(AgexExtremum e:extrema){if(e.used)continue;PVector l=local(e.point);if(e.geodesic<model.forearm*1.1f)continue;
      if(l.y<-model.legLen()*.55f)continue;cand.add(e);}
    // Elbow disambiguation: a bent elbow pushed away from the body is itself a geodesic
    // extremum. A candidate close to a shoulder with a geodesically farther candidate
    // about one forearm away is that arm's elbow, not a hand; keep it as an elbow hint.
    elbowHint[0]=elbowHint[1]=null;
    float fore=model.forearm+model.handLen;
    for(int i=cand.size()-1;i>=0;i--){AgexExtremum e=cand.get(i);
      float dl=PVector.dist(e.point,shoulder(true)),dr=PVector.dist(e.point,shoulder(false));boolean nearLeft=dl<dr;float ds=min(dl,dr);
      if(ds>model.upperArm*1.35f)continue;
      for(AgexExtremum o:cand){if(o==e)continue;float dd=PVector.dist(o.point,e.point);
        if(dd<fore*.55f||dd>fore*1.6f)continue;
        float os=PVector.dist(o.point,nearLeft?shoulder(true):shoulder(false));
        if(os<ds+.12f||os>model.armReach()*1.2f)continue;
        elbowHint[nearLeft?0:1]=pushBack(e.point,model.upperArmR);e.label=nearLeft?"left_elbow":"right_elbow";cand.remove(i);break;}}
    PVector[] predicted={predictedHand(true),predictedHand(false)};
    float bestCost=Float.MAX_VALUE;AgexExtremum bl=null,br=null;
    for(int i=-1;i<cand.size();i++)for(int j=-1;j<cand.size();j++){if(i>=0&&i==j)continue;
      float cost=0;AgexExtremum L=i>=0?cand.get(i):null,R=j>=0?cand.get(j):null;
      cost+=handCost(L,true,predicted[0]);cost+=handCost(R,false,predicted[1]);if(cost<bestCost){bestCost=cost;bl=L;br=R;}}
    handX[0]=bl;handX[1]=br;if(bl!=null){bl.used=true;bl.label="left_hand";}if(br!=null){br.used=true;br.label="right_hand";}
  }
  float handCost(AgexExtremum e,boolean left,PVector predicted){
    if(e==null)return 0.35f; // cost of "no observation" for this hand
    float s=left?1:-1,cost=0;
    // side of torso entry: strong evidence
    float entry=e.side*s;cost+=entry>=0?0:.55f*constrain(-entry/(model.shoulderHalf*.6f),0,1)+.10f;
    // reach: a hand cannot be farther from its shoulder than the arm length
    float reach=PVector.dist(pushBack(e.point,model.handR),shoulder(left));cost+=max(0,reach-model.armReach()*1.15f)*4;
    if(predicted!=null&&stableFrames>2)cost+=min(.30f,PVector.dist(e.point,predicted)*1.2f);
    // prefer the geodesically farthest candidate: the hand ends the arm chain
    cost-=.25f*constrain((e.geodesic-model.armReach()*.5f)/model.armReach(),0,1);
    return cost-.35f;
  }
  PVector predictedHand(boolean left){ArticulatedLimb l=left?leftArm:rightArm;if(!l.valid)return null;PVector e=PVector.add(shoulder(left),PVector.mult(l.upper,model.upperArm));return PVector.add(e,PVector.mult(l.lower,model.forearm+model.handLen*.5f));}

  // ---------------------------------------------------------------- limbs
  void fitLimbs(boolean fresh){
    // Fresh/lost limbs are seeded from their labelled extremum; tracked limbs are
    // re-estimated by the generative pair optimiser (which also considers every
    // extremum for either side, so a wrong label cannot swap or fold a limb).
    for(ArticulatedLimb l:limbs())if(fresh||!l.valid||!cfg.articulatedGenerative)seedFromExtremum(l,fresh);
    if(!fresh&&cfg.articulatedGenerative){optimizePair(leftArm,rightArm);optimizePair(leftLeg,rightLeg);}
    for(int it=0;it<cfg.articulatedLimbIterations;it++){
      // point assignment: torso / head / limb segments by nearest capsule surface
      ArrayList<ArrayList<PVector>> up=new ArrayList<ArrayList<PVector>>(),lo=new ArrayList<ArrayList<PVector>>();
      ArticulatedLimb[] L=limbs();for(int i=0;i<4;i++){up.add(new ArrayList<PVector>());lo.add(new ArrayList<PVector>());}
      PVector sc=shoulderCenter(),hc=hipCenter(),hd=head();
      PVector[] j0=new PVector[4],j1=new PVector[4],j2=new PVector[4];float[] r0=new float[4],r1=new float[4];
      for(int i=0;i<4;i++){ArticulatedLimb l=L[i];j0[i]=l.arm?shoulder(l.left):hip(l.left);float a=l.arm?model.upperArm:model.thigh,b=l.arm?model.forearm+model.handLen:model.shin;
        j1[i]=PVector.add(j0[i],PVector.mult(l.upper,a));j2[i]=PVector.add(j1[i],PVector.mult(l.lower,b));r0[i]=l.arm?model.upperArmR:model.thighR;r1[i]=l.arm?model.forearmR:model.shinR;}
      for(PVector p:pts){
        PVector lp=local(p);
        // torso as a rounded box
        float tx=max(0,abs(lp.x)-model.torsoHalfWidth),ty=max(0,max(-.03f*model.height-lp.y,lp.y-model.torsoLen)),tz=max(0,abs(lp.z)-model.torsoHalfDepth);
        float dTorso=sqrt(tx*tx+ty*ty+tz*tz);float dHead=PVector.dist(p,hd)-model.headR;
        float best=min(dTorso,dHead)+cfg.articulatedTorsoBiasM;int bi=-1,bs=0;
        for(int i=0;i<4;i++){float du=segDist(p,j0[i],j1[i])-r0[i],dl=segDist(p,j1[i],j2[i])-r1[i];
          if(du<best){best=du;bi=i;bs=0;}if(dl<best){best=dl;bi=i;bs=1;}
          if(!L[i].arm){float df=segDist(p,j2[i],PVector.add(j2[i],PVector.mult(footDirection(),model.footLen)))-model.footR;if(df<best){best=df;bi=-1;}}}
        if(bi<0||best>cfg.articulatedAssignGateM)continue;
        (bs==0?up:lo).get(bi).add(p);
      }
      for(int i=0;i<4;i++)fitLimb(L[i],j0[i],up.get(i),lo.get(i),it==cfg.articulatedLimbIterations-1);
    }
  }
  void seedFromExtremum(ArticulatedLimb l,boolean fresh){
    AgexExtremum e=l.arm?handX[l.left?0:1]:footX[l.left?0:1];if(e==null)return;
    PVector j0=l.arm?shoulder(l.left):hip(l.left);float a=l.arm?model.upperArm:model.thigh,b=l.arm?model.forearm+model.handLen:model.shin;
    PVector tip=extremumTip(l,e.point);
    PVector cur=PVector.add(PVector.add(j0,PVector.mult(l.upper,a)),PVector.mult(l.lower,b));
    PVector curMid=PVector.add(j0,PVector.mult(l.upper,a));PVector eh=l.arm?elbowHint[l.left?0:1]:null;
    if(!fresh&&l.valid&&PVector.dist(cur,tip)<.16f&&(eh==null||PVector.dist(curMid,eh)<.12f))return;
    // Middle joint from an elbow extremum or the geodesic path (elbow/knee lies about
    // one lower-segment length back along it), else two-bone IK away from the torso.
    PVector oldU=l.upper.copy(),oldL=l.lower.copy();boolean had=l.valid&&!fresh;
    PVector hint=l.arm?elbowHint[l.left?0:1]:null;
    PVector mid=hint!=null?hint:alongPath(e.node,l.arm?(model.forearm+model.handLen*.8f):(model.shin*.95f));
    boolean done=false;
    if(mid!=null){if(hint==null)mid=pushBack(mid,l.arm?model.upperArmR:model.thighR);PVector d=PVector.sub(mid,j0);if(d.mag()>1e-3f){d.normalize();PVector m=PVector.add(j0,PVector.mult(d,a));PVector d2=PVector.sub(tip,m);
        if(d2.mag()>1e-3f){d2.normalize();l.upper.set(d);l.lower.set(d2);done=true;}}}
    if(!done)solveTwoBone(l,j0,tip,a,b);
    // Generative verification ("render and compare"): keep the tracked limb when the
    // re-seeded one explains the depth image worse (crossed arms, hand on the torso).
    if(had){float sNew=limbScore(l,j0,l.upper,l.lower),sOld=limbScore(l,j0,oldU,oldL);
      if(sNew<sOld-cfg.articulatedReseedMargin){l.upper.set(oldU);l.lower.set(oldL);return;}}
    l.valid=true;
  }
  // Mean agreement of the limb's camera-facing capsule surface with the depth map:
  // +1 measured surface where the model is, -1 free space seen through the model
  // (the depth is behind it / outside the body), 0 occluded by something in front.
  float limbScore(ArticulatedLimb l,PVector j0,PVector u,PVector lo){
    if(maskRef==null||calRef==null)return 0;float a=l.arm?model.upperArm:model.thigh,b=l.arm?model.forearm+model.handLen:model.shin,ru=l.arm?model.upperArmR:model.thighR,rl=l.arm?model.forearmR:model.shinR;
    PVector m=PVector.add(j0,PVector.mult(u,a));float sum=0;int n=0;
    for(int i=1;i<=14;i++){boolean up=i<=6;float t=up?i/6.0f:(i-6)/8.0f;PVector axis=up?PVector.add(j0,PVector.mult(u,a*t)):PVector.add(m,PVector.mult(lo,b*t));float r=up?ru:rl;
      float mg=axis.mag();if(mg<1e-4f)continue;PVector front=PVector.sub(axis,PVector.mult(axis,r/mg));PVector uv=calRef.projectDepth(front);if(uv==null)continue;
      int gx=round((uv.x-maskRef.step*.5f)/maskRef.step),gy=round((uv.y-maskRef.step*.5f)/maskRef.step);n++;
      if(gx<0||gy<0||gx>=maskRef.gridW||gy>=maskRef.gridH){n--;continue;} // outside the sensor's view: unknown, not free space
      int ci=gy*maskRef.gridW+gx;PVector q=cellPts[ci];
      if(q==null){int mm=maskRef.mm[ci];if(mm<=0)continue; sum-=1;continue;} // outside the person: free space
      float dz=q.z-front.z;if(abs(dz)<.045f)sum+=1;else if(dz>.07f)sum-=1;}
    return n==0?0:sum/n;
  }
  // ---------------------------------------------------------------- generative limb optimiser
  // Energy of a limb pair = robust distance of the observed points that the torso and
  // head do not explain to the nearest limb capsule surface, plus free-space violations
  // (model surface where the sensor sees through). Both limbs of a pair compete for
  // the same points, which resolves crossed arms and hand-over-hand configurations.
  ArrayList<PVector> pairPts=new ArrayList<PVector>();float[] otherDist=new float[0];
  float robustTrunc=.08f;
  void collectPairPoints(boolean arms){
    pairPts.clear();PVector hd=head();float reach=model.armReach()+.10f;PVector ls=shoulder(true),rs=shoulder(false);
    for(PVector p:pts){PVector lp=local(p);
      float tx=max(0,abs(lp.x)-model.torsoHalfWidth),ty=max(0,max(-.03f*model.height-lp.y,lp.y-model.torsoLen)),tz=max(0,abs(lp.z)-model.torsoHalfDepth);
      float dT=sqrt(tx*tx+ty*ty+tz*tz),dH=PVector.dist(p,hd)-model.headR;
      if(min(dT,dH)<.025f)continue;
      if(arms){
        // pelvis/thigh surface below the torso box is not arm evidence (hands hanging
        // at the sides are further out laterally and are kept)
        if(lp.y<.02f*model.height&&abs(lp.x)<model.hipHalf+model.thighR+.03f&&lp.z<model.torsoHalfDepth*1.8f)continue;
        if(lp.y<-.10f*model.height&&lp.z<model.torsoHalfDepth*2&&abs(lp.x)<model.hipHalf+model.thighR+.03f)continue;
        if(PVector.dist(p,ls)>reach&&PVector.dist(p,rs)>reach)continue;}
      else{if(lp.y>-.02f*model.height)continue;}
      pairPts.add(p);}
    if(pairPts.size()>cfg.articulatedPairMaxPoints){ArrayList<PVector> sub=new ArrayList<PVector>();float step=pairPts.size()/(float)cfg.articulatedPairMaxPoints;for(float i=0;i<pairPts.size();i+=step)sub.add(pairPts.get((int)i));pairPts=sub;}
  }
  float limbSurfaceDist(ArticulatedLimb l,PVector j0,PVector u,PVector lo,PVector p){
    float a=l.arm?model.upperArm:model.thigh,b=l.arm?model.forearm+model.handLen:model.shin;PVector m=PVector.add(j0,PVector.mult(u,a)),e=PVector.add(m,PVector.mult(lo,b));
    float d=min(segDist(p,j0,m)-(l.arm?model.upperArmR:model.thighR),segDist(p,m,e)-(l.arm?model.forearmR:model.shinR));
    if(!l.arm)d=min(d,segDist(p,e,PVector.add(e,PVector.mult(footDirection(),model.footLen)))-model.footR);
    return max(0,d);
  }
  float limbEnergy(ArticulatedLimb l,PVector j0,PVector u,PVector lo){
    double e=0;int n=pairPts.size();
    for(int i=0;i<n;i++){float d=min(otherDist[i],limbSurfaceDist(l,j0,u,lo,pairPts.get(i)));d=min(d,robustTrunc);e+=d*d;}
    float fs=freeSpaceViolations(l,j0,u,lo);
    return (float)(e/max(1,n))/(robustTrunc*robustTrunc)+cfg.articulatedFreeSpaceWeight*fs;
  }
  // Fraction of the limb's camera-facing surface samples through which the sensor
  // sees something farther away (or no person at all): the limb cannot be there.
  // Samples hidden behind nearer surfaces are unknown and cost nothing.
  float freeSpaceViolations(ArticulatedLimb l,PVector j0,PVector u,PVector lo){
    if(maskRef==null||calRef==null)return 0;float a=l.arm?model.upperArm:model.thigh,b=l.arm?model.forearm+model.handLen:model.shin,ru=l.arm?model.upperArmR:model.thighR,rl=l.arm?model.forearmR:model.shinR;
    PVector m=PVector.add(j0,PVector.mult(u,a));int bad=0,n=0;
    for(int i=1;i<=14;i++){boolean up=i<=6;float t=up?i/6.0f:(i-6)/8.0f;PVector axis=up?PVector.add(j0,PVector.mult(u,a*t)):PVector.add(m,PVector.mult(lo,b*t));float r=up?ru:rl;
      float mg=axis.mag();if(mg<1e-4f)continue;PVector front=PVector.sub(axis,PVector.mult(axis,r/mg));PVector uv=calRef.projectDepth(front);if(uv==null)continue;
      int gx=round((uv.x-maskRef.step*.5f)/maskRef.step),gy=round((uv.y-maskRef.step*.5f)/maskRef.step);
      if(gx<0||gy<0||gx>=maskRef.gridW||gy>=maskRef.gridH)continue;n++;
      int ci=gy*maskRef.gridW+gx;PVector q=cellPts[ci];
      if(q==null){if(maskRef.mm[ci]>0)bad++;continue;}
      if(q.z-front.z>.07f)bad++;}
    return n==0?0:bad/(float)n;
  }
  void optimizePair(ArticulatedLimb A,ArticulatedLimb B){
    collectPairPoints(A.arm);if(pairPts.size()<cfg.articulatedMinLimbPoints){return;}
    if(otherDist.length<pairPts.size())otherDist=new float[pairPts.size()*2];
    for(int round=0;round<2;round++)for(ArticulatedLimb l:new ArticulatedLimb[]{A,B}){
      ArticulatedLimb o=l==A?B:A;PVector oj=o.arm?shoulder(o.left):hip(o.left);
      for(int i=0;i<pairPts.size();i++)otherDist[i]=limbSurfaceDist(o,oj,o.upper,o.lower,pairPts.get(i));
      optimizeLimb(l,round==0);}
  }
  void optimizeLimb(ArticulatedLimb l,boolean withSeeds){
    PVector j0=l.arm?shoulder(l.left):hip(l.left);float a=l.arm?model.upperArm:model.thigh,b=l.arm?model.forearm+model.handLen:model.shin;
    PVector bu=l.upper.copy(),bl=l.lower.copy();float best=limbEnergy(l,j0,bu,bl);
    if(withSeeds){
      ArrayList<PVector[]> seeds=new ArrayList<PVector[]>();
      // constant-velocity-free rest poses (recovery) and every compatible extremum
      ArticulatedLimb tmp=new ArticulatedLimb(l.left,l.arm);
      setRestPose(tmp);seeds.add(new PVector[]{tmp.upper.copy(),tmp.lower.copy()});
      for(AgexExtremum e:extrema){if(e==headX)continue;PVector tip=extremumTip(l,e.point);float dist=PVector.dist(tip,j0);
        if(dist>(a+b)*1.15f||dist<(l.arm?.12f:.35f))continue;if(!l.arm&&local(e.point).y>-model.legLen()*.45f)continue;
        solveTwoBone(tmp,j0,tip,a,b);seeds.add(new PVector[]{tmp.upper.copy(),tmp.lower.copy()});
        // straight limb through the extremum (also covers a limb truncated by the image border)
        {PVector st=PVector.sub(tip,j0);if(st.mag()>.05f){st.normalize();seeds.add(new PVector[]{st.copy(),st.copy()});}}
        PVector hint=l.arm?elbowHint[l.left?0:1]:null;
        if(hint!=null){PVector d=PVector.sub(hint,j0);d.normalize();PVector m=PVector.add(j0,PVector.mult(d,a));PVector d2=PVector.sub(tip,m);if(d2.mag()>.02f){d2.normalize();seeds.add(new PVector[]{d,d2});}}
        // alternative elbow bend (the IK bend plane is ambiguous)
        PVector to=PVector.sub(tip,j0);to.normalize();for(int k=0;k<3;k++){PVector side=k==0?axFwd:(k==1?axLeft:PVector.mult(axLeft,-1));PVector bend=PVector.sub(side,PVector.mult(to,side.dot(to)));if(bend.mag()<.1f)continue;bend.normalize();
          float dd=min(dist,a+b-.001f),ang=acos(constrain((a*a+dd*dd-b*b)/(2*a*dd),-1,1));PVector u=PVector.add(PVector.mult(to,cos(ang)),PVector.mult(bend,sin(ang)));u.normalize();
          PVector m=PVector.add(j0,PVector.mult(u,a));PVector lo=PVector.sub(PVector.add(j0,PVector.mult(to,dd)),m);if(lo.mag()<.01f)continue;lo.normalize();seeds.add(new PVector[]{u,lo});}}
      for(PVector[] sd:seeds){float e=limbEnergy(l,j0,sd[0],sd[1]);if(e<best-cfg.articulatedReseedMargin*.05f){best=e;bu=sd[0].copy();bl=sd[1].copy();}}
    }
    // coordinate descent on the 4 swing angles, coarse to fine
    // coarse steps only on the first round (re-seeding), then refinement
    float[] steps=withSeeds?new float[]{.35f,.17f,.08f,.04f}:new float[]{.08f,.04f};
    for(float st:steps){boolean improved=true;int guard=0;while(improved&&guard++<2){improved=false;
        for(int k=0;k<8;k++){PVector u=bu.copy(),lo=bl.copy();PVector ax=k%4<2?perp(bu,false):perp(bu,true);float sg=(k&1)==0?st:-st;
          if(k<4){u=rotateAbout(bu,ax,sg);lo=rotateAbout(bl,ax,sg);} // swing the whole limb from the proximal joint
          else{PVector ax2=k%4<2?perp(bl,false):perp(bl,true);lo=rotateAbout(bl,ax2,sg);} // bend the distal segment
          float e=limbEnergy(l,j0,u,lo);if(e<best-1e-4f){best=e;bu=u;bl=lo;improved=true;}}}}
    l.upper.set(bu);l.lower.set(bl);applyJointLimits(l);
  }
  PVector limitTurn(PVector from,PVector to,float maxRad){PVector t=to.copy();t.normalize();float c=constrain(from.dot(t),-1,1),ang=acos(c);if(ang<=maxRad)return t;
    PVector ax=from.cross(t);if(ax.mag()<1e-5f)return from.copy();ax.normalize();return rotateAbout(from,ax,maxRad);}
  PVector perp(PVector v,boolean second){PVector ref=abs(v.dot(axFwd))<.9f?axFwd:axUp;PVector p1=v.cross(ref);p1.normalize();if(!second)return p1;PVector p2=v.cross(p1);p2.normalize();return p2;}
  PVector rotateAbout(PVector v,PVector axis,float ang){float c=cos(ang),sn=sin(ang);PVector r=PVector.add(PVector.add(PVector.mult(v,c),PVector.mult(axis.cross(v),sn)),PVector.mult(axis,axis.dot(v)*(1-c)));r.normalize();return r;}

  // Joint-centre target implied by a limb-end extremum: a hand extremum is the palm/
  // fingers surface; a foot extremum is the toe, so the ankle lies one foot length
  // back (along the body's forward axis) and above the sole.
  PVector footDirection(){PVector f=PVector.sub(axFwd,PVector.mult(axUp,.35f));f.normalize();return f;}
  PVector extremumTip(ArticulatedLimb l,PVector p){
    // A hand extremum is the fingertip surface: the hand joint (palm centre) lies
    // (fingertip length - hand joint length) back toward the shoulder.
    if(l.arm){PVector t=pushBack(p,model.handR*.6f);PVector d=PVector.sub(t,shoulder(l.left));float m=d.mag();if(m>.05f)t.sub(PVector.mult(d,(model.handTip-model.handLen)/m));return t;}
    PVector t=pushBack(p,model.shinR*.6f);t.sub(PVector.mult(axFwd,model.footLen*.75f));t.add(PVector.mult(axUp,model.ankleHeight*.5f));return t;}
  void solveTwoBone(ArticulatedLimb l,PVector j0,PVector tip,float a,float b){
    PVector to=PVector.sub(tip,j0);float d=constrain(to.mag(),.02f,a+b-.001f);to.normalize();
    float cosA=constrain((a*a+d*d-b*b)/(2*a*d),-1,1),ang=acos(cosA);
    // bend direction: arms bend down/back, legs bend forward (knee toward camera)
    PVector bend=l.arm?PVector.mult(axUp,-1):axFwd.copy();bend=PVector.sub(bend,PVector.mult(to,bend.dot(to)));if(bend.mag()<1e-3f)bend=PVector.sub(axFwd,PVector.mult(to,axFwd.dot(to)));bend.normalize();
    PVector u=PVector.add(PVector.mult(to,cos(ang)),PVector.mult(bend,sin(ang)));u.normalize();PVector m=PVector.add(j0,PVector.mult(u,a));PVector lo=PVector.sub(PVector.add(j0,PVector.mult(to,d)),m);lo.normalize();
    l.upper.set(u);l.lower.set(lo);
  }
  void fitLimb(ArticulatedLimb l,PVector j0,ArrayList<PVector> upperPts,ArrayList<PVector> lowerPts,boolean last){
    float a=l.arm?model.upperArm:model.thigh,ru=l.arm?model.upperArmR:model.thighR,rl=l.arm?model.forearmR:model.shinR;
    int minPts=cfg.articulatedMinLimbPoints;
    AgexExtremum ex=l.arm?handX[l.left?0:1]:footX[l.left?0:1];
    if(ex!=null&&cfg.articulatedGenerative){PVector tipNow=PVector.add(PVector.add(j0,PVector.mult(l.upper,a)),PVector.mult(l.lower,l.arm?model.forearm+model.handLen:model.shin));
      if(PVector.dist(tipNow,extremumTip(l,ex.point))>.15f)ex=null;} // a label that disagrees with the verified limb is not used
    if(upperPts.size()>=minPts){PVector d=new PVector();float wsum=0;for(PVector p:upperPts){PVector q=PVector.sub(pushBack(p,ru),j0);float m=q.mag();if(m<.02f||q.dot(l.upper)<a*.25f)continue;float w=min(1,m/a);d.add(PVector.mult(q,w/m));wsum+=w;}
      if(wsum>0){d.normalize();l.upper.set(limitTurn(l.upper,PVector.lerp(l.upper,d,.75f),cfg.articulatedRefineMaxTurnRad));}}
    PVector mid=PVector.add(j0,PVector.mult(l.upper,a));
    PVector d=new PVector();float wsum=0;
    for(PVector p:lowerPts){PVector q=PVector.sub(pushBack(p,rl),mid);float m=q.mag();if(m<.03f||q.dot(l.lower)<max(m*.2f,.04f))continue;float w=min(1,m/(l.arm?model.forearm:model.shin));d.add(PVector.mult(q,w/m));wsum+=w;}
    if(ex!=null){PVector q=PVector.sub(extremumTip(l,ex.point),mid);float m=q.mag();if(m>.03f){float w=cfg.articulatedExtremumWeight*max(1,lowerPts.size()*.05f);d.add(PVector.mult(q,w/m));wsum+=w;}}
    if(wsum>0&&lowerPts.size()+(ex!=null?minPts:0)>=minPts){d.normalize();l.lower.set(limitTurn(l.lower,PVector.lerp(l.lower,d,.8f),cfg.articulatedRefineMaxTurnRad));}
    applyJointLimits(l);
    if(last){l.support=upperPts.size()+lowerPts.size()+(ex!=null?minPts:0);
      if(l.support>=minPts){l.lostFrames=0;l.upperQ=constrain(upperPts.size()/(float)(minPts*3),.25f,1);l.lowerQ=constrain((lowerPts.size()+(ex!=null?minPts*2:0))/(float)(minPts*3),.25f,1);}
      else{l.lostFrames++;l.upperQ*=.85f;l.lowerQ*=.85f;}}
  }
  void applyJointLimits(ArticulatedLimb l){
    // The lower segment cannot fold back onto the upper one (elbow/knee <= ~165 deg flexion).
    float c=l.upper.dot(l.lower);if(c<-.96f){PVector bend=PVector.sub(l.lower,PVector.mult(l.upper,c));if(bend.mag()<1e-3f)bend=l.arm?PVector.mult(axUp,-1):axFwd.copy();bend.normalize();
      l.lower=PVector.add(PVector.mult(l.upper,-.96f),PVector.mult(bend,sqrt(1-.96f*.96f)));l.lower.normalize();}
    // Knees do not hyper-extend backwards noticeably: keep the shin from pointing behind the thigh plane.
    // Knees flex only one way: (thigh x shin) must not point to the body's right
    // (hyper-extension). Rotate the shin back about the lateral axis when it does.
    if(!l.arm){float v=l.upper.cross(l.lower).dot(axLeft),lim=-.12f;
      if(v<lim){float ang=asin(constrain(lim-v,0,1));PVector a1=rotateAbout(l.lower,axLeft,ang),a2=rotateAbout(l.lower,axLeft,-ang);
        l.lower=l.upper.cross(a1).dot(axLeft)>l.upper.cross(a2).dot(axLeft)?a1:a2;}}
  }
  void fitHead(){
    PVector guess=head();PVector sum=new PVector();int n=0;
    for(PVector p:pts){if(PVector.dist(p,guess)>model.headR*1.9f)continue;PVector l=local(p);if(l.y<model.torsoLen+model.neckToHead*.35f)continue;sum.add(pushBack(p,model.headR*.85f));n++;}
    if(headX!=null){sum.add(PVector.mult(pushBack(headX.point,model.headR*.85f),3));n+=3;}
    if(n>=6){PVector c=PVector.div(sum,n);PVector loc=local(c);
      // head top extremum sits ~one head radius above the centre
      if(headX!=null)loc.y=min(loc.y,local(headX.point).y-model.headR*.9f);
      loc.y=constrain(loc.y,model.torsoLen+model.neckToHead*.6f,model.torsoLen+model.neckToHead*1.35f);loc.x=constrain(loc.x,-model.shoulderHalf*.6f,model.shoulderHalf*.6f);
      headOffset=headOffset==null?loc:PVector.lerp(headOffset,loc,.5f);}
  }
  void enforceFloor(SkeletonFloorModel floor){
    if(floor==null||!floor.valid)return;
    for(ArticulatedLimb l:new ArticulatedLimb[]{leftLeg,rightLeg}){PVector h=hip(l.left),k=PVector.add(h,PVector.mult(l.upper,model.thigh)),a=PVector.add(k,PVector.mult(l.lower,model.shin));
      float ah=floor.height(a);if(ah<model.ankleHeight*.6f){PVector target=PVector.add(a,PVector.mult(new PVector(floor.nx,floor.ny,floor.nz),model.ankleHeight*.6f-ah));solveTwoBone(l,h,target,model.thigh,model.shin);}}
  }
  // Slowly refine stature while the user stands upright with visible feet.
  void learnModel(SkeletonFloorModel floor){
    if(floor==null||!floor.valid||model.samples>400)return;
    float bottom=measureBottom(floor);
    boolean upright=bottom<.10f&&axUp.dot(new PVector(floor.nx,floor.ny,floor.nz))>.96f&&headX!=null;if(!upright)return;
    float h=measureTop(floor,head(),model.headR*1.6f);if(h<1.2f||h>2.15f||abs(h-model.height)>.15f)return;
    float nh=lerp(model.height,h,model.samples<30?.15f:.04f);model.samples++;if(abs(nh-model.height)>.002f){model.fromHeight(nh);}
  }

  // ---------------------------------------------------------------- publication
  SkeletonPose3D publish(SkeletonCalibration3D cal,long tick){
    SkeletonPose3D s=new SkeletonPose3D();
    float torsoQ=constrain(lastTorsoOverlap<=0?.85f:(.35f+.65f*constrain(lastTorsoOverlap/.6f,0,1)),.2f,1);
    set(s.hipCenter,hipCenter(),torsoQ,cal,tick);set(s.spine,spine(),torsoQ,cal,tick);set(s.shoulderCenter,shoulderCenter(),torsoQ,cal,tick);
    set(s.head,head(),headX!=null?.95f:.7f*torsoQ,cal,tick);
    set(s.leftShoulder,shoulder(true),torsoQ,cal,tick);set(s.rightShoulder,shoulder(false),torsoQ,cal,tick);
    set(s.leftHip,hip(true),torsoQ,cal,tick);set(s.rightHip,hip(false),torsoQ,cal,tick);
    publishArm(s,leftArm,s.leftElbow,s.leftWrist,s.leftHand,cal,tick);publishArm(s,rightArm,s.rightElbow,s.rightWrist,s.rightHand,cal,tick);
    publishLeg(s,leftLeg,s.leftKnee,s.leftAnkle,s.leftFoot,cal,tick);publishLeg(s,rightLeg,s.rightKnee,s.rightAnkle,s.rightFoot,cal,tick);
    s.poseSource="articulated";return s;
  }
  void publishArm(SkeletonPose3D s,ArticulatedLimb l,SkeletonJoint3D el,SkeletonJoint3D wr,SkeletonJoint3D ha,SkeletonCalibration3D cal,long tick){
    PVector sh=shoulder(l.left),e=PVector.add(sh,PVector.mult(l.upper,model.upperArm)),w=PVector.add(e,PVector.mult(l.lower,model.forearm)),h=PVector.add(w,PVector.mult(l.lower,model.handLen));
    int state=l.lostFrames==0?SkeletonJoint3D.TRACKED:(l.lostFrames<cfg.poseOcclusionHoldFrames?SkeletonJoint3D.INFERRED:SkeletonJoint3D.OCCLUDED);
    set(el,e,l.upperQ,cal,tick,state);set(wr,w,l.lowerQ,cal,tick,state);set(ha,h,l.lowerQ,cal,tick,state);
  }
  void publishLeg(SkeletonPose3D s,ArticulatedLimb l,SkeletonJoint3D kn,SkeletonJoint3D an,SkeletonJoint3D fo,SkeletonCalibration3D cal,long tick){
    PVector hp=hip(l.left),k=PVector.add(hp,PVector.mult(l.upper,model.thigh)),a=PVector.add(k,PVector.mult(l.lower,model.shin));
    PVector footDir=PVector.sub(axFwd,PVector.mult(axUp,.35f));footDir.normalize();PVector f=PVector.add(a,PVector.mult(footDir,model.footLen*.9f));
    int state=l.lostFrames==0?SkeletonJoint3D.TRACKED:(l.lostFrames<cfg.poseOcclusionHoldFrames?SkeletonJoint3D.INFERRED:SkeletonJoint3D.OCCLUDED);
    set(kn,k,l.upperQ,cal,tick,state);set(an,a,l.lowerQ,cal,tick,state);set(fo,f,l.lowerQ*.9f,cal,tick,state);
  }
  void set(SkeletonJoint3D j,PVector p,float q,SkeletonCalibration3D cal,long tick){set(j,p,q,cal,tick,SkeletonJoint3D.TRACKED);}
  void set(SkeletonJoint3D j,PVector p,float q,SkeletonCalibration3D cal,long tick,int state){
    if(p==null||p.z<=.05f)return;PVector uv=cal.projectDepth(p);j.set(uv==null?new PVector():uv,p,constrain(q,.05f,1),state,"articulated",tick);
  }
}

// One-Euro filter per published joint (Casiez et al.): low jitter at rest, low
// lag during fast motion. Cheaper and less laggy than stacked Kalman/consensus.
class ArticulatedJointFilter {
  final SkeletonConfig cfg;final HashMap<String,float[]> state=new HashMap<String,float[]>();
  ArticulatedJointFilter(SkeletonConfig c){cfg=c;}
  void reset(){state.clear();}
  void apply(SkeletonJoint3D j,long tick,boolean distal){
    if(j==null||!j.tracked())return;float[] s=state.get(j.name);
    if(s==null||tick-(long)s[7]>250){state.put(j.name,new float[]{j.world.x,j.world.y,j.world.z,0,0,0,0,tick});return;}
    float dt=max(.004f,(tick-s[7])/1000.0f);float minCut=distal?cfg.articulatedFilterMinCutoff*1.6f:cfg.articulatedFilterMinCutoff,beta=distal?cfg.articulatedFilterBeta*1.4f:cfg.articulatedFilterBeta;
    float[] x={j.world.x,j.world.y,j.world.z};float speed=0;
    for(int k=0;k<3;k++){float dx=(x[k]-s[k])/dt;float ad=alpha(dt,cfg.articulatedFilterDerivativeCutoff);s[3+k]=s[3+k]+ad*(dx-s[3+k]);speed+=s[3+k]*s[3+k];}
    speed=sqrt(speed);float cutoff=minCut+beta*speed,a=alpha(dt,cutoff);
    for(int k=0;k<3;k++)s[k]=s[k]+a*(x[k]-s[k]);s[7]=tick;j.world.set(s[0],s[1],s[2]);
  }
  float alpha(float dt,float cutoff){float tau=1.0f/(TWO_PI*max(.01f,cutoff));return 1.0f/(1.0f+tau/dt);}
}
