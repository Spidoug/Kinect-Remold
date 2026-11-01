// ===== SynKinect Studio / Core (shared by all modules) / PointCloud.pde =====
class PointCloudBuilder {
  AppConfig cfg;
  RgbDepthRegistration registration;
  final int[] neighborScratch=new int[8];
  final int[] medianScratch=new int[49];
  PointCloudBuilder(AppConfig cfg,RgbDepthRegistration registration) { this.cfg = cfg;
     this.registration=registration; }

  PointCloud build(DepthFrame f, Calibration c, int step, float targetZ, float band, PointCloudBuildStats stats, RgbSnapshot rgb) {
    if (stats != null) stats.clear();
    if (f == null || f.depth == null || c == null || !c.valid) return new PointCloud();

    int safeStep = max(1, step);
    int estimated=((f.width+safeStep-1)/safeStep)*((f.height+safeStep-1)/safeStep);

    PointCloud cloud = new PointCloud(estimated);
    boolean includeColor=(cfg.meshColorEnabled||cfg.colorIcpEnabled)&&registration!=null&&rgb!=null;
    if(includeColor) registration.prepareFrame(f,rgb);
    boolean[] componentMask=cfg.pointCloudConnectedTarget&&(!cfg.boundingBoxEnabled||scannerState().boundingBox==null||!scannerState().boundingBox.locked)&&!Float.isNaN(targetZ)?connectedTargetMask(f,c,safeStep,targetZ,band):null;
    int componentW=(f.width+safeStep-1)/safeStep;
    for (int v = 0; v < f.height; v += safeStep) {
      int row=v*f.width;
      for (int u = 0; u < f.width; u += safeStep) {
        if (stats != null) stats.sourcePixels++;
        int index=row+u;
        if(componentMask!=null&&!componentMask[(v/safeStep)*componentW+(u/safeStep)]){if(stats!=null)stats.rejectedBand++;continue;}
        int raw = f.depth[index] & 0xFFFF;
        if (raw == 0) continue;
        if (stats != null) stats.nonZero++;
        int filteredMm=filteredDepthMm(f,u,v,raw,safeStep,c);
        if(filteredMm<=0){if(stats!=null)stats.rejectedSpatial++;continue;}
        float z = filteredMm * c.depthScale;
        if (z < cfg.minDepthM || z > cfg.maxDepthM) { if (stats != null) stats.rejectedRange++;
           continue; }
        if (stats != null) stats.inRange++;
        if (!Float.isNaN(targetZ) && abs(z - targetZ) > band) { if (stats != null) stats.rejectedBand++;
           continue; }
        float x = registration!=null ? registration.pointX(index,z) : (u-c.cx)*z/c.fx;

        float y = registration!=null ? registration.pointY(index,z) : (v-c.cy)*z/c.fy;

        float confidence=c.depthConfidence(index,z)*edgeConfidence(f,u,v,filteredMm,c)*surfaceConfidence(f,u,v,filteredMm,c);

        if(confidence<cfg.pointCloudMinimumConfidence){if(stats!=null)stats.rejectedSpatial++;
          continue;}
        int rgbColor = includeColor ? registration.colorAt(index,z) : 0;
        cloud.add(new PVector(x,y,z),rgbColor,confidence);
        if (stats != null) stats.accepted++;
      }
    }
    return cloud;
  }

  boolean[] connectedTargetMask(DepthFrame f,Calibration c,int step,float targetZ,float band){
    int gw=(f.width+step-1)/step,gh=(f.height+step-1)/step,n=gw*gh;
    boolean[] candidate=new boolean[n],visited=new boolean[n],bestMask=new boolean[n];
    float[] depth=new float[n];Arrays.fill(depth,Float.NaN);
    float relaxed=band*1.04f;int valid=0;

    // Segmentation uses a slightly expanded version of the acquisition ROI.
    // This still leaves room for the complete object while preventing full-FOV
    // walls/floor/table surfaces from becoming the dominant component.
    float margin=cfg.targetSegmentationMargin;
    int minGX=constrain(floor((cfg.depthRoiLeft-margin)*f.width/step),0,gw-1);
    int maxGX=constrain(ceil((cfg.depthRoiRight+margin)*f.width/step),minGX+1,gw);
    int minGY=constrain(floor((cfg.depthRoiTop-margin)*f.height/step),0,gh-1);
    int maxGY=constrain(ceil((cfg.depthRoiBottom+margin)*f.height/step),minGY+1,gh);
    for(int gy=minGY;gy<maxGY;gy++){
      int v=min(f.height-1,gy*step);
      for(int gx=minGX;gx<maxGX;gx++){
        int u=min(f.width-1,gx*step),index=v*f.width+u,mm=f.depth[index]&0xffff;
        if(mm==0)continue;if(c!=null)mm=c.correctedDepthMm(index,mm);if(mm<=0)continue;
        float z=mm*(c==null?0.001f:c.depthScale);
        if(z<cfg.minDepthM||z>cfg.maxDepthM||abs(z-targetZ)>relaxed)continue;
        int gi=gy*gw+gx;candidate[gi]=true;depth[gi]=z;valid++;
      }
    }
    if(valid<cfg.pointCloudComponentMinSamples)return bestMask;

    int bestCount=0;float bestScore=-Float.MAX_VALUE;
    ArrayDeque<Integer> queue=new ArrayDeque<Integer>();ArrayList<Integer> component=new ArrayList<Integer>();
    float link=max(0.005f,cfg.pointCloudComponentDepthLinkM);
    for(int seed=0;seed<n;seed++){
      if(!candidate[seed]||visited[seed])continue;
      queue.clear();component.clear();queue.add(seed);visited[seed]=true;
      float sx=0,sy=0,depthError=0;int borderHits=0;
      while(!queue.isEmpty()){
        int q=queue.removeFirst();component.add(q);int qx=q%gw,qy=q/gw;sx+=qx;sy+=qy;
        depthError+=abs(depth[q]-targetZ);
        if(qx<=minGX+1||qx>=maxGX-2||qy<=minGY+1||qy>=maxGY-2)borderHits++;
        for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
          if(dx==0&&dy==0)continue;int nx=qx+dx,ny=qy+dy;
          if(nx<minGX||ny<minGY||nx>=maxGX||ny>=maxGY)continue;
          int ni=ny*gw+nx;if(!candidate[ni]||visited[ni])continue;
          // Image adjacency is accepted only when metric depth also represents one continuous 3D surface.
          // Require metric depth continuity so object and support/background do
          // not merge through a one-pixel contact/occlusion boundary.
          float localLink=link*(dx!=0&&dy!=0?1.35f:1.0f);
          if(abs(depth[ni]-depth[q])>localLink)continue;
          visited[ni]=true;queue.addLast(ni);
        }
      }
      int count=component.size();if(count<cfg.pointCloudComponentMinSamples)continue;
      float cx=sx/count,cy=sy/count;
      float centerGX=(minGX+maxGX-1)*.5f,centerGY=(minGY+maxGY-1)*.5f;
      float dx=(cx-centerGX)/max(1,(maxGX-minGX)*.5f),dy=(cy-centerGY)/max(1,(maxGY-minGY)*.5f);
      float centrality=max(0,1.0f-sqrt(dx*dx+dy*dy));
      float meanDepthError=depthError/count;
      float depthAffinity=constrain(1.0f-meanDepthError/max(0.02f,band),0.20f,1.0f);
      float borderRatio=borderHits/(float)count;
      float borderFactor=max(0.08f,1.0f-cfg.pointCloudComponentBorderPenalty*constrain(borderRatio*4.0f,0,1));
      float score=count*(0.62f+0.38f*centrality)*depthAffinity*borderFactor;
      if(score>bestScore){Arrays.fill(bestMask,false);for(Integer q:component)bestMask[q]=true;bestScore=score;bestCount=count;}
    }
    return bestMask;
  }

  float edgeConfidence(DepthFrame f,int u,int v,int centerMm,Calibration calibration){
    if(f==null||f.depth==null||centerMm<=0)return 0;
    float center=centerMm*0.001f,maxDelta=0;int valid=0;
    final int[] dx={-1,1,0,0},dy={0,0,-1,1};
    for(int k=0;k<4;k++){
      int x=u+dx[k],y=v+dy[k];if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int index=y*f.width+x,mm=f.depth[index]&0xffff;if(mm==0)continue;
      if(calibration!=null)mm=calibration.correctedDepthMm(index,mm);if(mm<=0)continue;

      maxDelta=max(maxDelta,abs(mm*0.001f-center));valid++;
    }
    if(valid<2)return 0.45f;
    if(maxDelta>=cfg.pointCloudEdgeRejectM)return 0;
    if(maxDelta<=cfg.pointCloudEdgeSoftM)return 1.0f;
    float span=max(0.0001f,cfg.pointCloudEdgeRejectM-cfg.pointCloudEdgeSoftM);
    return constrain(1.0f-(maxDelta-cfg.pointCloudEdgeSoftM)/span,0.10f,1.0f);
  }

  float surfaceConfidence(DepthFrame f,int u,int v,int centerMm,Calibration calibration){
    if(f==null||f.depth==null||centerMm<=0)return 0;int n=0,coherent=0;float sum=0,sum2=0;
    for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){int x=u+dx,y=v+dy;if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int index=y*f.width+x,mm=f.depth[index]&0xffff;if(mm==0)continue;if(calibration!=null)mm=calibration.correctedDepthMm(index,mm);if(mm<=0)continue;
      float dz=(mm-centerMm)*.001f;if(abs(dz)<=cfg.pointCloudEdgeRejectM){coherent++;sum+=dz;sum2+=dz*dz;}n++;}
    if(n<4)return .55f;float support=coherent/(float)n;if(support<cfg.pointCloudMinimumSupport)return .08f;
    float mean=sum/max(1,coherent),variance=max(0,sum2/max(1,coherent)-mean*mean),sigma=sqrt(variance);
    float noise=constrain(1.0f-sigma/max(.001f,cfg.pointCloudSurfaceNoiseM),.12f,1.0f);
    return constrain(support*noise,.08f,1.0f);
  }

  int filteredDepthMm(DepthFrame f,int u,int v,int centerMm,int step){return filteredDepthMm(f,u,v,centerMm,step,null);
    }
  int filteredDepthMm(DepthFrame f,int u,int v,int centerMm,int step,Calibration calibration){
    int centerIndex=v*f.width+u;if(calibration!=null)centerMm=calibration.correctedDepthMm(centerIndex,centerMm);

    int toleranceMm=max(1,round(cfg.pointCloudNeighborToleranceM*1000.0f));
    int n=0;
    for(int dy=-step;dy<=step;dy+=step)for(int dx=-step;dx<=step;dx+=step){
      if(dx==0&&dy==0)continue;
      int x=u+dx,y=v+dy;
      if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int ni=y*f.width+x,mm=f.depth[ni]&0xffff;if(calibration!=null&&mm!=0)mm=calibration.correctedDepthMm(ni,mm);

      if(mm!=0)neighborScratch[n++]=mm;
    }

    int filtered=centerMm;
    if(n>=3){
      sortSmall(neighborScratch,n);
      int median=neighborScratch[n/2],coherent=0;
      for(int i=0;i<n;i++)if(abs(neighborScratch[i]-median)<=toleranceMm)coherent++;

      int majority=max(3,(n*5+7)/8); // ceil(n * 0.625)
      if(coherent>=majority){
        if(abs(centerMm-median)>toleranceMm)filtered=median;
        else{
          int m=0;medianScratch[m++]=centerMm;
          for(int i=0;i<n;i++)if(abs(neighborScratch[i]-median)<=toleranceMm)medianScratch[m++]=neighborScratch[i];

          sortSmall(medianScratch,m);filtered=medianScratch[m/2];
        }
      }
    }

    if(cfg.pointCloudSpatialFilter&&n>2){
      int consistent=0;
      for(int i=0;i<n;i++)if(abs(neighborScratch[i]-filtered)<=toleranceMm)consistent++;

      if(consistent<max(2,(n+1)/2))return -1;
    }
    return filtered;
  }

  PointCloud buildHighQuality(DepthFrame f, Calibration c, float targetZ, float band, RgbSnapshot rgb) {
    if (f == null || f.depth == null || c == null || !c.valid) return new PointCloud();

    int step=max(1,cfg.hqIntegrationStep);
    int estimated=((f.width+step-1)/step)*((f.height+step-1)/step);
    PointCloud cloud=new PointCloud(estimated);
    boolean includeColor=(cfg.meshColorEnabled||cfg.colorIcpEnabled)&&registration!=null&&rgb!=null;
    if(includeColor)registration.prepareFrame(f,rgb);
    boolean[] componentMask=cfg.pointCloudConnectedTarget&&(!cfg.boundingBoxEnabled||scannerState().boundingBox==null||!scannerState().boundingBox.locked)&&!Float.isNaN(targetZ)?connectedTargetMask(f,c,step,targetZ,band):null;
    int componentW=(f.width+step-1)/step;
    for(int v=0;v<f.height;v+=step){
      int row=v*f.width;
      for(int u=0;u<f.width;u+=step){
        int index=row+u;if(componentMask!=null&&!componentMask[(v/step)*componentW+(u/step)])continue;int raw=f.depth[index]&0xffff;
        int filteredMm=filteredDepthMmHighQuality(f,u,v,raw,c);
        if(filteredMm<=0)continue;
        float z=filteredMm*c.depthScale;
        if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
        if(!Float.isNaN(targetZ)&&abs(z-targetZ)>band)continue;
        float x=registration!=null?registration.pointX(index,z):(u-c.cx)*z/c.fx;
        float y=registration!=null?registration.pointY(index,z):(v-c.cy)*z/c.fy;
        float confidence=c.depthConfidence(index,z)*edgeConfidence(f,u,v,filteredMm,c)*surfaceConfidence(f,u,v,filteredMm,c);

        if(confidence<max(cfg.pointCloudMinimumConfidence,cfg.hqTsdfMinimumPointConfidence*0.82f))continue;
        int color=includeColor?registration.colorAt(index,z):0;
        cloud.add(new PVector(x,y,z),color,confidence);
      }
    }
    return cloud;
  }

  int filteredDepthMmHighQuality(DepthFrame f,int u,int v,int centerMm){return filteredDepthMmHighQuality(f,u,v,centerMm,null);
    }
  int filteredDepthMmHighQuality(DepthFrame f,int u,int v,int centerMm,Calibration calibration){
    int centerIndex=v*f.width+u;if(calibration!=null&&centerMm!=0)centerMm=calibration.correctedDepthMm(centerIndex,centerMm);

    int radius=max(1,cfg.hqDepthFilterRadius),tolerance=max(1,round(cfg.hqDepthEdgeToleranceM*1000.0f));

    int n=0;
    for(int dy=-radius;dy<=radius;dy++)for(int dx=-radius;dx<=radius;dx++){
      int x=u+dx,y=v+dy;if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int ni=y*f.width+x,mm=f.depth[ni]&0xffff;if(mm==0)continue;if(calibration!=null)mm=calibration.correctedDepthMm(ni,mm);

      if(centerMm==0||abs(mm-centerMm)<=tolerance)medianScratch[n++]=mm;
    }
    if(centerMm==0){
      if(n<cfg.hqHoleFillMinimumNeighbors)return -1;
      sortSmall(medianScratch,n);int median=medianScratch[n/2],coherent=0;
      for(int i=0;i<n;i++)if(abs(medianScratch[i]-median)<=tolerance)coherent++;
      if(coherent<cfg.hqHoleFillMinimumNeighbors)return -1;
      return median;
    }
    if(n<3)return centerMm;
    sortSmall(medianScratch,n);
    int median=medianScratch[n/2];
    // Edge-aware median: only samples already close to the center are present,
    // so this suppresses structured-light speckle without bleeding across depth edges.
    return abs(median-centerMm)<=tolerance?median:centerMm;
  }

  void sortSmall(int[] values,int count){
    for(int i=1;i<count;i++){
      int value=values[i],j=i-1;
      while(j>=0&&values[j]>value){values[j+1]=values[j];j--;}
      values[j+1]=value;
    }
  }
}

class PointCloud {
  ArrayList<PVector> points;
  int[] colors;float[] confidence;
  PointCloud(){this(4096);}
  PointCloud(int capacity){int safe=max(16,capacity);points=new ArrayList<PVector>(safe);
    colors=new int[safe];confidence=new float[safe];Arrays.fill(confidence,1.0f);
    }
  int size() { return points.size(); }
  void add(PVector p,int c){add(p,c,1.0f);}
  void add(PVector p,int c,float q){
    int index=points.size();points.add(p);
    if(index>=colors.length){int next=max(index+1,colors.length*2);colors=Arrays.copyOf(colors,next);
      confidence=Arrays.copyOf(confidence,next);}
    colors[index]=c;confidence[index]=constrain(q,0.05f,1.0f);
  }
  int colorAt(int i){return i>=0&&i<points.size()?colors[i]:0;}
  float confidenceAt(int i){return i>=0&&i<points.size()?confidence[i]:1.0f;}

  PVector centroidTransformed(RigidTransform t) {
    if(points.isEmpty())return new PVector();
    double sx=0,sy=0,sz=0;float[] m=t.m;
    for(PVector p:points){sx+=m[0]*p.x+m[1]*p.y+m[2]*p.z+m[3];sy+=m[4]*p.x+m[5]*p.y+m[6]*p.z+m[7];
      sz+=m[8]*p.x+m[9]*p.y+m[10]*p.z+m[11];}
    float inv=1.0f/points.size();return new PVector((float)(sx*inv),(float)(sy*inv),(float)(sz*inv));

  }
  PointCloud transformed(RigidTransform t, int maxPoints) {
    int limit=max(1,maxPoints),stride=max(1,(points.size()+limit-1)/limit);
    PointCloud out = new PointCloud(min(points.size(),limit)+1);
    for (int i = 0; i < points.size(); i += stride) out.add(t.apply(points.get(i)),colorAt(i),confidenceAt(i));
     return out;
  }
}

class PreviewPointVoxel {
  PVector p;int color;float confidence;int count=1;
  PreviewPointVoxel(PVector point,int c,float q){p=point.copy();color=c;confidence=q;}
  void add(PVector point,int c,float q){
    count=min(64,count+1);float a=1.0f/count;p.lerp(point,a);
    confidence=lerp(confidence,q,.20f);
    if(c!=0){if(color==0)color=c;else{
      int ar=(color>>16)&255,ag=(color>>8)&255,ab=color&255;
      int br=(c>>16)&255,bg=(c>>8)&255,bb=c&255;
      color=0xff000000|(round(lerp(ar,br,.18f))<<16)|(round(lerp(ag,bg,.18f))<<8)|round(lerp(ab,bb,.18f));
    }}
  }
}

class PointCloudAccumulator {
  final AppConfig cfg;
  final HashMap<VertexKey,PreviewPointVoxel> voxels=new HashMap<VertexKey,PreviewPointVoxel>();
  PointCloud cached=new PointCloud();boolean dirty=true;
  PointCloudAccumulator(AppConfig c){cfg=c;}
  void reset(){voxels.clear();cached=new PointCloud();dirty=true;}

  void accumulate(PointCloud cloud,RigidTransform pose){
    if(cloud==null||pose==null||cloud.size()==0)return;
    int budget=max(1,cfg.previewPointMaxPoints);
    int stride=max(1,(cloud.size()+max(1,cfg.previewPointTransientMaxPoints)-1)/max(1,cfg.previewPointTransientMaxPoints));
    for(int i=0;i<cloud.size();i+=stride){
      if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;
      PVector world=pose.apply(cloud.points.get(i));
      VertexKey key=new VertexKey(world.x,world.y,world.z,cfg.previewPointVoxelM);
      PreviewPointVoxel v=voxels.get(key);
      if(v!=null)v.add(world,cloud.colorAt(i),cloud.confidenceAt(i));
      else if(voxels.size()<budget)voxels.put(key,new PreviewPointVoxel(world,cloud.colorAt(i),cloud.confidenceAt(i)));
    }
    dirty=true;
  }

  PointCloud snapshot(){
    if(!dirty&&cached!=null)return cached;
    int maxDisplay=max(1,cfg.previewPointDisplayMaxPoints);
    int stride=max(1,(voxels.size()+maxDisplay-1)/maxDisplay);
    PointCloud out=new PointCloud(min(maxDisplay,voxels.size())+8);int i=0;
    for(PreviewPointVoxel v:voxels.values()){
      if((i++%stride)!=0)continue;
      out.add(v.p.copy(),v.color,v.confidence);
    }
    cached=out;dirty=false;return cached;
  }

  PointCloud snapshotWithTransient(PointCloud transientCloud){
    PointCloud permanent=snapshot();
    if(transientCloud==null||transientCloud.size()==0)return permanent;
    int transientLimit=max(1,cfg.previewPointTransientMaxPoints);
    int permanentLimit=max(1,cfg.previewPointDisplayMaxPoints-transientLimit);
    int pStride=max(1,(permanent.size()+permanentLimit-1)/permanentLimit);
    PointCloud out=new PointCloud(min(permanent.size(),permanentLimit)+min(transientCloud.size(),transientLimit)+8);
    for(int i=0;i<permanent.size();i+=pStride)out.add(permanent.points.get(i).copy(),permanent.colorAt(i),permanent.confidenceAt(i));
    int tStride=max(1,(transientCloud.size()+transientLimit-1)/transientLimit);
    for(int i=0;i<transientCloud.size();i+=tStride)out.add(transientCloud.points.get(i).copy(),transientCloud.colorAt(i),transientCloud.confidenceAt(i));
    return out;
  }
}


// Static support surface (table/floor) under a turntable. The Kinect does not
// move in Turntable mode, so the plane is constant in camera coordinates. Every
// point on or below it is static background: if it stays in the ROI it dominates
// ICP (a table is usually far larger than the object) and pulls the estimated
// rotation back to zero. Skanect/KinectFusion turntable workflows remove the
// ground plane for the same reason. Plane: n.p + d, positive on the object side.
class SupportPlane {
  boolean valid=false;float nx,ny,nz,d,clearance;int inliers=0;float inlierRatio=0;
  void invalidate(){valid=false;inliers=0;inlierRatio=0;}
  float signedDistance(PVector q){return nx*q.x+ny*q.y+nz*q.z+d;}
  float signedDistance(float x,float y,float z){return nx*x+ny*y+nz*z+d;}
  boolean keeps(PVector q){return !valid||signedDistance(q)>=clearance;}
  boolean similar(SupportPlane o){
    if(o==null||!o.valid||!valid)return false;float dot=nx*o.nx+ny*o.ny+nz*o.nz;
    return dot>cos(radians(3.0f))&&abs(d-o.d)<0.012f;
  }
}

class SupportPlaneEstimator {
  final AppConfig cfg;final Random random=new Random(0x5eed);
  SupportPlaneEstimator(AppConfig cfg){this.cfg=cfg;}

  // Gravity-guided RANSAC over a sparse grid of the full depth frame, followed by
  // a least-squares refit on the inliers. The accelerometer only fixes the plane
  // orientation prior; its sign convention does not matter because the normal is
  // oriented toward the object found in the acquisition ROI.
  SupportPlane estimate(DepthFrame f,Calibration c,RgbDepthRegistration reg,MotionSample motion){
    if(f==null||f.depth==null||c==null||!c.valid)return null;
    int step=max(2,cfg.supportPlaneSampleStep);
    int cap=((f.width+step-1)/step)*((f.height+step-1)/step);
    float[] xs=new float[cap],ys=new float[cap],zs=new float[cap];int n=0;
    float[] rxs=new float[cap/2+16],rys=new float[cap/2+16],rzs=new float[cap/2+16];int roiN=0;
    int roiX0=round(cfg.depthRoiLeft*f.width),roiX1=round(cfg.depthRoiRight*f.width),roiY0=round(cfg.depthRoiTop*f.height),roiY1=round(cfg.depthRoiBottom*f.height);
    for(int v=0;v<f.height;v+=step)for(int u=0;u<f.width;u+=step){
      int i=v*f.width+u,mm=f.depth[i]&0xffff;if(mm==0)continue;mm=c.correctedDepthMm(i,mm);if(mm<=0)continue;
      float z=mm*c.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
      float x=reg!=null?reg.pointX(i,z):(u-c.cx)*z/c.fx,y=reg!=null?reg.pointY(i,z):(v-c.cy)*z/c.fy;
      xs[n]=x;ys[n]=y;zs[n]=z;n++;
      if(u>=roiX0&&u<roiX1&&v>=roiY0&&v<roiY1&&roiN<rxs.length){rxs[roiN]=x;rys[roiN]=y;rzs[roiN]=z;roiN++;}
    }
    if(n<200)return null;
    PVector g=motion!=null&&motion.gravityReliable()?motion.gravityUnit():null;
    // Without a trustworthy accelerometer, assume the usual upright sensor and
    // only accept planes whose normal is close to camera-space vertical.
    float minVertical=g!=null?cos(radians(cfg.supportPlaneMaxTiltDeg)):cos(radians(max(cfg.supportPlaneMaxTiltDeg,45.0f)));
    float bestScore=0;float bnx=0,bny=0,bnz=0,bd=0;
    for(int it=0;it<cfg.supportPlaneIterations;it++){
      int a=random.nextInt(n),b=random.nextInt(n),e=random.nextInt(n);if(a==b||b==e||a==e)continue;
      float ux=xs[b]-xs[a],uy=ys[b]-ys[a],uz=zs[b]-zs[a],vx=xs[e]-xs[a],vy=ys[e]-ys[a],vz=zs[e]-zs[a];
      float cx=uy*vz-uz*vy,cy=uz*vx-ux*vz,cz=ux*vy-uy*vx,m=sqrt(cx*cx+cy*cy+cz*cz);if(m<1e-6f)continue;cx/=m;cy/=m;cz/=m;
      float vertical=g!=null?abs(cx*g.x+cy*g.y+cz*g.z):abs(cy);if(vertical<minVertical)continue;
      float dd=-(cx*xs[a]+cy*ys[a]+cz*zs[a]);int count=0;
      for(int i=0;i<n;i+=2){float z=zs[i],tol=cfg.supportPlaneInlierM+0.0030f*z*z;if(abs(cx*xs[i]+cy*ys[i]+cz*zs[i]+dd)<=tol)count++;}
      if(count>bestScore){bestScore=count;bnx=cx;bny=cy;bnz=cz;bd=dd;}
    }
    if(bestScore<=0)return null;
    // Least-squares refinement: centroid + smallest-eigenvalue direction of the inlier covariance.
    double sx=0,sy=0,sz=0;int in=0;
    for(int i=0;i<n;i++){float z=zs[i],tol=cfg.supportPlaneInlierM+0.0030f*z*z;if(abs(bnx*xs[i]+bny*ys[i]+bnz*zs[i]+bd)<=tol){sx+=xs[i];sy+=ys[i];sz+=zs[i];in++;}}
    if(in<cfg.supportPlaneMinInliers||in<n*cfg.supportPlaneMinInlierRatio)return null;
    double mx=sx/in,my=sy/in,mz=sz/in;double[][] cov=new double[3][3];
    for(int i=0;i<n;i++){float z=zs[i],tol=cfg.supportPlaneInlierM+0.0030f*z*z;if(abs(bnx*xs[i]+bny*ys[i]+bnz*zs[i]+bd)>tol)continue;
      double dx=xs[i]-mx,dy=ys[i]-my,dz=zs[i]-mz;cov[0][0]+=dx*dx;cov[0][1]+=dx*dy;cov[0][2]+=dx*dz;cov[1][1]+=dy*dy;cov[1][2]+=dy*dz;cov[2][2]+=dz*dz;}
    cov[1][0]=cov[0][1];cov[2][0]=cov[0][2];cov[2][1]=cov[1][2];
    double[] normal=smallestEigenvector(cov,new double[]{bnx,bny,bnz});
    SupportPlane p=new SupportPlane();p.nx=(float)normal[0];p.ny=(float)normal[1];p.nz=(float)normal[2];
    p.d=(float)-(p.nx*mx+p.ny*my+p.nz*mz);p.inliers=in;p.inlierRatio=in/(float)n;
    // Orient toward the object: the median ROI sample that is not on the plane.
    ArrayList<Float> side=new ArrayList<Float>();
    for(int i=0;i<roiN;i++){float s=p.signedDistance(rxs[i],rys[i],rzs[i]);if(abs(s)>0.012f)side.add(s);}
    if(side.size()<40)return null;
    Collections.sort(side);if(side.get(side.size()/2)<0){p.nx=-p.nx;p.ny=-p.ny;p.nz=-p.nz;p.d=-p.d;}
    // Clearance scales with the structured-light noise at the plane's distance.
    float planeZ=(float)mz;p.clearance=max(cfg.supportPlaneClearanceM,2.5f*(0.0012f+0.0020f*planeZ*planeZ));
    p.valid=true;return p;
  }

  double[] smallestEigenvector(double[][] a,double[] seed){
    // Inverse iteration on the symmetric 3x3 covariance (shifted for stability).
    double[][] m=new double[3][3];double shift=1e-9*(a[0][0]+a[1][1]+a[2][2]+1e-12);
    for(int r=0;r<3;r++)for(int col=0;col<3;col++)m[r][col]=a[r][col]+(r==col?shift:0);
    double[] v={seed[0],seed[1],seed[2]};
    for(int it=0;it<24;it++){
      double[] x=solve3(m,v);if(x==null)break;double len=Math.sqrt(x[0]*x[0]+x[1]*x[1]+x[2]*x[2]);if(len<1e-18)break;
      v[0]=x[0]/len;v[1]=x[1]/len;v[2]=x[2]/len;
    }
    double len=Math.sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);if(len<1e-12)return seed;
    return new double[]{v[0]/len,v[1]/len,v[2]/len};
  }
  double[] solve3(double[][] m,double[] b){
    double det=m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])-m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])+m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);
    if(Math.abs(det)<1e-30)return null;double[] x=new double[3];
    for(int k=0;k<3;k++){double[][] t=new double[3][3];for(int r=0;r<3;r++)for(int col=0;col<3;col++)t[r][col]=col==k?b[r]:m[r][col];
      x[k]=(t[0][0]*(t[1][1]*t[2][2]-t[1][2]*t[2][1])-t[0][1]*(t[1][0]*t[2][2]-t[1][2]*t[2][0])+t[0][2]*(t[1][0]*t[2][1]-t[1][1]*t[2][0]))/det;}
    return x;
  }
}

class BoundingBoxTracker {
  final AppConfig cfg;
  boolean locked=false,worldLocked=false;
  float minX,maxX,minY,maxY,minZ,maxZ;
  // Immutable acquisition volume in reconstruction/world coordinates.
  PVector worldCenter=new PVector();
  float worldHalfSide=0;
  // Camera-space support plane removed from every Turntable ROI query.
  SupportPlane supportPlane=null;
  BoundingBoxTracker(AppConfig c){cfg=c;}
  void reset(){locked=false;minX=maxX=minY=maxY=minZ=maxZ=0;resetWorldLock();}
  void resetWorldLock(){worldLocked=false;worldCenter.set(0,0,0);worldHalfSide=0;}

  // Returns true when the ROI had to be re-derived because the support changed.
  boolean setSupportPlane(SupportPlane plane){
    if(plane==null||!plane.valid)return false;
    boolean changed=supportPlane==null||!supportPlane.similar(plane);
    supportPlane=plane;
    if(changed&&locked&&!worldLocked){locked=false;return true;}
    return false;
  }
  void clearSupportPlane(){supportPlane=null;if(!worldLocked)locked=false;}
  boolean supportActive(){return cfg.supportPlaneEnabled&&supportPlane!=null&&supportPlane.valid&&!(scannerFusionMode()&&scannerState().scanActive);}
  PointCloud removeSupport(PointCloud input){
    if(input==null||!supportActive())return input;
    PointCloud out=new PointCloud(max(16,input.size()));
    for(int i=0;i<input.size();i++){PVector q=input.points.get(i);if(!supportPlane.keeps(q))continue;out.add(q.copy(),input.colorAt(i),input.confidenceAt(i));}
    return out;
  }

  PointCloud filter(PointCloud input){return filter(input,true);}
  PointCloud filter(PointCloud input,boolean adapt){
    if(input==null)return new PointCloud();
    if(!cfg.boundingBoxEnabled)return input;
    boolean support=supportActive();
    if(!locked)lockFrom(support?removeSupport(input):input);
    if(!locked)return support?removeSupport(input):input;
    PointCloud out=new PointCloud(max(16,input.size()));
    for(int i=0;i<input.size();i++){
      PVector q=input.points.get(i);
      if(q.x<minX||q.x>maxX||q.y<minY||q.y>maxY||q.z<minZ||q.z>maxZ)continue;
      if(support&&!supportPlane.keeps(q))continue;
      out.add(q.copy(),input.colorAt(i),input.confidenceAt(i));
    }
    // The ROI may follow the object only while idle. Once Scan starts it is
    // frozen so capture cannot silently grow/shift beyond the preview volume.
    if(adapt&&!scannerState().scanActive&&out.size()>=cfg.boundingBoxMinPoints)adaptCenter(out);
    return out;
  }

  void lockFrom(PointCloud cloud){
    if(cloud==null||cloud.size()<cfg.boundingBoxMinPoints)return;
    int n=cloud.size();float[] xs=new float[n],ys=new float[n],zs=new float[n];int m=0;
    for(int i=0;i<n;i++){
      if(cloud.confidenceAt(i)<cfg.pointCloudMinimumConfidence)continue;
      PVector q=cloud.points.get(i);xs[m]=q.x;ys[m]=q.y;zs[m]=q.z;m++;
    }
    if(m<cfg.boundingBoxMinPoints)return;
    Arrays.sort(xs,0,m);Arrays.sort(ys,0,m);Arrays.sort(zs,0,m);
    int lo=constrain(round((m-1)*.035f),0,m-1),hi=constrain(round((m-1)*.965f),lo,m-1);
    float cx=(xs[lo]+xs[hi])*.5f,cy=(ys[lo]+ys[hi])*.5f,cz=(zs[lo]+zs[hi])*.5f;
    float width=constrain((xs[hi]-xs[lo])+2*cfg.boundingBoxMarginM,cfg.boundingBoxMinWidthM,cfg.boundingBoxMaxWidthM);
    float height=constrain((ys[hi]-ys[lo])+2*cfg.boundingBoxMarginM+cfg.boundingBoxBaseExtraM,cfg.boundingBoxMinHeightM,cfg.boundingBoxMaxHeightM);
    float depth=constrain((zs[hi]-zs[lo])+2*cfg.boundingBoxDepthMarginM,cfg.boundingBoxMinDepthM,cfg.boundingBoxMaxDepthM);
    minX=cx-width*.5f;maxX=cx+width*.5f;
    // +Y is down in Kinect camera space; reserve extra room below the object for
    // the rotating plate/visual markers, not for the entire support table.
    minY=cy-height*.5f-cfg.boundingBoxMarginM*.25f;
    maxY=cy+height*.5f+cfg.boundingBoxBaseExtraM*.50f;
    minZ=cz-depth*.5f;maxZ=cz+depth*.5f;
    locked=true;
  }

  void adaptCenter(PointCloud cloud){
    if(!locked||worldLocked||cfg.boundingBoxCenterFollowAlpha<=0||cloud==null||cloud.size()<cfg.boundingBoxMinPoints)return;
    int step=max(1,cloud.size()/900),n=0,cap=(cloud.size()+step-1)/step;
    float[] xs=new float[cap],ys=new float[cap],zs=new float[cap];
    for(int i=0;i<cloud.size();i+=step){PVector q=cloud.points.get(i);xs[n]=q.x;ys[n]=q.y;zs[n]=q.z;n++;}
    if(n<24)return;Arrays.sort(xs,0,n);Arrays.sort(ys,0,n);Arrays.sort(zs,0,n);
    float ox=(minX+maxX)*.5f,oy=(minY+maxY)*.5f,oz=(minZ+maxZ)*.5f;
    float nx=xs[n/2],ny=ys[n/2],nz=zs[n/2];
    float dx=constrain(nx-ox,-cfg.boundingBoxMaxCenterCorrectionM,cfg.boundingBoxMaxCenterCorrectionM);
    float dy=constrain(ny-oy,-cfg.boundingBoxMaxCenterCorrectionM,cfg.boundingBoxMaxCenterCorrectionM);
    float dz=constrain(nz-oz,-cfg.boundingBoxMaxCenterCorrectionM,cfg.boundingBoxMaxCenterCorrectionM);
    float a=cfg.boundingBoxCenterFollowAlpha;
    dx*=a;dy*=a;dz*=a;minX+=dx;maxX+=dx;minY+=dy;maxY+=dy;minZ+=dz;maxZ+=dz;
  }

  void lockWorldCube(RigidTransform pose){
    if(worldLocked||!locked||pose==null)return;
    PVector cameraCenter=new PVector((minX+maxX)*.5f,(minY+maxY)*.5f,(minZ+maxZ)*.5f);
    worldCenter=pose.apply(cameraCenter);
    float width=maxX-minX,height=maxY-minY,depth=maxZ-minZ;
    // Rotation-safe turntable cube: the horizontal diagonal guarantees that an
    // object fitting the idle ROI still fits after any yaw without enlarging Scan.
    float side=max(height,sqrt(width*width+depth*depth));
    // Keep a tiny numerical guard only; this is not an expanding margin.
    worldHalfSide=max(0.001f,side*.5005f);
    worldLocked=true;
  }

  PointCloud filterWorld(PointCloud input,RigidTransform pose){
    if(input==null)return new PointCloud();
    if(!cfg.boundingBoxEnabled||!worldLocked||pose==null)return input;
    PointCloud out=new PointCloud(max(16,input.size()));float h=worldHalfSide;
    for(int i=0;i<input.size();i++){
      PVector p=pose.apply(input.points.get(i));
      if(abs(p.x-worldCenter.x)>h||abs(p.y-worldCenter.y)>h||abs(p.z-worldCenter.z)>h)continue;
      out.add(input.points.get(i).copy(),input.colorAt(i),input.confidenceAt(i));
    }
    return out;
  }

  PVector displayCenter(){
    if(worldLocked)return worldCenter.copy();
    if(locked)return new PVector((minX+maxX)*.5f,(minY+maxY)*.5f,(minZ+maxZ)*.5f);
    return null;
  }
  float displayCubeSide(){
    if(worldLocked)return worldHalfSide*2.0f;
    if(!locked)return Float.NaN;
    float width=maxX-minX,height=maxY-minY,depth=maxZ-minZ;
    return max(height,sqrt(width*width+depth*depth));
  }
}


class SpatialHash {
  float cell;
  HashMap<Long, ArrayList<PVector>> buckets;
  SpatialHash(float cell,int expectedPoints) { this.cell = max(0.000001f, cell);buckets=new HashMap<Long,ArrayList<PVector>>(max(16,expectedPoints*2));
     }

  long key(int x,int y,int z) {
    long a=((long)x & 0x1FFFFF), b=((long)y & 0x1FFFFF), c=((long)z & 0x1FFFFF);
    return (a<<42)|(b<<21)|c;
  }
  int cellCoord(float v){ return floor(v/cell); }
  void add(PVector p) {
    long k=key(cellCoord(p.x),cellCoord(p.y),cellCoord(p.z)); ArrayList<PVector> list=buckets.get(k);

    if(list==null){ list=new ArrayList<PVector>(); buckets.put(k,list); } list.add(p);

  }

  PVector nearest(PVector p,float maxDist) {return p==null?null:nearest(p.x,p.y,p.z,maxDist);}
  PVector nearest(float px,float py,float pz,float maxDist) {
    int cx=cellCoord(px), cy=cellCoord(py), cz=cellCoord(pz);
    int radius=max(1, ceil(maxDist/cell));
    PVector best=null; float best2=maxDist*maxDist;
    for(int dz=-radius;dz<=radius;dz++) for(int dy=-radius;dy<=radius;dy++) for(int dx=-radius;dx<=radius;dx++) {
      ArrayList<PVector> list=buckets.get(key(cx+dx,cy+dy,cz+dz));
      if(list==null) continue;
      for(PVector q:list){float qx=px-q.x,qy=py-q.y,qz=pz-q.z,d2=qx*qx+qy*qy+qz*qz;
        if(d2<best2){best2=d2;best=q;}}
    }
    return best;
  }
}
