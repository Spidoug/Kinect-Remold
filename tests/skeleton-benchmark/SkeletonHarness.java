import processing.core.*;
import java.util.*;

/**
 * Ground-truth benchmark for SynSkeleton (20-joint Kinect v1 topology).
 *
 * An articulated 1.75 m human (capsules/rounded boxes driven by forward
 * kinematics) performs a continuous sequence of difficult poses in front of a
 * synthetic Kinect Xbox 360 (disparity noise + quantisation, projector shadows,
 * grazing-angle/edge dropouts). Every frame goes through the unmodified
 * SkeletonProcessingSession and each published joint is compared with the
 * exact joint position.
 *
 * Usage: java SkeletonHarness [distanceM=2.6] [seed=3]
 */
public class SkeletonHarness {
  // ------------------------------------------------------------ vector helpers
  static double[] v(double x,double y,double z){return new double[]{x,y,z};}
  static double[] add(double[] a,double[] b){return v(a[0]+b[0],a[1]+b[1],a[2]+b[2]);}
  static double[] sub(double[] a,double[] b){return v(a[0]-b[0],a[1]-b[1],a[2]-b[2]);}
  static double[] mul(double[] a,double s){return v(a[0]*s,a[1]*s,a[2]*s);}
  static double dot(double[] a,double[] b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}
  static double len(double[] a){return Math.sqrt(dot(a,a));}
  static double[] norm(double[] a){double l=len(a);return l<1e-12?v(0,1,0):mul(a,1/l);}
  static double[] lerp(double[] a,double[] b,double t){return v(a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t);}
  /** Unit direction in the person frame: x = person's LEFT, y = up, z = forward (toward the camera). */
  static double[] dir(double x,double y,double z){return norm(v(x,y,z));}

  // ------------------------------------------------------------ body model
  static final String[] JN={"hipCenter","spine","shoulderCenter","head","leftShoulder","leftElbow","leftWrist","leftHand","rightShoulder","rightElbow","rightWrist","rightHand",
    "leftHip","leftKnee","leftAnkle","leftFoot","rightHip","rightKnee","rightAnkle","rightFoot"};
  static final int HIPC=0,SPINE=1,SHC=2,HEAD=3,LSH=4,LEL=5,LWR=6,LHA=7,RSH=8,REL=9,RWR=10,RHA=11,LHIP=12,LKN=13,LAN=14,LFO=15,RHIP=16,RKN=17,RAN=18,RFO=19;

  /** Limb directions for one instant (person frame). */
  static class Pose {
    double[] lUpper=dir(0.15,-1,0),lFore=dir(0.08,-1,0.05),rUpper=dir(-0.15,-1,0),rFore=dir(-0.08,-1,0.05);
    double[] lThigh=dir(0.02,-1,0),lShin=dir(0,-1,0),rThigh=dir(-0.02,-1,0),rShin=dir(0,-1,0);
    double yaw=0,rootDy=0,rootX=0,rootZ=0,lean=0;
    Pose copy(){Pose p=new Pose();p.lUpper=lUpper;p.lFore=lFore;p.rUpper=rUpper;p.rFore=rFore;p.lThigh=lThigh;p.lShin=lShin;p.rThigh=rThigh;p.rShin=rShin;p.yaw=yaw;p.rootDy=rootDy;p.rootX=rootX;p.rootZ=rootZ;p.lean=lean;return p;}
    static Pose blend(Pose a,Pose b,double t){Pose p=new Pose();
      p.lUpper=norm(lerp(a.lUpper,b.lUpper,t));p.lFore=norm(lerp(a.lFore,b.lFore,t));p.rUpper=norm(lerp(a.rUpper,b.rUpper,t));p.rFore=norm(lerp(a.rFore,b.rFore,t));
      p.lThigh=norm(lerp(a.lThigh,b.lThigh,t));p.lShin=norm(lerp(a.lShin,b.lShin,t));p.rThigh=norm(lerp(a.rThigh,b.rThigh,t));p.rShin=norm(lerp(a.rShin,b.rShin,t));
      p.yaw=a.yaw+(b.yaw-a.yaw)*t;p.rootDy=a.rootDy+(b.rootDy-a.rootDy)*t;p.rootX=a.rootX+(b.rootX-a.rootX)*t;p.rootZ=a.rootZ+(b.rootZ-a.rootZ)*t;p.lean=a.lean+(b.lean-a.lean)*t;return p;}
  }

  /** Forward kinematics -> 20 joints + hand tips, in scene coordinates (Y up, person at origin facing +z). */
  static double[][] joints(Pose p,double[] rootPos){
    double[][] j=new double[22][];
    double c=Math.cos(p.yaw),s=Math.sin(p.yaw);
    // person frame -> scene: rotate about Y by yaw (x=left,z=forward)
    java.util.function.Function<double[],double[]> R=(d)->v(c*d[0]+s*d[2],d[1],-s*d[0]+c*d[2]);
    double[] up=R.apply(dir(0,1,-p.lean*0.0+0)); // torso axis (lean handled by tilt below)
    double[] torsoUp=R.apply(dir(0,1,p.lean));
    double[] hipC=add(rootPos,v(0,0.95+p.rootDy,0));
    j[HIPC]=hipC;
    j[SPINE]=add(hipC,mul(torsoUp,0.21));
    j[SHC]=add(hipC,mul(torsoUp,0.49));
    j[HEAD]=add(j[SHC],mul(torsoUp,0.19));
    double[] left=R.apply(v(1,0,0));
    j[LSH]=add(add(j[SHC],mul(left,0.185)),mul(torsoUp,-0.025));
    j[RSH]=add(add(j[SHC],mul(left,-0.185)),mul(torsoUp,-0.025));
    j[LEL]=add(j[LSH],mul(R.apply(p.lUpper),0.29));j[LWR]=add(j[LEL],mul(R.apply(p.lFore),0.255));j[LHA]=add(j[LWR],mul(R.apply(p.lFore),0.075));
    j[REL]=add(j[RSH],mul(R.apply(p.rUpper),0.29));j[RWR]=add(j[REL],mul(R.apply(p.rFore),0.255));j[RHA]=add(j[RWR],mul(R.apply(p.rFore),0.075));
    j[LHIP]=add(hipC,mul(left,0.095));j[RHIP]=add(hipC,mul(left,-0.095));
    j[LKN]=add(j[LHIP],mul(R.apply(p.lThigh),0.44));j[LAN]=add(j[LKN],mul(R.apply(p.lShin),0.42));
    j[RKN]=add(j[RHIP],mul(R.apply(p.rThigh),0.44));j[RAN]=add(j[RKN],mul(R.apply(p.rShin),0.42));
    double[] fwd=R.apply(v(0,0,1));
    j[LFO]=add(add(j[LAN],mul(fwd,0.11)),v(0,-0.045,0));j[RFO]=add(add(j[RAN],mul(fwd,0.11)),v(0,-0.045,0));
    j[20]=add(j[LWR],mul(R.apply(p.lFore),0.18));j[21]=add(j[RWR],mul(R.apply(p.rFore),0.18)); // hand tips
    return j;
  }

  static double sdCapsule(double[] q,double[] a,double[] b,double r){double[] pa=sub(q,a),ba=sub(b,a);double h=Math.max(0,Math.min(1,dot(pa,ba)/dot(ba,ba)));return len(sub(pa,mul(ba,h)))-r;}
  static double sdSphere(double[] q,double[] c,double r){return len(sub(q,c))-r;}
  static double sdOrientedBox(double[] q,double[] c,double[] ax,double[] ay,double[] az,double hx,double hy,double hz,double r){
    double[] d=sub(q,c);double x=Math.abs(dot(d,ax))-(hx-r),y=Math.abs(dot(d,ay))-(hy-r),z=Math.abs(dot(d,az))-(hz-r);
    double ox=Math.max(x,0),oy=Math.max(y,0),oz=Math.max(z,0);return Math.sqrt(ox*ox+oy*oy+oz*oz)+Math.min(Math.max(x,Math.max(y,z)),0)-r;}

  double[][] J; Pose P; double[] ax,ay,az; // current body
  double bodySdf(double[] q){
    double d=1e9;
    d=Math.min(d,sdOrientedBox(q,lerp(J[HIPC],J[SHC],0.52),ax,ay,az,0.165,0.27,0.105,0.07));   // torso
    d=Math.min(d,sdOrientedBox(q,add(J[HIPC],mul(ay,-0.02)),ax,ay,az,0.175,0.11,0.115,0.06));   // pelvis
    d=Math.min(d,sdCapsule(q,J[SHC],add(J[SHC],mul(ay,0.08)),0.055));                            // neck
    d=Math.min(d,sdSphere(q,add(J[HEAD],mul(ay,0.02)),0.105));                                   // head
    d=Math.min(d,sdCapsule(q,J[LSH],J[LEL],0.052));d=Math.min(d,sdCapsule(q,J[LEL],J[LWR],0.042));d=Math.min(d,sdCapsule(q,J[LWR],J[20],0.036));
    d=Math.min(d,sdCapsule(q,J[RSH],J[REL],0.052));d=Math.min(d,sdCapsule(q,J[REL],J[RWR],0.042));d=Math.min(d,sdCapsule(q,J[RWR],J[21],0.036));
    d=Math.min(d,sdCapsule(q,J[LHIP],J[LKN],0.074));d=Math.min(d,sdCapsule(q,J[LKN],J[LAN],0.055));d=Math.min(d,sdCapsule(q,J[LAN],add(J[LFO],mul(az,0.07)),0.042));
    d=Math.min(d,sdCapsule(q,J[RHIP],J[RKN],0.074));d=Math.min(d,sdCapsule(q,J[RKN],J[RAN],0.055));d=Math.min(d,sdCapsule(q,J[RAN],add(J[RFO],mul(az,0.07)),0.042));
    return d;
  }
  double sceneSdf(double[] q){return Math.min(bodySdf(q),Math.min(q[1],q[2]+1.3));} // floor y=0, wall z=-1.3

  void setBody(Pose p){P=p;J=joints(p,v(p.rootX,0,p.rootZ));double c=Math.cos(p.yaw),s=Math.sin(p.yaw);
    ax=v(c,0,-s);ay=norm(sub(J[SHC],J[HIPC]));az=norm(v(s*1,0,c));
    // re-orthogonalise az against ay
    az=norm(sub(az,mul(ay,dot(az,ay))));ax=norm(v(ay[1]*az[2]-ay[2]*az[1],ay[2]*az[0]-ay[0]*az[2],ay[0]*az[1]-ay[1]*az[0]));}

  // ------------------------------------------------------------ sensor
  static final int W=640,H=480;static final double BASE=0.075,IRF=580,DSIG=0.075,DQ=1.0/8.0;
  float[] RX,RY; double[] camPos; double[][] camR; // camR columns: right, down, forward (scene)
  void lookAt(double[] eye,double[] target){double[] f=norm(sub(target,eye));double[] r=norm(v(f[1]*0-f[2]*1,f[2]*0-f[0]*0,f[0]*1-f[1]*0));
    double[] d=v(f[1]*r[2]-f[2]*r[1],f[2]*r[0]-f[0]*r[2],f[0]*r[1]-f[1]*r[0]);camPos=eye;camR=new double[][]{r,d,f};}
  double[] toCam(double[] s){double[] d=sub(s,camPos);return v(dot(d,camR[0]),dot(d,camR[1]),dot(d,camR[2]));}
  double trace(double[] o,double[] d,double tmax){double t=0.05;for(int i=0;i<300&&t<tmax;i++){double h=sceneSdf(add(o,mul(d,t)));if(h<2e-5)return t;t+=h*0.97;}return -1;}
  short[] render(long seed){
    float[] z=new float[W*H];double[] proj=add(camPos,mul(camR[0],BASE));
    java.util.stream.IntStream.range(0,H).parallel().forEach(vv->{Random rr=new Random(seed*1000003L+vv);for(int u=0;u<W;u++){
      int i=vv*W+u;double rx=RX[i],ry=RY[i],rn=Math.sqrt(rx*rx+ry*ry+1);double[] dk=v(rx/rn,ry/rn,1/rn);
      double[] d=add(add(mul(camR[0],dk[0]),mul(camR[1],dk[1])),mul(camR[2],dk[2]));
      double t=trace(camPos,d,6.0);if(t<0)continue;double[] p=add(camPos,mul(d,t));
      double e=1e-4;double[] g=v(sceneSdf(add(p,v(e,0,0)))-sceneSdf(add(p,v(-e,0,0))),sceneSdf(add(p,v(0,e,0)))-sceneSdf(add(p,v(0,-e,0))),sceneSdf(add(p,v(0,0,e)))-sceneSdf(add(p,v(0,0,-e))));
      double gl=len(g);if(gl<1e-12)continue;if(Math.abs(dot(g,d)/gl)<0.10+0.08*rr.nextDouble())continue;
      double[] q=sub(p,proj);double ql=len(q);double th=trace(proj,mul(q,1/ql),ql+0.01);if(th>=0&&th<ql-0.004)continue;
      double zt=t*dk[2];if(zt<0.4||zt>4.5)continue;double disp=BASE*IRF/zt+rr.nextGaussian()*DSIG;disp=Math.round(disp/DQ)*DQ;if(disp<=1)continue;z[i]=(float)(BASE*IRF/disp);}});
    short[] out=new short[W*H];Random r=new Random(seed);
    for(int y=0;y<H;y++)for(int x=0;x<W;x++){int i=y*W+x;float c=z[i];if(c<=0)continue;boolean edge=false;
      if(x>0&&z[i-1]>0&&Math.abs(z[i-1]-c)>0.03)edge=true;if(x<W-1&&z[i+1]>0&&Math.abs(z[i+1]-c)>0.03)edge=true;
      if(y>0&&z[i-W]>0&&Math.abs(z[i-W]-c)>0.03)edge=true;if(y<H-1&&z[i+W]>0&&Math.abs(z[i+W]-c)>0.03)edge=true;
      if(edge&&r.nextDouble()<0.45)continue;if(r.nextDouble()<0.003)continue;out[i]=(short)Math.round(c*1000);}
    return out;
  }

  short[] cachedRender(double dist,long seed,double fps,int f) throws java.io.IOException{
    String rev=System.getProperty("skel.cacheRevision","bodyview2");java.io.File dir=new java.io.File(String.format(Locale.ROOT,"%s/%s_%s_d%.2f_s%d_f%.0f",System.getProperty("skel.cache","skelcache"),rev,System.getProperty("skel.scene","std"),dist,seed,fps));dir.mkdirs();
    java.io.File file=new java.io.File(dir,String.format("f%05d.bin",f));
    if(file.isFile()){try(java.io.DataInputStream in=new java.io.DataInputStream(new java.io.BufferedInputStream(new java.util.zip.GZIPInputStream(new java.io.FileInputStream(file))))){short[] d=new short[W*H];for(int i=0;i<d.length;i++)d[i]=in.readShort();return d;}}
    short[] d=render(seed*100000+f);
    try(java.io.DataOutputStream out=new java.io.DataOutputStream(new java.io.BufferedOutputStream(new java.util.zip.GZIPOutputStream(new java.io.FileOutputStream(file))))){for(short x:d)out.writeShort(x);}
    return d;
  }
  // ------------------------------------------------------------ choreography
  static Pose base(){return new Pose();}
  static class Segment{final String name;final double dur;final java.util.function.DoubleFunction<Pose> f;Segment(String n,double d,java.util.function.DoubleFunction<Pose> f){name=n;dur=d;this.f=f;}}
  static List<Segment> choreography(){
    List<Segment> L=new ArrayList<Segment>();
    L.add(new Segment("rest",3.0,t->base()));
    L.add(new Segment("tpose",3.0,t->{Pose p=base();p.lUpper=dir(1,0,0);p.lFore=dir(1,0,0);p.rUpper=dir(-1,0,0);p.rFore=dir(-1,0,0);return p;}));
    L.add(new Segment("wave",3.5,t->{Pose p=base();p.rUpper=dir(-1,0.35,0.15);double a=Math.sin(t*2*Math.PI*1.4)*0.45;p.rFore=dir(-Math.sin(a),Math.cos(a),0.1);return p;}));
    L.add(new Segment("reach",4.0,t->{Pose p=base();double k=0.5-0.5*Math.cos(t*2*Math.PI/2.0);
      p.rUpper=norm(lerp(dir(-0.15,-1,0),dir(-0.25,-0.05,1),k));p.rFore=norm(lerp(dir(-0.08,-1,0.05),dir(-0.05,0.05,1),k));
      double k2=0.5-0.5*Math.cos((t+1.0)*2*Math.PI/2.0);p.lUpper=norm(lerp(dir(0.15,-1,0),dir(0.25,-0.05,1),k2*0.8));p.lFore=norm(lerp(dir(0.08,-1,0.05),dir(0.05,0.05,1),k2*0.8));return p;}));
    L.add(new Segment("type",4.0,t->{Pose p=base();
      p.lUpper=dir(0.12,-0.75,0.65);p.rUpper=dir(-0.12,-0.75,0.65);
      double a=0.18*Math.sin(t*2*Math.PI*1.1),b=0.18*Math.sin(t*2*Math.PI*0.8+1.3);
      p.lFore=dir(-0.25+a,0.05+0.1*Math.cos(t*5),1);p.rFore=dir(0.25+b,0.05+0.1*Math.sin(t*4),1);return p;}));
    L.add(new Segment("cross",3.0,t->{Pose p=base();p.lUpper=dir(0.25,-0.7,0.7);p.lFore=dir(-1,0.35,0.12);p.rUpper=dir(-0.25,-0.7,0.7);p.rFore=dir(1,0.25,0.22);return p;}));
    L.add(new Segment("kneeUp",4.0,t->{Pose p=base();double ph=t*2*Math.PI*0.75;double l=Math.max(0,Math.sin(ph)),r=Math.max(0,-Math.sin(ph));
      p.lThigh=norm(lerp(dir(0.02,-1,0),dir(0.02,-0.1,1),l));p.lShin=norm(lerp(dir(0,-1,0),dir(0,-1,-0.1),l));
      p.rThigh=norm(lerp(dir(-0.02,-1,0),dir(-0.02,-0.1,1),r));p.rShin=norm(lerp(dir(0,-1,0),dir(0,-1,-0.1),r));
      p.lUpper=dir(0.15,-1,-0.3*l+0.3*r);p.rUpper=dir(-0.15,-1,0.3*l-0.3*r);return p;}));
    L.add(new Segment("turn",4.0,t->{Pose p=base();p.yaw=Math.toRadians(40)*Math.sin(t*2*Math.PI/4.0);
      p.lUpper=dir(0.7,-0.5,0.3);p.lFore=dir(0.3,0.1,1);p.rUpper=dir(-0.7,-0.5,0.3);p.rFore=dir(-0.3,0.1,1);return p;}));
    // Body3D viewport/tracking regression: the person walks across the native FOV
    // and toward/away from the sensor.  The historical benchmark kept the root at
    // x=z=0 and therefore could not catch stale-centre or off-panel failures.
    L.add(new Segment("sideSweep",6.0,t->{Pose p=base();p.rootX=.70*Math.sin(t*2*Math.PI/6.0);p.yaw=Math.toRadians(8)*Math.sin(t*2*Math.PI/3.0);return p;}));
    L.add(new Segment("depthSweep",5.0,t->{Pose p=base();p.rootZ=.52*Math.sin(t*2*Math.PI/5.0);p.lUpper=dir(.35,-.9,.18);p.rUpper=dir(-.35,-.9,.18);return p;}));
    L.add(new Segment("overhead",3.0,t->{Pose p=base();p.lUpper=dir(0.35,1,0.05);p.lFore=dir(0.1,1,0);p.rUpper=dir(-0.35,1,0.05);p.rFore=dir(-0.1,1,0);return p;}));
    L.add(new Segment("rest2",2.5,t->base()));
    return L;
  }
  static Pose poseAt(List<Segment> L,double t){
    double acc=0;for(int i=0;i<L.size();i++){Segment s=L.get(i);if(t<acc+s.dur||i==L.size()-1){double lt=t-acc;Pose p=s.f.apply(lt);
        // 0.6 s blend from the previous segment's final pose
        if(i>0&&lt<0.6){Segment prev=L.get(i-1);Pose q=prev.f.apply(prev.dur);double k=lt/0.6;k=k*k*(3-2*k);p=Pose.blend(q,p,k);}return p;}acc+=s.dur;}
    return base();
  }
  static String segmentAt(List<Segment> L,double t){double acc=0;for(Segment s:L){if(t<acc+s.dur)return s.name;acc+=s.dur;}return L.get(L.size()-1).name;}
  static double transitionAt(List<Segment> L,double t){double acc=0;for(Segment s:L){if(t<acc+s.dur)return t-acc;acc+=s.dur;}return 99;}

  // ------------------------------------------------------------ evaluation
  static PVector jointOf(SynKinectStudio.SkeletonPose3D s,int k){
    SynKinectStudio.SkeletonJoint3D j=null;
    switch(k){case HIPC:j=s.hipCenter;break;case SPINE:j=s.spine;break;case SHC:j=s.shoulderCenter;break;case HEAD:j=s.head;break;
      case LSH:j=s.leftShoulder;break;case LEL:j=s.leftElbow;break;case LWR:j=s.leftWrist;break;case LHA:j=s.leftHand;break;
      case RSH:j=s.rightShoulder;break;case REL:j=s.rightElbow;break;case RWR:j=s.rightWrist;break;case RHA:j=s.rightHand;break;
      case LHIP:j=s.leftHip;break;case LKN:j=s.leftKnee;break;case LAN:j=s.leftAnkle;break;case LFO:j=s.leftFoot;break;
      case RHIP:j=s.rightHip;break;case RKN:j=s.rightKnee;break;case RAN:j=s.rightAnkle;break;case RFO:j=s.rightFoot;break;}
    return j!=null&&j.tracked()?j.world:null;
  }
  static final int[][] GROUPS={{HIPC,SPINE,SHC,HEAD},{LSH,RSH},{LEL,REL},{LWR,RWR,LHA,RHA},{LHIP,RHIP,LKN,RKN},{LAN,RAN,LFO,RFO}};
  static final String[] GROUP_NAMES={"torso+head","shoulders","elbows","wrists+hands","hips+knees","ankles+feet"};

  static class ViewportStats {
    long frames=0,points=0,escaped=0;double maxCenter=0,maxOccX=0,maxOccY=0,sumCenter=0;
    void add(SynKinectStudio app,SynKinectStudio.BodySkeletonPreview view,SynKinectStudio.BodyViewFrame vf,SynKinectStudio.PointCloud cloud){
      if(vf==null||!vf.valid)return;frames++;maxCenter=Math.max(maxCenter,vf.centerErrorPx);sumCenter+=vf.centerErrorPx;maxOccX=Math.max(maxOccX,vf.occupancyX);maxOccY=Math.max(maxOccY,vf.occupancyY);
      if(cloud==null||cloud.points==null)return;for(PVector q:cloud.points){if(q==null||!view.plausibleBodyPoint(q,vf.origin))continue;points++;PVector p=view.project3DPoint(q.x-vf.origin.x,q.y-vf.origin.y,q.z-vf.origin.z,vf.cx,vf.cy,vf.scale,vf.yaw,vf.pitch);if(!vf.contains(p.x,p.y,1))escaped++;}
    }
  }

  public static void main(String[] a) throws Exception{
    double dist=a.length>0?Double.parseDouble(a[0]):2.6;long seed=a.length>1?Long.parseLong(a[1]):3;
    new SkeletonHarness().run(dist,seed);System.exit(0);
  }
  void run(double dist,long seed) throws Exception{
    SynKinectStudio app=new SynKinectStudio();app.studio=app.new StudioController(app.new StudioServices());
    SynKinectStudio.AppConfig cfg=app.new AppConfig();cfg.load(app.studio.services.paths.resource("scanner","config.properties"));
    SynKinectStudio.Calibration cal=app.new Calibration();cal.configure(cfg);SynKinectStudio.RgbDepthRegistration reg=app.new RgbDepthRegistration(cfg,cal);
    RX=reg.rayX;RY=reg.rayY;
    SynKinectStudio.SkeletonProcessingSession session=app.studio.services.skeletons.createSession(cal,reg);
    {String sm=System.getProperty("skel.solver");if(sm!=null)session.cfg.solverMode=sm;}
    // Optional end-to-end check: feed the tracked poses to the Interactivity controller
    // (recording sink, no real input) and report which gestures each segment produced.
    if(Boolean.getBoolean("skel.interaction")){SynKinectStudio.InteractionConfig icfg=app.new InteractionConfig();icfg.load(app.studio.services.paths.resource("interactivity","config.properties"));
      recorder=new Recorder();controller=app.new InteractionDesktopController(icfg,recorder);controller.setEnabled(true);}
    lookAt(v(0,Double.parseDouble(System.getProperty("skel.camH","0.82")),dist),v(0,Double.parseDouble(System.getProperty("skel.lookH","0.92")),0));
    SynKinectStudio.BodySkeletonPreview[] bodyViews={app.new BodySkeletonPreview(),app.new BodySkeletonPreview(),app.new BodySkeletonPreview()};
    int[][] bodyViewSize={{760,430},{520,270},{360,220}};ViewportStats[] bodyViewStats={new ViewportStats(),new ViewportStats(),new ViewportStats()};
    List<Segment> L=choreography();double total=0;for(Segment s:L)total+=s.dur;
    total=Math.min(total,Double.parseDouble(System.getProperty("skel.stopAfter","1e9")));
    double fps=Double.parseDouble(System.getProperty("skel.fps","30"));int frames=(int)(total*fps);
    boolean verbose=Boolean.getBoolean("skel.verbose");
    // accumulators per segment and group
    LinkedHashMap<String,double[]> segSum=new LinkedHashMap<String,double[]>();LinkedHashMap<String,int[]> segCnt=new LinkedHashMap<String,int[]>();
    LinkedHashMap<String,int[]> segMissing=new LinkedHashMap<String,int[]>(),segSwap=new LinkedHashMap<String,int[]>(),segHandOk=new LinkedHashMap<String,int[]>(),segHands=new LinkedHashMap<String,int[]>();
    int mirrorVotes=0,directVotes=0;double procSum=0;int procN=0;
    ArrayList<double[]> allHandErr=new ArrayList<double[]>();
    for(int f=0;f<frames;f++){
      double t=f/fps;Pose p=poseAt(L,t);setBody(p);
      short[] depth=cachedRender(dist,seed,fps,f);int valid=0;for(short d:depth)if(d!=0)valid++;
      if(f==0&&System.getProperty("skel.dump")!=null){int[] px=new int[W*H];for(int i=0;i<W*H;i++){int mm=depth[i]&0xffff;int g=mm==0?0:Math.max(0,Math.min(255,(int)(255-(mm-500)*255/4000)));px[i]=(g<<16)|(g<<8)|g;}
        java.awt.image.BufferedImage bi=new java.awt.image.BufferedImage(W,H,java.awt.image.BufferedImage.TYPE_INT_RGB);bi.setRGB(0,0,W,H,px,0,W);javax.imageio.ImageIO.write(bi,"png",new java.io.File(System.getProperty("skel.dump")));
        System.out.println("valid="+valid);}
      SynKinectStudio.DepthFrame df=app.new DepthFrame();df.width=W;df.height=H;df.stride=W*2;df.depth=depth;df.frameNumber=f+1;df.frameId=f+1;
      df.timestampUs=(long)(t*1e6);df.validCount=valid;df.plausibleCount=valid;df.deviceCalibrated=true;
      double[] upCam=v(camR[0][1],camR[1][1],camR[2][1]);df.motion.flags=1;df.motion.accelX=(int)Math.round(upCam[0]*819);df.motion.accelY=(int)Math.round(upCam[1]*819);df.motion.accelZ=(int)Math.round(upCam[2]*819);
      long t0=System.nanoTime();SynKinectStudio.SkeletonModuleFrame out=session.process(df,null,(long)(t*1000));double ms=(System.nanoTime()-t0)/1e6;
      if(controller!=null&&out.pose!=null){recorder.segment=segmentAt(L,t);recorder.t=t;controller.clockOverride=(long)(t*1000)+1000;controller.update(out.pose);}
      if(f>10){procSum+=ms;procN++;}
      String seg=segmentAt(L,t);boolean settled=transitionAt(L,t)>=0.8;
      segSum.putIfAbsent(seg,new double[GROUPS.length]);segCnt.putIfAbsent(seg,new int[GROUPS.length]);segMissing.putIfAbsent(seg,new int[1]);segSwap.putIfAbsent(seg,new int[1]);segHandOk.putIfAbsent(seg,new int[1]);segHands.putIfAbsent(seg,new int[1]);
      SynKinectStudio.SkeletonPose3D s=out.pose;
      double[][] gtCam=new double[20][];for(int k=0;k<20;k++)gtCam[k]=toCam(J[k]);
      if(s==null||!s.tracked){segMissing.get(seg)[0]++;if(verbose)System.out.printf(Locale.ROOT,"t=%.2f %s: not tracked (%s)%n",t,seg,s==null?"null":s.reason);continue;}
      for(int vi=0;vi<bodyViews.length;vi++){SynKinectStudio.BodyViewFrame vf=bodyViews[vi].prepareFrame(s,out.bodyCloud,0,0,bodyViewSize[vi][0],bodyViewSize[vi][1]);bodyViewStats[vi].add(app,bodyViews[vi],vf,out.bodyCloud);}
      // convention check on shoulders (person's left should be image right)
      PVector ls=jointOf(s,LSH);if(ls!=null){double dDirect=len(sub(v(ls.x,ls.y,ls.z),gtCam[LSH])),dMirror=len(sub(v(ls.x,ls.y,ls.z),gtCam[RSH]));if(dDirect<dMirror)directVotes++;else mirrorVotes++;}
      boolean mirrored=mirrorVotes>directVotes;
      if(System.getProperty("skel.dumpJoints")!=null&&f%10==5){for(int k=0;k<20;k++){PVector e=jointOf(s,k);System.out.printf(Locale.ROOT,"   %-14s gt=(%.3f,%.3f,%.3f) est=%s%n",JN[k],gtCam[k][0],gtCam[k][1],gtCam[k][2],e==null?"--":String.format(Locale.ROOT,"(%.3f,%.3f,%.3f)",e.x,e.y,e.z));}}
      if(!settled)continue;
      for(int g=0;g<GROUPS.length;g++)for(int k:GROUPS[g]){int kk=mirrored?mirrorIndex(k):k;PVector e=jointOf(s,kk);if(e==null){segMissing.get(seg)[0]++;continue;}
        double err=len(sub(v(e.x,e.y,e.z),gtCam[k]));segSum.get(seg)[g]+=err;segCnt.get(seg)[g]++;}
      for(int k:new int[]{LHA,RHA}){int kk=mirrored?mirrorIndex(k):k;PVector e=jointOf(s,kk);segHands.get(seg)[0]++;if(e==null)continue;double[] ev=v(e.x,e.y,e.z);
        double err=len(sub(ev,gtCam[k])),other=len(sub(ev,gtCam[k==LHA?RHA:LHA]));if(err<0.08)segHandOk.get(seg)[0]++;if(other+0.02<err&&err>0.10)segSwap.get(seg)[0]++;allHandErr.add(new double[]{err});}
      if(verbose){PVector lh=jointOf(s,mirrored?RHA:LHA),rh=jointOf(s,mirrored?LHA:RHA);System.out.printf(Locale.ROOT,"t=%.2f %-8s L=%s R=%s  %.0fms%n",t,seg,
        lh==null?"--":String.format(Locale.ROOT,"%.0fcm",100*len(sub(v(lh.x,lh.y,lh.z),gtCam[LHA]))),rh==null?"--":String.format(Locale.ROOT,"%.0fcm",100*len(sub(v(rh.x,rh.y,rh.z),gtCam[RHA]))),ms);}
    }
    System.out.printf(Locale.ROOT,"convention: %s (votes direct=%d mirrored=%d)  mean processing %.1f ms/frame%n",mirrorVotes>directVotes?"MIRRORED":"direct",directVotes,mirrorVotes,procSum/Math.max(1,procN));
    System.out.printf(Locale.ROOT,"%-9s","segment");for(String g:GROUP_NAMES)System.out.printf(Locale.ROOT," %13s",g);System.out.println("   hands<8cm  swaps  missing");
    double[] tot=new double[GROUPS.length];int[] totN=new int[GROUPS.length];int ok=0,hn=0,sw=0;
    for(String seg:segSum.keySet()){System.out.printf(Locale.ROOT,"%-9s",seg);for(int g=0;g<GROUPS.length;g++){int n=segCnt.get(seg)[g];System.out.printf(Locale.ROOT," %11.1fcm",n==0?Double.NaN:100*segSum.get(seg)[g]/n);tot[g]+=segSum.get(seg)[g];totN[g]+=n;}
      int h=segHands.get(seg)[0];System.out.printf(Locale.ROOT,"   %8.0f%%  %5d  %7d%n",h==0?0:100.0*segHandOk.get(seg)[0]/h,segSwap.get(seg)[0],segMissing.get(seg)[0]);ok+=segHandOk.get(seg)[0];hn+=h;sw+=segSwap.get(seg)[0];}
    if(recorder!=null){System.out.println("interaction events per segment (pointer moves / left presses / right clicks / scroll notches):");
      for(Map.Entry<String,int[]> e:recorder.counts.entrySet())System.out.printf(Locale.ROOT,"  %-9s %5d %4d %4d %4d%n",e.getKey(),e.getValue()[0],e.getValue()[1],e.getValue()[2],e.getValue()[3]);}
    System.out.printf(Locale.ROOT,"%-9s","ALL");for(int g=0;g<GROUPS.length;g++)System.out.printf(Locale.ROOT," %11.1fcm",totN[g]==0?Double.NaN:100*tot[g]/totN[g]);System.out.printf(Locale.ROOT,"   %8.0f%%  %5d%n",hn==0?0:100.0*ok/hn,sw);
    boolean viewPass=true;System.out.println("Body3D shared viewport contract:");
    for(int vi=0;vi<bodyViews.length;vi++){ViewportStats v=bodyViewStats[vi];double mean=v.frames==0?Double.NaN:v.sumCenter/v.frames,escape=v.points==0?0:100.0*v.escaped/v.points;
      boolean pass=v.frames>0&&v.escaped==0&&v.maxCenter<=Math.min(bodyViewSize[vi][0],bodyViewSize[vi][1])*.085&&v.maxOccX<=.98&&v.maxOccY<=.98;viewPass&=pass;
      System.out.printf(Locale.ROOT,"  %dx%d frames=%d center mean/max %.1f/%.1f px  occupancy max %.3f/%.3f  escaped %d/%d (%.3f%%)  %s%n",bodyViewSize[vi][0],bodyViewSize[vi][1],v.frames,mean,v.maxCenter,v.maxOccX,v.maxOccY,v.escaped,v.points,escape,pass?"PASS":"FAIL");}
    System.out.println("BODY3D VIEWPORT RESULT: "+(viewPass?"PASS":"FAIL"));
  }
  SynKinectStudio.InteractionDesktopController controller;Recorder recorder;
  static class Recorder implements SynKinectStudio.InteractionInputSink {
    String segment="";double t;LinkedHashMap<String,int[]> counts=new LinkedHashMap<String,int[]>();
    int[] c(){return counts.computeIfAbsent(segment,k->new int[4]);}
    public boolean available(){return true;}public String error(){return "";}public java.awt.Rectangle bounds(){return new java.awt.Rectangle(0,0,1920,1080);}
    public void move(int x,int y){c()[0]++;}
    public void button(int m,boolean d){if(d){if(m==java.awt.event.InputEvent.BUTTON1_DOWN_MASK)c()[1]++;else c()[2]++;}}
    public void wheel(int n){c()[3]+=Math.abs(n);}
    public void key(int vk,boolean d){}public void pasteText(String s){}
  }
  static int mirrorIndex(int k){switch(k){case LSH:return RSH;case RSH:return LSH;case LEL:return REL;case REL:return LEL;case LWR:return RWR;case RWR:return LWR;case LHA:return RHA;case RHA:return LHA;
    case LHIP:return RHIP;case RHIP:return LHIP;case LKN:return RKN;case RKN:return LKN;case LAN:return RAN;case RAN:return LAN;case LFO:return RFO;case RFO:return LFO;default:return k;}}
}
