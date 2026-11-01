// ===== SynKinect Studio / 3D Scanner / UI.pde =====
class ScannerUI {
  final int ACTION_START=0, ACTION_RESET=1, ACTION_MESH=2, ACTION_STL=3, ACTION_OBJ=4, ACTION_PLY=5;
  final int ACTION_CLEAN=6, ACTION_SMOOTH=7, ACTION_CENTER=8, ACTION_UNDO=9, ACTION_HQ=10, ACTION_SURFACE_MODE=11, ACTION_MODE=12, ACTION_RGB_OVERLAY=13;

  final int BUTTON_NORMAL=0, BUTTON_PRIMARY=1, BUTTON_QUIET=2;

 final ArrayList<UiButton> buttons = new ArrayList<UiButton>();
 final ArrayList<UiActionGroup> groups = new ArrayList<UiActionGroup>();
  float previewX, previewY, previewW, previewH;

  ScannerUI() {
    UiActionGroup capture = group("group.capture");
    capture.add(button("button.mode", ACTION_MODE, BUTTON_NORMAL));
    capture.add(button("button.start", ACTION_START, BUTTON_PRIMARY));
    capture.add(button("button.reset", ACTION_RESET, BUTTON_QUIET));
    capture.add(button("button.surface_mode", ACTION_SURFACE_MODE, BUTTON_NORMAL));
    capture.add(button("button.rgb_overlay", ACTION_RGB_OVERLAY, BUTTON_NORMAL));

    UiActionGroup meshGroup = group("group.mesh");
    meshGroup.add(button("button.mesh", ACTION_MESH, BUTTON_PRIMARY));
    meshGroup.add(button("button.refine", ACTION_HQ, BUTTON_NORMAL));

    UiActionGroup editGroup = group("group.edit");
    editGroup.add(button("button.clean", ACTION_CLEAN, BUTTON_NORMAL));
    editGroup.add(button("button.smooth", ACTION_SMOOTH, BUTTON_NORMAL));
    editGroup.add(button("button.center", ACTION_CENTER, BUTTON_NORMAL));
    editGroup.add(button("button.undo", ACTION_UNDO, BUTTON_QUIET));

    UiActionGroup exportGroup = group("group.export");
    exportGroup.add(button("button.stl", ACTION_STL, BUTTON_NORMAL));
    exportGroup.add(button("button.obj", ACTION_OBJ, BUTTON_NORMAL));
    exportGroup.add(button("button.ply", ACTION_PLY, BUTTON_NORMAL));

  }

  UiActionGroup group(String key) { UiActionGroup g=new UiActionGroup(key); groups.add(g);
     return g; }
  UiButton button(String key,int action,int style) { UiButton b=new UiButton(key,action,style);
     buttons.add(b); return b; }

  float statusHeight(){return studio.ui.metricPanelHeight(max(80,width-2*studioUiMargin()),8,true);
    }

  void draw() {
    drawHeader();
    ScannerTheme theme=scannerState().theme;
    float m=studioUiMargin(),gap=studioUiGap(),w=max(80,width-2*m);
    float statusY=studioUiHeaderHeight()+gap,statusH=statusHeight(),toolbarH=toolbarHeight(w);

    float available=max(1,studio.contentHeight-statusY-m);
    StudioUiRect[] bands=studio.ui.vertical(m,statusY,w,available,gap,new float[]{statusH,180,toolbarH},new float[]{statusH,90,toolbarH},new float[]{0,
        1,0});
    StudioUiRect statusBand=bands[0],bodyBand=bands[1],toolbarBand=bands[2];
    drawSystemStatus(statusBand.x,statusBand.y,statusBand.w,statusBand.h);
    float bodyY=bodyBand.y,bodyH=bodyBand.h,toolbarY=toolbarBand.y;toolbarH=toolbarBand.h;

    // RGB Camera and Metric Depth are diagnostics, not Scanner work surfaces.
    // Give the complete body area to the 3D reconstruction.
    drawReconstructionCard(m,bodyY,w,bodyH);
    drawToolbar(m,toolbarY,w,toolbarH);
  }

  void drawSystemStatus(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,scannerState().i18n.tr("panel.system"));
    KinectSource source=scannerState().source;
    boolean rgb=source!=null&&source.colorConnected,depth=source!=null&&source.depthConnected;
    DepthCorrectionProfile depthProfile=scannerState().calibration==null?null:scannerState().calibration.depthCorrection;
    boolean savedCalibration=depthProfile!=null&&depthProfile.calibrated;

    String[] labels={scannerState().i18n.tr("label.rgbShort"),scannerState().i18n.tr("label.depthShort"),scannerState().i18n.tr("chip.profile"),scannerState().i18n.tr("label.target"),scannerState().i18n.tr("label.icp"),
      scannerState().i18n.tr(scannerFusionMode()?"label.trajectory":"label.turn"),scannerState().i18n.tr("label.keyframes"),scannerState().i18n.tr("label.progress"),scannerState().i18n.tr("label.quality")};

    String[] values={source==null?"0":String.valueOf(source.colorFrames),source==null?"0":String.valueOf(source.depthFrames),
      scannerState().i18n.tr(savedCalibration?"metric.calibrated":"calwindow.none"),targetValue(),icpValue(),
      (scannerFusionMode()?nf(fusionTrajectorySpanM(),1,2)+" m":nf(scannerState().scanCoverage==null?0:scannerState().scanCoverage.sweepDeg,1,1)+"°"),String.valueOf(scannerState().hqArchive==null?0:scannerState().hqArchive.size()),
      nf(constrain(scannerState().uiProgress,0,1)*100,1,0)+"%",nf(constrain(scannerState().uiScanQuality,0,1)*100,1,0)+"%"};
    boolean[] active={rgb,depth,savedCalibration,!Float.isNaN(scannerState().uiTargetDepthM),scannerState().uiTrackingGood,
      (scannerFusionMode()?scannerState().fusionTrajectory.size()>1:scannerState().scanCoverage!=null&&scannerState().scanCoverage.sweepDeg>0.1f),scannerState().hqArchive!=null&&scannerState().hqArchive.size()>0,
      scannerState().scanActive,scannerState().uiScanQuality>=0.55f};
    StudioUiMetrics ui=studio.ui.metrics();float footer=ui.footerH,ix=x+ui.panelPad,iy=y+ui.cardTitleH+ui.panelPad*.45f,iw=max(1,w-ui.panelPad*2),ih=max(1,
      h-ui.cardTitleH-ui.panelPad*1.45f-footer);
    studio.ui.drawMetricGrid(labels,values,active,ix,iy,iw,ih);
    String sourceStatus=source==null?"":source.displayError(),message=sourceStatus.length()>0?sourceStatus:scannerState().status;
    if(message==null||message.length()==0)message=scannerState().i18n.tr("status.ready");

    float footerY=y+h-footer*.5f;fill(sourceStatus.length()>0?scannerState().theme.WARN:scannerState().theme.TEXT_MUTED);
    noStroke();ellipse(x+15,footerY,6,6);fill(scannerState().theme.TEXT_MUTED);uiText(scannerState().theme.FONT_TINY,false);
    textAlign(LEFT,CENTER);fitCurrentTextSize(message,scannerState().theme.FONT_TINY,8,w-42,footer-4);
    text(ellipsizeToWidth(message,w-42),x+25,footerY);textAlign(LEFT,BASELINE);
  }

  void drawHeader() {
    studio.ui.renderer.header(scannerState().i18n,scannerState().i18n.tr("app.title"));

  }

  void drawRgbCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,scannerState().i18n.tr("panel.rgb"));
    float px=x+10, py=y+studioUiCardTitleHeight(), pw=max(1,w-20), ph=max(1,h-studioUiCardTitleHeight()-42);

    previewSurface(px,py,pw,ph);
    if(scannerState().colorPreview!=null) imageFit(scannerState().colorPreview,px,py,pw,ph);
     else drawWaiting(px,py,pw,ph,scannerState().i18n.tr("waiting.rgb"));
    boolean rgb=scannerState().source!=null&&scannerState().source.colorConnected;

    drawCompactFooter(x,y,w,h,scannerState().i18n.tr("chip.rgb"),rgb,rgbFooterValue());

  }

  String rgbFooterValue(){
    String frames=scannerState().source==null?"0":String.valueOf(scannerState().source.colorFrames);

    if(scannerState().source!=null)frames+="  ·  pairs "+scannerState().source.queuedRgbdPairs()+"/"+scannerState().config.rgbdQueueFrames;

    if(Float.isNaN(scannerState().latestRgbDepthSkewMs))return frames;
    String value=frames+"  ·  "+scannerState().i18n.tr("chip.sync")+" "+nf(scannerState().latestRgbDepthSkewMs,1,1)+" ms";

    if(scannerState().rgbRegistration!=null&&(abs(scannerState().rgbRegistration.autoOffsetX)>0.05f||abs(scannerState().rgbRegistration.autoOffsetY)>0.05f))
      value+="  ·  Δxy "+nf(scannerState().rgbRegistration.autoOffsetX,1,1)+","+nf(scannerState().rgbRegistration.autoOffsetY,1,1);

    return value;
  }

  void drawDepthCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,scannerState().i18n.tr("panel.depth"));
    float footerH=64;
    float px=x+10,py=y+studioUiCardTitleHeight(),pw=max(1,w-20),ph=max(1,h-studioUiCardTitleHeight()-footerH-8);

    previewSurface(px,py,pw,ph);
    if(scannerState().depthPreview!=null) imageFit(scannerState().depthPreview,px,py,pw,ph);
     else drawWaiting(px,py,pw,ph,scannerState().i18n.tr("waiting.depth"));

    boolean depthOk=scannerState().source!=null&&scannerState().source.depthConnected;

    boolean metric=scannerState().latestDepth!=null&&scannerState().latestDepth.deviceCalibrated;

    float fy=py+ph+9,chipGap=6,chipW=max(24,(w-20-chipGap*2)/3.0f);
    miniState(x+10,fy,chipW,scannerState().i18n.tr("chip.depth"),depthOk);
    miniState(x+10+chipW+chipGap,fy,chipW,scannerState().i18n.tr("chip.metric"),metric);

    boolean profile=scannerState().calibration!=null&&scannerState().calibration.hasDepthCorrection();

    miniState(x+10+(chipW+chipGap)*2,fy,chipW,scannerState().i18n.tr("chip.profile"),profile);


    String value="—";
    if(scannerState().latestDepthDiagnostics!=null&&scannerState().latestDepthDiagnostics.plausiblePixels>0){
      value=nf(scannerState().latestDepthDiagnostics.medianMm/1000.0f,1,2)+" m  ·  "+nf(scannerState().latestDepthDiagnostics.plausibleRatio*100.0f,1,1)+"%";

      if(scannerState().source!=null)value+="  ·  q "+scannerState().source.queuedRgbdPairs()+"/"+scannerState().config.rgbdQueueFrames+" → "+reconstructionQueuedFrames()+"/"+scannerState().config.reconstructionQueueFrames;

    }
    fill(scannerState().theme.TEXT_MUTED); uiText(scannerState().theme.FONT_SMALL,false);
     textAlign(scannerState().i18n.startAlign(),CENTER);
    fitCurrentTextSize(value,scannerState().theme.FONT_SMALL,7,w-20,24);text(ellipsizeToWidth(value,w-20),scannerState().i18n.rtl?x+w-10:x+10,y+h-16);
     textAlign(LEFT,BASELINE);
  }

  void drawCompactFooter(float x,float y,float w,float h,String label,boolean active,String value) {
    float cy=y+h-20;
    noStroke(); fill(active?scannerState().theme.ACCENT:scannerState().theme.BORDER);
     ellipse(x+16,cy,7,7);
    fill(scannerState().theme.TEXT_MUTED); uiText(scannerState().theme.FONT_SMALL,false);
     textAlign(LEFT,CENTER);String footer=label+"  "+value;fitCurrentTextSize(footer,scannerState().theme.FONT_SMALL,7,w-41,24);
    text(ellipsizeToWidth(footer,w-41),x+27,cy); textAlign(LEFT,BASELINE);
  }

  void miniState(float x,float y,float w,String label,boolean active) {
    noStroke(); fill(scannerState().theme.SURFACE_ALT); rect(x,y,w,24,7);
    fill(active?scannerState().theme.ACCENT:scannerState().theme.TEXT_MUTED); ellipse(x+11,y+12,6,6);

    fill(scannerState().theme.TEXT_MUTED); uiText(scannerState().theme.FONT_TINY,false);
     textAlign(LEFT,CENTER);fitCurrentTextSize(label,scannerState().theme.FONT_TINY,7,w-26,20);
    text(ellipsizeToWidth(label,w-26),x+20,y+12); textAlign(LEFT,BASELINE);
  }

  void drawReconstructionCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,scannerState().i18n.tr("panel.reconstruction"));

    previewX=x+10; previewY=y+studioUiCardTitleHeight(); previewW=max(1,w-20); previewH=max(1,h-studioUiCardTitleHeight()-10);

    previewSurface(previewX,previewY,previewW,previewH);
    draw3DPreview(previewX,previewY,previewW,previewH);
    drawPreviewOverlay(previewX,previewY,previewW,previewH);
  }

  void drawPreviewOverlay(float x,float y,float w,float h) {
    boolean complete=scannerState().uiScanComplete;
    String scanState=complete?scannerState().i18n.tr("scan.complete"):(scannerState().scanActive?(scannerState().scanPaused?scannerState().i18n.tr("scan.paused"):scannerState().i18n.tr("scan.active")):scannerState().i18n.tr("scan.idle"));

    boolean offlineRunning=scannerOfflineReconstructionRunning();
    if(offlineRunning){
      int pct=round(constrain(scannerState().hqProgress,0,1)*100);
      scanState=scannerHqRunning()?scannerState().i18n.format("button.refine.progress",pct):scannerState().i18n.format("button.mesh.progress",pct);
    }
    drawChip(x+w-132,y+10,122,28,scanState,offlineRunning||(scannerState().scanActive&&!scannerState().scanPaused),scannerState().theme.ACCENT);

    fill(scannerState().theme.TEXT_MUTED); uiText(scannerState().theme.FONT_TINY,false);
     textAlign(LEFT,CENTER);String orbitHint=scannerState().i18n.tr("hint.orbit.short");
    fitCurrentTextSize(orbitHint,scannerState().theme.FONT_TINY,7,max(40,w-160),24);
    text(ellipsizeToWidth(orbitHint,max(40,w-160)),x+12,y+24); textAlign(LEFT,BASELINE);
    if(offlineRunning)drawHqProgressPanel(x,y,w,h);
    else drawCoverageStrip(x+12,y+h-18,max(40,w-24),7);

  }

  // Offline reconstruction progress inside the viewport: stage, percentage,
  // remaining time and a determinate bar, in the Scanner chip/panel style.
  void drawHqProgressPanel(float x,float y,float w,float h){
    ScannerTheme theme=scannerState().theme;HqProgressTracker t=scannerState().hqTracker;
    float pw=min(w-24,max(260,w*.46f)),ph=64,px=x+(w-pw)/2,py=y+h-ph-12;
    float p=t.displayed();
    pushStyle();noStroke();fill(theme.SURFACE);rect(px,py,pw,ph,12);
    fill(theme.TEXT);uiText(theme.FONT_SMALL,true);textAlign(LEFT,CENTER);
    String stage=t.stageLabel(),pct=round(constrain(scannerState().hqProgress,0,1)*100)+"%",eta=t.remainingLabel();
    fitCurrentTextSize(stage,theme.FONT_SMALL,8,pw*.58f,20);text(ellipsizeToWidth(stage,pw*.58f),px+14,py+17);
    fill(theme.TEXT_MUTED);uiText(theme.FONT_TINY,false);textAlign(RIGHT,CENTER);
    String right=eta.length()>0?pct+"  ·  "+eta:pct;fitCurrentTextSize(right,theme.FONT_TINY,7,pw*.40f,20);text(ellipsizeToWidth(right,pw*.40f),px+pw-14,py+17);
    float bx=px+14,by=py+33,bw=pw-28,bh=8;fill(theme.SURFACE_ALT);rect(bx,by,bw,bh,4);
    fill(theme.ACCENT);rect(bx,by,max(bh,bw*p),bh,4);
    // Stage boundaries as subtle ticks so the operator sees where the run is.
    stroke(theme.BORDER);strokeWeight(1);for(int i=2;i<t.stageStart.length;i++){float tx=bx+bw*t.stageStart[i];line(tx,by-2,tx,by+bh+2);}
    noStroke();fill(theme.TEXT_MUTED);uiText(theme.FONT_TINY,false);textAlign(LEFT,CENTER);
    String hint=scannerState().i18n.tr("hq.cancel_hint");fitCurrentTextSize(hint,theme.FONT_TINY,7,bw,14);text(ellipsizeToWidth(hint,bw),bx,py+ph-12);
    popStyle();textAlign(LEFT,BASELINE);
  }


  void drawCoverageStrip(float x,float y,float w,float h){
    if(scannerFusionMode())return;
    ScanCoverageTracker coverage=scannerState().scanCoverage;
    if(coverage==null||coverage.covered==null||coverage.covered.length==0)return;
    int bins=coverage.covered.length;float gap=1.0f,segment=max(1,(w-gap*(bins-1))/bins);noStroke();
    for(int i=0;i<bins;i++){fill(coverage.covered[i]?scannerState().theme.ACCENT:scannerState().theme.BORDER);rect(x+i*(segment+gap),y,segment,h,2);}
  }


  float fusionTrajectorySpanM(){if(scannerState().fusionTrajectory.size()<2)return 0;PVector first=scannerState().fusionTrajectory.peekFirst();float span=0;for(PVector p:scannerState().fusionTrajectory)span=max(span,PVector.dist(first,p));return span;}

  String targetValue() {
    float depth=scannerState().uiTargetDepthM;
    if(Float.isNaN(depth)) return "—";
    String value=nf(depth,1,2)+" m";
    if(scannerState().scanActive&&scannerState().depthTarget!=null&&scannerState().depthTarget.locked())value+=" · "+scannerState().i18n.tr("target.locked");
    return value;
  }

  String icpValue() {
    float rms=scannerState().uiIcpRmsMm;
    if(!scannerState().uiTrackingGood||Float.isNaN(rms)) return "—";
    return nf(rms,1,1)+" mm";
  }

  void metricTile(float x,float y,float w,float h,String label,String value){metricTile(x,y,w,h,label,value,true);
    }
  void metricTile(float x,float y,float w,float h,String label,String value,boolean active) {studio.ui.renderer.metric(x,y,w,h,label,value,active);
    }


  float actionPanelPreferredHeight(UiActionGroup group,float panelW){return studio.ui.actionPanelHeight(panelW,max(1,group.items.size()),false);
    }
  float toolbarHeight(float totalW){
    float gap=studioUiGap();boolean fourColumns=totalW>=1120;int columns=fourColumns?4:2;int rows=(groups.size()+columns-1)/columns;
    float panelW=max(1,(totalW-gap*(columns-1))/columns),rowH=0;
    for(UiActionGroup group:groups)rowH=max(rowH,actionPanelPreferredHeight(group,panelW));
    return rows*rowH+max(0,rows-1)*gap;
  }
  void drawToolbar(float x,float y,float w,float h){
    float gap=studioUiGap();int columns=w>=1120?4:2;int rows=(groups.size()+columns-1)/columns;
    float rowH=max(1,(h-gap*max(0,rows-1))/rows),panelW=max(1,(w-gap*(columns-1))/columns);
    for(int i=0;i<groups.size();i++){
      int row=i/columns,col=i%columns;float px=x+col*(panelW+gap),py=y+row*(rowH+gap);
      drawActionPanel(groups.get(i),px,py,panelW,rowH);
    }
  }
  void drawActionPanel(UiActionGroup group,float x,float y,float w,float h){card(x,y,w,h);
    studio.ui.module(scannerState().i18n).panelTitle(x,y,w,scannerState().i18n.tr(group.labelKey));
    StudioUiMetrics ui=studio.ui.metrics();ArrayList<StudioUiButton> items=new ArrayList<StudioUiButton>();
    for(UiButton item:group.items){item.configure(item.label(),item.enabled(),false,item.style==scannerState().ui.BUTTON_PRIMARY,item.style==scannerState().ui.BUTTON_QUIET);
      items.add(item);}studio.ui.layoutButtons(items,x+ui.panelPad,y+ui.cardTitleH+ui.panelPad*.45f,max(1,w-ui.panelPad*2),max(1,h-ui.cardTitleH-ui.panelPad*1.45f));
    for(StudioUiButton item:items)item.draw();}


  void card(float x,float y,float w,float h) { studio.ui.module(scannerState().i18n).panel("",x,y,w,h);
     }
  void cardTitle(float x,float y,float w,String title) { studio.ui.module(scannerState().i18n).panelTitle(x,y,w,title);
     }
  void previewSurface(float x,float y,float w,float h) { noStroke(); fill(scannerState().theme.PREVIEW);
     rect(x,y,w,h,9); }
  void drawWaiting(float x,float y,float w,float h,String message) { fill(scannerState().theme.TEXT_MUTED);
     textAlign(CENTER,CENTER); uiText(scannerState().theme.FONT_BODY,false);fitCurrentTextSize(message,scannerState().theme.FONT_BODY,8,w-18,h-12);
    text(ellipsizeToWidth(message,w-18),x+w/2,y+h/2); textAlign(LEFT,BASELINE); }
  void imageFit(PImage img,float x,float y,float w,float h) {
    if(img==null||img.width<=0||img.height<=0)return;
    float s=min(w/img.width,h/img.height),dw=img.width*s,dh=img.height*s,dx=x+(w-dw)/2,dy=y+(h-dh)/2;
    pushMatrix();translate(dx+dw,dy);scale(-1,1);image(img,0,0,dw,dh);popMatrix();

  }

  void draw3DPreview(float x,float y,float w,float h) {
    Mesh3D renderMesh=scannerState().mesh;
    if((renderMesh==null||renderMesh.triangleCount()==0)&&scannerState().liveMesh!=null&&scannerState().liveMesh.triangleCount()>0)
      renderMesh=scannerState().liveMesh;
    PointCloud ref=null;

    // While scanning (including manual pause), the viewport remains an
    // ICP-registered point reconstruction. A mesh is shown only after an
    // explicit mesh command. After full-turn auto-pause, keep the point model
    // visible until such a mesh exists.
    boolean explicitMesh=scannerState().meshViewActive&&renderMesh!=null&&renderMesh.triangleCount()>0;
    if(!explicitMesh)renderMesh=null;
    // An explicit Build Mesh / Refine HQ result always owns the viewport. Capture
    // may remain paused/active in the background, but it must never force the UI
    // back to the point cloud after a mesh has been requested.
    boolean pointMode=!explicitMesh&&(scannerState().showLiveDetectionCloud||scannerState().scanActive||scannerState().uiPreviewCloud!=null);
    if(pointMode){ref=scannerState().uiPreviewCloud;renderMesh=null;}

    if(scannerState().viewport3D==null)scannerState().viewport3D=new Scanner3DViewport();
    scannerState().viewport3D.draw(x,y,w,h,renderMesh,ref);
  }

  void drawChip(float x,float y,float w,float h,String label,boolean active,int tint) {
    noStroke(); fill(active?scannerState().theme.SURFACE_RAISED:scannerState().theme.SURFACE_ALT);
     rect(x,y,w,h,h/2);
    fill(active?tint:scannerState().theme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(scannerState().theme.FONT_TINY,true);
    fitCurrentTextSize(label,scannerState().theme.FONT_TINY,7,w-10,h-6);text(ellipsizeToWidth(label,w-10),x+w/2,y+h/2);
     textAlign(LEFT,BASELINE);
  }

  String ellipsize(String s,int limit) { if(s==null)return ""; return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…";
     }
  boolean isOver3D(float mx,float my){ return mx>=previewX&&mx<=previewX+previewW&&my>=previewY&&my<=previewY+previewH;
     }
  boolean handleMousePressed(float mx,float my){
    for(UiButton b:buttons)if(b.hit(mx,my)){
      if(b.enabled())b.fire();else scannerActionBlockedStatus(b.action);
      return true;
    }
    return false;
  }
}

class Scanner3DViewport {
  PGraphics buffer=null;
  int bufferWidth=0,bufferHeight=0;
  Mesh3D cachedMesh=null;
  final ArrayList<PShape> meshChunks=new ArrayList<PShape>();
  int meshCursor=0;
  Object framedGeometry=null;
  int framedKind=0;
  long framedRevision=-1;
  final StableViewportFilter sceneFit=new StableViewportFilter();
  final StableViewportFilter frameFit=new StableViewportFilter();
  final int meshChunkTriangles=10000;
  boolean captureFramingLocked=false,lastCaptureActive=false;
  float captureScale=Float.NaN,captureCenterX=0,captureCenterY=0;
  boolean idleDetectionFramingLocked=false;
  float idleScale=Float.NaN,idleCenterX=0,idleCenterY=0;
  PVector idleBoxCenter=null;float idleBoxSide=Float.NaN;

  void dispose(){buffer=null;bufferWidth=0;bufferHeight=0;cachedMesh=null;framedGeometry=null;framedKind=0;framedRevision=-1;meshChunks.clear();
    meshCursor=0;sceneFit.reset();frameFit.reset();captureFramingLocked=false;lastCaptureActive=false;captureScale=Float.NaN;idleDetectionFramingLocked=false;idleScale=Float.NaN;idleBoxCenter=null;idleBoxSide=Float.NaN;}

  void ensureBuffer(int w,int h){
    w=max(64,w);h=max(64,h);
    if(buffer!=null&&bufferWidth==w&&bufferHeight==h)return;
    buffer=createGraphics(w,h,P3D);
    bufferWidth=w;bufferHeight=h;
    cachedMesh=null;meshChunks.clear();meshCursor=0;
  }

  void resetMeshCache(Mesh3D mesh){
    if(cachedMesh==mesh)return;
    cachedMesh=mesh;meshChunks.clear();meshCursor=0;
  }

  void buildNextMeshChunk(Mesh3D mesh){
    if(buffer==null||mesh==null||meshCursor>=mesh.triangles.size())return;
    int end=min(mesh.triangles.size(),meshCursor+meshChunkTriangles);
    PShape chunk=buffer.createShape();
    chunk.beginShape(TRIANGLES);chunk.noStroke();
    boolean textured=scannerState().rgbOverlayEnabled&&scannerState().rgbFinalized;
    for(int i=meshCursor;i<end;i++){
      Triangle3D tri=mesh.triangles.get(i);
      chunk.normal(tri.n.x,tri.n.y,tri.n.z);
      chunk.fill(textured?mesh.renderColor(tri.ca,scannerState().theme.ACCENT):scannerState().theme.ACCENT);chunk.vertex(tri.a.x,tri.a.y,tri.a.z);

      chunk.fill(textured?mesh.renderColor(tri.cb,scannerState().theme.ACCENT):scannerState().theme.ACCENT);chunk.vertex(tri.b.x,tri.b.y,tri.b.z);

      chunk.fill(textured?mesh.renderColor(tri.cc,scannerState().theme.ACCENT):scannerState().theme.ACCENT);chunk.vertex(tri.c.x,tri.c.y,tri.c.z);

    }
    chunk.endShape();meshChunks.add(chunk);meshCursor=end;
  }

  void draw(float x,float y,float w,float h,Mesh3D renderMesh,PointCloud ref){
    int bw=max(64,round(w));int bh=max(64,round(h));
    ensureBuffer(bw,bh);resetMeshCache(renderMesh);

    PVector rawFocusCenter=new PVector(0,0,0.75f);
    float rawSceneRadius=0.20f;
    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      rawFocusCenter=renderMesh.boundsCenter();rawSceneRadius=max(0.05f,renderMesh.boundsRadius());
    }else if(ref!=null&&ref.points!=null&&!ref.points.isEmpty()){
      float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;
      float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;
      for(PVector point:ref.points){
        if(point==null)continue;
        minX=min(minX,point.x);minY=min(minY,point.y);minZ=min(minZ,point.z);
        maxX=max(maxX,point.x);maxY=max(maxY,point.y);maxZ=max(maxZ,point.z);
      }
      if(minX<Float.POSITIVE_INFINITY){
        rawFocusCenter.set((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
        rawSceneRadius=max(0.05f,dist(minX,minY,minZ,maxX,maxY,maxZ)*0.5f);
      }
    }

    int geometryKind=(renderMesh!=null&&renderMesh.triangleCount()>0)?2:(ref!=null?1:0);
    Object geometryIdentity=(geometryKind==2)?renderMesh:ref;
    // PointCloud is rebuilt every frame, so object identity must NOT be treated
    // as a new scene. Reset framing only when the viewport actually changes
    // mode (live cloud <-> reconstructed mesh).
    long revision=scannerState().previewAutoFitRevision;
    if(geometryKind!=0&&(geometryKind!=framedKind||revision!=framedRevision)){
      framedKind=geometryKind;framedGeometry=geometryIdentity;framedRevision=revision;sceneFit.reset();frameFit.reset();idleDetectionFramingLocked=false;idleScale=Float.NaN;idleBoxCenter=null;idleBoxSide=Float.NaN;
      if(!scannerState().previewUserAdjusted){scannerState().previewPanX=0;scannerState().previewPanY=0;scannerState().previewZoom=1.0f;}
    }

    AppConfig viewCfg=scannerState().config;
    boolean captureNow=scannerState().scanActive||scannerState().scanPaused;
    boolean idleDetectionLockEligible=!captureNow&&renderMesh==null&&ref!=null&&ref.points!=null&&ref.points.size()>=20;
    if(captureNow&&!lastCaptureActive){
      // Keep the same metric camera used by the stable preview when Scan begins.
      // Tracking and reconstruction are independent from this presentation state.
      float retainedScale=idleDetectionFramingLocked?idleScale:frameFit.scale;
      if(!Float.isFinite(retainedScale)||retainedScale<=0)
        retainedScale=min(bw*0.94f,bh*0.90f);
      captureScale=retainedScale;
      captureCenterX=idleDetectionFramingLocked?idleCenterX:frameFit.centerX;
      captureCenterY=idleDetectionFramingLocked?idleCenterY:frameFit.centerY;
      captureFramingLocked=true;
      frameFit.scale=captureScale;
      frameFit.centerX=captureCenterX;frameFit.centerY=captureCenterY;
    }else if(!captureNow&&lastCaptureActive){
      captureFramingLocked=false;captureScale=Float.NaN;frameFit.reset();sceneFit.reset();idleDetectionFramingLocked=false;idleScale=Float.NaN;idleBoxCenter=null;idleBoxSide=Float.NaN;
    }
    // Before Scan, lock the preview on its first usable cloud. Target-detection
    // fluctuations must never drive repeated camera refocusing.
    if(captureNow){
      if(!captureFramingLocked){
        sceneFit.updateScene(rawFocusCenter,rawSceneRadius,viewCfg.previewAutoFitDeadband,
          viewCfg.previewAutoFitZoomOutResponse,viewCfg.previewAutoFitZoomInResponse,
          viewCfg.previewAutoFitCenterResponse,viewCfg.previewAutoFitShrinkDelayFrames);
      }
    }else if(!idleDetectionFramingLocked&&idleDetectionLockEligible){
      sceneFit.updateScene(rawFocusCenter,rawSceneRadius,viewCfg.previewAutoFitDeadband,
        viewCfg.previewAutoFitZoomOutResponse,viewCfg.previewAutoFitZoomInResponse,
        viewCfg.previewAutoFitCenterResponse,viewCfg.previewAutoFitShrinkDelayFrames);
    }
    PVector focusCenter=sceneFit.focus==null?rawFocusCenter.copy():sceneFit.focus.copy();float sceneRadius=max(.05f,Float.isNaN(sceneFit.radius)?rawSceneRadius:sceneFit.radius);

    float meshDisplayOffsetY=0.0f;
    float floorY=focusCenter.y+sceneRadius*1.05f;
    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      float meshBottomY=meshMaxY(renderMesh);
      if(Float.isFinite(meshBottomY))meshDisplayOffsetY=floorY-meshBottomY;
    }

    // Capture keeps the preview framing for both Turntable and Fusion.
    // Avoid projecting and sorting points once the camera is locked.
    ScannerViewFit fit;float targetViewScale;
    if(captureNow&&captureFramingLocked){
      fit=new ScannerViewFit();fit.centerX=captureCenterX;fit.centerY=captureCenterY;
      targetViewScale=captureScale;
    }else{
      fit=scannerViewFit(renderMesh,ref,focusCenter,scannerState().previewYaw,scannerState().previewPitch,meshDisplayOffsetY);
      targetViewScale=min((bw*.90f)/max(.04f,fit.spanX),(bh*.86f)/max(.04f,fit.spanY));
      if(!Float.isFinite(targetViewScale)||targetViewScale<=0)targetViewScale=max(1.0f,min(bw,bh)*0.40f/max(sceneRadius,0.02f));
    }
    // Before scanning, use a fixed one-meter-wide metric viewing region.
    // Fit that region into the available viewport instead of scaling it from
    // the fluctuating number or extent of detected depth points.
    if(!captureNow&&renderMesh==null){
      float meterSpan=1.0f;
      targetViewScale=min(bw*0.94f,bh*0.90f)/meterSpan;
    }
    targetViewScale=constrain(targetViewScale,20.0f,max(80.0f,min(bw,bh)*8.0f));
    lastCaptureActive=captureNow;

    if(!captureNow){
      // A preview cloud is framed once, then the camera remains fixed until
      // capture starts or the user resets the viewport.
      if(idleDetectionLockEligible){
        if(!idleDetectionFramingLocked){
          // Lock the metric preview framing on the first usable point cloud.
          frameFit.scale=targetViewScale;
          frameFit.centerX=fit.centerX;frameFit.centerY=fit.centerY;
          idleScale=frameFit.scale;idleCenterX=frameFit.centerX;idleCenterY=frameFit.centerY;idleDetectionFramingLocked=true;
        }else{frameFit.scale=idleScale;frameFit.centerX=idleCenterX;frameFit.centerY=idleCenterY;}
      }else if(renderMesh!=null){
        frameFit.updateFrame(targetViewScale,fit.centerX,fit.centerY,viewCfg.previewAutoFitDeadband,
          viewCfg.previewAutoFitZoomOutResponse,viewCfg.previewAutoFitZoomInResponse,
          viewCfg.previewAutoFitCenterResponse,viewCfg.previewAutoFitShrinkDelayFrames);
      }else if(Float.isNaN(frameFit.scale)){
        frameFit.scale=min(bw*0.94f,bh*0.90f);
        frameFit.centerX=0;frameFit.centerY=0;
      }
    }else if(!captureFramingLocked){
      // Freeze the presentation camera on the first coherent capture view. Both
      // modes keep this zoom/center locked; reconstruction coordinates are entirely
      // independent from viewport framing.
      captureScale=targetViewScale;captureCenterX=fit.centerX;captureCenterY=fit.centerY;
      captureFramingLocked=true;frameFit.scale=captureScale;frameFit.centerX=captureCenterX;frameFit.centerY=captureCenterY;
    }
    // Capture presentation is now immutable in both modes. Fusion world growth
    // changes TSDF geometry, never the user's camera/zoom. This prevents the
    // viewport from visually masking drift or making stable geometry appear to
    // breathe while the sensor moves.
    if(captureNow&&captureFramingLocked){frameFit.scale=captureScale;frameFit.centerX=captureCenterX;frameFit.centerY=captureCenterY;}
    float viewScale=frameFit.scale*scannerState().previewZoom;
    float worldStroke=1.0f/max(1.0f,viewScale);
    float axisLen=max(sceneRadius*1.05f,0.08f);
    float panWorldX=scannerState().previewPanX/max(1.0f,viewScale);
    float panWorldY=scannerState().previewPanY/max(1.0f,viewScale);

    buffer.beginDraw();
    buffer.background(scannerState().theme.PREVIEW);
    buffer.hint(ENABLE_DEPTH_TEST);
    buffer.ortho(-bw*0.5f,bw*0.5f,-bh*0.5f,bh*0.5f,-10000,10000);
    buffer.translate(bw*0.5f-frameFit.centerX*viewScale,bh*0.5f-frameFit.centerY*viewScale,0);
    buffer.ambientLight(92,92,100);
    buffer.directionalLight(224,224,224,-0.4f,0.6f,-1.0f);
    buffer.directionalLight(112,126,150,0.5f,-0.3f,-0.2f);
    buffer.scale(viewScale);
    buffer.translate(panWorldX,panWorldY,0);
    buffer.rotateX(scannerState().previewPitch);
    // Kinect points extend along +Z. The half turn presents the cloud from the
    // sensor-facing side and keeps left/right consistent with the RGB preview.
    buffer.rotateY(PI+scannerState().previewYaw);
    // The half-turn gives a front view; the X reflection removes the mirrored
    // left/right presentation. Reconstruction coordinates remain unchanged.
    buffer.scale(-1,1,1);
    buffer.translate(-focusCenter.x,-focusCenter.y,-focusCenter.z);

    PVector floorCenter=new PVector(focusCenter.x,floorY,focusCenter.z);
    if(scannerFusionMode())drawClassicGrid(floorCenter,sceneRadius,worldStroke);else drawTurntableBase(floorCenter,sceneRadius,worldStroke);
    drawClassicAxes(focusCenter,axisLen,worldStroke);
    if(scannerFusionMode())drawFusionTrajectory(worldStroke);

    buffer.stroke(scannerState().theme.GRID);buffer.strokeWeight(worldStroke);buffer.noFill();
    PVector detectionCenter=null;float detectionSide=Float.NaN;
    if(scannerFusionMode()&&scannerState().fusionCaptureTargetWorld!=null){
      // During capture there is intentionally no TSDF. Show the foreground target
      // locked from depth instead of a reconstruction volume that does not exist yet.
      detectionCenter=scannerState().fusionCaptureTargetWorld.copy();
      detectionSide=scannerState().fusionCaptureTargetSideM;
    }else if(scannerState().boundingBox!=null){
      detectionCenter=scannerState().boundingBox.displayCenter();
      detectionSide=scannerState().boundingBox.displayCubeSide();
    }
    if(!captureNow&&renderMesh==null&&idleDetectionFramingLocked){
      if(idleBoxCenter==null&&scannerState().boundingBox!=null&&scannerState().boundingBox.locked
          &&detectionCenter!=null&&Float.isFinite(detectionSide)&&detectionSide>0){
        idleBoxCenter=detectionCenter.copy();idleBoxSide=detectionSide;
      }
      if(idleBoxCenter!=null){detectionCenter=idleBoxCenter;detectionSide=idleBoxSide;}
    }
    buffer.pushMatrix();
    if(detectionCenter!=null&&Float.isFinite(detectionSide)&&detectionSide>0){
      buffer.translate(detectionCenter.x,detectionCenter.y,detectionCenter.z);
      buffer.box(detectionSide,detectionSide,detectionSide);
    }else{
      buffer.translate(focusCenter.x,focusCenter.y,focusCenter.z);
      buffer.box(sceneRadius*2.1f,sceneRadius*2.1f,sceneRadius*2.1f);
    }
    buffer.popMatrix();

    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      if(meshCursor<renderMesh.triangles.size())buildNextMeshChunk(renderMesh);
      buffer.pushMatrix();buffer.translate(0,meshDisplayOffsetY,0);
      for(PShape chunk:meshChunks)buffer.shape(chunk);
      buffer.popMatrix();
    }else if(ref!=null&&ref.points!=null){
      // Point clouds can be shown with a uniform accent color or with the captured
      // RGB overlay so both Turntable and Fusion present the same option.
      boolean colorized=scannerState().rgbOverlayEnabled;
      buffer.strokeWeight(worldStroke*2.0f);
      buffer.beginShape(POINTS);
      for(int i=0;i<ref.points.size();i++){
        PVector point=ref.points.get(i);
        if(point==null)continue;
        int colorValue=colorized?ref.colorAt(i):0;
        if(colorValue!=0)buffer.stroke((colorValue>>16)&255,(colorValue>>8)&255,colorValue&255,constrain(round(ref.confidenceAt(i)*255.0f),96,255));
        else buffer.stroke(scannerState().theme.ACCENT);
        buffer.vertex(point.x,point.y,point.z);
      }
      buffer.endShape();
    }

    buffer.noLights();buffer.hint(DISABLE_DEPTH_TEST);buffer.endDraw();
    image(buffer,x,y,w,h);
  }

  class ScannerViewFit {float centerX=0,centerY=0,spanX=.4f,spanY=.4f;int samples=0;}
  PVector scannerViewProject(PVector point,PVector center,float yaw,float pitch){
    float x=-(point.x-center.x),y=point.y-center.y,z=point.z-center.z;float a=PI+yaw,cy=cos(a),sy=sin(a);
    float x1=x*cy+z*sy,z1=-x*sy+z*cy,cp=cos(pitch),sp=sin(pitch),y1=y*cp-z1*sp;return new PVector(x1,y1,z1);
  }
  ScannerViewFit scannerViewFit(Mesh3D mesh,PointCloud ref,PVector center,float yaw,float pitch,float meshOffsetY){
    ScannerViewFit fit=new ScannerViewFit();
    int capacity=0;
    if(mesh!=null&&mesh.triangleCount()>0)capacity=min(10500,max(3,mesh.triangles.size()*3));
    else if(ref!=null&&ref.points!=null)capacity=min(5000,max(3,ref.points.size()));
    if(capacity<3)return fit;
    float[] xs=new float[capacity],ys=new float[capacity];int n=0;
    if(mesh!=null&&mesh.triangleCount()>0){
      int stride=max(1,mesh.triangles.size()/3500);
      for(int i=0;i<mesh.triangles.size()&&n<capacity;i+=stride){
        Triangle3D t=mesh.triangles.get(i);PVector[] vv={t.a,t.b,t.c};
        for(PVector v:vv){if(n>=capacity)break;PVector shifted=new PVector(v.x,v.y+meshOffsetY,v.z);PVector q=scannerViewProject(shifted,center,yaw,pitch);xs[n]=q.x;ys[n]=q.y;n++;}
      }
    }else if(ref!=null&&ref.points!=null&&!ref.points.isEmpty()){
      int stride=max(1,ref.points.size()/5000);
      for(int i=0;i<ref.points.size()&&n<capacity;i+=stride){PVector v=ref.points.get(i);if(v==null)continue;PVector q=scannerViewProject(v,center,yaw,pitch);xs[n]=q.x;ys[n]=q.y;n++;}
    }
    if(n<3)return fit;Arrays.sort(xs,0,n);Arrays.sort(ys,0,n);int lo=constrain(round((n-1)*.01f),0,n-1),hi=constrain(round((n-1)*.99f),lo,n-1);
    float minX=xs[lo],maxX=xs[hi],minY=ys[lo],maxY=ys[hi];fit.centerX=(minX+maxX)*.5f;fit.centerY=(minY+maxY)*.5f;fit.spanX=max(.04f,maxX-minX);fit.spanY=max(.04f,maxY-minY);fit.samples=n;return fit;
  }


  float meshMaxY(Mesh3D mesh){
    if(mesh==null||mesh.triangleCount()==0)return Float.NaN;
    float maxY=Float.NEGATIVE_INFINITY;
    for(Triangle3D t:mesh.triangles){
      maxY=max(maxY,max(t.a.y,max(t.b.y,t.c.y)));
    }
    return maxY;
  }


  void drawTurntableBase(PVector center,float radius,float strokeWorld){
    float r=max(radius*1.28f,0.12f);buffer.noFill();buffer.stroke(scannerState().theme.BORDER);buffer.strokeWeight(strokeWorld);
    buffer.pushMatrix();buffer.translate(center.x,center.y,center.z);buffer.rotateX(HALF_PI);buffer.ellipse(0,0,r*2,r*2);buffer.ellipse(0,0,r*.10f,r*.10f);
    buffer.line(-r,0,r,0);buffer.line(0,-r,0,r);buffer.popMatrix();
  }
  void drawFusionTrajectory(float strokeWorld){
    if(scannerState().fusionTrajectory.size()<2)return;buffer.noFill();buffer.stroke(scannerState().theme.FUSION_TRAJECTORY);buffer.strokeWeight(strokeWorld*2.2f);
    buffer.beginShape();for(PVector p:scannerState().fusionTrajectory)buffer.vertex(p.x,p.y,p.z);buffer.endShape();
  }

  void drawClassicGrid(PVector center,float radius,float strokeWorld){
    float size=max(radius*1.6f,0.18f);int lines=10;float step=(size*2.0f)/lines;
    buffer.stroke(scannerState().theme.BORDER);buffer.strokeWeight(strokeWorld);
    for(int i=0;i<=lines;i++){
      float d=-size+i*step;
      buffer.line(center.x-size,center.y,center.z+d,center.x+size,center.y,center.z+d);
      buffer.line(center.x+d,center.y,center.z-size,center.x+d,center.y,center.z+size);
    }
  }

  void drawClassicAxes(PVector center,float axisLen,float strokeWorld){
    buffer.strokeWeight(strokeWorld*1.7f);
    buffer.stroke(220,92,92);buffer.line(center.x,center.y,center.z,center.x+axisLen,center.y,center.z);
    buffer.stroke(92,220,140);buffer.line(center.x,center.y,center.z,center.x,center.y-axisLen,center.z);
    buffer.stroke(92,150,232);buffer.line(center.x,center.y,center.z,center.x,center.y,center.z+axisLen);
  }

}
class UiActionGroup {
 final String labelKey; final ArrayList<UiButton> items=new ArrayList<UiButton>();

  UiActionGroup(String key){labelKey=key;}
  void add(UiButton button){items.add(button);}
}

class UiButton extends StudioUiButton {
  final String labelKey; final int action,style;
  UiButton(String labelKey,int action,int style){this.labelKey=labelKey;this.action=action;
    this.style=style;}
  void setBounds(float x,float y,float w,float h){place(x,y,w,h);}
  String label(){
    if(action==scannerState().ui.ACTION_MODE)return scannerState().i18n.tr(scannerModeKey());
    if(action==scannerState().ui.ACTION_START&&scannerState().scanActive)return scannerState().i18n.tr(scannerState().scanPaused?"button.resume":"button.pause");
    if(action==scannerState().ui.ACTION_HQ&&scannerHqRunning()){
      String label=scannerState().i18n.format("button.refine.progress",round(constrain(scannerState().hqProgress,0,1)*100));
      String eta=scannerState().hqTracker.remainingLabel();return eta.length()>0?label+" · "+eta:label;
    }
    if(action==scannerState().ui.ACTION_HQ&&scannerHasMesh())return scannerState().i18n.tr("button.refine_mesh");
    if(action==scannerState().ui.ACTION_MESH&&scannerBuildRunning()){
      if(scannerState().hqTracker.active())return scannerState().i18n.format("button.mesh.progress",round(constrain(scannerState().hqProgress,0,1)*100));
      return scannerState().i18n.tr("button.mesh.running");
    }
    if(action==scannerState().ui.ACTION_SURFACE_MODE)return scannerState().i18n.tr(scannerState().solidScanMode?"mode.solid":"mode.texture");
    if(action==scannerState().ui.ACTION_RGB_OVERLAY)return scannerState().i18n.tr(scannerState().rgbOverlayEnabled?"overlay.on":"overlay.off");
    if(action==scannerState().ui.ACTION_HQ&&scannerState().config!=null&&scannerState().hqArchive!=null){
      int have=scannerState().hqArchive.size(),need=scannerState().config.hqMinimumKeyframes;
      if(have<need)return scannerState().i18n.tr(labelKey)+" · "+have+"/"+need;
    }
    return scannerState().i18n.tr(labelKey);
  }
  boolean enabled(){return scannerActionAllowed(action);}
  void draw(){
    boolean en=enabled();
    boolean selected=(action==scannerState().ui.ACTION_START&&scannerState().scanActive)
      ||(action==scannerState().ui.ACTION_HQ&&scannerHqRunning())
      ||(action==scannerState().ui.ACTION_SURFACE_MODE&&scannerState().solidScanMode)
      ||(action==scannerState().ui.ACTION_RGB_OVERLAY&&scannerState().rgbOverlayEnabled)
      ||(action==scannerState().ui.ACTION_MODE);

    configure(label(),en,selected,style==scannerState().ui.BUTTON_PRIMARY,style==scannerState().ui.BUTTON_QUIET);
    if(action==scannerState().ui.ACTION_HQ&&scannerHqRunning()){
      studio.ui.renderer.progressButton(x,y,w,h,label,scannerState().hqTracker.displayed(),false);
      return;
    }
    if(action==scannerState().ui.ACTION_MESH&&scannerBuildRunning()){
      boolean determinate=scannerState().hqTracker.active();
      studio.ui.renderer.progressButton(x,y,w,h,label,determinate?scannerState().hqTracker.displayed():0,!determinate);return;
    }
    super.draw();
  }
  void fire(){dispatchUiAction(action);}
}
