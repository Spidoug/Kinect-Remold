// ===== SynKinect Studio / Module API =====

interface StudioModuleFactory { StudioModuleBase create(StudioController owner); }

StudioModuleBase[] buildStudioModules(StudioController owner){
  ArrayList<StudioModuleFactory> factories=new ArrayList<StudioModuleFactory>();
  factories.add(new StudioModuleFactory(){public StudioModuleBase create(StudioController c){return new ScannerStudioModule(c);}});
  
  factories.add(new StudioModuleFactory(){public StudioModuleBase create(StudioController c){return new AcousticStudioModule(c);}});
  
  factories.add(new StudioModuleFactory(){public StudioModuleBase create(StudioController c){return new MicrophoneStudioModule(c);}});
  
  factories.add(new StudioModuleFactory(){public StudioModuleBase create(StudioController c){return new SurveillanceStudioModule(c);}});
  
  factories.add(new StudioModuleFactory(){public StudioModuleBase create(StudioController c){return new InteractivityStudioModule(c);}});
  
  ArrayList<StudioModuleBase> all=new ArrayList<StudioModuleBase>();
  LinkedHashSet<String> occupiedIds=new LinkedHashSet<String>();
  for(StudioModuleFactory factory:factories){StudioModuleBase module=factory.create(owner);
    if(module==null)continue;if(!occupiedIds.add(module.key()))throw new IllegalStateException("Duplicate built-in Studio module id: "+module.key());
    all.add(module);}
  all.addAll(loadExternalStudioModules(owner,occupiedIds));
  return all.toArray(new StudioModuleBase[all.size()]);
}

ArrayList<StudioModuleBase> loadExternalStudioModules(StudioController owner,Set<String> occupiedIds){
  ArrayList<ExternalStudioModule> loaded=new ArrayList<ExternalStudioModule>();
  File directory=studioModulesDirectory();
  File[] jars=directory==null?null:directory.listFiles(new FileFilter(){public boolean accept(File file){return file.isFile()&&file.getName().toLowerCase(Locale.ROOT).endsWith(".jar");}
    });
  if(jars==null||jars.length==0)return new ArrayList<StudioModuleBase>();
  Arrays.sort(jars,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});
  
  HashSet<String> ids=new HashSet<String>();if(occupiedIds!=null)ids.addAll(occupiedIds);
  
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
          if(api!=org.synkinect.studio.api.SynKinectStudioModule.API_VERSION){println("Module skipped ["+jar.getName()+"]: "+id+" requires API "+api+", host requires API "+org.synkinect.studio.api.SynKinectStudioModule.API_VERSION);
            continue;}
          if(!validExternalModuleId(id)){println("Module skipped ["+jar.getName()+"]: invalid id '"+id+"'.");
            continue;}
          if(name.length()==0){println("Module skipped ["+jar.getName()+"]: "+id+" has an empty name.");
            continue;}
          if(ids.contains(id)){println("Module skipped ["+jar.getName()+"]: duplicate id '"+id+"'.");
            continue;}
          ids.add(id);
          loaded.add(new ExternalStudioModule(owner,plugin,id,truncatePluginText(name,80),plugin.order(),jar,loader));
          
          acceptedFromJar=true;
        }catch(Throwable error){rethrowFatalPluginError(error);println("Module metadata rejected ["+jar.getName()+"]: "+safeStudioMessage(error));
          }
      }
    }catch(Throwable error){rethrowFatalPluginError(error);println("Module JAR rejected ["+jar.getName()+"]: "+safeStudioMessage(error));
      }
    if(!acceptedFromJar&&loader!=null){try{loader.close();}catch(IOException ignored){}}
  }

  Collections.sort(loaded,new Comparator<ExternalStudioModule>(){public int compare(ExternalStudioModule a,ExternalStudioModule b){int order=Integer.compare(a.pluginOrder,
        b.pluginOrder);return order!=0?order:a.pluginId.compareTo(b.pluginId);}});
  
  ArrayList<StudioModuleBase> out=new ArrayList<StudioModuleBase>();out.addAll(loaded);
  
  if(!out.isEmpty())println("SynKinect Studio Module API: loaded "+out.size()+" external module(s).");
  
  return out;
}

boolean validExternalModuleId(String id){return id!=null&&id.matches("[a-z0-9][a-z0-9._-]{0,63}")&&!id.startsWith("synkinect.");
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
  File working=studioRuntimeFile("modules");
  try{
    java.security.CodeSource source=SynKinectStudio.class.getProtectionDomain().getCodeSource();
    
    if(source!=null&&source.getLocation()!=null){
      File code=new File(source.getLocation().toURI());
      File base=code.isFile()?code.getParentFile():code;
      if(base!=null&&"lib".equalsIgnoreCase(base.getName()))base=base.getParentFile();
      
      if(base!=null){File packaged=new File(base,"modules");if(packaged.isDirectory()||!working.isDirectory())return packaged;
        }
    }
  }catch(Exception ignored){}
  return working;
}


void closeStudioModuleResources(StudioModuleBase[] modules){
  Set<Closeable> resources=Collections.newSetFromMap(new IdentityHashMap<Closeable,Boolean>());
  
  if(modules!=null)for(StudioModuleBase module:modules){Closeable resource=module==null?null:module.hostResource();
    if(resource!=null)resources.add(resource);}
  for(Closeable resource:resources){try{resource.close();}catch(IOException error){println("Module host resource close warning: "+safeStudioMessage(error));
      }}
}

class ExternalStudioModule extends StudioModuleBase {
  final org.synkinect.studio.api.SynKinectStudioModule plugin;
  final StudioPluginContext context;
  final String pluginId,pluginFallbackName;
  final int pluginOrder;
  final File sourceJar;
  final ClassLoader pluginClassLoader;
  boolean usingHostUi=false;

  ExternalStudioModule(StudioController owner,org.synkinect.studio.api.SynKinectStudioModule plugin,String id,String fallbackName,int order,File sourceJar,
    ClassLoader loader){
    super(owner,id,"plugin."+id,"plugin."+id+".description");this.plugin=plugin;pluginId=id;
    pluginFallbackName=fallbackName;pluginOrder=order;this.sourceJar=sourceJar;pluginClassLoader=loader;
    context=new StudioPluginContext(owner,id);
  }
  @Override public String title(){
    try{String value=plugin.name(owner.currentLanguage());return value==null||value.trim().isEmpty()?pluginFallbackName:truncatePluginText(value,80);
      }
    catch(Throwable error){rethrowFatalPluginError(error);return pluginFallbackName;
      }
  }
  @Override public String description(){
    try{String value=plugin.description(owner.currentLanguage());return value==null||value.trim().isEmpty()?title():truncatePluginText(value,220);
      }
    catch(Throwable error){rethrowFatalPluginError(error);return title();}
  }
  public void setupModule(){try{plugin.setup(context);}catch(Throwable error){throw pluginRuntimeFailure("setup",error);
      }}
  public void activateModule(){try{plugin.activate();}catch(Throwable error){throw pluginRuntimeFailure("activate",error);
      }}
  public void deactivateModule(){
    try{plugin.deactivate();}
    catch(Throwable error){rethrowFatalPluginError(error);RuntimeException failure=pluginRuntimeFailure("deactivate",error);
      activationFailure(failure);context.log("deactivate failed: "+safeStudioMessage(error));
      error.printStackTrace();}
  }
  public void drawModule(){
    try{
      org.synkinect.studio.api.StudioModuleUi model=plugin.ui(owner.currentLanguage());
      
      usingHostUi=model!=null;
      if(usingHostUi){context.autoView.draw(model,title());return;}
      plugin.draw();
    }catch(Throwable error){throw pluginRuntimeFailure("draw",error);}
  }
  public void mousePressedModule(){
    if(phase!=ModulePhase.READY)return;
    try{
      if(usingHostUi){String action=context.autoView.actionAt(owner.contentMouseX(),owner.contentMouseY());
        if(action!=null&&!action.isEmpty())plugin.action(action);return;}
      plugin.mousePressed(owner.contentMouseX(),owner.contentMouseY(),mouseButton);
      
    }catch(Throwable error){pluginInputFailure("mousePressed",error);}
  }
  public void mouseDraggedModule(){if(phase==ModulePhase.READY)try{plugin.mouseDragged(owner.contentMouseX(),owner.contentMouseY(),mouseButton);
      }catch(Throwable error){pluginInputFailure("mouseDragged",error);}}
  public void mouseReleasedModule(){if(phase==ModulePhase.READY)try{plugin.mouseReleased(owner.contentMouseX(),owner.contentMouseY(),mouseButton);
      }catch(Throwable error){pluginInputFailure("mouseReleased",error);}}
  public void mouseWheelModule(processing.event.MouseEvent event){if(phase==ModulePhase.READY)try{float amount=event==null?0:event.getCount();
      if(usingHostUi){context.autoView.scrollBy(amount);return;}plugin.mouseWheel(amount);
      }catch(Throwable error){pluginInputFailure("mouseWheel",error);}}
  public void keyPressedModule(){if(phase==ModulePhase.READY)try{plugin.keyPressed(key,keyCode);
      }catch(Throwable error){pluginInputFailure("keyPressed",error);}}
  void pluginInputFailure(String action,Throwable error){RuntimeException failure=pluginRuntimeFailure(action,error);
    renderFailure(failure);context.log(action+" failed: "+safeStudioMessage(error));
    error.printStackTrace();}
  public void contextChanged(org.synkinect.studio.api.StudioContextEvent event){try{plugin.contextChanged(event);
      }catch(Throwable error){throw pluginRuntimeFailure("contextChanged",error);
      }}
  public String closeBlockReason(){try{String value=plugin.closeBlockReason(owner.currentLanguage());
      return value==null?"":truncatePluginText(value,240);}catch(Throwable error){rethrowFatalPluginError(error);
      context.log("closeBlockReason failed: "+safeStudioMessage(error));return "";
      }}
  @Override public Closeable hostResource(){return pluginClassLoader instanceof Closeable?(Closeable)pluginClassLoader:null;
    }
  public void disposeModule(){
    try{plugin.dispose();}
    catch(Throwable error){rethrowFatalPluginError(error);context.log("dispose failed: "+safeStudioMessage(error));
      error.printStackTrace();}
    finally{context.stopWorkers();}
  }
}

class StudioPluginContext implements org.synkinect.studio.api.StudioModuleContext {
  final StudioController owner;final String moduleId;
  final CopyOnWriteArrayList<Thread> moduleWorkers=new CopyOnWriteArrayList<Thread>();
  
  final StudioPluginAutoView autoView;
  StudioPluginContext(StudioController owner,String moduleId){this.owner=owner;this.moduleId=moduleId;
    autoView=new StudioPluginAutoView(this);}
  public int apiVersion(){return org.synkinect.studio.api.SynKinectStudioModule.API_VERSION;
    }
  public String studioVersion(){return "1";}
  public PApplet applet(){return SynKinectStudio.this;}
  public int contentWidth(){return width;}
  public int contentHeight(){return owner.contentHeight;}
  public float uiScale(){return studioUiScale();}
  public String locale(){return owner.currentLanguage();}
  public String platform(){if(owner.services.transportFactory.isWindows())return "windows";
    if(owner.services.transportFactory.isLinux())return "linux";return "unsupported";
    }
  public long deviceGeneration(){return owner.services.devices.generation;}
  public org.synkinect.studio.api.StudioDeviceInfo selectedDevice(){return owner.publicDevice(owner.selectedKinect());
    }
  public List<org.synkinect.studio.api.StudioDeviceInfo> devices(){return owner.publicDevices();
    }
  String endpoint(TransportEndpoint value){if(value==null)return "";if(owner.services.transportFactory.isWindows())return value.windowsPath;
    if(owner.services.transportFactory.isLinux())return value.linuxPath;return "";
    }
  public String audioEndpoint(){KinectDevice device=owner.selectedKinect();return audioEndpoint(device==null?"":device.id);
    }
  public String audioEndpoint(String deviceId){return endpoint(owner.services.endpoints.audioFor(deviceId));
    }
  public String audioControlEndpoint(){KinectDevice device=owner.selectedKinect();
    return audioControlEndpoint(device==null?"":device.id);}
  public String audioControlEndpoint(String deviceId){return endpoint(owner.services.endpoints.audioControlFor(deviceId));
    }
  public String skeletonEndpoint(){return endpoint(owner.services.endpoints.skeleton);
    }
  public String controlEndpoint(){return owner.services.transportFactory.isWindows()?"\\\\.\\pipe\\Kinect360RemoldControl":(owner.services.transportFactory.isLinux()?"/run/kinect360-remold/control.sock":"");
    }
  public String nuiEndpoint(){return "";}
  public String sdkEndpoint(){KinectDevice d=owner.selectedKinect();return d==null?"":d.sdk;
    }
  public org.synkinect.studio.api.StudioTransport openTransport(String endpoint)throws IOException{
    if(endpoint==null||endpoint.trim().isEmpty())throw new IOException("Module transport endpoint is empty.");
    
    return new StudioTransportAdapter(owner.services.transportFactory.openEndpoint(endpoint.trim()));
    
  }
  public Path dataDirectory()throws IOException{
    Path root=pluginDataRoot().resolve(owner.services.paths.safeSegment(moduleId)).resolve("output");
    Files.createDirectories(root);return root;
  }
  Path pluginDataRoot(){return owner.services.paths.appRoot("modules").toPath();}
  public Thread runAsync(String role,final Runnable task){
    if(task==null)throw new IllegalArgumentException("task");
    String safeRole=role==null?"worker":role.replaceAll("[^A-Za-z0-9._-]","_");
    Thread worker=owner.services.workers.startLowPriority("Plugin-"+moduleId+"-"+safeRole,new Runnable(){public void run(){try{task.run();}catch(Throwable error){
          rethrowFatalPluginError(error);log("worker failed: "+safeStudioMessage(error));error.printStackTrace();}finally{moduleWorkers.remove(Thread.currentThread());}
        }});
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
      try{worker.join(Math.max(1,Math.min(250,remaining/1000000L)));}catch(InterruptedException error){Thread.currentThread().interrupt();
        break;}
    }
    moduleWorkers.clear();
  }
  public void log(String message){println("[Studio module "+moduleId+"] "+(message==null?"":message));
    }
}

class StudioTransportAdapter implements org.synkinect.studio.api.StudioTransport {
  final LocalTransport delegate;
  StudioTransportAdapter(LocalTransport delegate){this.delegate=delegate;}
  public void write(byte[] data)throws IOException{if(data==null)throw new NullPointerException("data");
    delegate.write(data);}
  public void readFully(byte[] data)throws IOException{if(data==null)throw new NullPointerException("data");
    delegate.readFully(data);}
  public void close()throws IOException{delegate.close();}
}
