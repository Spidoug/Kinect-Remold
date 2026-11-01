// ===== SynKinect Studio / 3D Scanner / Exporters.pde =====
class ExportSpace {
  PVector position(PVector p) { return new PVector(p.x, -p.y, p.z); }
  Triangle3D triangle(Triangle3D t) {
    // Y reflection reverses handedness; swapping B/C preserves outward winding.
    return new Triangle3D(position(t.a), position(t.c), position(t.b), t.ca, t.cc, t.cb);

  }
}

class VertexKey {
  final long x,y,z;
  VertexKey(float px,float py,float pz,float q){x=Math.round(px/q);y=Math.round(py/q);z=Math.round(pz/q);}
  public int hashCode(){long h=x*73856093L^y*19349663L^z*83492791L;return(int)(h^(h>>>32));}
  public boolean equals(Object o){if(!(o instanceof VertexKey))return false;VertexKey k=(VertexKey)o;return x==k.x&&y==k.y&&z==k.z;}
}
class FaceKey {
  final int a,b,c;
  FaceKey(int x,int y,int z){
    int lo=Math.min(x,Math.min(y,z)),hi=Math.max(x,Math.max(y,z));
    a=lo;c=hi;b=x+y+z-lo-hi;
  }
  public int hashCode(){return (a*73856093)^(b*19349663)^(c*83492791);}
  public boolean equals(Object o){if(!(o instanceof FaceKey))return false;FaceKey k=(FaceKey)o;return a==k.a&&b==k.b&&c==k.c;}
}
class VertexAccum {
  float x,y,z;long a,r,g,b;int count;
  void add(float px,float py,float pz,int colorValue){x+=px;y+=py;z+=pz;a+=(colorValue>>>24)&255;r+=(colorValue>>16)&255;g+=(colorValue>>8)&255;b+=colorValue&255;count++;}
  PVector point(){float n=Math.max(1,count);return new PVector(x/n,y/n,z/n);}
  int colorValue(){int n=Math.max(1,count),aa=(int)(a/n),rr=(int)(r/n),gg=(int)(g/n),bb=(int)(b/n);return ((aa&255)<<24)|((rr&255)<<16)|((gg&255)<<8)|(bb&255);}
}
class IndexedFace {
  int a,b,c;Triangle3D source;
  IndexedFace(int a,int b,int c,Triangle3D source){this.a=a;this.b=b;this.c=c;this.source=source;}
}
class IndexedMesh {
  ArrayList<PVector> vertices=new ArrayList<PVector>();
  ArrayList<PVector> normals=new ArrayList<PVector>();
  ArrayList<Integer> colors=new ArrayList<Integer>();
  ArrayList<IndexedFace> faces=new ArrayList<IndexedFace>();
  float toleranceM;
}
class MeshCompactor {
  AppConfig cfg;
  MeshCompactor(AppConfig cfg){this.cfg=cfg;}
  IndexedMesh compact(Mesh3D source){
    float base=Math.max(0.00001f,cfg.exportWeldToleranceM),limit=Math.max(base,cfg.exportMaxWeldToleranceM);
    int sourceFaces=source==null?0:source.triangleCount();
    if(sourceFaces==0)return compactAt(source,base);
    // Surface complexity scales approximately with 1/q^2. Start near the useful
    // tolerance instead of rebuilding the complete mesh six times in tiny steps.
    float q=base;
    if(sourceFaces>cfg.exportMaxTriangles){
      float ratio=sourceFaces/(float)Math.max(1,cfg.exportMaxTriangles);
      q=Math.min(limit,Math.max(base,base*(float)Math.sqrt(ratio)*0.90f));
    }
    IndexedMesh best=compactAt(source,q);
    for(int pass=0;pass<2&&best.faces.size()>cfg.exportMaxTriangles&&q<limit-0.0000001f;pass++){
      float ratio=best.faces.size()/(float)Math.max(1,cfg.exportMaxTriangles);
      float next=Math.min(limit,Math.max(q*1.20f,q*(float)Math.sqrt(ratio)*1.05f));
      if(next<=q+0.0000001f)next=limit;
      q=next;best=compactAt(source,q);
    }
    return best;
  }
  IndexedMesh compactAt(Mesh3D source,float q){
    IndexedMesh out=new IndexedMesh();out.toleranceM=q;
    if(source==null||source.triangles.isEmpty())return out;
    int expected=Math.max(16,Math.min(source.triangleCount()*2,1500000));
    HashMap<VertexKey,Integer> indices=new HashMap<VertexKey,Integer>(expected);
    ArrayList<VertexAccum> accum=new ArrayList<VertexAccum>(Math.min(expected,1000000));
    HashSet<FaceKey> seenFaces=new HashSet<FaceKey>(Math.max(16,Math.min(source.triangleCount(),1000000)));
    out.faces.ensureCapacity(Math.min(source.triangleCount(),cfg.exportMaxTriangles*2));
    for(Triangle3D t:source.triangles){
      // ExportSpace reflects Y and swaps B/C to preserve winding, performed here
      // without allocating a temporary Triangle3D and three temporary PVectors.
      int ia=indexFor(t.a.x,-t.a.y,t.a.z,t.ca,q,indices,accum);
      int ib=indexFor(t.c.x,-t.c.y,t.c.z,t.cc,q,indices,accum);
      int ic=indexFor(t.b.x,-t.b.y,t.b.z,t.cb,q,indices,accum);
      if(ia==ib||ib==ic||ia==ic)continue;
      FaceKey fk=new FaceKey(ia,ib,ic);if(!seenFaces.add(fk))continue;
      out.faces.add(new IndexedFace(ia,ib,ic,t));
    }
    out.vertices.ensureCapacity(accum.size());out.colors.ensureCapacity(accum.size());out.normals.ensureCapacity(accum.size());
    for(VertexAccum v:accum){out.vertices.add(v.point());out.colors.add(v.colorValue());out.normals.add(new PVector());}
    for(IndexedFace f:out.faces){
      PVector a=out.vertices.get(f.a),b=out.vertices.get(f.b),c=out.vertices.get(f.c);
      float ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z;
      float nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx,magSq=nx*nx+ny*ny+nz*nz;
      if(magSq<=1e-12f)continue;
      float inv=1.0f/(float)Math.sqrt(magSq);nx*=inv;ny*=inv;nz*=inv;
      PVector na=out.normals.get(f.a),nb=out.normals.get(f.b),nc=out.normals.get(f.c);
      na.x+=nx;na.y+=ny;na.z+=nz;nb.x+=nx;nb.y+=ny;nb.z+=nz;nc.x+=nx;nc.y+=ny;nc.z+=nz;
    }
    for(PVector n:out.normals){float m=n.x*n.x+n.y*n.y+n.z*n.z;if(m>1e-12f){float inv=1.0f/(float)Math.sqrt(m);n.x*=inv;n.y*=inv;n.z*=inv;}}
    return out;
  }
  int indexFor(float x,float y,float z,int c,float q,HashMap<VertexKey,Integer> indices,ArrayList<VertexAccum> accum){
    VertexKey key=new VertexKey(x,y,z,q);Integer idx=indices.get(key);
    if(idx==null){idx=accum.size();indices.put(key,idx);accum.add(new VertexAccum());}
    accum.get(idx).add(x,y,z,c);return idx;
  }
}

// Export-space convention shared by STL, OBJ and PLY.
// Scanner/Processing reconstruction uses screen-style +Y downward. External
// 3D/CAD files use +Y upward, so reflect Y only at serialization time.
// Reflection changes handedness; face winding is reversed by each exporter.
class ScannerExportSpace {
  static PVector point(PVector p){return new PVector(p.x,-p.y,p.z);}
  static PVector normal(PVector n){PVector out=new PVector(n.x,-n.y,n.z);if(out.magSq()>1e-12f)out.normalize();return out;}
}

class STLExporter {
  AppConfig cfg;MeshCompactor compactor;
  STLExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void writeBinary(Mesh3D mesh, File file) throws Exception {
    IndexedMesh indexed=compactor.compact(mesh);
    File parent=file.getParentFile();if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder");

    DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(file)));

    try {
      byte[] header = new byte[80]; String text="SynKinect Studio compact STL; weld="+indexed.toleranceM+"m";
      byte[] title=text.getBytes("US-ASCII");
      System.arraycopy(title,0,header,0,Math.min(title.length,80)); out.write(header);
       writeLEInt(out,indexed.faces.size());
      for(IndexedFace f:indexed.faces){PVector a=ScannerExportSpace.point(indexed.vertices.get(f.a)),b=ScannerExportSpace.point(indexed.vertices.get(f.b)),c=ScannerExportSpace.point(indexed.vertices.get(f.c));
        // Y reflection reverses handedness: serialize A,C,B to preserve outward winding.
        PVector n=PVector.sub(c,a).cross(PVector.sub(b,a));if(n.magSq()>1e-12f)n.normalize();
        writeVec(out,n,false);writeVec(out,a,true);writeVec(out,c,true);writeVec(out,b,true);
        writeLEShort(out,0);}
    } finally { out.close(); }
  }
  void writeVec(DataOutputStream out,PVector v,boolean millimeters)throws Exception{float scale=millimeters?1000.0f:1.0f;
    writeLEFloat(out,v.x*scale);writeLEFloat(out,v.y*scale);writeLEFloat(out,v.z*scale);
    }
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));
    }
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);
    out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);
    }
  void writeLEShort(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);
    out.writeByte((value>>8)&255);}
}

class OBJExporter {
  AppConfig cfg;MeshCompactor compactor;
  OBJExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void write(Mesh3D mesh,File obj)throws Exception{
    IndexedMesh indexed=compactor.compact(mesh);
    File folder=obj.getParentFile();if(folder!=null&&!folder.exists()&&!folder.mkdirs())throw new IOException("Could not create export folder: "+folder.getAbsolutePath());
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(obj)));
    try{
      out.println("## SynKinect Studio indexed mesh");
      out.println("# coordinate_system: right-handed; +X right; +Y up; +Z forward; units: meters");
      out.println("# export_transform: scanner +Y-down converted to +Y-up; winding preserved");
      for(int i=0;i<indexed.vertices.size();i++)writeVertex(out,ScannerExportSpace.point(indexed.vertices.get(i)),indexed.colors.get(i));
      for(PVector n:indexed.normals){PVector en=ScannerExportSpace.normal(n);out.println("vn "+en.x+" "+en.y+" "+en.z);}
      for(IndexedFace f:indexed.faces)out.println("f "+(f.a+1)+"//"+(f.a+1)+" "+(f.c+1)+"//"+(f.c+1)+" "+(f.b+1)+"//"+(f.b+1));
    }finally{out.close();}
  }
  void writeVertex(PrintWriter out,PVector p,int c){
    float r=((c>>16)&255)/255.0f,g=((c>>8)&255)/255.0f,b=(c&255)/255.0f;
    out.println("v "+p.x+" "+p.y+" "+p.z+" "+r+" "+g+" "+b);
  }
}

class PLYExporter {
  AppConfig cfg;MeshCompactor compactor;
  PLYExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void write(Mesh3D mesh,File file)throws Exception{
    IndexedMesh indexed=compactor.compact(mesh);File parent=file.getParentFile();
    if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder");

    BufferedOutputStream raw=new BufferedOutputStream(new FileOutputStream(file));
    DataOutputStream out=new DataOutputStream(raw);
    try{
      String header=
        "ply\n"+
        "format binary_little_endian 1.0\n"+
        "comment SynKinect Studio compact indexed mesh\n"+
         "comment coordinate_system right-handed +X right +Y up +Z forward units meters\n"+
        "comment export_transform scanner +Y-down converted to +Y-up winding preserved\n"+
        "element vertex "+indexed.vertices.size()+"\n"+
        "property float x\n"+
        "property float y\n"+
        "property float z\n"+
        "property float nx\n"+
        "property float ny\n"+
        "property float nz\n"+
        "property uchar red\n"+
        "property uchar green\n"+
        "property uchar blue\n"+
        "property uchar alpha\n"+
        "element face "+indexed.faces.size()+"\n"+
        "property list uchar int vertex_indices\n"+
        "end_header\n";

      out.write(header.getBytes("US-ASCII"));
      for(int i=0;i<indexed.vertices.size();i++){PVector v=ScannerExportSpace.point(indexed.vertices.get(i)),n=ScannerExportSpace.normal(indexed.normals.get(i));
        int c=indexed.colors.get(i);writeLEFloat(out,v.x);writeLEFloat(out,v.y);writeLEFloat(out,v.z);
        writeLEFloat(out,n.x);writeLEFloat(out,n.y);writeLEFloat(out,n.z);
        out.writeByte((c>>16)&255);out.writeByte((c>>8)&255);out.writeByte(c&255);out.writeByte((c>>>24)&255);
        }
      for(IndexedFace f:indexed.faces){out.writeByte(3);writeLEInt(out,f.a);writeLEInt(out,f.c);
        writeLEInt(out,f.b);}
    }finally{out.close();}
  }
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));
    }
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);
    out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);
    }
}
