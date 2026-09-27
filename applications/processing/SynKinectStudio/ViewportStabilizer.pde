// Shared, UI-only auto-framing filter used by 3D viewports.
// It never feeds display transforms back into tracking/reconstruction.
class StableViewportFilter {
  float scale=Float.NaN,centerX=0,centerY=0,radius=Float.NaN;
  PVector focus=null;
  int shrinkFrames=0;

  void reset(){scale=Float.NaN;centerX=centerY=0;radius=Float.NaN;focus=null;shrinkFrames=0;}

  void updateFrame(float targetScale,float targetX,float targetY,float deadband,float zoomOutResponse,float zoomInResponse,float centerResponse,int shrinkDelay){
    updateFrame(targetScale,targetX,targetY,deadband,zoomOutResponse,zoomOutResponse,.0f,zoomInResponse,centerResponse,shrinkDelay);
  }

  void updateFrame(float targetScale,float targetX,float targetY,float deadband,float zoomOutResponse,float emergencyZoomOutResponse,float emergencyRatio,
      float zoomInResponse,float centerResponse,int shrinkDelay){
    if(!Float.isFinite(targetScale)||targetScale<=0)return;
    if(Float.isNaN(scale)){scale=targetScale;centerX=targetX;centerY=targetY;shrinkFrames=0;return;}
    float dead=max(0,deadband),ratio=targetScale/max(.0001f,scale);
    if(ratio<1.0f-dead){
      float response=emergencyRatio>0&&ratio<emergencyRatio?max(zoomOutResponse,emergencyZoomOutResponse):zoomOutResponse;
      scale=lerp(scale,targetScale,constrain(response,0,1));shrinkFrames=0;
    }else if(ratio>1.0f+dead){
      shrinkFrames++;if(shrinkFrames>=max(0,shrinkDelay))scale=lerp(scale,targetScale,zoomInResponse);
    }else shrinkFrames=0;
    float dx=targetX-centerX,dy=targetY-centerY;
    float centerDead=max(.002f,dead*.12f);
    float response=centerResponse;
    if(abs(dx)>max(.12f,centerDead*5)||abs(dy)>max(.12f,centerDead*5))response=min(1.0f,centerResponse*2.2f);
    if(abs(dx)>centerDead)centerX=lerp(centerX,targetX,response);
    if(abs(dy)>centerDead)centerY=lerp(centerY,targetY,response);
  }

  void updateScene(PVector targetFocus,float targetRadius,float deadband,float zoomOutResponse,float zoomInResponse,float centerResponse,int shrinkDelay){
    if(targetFocus==null||!Float.isFinite(targetRadius)||targetRadius<=0)return;
    if(focus==null||Float.isNaN(radius)){focus=targetFocus.copy();radius=targetRadius;shrinkFrames=0;return;}
    float dead=max(0,deadband),focusDead=max(.004f,max(.05f,radius)*dead*.35f);
    PVector d=PVector.sub(targetFocus,focus);
    if(abs(d.x)>focusDead)focus.x=lerp(focus.x,targetFocus.x,centerResponse);
    if(abs(d.y)>focusDead)focus.y=lerp(focus.y,targetFocus.y,centerResponse);
    if(abs(d.z)>focusDead)focus.z=lerp(focus.z,targetFocus.z,centerResponse);
    if(targetRadius>radius*(1.0f+dead)){radius=lerp(radius,targetRadius,zoomOutResponse);shrinkFrames=0;}
    else if(targetRadius<radius*(1.0f-dead)){shrinkFrames++;if(shrinkFrames>=max(0,shrinkDelay))radius=lerp(radius,targetRadius,zoomInResponse);}
    else shrinkFrames=0;
  }
}
