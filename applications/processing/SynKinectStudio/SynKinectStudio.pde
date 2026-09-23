import java.io.*;
import java.nio.*;
import java.net.*;
import java.nio.channels.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.text.SimpleDateFormat;
import javax.imageio.*;
import javax.imageio.stream.*;
import javax.imageio.plugins.jpeg.JPEGImageWriteParam;
import javax.sound.sampled.*;
import java.awt.image.BufferedImage;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.Robot;
import java.awt.Rectangle;
import java.awt.GraphicsDevice;
import java.awt.GraphicsEnvironment;
import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.awt.AWTException;
import com.jogamp.newt.opengl.GLWindow;
import com.jogamp.newt.event.WindowAdapter;
import com.jogamp.newt.event.WindowEvent;
import com.jogamp.nativewindow.WindowClosingProtocol;


// ===== SynKinect Studio unified application =====
final int STUDIO_TOP_BAR_H=50;
final int STUDIO_MIN_WIDTH=1440;
final int STUDIO_MIN_HEIGHT=900;

final int STUDIO_FONT_TINY=13;
final int STUDIO_FONT_SMALL=15;
final int STUDIO_FONT_BODY=16;
final int STUDIO_FONT_LABEL=16;
final int STUDIO_FONT_METRIC=21;
final int STUDIO_FONT_TITLE=29;
final int STUDIO_FONT_BUTTON=16;

// Processing requires one PApplet host, but the Studio runtime itself is a normal
// object graph. Every controller owns its services, configuration, module states
// and lifecycle; no module depends on process-wide mutable singletons.
StudioController studio=null;
PFont studioUnicodeRegular,studioUnicodeHeading;
volatile boolean studioCloseDispatchPending=false;
volatile boolean studioCloseIntent=false;
volatile boolean studioExitCommitted=false;
volatile boolean studioExitInProgress=false;
volatile long studioLastDrawHeartbeatNs=System.nanoTime();
volatile int studioGeometryRefreshFrames=0;
WindowAdapter studioCloseListener=null;
Thread studioCloseWatchdog=null;
volatile Throwable studioFatalError=null;
volatile String studioFatalPhase="";
volatile String studioFatalMessage="";
volatile boolean studioFatalLogged=false;

File studioRuntimeRoot(){
  String configured=System.getProperty("synkinect.app.home","").trim();
  File root=configured.length()>0?new File(configured):new File(System.getProperty("user.dir","."));
  
  try{return root.getCanonicalFile();}catch(IOException ignored){return root.getAbsoluteFile();
    }
}
File studioRuntimeFile(String relative){return new File(studioRuntimeRoot(),relative==null?"":relative);
  }

File studioLogDirectory(){
  File dir=studioRuntimeFile("data/studio/output/logs");
  if(!dir.isDirectory())dir.mkdirs();
  return dir;
}
File studioCleanExitMarker(){return new File(studioLogDirectory(),".last-exit-clean");
  }
void clearStudioCleanExitMarker(){try{Files.deleteIfExists(studioCleanExitMarker().toPath());
    }catch(Exception ignored){}}
void markStudioCleanExit(){
  try{Files.writeString(studioCleanExitMarker().toPath(),"clean "+new Date().toString()+System.lineSeparator(),java.nio.charset.StandardCharsets.UTF_8);
    }
  catch(Exception ignored){}
}
boolean studioHasFatalError(){return studioFatalError!=null;}
void enterStudioFatal(String phase,Throwable error){
  if(error==null)error=new RuntimeException("Unknown SynKinect Studio failure");
  if(studioFatalError==null){
    studioFatalError=error;
    studioFatalPhase=phase==null?"runtime":phase;
    studioFatalMessage=safeStudioMessage(error);
  }
  println("SynKinect Studio fatal ["+studioFatalPhase+"]: "+studioFatalMessage);
  error.printStackTrace();
  if(studioFatalLogged)return;
  studioFatalLogged=true;
  try{
    File log=new File(studioLogDirectory(),"StudioFatal.log");
    PrintWriter out=new PrintWriter(new OutputStreamWriter(new FileOutputStream(log,true),java.nio.charset.StandardCharsets.UTF_8));
    
    out.println("============================================================");
    out.println(new Date().toString()+" | phase="+studioFatalPhase);
    out.println("message="+studioFatalMessage);
    error.printStackTrace(out);
    out.flush();out.close();
  }catch(Exception logError){println("Could not write StudioFatal.log: "+safeStudioMessage(logError));
    }
}
void drawStudioFatalScreen(){
  background(0xFF10151B);
  hint(DISABLE_DEPTH_TEST);
  camera();perspective();
  pushStyle();
  textAlign(LEFT,TOP);
  fill(0xFFF4F7FA);textSize(30);text("SynKinect Studio — startup/runtime error",54,48);
  
  fill(0xFFE8B06A);textSize(17);text("The Studio was kept open so the failure is visible instead of closing silently.",54,102,width-108,52);
  
  fill(0xFFF4F7FA);textSize(16);
  String detail="Phase: "+studioFatalPhase+"\n\n"+studioFatalMessage+"\n\nDiagnostic: "+new File(studioLogDirectory(),"StudioFatal.log").getAbsolutePath()+"\nLauncher log: "+new File(studioLogDirectory(),
    "SynKinectStudio.log").getAbsolutePath();
  text(detail,54,168,max(200,width-108),max(180,height-230));
  fill(0xFFAAB6C2);textSize(14);text("Close this window after copying the diagnostic path if you need to report the failure.",54,height-48);
  
  popStyle();
}

String installedStudioFont(String[] candidates){
  HashSet<String> available=new HashSet<String>();
  try{for(String family:GraphicsEnvironment.getLocalGraphicsEnvironment().getAvailableFontFamilyNames())available.add(family.toLowerCase(Locale.ROOT));
    }
  catch(Exception ignored){}
  for(String candidate:candidates)if(candidate!=null&&available.contains(candidate.toLowerCase(Locale.ROOT)))return candidate;
  
  return "Dialog";
}
void initializeStudioTypography(){
  String locale=studio.i18n==null?Locale.getDefault().toLanguageTag():studio.i18n.language;
  
  String normalized=locale==null?"":locale.toLowerCase(Locale.ROOT);
  boolean japanese=normalized.startsWith("ja"),chinese=normalized.startsWith("zh");
  
  String regular=installedStudioFont(chinese
    ?new String[]{"Microsoft YaHei UI","Microsoft YaHei","PingFang SC","Noto Sans CJK SC","Noto Sans SC","Source Han Sans SC","WenQuanYi Micro Hei","Dialog"}
  
    :japanese
      ?new String[]{"Yu Gothic UI","Meiryo UI","Noto Sans CJK JP","Noto Sans JP","Noto Sans","DejaVu Sans","Dialog"}
      :new String[]{"Segoe UI Variable Text","Segoe UI Variable","Segoe UI","Inter","Noto Sans","Cantarell","Ubuntu Sans","Ubuntu","DejaVu Sans","Liberation Sans",
      "Dialog"});
  String heading=installedStudioFont(chinese
    ?new String[]{"Microsoft YaHei UI Bold","Microsoft YaHei UI","Microsoft YaHei","PingFang SC Semibold","PingFang SC","Noto Sans CJK SC","Noto Sans SC",
      "Source Han Sans SC","Dialog"}
    :japanese
      ?new String[]{"Yu Gothic UI Semibold","Yu Gothic UI","Meiryo UI","Noto Sans CJK JP","Noto Sans JP","Dialog"}
      :new String[]{"Segoe UI Variable Display","Segoe UI Variable","Segoe UI Semibold","Segoe UI","Inter SemiBold","Inter","Noto Sans SemiBold","Noto Sans",
      "Cantarell","Ubuntu Sans","Ubuntu","DejaVu Sans","Dialog"});
  studioUnicodeRegular=createFont(regular,STUDIO_FONT_BODY,true);
  studioUnicodeHeading=createFont(heading,STUDIO_FONT_TITLE,true);
  textFont(studioUnicodeRegular);
  textLeading(STUDIO_FONT_BODY*1.30f);
}
void studioText(float size,boolean heading){
  PFont f=heading?studioUnicodeHeading:studioUnicodeRegular;
  if(f!=null)textFont(f);
  float resolved=responsiveFontSize(size);
  textSize(resolved);
  textLeading(resolved*1.30f);
}

class StudioServices {
  final ConfigRules configRules=new ConfigRules();
  final StudioPaths paths=new StudioPaths();
  final StudioEndpoints endpoints=new StudioEndpoints();
  final WorkerFactory workers=new WorkerFactory();
  final ScannerProtocol scannerProtocol=new ScannerProtocol();
  final SpatialAudioProtocol spatialAudioProtocol=new SpatialAudioProtocol();
  final SpatialAudioSessionRegistry spatialAudioSessions=new SpatialAudioSessionRegistry();
  final SurveillanceProtocol surveillanceProtocol=new SurveillanceProtocol();
  final LocalTransportFactory transportFactory=new LocalTransportFactory();
  final KinectDeviceRegistry devices=new KinectDeviceRegistry();
  final SkeletonLibrary skeletons=new SkeletonLibrary();
  final HashMap<String,AppI18nCatalog> catalogs=new HashMap<String,AppI18nCatalog>();
  
  synchronized AppI18nCatalog catalog(String app){AppI18nCatalog value=catalogs.get(app);
    if(value==null){value=new AppI18nCatalog(app);catalogs.put(app,value);}return value;
    }
}

public void settings(){
  // The Studio uses logical pixels consistently. High-DPI
  // displays must not silently inflate the whole Processing canvas.
  size(STUDIO_MIN_WIDTH,STUDIO_MIN_HEIGHT,P3D);
  pixelDensity(1);
  smooth(4);
  try{PJOGL.setIcon(studioRuntimeFile("data/studio/synkinect-studio-icon.png").getAbsolutePath());
    }catch(Exception ignored){}
}

public void setup(){
  clearStudioCleanExitMarker();
  try{
    studio=new StudioController(new StudioServices());
    studio.initializeModules();
    surface.setTitle("SynKinect Studio");
    surface.setResizable(true);
    enforceStudioInitialWindowSize();
    studio.setup();
  }catch(Throwable error){
    enterStudioFatal("setup",error);
    try{surface.setTitle("SynKinect Studio — ERROR");surface.setResizable(true);}catch(Throwable ignored){}
  }
  configureStudioClosePolicy();
}

public void draw(){
  studioLastDrawHeartbeatNs=System.nanoTime();
  try{
    serviceStudioNativeGeometry();
    if(studioCloseDispatchPending&&!studioExitCommitted){
      studioCloseDispatchPending=false;
      exit();
      if(studioExitCommitted)return;
    }
    if(studioHasFatalError()){drawStudioFatalScreen();return;}
    if(studio==null){enterStudioFatal("draw",new IllegalStateException("Studio controller was not initialized"));
      drawStudioFatalScreen();return;}
    studio.draw();
  }catch(Throwable error){
    enterStudioFatal("draw",error);
    try{drawStudioFatalScreen();}catch(Throwable ignored){}
  }
}
public void mousePressed(){if(studio!=null&&!studioHasFatalError())studio.mousePressed();
  }
public void mouseDragged(){if(studio!=null&&!studioHasFatalError())studio.mouseDragged();
  }
public void mouseReleased(){if(studio!=null&&!studioHasFatalError())studio.mouseReleased();
  }
public void mouseWheel(processing.event.MouseEvent event){if(studio!=null&&!studioHasFatalError())studio.mouseWheel(event);
  }
public void keyPressed(){
  // Processing treats ESC as an implicit exit request. Keep it from closing the
  // application, then dispatch every other key through the generic module path.
  if(key==ESC){key=0;return;}
  if(studio!=null&&!studioHasFatalError())studio.keyPressed();
}
public void dispose(){
  if(studio!=null)try{studio.dispose();}catch(Throwable error){if(!studioHasFatalError())enterStudioFatal("dispose",error);
    }
}
public void exit(){
  // Armed surveillance owns the Studio until the user explicitly disarms it.
  // Other shutdown paths remain non-blocking once the close policy permits exit.
  if(studioExitCommitted||studioExitInProgress)return;
  if(studio!=null&&!studioHasFatalError()&&studio.blockCloseIfRequired())return;
  studioCloseIntent=true;
  studioCloseDispatchPending=false;
  startStudioCloseWatchdog();
  studioExitInProgress=true;
  try{
    restoreStudioClosePolicy();
    if(studio!=null)try{studio.dispose();}catch(Throwable error){println("Studio shutdown warning: "+safeStudioMessage(error));
      }
    if(!studioHasFatalError())markStudioCleanExit();
    studioExitCommitted=true;
    super.exit();
  }finally{
    if(!studioExitCommitted)studioExitInProgress=false;
  }
}

void enforceStudioInitialWindowSize(){
  // Window geometry is owned by the native window manager after startup.
  if(width>=STUDIO_MIN_WIDTH&&height>=STUDIO_MIN_HEIGHT)return;
  try{surface.setSize(max(width,STUDIO_MIN_WIDTH),max(height,STUDIO_MIN_HEIGHT));
    }
  catch(Exception e){println("Studio initial-size warning: "+safeStudioMessage(e));
    }
}

void noteStudioNativeGeometryChange(){
  // Repaint a few frames after native geometry/focus events without mutating
  // native size, position, decoration or visibility.
  studioGeometryRefreshFrames=max(studioGeometryRefreshFrames,6);
}

void serviceStudioNativeGeometry(){
  if(studioGeometryRefreshFrames<=0)return;
  studioGeometryRefreshFrames--;
  // Rendering is continuous; resetting the view state is sufficient for P3D to
  // adopt the new drawable geometry.
  try{
    if(g!=null){
      hint(DISABLE_DEPTH_TEST);
      camera();
      perspective();
    }
  }catch(Throwable error){println("Studio geometry refresh warning: "+safeStudioMessage(error));
    }
}

void requestStudioClose(){
  if(studioExitCommitted)return;
  if(studio!=null&&studio.blockCloseIfRequired())return;
  studioCloseIntent=true;
  studioCloseDispatchPending=true;
  startStudioCloseWatchdog();
}

void startStudioCloseWatchdog(){
  synchronized(this){
    if(studioCloseWatchdog!=null&&studioCloseWatchdog.isAlive())return;
    studioCloseWatchdog=new Thread(new Runnable(){public void run(){
      try{
        // An orderly Processing/JOGL shutdown normally finishes well before this
        // deadline. If it does not, terminate independently of renderer, USB and
        // hidden-launcher state. Runtime.halt is intentionally last-resort only.
        Thread.sleep(4000);
        if(!studioCloseIntent)return;
        try{
          Object nativeWindow=surface.getNative();
          if(nativeWindow instanceof GLWindow){
            GLWindow window=(GLWindow)nativeWindow;
            if(studioCloseListener!=null)window.removeWindowListener(studioCloseListener);
            studioCloseListener=null;
            window.setDefaultCloseOperation(WindowClosingProtocol.WindowClosingMode.DISPOSE_ON_CLOSE);
            window.destroy();
          }
        }catch(Throwable ignored){}
        Runtime.getRuntime().halt(0);
      }catch(InterruptedException ignored){Thread.currentThread().interrupt();}
    }},"Studio-Close-Watchdog");
    studioCloseWatchdog.setDaemon(true);
    studioCloseWatchdog.start();
  }
}

// The operating system owns window geometry and decoration. The listener only
// observes geometry/focus events and forwards close requests.
void configureStudioClosePolicy(){
  if(studioCloseListener!=null)return;
  try{
    Object nativeWindow=surface.getNative();
    if(nativeWindow instanceof GLWindow){
      final GLWindow window=(GLWindow)nativeWindow;
      window.setDefaultCloseOperation(WindowClosingProtocol.WindowClosingMode.DO_NOTHING_ON_CLOSE);
      
      studioCloseListener=new WindowAdapter(){
        @Override public void windowResized(WindowEvent event){noteStudioNativeGeometryChange();
          }
        @Override public void windowMoved(WindowEvent event){noteStudioNativeGeometryChange();
          }
        @Override public void windowGainedFocus(WindowEvent event){noteStudioNativeGeometryChange();
          }
        @Override public void windowDestroyNotify(WindowEvent event){
          requestStudioClose();
        }
      };
      window.addWindowListener(studioCloseListener);
    }
  }catch(Exception e){println("Studio close-policy warning: "+safeStudioMessage(e));
    }
}

void restoreStudioClosePolicy(){
  try{
    Object nativeWindow=surface.getNative();
    if(nativeWindow instanceof GLWindow){
      GLWindow window=(GLWindow)nativeWindow;
      if(studioCloseListener!=null)window.removeWindowListener(studioCloseListener);
      
      studioCloseListener=null;
      window.setDefaultCloseOperation(WindowClosingProtocol.WindowClosingMode.DISPOSE_ON_CLOSE);
      
    }
  }catch(Exception e){println("Studio close-policy restore warning: "+safeStudioMessage(e));
    }
}

void putFixedDeviceId(ByteBuffer buffer,String deviceId){
  final int bytes=64;
  byte[] raw=(deviceId==null?"":deviceId).getBytes(java.nio.charset.StandardCharsets.UTF_8);
  
  int n=min(bytes-1,raw.length);
  if(n>0)buffer.put(raw,0,n);
  for(int i=n;i<bytes;i++)buffer.put((byte)0);
}
String selectedKinectDeviceId(){KinectDevice device=studio.selectedKinect();return device==null?"":device.id;
  }

class KinectDevice {
  final String id,label,state,control,camera,audio,audioControl,virtualCamera,sdk;
  
  final String endpoint;
  KinectDevice(String id,String label,String state,String control,String camera,String audio,String audioControl,String virtualCamera,String sdk){
    this.id=clean(id);this.label=clean(label);this.state=clean(state);this.control=clean(control);
    this.camera=clean(camera);this.audio=clean(audio);this.audioControl=clean(audioControl);
    this.virtualCamera=clean(virtualCamera);this.sdk=clean(sdk);this.endpoint=this.camera;
    
  }
  static String clean(String value){return value==null?"":value.trim();}
  boolean readyState(){return "Ready".equalsIgnoreCase(state);}
  boolean controlReady(){return !control.isEmpty();}
  boolean cameraReady(){return !camera.isEmpty();}
  boolean audioReady(){return !audio.isEmpty();}
  boolean audioControlReady(){return !audioControl.isEmpty();}
  boolean virtualCameraReady(){return !virtualCamera.isEmpty();}
  boolean sdkReady(){return !sdk.isEmpty();}
}

class KinectDeviceRegistry {
  final Object lock=new Object();
  final ArrayList<KinectDevice> devices=new ArrayList<KinectDevice>();
  volatile String selectedId="";
  volatile long generation=0,lastRefreshMs=0;
  volatile boolean refreshQueued=false;
  final long refreshIntervalMs=750;
  final long manifestFreshnessMs=15000;
  final long disappearanceGraceMs=30000;
  final HashMap<String,Long> lastSeenMs=new HashMap<String,Long>();

  File manifestFile(){
    if(System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("windows")){
      String root=System.getenv("ProgramData");
      if(root==null||root.trim().isEmpty())root="C:\\ProgramData";
      return new File(new File(root,"Kinect360Remold"),"devices.tsv");
    }
    return new File("/run/kinect360-remold/devices.tsv");
  }

  void refreshIfDue(){requestRefresh(false);}
  void requestRefresh(boolean force){
    long now=System.nanoTime()/1000000L;
    synchronized(lock){
      if(!force&&now-lastRefreshMs<refreshIntervalMs)return;
      if(refreshQueued)return;
      refreshQueued=true;lastRefreshMs=now;
    }
    studio.services.workers.startLowPriority("Device-Registry",new Runnable(){public void run(){
      try{refresh();}finally{refreshQueued=false;}
    }});
  }
  void refresh(){
    ArrayList<KinectDevice> found=new ArrayList<KinectDevice>();
    File file=manifestFile();
    long wallNow=System.currentTimeMillis();
    boolean manifestFresh=file.isFile()&&file.lastModified()>0&&wallNow-file.lastModified()<=manifestFreshnessMs;
    boolean linuxRuntimeRemoved=!System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("windows")&&!file.isFile();

    // On Linux the runtime owns /run/kinect360-remold/devices.tsv. If that
    // manifest no longer exists, uninstall/stop has completed and retained
    // device identities must disappear immediately. The 30 s grace remains
    // only for short USB/PnP gaps while the runtime itself is alive.
    if(linuxRuntimeRemoved){
      synchronized(lock){
        String before=signature(devices,selectedId);
        devices.clear();lastSeenMs.clear();selectedId="";
        if(!signature(devices,selectedId).equals(before))generation++;
      }
      return;
    }
    
    if(manifestFresh){
      try{
        for(String line:Files.readAllLines(file.toPath(),java.nio.charset.StandardCharsets.UTF_8)){
          line=line.trim();
          if(line.isEmpty()||line.startsWith("#"))continue;
          String[] parts=line.split("\t",-1);
          if(parts.length<3)continue;
          String id=parts[0].trim(),label=parts[1].trim();
          String state=parts[2].trim();
          String control=parts.length>3?parts[3].trim():"";
          String camera=parts.length>4?parts[4].trim():"";
          String audio=parts.length>5?parts[5].trim():"";
          String audioControl=parts.length>6?parts[6].trim():"";
          String virtualCamera=parts.length>7?parts[7].trim():"";
          String sdk=parts.length>8?parts[8].trim():"";
          if(!id.isEmpty())found.add(new KinectDevice(id,label.isEmpty()?id:label,state,control,camera,audio,audioControl,virtualCamera,sdk));
          
        }
      }catch(IOException e){println("device-registry: "+safeStudioMessage(e));}
    }
    LinkedHashMap<String,KinectDevice> unique=new LinkedHashMap<String,KinectDevice>();
    for(KinectDevice d:found)unique.put(d.id,d);
    found=new ArrayList<KinectDevice>(unique.values());
    Collections.sort(found,new Comparator<KinectDevice>(){public int compare(KinectDevice a,KinectDevice b){return a.id.compareTo(b.id);}});
    
    long now=System.nanoTime()/1000000L;
    synchronized(lock){
      String before=signature(devices,selectedId);
      LinkedHashMap<String,KinectDevice> merged=new LinkedHashMap<String,KinectDevice>();
      
      for(KinectDevice d:found){merged.put(d.id,d);lastSeenMs.put(d.id,now);}
      // Keep the physical device identity through CameraBridge restarts and USB/PnP
      // re-enumeration. A retained entry is explicitly reconnecting and carries no
      // stale camera endpoint, so modules wait for the same device-id instead of
      // interpreting a short runtime gap as a physical unplug.
      for(KinectDevice old:devices){Long seen=lastSeenMs.get(old.id);if(!merged.containsKey(old.id)&&seen!=null&&now-seen<disappearanceGraceMs)merged.put(old.id,
          new KinectDevice(old.id,old.label,"Reconnecting","","","","","",""));}
      Iterator<Map.Entry<String,Long>> seenIt=lastSeenMs.entrySet().iterator();while(seenIt.hasNext()){Map.Entry<String,Long> e=seenIt.next();
        if(now-e.getValue()>=disappearanceGraceMs&&!merged.containsKey(e.getKey()))seenIt.remove();
        }
      devices.clear();devices.addAll(merged.values());Collections.sort(devices,new Comparator<KinectDevice>(){public int compare(KinectDevice a,KinectDevice b){
          return a.id.compareTo(b.id);}});
      boolean selectedPresent=false;for(KinectDevice d:devices)if(d.id.equals(selectedId)){selectedPresent=true;
        break;}
      if(!selectedPresent)selectedId=devices.isEmpty()?"":devices.get(0).id;
      String after=signature(devices,selectedId);if(!after.equals(before))generation++;
      
    }
  }
  String signature(List<KinectDevice> list,String selected){StringBuilder b=new StringBuilder(selected);
    for(KinectDevice d:list)b.append('|').append(d.id).append('#').append(d.state).append('@').append(d.control).append('@').append(d.camera).append('@').append(d.audio).append('@').append(d.audioControl).append('@').append(d.virtualCamera).append('@').append(d.sdk);
    return b.toString();}
  KinectDevice selected(){synchronized(lock){for(KinectDevice d:devices)if(d.id.equals(selectedId))return d;
      return devices.isEmpty()?null:devices.get(0);}}
  KinectDevice byId(String id){if(id==null)return null;synchronized(lock){for(KinectDevice d:devices)if(d.id.equals(id))return d;
      return null;}}
  ArrayList<KinectDevice> snapshot(){synchronized(lock){return new ArrayList<KinectDevice>(devices);
      }}
  int count(){synchronized(lock){return devices.size();}}
  int readyCameraCount(){synchronized(lock){int n=0;for(KinectDevice d:devices)if(d.cameraReady())n++;
      return n;}}
  void cycle(){synchronized(lock){if(devices.isEmpty()){selectedId="";return;}int idx=0;
      for(int i=0;i<devices.size();i++)if(devices.get(i).id.equals(selectedId)){idx=i;
        break;}selectedId=devices.get((idx+1)%devices.size()).id;generation++;}}
  String selectorLabel(){synchronized(lock){if(devices.isEmpty())return "Kinect · 0";
      int idx=0;for(int i=0;i<devices.size();i++)if(devices.get(i).id.equals(selectedId)){idx=i;
        break;}KinectDevice d=devices.get(idx);String name=d.label==null||d.label.trim().isEmpty()?"Kinect":d.label.trim();
      return name+" · "+(idx+1)+"/"+devices.size();}}
}

interface StudioModule {
  String key();
  String title();
  String description();
  void setupModule();
  void activateModule();
  void deactivateModule();
  void drawModule();
  void mousePressedModule();
  void mouseDraggedModule();
  void mouseReleasedModule();
  void mouseWheelModule(processing.event.MouseEvent event);
  void keyPressedModule();
  void contextChanged(org.synkinect.studio.api.StudioContextEvent event);
  String leaveBlockReason();
  String closeBlockReason();
  void blockedAction(String reason);
  void disposeModule();
}

enum ModulePhase { NEW, READY, INIT_FAILED, ACTIVATE_FAILED, RENDER_FAILED, DISPOSED }

abstract class StudioModuleBase implements StudioModule {
  final StudioController owner;
  final String moduleKey,moduleTitleKey,moduleDescriptionKey;
  volatile ModulePhase phase=ModulePhase.NEW;
  volatile String failureMessage="";
  StudioModuleBase(StudioController owner,String key,String titleKey,String descriptionKey){this.owner=owner;
    moduleKey=key;moduleTitleKey=titleKey;moduleDescriptionKey=descriptionKey;}
  public String key(){return moduleKey;}
  public String title(){return owner.i18n==null?moduleTitleKey:owner.i18n.tr(moduleTitleKey);
    }
  public String description(){return owner.i18n==null?moduleDescriptionKey:owner.i18n.tr(moduleDescriptionKey);
    }
  boolean ownsResources(){return phase==ModulePhase.READY||phase==ModulePhase.RENDER_FAILED;
    }
  public Object localState(){return null;}
  void prepareRetry(){
    if(phase==ModulePhase.INIT_FAILED)phase=ModulePhase.NEW;
    else if(phase==ModulePhase.ACTIVATE_FAILED||phase==ModulePhase.RENDER_FAILED)phase=ModulePhase.READY;
    
    if(phase==ModulePhase.NEW||phase==ModulePhase.READY)failureMessage="";
  }
  void initialize(){
    if(phase!=ModulePhase.NEW)return;
    try{setupModule();phase=ModulePhase.READY;failureMessage="";}
    catch(Exception error){
      phase=ModulePhase.INIT_FAILED;failureMessage=safeStudioMessage(error);
      println("Module initialization failed ["+moduleKey+"]: "+failureMessage);error.printStackTrace();
      
    }
  }
  void activationFailure(Exception error){phase=ModulePhase.ACTIVATE_FAILED;failureMessage=safeStudioMessage(error);
    }
  void renderFailure(Exception error){phase=ModulePhase.RENDER_FAILED;failureMessage=safeStudioMessage(error);
    }
  void markDisposed(){phase=ModulePhase.DISPOSED;}
  public void mousePressedModule(){}
  public void mouseDraggedModule(){}
  public void mouseReleasedModule(){}
  public void mouseWheelModule(processing.event.MouseEvent event){}
  public void keyPressedModule(){}
  public void contextChanged(org.synkinect.studio.api.StudioContextEvent event){}
  public String leaveBlockReason(){return "";}
  public String closeBlockReason(){return "";}
  public void blockedAction(String reason){}
  public Closeable hostResource(){return null;}
}

class ScannerStudioModule extends StudioModuleBase {
  final ScannerModuleState state;
  ScannerStudioModule(StudioController owner){super(owner,"scanner","module.scanner","home.scanner");
    state=owner.moduleStates.install(ScannerModuleState.class,new ScannerModuleState());
    }
  @Override public Object localState(){return state;}
  public void setupModule(){setupScannerModule();}
  public void activateModule(){
    ensureScannerSource();
    if(state.source!=null){
      // Scanner does not own RGB HQ. It follows the selected Kinect driver
      // setting configured from the Studio system panel or KINECT terminal.
      state.source.setFollowDriverRgbHq(true);
      state.source.start();state.source.clearConsumerPairs();
    }
  }
  public void deactivateModule(){
    cancelScannerReconstructionReset();
    // Strict module isolation: HQ Scanner state must never leak into a module
    // that expects canonical VGA RGB+Depth. Every module transition releases its
    // ScannerPort subscription and the next module negotiates its own mode.
    if(state.scanActive){
      state.scanPaused=true;clearPendingScanWork();
    }
    if(state.source!=null){
      state.source.requestStop(true);
      state.source.setFollowDriverRgbHq(false);
    }
  }
  public void drawModule(){drawScannerModule();}
  public void mousePressedModule(){scannerMousePressed();}
  public void mouseDraggedModule(){scannerMouseDragged();}
  public void mouseWheelModule(processing.event.MouseEvent event){scannerMouseWheel(event);
    }
  public void keyPressedModule(){}
  public void contextChanged(org.synkinect.studio.api.StudioContextEvent event){
    if(event.localeChanged()&&state.i18n!=null){state.i18n.setLanguage(event.locale());
      state.status=state.i18n.tr("status.ready");}
    if(event.devicesChanged()){
      String reason=event.selectionChanged()?"device-selection":"device-registry";
      
      if(state.source!=null)state.source.requestReconnect(reason,event.selectionChanged());
      
      if(event.selectionChanged()){
        if(state.source!=null)state.source.clearConsumerPairs();
        state.latestPair=null;state.latestDepth=null;state.latestDepthDiagnostics=null;
        state.depthPreview=null;state.colorPreview=null;
        state.scanActive=false;state.scanPaused=false;clearPendingScanWork();
      }
      owner.services.workers.startLowPriority("Scanner-Device-Reconcile",new Runnable(){public void run(){refreshScannerCalibrationForSelectedDevice(true);}
        });
    }
  }
  public void disposeModule(){disposeScannerModule();}
}

class AcousticStudioModule extends StudioModuleBase {
  final AcousticModuleState state;
  AcousticStudioModule(StudioController owner){super(owner,"acoustic","module.acoustic","home.acoustic");
    state=owner.moduleStates.install(AcousticModuleState.class,new AcousticModuleState());
    }
  @Override public Object localState(){return state;}
  public void setupModule(){setupAcousticModule();}
  public void activateModule(){
    if(state.output!=null)state.output.start();
    if(state.source!=null)state.source.start();
  }
  public void deactivateModule(){
    if(state.source!=null)state.source.requestStop();
    if(state.output!=null)state.output.requestStop();
  }
  public void drawModule(){drawAcousticModule();}
  public void mousePressedModule(){acousticMousePressed();}
  public void keyPressedModule(){}
  public void contextChanged(org.synkinect.studio.api.StudioContextEvent event){
    if(event.localeChanged()&&state.i18n!=null)state.i18n.setLanguage(event.locale());
    
    if(event.devicesChanged()){
      String reason=event.selectionChanged()?"device-selection":"device-registry";
      
      if(state.source!=null)state.source.requestReconnect(reason,event.selectionChanged());
      
      if(event.selectionChanged()){if(state.source!=null)state.source.resetAnalysis();if(state.beamEngine!=null)state.beamEngine.reset();if(state.autoSteerer!=null)state.autoSteerer.reset();
        state.scan=null;}
    }
  }
  public void disposeModule(){disposeAcousticModule();}
}

class MicrophoneStudioModule extends StudioModuleBase {
  final MicrophoneModuleState state;
  MicrophoneStudioModule(StudioController owner){super(owner,"microphones","module.microphones","home.microphones");
    state=owner.moduleStates.install(MicrophoneModuleState.class,new MicrophoneModuleState());
    }
  @Override public Object localState(){return state;}
  public void setupModule(){setupMicrophoneModule();}
  public void activateModule(){if(state.source!=null)state.source.start();}
  public void deactivateModule(){
    if(state.source!=null)state.source.requestStop();
    if(state.pipeline!=null){
      state.pipeline.monitor.requestStop();
      state.pipeline.player.requestStop();
      state.pipeline.selfTest.requestStop();
      if(state.pipeline.recorder.isRecording()){
        final WavRecorder recorder=state.pipeline.recorder;
        owner.services.workers.startLowPriority("Microphone-Recorder-Close",new Runnable(){public void run(){recorder.stop();}});
        
      }
    }
  }
  public void drawModule(){drawMicrophoneModule();}
  public void mousePressedModule(){microphoneMousePressed();}
  public void keyPressedModule(){}
  public void contextChanged(org.synkinect.studio.api.StudioContextEvent event){
    if(event.localeChanged()&&state.i18n!=null)state.i18n.setLanguage(event.locale());
    
    if(event.devicesChanged()){String reason=event.selectionChanged()?"device-selection":"device-registry";
      if(state.source!=null)state.source.requestReconnect(reason,event.selectionChanged());
      if(event.selectionChanged()&&state.source!=null)state.source.clearSnapshot();
      }
  }
  public void disposeModule(){disposeMicrophoneModule();}
}

class SurveillanceStudioModule extends StudioModuleBase {
  final SurveillanceModuleState state;
  SurveillanceStudioModule(StudioController owner){super(owner,"surveillance","module.surveillance","home.surveillance");
    state=owner.moduleStates.install(SurveillanceModuleState.class,new SurveillanceModuleState());
    }
  @Override public Object localState(){return state;}
  public void setupModule(){setupSurveillanceModule();}
  public void activateModule(){activateSurveillanceRuntime();}
  public void deactivateModule(){deactivateSurveillanceRuntime();}
  public void drawModule(){drawSurveillanceModule();}
  public void mousePressedModule(){surveillanceMousePressed();}
  public void keyPressedModule(){}
  public void contextChanged(org.synkinect.studio.api.StudioContextEvent event){
    if(event.localeChanged()&&state.i18n!=null){state.i18n.setLanguage(event.locale());
      state.status=state.i18n.tr(state.armed?"status.armed_multi":"status.disarmed");
      }
    if(event.devicesChanged()&&state.config!=null)owner.services.workers.startLowPriority("Surveillance-Device-Reconcile",new Runnable(){public void run(){
        syncSurveillanceDevices(true);}});
  }
  public String leaveBlockReason(){return state.armed?state.i18n.tr("status.leave_blocked_armed"):"";
    }
  public String closeBlockReason(){return state.armed?state.i18n.tr("status.close_blocked_armed"):"";
    }
  public void blockedAction(String reason){if(reason!=null&&!reason.isEmpty())state.status=reason;
    }
  public void disposeModule(){disposeSurveillanceModule();}
}

class InteractivityStudioModule extends StudioModuleBase {
  final InteractionModuleState state;
  InteractivityStudioModule(StudioController owner){super(owner,"interactivity","module.interactivity","home.interactivity");
    state=owner.moduleStates.install(InteractionModuleState.class,new InteractionModuleState());
    }
  @Override public Object localState(){return state;}
  public void setupModule(){setupInteractivityModule();}
  public void activateModule(){activateInteractivityModule();}
  public void deactivateModule(){requestDeactivateInteractivityModule();}
  public void drawModule(){drawInteractivityModule();}
  public void mousePressedModule(){interactivityMousePressed();}
  public void keyPressedModule(){}
  public void contextChanged(org.synkinect.studio.api.StudioContextEvent event){
    if(event.localeChanged()&&state.i18n!=null){state.i18n.setLanguage(event.locale());
      state.status=state.i18n.tr(state.controlEnabled?"status.control_on":"status.ready");
      }
    if(event.devicesChanged()){
      String reason=event.selectionChanged()?"device-selection":"device-registry";
      
      if(state.rgbd!=null)state.rgbd.requestReconnect(reason,event.selectionChanged());
      
      if(event.selectionChanged()){if(state.rgbd!=null)state.rgbd.clearConsumerPairs();
        if(state.processor!=null)state.processor.clearPublished();state.lastProcessedFrame=-1;
        state.skeleton=null;state.rgbImage=null;}
      owner.services.workers.startLowPriority("Interactivity-Device-Reconcile",new Runnable(){public void run(){refreshInteractionCalibrationForSelectedDevice();}
        });
    }
  }
  public void disposeModule(){disposeInteractivityModule();}
}

class StudioModuleStateStore {
  final HashMap<Class<?>,Object> values=new HashMap<Class<?>,Object>();
  synchronized <T> T install(Class<T> type,T value){if(type==null||value==null)throw new IllegalArgumentException("module state");
    Object existing=values.get(type);if(existing==null){values.put(type,value);return value;
      }return type.cast(existing);}
  synchronized <T> T get(Class<T> type){Object value=values.get(type);if(value==null)throw new IllegalStateException("Module state is not installed: "+(type==null?"null":type.getSimpleName()));
    return type.cast(value);}
  synchronized void clear(){values.clear();}
}

class StudioController {
  final StudioServices services;
  final StudioShellConfig config;
  final StudioUiSystem ui=new StudioUiSystem();
  final StudioSystemControl systemControl=new StudioSystemControl();
  final StudioHomeSystemPanel homeSystemPanel=new StudioHomeSystemPanel();
  final StudioModuleStateStore moduleStates=new StudioModuleStateStore();
  StudioModuleBase[] modules=null;
  StudioShellI18n i18n;
  StudioController(StudioServices services){
    this.services=services;
    config=new StudioShellConfig(services.configRules);
  }
  <T> T state(Class<T> type){return moduleStates.get(type);}
  void initializeModules(){
    if(modules==null)modules=buildStudioModules(this);
  }
  final Object lifecycleLock=new Object();
  final java.util.concurrent.locks.ReentrantLock operationLock=new java.util.concurrent.locks.ReentrantLock();
  
  volatile int activeModule=-1;
  volatile int desiredModule=-1;
  volatile int ownedModule=-1;
  volatile int transitionTarget=-1;
  volatile boolean ready=false;
  volatile boolean shuttingDown=false;
  volatile boolean transitioning=false;
  volatile boolean lifecycleRun=false;
  Thread lifecycleThread=null;
  int contentHeight=1;
  volatile long seenDeviceGeneration=-1;
  volatile String seenSelectedDeviceId="";
  float homeScrollY=0,homeMaxScroll=0,homeScrollDragOffset=0;
  boolean homeScrollDragging=false;

  // All module UI is rendered in content-local coordinates after the shell
  // translates the canvas by STUDIO_TOP_BAR_H. Pointer input must use the exact
  // inverse transform. Keeping this rule here prevents individual modules
  // from mixing window-space and content-space coordinates.
  float contentMouseX(){return mouseX;}
  float contentMouseY(){return mouseY-STUDIO_TOP_BAR_H;}
  float contentPMouseX(){return pmouseX;}
  float contentPMouseY(){return pmouseY-STUDIO_TOP_BAR_H;}

  String currentLanguage(){return studio.i18n==null?"en-US":studio.i18n.language;
    }
  void cycleLanguage(){
    if(studio.i18n==null)return;
    studio.i18n.toggle();
    initializeStudioTypography();
    applyLanguageToModules(studio.i18n.language);
    updateTitle();
  }
  void setLanguage(String locale){
    if(studio.i18n==null)return;
    studio.i18n.setLanguage(locale);
    initializeStudioTypography();
    applyLanguageToModules(studio.i18n.language);
    updateTitle();
  }
  void applyLanguageToModules(String locale){
    dispatchContextEvent(org.synkinect.studio.api.StudioContextEvent.LOCALE_CHANGED);
    
  }

  void setup(){
    contentHeight=max(1,height-STUDIO_TOP_BAR_H);
    studio.config.load(studio.services.paths.resource("studio","config.properties"));
    
    studio.i18n=new StudioShellI18n(studio.config.language);
    studio.i18n.applyOrder(studio.config.languages);
    initializeStudioTypography();
    services.devices.requestRefresh(true);seenDeviceGeneration=-1;seenSelectedDeviceId="";
    homeScrollY=0;homeMaxScroll=0;homeScrollDragging=false;homeScrollDragOffset=0;
    
    frameRate(constrain(studio.config.uiFrameRate,studio.config.uiMinFrameRate,studio.config.uiMaxFrameRate));
    
    ready=true;
    startLifecycle();
    // The Studio starts on a presentation/home screen. No module is initialized or
    // activated until the user explicitly selects one.
    activeModule=-1;desiredModule=-1;ownedModule=-1;transitioning=false;
    updateTitle();
  }

  void draw(){
    contentHeight=max(1,height-STUDIO_TOP_BAR_H);
    services.devices.refreshIfDue();
    reconcileDeviceSelection();
    StudioModuleBase active=activeModule>=0&&activeModule<modules.length?modules[activeModule]:null;
    

    // P3D keeps camera and model transforms in the same model-view stack.
    // Never call resetMatrix() after camera(): that erases the default camera
    // and places z=0 UI geometry on the eye plane, so only background() remains
    // visible. Restore a known 2D-friendly P3D state with camera()+perspective().
    resetStudioUiRenderer();
    pushStyle();
    pushMatrix();
    translate(0,STUDIO_TOP_BAR_H);
    if(active==null){
      drawStudioHome();
    }else{
      if(active.phase==ModulePhase.READY&&isReady(activeModule)){
        try{active.drawModule();}
        catch(Exception error){
          active.renderFailure(error);
          println("Module render failed ["+active.moduleKey+"]: "+active.failureMessage);
          
          error.printStackTrace();
        }
      }
      if(active.phase!=ModulePhase.READY||!isReady(activeModule))drawModuleStartup(active);
      
    }
    popMatrix();
    popStyle();

    // The shell owns the top navigation layer. Modules cannot leak matrix or
    // style state into it, and a module rendering failure cannot erase it.
    resetStudioUiRenderer();
    pushStyle();
    drawTopBar();
    popStyle();
  }

  void resetStudioUiRenderer(){
    hint(DISABLE_DEPTH_TEST);
    camera();
    perspective();
    if(studioUnicodeRegular!=null)textFont(studioUnicodeRegular);
    textLeading(responsiveFontSize(STUDIO_FONT_BODY)*1.30f);
  }

  String selectedKinectId(){KinectDevice selected=services.devices.selected();return selected==null?"":selected.id;
    }
  void reconcileDeviceSelection(){
    long generation=services.devices.generation;
    String selectedId=selectedKinectId();
    if(generation==seenDeviceGeneration&&Objects.equals(selectedId,seenSelectedDeviceId))return;
    
    boolean selectionChanged=!Objects.equals(selectedId,seenSelectedDeviceId);
    seenDeviceGeneration=generation;seenSelectedDeviceId=selectedId;
    onDeviceRegistryChanged(selectionChanged);
  }
  void onDeviceRegistryChanged(boolean selectionChanged){
    int flags=org.synkinect.studio.api.StudioContextEvent.DEVICES_CHANGED|(selectionChanged?org.synkinect.studio.api.StudioContextEvent.SELECTION_CHANGED:0);
    
    dispatchContextEvent(flags);
  }
  org.synkinect.studio.api.StudioDeviceInfo publicDevice(KinectDevice device){return device==null?null:new org.synkinect.studio.api.StudioDeviceInfo(device.id,
      device.label,device.endpoint);}
  List<org.synkinect.studio.api.StudioDeviceInfo> publicDevices(){ArrayList<org.synkinect.studio.api.StudioDeviceInfo> out=new ArrayList<org.synkinect.studio.api.StudioDeviceInfo>();
    for(KinectDevice device:services.devices.snapshot())out.add(publicDevice(device));
    return Collections.unmodifiableList(out);}
  void dispatchContextEvent(int flags){
    if(modules==null)return;org.synkinect.studio.api.StudioContextEvent event=new org.synkinect.studio.api.StudioContextEvent(flags,currentLanguage(),services.devices.generation,
      publicDevice(selectedKinect()),publicDevices());
    for(StudioModuleBase module:modules){if(module.phase==ModulePhase.NEW||module.phase==ModulePhase.INIT_FAILED||module.phase==ModulePhase.DISPOSED)continue;
      try{module.contextChanged(event);}catch(Throwable error){rethrowFatalPluginError(error);
        println("Module context event failed ["+module.key()+"]: "+safeStudioMessage(error));
        error.printStackTrace();}}
  }
  void cycleKinect(){
    String before=selectedKinectId();services.devices.cycle();String after=selectedKinectId();
    
    seenDeviceGeneration=services.devices.generation;seenSelectedDeviceId=after;
    if(!Objects.equals(before,after))onDeviceRegistryChanged(true);
    updateTitle();
  }
  KinectDevice selectedKinect(){return services.devices.selected();}

  float deviceButtonW(){return constrain(width*0.17f,180,246);}
  float languageButtonW(){return constrain(width*0.095f,96,132);}
  float closeButtonW(){return 38;}
  float homeButtonW(){return constrain(width*0.070f,72,94);}
  float shellMargin(){return constrain(width*0.014f,14,22);}
  float shellGap(){return 12;}
  float shellButtonY(){return 7;}
  float shellButtonH(){return 36;}
  float homeButtonX(){return shellMargin();}
  float closeButtonX(){return width-shellMargin()-closeButtonW();}
  float languageButtonX(){return closeButtonX()-shellGap()-languageButtonW();}
  float deviceButtonX(){
    float centered=(width-deviceButtonW())*0.5f;
    float minX=homeButtonX()+homeButtonW()+150;
    float maxX=languageButtonX()-deviceButtonW()-18;
    return constrain(centered,minX,max(minX,maxX));
  }
  float shellTitleX(){return homeButtonX()+homeButtonW()+16;}
  float shellTitleW(){return max(80,deviceButtonX()-shellTitleX()-16);}
  boolean shellHit(float mx,float my,float x,float w){return mx>=x&&mx<=x+w&&my>=shellButtonY()&&my<=shellButtonY()+shellButtonH();
    }
  boolean homeButtonHit(float mx,float my){return shellHit(mx,my,homeButtonX(),homeButtonW());
    }
  boolean languageButtonHit(float mx,float my){return shellHit(mx,my,languageButtonX(),languageButtonW());
    }
  boolean closeButtonHit(float mx,float my){return shellHit(mx,my,closeButtonX(),closeButtonW());
    }
  boolean deviceButtonHit(float mx,float my){return shellHit(mx,my,deviceButtonX(),deviceButtonW());
    }

  void drawShellButton(float x,float w,String label,boolean active,boolean enabled,boolean hot){
    pushStyle();
    int border=hot?0xFF68A9E8:0xFF35414D;
    int surface=active?0xFF293440:(hot?0xFF222B34:0xFF181E25);
    stroke(border);fill(surface);rect(x,shellButtonY(),w,shellButtonH(),9);noStroke();
    
    fill(enabled?(active?0xFFF4F7FA:0xFFD4DCE4):0xFF7E8994);textAlign(CENTER,CENTER);
    
    studioText(STUDIO_FONT_BUTTON,true);fitCurrentTextSize(label,STUDIO_FONT_BUTTON,8,max(12,w-12),30);
    
    text(ellipsizeToWidth(label,max(12,w-12)),x+w/2,shellButtonY()+shellButtonH()/2);
    
    popStyle();
  }

  void drawTopBar(){
    noStroke();fill(0xFF0C1014);rect(0,0,width,STUDIO_TOP_BAR_H);
    boolean homeActive=activeModule<0;
    boolean homeEnabled=homeActive||activeLeaveBlockReason().isEmpty();
    drawShellButton(homeButtonX(),homeButtonW(),studio.i18n.tr("button.home"),homeActive,homeEnabled,homeEnabled&&homeButtonHit(mouseX,mouseY));
    

    String shellTitle=activeModule<0?"SynKinect Studio":modules[activeModule].title();
    
    fill(0xFFE7EDF3);textAlign(LEFT,CENTER);studioText(STUDIO_FONT_BODY,true);
    fitCurrentTextSize(shellTitle,STUDIO_FONT_BODY,12,shellTitleW(),shellButtonH()-4);
    
    text(shellTitle,shellTitleX(),shellButtonY()+shellButtonH()*.5f);

    String deviceLabel=services.devices.selectorLabel();
    drawShellButton(deviceButtonX(),deviceButtonW(),deviceLabel,false,services.devices.count()>0,deviceButtonHit(mouseX,mouseY));
    

    String lang=studio.i18n.tr("button.language")+" · "+studio.i18n.shortLanguage();
    
    drawShellButton(languageButtonX(),languageButtonW(),lang,false,true,languageButtonHit(mouseX,mouseY));
    
    drawCloseButton();
    textAlign(LEFT,BASELINE);
  }

  void drawCloseButton(){
    boolean hot=closeButtonHit(mouseX,mouseY);pushStyle();stroke(hot?0xFFE17D7D:0xFF35414D);
    fill(hot?0xFF4A2428:0xFF181E25);rect(closeButtonX(),shellButtonY(),closeButtonW(),shellButtonH(),9);
    noStroke();fill(hot?0xFFFFB0B0:0xFFD4DCE4);textAlign(CENTER,CENTER);studioText(20,true);
    text("×",closeButtonX()+closeButtonW()*.5f,shellButtonY()+shellButtonH()*.48f);
    popStyle();
  }

  boolean isReady(int moduleIndex){return moduleIndex>=0&&!transitioning&&ownedModule==moduleIndex;
    }
  int moduleIndexForState(Object state){if(state==null||modules==null)return -1;for(int i=0;i<modules.length;i++)if(modules[i].localState()==state)return i;
    return -1;}
  boolean isStateReady(Object state){return isReady(moduleIndexForState(state));}
  boolean isStateActive(Object state){int index=moduleIndexForState(state);return index>=0&&activeModule==index;
    }
  String activeLeaveBlockReason(){if(activeModule<0||activeModule>=modules.length)return "";
    String reason=modules[activeModule].leaveBlockReason();return reason==null?"":reason.trim();
    }
  boolean blockActiveLeaveIfRequired(){String reason=activeLeaveBlockReason();if(reason.isEmpty())return false;
    modules[activeModule].blockedAction(reason);return true;}
  String closeBlockReason(){if(modules==null)return "";for(StudioModuleBase module:modules){if(module==null||module.phase==ModulePhase.NEW||module.phase==ModulePhase.INIT_FAILED||module.phase==ModulePhase.DISPOSED)continue;
      String reason=module.closeBlockReason();if(reason!=null&&!reason.trim().isEmpty()){module.blockedAction(reason.trim());
        return reason.trim();}}return "";}
  boolean blockCloseIfRequired(){String reason=closeBlockReason();if(reason.isEmpty())return false;
    studioCloseIntent=false;studioCloseDispatchPending=false;return true;}

  void mousePressed(){
    if(closeButtonHit(mouseX,mouseY)){requestStudioClose();return;}
    if(homeButtonHit(mouseX,mouseY)){goHome();return;}
    if(deviceButtonHit(mouseX,mouseY)){cycleKinect();return;}
    if(languageButtonHit(mouseX,mouseY)){cycleLanguage();return;}
    if(activeModule<0){float cmx=contentMouseX(),cmy=contentMouseY();if(beginHomeScrollbarDrag(cmx,cmy))return;
      String action=homeSystemPanel.actionAt(cmx,cmy);if(action!=null){systemControl.run(action);
        return;}int card=homeCardAt(cmx,cmy);if(card>=0)select(card,false);return;
      }
    if(!isReady(activeModule))return;
    modules[activeModule].mousePressedModule();
  }
  void mouseDragged(){
    if(activeModule<0){dragHomeScrollbar(contentMouseY());return;}if(isReady(activeModule))modules[activeModule].mouseDraggedModule();
    
  }
  void mouseReleased(){homeScrollDragging=false;if(activeModule>=0&&isReady(activeModule))modules[activeModule].mouseReleasedModule();
    }
  void mouseWheel(processing.event.MouseEvent event){if(activeModule<0){homeScrollBy(event==null?0:event.getCount());
      return;}if(isReady(activeModule))modules[activeModule].mouseWheelModule(event);
    }
  void keyPressed(){if(activeModule>=0&&isReady(activeModule))modules[activeModule].keyPressedModule();
    }


  void goHome(){
    if(activeModule>=0&&blockActiveLeaveIfRequired())return;
    activeModule=-1;homeScrollY=0;homeScrollDragging=false;
    synchronized(lifecycleLock){desiredModule=-1;transitioning=ownedModule>=0;lifecycleLock.notifyAll();
      }
    updateTitle();
  }

  void select(int next,boolean initial){
    next=constrain(next,0,modules.length-1);
    if(!initial&&next!=activeModule&&activeModule>=0&&blockActiveLeaveIfRequired())return;
    
    if(!initial&&next==activeModule&&desiredModule==next&&modules[next].phase==ModulePhase.READY)return;
    
    activeModule=next;
    modules[next].prepareRetry();
    synchronized(lifecycleLock){
      desiredModule=next;
      transitioning=ownedModule!=next;
      lifecycleLock.notifyAll();
    }
    updateTitle();
  }

  void updateTitle(){if(ready)surface.setTitle(activeModule<0?"SynKinect Studio":"SynKinect Studio — "+modules[activeModule].title());
    }

  void startLifecycle(){
    synchronized(lifecycleLock){if(lifecycleRun)return;lifecycleRun=true;}
    lifecycleThread=services.workers.start("Lifecycle",new Runnable(){public void run(){lifecycleLoop();}});
    
  }

  void lifecycleLoop(){
    while(true){
      int next;
      synchronized(lifecycleLock){
        while(lifecycleRun&&desiredModule==ownedModule){
          transitioning=false;
          try{lifecycleLock.wait();}catch(InterruptedException ignored){if(!lifecycleRun)return;
            }
        }
        if(!lifecycleRun)return;
        next=desiredModule;
        transitioning=true;
      }
      boolean operationHeld=false;
      try{
        operationLock.lockInterruptibly();operationHeld=true;
        int previous=ownedModule;
        transitionTarget=next;
        if(previous>=0&&next!=previous){
          String reason=modules[previous].leaveBlockReason();
          if(reason!=null&&!reason.trim().isEmpty()){
            modules[previous].blockedAction(reason.trim());
            synchronized(lifecycleLock){desiredModule=previous;transitioning=false;
              lifecycleLock.notifyAll();}
            transitionTarget=-1;
            continue;
          }
        }
        if(previous>=0){modules[previous].deactivateModule();ownedModule=-1;}
        synchronized(lifecycleLock){if(!lifecycleRun){transitionTarget=-1;return;
            }next=desiredModule;transitionTarget=next;}
        if(next>=0){
          StudioModuleBase target=modules[next];
          target.initialize();
          if(target.phase==ModulePhase.READY){
            try{
              target.activateModule();
              ownedModule=next;
            }catch(Exception activationError){
              target.activationFailure(activationError);
              ownedModule=-1;
              try{target.deactivateModule();}catch(Exception cleanupError){println("Module activation cleanup warning ["+target.moduleKey+"]: "+safeStudioMessage(cleanupError));
                }
              synchronized(lifecycleLock){if(desiredModule==next)desiredModule=-1;
                }
              println("Module activation failed ["+target.moduleKey+"]: "+target.failureMessage);
              
              activationError.printStackTrace();
            }
          }else{
            ownedModule=-1;
            synchronized(lifecycleLock){if(desiredModule==next)desiredModule=-1;}
          }
        }else ownedModule=-1;
        transitionTarget=-1;
      }catch(InterruptedException interrupted){
        if(!lifecycleRun)return;
        Thread.currentThread().interrupt();
      }catch(Exception e){
        ownedModule=-1;
        synchronized(lifecycleLock){if(desiredModule==next)desiredModule=-1;}
        println("Studio module transition warning: "+safeStudioMessage(e));e.printStackTrace();
        
      }finally{
        if(operationHeld)operationLock.unlock();
      }
      synchronized(lifecycleLock){transitioning=ownedModule!=desiredModule;lifecycleLock.notifyAll();
        }
    }
  }

  Thread detachLifecycle(){
    Thread t;
    synchronized(lifecycleLock){
      lifecycleRun=false;transitioning=false;lifecycleLock.notifyAll();t=lifecycleThread;
      lifecycleThread=null;
    }
    if(t!=null&&t!=Thread.currentThread())t.interrupt();
    return t;
  }

  void dispose(){
    if(shuttingDown)return;
    shuttingDown=true;
    final Thread lifecycle=detachLifecycle();
    // The Processing animation thread must never wait for USB, named-pipe or
    // Unix-socket workers. Cleanup remains best-effort and idempotent in a daemon
    // worker; the process-level close watchdog provides the absolute deadline.
    services.workers.start("Shutdown",new Runnable(){public void run(){disposeBlocking(lifecycle);}});
    
  }

  void disposeBlocking(Thread lifecycle){
    if(lifecycle!=null&&lifecycle!=Thread.currentThread()){
      try{lifecycle.join(750);}catch(InterruptedException ignored){Thread.currentThread().interrupt();
        }
    }
    boolean operationHeld=false;
    try{
      operationHeld=operationLock.tryLock(500,java.util.concurrent.TimeUnit.MILLISECONDS);
      
      for(int i=modules.length-1;i>=0;i--){
        try{if(modules[i].ownsResources())modules[i].disposeModule();}catch(Exception ignored){}finally{modules[i].markDisposed();
          }
      }
      closeStudioModuleResources(modules);
      services.spatialAudioSessions.stopAll();
      moduleStates.clear();
    }catch(InterruptedException e){Thread.currentThread().interrupt();}
    finally{if(operationHeld)operationLock.unlock();}
  }
}



float homeContentWidth(){return max(320,studio.ui.metrics().workspaceWidth());}
float homeModuleGap(){return max(14,studio.ui.metrics().gap);}
int homeModuleCols(){
  int count=studio.modules==null?0:studio.modules.length;if(count<=0)return 1;
  float cw=homeContentWidth(),gap=homeModuleGap(),minimum=280*studioUiScale();
  return min(count,max(1,floor((cw+gap)/(minimum+gap))));
}
float homeTitleY(){return max(24,30*studioUiScale());}
float homeScrollTop(){return max(86,94*studioUiScale());}
float homeScrollBottom(){return max(homeScrollTop()+80,studio.contentHeight-max(16,20*studioUiScale()));
  }
float homeModuleStartY(){return homeScrollTop()+max(8,12*studioUiScale());}
float homeModuleCardH(){return constrain(studio.contentHeight*.17f,132,220*studioUiScale());
  }
float homeModuleCardW(){int cols=homeModuleCols();return (homeContentWidth()-homeModuleGap()*(cols-1))/cols;
  }
float homeModuleEndY(){int rows=(studio.modules.length+homeModuleCols()-1)/homeModuleCols();
  return homeModuleStartY()+rows*homeModuleCardH()+max(0,rows-1)*homeModuleGap();
  }
float homeSystemPanelY(){return homeModuleEndY()+max(16,20*studioUiScale());}
float homeContentEndY(){return homeSystemPanelY()+studio.homeSystemPanel.preferredHeight(homeContentWidth())+max(18,24*studioUiScale());
  }
void updateHomeScrollBounds(){float viewport=max(1,homeScrollBottom()-homeScrollTop());
  float logical=max(0,homeContentEndY()-homeScrollTop());studio.homeMaxScroll=max(0,logical-viewport);
  studio.homeScrollY=constrain(studio.homeScrollY,0,studio.homeMaxScroll);}
void homeScrollBy(float amount){updateHomeScrollBounds();if(studio.homeMaxScroll<=0)return;
  studio.homeScrollY=constrain(studio.homeScrollY+amount*max(32,studio.ui.metrics().buttonH*.95f),0,studio.homeMaxScroll);
  }
float homeScrollbarTrackX(){return width-18;}
float homeScrollbarTrackW(){return 12;}
float homeScrollbarThumbH(){float track=max(1,homeScrollBottom()-homeScrollTop());
  return max(34,track*(track/(track+studio.homeMaxScroll)));}
float homeScrollbarThumbY(){float track=max(1,homeScrollBottom()-homeScrollTop()),thumb=homeScrollbarThumbH();
  return homeScrollTop()+(track-thumb)*(studio.homeMaxScroll<=0?0:studio.homeScrollY/studio.homeMaxScroll);
  }
boolean beginHomeScrollbarDrag(float mx,float my){updateHomeScrollBounds();if(studio.homeMaxScroll<=0||mx<homeScrollbarTrackX()||mx>homeScrollbarTrackX()+homeScrollbarTrackW()||my<homeScrollTop()||my>homeScrollBottom())return false;
  float thumb=homeScrollbarThumbH(),thumbY=homeScrollbarThumbY();if(my<thumbY||my>thumbY+thumb){float track=max(1,homeScrollBottom()-homeScrollTop()-thumb);
    studio.homeScrollY=constrain(((my-homeScrollTop()-thumb*.5f)/track)*studio.homeMaxScroll,0,studio.homeMaxScroll);
    thumbY=homeScrollbarThumbY();}studio.homeScrollDragging=true;studio.homeScrollDragOffset=constrain(my-thumbY,0,thumb);
  return true;}
void dragHomeScrollbar(float my){if(!studio.homeScrollDragging)return;updateHomeScrollBounds();
  if(studio.homeMaxScroll<=0){studio.homeScrollDragging=false;return;}float thumb=homeScrollbarThumbH(),track=max(1,homeScrollBottom()-homeScrollTop()-thumb),
  thumbY=constrain(my-studio.homeScrollDragOffset,homeScrollTop(),homeScrollTop()+track);
  studio.homeScrollY=constrain(((thumbY-homeScrollTop())/track)*studio.homeMaxScroll,0,studio.homeMaxScroll);
  }
void drawHomeScrollbar(){if(studio.homeMaxScroll<=0)return;float top=homeScrollTop(),bottom=homeScrollBottom(),track=max(1,bottom-top),thumb=max(34,track*(track/(track+studio.homeMaxScroll))),
  thumbY=top+(track-thumb)*(studio.homeScrollY/studio.homeMaxScroll);pushStyle();
  noStroke();fill(0xFF2D3945);rect(width-11,top,3,track,2);fill(0xFF68A9E8);rect(width-11,thumbY,3,thumb,2);
  popStyle();}

void drawStudioHome(){
  background(0xFF10151B);float cw=homeContentWidth(),cx=(width-cw)/2;
  fill(0xFFF4F7FA);textAlign(CENTER,TOP);studioText(31,true);text("SynKinect Studio",width/2,homeTitleY());
  
  updateHomeScrollBounds();float scroll=studio.homeScrollY,clipTop=homeScrollTop(),clipBottom=homeScrollBottom();
  
  clip(0,clipTop,width,max(1,clipBottom-clipTop));
  int cols=homeModuleCols();float gap=homeModuleGap(),cardW=homeModuleCardW(),cardH=homeModuleCardH(),startY=homeModuleStartY();
  
  for(int i=0;i<studio.modules.length;i++){
    int row=i/cols,col=i%cols;float x=cx+col*(cardW+gap),logicalY=startY+row*(cardH+gap),y=logicalY-scroll;
    if(y+cardH<clipTop||y>clipBottom)continue;boolean hot=mouseX>=x&&mouseX<=x+cardW&&studio.contentMouseY()>=y&&studio.contentMouseY()<=y+cardH;
    
    stroke(hot?0xFF68A9E8:0xFF2D3945);fill(hot?0xFF1F2A34:0xFF171E25);rect(x,y,cardW,cardH,12);
    noStroke();fill(0xFFF4F7FA);textAlign(LEFT,TOP);studioText(STUDIO_FONT_BODY,true);
    String cardTitle=studio.modules[i].title();fitCurrentTextSize(cardTitle,STUDIO_FONT_BODY,11,cardW-32,27);
    text(ellipsizeToWidth(cardTitle,cardW-32),x+16,y+14);fill(0xFFAAB6C2);studioText(STUDIO_FONT_SMALL,false);
    float descriptionY=y+45,descriptionH=max(30,cardH-57);text(homeModuleDescription(i),x+16,descriptionY,cardW-32,descriptionH);
    
  }
  float panelY=homeSystemPanelY()-scroll;studio.homeSystemPanel.draw(cx,panelY,cw,studio.homeSystemPanel.preferredHeight(cw));
  
  noClip();drawHomeScrollbar();
}
String homeModuleDescription(int i){return i>=0&&i<studio.modules.length?studio.modules[i].description():"";
  }
int homeCardAt(float mx,float my){if(my<homeScrollTop()||my>homeScrollBottom())return -1;
  float cw=homeContentWidth(),cx=(width-cw)/2;int cols=homeModuleCols();float gap=homeModuleGap(),cardW=homeModuleCardW(),cardH=homeModuleCardH(),startY=homeModuleStartY(),
  scroll=studio.homeScrollY;for(int i=0;i<studio.modules.length;i++){int row=i/cols,col=i%cols;
    float x=cx+col*(cardW+gap),y=startY+row*(cardH+gap)-scroll;if(mx>=x&&mx<=x+cardW&&my>=y&&my<=y+cardH)return i;
    }return -1;}


class StudioHomeSystemPanel {
  final String[] actions={"Install","Status","OpenCamera","Tilt","StartupTilt","RgbHqToggle","IpStatus","IpReset","IpToggle","Uninstall"};
  
  final StudioUiButton[] buttons=new StudioUiButton[actions.length];
  StudioHomeSystemPanel(){for(int i=0;i<buttons.length;i++)buttons[i]=new StudioUiButton();
    }
  String label(String action){return studio.i18n.tr("system."+action.toLowerCase(Locale.ROOT));
    }
  float innerWidth(float w){return max(1,w);}
  float preferredHeight(float w){StudioUiMetrics metrics=studio.ui.metrics();float inner=innerWidth(w),header=58*studioUiScale(),actionsH=studio.ui.actionPanelHeight(inner,
      actions.length,false)-metrics.cardTitleH;return max(154,header+actionsH+metrics.footerH+metrics.gap);
    }
  void draw(float x,float y,float w,float h){
    float innerW=innerWidth(w),innerX=x+(w-innerW)*0.5f;
    fill(0xFFE7EDF3);textAlign(CENTER,TOP);studioText(STUDIO_FONT_BODY,true);String title=studio.i18n.tr("system.title");
    fitCurrentTextSize(title,STUDIO_FONT_BODY,11,innerW,26);text(ellipsizeToWidth(title,innerW),x+w*0.5f,y);
    
    fill(0xFF8999A8);studioText(STUDIO_FONT_SMALL,false);String description=studio.i18n.tr("system.description");
    fitCurrentTextSize(description,STUDIO_FONT_SMALL,10,innerW,24);text(ellipsizeToWidth(description,innerW),x+w*0.5f,y+27);
    
    StudioUiMetrics metrics=studio.ui.metrics();float top=y+max(54,58*studioUiScale()),footer=metrics.footerH,footerY=y+h-footer;
    float buttonAreaH=max(metrics.buttonMinH,footerY-top-max(4,metrics.gap*.45f));
    ArrayList<StudioUiButton> list=new ArrayList<StudioUiButton>();for(int i=0;i<buttons.length;i++){buttons[i].configure(label(actions[i]),studio.systemControl.actionEnabled(actions[i]),
        false,false,false);list.add(buttons[i]);}studio.ui.layoutButtons(list,innerX,top,innerW,buttonAreaH);
    for(StudioUiButton button:list)button.draw();
    String state=studio.systemControl.message();studio.ui.renderer.statusFooter(innerX,footerY,innerW,footer,state,studio.systemControl.lastOk);
    
  }
  String actionAt(float mx,float my){if(!studio.systemControl.available())return null;
    for(int i=0;i<buttons.length;i++)if(studio.systemControl.actionEnabled(actions[i])&&buttons[i].hit(mx,my))return actions[i];
    return null;}
}

class StudioSystemControl {
  volatile String lastMessage="";volatile boolean lastOk=true;volatile boolean controlResolved=false,rgbHqBusy=false;
  volatile File controlScript=null;
  boolean supported(){return studio.services.transportFactory.isWindows()||studio.services.transportFactory.isLinux();
    }
  boolean available(){return supported()&&findControlScript()!=null;}
  boolean actionEnabled(String action){
    if(!available())return false;
    KinectDevice d=studio.selectedKinect();
    if("OpenCamera".equals(action))return d!=null&&d.virtualCameraReady();
    if("Tilt".equals(action)||"StartupTilt".equals(action))return d!=null&&d.controlReady();
    if("RgbHqToggle".equals(action))return !rgbHqBusy&&d!=null&&d.cameraReady();
    
    return true;
  }
  String message(){if(lastMessage!=null&&lastMessage.length()>0)return lastMessage;
    if(!supported())return studio.i18n.tr("system.unsupported");if(findControlScript()==null)return studio.i18n.tr("system.not_found");
    return studio.i18n.tr("system.ready");}
  synchronized File findControlScript(){
    if(controlResolved)return controlScript;
    File[] candidates=studio.services.transportFactory.isWindows()
      ?new File[]{studio.services.paths.runtimeFile("../../drivers/system/Kinect.ps1")}
      :new File[]{studio.services.paths.runtimeFile("../../drivers/KINECT.sh")};
    for(File candidate:candidates){try{File f=candidate.getCanonicalFile();if(f.isFile()){controlScript=f;
          break;}}catch(IOException ignored){}}
    controlResolved=true;return controlScript;
  }
  String psLiteral(String value){return "'"+(value==null?"":value.replace("'","''"))+"'";
    }
  String shQuote(String value){return "'"+(value==null?"":value.replace("'","'\\''"))+"'";
    }
  boolean commandAvailable(String name){
    String path=System.getenv("PATH");if(path==null||path.length()==0)return false;
    
    for(String dir:path.split(File.pathSeparator)){if(dir==null||dir.length()==0)continue;
      File f=new File(dir,name);if(f.isFile()&&f.canExecute())return true;}
    return false;
  }
  ProcessBuilder linuxTerminal(String command)throws IOException{
    if(commandAvailable("x-terminal-emulator"))return new ProcessBuilder("x-terminal-emulator","-e","bash","-lc",command);
    
    if(commandAvailable("gnome-terminal"))return new ProcessBuilder("gnome-terminal","--","bash","-lc",command);
    
    if(commandAvailable("konsole"))return new ProcessBuilder("konsole","-e","bash","-lc",command);
    
    if(commandAvailable("mate-terminal"))return new ProcessBuilder("mate-terminal","--","bash","-lc",command);
    
    if(commandAvailable("xterm"))return new ProcessBuilder("xterm","-e","bash","-lc",command);
    
    throw new IOException("No supported Linux terminal emulator was found (x-terminal-emulator, gnome-terminal, konsole, mate-terminal or xterm).");
    
  }
  ProcessBuilder directRgbHqCommand(File target,String deviceId){
    ProcessBuilder builder=studio.services.transportFactory.isWindows()
      ?new ProcessBuilder("powershell.exe","-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-File",target.getAbsolutePath(),"-Action","RgbHqToggle","-DeviceId",deviceId,"-NoPause")
      :new ProcessBuilder("bash",target.getAbsolutePath(),"--action","RgbHqToggle","--device-id",deviceId);
    builder.directory(target.getParentFile());builder.redirectErrorStream(true);return builder;
  }
  String readProcessOutput(Process process)throws IOException{
    StringBuilder output=new StringBuilder();
    try(BufferedReader reader=new BufferedReader(new InputStreamReader(process.getInputStream(),java.nio.charset.StandardCharsets.UTF_8))){
      String line;while((line=reader.readLine())!=null){line=line.trim();if(line.length()==0)continue;
        if(output.length()>4096)output.delete(0,Math.max(0,output.length()-2048));
        if(output.length()>0)output.append('\n');output.append(line);
      }
    }
    return output.toString();
  }
  String lastProcessLine(String output){
    if(output==null||output.length()==0)return "command failed";
    String[] lines=output.split("\\r?\\n");
    for(int i=lines.length-1;i>=0;i--){String line=lines[i].trim();if(line.length()>0)return line;}
    return "command failed";
  }
  void runRgbHqToggle(final File target){
    if(rgbHqBusy)return;
    rgbHqBusy=true;lastOk=true;lastMessage=studio.i18n.format("system.started","RGB HQ");
    studio.services.workers.startLowPriority("System-Control-RGB-HQ",new Runnable(){public void run(){
      try{
        KinectDevice selected=studio.selectedKinect();
        if(selected==null||!selected.cameraReady())throw new IOException("Kinect camera transport is not ready");
        final String deviceId=selected.id;
        Process process=directRgbHqCommand(target,deviceId).start();
        String output=readProcessOutput(process);int code=process.waitFor();
        if(code!=0)throw new IOException(lastProcessLine(output)+" (exit "+code+")");

        String lower=output.toLowerCase(Locale.ROOT);
        Boolean enabled=lower.indexOf("rgb-hq=on")>=0?Boolean.TRUE:(lower.indexOf("rgb-hq=off")>=0?Boolean.FALSE:null);
        KinectDevice current=studio.selectedKinect();
        if(current!=null&&deviceId.equals(current.id)){
          try{ScannerModuleState scanner=studio.state(ScannerModuleState.class);
            if(scanner!=null&&scanner.source!=null){
              if(enabled!=null)scanner.source.applyDriverRgbHq(current,enabled.booleanValue());
              else scanner.source.refreshDriverRgbHq(current);
            }
          }catch(Exception ignored){}
        }
        if(Boolean.TRUE.equals(enabled))lastMessage="RGB HQ: ON";
        else if(Boolean.FALSE.equals(enabled))lastMessage="RGB HQ: OFF";
        else lastMessage="RGB HQ";
        lastOk=true;
      }catch(InterruptedException interrupted){Thread.currentThread().interrupt();lastOk=false;lastMessage=studio.i18n.format("system.failed","RGB HQ");}
      catch(Exception e){lastOk=false;lastMessage=studio.i18n.format("system.failed",safeStudioMessage(e));}
      finally{rgbHqBusy=false;}
    }});
  }
  void run(final String action){
    File script=findControlScript();if(!supported()){lastOk=false;lastMessage=studio.i18n.tr("system.unsupported");
      return;}if(script==null){lastOk=false;lastMessage=studio.i18n.tr("system.not_found");
      return;}
    final File target=script;
    if("RgbHqToggle".equals(action)){runRgbHqToggle(target);return;}
    lastOk=true;lastMessage=studio.i18n.format("system.started",studio.i18n.tr("system."+action.toLowerCase(Locale.ROOT)));
    studio.services.workers.startLowPriority("System-Control-"+action,new Runnable(){public void run(){try{
      KinectDevice selected=studio.selectedKinect();String deviceId=selected==null?"":selected.id;
      boolean needsDevice="OpenCamera".equals(action)||"Tilt".equals(action)||"StartupTilt".equals(action);
      if(studio.services.transportFactory.isWindows()){
        String childArgs="@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"+psLiteral(target.getAbsolutePath())+",'-Action',"+psLiteral(action)+(needsDevice?",'-DeviceId',"+psLiteral(deviceId):"")+")";
        String command="$a="+childArgs+"; Start-Process -FilePath 'powershell.exe' -ArgumentList $a";
        new ProcessBuilder("powershell.exe","-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-Command",command).directory(target.getParentFile()).start();
      }else{
        String command="REMOLD_GUI=1 bash "+shQuote(target.getAbsolutePath())+" --action "+shQuote(action)+(needsDevice?" --device-id "+shQuote(deviceId):"")+"; rc=$?; printf '\n'; read -r -p 'Press Enter to close: ' _ || true; exit $rc";
        linuxTerminal(command).directory(target.getParentFile()).start();
      }
    }catch(Exception e){lastOk=false;lastMessage=studio.i18n.format("system.failed",safeStudioMessage(e));}}});
    
  }
}

void drawModuleStartup(StudioModuleBase module){
  background(0xFF10151B);
  fill(0xFFF4F7FA);textAlign(CENTER,CENTER);studioText(22,true);
  String title=module.title();
  fitCurrentTextSize(title,22,9,width-48,36);text(ellipsizeToWidth(title,width-48),width*0.5f,max(80,(height-STUDIO_TOP_BAR_H)*0.42f));
  
  fill(0xFFAAB6C2);studioText(STUDIO_FONT_SMALL,false);
  String message=(module.phase==ModulePhase.INIT_FAILED||module.phase==ModulePhase.ACTIVATE_FAILED)
    ? studio.i18n.format("startup.failed",module.failureMessage)
    : module.phase==ModulePhase.RENDER_FAILED
      ? studio.i18n.format("startup.render_failed",module.failureMessage)
      : studio.i18n.tr("startup.loading");
  fitCurrentTextSize(message,STUDIO_FONT_SMALL,8,width-48,30);text(ellipsizeToWidth(message,width-48),width*0.5f,max(120,(height-STUDIO_TOP_BAR_H)*0.42f+42));
  
  textAlign(LEFT,BASELINE);
}

String safeStudioMessage(Throwable e){String m=e==null?null:e.getMessage();return m==null||m.length()==0?(e==null?"unknown":e.getClass().getSimpleName()):m;
  }

// One parsing policy for every Studio module. Invalid or missing values always
// resolve to the caller-provided default and bounded values are clamped here.
// File I/O error reporting is centralized here for all modules.
class ConfigRules {
  Properties load(File file,String scope){
    Properties p=new Properties();
    if(file==null||!file.isFile())return p;
    try(InputStream in=new FileInputStream(file);Reader reader=new InputStreamReader(in,java.nio.charset.StandardCharsets.UTF_8)){p.load(reader);
      }
    catch(IOException e){println(scope+"-config: "+safeStudioMessage(e));}
    return p;
  }
  String text(Properties p,String key,String fallback){String v=p==null?null:p.getProperty(key);
    return v==null||v.trim().isEmpty()?fallback:v.trim();}
  boolean flag(Properties p,String key,boolean fallback){
    String v=text(p,key,"");if(v.isEmpty())return fallback;
    if("true".equalsIgnoreCase(v)||"1".equals(v)||"yes".equalsIgnoreCase(v)||"on".equalsIgnoreCase(v))return true;
    
    if("false".equalsIgnoreCase(v)||"0".equals(v)||"no".equalsIgnoreCase(v)||"off".equalsIgnoreCase(v))return false;
    
    return fallback;
  }
  int integer(Properties p,String key,int fallback){try{return Integer.parseInt(text(p,key,String.valueOf(fallback)));
      }catch(NumberFormatException e){return fallback;}}
  int integer(Properties p,String key,int fallback,int lo,int hi){return Math.max(lo,Math.min(hi,integer(p,key,fallback)));
    }
  long longNumber(Properties p,String key,long fallback){return longNumber(text(p,key,String.valueOf(fallback)),fallback);
    }
  long longNumber(String value,long fallback){try{return Long.parseLong(value==null?"":value.trim());
      }catch(NumberFormatException e){return fallback;}}
  long longNumber(Properties p,String key,long fallback,long lo,long hi){long v=longNumber(p,key,fallback);
    return Math.max(lo,Math.min(hi,v));}
  float decimal(Properties p,String key,float fallback){try{return Float.parseFloat(text(p,key,String.valueOf(fallback)));
      }catch(NumberFormatException e){return fallback;}}
  float decimal(Properties p,String key,float fallback,float lo,float hi){return Math.max(lo,Math.min(hi,decimal(p,key,fallback)));
    }
  int even(Properties p,String key,int fallback,int lo,int hi){int v=integer(p,key,fallback,lo,hi);
    return (v&1)==0?v:Math.max(lo,v-1);}
  float[] decimalList(String value,int count){
    if(value==null)return null;String[] parts=value.split(",");if(parts.length!=count)return null;
    float[] out=new float[count];
    try{for(int i=0;i<count;i++)out[i]=Float.parseFloat(parts[i].trim());return out;
      }catch(NumberFormatException e){return null;}
  }
}

class StudioShellConfig {
  final ConfigRules rules;
  StudioShellConfig(ConfigRules rules){this.rules=rules;}
  String language="en-US";
  String languages="";
  int uiFrameRate=30,uiMinFrameRate=24,uiMaxFrameRate=60;
  float uiFontScale=1.0f;
  void load(File file){
    Properties p=rules.load(file,"studio");
    language=rules.text(p,"app.language",language);
    languages=rules.text(p,"app.languages",languages);
    uiMinFrameRate=rules.integer(p,"ui.minFrameRate",uiMinFrameRate,1,240);
    uiMaxFrameRate=rules.integer(p,"ui.maxFrameRate",uiMaxFrameRate,uiMinFrameRate,240);
    
    uiFrameRate=rules.integer(p,"ui.frameRate",uiFrameRate,uiMinFrameRate,uiMaxFrameRate);
    
    uiFontScale=rules.decimal(p,"ui.fontScale",uiFontScale,0.90f,1.35f);
  }
}

Properties loadStudioProperties(File file){return studio.services.configRules.load(file,"studio");
  }

class StudioPaths {
  final File runtimeRoot=studioRuntimeRoot();
  File resource(String app,String relative){return new File(new File(runtimeRoot,"data"),safeSegment(app)+"/"+relative);
    }
  File appRoot(String app){return new File(new File(runtimeRoot,"data"),safeSegment(app));
    }
  File runtimeFile(String relative){return new File(runtimeRoot,relative==null?"":relative);
    }
  File appDataRoot(String app){
    File root=new File(appRoot(app),"output");
    if(!root.exists())root.mkdirs();
    return root;
  }
  File dataFile(String app,String relative){
    Path root=appDataRoot(app).toPath().toAbsolutePath().normalize();
    String clean=relative==null?"":relative.trim();
    if(clean.length()==0)clean="data";
    try{
      Path requested=Paths.get(clean);
      if(requested.isAbsolute())clean=requested.getFileName()==null?"data":requested.getFileName().toString();
      
    }catch(Exception ignored){clean="data";}
    Path candidate=root.resolve(clean).normalize();
    if(!candidate.startsWith(root))candidate=root.resolve("data");
    return candidate.toFile();
  }
  File dataDirectory(String app,String configured,String fallback){
    String value=configured==null?"":configured.trim();
    if(value.length()==0)value=fallback;
    File result=dataFile(app,value);
    if(!result.exists())result.mkdirs();
    return result;
  }
  String safeSegment(String value){String s=value==null?"app":value.replaceAll("[^A-Za-z0-9._-]","_");
    return s.length()==0?"app":s;}
}

class AppI18nCatalog {
  final String app;
  final ArrayList<String> supported=new ArrayList<String>();
  final HashMap<String,Properties> catalogs=new HashMap<String,Properties>();
  String fallback="";
  AppI18nCatalog(String app){this.app=app;discover();}
  void discover(){
    File dir=studio.services.paths.resource(app,"i18n");File[] files=dir.listFiles();
    if(files==null)return;
    Arrays.sort(files,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});
    
    for(File file:files){
      if(!file.isFile()||!file.getName().toLowerCase(Locale.ROOT).endsWith(".properties"))continue;
      
      Properties catalog=loadStudioProperties(file);String inferred=file.getName().substring(0,file.getName().length()-11);
      
      String locale=catalog.getProperty("meta.locale",inferred).trim();if(locale.length()==0||catalogs.containsKey(locale))continue;
      
      supported.add(locale);catalogs.put(locale,catalog);if("true".equalsIgnoreCase(catalog.getProperty("meta.default","false")))fallback=locale;
      
    }
    if(fallback.length()==0&&!supported.isEmpty())fallback=supported.get(0);
  }
  String resolve(String requested){
    if(supported.isEmpty())return "";String value=requested==null?"auto":requested.trim();
    
    if(value.length()==0||"auto".equalsIgnoreCase(value))value=Locale.getDefault().toLanguageTag();
    
    for(String locale:supported)if(locale.equalsIgnoreCase(value))return locale;
    String prefix=value.toLowerCase(Locale.ROOT).split("[-_]")[0];
    for(String locale:supported)if(locale.toLowerCase(Locale.ROOT).split("[-_]")[0].equals(prefix))return locale;
    
    return fallback;
  }
  String raw(String locale,String key,String d){
    Properties active=catalogs.get(locale);String value=active==null?null:active.getProperty(key);
    
    if(value==null&&fallback.length()>0){Properties base=catalogs.get(fallback);value=base==null?null:base.getProperty(key);
      }
    return value==null?d:value;
  }
  String meta(String locale,String key,String d){return raw(locale,key,d);}
  void applyOrder(String csv){
    if(csv==null||csv.trim().length()==0)return;ArrayList<String> ordered=new ArrayList<String>();
    
    for(String token:csv.split(",")){String wanted=token.trim();for(String locale:supported)if(locale.equalsIgnoreCase(wanted)&&!ordered.contains(locale))ordered.add(locale);
      }
    for(String locale:supported)if(!ordered.contains(locale))ordered.add(locale);
    supported.clear();supported.addAll(ordered);
  }
}

class ModuleI18n {
  final String app;final AppI18nCatalog catalog;String language="";boolean rtl=false;
  
  ModuleI18n(String app,String requested){this.app=app;catalog=studio.services.catalog(app);
    language=catalog.resolve(requested);refreshDirection();}
  String resolve(String requested){return catalog.resolve(requested);}
  void setLanguage(String locale){language=resolve(locale);refreshDirection();}
  void refreshDirection(){rtl="rtl".equalsIgnoreCase(catalog.meta(language,"meta.direction","ltr"));
    }
  String raw(String key,String d){return catalog.raw(language,key,d);}
  String tr(String key){return raw(key,key);}
  String format(String key,Object...args){try{return String.format(Locale.ROOT,tr(key),args);
      }catch(Exception e){return tr(key);}}
  String shortLanguage(){return catalog.meta(language,"meta.short",language);}
  int startAlign(){return rtl?RIGHT:LEFT;}
}

class StudioShellI18n extends ModuleI18n {
  StudioShellI18n(String requested){super("studio",requested);}
  void applyOrder(String csv){catalog.applyOrder(csv);language=resolve(language);
    }
  void toggle(){if(catalog.supported.size()<=1)return;int i=catalog.supported.indexOf(language);
    language=catalog.supported.get((i+1+catalog.supported.size())%catalog.supported.size());
    refreshDirection();}
}


float studioUiScale(){return studioUiMetrics().scale;}
float responsiveFontSize(float base){
  float configured=studio==null||studio.config==null?1.0f:studio.config.uiFontScale;
  
  return max(7.5f,base*studioUiScale()*configured);
}
void fitCurrentTextSize(String value,float preferred,float minimum,float maxWidth,float maxHeight){
  float hi=responsiveFontSize(preferred),lo=max(7.0f,responsiveFontSize(minimum));
  
  if(value==null)value="";
  maxWidth=max(1,maxWidth);maxHeight=max(1,maxHeight);
  textSize(hi);
  if(textWidth(value)<=maxWidth&&textAscent()+textDescent()<=maxHeight)return;
  float best=lo,left=lo,right=hi;
  for(int i=0;i<8;i++){
    float mid=(left+right)*0.5f;textSize(mid);
    if(textWidth(value)<=maxWidth&&textAscent()+textDescent()<=maxHeight){best=mid;
      left=mid;}else right=mid;
  }
  textSize(best);
}
String ellipsizeToWidth(String value,float maxWidth){
  if(value==null)return "";
  if(maxWidth<=0)return "";
  if(textWidth(value)<=maxWidth)return value;
  String dots="…";if(maxWidth<=textWidth(dots))return dots;
  // Work in Unicode code points so truncation never splits surrogate pairs.
  int count=value.codePointCount(0,value.length()),lo=0,hi=count,best=0;
  while(lo<=hi){
    int mid=(lo+hi)>>>1;
    int end=value.offsetByCodePoints(0,mid);
    String candidate=value.substring(0,end)+dots;
    if(textWidth(candidate)<=maxWidth){best=mid;lo=mid+1;}else hi=mid-1;
  }
  return value.substring(0,value.offsetByCodePoints(0,best))+dots;
}

// ===== Shared local transport =====
class TransportEndpoint {
  final String windowsPath,linuxPath,label;
  TransportEndpoint(String windowsPath,String linuxPath,String label){this.windowsPath=windowsPath;
    this.linuxPath=linuxPath;this.label=label;}
}

class StudioEndpoints {
  final TransportEndpoint skeleton=new TransportEndpoint("","","nui-skeleton:unavailable");
  
  final String linuxAudioStatus="/run/kinect360-remold/audio-bridge-status.txt";
  TransportEndpoint fromManifest(String endpoint,String label){String value=endpoint==null?"":endpoint.trim();
    if(value.isEmpty())return new TransportEndpoint("","",label+":unavailable");if(studio.services.transportFactory.isWindows())return new TransportEndpoint(value,
      "",label);if(studio.services.transportFactory.isLinux())return new TransportEndpoint("",value,label);
    return new TransportEndpoint("","",label+":unavailable");}
  TransportEndpoint audioFor(String deviceId){KinectDevice d=studio.services.devices.byId(deviceId);
    return fromManifest(d==null?"":d.audio,"audio");}
  TransportEndpoint audioControlFor(String deviceId){KinectDevice d=studio.services.devices.byId(deviceId);
    return fromManifest(d==null?"":d.audioControl,"audio-control");}
  boolean skeletonAvailable(){return false;}
}

class WorkerFactory {
  Thread start(String role,Runnable task){return start(role,task,Thread.NORM_PRIORITY,true);
    }
  Thread startLowPriority(String role,Runnable task){return start(role,task,Thread.MIN_PRIORITY,true);
    }
  Thread startCritical(String role,Runnable task){return start(role,task,Thread.MIN_PRIORITY,false);
    }
  private Thread start(String role,Runnable task,int priority,boolean daemon){
    Thread worker=new Thread(task,"SynKinectStudio-"+role);
    worker.setPriority(priority);
    worker.setDaemon(daemon);
    worker.start();
    return worker;
  }
}

class LocalTransportFactory {
  enum HostPlatform { WINDOWS, LINUX, UNSUPPORTED }
  static final long CONNECT_TIMEOUT_MS=2500;
  static final long READ_TIMEOUT_MS=8000;
  static final long WRITE_TIMEOUT_MS=3000;
  final HostPlatform platform=detectPlatform();
  final ExecutorService windowsIo=Executors.newFixedThreadPool(12,new ThreadFactory(){
    final java.util.concurrent.atomic.AtomicInteger sequence=new java.util.concurrent.atomic.AtomicInteger();
    public Thread newThread(Runnable task){Thread t=new Thread(task,"SynKinectStudio-PipeIO-"+sequence.incrementAndGet());t.setDaemon(true);t.setPriority(Thread.NORM_PRIORITY);return t;}
    
  });
  HostPlatform detectPlatform(){String os=System.getProperty("os.name","").toLowerCase(Locale.ROOT);
    if(os.contains("linux"))return HostPlatform.LINUX;if(os.contains("windows"))return HostPlatform.WINDOWS;
    return HostPlatform.UNSUPPORTED;}
  boolean isLinux(){return platform==HostPlatform.LINUX;}
  boolean isWindows(){return platform==HostPlatform.WINDOWS;}
  LocalTransport openEndpoint(String endpoint)throws IOException {return open(endpoint,endpoint);
    }
  LocalTransport open(String windowsPath,String linuxPath)throws IOException {
    LocalTransport t=new LocalTransport();
    t.windowsExecutor=windowsIo;
    try{
      if(platform==HostPlatform.LINUX){
        SocketChannel channel=SocketChannel.open(StandardProtocolFamily.UNIX);
        channel.configureBlocking(false);
        t.unixChannel=channel;
        UnixDomainSocketAddress address=UnixDomainSocketAddress.of(linuxPath);
        if(!channel.connect(address))finishConnect(channel,CONNECT_TIMEOUT_MS);
      }else if(platform==HostPlatform.WINDOWS){
        final String path=windowsPath;
        t.windowsPipe=awaitWindows(new Callable<RandomAccessFile>(){public RandomAccessFile call()throws Exception{return new RandomAccessFile(path,"rw");}
          },CONNECT_TIMEOUT_MS,"connect");
      }else throw new IOException("Unsupported host platform: "+System.getProperty("os.name","unknown"));
      
      return t;
    }catch(IOException e){try{t.close();}catch(IOException ignored){}throw e;}
  }
  void finishConnect(SocketChannel channel,long timeoutMs)throws IOException {
    final long deadline=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(timeoutMs);
    
    try(Selector selector=Selector.open()){
      channel.register(selector,SelectionKey.OP_CONNECT);
      while(!channel.finishConnect()){
        long remaining=deadline-System.nanoTime();
        if(remaining<=0)throw new SocketTimeoutException("local socket connect timed out");
        
        long wait=Math.max(1,TimeUnit.NANOSECONDS.toMillis(remaining));
        if(selector.select(wait)==0&&System.nanoTime()>=deadline)throw new SocketTimeoutException("local socket connect timed out");
        
        selector.selectedKeys().clear();
      }
    }
  }
  <T>T awaitWindows(Callable<T> operation,long timeoutMs,String phase)throws IOException {
    Future<T> future=windowsIo.submit(operation);
    try{return future.get(timeoutMs,TimeUnit.MILLISECONDS);}
    catch(TimeoutException e){future.cancel(false);SocketTimeoutException timeout=new SocketTimeoutException("Windows local pipe "+phase+" timed out after "+timeoutMs+" ms");
      timeout.initCause(e);throw timeout;}
    catch(InterruptedException e){future.cancel(false);Thread.currentThread().interrupt();
      InterruptedIOException interrupted=new InterruptedIOException("Windows local pipe "+phase+" interrupted");
      interrupted.initCause(e);throw interrupted;}
    catch(ExecutionException e){Throwable cause=e.getCause();if(cause instanceof IOException)throw (IOException)cause;
      IOException failure=new IOException("Windows local pipe "+phase+" failed");
      failure.initCause(cause);throw failure;}
  }
}

class LocalTransport implements Closeable {
  RandomAccessFile windowsPipe;
  ExecutorService windowsExecutor;
  SocketChannel unixChannel;
  volatile boolean closed=false;

  void write(byte[] data)throws IOException {
    if(data==null)return;
    if(closed)throw new EOFException("local transport closed");
    if(windowsPipe!=null){
      final RandomAccessFile pipe=windowsPipe;final byte[] payload=data;
      windowsCall(new Callable<Void>(){public Void call()throws Exception{pipe.write(payload);return null;}},LocalTransportFactory.WRITE_TIMEOUT_MS,"write");
      
      return;
    }
    SocketChannel channel=unixChannel;if(channel==null)throw new EOFException("local transport unavailable");
    
    ByteBuffer buffer=ByteBuffer.wrap(data);long deadline=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(LocalTransportFactory.WRITE_TIMEOUT_MS);
    
    while(buffer.hasRemaining()){
      int n=channel.write(buffer);
      if(n<0)throw new EOFException("local transport closed");
      if(n==0)waitUnix(channel,SelectionKey.OP_WRITE,deadline,"write");
    }
  }
  void readFully(byte[] data)throws IOException {
    if(data==null)return;
    if(closed)throw new EOFException("local transport closed");
    if(windowsPipe!=null){
      final RandomAccessFile pipe=windowsPipe;final byte[] target=data;
      windowsCall(new Callable<Void>(){public Void call()throws Exception{pipe.readFully(target);return null;}},LocalTransportFactory.READ_TIMEOUT_MS,"read");
      
      return;
    }
    SocketChannel channel=unixChannel;if(channel==null)throw new EOFException("local transport unavailable");
    
    ByteBuffer buffer=ByteBuffer.wrap(data);long deadline=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(LocalTransportFactory.READ_TIMEOUT_MS);
    
    while(buffer.hasRemaining()){
      int n=channel.read(buffer);
      if(n<0)throw new EOFException("local transport closed");
      if(n==0)waitUnix(channel,SelectionKey.OP_READ,deadline,"read");
    }
  }
  <T>T windowsCall(Callable<T> operation,long timeoutMs,String phase)throws IOException {
    if(windowsExecutor==null)throw new EOFException("Windows local pipe executor unavailable");
    
    Future<T> future=windowsExecutor.submit(operation);
    try{return future.get(timeoutMs,TimeUnit.MILLISECONDS);}
    catch(TimeoutException e){future.cancel(false);closeWindowsAsync();SocketTimeoutException timeout=new SocketTimeoutException("Windows local pipe "+phase+" timed out after "+timeoutMs+" ms");
      timeout.initCause(e);throw timeout;}
    catch(InterruptedException e){future.cancel(false);Thread.currentThread().interrupt();
      InterruptedIOException interrupted=new InterruptedIOException("Windows local pipe "+phase+" interrupted");
      interrupted.initCause(e);throw interrupted;}
    catch(ExecutionException e){Throwable cause=e.getCause();if(cause instanceof IOException)throw (IOException)cause;
      IOException failure=new IOException("Windows local pipe "+phase+" failed");
      failure.initCause(cause);throw failure;}
  }
  void waitUnix(SocketChannel channel,int operation,long deadline,String phase)throws IOException {
    long remaining=deadline-System.nanoTime();
    if(remaining<=0)throw new SocketTimeoutException("local socket "+phase+" timed out");
    
    try(Selector selector=Selector.open()){
      channel.register(selector,operation);
      long wait=Math.max(1,TimeUnit.NANOSECONDS.toMillis(remaining));
      if(selector.select(wait)==0&&System.nanoTime()>=deadline)throw new SocketTimeoutException("local socket "+phase+" timed out");
      
      selector.selectedKeys().clear();
    }
  }
  void closeWindowsAsync(){
    final RandomAccessFile pipe=windowsPipe;windowsPipe=null;
    if(pipe==null)return;
    // Do not queue cancellation behind the same pool that may contain a stalled
    // pipe read. A dedicated daemon closer can release the native handle and
    // unblock that read even when every regular pipe-I/O worker is occupied.
    try{
      Thread closer=new Thread(new Runnable(){public void run(){try{pipe.close();}catch(IOException ignored){}}},"SynKinectStudio-PipeCloser");
      
      closer.setDaemon(true);closer.start();
    }catch(Throwable ignored){try{pipe.close();}catch(IOException ignored2){}}
  }
  public synchronized void close()throws IOException {
    if(closed)return;
    closed=true;
    IOException failure=null;
    SocketChannel channel=unixChannel;unixChannel=null;
    if(channel!=null){
      try{channel.shutdownInput();}catch(Exception ignored){}
      try{channel.shutdownOutput();}catch(Exception ignored){}
      try{channel.close();}catch(IOException e){failure=e;}
    }
    closeWindowsAsync();
    if(failure!=null)throw failure;
  }
}

