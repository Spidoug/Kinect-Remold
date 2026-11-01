// ===== SynKinect Studio / 3D Scanner / FULL QUALITY reconstruction core =====
// Adapted from Kinect_Remold_3D_Reconstruction_v1.0. The Studio keeps ownership
// of RGB-D transport, calibration, automatic support-plane/object detection and
// UI. This core owns the offline organized ICP, SE(3) pose graph and Surface-SDF
// used by the Scanner's FULL QUALITY reconstruction path.

class ScannerFqMath {
  RigidTransform copy(RigidTransform src){RigidTransform t=new RigidTransform();t.set(src);return t;}
  RigidTransform exp(float[] x){
    double wx=x[0],wy=x[1],wz=x[2],vx=x[3],vy=x[4],vz=x[5];
    double theta=Math.sqrt(wx*wx+wy*wy+wz*wz),theta2=theta*theta,A,B,C;
    if(theta<1e-6){A=1.0-theta2/6.0+theta2*theta2/120.0;B=.5-theta2/24.0+theta2*theta2/720.0;C=1.0/6.0-theta2/120.0+theta2*theta2/5040.0;}
    else{A=Math.sin(theta)/theta;B=(1.0-Math.cos(theta))/theta2;C=(theta-Math.sin(theta))/(theta2*theta);}
    double k00=0,k01=-wz,k02=wy,k10=wz,k11=0,k12=-wx,k20=-wy,k21=wx,k22=0;
    double q00=k01*k10+k02*k20,q01=k02*k21,q02=k01*k12,q10=k12*k20,q11=k10*k01+k12*k21,q12=k10*k02,q20=k21*k10,q21=k20*k01,q22=k20*k02+k21*k12;
    RigidTransform t=new RigidTransform();
    t.m[0]=(float)(1+A*k00+B*q00);t.m[1]=(float)(A*k01+B*q01);t.m[2]=(float)(A*k02+B*q02);
    t.m[4]=(float)(A*k10+B*q10);t.m[5]=(float)(1+A*k11+B*q11);t.m[6]=(float)(A*k12+B*q12);
    t.m[8]=(float)(A*k20+B*q20);t.m[9]=(float)(A*k21+B*q21);t.m[10]=(float)(1+A*k22+B*q22);
    t.m[3]=(float)((1+B*k00+C*q00)*vx+(B*k01+C*q01)*vy+(B*k02+C*q02)*vz);
    t.m[7]=(float)((B*k10+C*q10)*vx+(1+B*k11+C*q11)*vy+(B*k12+C*q12)*vz);
    t.m[11]=(float)((B*k20+C*q20)*vx+(B*k21+C*q21)*vy+(1+B*k22+C*q22)*vz);
    return t;
  }
  float[] log(RigidTransform t){
    float[] x=new float[6];double tr=t.m[0]+t.m[5]+t.m[10],c=Math.max(-1.0,Math.min(1.0,(tr-1.0)*.5)),theta=Math.acos(c),wx,wy,wz;
    if(theta<1e-6){wx=.5*(t.m[9]-t.m[6]);wy=.5*(t.m[2]-t.m[8]);wz=.5*(t.m[4]-t.m[1]);}
    else if(Math.PI-theta<1e-4){
      double ax=Math.sqrt(Math.max(0,(t.m[0]+1)*.5)),ay=Math.sqrt(Math.max(0,(t.m[5]+1)*.5)),az=Math.sqrt(Math.max(0,(t.m[10]+1)*.5));
      if(t.m[9]-t.m[6]<0)ax=-ax;if(t.m[2]-t.m[8]<0)ay=-ay;if(t.m[4]-t.m[1]<0)az=-az;double n=Math.sqrt(ax*ax+ay*ay+az*az);if(n<1e-9){ax=1;ay=az=0;n=1;}wx=theta*ax/n;wy=theta*ay/n;wz=theta*az/n;
    }else{double s=theta/(2*Math.sin(theta));wx=s*(t.m[9]-t.m[6]);wy=s*(t.m[2]-t.m[8]);wz=s*(t.m[4]-t.m[1]);}
    double th2=wx*wx+wy*wy+wz*wz,D;if(th2<1e-8)D=1.0/12.0+th2/720.0;else{double th=Math.sqrt(th2);D=1.0/th2-(1.0+Math.cos(th))/(2.0*th*Math.sin(th));}
    double k01=-wz,k02=wy,k10=wz,k12=-wx,k20=-wy,k21=wx;
    double q00=k01*k10+k02*k20,q01=k02*k21,q02=k01*k12,q10=k12*k20,q11=k10*k01+k12*k21,q12=k10*k02,q20=k21*k10,q21=k20*k01,q22=k20*k02+k21*k12;
    double tx=t.m[3],ty=t.m[7],tz=t.m[11];
    x[0]=(float)wx;x[1]=(float)wy;x[2]=(float)wz;
    x[3]=(float)((1+D*q00)*tx+(-.5*k01+D*q01)*ty+(-.5*k02+D*q02)*tz);
    x[4]=(float)((-.5*k10+D*q10)*tx+(1+D*q11)*ty+(-.5*k12+D*q12)*tz);
    x[5]=(float)((-.5*k20+D*q20)*tx+(-.5*k21+D*q21)*ty+(1+D*q22)*tz);
    return x;
  }
  boolean solve6(float[][] A,float[] b,float[] x){
    float[][] M=new float[6][7];for(int r=0;r<6;r++){for(int c=0;c<6;c++)M[r][c]=A[r][c];M[r][6]=b[r];}
    for(int c=0;c<6;c++){int pivot=c;float best=Math.abs(M[c][c]);for(int r=c+1;r<6;r++){float v=Math.abs(M[r][c]);if(v>best){best=v;pivot=r;}}if(best<1e-10f)return false;
      if(pivot!=c){float[] tmp=M[c];M[c]=M[pivot];M[pivot]=tmp;}float d=M[c][c];for(int k=c;k<7;k++)M[c][k]/=d;
      for(int r=0;r<6;r++){if(r==c)continue;float f=M[r][c];if(Math.abs(f)<1e-12f)continue;for(int k=c;k<7;k++)M[r][k]-=f*M[c][k];}}
    for(int i=0;i<6;i++)x[i]=M[i][6];return true;
  }
  float norm6(float[] x){float s=0;for(float v:x)s+=v*v;return (float)Math.sqrt(s);}
  float huber(float r,float d){float a=Math.abs(r);return a<=d?1.0f:d/Math.max(a,1e-7f);}
  float cauchy(float r,float c){float u=r/Math.max(c,1e-7f);return 1.0f/(1.0f+u*u);}
  float colorDistance01(int a,int b){float ar=(a>>16)&255,ag=(a>>8)&255,ab=a&255,br=(b>>16)&255,bg=(b>>8)&255,bb=b&255,dr=ar-br,dg=ag-bg,db=ab-bb;return (float)Math.sqrt(dr*dr+dg*dg+db*db)/(441.67296f);}
}

class ScannerFqLevel {
  int w,h;float fx,fy,cx,cy;PVector[] vertex,normal;int[] color;boolean[] valid;
  ScannerFqLevel(int w,int h){this.w=w;this.h=h;int n=w*h;vertex=new PVector[n];normal=new PVector[n];color=new int[n];valid=new boolean[n];}
  int projectX(PVector p){return p.z<=1e-5f?-1:Math.round(fx*p.x/p.z+cx);}
  int projectY(PVector p){return p.z<=1e-5f?-1:Math.round(fy*p.y/p.z+cy);}
}

class ScannerFqFrame {
  int w,h;float fx,fy,cx,cy;long frameNumber;float[] x,y,z;int[] color;boolean[] valid;ScannerFqLevel[] levels;
  ScannerFqFrame(int w,int h){this.w=w;this.h=h;int n=w*h;x=new float[n];y=new float[n];z=new float[n];color=new int[n];valid=new boolean[n];}
  void buildPyramid(){levels=new ScannerFqLevel[]{buildLevel(4),buildLevel(2),buildLevel(1)};}
  ScannerFqLevel buildLevel(int step){
    int lw=(w+step-1)/step,lh=(h+step-1)/step;ScannerFqLevel L=new ScannerFqLevel(lw,lh);L.fx=fx/step;L.fy=fy/step;L.cx=cx/step;L.cy=cy/step;
    for(int yy=0;yy<lh;yy++){int sy=Math.min(h-1,yy*step);for(int xx=0;xx<lw;xx++){int sx=Math.min(w-1,xx*step),src=sy*w+sx,dst=yy*lw+xx;if(!valid[src])continue;L.vertex[dst]=new PVector(x[src],y[src],z[src]);L.color[dst]=color[src];L.valid[dst]=true;}}
    for(int yy=1;yy<lh-1;yy++)for(int xx=1;xx<lw-1;xx++){int i=yy*lw+xx;if(!L.valid[i])continue;PVector l=L.vertex[i-1],r=L.vertex[i+1],u=L.vertex[i-lw],d=L.vertex[i+lw];if(l==null||r==null||u==null||d==null)continue;
      PVector dx=PVector.sub(r,l),dy=PVector.sub(d,u),n=dx.cross(dy);if(n.magSq()<1e-12f)continue;n.normalize();if(n.dot(L.vertex[i])>0)n.mult(-1);L.normal[i]=n;}
    return L;
  }
  PVector fullNormal(int px,int py){if(levels==null||levels.length<3)return null;ScannerFqLevel L=levels[2];if(px<0||py<0||px>=L.w||py>=L.h)return null;return L.normal[py*L.w+px];}
  boolean continuous(int px,int py,float maxJump){if(px<=0||py<=0||px>=w-1||py>=h-1)return false;int i=py*w+px;if(!valid[i])return false;float zz=z[i];int[] q={i-1,i+1,i-w,i+w};for(int j:q)if(!valid[j]||Math.abs(z[j]-zz)>maxJump)return false;return true;}
}

class ScannerFqRegistrationResult {RigidTransform transform=new RigidTransform();float rmse=Float.POSITIVE_INFINITY,fitness=0;int correspondences=0,sourceSamples=0;boolean ok=false;}

class ScannerFqRegistration {
  final ScannerFqMath math;final int[] iterations={12,9,7};final float[] maxDistance={.080f,.045f,.025f};final float[] maxNormalDeg={55,45,35};
  float huber=.018f,colorInfluence=.28f;
  ScannerFqRegistration(ScannerFqMath math){this.math=math;}
  ScannerFqRegistrationResult align(ScannerFqFrame source,ScannerFqFrame target,RigidTransform initial){
    ScannerFqRegistrationResult out=new ScannerFqRegistrationResult();RigidTransform T=math.copy(initial);float lastRmse=Float.POSITIVE_INFINITY;int lastPairs=0,lastSamples=0;
    for(int level=0;level<3;level++){ScannerFqLevel S=source.levels[level],D=target.levels[level];
      for(int it=0;it<iterations[level];it++){float[][] A=new float[6][6];float[] b=new float[6];double err2=0,sumW=0;int pairs=0,samples=0;float gate=maxDistance[level],cosA=(float)Math.cos(Math.toRadians(maxNormalDeg[level]));
        for(int si=0;si<S.w*S.h;si++){if(!S.valid[si])continue;PVector sp=S.vertex[si],sn=S.normal[si];if(sp==null||sn==null)continue;samples++;PVector p=T.apply(sp);if(p.z<=1e-5f)continue;
          int tx=D.projectX(p),ty=D.projectY(p);if(tx<1||ty<1||tx>=D.w-1||ty>=D.h-1)continue;int di=ty*D.w+tx;if(!D.valid[di])continue;PVector q=D.vertex[di],n=D.normal[di];if(q==null||n==null||Math.abs(p.z-q.z)>gate)continue;
          PVector ns=T.rotate(sn);if(ns.magSq()<1e-12f)continue;ns.normalize();if(ns.dot(n)<cosA)continue;PVector diff=PVector.sub(p,q);float residual=n.dot(diff);if(Math.abs(residual)>gate)continue;
          float robust=math.huber(residual,huber)*math.cauchy(residual,gate*.55f),cd=math.colorDistance01(S.color[si],D.color[di]),cw=(float)Math.exp(-cd*4.0f),weight=robust*((1-colorInfluence)+colorInfluence*cw);
          PVector cross=p.cross(n);float[] J={cross.x,cross.y,cross.z,n.x,n.y,n.z};for(int r=0;r<6;r++){b[r]+=weight*J[r]*(-residual);for(int c=0;c<6;c++)A[r][c]+=weight*J[r]*J[c];}
          err2+=weight*residual*residual;sumW+=weight;pairs++;
        }
        for(int d=0;d<6;d++)A[d][d]+=1e-5f;if(pairs<40||sumW<1)break;float[] delta=new float[6];if(!math.solve6(A,b,delta))break;
        float rn=(float)Math.sqrt(delta[0]*delta[0]+delta[1]*delta[1]+delta[2]*delta[2]),maxR=(float)Math.toRadians(8);if(rn>maxR){float k=maxR/rn;delta[0]*=k;delta[1]*=k;delta[2]*=k;}
        float tn=(float)Math.sqrt(delta[3]*delta[3]+delta[4]*delta[4]+delta[5]*delta[5]);if(tn>.050f){float k=.050f/tn;delta[3]*=k;delta[4]*=k;delta[5]*=k;}
        T=math.exp(delta).multiply(T);lastRmse=(float)Math.sqrt(err2/sumW);lastPairs=pairs;lastSamples=samples;if(math.norm6(delta)<2e-5f)break;
      }
    }
    out.transform=T;out.rmse=lastRmse;out.correspondences=lastPairs;out.sourceSamples=lastSamples;out.fitness=Math.max(0,Math.min(1,lastPairs/(float)Math.max(1,lastSamples)));out.ok=lastPairs>=80&&Float.isFinite(lastRmse)&&lastRmse<.022f;return out;
  }
}

class ScannerFqPoseEdge {int i,j;RigidTransform measurement;float weight;boolean loop;ScannerFqPoseEdge(int i,int j,RigidTransform m,float w,boolean l){this.i=i;this.j=j;measurement=new RigidTransform();measurement.set(m);weight=w;loop=l;}}

class ScannerFqPoseGraph {
  final ScannerFqMath math;final ArrayList<RigidTransform> poses=new ArrayList<RigidTransform>();final ArrayList<ScannerFqPoseEdge> edges=new ArrayList<ScannerFqPoseEdge>();
  double sigmaR=Math.toRadians(2),sigmaT=.018,loopCauchy=3,lastInitialCost=Double.POSITIVE_INFINITY,lastFinalCost=Double.POSITIVE_INFINITY;int acceptedSteps=0;
  ScannerFqPoseGraph(ScannerFqMath m){math=m;}
  void addPose(RigidTransform p){poses.add(math.copy(p));}void addEdge(ScannerFqPoseEdge e){edges.add(e);}
  float[] residual(ScannerFqPoseEdge e,ArrayList<RigidTransform> state){RigidTransform pred=state.get(e.i).inverseRigid().multiply(state.get(e.j)),err=e.measurement.inverseRigid().multiply(pred);float[] r=math.log(err);for(int k=0;k<3;k++)r[k]/=(float)sigmaR;for(int k=3;k<6;k++)r[k]/=(float)sigmaT;return r;}
  double sq(float[] r){double s=0;for(float v:r)s+=(double)v*v;return s;}
  double weight(ScannerFqPoseEdge e,double s2){if(!e.loop){double s=Math.sqrt(Math.max(0,s2));return s<=3.5?1:3.5/Math.max(s,1e-12);}double c=loopCauchy*loopCauchy;return 1/(1+s2/c);}
  double loss(ScannerFqPoseEdge e,double s2){if(!e.loop){double s=Math.sqrt(Math.max(0,s2));return s<=3.5?.5*s2:3.5*(s-1.75);}double c=loopCauchy*loopCauchy;return .5*c*Math.log1p(s2/c);}
  double cost(ArrayList<RigidTransform> s){double c=0;for(ScannerFqPoseEdge e:edges){float[] r=residual(e,s);c+=Math.max(1e-4,e.weight)*loss(e,sq(r));}return c;}
  double[][] jacobian(ScannerFqPoseEdge e,ArrayList<RigidTransform> state,boolean wrtI,float[] r0){double[][] J=new double[6][6];int node=wrtI?e.i:e.j;if(node==0)return J;RigidTransform original=state.get(node);
    for(int k=0;k<6;k++){double eps=k<3?1e-4:1e-4;float[] d=new float[6];d[k]=(float)eps;state.set(node,math.exp(d).multiply(original));float[] rp=residual(e,state);state.set(node,original);for(int r=0;r<6;r++)J[r][k]=(rp[r]-r0[r])/eps;}return J;}
  void block(double[][] H,int bi,int bj,double[][] A,double[][] B,double w){if(bi<0||bj<0)return;for(int a=0;a<6;a++)for(int b=0;b<6;b++){double v=0;for(int r=0;r<6;r++)v+=A[r][a]*B[r][b];H[bi+a][bj+b]+=w*v;}}
  void gradient(double[] g,int bi,double[][] J,float[] r,double w){if(bi<0)return;for(int a=0;a<6;a++){double v=0;for(int q=0;q<6;q++)v+=J[q][a]*r[q];g[bi+a]+=w*v;}}
  boolean pcg(double[][] A,double[] b,double[] x){int n=b.length;Arrays.fill(x,0);double[] r=b.clone(),z=new double[n],p=new double[n],Ap=new double[n];double bn=0;for(double v:b)bn+=v*v;bn=Math.sqrt(bn);if(bn<1e-14)return true;
    for(int i=0;i<n;i++){z[i]=r[i]/Math.max(Math.abs(A[i][i]),1e-12);p[i]=z[i];}double rz=0;for(int i=0;i<n;i++)rz+=r[i]*z[i];int maxIt=Math.min(800,Math.max(80,n*2));
    for(int it=0;it<maxIt;it++){for(int i=0;i<n;i++){double s=0;for(int j=0;j<n;j++)s+=A[i][j]*p[j];Ap[i]=s;}double pAp=0;for(int i=0;i<n;i++)pAp+=p[i]*Ap[i];if(!(pAp>1e-20)||!Double.isFinite(pAp))return false;double alpha=rz/pAp,r2=0;
      for(int i=0;i<n;i++){x[i]+=alpha*p[i];r[i]-=alpha*Ap[i];r2+=r[i]*r[i];}if(Math.sqrt(r2)<=1e-7*Math.max(1,bn))return true;for(int i=0;i<n;i++)z[i]=r[i]/Math.max(Math.abs(A[i][i]),1e-12);double rn=0;for(int i=0;i<n;i++)rn+=r[i]*z[i];if(!Double.isFinite(rn))return false;double beta=rn/Math.max(Math.abs(rz),1e-30);for(int i=0;i<n;i++)p[i]=z[i]+beta*p[i];rz=rn;}return true;}
  ArrayList<RigidTransform> apply(double[] dx){ArrayList<RigidTransform> t=new ArrayList<RigidTransform>(poses.size());t.add(math.copy(poses.get(0)));for(int i=1;i<poses.size();i++){int b=(i-1)*6;float[] d=new float[6];for(int k=0;k<6;k++)d[k]=(float)dx[b+k];float rn=(float)Math.sqrt(d[0]*d[0]+d[1]*d[1]+d[2]*d[2]),mr=(float)Math.toRadians(4);if(rn>mr){float s=mr/rn;d[0]*=s;d[1]*=s;d[2]*=s;}float tn=(float)Math.sqrt(d[3]*d[3]+d[4]*d[4]+d[5]*d[5]);if(tn>.045f){float s=.045f/tn;d[3]*=s;d[4]*=s;d[5]*=s;}t.add(math.exp(d).multiply(poses.get(i)));}return t;}
  void optimize(int iterations){if(poses.size()<2||edges.isEmpty())return;int dim=(poses.size()-1)*6;double lambda=1e-3,current=cost(poses);lastInitialCost=current;acceptedSteps=0;
    for(int it=0;it<iterations;it++){double[][] H=new double[dim][dim];double[] g=new double[dim];for(ScannerFqPoseEdge e:edges){float[] r=residual(e,poses);double w=Math.max(1e-4,e.weight)*weight(e,sq(r));if(w<1e-8)continue;double[][] Ji=jacobian(e,poses,true,r),Jj=jacobian(e,poses,false,r);int bi=e.i==0?-1:(e.i-1)*6,bj=e.j==0?-1:(e.j-1)*6;gradient(g,bi,Ji,r,w);gradient(g,bj,Jj,r,w);block(H,bi,bi,Ji,Ji,w);block(H,bj,bj,Jj,Jj,w);block(H,bi,bj,Ji,Jj,w);block(H,bj,bi,Jj,Ji,w);}
      double[] rhs=new double[dim];double mg=0;for(int i=0;i<dim;i++){mg=Math.max(mg,Math.abs(g[i]));double d=Math.max(H[i][i],1e-9);H[i][i]+=lambda*(d+1e-6);rhs[i]=-g[i];}if(mg<1e-8)break;double[] dx=new double[dim];if(!pcg(H,rhs,dx)){lambda=Math.min(1e9,lambda*10);continue;}ArrayList<RigidTransform> trial=apply(dx);double tc=cost(trial);
      if(Double.isFinite(tc)&&tc<current){double improvement=current-tc;for(int i=0;i<poses.size();i++)poses.set(i,trial.get(i));current=tc;acceptedSteps++;lambda=Math.max(1e-8,lambda*.35);if(improvement<1e-7*Math.max(1,current))break;}else lambda=Math.min(1e9,lambda*8);}
    lastFinalCost=current;
  }
}

class ScannerFqVoxel {float sdf=1,weight=0,r=0,g=0,b=0;}
class ScannerFqSurfaceSdf {
  final ConcurrentHashMap<Long,ScannerFqVoxel> voxels=new ConcurrentHashMap<Long,ScannerFqVoxel>();float voxel=.004f,trunc=.016f,maxWeight=48;int maxVoxels=4000000;volatile boolean limit=false;
  int vi(float v){return (int)Math.floor(v/voxel);}long key(int x,int y,int z){long bx=((long)x+1048576)&0x1fffff,by=((long)y+1048576)&0x1fffff,bz=((long)z+1048576)&0x1fffff;return (bx<<42)|(by<<21)|bz;}
  int[] decode(long k){return new int[]{(int)((k>>42)&0x1fffff)-1048576,(int)((k>>21)&0x1fffff)-1048576,(int)(k&0x1fffff)-1048576};}
  void update(PVector p,float sdf,int color,float w){if(w<=0)return;long k=key(vi(p.x),vi(p.y),vi(p.z));ScannerFqVoxel v=voxels.get(k);if(v==null){if(voxels.size()>=maxVoxels){limit=true;return;}ScannerFqVoxel fresh=new ScannerFqVoxel(),old=voxels.putIfAbsent(k,fresh);v=old==null?fresh:old;}
    synchronized(v){float q=Math.max(.02f,Math.min(1,w)),nw=v.weight+q;v.sdf=(v.sdf*v.weight+sdf*q)/nw;int c=color==0?0xffb4b4b4:color,cr=(c>>16)&255,cg=(c>>8)&255,cb=c&255;v.r=(v.r*v.weight+cr*q)/nw;v.g=(v.g*v.weight+cg*q)/nw;v.b=(v.b*v.weight+cb*q)/nw;v.weight=Math.min(maxWeight,nw);}}
  void integrateSurfaceSample(PVector surface,PVector normal,int color,float w){if(surface==null||normal==null||normal.magSq()<1e-12f||w<=0)return;PVector n=normal.copy().normalize();
    for(float s=-trunc;s<=trunc+.5f*voxel;s+=voxel){PVector q=PVector.add(surface,PVector.mult(n,s));update(q,Math.max(-1,Math.min(1,s/trunc)),color,w);if(limit)return;}}
  void integrate(ScannerFqFrame f,RigidTransform pose){for(int yy=2;yy<f.h-2;yy++)for(int xx=2;xx<f.w-2;xx++){int i=yy*f.w+xx;if(!f.valid[i]||!f.continuous(xx,yy,.050f))continue;PVector n=f.fullNormal(xx,yy);if(n==null||n.magSq()<1e-12f)continue;PVector p=pose.apply(new PVector(f.x[i],f.y[i],f.z[i])),nw=pose.rotate(n);if(nw.magSq()<1e-12f)continue;nw.normalize();integrateSurfaceSample(p,nw,f.color[i],1.0f);if(limit)return;}}
  int integrateDeformed(ScannerFqFrame f,RigidTransform pose,ScannerFqDeformationGraph graph,ScannerFqCanonicalSurfelMap model,boolean allowNew,float frameQuality){int integrated=0;
    for(int y=2;y<f.h-2;y++)for(int x=2;x<f.w-2;x++){int i=y*f.w+x;if(!f.valid[i]||!f.continuous(x,y,.042f))continue;PVector fn=f.fullNormal(x,y);if(fn==null||fn.magSq()<1e-12f)continue;PVector pw=pose.apply(new PVector(f.x[i],f.y[i],f.z[i])),nw=pose.rotate(fn);if(nw.magSq()<1e-12f)continue;nw.normalize();
      ScannerFqDeformationGraph.NodeBlend blend=graph.blendAt(pw);PVector ps=graph.warp(pw,blend),ns=graph.warpNormal(nw,blend);if(ns==null||ns.magSq()<1e-12f)continue;ns.normalize();ScannerFqCanonicalSurfel near=model.nearestCompatible(ps,ns,.036f,.48f);float conf=0;PVector fused=ps,fusedNormal=ns;
      if(near!=null){PVector diff=PVector.sub(ps,near.p);float dist=diff.mag(),plane=near.n.dot(diff),normalCos=Math.max(0,ns.dot(near.n));if(dist>.036f||Math.abs(plane)>.020f||normalCos<.48f)continue;float planeScore=(float)Math.exp(-(plane*plane)/(2*.007f*.007f)),distScore=(float)Math.exp(-(dist*dist)/(2*.018f*.018f));conf=Math.max(0,Math.min(1,frameQuality*planeScore*distScore*normalCos*normalCos));if(conf<.08f)continue;float lock=Math.max(.70f,Math.min(.93f,.70f+.25f*near.weight/Math.max(near.weight+6,1e-6f)));fused=PVector.sub(ps,PVector.mult(near.n,plane*lock));fusedNormal=PVector.add(PVector.mult(near.n,.70f),PVector.mult(ns,.30f));if(fusedNormal.magSq()>1e-12f)fusedNormal.normalize();}
      else{if(!allowNew||frameQuality<.68f)continue;conf=.16f*frameQuality;}integrateSurfaceSample(fused,fusedNormal,f.color[i],conf);model.integrate(fused,fusedNormal,f.color[i],Math.max(.08f,conf));integrated++;if(limit)return integrated;
    }return integrated;}
  float sample(int x,int y,int z){ScannerFqVoxel v=voxels.get(key(x,y,z));return v==null||v.weight<=0?1:v.sdf;}float weight(int x,int y,int z){ScannerFqVoxel v=voxels.get(key(x,y,z));return v==null?0:v.weight;}
  int color(int x,int y,int z){ScannerFqVoxel v=voxels.get(key(x,y,z));if(v==null||v.weight<=0)return 0xffb4b4b4;return 0xff000000|(Math.max(0,Math.min(255,Math.round(v.r)))<<16)|(Math.max(0,Math.min(255,Math.round(v.g)))<<8)|Math.max(0,Math.min(255,Math.round(v.b)));}
  int lerpColor(int a,int b,float t){int ar=(a>>16)&255,ag=(a>>8)&255,ab=a&255,br=(b>>16)&255,bg=(b>>8)&255,bb=b&255;return 0xff000000|(Math.round(ar+(br-ar)*t)<<16)|(Math.round(ag+(bg-ag)*t)<<8)|Math.round(ab+(bb-ab)*t);}
  Mesh3D extractMesh(){Mesh3D out=new Mesh3D();int[][] off={{0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1}},tet={{0,5,1,6},{0,1,2,6},{0,2,3,6},{0,3,7,6},{0,7,4,6},{0,4,5,6}},edges={{0,1},{0,2},{0,3},{1,2},{1,3},{2,3}};
    for(Long kk:voxels.keySet()){int[] base=decode(kk);PVector[] p=new PVector[8];float[] s=new float[8],w=new float[8];int[] c=new int[8];boolean pos=false,neg=false;int known=0;
      for(int i=0;i<8;i++){int x=base[0]+off[i][0],y=base[1]+off[i][1],z=base[2]+off[i][2];p[i]=new PVector(x*voxel,y*voxel,z*voxel);w[i]=weight(x,y,z);s[i]=sample(x,y,z);c[i]=color(x,y,z);if(w[i]>=.12f){known++;if(s[i]<0)neg=true;else pos=true;}}if(known<5||!(pos&&neg))continue;
      for(int[] tt:tet){PVector[] q=new PVector[4];int[] qc=new int[4];int qn=0;for(int[] e:edges){int a=tt[e[0]],b=tt[e[1]];if(w[a]<.12f||w[b]<.12f||(s[a]<0)==(s[b]<0))continue;float den=s[a]-s[b],u=Math.abs(den)<1e-7f?.5f:s[a]/den;u=Math.max(0,Math.min(1,u));q[qn]=PVector.lerp(p[a],p[b],u);qc[qn]=lerpColor(c[a],c[b],u);if(++qn==4)break;}if(qn==3)out.addTriangle(q[0],q[1],q[2],qc[0],qc[1],qc[2]);else if(qn==4){out.addTriangle(q[0],q[1],q[2],qc[0],qc[1],qc[2]);out.addTriangle(q[0],q[2],q[3],qc[0],qc[2],qc[3]);}}
    }return out;}
}

class ScannerFullQualityEngine {
  final AppConfig cfg;final Calibration calibration;final RgbDepthRegistration registration;final HighQualityReconstructor owner;final ScannerFqMath math=new ScannerFqMath();final ScannerFqRegistration icp=new ScannerFqRegistration(math);
  volatile float lastRmse=Float.NaN,lastFitness=0,lastDeformRmse=Float.NaN,lastDeformQuality=0;volatile int loopClosures=0,activeVoxels=0,deformRejected=0;volatile double poseCostBefore=Double.NaN,poseCostAfter=Double.NaN;
  ScannerFullQualityEngine(AppConfig c,Calibration cal,RgbDepthRegistration reg,HighQualityReconstructor owner){cfg=c;calibration=cal;registration=reg;this.owner=owner;}
  ScannerFqFrame frame(HighQualityKeyframe k,boolean fusion){
    if(k==null||k.depth==null||k.depth.depth==null||calibration==null||!calibration.valid)return null;DepthFrame d=k.depth;RgbSnapshot rgb=owner.rgbSnapshot(k);if(registration!=null&&rgb!=null)registration.prepareFrame(d,rgb);
    ScannerFqFrame f=new ScannerFqFrame(d.width,d.height);f.fx=calibration.fx;f.fy=calibration.fy;f.cx=calibration.cx;f.cy=calibration.cy;f.frameNumber=d.frameNumber;float[] rx=calibration.rayX(),ry=calibration.rayY();BoundingBoxTracker box=scannerState().boundingBox;SupportPlane plane=box==null?null:box.supportPlane;
    for(int v=0;v<d.height;v++)for(int u=0;u<d.width;u++){int i=v*d.width+u,mm=d.depth[i]&0xffff;if(mm==0)continue;mm=calibration.correctedDepthMm(i,mm);if(mm<=0)continue;float z=mm*calibration.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;if(Float.isFinite(k.targetDepthM)&&Math.abs(z-k.targetDepthM)>k.bandM)continue;
      float x=rx[i]*z,y=ry[i]*z;PVector p=new PVector(x,y,z);if(!fusion&&plane!=null&&plane.valid&&!plane.keeps(p))continue;if(!fusion&&box!=null&&box.locked&&(x<box.minX||x>box.maxX||y<box.minY||y>box.maxY||z<box.minZ||z>box.maxZ))continue;
      f.x[i]=x;f.y[i]=y;f.z[i]=z;f.valid[i]=true;f.color[i]=registration!=null&&rgb!=null?registration.colorAt(i,z):0xffb4b4b4;
    }f.buildPyramid();return f;
  }
  float poseDistance(RigidTransform a,RigidTransform b){float dx=a.m[3]-b.m[3],dy=a.m[7]-b.m[7],dz=a.m[11]-b.m[11];return (float)Math.sqrt(dx*dx+dy*dy+dz*dz);}
  Mesh3D reconstruct(ArrayList<HighQualityKeyframe> frames,boolean fusion){
    if(frames==null||frames.size()<cfg.hqMinimumKeyframes)throw new IllegalStateException("FULL QUALITY: poucos keyframes");HqProgressTracker progress=scannerState().hqTracker;int n=frames.size();ArrayList<ScannerFqFrame> ff=new ArrayList<ScannerFqFrame>(n);
    for(int i=0;i<n;i++){ScannerFqFrame f=frame(frames.get(i),fusion);if(f==null)throw new IllegalStateException("FULL QUALITY: frame RGB-D inválido em "+i);ff.add(f);progress.set(progress.PREPARE,(i+1)/(float)n);if(Thread.currentThread().isInterrupted())return null;}
    ScannerFqPoseGraph graph=new ScannerFqPoseGraph(math);graph.addPose(frames.get(0).initialPose);float rmsSum=0;int rmsN=0;
    for(int i=1;i<n;i++){RigidTransform prior=frames.get(i-1).initialPose.inverseRigid().multiply(frames.get(i).initialPose);ScannerFqRegistrationResult r=icp.align(ff.get(i),ff.get(i-1),prior);lastRmse=r.rmse;lastFitness=r.fitness;
      if(!r.ok)throw new IllegalStateException("FULL QUALITY ICP falhou no keyframe "+i+" (RMSE "+nf(r.rmse*1000,1,2)+" mm, fitness "+nf(r.fitness,1,3)+")");RigidTransform world=graph.poses.get(i-1).multiply(r.transform);graph.addPose(world);graph.addEdge(new ScannerFqPoseEdge(i-1,i,r.transform,Math.max(.20f,Math.min(1,r.fitness)),false));rmsSum+=r.rmse;rmsN++;progress.set(progress.ALIGN,.72f*(i/(float)Math.max(1,n-1)));if(Thread.currentThread().isInterrupted())return null;}
    loopClosures=0;if(!fusion&&n>=8&&Math.abs(frames.get(n-1).sweepDeg-frames.get(0).sweepDeg)>=300){RigidTransform prior=graph.poses.get(0).inverseRigid().multiply(graph.poses.get(n-1));ScannerFqRegistrationResult r=icp.align(ff.get(n-1),ff.get(0),prior);if(r.ok&&r.fitness>=.18f&&r.rmse<.016f){graph.addEdge(new ScannerFqPoseEdge(0,n-1,r.transform,Math.max(.14f,Math.min(.9f,r.fitness*.9f)),true));loopClosures++;}}
    if(fusion){for(int a=0;a<n&&loopClosures<24;a+=2)for(int b=a+6;b<n&&loopClosures<24;b+=2){if(poseDistance(graph.poses.get(a),graph.poses.get(b))>.24f)continue;RigidTransform prior=graph.poses.get(a).inverseRigid().multiply(graph.poses.get(b));ScannerFqRegistrationResult r=icp.align(ff.get(b),ff.get(a),prior);if(r.ok&&r.fitness>=.18f&&r.rmse<.016f){graph.addEdge(new ScannerFqPoseEdge(a,b,r.transform,Math.max(.14f,Math.min(.9f,r.fitness*.9f)),true));loopClosures++;}}}
    progress.set(progress.ALIGN,.82f);graph.optimize(fusion?32:42);poseCostBefore=graph.lastInitialCost;poseCostAfter=graph.lastFinalCost;progress.set(progress.CONSENSUS,1);
    // Surface-lock stage from the FULL QUALITY reference engine: the first frame
    // seeds a canonical surfel model and deformation graph; later frames are
    // locally warped against that canonical surface before Surface-SDF fusion.
    ScannerFqSurfaceSdf sdf=new ScannerFqSurfaceSdf();ScannerFqCanonicalSurfelMap canonical=new ScannerFqCanonicalSurfelMap(.010f);ScannerFqDeformationGraph deform=new ScannerFqDeformationGraph(math);deformRejected=0;
    ScannerFqFrame first=ff.get(0);RigidTransform firstPose=graph.poses.get(0);sdf.integrate(first,firstPose);deform.seedFromFrame(first,firstPose,6);
    for(int y=2;y<first.h-2;y++)for(int x=2;x<first.w-2;x++){int i=y*first.w+x;if(!first.valid[i]||!first.continuous(x,y,.045f))continue;PVector fn=first.fullNormal(x,y);if(fn==null||fn.magSq()<1e-12f)continue;PVector pw=firstPose.apply(new PVector(first.x[i],first.y[i],first.z[i])),nw=firstPose.rotate(fn);if(nw.magSq()<1e-12f)continue;nw.normalize();canonical.integrate(pw,nw,first.color[i],1.0f);}
    activeVoxels=sdf.voxels.size();progress.set(progress.FUSE,1.0f/n);
    for(int i=1;i<n;i++){if(Thread.currentThread().isInterrupted())return null;deform.resetTransforms();deform.solve(ff.get(i),graph.poses.get(i),canonical,4,5);ScannerFqDeformationResult dr=deform.solve(ff.get(i),graph.poses.get(i),canonical,1,10);lastDeformRmse=dr.rmse;lastDeformQuality=dr.quality;boolean accept=dr.ok;int integrated=0;
      if(accept){integrated=sdf.integrateDeformed(ff.get(i),graph.poses.get(i),deform,canonical,dr.quality>=.68f,dr.quality);if(integrated<160){accept=false;deformRejected++;}}else deformRejected++;
      if(accept&&(i%4)==0)deform.addNodesFromSurfels(canonical);activeVoxels=sdf.voxels.size();if(sdf.limit)throw new IllegalStateException("FULL QUALITY Surface-SDF excedeu "+sdf.maxVoxels+" voxels");progress.set(progress.FUSE,(i+1)/(float)n);
    }
    progress.set(progress.MESH,.05f);Mesh3D raw=sdf.extractMesh();progress.set(progress.MESH,.75f);if(raw==null||raw.triangleCount()==0)throw new IllegalStateException("FULL QUALITY Surface-SDF não gerou superfície");Mesh3D clean=scannerState().meshEditor.polishHighQuality(raw);progress.set(progress.MESH,1);
    scannerState().hqDiagnostic="FULL QUALITY · ICP "+nf((rmsN==0?lastRmse:rmsSum/rmsN)*1000,1,2)+" mm · deformation "+nf(lastDeformRmse*1000,1,2)+" mm / q "+nf(lastDeformQuality,1,2)+" · rejeitados "+deformRejected+" · loops "+loopClosures+" · voxels "+activeVoxels+" · pose cost "+nf((float)poseCostBefore,1,2)+"→"+nf((float)poseCostAfter,1,2);return clean;
  }
}
