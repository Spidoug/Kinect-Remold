// ===== SynKinect Studio / Motion-capture sinks =====
// Dependency-free (java.net only) network sinks and the BVH recorder. Every sink
// consumes immutable MocapPose snapshots through its own latest-only mailbox and
// thread; sockets bind to the configured bindAddress (127.0.0.1 by default).
// Wire formats are documented in docs/MOTION-CAPTURE.md.

// ---------------------------------------------------------------- OSC 1.0 encoder
class OscMessageBuilder {
  final String address;final StringBuilder tags=new StringBuilder(",");final ByteArrayOutputStream args=new ByteArrayOutputStream(64);
  OscMessageBuilder(String address){this.address=address;}
  OscMessageBuilder i(int v){tags.append('i');int32(args,v);return this;}
  OscMessageBuilder f(float v){tags.append('f');int32(args,Float.floatToIntBits(v));return this;}
  OscMessageBuilder s(String v){tags.append('s');oscString(args,v==null?"":v);return this;}
  byte[] bytes(){ByteArrayOutputStream out=new ByteArrayOutputStream(32+args.size());oscString(out,address);oscString(out,tags.toString());
    byte[] a=args.toByteArray();out.write(a,0,a.length);return out.toByteArray();}
}
void int32(ByteArrayOutputStream out,int v){out.write((v>>>24)&255);out.write((v>>>16)&255);out.write((v>>>8)&255);out.write(v&255);}
// OSC-string: UTF-8 bytes, NUL terminated, zero padded to a multiple of 4.
void oscString(ByteArrayOutputStream out,String s){byte[] b=s.getBytes(java.nio.charset.StandardCharsets.UTF_8);out.write(b,0,b.length);int pad=4-(b.length%4);for(int k=0;k<pad;k++)out.write(0);}
class OscBundleBuilder {
  final ByteArrayOutputStream out=new ByteArrayOutputStream(2048);int count=0;
  OscBundleBuilder(){oscString(out,"#bundle");int32(out,0);int32(out,1);} // time tag 0x0000000000000001 = immediately
  OscBundleBuilder add(OscMessageBuilder m){byte[] b=m.bytes();int32(out,b.length);out.write(b,0,b.length);count++;return this;}
  byte[] bytes(){return out.toByteArray();}
}

// ---------------------------------------------------------------- JSON encoder
String mocapJsonEscape(String s){StringBuilder b=new StringBuilder(s.length()+2);for(int i=0;i<s.length();i++){char c=s.charAt(i);
    if(c=='"'||c=='\\'){b.append('\\').append(c);}else if(c<0x20){b.append(String.format(Locale.ROOT,"\\u%04x",(int)c));}else b.append(c);}return b.toString();}
void mocapJsonNum(StringBuilder b,float v){if(!Float.isFinite(v)){b.append('0');return;}b.append(String.format(Locale.ROOT,"%.5f",v));}
void mocapJsonArr(StringBuilder b,float[] a,int off,int n){b.append('[');for(int k=0;k<n;k++){if(k>0)b.append(',');mocapJsonNum(b,a[off+k]);}b.append(']');}
// Schema v1: {"v":1,"device":..,"t":..,"frame":..,"space":"unity|camera","mirror":..,"bodies":[{"id":..,"tracked":..,"confidence":..,"joints":{..}}]}
String mocapJson(MocapPose p,boolean cameraSpace){
  StringBuilder b=new StringBuilder(4096);
  b.append("{\"v\":1,\"device\":\"").append(mocapJsonEscape(p.deviceId)).append("\",\"t\":").append(String.format(Locale.ROOT,"%.3f",p.timeMs/1000.0))
    .append(",\"frame\":").append(p.frameNumber).append(",\"space\":\"").append(cameraSpace?"camera":"unity").append("\",\"mirror\":").append(p.mirrored).append(",\"bodies\":[");
  if(p.tracked||p.trackingId!=0){
    b.append("{\"id\":").append(p.trackingId).append(",\"tracked\":").append(p.tracked).append(",\"confidence\":");mocapJsonNum(b,p.confidence);b.append(",\"joints\":{");
    if(cameraSpace){BodyFrame f=p.source;float[] xyz=new float[3];
      for(int i=0;i<f.jointCount();i++){if(i>0)b.append(',');xyz[0]=f.x(i);xyz[1]=f.y(i);xyz[2]=f.z(i);
        b.append('"').append(f.jointName(i)).append("\":{\"p\":");mocapJsonArr(b,xyz,0,3);b.append(",\"c\":");mocapJsonNum(b,f.confidence(i));b.append(",\"s\":").append(f.state(i)).append('}');}
    }else{
      for(int i=0;i<p.boneCount();i++){if(i>0)b.append(',');
        b.append('"').append(p.boneName(i)).append("\":{\"p\":");mocapJsonArr(b,p.globalPos,i*3,3);b.append(",\"q\":");mocapJsonArr(b,p.localRot,i*4,4);
        b.append(",\"g\":");mocapJsonArr(b,p.globalRot,i*4,4);b.append(",\"c\":");mocapJsonNum(b,p.boneConf[i]);b.append('}');}
    }
    b.append("}}");
  }
  b.append("]}");return b.toString();
}

// ---------------------------------------------------------------- sink base
abstract class MocapSink {
  final String id;final String role;volatile boolean enabled=false;LatestMailbox<MocapPose> box;
  volatile long packets=0,errors=0;volatile float latencyMs=-1;volatile String lastError="";long lastSentMs=0;volatile int minIntervalMs=0;
  MocapSink(String id){this.id=id;role="Mocap-"+id;}
  synchronized void setEnabled(boolean on)throws IOException{
    if(on==enabled)return;
    if(on){open();box=new LatestMailbox<MocapPose>(role,new java.util.function.Consumer<MocapPose>(){public void accept(MocapPose p){deliver(p);}});enabled=true;lastError="";}
    else{enabled=false;if(box!=null)box.close(500);box=null;closeResources();}
  }
  void offer(MocapPose p){LatestMailbox<MocapPose> b=box;if(enabled&&b!=null)b.offer(p);}
  void deliver(MocapPose p){
    long now=millis64();if(minIntervalMs>0&&lastSentMs>0&&now-lastSentMs<minIntervalMs)return;
    try{send(p);lastSentMs=now;float lat=p.inputMs>0?max(0,millis64()-p.inputMs):-1;if(lat>=0)latencyMs=latencyMs<0?lat:latencyMs+(lat-latencyMs)*.1f;}
    catch(IOException e){errors++;lastError=safeStudioMessage(e);}
  }
  abstract void open()throws IOException;
  abstract void send(MocapPose p)throws IOException;
  abstract void closeResources();
  int clients(){return 0;}
  String endpoint(){return "";}
}

abstract class MocapUdpSink extends MocapSink {
  final String bindAddress,host;final int port;DatagramSocket socket;InetSocketAddress target;
  MocapUdpSink(String id,String bindAddress,String host,int port){super(id);this.bindAddress=bindAddress;this.host=host;this.port=port;}
  void open()throws IOException{target=new InetSocketAddress(InetAddress.getByName(host),port);
    DatagramSocket s=new DatagramSocket(null);try{s.bind(new InetSocketAddress(InetAddress.getByName(bindAddress),0));}catch(IOException e){s.close();throw e;}socket=s;}
  void datagram(byte[] data)throws IOException{DatagramSocket s=socket;if(s==null)throw new IOException("socket closed");s.send(new DatagramPacket(data,data.length,target));packets++;}
  void closeResources(){DatagramSocket s=socket;socket=null;if(s!=null)s.close();}
  String endpoint(){return host+":"+port;}
}

// VMC protocol (OSC over UDP): OK, T, Root/Pos and one Bone/Pos per humanoid bone.
class MocapVmcSink extends MocapUdpSink {
  long startMs=0;
  MocapVmcSink(String bindAddress,String host,int port){super("VMC",bindAddress,host,port);}
  void open()throws IOException{super.open();startMs=millis64();}
  byte[] encode(MocapPose p){
    OscBundleBuilder b=new OscBundleBuilder();
    b.add(new OscMessageBuilder("/VMC/Ext/OK").i(1));
    b.add(new OscMessageBuilder("/VMC/Ext/T").f((p.timeMs-startMs)/1000.0f));
    b.add(new OscMessageBuilder("/VMC/Ext/Root/Pos").s("root").f(0).f(0).f(0).f(0).f(0).f(0).f(1));
    for(int i=0;i<p.boneCount();i++){OscMessageBuilder m=new OscMessageBuilder("/VMC/Ext/Bone/Pos").s(p.boneName(i));
      for(int k=0;k<3;k++)m.f(p.localPos[i*3+k]);for(int k=0;k<4;k++)m.f(p.localRot[i*4+k]);b.add(m);}
    return b.bytes();
  }
  void send(MocapPose p)throws IOException{datagram(encode(p));}
}

// Plain OSC: /synkinect/frame, /synkinect/joint (camera space, Kinect v1 names), /synkinect/bone (Unity space, global).
class MocapOscSink extends MocapUdpSink {
  MocapOscSink(String bindAddress,String host,int port){super("OSC",bindAddress,host,port);}
  byte[] encode(MocapPose p){
    OscBundleBuilder b=new OscBundleBuilder();BodyFrame f=p.source;float[] up=f.upVector();
    b.add(new OscMessageBuilder("/synkinect/frame").i((int)p.frameNumber).f(p.timeMs/1000.0f).i((int)p.trackingId).i(p.tracked?1:0).f(up==null?0:up[0]).f(up==null?-1:up[1]).f(up==null?0:up[2]));
    for(int i=0;i<f.jointCount();i++)b.add(new OscMessageBuilder("/synkinect/joint").s(f.jointName(i)).f(f.x(i)).f(f.y(i)).f(f.z(i)).f(f.jointTracked(i)?f.confidence(i):0));
    for(int i=0;i<p.boneCount();i++){OscMessageBuilder m=new OscMessageBuilder("/synkinect/bone").s(p.boneName(i));for(int k=0;k<3;k++)m.f(p.globalPos[i*3+k]);for(int k=0;k<4;k++)m.f(p.globalRot[i*4+k]);b.add(m);}
    return b.bytes();
  }
  void send(MocapPose p)throws IOException{datagram(encode(p));}
}

// One JSON document per UDP datagram.
class MocapJsonUdpSink extends MocapUdpSink {
  final boolean cameraSpace;
  MocapJsonUdpSink(String bindAddress,String host,int port,boolean cameraSpace){super("JSON",bindAddress,host,port);this.cameraSpace=cameraSpace;}
  void send(MocapPose p)throws IOException{datagram(mocapJson(p,cameraSpace).getBytes(java.nio.charset.StandardCharsets.UTF_8));}
}

// ---------------------------------------------------------------- minimal RFC 6455 WebSocket server
String websocketAccept(String key){
  try{java.security.MessageDigest sha=java.security.MessageDigest.getInstance("SHA-1");
    byte[] d=sha.digest((key.trim()+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").getBytes(java.nio.charset.StandardCharsets.ISO_8859_1));
    return java.util.Base64.getEncoder().encodeToString(d);}catch(java.security.NoSuchAlgorithmException e){throw new IllegalStateException(e);}
}
byte[] websocketFrame(int opcode,byte[] payload){
  int n=payload.length;ByteArrayOutputStream out=new ByteArrayOutputStream(n+10);out.write(0x80|opcode);
  if(n<126)out.write(n);else if(n<65536){out.write(126);out.write((n>>>8)&255);out.write(n&255);}
  else{out.write(127);for(int s=56;s>=0;s-=8)out.write((int)(((long)n>>>s)&255));}
  out.write(payload,0,n);return out.toByteArray();
}

class MocapWebSocketSink extends MocapSink {
  final String bindAddress;final int port;final boolean cameraSpace;final int maxClients=16;
  ServerSocket server;Thread acceptThread;final CopyOnWriteArrayList<MocapWsClient> clients=new CopyOnWriteArrayList<MocapWsClient>();
  MocapWebSocketSink(String bindAddress,int port,boolean cameraSpace){super("WebSocket");this.bindAddress=bindAddress;this.port=port;this.cameraSpace=cameraSpace;}
  void open()throws IOException{
    ServerSocket s=new ServerSocket();s.setReuseAddress(true);
    try{s.bind(new InetSocketAddress(InetAddress.getByName(bindAddress),port),16);}catch(IOException e){s.close();throw e;}
    server=s;final ServerSocket srv=s;acceptThread=studio.services.workers.start("Mocap-WebSocket-Accept",new Runnable(){public void run(){acceptLoop(srv);}});
  }
  void acceptLoop(ServerSocket srv){
    while(!srv.isClosed()){try{Socket c=srv.accept();if(clients.size()>=maxClients){c.close();continue;}
        final MocapWsClient client=new MocapWsClient(this,c);studio.services.workers.start("Mocap-WebSocket-Client",new Runnable(){public void run(){client.run();}});
      }catch(IOException e){if(!srv.isClosed()){errors++;lastError=safeStudioMessage(e);}}}
  }
  void send(MocapPose p)throws IOException{
    if(clients.isEmpty())return;byte[] frame=websocketFrame(1,mocapJson(p,cameraSpace).getBytes(java.nio.charset.StandardCharsets.UTF_8));
    for(MocapWsClient c:clients)c.offer(frame);
  }
  void closeResources(){ServerSocket s=server;server=null;if(s!=null)try{s.close();}catch(IOException ignored){}
    for(MocapWsClient c:clients)c.close();clients.clear();}
  int clients(){return clients.size();}
  String endpoint(){return "ws://"+bindAddress+":"+port+"/";}
}

// One connected client: handshake + control frames on its thread, data frames via its own latest-only writer.
class MocapWsClient {
  final MocapWebSocketSink owner;final Socket socket;OutputStream out;LatestMailbox<byte[]> writer;volatile boolean closed=false;
  MocapWsClient(MocapWebSocketSink owner,Socket socket){this.owner=owner;this.socket=socket;}
  void run(){
    try{
      socket.setTcpNoDelay(true);socket.setSoTimeout(5000);InputStream in=new BufferedInputStream(socket.getInputStream());out=socket.getOutputStream();
      String key=null;String line=readLine(in);if(line==null||!line.startsWith("GET "))throw new IOException("not a WebSocket request");
      while((line=readLine(in))!=null&&line.length()>0){int c=line.indexOf(':');if(c>0&&line.substring(0,c).trim().equalsIgnoreCase("Sec-WebSocket-Key"))key=line.substring(c+1).trim();}
      if(key==null){writeRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");throw new IOException("missing Sec-WebSocket-Key");}
      writeRaw("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "+websocketAccept(key)+"\r\n\r\n");
      socket.setSoTimeout(0);
      writer=new LatestMailbox<byte[]>("Mocap-WebSocket-Writer",new java.util.function.Consumer<byte[]>(){public void accept(byte[] f){try{write(f);owner.packets++;}catch(IOException e){close();}}});
      owner.clients.add(this);
      readLoop(in);
    }catch(IOException e){}
    finally{close();}
  }
  void readLoop(InputStream in)throws IOException{
    while(!closed){int b0=in.read();if(b0<0)return;int b1=in.read();if(b1<0)return;int op=b0&15;boolean masked=(b1&128)!=0;long len=b1&127;
      if(len==126)len=(in.read()<<8)|in.read();else if(len==127){len=0;for(int k=0;k<8;k++)len=(len<<8)|in.read();}
      if(len>1<<20)throw new IOException("frame too large");byte[] mask=new byte[4];if(masked)readFully(in,mask);byte[] data=new byte[(int)len];readFully(in,data);
      if(masked)for(int k=0;k<data.length;k++)data[k]^=mask[k&3];
      if(op==8){try{write(websocketFrame(8,data.length>=2?Arrays.copyOf(data,2):new byte[0]));}catch(IOException ignored){}return;}
      if(op==9)write(websocketFrame(10,data)); // ping -> pong; text/binary/pong from clients are ignored
    }
  }
  void readFully(InputStream in,byte[] b)throws IOException{int o=0;while(o<b.length){int r=in.read(b,o,b.length-o);if(r<0)throw new EOFException();o+=r;}}
  String readLine(InputStream in)throws IOException{StringBuilder b=new StringBuilder();int c;while((c=in.read())>=0){if(c=='\n')break;if(c!='\r')b.append((char)c);if(b.length()>8192)throw new IOException("header too long");}
    return c<0&&b.length()==0?null:b.toString();}
  void writeRaw(String s)throws IOException{write(s.getBytes(java.nio.charset.StandardCharsets.ISO_8859_1));}
  void write(byte[] b)throws IOException{synchronized(this){out.write(b);out.flush();}}
  void offer(byte[] frame){LatestMailbox<byte[]> w=writer;if(w!=null&&!closed)w.offer(frame);}
  void close(){if(closed)return;closed=true;owner.clients.remove(this);if(writer!=null)writer.close();try{socket.close();}catch(IOException ignored){}}
}

// ---------------------------------------------------------------- BVH recorder
// HIERARCHY from the rest bone lengths at Start; MOTION rows with ZXY Euler degrees.
// BVH space is right-handed, Y up, avatar facing +Z (CMU convention): x_bvh = -x_unity,
// quaternion (x,y,z,w)_unity -> (x,-y,-z,w)_bvh. Units: centimetres.
class MocapBvhRecorder {
  final Object lock=new Object();volatile boolean recording=false;LatestMailbox<MocapPose> box;
  final ArrayList<float[]> frames=new ArrayList<float[]>();long firstMs=0,lastMs=0;float[] restLengths;double[][] restOffsets;double[] prevEuler;File directory;
  volatile int frameCount=0;
  MocapBvhRecorder(){}
  void start(File directory,float[] restLengths){
    synchronized(lock){this.directory=directory;frames.clear();firstMs=lastMs=0;frameCount=0;prevEuler=null;
      MocapRetargeter r=new MocapRetargeter();if(restLengths!=null)System.arraycopy(restLengths,0,r.lengths,0,Math.min(restLengths.length,r.lengths.length));
      this.restLengths=r.lengths.clone();restOffsets=r.restOffsets();recording=true;}
    box=new LatestMailbox<MocapPose>("Mocap-BVH",new java.util.function.Consumer<MocapPose>(){public void accept(MocapPose p){add(p);}});
  }
  void offer(MocapPose p){LatestMailbox<MocapPose> b=box;if(recording&&b!=null)b.offer(p);}
  void add(MocapPose p){
    int nb=p.boneCount();float[] row=new float[3+nb*3];
    row[0]=-p.globalPos[0]*100f;row[1]=p.globalPos[1]*100f;row[2]=p.globalPos[2]*100f;
    double[] e=new double[nb*3];
    for(int i=0;i<nb;i++){double[] q={p.localRot[i*4],-p.localRot[i*4+1],-p.localRot[i*4+2],p.localRot[i*4+3]};double[] zxy=mcEulerZXYDeg(mcQToMatrix(mcQNorm(q)));
      for(int k=0;k<3;k++){double v=zxy[k];if(prevEuler!=null){double pv=prevEuler[i*3+k];while(v-pv>180)v-=360;while(v-pv<-180)v+=360;}e[i*3+k]=v;row[3+i*3+k]=(float)v;}}
    synchronized(lock){if(!recording)return;prevEuler=e;frames.add(row);if(firstMs==0)firstMs=p.timeMs;lastMs=p.timeMs;frameCount=frames.size();}
  }
  // Stops and writes the file; returns null when nothing was recorded.
  File stop()throws IOException{
    LatestMailbox<MocapPose> b=box;box=null;if(b!=null)b.close(800);
    ArrayList<float[]> rows;long a,z;synchronized(lock){recording=false;rows=new ArrayList<float[]>(frames);a=firstMs;z=lastMs;frames.clear();}
    if(rows.isEmpty())return null;
    double frameTime=rows.size()>1&&z>a?(z-a)/1000.0/(rows.size()-1):1/30.0;
    Files.createDirectories(directory.toPath());
    File file=new File(directory,"mocap-"+new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date())+".bvh");
    try(Writer w=new BufferedWriter(new OutputStreamWriter(new FileOutputStream(file),java.nio.charset.StandardCharsets.US_ASCII))){w.write(bvhText(rows,frameTime));}
    return file;
  }
  String bvhText(List<float[]> rows,double frameTime){
    StringBuilder b=new StringBuilder(rows.size()*300+4096);b.append("HIERARCHY\n");writeJoint(b,0,0);
    b.append("MOTION\nFrames: ").append(rows.size()).append('\n').append(String.format(Locale.ROOT,"Frame Time: %.6f\n",frameTime));
    for(float[] r:rows){for(int k=0;k<r.length;k++){if(k>0)b.append(' ');b.append(String.format(Locale.ROOT,"%.4f",r[k]));}b.append('\n');}
    return b.toString();
  }
  String off(double[] u){return String.format(Locale.ROOT,"%.4f %.4f %.4f",-u[0]*100,u[1]*100,u[2]*100);}
  void writeJoint(StringBuilder b,int bone,int depth){
    String ind=repeat("  ",depth);
    if(bone==0)b.append("ROOT Hips\n{\n  OFFSET 0.0000 0.0000 0.0000\n  CHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation\n");
    else b.append(ind).append("JOINT ").append(MOCAP_BONES[bone]).append('\n').append(ind).append("{\n").append(ind).append("  OFFSET ").append(off(restOffsets[bone])).append('\n')
      .append(ind).append("  CHANNELS 3 Zrotation Xrotation Yrotation\n");
    boolean child=false;for(int i=0;i<MOCAP_BONES.length;i++)if(MOCAP_PARENT[i]==bone){writeJoint(b,i,depth+1);child=true;}
    if(!child){double[] end;String n=MOCAP_BONES[bone];
      if(n.equals("Head"))end=mcV(0,.18,0);
      else if(n.endsWith("Hand"))end=mcV((n.startsWith("Left")?-1:1)*restLengths[RL_HAND]*2.2,0,0);
      else end=mcScale(mcNorm(mcV(0,-.4,1)),restLengths[RL_FOOT]);
      b.append(ind).append("  End Site\n").append(ind).append("  {\n").append(ind).append("    OFFSET ").append(off(end)).append('\n').append(ind).append("  }\n");}
    b.append(ind).append("}\n");
  }
  String repeat(String s,int n){StringBuilder b=new StringBuilder();for(int i=0;i<n;i++)b.append(s);return b.toString();}
}
