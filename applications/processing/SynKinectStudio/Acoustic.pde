// Responsive geometry is supplied by StudioUiMetrics.

// ===== SynKinect Studio / Acoustic Scanner / Module.pde =====
AcousticModuleState acousticState(){return studio.state(AcousticModuleState.class);
  }

class AcousticModuleState {
  final AcousticTheme theme=new AcousticTheme();

  SpatialAudioConfig config;
  AcousticI18n i18n;
  AcousticSource source;
  SpatialAudioEngine beamEngine;
  SpatialAutoSteerer autoSteerer;
  AcousticBeamOutput output;
  AcousticUI ui;
  volatile SpatialAudioScanFrame scan;
  volatile boolean automaticBeam=true;
  volatile float manualAzimuthDeg=0;
  volatile float beamAzimuthDeg=0;
}

void setupAcousticModule(){
  acousticState().config=studio.services.spatialAudioSessions.config();
  
  acousticState().i18n=new AcousticI18n(studio.currentLanguage());
  initializeAcousticTypography();
  acousticState().beamEngine=new SpatialAudioEngine(acousticState().config);
  acousticState().autoSteerer=new SpatialAutoSteerer(acousticState().config);
  acousticState().output=new AcousticBeamOutput(acousticState().config);
  acousticState().source=new AcousticSource(acousticState().config);
  acousticState().ui=new AcousticUI();
}

void drawAcousticModule(){
  background(acousticState().theme.BG);
  SpatialAudioFrame frame=acousticState().source==null?null:acousticState().source.snapshot();
  
  acousticState().ui.draw(frame,acousticState().scan);
}

void acousticMousePressed(){if(acousticState().ui!=null)acousticState().ui.handleMouse(studio.contentMouseX(),studio.contentMouseY());
  }
void resetAcousticMap(){if(acousticState().source!=null)acousticState().source.resetAnalysis();
  if(acousticState().beamEngine!=null)acousticState().beamEngine.reset();
  if(acousticState().autoSteerer!=null)acousticState().autoSteerer.reset();acousticState().scan=null;
  }
void disposeAcousticModule(){
  if(acousticState().source!=null)acousticState().source.stop();
  if(acousticState().output!=null)acousticState().output.stop();
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticLocalization.pde =====
class AcousticI18n extends ModuleI18n {
  AcousticI18n(String requested){super("acoustic",requested);}
}


class AcousticTheme {
  final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE2=0xFF202832,RAISED=0xFF293440;
  
  final int BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,GRID=0xFF35404A,ACTIVE=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B;
  
  final int FONT_TINY=STUDIO_FONT_TINY,FONT_SMALL=STUDIO_FONT_SMALL,FONT_BODY=STUDIO_FONT_BODY,FONT_LABEL=STUDIO_FONT_LABEL,FONT_METRIC=STUDIO_FONT_METRIC,
  FONT_TITLE=STUDIO_FONT_TITLE;
}

void initializeAcousticTypography(){if(studioUnicodeRegular==null||studioUnicodeHeading==null)initializeStudioTypography();
  }
void acousticText(float size,boolean heading){studioText(size,heading);}


// ===== SynKinect Studio / Acoustic Scanner / AcousticSource.pde =====
class AcousticSource implements SpatialAudioSessionListener {
  final SpatialAudioConfig cfg;
  final Object frameLock=new Object();
  volatile boolean running=false;
  volatile String deviceId="";
  volatile SpatialAudioDeviceSession session;
  SpatialAudioFrame latest;

  AcousticSource(SpatialAudioConfig cfg){this.cfg=cfg;}

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
    synchronized(frameLock){latest=null;}
    if(current!=null&&!currentId.isEmpty())studio.services.spatialAudioSessions.detach(currentId,this);
  }

  void requestReconnect(String reason){requestReconnect(reason,false);}

  synchronized void requestReconnect(String reason,boolean selectionChanged){
    if(!running)return;
    String selected=selectedKinectDeviceId();
    if(selected==null)selected="";
    if(selectionChanged||!selected.equals(deviceId)){
      bindSelectedDevice();
      if(acousticState().autoSteerer!=null)acousticState().autoSteerer.reset();
      acousticState().scan=null;
      return;
    }
    SpatialAudioDeviceSession current=session;
    if(current!=null)current.requestReconnect(reason,selectionChanged);
  }

  void resetAnalysis(){
    SpatialAudioDeviceSession current=session;
    if(current!=null)current.resetAnalysis();
    acousticState().scan=null;
  }

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

  public void onSpatialAudioFrame(SpatialAudioFrame frame,SpatialAudioScanFrame scan){
    if(!running||frame==null||scan==null)return;
    synchronized(frameLock){latest=frame;}
    acousticState().scan=scan;
    float target=acousticState().manualAzimuthDeg;
    if(acousticState().automaticBeam&&acousticState().autoSteerer!=null){
      target=acousticState().autoSteerer.update(scan,acousticState().beamAzimuthDeg,System.currentTimeMillis());
    }
    acousticState().beamAzimuthDeg=constrain(target,-90,90);
    if(acousticState().output!=null&&acousticState().beamEngine!=null){
      acousticState().output.offer(acousticState().beamEngine.beamform(frame,acousticState().beamAzimuthDeg,scan));
    }
  }
}


// ===== SynKinect Studio / Acoustic Scanner / Beamformed Windows output =====
class AcousticBeamOutput {
  final SpatialAudioConfig cfg;final Object lock=new Object();final ArrayDeque<short[]> queue=new ArrayDeque<short[]>();
  
  volatile boolean running=false;volatile long runGeneration=0;volatile String stateKey="output.idle",detail="";
  volatile long dropped=0,frames=0;Thread worker;SourceDataLine line;
  AcousticBeamOutput(SpatialAudioConfig cfg){this.cfg=cfg;}
  synchronized void start(){if(running)return;running=true;stateKey="output.starting";
    final long generation=++runGeneration;worker=studio.services.workers.start("Acoustic-BeamOutput",new Runnable(){public void run(){loop(generation);}
      });}
  void offer(short[] pcm){if(!running||pcm==null)return;synchronized(lock){while(queue.size()>=cfg.beamQueueFrames){queue.removeFirst();
        dropped++;}queue.addLast(pcm);lock.notifyAll();}}
  void requestStop(){Thread t;running=false;++runGeneration;synchronized(lock){queue.clear();
      lock.notifyAll();}closeLine();t=worker;worker=null;if(t!=null&&t!=Thread.currentThread())t.interrupt();
    if(!"output.error".equals(stateKey))stateKey="output.idle";}
  void stop(){running=false;++runGeneration;synchronized(lock){lock.notifyAll();}closeLine();
    Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread()){t.interrupt();
      try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();
        }}synchronized(lock){queue.clear();}if(!"output.error".equals(stateKey))stateKey="output.idle";
    }
  void loop(long generation){
    SourceDataLine local=null;
    try{
      AudioFormat fmt=new AudioFormat((float)16000,16,1,true,false);
      local=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,fmt));
      
      local.open(fmt,cfg.beamLineBufferBytes);local.start();
      synchronized(lock){if(generation==runGeneration)line=local;}
      if(generation==runGeneration)stateKey="output.live";
      while(running&&generation==runGeneration){
        short[] block=null;
        synchronized(lock){
          while(running&&generation==runGeneration&&queue.isEmpty())try{lock.wait(100);
            }catch(InterruptedException e){if(!running||generation!=runGeneration)return;
            }
          if(!queue.isEmpty())block=queue.removeFirst();
        }
        if(block==null)continue;
        ByteBuffer b=ByteBuffer.allocate(block.length*2).order(ByteOrder.LITTLE_ENDIAN);
        for(short v:block)b.putShort(v);
        local.write(b.array(),0,b.position());frames++;
      }
    }catch(Exception e){if(generation==runGeneration){detail=safeStudioMessage(e);
        stateKey="output.error";}}
    finally{if(generation==runGeneration)running=false;closeLine(local);}
  }
  void closeLine(){SourceDataLine current;synchronized(lock){current=line;line=null;
      }closeLine(current);}
  void closeLine(SourceDataLine current){if(current==null)return;synchronized(lock){if(line==current)line=null;
      }try{current.stop();}catch(Exception ignored){}try{current.flush();}catch(Exception ignored){}try{current.close();
      }catch(Exception ignored){}}
}

// ===== SynKinect Studio / Acoustic Scanner / AcousticUI.pde =====
class AcousticUI {
  final StudioUiButton autoButton=new StudioUiButton(),manualButton=new StudioUiButton(),resetButton=new StudioUiButton();
  
  float radarCx,radarCy,radarR,radarX,radarY,radarW,radarH;

  float statusHeight(){return studio.ui.metricPanelHeight(max(80,width-2*studioUiMargin()),6,false);
    }
  float controlsHeight(float panelW){return max(132*studioUiScale(),studio.ui.actionPanelHeight(panelW,3,false)+18*studioUiScale());
    }
  void draw(SpatialAudioFrame frame,SpatialAudioScanFrame scan){drawHeader();drawStatus(frame,scan);
    drawBody(frame,scan);}

  void drawHeader(){
    studio.ui.renderer.header(acousticState().i18n,acousticState().i18n.tr("app.title"));
    
  }

  void drawStatus(SpatialAudioFrame frame,SpatialAudioScanFrame scan){
    float x=studioUiMargin(),y=studioUiHeaderHeight()+studioUiGap(),w=width-2*studioUiMargin(),h=statusHeight();
    card(x,y,w,h);cardTitle(x,y,w,acousticState().i18n.tr("panel.status"));
    String state=acousticState().source==null?"source.starting":acousticState().source.displayStateKey(),transport=acousticState().i18n.tr(state);
    
    String pos=scan==null||!Float.isFinite(scan.positionXM)?"—":nf(scan.positionXM,1,2)+" / "+nf(scan.positionZM,1,2)+" m";
    
    String voice=scan==null?"—":(scan.speech?acousticState().i18n.format("voice.detected",scan.voiceProbability*100,scan.snrDb):acousticState().i18n.format("voice.noise",
      scan.voiceProbability*100,scan.snrDb));
    String[] labels={acousticState().i18n.tr("label.transport"),acousticState().i18n.tr("label.frames"),acousticState().i18n.tr("label.azimuth"),acousticState().i18n.tr("label.position"),
      acousticState().i18n.tr("label.beam"),acousticState().i18n.tr("label.voice")};
    
    String[] values={transport,String.valueOf(acousticState().source==null?0:acousticState().source.frameCount()),scan==null?"—":nf(scan.azimuthDeg,1,1)+"°",
      pos,nf(acousticState().beamAzimuthDeg,1,1)+"°",voice};
    boolean[] active={acousticState().source!=null&&acousticState().source.connected(),true,scan!=null,scan!=null&&Float.isFinite(scan.positionXM),true,scan!=null&&scan.speech}
    ;
    StudioUiMetrics ui=studio.ui.metrics();float ix=x+ui.panelPad,iy=y+ui.cardTitleH+ui.panelPad*.45f,iw=max(1,w-ui.panelPad*2),ih=max(1,h-ui.cardTitleH-ui.panelPad*1.45f);
    
    studio.ui.drawMetricGrid(labels,values,active,ix,iy,iw,ih);
  }

  void drawBody(SpatialAudioFrame frame,SpatialAudioScanFrame scan){
    float x=studioUiMargin(),y=studioUiHeaderHeight()+studioUiGap()+statusHeight()+studioUiGap(),w=width-2*studioUiMargin(),h=max(1,studio.contentHeight-y-studioUiMargin()),
    g=studioUiGap();
    if(w>=820){
      float rightW=constrain(w*0.30f,300,min(420,w*.45f)),leftW=max(160,w-rightW-g),rightX=x+leftW+g,controlH=controlsHeight(rightW);
      
      StudioUiRect[] side=studio.ui.vertical(rightX,y,rightW,h,g,new float[]{controlH,180},new float[]{controlH,100},new float[]{0,1});
      
      drawRadar(x,y,leftW,h,scan);drawControls(side[0].x,side[0].y,side[0].w,side[0].h);
      drawMicLevels(side[1].x,side[1].y,side[1].w,side[1].h,frame);
    }else{
      float controlH=controlsHeight(w);
      StudioUiRect[] bands=studio.ui.vertical(x,y,w,h,g,new float[]{controlH,180,100},new float[]{controlH,90,80},new float[]{0,1,.35f});
      
      drawControls(bands[0].x,bands[0].y,bands[0].w,bands[0].h);drawRadar(bands[1].x,bands[1].y,bands[1].w,bands[1].h,scan);
      drawMicLevels(bands[2].x,bands[2].y,bands[2].w,bands[2].h,frame);
    }
  }

  void drawControls(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,acousticState().i18n.tr("panel.controls"));
    StudioUiMetrics metrics=studio.ui.metrics();float pad=metrics.panelPad,by=y+metrics.cardTitleH+metrics.panelPad*.5f,inner=max(1,w-pad*2),available=max(1,
      h-metrics.cardTitleH-metrics.panelPad*1.5f);
    ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();
    autoButton.configure(acousticState().i18n.tr("button.auto"),true,acousticState().automaticBeam,false,false);
    
    manualButton.configure(acousticState().i18n.tr("button.manual"),true,!acousticState().automaticBeam,false,false);
    
    resetButton.configure(acousticState().i18n.tr("button.reset"),true,false,false,false);
    
    items.add(autoButton);items.add(manualButton);items.add(resetButton);studio.ui.layoutButtons(items,x+pad,by,inner,available);
    for(StudioUiButton item:items)item.draw();
  }

  void drawRadar(float x,float y,float w,float h,SpatialAudioScanFrame scan){
    radarX=x;radarY=y;radarW=w;radarH=h;card(x,y,w,h);cardTitle(x,y,w,acousticState().i18n.tr("panel.radar"));
    
    float cx=x+w/2,cy=y+h-48,maxR=max(8,min(w*0.44f,(h-studioUiCardTitleHeight()-40)*0.94f));
    radarCx=cx;radarCy=cy;radarR=maxR;stroke(acousticState().theme.GRID);noFill();
    
    for(int r=1;r<=4;r++)arc(cx,cy,maxR*r/2,maxR*r/2,PI,TWO_PI);for(int a=-90;a<=90;a+=30){float t=radians(a);
      line(cx,cy,cx+maxR*sin(t),cy-maxR*cos(t));}
    fill(acousticState().theme.MUTED);acousticText(acousticState().theme.FONT_TINY,false);
    textAlign(CENTER,CENTER);for(int a=-90;a<=90;a+=30){float t=radians(a);text(a+"°",cx+(maxR+18)*sin(t),cy-(maxR+18)*cos(t));
      }
    if(scan!=null){noStroke();fill(acousticState().theme.ACTIVE,42);beginShape();
      vertex(cx,cy);for(int i=0;i<scan.occupancy.length;i++){float t=radians(-90+i),r=maxR*(0.18f+0.82f*constrain(scan.occupancy[i]*5,0,1));
        vertex(cx+r*sin(t),cy-r*cos(t));}vertex(cx,cy);endShape(CLOSE);float t=radians(scan.azimuthDeg);
      stroke(acousticState().theme.ACTIVE);strokeWeight(2);line(cx,cy,cx+maxR*sin(t),cy-maxR*cos(t));
      noStroke();fill(acousticState().theme.TEXT);ellipse(cx+maxR*0.82f*sin(t),cy-maxR*0.82f*cos(t),10,10);
      }
    float bt=radians(acousticState().beamAzimuthDeg);stroke(acousticState().theme.GOOD);
    strokeWeight(3);line(cx,cy,cx+maxR*0.94f*sin(bt),cy-maxR*0.94f*cos(bt));noStroke();
    
    fill(acousticState().theme.MUTED);textAlign(LEFT,TOP);acousticText(acousticState().theme.FONT_SMALL,false);
    String note=acousticState().i18n.tr(acousticState().automaticBeam?"radar.note_auto":"radar.note_manual");
    fitCurrentTextSize(note,acousticState().theme.FONT_SMALL,7,w-28,30);text(ellipsizeToWidth(note,w-28),x+14,y+studioUiCardTitleHeight()+8);
    textAlign(LEFT,BASELINE);
    String status=scan==null?acousticState().i18n.tr("status.waiting"):acousticState().i18n.format("status.scan_voice",scan.azimuthDeg,scan.confidence*100,
      scan.voiceProbability*100,scan.snrDb);fill(acousticState().theme.MUTED);acousticText(acousticState().theme.FONT_SMALL,false);
    fitCurrentTextSize(status,acousticState().theme.FONT_SMALL,7,w-28,24);text(ellipsizeToWidth(status,w-28),x+14,y+h-18);
    
  }

  void drawMicLevels(float x,float y,float w,float h,SpatialAudioFrame frame){card(x,y,w,h);
    cardTitle(x,y,w,acousticState().i18n.tr("panel.microphones"));float top=y+studioUiCardTitleHeight()+8,rowH=max(1,(h-studioUiCardTitleHeight()-16)/4.0f);
    for(int ch=0;ch<4;ch++){float yy=top+ch*rowH,peak=frame==null?0:frame.peak[ch];
      fill(acousticState().theme.MUTED);acousticText(acousticState().theme.FONT_SMALL,false);
      text(acousticState().i18n.format("label.mic",ch+1),x+16,yy+14);fill(acousticState().theme.TEXT);
      textAlign(RIGHT,BASELINE);text(nf(peak*100,1,1)+"%",x+w-16,yy+14);textAlign(LEFT,BASELINE);
      float bx=x+16,by=yy+24,bw=w-32;fill(acousticState().theme.GRID);rect(bx,by,bw,9,4.5f);
      fill(acousticState().theme.ACTIVE);rect(bx,by,bw*constrain(peak,0,1),9,4.5f);
      }}
  void card(float x,float y,float w,float h){studio.ui.panel("",x,y,w,h).draw(acousticState().i18n);
     }
  void cardTitle(float x,float y,float w,String title){studio.ui.renderer.panelTitle(acousticState().i18n,x,y,w,title);
    }
  void metric(float x,float y,float w,float h,String label,String value,boolean active){studio.ui.renderer.metric(x,y,w,h,label,value,active);
    }
  void handleMouse(float mx,float my){if(resetButton.hit(mx,my)){resetAcousticMap();
      return;}if(autoButton.hit(mx,my)){acousticState().automaticBeam=true;if(acousticState().autoSteerer!=null)acousticState().autoSteerer.reset();
      return;}if(manualButton.hit(mx,my)){acousticState().automaticBeam=false;return;
      }if(!acousticState().automaticBeam&&hit(mx,my,radarX,radarY,radarW,radarH)){float dx=mx-radarCx,dy=radarCy-my;
      if(dy>=-8){acousticState().manualAzimuthDeg=constrain(degrees(atan2(dx,max(1,dy))),-90,90);
        acousticState().beamAzimuthDeg=acousticState().manualAzimuthDeg;}}}
  boolean hit(float mx,float my,float x,float y,float w,float h){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;
    }
}
