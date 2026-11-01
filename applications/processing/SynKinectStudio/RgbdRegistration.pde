// ===== SynKinect Studio / Core (shared by all modules) / RgbRegistration.pde =====
class RgbProjection { float u,v,z;boolean valid; }

class RgbDepthRegistration {
  final AppConfig cfg;final Calibration depth;
  float[] rayX,rayY,rgbZBuffer;
  int preparedFrameId=-1;long preparedRgbFrameNumber=-1;int prepareCount=0;
  DepthFrame preparedDepth=null;RgbSnapshot preparedRgb=null;
  final RgbProjection sampleProjection=new RgbProjection();
  final float[] refineX=new float[4096],refineY=new float[4096];
  volatile float autoOffsetX=0.0f,autoOffsetY=0.0f,lastSyncSkewMs=Float.NaN,lastRefineGain=1.0f;
  volatile int lastRefineEdges=0;
  float projectionScaleX=1.0f,projectionScaleY=1.0f;
  volatile int raysVersion=-1;

  RgbDepthRegistration(AppConfig cfg,Calibration depth){this.cfg=cfg;this.depth=depth;
    rebuildDepthRays();}
  // Rays come from the per-device Calibration (intrinsics, distortion, pixel convention),
  // the same table used by depth calibration plane fitting.
  void rebuildDepthRays(){int version=depth.geometryVersion;float[][] r=depth.rays();rayX=r[0];rayY=r[1];raysVersion=version;
    clearPreparedFrame();
  }
  void ensureRays(){if(raysVersion!=depth.geometryVersion)rebuildDepthRays();}
  float pointX(int index,float z){ensureRays();return rayX[index]*z;}float pointY(int index,float z){ensureRays();return rayY[index]*z;
    }
  void project(int index,float z,RgbProjection out,float extraX,float extraY){ensureRays();projectPoint(rayX[index]*z,rayY[index]*z,z,out,extraX,extraY);
    }
  void projectPoint(float xd,float yd,float zd,RgbProjection out,float extraX,float extraY){
    float xc=cfg.regR00*xd+cfg.regR01*yd+cfg.regR02*zd+cfg.regTx,yc=cfg.regR10*xd+cfg.regR11*yd+cfg.regR12*zd+cfg.regTy,zc=cfg.regR20*xd+cfg.regR21*yd+cfg.regR22*zd+cfg.regTz;

    if(zc<=0.001f){out.valid=false;return;}float x=xc/zc,y=yc/zc,r2=x*x+y*y,r4=r2*r2,r6=r4*r2,radial=1.0f+cfg.rgbK1*r2+cfg.rgbK2*r4+cfg.rgbK3*r6;

    float xDist=x*radial+2.0f*cfg.rgbP1*x*y+cfg.rgbP2*(r2+2.0f*x*x),yDist=y*radial+cfg.rgbP1*(r2+2.0f*y*y)+2.0f*cfg.rgbP2*x*y;

    float nominalU=cfg.rgbFx*xDist+cfg.rgbCx+cfg.colorRegistrationOffsetX+autoOffsetX+extraX,nominalV=cfg.rgbFy*yDist+cfg.rgbCy+cfg.colorRegistrationOffsetY+autoOffsetY+extraY;

    out.u=nominalU*projectionScaleX;out.v=nominalV*projectionScaleY;out.z=zc;out.valid=true;

  }
  void clearPreparedFrame(){preparedFrameId=-1;preparedRgbFrameNumber=-1;preparedDepth=null;
    preparedRgb=null;}
  void prepareFrame(DepthFrame frame,RgbSnapshot rgb){
    if(frame!=null&&frame.width>0&&frame.height>0&&(rayX==null||rayX.length!=frame.width*frame.height))rebuildDepthRays();
    if(frame==null||frame.depth==null||rgb==null||rgb.pixels==null){clearPreparedFrame();
      return;}
    if(preparedFrameId==frame.frameId&&preparedRgbFrameNumber==rgb.frameNumber&&preparedRgb==rgb)return;

    prepareCount++;projectionScaleX=rgb.width/(float)max(1,depth.depthWidth);
    projectionScaleY=rgb.height/(float)max(1,depth.depthHeight);
    lastSyncSkewMs=Float.isNaN(rgb.syncResidualMs)?Math.abs(frame.timestampUs-rgb.timestampUs)/1000.0f:rgb.syncResidualMs;

    if(lastSyncSkewMs>rgb.syncToleranceMs){clearPreparedFrame();return;}
    if(cfg.rgbAutoRefine&&cfg.rgbRefineSearchPx>0&&(prepareCount%cfg.rgbRefineEveryFrames)==0)refineFineOffset(frame,rgb);

    int depthPixels=frame.width*frame.height;
    if(cfg.rgbOcclusionFilter){
      int rgbPixels=rgb.width*rgb.height;if(rgbZBuffer==null||rgbZBuffer.length!=rgbPixels)rgbZBuffer=new float[rgbPixels];
      Arrays.fill(rgbZBuffer,Float.POSITIVE_INFINITY);RgbProjection q=new RgbProjection();

      for(int i=0;i<depthPixels;i++){int mm=frame.depth[i]&0xffff;if(mm==0)continue;
        mm=depth.correctedDepthMm(i,mm);float z=mm*depth.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
        project(i,z,q,0,0);if(!q.valid)continue;int x=round(q.u),y=round(q.v);if(x<0||x>=rgb.width||y<0||y>=rgb.height)continue;
        int ri=y*rgb.width+x;if(q.z<rgbZBuffer[ri])rgbZBuffer[ri]=q.z;}
    }
    preparedDepth=frame;preparedRgb=rgb;preparedFrameId=frame.frameId;preparedRgbFrameNumber=rgb.frameNumber;

  }
  int colorAt(int index,float z){
    RgbSnapshot rgb=preparedRgb;if(preparedFrameId<0||rgb==null||preparedDepth==null||index<0||index>=preparedDepth.depth.length)return 0;

    project(index,z,sampleProjection,0,0);return colorFromPreparedProjection(rgb,sampleProjection);

  }
  int colorAtPoint(float x,float y,float z){
    RgbSnapshot rgb=preparedRgb;if(preparedFrameId<0||rgb==null||preparedDepth==null)return 0;

    projectPoint(x,y,z,sampleProjection,0,0);return colorFromPreparedProjection(rgb,sampleProjection);

  }
  int colorFromPreparedProjection(RgbSnapshot rgb,RgbProjection q){
    if(!q.valid||q.u<0||q.v<0||q.u>rgb.width-1.001f||q.v>rgb.height-1.001f)return 0;

    if(cfg.rgbOcclusionFilter&&rgbZBuffer!=null){int zx=constrain(round(q.u),0,rgb.width-1),zy=constrain(round(q.v),0,rgb.height-1);
      float front=rgbZBuffer[zy*rgb.width+zx];if(Float.isFinite(front)&&q.z>front+cfg.rgbOcclusionToleranceM)return 0;
      }
    return sampleBilinearWeighted(rgb,q.u,q.v,lastSyncSkewMs);
  }
  int sampleBilinearWeighted(RgbSnapshot rgb,float u,float v,float syncMs){
    int x0=floor(u),y0=floor(v),x1=min(rgb.width-1,x0+1),y1=min(rgb.height-1,y0+1);
    float fx=u-x0,fy=v-y0;int c00=rgb.pixels[y0*rgb.width+x0],c10=rgb.pixels[y0*rgb.width+x1],c01=rgb.pixels[y1*rgb.width+x0],c11=rgb.pixels[y1*rgb.width+x1];

    float r0=lerp((c00>>16)&255,(c10>>16)&255,fx),r1=lerp((c01>>16)&255,(c11>>16)&255,fx),g0=lerp((c00>>8)&255,(c10>>8)&255,fx),g1=lerp((c01>>8)&255,(c11>>8)&255,
      fx),b0=lerp(c00&255,c10&255,fx),b1=lerp(c01&255,c11&255,fx);
    int r=constrain(round(lerp(r0,r1,fy)),0,255),g=constrain(round(lerp(g0,g1,fy)),0,255),b=constrain(round(lerp(b0,b1,fy)),0,255),luma=(77*r+150*g+29*b)>>8;
    float exposure=1.0f;
    if(luma<cfg.rgbExposureLowLuma)exposure=max(0.05f,luma/(float)max(1,cfg.rgbExposureLowLuma));
    else if(luma>cfg.rgbExposureHighLuma)exposure=max(0.05f,(255-luma)/(float)max(1,255-cfg.rgbExposureHighLuma));
    float sync=1.0f-constrain(syncMs/max(1.0f,rgb.syncToleranceMs),0.0f,1.0f),quality=constrain(exposure*(0.35f+0.65f*sync)*rgb.frameQuality,0.05f,1.0f);
    int alpha=constrain(round(quality*255.0f),1,255);return(alpha<<24)|(r<<16)|(g<<8)|b;

  }
  void refineFineOffset(DepthFrame frame,RgbSnapshot rgb){
    int count=0,step=max(2,cfg.rgbRefineSampleStep),threshold=cfg.rgbRefineEdgeThresholdMm;
    RgbProjection q=new RgbProjection();
    for(int v=step;v<frame.height-step&&count<refineX.length;v+=step)for(int u=step;u<frame.width-step&&count<refineX.length;u+=step){int i=v*frame.width+u,
      mm=frame.depth[i]&0xffff;if(mm==0)continue;mm=depth.correctedDepthMm(i,mm);
      int ri=v*frame.width+min(frame.width-1,u+step),di=min(frame.height-1,v+step)*frame.width+u,mr=frame.depth[ri]&0xffff,md=frame.depth[di]&0xffff;
      if(mr!=0)mr=depth.correctedDepthMm(ri,mr);if(md!=0)md=depth.correctedDepthMm(di,md);
      boolean edge=(mr!=0&&abs(mr-mm)>=threshold)||(md!=0&&abs(md-mm)>=threshold);
      if(!edge)continue;float z=mm*depth.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
      project(i,z,q,0,0);if(!q.valid||q.u<3||q.v<3||q.u>=rgb.width-3||q.v>=rgb.height-3)continue;
      refineX[count]=q.u;refineY[count]=q.v;count++;}
    lastRefineEdges=count;if(count<cfg.rgbRefineMinimumEdges){lastRefineGain=1.0f;
      return;}int search=cfg.rgbRefineSearchPx,bestDx=0,bestDy=0;double base=0,best=-1;

    for(int dy=-search;dy<=search;dy++)for(int dx=-search;dx<=search;dx++){double score=0;
      for(int i=0;i<count;i++)score+=rgbGradient(rgb,round(refineX[i])+dx,round(refineY[i])+dy);
      if(dx==0&&dy==0)base=score;if(score>best){best=score;bestDx=dx;bestDy=dy;}}
    lastRefineGain=(float)(best/Math.max(1.0,base));if((bestDx!=0||bestDy!=0)&&best>base*1.01){autoOffsetX=constrain(autoOffsetX+bestDx*cfg.rgbRefineAlpha,
        -cfg.rgbRefineMaxOffsetPx,cfg.rgbRefineMaxOffsetPx);autoOffsetY=constrain(autoOffsetY+bestDy*cfg.rgbRefineAlpha,-cfg.rgbRefineMaxOffsetPx,cfg.rgbRefineMaxOffsetPx);
      }
  }
  int rgbGradient(RgbSnapshot rgb,int x,int y){if(x<1||x>=rgb.width-1||y<1||y>=rgb.height-1)return 0;
    int lx=luma(rgb.pixels[y*rgb.width+x-1]),rx=luma(rgb.pixels[y*rgb.width+x+1]),uy=luma(rgb.pixels[(y-1)*rgb.width+x]),dy=luma(rgb.pixels[(y+1)*rgb.width+x]);
    return abs(rx-lx)+abs(dy-uy);}int luma(int c){int r=(c>>16)&255,g=(c>>8)&255,b=c&255;
    return(77*r+150*g+29*b)>>8;}
}
