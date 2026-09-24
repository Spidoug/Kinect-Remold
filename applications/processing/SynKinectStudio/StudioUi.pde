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

    // The workspace follows the viewport at every supported size. The minimum
    // window keeps a 1320 px content area and larger windows preserve the same
    // proportional side margins.
    margin=max(20*scale,cw/24.0f);
    gap=constrain(cw/72.0f,18*scale,48*scale);
    radius=constrain(13*scale,10,18);
    headerH=constrain(66*scale,54,86);
    cardTitleH=constrain(42*scale,36,56);
    buttonH=constrain(40*scale,34,52);
    buttonMinH=constrain(34*scale,30,44);
    metricH=constrain(48*scale,42,64);
    footerH=constrain(30*scale,26,40);
    panelPad=constrain(13*scale,10,22);
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

class StudioUiRect {
  float x,y,w,h;
  StudioUiRect(){}
  StudioUiRect(float x,float y,float w,float h){set(x,y,w,h);}
  StudioUiRect set(float x,float y,float w,float h){this.x=x;this.y=y;this.w=max(0,w);
    this.h=max(0,h);return this;}
  boolean hit(float px,float py){return px>=x&&px<=x+w&&py>=y&&py<=y+h;}
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
  StudioUiButton(){}
  StudioUiButton(String label){this.label=label==null?"":label;}
  StudioUiButton configure(String label,boolean enabled,boolean selected,boolean primary,boolean quiet){this.label=label==null?"":label;
    this.enabled=enabled;this.selected=selected;this.primary=primary;this.quiet=quiet;
    return this;}
  StudioUiButton place(float x,float y,float w,float h){set(x,y,w,h);return this;
    }
  boolean hit(float px,float py){return enabled&&super.hit(px,py);}
  void draw(){studio.ui.renderer.button(x,y,w,h,label,enabled,selected,primary,quiet);
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
  void panelTitle(ModuleI18n i18n,float x,float y,float w,String title){StudioUiMetrics m=studioUiMetrics();
    pushStyle();colorMode(RGB,255);fill(0xFFF4F7FA);noStroke();studioText(STUDIO_FONT_SMALL,true);
    textAlign(i18n.startAlign(),CENTER);float inset=max(10,m.panelPad+2);fitCurrentTextSize(title,STUDIO_FONT_SMALL,8,max(20,w-inset*2),m.cardTitleH-5);
    text(ellipsizeToWidth(title,max(20,w-inset*2)),i18n.rtl?x+w-inset:x+inset,y+m.cardTitleH*.5f);
    popStyle();}
  void button(float x,float y,float w,float h,String label,boolean enabled,boolean selected,boolean primary,boolean quiet){
    StudioUiMetrics m=studioUiMetrics();pushStyle();rectMode(CORNER);colorMode(RGB,255);
    strokeWeight(1);strokeCap(ROUND);boolean hot=enabled&&studio.contentMouseX()>=x&&studio.contentMouseX()<=x+w&&studio.contentMouseY()>=y&&studio.contentMouseY()<=y+h;
    
    int base=quiet?0xFF181E25:(primary?0xFF293440:0xFF202832);stroke((hot||selected)?0xFF68A9E8:0xFF35414D);
    fill(enabled?(selected?0xFF203A52:(hot?0xFF293440:base)):0xFF11151A);rect(x,y,w,h,max(6,m.radius*.58f));
    
    noStroke();fill(enabled?(selected||primary?0xFFF4F7FA:0xFFAAB6C2):0xFF35414D);
    textAlign(CENTER,CENTER);studioText(STUDIO_FONT_BUTTON,true);fitCurrentTextSize(label,STUDIO_FONT_BUTTON,7,max(10,w-10),max(10,h-6));
    text(ellipsizeToWidth(label,max(10,w-10)),x+w/2,y+h/2);popStyle();
  }
  void metric(float x,float y,float w,float h,String label,String value,boolean active){
    pushStyle();float labelZone=max(13,h*.38f),valueZone=max(15,h*.43f);noStroke();
    fill(0xFF202832);rect(x,y,w,h,max(6,studioUiMetrics().radius*.58f));fill(active?0xFF68A9E8:0xFFAAB6C2);
    ellipse(x+11,y+max(11,min(14,h*.28f)),6,6);
    fill(0xFFAAB6C2);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,CENTER);fitCurrentTextSize(label,STUDIO_FONT_TINY,7,max(12,w-28),labelZone);
    text(ellipsizeToWidth(label,max(12,w-28)),x+21,y+max(11,min(14,h*.28f)));
    fill(0xFFF4F7FA);studioText(STUDIO_FONT_SMALL,true);fitCurrentTextSize(value,STUDIO_FONT_SMALL,7,max(12,w-18),valueZone);
    text(ellipsizeToWidth(value,max(12,w-18)),x+9,y+h-max(11,min(15,h*.27f)));textAlign(LEFT,BASELINE);
    popStyle();
  }
  void statusFooter(float x,float y,float w,float h,String value,boolean good){pushStyle();
    fill(good?0xFF7CC7A0:0xFFE4B86B);studioText(STUDIO_FONT_TINY,false);textAlign(LEFT,CENTER);
    fitCurrentTextSize(value,STUDIO_FONT_TINY,7,max(12,w-20),max(10,h-3));text(ellipsizeToWidth(value,max(12,w-20)),x+10,y+h*.5f);
    textAlign(LEFT,BASELINE);popStyle();}
}

class StudioUiSystem {
  final StudioUiRenderer renderer=new StudioUiRenderer();
  StudioUiMetrics metrics(){return studioUiMetrics();}
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
    float[] cy=new float[cols],px=new float[count],py=new float[count],ph=new float[count];
    Arrays.fill(cy,top);
    for(int i=0;i<count;i++){org.synkinect.studio.api.StudioModulePanel panel=panels.get(i);
      int col=0;for(int c=1;c<cols;c++)if(cy[c]<cy[col])col=c;px[i]=gridX+col*(colW+colGap);
      py[i]=cy[col];ph[i]=preferredPanelHeight(panel,colW,m);cy[col]+=ph[i]+m.gap;
      }
    float contentBottom=top;for(float value:cy)contentBottom=max(contentBottom,value-m.gap);
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
  float preferredPanelHeight(org.synkinect.studio.api.StudioModulePanel panel,float w,StudioUiMetrics m){int kind=panel.kind();
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_METRICS)return m.metricPanelHeight(w,panel.metrics().size(),false);
    if(kind==org.synkinect.studio.api.StudioModulePanel.KIND_ACTIONS)return m.actionPanelHeight(w,panel.actions().size(),panel.text()!=null&&!panel.text().isEmpty());
    return max(86,m.cardTitleH+72*m.scale);}
  void drawEmptyPanel(float x,float y,float w,float h,String status){studio.ui.renderer.panel(x,y,w,h);
    if(status!=null&&!status.isEmpty()){fill(0xFFAAB6C2);studioText(STUDIO_FONT_BODY,false);
      textAlign(CENTER,CENTER);fitCurrentTextSize(status,STUDIO_FONT_BODY,8,w-24,h-20);
      text(ellipsizeToWidth(status,w-24),x+w/2,y+h/2);textAlign(LEFT,BASELINE);}}
  void drawPanel(org.synkinect.studio.api.StudioModulePanel p,float x,float y,float w,float h,StudioUiMetrics m){studio.ui.renderer.panel(x,y,w,h);
    studio.ui.renderer.panelTitle(studio.i18n,x,y,w,p.title());float ix=x+m.panelPad,iy=y+m.cardTitleH+m.panelPad*.45f,iw=max(1,w-m.panelPad*2),ih=max(1,
      h-m.cardTitleH-m.panelPad*1.45f);if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_METRICS)drawMetrics(p,ix,iy,iw,ih);
    else if(p.kind()==org.synkinect.studio.api.StudioModulePanel.KIND_ACTIONS)drawActions(p,ix,iy,iw,ih);
    else drawText(p,ix,iy,iw,ih);}
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
    studioText(STUDIO_FONT_BODY,false);textAlign(LEFT,TOP);text(p.text()==null?"":p.text(),x,y,w,h);
    textAlign(LEFT,BASELINE);}
  String actionAt(float mx,float my){for(int i=0;i<actionButtons.size()&&i<actionIds.size();i++)if(actionButtons.get(i).enabled&&actionButtons.get(i).hit(mx,
      my))return actionIds.get(i);return null;}
}
