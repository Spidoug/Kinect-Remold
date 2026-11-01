// ===== SynKinect Studio / Interactivity / hand controls and virtual keyboard =====
//
// Input model inspired by the Kinect for Windows SDK interaction stream:
//  * every hand owns a physical interaction zone anchored at ITS shoulder and scaled
//    by the user's arm length, so both hands are equally usable and the mapping is
//    the same for tall and short users and at any distance from the sensor;
//  * "press" is a relative push toward the screen (an adaptive baseline absorbs slow
//    drift), with hysteresis and a click lock that freezes the pointer while the
//    hand is pushing, so a click lands exactly where the user aimed;
//  * pointer smoothing is a One-Euro filter (steady when hovering, no lag when moving).
// Two hands are tracked independently: in mouse mode the second hand adds right
// click, double click and scrolling; in keyboard mode each hand has its own cursor
// and both can type on the on-screen keyboard at the same time.
// Everything is plain Java/AWT/Swing: no external libraries.

interface InteractionInputSink {
  boolean available();
  String error();
  java.awt.Rectangle bounds();
  void move(int x,int y);
  void button(int awtMask,boolean down);
  void wheel(int notches);
  void key(int vk,boolean down);
  void pasteText(String text);
}

class RobotInputSink implements InteractionInputSink {
  java.awt.Robot robot;java.awt.Rectangle desktop;String error="";
  final boolean mac=System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("mac");
  RobotInputSink(){
    try{if(GraphicsEnvironment.isHeadless())throw new AWTException("headless");robot=new java.awt.Robot();robot.setAutoDelay(0);desktop=computeBounds();}
    catch(Exception e){error=safeStudioMessage(e);robot=null;desktop=new java.awt.Rectangle(0,0,1,1);}
  }
  java.awt.Rectangle computeBounds(){java.awt.Rectangle all=null;for(GraphicsDevice gd:GraphicsEnvironment.getLocalGraphicsEnvironment().getScreenDevices()){java.awt.Rectangle b=gd.getDefaultConfiguration().getBounds();
      all=all==null?new java.awt.Rectangle(b):all.union(b);}return all==null?new java.awt.Rectangle(0,0,1920,1080):all;}
  public boolean available(){return robot!=null;}
  public String error(){return error;}
  public java.awt.Rectangle bounds(){return desktop;}
  public void move(int x,int y){if(robot==null)return;try{robot.mouseMove(x,y);error="";}catch(Exception e){error=safeStudioMessage(e);}}
  public void button(int mask,boolean down){if(robot==null)return;try{if(down)robot.mousePress(mask);else robot.mouseRelease(mask);}catch(Exception e){error=safeStudioMessage(e);}}
  public void wheel(int n){if(robot==null||n==0)return;try{robot.mouseWheel(n);}catch(Exception e){error=safeStudioMessage(e);}}
  public void key(int vk,boolean down){if(robot==null)return;try{if(down)robot.keyPress(vk);else robot.keyRelease(vk);}catch(Exception e){error=safeStudioMessage(e);}}
  // Characters without a layout-independent key code (accents, ç, symbols) are typed
  // through the clipboard; the previous text clipboard content is restored afterwards.
  public void pasteText(final String text){
    if(robot==null||text==null||text.isEmpty())return;
    try{
      final java.awt.datatransfer.Clipboard cb=java.awt.Toolkit.getDefaultToolkit().getSystemClipboard();
      String previous=null;try{if(cb.isDataFlavorAvailable(java.awt.datatransfer.DataFlavor.stringFlavor))previous=(String)cb.getData(java.awt.datatransfer.DataFlavor.stringFlavor);}catch(Exception ignored){}
      cb.setContents(new java.awt.datatransfer.StringSelection(text),null);
      int mod=mac?KeyEvent.VK_META:KeyEvent.VK_CONTROL;robot.keyPress(mod);robot.keyPress(KeyEvent.VK_V);robot.keyRelease(KeyEvent.VK_V);robot.keyRelease(mod);
      final String restore=previous;
      if(restore!=null){Thread t=new Thread(new Runnable(){public void run(){try{Thread.sleep(250);cb.setContents(new java.awt.datatransfer.StringSelection(restore),null);}catch(Exception ignored){}}},"vk-clipboard-restore");t.setDaemon(true);t.start();}
    }catch(Exception e){error=safeStudioMessage(e);}
  }
}

class InteractionOneEuro {
  final float minCutoff,beta,dCutoff;float x=Float.NaN,dx=0;long t=0;
  InteractionOneEuro(float minCutoff,float beta,float dCutoff){this.minCutoff=minCutoff;this.beta=beta;this.dCutoff=dCutoff;}
  void reset(){x=Float.NaN;dx=0;t=0;}
  float filter(float v,long now){
    if(Float.isNaN(x)||t==0||now-t>400){x=v;dx=0;t=now;return v;}
    float dt=max(.004f,(now-t)/1000.0f);t=now;float d=(v-x)/dt;dx+=alpha(dt,dCutoff)*(d-dx);
    x+=alpha(dt,minCutoff+beta*abs(dx))*(v-x);return x;
  }
  float alpha(float dt,float cutoff){float tau=1.0f/(TWO_PI*max(.01f,cutoff));return 1.0f/(1.0f+tau/dt);}
}

// Stable body-aligned frame: right = user's right, up, toward = toward the sensor.
class InteractionBodyFrame {
  final PVector right=new PVector(-1,0,0),up=new PVector(0,-1,0),toward=new PVector(0,0,-1);
  float armLength=.58f;boolean ready=false;
  boolean update(SkeletonPose3D s){
    if(s==null||!s.torsoTracked())return false;
    PVector r=PVector.sub(s.rightShoulder.world,s.leftShoulder.world);if(r.mag()<.05f)return false;r.normalize();
    PVector u=PVector.sub(s.shoulderCenter.world,s.hipCenter.world);if(u.mag()<.08f)return false;u.normalize();
    u.sub(PVector.mult(r,u.dot(r)));if(u.mag()<.2f)return false;u.normalize();
    PVector t=u.cross(r);t.normalize();
    // Torso yaw is followed smoothly; a hand gesture never rotates the frame.
    if(!ready){right.set(r);up.set(u);toward.set(t);ready=true;}
    else{float a=.18f;right.lerp(r,a);up.lerp(u,a);right.normalize();up.sub(PVector.mult(right,up.dot(right)));up.normalize();PVector nt=up.cross(right);nt.normalize();toward.set(nt);}
    float arm=0;int n=0;
    if(s.leftElbow.tracked()&&s.leftWrist.tracked()){arm+=PVector.dist(s.leftShoulder.world,s.leftElbow.world)+PVector.dist(s.leftElbow.world,s.leftWrist.world);n++;}
    if(s.rightElbow.tracked()&&s.rightWrist.tracked()){arm+=PVector.dist(s.rightShoulder.world,s.rightElbow.world)+PVector.dist(s.rightElbow.world,s.rightWrist.world);n++;}
    if(n>0){arm/=n;if(arm>.30f&&arm<.95f)armLength=lerp(armLength,arm,.05f);}
    return true;
  }
  void reset(){ready=false;}
}

class InteractionHand {
  final boolean left;final InteractionConfig cfg;
  final InteractionOneEuro fx,fy;
  boolean tracked=false,engaged=false,pressed=false,justPressed=false,justReleased=false,locked=false;
  float nx=.5f,ny=.5f,rawX=.5f,rawY=.5f,lockX=.5f,lockY=.5f,extent=0,baseline=Float.NaN,pressProgress=0,lastDelta=0,lateral=0,vertical=0;
  long lastSeenMs=0,pressCandidateSince=0,pressStartMs=0,lastUpdateMs=0,engagedSince=0,releaseHoldUntil=0;
  final float[] mLat=new float[24],mVert=new float[24],mFwd=new float[24];final long[] mT=new long[24];int mN=0,mHead=0;
  final float[] histX=new float[16],histY=new float[16];final long[] histT=new long[16];int histN=0,histHead=0;
  final PVector world=new PVector();
  InteractionHand(boolean left,InteractionConfig cfg){this.left=left;this.cfg=cfg;fx=new InteractionOneEuro(cfg.pointerMinCutoff,cfg.pointerBeta,cfg.pointerDCutoff);fy=new InteractionOneEuro(cfg.pointerMinCutoff,cfg.pointerBeta,cfg.pointerDCutoff);}
  void reset(){tracked=engaged=pressed=justPressed=justReleased=locked=false;baseline=Float.NaN;pressProgress=0;pressCandidateSince=0;fx.reset();fy.reset();histN=0;mN=0;}
  // mapOffset shifts the zone centre in normalised output units (keyboard mode).
  void update(SkeletonPose3D s,SkeletonJoint3D joint,InteractionBodyFrame f,long now,float mapOffset,float widthScale){
    justPressed=justReleased=false;
    float dt=lastUpdateMs==0?.033f:constrain((now-lastUpdateMs)/1000.0f,.004f,.25f);lastUpdateMs=now;
    SkeletonJoint3D shoulder=left?s.leftShoulder:s.rightShoulder;
    if(joint==null||!joint.observed()||joint.confidence<cfg.cursorMinHandConfidence||shoulder==null||!shoulder.tracked()){
      tracked=false;engaged=false;
      if(pressed&&now-lastSeenMs>cfg.cursorLostReleaseMs){pressed=false;justReleased=true;locked=false;}
      return;}
    tracked=true;lastSeenMs=now;world.set(joint.world);
    float L=max(.30f,f.armLength),side=left?-1:1;
    PVector rel=PVector.sub(joint.world,shoulder.world);
    lateral=rel.dot(f.right);vertical=rel.dot(f.up);extent=rel.dot(f.toward)/L;
    float w=cfg.zoneWidthArm*L*widthScale,h=cfg.zoneHeightArm*L,centre=side*cfg.zoneOutwardArm*L,top=cfg.zoneTopArm*L;
    rawX=.5f+(lateral-centre)/w+mapOffset;rawY=(top-vertical)/h;
    if(cfg.mirrorX)rawX=1-rawX;
    // Engagement: the hand is raised in front of the body (SDK "active hand").
    boolean inHeight=vertical>-cfg.engageBelowShoulderArm*L&&vertical<cfg.engageAboveShoulderArm*L;
    if(!engaged)engaged=inHeight&&extent>=cfg.engageForwardArm;
    else engaged=inHeight&&extent>=cfg.engageForwardArm-.06f;
    if(!engaged&&!pressed){baseline=Float.NaN;pressProgress=0;lastDelta=0;locked=false;pressCandidateSince=0;fx.reset();fy.reset();histN=0;mN=0;return;}
    float px=fx.filter(rawX*1000.0f,now)/1000.0f,py=fy.filter(rawY*1000.0f,now)/1000.0f;
    if(Float.isNaN(baseline)){baseline=extent;engagedSince=now;}
    // A press is a push along the pointing axis: while the hand is still being raised
    // or is moving across the zone, the baseline follows it (no accidental clicks).
    float[] past=motionAgo(now,cfg.pressDirectionWindowMs);
    float dFwd=past==null?0:(extent*L-past[2]),dPlanar=past==null?0:dist(lateral,vertical,past[0],past[1]);
    boolean settling=now-engagedSince<cfg.engageSettleMs,sideways=dPlanar>max(.03f,abs(dFwd)*cfg.pressDirectionRatio);
    if(!pressed){
      if(settling)baseline=extent;
      else{float tau=extent<baseline?cfg.pressBaselineFallS:(sideways?cfg.pressBaselineSidewaysS:cfg.pressBaselineRiseS);baseline+=(extent-baseline)*(1-exp(-dt/max(.02f,tau)));}
    }
    rememberMotion(now,lateral,vertical,extent*L);
    float delta=extent-baseline;pressProgress=constrain(delta/cfg.pressDeltaArm,0,1);
    if(!pressed){
      if(delta>cfg.pressDeltaArm*cfg.pressLockFraction){if(!locked){locked=true;float[] at=positionAgo(now,cfg.pressLockLookbackMs,px,py);lockX=at[0];lockY=at[1];}}
      else if(delta<cfg.pressDeltaArm*cfg.pressLockFraction*.5f)locked=false;
      // A push that approached the plane continuously is accepted at once; a jump from
      // rest (a depth spike) must still be past the plane after pressStableMs.
      boolean confirm=false;
      if(delta>=cfg.pressDeltaArm&&lastDelta>=cfg.pressDeltaArm*.4f)confirm=true;
      else if(pressCandidateSince==0){if(delta>=cfg.pressDeltaArm)pressCandidateSince=now;}
      else if(delta<cfg.pressDeltaArm*.55f)pressCandidateSince=0;
      else if(now-pressCandidateSince>=cfg.pressStableMs&&delta>=cfg.pressDeltaArm*.7f)confirm=true;
      if(confirm){pressed=true;justPressed=true;pressStartMs=now;pressCandidateSince=0;}
    }else{
      if(delta<=cfg.pressReleaseArm){pressed=false;justReleased=true;if(locked)releaseHoldUntil=now+cfg.pressReleaseHoldMs;locked=false;baseline=extent;}
      else if(locked&&dist(px,py,lockX,lockY)>cfg.pressDragUnlock)locked=false; // deliberate motion while pressed = drag
    }
    lastDelta=pressed?cfg.pressDeltaArm:delta;remember(now,px,py);
    // the pointer stays on the click target while the hand is pulled back
    if(locked||now<releaseHoldUntil){nx=lockX;ny=lockY;}else{nx=px;ny=py;}
  }
  void rememberMotion(long now,float la,float ve,float fw){mLat[mHead]=la;mVert[mHead]=ve;mFwd[mHead]=fw;mT[mHead]=now;mHead=(mHead+1)%mLat.length;mN=min(mN+1,mLat.length);}
  float[] motionAgo(long now,long ms){float[] r=null;for(int k=1;k<=mN;k++){int i=(mHead-k+mLat.length)%mLat.length;r=new float[]{mLat[i],mVert[i],mFwd[i]};if(now-mT[i]>=ms)break;}return r;}
  void remember(long now,float x,float y){histX[histHead]=x;histY[histHead]=y;histT[histHead]=now;histHead=(histHead+1)%histX.length;histN=min(histN+1,histX.length);}
  float[] positionAgo(long now,long ms,float fallbackX,float fallbackY){
    float bx=fallbackX,by=fallbackY;for(int k=1;k<=histN;k++){int i=(histHead-k+histX.length)%histX.length;bx=histX[i];by=histY[i];if(now-histT[i]>=ms)break;}
    return new float[]{bx,by};
  }
  boolean inside(){return nx>=-.02f&&nx<=1.02f&&ny>=-.02f&&ny<=1.02f;}
}

// ---------------------------------------------------------------- virtual keyboard
class VirtualKey {
  static final int CHAR=0,BACKSPACE=1,ENTER=2,SPACE=3,SHIFT=4,LAYER=5,LEFT=6,RIGHT=7,CLOSE=8,TAB=9;
  final int type;final String text;final float units;float x,y,w,h;
  VirtualKey(int type,String text,float units){this.type=type;this.text=text;this.units=units;}
  boolean repeatable(){return type==BACKSPACE||type==LEFT||type==RIGHT||type==SPACE||type==CHAR;}
}

class VirtualKeyboardModel {
  final InteractionInputSink sink;final ModuleI18n i18n;
  final ArrayList<ArrayList<VirtualKey>> letters=new ArrayList<ArrayList<VirtualKey>>(),symbols=new ArrayList<ArrayList<VirtualKey>>();
  boolean symbolLayer=false,shift=false,caps=false;long lastShiftMs=0;
  float width=1000,height=340,pad=14,headerH=30;
  // per hand: 0 = left, 1 = right
  final VirtualKey[] hover=new VirtualKey[2],active=new VirtualKey[2];final float[] cx={-1,-1},cy={-1,-1},progress=new float[2];final boolean[] visible=new boolean[2],down=new boolean[2];
  final long[] hoverSince=new long[2],activeSince=new long[2],lastRepeat=new long[2];final boolean[] dwellFired=new boolean[2];
  VirtualKey flashKey=null;long flashUntil=0;int typedCount=0;boolean closeRequested=false;
  VirtualKeyboardModel(InteractionInputSink sink,ModuleI18n i18n){this.sink=sink;this.i18n=i18n;build();}
  ArrayList<VirtualKey> row(Object... spec){ArrayList<VirtualKey> r=new ArrayList<VirtualKey>();for(Object o:spec){if(o instanceof VirtualKey)r.add((VirtualKey)o);else r.add(new VirtualKey(VirtualKey.CHAR,(String)o,1));}return r;}
  VirtualKey k(int type,float units){return new VirtualKey(type,"",units);}
  void build(){
    letters.add(row("1","2","3","4","5","6","7","8","9","0",k(VirtualKey.BACKSPACE,1.6f)));
    letters.add(row(k(VirtualKey.TAB,1.3f),"q","w","e","r","t","y","u","i","o","p"));
    letters.add(row(k(VirtualKey.SHIFT,1.6f),"a","s","d","f","g","h","j","k","l","ç"));
    letters.add(row(k(VirtualKey.LAYER,1.6f),"z","x","c","v","b","n","m",",",".",k(VirtualKey.ENTER,1.6f)));
    letters.add(row(k(VirtualKey.CLOSE,1.3f),k(VirtualKey.LEFT,1),k(VirtualKey.RIGHT,1),k(VirtualKey.SPACE,5.2f),"-","?","!"));
    symbols.add(row("á","à","â","ã","é","ê","í","ó","ô","õ",k(VirtualKey.BACKSPACE,1.6f)));
    symbols.add(row(k(VirtualKey.TAB,1.3f),"ú","ü","@","#","$","%","&","*","(",")"));
    symbols.add(row(k(VirtualKey.SHIFT,1.6f),"+","=","/","\\",":",";","\"","'","_","~"));
    symbols.add(row(k(VirtualKey.LAYER,1.6f),"<",">","[","]","{","}","|","ª","º",k(VirtualKey.ENTER,1.6f)));
    symbols.add(row(k(VirtualKey.CLOSE,1.3f),k(VirtualKey.LEFT,1),k(VirtualKey.RIGHT,1),k(VirtualKey.SPACE,5.2f),"-","?","!"));
  }
  ArrayList<ArrayList<VirtualKey>> rows(){return symbolLayer?symbols:letters;}
  synchronized void layout(float w,float h){
    width=w;height=h;pad=max(8,w*.012f);headerH=max(22,h*.085f);float gap=max(4,w*.006f);
    int nRows=letters.size();float rowH=(h-headerH-pad*2-gap*(nRows-1))/nRows;
    for(int li=0;li<2;li++){ArrayList<ArrayList<VirtualKey>> layer=li==0?letters:symbols;for(int r=0;r<layer.size();r++){ArrayList<VirtualKey> row=layer.get(r);float units=0;for(VirtualKey key:row)units+=key.units;
      float unitW=(w-pad*2-gap*(row.size()-1))/units,x=pad,y=headerH+pad+r*(rowH+gap);
      for(VirtualKey key:row){key.x=x;key.y=y;key.w=unitW*key.units;key.h=rowH;x+=key.w+gap;}}}
  }
  synchronized VirtualKey keyAt(float x,float y){for(ArrayList<VirtualKey> row:rows())for(VirtualKey key:row)if(x>=key.x&&x<=key.x+key.w&&y>=key.y&&y<=key.y+key.h)return key;return null;}
  // Nearest key when slightly outside the grid: small hand noise at the border still types.
  synchronized VirtualKey nearestKey(float x,float y,float maxDist){VirtualKey best=null;float bd=maxDist;for(ArrayList<VirtualKey> row:rows())for(VirtualKey key:row){float dx=max(0,max(key.x-x,x-(key.x+key.w))),dy=max(0,max(key.y-y,y-(key.y+key.h))),d=sqrt(dx*dx+dy*dy);if(d<bd){bd=d;best=key;}}return best;}
  String label(VirtualKey key){
    switch(key.type){
      case VirtualKey.BACKSPACE:return "⌫";case VirtualKey.ENTER:return "↵";case VirtualKey.SPACE:return i18n.tr("keyboard.space");
      case VirtualKey.SHIFT:return caps?"⇪":"⇧";case VirtualKey.LAYER:return symbolLayer?"abc":"?123 áé";case VirtualKey.LEFT:return "←";case VirtualKey.RIGHT:return "→";
      case VirtualKey.CLOSE:return i18n.tr("keyboard.close");case VirtualKey.TAB:return "⇥";
      default:return upper()?key.text.toUpperCase(Locale.ROOT):key.text;}
  }
  boolean upper(){return shift^caps;}
  // Executes one key. Returns true when it produced text/navigation output.
  synchronized boolean activate(VirtualKey key,long now,boolean repeat){
    if(key==null)return false;flashKey=key;flashUntil=now+160;
    switch(key.type){
      case VirtualKey.SHIFT:if(repeat)return false;if(now-lastShiftMs<450){caps=!caps;shift=false;}else shift=!shift;lastShiftMs=now;return false;
      case VirtualKey.LAYER:if(repeat)return false;symbolLayer=!symbolLayer;return false;
      case VirtualKey.CLOSE:if(repeat)return false;closeRequested=true;return false;
      case VirtualKey.BACKSPACE:tap(KeyEvent.VK_BACK_SPACE);break;
      case VirtualKey.ENTER:if(repeat)return false;tap(KeyEvent.VK_ENTER);break;
      case VirtualKey.TAB:if(repeat)return false;tap(KeyEvent.VK_TAB);break;
      case VirtualKey.SPACE:tap(KeyEvent.VK_SPACE);break;
      case VirtualKey.LEFT:tap(KeyEvent.VK_LEFT);break;
      case VirtualKey.RIGHT:tap(KeyEvent.VK_RIGHT);break;
      default:typeText(upper()?key.text.toUpperCase(Locale.ROOT):key.text);if(shift&&!repeat)shift=false;
    }
    typedCount++;return true;
  }
  void tap(int vk){sink.key(vk,true);sink.key(vk,false);}
  void typeText(String t){
    if(t.length()==1){char c=t.charAt(0);
      if(c>='a'&&c<='z'){tap(KeyEvent.VK_A+(c-'a'));return;}
      if(c>='A'&&c<='Z'){sink.key(KeyEvent.VK_SHIFT,true);tap(KeyEvent.VK_A+(c-'A'));sink.key(KeyEvent.VK_SHIFT,false);return;}
      if(c>='0'&&c<='9'){tap(KeyEvent.VK_0+(c-'0'));return;}}
    sink.pasteText(t); // layout-independent for accents and symbols
  }
}

// Always-on-top, never-focused overlay window: typing goes to the application that
// already has keyboard focus, exactly like an OS on-screen keyboard.
class VirtualKeyboardWindow {
  final VirtualKeyboardModel model;final float widthFraction;JWindow window;JComponent canvas;volatile boolean shown=false;boolean translucent=false;String error="";
  final java.awt.Color BG=new java.awt.Color(0x11,0x15,0x1A,236),KEY=new java.awt.Color(0x20,0x28,0x32),KEY_ALT=new java.awt.Color(0x29,0x34,0x40),BORDER=new java.awt.Color(0x35,0x41,0x4D),
    TEXT=new java.awt.Color(0xF4,0xF7,0xFA),MUTED=new java.awt.Color(0xAA,0xB6,0xC2),RIGHT=new java.awt.Color(0x68,0xA9,0xE8),LEFT=new java.awt.Color(0xFF,0xB5,0x4A),FLASH=new java.awt.Color(0x28,0x50,0x6E);
  VirtualKeyboardWindow(VirtualKeyboardModel model,float widthFraction){this.model=model;this.widthFraction=widthFraction;}
  boolean supported(){return !GraphicsEnvironment.isHeadless();}
  void setVisible(final boolean on){
    if(!supported()){error="headless";return;}
    if(on==shown)return;shown=on;
    SwingUtilities.invokeLater(new Runnable(){public void run(){try{
      if(on){if(window==null)create();place();window.setVisible(true);window.toFront();}
      else if(window!=null)window.setVisible(false);
    }catch(Exception e){error=safeStudioMessage(e);shown=false;}}});
  }
  void create(){
    window=new JWindow();window.setType(java.awt.Window.Type.UTILITY);window.setAlwaysOnTop(true);window.setFocusableWindowState(false);window.setAutoRequestFocus(false);
    try{GraphicsDevice gd=GraphicsEnvironment.getLocalGraphicsEnvironment().getDefaultScreenDevice();
      translucent=gd.isWindowTranslucencySupported(GraphicsDevice.WindowTranslucency.PERPIXEL_TRANSLUCENT);
      if(translucent)window.setBackground(new java.awt.Color(0,0,0,0));}catch(Exception ignored){translucent=false;}
    canvas=new JComponent(){protected void paintComponent(java.awt.Graphics g){paintKeyboard((java.awt.Graphics2D)g,getWidth(),getHeight());}};
    canvas.setOpaque(!translucent);
    // The physical mouse can type too (useful to test or as a fallback).
    canvas.addMouseListener(new java.awt.event.MouseAdapter(){public void mousePressed(java.awt.event.MouseEvent e){VirtualKey k=model.keyAt(e.getX(),e.getY());if(k!=null){model.activate(k,millis64(),false);canvas.repaint();}}});
    window.setContentPane(canvas);
  }
  void place(){
    java.awt.Rectangle b=GraphicsEnvironment.getLocalGraphicsEnvironment().getMaximumWindowBounds();
    int w=round(min(1280,b.width*widthFraction)),h=round(w*.36f);
    window.setBounds(b.x+(b.width-w)/2,b.y+b.height-h-18,w,h);model.layout(w,h);
  }
  void repaint(){if(canvas!=null&&shown)canvas.repaint();}
  // Maps a normalised hand position to keyboard pixel coordinates.
  float keyboardX(float nx){return nx*model.width;}
  float keyboardY(float ny){return model.headerH+ny*(model.height-model.headerH);}
  void paintKeyboard(java.awt.Graphics2D g,int w,int h){
    if(abs(model.width-w)>.5f||abs(model.height-h)>.5f)model.layout(w,h);
    g.setRenderingHint(java.awt.RenderingHints.KEY_ANTIALIASING,java.awt.RenderingHints.VALUE_ANTIALIAS_ON);
    g.setRenderingHint(java.awt.RenderingHints.KEY_TEXT_ANTIALIASING,java.awt.RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
    if(translucent){g.setComposite(java.awt.AlphaComposite.Clear);g.fillRect(0,0,w,h);g.setComposite(java.awt.AlphaComposite.SrcOver);}
    int arc=round(max(10,w*.012f));
    g.setColor(BG);g.fillRoundRect(0,0,w-1,h-1,arc*2,arc*2);g.setColor(BORDER);g.drawRoundRect(0,0,w-1,h-1,arc*2,arc*2);
    long now=millis64();
    synchronized(model){
      java.awt.Font base=new java.awt.Font(java.awt.Font.SANS_SERIF,java.awt.Font.PLAIN,max(11,round(model.headerH*.46f)));
      g.setFont(base);g.setColor(MUTED);java.awt.FontMetrics fm=g.getFontMetrics();
      g.drawString(model.i18n.tr("keyboard.title")+"  ·  "+model.i18n.tr("keyboard.hint"),round(model.pad),round(model.headerH*.5f+fm.getAscent()*.5f+model.pad*.35f));
      // accent strip on the left, like the Studio panels
      g.setColor(RIGHT);g.fillRoundRect(0,round(model.pad),4,round(model.headerH),3,3);
      java.awt.Font keyFont=new java.awt.Font(java.awt.Font.SANS_SERIF,java.awt.Font.BOLD,max(12,round(model.rows().get(1).get(1).h*.40f)));
      for(ArrayList<VirtualKey> row:model.rows())for(VirtualKey key:row){
        int kx=round(key.x),ky=round(key.y),kw=round(key.w),kh=round(key.h),r=round(min(kw,kh)*.18f);
        boolean special=key.type!=VirtualKey.CHAR;boolean flash=key==model.flashKey&&now<model.flashUntil;
        g.setColor(flash?FLASH:(special?KEY_ALT:KEY));g.fillRoundRect(kx,ky,kw,kh,r,r);
        boolean hl=false,hr=false;for(int hnd=0;hnd<2;hnd++)if(model.visible[hnd]&&model.hover[hnd]==key){if(hnd==0)hl=true;else hr=true;}
        if(key.type==VirtualKey.SHIFT&&(model.shift||model.caps)){g.setColor(RIGHT);g.fillRoundRect(kx,ky+kh-4,kw,4,2,2);}
        if(key.type==VirtualKey.LAYER&&model.symbolLayer){g.setColor(RIGHT);g.fillRoundRect(kx,ky+kh-4,kw,4,2,2);}
        g.setStroke(new java.awt.BasicStroke(hl||hr?2.4f:1f));g.setColor(hr?RIGHT:(hl?LEFT:BORDER));g.drawRoundRect(kx,ky,kw,kh,r,r);
        if(hl&&hr){g.setColor(LEFT);g.drawRoundRect(kx+3,ky+3,kw-6,kh-6,r,r);}
        String lbl=model.label(key);java.awt.Font f=special&&lbl.length()>2?base:keyFont;g.setFont(f);java.awt.FontMetrics km=g.getFontMetrics();
        g.setColor(TEXT);g.drawString(lbl,kx+(kw-km.stringWidth(lbl))/2,ky+(kh+km.getAscent()-km.getDescent())/2);
      }
      // hand cursors with push progress rings
      for(int hnd=0;hnd<2;hnd++){if(!model.visible[hnd])continue;java.awt.Color c=hnd==0?LEFT:RIGHT;float x=model.cx[hnd],y=model.cy[hnd];int rr=round(max(9,w*.011f));
        g.setColor(new java.awt.Color(c.getRed(),c.getGreen(),c.getBlue(),model.down[hnd]?230:170));g.fillOval(round(x-rr*.45f),round(y-rr*.45f),round(rr*.9f),round(rr*.9f));
        g.setStroke(new java.awt.BasicStroke(3f));g.setColor(new java.awt.Color(c.getRed(),c.getGreen(),c.getBlue(),90));g.drawOval(round(x-rr),round(y-rr),rr*2,rr*2);
        g.setColor(c);g.drawArc(round(x-rr),round(y-rr),rr*2,rr*2,90,-round(360*constrain(model.progress[hnd],0,1)));
        g.setFont(base);g.setColor(c);g.drawString(model.i18n.tr(hnd==0?"keyboard.hand_left_short":"keyboard.hand_right_short"),round(x+rr+3),round(y-rr*.4f));}
    }
  }
}
