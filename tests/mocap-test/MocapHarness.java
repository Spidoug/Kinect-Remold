import processing.core.*;
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * Motion-capture pipeline test (no Kinect): synthetic SynSkeleton poses ->
 * BodyFrame -> MocapRetargeter -> VMC / OSC / JSON-UDP / WebSocket sinks and the
 * BVH recorder. Every wire format is decoded here with independent parsers.
 */
public class MocapHarness {
  static SynKinectStudio app;
  static final List<String> fails=new ArrayList<>();
  static int checks=0;
  static void check(boolean ok,String what){checks++;if(!ok){fails.add(what);System.out.println("  FAIL "+what);}}

  // ------------------------------------------------------------ synthetic pose (camera space: +x = user's LEFT, +y down, +z away)
  static PVector v(double x,double y,double z){return new PVector((float)x,(float)y,(float)z);}
  static final double Z0=2.0;
  static final PVector HEAD=v(0,-.70,Z0),SC=v(0,-.48,Z0),SP=v(0,-.22,Z0),HC=v(0,.05,Z0),LSH=v(.19,-.45,Z0),RSH=v(-.19,-.45,Z0),LHIP=v(.095,.05,Z0),RHIP=v(-.095,.05,Z0);
  static final double UA=.29,FA=.255,HA=.075;
  /** Arm description: unit directions (camera space) of upper arm, forearm/hand and thumb. */
  static class Arm {PVector upper,fore,thumb;Arm(PVector u,PVector f,PVector t){upper=u.copy().normalize();fore=f.copy().normalize();thumb=t.copy().normalize();}}
  static Arm tposeLeft(){return new Arm(v(1,0,0),v(1,0,0),v(0,0,-1));}   // user's left arm lateral, palm down, thumb toward the sensor
  static Arm tposeRight(){return new Arm(v(-1,0,0),v(-1,0,0),v(0,0,-1));}
  static SynKinectStudio.SkeletonPose3D pose(Arm l,Arm r,long t){
    SynKinectStudio.SkeletonPose3D s=app.new SkeletonPose3D();
    set(s.head,HEAD,t);set(s.shoulderCenter,SC,t);set(s.spine,SP,t);set(s.hipCenter,HC,t);set(s.leftShoulder,LSH,t);set(s.rightShoulder,RSH,t);
    set(s.leftHip,LHIP,t);set(s.rightHip,RHIP,t);
    arm(s,true,LSH,l,t);arm(s,false,RSH,r,t);
    for(int side=0;side<2;side++){PVector hip=side==0?LHIP:RHIP;PVector knee=PVector.add(hip,v(0,.44,0)),ankle=PVector.add(knee,v(0,.42,0)),foot=PVector.add(ankle,v(0,.045,-.11));
      if(side==0){set(s.leftKnee,knee,t);set(s.leftAnkle,ankle,t);set(s.leftFoot,foot,t);}else{set(s.rightKnee,knee,t);set(s.rightAnkle,ankle,t);set(s.rightFoot,foot,t);}}
    s.tracked=true;s.confidence=.9f;s.torsoConfidence=.95f;s.trackingId=7;s.meanDepthM=(float)Z0;return s;
  }
  static void arm(SynKinectStudio.SkeletonPose3D s,boolean left,PVector sh,Arm a,long t){
    PVector el=PVector.add(sh,PVector.mult(a.upper,(float)UA)),wr=PVector.add(el,PVector.mult(a.fore,(float)FA)),ha=PVector.add(wr,PVector.mult(a.fore,(float)HA)),
      tip=PVector.add(wr,PVector.mult(a.fore,.18f)),th=PVector.add(PVector.add(wr,PVector.mult(a.fore,.03f)),PVector.mult(a.thumb,.05f));
    if(left){set(s.leftElbow,el,t);set(s.leftWrist,wr,t);set(s.leftHand,ha,t);set(s.leftHandTip,tip,t);set(s.leftThumb,th,t);}
    else{set(s.rightElbow,el,t);set(s.rightWrist,wr,t);set(s.rightHand,ha,t);set(s.rightHandTip,tip,t);set(s.rightThumb,th,t);}
  }
  static void set(SynKinectStudio.SkeletonJoint3D j,PVector p,long t){j.set(new PVector(),p.copy(),.9f,SynKinectStudio.SkeletonJoint3D.TRACKED,"test",t);}
  static SynKinectStudio.BodyFrame frame(SynKinectStudio.SkeletonPose3D s,long frame,long t){
    // gravity straight down in camera space, floor 1.0 m below the camera origin
    return app.bodyFrameFromPose("test:0",s,frame,t-8,t,v(0,-1,0),true,1.0f);
  }

  // ------------------------------------------------------------ quaternion helpers (independent of the sketch)
  static int bone(String n){for(int i=0;i<app.MOCAP_BONES.length;i++)if(app.MOCAP_BONES[i].equals(n))return i;throw new IllegalArgumentException(n);}
  static double[] q(float[] a,int i){return new double[]{a[i*4],a[i*4+1],a[i*4+2],a[i*4+3]};}
  static double angleDeg(double[] q){double w=Math.min(1,Math.abs(q[3])/Math.sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3]));return Math.toDegrees(2*Math.acos(w));}
  static double[] axis(double[] q){double s=Math.sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]);if(s<1e-9)return new double[]{0,0,0};double sg=q[3]<0?-1:1;return new double[]{sg*q[0]/s,sg*q[1]/s,sg*q[2]/s};}
  static double[] rot(double[] q,double[] v){double x=q[0],y=q[1],z=q[2],w=q[3];
    double tx=2*(y*v[2]-z*v[1]),ty=2*(z*v[0]-x*v[2]),tz=2*(x*v[1]-y*v[0]);
    return new double[]{v[0]+w*tx+(y*tz-z*ty),v[1]+w*ty+(z*tx-x*tz),v[2]+w*tz+(x*ty-y*tx)};}
  static double dot(double[] a,double[] b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}
  static String fmt(double[] a){StringBuilder b=new StringBuilder("(");for(int i=0;i<a.length;i++){if(i>0)b.append(", ");b.append(String.format(Locale.ROOT,"%.3f",a[i]));}return b.append(")").toString();}

  // ------------------------------------------------------------ independent OSC parser
  static class OscMsg {String address;String tags;List<Object> args=new ArrayList<>();}
  static String oscStr(ByteBuffer b){int start=b.position();while(b.get()!=0){}int len=b.position()-1-start;byte[] s=new byte[len];for(int i=0;i<len;i++)s[i]=b.get(start+i);
    while((b.position()-start)%4!=0)b.get();return new String(s,StandardCharsets.UTF_8);}
  static void parseOsc(ByteBuffer b,List<OscMsg> out){
    int start=b.position();String first=oscStr(b);
    if(first.equals("#bundle")){long tt=b.getLong();if(tt!=1)fails.add("bundle timetag "+tt);int end=b.limit();
      while(b.position()<end){int size=b.getInt();ByteBuffer e=b.slice();e.limit(size);parseOsc(e,out);b.position(b.position()+size);}return;}
    OscMsg m=new OscMsg();m.address=first;m.tags=oscStr(b);
    for(char c:m.tags.substring(1).toCharArray()){if(c=='i')m.args.add(b.getInt());else if(c=='f')m.args.add(b.getFloat());else if(c=='s')m.args.add(oscStr(b));else throw new IllegalStateException("tag "+c);}
    out.add(m);
  }
  static byte[] receive(DatagramSocket s)throws IOException{byte[] buf=new byte[65536];DatagramPacket p=new DatagramPacket(buf,buf.length);s.receive(p);return Arrays.copyOf(buf,p.getLength());}

  public static void main(String[] a)throws Exception{
    app=new SynKinectStudio();app.studio=app.new StudioController(app.new StudioServices());
    SynKinectStudio.MocapRetargeter rt=app.new MocapRetargeter();
    long t=100000;

    // ---- 1. T-pose -> identity local rotations
    System.out.println("[retarget] T-pose");
    SynKinectStudio.MocapPose tp=rt.retarget(frame(pose(tposeLeft(),tposeRight(),t),1,t));
    double worst=0;String worstBone="";
    for(int i=0;i<tp.boneCount();i++){double ang=angleDeg(q(tp.localRot,i));if(ang>worst){worst=ang;worstBone=tp.boneName(i);}
}
    System.out.printf(Locale.ROOT,"  max local rotation in T-pose: %.2f deg (%s)%n",worst,worstBone);
    check(worst<3.0,"T-pose local rotations ~identity (max "+worst+" deg on "+worstBone+")");
    double hipsY=tp.globalPos[1];System.out.printf(Locale.ROOT,"  Hips height above floor: %.3f m%n",hipsY);check(Math.abs(hipsY-.95)<.02,"hips height from floor plane");
    int lua=bone("LeftUpperArm");check(tp.globalPos[lua*3]<-.1,"LeftUpperArm on avatar's left (-X in Unity)");

    // ---- 2. Left arm raised 90 deg (abduction) -> LeftUpperArm local = 90 deg about -Z
    System.out.println("[retarget] left arm raised 90 deg");
    Arm up=new Arm(v(0,-1,0),v(0,-1,0),v(0,0,-1));
    SynKinectStudio.MocapPose lp=rt.retarget(frame(pose(up,tposeRight(),t+33),2,t+33));
    double[] ql=q(lp.localRot,lua);double ang=angleDeg(ql);double[] ax=axis(ql);double[] d=rot(ql,new double[]{-1,0,0});
    System.out.printf(Locale.ROOT,"  LeftUpperArm local: angle %.2f deg axis %s, rest(-X) -> %s%n",ang,fmt(ax),fmt(d));
    check(Math.abs(ang-90)<3,"LeftUpperArm raise angle ~90 ("+ang+")");
    check(dot(ax,new double[]{0,0,-1})>.99,"LeftUpperArm raise axis -Z "+fmt(ax));
    check(dot(d,new double[]{0,1,0})>.998,"LeftUpperArm rest direction maps to +Y");
    check(angleDeg(q(lp.localRot,bone("RightUpperArm")))<3,"RightUpperArm unchanged");
    check(angleDeg(q(lp.localRot,bone("LeftLowerArm")))<3,"LeftLowerArm straight (local identity)");
    // right arm
    Arm upR=new Arm(v(0,-1,0),v(0,-1,0),v(0,0,-1));
    SynKinectStudio.MocapPose rp=rt.retarget(frame(pose(tposeLeft(),upR,t+66),3,t+66));
    double[] qr=q(rp.localRot,bone("RightUpperArm"));System.out.printf(Locale.ROOT,"  RightUpperArm local: angle %.2f deg axis %s%n",angleDeg(qr),fmt(axis(qr)));
    check(Math.abs(angleDeg(qr)-90)<3&&dot(axis(qr),new double[]{0,0,1})>.99,"RightUpperArm raise 90 about +Z");

    // ---- 3. Elbow bent 90 deg forward (toward the sensor): LowerArm 90 deg about +Y, UpperArm keeps no twist
    System.out.println("[retarget] left elbow flexed 90 deg forward");
    // pure hinge flexion keeps the palm down: the thumb now points medially (toward -X camera)
    Arm bent=new Arm(v(1,0,0),v(0,0,-1),v(-1,0,0));
    SynKinectStudio.MocapPose bp=rt.retarget(frame(pose(bent,tposeRight(),t+99),4,t+99));
    double[] qf=q(bp.localRot,bone("LeftLowerArm"));System.out.printf(Locale.ROOT,"  LeftLowerArm local: angle %.2f deg axis %s; LeftUpperArm %.2f deg%n",angleDeg(qf),fmt(axis(qf)),angleDeg(q(bp.localRot,lua)));
    check(Math.abs(angleDeg(qf)-90)<4&&dot(axis(qf),new double[]{0,1,0})>.98,"LeftLowerArm flexion 90 about +Y");
    check(angleDeg(q(bp.localRot,lua))<4,"LeftUpperArm no twist with forward elbow bend");
    // upper arm internal rotation: forearm hanging down instead of forward -> 90 deg twist about the arm axis (-X)
    Arm twisted=new Arm(v(1,0,0),v(0,1,0),v(0,0,-1));
    SynKinectStudio.MocapPose twp=rt.retarget(frame(pose(twisted,tposeRight(),t+132),5,t+132));
    double[] qt=q(twp.localRot,lua);System.out.printf(Locale.ROOT,"  LeftUpperArm twist: angle %.2f deg axis %s%n",angleDeg(qt),fmt(axis(qt)));
    check(Math.abs(angleDeg(qt)-90)<4&&Math.abs(dot(axis(qt),new double[]{1,0,0}))>.98,"LeftUpperArm twist about the arm axis from elbow plane");

    // ---- 4. Mirror: left raise becomes RightUpperArm about +Z
    SynKinectStudio.MocapPose mp=lp.mirrored();double[] qm=q(mp.localRot,bone("RightUpperArm"));
    check(Math.abs(angleDeg(qm)-90)<3&&dot(axis(qm),new double[]{0,0,1})>.99,"mirror maps LeftUpperArm raise to RightUpperArm about +Z");
    check(mp.globalPos[bone("RightHand")*3]>0,"mirrored raised hand on +X");

    // ---- 5. Tilted sensor (gravity 12 deg off): T-pose still identity
    double tilt=Math.toRadians(12);float c=(float)Math.cos(tilt),s=(float)Math.sin(tilt);
    SynKinectStudio.SkeletonPose3D tilted=pose(tposeLeft(),tposeRight(),t+165);
    for(SynKinectStudio.SkeletonJoint3D j:tilted.kinectV2_25()){PVector w=j.world;float y=w.y,z=w.z;w.y=c*y-s*z;w.z=s*y+c*z;}
    PVector upv=v(0,-c,-s); // rotated (0,-1,0)
    SynKinectStudio.MocapPose tl=rt.retarget(app.bodyFrameFromPose("test:0",tilted,6,t+157,t+165,upv,false,0));
    double tw=0;for(int i=0;i<tl.boneCount();i++)tw=Math.max(tw,angleDeg(q(tl.localRot,i)));
    System.out.printf(Locale.ROOT,"[retarget] sensor pitched 12 deg: max local %.2f deg, hips global %.2f deg%n",tw,angleDeg(q(tl.globalRot,0)));
    check(tw<3&&angleDeg(q(tl.globalRot,0))<3,"gravity alignment removes sensor pitch");

    // quaternion unit length everywhere
    for(SynKinectStudio.MocapPose p:new SynKinectStudio.MocapPose[]{tp,lp,rp,bp,twp,mp,tl})for(int i=0;i<p.boneCount();i++){double[] qq=q(p.localRot,i);double n=Math.sqrt(dot(qq,qq)+qq[3]*qq[3]);if(Math.abs(n-1)>1e-3)check(false,"unit quaternion "+p.boneName(i));}

    // ---- 6. VMC over UDP
    System.out.println("[sink] VMC");
    try(DatagramSocket rx=new DatagramSocket(0,InetAddress.getByName("127.0.0.1"))){rx.setSoTimeout(3000);
      SynKinectStudio.MocapVmcSink vmc=app.new MocapVmcSink("127.0.0.1","127.0.0.1",rx.getLocalPort());vmc.setEnabled(true);vmc.offer(lp);
      List<OscMsg> msgs=new ArrayList<>();parseOsc(ByteBuffer.wrap(receive(rx)),msgs);vmc.setEnabled(false);
      Map<String,OscMsg> bones=new LinkedHashMap<>();int ok=-1;boolean haveT=false,haveRoot=false;
      for(OscMsg m:msgs){if(m.address.equals("/VMC/Ext/OK"))ok=(Integer)m.args.get(0);else if(m.address.equals("/VMC/Ext/T"))haveT=m.tags.equals(",f");
        else if(m.address.equals("/VMC/Ext/Root/Pos"))haveRoot=m.tags.equals(",sfffffff")&&"root".equals(m.args.get(0));
        else if(m.address.equals("/VMC/Ext/Bone/Pos")){check(m.tags.equals(",sfffffff"),"Bone/Pos type tags");bones.put((String)m.args.get(0),m);}}
      System.out.println("  messages="+msgs.size()+" bones="+bones.keySet());
      check(ok==1,"/VMC/Ext/OK 1");check(haveT,"/VMC/Ext/T float");check(haveRoot,"/VMC/Ext/Root/Pos");
      check(bones.keySet().equals(new LinkedHashSet<>(Arrays.asList(app.MOCAP_BONES))),"VMC bone names");
      for(OscMsg m:bones.values()){double x=(Float)m.args.get(4),y=(Float)m.args.get(5),z=(Float)m.args.get(6),w=(Float)m.args.get(7);
        if(Math.abs(Math.sqrt(x*x+y*y+z*z+w*w)-1)>1e-3)check(false,"VMC quaternion unit length "+m.args.get(0));}
      OscMsg ua=bones.get("LeftUpperArm");double[] qv={(Float)ua.args.get(4),(Float)ua.args.get(5),(Float)ua.args.get(6),(Float)ua.args.get(7)};
      System.out.printf(Locale.ROOT,"  VMC LeftUpperArm: %.2f deg axis %s%n",angleDeg(qv),fmt(axis(qv)));
      check(Math.abs(angleDeg(qv)-90)<3&&dot(axis(qv),new double[]{0,0,-1})>.99,"VMC LeftUpperArm 90 deg about -Z");
    }

    // ---- 7. Plain OSC + JSON UDP
    System.out.println("[sink] OSC + JSON UDP");
    try(DatagramSocket rx=new DatagramSocket(0,InetAddress.getByName("127.0.0.1"))){rx.setSoTimeout(3000);
      SynKinectStudio.MocapOscSink osc=app.new MocapOscSink("127.0.0.1","127.0.0.1",rx.getLocalPort());osc.setEnabled(true);osc.offer(tp);
      List<OscMsg> msgs=new ArrayList<>();parseOsc(ByteBuffer.wrap(receive(rx)),msgs);osc.setEnabled(false);
      long joints=msgs.stream().filter(m->m.address.equals("/synkinect/joint")).count(),frames=msgs.stream().filter(m->m.address.equals("/synkinect/frame")).count();
      System.out.println("  /synkinect/joint="+joints+" /synkinect/frame="+frames);check(joints==24&&frames==1,"OSC joint/frame messages");
      SynKinectStudio.MocapJsonUdpSink js=app.new MocapJsonUdpSink("127.0.0.1","127.0.0.1",rx.getLocalPort(),false);js.setEnabled(true);js.offer(tp);
      String json=new String(receive(rx),StandardCharsets.UTF_8);js.setEnabled(false);
      check(json.startsWith("{\"v\":1,")&&json.contains("\"space\":\"unity\"")&&json.contains("\"Hips\":{\"p\":[")&&json.contains("\"LeftFoot\""),"JSON UDP document");
      System.out.println("  JSON bytes="+json.length());
    }

    // ---- 8. WebSocket server + java.net.http client
    System.out.println("[sink] WebSocket");
    int wsPort;try(ServerSocket probe=new ServerSocket(0,1,InetAddress.getByName("127.0.0.1"))){wsPort=probe.getLocalPort();}
    SynKinectStudio.MocapWebSocketSink ws=app.new MocapWebSocketSink("127.0.0.1",wsPort,false);ws.setEnabled(true);
    BlockingQueue<String> got=new LinkedBlockingQueue<>();CountDownLatch pong=new CountDownLatch(1);
    java.net.http.WebSocket client=java.net.http.HttpClient.newBuilder().proxy(java.net.http.HttpClient.Builder.NO_PROXY).build().newWebSocketBuilder()
      .buildAsync(URI.create("ws://127.0.0.1:"+wsPort+"/"),new java.net.http.WebSocket.Listener(){
        StringBuilder part=new StringBuilder();
        public CompletionStage<?> onText(java.net.http.WebSocket w,CharSequence data,boolean last){part.append(data);if(last){got.add(part.toString());part.setLength(0);}w.request(1);return null;}
        public CompletionStage<?> onPong(java.net.http.WebSocket w,ByteBuffer m){pong.countDown();w.request(1);return null;}
      }).get(5,TimeUnit.SECONDS);
    String msg=null;for(int i=0;i<50&&msg==null;i++){ws.offer(tp);msg=got.poll(100,TimeUnit.MILLISECONDS);}
    System.out.println("  clients="+ws.clients()+" received="+(msg==null?"none":msg.length()+" chars"));
    check(msg!=null&&msg.contains("\"bodies\":[{\"id\":7")&&msg.contains("\"LeftUpperArm\""),"WebSocket JSON frame");
    client.sendPing(ByteBuffer.wrap(new byte[]{1,2,3}));check(pong.await(3,TimeUnit.SECONDS),"WebSocket ping -> pong");
    client.sendClose(java.net.http.WebSocket.NORMAL_CLOSURE,"bye").get(3,TimeUnit.SECONDS);
    for(int i=0;i<30&&ws.clients()>0;i++)Thread.sleep(50);check(ws.clients()==0,"WebSocket close handling");
    ws.setEnabled(false);

    // ---- 9. Latest-only mailbox never blocks the producer
    SynKinectStudio.LatestMailbox<Integer> slow=app.new LatestMailbox<Integer>("slow",x->{try{Thread.sleep(200);}catch(InterruptedException e){}});
    long t0=System.nanoTime();for(int i=0;i<1000;i++)slow.offer(i);double ms=(System.nanoTime()-t0)/1e6;slow.close();
    System.out.printf(Locale.ROOT,"[mailbox] 1000 offers to a 200 ms consumer took %.2f ms (dropped %d)%n",ms,slow.dropped);check(ms<100&&slow.dropped>900,"latest-only mailbox");

    // ---- 10. BVH record + re-parse
    System.out.println("[bvh]");
    Path dir=Files.createTempDirectory("mocap-bvh");SynKinectStudio.MocapBvhRecorder rec=app.new MocapBvhRecorder();rec.start(dir.toFile(),tp.restLengths);
    int N=24;SynKinectStudio.MocapRetargeter rt2=app.new MocapRetargeter();
    for(int i=0;i<N;i++){double k=i/(double)(N-1);Arm l=new Arm(v(Math.cos(k*Math.PI/2),-Math.sin(k*Math.PI/2),0),v(Math.cos(k*Math.PI/2),-Math.sin(k*Math.PI/2),0),v(0,0,-1));
      long ti=t+1000+i*33;SynKinectStudio.MocapPose p=rt2.retarget(frame(pose(l,tposeRight(),ti),100+i,ti));int before=rec.frameCount;rec.offer(p);
      for(int w=0;w<200&&rec.frameCount==before;w++)Thread.sleep(2);}
    File bvh=rec.stop();check(bvh!=null&&bvh.isFile(),"BVH file written");
    List<String> lines=Files.readAllLines(bvh.toPath());int joints=0,channels=0,frames=-1,motionAt=-1;double frameTime=0;List<String> order=new ArrayList<>();
    for(int i=0;i<lines.size();i++){String ln=lines.get(i).trim();
      if(ln.startsWith("ROOT ")||ln.startsWith("JOINT ")){joints++;order.add(ln.split("\\s+")[1]);}
      if(ln.startsWith("CHANNELS "))channels+=Integer.parseInt(ln.split("\\s+")[1]);
      if(ln.startsWith("Frames:"))frames=Integer.parseInt(ln.split("\\s+")[1]);
      if(ln.startsWith("Frame Time:")){frameTime=Double.parseDouble(ln.split("\\s+")[2]);motionAt=i+1;}}
    int rows=0;boolean widthOk=true;double lastZ=0,lastX=0,lastY=0;int uaIdx=order.indexOf("LeftUpperArm");
    for(int i=motionAt;i<lines.size();i++){if(lines.get(i).trim().isEmpty())continue;String[] vals=lines.get(i).trim().split("\\s+");rows++;if(vals.length!=channels)widthOk=false;
      int base=6+(uaIdx-1)*3;lastZ=Double.parseDouble(vals[base]);lastX=Double.parseDouble(vals[base+1]);lastY=Double.parseDouble(vals[base+2]);}
    System.out.printf(Locale.ROOT,"  %s: joints=%d channels=%d frames=%d rows=%d frameTime=%.4f  LeftUpperArm last ZXY=(%.1f, %.1f, %.1f)%n",bvh.getName(),joints,channels,frames,rows,frameTime,lastZ,lastX,lastY);
    check(joints==app.MOCAP_BONES.length,"BVH joint count");check(channels==6+3*(app.MOCAP_BONES.length-1),"BVH channel count");
    check(frames==N&&rows==N&&widthOk,"BVH frame count / row width");check(Math.abs(frameTime-.033)<.002,"BVH frame time");
    // last frame: left arm raised 90 deg = 90 deg about -Z (Unity). BVH reflection (x,y,z,w)->(x,-y,-z,w) gives 90 deg about +Z => ZXY (90,0,0).
    check(Math.abs(lastZ-90)<3&&Math.abs(lastX)<3&&Math.abs(lastY)<3,"BVH LeftUpperArm ZXY ~ (90,0,0)");

    // ---- 11. SDK conversion
    org.synkinect.studio.api.StudioBodyFrame sf=app.studioBodyFrame(lp.source,lp);
    check(sf.joints().size()==24&&sf.joint("ShoulderLeft")!=null&&sf.humanoidBones().size()==19&&sf.humanoid("LeftUpperArm").hasRotation(),"SDK StudioBodyFrame");

    System.out.println("checks="+checks+" failures="+fails.size());
    System.out.println("RESULT: "+(fails.isEmpty()?"PASS":"FAIL "+fails));
    System.exit(fails.isEmpty()?0:1);
  }
}
