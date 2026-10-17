import processing.core.*;
import java.util.*;

/** Scripted two-hand interaction test for InteractionDesktopController (no Kinect, no Robot). */
public class InteractionHarness {
  static SynKinectStudio app;
  static class Rec implements SynKinectStudio.InteractionInputSink {
    java.awt.Rectangle b=new java.awt.Rectangle(0,0,1920,1080);ArrayList<String> log=new ArrayList<String>();int x=-1,y=-1;long t;
    public boolean available(){return true;}public String error(){return "";}public java.awt.Rectangle bounds(){return b;}
    public void move(int x,int y){this.x=x;this.y=y;}
    public void button(int m,boolean d){log.add(String.format(Locale.ROOT,"t=%d %s%s @%d,%d",t,m==java.awt.event.InputEvent.BUTTON1_DOWN_MASK?"L":"R",d?"down":"up",x,y));}
    public void wheel(int n){log.add("t="+t+" wheel "+n);}
    public void key(int vk,boolean d){if(d)log.add("t="+t+" key "+java.awt.event.KeyEvent.getKeyText(vk));}
    public void pasteText(String s){log.add("t="+t+" paste "+s);}
  }
  static Random rnd=new Random(7);
  static PVector v(double x,double y,double z){return new PVector((float)x,(float)y,(float)z);}
  // camera coordinates: +x image right (= user's LEFT), +y down, +z away. User at z=2.0 facing the sensor.
  static final PVector LSH=v(.19,-.45,2.0),RSH=v(-.19,-.45,2.0);
  static SynKinectStudio.SkeletonPose3D pose(PVector lHand,PVector rHand,long t,float noise){
    SynKinectStudio.SkeletonPose3D s=app.new SkeletonPose3D();
    set(s.head,v(0,-.70,2.0),t,0);set(s.shoulderCenter,v(0,-.48,2.0),t,0);set(s.spine,v(0,-.22,2.0),t,0);set(s.hipCenter,v(0,.05,2.0),t,0);
    set(s.leftShoulder,LSH,t,0);set(s.rightShoulder,RSH,t,0);set(s.leftHip,v(.09,.06,2.0),t,0);set(s.rightHip,v(-.09,.06,2.0),t,0);
    arm(s.leftElbow,s.leftWrist,s.leftHand,LSH,lHand,t,noise);arm(s.rightElbow,s.rightWrist,s.rightHand,RSH,rHand,t,noise);
    s.tracked=true;s.torsoConfidence=.95f;s.confidence=.9f;s.interactionConfidence=.9f;s.trackingId=1;s.meanDepthM=2.0f;return s;
  }
  static void arm(SynKinectStudio.SkeletonJoint3D el,SynKinectStudio.SkeletonJoint3D wr,SynKinectStudio.SkeletonJoint3D ha,PVector sh,PVector hand,long t,float noise){
    // fixed bone lengths (upper .29, forearm .25, hand .07), elbow bends downward
    PVector dir=PVector.sub(hand,sh);float dl=dir.mag();dir.normalize();PVector wrist=PVector.sub(hand,PVector.mult(dir,.07f));
    PVector to=PVector.sub(wrist,sh);float d=Math.min(to.mag(),.539f);to.normalize();float a=.29f,b=.25f;
    float ang=(float)Math.acos(Math.max(-1,Math.min(1,(a*a+d*d-b*b)/(2*a*d))));PVector bend=new PVector(0,1,0);bend.sub(PVector.mult(to,bend.dot(to)));if(bend.mag()<1e-3f)bend=new PVector(0,0,1);bend.normalize();
    PVector u=PVector.add(PVector.mult(to,(float)Math.cos(ang)),PVector.mult(bend,(float)Math.sin(ang)));PVector el2=PVector.add(sh,PVector.mult(u,a));
    set(el,el2,t,noise);set(wr,wrist,t,noise);set(ha,hand,t,noise);
  }
  static void set(SynKinectStudio.SkeletonJoint3D j,PVector p,long t,float noise){PVector q=p.copy();if(noise>0){q.x+=(float)rnd.nextGaussian()*noise;q.y+=(float)rnd.nextGaussian()*noise;q.z+=(float)rnd.nextGaussian()*noise*1.5f;}
    j.set(new PVector(),q,.9f,SynKinectStudio.SkeletonJoint3D.TRACKED,"test",t);}
  // user's right = -x, toward sensor = -z, up = -y
  static PVector off(PVector sh,double right,double up,double toward){return v(sh.x-right,sh.y-up,sh.z-toward);}
  static PVector lerp(PVector a,PVector b,double k){return PVector.lerp(a,b,(float)Math.max(0,Math.min(1,k)));}
  static double smooth(double k){k=Math.max(0,Math.min(1,k));return k*k*(3-2*k);}

  public static void main(String[] a) throws Exception{
    app=new SynKinectStudio();app.studio=app.new StudioController(app.new StudioServices());
    SynKinectStudio.InteractionConfig cfg=app.new InteractionConfig();cfg.load(app.studio.services.paths.resource("interactivity","config.properties"));
    Rec rec=new Rec();SynKinectStudio.InteractionDesktopController dc=app.new InteractionDesktopController(cfg,rec);
    SynKinectStudio.InteractionI18n i18n=app.new InteractionI18n("pt-BR");dc.attachKeyboard(i18n);dc.setEnabled(true);
    float noise=Float.parseFloat(System.getProperty("noise","0.004"));int fps=30;
    PVector restL=off(LSH,.02,-.65,.05),restR=off(RSH,-.02,-.65,.05);
    PVector hoverR=off(RSH,.05,-.12,.32),hoverR2=off(RSH,.30,-.12,.32),pushR=off(RSH,.30,-.15,.44);
    PVector hoverL=off(LSH,-.05,-.15,.32),pushL=off(LSH,-.05,-.15,.44),raiseL=off(LSH,-.05,.02,.30),raiseLup=off(LSH,-.05,.14,.30);
    double T=15.5;int moveCheckX=-1;StringBuilder trace=new StringBuilder();
    for(int f=0;f<=T*fps;f++){double t=f/(double)fps;long ms=(long)(t*1000);rec.t=ms;dc.clockOverride=ms+1000;
      PVector l=restL,r=restR;
      if(t<1){}
      else if(t<2){r=lerp(restR,hoverR,smooth(t-1));}
      else if(t<4){r=lerp(hoverR,hoverR2,smooth((t-2)/2));}
      else if(t<4.25){r=lerp(hoverR2,pushR,smooth((t-4)/.25));}         // click (push with 3 cm downward drift)
      else if(t<4.8){r=lerp(pushR,hoverR2,smooth((t-4.25)/.3));}
      else if(t<6){r=hoverR2;l=lerp(restL,hoverL,smooth((t-4.8)/.8));}
      else if(t<6.25){r=hoverR2;l=lerp(hoverL,pushL,smooth((t-6)/.25));}    // left push = right click
      else if(t<7){r=hoverR2;l=lerp(pushL,hoverL,smooth((t-6.25)/.3));}
      else if(t<8){r=hoverR2;l=lerp(hoverL,raiseL,smooth(t-7));}
      else if(t<9.5){r=hoverR2;l=lerp(raiseL,raiseLup,smooth((t-8)/.6));}  // scroll up
      else if(t<10){r=hoverR2;l=lerp(raiseLup,restL,smooth((t-9.5)/.5));}
      else if(t<10.25){r=lerp(hoverR2,pushR,smooth((t-10)/.25));}          // press and drag
      else if(t<11.5){PVector d=off(RSH,.12,-.15,.44);r=lerp(pushR,d,smooth((t-10.25)/1.0));}
      else if(t<12){PVector d=off(RSH,.12,-.15,.44);r=lerp(d,off(RSH,.12,-.15,.30),smooth((t-11.5)/.3));}
      else if(t<12.4){r=off(RSH,.12,-.15,.30);l=lerp(restL,hoverL,smooth((t-12)/.4));}
      else if(t<12.65){r=lerp(off(RSH,.12,-.15,.30),off(RSH,.12,-.15,.44),smooth((t-12.4)/.25));l=hoverL;}  // both push = double click
      else if(t<12.75){r=off(RSH,.12,-.15,.44);l=lerp(hoverL,pushL,smooth((t-12.65)/.1));}
      else {r=lerp(off(RSH,.12,-.15,.44),restR,smooth((t-12.75)/.8));l=lerp(pushL,restL,smooth((t-12.75)/.8));}
      dc.update(pose(l,r,ms,noise));
      if(f%15==0)trace.append(String.format(Locale.ROOT,"t=%.1f cursor=%d,%d state=%s R[eng=%s ext=%.2f prog=%.2f] L[eng=%s]%n",t,rec.x,rec.y,dc.gestureKey(),dc.rightHand.engaged,dc.rightHand.extent,dc.rightHand.pressProgress,dc.leftHand.engaged));
    }
    if(Boolean.getBoolean("trace"))System.out.print(trace);
    for(String s:rec.log)if(!s.contains("wheel"))System.out.println(s);
    // ---- expectations for the scripted mouse sequence
    ArrayList<String> fails=new ArrayList<String>();int wheelUp=0;ArrayList<String> btn=new ArrayList<String>();
    for(String s:rec.log){if(s.contains("wheel")){if(s.endsWith(" -1")||s.contains("wheel -"))wheelUp++;}else btn.add(s.substring(s.indexOf(' ')+1));}
    System.out.println("scroll-up notches: "+wheelUp);
    String[] want={"Ldown","Lup","Rdown","Rup","Ldown","Lup","Ldown","Lup","Ldown","Lup"};
    if(btn.size()!=want.length)fails.add("expected "+want.length+" button events, got "+btn.size());
    else{for(int i=0;i<want.length;i++)if(!btn.get(i).startsWith(want[i]))fails.add("event "+i+" is "+btn.get(i)+", expected "+want[i]);
      if(!btn.get(0).substring(btn.get(0).indexOf('@')).equals(btn.get(1).substring(btn.get(1).indexOf('@'))))fails.add("click moved between press and release");
      if(btn.get(4).substring(btn.get(4).indexOf('@')).equals(btn.get(5).substring(btn.get(5).indexOf('@'))))fails.add("drag did not move");}
    if(wheelUp<5)fails.add("scroll gesture produced "+wheelUp+" notches");
    // jitter while hovering still (cursor std-dev, px)
    rec.log.clear();ArrayList<int[]> pts=new ArrayList<int[]>();
    for(int f=0;f<90;f++){long ms=20000+f*33;rec.t=ms;dc.clockOverride=ms;dc.update(pose(restL,hoverR,ms,noise));if(f>30)pts.add(new int[]{rec.x,rec.y});}
    double mx=0,my=0;for(int[] p:pts){mx+=p[0];my+=p[1];}mx/=pts.size();my/=pts.size();double vx=0,vy=0;for(int[] p:pts){vx+=(p[0]-mx)*(p[0]-mx);vy+=(p[1]-my)*(p[1]-my);}
    System.out.printf(Locale.ROOT,"hover jitter: sd x=%.2f px y=%.2f px (noise %.1f mm)  spurious events=%d%n",Math.sqrt(vx/pts.size()),Math.sqrt(vy/pts.size()),noise*1000,rec.log.size());

    // ---- keyboard: two hands typing
    rec.log.clear();dc.keyboardVisible=true;dc.keyboard.layout(1100,396);dc.leftHand.reset();dc.rightHand.reset();
    String target=System.getProperty("text","ola mundo");
    long t0=30000;int typed=0;
    // Aim: find hand position for a key by inverting the zone map numerically.
    for(int ci=0;ci<target.length();ci++){char c=target.charAt(ci);String ks=c==' '?null:String.valueOf(c);
      SynKinectStudio.VirtualKey key=null;for(ArrayList<SynKinectStudio.VirtualKey> row:dc.keyboard.rows())for(SynKinectStudio.VirtualKey k:row){if(ks==null?k.type==SynKinectStudio.VirtualKey.SPACE:(k.type==0&&k.text.equals(ks)))key=k;}
      if(key==null)continue;float kx=(key.x+key.w/2)/dc.keyboard.width,ky=(key.y+key.h/2-dc.keyboard.headerH)/(dc.keyboard.height-dc.keyboard.headerH);
      boolean useLeft=kx<.5f;PVector sh=useLeft?LSH:RSH;
      // invert: nx = .5 + (lateral - side*outward*L)/(w) + offset
      float L=dc.frame.armLength,side=useLeft?-1:1,w=cfg.zoneWidthArm*L*cfg.keyboardZoneScale,h=cfg.zoneHeightArm*L,off=useLeft?-cfg.keyboardSideOffset:cfg.keyboardSideOffset;
      double lateral=(kx-.5-off)*w+side*cfg.zoneOutwardArm*L,vertical=cfg.zoneTopArm*L-ky*h;
      PVector hover=off(sh,lateral,vertical,.32),push=off(sh,lateral,vertical-.02,.44);
      for(int f=0;f<28;f++){long ms=t0+f*33;rec.t=ms;dc.clockOverride=ms;
        PVector hnd=f<12?hover:lerp(hover,push,f<16?smooth((f-12)/4.0):(f<20?1-smooth((f-16)/4.0):0));
        PVector other=useLeft?restR:restL;dc.update(useLeft?pose(hnd,other,ms,noise):pose(other,hnd,ms,noise));
        if(Boolean.getBoolean("ktrace")){SynKinectStudio.InteractionHand hh=useLeft?dc.leftHand:dc.rightHand;System.out.printf(Locale.ROOT,"  %c f=%d eng=%s ext=%.2f base=%.2f prog=%.2f pressed=%s hover=%s%n",c,f,hh.engaged,hh.extent,hh.baseline,hh.pressProgress,hh.pressed,dc.keyboard.hover[useLeft?0:1]==null?"-":dc.keyboard.label(dc.keyboard.hover[useLeft?0:1]));}}
      t0+=28*33;
    }
    StringBuilder out=new StringBuilder();for(String s:rec.log){if(s.contains(" key ")){String k=s.substring(s.indexOf(" key ")+5);out.append(k.equals("Space")?" ":k.toLowerCase(Locale.ROOT));}}
    System.out.println("keyboard typed: \""+out+"\"  (target \""+target+"\")  events="+rec.log.size());
    if(!out.toString().equals(target))fails.add("typed text differs");
    System.out.println(fails.isEmpty()?"RESULT: PASS":"RESULT: FAIL "+fails);
    // render the overlay (offscreen) for a visual check
    int W=1100,H=396;java.awt.image.BufferedImage img=new java.awt.image.BufferedImage(W+40,H+40,java.awt.image.BufferedImage.TYPE_INT_ARGB);
    java.awt.Graphics2D g=img.createGraphics();g.setColor(new java.awt.Color(0x2a,0x33,0x3d));g.fillRect(0,0,W+40,H+40);g.translate(20,20);
    SynKinectStudio.VirtualKeyboardModel m=dc.keyboard;m.layout(W,H);
    SynKinectStudio.VirtualKey kl=m.rows().get(2).get(3),kr=m.rows().get(1).get(7);
    m.visible[0]=m.visible[1]=true;m.hover[0]=kl;m.hover[1]=kr;m.cx[0]=kl.x+kl.w*.6f;m.cy[0]=kl.y+kl.h*.4f;m.cx[1]=kr.x+kr.w*.4f;m.cy[1]=kr.y+kr.h*.55f;m.progress[0]=.35f;m.progress[1]=.8f;m.shift=true;
    dc.keyboardWindow.paintKeyboard(g,W,H);g.dispose();javax.imageio.ImageIO.write(img,"png",new java.io.File(System.getProperty("png.dir","."),"virtual-keyboard.png"));
    m.symbolLayer=true;m.shift=false;img=new java.awt.image.BufferedImage(W+40,H+40,java.awt.image.BufferedImage.TYPE_INT_ARGB);g=img.createGraphics();g.setColor(new java.awt.Color(0x2a,0x33,0x3d));g.fillRect(0,0,W+40,H+40);g.translate(20,20);
    dc.keyboardWindow.paintKeyboard(g,W,H);g.dispose();javax.imageio.ImageIO.write(img,"png",new java.io.File(System.getProperty("png.dir","."),"virtual-keyboard-symbols.png"));
    System.exit(0);
  }
}
