// ===== SynSkeleton ONNX body-tracking backend =====
// RGB MoveNet and metric-depth SynSkeleton are selectable pose sources.
// Depth remains metric sensor evidence for the neural input and XYZ deprojection;
// no geometric/articulated pose solver is used as a fallback when the model is
// missing, fails, or does not observe a landmark.
class SynSkeletonOnnxTracker {
  static final int KP=58, BODY_KP=16, HAND_KP=21, IN_W=320, IN_H=240;
  final SkeletonConfig cfg;final SkeletonCalibration3D cal;final KinectSource rgbSource;
  OrtEnvironment env;OrtSession session;String inputName="";File modelFile;
  OrtSession rgbHandSession;String rgbHandInputName="";String rgbHandStatus="hand_model_missing";
  int rgbInputSize=192;int[] rgbBuffer;
  SkeletonPose3D previous=null;String lastReason="model_not_loaded";long trackingId=0,nextTrackingId=1;
  float inferenceMs=0;long lastFrame=-1;

  SynSkeletonOnnxTracker(SkeletonConfig c,Calibration calibration,RgbDepthRegistration registration,KinectSource source){cfg=c;cal=new SkeletonCalibration3D(calibration,registration);rgbSource=source;load();}
  void reset(){previous=null;trackingId=0;lastFrame=-1;lastReason=session==null?"model_not_loaded":"searching";}
  void close(){try{if(session!=null)session.close();}catch(Throwable ignored){}session=null;try{if(rgbHandSession!=null)rgbHandSession.close();}catch(Throwable ignored){}rgbHandSession=null;}
  String status(){return lastReason;}

  File resolveModel(){
    String override=System.getProperty("synkinect.synskeleton.model","").trim();
    if(override.length()>0){File f=new File(override);if(f.isFile())return f;}
    String selected=cfg.trackingMode.equals("rgb")?cfg.rgbModelPath:cfg.depthModelPath;
    File packaged=studioRuntimeFile(selected);if(packaged.isFile())return packaged;
    File sketch=sketchFile(selected);if(sketch!=null&&sketch.isFile())return sketch;
    return null;
  }
  void load(){
    close();modelFile=resolveModel();
    if(modelFile==null){lastReason="synskeleton_model_missing";return;}
    try{
      env=OrtEnvironment.getEnvironment();OrtSession.SessionOptions opt=new OrtSession.SessionOptions();
      opt.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
      session=env.createSession(modelFile.getAbsolutePath(),opt);
      if(cfg.trackingMode.equals("rgb")){
        inputName=session.getInputNames().iterator().next();
        ai.onnxruntime.NodeInfo node=session.getInputInfo().get(inputName);
        if(!(node.getInfo() instanceof ai.onnxruntime.TensorInfo))throw new IllegalArgumentException("RGB input must be a tensor");
        long[] dims=((ai.onnxruntime.TensorInfo)node.getInfo()).getShape();
        if(dims.length!=4||dims[0]!=1||dims[1]<1||dims[1]>1024||dims[2]!=dims[1]||dims[3]!=3)
          throw new IllegalArgumentException("Expected RGB model input [1,size,size,3]");
        if(((ai.onnxruntime.TensorInfo)node.getInfo()).type!=ai.onnxruntime.OnnxJavaType.INT32)
          throw new IllegalArgumentException("MoveNet input must be INT32 RGB pixels");
        ai.onnxruntime.NodeInfo rgbOutput=session.getOutputInfo().values().iterator().next();
        if(!(rgbOutput.getInfo() instanceof ai.onnxruntime.TensorInfo))throw new IllegalArgumentException("MoveNet output must be a tensor");
        ai.onnxruntime.TensorInfo rgbInfo=(ai.onnxruntime.TensorInfo)rgbOutput.getInfo();
        long[] rgbShape=rgbInfo.getShape();
        if(rgbInfo.type!=ai.onnxruntime.OnnxJavaType.FLOAT||rgbShape.length!=4||rgbShape[0]!=1||rgbShape[1]!=1||rgbShape[2]!=17||rgbShape[3]!=3)
          throw new IllegalArgumentException("Expected MoveNet output FLOAT [1,1,17,3]");
        rgbInputSize=(int)dims[1];
        loadRgbHands();
      }else{
      if(!session.getInputNames().contains("depth_metric"))throw new IllegalArgumentException("Expected ONNX input depth_metric");
      inputName="depth_metric";
      ai.onnxruntime.NodeInfo node=session.getInputInfo().get(inputName);
      if(!(node.getInfo() instanceof ai.onnxruntime.TensorInfo))throw new IllegalArgumentException("Input must be a tensor");
      long[] dims=((ai.onnxruntime.TensorInfo)node.getInfo()).getShape();
      if(dims.length!=4||(dims[0]!=1&&dims[0]!=-1)||dims[1]!=1||dims[2]!=IN_H||dims[3]!=IN_W)
        throw new IllegalArgumentException("Expected ONNX input [1,1,240,320]");
      if(!session.getOutputNames().contains("keypoints"))throw new IllegalArgumentException("Expected ONNX output keypoints");
      ai.onnxruntime.NodeInfo outputNode=session.getOutputInfo().get("keypoints");
      if(!(outputNode.getInfo() instanceof ai.onnxruntime.TensorInfo))throw new IllegalArgumentException("Keypoints output must be a tensor");
      long[] outputShape=((ai.onnxruntime.TensorInfo)outputNode.getInfo()).getShape();
      if(outputShape.length!=3||(outputShape[0]!=1&&outputShape[0]!=-1)||outputShape[1]!=KP||outputShape[2]!=4)
        throw new IllegalArgumentException("Expected ONNX keypoints output [1,58,4]");
      }
      lastReason="searching";
    }catch(Throwable e){lastReason="synskeleton_load_error: "+shortError(e);close();}
  }

  SkeletonPose3D track(DepthFrame depth,long tick){
    SkeletonPose3D empty=new SkeletonPose3D();empty.poseSource="SynSkeleton.onnx";
    if(session==null){if(modelFile==null)load();empty.reason=lastReason;return empty;}
    if(depth==null||depth.depth==null){empty.reason="no_depth";lastReason=empty.reason;return empty;}
    try{
      long t0=System.nanoTime();float[][] kp=infer(depth);inferenceMs=(System.nanoTime()-t0)/1_000_000.0f;
      if(kp==null){empty.reason="model_output_invalid";lastReason=empty.reason;return empty;}
      SkeletonPose3D pose=buildPose(kp,depth,tick);lastFrame=depth.frameNumber;
      if(pose.tracked){previous=pose;lastReason="tracked_synskeleton";}else{previous=null;lastReason=pose.reason;}
      return pose;
    }catch(Throwable e){previous=null;empty.reason="synskeleton_inference_error";lastReason=empty.reason+": "+shortError(e);return empty;}
  }

  // MoveNet supplies body landmarks only; finger landmarks require a separately validated hand model.
  SkeletonPose3D trackRgb(DepthFrame depth,RawRgbFrame rgb,long tick){
    SkeletonPose3D empty=new SkeletonPose3D();empty.poseSource="MoveNet.onnx";
    if(session==null){empty.reason=lastReason;return empty;}
    if(depth==null||depth.depth==null||rgb==null||rgb.data==null){empty.reason="waiting_for_synchronized_rgbd";lastReason=empty.reason;return empty;}
    try{
      float[][] points=inferRgb(rgb,depth);
      if(points==null){empty.reason="invalid_rgb_model_output";lastReason=empty.reason;return empty;}
      SkeletonPose3D pose=buildPose(points,depth,tick);pose.poseSource="MoveNet.onnx";
      if(pose.tracked&&rgbHandSession!=null){
        inferRgbHands(pose,depth,rgb,tick);
        smoothObserved(pose,previous,tick);
        pose.leftHandDetail.updateConfidence();pose.rightHandDetail.updateConfidence();
        derivePalmBodyJoint(pose.leftHand,pose.leftHandDetail,pose.leftWrist,tick);
        derivePalmBodyJoint(pose.rightHand,pose.rightHandDetail,pose.rightWrist,tick);
        copyFromHand(pose.leftHandTip,pose.leftHandDetail,12,.94f,tick);copyFromHand(pose.rightHandTip,pose.rightHandDetail,12,.94f,tick);
        copyFromHand(pose.leftThumb,pose.leftHandDetail,4,.94f,tick);copyFromHand(pose.rightThumb,pose.rightHandDetail,4,.94f,tick);
        pose.interactionConfidence=constrain(.55f*pose.torsoConfidence+.45f*max(pose.leftHandDetail.confidence,pose.rightHandDetail.confidence),0,1);
        pose.confidence=meanConfidence(pose.canonicalJoints());
      }
      previous=pose;
      lastReason=pose.tracked?"tracked_rgb_body":"acquiring_rgb_body";
      pose.reason=lastReason;return pose;
    }catch(Throwable e){empty.reason="rgb_inference_error";lastReason=empty.reason+": "+shortError(e);return empty;}
  }


  // The RGB hand teacher uses the same RTMPose SimCC output contract as DepthAutoLearn.
  // All 3D hand landmarks still require calibrated, observed depth measurements.
  void loadRgbHands(){
    rgbHandStatus="hand_model_missing";
    File model=studioRuntimeFile("data/skeleton/rtmpose-hand.onnx");
    if(model==null||!model.isFile())model=sketchFile("data/skeleton/rtmpose-hand.onnx");
    if(model==null||!model.isFile())return;
    try{
      OrtSession.SessionOptions options=new OrtSession.SessionOptions();
      options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
      rgbHandSession=env.createSession(model.getAbsolutePath(),options);
      rgbHandInputName=rgbHandSession.getInputNames().iterator().next();
      ai.onnxruntime.NodeInfo node=rgbHandSession.getInputInfo().get(rgbHandInputName);
      if(!(node.getInfo() instanceof ai.onnxruntime.TensorInfo))throw new IllegalArgumentException("Hand input must be a tensor");
      ai.onnxruntime.TensorInfo info=(ai.onnxruntime.TensorInfo)node.getInfo();
      long[] shape=info.getShape();
      if(shape.length!=4||shape[1]!=3||shape[2]!=256||shape[3]!=256||info.type!=ai.onnxruntime.OnnxJavaType.FLOAT)
        throw new IllegalArgumentException("Expected RTMPose hand FLOAT [1,3,256,256]");
      if(rgbHandSession.getOutputNames().size()<2)throw new IllegalArgumentException("Expected two SimCC outputs");
      rgbHandStatus="ready";
    }catch(Throwable e){rgbHandStatus="hand_model_error: "+shortError(e);try{if(rgbHandSession!=null)rgbHandSession.close();}catch(Throwable ignored){}rgbHandSession=null;}
  }

  void inferRgbHands(SkeletonPose3D pose,DepthFrame depth,RawRgbFrame rgb,long tick){
    if(rgbBuffer==null||rgbBuffer.length<rgb.width*rgb.height)return;
    try{
      inferRgbHand(pose.leftHandDetail,pose.leftWrist,pose.leftElbow,depth,rgb,tick);
      inferRgbHand(pose.rightHandDetail,pose.rightWrist,pose.rightElbow,depth,rgb,tick);
      rgbHandStatus="ready";
    }catch(Throwable e){rgbHandStatus="hand_inference_error: "+shortError(e);}
  }

  void inferRgbHand(SkeletonHand3D hand,SkeletonJoint3D wrist,SkeletonJoint3D elbow,DepthFrame depth,RawRgbFrame rgb,long tick)throws Exception{
    if(!wrist.tracked()||!elbow.tracked())return;
    PVector w=wrist.image,e=elbow.image;
    float fore=PVector.dist(w,e);if(!Float.isFinite(fore)||fore<12)return;
    float vx=(w.x-e.x)/fore,vy=(w.y-e.y)/fore;
    float side=constrain(fore*1.55f,72,190);
    float x0=w.x+vx*fore*.20f-side*.5f,y0=w.y+vy*fore*.20f-side*.5f;
    final int size=256;
    float[] mean={123.675f,116.28f,103.53f},std={58.395f,57.12f,57.375f};
    FloatBuffer pixels=FloatBuffer.allocate(3*size*size);
    for(int c=0;c<3;c++)for(int y=0;y<size;y++)for(int x=0;x<size;x++){
      int sx=constrain(round(x0+(x+.5f)*side/size),0,rgb.width-1);
      int sy=constrain(round(y0+(y+.5f)*side/size),0,rgb.height-1);
      int color=rgbBuffer[sy*rgb.width+sx];
      int channel=c==0?((color>>16)&255):c==1?((color>>8)&255):(color&255);
      pixels.put((channel-mean[c])/std[c]);
    }
    pixels.rewind();
    try(OnnxTensor input=OnnxTensor.createTensor(env,pixels,new long[]{1,3,size,size})){
      HashMap<String,OnnxTensor> args=new HashMap<String,OnnxTensor>();args.put(rgbHandInputName,input);
      try(OrtSession.Result output=rgbHandSession.run(args)){
        if(output.size()<2)return;
        Object ox=output.get(0).getValue(),oy=output.get(1).getValue();
        if(!(ox instanceof float[][][])||!(oy instanceof float[][][]))return;
        float[][][] xx=(float[][][])ox,yy=(float[][][])oy;
        if(xx.length<1||yy.length<1||xx[0].length<21||yy[0].length<21)return;
        // Project candidate depth samples once per hand, rather than once per landmark.
        java.util.ArrayList<float[]> candidates=new java.util.ArrayList<float[]>();
        for(int dy=0;dy<depth.height;dy+=3)for(int dx=0;dx<depth.width;dx+=3){
          int idx=dy*depth.width+dx,mm=depth.depth[idx]&0xffff;
          if(mm<350||mm>6000)continue;
          if(cal.sharedCalibration!=null)mm=cal.sharedCalibration.correctedDepthMm(idx,mm);
          if(mm<350||mm>6000||abs(mm-round(wrist.world.z*1000))>300)continue;
          PVector uv=cal.projectRgb(dx,dy,mm);
          if(uv!=null&&uv.x>=x0-20&&uv.x<=x0+side+20&&uv.y>=y0-20&&uv.y<=y0+side+20)
            candidates.add(new float[]{uv.x,uv.y,dx,dy,mm});
        }
        int valid=0;
        for(int k=0;k<21;k++){
          if(xx[0][k]==null||yy[0][k]==null||xx[0][k].length<2||yy[0][k].length<2)continue;
          int ix=0,iy=0;float maxX=-Float.MAX_VALUE,maxY=-Float.MAX_VALUE;
          for(int j=0;j<xx[0][k].length;j++)if(xx[0][k][j]>maxX){maxX=xx[0][k][j];ix=j;}
          for(int j=0;j<yy[0][k].length;j++)if(yy[0][k][j]>maxY){maxY=yy[0][k][j];iy=j;}
          float conf=1.0f/(1.0f+exp(-min(maxX,maxY)));
          if(conf<.45f)continue;
          float px=x0+ix*.5f*side/size,py=y0+iy*.5f*side/size;
          if(px<0||px>=rgb.width||py<0||py>=rgb.height)continue;
          float[] nearest=null;float best=18*18;
          for(float[] candidate:candidates){
            float dist=(candidate[0]-px)*(candidate[0]-px)+(candidate[1]-py)*(candidate[1]-py);
            if(dist<best){best=dist;nearest=candidate;}
          }
          if(nearest==null)continue;
          float[] q={(nearest[2]+.5f)/depth.width,(nearest[3]+.5f)/depth.height,nearest[4],conf};
          setModelJoint(hand.landmarks[k],q,depth,tick,.45f,"rtmpose-rgb-hand");
          if(hand.landmarks[k].tracked())valid++;
        }
        if(valid<8){for(SkeletonJoint3D joint:hand.landmarks)clearJoint(joint);clearJoint(hand.palm);return;}
        SkeletonJoint3D[] anchors={hand.landmarks[0],hand.landmarks[5],hand.landmarks[9],hand.landmarks[13],hand.landmarks[17]};
        deriveAverage(hand.palm,anchors,.88f,"rtmpose-rgb-palm",tick);
        hand.source="RTMPose Hand ONNX";hand.updateConfidence();
      }
    }
  }

  float[][] inferRgb(RawRgbFrame rgb,DepthFrame depth)throws Exception{
    if(rgb.width<=0||rgb.height<=0||rgb.width>4096||rgb.height>4096)return null;
    int count=rgb.width*rgb.height;
    if(rgbBuffer==null||rgbBuffer.length!=count)rgbBuffer=new int[count];
    if(rgbSource==null||!rgbSource.decodeRgbPayloadToArgb(rgb.data,rgb.width,rgb.height,rgb.pixelFormat,rgbBuffer))return null;
    java.nio.IntBuffer values=java.nio.IntBuffer.allocate(rgbInputSize*rgbInputSize*3);
    for(int y=0;y<rgbInputSize;y++)for(int x=0;x<rgbInputSize;x++){
      int sx=min(rgb.width-1,(int)((x+.5f)*rgb.width/rgbInputSize));
      int sy=min(rgb.height-1,(int)((y+.5f)*rgb.height/rgbInputSize));
      int color=rgbBuffer[sy*rgb.width+sx];values.put((color>>16)&255);values.put((color>>8)&255);values.put(color&255);
    }
    values.rewind();float[][] result=new float[KP][4];
    try(OnnxTensor tensor=OnnxTensor.createTensor(env,values,new long[]{1,rgbInputSize,rgbInputSize,3})){
      java.util.HashMap<String,OnnxTensor> inputs=new java.util.HashMap<String,OnnxTensor>();inputs.put(inputName,tensor);
      try(OrtSession.Result output=session.run(inputs)){
        Object raw=output.get(0).getValue();
        if(!(raw instanceof float[][][][]))return null;
        float[][][][] landmarks=(float[][][][])raw;
        if(landmarks.length!=1||landmarks[0].length!=1||landmarks[0][0].length!=17)return null;
        int[] mapped={0,0,0,0,5,6,7,8,9,10,11,12,13,14,15,16};
        // All 3D points are taken from calibrated depth, never guessed from RGB pixels.
        RgbDepthRegistration registration=cal.sharedRegistration;
        registration.projectionScaleX=rgb.width/(float)max(1,cal.sharedCalibration.depthWidth);
        registration.projectionScaleY=rgb.height/(float)max(1,cal.sharedCalibration.depthHeight);
        for(int j=0;j<16;j++){
          int k=mapped[j];if(j>=1&&j<=3)continue;
          float[] point=landmarks[0][0][k];
          if(point==null||point.length<3||!Float.isFinite(point[0])||!Float.isFinite(point[1])||!Float.isFinite(point[2]))continue;
          float confidence=constrain(point[2],0,1);
          if(confidence<.14f)continue;
          float px=point[1]*rgb.width,py=point[0]*rgb.height;
          float best=Float.POSITIVE_INFINITY;int bestIndex=-1,bestMm=0;
          for(int dy=0;dy<depth.height;dy+=3)for(int dx=0;dx<depth.width;dx+=3){
            int index=dy*depth.width+dx,mm=depth.depth[index]&0xffff;
            if(mm<350||mm>6000)continue;
            if(cal.sharedCalibration!=null)mm=cal.sharedCalibration.correctedDepthMm(index,mm);
            if(mm<350||mm>6000)continue;
            PVector uv=cal.projectRgb(dx,dy,mm);if(uv==null)continue;
            float dist=(uv.x-px)*(uv.x-px)+(uv.y-py)*(uv.y-py);
            if(dist<best){best=dist;bestIndex=index;bestMm=mm;}
          }
          if(bestIndex<0||best>36*36)continue;
          int dx=bestIndex%depth.width,dy=bestIndex/depth.width;
          result[j][0]=(dx+.5f)/depth.width;result[j][1]=(dy+.5f)/depth.height;
          result[j][2]=bestMm;result[j][3]=confidence;
        }
      }
    }
    return result;
  }

  float[][] infer(DepthFrame d)throws Exception{
    FloatBuffer fb=FloatBuffer.allocate(IN_W*IN_H);
    float[] valid=new float[4];
    if(d.width<=0||d.height<=0||d.depth==null||(long)d.depth.length<(long)d.width*d.height)return null;
    boolean halve=(d.width==IN_W*2&&d.height==IN_H*2);
    for(int y=0;y<IN_H;y++){
      int sy=min(d.height-1,(int)((y+.5f)*d.height/IN_H));
      for(int x=0;x<IN_W;x++){
        int sx=min(d.width-1,(int)((x+.5f)*d.width/IN_W));
        float mm=0;
        if(halve){
          int xx=x*2,yy=y*2;
          int n=0;
          for(int oy=0;oy<2;oy++)for(int ox=0;ox<2;ox++){
            int idx=(yy+oy)*d.width+xx+ox;
            int raw=d.depth[idx]&0xffff;
            if(raw>0&&cal.sharedCalibration!=null)raw=cal.sharedCalibration.correctedDepthMm(idx,raw);
            if(raw>350&&raw<6000)valid[n++]=raw;
          }
          if(n>0){java.util.Arrays.sort(valid,0,n);mm=(n%2==1)?valid[n/2]:(valid[n/2-1]+valid[n/2])*.5f;}
        }else{
          int idx=sy*d.width+sx;int raw=d.depth[idx]&0xffff;
          if(raw>0&&cal.sharedCalibration!=null)raw=cal.sharedCalibration.correctedDepthMm(idx,raw);
          if(raw>350&&raw<6000)mm=raw;
        }
        fb.put(mm>350&&mm<6000?constrain((mm-2200.0f)/1800.0f,-1.0f,1.8f):-2.0f);
      }
    }
    fb.rewind();long[] shape={1,1,IN_H,IN_W};
    try(OnnxTensor in=OnnxTensor.createTensor(env,fb,shape)){
      HashMap<String,OnnxTensor> inputs=new HashMap<String,OnnxTensor>();inputs.put(inputName,in);
      try(OrtSession.Result result=session.run(inputs)){
        if(result.size()<1)return null;Object value=result.get("keypoints").orElseThrow(()->new IllegalArgumentException("Missing keypoints output")).getValue();if(!(value instanceof float[][][]))return null;
        float[][][] out=(float[][][])value;if(out.length!=1||out[0]==null||out[0].length!=KP)return null;for(float[] point:out[0])if(point==null||point.length!=4)return null;return out[0];
      }
    }
  }

  SkeletonPose3D buildPose(float[][] k,DepthFrame depth,long tick){
    SkeletonPose3D s=new SkeletonPose3D();s.poseSource="SynSkeleton.onnx";s.reason="acquiring_synskeleton";
    // Model layout: head,nose,earL,earR, shoulders, elbows, wrists, hips,
    // knees, ankles, then 21 left-hand and 21 right-hand landmarks.
    setModelJoint(s.head,k[0],depth,tick,.20f,"synskeleton-head");
    setModelJoint(s.leftShoulder,k[4],depth,tick,.18f,"synskeleton");setModelJoint(s.rightShoulder,k[5],depth,tick,.18f,"synskeleton");
    setModelJoint(s.leftElbow,k[6],depth,tick,.16f,"synskeleton");setModelJoint(s.rightElbow,k[7],depth,tick,.16f,"synskeleton");
    setModelJoint(s.leftWrist,k[8],depth,tick,.14f,"synskeleton");setModelJoint(s.rightWrist,k[9],depth,tick,.14f,"synskeleton");
    setModelJoint(s.leftHip,k[10],depth,tick,.18f,"synskeleton");setModelJoint(s.rightHip,k[11],depth,tick,.18f,"synskeleton");
    setModelJoint(s.leftKnee,k[12],depth,tick,.16f,"synskeleton");setModelJoint(s.rightKnee,k[13],depth,tick,.16f,"synskeleton");
    setModelJoint(s.leftAnkle,k[14],depth,tick,.14f,"synskeleton");setModelJoint(s.rightAnkle,k[15],depth,tick,.14f,"synskeleton");
    setHand(s.leftHandDetail,k,16,depth,tick);setHand(s.rightHandDetail,k,37,depth,tick);

    deriveMidpoint(s.shoulderCenter,s.leftShoulder,s.rightShoulder,.96f,"synskeleton-derived",tick);
    copyJoint(s.spineShoulder,s.shoulderCenter,.98f,"synskeleton-derived",tick);
    deriveMidpoint(s.hipCenter,s.leftHip,s.rightHip,.96f,"synskeleton-derived",tick);
    deriveBetween(s.spine,s.shoulderCenter,s.hipCenter,.55f,.93f,"synskeleton-derived",tick);
    derivePalmBodyJoint(s.leftHand,s.leftHandDetail,s.leftWrist,tick);derivePalmBodyJoint(s.rightHand,s.rightHandDetail,s.rightWrist,tick);
    deriveFoot(s.leftFoot,s.leftKnee,s.leftAnkle,tick);deriveFoot(s.rightFoot,s.rightKnee,s.rightAnkle,tick);
    copyFromHand(s.leftHandTip,s.leftHandDetail,12,.94f,tick);copyFromHand(s.rightHandTip,s.rightHandDetail,12,.94f,tick);
    copyFromHand(s.leftThumb,s.leftHandDetail,4,.94f,tick);copyFromHand(s.rightThumb,s.rightHandDetail,4,.94f,tick);

    smoothObserved(s,previous,tick);
    s.leftHandDetail.updateConfidence();s.rightHandDetail.updateConfidence();
    int core=trackedCount(new SkeletonJoint3D[]{s.leftShoulder,s.rightShoulder,s.leftHip,s.rightHip});
    float torsoQ=meanConfidence(new SkeletonJoint3D[]{s.leftShoulder,s.rightShoulder,s.leftHip,s.rightHip,s.shoulderCenter,s.hipCenter,s.spine});
    s.torsoConfidence=torsoQ;s.upperBodyConfidence=meanConfidence(new SkeletonJoint3D[]{s.head,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist});
    s.lowerBodyConfidence=meanConfidence(new SkeletonJoint3D[]{s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle});
    s.interactionConfidence=constrain(.55f*torsoQ+.45f*max(s.leftHandDetail.confidence,s.rightHandDetail.confidence),0,1);
    s.confidence=meanConfidence(s.canonicalJoints());
    s.tracked=core>=3&&torsoQ>=.16f;
    if(s.tracked){if(trackingId==0)trackingId=nextTrackingId++;s.trackingId=trackingId;s.reason="tracked_synskeleton";derivePresentation(s,depth);}
    else{trackingId=0;s.reason="acquiring_synskeleton";}
    classifyPosture(s);return s;
  }

  void setModelJoint(SkeletonJoint3D j,float[] q,DepthFrame d,long tick,float minQ,String src){
    clearJoint(j);if(q==null||q.length<4)return;float conf=constrain(q[3],0,1),zmm=q[2];if(!Float.isFinite(conf)||!Float.isFinite(zmm)||!Float.isFinite(q[0])||!Float.isFinite(q[1])||conf<minQ||zmm<350||zmm>6000||q[0]<0||q[0]>1||q[1]<0||q[1]>1)return;
    int u=constrain(round(constrain(q[0],0,1)*(d.width-1)),0,d.width-1),v=constrain(round(constrain(q[1],0,1)*(d.height-1)),0,d.height-1);
    PVector xyz=cal.deproject(u,v,round(zmm));if(xyz==null||xyz.z<=0)return;PVector rgb=cal.projectWorldRgb(xyz);if(rgb==null)rgb=new PVector(u,v);
    j.set(rgb,xyz,conf,SkeletonJoint3D.TRACKED,src,tick);
  }
  void setHand(SkeletonHand3D h,float[][] k,int base,DepthFrame d,long tick){
    for(int i=0;i<HAND_KP;i++)setModelJoint(h.landmarks[i],k[base+i],d,tick,.11f,"synskeleton-hand");
    // No hand is synthesized. Palm exists only when current model landmarks support it.
    SkeletonJoint3D[] anchors={h.landmarks[0],h.landmarks[5],h.landmarks[9],h.landmarks[13],h.landmarks[17]};deriveAverage(h.palm,anchors,.88f,"synskeleton-palm",tick);
    h.source="SynSkeleton.onnx";h.updateConfidence();
  }
  void derivePalmBodyJoint(SkeletonJoint3D out,SkeletonHand3D hand,SkeletonJoint3D wrist,long tick){clearJoint(out);if(hand!=null&&hand.palm.tracked()){copyJoint(out,hand.palm,.98f,"synskeleton-palm",tick);return;}if(wrist!=null&&wrist.tracked())copyJoint(out,wrist,.82f,"synskeleton-wrist",tick);}
  void deriveFoot(SkeletonJoint3D out,SkeletonJoint3D knee,SkeletonJoint3D ankle,long tick){clearJoint(out);if(knee==null||ankle==null||!knee.tracked()||!ankle.tracked())return;PVector axis=PVector.sub(ankle.world,knee.world);if(axis.magSq()<1e-6f)return;axis.normalize();PVector xyz=PVector.add(ankle.world,PVector.mult(axis,.12f));PVector uv=cal.projectWorldRgb(xyz);if(uv==null)uv=cal.projectDepth(xyz);if(uv!=null)out.set(uv,xyz,min(knee.confidence,ankle.confidence)*.72f,SkeletonJoint3D.INFERRED,"synskeleton-derived",tick);}
  void copyFromHand(SkeletonJoint3D out,SkeletonHand3D h,int idx,float scale,long tick){clearJoint(out);if(h==null||idx<0||idx>=HAND_KP||!h.landmarks[idx].tracked())return;copyJoint(out,h.landmarks[idx],scale,"synskeleton-hand",tick);}

  void deriveMidpoint(SkeletonJoint3D out,SkeletonJoint3D a,SkeletonJoint3D b,float scale,String src,long tick){deriveBetween(out,a,b,.5f,scale,src,tick);}
  void deriveBetween(SkeletonJoint3D out,SkeletonJoint3D a,SkeletonJoint3D b,float t,float scale,String src,long tick){clearJoint(out);if(a==null||b==null||!a.tracked()||!b.tracked())return;PVector xyz=PVector.lerp(a.world,b.world,t),uv=cal.projectWorldRgb(xyz);if(uv==null)uv=cal.projectDepth(xyz);if(uv!=null)out.set(uv,xyz,min(a.confidence,b.confidence)*scale,SkeletonJoint3D.INFERRED,src,tick);}
  void deriveAverage(SkeletonJoint3D out,SkeletonJoint3D[] in,float scale,String src,long tick){clearJoint(out);PVector xyz=new PVector();float sum=0;int n=0;for(SkeletonJoint3D j:in)if(j!=null&&j.tracked()){float w=max(.05f,j.confidence);xyz.add(PVector.mult(j.world,w));sum+=w;n++;}if(n<2||sum<=0)return;xyz.div(sum);PVector uv=cal.projectWorldRgb(xyz);if(uv==null)uv=cal.projectDepth(xyz);if(uv!=null)out.set(uv,xyz,constrain((sum/n)*scale,0,1),SkeletonJoint3D.INFERRED,src,tick);}
  void copyJoint(SkeletonJoint3D out,SkeletonJoint3D src,float scale,String source,long tick){if(out==null||src==null||!src.tracked())return;out.set(src.image,src.world,src.confidence*scale,src.state,source,tick);}
  void clearJoint(SkeletonJoint3D j){if(j==null)return;j.confidence=0;j.state=SkeletonJoint3D.LOST;j.source="SynSkeleton.onnx";j.velocity.set(0,0,0);}

  void smoothObserved(SkeletonPose3D cur,SkeletonPose3D prev,long tick){
    if(cur==null||prev==null)return;HashMap<String,SkeletonJoint3D> old=new HashMap<String,SkeletonJoint3D>();for(SkeletonJoint3D j:prev.canonicalJoints())if(j!=null)old.put(j.name,j);
    for(SkeletonJoint3D j:cur.canonicalJoints()){
      if(j==null||!j.observed())continue;SkeletonJoint3D p=old.get(j.name);if(p==null||!p.observed())continue;
      float delta=PVector.dist(j.world,p.world),alpha=j.name.indexOf("thumb")>=0||j.name.indexOf("index")>=0||j.name.indexOf("middle")>=0||j.name.indexOf("ring")>=0||j.name.indexOf("pinky")>=0?.48f:.38f;
      if(delta>.12f)alpha=.78f;else if(delta<.008f)alpha=.24f;PVector filtered=PVector.lerp(p.world,j.world,alpha);PVector uv=cal.projectWorldRgb(filtered);if(uv==null)uv=cal.projectDepth(filtered);if(uv!=null){j.world.set(filtered);j.image.set(uv);}
    }
  }

  void derivePresentation(SkeletonPose3D s,DepthFrame d){
    int minX=d.width-1,minY=d.height-1,maxX=0,maxY=0,n=0;float z=0;
    for(SkeletonJoint3D j:s.canonicalJoints())if(j!=null&&j.tracked()&&j.world.z>0){PVector uv=cal.projectDepth(j.world);if(uv!=null){minX=min(minX,round(uv.x));maxX=max(maxX,round(uv.x));minY=min(minY,round(uv.y));maxY=max(maxY,round(uv.y));}z+=j.world.z;n++;}
    if(n>0){s.minX=constrain(minX,0,d.width-1);s.maxX=constrain(maxX,0,d.width-1);s.minY=constrain(minY,0,d.height-1);s.maxY=constrain(maxY,0,d.height-1);s.meanDepthM=z/n;s.clippedTop=s.minY<=4;s.clippedBottom=s.maxY>=d.height-5;}
    s.lowerBodyVisible=s.leftKnee.tracked()||s.rightKnee.tracked()||s.leftAnkle.tracked()||s.rightAnkle.tracked();
    if(s.leftShoulder.tracked()&&s.rightShoulder.tracked()){float px=PVector.dist(s.leftShoulder.image,s.rightShoulder.image);s.faceWidthPx=constrain(px*.36f,18,140);s.faceHeightPx=s.faceWidthPx*1.25f;}
  }
  void classifyPosture(SkeletonPose3D s){
    s.posture="unknown";s.postureConfidence=0;if(!s.hipCenter.tracked())return;
    float q=s.lowerBodyConfidence;if((s.leftKnee.tracked()&&s.leftAnkle.tracked())||(s.rightKnee.tracked()&&s.rightAnkle.tracked())){
      SkeletonJoint3D hip=s.leftKnee.tracked()?s.leftHip:s.rightHip,knee=s.leftKnee.tracked()?s.leftKnee:s.rightKnee,ankle=s.leftAnkle.tracked()?s.leftAnkle:s.rightAnkle;
      if(hip.tracked()&&knee.tracked()&&ankle.tracked()){PVector thigh=PVector.sub(knee.world,hip.world),shin=PVector.sub(ankle.world,knee.world);float bend=degrees(PVector.angleBetween(PVector.mult(thigh,-1),shin));if(bend<135){s.posture="seated";s.postureConfidence=constrain(q+.18f,0,1);}else{s.posture="standing";s.postureConfidence=constrain(q+.15f,0,1);}return;}
    }
    s.posture="standing";s.postureConfidence=constrain(s.torsoConfidence*.65f,0,1);
  }
  int trackedCount(SkeletonJoint3D[] a){int n=0;for(SkeletonJoint3D j:a)if(j!=null&&j.tracked())n++;return n;}
  float meanConfidence(SkeletonJoint3D[] a){float sum=0;int n=0;for(SkeletonJoint3D j:a)if(j!=null&&j.tracked()){sum+=j.confidence;n++;}return n==0?0:constrain(sum/n,0,1);}
  String shortError(Throwable e){String s=e==null?"unknown":e.getMessage();if(s==null||s.length()==0)s=e.getClass().getSimpleName();return s.length()>120?s.substring(0,120):s;}
}
