// ===== SynKinect Studio / Module API =====

StudioModuleBase[] buildStudioModules(StudioController owner){
  ArrayList<StudioModuleBase> all=new ArrayList<StudioModuleBase>();
  all.add(new ScannerStudioModule(owner));
  all.add(new AcousticStudioModule(owner));
  all.add(new MicrophoneStudioModule(owner));
  all.add(new SurveillanceStudioModule(owner));
  all.add(new InteractivityStudioModule(owner));
  all.addAll(loadExternalStudioModules(owner));
  return all.toArray(new StudioModuleBase[all.size()]);
}

ArrayList<StudioModuleBase> loadExternalStudioModules(StudioController owner){
  ArrayList<ExternalStudioModule> loaded=new ArrayList<ExternalStudioModule>();
  File directory=studioModulesDirectory();
  File[] jars=directory==null?null:directory.listFiles(new FileFilter(){public boolean accept(File file){return file.isFile()&&file.getName().toLowerCase(Locale.ROOT).endsWith(".jar");}});
  if(jars==null||jars.length==0)return new ArrayList<StudioModuleBase>();
  Arrays.sort(jars,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});
  HashSet<String> ids=new HashSet<String>();
  println("SynKinect Studio Module API: scanning "+jars.length+" JAR(s) in "+directory.getAbsolutePath());
  println("External Studio modules run in-process; load only trusted JARs.");

  for(File jar:jars){
    URLClassLoader loader=null;boolean acceptedFromJar=false;
    try{
      loader=new URLClassLoader(new URL[]{jar.toURI().toURL()},org.synkinect.studio.api.SynKinectStudioModule.class.getClassLoader());
      ServiceLoader<org.synkinect.studio.api.SynKinectStudioModule> services=ServiceLoader.load(org.synkinect.studio.api.SynKinectStudioModule.class,loader);
      Iterator<org.synkinect.studio.api.SynKinectStudioModule> iterator=services.iterator();
      int providerErrors=0;
      while(true){
        org.synkinect.studio.api.SynKinectStudioModule plugin=null;
        try{
          if(!iterator.hasNext())break;
          plugin=iterator.next();providerErrors=0;
        }catch(ServiceConfigurationError error){
          providerErrors++;
          println("Module provider rejected ["+jar.getName()+"]: "+safeStudioMessage(error));
          if(providerErrors>=8)break;
          continue;
        }
        try{
          String id=plugin.id()==null?"":plugin.id().trim();
          String name=plugin.name()==null?"":plugin.name().trim();
          int api=plugin.apiVersion();
          if(api!=org.synkinect.studio.api.SynKinectStudioModule.API_VERSION){println("Module skipped ["+jar.getName()+"]: "+id+" requires API "+api+", host API is "+org.synkinect.studio.api.SynKinectStudioModule.API_VERSION);continue;}
          if(!validExternalModuleId(id)){println("Module skipped ["+jar.getName()+"]: invalid/reserved id '"+id+"'.");continue;}
          if(name.length()==0){println("Module skipped ["+jar.getName()+"]: "+id+" has an empty name.");continue;}
          if(ids.contains(id)){println("Module skipped ["+jar.getName()+"]: duplicate id '"+id+"'.");continue;}
          ids.add(id);
          loaded.add(new ExternalStudioModule(owner,plugin,id,truncatePluginText(name,80),plugin.order(),jar,loader));
          acceptedFromJar=true;
        }catch(Throwable error){rethrowFatalPluginError(error);println("Module metadata rejected ["+jar.getName()+"]: "+safeStudioMessage(error));}
      }
    }catch(Throwable error){rethrowFatalPluginError(error);println("Module JAR rejected ["+jar.getName()+"]: "+safeStudioMessage(error));}
    if(!acceptedFromJar&&loader!=null){try{loader.close();}catch(IOException ignored){}}
  }

  Collections.sort(loaded,new Comparator<ExternalStudioModule>(){public int compare(ExternalStudioModule a,ExternalStudioModule b){int order=Integer.compare(a.pluginOrder,b.pluginOrder);return order!=0?order:a.pluginId.compareTo(b.pluginId);}});
  ArrayList<StudioModuleBase> out=new ArrayList<StudioModuleBase>();out.addAll(loaded);
  if(!out.isEmpty())println("SynKinect Studio Module API: loaded "+out.size()+" external module(s).");
  return out;
}

boolean validExternalModuleId(String id){
  if(id==null||!id.matches("[a-z0-9][a-z0-9._-]{0,63}")||id.startsWith("synkinect."))return false;
  return !id.equals("scanner")&&!id.equals("acoustic")&&!id.equals("microphones")&&!id.equals("surveillance")&&!id.equals("interactivity");
}
String truncatePluginText(String value,int maxCodePoints){
  if(value==null)return "";
  String clean=value.replace('\r',' ').replace('\n',' ').trim();
  int count=clean.codePointCount(0,clean.length());
  if(count<=maxCodePoints)return clean;
  return clean.substring(0,clean.offsetByCodePoints(0,maxCodePoints));
}
void rethrowFatalPluginError(Throwable error){
  if(error instanceof ThreadDeath)throw (ThreadDeath)error;
  if(error instanceof VirtualMachineError)throw (VirtualMachineError)error;
}
RuntimeException pluginRuntimeFailure(String action,Throwable error){
  rethrowFatalPluginError(error);
  if(error instanceof RuntimeException)return (RuntimeException)error;
  return new RuntimeException(action+": "+safeStudioMessage(error),error);
}

File studioModulesDirectory(){
  String configured=System.getProperty("synkinect.studio.modules","").trim();
  if(configured.length()>0)return new File(configured);
  File working=new File(System.getProperty("user.dir","."),"modules");
  try{
    java.security.CodeSource source=SynKinectStudio.class.getProtectionDomain().getCodeSource();
    if(source!=null&&source.getLocation()!=null){
      File code=new File(source.getLocation().toURI());
      File base=code.isFile()?code.getParentFile():code;
      if(base!=null&&"lib".equalsIgnoreCase(base.getName()))base=base.getParentFile();
      if(base!=null){File packaged=new File(base,"modules");if(packaged.isDirectory()||!working.isDirectory())return packaged;}
    }
  }catch(Exception ignored){}
  return working;
}

String externalModuleDescription(StudioModuleBase module){
  return module instanceof ExternalStudioModule?((ExternalStudioModule)module).description():module.title();
}

void closeExternalStudioModuleLoaders(StudioModuleBase[] modules){
  Set<URLClassLoader> loaders=Collections.newSetFromMap(new IdentityHashMap<URLClassLoader,Boolean>());
  for(StudioModuleBase module:modules){
    if(module instanceof ExternalStudioModule){
      ClassLoader loader=((ExternalStudioModule)module).pluginClassLoader;
      if(loader instanceof URLClassLoader)loaders.add((URLClassLoader)loader);
    }
  }
  for(URLClassLoader loader:loaders){try{loader.close();}catch(IOException error){println("Module class loader close warning: "+safeStudioMessage(error));}}
}

class ExternalStudioModule extends StudioModuleBase {
  final org.synkinect.studio.api.SynKinectStudioModule plugin;
  final StudioPluginContext context;
  final String pluginId,pluginFallbackName;
  final int pluginOrder;
  final File sourceJar;
  final ClassLoader pluginClassLoader;

  ExternalStudioModule(StudioController owner,org.synkinect.studio.api.SynKinectStudioModule plugin,String id,String fallbackName,int order,File sourceJar,ClassLoader loader){
    super(owner,-1,"plugin."+id);this.plugin=plugin;pluginId=id;pluginFallbackName=fallbackName;pluginOrder=order;this.sourceJar=sourceJar;pluginClassLoader=loader;context=new StudioPluginContext(owner,id);
  }
  @Override public String title(){
    try{String value=plugin.name(owner.currentLanguage());return value==null||value.trim().isEmpty()?pluginFallbackName:truncatePluginText(value,80);}
    catch(Throwable error){rethrowFatalPluginError(error);return pluginFallbackName;}
  }
  String description(){
    try{String value=plugin.description(owner.currentLanguage());return value==null||value.trim().isEmpty()?title():truncatePluginText(value,220);}
    catch(Throwable error){rethrowFatalPluginError(error);return title();}
  }
  public void setupModule(){try{plugin.setup(context);}catch(Throwable error){throw pluginRuntimeFailure("setup",error);}}
  public void activateModule(){try{plugin.activate();}catch(Throwable error){throw pluginRuntimeFailure("activate",error);}}
  public void deactivateModule(){
    try{plugin.deactivate();}
    catch(Throwable error){rethrowFatalPluginError(error);RuntimeException failure=pluginRuntimeFailure("deactivate",error);activationFailure(failure);context.log("deactivate failed: "+safeStudioMessage(error));error.printStackTrace();}
  }
  public void drawModule(){try{plugin.draw();}catch(Throwable error){throw pluginRuntimeFailure("draw",error);}}
  public void mousePressedModule(){if(phase==ModulePhase.READY)try{plugin.mousePressed(owner.contentMouseX(),owner.contentMouseY(),mouseButton);}catch(Throwable error){pluginInputFailure("mousePressed",error);}}
  public void mouseDraggedModule(){if(phase==ModulePhase.READY)try{plugin.mouseDragged(owner.contentMouseX(),owner.contentMouseY(),mouseButton);}catch(Throwable error){pluginInputFailure("mouseDragged",error);}}
  public void mouseWheelModule(processing.event.MouseEvent event){if(phase==ModulePhase.READY)try{plugin.mouseWheel(event==null?0:event.getCount());}catch(Throwable error){pluginInputFailure("mouseWheel",error);}}
  public void keyPressedModule(){if(phase==ModulePhase.READY)try{plugin.keyPressed(key,keyCode);}catch(Throwable error){pluginInputFailure("keyPressed",error);}}
  void pluginInputFailure(String action,Throwable error){RuntimeException failure=pluginRuntimeFailure(action,error);renderFailure(failure);context.log(action+" failed: "+safeStudioMessage(error));error.printStackTrace();}
  public void disposeModule(){
    try{plugin.dispose();}
    catch(Throwable error){rethrowFatalPluginError(error);context.log("dispose failed: "+safeStudioMessage(error));error.printStackTrace();}
    finally{context.stopWorkers();}
  }
}

class StudioPluginContext implements org.synkinect.studio.api.StudioModuleContext {
  final StudioController owner;final String moduleId;
  final CopyOnWriteArrayList<Thread> moduleWorkers=new CopyOnWriteArrayList<Thread>();
  StudioPluginContext(StudioController owner,String moduleId){this.owner=owner;this.moduleId=moduleId;}
  public int apiVersion(){return org.synkinect.studio.api.SynKinectStudioModule.API_VERSION;}
  public String studioVersion(){return "1";}
  public PApplet applet(){return SynKinectStudio.this;}
  public int contentWidth(){return width;}
  public int contentHeight(){return owner.contentHeight;}
  public float uiScale(){return studioUiScale();}
  public String locale(){return owner.currentLanguage();}
  public String platform(){if(owner.services.transportFactory.isWindows())return "windows";if(owner.services.transportFactory.isLinux())return "linux";return "unsupported";}
  public long deviceGeneration(){return owner.services.devices.generation;}
  public org.synkinect.studio.api.StudioDeviceInfo selectedDevice(){KinectDevice device=owner.selectedKinect();return device==null?null:pluginDevice(device);}
  public List<org.synkinect.studio.api.StudioDeviceInfo> devices(){ArrayList<org.synkinect.studio.api.StudioDeviceInfo> out=new ArrayList<org.synkinect.studio.api.StudioDeviceInfo>();for(KinectDevice device:owner.services.devices.snapshot())out.add(pluginDevice(device));return Collections.unmodifiableList(out);}
  org.synkinect.studio.api.StudioDeviceInfo pluginDevice(KinectDevice device){return new org.synkinect.studio.api.StudioDeviceInfo(device.id,device.label,device.endpoint);}
  String endpoint(TransportEndpoint value){if(value==null)return "";if(owner.services.transportFactory.isWindows())return value.windowsPath;if(owner.services.transportFactory.isLinux())return value.linuxPath;return "";}
  public String audioEndpoint(){return endpoint(owner.services.endpoints.audio);}
  public String audioControlEndpoint(){return endpoint(owner.services.endpoints.audioControl);}
  public String skeletonEndpoint(){return endpoint(owner.services.endpoints.skeleton);}
  public String controlEndpoint(){return owner.services.transportFactory.isWindows()?"\\\\.\\pipe\\Kinect360RemoldControl":(owner.services.transportFactory.isLinux()?"/run/kinect360-remold/control.sock":"");}
  public String nuiEndpoint(){return owner.services.transportFactory.isWindows()?"\\\\.\\pipe\\Kinect360RemoldNui":(owner.services.transportFactory.isLinux()?"/run/kinect360-remold/nui.sock":"");}
  public String sdkEndpoint(){return owner.services.transportFactory.isWindows()?"\\\\.\\pipe\\Kinect360RemoldSdk":(owner.services.transportFactory.isLinux()?"/run/kinect360-remold/sdk.sock":"");}
  public org.synkinect.studio.api.StudioTransport openTransport(String endpoint)throws IOException{
    if(endpoint==null||endpoint.trim().isEmpty())throw new IOException("Module transport endpoint is empty.");
    return new StudioTransportAdapter(owner.services.transportFactory.openEndpoint(endpoint.trim()));
  }
  public Path dataDirectory()throws IOException{
    Path root=pluginDataRoot().resolve(moduleId);Files.createDirectories(root);return root;
  }
  Path pluginDataRoot(){
    if(owner.services.transportFactory.isWindows()){
      String local=System.getenv("LOCALAPPDATA");if(local!=null&&!local.trim().isEmpty())return Paths.get(local,"Kinect360Remold","SynKinectStudio","modules");
    }else if(owner.services.transportFactory.isLinux()){
      String xdg=System.getenv("XDG_DATA_HOME");if(xdg!=null&&!xdg.trim().isEmpty())return Paths.get(xdg,"kinect360-remold","SynKinectStudio","modules");
      String home=System.getProperty("user.home",".");return Paths.get(home,".local","share","kinect360-remold","SynKinectStudio","modules");
    }
    return Paths.get(System.getProperty("user.home","."),".synkinect-studio","modules");
  }
  public Thread runAsync(String role,final Runnable task){
    if(task==null)throw new IllegalArgumentException("task");
    String safeRole=role==null?"worker":role.replaceAll("[^A-Za-z0-9._-]","_");
    Thread worker=owner.services.workers.startLowPriority("Plugin-"+moduleId+"-"+safeRole,new Runnable(){public void run(){try{task.run();}catch(Throwable error){rethrowFatalPluginError(error);log("worker failed: "+safeStudioMessage(error));error.printStackTrace();}finally{moduleWorkers.remove(Thread.currentThread());}}});
    moduleWorkers.add(worker);
    if(!worker.isAlive())moduleWorkers.remove(worker);
    return worker;
  }
  void stopWorkers(){
    long deadline=System.nanoTime()+1200000000L;
    for(Thread worker:moduleWorkers)if(worker!=null&&worker!=Thread.currentThread()&&worker.isAlive())worker.interrupt();
    for(Thread worker:moduleWorkers){
      if(worker==null||worker==Thread.currentThread()||!worker.isAlive())continue;
      long remaining=deadline-System.nanoTime();if(remaining<=0)break;
      try{worker.join(Math.max(1,Math.min(250,remaining/1000000L)));}catch(InterruptedException error){Thread.currentThread().interrupt();break;}
    }
    moduleWorkers.clear();
  }
  public void log(String message){println("[Studio module "+moduleId+"] "+(message==null?"":message));}
}

class StudioTransportAdapter implements org.synkinect.studio.api.StudioTransport {
  final LocalTransport delegate;
  StudioTransportAdapter(LocalTransport delegate){this.delegate=delegate;}
  public void write(byte[] data)throws IOException{if(data==null)throw new NullPointerException("data");delegate.write(data);}
  public void readFully(byte[] data)throws IOException{if(data==null)throw new NullPointerException("data");delegate.readFully(data);}
  public void close()throws IOException{delegate.close();}
}
