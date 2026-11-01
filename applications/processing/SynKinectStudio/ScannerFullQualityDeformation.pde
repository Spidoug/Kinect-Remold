// ===== SynKinect Studio / 3D Scanner / FULL QUALITY non-rigid surface lock =====
// Ported from Kinect_Remold_3D_Reconstruction_v1.0 NativeCore.java. Units are
// metres here (the reference project uses millimetres). The graph is applied
// only in the offline FULL QUALITY pass after rigid ICP + global pose-graph
// optimisation; live Scanner tracking remains rigid and responsive.

class ScannerFqCanonicalSurfel {
  PVector p,n; int color; float weight;
  ScannerFqCanonicalSurfel(PVector p,PVector n,int color,float weight){
    this.p=p.copy();this.n=n!=null?n.copy():new PVector(0,0,-1);
    if(this.n.magSq()>1e-12f)this.n.normalize();this.color=color;this.weight=weight;
  }
}

class ScannerFqCanonicalSurfelMap {
  final ConcurrentHashMap<Long,ScannerFqCanonicalSurfel> cells=new ConcurrentHashMap<Long,ScannerFqCanonicalSurfel>();
  float cellM=.010f; int maxSurfels=420000;
  ScannerFqCanonicalSurfelMap(float cellM){this.cellM=cellM;}
  int vi(float v){return (int)Math.floor(v/cellM);}
  long key(int x,int y,int z){long bx=((long)x+1048576)&0x1fffff,by=((long)y+1048576)&0x1fffff,bz=((long)z+1048576)&0x1fffff;return (bx<<42)|(by<<21)|bz;}
  void clear(){cells.clear();}
  ScannerFqCanonicalSurfel nearestCompatible(PVector p,PVector n,float maxDist,float minNormalCos){
    int x=vi(p.x),y=vi(p.y),z=vi(p.z),rad=Math.max(1,(int)Math.ceil(maxDist/cellM));ScannerFqCanonicalSurfel best=null;float bestScore=Float.POSITIVE_INFINITY;
    for(int dz=-rad;dz<=rad;dz++)for(int dy=-rad;dy<=rad;dy++)for(int dx=-rad;dx<=rad;dx++){
      ScannerFqCanonicalSurfel sf=cells.get(key(x+dx,y+dy,z+dz));if(sf==null)continue;PVector d=PVector.sub(p,sf.p);float euclid=d.mag();if(euclid>maxDist)continue;
      float ndot=1;if(n!=null&&n.magSq()>1e-12f&&sf.n!=null&&sf.n.magSq()>1e-12f){ndot=n.dot(sf.n);if(ndot<minNormalCos)continue;}
      float plane=Math.abs(sf.n.dot(d)),score=euclid+1.8f*plane+(1-ndot)*.012f;if(score<bestScore){bestScore=score;best=sf;}
    }return best;
  }
  void integrate(PVector p,PVector n,int color,float w){
    if(p==null||!Float.isFinite(p.x)||!Float.isFinite(p.y)||!Float.isFinite(p.z)||w<=0)return;long k=key(vi(p.x),vi(p.y),vi(p.z));ScannerFqCanonicalSurfel sf=cells.get(k);
    if(sf==null){if(cells.size()>=maxSurfels)return;ScannerFqCanonicalSurfel fresh=new ScannerFqCanonicalSurfel(p,n,color,w),old=cells.putIfAbsent(k,fresh);sf=old!=null?old:fresh;if(old==null)return;}
    synchronized(sf){float incoming=Math.min(w,4),den=Math.max(1e-6f,sf.weight+incoming),a=incoming/den,ia=1-a;sf.p.mult(ia).add(PVector.mult(p,a));
      if(n!=null&&n.magSq()>1e-12f){PVector nn=n.copy().normalize();if(sf.n.dot(nn)>.15f){sf.n.mult(ia).add(PVector.mult(nn,a));if(sf.n.magSq()>1e-12f)sf.n.normalize();}}
      int ar=(sf.color>>16)&255,ag=(sf.color>>8)&255,ab=sf.color&255,br=(color>>16)&255,bg=(color>>8)&255,bb=color&255;sf.color=0xff000000|(Math.round(ar*ia+br*a)<<16)|(Math.round(ag*ia+bg*a)<<8)|Math.round(ab*ia+bb*a);sf.weight=Math.min(96,sf.weight+incoming);
    }
  }
  ArrayList<ScannerFqCanonicalSurfel> snapshot(int max){ArrayList<ScannerFqCanonicalSurfel> out=new ArrayList<ScannerFqCanonicalSurfel>();int step=Math.max(1,cells.size()/Math.max(1,max)),i=0;for(ScannerFqCanonicalSurfel sf:cells.values()){if((i++%step)==0)out.add(sf);if(out.size()>=max)break;}return out;}
}

class ScannerFqDeformationNode {
  PVector g; RigidTransform T=new RigidTransform(); int[] neighbors=new int[0];
  ScannerFqDeformationNode(PVector g){this.g=g.copy();}
}
class ScannerFqDeformationResult {boolean ok=false;float rmse=Float.POSITIVE_INFINITY,inlierRatio=0,quality=0;int correspondences=0;}

class ScannerFqDeformationGraph {
  class NodeBlend {int[] ids;float[] w;NodeBlend(int k){ids=new int[k];w=new float[k];Arrays.fill(ids,-1);}}
  class PreparedSample {PVector pw,nw;NodeBlend blend;PreparedSample(PVector p,PVector n,NodeBlend b){pw=p;nw=n;blend=b;}}
  final ScannerFqMath math;final ArrayList<ScannerFqDeformationNode> nodes=new ArrayList<ScannerFqDeformationNode>();final HashMap<Long,ArrayList<Integer>> nodeGrid=new HashMap<Long,ArrayList<Integer>>();
  float nodeSpacingM=.050f,gridCellM=.050f;int maxNodes=1400,kBlend=4;
  ScannerFqDeformationGraph(ScannerFqMath math){this.math=math;}
  int gcoord(float v){return (int)Math.floor(v/Math.max(.001f,gridCellM));}
  long gkey(int x,int y,int z){long bx=((long)x+1048576)&0x1fffff,by=((long)y+1048576)&0x1fffff,bz=((long)z+1048576)&0x1fffff;return (bx<<42)|(by<<21)|bz;}
  void addToGrid(int id){PVector p=nodes.get(id).g;long k=gkey(gcoord(p.x),gcoord(p.y),gcoord(p.z));ArrayList<Integer>b=nodeGrid.get(k);if(b==null){b=new ArrayList<Integer>();nodeGrid.put(k,b);}b.add(id);}
  void rebuildSpatialIndex(){nodeGrid.clear();gridCellM=Math.max(.024f,nodeSpacingM);for(int i=0;i<nodes.size();i++)addToGrid(i);}
  void clear(){nodes.clear();nodeGrid.clear();}
  void resetTransforms(){for(ScannerFqDeformationNode n:nodes)n.T.setIdentity();}
  boolean hasNodeNear(PVector p,float radius){if(nodes.isEmpty())return false;int cx=gcoord(p.x),cy=gcoord(p.y),cz=gcoord(p.z),rad=Math.max(1,(int)Math.ceil(radius/gridCellM));float r2=radius*radius;
    for(int dz=-rad;dz<=rad;dz++)for(int dy=-rad;dy<=rad;dy++)for(int dx=-rad;dx<=rad;dx++){ArrayList<Integer>b=nodeGrid.get(gkey(cx+dx,cy+dy,cz+dz));if(b==null)continue;for(int id:b){PVector g=nodes.get(id).g;float x=p.x-g.x,y=p.y-g.y,z=p.z-g.z;if(x*x+y*y+z*z<r2)return true;}}return false;}
  void seedFromFrame(ScannerFqFrame f,RigidTransform worldFromCam,int stride){nodes.clear();nodeGrid.clear();gridCellM=Math.max(.024f,nodeSpacingM);int step=Math.max(1,stride);
    for(int y=0;y<f.h&&nodes.size()<maxNodes;y+=step)for(int x=0;x<f.w&&nodes.size()<maxNodes;x+=step){int i=y*f.w+x;if(!f.valid[i])continue;PVector p=worldFromCam.apply(new PVector(f.x[i],f.y[i],f.z[i]));if(!hasNodeNear(p,nodeSpacingM)){nodes.add(new ScannerFqDeformationNode(p));addToGrid(nodes.size()-1);}}
    rebuildNeighbors();
  }
  void addNodesFromSurfels(ScannerFqCanonicalSurfelMap map){if(nodes.size()>=maxNodes)return;if(nodeGrid.isEmpty())rebuildSpatialIndex();for(ScannerFqCanonicalSurfel sf:map.snapshot(maxNodes*2)){if(!hasNodeNear(sf.p,nodeSpacingM)){nodes.add(new ScannerFqDeformationNode(sf.p));addToGrid(nodes.size()-1);if(nodes.size()>=maxNodes)break;}}rebuildNeighbors();}
  void rebuildNeighbors(){for(int i=0;i<nodes.size();i++){final int self=i;Integer[] ids=new Integer[Math.max(0,nodes.size()-1)];int k=0;for(int j=0;j<nodes.size();j++)if(i!=j)ids[k++]=j;final PVector gi=nodes.get(i).g;
      Arrays.sort(ids,new Comparator<Integer>(){public int compare(Integer a,Integer b){PVector ga=nodes.get(a).g,gb=nodes.get(b).g;float dax=ga.x-gi.x,day=ga.y-gi.y,daz=ga.z-gi.z,dbx=gb.x-gi.x,dby=gb.y-gi.y,dbz=gb.z-gi.z;return Float.compare(dax*dax+day*day+daz*daz,dbx*dbx+dby*dby+dbz*dbz);}});
      int nn=Math.min(4,ids.length);nodes.get(self).neighbors=new int[nn];for(int q=0;q<nn;q++)nodes.get(self).neighbors[q]=ids[q];}rebuildSpatialIndex();}
  void insertNearest(NodeBlend b,float[] d2,int id,float dist2){for(int q=0;q<b.ids.length;q++)if(dist2<d2[q]){for(int r=b.ids.length-1;r>q;r--){d2[r]=d2[r-1];b.ids[r]=b.ids[r-1];}d2[q]=dist2;b.ids[q]=id;break;}}
  NodeBlend blendAt(PVector p){int k=Math.min(kBlend,nodes.size());NodeBlend b=new NodeBlend(k);if(k==0)return b;float[] d2=new float[k];Arrays.fill(d2,Float.POSITIVE_INFINITY);int cx=gcoord(p.x),cy=gcoord(p.y),cz=gcoord(p.z),valid=0;
    for(int radius=1;radius<=12&&valid<k;radius++){for(int dz=-radius;dz<=radius;dz++)for(int dy=-radius;dy<=radius;dy++)for(int dx=-radius;dx<=radius;dx++){if(radius>1&&Math.max(Math.max(Math.abs(dx),Math.abs(dy)),Math.abs(dz))!=radius)continue;ArrayList<Integer> bucket=nodeGrid.get(gkey(cx+dx,cy+dy,cz+dz));if(bucket==null)continue;for(int id:bucket){PVector g=nodes.get(id).g;float ax=p.x-g.x,ay=p.y-g.y,az=p.z-g.z;insertNearest(b,d2,id,ax*ax+ay*ay+az*az);}}valid=0;for(int id:b.ids)if(id>=0)valid++;}
    if(valid==0)return b;float far=.001f;for(float d:d2)if(Float.isFinite(d))far=Math.max(far,(float)Math.sqrt(d));far+=1e-7f;float sum=0;for(int q=0;q<k;q++){if(b.ids[q]<0)continue;float d=(float)Math.sqrt(d2[q]),a=Math.max(0,1-d/far);b.w[q]=a*a;sum+=b.w[q];}if(sum<1e-8f){for(int q=0;q<k;q++)if(b.ids[q]>=0){b.w[q]=1;break;}return b;}for(int q=0;q<k;q++)b.w[q]/=sum;return b;}
  PVector warp(PVector p,NodeBlend b){if(nodes.isEmpty()||b.ids.length==0)return p.copy();float ox=0,oy=0,oz=0;for(int q=0;q<b.ids.length;q++){int id=b.ids[q];float w=b.w[q];if(id<0||w<=0)continue;ScannerFqDeformationNode n=nodes.get(id);float lx=p.x-n.g.x,ly=p.y-n.g.y,lz=p.z-n.g.z;ox+=w*(n.T.m[0]*lx+n.T.m[1]*ly+n.T.m[2]*lz+n.g.x+n.T.m[3]);oy+=w*(n.T.m[4]*lx+n.T.m[5]*ly+n.T.m[6]*lz+n.g.y+n.T.m[7]);oz+=w*(n.T.m[8]*lx+n.T.m[9]*ly+n.T.m[10]*lz+n.g.z+n.T.m[11]);}return new PVector(ox,oy,oz);}
  PVector warpNormal(PVector normal,NodeBlend b){if(normal==null)return null;if(nodes.isEmpty()||b.ids.length==0)return normal.copy();float ox=0,oy=0,oz=0;for(int q=0;q<b.ids.length;q++){int id=b.ids[q];float w=b.w[q];if(id<0||w<=0)continue;RigidTransform T=nodes.get(id).T;ox+=w*(T.m[0]*normal.x+T.m[1]*normal.y+T.m[2]*normal.z);oy+=w*(T.m[4]*normal.x+T.m[5]*normal.y+T.m[6]*normal.z);oz+=w*(T.m[8]*normal.x+T.m[9]*normal.y+T.m[10]*normal.z);}PVector out=new PVector(ox,oy,oz);if(out.magSq()>1e-12f)out.normalize();return out;}
  ScannerFqDeformationResult solve(ScannerFqFrame frame,RigidTransform worldFromCam,ScannerFqCanonicalSurfelMap model,int sampleStride,int iterations){ScannerFqDeformationResult result=new ScannerFqDeformationResult();if(nodes.size()<4||model.cells.size()<200)return result;if(nodeGrid.isEmpty())rebuildSpatialIndex();int step=Math.max(1,sampleStride);ArrayList<PreparedSample> prepared=new ArrayList<PreparedSample>(Math.max(1024,(frame.w/step)*(frame.h/step)/2));
    for(int y=2;y<frame.h-2;y+=step)for(int x=2;x<frame.w-2;x+=step){int idx=y*frame.w+x;if(!frame.valid[idx]||!frame.continuous(x,y,.045f))continue;PVector fn=frame.fullNormal(x,y);if(fn==null||fn.magSq()<1e-12f)continue;PVector pw=worldFromCam.apply(new PVector(frame.x[idx],frame.y[idx],frame.z[idx])),nw=worldFromCam.rotate(fn);if(nw.magSq()<1e-12f)continue;nw.normalize();NodeBlend blend=blendAt(pw);boolean usable=false;for(int id:blend.ids)if(id>=0){usable=true;break;}if(usable)prepared.add(new PreparedSample(pw,nw,blend));}
    if(prepared.size()<140)return result;float lastErr=Float.POSITIVE_INFINITY;int lastPairs=0,lastIn=0;
    for(int it=0;it<iterations;it++){float[][][] A=new float[nodes.size()][6][6];float[][] b=new float[nodes.size()][6];float[] support=new float[nodes.size()];float err2=0,errW=0;int pairs=0,inliers=0;
      for(PreparedSample ps:prepared){PVector q=warp(ps.pw,ps.blend),qn=warpNormal(ps.nw,ps.blend);ScannerFqCanonicalSurfel sf=model.nearestCompatible(q,qn,.034f,.55f);if(sf==null)continue;PVector diff=PVector.sub(q,sf.p);float euclid=diff.mag(),r=sf.n.dot(diff);if(euclid>.034f||Math.abs(r)>.020f)continue;float normalCos=Math.max(0,qn.dot(sf.n));float robust=math.huber(r,.006f)*tukey(r,.020f),geom=(float)Math.exp(-(euclid*euclid)/(2*.018f*.018f)),dataWeight=robust*geom*normalCos*normalCos;if(dataWeight<.02f)continue;
        for(int k=0;k<ps.blend.ids.length;k++){int ni=ps.blend.ids[k];float bw=ps.blend.w[k];if(ni<0||bw<=0)continue;ScannerFqDeformationNode nd=nodes.get(ni);float lx=ps.pw.x-nd.g.x,ly=ps.pw.y-nd.g.y,lz=ps.pw.z-nd.g.z;PVector rn=new PVector(nd.T.m[0]*lx+nd.T.m[1]*ly+nd.T.m[2]*lz,nd.T.m[4]*lx+nd.T.m[5]*ly+nd.T.m[6]*lz,nd.T.m[8]*lx+nd.T.m[9]*ly+nd.T.m[10]*lz),cross=rn.cross(sf.n);float[] J={cross.x,cross.y,cross.z,sf.n.x,sf.n.y,sf.n.z};float ww=dataWeight*bw*bw;for(int a=0;a<6;a++){b[ni][a]+=ww*J[a]*(-r);for(int c=0;c<6;c++)A[ni][a][c]+=ww*J[a]*J[c];}support[ni]+=ww;}
        err2+=dataWeight*r*r;errW+=dataWeight;pairs++;if(Math.abs(r)<.0075f&&euclid<.015f)inliers++;}
      for(int ni=0;ni<nodes.size();ni++){if(support[ni]<1)continue;ScannerFqDeformationNode nd=nodes.get(ni);float[] mean=new float[6];int cnt=0;for(int nb:nd.neighbors){float[] lx=math.log(nodes.get(nb).T);for(int k=0;k<6;k++)mean[k]+=lx[k];cnt++;}if(cnt>0)for(int k=0;k<6;k++)mean[k]/=cnt;float[] self=math.log(nd.T);float lambda=.60f*support[ni]+2.5f;for(int k=0;k<6;k++){A[ni][k][k]+=lambda;b[ni][k]+=lambda*(mean[k]-self[k]);}float[] d=new float[6];if(!math.solve6(A[ni],b[ni],d))continue;float rn=(float)Math.sqrt(d[0]*d[0]+d[1]*d[1]+d[2]*d[2]),maxR=(float)Math.toRadians(2);if(rn>maxR){float sc=maxR/rn;d[0]*=sc;d[1]*=sc;d[2]*=sc;}float tn=(float)Math.sqrt(d[3]*d[3]+d[4]*d[4]+d[5]*d[5]);if(tn>.008f){float sc=.008f/tn;d[3]*=sc;d[4]*=sc;d[5]*=sc;}nd.T=math.exp(d).multiply(nd.T);}
      if(pairs>0&&errW>0){lastErr=(float)Math.sqrt(err2/errW);lastPairs=pairs;lastIn=inliers;}if(lastErr<.0028f)break;
    }
    result.rmse=lastErr;result.correspondences=lastPairs;result.inlierRatio=lastPairs>0?(float)lastIn/lastPairs:0;float rmseScore=Float.isFinite(lastErr)?Math.max(0,Math.min(1,1-lastErr/.014f)):0,pairScore=Math.max(0,Math.min(1,lastPairs/900.0f));result.quality=.52f*result.inlierRatio+.30f*rmseScore+.18f*pairScore;result.ok=lastPairs>=140&&Float.isFinite(lastErr)&&lastErr<.012f&&result.inlierRatio>.52f&&result.quality>.55f;return result;
  }
  float tukey(float r,float c){float a=Math.abs(r);if(a>=c)return 0;float u=r/c,q=1-u*u;return q*q;}
}
