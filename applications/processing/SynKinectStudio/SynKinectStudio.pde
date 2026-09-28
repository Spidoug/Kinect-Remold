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
import javax.swing.*;
import java.awt.image.BufferedImage;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.Robot;
import java.awt.Rectangle;
import java.awt.GraphicsDevice;
import java.awt.GraphicsEnvironment;
import java.awt.FileDialog;
import java.awt.Frame;
import java.awt.Window;
import java.awt.Image;
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

final int STUDIO_FONT_TINY=14;
final int STUDIO_FONT_SMALL=16;
final int STUDIO_FONT_BODY=17;
final int STUDIO_FONT_LABEL=17;
final int STUDIO_FONT_METRIC=22;
final int STUDIO_FONT_TITLE=30;
final int STUDIO_FONT_BUTTON=17;

// Processing requires one PApplet host, but the Studio runtime itself is a normal
// object graph. Every controller owns its services, configuration, module states
// and lifecycle; no module depends on process-wide mutable singletons.
StudioController studio=null;
PFont studioUnicodeRegular,studioUnicodeHeading,studioBrandRegular,studioBrandHeading;
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
  File root=null;
  if(configured.length()>0)root=new File(configured);
  // Resolve packaged resources from the native application image.
  if(root==null){String appPath=System.getProperty("jpackage.app-path","").trim();
    if(appPath.length()>0){File launcher=new File(appPath);File parent=launcher.getParentFile();if(parent!=null)root=parent;}}
  if(root==null)root=new File(System.getProperty("user.dir","."));
  try{return root.getCanonicalFile();}catch(IOException ignored){return root.getAbsoluteFile();
    }
}
File studioRuntimeFile(String relative){return new File(studioRuntimeRoot(),relative==null?"":relative);
  }

BufferedImage studioWindowIconCache=null;
BufferedImage studioWindowIcon(){
  if(studioWindowIconCache!=null)return studioWindowIconCache;
  try{
    File icon=studioRuntimeFile("data/studio/resources/synkinect-studio-icon.png");
    if(icon.isFile())studioWindowIconCache=ImageIO.read(icon);
  }catch(Exception ignored){}
  return studioWindowIconCache;
}
void studioApplyWindowIcon(Window window){
  if(window==null)return;BufferedImage icon=studioWindowIcon();if(icon==null)return;
  ArrayList<Image> icons=new ArrayList<Image>();icons.add(icon);window.setIconImages(icons);
}

File studioLogDirectory(){
  String explicit=System.getProperty("kinect.remold.userData","").trim();
  File base;
  if(explicit.length()>0)base=new File(explicit);
  else if(System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("win")){
    String local=System.getenv("LOCALAPPDATA");
    base=new File(local==null||local.trim().isEmpty()?System.getProperty("user.home","."):local,"Kinect Remold/Data/SynKinect Studio");
  }else{
    String xdg=System.getenv("XDG_DATA_HOME");
    base=new File(xdg==null||xdg.trim().isEmpty()?new File(System.getProperty("user.home","."),".local/share"):new File(xdg),"Kinect Remold/Data/SynKinect Studio");
  }
  File dir=new File(new File(base,"studio"),"logs");
  if(!dir.isDirectory())dir.mkdirs();
  return dir;
}
File studioCleanExitMarker(){return new File(studioLogDirectory(),".last-exit-clean");
  }

interface StudioDirectorySelection {
  void accepted(File directory);
  void failed(Exception error);
}

String runNativeFolderDialog(String title,File initial)throws Exception{
  return studio.ui.nativeDialogs.chooseDirectory(title,initial);
}
void chooseWritableDirectoryAsync(final String title,final File initial,final StudioDirectorySelection selection){
  studio.ui.nativeDialogs.chooseWritableDirectoryAsync(title,initial,selection);
}

void moveFileAtomically(File source,File target)throws IOException{
  if(source==null||target==null)throw new IOException("Invalid file move");
  File parent=target.getAbsoluteFile().getParentFile();
  if(parent!=null&&!parent.isDirectory()&&!parent.mkdirs())throw new IOException("Could not create directory: "+parent.getAbsolutePath());
  try{Files.move(source.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);}
  catch(AtomicMoveNotSupportedException e){Files.move(source.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING);}
}

File uniqueOutputFile(File directory,String stem,String extension){
  File dir=directory==null?new File("."):directory;
  String base=(stem==null||stem.trim().length()==0)?"output":stem.trim();
  String ext=extension==null?"":extension;
  File candidate=new File(dir,base+ext);
  for(int i=2;candidate.exists();i++)candidate=new File(dir,base+"-"+i+ext);
  return candidate.getAbsoluteFile();
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
String studioStartupText(String key,String defaultValue){
  try{
    File root=new File(studioRuntimeRoot(),"data/studio/resources/i18n");
    String wanted="en-US";
    File exact=new File(root,wanted+".properties");
    File chosen=exact.isFile()?exact:new File(root,"en-US.properties");
    Properties p=loadStudioProperties(chosen);
    return p.getProperty(key,defaultValue);
  }catch(Exception ignored){return defaultValue;}
}
void drawStudioFatalScreen(){
  background(0xFF10151B);
  hint(DISABLE_DEPTH_TEST);
  camera();perspective();
  pushStyle();
  textAlign(LEFT,TOP);
  fill(0xFFF4F7FA);studioText(STUDIO_FONT_TITLE,true);text(studioStartupText("fatal.title","SynKinect Studio — startup/runtime error"),54,48);

  fill(0xFFE8B06A);studioText(STUDIO_FONT_BODY,false);text(studioStartupText("fatal.visible","The Studio was kept open so the failure is visible instead of closing silently."),54,102,width-108,52);

  fill(0xFFF4F7FA);studioText(STUDIO_FONT_SMALL,false);
  String detail=studioStartupText("fatal.phase","Phase")+": "+studioFatalPhase+"\n\n"+studioFatalMessage+"\n\n"+studioStartupText("fatal.diagnostic","Diagnostic")+": "+new File(studioLogDirectory(),"StudioFatal.log").getAbsolutePath()+"\n"+studioStartupText("fatal.launcher_log","Launcher log")+": "+new File(studioLogDirectory(),
    "SynKinectStudio.log").getAbsolutePath();
  text(detail,54,168,max(200,width-108),max(180,height-230));
  fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,false);text(studioStartupText("fatal.close_hint","Close this window after copying the log path if you need to report the failure."),54,height-48);

  popStyle();
}

String installedStudioFont(String[] candidates){
  HashSet<String> available=new HashSet<String>();
  try{for(String family:GraphicsEnvironment.getLocalGraphicsEnvironment().getAvailableFontFamilyNames())available.add(family.toLowerCase(Locale.ROOT));}
  catch(Exception ignored){}
  for(String candidate:candidates)if(candidate!=null&&available.contains(candidate.toLowerCase(Locale.ROOT)))return candidate;
  return "SansSerif";
}
String studioFontFamilyForLocale(String locale){
  String os=System.getProperty("os.name","").toLowerCase(Locale.ROOT);
  String lang=locale==null?"":locale.toLowerCase(Locale.ROOT);
  if(os.contains("win")){
    if(lang.startsWith("ja"))return installedStudioFont(new String[]{"Yu Gothic UI","Yu Gothic","Meiryo UI","Meiryo","Segoe UI","SansSerif"});
    if(lang.startsWith("zh-cn")||lang.startsWith("zh-sg"))return installedStudioFont(new String[]{"Microsoft YaHei UI","Microsoft YaHei","Segoe UI","SansSerif"});
    if(lang.startsWith("zh"))return installedStudioFont(new String[]{"Microsoft JhengHei UI","Microsoft JhengHei","Segoe UI","SansSerif"});
    if(lang.startsWith("ko"))return installedStudioFont(new String[]{"Malgun Gothic","Segoe UI","SansSerif"});
    return installedStudioFont(new String[]{"Segoe UI Variable","Segoe UI","Arial","SansSerif"});
  }
  if(lang.startsWith("ja"))return installedStudioFont(new String[]{"Noto Sans CJK JP","Noto Sans JP","Noto Sans","DejaVu Sans","SansSerif"});
  if(lang.startsWith("zh"))return installedStudioFont(new String[]{"Noto Sans CJK SC","Noto Sans CJK TC","Noto Sans SC","Noto Sans TC","Noto Sans","DejaVu Sans","SansSerif"});
  if(lang.startsWith("ko"))return installedStudioFont(new String[]{"Noto Sans CJK KR","Noto Sans KR","Noto Sans","DejaVu Sans","SansSerif"});
  return installedStudioFont(new String[]{"Noto Sans","DejaVu Sans","Liberation Sans","SansSerif"});
}
String studioTypographyLocale="";
void initializeStudioTypography(){
  String locale=studio==null||studio.i18n==null?"en-US":studio.i18n.language;
  String family=studioFontFamilyForLocale(locale);
  studioUnicodeRegular=createFont(family,STUDIO_FONT_BODY,true);
  studioUnicodeHeading=createFont(family,STUDIO_FONT_TITLE,true);
  // Brand/invariant Latin text must not change metrics when the UI switches
  // to a Japanese/Chinese/Korean font family.
  String brandFamily=studioFontFamilyForLocale("en-US");
  if(studioBrandRegular==null)studioBrandRegular=createFont(brandFamily,STUDIO_FONT_BODY,true);
  if(studioBrandHeading==null)studioBrandHeading=createFont(brandFamily,STUDIO_FONT_TITLE,true);
  studioTypographyLocale=locale;
  textFont(studioUnicodeRegular);
  textLeading(STUDIO_FONT_BODY*1.30f);
}
void ensureStudioTypography(){
  String locale=studio==null||studio.i18n==null?"en-US":studio.i18n.language;
  if(studioUnicodeRegular==null||!locale.equals(studioTypographyLocale))initializeStudioTypography();
}
float normalizedStudioTextSize(float size){
  float resolved=responsiveFontSize(size);
  textSize(resolved);
  float measured=max(0.01f,textAscent()+textDescent());
  // One requested Studio size always maps to the same visual line box.
  // This keeps baselines, buttons and cards stable when the font family changes.
  float target=resolved*1.02f;
  return constrain(resolved*(target/measured),resolved*0.82f,resolved*1.18f);
}
void studioText(float size,boolean heading){
  ensureStudioTypography();
  PFont f=heading?studioUnicodeHeading:studioUnicodeRegular;
  if(f!=null)textFont(f);
  float normalized=normalizedStudioTextSize(size);
  textSize(normalized);
  textLeading(normalized*1.30f);
}
void studioBrandText(float size,boolean heading){
  ensureStudioTypography();
  PFont f=heading?studioBrandHeading:studioBrandRegular;
  if(f!=null)textFont(f);
  float normalized=normalizedStudioTextSize(size);
  textSize(normalized);
  textLeading(normalized*1.30f);
}

class StudioServices {
  final ConfigRules configRules=new ConfigRules();
  final StudioPaths paths=new StudioPaths();
  final StudioEndpoints endpoints=new StudioEndpoints();
  final KinectDriverModuleRegistry driverModules=new KinectDriverModuleRegistry();
  final WorkerFactory workers=new WorkerFactory();
  final ScannerProtocol scannerProtocol=new ScannerProtocol();
  final SpatialAudioProtocol spatialAudioProtocol=new SpatialAudioProtocol();
  final SpatialAudioSessionRegistry spatialAudioSessions=new SpatialAudioSessionRegistry();
  final SurveillanceProtocol surveillanceProtocol=new SurveillanceProtocol();
  final LocalTransportFactory transportFactory=new LocalTransportFactory();
  final KinectDeviceRegistry devices=new KinectDeviceRegistry();
  final SkeletonLibrary skeletons=new SkeletonLibrary();
  final StudioProcessingBlocks processingBlocks=new StudioProcessingBlocks(skeletons,spatialAudioSessions);
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
  try{PJOGL.setIcon(studioRuntimeFile("data/studio/resources/synkinect-studio-icon.png").getAbsolutePath());
    }catch(Exception ignored){}
}

public void setup(){
  clearStudioCleanExitMarker();
  try{
    studio=new StudioController(new StudioServices());
    surface.setTitle("SynKinect Studio");
    surface.setResizable(true);
    enforceStudioInitialWindowSize();
    studio.setup();
  }catch(Throwable error){
    enterStudioFatal("setup",error);
    try{surface.setTitle("SynKinect Studio");surface.setResizable(true);}catch(Throwable ignored){}
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
        // Terminate if the normal Processing/JOGL shutdown cannot complete.
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
String selectedKinectRegistryKey(){KinectDevice device=studio.selectedKinect();return device==null?"":device.registryKey();
  }

class KinectDriverModule {
  final String id,generation,displayName,windowsControl,linuxControl;
  final TransportEndpoint sdkEndpoint;
  KinectDriverModule(String id,String generation,String displayName,TransportEndpoint sdkEndpoint,String windowsControl,String linuxControl){
    this.id=clean(id);this.generation=clean(generation);this.displayName=clean(displayName);this.sdkEndpoint=sdkEndpoint;
    this.windowsControl=clean(windowsControl);this.linuxControl=clean(linuxControl);
  }
  static String clean(String value){return value==null?"":value.trim();}
}

class KinectDriverModuleRegistry {
  final ArrayList<KinectDriverModule> modules=new ArrayList<KinectDriverModule>();
  KinectDriverModuleRegistry(){load();}
  void load(){
    File file=studioRuntimeFile("data/studio/config/driver-modules.properties");
    Properties p=new Properties();
    try(InputStream in=new BufferedInputStream(new FileInputStream(file));Reader reader=new InputStreamReader(in,java.nio.charset.StandardCharsets.UTF_8)){
      p.load(reader);
    }catch(Exception error){println("Driver module registry unavailable: "+safeStudioMessage(error));return;}
    int count=0;try{count=max(0,Integer.parseInt(p.getProperty("module.count","0").trim()));}catch(Exception ignored){}
    HashSet<String> ids=new HashSet<String>();
    for(int i=0;i<count;i++){
      String prefix="module."+i+".";String id=p.getProperty(prefix+"id","").trim();
      String generation=p.getProperty(prefix+"generation","").trim();String name=p.getProperty(prefix+"name",id).trim();
      String windows=p.getProperty(prefix+"windowsSdk","").trim();String linux=p.getProperty(prefix+"linuxSdk","").trim();
      String windowsControl=p.getProperty(prefix+"windowsControl","").trim();String linuxControl=p.getProperty(prefix+"linuxControl","").trim();
      if(id.isEmpty()||generation.isEmpty()||!ids.add(id)){println("Ignoring invalid driver module entry: "+i);continue;}
      modules.add(new KinectDriverModule(id,generation,name,new TransportEndpoint(windows,linux,id+"-sdk"),windowsControl,linuxControl));
    }
  }
  ArrayList<KinectDriverModule> snapshot(){return new ArrayList<KinectDriverModule>(modules);}
  KinectDriverModule byId(String id){if(id==null)return null;for(KinectDriverModule module:modules)if(module.id.equals(id))return module;return null;}
}

class KinectDevice {
  final String moduleId,generation,id,label,state,control,camera,audio,audioControl,virtualCamera,sdk,capabilities;
  final String endpoint;
  final int colorWidth,colorHeight,depthWidth,depthHeight,irWidth,irHeight,colorFps,depthFps;
  KinectDevice(String moduleId,String generation,String id,String label,String state,String control,String camera,String audio,String audioControl,String virtualCamera,String sdk){
    this(moduleId,generation,id,label,state,control,camera,audio,audioControl,virtualCamera,sdk,"",0,0,0,0,0,0,0,0);
  }
  KinectDevice(String moduleId,String generation,String id,String label,String state,String control,String camera,String audio,String audioControl,String virtualCamera,String sdk,
      String capabilities,int colorWidth,int colorHeight,int depthWidth,int depthHeight,int irWidth,int irHeight,int colorFps,int depthFps){
    this.moduleId=clean(moduleId);this.generation=clean(generation);this.id=clean(id);this.label=clean(label);this.state=clean(state);this.control=clean(control);
    this.camera=clean(camera);this.audio=clean(audio);this.audioControl=clean(audioControl);this.virtualCamera=clean(virtualCamera);this.sdk=clean(sdk);this.endpoint=this.camera;
    this.capabilities=normalizeCapabilities(capabilities,this.generation);
    this.colorWidth=positiveOr(colorWidth,"xbox-360".equals(this.generation)?640:0);this.colorHeight=positiveOr(colorHeight,"xbox-360".equals(this.generation)?480:0);
    this.depthWidth=positiveOr(depthWidth,"xbox-360".equals(this.generation)?640:0);this.depthHeight=positiveOr(depthHeight,"xbox-360".equals(this.generation)?480:0);
    this.irWidth=positiveOr(irWidth,"xbox-360".equals(this.generation)?640:0);this.irHeight=positiveOr(irHeight,"xbox-360".equals(this.generation)?488:0);
    this.colorFps=positiveOr(colorFps,"xbox-360".equals(this.generation)?30:0);this.depthFps=positiveOr(depthFps,"xbox-360".equals(this.generation)?30:0);
  }
  static int positiveOr(int value,int defaultValue){return value>0?value:defaultValue;}
  static String clean(String value){return value==null?"":value.trim();}
  static String normalizeCapabilities(String raw,String generation){
    String value=clean(raw).toLowerCase(Locale.ROOT);if(!value.isEmpty())return ","+value.replace(" ","")+",";
    // Fail closed. Capabilities describe what this concrete physical device
    // and backend negotiated now; generation-wide defaults can expose buttons
    // for hardware that does not actually provide the endpoint.
    return ",";
  }
  boolean hasCapability(String capability){String c=clean(capability).toLowerCase(Locale.ROOT).replace(" ","");return !c.isEmpty()&&capabilities.indexOf(","+c+",")>=0;}
  String registryKey(){return moduleId+":"+id;}
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
  volatile String selectedKey="";
  volatile long generation=0,lastRefreshMs=0;
  volatile boolean refreshQueued=false;
  final long refreshIntervalMs=750;
  final long disappearanceGraceMs=30000;
  final HashMap<String,Long> lastSeenMs=new HashMap<String,Long>();

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
  ArrayList<KinectDevice> queryModule(KinectDriverModule module)throws IOException{
    ArrayList<KinectDevice> found=new ArrayList<KinectDevice>();
    if(module==null||module.sdkEndpoint==null)return found;
    TransportEndpoint endpoint=module.sdkEndpoint;
    try(LocalTransport transport=studio.services.transportFactory.open(endpoint.windowsPath,endpoint.linuxPath)){
      transport.write("LIST\n".getBytes(java.nio.charset.StandardCharsets.UTF_8));
      String response=new String(transport.readToEnd(1024*1024),java.nio.charset.StandardCharsets.UTF_8);
      for(String line:response.split("\\r?\\n")){
        line=line.trim();
        if(line.isEmpty()||line.startsWith("ERR "))continue;
        String[] parts=line.split("\\t",-1);
        if(parts.length<3)continue;
        String id=parts[0].trim(),label=parts[1].trim(),state=parts[2].trim();
        String control=parts.length>3?parts[3].trim():"";
        String camera=parts.length>4?parts[4].trim():"";
        String audio=parts.length>5?parts[5].trim():"";
        String audioControl=parts.length>6?parts[6].trim():"";
        String virtualCamera=parts.length>7?parts[7].trim():"";
        String sdk=parts.length>8?parts[8].trim():"";
        String moduleId=parts.length>9&&!parts[9].trim().isEmpty()?parts[9].trim():module.id;
        String deviceGeneration=parts.length>10&&!parts[10].trim().isEmpty()?parts[10].trim():module.generation;
        String deviceCapabilities=parts.length>11?parts[11].trim():"";
        int colorWidth=parsePositive(parts,12),colorHeight=parsePositive(parts,13),depthWidth=parsePositive(parts,14),depthHeight=parsePositive(parts,15);
        int irWidth=parsePositive(parts,16),irHeight=parsePositive(parts,17),colorFps=parsePositive(parts,18),depthFps=parsePositive(parts,19);
        if(!id.isEmpty())found.add(new KinectDevice(moduleId,deviceGeneration,id,label.isEmpty()?id:label,state,control,camera,audio,audioControl,virtualCamera,sdk,
          deviceCapabilities,colorWidth,colorHeight,depthWidth,depthHeight,irWidth,irHeight,colorFps,depthFps));
      }
    }
    return found;
  }
  int parsePositive(String[] parts,int index){if(parts==null||index<0||index>=parts.length)return 0;try{return Math.max(0,Integer.parseInt(parts[index].trim()));}catch(Exception ignored){return 0;}}
  void refresh(){
    ArrayList<KinectDevice> found=new ArrayList<KinectDevice>();
    for(KinectDriverModule module:studio.services.driverModules.snapshot()){
      try{found.addAll(queryModule(module));}
      catch(IOException e){println("device-registry ["+module.id+"]: "+safeStudioMessage(e));}
    }

    LinkedHashMap<String,KinectDevice> unique=new LinkedHashMap<String,KinectDevice>();
    for(KinectDevice d:found)unique.put(d.registryKey(),d);
    found=new ArrayList<KinectDevice>(unique.values());
    Collections.sort(found,new Comparator<KinectDevice>(){public int compare(KinectDevice a,KinectDevice b){return a.registryKey().compareTo(b.registryKey());}});

    long now=System.nanoTime()/1000000L;
    synchronized(lock){
      String before=signature(devices,selectedKey);
      LinkedHashMap<String,KinectDevice> merged=new LinkedHashMap<String,KinectDevice>();
      for(KinectDevice d:found){String key=d.registryKey();merged.put(key,d);lastSeenMs.put(key,now);}
      for(KinectDevice old:devices){
        String key=old.registryKey();Long seen=lastSeenMs.get(key);
        if(!merged.containsKey(key)&&seen!=null&&now-seen<disappearanceGraceMs){
          merged.put(key,new KinectDevice(old.moduleId,old.generation,old.id,old.label,"Reconnecting","","","","","","",old.capabilities,old.colorWidth,old.colorHeight,old.depthWidth,old.depthHeight,old.irWidth,old.irHeight,old.colorFps,old.depthFps));
        }
      }
      Iterator<Map.Entry<String,Long>> seenIt=lastSeenMs.entrySet().iterator();
      while(seenIt.hasNext()){
        Map.Entry<String,Long> entry=seenIt.next();
        if(now-entry.getValue()>=disappearanceGraceMs&&!merged.containsKey(entry.getKey()))seenIt.remove();
      }
      devices.clear();devices.addAll(merged.values());
      Collections.sort(devices,new Comparator<KinectDevice>(){public int compare(KinectDevice a,KinectDevice b){return a.registryKey().compareTo(b.registryKey());}});
      boolean selectedPresent=false;
      for(KinectDevice d:devices)if(d.registryKey().equals(selectedKey)){selectedPresent=true;break;}
      if(!selectedPresent)selectedKey=devices.isEmpty()?"":devices.get(0).registryKey();
      String after=signature(devices,selectedKey);if(!after.equals(before))generation++;
    }
  }
  String signature(List<KinectDevice> list,String selected){StringBuilder b=new StringBuilder(selected);
    for(KinectDevice d:list)b.append('|').append(d.registryKey()).append('#').append(d.state).append('@').append(d.control).append('@').append(d.camera).append('@').append(d.audio).append('@').append(d.audioControl).append('@').append(d.virtualCamera).append('@').append(d.sdk).append('@').append(d.capabilities).append('@').append(d.colorWidth).append('x').append(d.colorHeight).append('@').append(d.depthWidth).append('x').append(d.depthHeight);
    return b.toString();}
  KinectDevice selected(){synchronized(lock){for(KinectDevice d:devices)if(d.registryKey().equals(selectedKey))return d;
      return devices.isEmpty()?null:devices.get(0);}}
  KinectDevice byId(String id){if(id==null)return null;synchronized(lock){KinectDevice match=null;for(KinectDevice d:devices){if(d.registryKey().equals(id))return d;if(d.id.equals(id)){if(match!=null)return null;match=d;}}return match;}}
  ArrayList<KinectDevice> snapshot(){synchronized(lock){return new ArrayList<KinectDevice>(devices);}}
  int count(){synchronized(lock){return devices.size();}}
  int readyCameraCount(){synchronized(lock){int n=0;for(KinectDevice d:devices)if(d.cameraReady())n++;return n;}}
  void cycle(){synchronized(lock){if(devices.isEmpty()){selectedKey="";return;}int idx=0;
      for(int i=0;i<devices.size();i++)if(devices.get(i).registryKey().equals(selectedKey)){idx=i;break;}selectedKey=devices.get((idx+1)%devices.size()).registryKey();generation++;}}
  String selectorLabel(){synchronized(lock){if(devices.isEmpty())return "Kinect · 0";
      int idx=0;for(int i=0;i<devices.size();i++)if(devices.get(i).registryKey().equals(selectedKey)){idx=i;break;}KinectDevice d=devices.get(idx);String name=d.label==null||d.label.trim().isEmpty()?"Kinect":d.label.trim();
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
  public int preferredUiFrameRate(){return constrain(owner.config.uiFrameRate,owner.config.uiMinFrameRate,owner.config.uiMaxFrameRate);}
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
      state.showLiveDetectionCloud=true;
      state.source.setFollowDriverRgbHq(true);
      state.source.start();state.source.clearConsumerPairs();
    }
  }
  public void deactivateModule(){
    cancelScannerReconstructionReset();
    // Module transitions release scanner stream ownership before another module
    // acquires camera streams. Every transition releases its
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
    if(event.depthCalibrationChanged())owner.services.workers.startLowPriority("Scanner-Calibration-Reconcile",new Runnable(){public void run(){refreshScannerCalibrationForSelectedDevice(true);}});
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
  public int preferredUiFrameRate(){return state.config==null?super.preferredUiFrameRate():constrain(state.config.uiFrameRate,owner.config.uiMinFrameRate,owner.config.uiMaxFrameRate);}
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
  public void mouseDraggedModule(){acousticMouseDragged();}
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
  public int preferredUiFrameRate(){return state.config==null?super.preferredUiFrameRate():constrain(state.config.uiFrameRate,owner.config.uiMinFrameRate,owner.config.uiMaxFrameRate);}
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
  public int preferredUiFrameRate(){return state.config==null?super.preferredUiFrameRate():constrain(state.config.uiFrameRate,owner.config.uiMinFrameRate,owner.config.uiMaxFrameRate);}
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
  public int preferredUiFrameRate(){return state.config==null?super.preferredUiFrameRate():constrain(state.config.uiFrameRate,owner.config.uiMinFrameRate,owner.config.uiMaxFrameRate);}
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
    if(event.depthCalibrationChanged())owner.services.workers.startLowPriority("Interactivity-Calibration-Reconcile",new Runnable(){public void run(){refreshInteractionCalibrationForSelectedDevice();}});
    if(event.devicesChanged()){
      String reason=event.selectionChanged()?"device-selection":"device-registry";

      if(state.rgbd!=null)state.rgbd.requestReconnect(reason,event.selectionChanged());

      if(event.selectionChanged()){if(state.rgbd!=null)state.rgbd.clearConsumerPairs();
        if(state.processor!=null)state.processor.clearPublished();state.lastProcessedFrame=-1;
        state.skeleton=null;state.depthImage=null;}
      owner.services.workers.startLowPriority("Interactivity-Device-Reconcile",new Runnable(){public void run(){refreshInteractionCalibrationForSelectedDevice();}
        });
    }
  }
  public int preferredUiFrameRate(){return 60;}
  public void disposeModule(){disposeInteractivityModule();}
}

class StudioModuleStateStore {
  final HashMap<Class<?>,Object> values=new HashMap<Class<?>,Object>();
  synchronized <T> T install(Class<T> type,T value){if(type==null||value==null)throw new IllegalArgumentException("module state");
    Object existing=values.get(type);if(existing==null){values.put(type,value);return value;
      }return type.cast(existing);}
  synchronized <T> T get(Class<T> type){Object value=values.get(type);if(value==null)throw new IllegalStateException("Module state is not installed: "+(type==null?"null":type.getSimpleName()));
    return type.cast(value);}
  synchronized <T> T getIfInstalled(Class<T> type){Object value=values.get(type);return value==null?null:type.cast(value);}
  synchronized void clear(){values.clear();}
}

class StudioController {
  final StudioServices services;
  final StudioShellConfig config;
  final StudioUiSystem ui=new StudioUiSystem();
  final StudioSystemControl systemControl=new StudioSystemControl();
  final StudioHomeSystemPanel homeSystemPanel=new StudioHomeSystemPanel();
  final StudioModuleStateStore moduleStates=new StudioModuleStateStore();
  final StudioUserPreferences userPreferences=new StudioUserPreferences();
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
  int appliedFrameRate=-1;
  Thread lifecycleThread=null;
  int contentHeight=1;
  volatile long seenDeviceGeneration=-1;
  volatile String seenSelectedDeviceId="";
  volatile boolean depthCalibrationEventPending=false;
  float homeScrollY=0,homeMaxScroll=0,homeScrollDragOffset=0;
  boolean homeScrollDragging=false;
  boolean aboutOpen=false;
  volatile SensorCalibrationWindow calibrationWindow=null;

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
    userPreferences.setLanguage(studio.i18n.language);
    initializeStudioTypography();
    applyLanguageToModules(studio.i18n.language);
    updateTitle();
  }
  void setLanguage(String locale){
    if(studio.i18n==null)return;
    studio.i18n.setLanguage(locale);
    userPreferences.setLanguage(studio.i18n.language);
    initializeStudioTypography();
    applyLanguageToModules(studio.i18n.language);
    updateTitle();
  }
  void applyLanguageToModules(String locale){
    dispatchContextEvent(org.synkinect.studio.api.StudioContextEvent.LOCALE_CHANGED);

  }
  void notifyDepthCalibrationChanged(){depthCalibrationEventPending=true;}

  void setup(){
    contentHeight=max(1,height-STUDIO_TOP_BAR_H);
    studio.config.load(studio.services.paths.resource("studio","config.properties"));
    initializeModules();
    String requestedLanguage=userPreferences.language(studio.config.language);
    studio.i18n=new StudioShellI18n(requestedLanguage);
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
    applyFrameRatePolicy();
    services.devices.refreshIfDue();
    reconcileDeviceSelection();
    if(depthCalibrationEventPending){depthCalibrationEventPending=false;dispatchContextEvent(org.synkinect.studio.api.StudioContextEvent.DEPTH_CALIBRATION_CHANGED);}
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

  void applyFrameRatePolicy(){
    int requested=constrain(config.uiFrameRate,config.uiMinFrameRate,config.uiMaxFrameRate);
    if(activeModule>=0&&activeModule<modules.length&&modules[activeModule]!=null)requested=constrain(modules[activeModule].preferredUiFrameRate(),config.uiMinFrameRate,config.uiMaxFrameRate);
    if(requested!=appliedFrameRate){frameRate(requested);appliedFrameRate=requested;}
  }

  void resetStudioUiRenderer(){
    hint(DISABLE_DEPTH_TEST);
    camera();
    perspective();
    if(studioUnicodeRegular!=null)textFont(studioUnicodeRegular);
    textLeading(responsiveFontSize(STUDIO_FONT_BODY)*1.30f);
  }

  String selectedKinectId(){KinectDevice selected=services.devices.selected();return selected==null?"":selected.registryKey();
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
  org.synkinect.studio.api.StudioDeviceInfo publicDevice(KinectDevice device){return device==null?null:new org.synkinect.studio.api.StudioDeviceInfo(device.registryKey(),
      device.id,device.moduleId,device.generation,device.label,device.endpoint,device.capabilities,device.colorWidth,device.colorHeight,device.depthWidth,device.depthHeight,
      device.irWidth,device.irHeight,device.colorFps,device.depthFps);}
  List<org.synkinect.studio.api.StudioDeviceInfo> publicDevices(){ArrayList<org.synkinect.studio.api.StudioDeviceInfo> out=new ArrayList<org.synkinect.studio.api.StudioDeviceInfo>();
    for(KinectDevice device:services.devices.snapshot())out.add(publicDevice(device));
    return Collections.unmodifiableList(out);}
  void dispatchContextEvent(int flags){
    org.synkinect.studio.api.StudioContextEvent event=new org.synkinect.studio.api.StudioContextEvent(flags,currentLanguage(),services.devices.generation,
      publicDevice(selectedKinect()),publicDevices());
    SensorCalibrationWindow window=calibrationWindow;if(window!=null&&!window.closed)window.contextChanged(event);
    if(modules==null)return;
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
  float aboutButtonW(){return constrain(width*0.075f,82,108);}
  float closeButtonW(){return 38;}
  float homeButtonW(){return constrain(width*0.070f,72,94);}
  float shellMargin(){return constrain(width*0.014f,14,22);}
  float shellGap(){return 12;}
  float shellButtonY(){return 7;}
  float shellButtonH(){return 36;}
  float homeButtonX(){return shellMargin();}
  float closeButtonX(){return width-shellMargin()-closeButtonW();}
  float languageButtonX(){return closeButtonX()-shellGap()-languageButtonW();}
  float aboutButtonX(){return languageButtonX()-shellGap()-aboutButtonW();}
  float deviceButtonX(){
    float centered=(width-deviceButtonW())*0.5f;
    float minX=homeButtonX()+homeButtonW()+150;
    float maxX=aboutButtonX()-deviceButtonW()-18;
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
  boolean aboutButtonHit(float mx,float my){return shellHit(mx,my,aboutButtonX(),aboutButtonW());
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

  void drawAboutOverlay(){
    pushStyle();
    float w=min(560,width-48),h=300,x=(width-w)*0.5f,y=max(STUDIO_TOP_BAR_H+28,(height-h)*0.5f);
    noStroke();fill(0xCC080B0F);rect(0,STUDIO_TOP_BAR_H,width,height-STUDIO_TOP_BAR_H);
    stroke(0xFF3B4855);fill(0xFF171D24);rect(x,y,w,h,14);noStroke();
    fill(0xFFF4F7FA);textAlign(CENTER,TOP);studioBrandText(STUDIO_FONT_TITLE,true);text("Kinect Remold",x+w*.5f,y+32);
    fill(0xFFDCE5ED);studioText(STUDIO_FONT_BODY,true);text(studio.i18n.tr("about.studio"),x+w*.5f,y+82);
    studioText(STUDIO_FONT_BODY,false);fill(0xFFB9C5D0);text(studio.i18n.tr("about.created_by"),x+w*.5f,y+122);
    fill(0xFFF4F7FA);studioBrandText(STUDIO_FONT_BODY,true);text("Douglas Santana / @spidoug",x+w*.5f,y+151);
    fill(0xFF8999A8);studioText(STUDIO_FONT_SMALL,false);text(studio.i18n.tr("about.scope"),x+34,y+194,w-68,48);
    fill(0xFF68A9E8);studioText(STUDIO_FONT_SMALL,true);text(studio.i18n.tr("about.close"),x+w*.5f,y+h-36);
    popStyle();
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
  int moduleIndexForKey(String key){if(key==null||modules==null)return -1;for(int i=0;i<modules.length;i++)if(key.equals(modules[i].key()))return i;return -1;}
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
    if(aboutOpen){aboutOpen=false;return;}
    if(closeButtonHit(mouseX,mouseY)){requestStudioClose();return;}
    if(homeButtonHit(mouseX,mouseY)){goHome();return;}
    if(deviceButtonHit(mouseX,mouseY)){cycleKinect();return;}
    if(languageButtonHit(mouseX,mouseY)){cycleLanguage();return;}
    if(aboutButtonHit(mouseX,mouseY)){aboutOpen=true;return;}
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


  void requestSensorCalibration(){
    KinectDevice d=selectedKinect();
    if(d==null||!d.hasCapability("depth")){systemControl.lastOk=false;systemControl.lastMessage=i18n.tr("system.not_found");return;}
    systemControl.lastOk=true;systemControl.lastMessage=i18n.tr("system.sensorcalibration");
    // Calibration is a standalone tool with its own RGB-D session. It does not
    // navigate to or depend on the Scanner plugin.
    final KinectDevice target=d;
    SwingUtilities.invokeLater(new Runnable(){public void run(){
      try{
        if(calibrationWindow!=null&&!calibrationWindow.closed){calibrationWindow.bindSelectedDevice();calibrationWindow.applyLocale();calibrationWindow.frame.toFront();calibrationWindow.frame.requestFocus();return;}
        calibrationWindow=new SensorCalibrationWindow(target);calibrationWindow.showWindow();
      }catch(Exception e){systemControl.lastOk=false;systemControl.lastMessage=safeExceptionMessage(e);}
    }});
  }

  void goHome(){
    if(activeModule>=0&&blockActiveLeaveIfRequired())return;
    activeModule=-1;homeScrollY=0;homeScrollDragging=false;
    synchronized(lifecycleLock){desiredModule=-1;transitioning=ownedModule>=0;lifecycleLock.notifyAll();
      }
    updateTitle();
  }

  void select(int next,boolean initial){
    if(modules==null||modules.length==0){activeModule=-1;desiredModule=-1;return;}
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

  void updateTitle(){if(ready)surface.setTitle("SynKinect Studio");
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
    if(calibrationWindow!=null)try{calibrationWindow.close();calibrationWindow.frame.dispose();}catch(Exception ignored){}
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
  fill(0xFFF4F7FA);textAlign(CENTER,TOP);studioBrandText(31,true);text("SynKinect Studio",width/2,homeTitleY());

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
  final StudioUiButton[] buttons=new StudioUiButton[14];
  StudioHomeSystemPanel(){for(int i=0;i<buttons.length;i++)buttons[i]=new StudioUiButton();}
  String[] actions(){
    KinectDevice d=studio.selectedKinect();
    ArrayList<String> out=new ArrayList<String>();
    out.add("Install");out.add("Status");
    if(d!=null){
      // The Home panel is capability-driven. Generation names select native
      // transports inside the driver modules; they do not decide which user
      // operations are visible. This keeps 1414/1473/1517 identical at the UI
      // contract and lets future generations inherit any capability they publish.
      if(d.hasCapability("depth"))out.add("SensorCalibration");
      if(d.virtualCameraReady()||d.hasCapability("ip-stream"))out.add("OpenCamera");
      if(d.hasCapability("manual-tilt"))out.add("Tilt");
      if(d.hasCapability("startup-tilt"))out.add("StartupTilt");
      if(d.hasCapability("rgb-hq"))out.add("RgbHqToggle");
      if(d.hasCapability("ip-stream")){out.add("IpStatus");out.add("IpReset");out.add("IpToggle");}
    }
    out.add("Uninstall");
    return out.toArray(new String[out.size()]);
  }
  String label(String action){return studio.i18n.tr("system."+action.toLowerCase(Locale.ROOT));}
  float innerWidth(float w){return max(1,w);}
  float preferredHeight(float w){String[] visible=actions();StudioUiMetrics metrics=studio.ui.metrics();float inner=innerWidth(w),header=58*studioUiScale(),actionsH=studio.ui.actionPanelHeight(inner,
      visible.length,false)-metrics.cardTitleH;return max(154,header+actionsH+metrics.footerH+metrics.gap);}
  void draw(float x,float y,float w,float h){
    String[] visible=actions();float innerW=innerWidth(w),innerX=x+(w-innerW)*0.5f;
    fill(0xFFE7EDF3);textAlign(CENTER,TOP);studioText(STUDIO_FONT_BODY,true);String title=studio.i18n.tr("system.title");
    fitCurrentTextSize(title,STUDIO_FONT_BODY,11,innerW,26);text(ellipsizeToWidth(title,innerW),x+w*0.5f,y);
    fill(0xFF8999A8);studioText(STUDIO_FONT_SMALL,false);String description=studio.i18n.tr("system.description");
    fitCurrentTextSize(description,STUDIO_FONT_SMALL,10,innerW,24);text(ellipsizeToWidth(description,innerW),x+w*0.5f,y+27);
    StudioUiMetrics metrics=studio.ui.metrics();float top=y+max(54,58*studioUiScale()),footer=metrics.footerH,footerY=y+h-footer;
    float buttonAreaH=max(metrics.buttonMinH,footerY-top-max(4,metrics.gap*.45f));
    ArrayList<StudioUiButton> list=new ArrayList<StudioUiButton>();for(int i=0;i<visible.length&&i<buttons.length;i++){buttons[i].configure(label(visible[i]),studio.systemControl.actionEnabled(visible[i]),false,false,false);list.add(buttons[i]);}
    studio.ui.layoutButtons(list,innerX,top,innerW,buttonAreaH);for(StudioUiButton button:list)button.draw();
    String state=studio.systemControl.message();
    KinectDevice selected=studio.selectedKinect();
    if(selected!=null&&selected.hasCapability("depth")){
      String quality=standaloneDepthCalibrationSummary(selected);
      if(state==null||state.length()==0||studio.i18n.tr("system.ready").equals(state))state=quality;
      else state=state+"  •  "+quality;
    }
    studio.ui.renderer.statusFooter(innerX,footerY,innerW,footer,state,studio.systemControl.lastOk);
  }
  String actionAt(float mx,float my){String[] visible=actions();for(int i=0;i<visible.length&&i<buttons.length;i++)if(studio.systemControl.actionEnabled(visible[i])&&buttons[i].hit(mx,my))return visible[i];return null;}
}

String standaloneDepthCalibrationSummary(KinectDevice device){
  if(device==null)return "";ModuleI18n ci=new ModuleI18n("scanner",studio.currentLanguage());DepthCalibrationStore store=new DepthCalibrationStore();
  int w=device.depthWidth>0?device.depthWidth:studio.services.scannerProtocol.WIDTH,h=device.depthHeight>0?device.depthHeight:studio.services.scannerProtocol.HEIGHT;
  DepthCorrectionProfile p=store.load(device.id,w,h);if(p==null||!p.calibrated)return ci.tr("calibration.quality.missing");
  float improvement=Float.isFinite(p.trainingRmsBeforeMm)?p.trainingRmsBeforeMm-p.trainingRmsAfterMm:0;String q=(p.coverage>=.70f&&p.trainingRmsAfterMm<=8&&improvement>=0)?"good":((p.coverage>=.50f&&p.trainingRmsAfterMm<=16)?"fair":"poor");
  return ci.format("calibration.quality."+q,p.coverage*100.0f,p.trainingRmsBeforeMm,p.trainingRmsAfterMm);
}

class StudioSystemControl {
  volatile String lastMessage="";volatile boolean lastOk=true;
  boolean supported(){return studio.services.transportFactory.isWindows()||studio.services.transportFactory.isLinux();
    }
  boolean maintenanceAction(String action){return "Install".equals(action)||"Status".equals(action)||"Uninstall".equals(action);}
  KinectDriverModule controlModule(KinectDevice device){return device==null?null:studio.services.driverModules.byId(device.moduleId);}
  File controlScript(String action,KinectDriverModule module){
    if(!supported()||module==null)return null;
    String configured=studio.services.transportFactory.isWindows()?module.windowsControl:module.linuxControl;
    if(configured==null||configured.trim().isEmpty())return null;
    try{File file=studio.services.paths.runtimeFile(configured).getCanonicalFile();return file.isFile()?file:null;}catch(IOException error){return null;}
  }
  File controlScript(String action,KinectDevice device){return controlScript(action,controlModule(device));}
  ArrayList<KinectDriverModule> maintenanceModules(String action){
    ArrayList<KinectDriverModule> out=new ArrayList<KinectDriverModule>();
    for(KinectDriverModule module:studio.services.driverModules.snapshot())if(controlScript(action,module)!=null)out.add(module);
    return out;
  }
  boolean maintenanceAvailable(){return supported();}
  boolean available(String action,KinectDevice device){return supported()&&controlScript(action,device)!=null;}
  boolean actionEnabled(String action){
    KinectDevice d=studio.selectedKinect();
    if("SensorCalibration".equals(action))return d!=null&&d.hasCapability("depth");
    if(maintenanceAction(action))return maintenanceAvailable();
    if(d==null)return false;
    if(action.startsWith("One"))return false; // reserved until a real persistent backend control exists
    if("OpenCamera".equals(action)){
      if(!d.hasCapability("color")||!d.cameraReady())return false;
      // A generation may expose OpenCamera through its SDK endpoint instead of
      // a platform maintenance script. Both are the same user-level action.
      return available(action,d)||d.sdkReady();
    }
    if("Tilt".equals(action))return d.hasCapability("manual-tilt")&&d.controlReady()&&available(action,d);
    if("StartupTilt".equals(action))return d.hasCapability("startup-tilt")&&d.controlReady()&&available(action,d);
    if("RgbHqToggle".equals(action))return d.hasCapability("rgb-hq")&&d.cameraReady()&&available(action,d);
    if("IpStatus".equals(action)||"IpReset".equals(action))return d.hasCapability("ip-stream")&&available(action,d);
    if("IpToggle".equals(action))return d.hasCapability("ip-stream")&&d.cameraReady()&&available(action,d);
    if(!available(action,d))return false;
    return true;
  }
  String message(){if(lastMessage!=null&&lastMessage.length()>0)return lastMessage;
    KinectDevice d=studio.selectedKinect();if(d!=null&&!"xbox-360".equals(d.generation))return d.readyState()?studio.i18n.tr("system.ready"):d.state;
    if(!supported())return studio.i18n.tr("system.unsupported");
    if(d!=null&&"xbox-360".equals(d.generation)&&controlScript("Status",d)==null)return studio.i18n.tr("system.not_found");
    return studio.i18n.tr("system.ready");}
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

    if(commandAvailable("kgx"))return new ProcessBuilder("kgx","--","bash","-lc",command);

    if(commandAvailable("kitty"))return new ProcessBuilder("kitty","bash","-lc",command);

    if(commandAvailable("alacritty"))return new ProcessBuilder("alacritty","-e","bash","-lc",command);

    if(commandAvailable("xterm"))return new ProcessBuilder("xterm","-e","bash","-lc",command);

    throw new IOException("No supported Linux terminal emulator was found (x-terminal-emulator, gnome-terminal, konsole, mate-terminal, kgx, kitty, alacritty or xterm).");

  }
  void runDeviceModuleAction(final String action){
    final KinectDevice selected=studio.selectedKinect();if(selected==null||!selected.sdkReady()){lastOk=false;lastMessage=studio.i18n.tr("system.not_found");return;}
    lastOk=true;lastMessage=studio.i18n.format("system.started",labelForAction(action));
    studio.services.workers.startLowPriority("Device-Module-Control-"+action,new Runnable(){public void run(){try{
      try(LocalTransport transport=studio.services.transportFactory.openEndpoint(selected.sdk)){
        String request="CONTROL\t"+selected.id+"\t"+action+"\n";transport.write(request.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        String reply=new String(transport.readToEnd(65536),java.nio.charset.StandardCharsets.UTF_8).trim();
        if(reply.startsWith("ERR"))throw new IOException(reply);lastOk=true;lastMessage=reply.isEmpty()?labelForAction(action):reply;
      }
    }catch(Exception e){lastOk=false;lastMessage=studio.i18n.format("system.failed",safeStudioMessage(e));}}});
  }
  String labelForAction(String action){return studio.i18n.tr("system."+action.toLowerCase(Locale.ROOT));}
  void runMaintenanceAction(final String action,final ArrayList<KinectDriverModule> modules){
    lastOk=true;lastMessage=studio.i18n.format("system.started",labelForAction(action));
    studio.services.workers.startLowPriority("System-Maintenance-"+action,new Runnable(){public void run(){
      try{
        ArrayList<File> targets=new ArrayList<File>();
        for(KinectDriverModule module:modules){File target=controlScript(action,module);if(target!=null)targets.add(target);}
        if(targets.isEmpty())throw new IOException("No driver maintenance script is available");
        if(studio.services.transportFactory.isWindows()){
          StringBuilder payload=new StringBuilder("$ErrorActionPreference='Continue'; $failed=0; $results=@(); ");
          for(File target:targets){
            String moduleName=target.getParentFile().getName();
            payload.append("Write-Host ''; Write-Host ").append(psLiteral("============================================================")).append(" -ForegroundColor Cyan; ");
            payload.append("Write-Host ").append(psLiteral(" "+moduleName+" / "+labelForAction(action))).append(" -ForegroundColor Cyan; ");
            payload.append("Write-Host ").append(psLiteral("============================================================")).append(" -ForegroundColor Cyan; ");
            payload.append("& ").append(psLiteral(target.getAbsolutePath())).append(" -Action ").append(psLiteral(action)).append(" -NoBanner -NoPause; $actionOk=$?; ");
            if(!"Status".equals(action)){
              payload.append("Write-Host ''; Write-Host ").append(psLiteral(studio.i18n.tr("system.verifying_status"))).append(" -ForegroundColor Yellow; ");
              payload.append("& ").append(psLiteral(target.getAbsolutePath())).append(" -Action 'Status' -NoBanner -NoPause; $statusOk=$?; ");
            }else payload.append("$statusOk=$actionOk; ");
            payload.append("$moduleOk=($actionOk -and $statusOk); if(-not $moduleOk){$failed=1}; ");
            payload.append("$results += ").append(psLiteral(moduleName)).append(" + ': ' + $(if($moduleOk){").append(psLiteral(studio.i18n.tr("system.result_ok"))).append("}else{").append(psLiteral(studio.i18n.tr("system.result_failed"))).append("}); ");
          }
          payload.append("Write-Host ''; Write-Host ").append(psLiteral("============================================================")).append(" -ForegroundColor Cyan; ");
          payload.append("Write-Host ").append(psLiteral(studio.i18n.tr("system.final_summary"))).append(" -ForegroundColor Cyan; ");
          payload.append("Write-Host ").append(psLiteral("============================================================")).append(" -ForegroundColor Cyan; $results | ForEach-Object { Write-Host ('  '+$_) }; ");
          payload.append("Write-Host ''; Read-Host ").append(psLiteral(studio.i18n.tr("system.press_enter_close"))).append(" | Out-Null; exit $failed");
          String command="$payload="+psLiteral(payload.toString())+"; Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',$payload)";
          new ProcessBuilder("powershell.exe","-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-Command",command).directory(targets.get(0).getParentFile()).start();
        }else{
          StringBuilder command=new StringBuilder("failed=0; results=''; ");
          for(File target:targets){
            String moduleName=target.getParentFile().getName();
            command.append("printf '\\n============================================================\\n %s / %s\\n============================================================\\n' ").append(shQuote(moduleName)).append(" ").append(shQuote(labelForAction(action))).append("; ");
            command.append("action_ok=1; REMOLD_GUI=1 bash ").append(shQuote(target.getAbsolutePath())).append(" --action ").append(shQuote(action)).append(" || action_ok=0; ");
            if(!"Status".equals(action)){
              command.append("printf '\\n%s\\n' ").append(shQuote(studio.i18n.tr("system.verifying_status"))).append("; status_ok=1; REMOLD_GUI=1 bash ").append(shQuote(target.getAbsolutePath())).append(" --action Status || status_ok=0; ");
            }else command.append("status_ok=$action_ok; ");
            command.append("if [ $action_ok -eq 1 ] && [ $status_ok -eq 1 ]; then printf -v results '%s  %s: %s\\n' \"$results\" ").append(shQuote(moduleName)).append(" ").append(shQuote(studio.i18n.tr("system.result_ok"))).append("; else printf -v results '%s  %s: %s\\n' \"$results\" ").append(shQuote(moduleName)).append(" ").append(shQuote(studio.i18n.tr("system.result_failed"))).append("; failed=1; fi; ");
          }
          command.append("printf '\\n============================================================\\n%s\\n============================================================\\n%b\\n' ").append(shQuote(studio.i18n.tr("system.final_summary"))).append(" \"$results\"; ");
          command.append("read -r -p ").append(shQuote(studio.i18n.tr("system.press_enter_close")+" ")).append(" _ || true; exit $failed");
          linuxTerminal(command.toString()).directory(targets.get(0).getParentFile()).start();
        }
        lastOk=true;int moduleCount=targets.size();lastMessage=labelForAction(action)+" · "+studio.i18n.format(moduleCount==1?"system.driver_module_count.one":"system.driver_module_count.many",moduleCount);
      }catch(Exception e){lastOk=false;lastMessage=studio.i18n.format("system.failed",safeStudioMessage(e));}
    }});
  }
  void run(final String action){
    KinectDevice selectedDevice=studio.selectedKinect();
    if("SensorCalibration".equals(action)){studio.requestSensorCalibration();return;}
    if(action.startsWith("One")||("OpenCamera".equals(action)&&selectedDevice!=null&&controlScript(action,selectedDevice)==null&&selectedDevice.sdkReady())){runDeviceModuleAction(action);return;}
    if(!supported()){lastOk=false;lastMessage=studio.i18n.tr("system.unsupported");return;}
    if(maintenanceAction(action)){
      final ArrayList<KinectDriverModule> modules=maintenanceModules(action);
      if(modules.isEmpty()){lastOk=false;lastMessage=studio.i18n.tr("system.not_found");return;}
      runMaintenanceAction(action,modules);return;
    }
    File script=controlScript(action,selectedDevice);if(script==null){lastOk=false;lastMessage=studio.i18n.tr("system.not_found");return;}
    final File target=script;final String deviceId=selectedDevice==null?"":selectedDevice.id;
    lastOk=true;lastMessage=studio.i18n.format("system.started",studio.i18n.tr("system."+action.toLowerCase(Locale.ROOT)));
    studio.services.workers.startLowPriority("System-Control-"+action,new Runnable(){public void run(){try{
      boolean needsDevice="OpenCamera".equals(action)||"Tilt".equals(action)||"StartupTilt".equals(action)||"RgbHqToggle".equals(action)||"IpDevice".equals(action)||"IpToggle".equals(action);
      String moduleName=target.getParentFile().getName(),actionLabel=labelForAction(action);
      if(studio.services.transportFactory.isWindows()){
        String header="Write-Host '============================================================' -ForegroundColor Cyan; Write-Host "+psLiteral(" "+moduleName+" / "+actionLabel)+" -ForegroundColor Cyan; Write-Host '============================================================' -ForegroundColor Cyan; ";
        String payload=header+"& "+psLiteral(target.getAbsolutePath())+" -Action "+psLiteral(action)+(needsDevice?" -DeviceId "+psLiteral(deviceId):"")+" -NoBanner -NoPause; $rc=$LASTEXITCODE; Write-Host ''; Read-Host "+psLiteral(studio.i18n.tr("system.press_enter_close"))+" | Out-Null; exit $rc";
        String command="$payload="+psLiteral(payload)+"; Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',$payload)";
        new ProcessBuilder("powershell.exe","-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-Command",command).directory(target.getParentFile()).start();
      }else{
        String command="printf '============================================================\\n %s / %s\\n============================================================\\n' "+shQuote(moduleName)+" "+shQuote(actionLabel)+"; REMOLD_GUI=1 bash "+shQuote(target.getAbsolutePath())+" --action "+shQuote(action)+(needsDevice?" --device-id "+shQuote(deviceId):"")+"; rc=$?; printf '\\n'; read -r -p "+shQuote(studio.i18n.tr("system.press_enter_close")+" ")+" _ || true; exit $rc";
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
  String text(Properties p,String key,String defaultValue){String v=p==null?null:p.getProperty(key);
    return v==null||v.trim().isEmpty()?defaultValue:v.trim();}
  boolean flag(Properties p,String key,boolean defaultValue){
    String v=text(p,key,"");if(v.isEmpty())return defaultValue;
    if("true".equalsIgnoreCase(v)||"1".equals(v)||"yes".equalsIgnoreCase(v)||"on".equalsIgnoreCase(v))return true;

    if("false".equalsIgnoreCase(v)||"0".equals(v)||"no".equalsIgnoreCase(v)||"off".equalsIgnoreCase(v))return false;

    return defaultValue;
  }
  int integer(Properties p,String key,int defaultValue){try{return Integer.parseInt(text(p,key,String.valueOf(defaultValue)));
      }catch(NumberFormatException e){return defaultValue;}}
  int integer(Properties p,String key,int defaultValue,int lo,int hi){return Math.max(lo,Math.min(hi,integer(p,key,defaultValue)));
    }
  long longNumber(Properties p,String key,long defaultValue){return longNumber(text(p,key,String.valueOf(defaultValue)),defaultValue);
    }
  long longNumber(String value,long defaultValue){try{return Long.parseLong(value==null?"":value.trim());
      }catch(NumberFormatException e){return defaultValue;}}
  long longNumber(Properties p,String key,long defaultValue,long lo,long hi){long v=longNumber(p,key,defaultValue);
    return Math.max(lo,Math.min(hi,v));}
  float decimal(Properties p,String key,float defaultValue){try{return Float.parseFloat(text(p,key,String.valueOf(defaultValue)));
      }catch(NumberFormatException e){return defaultValue;}}
  float decimal(Properties p,String key,float defaultValue,float lo,float hi){return Math.max(lo,Math.min(hi,decimal(p,key,defaultValue)));
    }
  int even(Properties p,String key,int defaultValue,int lo,int hi){int v=integer(p,key,defaultValue,lo,hi);
    return (v&1)==0?v:Math.max(lo,v-1);}
  float[] decimalList(String value,int count){
    if(value==null)return null;String[] parts=value.split(",");if(parts.length!=count)return null;
    float[] out=new float[count];
    try{for(int i=0;i<count;i++)out[i]=Float.parseFloat(parts[i].trim());return out;
      }catch(NumberFormatException e){return null;}
  }
}

class StudioUserPreferences {
  static final String NODE="org/synkinect/studio";
  static final String LANGUAGE_KEY="studio.language";
  java.util.prefs.Preferences preferences(){
    try{return java.util.prefs.Preferences.userRoot().node(NODE);}
    catch(SecurityException error){return null;}
  }
  String get(String key,String defaultValue){
    java.util.prefs.Preferences prefs=preferences();
    if(prefs==null)return defaultValue;
    try{String value=prefs.get(key,defaultValue);
      return value==null||value.trim().isEmpty()?defaultValue:value.trim();
    }catch(SecurityException error){return defaultValue;}
  }
  void put(String key,String value){
    if(key==null||key.trim().isEmpty()||value==null||value.trim().isEmpty())return;
    java.util.prefs.Preferences prefs=preferences();
    if(prefs==null)return;
    try{prefs.put(key.trim(),value.trim());prefs.flush();}
    catch(SecurityException error){}
    catch(java.util.prefs.BackingStoreException error){}
  }
  String language(String defaultLanguage){
    // First run is deliberately English. A different locale is restored only
    // after the user explicitly selects and persists it.
    return get(LANGUAGE_KEY,"en-US");
  }
  void setLanguage(String language){put(LANGUAGE_KEY,language);}
}

class StudioShellConfig {
  final ConfigRules rules;
  StudioShellConfig(ConfigRules rules){this.rules=rules;}
  String language="en-US";
  String languages="";
  int uiFrameRate=30,uiMinFrameRate=24,uiMaxFrameRate=60;
  float uiFontScale=1.0f;
  String modulesEnabled="scanner,acoustic,microphones,surveillance,interactivity";
  void load(File file){
    Properties p=rules.load(file,"studio");
    language=rules.text(p,"app.language",language);
    languages=rules.text(p,"app.languages",languages);
    modulesEnabled=rules.text(p,"studio.modules.enabled",modulesEnabled);
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
  File resource(String app,String relative){
    File moduleRoot=new File(new File(runtimeRoot,"data"),safeSegment(app));
    String clean=relative==null?"":relative.replace('\\','/');
    File canonical;
    if("config.properties".equals(clean))canonical=new File(moduleRoot,"config/config.properties");
    else if("driver-modules.properties".equals(clean))canonical=new File(moduleRoot,"config/driver-modules.properties");
    else if(clean.equals("i18n")||clean.startsWith("i18n/"))canonical=new File(moduleRoot,"resources/"+clean);
    else if(clean.toLowerCase(Locale.ROOT).endsWith(".png")||clean.toLowerCase(Locale.ROOT).endsWith(".ico"))canonical=new File(moduleRoot,"resources/"+clean);
    else canonical=new File(moduleRoot,clean);
    return canonical;
    }
  File runtimeFile(String relative){return new File(runtimeRoot,relative==null?"":relative);
    }
  File appDataRoot(String app){
    String explicit=System.getProperty("kinect.remold.userData","").trim();
    File base;
    if(explicit.length()>0)base=new File(explicit);
    else if(System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("win")){
      String local=System.getenv("LOCALAPPDATA");
      base=new File(local==null||local.trim().length()==0?System.getProperty("user.home","."):local,"Kinect Remold/Data/SynKinect Studio");
    }else{
      String xdg=System.getenv("XDG_DATA_HOME");
      base=new File(xdg==null||xdg.trim().length()==0?new File(System.getProperty("user.home","."),".local/share"):new File(xdg),"Kinect Remold/Data/SynKinect Studio");
    }
    File root=new File(base,safeSegment(app));
    if(root.exists()||root.mkdirs())return root;
    File homeData=new File(new File(System.getProperty("user.home","."),"Kinect Remold/Data/SynKinect Studio"),safeSegment(app));
    if(!homeData.exists())homeData.mkdirs();
    return homeData;
  }
  File cacheRoot(){
    String explicit=System.getProperty("kinect.remold.cache","").trim();
    if(explicit.length()>0)return ensureDirectory(new File(explicit));
    if(System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("win")){
      String local=System.getenv("LOCALAPPDATA");
      File base=new File(local==null||local.trim().length()==0?System.getProperty("user.home","."):local,"Kinect Remold/Cache");
      return ensureDirectory(base);
    }
    String xdg=System.getenv("XDG_CACHE_HOME");
    File base=xdg==null||xdg.trim().length()==0?new File(System.getProperty("user.home","."),".cache"):new File(xdg);
    return ensureDirectory(new File(base,"Kinect Remold"));
  }
  File cacheDirectory(String app){return ensureDirectory(new File(cacheRoot(),safeSegment(app)));}
  File downloadsRoot(){
    String explicit=System.getProperty("kinect.remold.downloads","").trim();
    if(explicit.length()>0)return ensureDirectory(new File(explicit));
    if(System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("win")){
      String local=System.getenv("LOCALAPPDATA");
      File base=new File(local==null||local.trim().length()==0?System.getProperty("user.home","."):local,"Kinect Remold/Downloads/dependencies");
      return ensureDirectory(base);
    }
    String xdg=System.getenv("XDG_CACHE_HOME");
    File base=xdg==null||xdg.trim().length()==0?new File(System.getProperty("user.home","."),".cache"):new File(xdg);
    return ensureDirectory(new File(base,"Kinect Remold/Downloads/dependencies"));
  }
  File dependencyDirectory(String app){return ensureDirectory(new File(downloadsRoot(),safeSegment(app)));}
  File ensureDirectory(File dir){if(!dir.exists())dir.mkdirs();return dir;}
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
  File dataDirectory(String app,String configured,String defaultFolder){
    String value=configured==null?"":configured.trim();
    if(value.length()==0)value=defaultFolder;
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
  String defaultLocale="";
  AppI18nCatalog(String app){this.app=app;discover();}
  void discover(){
    File dir=studio.services.paths.resource(app,"i18n");File[] files=dir.listFiles();
    if(files==null)return;
    Arrays.sort(files,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});

    for(File file:files){
      if(!file.isFile()||!file.getName().toLowerCase(Locale.ROOT).endsWith(".properties"))continue;

      Properties catalog=loadStudioProperties(file);String inferred=file.getName().substring(0,file.getName().length()-11);

      String locale=catalog.getProperty("meta.locale",inferred).trim();if(locale.length()==0||catalogs.containsKey(locale))continue;

      supported.add(locale);catalogs.put(locale,catalog);if("true".equalsIgnoreCase(catalog.getProperty("meta.default","false")))defaultLocale=locale;

    }
    if(defaultLocale.length()==0&&!supported.isEmpty())defaultLocale=supported.get(0);
  }
  String resolve(String requested){
    if(supported.isEmpty())return "";String value=requested==null?"auto":requested.trim();

    if(value.length()==0||"auto".equalsIgnoreCase(value))value=defaultLocale.length()==0?"en-US":defaultLocale;

    for(String locale:supported)if(locale.equalsIgnoreCase(value))return locale;
    String prefix=value.toLowerCase(Locale.ROOT).split("[-_]")[0];
    for(String locale:supported)if(locale.toLowerCase(Locale.ROOT).split("[-_]")[0].equals(prefix))return locale;

    return defaultLocale;
  }
  String raw(String locale,String key,String d){
    Properties active=catalogs.get(locale);String value=active==null?null:active.getProperty(key);

    if(value==null&&defaultLocale.length()>0){Properties base=catalogs.get(defaultLocale);value=base==null?null:base.getProperty(key);
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
float studioTypographyScale(){return 1.0f;}
float responsiveFontSize(float base){return max(8.5f,base);}
void fitCurrentTextSize(String value,float preferred,float minimum,float maxWidth,float maxHeight){
  // Preserve the currently selected regular/heading font and the same visual
  // normalization used by studioText(); never fall back to raw point size.
  float size=normalizedStudioTextSize(preferred);
  textSize(size);textLeading(size*1.30f);
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
  Thread startCritical(String role,Runnable task){return start(role,task,Thread.NORM_PRIORITY,false);
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
  byte[] readToEnd(int maxBytes)throws IOException {
    if(maxBytes<=0)throw new IllegalArgumentException("maxBytes");
    if(closed)throw new EOFException("local transport closed");
    ByteArrayOutputStream output=new ByteArrayOutputStream();
    byte[] chunk=new byte[Math.min(4096,maxBytes)];
    if(windowsPipe!=null){
      final RandomAccessFile pipe=windowsPipe;
      while(output.size()<maxBytes){
        final int capacity=Math.min(chunk.length,maxBytes-output.size());
        final byte[] target=capacity==chunk.length?chunk:new byte[capacity];
        int n;
        try{
          n=windowsCall(new Callable<Integer>(){public Integer call()throws Exception{return pipe.read(target);}},LocalTransportFactory.READ_TIMEOUT_MS,"read");
        }catch(IOException e){
          break;
        }
        if(n<0)break;
        if(n==0)continue;
        output.write(target,0,n);
      }
      return output.toByteArray();
    }
    SocketChannel channel=unixChannel;if(channel==null)throw new EOFException("local transport unavailable");
    ByteBuffer buffer=ByteBuffer.wrap(chunk);
    long deadline=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(LocalTransportFactory.READ_TIMEOUT_MS);
    while(output.size()<maxBytes){
      buffer.clear();
      buffer.limit(Math.min(buffer.capacity(),maxBytes-output.size()));
      int n=channel.read(buffer);
      if(n<0)break;
      if(n==0){waitUnix(channel,SelectionKey.OP_READ,deadline,"read");continue;}
      output.write(chunk,0,n);
      deadline=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(LocalTransportFactory.READ_TIMEOUT_MS);
    }
    return output.toByteArray();
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
    // Close the native pipe handle from an independent daemon thread.
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

