// Responsive geometry is supplied by StudioUiMetrics.

// ===== SynKinect Studio / Microphones / Module.pde =====
MicrophoneModuleState microphoneState(){return studio.state(MicrophoneModuleState.class);
  }

class MicrophoneModuleState {
  final MicrophoneTheme theme=new MicrophoneTheme();

  MicrophoneConfig config;
  SpatialAudioConfig spatialConfig;
  MicrophoneI18n i18n;
  AudioPipeline pipeline;
  MicrophoneSource source;
  AudioRuntimeStatus runtimeStatus;
  AudioCaptureControl captureControl;
  MicrophoneUI ui;
}

void setupMicrophoneModule(){
  microphoneState().config=new MicrophoneConfig();microphoneState().config.load(studio.services.paths.resource("microphones","config.properties"));
  
  microphoneState().spatialConfig=studio.services.spatialAudioSessions.config();
  microphoneState().i18n=new MicrophoneI18n(studio.currentLanguage());
  initializeMicrophoneTypography();
  microphoneState().pipeline=new AudioPipeline(microphoneState().config,microphoneState().spatialConfig);
  microphoneState().runtimeStatus=new AudioRuntimeStatus(microphoneState().config);microphoneState().captureControl=new AudioCaptureControl();
  microphoneState().source=new MicrophoneSource(microphoneState().config,microphoneState().pipeline);
  microphoneState().ui=new MicrophoneUI();
}

void drawMicrophoneModule(){background(microphoneState().theme.BG);microphoneState().runtimeStatus.refresh();
  if(microphoneState().captureControl!=null)microphoneState().captureControl.refreshIfDue();
  microphoneState().ui.draw(microphoneState().source==null?null:microphoneState().source.snapshot());
  }

void microphoneMousePressed(){if(microphoneState().ui!=null)microphoneState().ui.handleMousePressed(studio.contentMouseX(),studio.contentMouseY());
  }

void dispatchMicrophoneAction(int action){
  if(action==microphoneState().ui.ACTION_RECORD)toggleRecording();
  else if(action==microphoneState().ui.ACTION_MONITOR)toggleMonitor();
  else if(action==microphoneState().ui.ACTION_PLAY)togglePlayback();
  else if(action==microphoneState().ui.ACTION_TEST)toggleSpeakerTest();
  else if(action==microphoneState().ui.ACTION_AUTO)microphoneState().pipeline.monitor.setAutomatic(true);
  
  else if(action==microphoneState().ui.ACTION_MANUAL)microphoneState().pipeline.monitor.setAutomatic(false);
  
  else if(action==microphoneState().ui.ACTION_VOL_DOWN)adjustCaptureVolume(-5);
  else if(action==microphoneState().ui.ACTION_VOL_UP)adjustCaptureVolume(5);
  else if(action==microphoneState().ui.ACTION_MUTE)toggleCaptureMute();
}

void adjustCaptureVolume(int delta){if(microphoneState().captureControl!=null)microphoneState().captureControl.setVolume(constrain(microphoneState().captureControl.volumePercent+delta,
    0,100));}
void toggleCaptureMute(){if(microphoneState().captureControl!=null)microphoneState().captureControl.setMute(!microphoneState().captureControl.muted);
  }

void toggleRecording(){
  if(microphoneState().pipeline.recorder.isRecording()){microphoneState().pipeline.recorder.stop();
    return;}
  File directory=studio.services.paths.dataDirectory("microphones",microphoneState().config.recordingsDirectory,"recordings");
  
  if(!directory.exists()&&!directory.mkdirs()){microphoneState().pipeline.recorder.setError("mkdir");
    return;}
  String stamp=new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date());
  
  microphoneState().pipeline.recorder.start(new File(directory,microphoneState().config.recordingPrefix+"-"+stamp+"-4ch-s32.wav"));
  
}

void toggleMonitor(){
  if(microphoneState().pipeline.monitor.isRunning())microphoneState().pipeline.monitor.requestStop();
  
  else{microphoneState().pipeline.player.requestStop();microphoneState().pipeline.selfTest.requestStop();
    microphoneState().pipeline.monitor.start();}
}

void togglePlayback(){
  if(microphoneState().pipeline.player.isRunning()){microphoneState().pipeline.player.requestStop();
    return;}
  File last=microphoneState().pipeline.recorder.lastFile();
  if(last==null||!last.isFile()||last.length()<=44){microphoneState().pipeline.player.noFile();
    return;}
  microphoneState().pipeline.monitor.requestStop();microphoneState().pipeline.selfTest.requestStop();
  microphoneState().pipeline.player.start(last);
}

void toggleSpeakerTest(){
  if(microphoneState().pipeline.selfTest.isRunning())microphoneState().pipeline.selfTest.requestStop();
  
  else{microphoneState().pipeline.monitor.requestStop();microphoneState().pipeline.player.requestStop();
    microphoneState().pipeline.selfTest.start();}
}

void disposeMicrophoneModule(){if(microphoneState().source!=null)microphoneState().source.stop();
  if(microphoneState().pipeline!=null)microphoneState().pipeline.stop();}


// ===== SynKinect Studio / Microphones / AudioPipeline.pde =====
class AudioPipeline {
 final WavRecorder recorder;
 final LiveMonitor monitor;
 final RecordedWavPlayer player;
 final SpeakerSelfTest selfTest;

  AudioPipeline(MicrophoneConfig cfg,SpatialAudioConfig spatialCfg){
    recorder=new WavRecorder();
    monitor=new LiveMonitor(cfg,spatialCfg);
    player=new RecordedWavPlayer(cfg);
    selfTest=new SpeakerSelfTest(cfg);
  }

  void accept(SpatialAudioFrame frame,SpatialAudioScanFrame scan){recorder.accept(frame);monitor.accept(frame,scan);
    }
  void stop(){recorder.stop();monitor.stop();player.stop();selfTest.stop();}
}

class WavRecorder {
 final int blockAlign=studio.services.spatialAudioProtocol.CHANNELS*studio.services.spatialAudioProtocol.BYTES_PER_SAMPLE;
  
 final int byteRate=studio.services.spatialAudioProtocol.SAMPLE_RATE*blockAlign;
  RandomAccessFile output;
  long dataBytes=0,lastDataBytes=0,dataSizeOffset=0;
  String currentPath="";
  String stateKey="record.idle";
  String detail="";

  synchronized boolean isRecording(){return output!=null;}
  synchronized String state(){return stateKey;}
  synchronized String detail(){return detail;}
  synchronized long bytes(){return output!=null?dataBytes:lastDataBytes;}
  synchronized File lastFile(){return currentPath.length()==0?null:new File(currentPath);
    }

  synchronized void start(File path){
    stop(); detail=""; stateKey="record.idle";
    if(path==null){setError("null-path");return;}
    try{
      output=new RandomAccessFile(path,"rw"); output.setLength(0); currentPath=path.getAbsolutePath();
       lastDataBytes=0;
      writeHeader(output); stateKey="record.active";
    }catch(IOException e){closeWithoutHeader();setError(safeMessage(e));}
  }

  synchronized void accept(SpatialAudioFrame frame){
    if(output==null||frame==null)return;
    try{
      ByteBuffer data=ByteBuffer.allocate(studio.services.spatialAudioProtocol.PAYLOAD_BYTES).order(ByteOrder.LITTLE_ENDIAN);
      
      for(int sample=0;sample<studio.services.spatialAudioProtocol.SAMPLES;sample++)
        for(int mic=0;mic<studio.services.spatialAudioProtocol.CHANNELS;mic++)
          data.putInt(frame.channelValid(mic)?frame.samples[mic][sample]:0);
      output.write(data.array()); dataBytes+=data.capacity();
    }catch(IOException e){closeWithoutHeader();setError(safeMessage(e));}
  }

  synchronized void stop(){
    if(output==null)return;
    RandomAccessFile file=output; output=null; String closeError="";
    try{
      lastDataBytes=dataBytes; long fileBytes=44L+dataBytes;
      file.seek(4); writeLE32(file,fileBytes-8L); file.seek(dataSizeOffset); writeLE32(file,dataBytes);
      
      file.getFD().sync();
    }catch(IOException e){closeError=safeMessage(e);}
    finally{try{file.close();}catch(IOException e){if(closeError.length()==0)closeError=safeMessage(e);
        }dataBytes=0;dataSizeOffset=0;}
    if(closeError.length()>0)setError(closeError); else stateKey=lastDataBytes>0?"record.saved":"record.empty";
    
  }

  synchronized void setError(String message){stateKey="record.error";detail=message==null?"unknown":message;
    }

  void writeHeader(RandomAccessFile file)throws IOException{
    file.writeBytes("RIFF");writeLE32(file,0);file.writeBytes("WAVE");file.writeBytes("fmt ");
    writeLE32(file,16);
    writeLE16(file,1);writeLE16(file,studio.services.spatialAudioProtocol.CHANNELS);
    writeLE32(file,studio.services.spatialAudioProtocol.SAMPLE_RATE);writeLE32(file,byteRate);
    
    writeLE16(file,blockAlign);writeLE16(file,studio.services.spatialAudioProtocol.BYTES_PER_SAMPLE*8);
    file.writeBytes("data");dataSizeOffset=file.getFilePointer();writeLE32(file,0);
    dataBytes=0;
  }

  void closeWithoutHeader(){
    RandomAccessFile file=output;output=null;if(file!=null)try{file.close();}catch(IOException ignored){}dataBytes=0;
    dataSizeOffset=0;
  }
  void writeLE16(RandomAccessFile file,long value)throws IOException{file.write((int)(value&0xff));
    file.write((int)((value>>>8)&0xff));}
  void writeLE32(RandomAccessFile file,long value)throws IOException{file.write((int)(value&0xff));
    file.write((int)((value>>>8)&0xff));file.write((int)((value>>>16)&0xff));file.write((int)((value>>>24)&0xff));
    }
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;
    }
}

class LiveMonitor {
 final MicrophoneConfig cfg;
 final SpatialAudioConfig spatialCfg;
 final SpatialAudioEngine spatialEngine;
 final SpatialAutoSteerer autoSteerer;
 final Object lock=new Object();
 final ArrayDeque<byte[]> queue=new ArrayDeque<byte[]>();
  volatile boolean running=false;
  volatile long runGeneration=0;
  volatile String stateKey="monitor.idle";
  volatile String detail="";
  volatile boolean automaticBeam=true;
  volatile float manualAzimuthDeg=0;
  volatile float beamAzimuthDeg=0;
  volatile SpatialAudioScanFrame latestScan=null;
  Thread worker; SourceDataLine line;

  LiveMonitor(MicrophoneConfig cfg,SpatialAudioConfig spatialCfg){
    this.cfg=cfg;this.spatialCfg=spatialCfg;this.spatialEngine=new SpatialAudioEngine(spatialCfg);
    this.autoSteerer=new SpatialAutoSteerer(spatialCfg);
  }
  boolean isRunning(){return running;}
  String state(){return stateKey;}
  String detail(){return detail;}
  void setAutomatic(boolean value){automaticBeam=value;if(value)autoSteerer.reset();
    }
  void steerManual(float degrees){automaticBeam=false;manualAzimuthDeg=constrain(degrees,-90,90);
    beamAzimuthDeg=manualAzimuthDeg;}

  void start(){
    synchronized(lock){if(running)return;running=true;stateKey="monitor.starting";
      detail="";queue.clear();final long generation=++runGeneration;worker=studio.services.workers.start("Microphones-SpatialMonitor",new Runnable(){public void run(){
          playbackLoop(generation);}});}
  }

  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;queue.clear();
      lock.notifyAll();t=worker;worker=null;}closeLine();if(t!=null&&t!=Thread.currentThread())t.interrupt();
    if(!"monitor.error".equals(stateKey))stateKey="monitor.idle";}
  void stop(){
    Thread t;synchronized(lock){running=false;++runGeneration;queue.clear();lock.notifyAll();
      t=worker;worker=null;}
    closeLine();
    if(t!=null&&t!=Thread.currentThread())try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();
      }
    if(!"monitor.error".equals(stateKey))stateKey="monitor.idle";
  }

  void accept(SpatialAudioFrame frame,SpatialAudioScanFrame scan){
    if(frame==null||scan==null)return;

    // Localization/VAD is computed once by the per-Kinect shared session.
    // This monitor owns only its beam/output suppression state.
    latestScan=scan;
    float target=manualAzimuthDeg;
    if(automaticBeam)target=autoSteerer.update(scan,beamAzimuthDeg,System.currentTimeMillis());
    
    beamAzimuthDeg=constrain(target,-90,90);

    if(!running)return;
    short[] beam=spatialEngine.beamform(frame,beamAzimuthDeg,scan);
    ByteBuffer pcm=ByteBuffer.allocate(beam.length*2).order(ByteOrder.LITTLE_ENDIAN);
    
    for(short v:beam)pcm.putShort(v);
    synchronized(lock){
      if(!running)return;
      while(queue.size()>=cfg.monitorQueueFrames)queue.removeFirst();
      queue.addLast(pcm.array());lock.notifyAll();
    }
  }

  void playbackLoop(long generation){
    SourceDataLine local=null;
    try{
      AudioFormat format=new AudioFormat((float)studio.services.spatialAudioProtocol.SAMPLE_RATE,16,1,true,false);
      
      local=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));
      
      local.open(format,cfg.monitorLineBufferBytes);local.start();
      synchronized(lock){if(generation==runGeneration)line=local;}
      if(generation==runGeneration)stateKey="monitor.live";
      while(running&&generation==runGeneration){
        byte[] block=null;
        synchronized(lock){
          while(running&&generation==runGeneration&&queue.isEmpty())try{lock.wait(250);
            }catch(InterruptedException e){if(!running||generation!=runGeneration)return;
            Thread.currentThread().interrupt();return;}
          if(!queue.isEmpty())block=queue.removeFirst();
        }
        if(block!=null)local.write(block,0,block.length);
      }
    }catch(Exception e){if(generation==runGeneration){detail=safeMessage(e);stateKey="monitor.error";
        running=false;}}
    finally{closeLine(local);synchronized(lock){if(generation==runGeneration)queue.clear();
        }}
  }

  void closeLine(){SourceDataLine current;synchronized(lock){current=line;line=null;
      }closeLine(current);}
  void closeLine(SourceDataLine current){if(current==null)return;synchronized(lock){if(line==current)line=null;
      }try{if(current.isRunning())current.stop();}catch(Exception ignored){}try{current.flush();
      }catch(Exception ignored){}try{current.close();}catch(Exception ignored){}}
  String safeMessage(Exception e){String v=e.getMessage();return v==null||v.length()==0?e.getClass().getSimpleName():v;
    }
}

class RecordedWavPlayer {
 final MicrophoneConfig cfg;
  volatile boolean running=false;
  volatile long runGeneration=0;
  volatile String stateKey="playback.idle";
  volatile String detail="";
  volatile String fileName="";
  Thread worker; SourceDataLine line;

  RecordedWavPlayer(MicrophoneConfig cfg){this.cfg=cfg;}
  boolean isRunning(){return running;}
  String state(){return stateKey;}
  String detail(){return detail;}

  void noFile(){stateKey="playback.no_file";detail="";}
  void start(final File file){
    requestStop();if(file==null||!file.isFile()){noFile();return;}running=true;stateKey="playback.starting";
    detail="";fileName=file.getName();final long generation=++runGeneration;
    worker=studio.services.workers.start("Microphones-WavPlayback",new Runnable(){public void run(){playback(file,generation);}});
    
  }
  void requestStop(){running=false;++runGeneration;closeLine();Thread t=worker;worker=null;
    if(t!=null&&t!=Thread.currentThread())t.interrupt();if(!"playback.error".equals(stateKey)&&!"playback.no_file".equals(stateKey))stateKey="playback.idle";
    }
  void stop(){
    running=false;++runGeneration;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread()){t.interrupt();
      try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();
        }}
    if(!"playback.error".equals(stateKey)&&!"playback.no_file".equals(stateKey))stateKey="playback.idle";
    
  }

  void playback(File file,long generation){
    RandomAccessFile input=null;SourceDataLine local=null;
    try{
      input=new RandomAccessFile(file,"r");WavDataRegion region=findDataRegion(input);
      input.seek(region.offset);
      AudioFormat format=new AudioFormat((float)studio.services.spatialAudioProtocol.SAMPLE_RATE,16,1,true,false);
      
      local=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));
      local.open(format,cfg.playbackLineBufferBytes);local.start();
      if(generation!=runGeneration){closeLine(local);return;}line=local;stateKey="playback.live";
      
      byte[] raw=new byte[studio.services.spatialAudioProtocol.PAYLOAD_BYTES];long remaining=region.bytes;
      
      while(running&&generation==runGeneration&&remaining>0){
        int wanted=(int)Math.min(raw.length,remaining);int n=input.read(raw,0,wanted);
        if(n<0)break;remaining-=n;
        int frameBytes=studio.services.spatialAudioProtocol.CHANNELS*studio.services.spatialAudioProtocol.BYTES_PER_SAMPLE;
        int frames=n/frameBytes;if(frames<=0)continue;
        ByteBuffer src=ByteBuffer.wrap(raw,0,frames*frameBytes).order(ByteOrder.LITTLE_ENDIAN);
        
        int[][] channel=new int[studio.services.spatialAudioProtocol.CHANNELS][frames];
        long[] peaks=new long[studio.services.spatialAudioProtocol.CHANNELS];
        for(int i=0;i<frames;i++)for(int ch=0;ch<studio.services.spatialAudioProtocol.CHANNELS;ch++){int v=src.getInt();
          channel[ch][i]=v;long mag=v==Integer.MIN_VALUE?2147483648L:Math.abs((long)v);
          if(mag>peaks[ch])peaks[ch]=mag;}
        int selected=0;for(int ch=1;ch<studio.services.spatialAudioProtocol.CHANNELS;ch++)if(peaks[ch]>peaks[selected])selected=ch;
        
        float gain=constrain((cfg.monitorTargetPeak*2147483647.0f)/Math.max(1L,peaks[selected]),1.0f,cfg.monitorMaxGain);
        
        ByteBuffer out=ByteBuffer.allocate(frames*2).order(ByteOrder.LITTLE_ENDIAN);
        
        for(int v:channel[selected]){long amp=(long)(v*gain);amp=Math.max(Integer.MIN_VALUE,Math.min(Integer.MAX_VALUE,amp));
          out.putShort((short)constrain((int)(amp>>16),-32768,32767));}
        local.write(out.array(),0,out.position());
      }
      if(running&&generation==runGeneration)stateKey="playback.finished";
    }catch(Exception e){if(generation==runGeneration){stateKey="playback.error";detail=safeMessage(e);
        }}
    finally{if(generation==runGeneration)running=false;if(input!=null)try{input.close();
        }catch(IOException ignored){}closeLine(local);}
  }

  WavDataRegion findDataRegion(RandomAccessFile file)throws IOException{
    if(file.length()<12)throw new IOException("wav-header");
    byte[] head=new byte[12];file.readFully(head);
    if(head[0]!='R'||head[1]!='I'||head[2]!='F'||head[3]!='F'||head[8]!='W'||head[9]!='A'||head[10]!='V'||head[11]!='E')throw new IOException("wav-signature");
    
    boolean formatOk=false;long dataOffset=-1,dataBytes=0;
    while(file.getFilePointer()+8<=file.length()){
      byte[] id=new byte[4];file.readFully(id);long size=readLE32(file);long next=file.getFilePointer()+size+(size&1L);
      
      String chunk=new String(id,"US-ASCII");
      if("fmt ".equals(chunk)){
        if(size<16)throw new IOException("wav-fmt");byte[] fmt=new byte[16];file.readFully(fmt);
        ByteBuffer b=ByteBuffer.wrap(fmt).order(ByteOrder.LITTLE_ENDIAN);
        int tag=b.getShort()&0xffff,channels=b.getShort()&0xffff,rate=b.getInt();
        b.getInt();b.getShort();int bits=b.getShort()&0xffff;
        formatOk=tag==1&&channels==studio.services.spatialAudioProtocol.CHANNELS&&rate==studio.services.spatialAudioProtocol.SAMPLE_RATE&&bits==32;
        
      }else if("data".equals(chunk)){dataOffset=file.getFilePointer();dataBytes=Math.min(size,file.length()-dataOffset);
        }
      file.seek(Math.min(next,file.length()));if(formatOk&&dataOffset>=0)break;
    }
    if(!formatOk||dataOffset<0||dataBytes<=0)throw new IOException("wav-format");
    return new WavDataRegion(dataOffset,dataBytes);
  }
  long readLE32(RandomAccessFile f)throws IOException{return (f.readUnsignedByte())|(long)f.readUnsignedByte()<<8|(long)f.readUnsignedByte()<<16|(long)f.readUnsignedByte()<<24;
    }
  void closeLine(){SourceDataLine current=line;line=null;closeLine(current);}
  void closeLine(SourceDataLine current){if(current==null)return;if(line==current)line=null;
    try{if(current.isRunning())current.stop();}catch(Exception ignored){}try{current.flush();
      }catch(Exception ignored){}try{current.close();}catch(Exception ignored){}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;
    }
}

class WavDataRegion { final long offset,bytes; WavDataRegion(long offset,long bytes){this.offset=offset;
    this.bytes=bytes;} }

class SpeakerSelfTest {
 final MicrophoneConfig cfg;
  volatile boolean running=false;
  volatile long runGeneration=0;
  volatile String stateKey="speaker.idle";
  volatile String detail="";
  Thread worker;SourceDataLine line;
  SpeakerSelfTest(MicrophoneConfig cfg){this.cfg=cfg;}
  boolean isRunning(){return running;}
  String state(){return stateKey;}
  String detail(){return detail;}

  void start(){if(running)return;running=true;stateKey="speaker.starting";detail="";
    final long generation=++runGeneration;worker=studio.services.workers.start("Microphones-SpeakerTest",new Runnable(){public void run(){playTone(generation);}
      });}
  void requestStop(){running=false;++runGeneration;closeLine();Thread t=worker;worker=null;
    if(t!=null&&t!=Thread.currentThread())t.interrupt();if(!"speaker.error".equals(stateKey))stateKey="speaker.idle";
    }
  void stop(){running=false;++runGeneration;closeLine();Thread t=worker;worker=null;
    if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(cfg.workerJoinMs);
        }catch(InterruptedException e){Thread.currentThread().interrupt();}}if(!"speaker.error".equals(stateKey))stateKey="speaker.idle";
    }
  void playTone(long generation){
    SourceDataLine local=null;
    try{
      int rate=studio.services.spatialAudioProtocol.SAMPLE_RATE;AudioFormat format=new AudioFormat((float)rate,16,1,true,false);
      
      local=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));
      local.open(format,cfg.speakerLineBufferBytes);local.start();
      if(generation!=runGeneration){closeLine(local);return;}line=local;
      int samples=max(1,rate*cfg.speakerDurationMs/1000);ByteBuffer tone=ByteBuffer.allocate(samples*2).order(ByteOrder.LITTLE_ENDIAN);
      
      for(int i=0;i<samples;i++){double edge=Math.min(i, samples-1-i);double envelope=Math.min(1.0,edge/Math.max(1.0,cfg.speakerFadeSamples));
        short value=(short)(Math.sin(2.0*Math.PI*cfg.speakerFrequencyHz*i/rate)*cfg.speakerAmplitude*envelope);
        tone.putShort(value);}
      stateKey="speaker.live";local.write(tone.array(),0,tone.position());if(running&&generation==runGeneration)local.drain();
      if(generation==runGeneration)stateKey="speaker.done";
    }catch(Exception e){if(generation==runGeneration){stateKey="speaker.error";detail=safeMessage(e);
        }}
    finally{if(generation==runGeneration)running=false;closeLine(local);}
  }
  void closeLine(){SourceDataLine current=line;line=null;closeLine(current);}
  void closeLine(SourceDataLine current){if(current==null)return;if(line==current)line=null;
    try{current.stop();}catch(Exception ignored){}try{current.flush();}catch(Exception ignored){}try{current.close();
      }catch(Exception ignored){}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;
    }
}


// ===== SynKinect Studio / Microphones / AudioRuntimeStatus.pde =====
class AudioRuntimeStatus {
 final MicrophoneConfig cfg;
 final HashMap<String,String> values=new HashMap<String,String>();
  long nextRefreshMs=0;
  volatile boolean refreshQueued=false;
  volatile boolean available=false;
  volatile String readError="";

  AudioRuntimeStatus(MicrophoneConfig cfg){this.cfg=cfg;}

  void refresh(){
    long now=System.currentTimeMillis();if(now<nextRefreshMs)return;nextRefreshMs=now+cfg.statusRefreshMs;
    
    if(refreshQueued)return;refreshQueued=true;
    studio.services.workers.startLowPriority("Microphones-RuntimeStatus",new Runnable(){public void run(){try{refreshNow();}finally{refreshQueued=false;}
        }});
  }

  void refreshNow(){
    long now=System.currentTimeMillis();
    File statusFile=resolveStatusFile();
    if(statusFile==null||!statusFile.isFile()){available=false;readError="missing";
      return;}
    if(now-statusFile.lastModified()>cfg.statusStaleMs){available=false;readError="stale";
      return;}
    BufferedReader reader=null;
    try{
      HashMap<String,String> fresh=new HashMap<String,String>();reader=new BufferedReader(new InputStreamReader(new FileInputStream(statusFile),"UTF-8"));
      String line;
      while((line=reader.readLine())!=null){int eq=line.indexOf('=');if(eq>0)fresh.put(line.substring(0,eq).trim(),line.substring(eq+1).trim());
        }
      synchronized(values){values.clear();values.putAll(fresh);}available=true;readError="";
      
    }catch(IOException e){available=false;readError=safeMessage(e);}
    finally{if(reader!=null)try{reader.close();}catch(IOException ignored){}}
  }

  File resolveStatusFile(){
    if(studio.services.transportFactory.isLinux())return new File(studio.services.endpoints.linuxAudioStatus);
    
    String root=environmentPath("ProgramData");
    if(root==null)root=environmentPath("ALLUSERSPROFILE");
    return root==null?null:new File(new File(root,cfg.statusDirectory),cfg.statusFileName);
    
  }

  String environmentPath(String name){String value=System.getenv(name);if(value==null)return null;
    value=value.trim();return value.length()==0?null:value;}
  String get(String key,String fallback){synchronized(values){String v=values.get(key);
      return v==null?fallback:v;}}
  long number(String key){return studio.services.configRules.longNumber(get(key,"0"),0);
    }
  String stage(){return get("stage","");}
  long transportPackets(){return studio.services.transportFactory.isLinux()?number("alsa_reads"):number("wasapi_packets");
    }
  long published(){return number("published_frames");}
  long runtimeSessions(){return number("runtime_sessions");}
  long lastError(){return number("last_error");}
  int captureRate(){return (int)number("capture_sample_rate");}
  int captureChannels(){return (int)number("capture_channels");}
  int captureBits(){return (int)number("capture_bits");}

  String stateKey(){
    if(!available)return "status.unavailable";
    String current=stage();
    if(lastError()!=0||current.endsWith("-error"))return "status.audio_error";
    if("uac-runtime-capturing".equals(current)){
      if(captureRate()==studio.services.spatialAudioProtocol.SAMPLE_RATE&&captureChannels()>=studio.services.spatialAudioProtocol.CHANNELS&&published()>0)return "status.ok";
      
      return "status.wait_frames";
    }
    if(current.startsWith("uac-firmware")||current.startsWith("uac-search")||current.equals("starting"))return "status.wait";
    
    return "status.wait";
  }

  String formatSummary(){
    String format=captureChannels()>0?captureChannels()+"ch / "+captureRate()+" Hz / "+captureBits()+" bit":"—";
    
    return format;
  }
  String compactCounters(){String backend=studio.services.transportFactory.isLinux()?"ALSA":"WASAPI";
    return backend+" "+transportPackets()+" · PCM "+published()+" · SESS "+runtimeSessions();
    }
  String errorCode(){long code=lastError();return code==0?"":String.valueOf(code);
    }
  String detail(){String d=get("detail","");if(d.length()>96)d=d.substring(0,95)+"…";
    return d;}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;
    }
}


// ===== SynKinect Studio / Microphones / MicrophoneConfig.pde =====
class MicrophoneConfig {
  int uiFrameRate = 30;
  int workerJoinMs = 1200;
  int statusRefreshMs = 500;
  int statusStaleMs = 3000;
  String statusDirectory = "Kinect360Remold";
  String statusFileName = "audio-bridge-status.txt";
  String recordingsDirectory = "recordings";
  String recordingPrefix = "KinectMics";
  int monitorQueueFrames = 8;
  float monitorTargetPeak = 0.55f;
  float monitorMaxGain = 64.0f;
  float monitorGainSmoothing = 0.18f;
  int monitorLineBufferBytes = 4096;
  int playbackLineBufferBytes = 8192;
  int speakerFrequencyHz = 700;
  int speakerDurationMs = 750;
  int speakerAmplitude = 12000;
  int speakerFadeSamples = 400;
  int speakerLineBufferBytes = 4096;

  void load(File file) {
    Properties p=studio.services.configRules.load(file,"microphone");
      uiFrameRate = intValue(p,"ui.frameRate",uiFrameRate,10,120);
      workerJoinMs = intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);
    
    
    
    
    
      statusRefreshMs = intValue(p,"status.refreshMs",statusRefreshMs,100,5000);
    
      statusStaleMs = intValue(p,"status.staleMs",statusStaleMs,500,30000);
    
      statusDirectory = textValue(p,"status.directory",statusDirectory);
    
      statusFileName = textValue(p,"status.file",statusFileName);
      recordingsDirectory = textValue(p,"record.directory",recordingsDirectory);
      recordingPrefix = textValue(p,"record.filePrefix",recordingPrefix);
      monitorQueueFrames = intValue(p,"monitor.queueFrames",monitorQueueFrames,2,64);
    
      monitorTargetPeak = floatValue(p,"monitor.targetPeak",monitorTargetPeak,0.05f,0.95f);
    
      monitorMaxGain = floatValue(p,"monitor.maxGain",monitorMaxGain,1.0f,128.0f);
    
      monitorGainSmoothing = floatValue(p,"monitor.gainSmoothing",monitorGainSmoothing,0.01f,1.0f);
    
      monitorLineBufferBytes = intValue(p,"monitor.lineBufferBytes",monitorLineBufferBytes,512,65536);
    
      playbackLineBufferBytes = intValue(p,"playback.lineBufferBytes",playbackLineBufferBytes,512,131072);
    
      speakerFrequencyHz = intValue(p,"speaker.frequencyHz",speakerFrequencyHz,80,12000);
    
      speakerDurationMs = intValue(p,"speaker.durationMs",speakerDurationMs,100,5000);
    
      speakerAmplitude = intValue(p,"speaker.amplitude",speakerAmplitude,100,32767);
    
      speakerFadeSamples = intValue(p,"speaker.fadeSamples",speakerFadeSamples,1,8000);
    
      speakerLineBufferBytes = intValue(p,"speaker.lineBufferBytes",speakerLineBufferBytes,512,65536);
    
  }

  String textValue(Properties p,String key,String fallback){return studio.services.configRules.text(p,key,fallback);
    }
  boolean boolValue(Properties p,String key,boolean fallback){return studio.services.configRules.flag(p,key,fallback);
    }
  int intValue(Properties p,String key,int fallback,int lo,int hi){return studio.services.configRules.integer(p,key,fallback,lo,hi);
    }
  float floatValue(Properties p,String key,float fallback,float lo,float hi){return studio.services.configRules.decimal(p,key,fallback,lo,hi);
    }
}


// ===== SynKinect Studio / Microphones / MicrophoneLocalization.pde =====
class MicrophoneI18n extends ModuleI18n {
  MicrophoneI18n(String requested){super("microphones",requested);}
}


class MicrophoneTheme {
  final int BG=0xFF11151A, SURFACE=0xFF181E25, SURFACE_ALT=0xFF202832, RAISED=0xFF293440;
  
  final int BORDER=0xFF35414D, TEXT=0xFFF4F7FA, MUTED=0xFFAAB6C2, ACTIVE=0xFF68A9E8, DIM=0xFF6F7C88;
  
  final int GOOD=0xFF7CC7A0, WARN=0xFFE4B86B, BAD=0xFFE17D7D, PREVIEW=0xFF0B0F13, GRID=0xFF35404A;
  
  final int FONT_TINY=STUDIO_FONT_TINY, FONT_SMALL=STUDIO_FONT_SMALL, FONT_BODY=STUDIO_FONT_BODY, FONT_LABEL=STUDIO_FONT_LABEL, FONT_METRIC=STUDIO_FONT_METRIC,
   FONT_TITLE=STUDIO_FONT_TITLE;
}

void initializeMicrophoneTypography(){if(studioUnicodeRegular==null||studioUnicodeHeading==null)initializeStudioTypography();
  }
void micText(float size,boolean heading){studioText(size,heading);}


class AudioCaptureControl {
  final int MAGIC=0x43414D52,VERSION=1,CMD_PING=0,CMD_GET=1,CMD_SET_VOLUME=2,CMD_SET_MUTE=3;
  
  volatile int volumePercent=100;
  volatile boolean muted=false,available=false;
  volatile String backend="driver",detail="audio-control endpoint unavailable";
  volatile long lastRefreshMs=0;
  void refreshIfDue(){long now=System.currentTimeMillis();if(now-lastRefreshMs<1000)return;
    lastRefreshMs=now;exchange(CMD_GET,0);}
  void setVolume(int percent){exchange(CMD_SET_VOLUME,constrain(percent,0,100));}
  void setMute(boolean value){exchange(CMD_SET_MUTE,value?1:0);}
  synchronized boolean exchange(int command,int value){
    KinectDevice device=studio.selectedKinect();
    if(device==null||!device.audioControlReady()){available=false;detail="audio-control endpoint unavailable";
      return false;}
    TransportEndpoint endpoint=studio.services.endpoints.audioControlFor(device.id);
    
    try(LocalTransport pipe=studio.services.transportFactory.open(endpoint.windowsPath,endpoint.linuxPath)){
      ByteBuffer q=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);q.putInt(MAGIC).putInt(VERSION).putInt(command).putInt(value);
      pipe.write(q.array());
      byte[] rb=new byte[20];pipe.readFully(rb);ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
      
      int magic=r.getInt(),version=r.getInt(),result=r.getInt(),volume=r.getInt(),mute=r.getInt();
      
      if(magic!=MAGIC||version!=VERSION||result!=0)throw new IOException("audio-control rejected request: "+result);
      
      volumePercent=constrain(volume,0,100);muted=mute!=0;available=true;detail="driver";
      return true;
    }catch(Exception e){available=false;detail=safeStudioMessage(e);return false;
      }
  }
  String summary(){return available?(muted?microphoneState().i18n.tr("button.mute")+" · ":"")+volumePercent+"%":microphoneState().i18n.tr("audio.unavailable");
    }
}
// ===== SynKinect Studio / Microphones / MicrophoneSource.pde =====
class MicrophoneSource implements SpatialAudioSessionListener {
  final MicrophoneConfig cfg;
  final AudioPipeline pipeline;
  final Object frameLock=new Object();
  volatile boolean running=false;
  volatile String deviceId="";
  volatile SpatialAudioDeviceSession session;
  SpatialAudioFrame latest;

  MicrophoneSource(MicrophoneConfig cfg,AudioPipeline pipeline){this.cfg=cfg;this.pipeline=pipeline;}

  synchronized void start(){
    if(running)return;
    running=true;
    bindSelectedDevice();
  }

  synchronized void requestStop(){
    if(!running)return;
    running=false;
    unbind();
  }

  synchronized void stop(){
    running=false;
    unbind();
  }

  void bindSelectedDevice(){
    String selected=selectedKinectDeviceId();
    if(selected==null)selected="";
    selected=selected.trim();
    if(selected.equals(deviceId)&&session!=null)return;
    unbind();
    deviceId=selected;
    if(!running||deviceId.isEmpty())return;
    session=studio.services.spatialAudioSessions.attach(deviceId,this);
  }

  void unbind(){
    SpatialAudioDeviceSession current=session;
    String currentId=deviceId;
    session=null;
    deviceId="";
    clearSnapshot();
    if(current!=null&&!currentId.isEmpty())studio.services.spatialAudioSessions.detach(currentId,this);
  }

  synchronized void requestReconnect(String reason,boolean selectionChanged){
    if(!running)return;
    String selected=selectedKinectDeviceId();
    if(selected==null)selected="";
    if(selectionChanged||!selected.equals(deviceId)){
      bindSelectedDevice();
      return;
    }
    SpatialAudioDeviceSession current=session;
    if(current!=null)current.requestReconnect(reason,selectionChanged);
  }

  void requestReconnect(String reason){requestReconnect(reason,false);}

  void clearSnapshot(){synchronized(frameLock){latest=null;}}
  SpatialAudioFrame snapshot(){synchronized(frameLock){return latest;}}
  boolean connected(){SpatialAudioDeviceSession current=session;return current!=null&&current.connected;}
  long frameCount(){SpatialAudioDeviceSession current=session;return current==null?0:current.frameCount;}
  long reconnectKicks(){SpatialAudioDeviceSession current=session;return current==null?0:current.reconnectKicks;}

  String displayStateKey(){
    SpatialAudioDeviceSession current=session;
    if(!running)return "source.starting";
    if(current==null)return "source.reconnecting";
    return current.displayStateKey();
  }

  String pipeModeKey(){return "source.pipe_primary";}

  public void onSpatialAudioFrame(SpatialAudioFrame frame,SpatialAudioScanFrame scan){
    if(!running||frame==null||scan==null)return;
    synchronized(frameLock){latest=frame;}
    pipeline.accept(frame,scan);
  }
}


// ===== SynKinect Studio / Microphones / MicrophoneUI.pde =====
class MicrophoneUI {
  final int ACTION_RECORD=0,ACTION_MONITOR=1,ACTION_PLAY=2,ACTION_TEST=3,ACTION_AUTO=4,ACTION_MANUAL=5,ACTION_VOL_DOWN=6,ACTION_VOL_UP=7,ACTION_MUTE=8;
  
 final ArrayList<MicButton> buttons=new ArrayList<MicButton>();

  MicrophoneUI(){
    buttons.add(new MicButton("button.record",ACTION_RECORD,true));
    buttons.add(new MicButton("button.monitor",ACTION_MONITOR,false));
    buttons.add(new MicButton("button.play",ACTION_PLAY,false));
    buttons.add(new MicButton("button.test",ACTION_TEST,false));
    buttons.add(new MicButton("mode.auto",ACTION_AUTO,false));
    buttons.add(new MicButton("mode.manual",ACTION_MANUAL,false));
    buttons.add(new MicButton("button.volume_down",ACTION_VOL_DOWN,false));
    buttons.add(new MicButton("button.volume_up",ACTION_VOL_UP,false));
    buttons.add(new MicButton("button.mute",ACTION_MUTE,false));
  }

  float statusHeight(){return studio.ui.metricPanelHeight(max(80,width-2*studioUiMargin()),6,false);
    }

  void draw(SpatialAudioFrame frame){
    drawHeader();
    MicrophoneTheme theme=microphoneState().theme;
    float m=studioUiMargin(),gap=studioUiGap(),w=max(80,width-2*m),statusY=studioUiHeaderHeight()+gap,statusH=statusHeight();
    
    drawTransportPanel(m,statusY,w,statusH);
    float bodyY=statusY+statusH+gap,bodyH=max(1,studio.contentHeight-bodyY-m);
    int[] captureActions={ACTION_RECORD,ACTION_MONITOR,ACTION_AUTO,ACTION_MANUAL};
    
    int[] playbackActions={ACTION_PLAY,ACTION_TEST,ACTION_VOL_DOWN,ACTION_VOL_UP,ACTION_MUTE};
    
    if(w>=720){
      float half=(w-gap)*.5f;
      float actionH=max(actionPanelHeight(half,captureActions.length),actionPanelHeight(w-half-gap,playbackActions.length));
      
      StudioUiRect[] bands=studio.ui.vertical(m,bodyY,w,bodyH,gap,new float[]{180,actionH},new float[]{90,actionH},new float[]{1,0});
      
      StudioUiRect micBand=bands[0],actionBand=bands[1];
      drawMicrophonePanel(micBand.x,micBand.y,micBand.w,micBand.h,frame);
      drawActionGroup(m,actionBand.y,half,actionBand.h,microphoneState().i18n.tr("panel.capture"),captureActions);
      
      drawActionGroup(m+half+gap,actionBand.y,w-half-gap,actionBand.h,microphoneState().i18n.tr("panel.playback"),playbackActions);
      
    }else{
      float captureH=actionPanelHeight(w,captureActions.length),playbackH=actionPanelHeight(w,playbackActions.length);
      
      StudioUiRect[] bands=studio.ui.vertical(m,bodyY,w,bodyH,gap,new float[]{160,captureH,playbackH},new float[]{80,captureH,playbackH},new float[]{1,
          0,0});
      drawMicrophonePanel(bands[0].x,bands[0].y,bands[0].w,bands[0].h,frame);
      drawActionGroup(bands[1].x,bands[1].y,bands[1].w,bands[1].h,microphoneState().i18n.tr("panel.capture"),captureActions);
      
      drawActionGroup(bands[2].x,bands[2].y,bands[2].w,bands[2].h,microphoneState().i18n.tr("panel.playback"),playbackActions);
      
    }
  }

  void drawHeader(){
    studio.ui.renderer.header(microphoneState().i18n,microphoneState().i18n.tr("app.title"));
    
  }

  void drawTransportPanel(float x,float y,float w,float h){
    card(x,y,w,h);studio.ui.renderer.panelTitle(microphoneState().i18n,x,y,w,microphoneState().i18n.tr("panel.transport"));
    
    boolean live=microphoneState().source!=null&&microphoneState().source.connected();
    String transportState=microphoneState().i18n.tr(microphoneState().source==null?"source.starting":microphoneState().source.displayStateKey());
    if(live)transportState+=" · "+microphoneState().i18n.tr(microphoneState().source.pipeModeKey());
    SpatialAudioScanFrame spatial=microphoneState().pipeline==null?null:microphoneState().pipeline.monitor.latestScan;
    String doa=spatial==null?"—":nf(spatial.azimuthDeg,1,1)+"° / "+nf(microphoneState().pipeline.monitor.beamAzimuthDeg,1,1)+"°";
    String reconnects=String.valueOf(microphoneState().source==null?0:microphoneState().source.reconnectKicks());
    String code=microphoneState().runtimeStatus.errorCode();if(code.length()>0)reconnects+=" · E"+code;
    
    String volume=microphoneState().captureControl==null?"—":microphoneState().captureControl.summary();
    String[] labels={microphoneState().i18n.tr("label.transport"),microphoneState().i18n.tr("label.frames"),microphoneState().i18n.tr("label.doa_beam"),
      microphoneState().i18n.tr("label.runtime"),microphoneState().i18n.tr("label.reconnects"),microphoneState().i18n.tr("label.volume")};
    
    String[] values={transportState,formatCount(microphoneState().source==null?0:microphoneState().source.frameCount()),doa,microphoneState().runtimeStatus.formatSummary(),
      reconnects,volume};boolean[] active={live,live,spatial!=null,"status.ok".equals(microphoneState().runtimeStatus.stateKey()),microphoneState().runtimeStatus.lastError()==0,
      microphoneState().captureControl!=null&&microphoneState().captureControl.available};
    
    StudioUiMetrics ui=studio.ui.metrics();float ix=x+ui.panelPad,iy=y+ui.cardTitleH+ui.panelPad*.45f,iw=max(1,w-ui.panelPad*2),ih=max(1,h-ui.cardTitleH-ui.panelPad*1.45f);
    studio.ui.drawMetricGrid(labels,values,active,ix,iy,iw,ih);
  }

  void metricTile(float x,float y,float w,float h,String label,String value,boolean active){studio.ui.renderer.metric(x,y,w,h,label,value,active);
    }

  void drawMicrophonePanel(float x,float y,float w,float h,SpatialAudioFrame frame){
    card(x,y,w,h);studio.ui.renderer.panelTitle(microphoneState().i18n,x,y,w,microphoneState().i18n.tr("panel.microphones"));
    
    float pad=10,innerY=y+studioUiCardTitleHeight()+4,innerH=max(1,h-studioUiCardTitleHeight()-14);
    
    drawMicrophoneGrid(x+pad,innerY,w-pad*2,innerH,frame);
  }

  void drawMicrophoneGrid(float x,float y,float w,float h,SpatialAudioFrame frame){
    float gap=studioUiGap(),cw=(w-gap)/2.0f,ch=(h-gap)/2.0f;
    for(int mic=0;mic<studio.services.spatialAudioProtocol.CHANNELS;mic++){
      int col=mic%2,row=mic/2;drawMicrophoneCard(x+col*(cw+gap),y+row*(ch+gap),cw,ch,mic,frame);
      
    }
  }

  void drawMicrophoneCard(float x,float y,float w,float h,int mic,SpatialAudioFrame frame){
    card(x,y,w,h);boolean valid=frame!=null&&frame.channelValid(mic);float peak=valid?frame.peak[mic]:0;
    
    fill(valid?microphoneState().theme.ACTIVE:microphoneState().theme.DIM);ellipse(x+14,y+17,7,7);
    
    fill(microphoneState().theme.MUTED);micText(microphoneState().theme.FONT_SMALL,false);
    textAlign(LEFT,CENTER);String micLabel=microphoneState().i18n.tr("label.mic")+" "+(mic+1);
    fitCurrentTextSize(micLabel,microphoneState().theme.FONT_SMALL,7,max(30,w-105),24);
    text(ellipsizeToWidth(micLabel,max(30,w-105)),x+25,y+17);
    fill(microphoneState().theme.TEXT);textAlign(RIGHT,CENTER);micText(microphoneState().theme.FONT_SMALL,true);
    text(valid?nf(peak*100,1,1)+"%":"—",x+w-12,y+17);textAlign(LEFT,BASELINE);

    float meterX=x+12,meterY=y+31,meterW=w-24;fill(microphoneState().theme.GRID);
    noStroke();rect(meterX,meterY,meterW,5,2.5f);fill(valid?microphoneState().theme.ACTIVE:microphoneState().theme.DIM);
    rect(meterX,meterY,meterW*constrain(peak,0,1),5,2.5f);
    float wx=x+12,wy=y+47,ww=max(1,w-24),wh=max(1,h-59);fill(microphoneState().theme.PREVIEW);
    rect(wx,wy,ww,wh,8);stroke(microphoneState().theme.GRID);line(wx,wy+wh/2,wx+ww,wy+wh/2);
    
    if(!valid)return;
    stroke(microphoneState().theme.ACTIVE);noFill();beginShape();
    for(int i=0;i<studio.services.spatialAudioProtocol.SAMPLES;i++){
      float sx=map(i,0,studio.services.spatialAudioProtocol.SAMPLES-1,wx+4,wx+ww-4);
      float normalized=constrain(frame.samples[mic][i]/2147483648.0f,-1,1);float sy=wy+wh/2-normalized*wh*0.43f;
      vertex(sx,sy);
    }
    endShape();
  }


  float actionPanelHeight(float panelW,int count){return studio.ui.actionPanelHeight(panelW,count,true);
    }
  void drawActionGroup(float x,float y,float w,float h,String title,int[] actions){
    card(x,y,w,h);studio.ui.renderer.panelTitle(microphoneState().i18n,x,y,w,title);
    StudioUiMetrics ui=studio.ui.metrics();ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();
    for(int action:actions){MicButton b=findButton(action);if(b!=null){b.configure(b.label(),b.actionEnabled(),b.active(),b.primary,false);
        items.add(b);}}float footer=ui.footerH;studio.ui.layoutButtons(items,x+ui.panelPad,y+ui.cardTitleH+ui.panelPad*.45f,max(1,w-ui.panelPad*2),max(1,
      h-ui.cardTitleH-ui.panelPad*1.45f-footer));for(StudioUiButton item:items)item.draw();
    studio.ui.renderer.statusFooter(x+ui.panelPad,y+h-footer,w-ui.panelPad*2,footer,groupStatus(actions),true);
    
  }

  String groupStatus(int[] actions){
    if(containsAction(actions,ACTION_RECORD)){
      if(microphoneState().pipeline.recorder.isRecording())return microphoneState().i18n.format("status.recording",formatBytes(microphoneState().pipeline.recorder.bytes()));
      
      if(microphoneState().pipeline.monitor.isRunning()){
        SpatialAudioScanFrame scan=microphoneState().pipeline.monitor.latestScan;
        
        String doa=scan==null?"—":nf(scan.azimuthDeg,1,1)+"°";
        String mode=microphoneState().i18n.tr(microphoneState().pipeline.monitor.automaticBeam?"mode.auto":"mode.manual");
        
        return "DOA "+doa+" · "+microphoneState().i18n.tr("label.doa_beam")+" "+nf(microphoneState().pipeline.monitor.beamAzimuthDeg,1,1)+"° · "+mode;
        
      }
      String key=microphoneState().pipeline.recorder.state();return microphoneState().i18n.tr(key);
      
    }
    if(containsAction(actions,ACTION_PLAY)){
      if(microphoneState().pipeline.player.isRunning())return microphoneState().i18n.format("status.playback",microphoneState().pipeline.player.fileName);
      
      if(microphoneState().pipeline.selfTest.isRunning())return microphoneState().i18n.format("status.speaker",microphoneState().config.speakerFrequencyHz);
      
      String key=!"playback.idle".equals(microphoneState().pipeline.player.state())?microphoneState().pipeline.player.state():microphoneState().pipeline.selfTest.state();
      
      return microphoneState().i18n.tr(key);
    }
    return microphoneState().i18n.tr(microphoneState().runtimeStatus.stateKey())+" · "+microphoneState().runtimeStatus.compactCounters();
    
  }

  boolean containsAction(int[] actions,int action){for(int a:actions)if(a==action)return true;
    return false;}
  MicButton findButton(int action){for(MicButton b:buttons)if(b.action==action)return b;
    return null;}
  boolean handleMousePressed(float mx,float my){for(MicButton b:buttons)if(b.hit(mx,my)){b.fire();
      return true;}return false;}
  void card(float x,float y,float w,float h){studio.ui.panel("",x,y,w,h).draw(microphoneState().i18n);
     }
  String formatCount(long value){if(value>=1000000)return nf(value/1000000.0f,1,1)+"M";
    if(value>=1000)return nf(value/1000.0f,1,1)+"k";return String.valueOf(value);
    }
  String formatBytes(long value){if(value>=1024L*1024L)return nf(value/(1024.0f*1024.0f),1,1)+" MB";
    if(value>=1024)return nf(value/1024.0f,1,1)+" KB";return value+" B";}
  String ellipsize(String s,int limit){if(s==null)return "";return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…";
    }
}

class MicButton extends StudioUiButton {final String labelKey;final int action;final boolean primary;
  
  MicButton(String key,int action,boolean primary){labelKey=key;this.action=action;
    this.primary=primary;}
  void setBounds(float x,float y,float w,float h){place(x,y,w,h);}
  boolean active(){
    if(action==microphoneState().ui.ACTION_AUTO)return microphoneState().pipeline.monitor.automaticBeam;
    
    if(action==microphoneState().ui.ACTION_MANUAL)return !microphoneState().pipeline.monitor.automaticBeam;
    
    if(action==microphoneState().ui.ACTION_MUTE)return microphoneState().captureControl!=null&&microphoneState().captureControl.muted;
    
    if(action==microphoneState().ui.ACTION_RECORD) return microphoneState().pipeline.recorder.isRecording();
    if(action==microphoneState().ui.ACTION_MONITOR) return microphoneState().pipeline.monitor.isRunning();
    if(action==microphoneState().ui.ACTION_PLAY) return microphoneState().pipeline.player.isRunning();
    if(action==microphoneState().ui.ACTION_TEST) return microphoneState().pipeline.selfTest.isRunning();
    return false;
    
  }
  String label(){
    if(action==microphoneState().ui.ACTION_AUTO||action==microphoneState().ui.ACTION_MANUAL)return microphoneState().i18n.tr(labelKey);
    
    if(action==microphoneState().ui.ACTION_VOL_DOWN||action==microphoneState().ui.ACTION_VOL_UP||action==microphoneState().ui.ACTION_MUTE)return microphoneState().i18n.tr(labelKey);
    
    if(active())return microphoneState().i18n.tr("button.stop");return microphoneState().i18n.tr(labelKey);
    
  }
  boolean driverCaptureControlAction(){return action==microphoneState().ui.ACTION_VOL_DOWN||action==microphoneState().ui.ACTION_VOL_UP||action==microphoneState().ui.ACTION_MUTE;
    }
  boolean actionEnabled(){KinectDevice d=studio.selectedKinect();if(driverCaptureControlAction())return d!=null&&d.audioControlReady()&&microphoneState().captureControl!=null;
    if(action==microphoneState().ui.ACTION_RECORD||action==microphoneState().ui.ACTION_MONITOR||action==microphoneState().ui.ACTION_AUTO||action==microphoneState().ui.ACTION_MANUAL)return d!=null&&d.audioReady();
    return true;}
  void draw(){boolean on=active();configure(label(),actionEnabled(),on,primary,false);
    super.draw();}
  void fire(){if(!actionEnabled())return;dispatchMicrophoneAction(action);}
}


