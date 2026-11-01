// ===== SynKinect Studio / Module API =====

interface StudioModuleFactory { StudioModuleBase create(StudioController owner); }

interface BuiltinStudioPluginFactory { String id(); StudioModuleBase create(StudioController owner); }

ArrayList<BuiltinStudioPluginFactory> builtinStudioPlugins(){
  ArrayList<BuiltinStudioPluginFactory> out=new ArrayList<BuiltinStudioPluginFactory>();
  out.add(new BuiltinStudioPluginFactory(){public String id(){return "scanner";}public StudioModuleBase create(StudioController c){return new ScannerStudioModule(c);}});
  out.add(new BuiltinStudioPluginFactory(){public String id(){return "acoustic";}public StudioModuleBase create(StudioController c){return new AcousticStudioModule(c);}});
  out.add(new BuiltinStudioPluginFactory(){public String id(){return "microphones";}public StudioModuleBase create(StudioController c){return new MicrophoneStudioModule(c);}});
  out.add(new BuiltinStudioPluginFactory(){public String id(){return "surveillance";}public StudioModuleBase create(StudioController c){return new SurveillanceStudioModule(c);}});
  out.add(new BuiltinStudioPluginFactory(){public String id(){return "interactivity";}public StudioModuleBase create(StudioController c){return new InteractivityStudioModule(c);}});
  out.add(new BuiltinStudioPluginFactory(){public String id(){return "mocap";}public StudioModuleBase create(StudioController c){return new MocapStudioModule(c);}});
  return out;
}

LinkedHashSet<String> enabledBuiltinStudioPlugins(StudioController owner){
  LinkedHashSet<String> enabled=new LinkedHashSet<String>();
  String raw=owner==null||owner.config==null?"":owner.config.modulesEnabled;
  if(raw==null||raw.trim().isEmpty()||"*".equals(raw.trim())){for(BuiltinStudioPluginFactory f:builtinStudioPlugins())enabled.add(f.id());return enabled;}
  for(String token:raw.split(",")){String id=token.trim().toLowerCase(Locale.ROOT);if(!id.isEmpty())enabled.add(id);}
  return enabled;
}

StudioModuleBase[] buildStudioModules(StudioController owner){
  ArrayList<StudioModuleBase> all=new ArrayList<StudioModuleBase>();
  LinkedHashSet<String> occupiedIds=new LinkedHashSet<String>();
  LinkedHashSet<String> enabled=enabledBuiltinStudioPlugins(owner);
  // Built-ins use the same registry/lifecycle contract as installable JAR plugins.
  // Removing an id from studio.modules.enabled removes it from the Studio without
  // leaving positional assumptions in the shell.
  for(BuiltinStudioPluginFactory factory:builtinStudioPlugins()){
    if(!enabled.contains(factory.id()))continue;
    StudioModuleBase module=factory.create(owner);if(module==null)continue;
    if(!occupiedIds.add(module.key()))throw new IllegalStateException("Duplicate Studio plugin id: "+module.key());
    all.add(module);
  }
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
          ExternalStudioModule module=new ExternalStudioModule(owner,plugin,id,truncatePluginText(name,80),plugin.order(),jar,loader);
          loaded.add(module);
          ids.add(id);
          acceptedFromJar=true;
        }catch(Throwable error){rethrowFatalPluginError(error);println("Module metadata rejected ["+jar.getName()+"]: "+safeStudioMessage(error));
          }
      }
      // Backend-only providers are adapted to the existing module lifecycle.
      ServiceLoader<org.synkinect.studio.api.StudioBackend> backends=ServiceLoader.load(org.synkinect.studio.api.StudioBackend.class,loader);
      Iterator<org.synkinect.studio.api.StudioBackend> backendIterator=backends.iterator();
      int backendErrors=0;
      while(true){
        org.synkinect.studio.api.StudioBackend backend=null;
        try{if(!backendIterator.hasNext())break;backend=backendIterator.next();backendErrors=0;}
        catch(ServiceConfigurationError error){backendErrors++;println("Backend provider rejected ["+jar.getName()+"]: "+safeStudioMessage(error));if(backendErrors>=8)break;continue;}
        try{
          org.synkinect.studio.api.SynKinectStudioModule plugin=new org.synkinect.studio.api.StudioBackendAdapter(backend);
          String id=plugin.id()==null?"":plugin.id().trim();
          String name=plugin.name()==null?"":plugin.name().trim();
          if(!validExternalModuleId(id)||name.isEmpty()||ids.contains(id)){
            println("Backend skipped ["+jar.getName()+"]: invalid or duplicate module id/name.");continue;
          }
          ExternalStudioModule module=new ExternalStudioModule(owner,plugin,id,truncatePluginText(name,80),plugin.order(),jar,loader);
          loaded.add(module);
          ids.add(id);
          acceptedFromJar=true;
        }catch(Throwable error){rethrowFatalPluginError(error);println("Backend metadata rejected ["+jar.getName()+"]: "+safeStudioMessage(error));}
      }
      // Factories return a new backend per registration, rather than a shared singleton.
      ServiceLoader<org.synkinect.studio.api.StudioBackendFactory> factories=ServiceLoader.load(org.synkinect.studio.api.StudioBackendFactory.class,loader);
      Iterator<org.synkinect.studio.api.StudioBackendFactory> factoryIterator=factories.iterator();
      int factoryErrors=0;
      while(true){
        org.synkinect.studio.api.StudioBackendFactory provider=null;
        try{if(!factoryIterator.hasNext())break;provider=factoryIterator.next();factoryErrors=0;}
        catch(ServiceConfigurationError error){factoryErrors++;println("Backend factory rejected ["+jar.getName()+"]: "+safeStudioMessage(error));if(factoryErrors>=8)break;continue;}
        try{
          org.synkinect.studio.api.StudioBackend backend=provider.create();
          if(backend==null)throw new IllegalStateException("Backend factory returned null");
          org.synkinect.studio.api.SynKinectStudioModule plugin=new org.synkinect.studio.api.StudioBackendAdapter(backend);
          String id=plugin.id()==null?"":plugin.id().trim();
          String name=plugin.name()==null?"":plugin.name().trim();
          if(!validExternalModuleId(id)||name.isEmpty()||ids.contains(id)){
            println("Backend factory skipped ["+jar.getName()+"]: invalid or duplicate module id/name.");continue;
          }
          ExternalStudioModule module=new ExternalStudioModule(owner,plugin,id,truncatePluginText(name,80),plugin.order(),jar,loader);
          loaded.add(module);
          ids.add(id);
          acceptedFromJar=true;
        }catch(Throwable error){rethrowFatalPluginError(error);println("Backend factory failed ["+jar.getName()+"]: "+safeStudioMessage(error));}
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
  final String pluginId,pluginDefaultName;
  final int pluginOrder;
  final File sourceJar;
  final ClassLoader pluginClassLoader;


  ExternalStudioModule(StudioController owner,org.synkinect.studio.api.SynKinectStudioModule plugin,String id,String defaultName,int order,File sourceJar,
    ClassLoader loader){
    super(owner,id,"plugin."+id,"plugin."+id+".description");this.plugin=plugin;pluginId=id;
    pluginDefaultName=defaultName;pluginOrder=order;this.sourceJar=sourceJar;pluginClassLoader=loader;
    context=new StudioPluginContext(owner,id);
  }
  @Override public String title(){
    try{String value=plugin.name(owner.currentLanguage());return value==null||value.trim().isEmpty()?pluginDefaultName:truncatePluginText(value,80);
      }
    catch(Throwable error){rethrowFatalPluginError(error);return pluginDefaultName;
      }
  }
  @Override public String description(){
    try{String value=plugin.description(owner.currentLanguage());return value==null||value.trim().isEmpty()?title():truncatePluginText(value,220);
      }
    catch(Throwable error){rethrowFatalPluginError(error);return title();}
  }
  public void setupModule(){try{plugin.setup(context);}catch(Throwable error){throw pluginRuntimeFailure("setup",error);
      }}
  public void activateModule(){context.setModuleActive(true);try{plugin.activate();}catch(Throwable error){throw pluginRuntimeFailure("activate",error);
      }}
  public void deactivateModule(){
    context.setModuleActive(false);
    try{plugin.deactivate();}
    catch(Throwable error){rethrowFatalPluginError(error);RuntimeException failure=pluginRuntimeFailure("deactivate",error);
      activationFailure(failure);context.log("deactivate failed: "+safeStudioMessage(error));
      error.printStackTrace();}
  }
  @Override protected org.synkinect.studio.api.StudioModuleUi uiSnapshot(){
    try{return plugin.ui(owner.currentLanguage());}
    catch(Throwable error){throw pluginRuntimeFailure("ui",error);}
  }
  @Override protected void uiAction(String actionId){
    try{plugin.action(actionId);}catch(Throwable error){throw pluginRuntimeFailure("action",error);}
  }
  public void drawModule(){
    try{plugin.draw();
    }catch(Throwable error){throw pluginRuntimeFailure("draw",error);}
  }
  public void mousePressedModule(){
    if(phase!=ModulePhase.READY)return;
    try{
      plugin.mousePressed(owner.ui.pointerX(),owner.ui.pointerY(),mouseButton);

    }catch(Throwable error){pluginInputFailure("mousePressed",error);}
  }
  public void mouseDraggedModule(){if(phase==ModulePhase.READY)try{plugin.mouseDragged(owner.ui.pointerX(),owner.ui.pointerY(),mouseButton);
      }catch(Throwable error){pluginInputFailure("mouseDragged",error);}}
  public void mouseReleasedModule(){if(phase==ModulePhase.READY)try{plugin.mouseReleased(owner.ui.pointerX(),owner.ui.pointerY(),mouseButton);
      }catch(Throwable error){pluginInputFailure("mouseReleased",error);}}
  public void mouseWheelModule(processing.event.MouseEvent event){if(phase==ModulePhase.READY)try{float amount=event==null?0:event.getCount();
      plugin.mouseWheel(amount);
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
    finally{context.disposeContext();}
  }
}

class StudioPluginContext implements org.synkinect.studio.api.StudioModuleContext {
  final StudioController owner;final String moduleId;
  final CopyOnWriteArrayList<Thread> moduleWorkers=new CopyOnWriteArrayList<Thread>();

  StudioPluginContext(StudioController owner,String moduleId){this.owner=owner;this.moduleId=moduleId;}
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
  public String audioEndpoint(){KinectDevice device=owner.selectedKinect();return audioEndpoint(device==null?"":device.registryKey());
    }
  public String audioEndpoint(String deviceId){return endpoint(owner.services.endpoints.audioFor(deviceId));
    }
  public String audioControlEndpoint(){KinectDevice device=owner.selectedKinect();
    return audioControlEndpoint(device==null?"":device.registryKey());}
  public String audioControlEndpoint(String deviceId){return endpoint(owner.services.endpoints.audioControlFor(deviceId));
    }
  public String controlEndpoint(){KinectDevice device=owner.selectedKinect();return device==null?"":device.control;
    }
  public String sdkEndpoint(){KinectDevice d=owner.selectedKinect();return d==null?"":d.sdk;
    }
  public org.synkinect.studio.api.StudioTransport openTransport(String endpoint)throws IOException{
    if(endpoint==null||endpoint.trim().isEmpty())throw new IOException("Module transport endpoint is empty.");

    return new StudioTransportAdapter(owner.services.transportFactory.openEndpoint(endpoint.trim()));

  }
  public org.synkinect.studio.api.StudioDepthCalibration depthCalibration(){KinectDevice d=owner.selectedKinect();return depthCalibration(d==null?"":d.registryKey());
    }
  public org.synkinect.studio.api.StudioDepthCalibration depthCalibration(String deviceId){
    KinectDevice d=owner.services.devices.byId(deviceId);if(d==null||!d.hasCapability("depth"))return null;
    int w=d.depthWidth>0?d.depthWidth:owner.services.scannerProtocol.WIDTH,h=d.depthHeight>0?d.depthHeight:owner.services.scannerProtocol.HEIGHT;
    DepthCorrectionProfile p=new DepthCalibrationStore().load(d.id,w,h);if(p==null||!p.calibrated)return null;
    return new org.synkinect.studio.api.StudioDepthCalibration(d.registryKey(),p.width,p.height,p.createdEpochMs,p.coverage,p.trainingRmsBeforeMm,p.trainingRmsAfterMm,p.scale,p.offsetM,p.noiseM);
  }
  public Path dataDirectory()throws IOException{
    Path root=pluginDataRoot().resolve(owner.services.paths.safeSegment(moduleId)).resolve("output");
    Files.createDirectories(root);return root;
  }
  Path pluginDataRoot(){return owner.services.paths.appDataRoot("modules").toPath();}
  // ---- body tracking (camera ownership follows module activation)
  final CopyOnWriteArrayList<HostStudioBodyTracking> bodySessions=new CopyOnWriteArrayList<HostStudioBodyTracking>();
  volatile boolean moduleActive=false;
  volatile boolean disposed=false;
  public org.synkinect.studio.api.StudioBodyTracking bodyTracking(String deviceId){
    if(disposed)throw new IllegalStateException("Module context is disposed.");
    KinectDevice device=deviceId==null||deviceId.trim().isEmpty()?owner.selectedKinect():owner.services.devices.byId(deviceId.trim());
    if(device==null||!device.hasCapability("depth"))return null;
    HostStudioBodyTracking session=new HostStudioBodyTracking(this,device);bodySessions.add(session);
    if(moduleActive)session.tracking.activate();
    return session;
  }
  void setModuleActive(boolean active){if(disposed&&active)throw new IllegalStateException("Module context is disposed.");moduleActive=active;
    for(HostStudioBodyTracking s:bodySessions){if(active)s.tracking.activate();else s.tracking.requestStop();}}
  void closeBodyTracking(){for(HostStudioBodyTracking s:bodySessions)s.close();bodySessions.clear();}
  public Thread runAsync(String role,final Runnable task){
    if(disposed)throw new IllegalStateException("Module context is disposed.");
    if(task==null)throw new IllegalArgumentException("task");
    String safeRole=role==null?"worker":role.replaceAll("[^A-Za-z0-9._-]","_");
    Thread worker=owner.services.workers.startLowPriority("Plugin-"+moduleId+"-"+safeRole,new Runnable(){public void run(){try{task.run();}catch(Throwable error){
          rethrowFatalPluginError(error);log("worker failed: "+safeStudioMessage(error));error.printStackTrace();}finally{moduleWorkers.remove(Thread.currentThread());}
        }});
    moduleWorkers.add(worker);
    if(!worker.isAlive())moduleWorkers.remove(worker);
    return worker;
  }
  void disposeContext(){disposed=true;moduleActive=false;closeBodyTracking();stopWorkers();}
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

// SDK adapter over BodyTrackingSession. Each SDK subscriber has its own latest-only
// mailbox/thread and its own retargeter, so humanoid local rotations are available.
class HostStudioBodyTracking implements org.synkinect.studio.api.StudioBodyTracking {
  final StudioPluginContext context;final BodyTrackingSession tracking;volatile boolean closed=false;
  HostStudioBodyTracking(StudioPluginContext context,KinectDevice device){this.context=context;
    tracking=studio.services.processingBlocks.openBodyTracking(new ModuleI18n("mocap",context.owner.currentLanguage()),device,
      new BodyTrackingOptions("Plugin-"+context.moduleId+"-Body","Module "+context.moduleId+" body tracking",2200,1800,15));}
  public String deviceId(){return tracking.deviceId;}
  public boolean live(){return !closed&&tracking.streamsLive();}
  public AutoCloseable subscribe(final java.util.function.Consumer<org.synkinect.studio.api.StudioBodyFrame> consumer){
    if(consumer==null)throw new IllegalArgumentException("consumer");if(closed)throw new IllegalStateException("body tracking closed");
    final MocapRetargeter retargeter=new MocapRetargeter();
    final LatestMailbox<BodyFrame> box=tracking.subscribe("Plugin-"+context.moduleId+"-BodyFrames",new java.util.function.Consumer<BodyFrame>(){public void accept(BodyFrame f){
      consumer.accept(studioBodyFrame(f,retargeter.retarget(f)));}});
    return new AutoCloseable(){public void close(){tracking.unsubscribe(box);}};
  }
  public void close(){if(closed)return;closed=true;context.bodySessions.remove(this);tracking.close();}
}

org.synkinect.studio.api.StudioBodyFrame studioBodyFrame(BodyFrame f,MocapPose p){
  ArrayList<org.synkinect.studio.api.StudioBodyJoint> joints=new ArrayList<org.synkinect.studio.api.StudioBodyJoint>();
  for(int i=0;i<f.jointCount();i++)joints.add(new org.synkinect.studio.api.StudioBodyJoint(f.jointName(i),f.x(i),f.y(i),f.z(i),f.confidence(i),f.state(i)));
  ArrayList<org.synkinect.studio.api.StudioBodyJoint> bones=new ArrayList<org.synkinect.studio.api.StudioBodyJoint>();
  if(p!=null)for(int i=0;i<p.boneCount();i++)bones.add(new org.synkinect.studio.api.StudioBodyJoint(p.boneName(i),p.globalPos[i*3],p.globalPos[i*3+1],p.globalPos[i*3+2],
    p.boneConf[i],p.boneValid[i]?SkeletonJoint3D.TRACKED:SkeletonJoint3D.PREDICTED,true,p.localRot[i*4],p.localRot[i*4+1],p.localRot[i*4+2],p.localRot[i*4+3]));
  return new org.synkinect.studio.api.StudioBodyFrame(f.deviceId,f.monotonicMs,f.frameNumber,f.trackingId,f.tracked,f.confidence,f.upVector(),joints,bones);
}
