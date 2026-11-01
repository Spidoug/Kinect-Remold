// ===== SynKinect Studio / Core (shared by all modules) / Math3D.pde =====
class RigidTransform {
  float[] m = new float[16];

  RigidTransform() { setIdentity(); }

  void setIdentity() {
    Arrays.fill(m, 0);
    m[0] = m[5] = m[10] = m[15] = 1;
  }

  void set(RigidTransform o) { arrayCopy(o.m, m); }

  PVector apply(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z + m[3],
      m[4]*p.x + m[5]*p.y + m[6]*p.z + m[7],
      m[8]*p.x + m[9]*p.y + m[10]*p.z + m[11]
    );
  }

  PVector rotate(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z,
      m[4]*p.x + m[5]*p.y + m[6]*p.z,
      m[8]*p.x + m[9]*p.y + m[10]*p.z
    );
  }

  RigidTransform multiply(RigidTransform b) {
    RigidTransform r = new RigidTransform();
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 4; col++) {
        float s = 0;
        for (int k = 0; k < 4; k++) s += m[row*4+k] * b.m[k*4+col];
        r.m[row*4+col] = s;
      }
    }
    return r;
  }

  RigidTransform inverseRigid() {
    RigidTransform r=new RigidTransform();
    r.m[0]=m[0];r.m[1]=m[4];r.m[2]=m[8];
    r.m[4]=m[1];r.m[5]=m[5];r.m[6]=m[9];
    r.m[8]=m[2];r.m[9]=m[6];r.m[10]=m[10];
    r.m[3]=-(r.m[0]*m[3]+r.m[1]*m[7]+r.m[2]*m[11]);
    r.m[7]=-(r.m[4]*m[3]+r.m[5]*m[7]+r.m[6]*m[11]);
    r.m[11]=-(r.m[8]*m[3]+r.m[9]*m[7]+r.m[10]*m[11]);
    return r;
  }

  RigidTransform fromRotationTranslation(float[][] R, PVector t) {
    RigidTransform x = new RigidTransform();
    x.m[0]=R[0][0]; x.m[1]=R[0][1]; x.m[2]=R[0][2]; x.m[3]=t.x;
    x.m[4]=R[1][0]; x.m[5]=R[1][1]; x.m[6]=R[1][2]; x.m[7]=t.y;
    x.m[8]=R[2][0]; x.m[9]=R[2][1]; x.m[10]=R[2][2]; x.m[11]=t.z;
    return x;
  }
}

class QuaternionFit {
  RigidTransform fit(ArrayList<PVector> src, ArrayList<PVector> dst) {
    int n=min(src.size(),dst.size());if(n<3)return new RigidTransform();
    double csx=0,csy=0,csz=0,cdx=0,cdy=0,cdz=0;
    for(int i=0;i<n;i++){PVector a=src.get(i),b=dst.get(i);csx+=a.x;csy+=a.y;csz+=a.z;
      cdx+=b.x;cdy+=b.y;cdz+=b.z;}
    float inv=1.0f/n;float sx=(float)(csx*inv),sy=(float)(csy*inv),sz=(float)(csz*inv),dx=(float)(cdx*inv),dy=(float)(cdy*inv),dz=(float)(cdz*inv);

    float Sxx=0,Sxy=0,Sxz=0,Syx=0,Syy=0,Syz=0,Szx=0,Szy=0,Szz=0;
    for(int i=0;i<n;i++){
      PVector pa=src.get(i),pb=dst.get(i);float ax=pa.x-sx,ay=pa.y-sy,az=pa.z-sz,bx=pb.x-dx,by=pb.y-dy,bz=pb.z-dz;

      Sxx+=ax*bx;Sxy+=ax*by;Sxz+=ax*bz;Syx+=ay*bx;Syy+=ay*by;Syz+=ay*bz;Szx+=az*bx;
      Szy+=az*by;Szz+=az*bz;
    }
    float tr=Sxx+Syy+Szz;
    float n00=tr,n01=Syz-Szy,n02=Szx-Sxz,n03=Sxy-Syx;
    float n11=Sxx-Syy-Szz,n12=Sxy+Syx,n13=Szx+Sxz;
    float n22=-Sxx+Syy-Szz,n23=Syz+Szy,n33=-Sxx-Syy+Szz;
    float q0=1,q1=0,q2=0,q3=0;
    for(int it=0;it<32;it++){
      float a0=n00*q0+n01*q1+n02*q2+n03*q3;
      float a1=n01*q0+n11*q1+n12*q2+n13*q3;
      float a2=n02*q0+n12*q1+n22*q2+n23*q3;
      float a3=n03*q0+n13*q1+n23*q2+n33*q3;
      float norm=sqrt(a0*a0+a1*a1+a2*a2+a3*a3);if(norm<1e-9f)break;float ni=1.0f/norm;
      q0=a0*ni;q1=a1*ni;q2=a2*ni;q3=a3*ni;
    }
    float w=q0,x=q1,y=q2,z=q3;
    float r00=1-2*y*y-2*z*z,r01=2*x*y-2*z*w,r02=2*x*z+2*y*w;
    float r10=2*x*y+2*z*w,r11=1-2*x*x-2*z*z,r12=2*y*z-2*x*w;
    float r20=2*x*z-2*y*w,r21=2*y*z+2*x*w,r22=1-2*x*x-2*y*y;
    RigidTransform out=new RigidTransform();out.m[0]=r00;out.m[1]=r01;out.m[2]=r02;
    out.m[3]=dx-(r00*sx+r01*sy+r02*sz);out.m[4]=r10;out.m[5]=r11;out.m[6]=r12;out.m[7]=dy-(r10*sx+r11*sy+r12*sz);
    out.m[8]=r20;out.m[9]=r21;out.m[10]=r22;out.m[11]=dz-(r20*sx+r21*sy+r22*sz);return out;

  }

  RigidTransform fitWeighted(ArrayList<PVector> src,ArrayList<PVector> dst,ArrayList<Float> weights){
    int n=min(src.size(),min(dst.size(),weights.size()));if(n<3)return new RigidTransform();
    double sw=0,csx=0,csy=0,csz=0,cdx=0,cdy=0,cdz=0;
    for(int i=0;i<n;i++){double w=max(0.0001f,weights.get(i));PVector a=src.get(i),b=dst.get(i);sw+=w;csx+=w*a.x;csy+=w*a.y;csz+=w*a.z;cdx+=w*b.x;cdy+=w*b.y;cdz+=w*b.z;}
    if(sw<1e-8)return new RigidTransform();float sx=(float)(csx/sw),sy=(float)(csy/sw),sz=(float)(csz/sw),dx=(float)(cdx/sw),dy=(float)(cdy/sw),dz=(float)(cdz/sw);
    double Sxx=0,Sxy=0,Sxz=0,Syx=0,Syy=0,Syz=0,Szx=0,Szy=0,Szz=0;
    for(int i=0;i<n;i++){double w=max(0.0001f,weights.get(i));PVector a=src.get(i),b=dst.get(i);double ax=a.x-sx,ay=a.y-sy,az=a.z-sz,bx=b.x-dx,by=b.y-dy,bz=b.z-dz;Sxx+=w*ax*bx;Sxy+=w*ax*by;Sxz+=w*ax*bz;Syx+=w*ay*bx;Syy+=w*ay*by;Syz+=w*ay*bz;Szx+=w*az*bx;Szy+=w*az*by;Szz+=w*az*bz;}
    float fSxx=(float)Sxx,fSxy=(float)Sxy,fSxz=(float)Sxz,fSyx=(float)Syx,fSyy=(float)Syy,fSyz=(float)Syz,fSzx=(float)Szx,fSzy=(float)Szy,fSzz=(float)Szz;
    float tr=fSxx+fSyy+fSzz,n00=tr,n01=fSyz-fSzy,n02=fSzx-fSxz,n03=fSxy-fSyx,n11=fSxx-fSyy-fSzz,n12=fSxy+fSyx,n13=fSzx+fSxz,n22=-fSxx+fSyy-fSzz,n23=fSyz+fSzy,n33=-fSxx-fSyy+fSzz;
    float q0=1,q1=0,q2=0,q3=0;for(int it=0;it<32;it++){float a0=n00*q0+n01*q1+n02*q2+n03*q3,a1=n01*q0+n11*q1+n12*q2+n13*q3,a2=n02*q0+n12*q1+n22*q2+n23*q3,a3=n03*q0+n13*q1+n23*q2+n33*q3,norm=sqrt(a0*a0+a1*a1+a2*a2+a3*a3);if(norm<1e-9f)break;float ni=1.0f/norm;q0=a0*ni;q1=a1*ni;q2=a2*ni;q3=a3*ni;}
    float w=q0,x=q1,y=q2,z=q3,r00=1-2*y*y-2*z*z,r01=2*x*y-2*z*w,r02=2*x*z+2*y*w,r10=2*x*y+2*z*w,r11=1-2*x*x-2*z*z,r12=2*y*z-2*x*w,r20=2*x*z-2*y*w,r21=2*y*z+2*x*w,r22=1-2*x*x-2*y*y;
    RigidTransform out=new RigidTransform();out.m[0]=r00;out.m[1]=r01;out.m[2]=r02;out.m[3]=dx-(r00*sx+r01*sy+r02*sz);out.m[4]=r10;out.m[5]=r11;out.m[6]=r12;out.m[7]=dy-(r10*sx+r11*sy+r12*sz);out.m[8]=r20;out.m[9]=r21;out.m[10]=r22;out.m[11]=dz-(r20*sx+r21*sy+r22*sz);return out;
  }
}
