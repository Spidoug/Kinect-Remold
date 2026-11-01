// ===== SynKinect Studio / Core (shared by all modules) / FrameTypes.pde =====



// ===== SynKinect Studio / Core (shared by all modules) / Per-device depth calibration =====
// Metric depth correction learned from one flat wall observed at several distances.
// Geometry: every depth pixel owns one undistorted normalized ray (x,y) taken from
// Calibration.rays(), the same table RgbDepthRegistration uses at runtime. A plane is
// linear in inverse depth over those rays: 1/z = a*x + b*y + c. The correction is a
// smooth residual field in inverse depth R(u,v,1/z) stored on a coarse control grid
// times disparity bins (DepthCorrectionSolver) plus an optional absolute
// disparity gain/offset estimated from tape-measured reference distances.
class PlaneModel {
  float ax=0,by=0,c=Float.NaN,rms=Float.POSITIVE_INFINITY,rmsW=Float.POSITIVE_INFINITY,sigmaW=Float.NaN;int samples=0;
  boolean valid(){return Float.isFinite(c)&&c>0.05f&&samples>64;}
  float inverseDepthAt(float x,float y){return ax*x+by*y+c;}
  float depthAt(float x,float y){float w=ax*x+by*y+c;return w>1e-4f?1.0f/w:Float.NaN;}
  float centerDepthM(){return valid()?1.0f/c:Float.NaN;}
  // Inverse-depth RMS equals the metric RMS a plane at 1 m would show; distance independent.
  float rmsAt1m(){return rmsW;}
}

// Robust (Huber IRLS) plane fit in inverse depth over the calibration's undistorted rays.
PlaneModel fitCalibrationPlane(float[] depth,int width,int height,Calibration calibration){return fitCalibrationPlane(depth,width,height,calibration,3);}
PlaneModel fitCalibrationPlane(float[] depth,int width,int height,Calibration calibration,int step){
  PlaneModel out=new PlaneModel();if(depth==null||calibration==null||depth.length<width*height)return out;
  float[][] rays=calibration.rays();float[] rx=rays[0],ry=rays[1];if(rx==null||rx.length!=width*height)return out;
  int margin=max(2,min(width,height)/60);step=max(1,step);
  int cap=((height-2*margin)/step+1)*((width-2*margin)/step+1);float[] res=new float[max(16,cap)];
  double a=0,b=0,c=0,sigma=Double.NaN;boolean have=false;int n=0;
  for(int iter=0;iter<6;iter++){
    double sxx=0,sxy=0,sx=0,syy=0,sy=0,sw=0,sxw=0,syw=0,sww=0;n=0;
    for(int v=margin;v<height-margin;v+=step)for(int u=margin;u<width-margin;u+=step){int i=v*width+u;float z=depth[i];
      if(!(z>0.30f&&z<8.0f))continue;double x=rx[i],y=ry[i],w=1.0/z,wt=1.0;
      if(have){double r=Math.abs(w-(a*x+b*y+c));if(r>6.0*sigma)continue;double k=1.5*sigma;if(r>k)wt=k/r;}
      sxx+=wt*x*x;sxy+=wt*x*y;sx+=wt*x;syy+=wt*y*y;sy+=wt*y;sw+=wt;sxw+=wt*x*w;syw+=wt*y*w;sww+=wt*w;n++;}
    if(n<128)return out;
    double[][] m={{sxx,sxy,sx,sxw},{sxy,syy,sy,syw},{sx,sy,sw,sww}};
    for(int col=0;col<3;col++){int piv=col;for(int r=col+1;r<3;r++)if(Math.abs(m[r][col])>Math.abs(m[piv][col]))piv=r;
      if(Math.abs(m[piv][col])<1e-15)return out;double[] t=m[col];m[col]=m[piv];m[piv]=t;double d=m[col][col];
      for(int k=col;k<4;k++)m[col][k]/=d;for(int r=0;r<3;r++)if(r!=col){double f=m[r][col];for(int k=col;k<4;k++)m[r][k]-=f*m[col][k];}}
    a=m[0][3];b=m[1][3];c=m[2][3];have=true;
    int rn=0;for(int v=margin;v<height-margin;v+=step)for(int u=margin;u<width-margin;u+=step){int i=v*width+u;float z=depth[i];
      if(!(z>0.30f&&z<8.0f))continue;if(rn<res.length)res[rn++]=(float)Math.abs(1.0/z-(a*rx[i]+b*ry[i]+c));}
    float med=calibrationSelect(res,rn,rn/2);double s=Math.max(1e-5,1.4826*med);
    if(Double.isFinite(sigma)&&Math.abs(s-sigma)<0.02*sigma&&iter>=2){sigma=s;break;}sigma=s;
  }
  out.ax=(float)a;out.by=(float)b;out.c=(float)c;out.samples=n;out.sigmaW=(float)sigma;
  double e2=0,ew=0;int en=0;for(int v=margin;v<height-margin;v+=step)for(int u=margin;u<width-margin;u+=step){int i=v*width+u;float z=depth[i];
    if(!(z>0.30f&&z<8.0f))continue;double wp=a*rx[i]+b*ry[i]+c;if(wp<=1e-4)continue;double rw=1.0/z-wp;if(Math.abs(rw)>4.0*sigma)continue;
    double rz=z-1.0/wp;e2+=rz*rz;ew+=rw*rw;en++;}
  out.rms=en==0?Float.POSITIVE_INFINITY:(float)Math.sqrt(e2/en);out.rmsW=en==0?Float.POSITIVE_INFINITY:(float)Math.sqrt(ew/en);
  if(!(c>0.05))out.c=Float.NaN;
  return out;
}
// k-th smallest of the first n values (partially reorders the array).
float calibrationSelect(float[] a,int n,int k){if(n<=0)return 0;k=constrain(k,0,n-1);int lo=0,hi=n-1;
  while(lo<hi){float p=a[(lo+hi)>>>1];int i=lo,j=hi;while(i<=j){while(a[i]<p)i++;while(a[j]>p)j--;if(i<=j){float t=a[i];a[i]=a[j];a[j]=t;i++;j--;}}
    if(k<=j)hi=j;else if(k>=i)lo=i;else break;}return a[k];}
float medianCalibrationDepth(float[] depth,int width,int height){int x0=width*3/8,x1=width*5/8,y0=height*3/8,y1=height*5/8;
  float[] scratch=new float[(x1-x0)*(y1-y0)/16+64];int n=0;for(int y=y0;y<y1;y+=4)for(int x=x0;x<x1;x+=4){float z=depth[y*width+x];
    if(z>0){if(n>=scratch.length)scratch=Arrays.copyOf(scratch,scratch.length*2);scratch[n++]=z;}}if(n==0)return Float.NaN;return calibrationSelect(scratch,n,n/2);
  }

class CalibrationStation {
  final int width,height;final float[] meanM,sigmaM;final PlaneModel plane;final float centerDepthM;
  // sigmaW: noise of the per-pixel robust mean in inverse depth (1/m); drives the 1/sigma^2 station weight.
  float sigmaW=Float.NaN;int frames=0,validPixels=0;
  CalibrationStation(int width,int height,float[] meanM,float[] sigmaM,PlaneModel plane,float centerDepthM){this.width=width;
    this.height=height;this.meanM=meanM;this.sigmaM=sigmaM;this.plane=plane;this.centerDepthM=centerDepthM;
    }
}

// Collects raw frames of one station and reduces them to a robust per-pixel depth:
// trimmed temporal mean, dropout rejection, flying-pixel rejection by temporal spread
// and by spatial discontinuity.
class CalibrationAccumulator {
  final int width,height,capacity;final short[][] frames;int frameCount=0;
  CalibrationAccumulator(int width,int height){this(width,height,30);}
  CalibrationAccumulator(int width,int height,int capacity){this.width=width;this.height=height;this.capacity=max(3,capacity);frames=new short[this.capacity][];}
  void add(DepthFrame f){if(f==null||f.depth==null||frameCount>=capacity)return;frames[frameCount++]=Arrays.copyOf(f.depth,width*height);}
  CalibrationStation finish(Calibration calibration){return finish(calibration,null);}
  CalibrationStation finish(Calibration calibration,AppConfig cfg){
    int n=width*height;float[] mean=new float[n],sigma=new float[n];int[] vals=new int[max(1,frameCount)];
    float trim=cfg==null?0.20f:cfg.calibrationTrimFraction,floorM=cfg==null?0.0015f:cfg.calibrationNoiseFloorM,flyK=cfg==null?6.0f:cfg.calibrationFlyingPixelSigma;
    int minCount=max(3,(int)Math.ceil(frameCount*0.6));
    for(int i=0;i<n;i++){int c=0;for(int f=0;f<frameCount;f++){int mm=frames[f][i]&0xffff;if(mm>0)vals[c++]=mm;}
      if(c<minCount)continue;
      for(int p=1;p<c;p++){int x=vals[p],q=p-1;while(q>=0&&vals[q]>x){vals[q+1]=vals[q];q--;}vals[q+1]=x;}
      int lo=(int)Math.floor(c*trim),hi=c-lo;if(hi-lo<2){lo=0;hi=c;}
      double s=0,s2=0;for(int p=lo;p<hi;p++){s+=vals[p];s2+=(double)vals[p]*vals[p];}int m=hi-lo;double mu=s/m,var=Math.max(0,s2/m-mu*mu);
      double iqr=(vals[(3*c)/4]-vals[c/4])/1.349,sd=Math.max(Math.sqrt(var),iqr)*0.001;double z=mu*0.001;
      double expected=floorM*(0.55+0.45*z*z);
      if(sd>flyK*expected||(vals[c-1]-vals[0])*0.001>0.25*z)continue;
      mean[i]=(float)z;sigma[i]=(float)Math.max(sd,1e-4);}
    // Spatial flying pixels: depth discontinuities larger than 5% of range are not wall samples.
    float[] out=Arrays.copyOf(mean,n);
    for(int v=1;v<height-1;v++)for(int u=1;u<width-1;u++){int i=v*width+u;float z=mean[i];if(z<=0)continue;float lim=0.05f*z+0.01f;
      int[] nb={i-1,i+1,i-width,i+width};for(int j:nb){float q=mean[j];if(q>0&&Math.abs(q-z)>lim){out[i]=0;break;}}}
    int valid=0;for(int i=0;i<n;i++)if(out[i]>0)valid++;else sigma[i]=0;
    PlaneModel plane=fitCalibrationPlane(out,width,height,calibration,2);
    float center=plane.valid()?plane.centerDepthM():medianCalibrationDepth(out,width,height);
    CalibrationStation st=new CalibrationStation(width,height,out,sigma,plane,center);st.frames=frameCount;st.validPixels=valid;
    float[] sw=new float[max(16,valid/7+16)];int k=0;for(int i=0;i<n;i+=7){float z=out[i];if(z>0&&k<sw.length)sw[k++]=sigma[i]/(z*z);}
    float medSigmaW=k==0?1e-3f:calibrationSelect(sw,k,k/2);
    // Temporal mean noise plus a floor for residual quantisation/speckle bias that averaging cannot remove.
    st.sigmaW=(float)Math.sqrt(medSigmaW*medSigmaW/max(1,frameCount)+2.5e-7);
    return st;
  }
}

class DepthCorrectionProfile {
  static final int MODEL_LEGACY_AFFINE=1,MODEL_DISPARITY_GRID=2;
  final String deviceId;final int width,height;final float[] scale,offsetM,noiseM;
  String deviceKey="";int modelType=MODEL_LEGACY_AFFINE;
  boolean calibrated=false;float coverage=0,trainingRmsBeforeMm=Float.NaN,trainingRmsAfterMm=Float.NaN,validationRmsBeforeMm=Float.NaN,validationRmsAfterMm=Float.NaN;
  long createdEpochMs=System.currentTimeMillis();
  // Distance-aware grid model (MODEL_DISPARITY_GRID). grid holds the inverse-depth residual
  // (1/m) at control nodes [bin][gy][gx]; w0..w1 is the measured inverse-depth range of bins.
  int gridX=0,gridY=0,bins=0;float w0=0,w1=0,regularization=Float.NaN;float[] grid=null;
  // Absolute model: 1/z_true = disparityGain * (1/z_corrected) + disparityOffset. Scale = 1/gain.
  float disparityGain=1.0f,disparityOffset=0.0f,referenceRmsMm=Float.NaN;int referenceCount=0;
  long intrinsicsHash=0L;
  // Per station (leave-one-station-out planarity metrics, mm) and centre distances (m).
  float[] stationCenterM=new float[0],stationRawCenterM=new float[0],stationReferenceM=new float[0];
  float[] stationRmsBeforeMm=new float[0],stationRmsAfterMm=new float[0],stationMaeBeforeMm=new float[0],stationMaeAfterMm=new float[0],stationP95BeforeMm=new float[0],stationP95AfterMm=new float[0];
  transient float[] pixelBins=null;transient float invBinWidth=0;

  DepthCorrectionProfile(String deviceId,int width,int height){this.deviceId=deviceId==null?"":deviceId;
    this.width=width;this.height=height;int n=width*height;scale=new float[n];offsetM=new float[n];
    noiseM=new float[n];Arrays.fill(scale,1.0f);Arrays.fill(noiseM,0.004f);}
  boolean gridModel(){return modelType==MODEL_DISPARITY_GRID&&grid!=null&&pixelBins!=null;}
  float globalScale(){return disparityGain>1e-6f?1.0f/disparityGain:1.0f;}
  int correctMm(int index,int rawMm){if(rawMm<=0||index<0||index>=scale.length)return rawMm;
    if(modelType==MODEL_DISPARITY_GRID){float[] lut=pixelBins;if(lut==null)return rawMm;int n=width*height;
      float w=1000.0f/rawMm,t=(w-w0)*invBinWidth;if(t<0)t=0;else if(t>bins-1)t=bins-1;int b=(int)t;if(b>bins-2)b=bins-2;float f=t-b;
      float wc=(w+lut[b*n+index]*(1-f)+lut[(b+1)*n+index]*f)*disparityGain+disparityOffset;if(!(wc>1e-4f))return rawMm;
      return constrain(round(1000.0f/wc),1,10000);}
    float m=rawMm*0.001f*scale[index]+offsetM[index];return constrain(round(m*1000.0f),1,10000);
    }
  // Grid residual (1/m) at fractional pixel (u,v) and measured inverse depth w (bilinear in u,v; linear in w).
  float residualAt(float u,float v,float w){if(grid==null)return 0;float tu=u*(gridX-1)/(float)max(1,width-1),tv=v*(gridY-1)/(float)max(1,height-1);
    tu=constrain(tu,0,gridX-1);tv=constrain(tv,0,gridY-1);int iu=min((int)tu,gridX-2),iv=min((int)tv,gridY-2);float fu=tu-iu,fv=tv-iv;
    float tb=constrain((w-w0)/max(1e-6f,w1-w0)*(bins-1),0,bins-1);int ib=min((int)tb,bins-2);float fb=tb-ib;float r=0;
    for(int db=0;db<2;db++){float wb=db==0?1-fb:fb;int base=(ib+db)*gridY;
      r+=wb*((1-fv)*((1-fu)*grid[(base+iv)*gridX+iu]+fu*grid[(base+iv)*gridX+iu+1])+fv*((1-fu)*grid[(base+iv+1)*gridX+iu]+fu*grid[(base+iv+1)*gridX+iu+1]));}
    return r;}
  // Builds the per-pixel bin LUT used by correctMm and a local affine approximation
  // (scale/offsetM) over the calibrated range for SDK consumers of StudioDepthCalibration.
  void prepareRuntime(){if(modelType!=MODEL_DISPARITY_GRID||grid==null||bins<2)return;int n=width*height;float[] lut=new float[bins*n];
    for(int b=0;b<bins;b++){float w=w0+(w1-w0)*b/(float)(bins-1);for(int v=0;v<height;v++)for(int u=0;u<width;u++)lut[b*n+v*width+u]=residualAt(u,v,w);}
    invBinWidth=(bins-1)/max(1e-6f,w1-w0);pixelBins=lut;
    int K=6;float[] zs=new float[K];for(int k=0;k<K;k++)zs[k]=1.0f/(w1-(w1-w0)*k/(float)(K-1));
    for(int i=0;i<n;i++){double sx=0,sy=0,sxx=0,sxy=0;int c=0;for(int k=0;k<K;k++){int mm=round(zs[k]*1000);int cm=correctMm(i,mm);double x=mm*0.001,y=cm*0.001;sx+=x;sy+=y;sxx+=x*x;sxy+=x*y;c++;}
      double den=c*sxx-sx*sx;if(Math.abs(den)<1e-12)continue;double a=(c*sxy-sx*sy)/den;scale[i]=(float)a;offsetM[i]=(float)((sy-a*sx)/c);}
  }
  float noiseAt(int index,float depthM,AppConfig cfg){float empirical=(index>=0&&index<noiseM.length)?noiseM[index]:cfg.calibrationNoiseFloorM;
    float z=max(0.35f,depthM);float range=cfg.calibrationNoiseFloorM*(0.55f+0.45f*z*z);
    return constrain(max(empirical,range),cfg.calibrationNoiseFloorM,cfg.calibrationNoiseCeilingM);
    }
  float confidenceAt(int index,float depthM,AppConfig cfg){float sigma=noiseAt(index,depthM,cfg);
    return constrain(cfg.calibrationNoiseFloorM/max(cfg.calibrationNoiseFloorM,sigma),0.20f,1.0f);
    }
  DepthCorrectionProfile fit(ArrayList<CalibrationStation> stations,Calibration calibration,AppConfig cfg){
    return new DepthCorrectionSolver(cfg,calibration).fit(stations,deviceId,deviceKey);}

  // Absolute reference. Each tape-measured distance (m, sensor to wall along the optical
  // axis) is matched to the captured station with the nearest centre distance; stations
  // then fix the disparity gain (one reference, z_true = s*z) or gain+offset (two or more
  // references spanning >= 0.25 1/m). Returns matched count, 0 = cleared, -1 = rejected.
  int applyReferences(float[] referencesM,AppConfig cfg){
    int s=stationCenterM.length;stationReferenceM=new float[s];Arrays.fill(stationReferenceM,Float.NaN);disparityGain=1;disparityOffset=0;referenceCount=0;referenceRmsMm=Float.NaN;
    if(referencesM==null||referencesM.length==0||s==0){prepareRuntime();return 0;}
    float tol=cfg==null?0.12f:cfg.calibrationReferenceMatchTolerance,maxErr=cfg==null?0.10f:cfg.calibrationReferenceMaxScaleError;
    for(float ref:referencesM){if(!(ref>0.2f&&ref<10f))continue;int best=-1;float bestErr=Float.POSITIVE_INFINITY;
      for(int i=0;i<s;i++){if(!Float.isNaN(stationReferenceM[i])||!(stationCenterM[i]>0))continue;float e=Math.abs(stationCenterM[i]/ref-1);if(e<bestErr){bestErr=e;best=i;}}
      if(best>=0&&bestErr<=tol){stationReferenceM[best]=ref;referenceCount++;}}
    if(referenceCount==0){prepareRuntime();return 0;}
    double swc=0,swt=0,scc=0,sct=0,wMin=1e9,wMax=-1e9;int n=0;
    for(int i=0;i<s;i++){if(Float.isNaN(stationReferenceM[i]))continue;double wc=1.0/stationCenterM[i],wt=1.0/stationReferenceM[i];swc+=wc;swt+=wt;scc+=wc*wc;sct+=wc*wt;n++;wMin=Math.min(wMin,wc);wMax=Math.max(wMax,wc);}
    double gain,off=0;if(n>=2&&wMax-wMin>=0.25){double den=n*scc-swc*swc;gain=(n*sct-swc*swt)/den;off=(swt-gain*swc)/n;}else gain=sct/scc;
    double scaleValue=1.0/gain;if(!(Math.abs(scaleValue-1)<=maxErr)||Math.abs(off)>0.08){Arrays.fill(stationReferenceM,Float.NaN);referenceCount=0;prepareRuntime();return -1;}
    disparityGain=(float)gain;disparityOffset=(float)off;
    double e2=0;for(int i=0;i<s;i++){if(Float.isNaN(stationReferenceM[i]))continue;double z=1.0/(gain/stationCenterM[i]+off);e2+=(z-stationReferenceM[i])*(z-stationReferenceM[i]);}
    referenceRmsMm=(float)(Math.sqrt(e2/n)*1000.0);prepareRuntime();return referenceCount;
  }
  float stationCenterAfterM(int i){if(i<0||i>=stationCenterM.length)return Float.NaN;return 1.0f/(disparityGain/stationCenterM[i]+disparityOffset);}
}

// Weighted least squares for the residual field on a control lattice gridX*gridY*bins with
// Laplacian (second-difference) plus weak membrane (first-difference) smoothness in u, v
// and along the disparity axis. Samples are aggregated into per-station 27-point normal
// equations once, so leave-one-station-out validation only subtracts one station's system.
class DepthCorrectionSolver {
  final AppConfig cfg;final Calibration cal;int W,H,GX,GY,B,nodes;float w0,w1;
  int[] iuTab,ivTab;float[] fuTab,fvTab;final int[][] cornerOffset=new int[8][8];
  long cgIterations=0;
  DepthCorrectionSolver(AppConfig cfg,Calibration cal){this.cfg=cfg;this.cal=cal;
    for(int a=0;a<8;a++)for(int b=0;b<8;b++){int dx=(b&1)-(a&1),dy=((b>>1)&1)-((a>>1)&1),db=((b>>2)&1)-((a>>2)&1);cornerOffset[a][b]=(db+1)*9+(dy+1)*3+(dx+1);}}
  class NormalSystem {final double[] ata=new double[nodes*27],atb=new double[nodes];double weight=0;long samples=0;}
  int node(int ix,int iy,int ib){return (ib*GY+iy)*GX+ix;}

  DepthCorrectionProfile fit(ArrayList<CalibrationStation> stations,String deviceId,String deviceKey){
    if(stations==null||stations.size()<3)throw new IllegalArgumentException("at least three calibration stations are required");
    CalibrationStation first=stations.get(0);W=first.width;H=first.height;int n=W*H;
    float[][] rays=cal.rays();if(rays[0]==null||rays[0].length!=n)throw new IllegalStateException("depth geometry does not match calibration frames");
    GX=max(4,cfg==null?40:cfg.calibrationGridX);GY=max(3,cfg==null?30:cfg.calibrationGridY);B=max(2,cfg==null?8:cfg.calibrationDepthBins);nodes=GX*GY*B;
    iuTab=new int[W];fuTab=new float[W];ivTab=new int[H];fvTab=new float[H];
    for(int u=0;u<W;u++){float t=u*(GX-1)/(float)(W-1);int i=min((int)t,GX-2);iuTab[u]=i;fuTab[u]=t-i;}
    for(int v=0;v<H;v++){float t=v*(GY-1)/(float)(H-1);int i=min((int)t,GY-2);ivTab[v]=i;fvTab[v]=t-i;}
    // Inverse-depth range covered by the stations (robust percentiles).
    float[] ws=new float[stations.size()*(n/11+2)];int wn=0;for(CalibrationStation st:stations)for(int i=0;i<n;i+=11){float z=st.meanM[i];if(z>0&&wn<ws.length)ws[wn++]=1.0f/z;}
    if(wn<100)throw new IllegalStateException("insufficient calibration samples");
    float lo=calibrationSelect(ws,wn,(int)(wn*0.005f)),hi=calibrationSelect(ws,wn,(int)(wn*0.995f));float pad=(hi-lo)*0.02f+1e-3f;w0=lo-pad;w1=hi+pad;
    int S=stations.size();NormalSystem[] sys=new NormalSystem[S];boolean[][] inlier=new boolean[S][];int[] validCount=new int[n];double[] noiseSum=new double[n];
    for(int s=0;s<S;s++){CalibrationStation st=stations.get(s);if(!st.plane.valid())throw new IllegalStateException("invalid calibration plane at station "+(s+1));
      inlier[s]=inlierMask(st,rays);sys[s]=accumulate(st,inlier[s],rays);
      for(int i=0;i<n;i++)if(inlier[s][i]){validCount[i]++;noiseSum[i]+=st.sigmaM[i];}}
    NormalSystem total=new NormalSystem();for(NormalSystem ns:sys){for(int i=0;i<total.ata.length;i++)total.ata[i]+=ns.ata[i];for(int i=0;i<nodes;i++)total.atb[i]+=ns.atb[i];total.weight+=ns.weight;total.samples+=ns.samples;}
    double meanDiag=0;int dn=0;for(int i=0;i<nodes;i++){double d=total.ata[i*27+13];if(d>0){meanDiag+=d;dn++;}}meanDiag=dn==0?1:meanDiag/dn;
    // Regularisation: fixed from configuration, or chosen by leave-one-station-out planarity error.
    float[] candidates=(cfg!=null&&cfg.calibrationRegularization>0)?new float[]{cfg.calibrationRegularization}:new float[]{0.03f,0.3f,3.0f};
    float bestRho=candidates[0];double bestScore=Double.POSITIVE_INFINITY;double[][] bestStats=null;double[] x=null,warm=null;
    for(float rho:candidates){final double[][] stats=new double[S][];double score=0;long cnt=0;final double[] full=solve(total,null,rho*meanDiag,warm);warm=full;
      final double lam=rho*meanDiag;final NormalSystem tot=total;final NormalSystem[] sy=sys;final boolean[][] in=inlier;final ArrayList<CalibrationStation> sts=stations;
      // Leave-one-station-out folds are independent: solve them in parallel.
      java.util.stream.IntStream.range(0,S).parallel().forEach(new java.util.function.IntConsumer(){public void accept(int s){stats[s]=evaluate(sts.get(s),in[s],solve(tot,sy[s],lam,full),rays);}});
      for(int s=0;s<S;s++){score+=stats[s][6]*stats[s][1]*stats[s][1];cnt+=(long)stats[s][6];}
      score=cnt==0?Double.POSITIVE_INFINITY:score/cnt;if(score<bestScore){bestScore=score;bestRho=rho;bestStats=stats;x=full;}}
    DepthCorrectionProfile p=new DepthCorrectionProfile(deviceId,W,H);p.deviceKey=deviceKey==null?"":deviceKey;p.modelType=DepthCorrectionProfile.MODEL_DISPARITY_GRID;
    p.gridX=GX;p.gridY=GY;p.bins=B;p.w0=w0;p.w1=w1;p.regularization=bestRho;p.grid=new float[nodes];for(int i=0;i<nodes;i++)p.grid[i]=(float)x[i];
    p.intrinsicsHash=cal.geometryHash;int minStations=cfg==null?3:min(cfg.calibrationMinimumStationsPerPixel,S);int covered=0;
    float nf=cfg==null?0.0015f:cfg.calibrationNoiseFloorM,nc=cfg==null?0.03f:cfg.calibrationNoiseCeilingM;
    for(int i=0;i<n;i++){if(validCount[i]>0)p.noiseM[i]=constrain((float)(noiseSum[i]/validCount[i]),nf,nc);if(validCount[i]>=minStations)covered++;}
    p.coverage=covered/(float)n;p.calibrated=p.coverage>=0.35f;
    p.stationCenterM=new float[S];p.stationRawCenterM=new float[S];p.stationReferenceM=new float[S];Arrays.fill(p.stationReferenceM,Float.NaN);
    p.stationRmsBeforeMm=new float[S];p.stationRmsAfterMm=new float[S];p.stationMaeBeforeMm=new float[S];p.stationMaeAfterMm=new float[S];p.stationP95BeforeMm=new float[S];p.stationP95AfterMm=new float[S];
    double vb=0,va=0,tb=0,ta=0;long vn=0,tn=0;final double[][] train=new double[S][];final double[] xf=x;final boolean[][] in2=inlier;final ArrayList<CalibrationStation> sts2=stations;
    java.util.stream.IntStream.range(0,S).parallel().forEach(new java.util.function.IntConsumer(){public void accept(int s){train[s]=evaluate(sts2.get(s),in2[s],xf,rays);}});
    for(int s=0;s<S;s++){CalibrationStation st=stations.get(s);double[] e=bestStats[s];
      p.stationRmsBeforeMm[s]=(float)e[0];p.stationRmsAfterMm[s]=(float)e[1];p.stationMaeBeforeMm[s]=(float)e[2];p.stationMaeAfterMm[s]=(float)e[3];p.stationP95BeforeMm[s]=(float)e[4];p.stationP95AfterMm[s]=(float)e[5];
      vb+=e[6]*e[0]*e[0];va+=e[6]*e[1]*e[1];vn+=(long)e[6];
      double[] t=train[s];tb+=t[6]*t[0]*t[0];ta+=t[6]*t[1]*t[1];tn+=(long)t[6];
      p.stationRawCenterM[s]=st.plane.centerDepthM();p.stationCenterM[s]=(float)t[7];}
    if(vn>0){p.validationRmsBeforeMm=(float)Math.sqrt(vb/vn);p.validationRmsAfterMm=(float)Math.sqrt(va/vn);}
    if(tn>0){p.trainingRmsBeforeMm=(float)Math.sqrt(tb/tn);p.trainingRmsAfterMm=(float)Math.sqrt(ta/tn);}
    p.prepareRuntime();
    if(!p.calibrated)throw new IllegalStateException("insufficient calibrated-pixel coverage: "+p.coverage);
    return p;
  }
  boolean[] inlierMask(CalibrationStation st,float[][] rays){int n=W*H;boolean[] m=new boolean[n];float[] r=new float[n];int k=0;PlaneModel pl=st.plane;
    for(int i=0;i<n;i++){float z=st.meanM[i];if(z>0)r[k++]=Math.abs(1.0f/z-pl.inverseDepthAt(rays[0][i],rays[1][i]));}
    float cut=max(6.0f*1.4826f*calibrationSelect(r,k,k/2),3.0f*st.sigmaW);
    for(int i=0;i<n;i++){float z=st.meanM[i];if(z>0)m[i]=Math.abs(1.0f/z-pl.inverseDepthAt(rays[0][i],rays[1][i]))<=cut;}return m;}
  NormalSystem accumulate(CalibrationStation st,boolean[] mask,float[][] rays){NormalSystem ns=new NormalSystem();double omega=1.0/Math.max(1e-10,(double)st.sigmaW*st.sigmaW);
    float[] phi=new float[8];int[] idx=new int[8];PlaneModel pl=st.plane;float binScale=(B-1)/(w1-w0);
    for(int v=0;v<H;v++)for(int u=0;u<W;u++){int i=v*W+u;if(!mask[i])continue;float w=1.0f/st.meanM[i],r=pl.inverseDepthAt(rays[0][i],rays[1][i])-w;
      float tb=constrain((w-w0)*binScale,0,B-1);int ib=min((int)tb,B-2);float fb=tb-ib,fu=fuTab[u],fv=fvTab[v];int iu=iuTab[u],iv=ivTab[v];
      for(int c=0;c<8;c++){int dx=c&1,dy=(c>>1)&1,db=(c>>2)&1;phi[c]=(dx==0?1-fu:fu)*(dy==0?1-fv:fv)*(db==0?1-fb:fb);idx[c]=node(iu+dx,iv+dy,ib+db);}
      for(int a=0;a<8;a++){double pa=omega*phi[a];if(pa==0)continue;int base=idx[a]*27;ns.atb[idx[a]]+=pa*r;for(int b=0;b<8;b++)ns.ata[base+cornerOffset[a][b]]+=pa*phi[b];}
      ns.weight+=omega;ns.samples++;}
    return ns;}
  // y = (A_total - A_excluded + R) x
  void apply(NormalSystem total,NormalSystem ex,double lam,double[] x,double[] y){
    int plane=GX*GY;
    for(int i=0;i<nodes;i++){int ix=i%GX,iy=(i/GX)%GY,ib=i/plane;double acc=0;int base=i*27;
      for(int k=0;k<27;k++){double a=total.ata[base+k];if(ex!=null)a-=ex.ata[base+k];if(a==0)continue;int dx=k%3-1,dy=(k/3)%3-1,db=k/9-1;
        acc+=a*x[node(ix+dx,iy+dy,ib+db)];}
      y[i]=acc+lam*1e-6*x[i];}
    double l2=lam,l1=lam*0.05;
    for(int ib=0;ib<B;ib++)for(int iy=0;iy<GY;iy++)for(int ix=0;ix<GX;ix++){int i=node(ix,iy,ib);
      if(ix+1<GX){int j=i+1;double d=l1*(x[j]-x[i]);y[i]-=d;y[j]+=d;}
      if(iy+1<GY){int j=i+GX;double d=l1*(x[j]-x[i]);y[i]-=d;y[j]+=d;}
      if(ib+1<B){int j=i+plane;double d=l1*(x[j]-x[i]);y[i]-=d;y[j]+=d;}
      if(ix+2<GX){int j=i+1,k=i+2;double d=l2*(x[i]-2*x[j]+x[k]);y[i]+=d;y[j]-=2*d;y[k]+=d;}
      if(iy+2<GY){int j=i+GX,k=i+2*GX;double d=l2*(x[i]-2*x[j]+x[k]);y[i]+=d;y[j]-=2*d;y[k]+=d;}
      if(ib+2<B){int j=i+plane,k=i+2*plane;double d=l2*(x[i]-2*x[j]+x[k]);y[i]+=d;y[j]-=2*d;y[k]+=d;}}
  }
  // Jacobi-preconditioned conjugate gradient.
  double[] solve(NormalSystem total,NormalSystem ex,double lam,double[] warm){
    double[] x=warm==null?new double[nodes]:warm.clone(),r=new double[nodes],z=new double[nodes],p=new double[nodes],q=new double[nodes],diag=new double[nodes];
    int plane=GX*GY;
    for(int i=0;i<nodes;i++){int ix=i%GX,iy=(i/GX)%GY,ib=i/plane;double d=total.ata[i*27+13]-(ex==null?0:ex.ata[i*27+13])+lam*1e-6;
      int nu=(ix>0?1:0)+(ix<GX-1?1:0),nv=(iy>0?1:0)+(iy<GY-1?1:0),nb=(ib>0?1:0)+(ib<B-1?1:0);d+=lam*0.05*(nu+nv+nb);
      d+=lam*(secondDiag(ix,GX)+secondDiag(iy,GY)+secondDiag(ib,B));diag[i]=Math.max(d,1e-30);}
    apply(total,ex,lam,x,q);double bn=0;for(int i=0;i<nodes;i++){double b=total.atb[i]-(ex==null?0:ex.atb[i]);r[i]=b-q[i];bn+=b*b;}
    bn=Math.sqrt(Math.max(bn,1e-300));double rz=0;for(int i=0;i<nodes;i++){z[i]=r[i]/diag[i];p[i]=z[i];rz+=r[i]*z[i];}
    for(int it=0;it<400;it++){double rn=0;for(double v:r)rn+=v*v;if(Math.sqrt(rn)<=1e-5*bn)break;cgIterations++;apply(total,ex,lam,p,q);double pq=0;for(int i=0;i<nodes;i++)pq+=p[i]*q[i];if(pq<=0)break;
      double alpha=rz/pq;for(int i=0;i<nodes;i++){x[i]+=alpha*p[i];r[i]-=alpha*q[i];}double rz2=0;for(int i=0;i<nodes;i++){z[i]=r[i]/diag[i];rz2+=r[i]*z[i];}
      double beta=rz2/rz;rz=rz2;for(int i=0;i<nodes;i++)p[i]=z[i]+beta*p[i];}
    return x;}
  double secondDiag(int i,int n){double d=0;if(i+2<n)d+=1;if(i-1>=0&&i+1<n)d+=4;if(i-2>=0)d+=1;return d;}
  float residual(double[] x,int u,int v,float w){float tb=constrain((w-w0)*(B-1)/(w1-w0),0,B-1);int ib=min((int)tb,B-2);float fb=tb-ib,fu=fuTab[u],fv=fvTab[v];int iu=iuTab[u],iv=ivTab[v];double r=0;
    for(int c=0;c<8;c++){int dx=c&1,dy=(c>>1)&1,db=(c>>2)&1;r+=(dx==0?1-fu:fu)*(dy==0?1-fv:fv)*(db==0?1-fb:fb)*x[node(iu+dx,iv+dy,ib+db)];}return (float)r;}
  // Planarity of one station before/after applying x: {rmsB,rmsA,maeB,maeA,p95B,p95A,count,correctedCentreM}.
  double[] evaluate(CalibrationStation st,boolean[] mask,double[] x,float[][] rays){int n=W*H;float[] corr=new float[n];
    for(int v=0;v<H;v++)for(int u=0;u<W;u++){int i=v*W+u;if(!mask[i])continue;float w=1.0f/st.meanM[i];float wc=w+residual(x,u,v,w);if(wc>1e-4f)corr[i]=1.0f/wc;}
    PlaneModel after=fitCalibrationPlane(corr,W,H,cal,2);PlaneModel before=st.plane;
    float[] eb=new float[n],ea=new float[n];int k=0;double sb=0,sa=0,mb=0,ma=0;
    for(int i=0;i<n;i+=2){if(!mask[i]||corr[i]<=0)continue;float zb=before.depthAt(rays[0][i],rays[1][i]),za=after.valid()?after.depthAt(rays[0][i],rays[1][i]):Float.NaN;if(!Float.isFinite(zb)||!Float.isFinite(za))continue;
      float db=Math.abs(st.meanM[i]-zb)*1000,da=Math.abs(corr[i]-za)*1000;eb[k]=db;ea[k]=da;k++;sb+=db*db;sa+=da*da;mb+=db;ma+=da;}
    if(k==0)return new double[]{Double.NaN,Double.NaN,Double.NaN,Double.NaN,Double.NaN,Double.NaN,0,st.centerDepthM};
    int q=(int)(k*0.95);return new double[]{Math.sqrt(sb/k),Math.sqrt(sa/k),mb/k,ma/k,calibrationSelect(eb,k,q),calibrationSelect(ea,k,q),k,after.valid()?after.centerDepthM():st.centerDepthM};}
}

class DepthCalibrationStore {
  static final int MAGIC=0x314C4143,VERSION=3,LEGACY_VERSION=2;
  File root(){return studio.services.paths.dataDirectory("core/rgbd","calibration","calibration");
    }
  String safeId(String id){String s=id==null?"kinect":id.replaceAll("[^A-Za-z0-9._-]","_");
    if(s.length()>80)s=s.substring(0,64)+"_"+Integer.toHexString(id.hashCode());return s;
    }
  KinectDevice deviceFor(String id){try{return id==null||id.isEmpty()||studio.services.devices==null?null:studio.services.devices.byId(id);}catch(Exception e){return null;}}
  // Profiles are keyed by the Studio registry key (module:id), falling back to the legacy bare id.
  String keyFor(String id){KinectDevice d=deviceFor(id);return d!=null?d.registryKey():(id==null?"":id);}
  String legacyIdFor(String id){KinectDevice d=deviceFor(id);return d!=null?d.id:(id==null?"":id);}
  File fileFor(String id){return new File(root(),safeId(id)+".depthcal");}
  boolean delete(String id){boolean ok=true;for(String k:new String[]{keyFor(id),legacyIdFor(id)}){File f=fileFor(k);if(f.exists()&&!f.delete())ok=false;}return ok;}
  void save(DepthCorrectionProfile p)throws IOException{File dir=root();if(!dir.exists()&&!dir.mkdirs())throw new IOException("cannot create calibration directory: "+dir);
    String key=p.deviceKey==null||p.deviceKey.isEmpty()?keyFor(p.deviceId):p.deviceKey;
    File target=fileFor(key),tmp=new File(target.getAbsolutePath()+".tmp");
    try(DataOutputStream out=new DataOutputStream(new BufferedOutputStream(new FileOutputStream(tmp)))){
      if(p.modelType!=DepthCorrectionProfile.MODEL_DISPARITY_GRID){writeLegacy(out,p);}else{
      out.writeInt(MAGIC);out.writeInt(VERSION);out.writeUTF(key);out.writeUTF(p.deviceId);out.writeInt(p.width);out.writeInt(p.height);
      out.writeLong(p.createdEpochMs);out.writeBoolean(p.calibrated);out.writeFloat(p.coverage);
      out.writeFloat(p.trainingRmsBeforeMm);out.writeFloat(p.trainingRmsAfterMm);out.writeFloat(p.validationRmsBeforeMm);out.writeFloat(p.validationRmsAfterMm);
      out.writeInt(p.modelType);out.writeInt(p.gridX);out.writeInt(p.gridY);out.writeInt(p.bins);out.writeFloat(p.w0);out.writeFloat(p.w1);out.writeFloat(p.regularization);
      out.writeFloat(p.disparityGain);out.writeFloat(p.disparityOffset);out.writeInt(p.referenceCount);out.writeFloat(p.referenceRmsMm);out.writeLong(p.intrinsicsHash);
      int s=p.stationCenterM.length;out.writeInt(s);for(int i=0;i<s;i++){out.writeFloat(p.stationCenterM[i]);out.writeFloat(p.stationRawCenterM[i]);out.writeFloat(p.stationReferenceM[i]);
        out.writeFloat(p.stationRmsBeforeMm[i]);out.writeFloat(p.stationRmsAfterMm[i]);out.writeFloat(p.stationMaeBeforeMm[i]);out.writeFloat(p.stationMaeAfterMm[i]);out.writeFloat(p.stationP95BeforeMm[i]);out.writeFloat(p.stationP95AfterMm[i]);}
      for(float v:p.grid)out.writeFloat(v);for(float v:p.noiseM)out.writeFloat(v);}}
    try{Files.move(tmp.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);
      }catch(AtomicMoveNotSupportedException e){Files.move(tmp.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING);}
    String legacy=legacyIdFor(p.deviceId);if(!safeId(legacy).equals(safeId(key))){File old=fileFor(legacy);if(old.exists())old.delete();}
    }
  void writeLegacy(DataOutputStream out,DepthCorrectionProfile p)throws IOException{out.writeInt(MAGIC);
      out.writeInt(LEGACY_VERSION);out.writeUTF(p.deviceId);out.writeInt(p.width);out.writeInt(p.height);
      out.writeLong(p.createdEpochMs);out.writeBoolean(p.calibrated);out.writeFloat(p.coverage);
      out.writeFloat(p.trainingRmsBeforeMm);out.writeFloat(p.trainingRmsAfterMm);out.writeFloat(p.validationRmsBeforeMm);out.writeFloat(p.validationRmsAfterMm);
      for(float v:p.scale)out.writeFloat(v);for(float v:p.offsetM)out.writeFloat(v);for(float v:p.noiseM)out.writeFloat(v);}
  DepthCorrectionProfile load(String id,int width,int height){String key=keyFor(id),legacy=legacyIdFor(id);
    DepthCorrectionProfile p=loadFile(fileFor(key),id,key,legacy,width,height);if(p==null&&!safeId(legacy).equals(safeId(key)))p=loadFile(fileFor(legacy),id,key,legacy,width,height);return p;}
  DepthCorrectionProfile loadFile(File f,String id,String key,String legacy,int width,int height){
    if(!f.isFile())return null;try(DataInputStream in=new DataInputStream(new BufferedInputStream(new FileInputStream(f)))){if(in.readInt()!=MAGIC)return null;int version=in.readInt();
      if(version==LEGACY_VERSION){String stored=in.readUTF();int w=in.readInt(),h=in.readInt();if(!(Objects.equals(stored,id)||Objects.equals(stored,legacy))||w!=width||h!=height)return null;
        DepthCorrectionProfile p=new DepthCorrectionProfile(stored,w,h);p.deviceKey=key;p.modelType=DepthCorrectionProfile.MODEL_LEGACY_AFFINE;p.createdEpochMs=in.readLong();
        p.calibrated=in.readBoolean();p.coverage=in.readFloat();p.trainingRmsBeforeMm=in.readFloat();p.trainingRmsAfterMm=in.readFloat();
        p.validationRmsBeforeMm=in.readFloat();p.validationRmsAfterMm=in.readFloat();for(int i=0;i<p.scale.length;i++)p.scale[i]=in.readFloat();
        for(int i=0;i<p.offsetM.length;i++)p.offsetM[i]=in.readFloat();for(int i=0;i<p.noiseM.length;i++)p.noiseM[i]=in.readFloat();
        return p.calibrated?p:null;}
      if(version!=VERSION)return null;
      String storedKey=in.readUTF(),storedId=in.readUTF();int w=in.readInt(),h=in.readInt();
      if(!(Objects.equals(storedKey,key)||Objects.equals(storedId,id)||Objects.equals(storedId,legacy))||w!=width||h!=height)return null;
      DepthCorrectionProfile p=new DepthCorrectionProfile(storedId,w,h);p.deviceKey=storedKey;p.createdEpochMs=in.readLong();p.calibrated=in.readBoolean();p.coverage=in.readFloat();
      p.trainingRmsBeforeMm=in.readFloat();p.trainingRmsAfterMm=in.readFloat();p.validationRmsBeforeMm=in.readFloat();p.validationRmsAfterMm=in.readFloat();
      p.modelType=in.readInt();p.gridX=in.readInt();p.gridY=in.readInt();p.bins=in.readInt();p.w0=in.readFloat();p.w1=in.readFloat();p.regularization=in.readFloat();
      p.disparityGain=in.readFloat();p.disparityOffset=in.readFloat();p.referenceCount=in.readInt();p.referenceRmsMm=in.readFloat();p.intrinsicsHash=in.readLong();
      if(p.modelType!=DepthCorrectionProfile.MODEL_DISPARITY_GRID||p.gridX<2||p.gridY<2||p.bins<2||p.gridX*p.gridY*p.bins>4000000||!(p.w1>p.w0))return null;
      int s=in.readInt();if(s<0||s>64)return null;p.stationCenterM=new float[s];p.stationRawCenterM=new float[s];p.stationReferenceM=new float[s];p.stationRmsBeforeMm=new float[s];p.stationRmsAfterMm=new float[s];
      p.stationMaeBeforeMm=new float[s];p.stationMaeAfterMm=new float[s];p.stationP95BeforeMm=new float[s];p.stationP95AfterMm=new float[s];
      for(int i=0;i<s;i++){p.stationCenterM[i]=in.readFloat();p.stationRawCenterM[i]=in.readFloat();p.stationReferenceM[i]=in.readFloat();p.stationRmsBeforeMm[i]=in.readFloat();p.stationRmsAfterMm[i]=in.readFloat();
        p.stationMaeBeforeMm[i]=in.readFloat();p.stationMaeAfterMm[i]=in.readFloat();p.stationP95BeforeMm[i]=in.readFloat();p.stationP95AfterMm[i]=in.readFloat();}
      p.grid=new float[p.gridX*p.gridY*p.bins];for(int i=0;i<p.grid.length;i++)p.grid[i]=in.readFloat();for(int i=0;i<p.noiseM.length;i++)p.noiseM[i]=in.readFloat();
      p.prepareRuntime();return p.calibrated?p:null;}catch(Exception e){return null;}}
}

class DepthCalibrationSession {
  final AppConfig cfg;final Calibration calibration;final DepthCalibrationStore store;
  final String deviceId;final ArrayList<CalibrationStation> stations=new ArrayList<CalibrationStation>();
  final boolean autoSave;
  boolean active=false,waitingForDistance=false;volatile boolean fitting=false;int capturedFrames=0,lastFrameId=-1;
  float anchorDepthM=Float.NaN;CalibrationAccumulator accumulator=null;float[] quickDepth=null;
  volatile DepthCorrectionProfile fitResult=null;volatile Exception fitError=null;Thread fitThread=null;

  DepthCalibrationSession(AppConfig cfg,Calibration calibration,DepthCalibrationStore store,String deviceId){this(cfg,calibration,store,deviceId,true);}
  DepthCalibrationSession(AppConfig cfg,Calibration calibration,DepthCalibrationStore store,String deviceId,boolean autoSave){this.cfg=cfg;
    this.calibration=calibration;this.store=store;this.deviceId=deviceId;this.autoSave=autoSave;}
  void start(){active=true;waitingForDistance=false;fitting=false;fitResult=null;fitError=null;capturedFrames=0;anchorDepthM=Float.NaN;
    accumulator=null;stations.clear();}
  void cancel(){active=false;accumulator=null;fitting=false;}
  // Planarity gate referenced to 1 m (inverse-depth RMS) so far stations with Kinect
  // quantisation noise are not rejected by a metric threshold meant for near range.
  boolean acceptablePlane(PlaneModel plane){return plane.valid()&&plane.rmsAt1m()<=cfg.calibrationPlaneResidualMaxM;}
  DepthCorrectionProfile offer(DepthFrame frame)throws IOException{
    if(!active)return null;
    if(fitting)return collectFit();
    if(frame==null||frame.depth==null||frame.frameId==lastFrameId)return null;
    lastFrameId=frame.frameId;
    if(quickDepth==null||quickDepth.length!=frame.depth.length)quickDepth=new float[frame.depth.length];
    for(int i=0;i<quickDepth.length;i++){int mm=frame.depth[i]&0xffff;quickDepth[i]=mm>0?mm*0.001f:0;
      }PlaneModel plane=fitCalibrationPlane(quickDepth,frame.width,frame.height,calibration,4);
    float center=plane.centerDepthM();if(!acceptablePlane(plane)||!Float.isFinite(center))return null;
    if(waitingForDistance){float previous=stations.get(stations.size()-1).centerDepthM;
      if(abs(center-previous)<cfg.calibrationDistanceSeparationM)return null;waitingForDistance=false;
      anchorDepthM=center;accumulator=new CalibrationAccumulator(frame.width,frame.height,cfg.calibrationFramesPerStation);
      capturedFrames=0;}
    if(accumulator==null){anchorDepthM=center;accumulator=new CalibrationAccumulator(frame.width,frame.height,cfg.calibrationFramesPerStation);
      }
    if(abs(center-anchorDepthM)>cfg.calibrationStabilityToleranceM*max(1.0f,anchorDepthM*anchorDepthM)){accumulator=null;
      capturedFrames=0;anchorDepthM=Float.NaN;return null;}
    accumulator.add(frame);capturedFrames++;
    if(capturedFrames<cfg.calibrationFramesPerStation)return null;
    CalibrationStation station=accumulator.finish(calibration,cfg);accumulator=null;capturedFrames=0;
    anchorDepthM=Float.NaN;if(!acceptablePlane(station.plane))return null;
    stations.add(station);
    if(stations.size()<cfg.calibrationStations){waitingForDistance=true;return null;
      }
    startFit();return collectFit();
  }
  void startFit(){fitting=true;fitResult=null;fitError=null;final ArrayList<CalibrationStation> snapshot=new ArrayList<CalibrationStation>(stations);
    final String key=store==null?deviceId:store.keyFor(deviceId);
    fitThread=new Thread(new Runnable(){public void run(){try{fitResult=new DepthCorrectionSolver(cfg,calibration).fit(snapshot,deviceId,key);}catch(Exception e){fitError=e;}}},"depth-calibration-fit");
    fitThread.setDaemon(true);fitThread.start();}
  DepthCorrectionProfile collectFit()throws IOException{Exception e=fitError;if(e!=null){fitting=false;active=false;if(e instanceof IOException)throw (IOException)e;throw new IllegalStateException(safeExceptionMessage(e),e);}
    DepthCorrectionProfile p=fitResult;if(p==null)return null;fitting=false;if(autoSave)store.save(p);active=false;return p;}
  // Blocks until the background fit ends (headless tools); returns null on timeout.
  DepthCorrectionProfile awaitResult(long timeoutMs)throws IOException{Thread t=fitThread;if(t!=null){try{t.join(timeoutMs);}catch(InterruptedException ie){Thread.currentThread().interrupt();}}return fitting?collectFit():null;}
}

class Calibration {
  volatile boolean valid = false;
  int depthWidth = studio.services.scannerProtocol.WIDTH;
  int depthHeight = studio.services.scannerProtocol.HEIGHT;
  float fx, fy, cx, cy, depthScale;
  // Depth lens distortion (Brown-Conrady, OpenCV order) on normalized coordinates and the
  // pixel convention: distorted normalized x = (u + pixelCenter + shiftU - cx) / fx.
  float k1,k2,k3,p1,p2,pixelCenter=0,shiftU=0,shiftV=0;
  boolean nativeGeometry=false,nativeDistortion=false;
  boolean colorIntrinsicsValid=false;float colorFx,colorFy,colorCx,colorCy,colorShiftD,colorShiftM;
  volatile int geometryVersion=0;volatile long geometryHash=0L;
  private float[] rayXTable,rayYTable;private int raysVersion=-1;
  String deviceId="";DepthCorrectionProfile depthCorrection=null;AppConfig cfg;

  void configure(AppConfig cfg) {
    this.cfg=cfg;if (cfg == null) { valid = false; return; }
    depthWidth = studio.services.scannerProtocol.WIDTH;
    depthHeight = studio.services.scannerProtocol.HEIGHT;
    fx = cfg.depthFx; fy = cfg.depthFy; cx = cfg.depthCx; cy = cfg.depthCy; depthScale = cfg.depthScale;
    k1=cfg.depthK1;k2=cfg.depthK2;k3=cfg.depthK3;p1=cfg.depthP1;p2=cfg.depthP2;pixelCenter=cfg.depthPixelCenter;shiftU=cfg.depthShiftU;shiftV=cfg.depthShiftV;
    nativeGeometry=false;nativeDistortion=false;colorIntrinsicsValid=false;
    valid = fx > 0 && fy > 0 && depthScale > 0;geometryChanged();
  }
  void selectDevice(String id,DepthCorrectionProfile profile){deviceId=id==null?"":id;
    depthCorrection=profile;}
  // Native metric devices (Kinect One) report their own intrinsics. Their depth engine uses
  // pixel centres at u+0.5; the factory distortion arrives separately (applyNativeDistortion).
  void applyNativeIntrinsics(int width,int height,double nativeFx,double nativeFy,double nativeCx,double nativeCy){
    if(width<=0||height<=0||!Double.isFinite(nativeFx)||!Double.isFinite(nativeFy)||!Double.isFinite(nativeCx)||!Double.isFinite(nativeCy)||nativeFx<=1||nativeFy<=1)return;
    depthWidth=width;depthHeight=height;fx=(float)nativeFx;fy=(float)nativeFy;cx=(float)nativeCx;cy=(float)nativeCy;depthScale=0.001f;valid=true;
    k1=k2=k3=p1=p2=0;pixelCenter=0.5f;shiftU=shiftV=0;nativeGeometry=true;nativeDistortion=false;geometryChanged();
    if(depthCorrection!=null&&(depthCorrection.width!=width||depthCorrection.height!=height))depthCorrection=null;
  }
  void applyNativeDistortion(float nk1,float nk2,float nk3,float np1,float np2,float nativePixelCenter){
    if(!(Float.isFinite(nk1)&&Float.isFinite(nk2)&&Float.isFinite(nk3)&&Float.isFinite(np1)&&Float.isFinite(np2))||Math.abs(nk1)>5||Math.abs(nk2)>5||Math.abs(nk3)>10||Math.abs(np1)>1||Math.abs(np2)>1)return;
    k1=nk1;k2=nk2;k3=nk3;p1=np1;p2=np2;if(Float.isFinite(nativePixelCenter)&&nativePixelCenter>=0&&nativePixelCenter<=1)pixelCenter=nativePixelCenter;nativeDistortion=true;geometryChanged();}
  void applyNativeColorIntrinsics(float cfx,float cfy,float ccx,float ccy,float shiftD,float shiftM){
    if(!(cfx>1&&cfy>1&&Float.isFinite(ccx)&&Float.isFinite(ccy)))return;colorFx=cfx;colorFy=cfy;colorCx=ccx;colorCy=ccy;colorShiftD=shiftD;colorShiftM=shiftM;colorIntrinsicsValid=true;}
  void geometryChanged(){long h=0xcbf29ce484222325L;float[] v={depthWidth,depthHeight,fx,fy,cx,cy,k1,k2,k3,p1,p2,pixelCenter,shiftU,shiftV};
    for(float f:v){h^=Float.floatToIntBits(f);h*=0x100000001b3L;}geometryHash=h==0?1:h;geometryVersion++;}
  void distortNormalized(float x,float y,float[] out){float r2=x*x+y*y,radial=1+k1*r2+k2*r2*r2+k3*r2*r2*r2;
    out[0]=x*radial+2*p1*x*y+p2*(r2+2*x*x);out[1]=y*radial+p1*(r2+2*y*y)+2*p2*x*y;}
  // Inverse Brown-Conrady by fixed-point iteration; false when it does not converge.
  boolean undistortNormalized(float xd,float yd,float[] out){float x=xd,y=yd;float[] d=new float[2];
    for(int it=0;it<30;it++){float r2=x*x+y*y,radial=1+k1*r2+k2*r2*r2+k3*r2*r2*r2;if(Math.abs(radial)<1e-6f)break;
      float ddx=2*p1*x*y+p2*(r2+2*x*x),ddy=p1*(r2+2*y*y)+2*p2*x*y;x=(xd-ddx)/radial;y=(yd-ddy)/radial;}
    distortNormalized(x,y,d);boolean ok=Float.isFinite(x)&&Float.isFinite(y)&&Math.abs(d[0]-xd)+Math.abs(d[1]-yd)<1e-4f;out[0]=ok?x:xd;out[1]=ok?y:yd;return ok;}
  // Forward model shared with deprojection: camera point -> depth pixel (u,v) in the same
  // pixel convention as rays(), so deproject(project(p)) round-trips.
  boolean projectToPixel(float X,float Y,float Z,float[] outUV){if(!(Z>1e-6f))return false;float[] d=new float[2];distortNormalized(X/Z,Y/Z,d);
    outUV[0]=fx*d[0]+cx-pixelCenter-shiftU;outUV[1]=fy*d[1]+cy-pixelCenter-shiftV;return Float.isFinite(outUV[0])&&Float.isFinite(outUV[1]);}
  // Undistorted normalized ray per depth pixel {rayX, rayY}; rebuilt when geometry changes.
  synchronized float[][] rays(){int n=max(1,depthWidth)*max(1,depthHeight);if(raysVersion==geometryVersion&&rayXTable!=null&&rayXTable.length==n)return new float[][]{rayXTable,rayYTable};
    int version=geometryVersion,dw=max(1,depthWidth),dh=max(1,depthHeight);float[] rx=new float[n],ry=new float[n],o=new float[2];
    for(int v=0;v<dh;v++)for(int u=0;u<dw;u++){undistortNormalized((u+pixelCenter+shiftU-cx)/fx,(v+pixelCenter+shiftV-cy)/fy,o);int i=v*dw+u;rx[i]=o[0];ry[i]=o[1];}
    rayXTable=rx;rayYTable=ry;raysVersion=version;return new float[][]{rx,ry};}
  float[] rayX(){return rays()[0];}float[] rayY(){return rays()[1];}
  boolean hasDepthCorrection(){DepthCorrectionProfile p=depthCorrection;return cfg!=null&&cfg.calibrationEnabled&&p!=null&&p.calibrated&&(p.intrinsicsHash==0L||p.intrinsicsHash==geometryHash);
    }
  int correctedDepthMm(int index,int rawMm){return hasDepthCorrection()?depthCorrection.correctMm(index,rawMm):rawMm;
    }
  float depthConfidence(int index,float depthM){return hasDepthCorrection()?depthCorrection.confidenceAt(index,depthM,cfg):1.0f;
    }
}
