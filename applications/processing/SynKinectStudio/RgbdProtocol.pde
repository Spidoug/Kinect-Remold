// ===== SynKinect Studio / Core (shared by all modules) / ScannerProtocol.pde =====
class ScannerProtocol {
  final int MAGIC = 0x43534D52;
  final int FRAME_MAGIC = 0x46534D52;
  final int VERSION = 1;
  final int CMD_SUBSCRIBE_STREAMS = 1;
  final int CMD_GET_DRIVER_SETTINGS = 2;
  final int DRIVER_RGB_HQ = 1;

  final int WIDTH = 640;
  final int HEIGHT = 480;
  final int RGB_HQ_WIDTH = 1280;
  final int RGB_HQ_HEIGHT = 1024;
  final int MODE_RGB = 0;
  final int MODE_IR = 1;
  final int MODE_DEPTH = 2;
  final int MODE_RGB_HQ = 3;
  final int STREAM_RGB = 1;
  final int STREAM_IR = 2;
  final int STREAM_DEPTH = 4;
  final int STREAM_RGB_HQ = 8;
  final int STREAM_SESSION = STREAM_RGB | STREAM_DEPTH;
  final int STREAM_SESSION_HQ = STREAM_RGB | STREAM_DEPTH | STREAM_RGB_HQ;

  final int CAP_RGB_DEPTH_CONCURRENT = 1;
  final int CAP_EXCLUSIVE_VIDEO_MODE = 2;
  final int CAP_PROJECTOR_REFCOUNTED = 4;
  final int CAP_ACCELEROMETER = 8;
  final int CAP_RGB_HQ = 16;
  final int CAP_RAW_SENSOR_FRAMES = 64;
  final int CAP_PERSISTENT_ISO_SESSION = 128;
  final int REQUIRED_CAPABILITIES = CAP_RGB_DEPTH_CONCURRENT | CAP_EXCLUSIVE_VIDEO_MODE | CAP_PROJECTOR_REFCOUNTED | CAP_RAW_SENSOR_FRAMES;


  final int DEPTH_FRAME_MM16 = 1003;
  final int PIXEL_BAYER_GRBG8 = 4;
  final int PIXEL_NV12 = 0x3231564E;
  final int PIXEL_BGRA32 = 0x41524742;
  final int PIXEL_JPEG = 1005;
  final int PIXEL_IR_RAW10_PACKED = 5;
  final int PIXEL_IR_U16 = 1004;
  final int PIXEL_DEPTH_RAW11_PACKED = 6;
  final int FLAG_FRAME_RECOVERED = 1;
  final int KNOWN_FRAME_FLAGS = FLAG_FRAME_RECOVERED;

  final int RGB_RAW_BYTES = WIDTH * HEIGHT;
  final int DEPTH_RAW11_PACKED_BYTES = WIDTH * HEIGHT * 11 / 8;
  final int RGB_HQ_BYTES = RGB_HQ_WIDTH * RGB_HQ_HEIGHT;
  final int MAX_PAYLOAD_BYTES = RGB_HQ_BYTES;
  final int ABSOLUTE_MAX_PAYLOAD_BYTES = 128 * 1024 * 1024;
  final int REPLY_BYTES = 68;
  // Kinect One reply extension (factory depth distortion + color intrinsics), opt-in via
  // RequestV2.deviceId[63]; see drivers/modules/kinect-one-remold/shared/KinectOneRemoldProtocol.h.
  final int DEPTH_CALIBRATION_NATIVE = 2;
  final int DEPTH_CALIBRATION_NATIVE_EXTENDED = 3;
  final int REPLY_EXTENSION_REQUEST = 0xC3;
  final int REPLY_EXTENSION_MAGIC = 0x31584352;
  final int REPLY_EXTENSION_BYTES = 64;
  final int FRAME_HEADER_BYTES = 76;

}

// Processing merges PDE source files into the sketch class. ScannerProtocol is therefore
// an inner type and must contain constants only; executable protocol helpers
// remain sketch methods in this source file because Processing does not allow them inside that class.
int scannerMaskForMode(int mode) {
  return mode == studio.services.scannerProtocol.MODE_RGB ? studio.services.scannerProtocol.STREAM_RGB
       : mode == studio.services.scannerProtocol.MODE_IR ? studio.services.scannerProtocol.STREAM_IR
       : mode == studio.services.scannerProtocol.MODE_DEPTH ? studio.services.scannerProtocol.STREAM_DEPTH
       : mode == studio.services.scannerProtocol.MODE_RGB_HQ ? studio.services.scannerProtocol.STREAM_RGB_HQ : 0;

}

boolean scannerFormatAllowedForMode(int mode,int fmt) {
  if(mode==studio.services.scannerProtocol.MODE_RGB||mode==studio.services.scannerProtocol.MODE_RGB_HQ)
    return fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8||fmt==studio.services.scannerProtocol.PIXEL_NV12||fmt==studio.services.scannerProtocol.PIXEL_BGRA32||fmt==studio.services.scannerProtocol.PIXEL_JPEG;
  if(mode==studio.services.scannerProtocol.MODE_IR)return fmt==studio.services.scannerProtocol.PIXEL_IR_RAW10_PACKED||fmt==studio.services.scannerProtocol.PIXEL_IR_U16;
  return mode==studio.services.scannerProtocol.MODE_DEPTH&&(fmt==studio.services.scannerProtocol.PIXEL_DEPTH_RAW11_PACKED||fmt==studio.services.scannerProtocol.DEPTH_FRAME_MM16);

}

boolean scannerPayloadAllowedForMode(int mode,int fmt,int bytes) {
  if(mode==studio.services.scannerProtocol.MODE_RGB){int w=scannerExpectedWidthForMode(mode),h=scannerExpectedHeightForMode(mode);if(w<=0||h<=0)return bytes>0;
    if(fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8)return bytes==w*h;
    if(fmt==studio.services.scannerProtocol.PIXEL_NV12)return bytes==w*h*3/2;
    if(fmt==studio.services.scannerProtocol.PIXEL_BGRA32)return bytes==w*h*4;
    if(fmt==studio.services.scannerProtocol.PIXEL_JPEG)return bytes>256&&bytes<=studio.services.scannerProtocol.ABSOLUTE_MAX_PAYLOAD_BYTES;
    return false;
  }

  if(mode==studio.services.scannerProtocol.MODE_IR){int w=scannerExpectedWidthForMode(mode),h=scannerExpectedHeightForMode(mode);if(fmt==studio.services.scannerProtocol.PIXEL_IR_U16)return w<=0||h<=0?bytes>0:bytes==w*h*2;return fmt==studio.services.scannerProtocol.PIXEL_IR_RAW10_PACKED&&(w<=0||h<=0?bytes>0:bytes==w*h*10/8);}
  if(mode==studio.services.scannerProtocol.MODE_DEPTH){int w=scannerExpectedWidthForMode(mode),h=scannerExpectedHeightForMode(mode);
    if(fmt==studio.services.scannerProtocol.DEPTH_FRAME_MM16)return w<=0||h<=0?bytes>0:bytes==w*h*2;
    return fmt==studio.services.scannerProtocol.PIXEL_DEPTH_RAW11_PACKED&&(w<=0||h<=0?bytes>0:bytes==w*h*11/8);
  }

  if(mode==studio.services.scannerProtocol.MODE_RGB_HQ){int w=scannerExpectedWidthForMode(mode),h=scannerExpectedHeightForMode(mode);if(fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8)return bytes==w*h;if(fmt==studio.services.scannerProtocol.PIXEL_NV12)return bytes==w*h*3/2;if(fmt==studio.services.scannerProtocol.PIXEL_BGRA32)return bytes==w*h*4;if(fmt==studio.services.scannerProtocol.PIXEL_JPEG)return bytes>256&&bytes<=studio.services.scannerProtocol.ABSOLUTE_MAX_PAYLOAD_BYTES;}return false;

}
int scannerExpectedWidthForMode(int mode){KinectDevice d=studio.selectedKinect();if(d!=null&&!"xbox-360".equals(d.generation)){if(mode==studio.services.scannerProtocol.MODE_DEPTH&&d.depthWidth>0)return d.depthWidth;if(mode==studio.services.scannerProtocol.MODE_IR&&d.irWidth>0)return d.irWidth;if((mode==studio.services.scannerProtocol.MODE_RGB||mode==studio.services.scannerProtocol.MODE_RGB_HQ)&&d.colorWidth>0)return d.colorWidth;}
  return mode==studio.services.scannerProtocol.MODE_RGB_HQ?studio.services.scannerProtocol.RGB_HQ_WIDTH:studio.services.scannerProtocol.WIDTH;}
int scannerExpectedHeightForMode(int mode){KinectDevice d=studio.selectedKinect();if(d!=null&&!"xbox-360".equals(d.generation)){if(mode==studio.services.scannerProtocol.MODE_DEPTH&&d.depthHeight>0)return d.depthHeight;if(mode==studio.services.scannerProtocol.MODE_IR&&d.irHeight>0)return d.irHeight;if((mode==studio.services.scannerProtocol.MODE_RGB||mode==studio.services.scannerProtocol.MODE_RGB_HQ)&&d.colorHeight>0)return d.colorHeight;}
  return mode==studio.services.scannerProtocol.MODE_RGB_HQ?studio.services.scannerProtocol.RGB_HQ_HEIGHT:studio.services.scannerProtocol.HEIGHT;}
boolean scannerDimensionsAllowedForMode(int mode,int w,int h){if(w<=0||h<=0)return false;KinectDevice d=studio.selectedKinect();if(d==null||"xbox-360".equals(d.generation))return w==scannerExpectedWidthForMode(mode)&&h==scannerExpectedHeightForMode(mode);int ew=scannerExpectedWidthForMode(mode),eh=scannerExpectedHeightForMode(mode);return ew<=0||eh<=0||(w==ew&&h==eh);}




// ===== SynKinect Studio / Core (shared by all modules) / RGB HQ processing =====
static class RgbFrameQuality {
  static float clamp01(float v){return Math.max(0.0f,Math.min(1.0f,v));}
  static float score(byte[] data,int w,int h,int fmt){
    if(data==null||w<=2||h<=2)return 0.0f;
    if(fmt==4&&data.length==w*h)return scoreBayer(data,w,h);
    if(fmt==1005){try{BufferedImage image=ImageIO.read(new ByteArrayInputStream(data));if(image==null)return 0;int iw=image.getWidth(),ih=image.getHeight(),step=Math.max(4,Math.min(iw,ih)/80);long grad=0;int good=0,n=0;for(int y=step;y<ih-step;y+=step)for(int x=step;x<iw-step;x+=step){int c=image.getRGB(x,y),l=image.getRGB(x-step,y),r=image.getRGB(x+step,y),u=image.getRGB(x,y-step),d=image.getRGB(x,y+step);int lum=((c>>16)&255)*54+((c>>8)&255)*183+(c&255)*19;lum>>=8;if(lum>16&&lum<242)good++;int ll=(((l>>16)&255)*54+((l>>8)&255)*183+(l&255)*19)>>8,rr=(((r>>16)&255)*54+((r>>8)&255)*183+(r&255)*19)>>8,uu=(((u>>16)&255)*54+((u>>8)&255)*183+(u&255)*19)>>8,dd=(((d>>16)&255)*54+((d>>8)&255)*183+(d&255)*19)>>8;grad+=Math.abs(rr-ll)+Math.abs(dd-uu);n++;}if(n==0)return 0;return clamp01((good/(float)n)*(.35f+.65f*clamp01((grad/(float)n)/42.0f)));}catch(Exception ignored){return 0;}}
    if(fmt==0x41524742&&data.length==w*h*4)return .70f;
    if((fmt==1||fmt==0x3231564E)&&data.length==w*h*3/2)return .68f;
    return 0.0f;
  }
  static float scoreBayer(byte[] data,int w,int h){
    long grad=0;int samples=0,good=0,clipped=0;int step=Math.max(6,Math.min(w,h)/96);
    if((step&1)!=0)step++;
    for(int y=step;y<h-step;y+=step)for(int x=step;x<w-step;x+=step){int i=y*w+x,v=data[i]&255;
      if(v>=20&&v<=240)good++;if(v<6||v>249)clipped++;int gx=Math.abs((data[i+2]&255)-(data[i-2]&255)),gy=Math.abs((data[i+2*w]&255)-(data[i-2*w]&255));
      grad+=gx+gy;samples++;}
    if(samples==0)return 0;float exposure=clamp01(good/(float)samples)*(1.0f-0.65f*clamp01(clipped/(float)samples));
    float sharp=clamp01((grad/(float)samples)/38.0f);return clamp01(exposure*(0.25f+0.75f*sharp));

  }
}

static class ColorStats {float r,g,b;int samples;boolean valid(){return samples>16&&r>1&&g>1&&b>1;
    }}
static class ColorReference {
  final float r,g,b;final boolean valid;
  ColorReference(float r,float g,float b,boolean valid){this.r=r;this.g=g;this.b=b;
    this.valid=valid;}
  static ColorReference fromFrames(List<HighQualityKeyframe> frames){
    if(frames==null||frames.isEmpty())return new ColorReference(128,128,128,false);

    float[] rs=new float[frames.size()],gs=new float[frames.size()],bs=new float[frames.size()];
    int n=0;
    for(HighQualityKeyframe k:frames){if(k==null||k.colorData==null)continue;ColorStats st=RgbHqProcessor.rawStats(k.colorData,k.colorWidth,k.colorHeight,
        k.colorPixelFormat);if(!st.valid())continue;rs[n]=st.r;gs[n]=st.g;bs[n]=st.b;
      n++;}
    if(n==0)return new ColorReference(128,128,128,false);Arrays.sort(rs,0,n);Arrays.sort(gs,0,n);
    Arrays.sort(bs,0,n);int m=n/2;float r=(n&1)==1?rs[m]:(rs[m-1]+rs[m])*0.5f,g=(n&1)==1?gs[m]:(gs[m-1]+gs[m])*0.5f,b=(n&1)==1?bs[m]:(bs[m-1]+bs[m])*0.5f;
    return new ColorReference(r,g,b,true);
  }
}

static class RgbHqProcessor {
  static int clamp8(int v){return v<0?0:v>255?255:v;}
  static int mirror(int p,int size){if(p<0)p=-p;if(p>=size)p=2*(size-1)-p;return p<0?0:p>=size?size-1:p;
    }
  static int sample(byte[] b,int w,int h,int x,int y){return b[mirror(y,h)*w+mirror(x,w)]&255;
    }
  static int avg2(int a,int b){return(a+b+1)>>1;}static int avg4(int a,int b,int c,int d){return(a+b+c+d+2)>>2;
    }
  static int rgbAt(byte[] b,int w,int h,int x,int y){
    boolean yo=(y&1)!=0,xo=(x&1)!=0;int c=sample(b,w,h,x,y),r=0,g=0,bl=0;
    if(!yo&&xo){r=c;int lh=sample(b,w,h,x-1,y),rh=sample(b,w,h,x+1,y),uv=sample(b,w,h,x,y-1),dv=sample(b,w,h,x,y+1);
      g=Math.abs(lh-rh)<=Math.abs(uv-dv)?avg2(lh,rh):avg2(uv,dv);bl=avg4(sample(b,w,h,x-1,y-1),sample(b,w,h,x+1,y-1),sample(b,w,h,x-1,y+1),sample(b,w,h,
        x+1,y+1));}
    else if(yo&&!xo){bl=c;int lh=sample(b,w,h,x-1,y),rh=sample(b,w,h,x+1,y),uv=sample(b,w,h,x,y-1),dv=sample(b,w,h,x,y+1);
      g=Math.abs(lh-rh)<=Math.abs(uv-dv)?avg2(lh,rh):avg2(uv,dv);r=avg4(sample(b,w,h,x-1,y-1),sample(b,w,h,x+1,y-1),sample(b,w,h,x-1,y+1),sample(b,w,h,
        x+1,y+1));}
    else if(!yo){g=c;r=avg2(sample(b,w,h,x-1,y),sample(b,w,h,x+1,y));bl=avg2(sample(b,w,h,x,y-1),sample(b,w,h,x,y+1));
      }
    else{g=c;r=avg2(sample(b,w,h,x,y-1),sample(b,w,h,x,y+1));bl=avg2(sample(b,w,h,x-1,y),sample(b,w,h,x+1,y));
      }
    return 0xff000000|(r<<16)|(g<<8)|bl;
  }
  static boolean decodeBayerGrbg(byte[] b,int w,int h,int[] out){
    if(b==null||out==null||b.length!=w*h||out.length<w*h)return false;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)out[y*w+x]=rgbAt(b,w,h,x,y);
    return true;
  }
  static byte[] bayerGrbgToNv12(byte[] b,int w,int h){
    if(b==null||w<=0||h<=0||(w&1)!=0||(h&1)!=0||b.length!=w*h)return null;
    int count=w*h;byte[] out=new byte[count*3/2];
    for(int y=0;y<h;y+=2)for(int x=0;x<w;x+=2){
      int c0=rgbAt(b,w,h,x,y),c1=rgbAt(b,w,h,x+1,y),c2=rgbAt(b,w,h,x,y+1),c3=rgbAt(b,w,h,x+1,y+1);

      int r0=(c0>>16)&255,g0=(c0>>8)&255,b0=c0&255,r1=(c1>>16)&255,g1=(c1>>8)&255,b1=c1&255;

      int r2=(c2>>16)&255,g2=(c2>>8)&255,b2=c2&255,r3=(c3>>16)&255,g3=(c3>>8)&255,b3=c3&255;

      out[y*w+x]=(byte)clamp8(((66*r0+129*g0+25*b0+128)>>8)+16);
      out[y*w+x+1]=(byte)clamp8(((66*r1+129*g1+25*b1+128)>>8)+16);
      out[(y+1)*w+x]=(byte)clamp8(((66*r2+129*g2+25*b2+128)>>8)+16);
      out[(y+1)*w+x+1]=(byte)clamp8(((66*r3+129*g3+25*b3+128)>>8)+16);
      int r=(r0+r1+r2+r3+2)>>2,g=(g0+g1+g2+g3+2)>>2,bl=(b0+b1+b2+b3+2)>>2;
      int u=((-38*r-74*g+112*bl+128)>>8)+128,v=((112*r-94*g-18*bl+128)>>8)+128,uv=count+(y/2)*w+x;

      out[uv]=(byte)clamp8(u);out[uv+1]=(byte)clamp8(v);
    }
    return out;
  }
  static ColorStats rawStats(byte[] data,int w,int h,int fmt){
    ColorStats st=new ColorStats();if(data==null||w<=0||h<=0)return st;long sr=0,sg=0,sb=0;
    int n=0,step=Math.max(8,Math.min(w,h)/64);if((step&1)!=0)step++;
    if(fmt==4&&data.length==w*h){for(int y=4;y<h-4;y+=step)for(int x=4;x<w-4;x+=step){int r,g,b;
        if((y&1)==0){r=sample(data,w,h,x|1,y);b=sample(data,w,h,x&~1,y+1);g=avg2(sample(data,w,h,x&~1,y),sample(data,w,h,x|1,y+1));
          }else{r=sample(data,w,h,x|1,y-1);b=sample(data,w,h,x&~1,y);g=avg2(sample(data,w,h,x|1,y),sample(data,w,h,x&~1,y-1));
          }if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}
    else if((fmt==1||fmt==0x3231564E)&&data.length==w*h*3/2){int ySize=w*h;for(int y=2;y<h-2;y+=step)for(int x=2;x<w-2;x+=step){int yy=data[y*w+x]&255,uv=ySize+(y/2)*w+(x&~1),
        u=(data[uv]&255)-128,v=(data[uv+1]&255)-128,c=Math.max(0,yy-16),r=clamp8((298*c+409*v+128)>>8),g=clamp8((298*c-100*u-208*v+128)>>8),b=clamp8((298*c+516*u+128)>>8);
        if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}
    else if(fmt==0x41524742&&data.length==w*h*4){for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){int i=(y*w+x)*4,b=data[i]&255,g=data[i+1]&255,r=data[i+2]&255;if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}
    else if(fmt==1005){try{BufferedImage image=ImageIO.read(new ByteArrayInputStream(data));if(image!=null){int iw=image.getWidth(),ih=image.getHeight();for(int y=0;y<ih;y+=step)for(int x=0;x<iw;x+=step){int c=image.getRGB(x,y),r=(c>>16)&255,g=(c>>8)&255,b=c&255;if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}}catch(Exception ignored){}}
    st.samples=n;if(n>0){st.r=sr/(float)n;st.g=sg/(float)n;st.b=sb/(float)n;}return st;

  }
  static ColorStats decodedStats(int[] pixels){ColorStats st=new ColorStats();if(pixels==null)return st;
    long sr=0,sg=0,sb=0;int n=0,step=Math.max(1,pixels.length/8192);for(int i=0;i<pixels.length;i+=step){int c=pixels[i],r=(c>>16)&255,g=(c>>8)&255,b=c&255;
      if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}st.samples=n;
    if(n>0){st.r=sr/(float)n;st.g=sg/(float)n;st.b=sb/(float)n;}return st;}
  static void normalize(int[] pixels,ColorReference ref,AppConfig cfg){if(pixels==null||ref==null||!ref.valid)return;
    ColorStats cur=decodedStats(pixels);if(!cur.valid())return;float gr=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,ref.r/cur.r)),
    gg=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,ref.g/cur.g)),gb=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,
      ref.b/cur.b));float mean=(gr+gg+gb)/3.0f;gr=0.78f*gr+0.22f*mean;gg=0.78f*gg+0.22f*mean;
    gb=0.78f*gb+0.22f*mean;for(int i=0;i<pixels.length;i++){int c=pixels[i],r=clamp8(Math.round(((c>>16)&255)*gr)),g=clamp8(Math.round(((c>>8)&255)*gg)),
      b=clamp8(Math.round((c&255)*gb));pixels[i]=0xff000000|(r<<16)|(g<<8)|b;}}
  static void sharpen(int[] pixels,int w,int h,float amount){if(pixels==null||w<3||h<3||amount<=0)return;
    int[] prev=new int[w],cur=new int[w],next=new int[w];System.arraycopy(pixels,0,prev,0,w);
    System.arraycopy(pixels,0,cur,0,w);System.arraycopy(pixels,w,next,0,w);for(int y=1;y<h-1;y++){if(y>1){int[] tmp=prev;
        prev=cur;cur=next;next=tmp;System.arraycopy(pixels,(y+1)*w,next,0,w);}for(int x=1;x<w-1;x++){int c=cur[x],l=cur[x-1],r=cur[x+1],u=prev[x],d=next[x];
        int rr=sharpenChannel((c>>16)&255,(l>>16)&255,(r>>16)&255,(u>>16)&255,(d>>16)&255,amount),gg=sharpenChannel((c>>8)&255,(l>>8)&255,(r>>8)&255,(u>>8)&255,
          (d>>8)&255,amount),bb=sharpenChannel(c&255,l&255,r&255,u&255,d&255,amount);
        pixels[y*w+x]=0xff000000|(rr<<16)|(gg<<8)|bb;}}}
  static int sharpenChannel(int c,int l,int r,int u,int d,float amount){float blur=(4*c+l+r+u+d)/8.0f;
    return clamp8(Math.round(c+amount*(c-blur)));}
}
