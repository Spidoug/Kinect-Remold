// ===== SynKinect Studio / 3D Scanner / Mesh.pde =====
class Triangle3D {
  PVector a,b,c,n=new PVector();
  int ca,cb,cc;
  Triangle3D(PVector a,PVector b,PVector c){this(a,b,c,0,0,0);}
  Triangle3D(PVector a,PVector b,PVector c,int ca,int cb,int cc){this.a=a;this.b=b;
    this.c=c;this.ca=ca;this.cb=cb;this.cc=cc;recalc();}
  void recalc(){
    float ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z;
    float nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx,magSq=nx*nx+ny*ny+nz*nz;
    if(magSq<=1e-12f){n.set(0,0,0);return;}float inv=1.0f/sqrt(magSq);n.set(nx*inv,ny*inv,nz*inv);
  }
  PVector center(){ return new PVector((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3);
     }
}

class Mesh3D {
  ArrayList<Triangle3D> triangles=new ArrayList<Triangle3D>();
  void clear(){triangles.clear();}
  int triangleCount(){return triangles.size();}
  void addTriangle(PVector a,PVector b,PVector c){addTriangle(a,b,c,0,0,0);}
  void addTriangle(PVector a,PVector b,PVector c,int ca,int cb,int cc){
    float ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z;
    float nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx;
    if(nx*nx+ny*ny+nz*nz>1e-12f)triangles.add(new Triangle3D(a,b,c,ca,cb,cc));
  }
  void recalculateNormals(){for(Triangle3D t:triangles)t.recalc();}
  boolean hasVertexColor(){for(Triangle3D t:triangles)if(((t.ca>>>24)&255)!=0||((t.cb>>>24)&255)!=0||((t.cc>>>24)&255)!=0)return true;return false;}

  Mesh3D deepCopy(){
    Mesh3D copy=new Mesh3D();
    for(Triangle3D t:triangles) copy.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);

    return copy;
  }

  PVector boundsCenter(){
    if(triangles.size()==0) return new PVector();
    float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;

    float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;

    for(Triangle3D t:triangles){
      PVector[] v={t.a,t.b,t.c};
      for(PVector p:v){ minX=min(minX,p.x); minY=min(minY,p.y); minZ=min(minZ,p.z);
         maxX=max(maxX,p.x); maxY=max(maxY,p.y); maxZ=max(maxZ,p.z); }
    }
    return new PVector((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
  }

  float boundsRadius(){
    if(triangles.size()==0) return 0.2f;
    PVector c=boundsCenter();
    float r=0.0f;
    for(Triangle3D t:triangles){
      r=max(r,max(PVector.dist(c,t.a),max(PVector.dist(c,t.b),PVector.dist(c,t.c))));

    }
    return max(r,0.01f);
  }

  // Mesh vertex colors use ARGB. A zero alpha channel means the triangle
  // has no captured color, so the current theme shade is used.
  int renderColor(int c,int defaultColor){ return ((c>>>24)&255)==0 ? defaultColor : c; }

}


// ===== SynKinect Studio / 3D Scanner / MeshEditing.pde =====
class MeshEditor {
 final AppConfig cfg;
  MeshEditor(AppConfig cfg){ this.cfg=cfg; }

  Mesh3D filterGeometry(Mesh3D source){
    Mesh3D filtered=new Mesh3D();if(source==null)return filtered;
    float maxEdgeSq=cfg.meshCleanupMaxEdgeM*cfg.meshCleanupMaxEdgeM,minCrossSq=4.0f*cfg.meshCleanupMinAreaM2*cfg.meshCleanupMinAreaM2;
    for(Triangle3D t:source.triangles){
      float abx=t.b.x-t.a.x,aby=t.b.y-t.a.y,abz=t.b.z-t.a.z;
      float bcx=t.c.x-t.b.x,bcy=t.c.y-t.b.y,bcz=t.c.z-t.b.z;
      float cax=t.a.x-t.c.x,cay=t.a.y-t.c.y,caz=t.a.z-t.c.z;
      if(abx*abx+aby*aby+abz*abz>maxEdgeSq||bcx*bcx+bcy*bcy+bcz*bcz>maxEdgeSq||cax*cax+cay*cay+caz*caz>maxEdgeSq)continue;
      float acx=t.c.x-t.a.x,acy=t.c.y-t.a.y,acz=t.c.z-t.a.z;
      float nx=aby*acz-abz*acy,ny=abz*acx-abx*acz,nz=abx*acy-aby*acx;
      if(nx*nx+ny*ny+nz*nz<minCrossSq)continue;
      filtered.addTriangle(t.a,t.b,t.c,t.ca,t.cb,t.cc);
    }
    return filtered;
  }

  // Scanner output must be a coherent object, not a raw TSDF dump. Perform the
  // topology-safe cleanup automatically at mesh generation/export time: remove
  // implausible triangles, the support/floor band and tiny disconnected islands.
  // Smoothing remains explicit so real surface detail is never silently softened.
  Mesh3D prepareGeneratedMesh(Mesh3D source){
    Mesh3D filtered=filterGeometry(source);
    Mesh3D supportTrimmed=removeFloorAndScanDebris(filtered);
    // addTriangle() computes each triangle normal as it is emitted, so a full
    // second normal pass here is redundant on large generated meshes.
    return removeSmallComponents(supportTrimmed);
  }

  Mesh3D clean(Mesh3D source){
    Mesh3D filtered=filterGeometry(source);Mesh3D floorTrimmed=removeFloorAndScanDebris(filtered);
    return removeSmallComponents(floorTrimmed);
  }
  Mesh3D removeFloorAndScanDebris(Mesh3D source){
    if(source==null||source.triangleCount()==0)return new Mesh3D();float minY=Float.POSITIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY;
    for(Triangle3D t:source.triangles)for(PVector v:new PVector[]{t.a,t.b,t.c}){minY=min(minY,v.y);maxY=max(maxY,v.y);}
    float span=max(.001f,maxY-minY),floorBand=max(.012f,span*.045f);Mesh3D out=new Mesh3D();
    for(Triangle3D t:source.triangles){PVector c=t.center();if(c.y>maxY-floorBand&&abs(t.n.y)>.72f)continue;
      float ab=PVector.dist(t.a,t.b),bc=PVector.dist(t.b,t.c),ca=PVector.dist(t.c,t.a);if(max(ab,max(bc,ca))>cfg.meshCleanupMaxEdgeM)continue;
      // Intermediate cleanup meshes are immutable. Reuse vertices here and copy
      // only when materializing the final component set.
      out.addTriangle(t.a,t.b,t.c,t.ca,t.cb,t.cc);}return out;
  }

  Mesh3D smooth(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D work=source.deepCopy();
    for(int i=0;i<cfg.meshSmoothIterations;i++)smoothPass(work,cfg.meshSmoothLambda);

    work.recalculateNormals();return work;
  }

  Mesh3D polish(Mesh3D source){
    Mesh3D work=clean(source);
    // Smooth works identically for a complete scan or the currently reconstructed
    // partial surface. Weld first so topology is coherent enough to identify holes.
    work=weldAndMerge(work);
    // Close only small, bounded holes caused by missing depth samples. Large open
    // boundaries (for example the unfinished side of a partial scan) are preserved.
    if(cfg.meshHoleFillEnabled)work=fillSmallHoles(work);
    // Taubin lambda/mu relaxation removes triangular stair-stepping without the
    // strong shrinkage of ordinary Laplacian smoothing. Open boundaries are pinned.
    // Detail-preserving Taubin polish with an automatic work budget. Large meshes
    // get fewer passes, preventing the UI from appearing frozen while avoiding
    // repeated smoothing that can erase real ridges and corners.
    int polishPasses=cfg.meshPolishIterations;
    if(work.triangleCount()>450000)polishPasses=min(polishPasses,1);
    else if(work.triangleCount()>220000)polishPasses=min(polishPasses,2);
    for(int i=0;i<polishPasses;i++){
      adaptiveSurfacePass(work,cfg.meshPolishLambda);adaptiveSurfacePass(work,cfg.meshPolishMu);
      Thread.yield();
    }
    work=weldAndMerge(work);
    work.recalculateNormals();return work;
  }

  void adaptiveSurfacePass(Mesh3D mesh,float factor){
    if(mesh==null||mesh.triangleCount()==0)return;HashMap<Long,PVector> sum=new HashMap<Long,PVector>();HashMap<Long,Integer> count=new HashMap<Long,Integer>();
    HashMap<Long,PVector> normalSum=new HashMap<Long,PVector>();HashMap<Long,HashSet<Long>> neighbors=new HashMap<Long,HashSet<Long>>();
    for(Triangle3D t:mesh.triangles){long a=key(t.a),b=key(t.b),c=key(t.c);addVertex(sum,count,a,t.a);addVertex(sum,count,b,t.b);addVertex(sum,count,c,t.c);addNormal(normalSum,a,t.n);addNormal(normalSum,b,t.n);addNormal(normalSum,c,t.n);connect(neighbors,a,b);connect(neighbors,b,c);connect(neighbors,c,a);}
    HashMap<Long,PVector> moved=new HashMap<Long,PVector>();
    for(Long k:sum.keySet()){PVector base=sum.get(k).copy();base.div(max(1,count.get(k)));HashSet<Long> ns=neighbors.get(k);if(ns==null||ns.size()<3){moved.put(k,base);continue;}
      PVector avg=new PVector();int n=0;for(Long qk:ns){PVector q=sum.get(qk);Integer qc=count.get(qk);if(q!=null&&qc!=null){avg.add(PVector.div(q.copy(),max(1,qc)));n++;}}if(n<2){moved.put(k,base);continue;}avg.div(n);
      PVector normal=normalSum.get(k);if(normal==null||normal.magSq()<1e-8f){moved.put(k,PVector.lerp(base,avg,abs(factor)));continue;}normal=normal.copy().normalize();float curvature=0;
      for(Long qk:ns){PVector qn=normalSum.get(qk);if(qn!=null&&qn.magSq()>1e-8f)curvature+=1.0f-abs(normal.dot(qn.copy().normalize()));}curvature/=max(1,ns.size());
      float strength=abs(factor)*constrain(1.0f-curvature*2.8f,.18f,1.0f);PVector delta=PVector.sub(avg,base);if(factor<0)delta.mult(-1);moved.put(k,PVector.add(base,PVector.mult(delta,strength)));}
    for(Triangle3D t:mesh.triangles){PVector a=moved.get(key(t.a)),b=moved.get(key(t.b)),c=moved.get(key(t.c));if(a!=null)t.a.set(a);if(b!=null)t.b.set(b);if(c!=null)t.c.set(c);t.recalc();}
  }
  void addNormal(HashMap<Long,PVector> normals,long k,PVector n){PVector v=normals.get(k);if(v==null){v=new PVector();normals.put(k,v);}v.add(n);}
  Mesh3D solidifyOpenSurface(Mesh3D source){
    if(source==null||source.triangleCount()==0)return source==null?new Mesh3D():source;Mesh3D out=weldAndMerge(source);
    HashMap<String,Integer> edgeCount=new HashMap<String,Integer>();HashMap<String,long[]> edgeEnds=new HashMap<String,long[]>();HashMap<Long,PVector> pos=new HashMap<Long,PVector>();
    float maxZ=Float.NEGATIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;for(Triangle3D t:out.triangles){long a=key(t.a),b=key(t.b),c=key(t.c);pos.put(a,t.a);pos.put(b,t.b);pos.put(c,t.c);
      maxZ=max(maxZ,max(t.a.z,max(t.b.z,t.c.z)));minZ=min(minZ,min(t.a.z,min(t.b.z,t.c.z)));addEdge(edgeCount,edgeEnds,a,b);addEdge(edgeCount,edgeEnds,b,c);addEdge(edgeCount,edgeEnds,c,a);}
    HashMap<Long,ArrayList<Long>> boundary=new HashMap<Long,ArrayList<Long>>();for(String ek:edgeCount.keySet())if(edgeCount.get(ek)==1){long[] e=edgeEnds.get(ek);connectBoundary(boundary,e[0],e[1]);}
    if(boundary.isEmpty())return out;float backZ=maxZ+max(.008f,(maxZ-minZ)*.025f);HashSet<Long> visited=new HashSet<Long>();
    for(Long seed:boundary.keySet()){if(visited.contains(seed))continue;ArrayList<Long> loop=traceOpenBoundary(seed,boundary,visited);if(loop.size()<3)continue;PVector center=new PVector();ArrayList<PVector> back=new ArrayList<PVector>();
      for(Long k:loop){PVector v=pos.get(k);if(v==null)continue;PVector bv=new PVector(v.x,v.y,backZ);back.add(bv);center.add(bv);}if(back.size()!=loop.size()||back.size()<3)continue;center.div(back.size());
      for(int i=0;i<back.size();i++){PVector a=pos.get(loop.get(i)),b=pos.get(loop.get((i+1)%loop.size())),ba=back.get(i),bb=back.get((i+1)%back.size());out.addTriangle(a.copy(),b.copy(),bb.copy());out.addTriangle(a.copy(),bb.copy(),ba.copy());out.addTriangle(bb.copy(),center.copy(),ba.copy());}}
    out.recalculateNormals();return out;
  }
  ArrayList<Long> traceOpenBoundary(long seed,HashMap<Long,ArrayList<Long>> g,HashSet<Long> visited){ArrayList<Long> loop=new ArrayList<Long>();long prev=Long.MIN_VALUE,cur=seed;
    for(int guard=0;guard<200000;guard++){if(visited.contains(cur)&&cur!=seed)break;loop.add(cur);visited.add(cur);ArrayList<Long> n=g.get(cur);if(n==null||n.isEmpty())break;long next=n.get(0);if(next==prev&&n.size()>1)next=n.get(1);prev=cur;cur=next;if(cur==seed)break;}return loop;}
  Mesh3D fillSmallHoles(Mesh3D source){
    if(source==null||source.triangleCount()==0)return source==null?new Mesh3D():source;
    HashMap<String,Integer> edgeCount=new HashMap<String,Integer>();
    HashMap<String,long[]> edgeEnds=new HashMap<String,long[]>();
    HashMap<Long,PVector> pos=new HashMap<Long,PVector>();
    HashMap<Long,Integer> colorSumR=new HashMap<Long,Integer>(),colorSumG=new HashMap<Long,Integer>(),colorSumB=new HashMap<Long,Integer>(),colorN=new HashMap<Long,Integer>();
    for(Triangle3D t:source.triangles){
      long ka=key(t.a),kb=key(t.b),kc=key(t.c);pos.put(ka,t.a);pos.put(kb,t.b);pos.put(kc,t.c);
      addColorSample(colorSumR,colorSumG,colorSumB,colorN,ka,t.ca);addColorSample(colorSumR,colorSumG,colorSumB,colorN,kb,t.cb);addColorSample(colorSumR,colorSumG,colorSumB,colorN,kc,t.cc);
      addEdge(edgeCount,edgeEnds,ka,kb);addEdge(edgeCount,edgeEnds,kb,kc);addEdge(edgeCount,edgeEnds,kc,ka);
    }
    HashMap<Long,ArrayList<Long>> boundary=new HashMap<Long,ArrayList<Long>>();
    for(String ek:edgeCount.keySet())if(edgeCount.get(ek)==1){long[] e=edgeEnds.get(ek);connectBoundary(boundary,e[0],e[1]);}
    HashSet<Long> visited=new HashSet<Long>();Mesh3D out=source.deepCopy();
    for(Long seed:boundary.keySet()){
      if(visited.contains(seed))continue;ArrayList<Long> loop=traceBoundaryLoop(seed,boundary,visited);
      if(loop.size()<3||loop.size()>cfg.meshHoleFillMaxEdges)continue;
      float perimeter=0,maxDiameter=0;PVector center=new PVector();boolean valid=true;
      for(int i=0;i<loop.size();i++){PVector a=pos.get(loop.get(i)),b=pos.get(loop.get((i+1)%loop.size()));if(a==null||b==null){valid=false;break;}center.add(a);perimeter+=PVector.dist(a,b);}
      if(!valid)continue;center.div(loop.size());
      for(Long k:loop){PVector a=pos.get(k);maxDiameter=max(maxDiameter,2.0f*PVector.dist(a,center));}
      if(perimeter>cfg.meshHoleFillMaxPerimeterM||maxDiameter>cfg.meshHoleFillMaxDiameterM)continue;
      int cc=averageLoopColor(loop,colorSumR,colorSumG,colorSumB,colorN);
      for(int i=0;i<loop.size();i++){
        long ka=loop.get(i),kb=loop.get((i+1)%loop.size());PVector a=pos.get(ka),b=pos.get(kb);
        int ca=vertexColor(ka,colorSumR,colorSumG,colorSumB,colorN),cb=vertexColor(kb,colorSumR,colorSumG,colorSumB,colorN);
        out.addTriangle(a.copy(),b.copy(),center.copy(),ca,cb,cc);
      }
    }
    out.recalculateNormals();return out;
  }

  void addEdge(HashMap<String,Integer> counts,HashMap<String,long[]> ends,long a,long b){long lo=a<b?a:b,hi=a<b?b:a;String k=lo+":"+hi;counts.put(k,counts.containsKey(k)?counts.get(k)+1:1);if(!ends.containsKey(k))ends.put(k,new long[]{a,b});}
  void connectBoundary(HashMap<Long,ArrayList<Long>> g,long a,long b){ArrayList<Long> aa=g.get(a);if(aa==null){aa=new ArrayList<Long>();g.put(a,aa);}if(!aa.contains(b))aa.add(b);ArrayList<Long> bb=g.get(b);if(bb==null){bb=new ArrayList<Long>();g.put(b,bb);}if(!bb.contains(a))bb.add(a);}
  ArrayList<Long> traceBoundaryLoop(long seed,HashMap<Long,ArrayList<Long>> g,HashSet<Long> visited){ArrayList<Long> loop=new ArrayList<Long>();long prev=Long.MIN_VALUE,cur=seed;for(int guard=0;guard<cfg.meshHoleFillMaxEdges+2;guard++){loop.add(cur);visited.add(cur);ArrayList<Long> n=g.get(cur);if(n==null||n.size()!=2)return new ArrayList<Long>();long next=n.get(0)==prev?n.get(1):n.get(0);prev=cur;cur=next;if(cur==seed)return loop;if(visited.contains(cur))return new ArrayList<Long>();}return new ArrayList<Long>();}
  void addColorSample(HashMap<Long,Integer> r,HashMap<Long,Integer> g,HashMap<Long,Integer> b,HashMap<Long,Integer> n,long k,int c){if(((c>>>24)&255)==0)return;r.put(k,(r.containsKey(k)?r.get(k):0)+((c>>16)&255));g.put(k,(g.containsKey(k)?g.get(k):0)+((c>>8)&255));b.put(k,(b.containsKey(k)?b.get(k):0)+(c&255));n.put(k,(n.containsKey(k)?n.get(k):0)+1);}
  int vertexColor(long k,HashMap<Long,Integer> r,HashMap<Long,Integer> g,HashMap<Long,Integer> b,HashMap<Long,Integer> n){int nn=n.containsKey(k)?n.get(k):0;if(nn<=0)return 0;return 0xff000000|((r.get(k)/nn)<<16)|((g.get(k)/nn)<<8)|(b.get(k)/nn);}
  int averageLoopColor(ArrayList<Long> loop,HashMap<Long,Integer> r,HashMap<Long,Integer> g,HashMap<Long,Integer> b,HashMap<Long,Integer> n){long rr=0,gg=0,bb=0,nn=0;for(Long k:loop){int q=n.containsKey(k)?n.get(k):0;if(q>0){rr+=r.get(k);gg+=g.get(k);bb+=b.get(k);nn+=q;}}if(nn==0)return 0;return 0xff000000|(((int)(rr/nn))<<16)|(((int)(gg/nn))<<8)|((int)(bb/nn));}

  Mesh3D weldAndMerge(Mesh3D source){
    Mesh3D out=new Mesh3D();if(source==null)return out;
    HashMap<Long,PVector> sums=new HashMap<Long,PVector>();HashMap<Long,Integer> counts=new HashMap<Long,Integer>();
    for(Triangle3D t:source.triangles){addVertex(sums,counts,key(t.a),t.a);addVertex(sums,counts,key(t.b),t.b);addVertex(sums,counts,key(t.c),t.c);}
    HashMap<Long,PVector> canonical=new HashMap<Long,PVector>();
    for(Long k:sums.keySet()){PVector v=sums.get(k).copy();v.div(max(1,counts.get(k)));canonical.put(k,v);}
    HashSet<String> faces=new HashSet<String>();
    for(Triangle3D t:source.triangles){long ka=key(t.a),kb=key(t.b),kc=key(t.c);if(ka==kb||kb==kc||kc==ka)continue;
      long[] sk={ka,kb,kc};Arrays.sort(sk);String fk=sk[0]+":"+sk[1]+":"+sk[2];if(!faces.add(fk))continue;
      PVector a=canonical.get(ka),b=canonical.get(kb),c=canonical.get(kc);if(a==null||b==null||c==null)continue;
      PVector ab=PVector.sub(b,a),ac=PVector.sub(c,a);if(ab.cross(ac).magSq()<4.0f*cfg.meshCleanupMinAreaM2*cfg.meshCleanupMinAreaM2)continue;
      out.addTriangle(a.copy(),b.copy(),c.copy(),t.ca,t.cb,t.cc);
    }
    return out;
  }

  Mesh3D polishHighQuality(Mesh3D source){
    Mesh3D work=clean(source);
    for(int i=0;i<cfg.hqMeshPolishIterations;i++){adaptiveSurfacePass(work,cfg.hqMeshPolishLambda);
      adaptiveSurfacePass(work,cfg.hqMeshPolishMu);}
    work.recalculateNormals();return work;
  }

  void smoothPass(Mesh3D mesh,float factor){
    HashMap<Long,PVector> sum=new HashMap<Long,PVector>();
    HashMap<Long,Integer> count=new HashMap<Long,Integer>();
    HashMap<Long,HashSet<Long>> neighbors=new HashMap<Long,HashSet<Long>>();
    for(Triangle3D t:mesh.triangles){
      long ka=key(t.a),kb=key(t.b),kc=key(t.c);
      addVertex(sum,count,ka,t.a);addVertex(sum,count,kb,t.b);addVertex(sum,count,kc,t.c);

      connect(neighbors,ka,kb);connect(neighbors,kb,kc);connect(neighbors,kc,ka);

    }
    // Boundary vertices stay fixed. This prevents smoothing from widening an
    // unfinished partial scan or rounding the rim of a legitimate opening.
    HashMap<String,Integer> smoothEdgeCount=new HashMap<String,Integer>();HashMap<String,long[]> smoothEdgeEnds=new HashMap<String,long[]>();
    for(Triangle3D t:mesh.triangles){addEdge(smoothEdgeCount,smoothEdgeEnds,key(t.a),key(t.b));addEdge(smoothEdgeCount,smoothEdgeEnds,key(t.b),key(t.c));addEdge(smoothEdgeCount,smoothEdgeEnds,key(t.c),key(t.a));}
    HashSet<Long> boundaryVertices=new HashSet<Long>();for(String ek:smoothEdgeCount.keySet())if(smoothEdgeCount.get(ek)==1){long[] e=smoothEdgeEnds.get(ek);boundaryVertices.add(e[0]);boundaryVertices.add(e[1]);}
    HashMap<Long,PVector> center=new HashMap<Long,PVector>(sum.size()*2);
    for(Long k:sum.keySet()){PVector p=sum.get(k).copy();p.div(max(1,count.get(k)));
      center.put(k,p);}
    HashMap<Long,PVector> moved=new HashMap<Long,PVector>(center.size()*2);
    for(Long k:center.keySet()){
      PVector base=center.get(k),avg=new PVector();int n=0;HashSet<Long> adj=neighbors.get(k);
      if(boundaryVertices.contains(k)){moved.put(k,base.copy());continue;}

      if(adj!=null)for(Long other:adj){PVector q=center.get(other);if(q!=null){avg.add(q);
          n++;}}
      if(n<2){moved.put(k,base.copy());continue;}
      avg.div(n);PVector delta=PVector.sub(avg,base);moved.put(k,PVector.add(base,PVector.mult(delta,factor)));

    }
    for(Triangle3D t:mesh.triangles){PVector a=moved.get(key(t.a)),b=moved.get(key(t.b)),c=moved.get(key(t.c));
      if(a!=null)t.a.set(a);if(b!=null)t.b.set(b);if(c!=null)t.c.set(c);}
  }

  Mesh3D removeSmallComponents(Mesh3D source){
    if(source==null||source.triangleCount()==0)return new Mesh3D();
    int n=source.triangleCount();
    HashMap<Long,ArrayList<Integer>> incidence=new HashMap<Long,ArrayList<Integer>>();

    for(int i=0;i<n;i++){
      Triangle3D t=source.triangles.get(i);addIncidence(incidence,key(t.a),i);addIncidence(incidence,key(t.b),i);
      addIncidence(incidence,key(t.c),i);
    }
    boolean[] seen=new boolean[n];ArrayList<ArrayList<Integer>> groups=new ArrayList<ArrayList<Integer>>();
    int largest=0;
    for(int seed=0;seed<n;seed++){
      if(seen[seed])continue;ArrayList<Integer> group=new ArrayList<Integer>();ArrayDeque<Integer> q=new ArrayDeque<Integer>();
      q.add(seed);seen[seed]=true;
      while(!q.isEmpty()){
        int i=q.removeFirst();group.add(i);Triangle3D t=source.triangles.get(i);long[] keys={key(t.a),key(t.b),key(t.c)};

        for(long k:keys){ArrayList<Integer> linked=incidence.get(k);if(linked==null)continue;
          for(Integer other:linked)if(!seen[other]){seen[other]=true;q.addLast(other);
            }}
      }
      groups.add(group);largest=max(largest,group.size());
    }
    int threshold=max(cfg.meshMinimumComponentTriangles,round(largest*cfg.meshMinimumComponentRatio));

    Mesh3D out=new Mesh3D();
    for(ArrayList<Integer> group:groups)if(group.size()>=threshold)for(Integer idx:group){Triangle3D t=source.triangles.get(idx);
      out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    if(out.triangleCount()==0){
      ArrayList<Integer> best=null;for(ArrayList<Integer> group:groups)if(best==null||group.size()>best.size())best=group;

      if(best!=null)for(Integer idx:best){Triangle3D t=source.triangles.get(idx);
        out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    }
    return out;
  }

  Mesh3D center(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D out=source.deepCopy();PVector c=out.boundsCenter();
    for(Triangle3D t:out.triangles){t.a.sub(c);t.b.sub(c);t.c.sub(c);t.recalc();}return out;

  }

  long key(PVector p){
    float q=max(0.000001f,cfg.meshWeldToleranceM);long x=round(p.x/q),y=round(p.y/q),z=round(p.z/q);

    return ((x&0x1FFFFFL)<<42)|((y&0x1FFFFFL)<<21)|(z&0x1FFFFFL);
  }
  void addIncidence(HashMap<Long,ArrayList<Integer>> m,long k,int i){ArrayList<Integer> list=m.get(k);
    if(list==null){list=new ArrayList<Integer>();m.put(k,list);}list.add(i);}
  void addVertex(HashMap<Long,PVector> sum,HashMap<Long,Integer> count,long k,PVector p){PVector acc=sum.get(k);
    if(acc==null){acc=new PVector();sum.put(k,acc);count.put(k,0);}acc.add(p);count.put(k,count.get(k)+1);
    }
  void connect(HashMap<Long,HashSet<Long>> n,long a,long b){if(a==b)return;HashSet<Long> aa=n.get(a);
    if(aa==null){aa=new HashSet<Long>();n.put(a,aa);}aa.add(b);HashSet<Long> bb=n.get(b);
    if(bb==null){bb=new HashSet<Long>();n.put(b,bb);}bb.add(a);}
}
