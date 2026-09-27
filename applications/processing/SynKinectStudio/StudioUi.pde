// ===== SynKinect Studio / shared responsive UI system =====
// Built-in and declarative external modules use the same components and sizing
// rules. Modules provide content and behavior; the host owns presentation,
// responsive layout, typography, hit testing and localization-safe fitting.

class StudioUiMetrics {
  final float scale,margin,gap,radius,headerH,cardTitleH,buttonH,buttonMinH,metricH,footerH,panelPad,minButtonW,maxButtonW,minMetricW,maxMetricW,minPanelW;

  final boolean compact,shortViewport;
  StudioUiMetrics(){
    float cw=max(1,width),ch=max(1,studio==null?height-STUDIO_TOP_BAR_H:studio.contentHeight);

    float growth=max(1.0f,min(cw/1440.0f,ch/850.0f));
    scale=constrain(pow(growth,0.18f),1.00f,1.30f);
    compact=cw<1200||ch<650;
    shortViewport=ch<600;

    // Bounded viewport-relative insets keep the workspace dense while
    // preserving a comfortable edge at every supported window size.
    margin=constrain(cw*0.020f,14*scale,30*scale);
    gap=constrain(cw*0.0105f,12*scale,24*scale);
    radius=constrain(13*scale,10,18);
    headerH=constrain(66*scale,54,86);
    cardTitleH=constrain(42*scale,36,56);
    buttonH=constrain(40*scale,34,52);
    buttonMinH=constrain(34*scale,30,44);
    metricH=constrain(48*scale,42,64);
    footerH=constrain(30*scale,26,40);
    panelPad=constrain(11*scale,9,18);
    minButtonW=constrain(96*scale,84,128);
    maxButtonW=constrain(184*scale,164,240);
    minMetricW=constrain(142*scale,122,190);
    maxMetricW=constrain(238*scale,214,310);
    minPanelW=constrain(360*scale,330,470);
  }
  float workspaceWidth(){return max(1,width-2*margin);}
  int columns(float available,int count,float minimumWidth){
    if(count<=1)return max(1,count);
    float g=max(7,gap*.62f),usable=max(1,available);
    int cols=max(1,floor((usable+g)/(max(52,minimumWidth)+g)));
    return min(count,cols);
  }
  int actionColumns(float available,int count){return columns(available,count,minButtonW);
    }
  int metricColumns(float available,int count){return columns(available,count,minMetricW);
    }
  int panelColumns(float available,int count){return columns(available,count,minPanelW);
    }
  float actionPanelHeight(float panelW,int count,boolean footer){
    int cols=actionColumns(max(1,panelW-panelPad*2),max(1,count));
    int rows=(max(1,count)+cols-1)/cols;
    float g=max(7,gap*.62f),buttons=rows*buttonH+max(0,rows-1)*g;
    return cardTitleH+panelPad*.55f+buttons+panelPad+(footer?footerH:0);
  }
  float metricPanelHeight(float panelW,int count,boolean footer){
    int cols=metricColumns(max(1,panelW-panelPad*2),max(1,count));
    int rows=(max(1,count)+cols-1)/cols;
    float g=max(7,gap*.62f),tiles=rows*metricH+max(0,rows-1)*g;
    return cardTitleH+panelPad*.55f+tiles+panelPad+(footer?footerH:0);
  }
}

StudioUiMetrics studioUiMetrics(){return new StudioUiMetrics();}
float studioUiMargin(){return studioUiMetrics().margin;}
float studioUiGap(){return studioUiMetrics().gap;}
float studioUiHeaderHeight(){return studioUiMetrics().headerH;}
float studioUiCardTitleHeight(){return studioUiMetrics().cardTitleH;}
String studioUiDisplayText(String value){return studioDisplayCase(value,studio==null||studio.i18n==null?"":studio.i18n.language);}

class StudioUiRect {
  float x,y,w,h;
  StudioUiRect(){}
  StudioUiRect(float x,float y,float w,float h){set(x,y,w,h);}
  StudioUiRect set(float x,float y,float w,float h){this.x=x;this.y=y;this.w=max(0,w);
    this.h=max(0,h);return this;}
  boolean hit(float px,float py){return px>=x&&px<=x+w&&py>=y&&py<=y+h;}
}

class StudioUiModuleFrontend {
  final ModuleI18n i18n;
  StudioUiModuleFrontend(ModuleI18n i18n){this.i18n=i18n;}
  StudioUiPanel panel(String title,float x,float y,float w,float h){StudioUiPanel p=new StudioUiPanel(title).place(x,y,w,h);p.draw(i18n);return p;}
  void panelTitle(float x,float y,float w,String title){studio.ui.renderer.panelTitle(i18n,x,y,w,title);}
  StudioUiRect body(float x,float y,float w,float h,boolean footer){return studio.ui.panelBody(x,y,w,h,footer);}
  void status(float x,float y,float w,float h,String value,boolean good){studio.ui.renderer.statusFooter(x,y,w,h,value,good);}
  void location(float x,float y,float w,float h,String label,File directory,boolean writable){studio.ui.renderer.locationFooter(x,y,w,h,label,directory,writable);}
  void buttons(ArrayList<StudioUiButton> buttons,float x,float y,float w,float h){studio.ui.layoutButtons(buttons,x,y,w,h);for(StudioUiButton b:buttons)b.draw();}
  void metrics(ArrayList<StudioUiMetric> metrics,float x,float y,float w,float h){studio.ui.layoutMetrics(metrics,x,y,w,h);for(StudioUiMetric m:metrics)m.draw();}
}

class StudioUiPanel extends StudioUiRect {
  String title="";
  StudioUiPanel(){}
  StudioUiPanel(String title){this.title=title==null?"":title;}
  StudioUiPanel place(float x,float y,float w,float h){set(x,y,w,h);return this;}
  void draw(ModuleI18n i18n){studio.ui.renderer.panel(x,y,w,h);if(title!=null&&!title.isEmpty())studio.ui.renderer.panelTitle(i18n,x,y,w,title);
    }
}

class StudioUiButton extends StudioUiRect {
  String label="";boolean enabled=true,selected=false,primary=false,quiet=false;
  long clickFlashUntilMs=0;
  String requiredCapability="";
  StudioUiButton(){}
  StudioUiButton(String label){this.label=label==null?"":label;}
  StudioUiButton require(String capability){requiredCapability=capability==null?"":capability.trim();return this;}
  StudioUiButton configure(String label,boolean enabled,boolean selected,boolean primary,boolean quiet){this.label=label==null?"":label;
    this.enabled=enabled&&studio.ui.capabilityAvailable(requiredCapability);this.selected=selected;this.primary=primary;this.quiet=quiet;
    return this;}
  StudioUiButton place(float x,float y,float w,float h){set(x,y,w,h);return this;
    }
  boolean hit(float px,float py){boolean yes=enabled&&super.hit(px,py);if(yes)clickFlashUntilMs=millis64()+150;return yes;}
  void draw(){boolean flash=enabled&&millis64()<clickFlashUntilMs;studio.ui.renderer.button(x,y,w,h,label,enabled,selected||flash,primary,quiet);
    }
}

class StudioUiMetric extends StudioUiRect {
  String label="",value="";boolean active=false;
  StudioUiMetric setContent(String label,String value,boolean active){this.label=label==null?"":label;
    this.value=value==null?"":value;this.active=active;return this;}
  StudioUiMetric place(float x,float y,float w,float h){set(x,y,w,h);return this;
    }
  void draw(){studio.ui.renderer.metric(x,y,w,h,label,value,active);}
}

class StudioUiRenderer {
  void header(ModuleI18n i18n,String title){
    title=studioUiDisplayText(title);
    StudioUiMetrics m=studioUiMetrics();pushStyle();rectMode(CORNER);colorMode(RGB,255);
    strokeWeight(1);strokeCap(ROUND);
    noStroke();fill(0xFF11151A);rect(0,0,width,m.headerH);fill(0xFF203A52);rect(0,m.headerH-2,width,2);
    fill(0xFFF4F7FA);studioText(STUDIO_FONT_TITLE,true);textAlign(i18n.startAlign(),CENTER);

    float textW=max(80,width-2*m.margin),tx=i18n.rtl?width-m.margin:m.margin;fitCurrentTextSize(title,STUDIO_FONT_TITLE,9,textW,m.headerH-8);
    text(ellipsizeToWidth(title,textW),tx,m.headerH*.5f);popStyle();
  }
  void panel(float x,float y,float w,float h){StudioUiMetrics m=studioUiMetrics();
    pushStyle();rectMode(CORNER);colorMode(RGB,255);stroke(0xFF35414D);strokeWeight(1);
    strokeCap(ROUND);fill(0xFF181E25);rect(x,y,w,h,m.radius);popStyle();}
  void panelTitle(ModuleI18n i18n,float x,float y,float w,String title){title=studioUiDisplayText(title);StudioUiMetrics m=studioUiMetrics();
    pushStyle();colorMode(RGB,255);fill(0xFFF4F7FA);noStroke();studioText(STUDIO_FONT_SMALL,true);
    textAlign(i18n.startAlign(),CENTER);float inset=max(10,m.panelPad+2);fitCurrentTextSize(title,STUDIO_FONT_SMALL,8,max(20,w-inset*2),m.cardTitleH-5);
    text(ellipsizeToWidth(title,max(20,w-inset*2)),i18n.rtl?x+w-inset:x+inset,y+m.cardTitleH*.5f);
    popStyle();}
  void button(float x,float y,float w,float h,String label,boolean enabled,boolean selected,boolean primary,boolean quiet){
    label=studioUiDisplayText(label);
    StudioUiMetrics m=studioUiMetrics();pushStyle();rectMode(CORNER);colorMode(RGB,255);
    strokeWeight(1);strokeCap(ROUND);boolean hot=enabled&&studio.ui.pointerX()>=x&&studio.ui.pointerX()<=x+w&&studio.ui.pointerY()>=y&&studio.ui.pointerY()<=y+h;

    int base=quiet?0xFF181E25:(primary?0xFF293440:0xFF202832);
    // Outline is strictly hover feedback. Persistent/toggle state never locks it on.
    stroke(hot?0xFF68A9E8:0xFF35414D);
    // Selected state and the short click pulse are expressed only by the interior.
    fill(enabled?(selected?0xFF28506E:(hot?0xFF293440:base)):0xFF11151A);rect(x,y,w,h,max(6,m.radius*.58f));

    noStroke();fill(enabled?(selected||primary?0xFFF4F7FA:0xFFAAB6C2):0xFF35414D);
    textAlign(CENTER,CENTER);studioText(STUDIO_FONT_BUTTON,true);fitCurrentTextSize(label,STUDIO_FONT_BUTTON,7,max(10,w-10),max(10,h-6));
    text(ellipsizeToWidth(label,max(10,w-10)),x+w/2,y+h/2);popStyle();
  }
  void metric(float x,float y,float w,float h,String label,String value,boolean active){
    label=studioUiDisplayText(label);
    pushStyle();float labelZone=max(13,h*.38f),valueZone=max(15,h*.43f);noStroke();
    fill(0xFF202832);rect(x,y,w,h,max(6,studioUiMetrics().radius*.58f));fill(active?0xFF68A9E8:0xFFAAB6C2);
    ellipse(x+11,y+max(11,min(14,h*.28f)),6,6);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,CENTER);fitCurrentTextSize(label,STUDIO_FONT_TINY,7,max(12,w-28),labelZone);
    text(ellipsizeToWidth(label,max(12,w-28)),x+21,y+max(11,min(14,h*.28f)));
    fill(0xFFF4F7FA);studioText(STUDIO_FONT_SMALL,true);fitCurrentTextSize(value,STUDIO_FONT_SMALL,7,max(12,w-18),valueZone);
    text(ellipsizeToWidth(value,max(12,w-18)),x+9,y+h-max(11,min(15,h*.27f)));textAlign(LEFT,BASELINE);
    popStyle();
  }
  void visualFrame(float x,float y,float w,float h,org.synkinect.studio.api.StudioModulePanel.Visual visual){
    pushStyle();clip(x,y,w,h);noStroke();fill(0xFF0E141A);rect(x,y,w,h);
    if(visual!=null&&visual.valid()){int vw=visual.width(),vh=visual.height();int[] src=visual.argb();PImage img=createImage(vw,vh,ARGB);img.loadPixels();arrayCopy(src,img.pixels);img.updatePixels();
      float dw=vw,dh=vh;if(visual.fit()!=org.synkinect.studio.api.StudioModulePanel.Visual.FIT_PIXEL){float k=visual.fit()==org.synkinect.studio.api.StudioModulePanel.Visual.FIT_COVER?max(w/vw,h/vh):min(w/vw,h/vh);dw=vw*k;dh=vh*k;}
      image(img,x+(w-dw)*.5f,y+(h-dh)*.5f,dw,dh);if(visual.label()!=null&&!visual.label().isEmpty()){fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,TOP);text(studioUiDisplayText(visual.label()),x+8,y+8);}}
    noClip();popStyle();
  }
  void statusFooter(float x,float y,float w,float h,String value,boolean good){value=studioUiDisplayText(value);pushStyle();
    fill(good?0xFF7CC7A0:0xFFE4B86B);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,CENTER);
    fitCurrentTextSize(value,STUDIO_FONT_TINY,7,max(12,w-20),max(10,h-3));text(ellipsizeToWidth(value,max(12,w-20)),x+10,y+h*.5f);
    textAlign(LEFT,BASELINE);popStyle();}
  // Shared presentation for persistent save/export locations. Keeping path
  // information in one renderer prevents modules from inventing different
  // cards, metrics or status strings for the same concept.
  void locationFooter(float x,float y,float w,float h,String label,File directory,boolean writable){
    String path=directory==null?"—":directory.getAbsolutePath();
    String value=studioUiDisplayText(label)+" · "+path;pushStyle();
    fill(writable?0xFF7CC7A0:0xFFE4B86B);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,CENTER);
    fitCurrentTextSize(value,STUDIO_FONT_TINY,7,max(12,w-20),max(10,h-3));
    text(ellipsizeToWidth(value,max(12,w-20)),x+10,y+h*.5f);textAlign(LEFT,BASELINE);popStyle();
  }
}

class StudioNativeDialogs {
  String processOutput(ProcessBuilder builder)throws Exception{
    Process process=builder.start();StringBuilder out=new StringBuilder();
    try(BufferedReader reader=new BufferedReader(new InputStreamReader(process.getInputStream(),java.nio.charset.StandardCharsets.UTF_8))){
      String line;while((line=reader.readLine())!=null){if(out.length()>0)out.append("\n");out.append(line);}
    }
    int code=process.waitFor();String value=out.toString().trim();
    if(code!=0&&value.length()==0)return "";return value;
  }
  String swingDirectoryFallback(String title,File initial)throws Exception{
    final String[] result={""};final Exception[] failure={null};
    Runnable chooserTask=new Runnable(){public void run(){JFrame owner=null;try{
      owner=new JFrame("SynKinect Studio");studioApplyWindowIcon(owner);owner.setUndecorated(true);owner.setAlwaysOnTop(true);owner.setLocationRelativeTo(null);owner.setVisible(true);owner.toFront();owner.requestFocus();
      JFileChooser chooser=initial==null?new JFileChooser():new JFileChooser(initial);
      chooser.setDialogTitle(title==null?"":title);chooser.setFileSelectionMode(JFileChooser.DIRECTORIES_ONLY);chooser.setAcceptAllFileFilterUsed(false);
      int answer=chooser.showOpenDialog(owner);if(answer==JFileChooser.APPROVE_OPTION&&chooser.getSelectedFile()!=null)result[0]=chooser.getSelectedFile().getAbsolutePath();
    }catch(Exception e){failure[0]=e;}finally{if(owner!=null){owner.setAlwaysOnTop(false);owner.dispose();}}}};
    if(SwingUtilities.isEventDispatchThread())chooserTask.run();else SwingUtilities.invokeAndWait(chooserTask);
    if(failure[0]!=null)throw failure[0];return result[0];
  }
  String chooseDirectory(String title,File initial)throws Exception{
    // A null initial directory means that the native desktop owns the starting
    // location (recent folders, This PC, home, mounted volumes, etc.). Recording
    // destinations are persisted separately and never force the chooser to open
    // in Downloads or in an application data folder.
    File start=initial==null?null:initial.getAbsoluteFile();
    if(start!=null&&!start.isDirectory()){File parent=start.getParentFile();start=parent!=null?parent:null;}
    if(studio.services.transportFactory.isWindows()){
      String script=start==null?
        "$s=New-Object -ComObject Shell.Application; $f=$s.BrowseForFolder(0,$env:SYNKINECT_DIALOG_TITLE,0); if($f){$f.Self.Path}":
        "$s=New-Object -ComObject Shell.Application; $f=$s.BrowseForFolder(0,$env:SYNKINECT_DIALOG_TITLE,0,$env:SYNKINECT_DIALOG_INITIAL); if($f){$f.Self.Path}";
      ProcessBuilder pb=new ProcessBuilder("powershell.exe","-NoLogo","-NoProfile","-STA","-Command",script);
      pb.environment().put("SYNKINECT_DIALOG_TITLE",title==null?"":title);
      if(start!=null)pb.environment().put("SYNKINECT_DIALOG_INITIAL",start.getAbsolutePath());
      return processOutput(pb);
    }
    if(studio.services.transportFactory.isLinux()){
      if(studio.systemControl.commandAvailable("zenity")){
        if(start==null)return processOutput(new ProcessBuilder("zenity","--file-selection","--directory","--title="+(title==null?"":title)));
        String base=start.getAbsolutePath()+File.separator;
        return processOutput(new ProcessBuilder("zenity","--file-selection","--directory","--title="+(title==null?"":title),"--filename="+base));
      }
      if(studio.systemControl.commandAvailable("kdialog")){
        if(start==null)return processOutput(new ProcessBuilder("kdialog","--getexistingdirectory","--title",title==null?"":title));
        return processOutput(new ProcessBuilder("kdialog","--getexistingdirectory",start.getAbsolutePath(),"--title",title==null?"":title));
      }
    }
    String os=System.getProperty("os.name","").toLowerCase(Locale.ROOT);
    if(os.contains("mac")){
      String prompt=title==null?"":title.replace("\\","\\\\").replace("\"","\\\"");
      String script=start==null?
        "POSIX path of (choose folder with prompt \""+prompt+"\")":
        "POSIX path of (choose folder with prompt \""+prompt+"\" default location POSIX file \""+start.getAbsolutePath().replace("\\","\\\\").replace("\"","\\\"")+"\")";
      return processOutput(new ProcessBuilder("osascript","-e",script));
    }
    return swingDirectoryFallback(title,start);
  }
  void chooseWritableDirectoryAsync(final String title,final StudioDirectorySelection selection){
    chooseWritableDirectoryAsync(title,null,selection);
  }
  void chooseWritableDirectoryAsync(final String title,final File initial,final StudioDirectorySelection selection){
    studio.services.workers.startLowPriority("Studio-Native-Folder-Dialog",new Runnable(){public void run(){try{
      String chosen=chooseDirectory(title,initial);if(chosen==null||chosen.trim().isEmpty())return;
      File directory=new File(chosen.trim()).getAbsoluteFile();if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("Could not create directory: "+directory.getAbsolutePath());
      if(!directory.canWrite())throw new IOException("Directory is not writable: "+directory.getAbsolutePath());selection.accepted(directory);
    }catch(Exception error){selection.failed(error);}}});
  }
  File chooseSaveFile(final String title,final File suggested)throws Exception{
    final File[] result={null};final Exception[] failure={null};
    Runnable task=new Runnable(){public void run(){Frame owner=null;FileDialog dialog=null;try{
      owner=new Frame("SynKinect Studio");studioApplyWindowIcon(owner);owner.setAlwaysOnTop(true);owner.setLocationRelativeTo(null);owner.setVisible(true);owner.toFront();owner.requestFocus();
      dialog=new FileDialog(owner,title==null?"":title,FileDialog.SAVE);dialog.setAlwaysOnTop(true);
      if(suggested!=null)dialog.setFile(suggested.getName());
      dialog.setVisible(true);String file=dialog.getFile(),dir=dialog.getDirectory();if(file!=null&&dir!=null)result[0]=new File(dir,file).getAbsoluteFile();
    }catch(Exception e){failure[0]=e;}finally{if(dialog!=null)dialog.dispose();if(owner!=null){owner.setAlwaysOnTop(false);owner.dispose();}}}};
    if(java.awt.EventQueue.isDispatchThread())task.run();else java.awt.EventQueue.invokeAndWait(task);
    if(failure[0]!=null)throw failure[0];return result[0];
  }
}

class StudioUiSystem {
  final StudioUiRenderer renderer=new StudioUiRenderer();
  final StudioNativeDialogs nativeDialogs=new StudioNativeDialogs();
  boolean capabilityAvailable(String requirement){
    if(requirement==null||requirement.trim().length()==0)return true;
    KinectDevice d=studio.selectedKinect();
    if(d==null)return false;
    String[] needs=requirement.toLowerCase(Locale.ROOT).split("\\+");
    for(String raw:needs){
      String need=raw.trim();if(need.length()==0)continue;
      // Capability-scoped controls follow the endpoint they actually consume.
      // An unrelated optional endpoint must not disable a working module button.
      if("device".equals(need)){if(!d.readyState())return false;continue;}
      if("control".equals(need)&&!d.controlReady())return false;
      else if("camera".equals(need)&&!d.cameraReady())return false;
      else if("audio".equals(need)&&!d.audioReady())return false;
      else if("audio-control".equals(need)&&!d.audioControlReady())return false;
      else if("virtual-camera".equals(need)&&!d.virtualCameraReady())return false;
      else if("sdk".equals(need)&&!d.sdkReady())return false;
      else if(!"control".equals(need)&&!"camera".equals(need)&&!"audio".equals(need)&&
              !"audio-control".equals(need)&&!"virtual-camera".equals(need)&&!"sdk".equals(need)&&
              !d.hasCapability(need))return false;
    }
    return true;
  }
  StudioUiMetrics metrics(){return studioUiMetrics();}
  // Frontend pointer coordinates. Modules never mix window-space mouse values
  // with content-space controls; the host owns the shell transform.
  float pointerX(){return studio.contentMouseX();}
  float pointerY(){return studio.contentMouseY();}
  float previousPointerX(){return studio.contentPMouseX();}
  float previousPointerY(){return studio.contentPMouseY();}
  StudioUiModuleFrontend module(ModuleI18n i18n){return new StudioUiModuleFrontend(i18n);}
  int actionColumns(float width,int count){return metrics().actionColumns(width,count);
    }
  int metricColumns(float width,int count){return metrics().metricColumns(width,count);
    }
  float actionPanelHeight(float width,int count,boolean footer){return metrics().actionPanelHeight(width,count,footer);
    }
  float metricPanelHeight(float width,int count,boolean footer){return metrics().metricPanelHeight(width,count,footer);
    }
  void layoutButtons(ArrayList<StudioUiButton> buttons,float x,float y,float w,float h){
    if(buttons==null||buttons.isEmpty())return;StudioUiMetrics m=metrics();int count=buttons.size(),cols=m.actionColumns(w,count),rows=(count+cols-1)/cols;
    float g=max(7,m.gap*.62f),cell=max(1,(w-g*(cols-1))/cols),bw=min(m.maxButtonW,cell),slot=max(1,(h-g*(rows-1))/rows),bh=min(m.buttonH,slot),gridH=rows*bh+g*(rows-1),
    top=y+max(0,(h-gridH)*.5f);
    for(int row=0;row<rows;row++){int first=row*cols,rowCount=min(cols,count-first);
      float rowW=rowCount*bw+max(0,rowCount-1)*g,rowX=x+max(0,(w-rowW)*.5f);for(int col=0;col<rowCount;col++)buttons.get(first+col).place(rowX+col*(bw+g),
        top+row*(bh+g),bw,bh);}
  }
  void layoutMetrics(ArrayList<StudioUiMetric> metrics,float x,float y,float w,float h){
    if(metrics==null||metrics.isEmpty())return;StudioUiMetrics m=this.metrics();int count=metrics.size(),cols=m.metricColumns(w,count),rows=(count+cols-1)/cols;
    float g=max(7,m.gap*.62f),cell=max(1,(w-g*(cols-1))/cols),mw=min(m.maxMetricW,cell),slot=max(1,(h-g*(rows-1))/rows),mh=min(m.metricH,slot),gridH=rows*mh+g*(rows-1),
    top=y+max(0,(h-gridH)*.5f);
    for(int row=0;row<rows;row++){int first=row*cols,rowCount=min(cols,count-first);
      float rowW=rowCount*mw+max(0,rowCount-1)*g,rowX=x+max(0,(w-rowW)*.5f);for(int col=0;col<rowCount;col++)metrics.get(first+col).place(rowX+col*(mw+g),
        top+row*(mh+g),mw,mh);}
  }
  StudioUiPanel panel(String title,float x,float y,float w,float h){return new StudioUiPanel(title).place(x,y,w,h);
    }
  void drawMetricGrid(String[] labels,String[] values,boolean[] active,float x,float y,float w,float h){
    ArrayList<StudioUiMetric> items=new ArrayList<StudioUiMetric>();int n=min(labels==null?0:labels.length,values==null?0:values.length);
    for(int i=0;i<n;i++)items.add(new StudioUiMetric().setContent(labels[i],values[i],active!=null&&i<active.length&&active[i]));
    layoutMetrics(items,x,y,w,h);for(StudioUiMetric item:items)item.draw();
  }
  float[] allocateAxis(float length,float wantedGap,float[] preferred,float[] minimum,float[] flex){
    int n=preferred==null?0:preferred.length;float[] result=new float[n+1];if(n==0)return result;
    float minSum=0;for(int i=0;i<n;i++)minSum+=minimum!=null&&i<minimum.length?max(0,minimum[i]):0;
    float gap=n<=1?0:max(0,min(wantedGap,(length-minSum)/max(1,n-1)));if(length<minSum)gap=0;
    float available=max(0,length-gap*max(0,n-1)),need=0,totalFlex=0;
    for(int i=0;i<n;i++){float minSize=minimum!=null&&i<minimum.length?max(0,minimum[i]):0;
      result[i]=max(minSize,preferred[i]);need+=result[i];totalFlex+=flex!=null&&i<flex.length?max(0,flex[i]):0;
      }
    if(need>available){float shrinkable=0;for(int i=0;i<n;i++){float minSize=minimum!=null&&i<minimum.length?max(0,minimum[i]):0;
        shrinkable+=max(0,result[i]-minSize);}float excess=need-available;if(shrinkable>0){for(int i=0;i<n;i++){float minSize=minimum!=null&&i<minimum.length?max(0,
            minimum[i]):0,room=max(0,result[i]-minSize);result[i]-=min(room,excess*(room/shrinkable));
          }}need=0;for(int i=0;i<n;i++)need+=result[i];if(need>available&&need>0){float fit=available/need;
        for(int i=0;i<n;i++)result[i]=max(0,result[i]*fit);}}
    else if(available>need&&totalFlex>0){float extra=available-need;for(int i=0;i<n;i++){float f=flex!=null&&i<flex.length?max(0,flex[i]):0;
        result[i]+=extra*(f/totalFlex);}}
    result[n]=gap;return result;
  }
  StudioUiRect[] vertical(float x,float y,float w,float h,float gap,float[] preferred,float[] minimum,float[] flex){
    int n=preferred==null?0:preferred.length;StudioUiRect[] out=new StudioUiRect[n];
    float[] sizes=allocateAxis(max(0,h),gap,preferred,minimum,flex);float actualGap=n==0?0:sizes[n],cy=y;
    for(int i=0;i<n;i++){out[i]=new StudioUiRect(x,cy,w,max(0,sizes[i]));cy+=sizes[i]+actualGap;
      }return out;
  }
  StudioUiRect[] horizontal(float x,float y,float w,float h,float gap,float[] preferred,float[] minimum,float[] flex){
    int n=preferred==null?0:preferred.length;StudioUiRect[] out=new StudioUiRect[n];
    float[] sizes=allocateAxis(max(0,w),gap,preferred,minimum,flex);float actualGap=n==0?0:sizes[n],cx=x;
    for(int i=0;i<n;i++){out[i]=new StudioUiRect(cx,y,max(0,sizes[i]),h);cx+=sizes[i]+actualGap;
      }return out;
  }
  StudioUiRect panelBody(float x,float y,float w,float h,boolean footer){StudioUiMetrics m=metrics();
    float footerH=footer?m.footerH:0;return new StudioUiRect(x+m.panelPad,y+m.cardTitleH+m.panelPad*.45f,max(1,w-m.panelPad*2),max(1,h-m.cardTitleH-m.panelPad*1.45f-footerH));
    }

}

// Generic host-rendered view for external modules. A module that returns a
// StudioModuleUi snapshot from the Module API needs no Processing drawing code.
class StudioPluginAutoView {
  final StudioPluginContext context;
  final ArrayList<StudioUiButton> actionButtons=new ArrayList<StudioUiButton>();
  final ArrayList<String> actionIds=new ArrayList<String>();
  float scrollY=0,maxScroll=0;
  StudioPluginAutoView(StudioPluginContext context){this.context=context;}
  boolean draw(org.synkinect.studio.api.StudioModuleUi model,String moduleTitle){
    if(model==null)return false;actionButtons.clear();actionIds.clear();StudioUiMetrics m=studio.ui.metrics();
    studio.ui.renderer.header(studio.i18n,moduleTitle);float x=m.margin,top=m.headerH+m.gap,w=max(80,width-2*m.margin),bottom=studio.contentHeight-m.margin;

    java.util.List<org.synkinect.studio.api.StudioModulePanel> panels=model.panels();
    if(panels==null||panels.isEmpty()){scrollY=0;maxScroll=0;drawEmptyPanel(x,top,w,max(80,bottom-top),model.status());
      return true;}
    int count=panels.size(),cols=m.panelColumns(w,count);float colGap=m.gap,colW=max(1,(w-colGap*(cols-1))/cols),gridX=x;
    float[] cy=new float[cols],px=new float[count],py=new float[count],ph=new float[count];int[] panelCol=new int[count];
    Arrays.fill(cy,top);
    for(int i=0;i<count;i++){org.synkinect.studio.api.StudioModulePanel panel=panels.get(i);
      int col=0;for(int c=1;c<cols;c++)if(cy[c]<cy[col])col=c;panelCol[i]=col;px[i]=gridX+col*(colW+colGap);
      py[i]=cy[col];ph[i]=preferredPanelHeight(panel,colW,m);cy[col]+=ph[i]+m.gap;
      }
    float contentBottom=top;for(float value:cy)contentBottom=max(contentBottom,value-m.gap);
    // When a declarative module fits without scrolling, spend the otherwise
    // unused lower area on the most information-rich panel of each column.
    // Text/visual content wins over metrics, and metrics win over controls.
    if(contentBottom<=bottom){
      for(int col=0;col<cols;col++){
        int primary=-1;float score=-1,sum=0;int inColumn=0;
        for(int i=0;i<count;i++)if(panelCol[i]==col){sum+=ph[i];inColumn++;float candidate=panelExpansionScore(panels.get(i));
          if(candidate>score){score=candidate;primary=i;}}
        if(primary<0)continue;float extra=max(0,(bottom-top)-sum-max(0,inColumn-1)*m.gap);ph[primary]+=extra;
        float yy=top;for(int i=0;i<count;i++)if(panelCol[i]==col){py[i]=yy;yy+=ph[i]+m.gap;}
      }
      contentBottom=bottom;
    }
    maxScroll=max(0,contentBottom-bottom);scrollY=constrain(scrollY,0,maxScroll);

    clip(0,top,width,max(1,bottom-top));
    for(int i=0;i<count;i++){float sy=py[i]-scrollY;if(sy+ph[i]<top||sy>bottom)continue;
      drawPanel(panels.get(i),px[i],sy,colW,ph[i],m);}
    noClip();
    if(maxScroll>0){float track=max(36,bottom-top),thumb=max(28,track*(track/(track+maxScroll))),thumbY=top+(track-thumb)*(scrollY/maxScroll);
      pushStyle();noStroke();fill(0xFF35414D);rect(width-max(4,m.margin*.35f),top,max(2,m.margin*.18f),track,2);
      fill(0xFF68A9E8);rect(width-max(4,m.margin*.35f),thumbY,max(2,m.margin*.18f),thumb,2);
      popStyle();}
    return true;
  }
  void scrollBy(float amount){if(maxScroll<=0)return;scrollY=constrain(scrollY+amount*max(24,studio.ui.metrics().buttonH*.8f),0,maxScroll);
    }
  float panelExpansionScore(org.synkinect.studio.api.StudioModulePanel panel){if(panel==null)return 0;int kind=panel.kind();
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_VISUAL)return 400;
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_TABLE)return 350;
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_LOG)return 340;
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_FORM)return 260;
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_TEXT)return 300+(panel.text()==null?0:min(100,panel.text().length()));
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_METRICS)return 200+panel.metrics().size();
    return 100+panel.actions().size();
  }
  float preferredPanelHeight(org.synkinect.studio.api.StudioModulePanel panel,float w,StudioUiMetrics m){int kind=panel.kind();
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_VISUAL)return max(220,m.cardTitleH+240*m.scale);
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_PROGRESS)return m.cardTitleH+84*m.scale;
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_TABLE)return m.cardTitleH+max(120,min(300,34*(panel.table()==null?1:panel.table().rows().size()+1)))*m.scale;
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_FORM)return m.cardTitleH+max(100,(panel.fields().size()*42+52))*m.scale;
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_LOG)return m.cardTitleH+220*m.scale;
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_SPACER)return max(8,panel.preferredHeight()*m.scale);
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_METRICS)return m.metricPanelHeight(w,panel.metrics().size(),false);
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_ACTIONS)return m.actionPanelHeight(w,panel.actions().size(),panel.text()!=null&&!panel.text().isEmpty());
    return max(86,m.cardTitleH+72*m.scale);}
  void drawEmptyPanel(float x,float y,float w,float h,String status){studio.ui.renderer.panel(x,y,w,h);
    if(status!=null&&!status.isEmpty()){status=studioUiDisplayText(status);fill(0xFFAAB6C2);studioText(STUDIO_FONT_BODY,false);
      textAlign(CENTER,CENTER);fitCurrentTextSize(status,STUDIO_FONT_BODY,8,w-24,h-20);
      text(ellipsizeToWidth(status,w-24),x+w/2,y+h/2);textAlign(LEFT,BASELINE);}}
  void drawPanel(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h,StudioUiMetrics m){studio.ui.renderer.panel(x,y,w,h);
    studio.ui.renderer.panelTitle(studio.i18n,x,y,w,p.title());float ix=x+m.panelPad,iy=y+m.cardTitleH+m.panelPad*.45f,iw=max(1,w-m.panelPad*2),ih=max(1,
      h-m.cardTitleH-m.panelPad*1.45f);if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_VISUAL)drawVisual(p,ix,iy,iw,ih);
    else if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_PROGRESS)drawProgress(p,ix,iy,iw,ih);
    else if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_TABLE)drawTable(p,ix,iy,iw,ih);
    else if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_FORM)drawForm(p,ix,iy,iw,ih);
    else if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_LOG)drawLog(p,ix,iy,iw,ih);
    else if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_SPACER){}
    else if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_METRICS)drawMetrics(p,ix,iy,iw,ih);
    else if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_ACTIONS)drawActions(p,ix,iy,iw,ih);
    else drawText(p,ix,iy,iw,ih);}
  void drawVisual(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h){studio.ui.renderer.visualFrame(x,y,w,h,p.visual());}
  void drawProgress(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h){
    org.synkinect.studio.api.StudioModulePanel.Progress q=p.progress();if(q==null)return;fill(0xFFDCE5EC);studioText(STUDIO_FONT_BODY,false);textAlign(LEFT,TOP);text(studioUiDisplayText(q.label()),x,y);
    float by=y+30*studioUiScale(),bh=9*studioUiScale();noStroke();fill(0xFF202A33);rect(x,by,w,bh,4);
    float v=q.indeterminate()?((millis64()%1200)/1200.0f):q.value();fill(0xFF58C7F3);rect(x,by,w*constrain(v,0,1),bh,4);
    fill(0xFF8797A5);studioText(STUDIO_FONT_SMALL,false);text(studioUiDisplayText(q.detail()),x,by+18*studioUiScale());
  }
  void drawTable(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h){
    org.synkinect.studio.api.StudioModulePanel.Table t=p.table();if(t==null||t.columns().isEmpty())return;int cols=t.columns().size();float cw=w/max(1,cols),rh=28*studioUiScale();studioText(STUDIO_FONT_SMALL,false);textAlign(LEFT,CENTER);
    noStroke();fill(0xFF202A33);rect(x,y,w,rh);fill(0xFFDCE5EC);for(int c=0;c<cols;c++)text(studioUiDisplayText(t.columns().get(c)),x+c*cw+8*studioUiScale(),y+rh*.5f);
    int maxRows=min(t.rows().size(),max(0,floor((h-rh)/rh)));for(int r=0;r<maxRows;r++){float yy=y+rh*(r+1);fill((r&1)==0?0xFF151C23:0xFF182129);rect(x,yy,w,rh);fill(0xFFAAB6C2);java.util.List<String> row=t.rows().get(r);for(int c=0;c<min(cols,row.size());c++)text(studioUiDisplayText(row.get(c)),x+c*cw+8*studioUiScale(),yy+rh*.5f);}
  }
  void drawForm(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h){
    float row=38*studioUiScale(),yy=y;studioText(STUDIO_FONT_SMALL,false);for(org.synkinect.studio.api.StudioModulePanel.Field f:p.fields()){fill(0xFFAAB6C2);textAlign(LEFT,CENTER);text(studioUiDisplayText(f.label()),x,yy+row*.5f);float bx=x+w*.48f,bw=w*.52f;noStroke();fill(0xFF202A33);rect(bx,yy,bw,row-6*studioUiScale(),5);fill(0xFFDCE5EC);text(studioUiDisplayText(f.value()),bx+9*studioUiScale(),yy+(row-6*studioUiScale())*.5f);yy+=row;if(yy>y+h-row)break;}
    if(!p.actions().isEmpty())drawActions(p,x,max(y,yy),w,max(1,y+h-max(y,yy)));
  }
  void drawLog(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h){
    float lh=20*studioUiScale();int maxLines=max(1,floor(h/lh)),start=max(0,p.logLines().size()-maxLines);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,TOP);int row=0;
    for(int i=start;i<p.logLines().size();i++,row++){org.synkinect.studio.api.StudioModulePanel.LogLine l=p.logLines().get(i);int col=l.level()==3?0xFFE77878:(l.level()==2?0xFFE9B85E:(l.level()==1?0xFF65C995:0xFFAAB6C2));fill(col);text(studioUiDisplayText(l.text()),x,y+row*lh);}
  }
  void drawMetrics(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h){ArrayList<StudioUiMetric> items=new ArrayList<StudioUiMetric>();
    for(org.synkinect.studio.api.StudioModuleMetric metric:p.metrics())items.add(new StudioUiMetric().setContent(metric.label(),metric.value(),metric.active()));
    studio.ui.layoutMetrics(items,x,y,w,h);for(StudioUiMetric item:items)item.draw();
    }
  void drawActions(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h){float footer=0;
    if(p.text()!=null&&!p.text().isEmpty())footer=studio.ui.metrics().footerH;for(org.synkinect.studio.api.StudioModuleAction action:p.actions()){StudioUiButton b=new StudioUiButton().configure(action.label(),
        action.enabled(),action.selected(),action.primary(),action.quiet());actionButtons.add(b);
      actionIds.add(action.id());}int first=max(0,actionButtons.size()-p.actions().size());
    ArrayList<StudioUiButton> current=new ArrayList<StudioUiButton>();for(int i=first;i<actionButtons.size();i++)current.add(actionButtons.get(i));
    studio.ui.layoutButtons(current,x,y,w,max(1,h-footer));for(StudioUiButton b:current)b.draw();
    if(footer>0)studio.ui.renderer.statusFooter(x,y+h-footer,w,footer,p.text(),true);
    }
  void drawText(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h){fill(0xFFAAB6C2);
    studioText(STUDIO_FONT_BODY,false);textAlign(LEFT,TOP);text(studioUiDisplayText(p.text()==null?"":p.text()),x,y,w,h);
    textAlign(LEFT,BASELINE);}
  String actionAt(float mx,float my){for(int i=0;i<actionButtons.size()&&i<actionIds.size();i++)if(actionButtons.get(i).enabled&&actionButtons.get(i).hit(mx,
      my))return actionIds.get(i);return null;}
}

class StudioSwingTheme {
  final java.awt.Color window=new java.awt.Color(0x11,0x15,0x1A);
  final java.awt.Color panel=new java.awt.Color(0x18,0x1E,0x25);
  final java.awt.Color button=new java.awt.Color(0x20,0x28,0x32);
  final java.awt.Color buttonPrimary=new java.awt.Color(0x29,0x34,0x40);
  final java.awt.Color disabled=new java.awt.Color(0x11,0x15,0x1A);
  final java.awt.Color border=new java.awt.Color(0x35,0x41,0x4D);
  final java.awt.Color hover=new java.awt.Color(0x68,0xA9,0xE8);
  final java.awt.Color text=new java.awt.Color(0xF4,0xF7,0xFA);
  final java.awt.Color muted=new java.awt.Color(0xAA,0xB6,0xC2);
  final java.awt.Color disabledText=new java.awt.Color(0x35,0x41,0x4D);
  final java.awt.Color accent=new java.awt.Color(0x68,0xA9,0xE8);
}

class StudioSwingButton extends JButton {
  private static final long serialVersionUID=1L;
  final StudioSwingTheme theme;final boolean primary;boolean hovered=false;
  StudioSwingButton(String text,StudioSwingTheme theme,boolean primary){super(text);this.theme=theme;this.primary=primary;
    setFocusable(false);setOpaque(false);setContentAreaFilled(false);setBorderPainted(false);setRolloverEnabled(true);setCursor(java.awt.Cursor.getPredefinedCursor(java.awt.Cursor.HAND_CURSOR));
    setPreferredSize(new java.awt.Dimension(168,40));setMinimumSize(new java.awt.Dimension(110,36));
    addMouseListener(new java.awt.event.MouseAdapter(){public void mouseEntered(java.awt.event.MouseEvent e){hovered=true;repaint();}public void mouseExited(java.awt.event.MouseEvent e){hovered=false;repaint();}});
  }
  protected void paintComponent(java.awt.Graphics g){java.awt.Graphics2D g2=(java.awt.Graphics2D)g.create();
    g2.setRenderingHint(java.awt.RenderingHints.KEY_ANTIALIASING,java.awt.RenderingHints.VALUE_ANTIALIAS_ON);
    int w=getWidth(),h=getHeight(),arc=Math.max(8,Math.min(14,h/3));boolean enabled=isEnabled();
    java.awt.Color fill=enabled?(hovered?theme.buttonPrimary:(primary?theme.buttonPrimary:theme.button)):theme.disabled;
    g2.setColor(fill);g2.fillRoundRect(1,1,Math.max(0,w-3),Math.max(0,h-3),arc,arc);
    g2.setColor(enabled&&hovered?theme.hover:theme.border);g2.drawRoundRect(1,1,Math.max(0,w-3),Math.max(0,h-3),arc,arc);
    g2.setColor(enabled?theme.text:theme.disabledText);java.awt.Font f=getFont().deriveFont(java.awt.Font.BOLD,Math.max(12f,getFont().getSize2D()));g2.setFont(f);
    java.awt.FontMetrics fm=g2.getFontMetrics();String label=getText()==null?"":getText();int tw=fm.stringWidth(label),tx=Math.max(8,(w-tw)/2),ty=(h-fm.getHeight())/2+fm.getAscent();g2.drawString(label,tx,ty);g2.dispose();
  }
}
