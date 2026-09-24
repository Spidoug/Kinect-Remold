// Shared spatial-audio DSP for built-in modules.
// The library owns no UI, transport, or module state and can be instantiated independently.

class SpatialAudioFrame {
  static final int CHANNELS=4;
  static final int SAMPLES=256;
  long frameNumber,tickMs;
  int channelMask;
  int[][] samples=new int[CHANNELS][SAMPLES];
  float[] peak=new float[CHANNELS];
  boolean valid(int channel){return channel>=0&&channel<CHANNELS&&(channelMask&(1<<channel))!=0;
    }
  boolean channelValid(int channel){return valid(channel);}
}


// ===== SynKinect Studio / Acoustic Scanner / SpatialAudioConfig.pde =====
class SpatialAudioConfig {
  int uiFrameRate=30,workerJoinMs=1200,reconnectMs=300,pipeOpenAttempts=4,pipeOpenRetryMs=75,noFrameWarningMs=2000,connectionStaleMs=3500;
  
  float soundSpeedMps=343.0f,minimumRms=0.0018f,occupancyDecay=0.94f;
  float localizationLowHz=120.0f,localizationHighHz=4200.0f,pairWeightFloor=0.20f,pairSharpnessGain=1.55f;
  
  float trackingSlowAlpha=0.10f,trackingFastAlpha=0.58f,trackingMaxJumpDeg=24.0f,trackingMinStability=0.38f,trackingPositionAlpha=0.22f;
  
  // Measured Kinect Xbox 360 channel coordinates in metres (channel 1..4).
  float[] microphoneXM={0.113f,-0.036f,-0.076f,-0.113f};
  // Voice-aware AUTO steering: only persistent, speech-like DOA candidates can move the beam.
  float voiceLowHz=100.0f,voiceHighHz=3600.0f,voiceBandMinRatio=0.56f;
  float voiceFlatnessMax=0.72f,voiceCoherenceMin=0.26f,voiceZcrMin=0.015f,voiceZcrMax=0.32f;
  float vadSnrOnDb=10.0f,vadSnrOffDb=6.0f,vadProbability=0.68f,noiseFloorAdaptDown=0.16f,noiseFloorAdaptUp=0.006f;
  
  int vadAttackFrames=5,vadReleaseFrames=14;
  float autoConfidence=0.075f,autoMaxSpreadDeg=8.0f,autoDeadbandDeg=7.0f,autoMaxSlewDegPerSec=35.0f;
  
  int autoDwellFrames=16,autoHoldMs=1200,autoUpdateMinMs=90;
  float beamOutputGain=1.25f;
  // Spectral noise suppression after spatial beamforming.
  boolean noiseSuppress=true;float noiseOverSubtract=1.35f,noiseMinGain=0.10f,noiseAdapt=0.035f,noiseSpeechAdapt=0.0015f;
  
  int beamQueueFrames=10,beamLineBufferBytes=8192;
  float locateXMinM=-2.5f,locateXMaxM=2.5f,locateZMinM=0.30f,locateZMaxM=4.0f;
  int locateXSteps=51,locateZSteps=38;

  void load(File file,String owner){
    Properties p=studio.services.configRules.load(file,owner);
      uiFrameRate=intValue(p,"ui.frameRate",uiFrameRate,10,120);
      workerJoinMs=intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);
      reconnectMs=intValue(p,"transport.reconnectMs",reconnectMs,50,5000);
      pipeOpenAttempts=intValue(p,"transport.pipeOpenAttempts",pipeOpenAttempts,1,20);
    
      pipeOpenRetryMs=intValue(p,"transport.pipeOpenRetryMs",pipeOpenRetryMs,10,1000);
    
      noFrameWarningMs=intValue(p,"transport.noFrameWarningMs",noFrameWarningMs,250,30000);
    
      connectionStaleMs=intValue(p,"transport.connectionStaleMs",connectionStaleMs,500,30000);
    
      soundSpeedMps=floatValue(p,"scan.soundSpeedMps",soundSpeedMps,250,400);
      minimumRms=floatValue(p,"scan.minimumRms",minimumRms,0,0.5f);
      occupancyDecay=floatValue(p,"scan.occupancyDecay",occupancyDecay,0,0.9999f);
    
      localizationLowHz=floatValue(p,"localization.lowHz",localizationLowHz,40,3000);
    
      localizationHighHz=floatValue(p,"localization.highHz",localizationHighHz,localizationLowHz+100,7900);
    
      pairWeightFloor=floatValue(p,"localization.pairWeightFloor",pairWeightFloor,0.0f,1.0f);
    
      pairSharpnessGain=floatValue(p,"localization.pairSharpnessGain",pairSharpnessGain,0.1f,4.0f);
    
      trackingSlowAlpha=floatValue(p,"tracking.slowAlpha",trackingSlowAlpha,0.01f,1.0f);
    
      trackingFastAlpha=floatValue(p,"tracking.fastAlpha",trackingFastAlpha,trackingSlowAlpha,1.0f);
    
      trackingMaxJumpDeg=floatValue(p,"tracking.maxJumpDeg",trackingMaxJumpDeg,2.0f,90.0f);
    
      trackingMinStability=floatValue(p,"tracking.minStability",trackingMinStability,0.0f,1.0f);
    
      trackingPositionAlpha=floatValue(p,"tracking.positionAlpha",trackingPositionAlpha,0.01f,1.0f);
    
      voiceLowHz=floatValue(p,"voice.lowHz",voiceLowHz,40,500);
      voiceHighHz=floatValue(p,"voice.highHz",voiceHighHz,1000,7500);
      voiceBandMinRatio=floatValue(p,"voice.bandMinRatio",voiceBandMinRatio,0.10f,0.95f);
      voiceFlatnessMax=floatValue(p,"voice.flatnessMax",voiceFlatnessMax,0.20f,0.98f);
      voiceCoherenceMin=floatValue(p,"voice.coherenceMin",voiceCoherenceMin,0.0f,0.95f);
      voiceZcrMin=floatValue(p,"voice.zcrMin",voiceZcrMin,0.0f,0.25f);
      voiceZcrMax=floatValue(p,"voice.zcrMax",voiceZcrMax,voiceZcrMin+0.02f,0.75f);
    
      vadSnrOnDb=floatValue(p,"voice.snrOnDb",vadSnrOnDb,0,40);
      vadSnrOffDb=floatValue(p,"voice.snrOffDb",vadSnrOffDb,0,vadSnrOnDb);
      vadProbability=floatValue(p,"voice.probability",vadProbability,0.10f,0.99f);
    
      vadAttackFrames=intValue(p,"voice.attackFrames",vadAttackFrames,1,60);
      vadReleaseFrames=intValue(p,"voice.releaseFrames",vadReleaseFrames,1,120);
      noiseFloorAdaptDown=floatValue(p,"voice.noiseAdaptDown",noiseFloorAdaptDown,0.001f,1);
    
      noiseFloorAdaptUp=floatValue(p,"voice.noiseAdaptUp",noiseFloorAdaptUp,0.0001f,0.2f);
    
      autoConfidence=floatValue(p,"beam.autoConfidence",autoConfidence,0,1);
      autoMaxSpreadDeg=floatValue(p,"beam.autoMaxSpreadDeg",autoMaxSpreadDeg,2,45);
    
      autoDeadbandDeg=floatValue(p,"beam.autoDeadbandDeg",autoDeadbandDeg,0,30);
      autoMaxSlewDegPerSec=floatValue(p,"beam.autoMaxSlewDegPerSec",autoMaxSlewDegPerSec,5,180);
    
      autoDwellFrames=intValue(p,"beam.autoDwellFrames",autoDwellFrames,2,120);
      autoHoldMs=intValue(p,"beam.autoHoldMs",autoHoldMs,0,5000);
      autoUpdateMinMs=intValue(p,"beam.autoUpdateMinMs",autoUpdateMinMs,10,1000);
    
      beamOutputGain=floatValue(p,"beam.outputGain",beamOutputGain,0.1f,8.0f);
      noiseSuppress=boolValue(p,"noise.enabled",noiseSuppress);
      noiseOverSubtract=floatValue(p,"noise.overSubtract",noiseOverSubtract,0.2f,4.0f);
    
      noiseMinGain=floatValue(p,"noise.minGain",noiseMinGain,0.0f,1.0f);
      noiseAdapt=floatValue(p,"noise.adapt",noiseAdapt,0.0001f,0.5f);
      noiseSpeechAdapt=floatValue(p,"noise.speechAdapt",noiseSpeechAdapt,0.00001f,0.05f);
    
      beamQueueFrames=intValue(p,"beam.queueFrames",beamQueueFrames,2,64);
      beamLineBufferBytes=intValue(p,"beam.lineBufferBytes",beamLineBufferBytes,512,131072);
    
      locateXMinM=floatValue(p,"locate.xMinM",locateXMinM,-10,0);
      locateXMaxM=floatValue(p,"locate.xMaxM",locateXMaxM,0,10);
      locateZMinM=floatValue(p,"locate.zMinM",locateZMinM,0.1f,10);
      locateZMaxM=floatValue(p,"locate.zMaxM",locateZMaxM,locateZMinM,15);
      locateXSteps=intValue(p,"locate.xSteps",locateXSteps,11,121);
      locateZSteps=intValue(p,"locate.zSteps",locateZSteps,8,100);
      float[] parsed=floatList(p.getProperty("geometry.microphoneXM"),4);
      if(parsed!=null)microphoneXM=parsed;
  }
  float[] floatList(String value,int count){return studio.services.configRules.decimalList(value,count);
    }
  String textValue(Properties p,String k,String f){return studio.services.configRules.text(p,k,f);
    }
  int intValue(Properties p,String k,int f,int lo,int hi){return studio.services.configRules.integer(p,k,f,lo,hi);
    }
  boolean boolValue(Properties p,String k,boolean f){return studio.services.configRules.flag(p,k,f);
    }
  float floatValue(Properties p,String k,float f,float lo,float hi){return studio.services.configRules.decimal(p,k,f,lo,hi);
    }
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticDsp.pde =====
class SpatialAudioScanFrame {
  long frameNumber,tickMs;
  float rms,azimuthDeg,rawAzimuthDeg,confidence,peakScore,stability=0,positionXM=Float.NaN,positionZM=Float.NaN,positionScore=0;
  
  float noiseFloorRms=0,snrDb=0,voiceBandRatio=0,spectralFlatness=1,zeroCrossingRate=0,coherence=0,voiceProbability=0;
  boolean speech=false,autoEligible=false;
  
  float[] directional=new float[181];
  float[] occupancy=new float[181];
}


class SpatialAudioTemporalTracker {
  final SpatialAudioConfig cfg;boolean initialized=false;float azimuth=0,positionX=Float.NaN,positionZ=Float.NaN,stability=0;
  
  SpatialAudioTemporalTracker(SpatialAudioConfig c){cfg=c;}
  void reset(){initialized=false;azimuth=0;positionX=positionZ=Float.NaN;stability=0;
    }
  void update(SpatialAudioScanFrame scan){
    if(scan==null)return;float raw=scan.rawAzimuthDeg,quality=constrain(scan.confidence,0,1);
    boolean positionObserved=Float.isFinite(scan.positionXM)&&Float.isFinite(scan.positionZM);
    
    if(scan.rms<cfg.minimumRms){stability*=.92f;if(initialized)scan.azimuthDeg=azimuth;
      scan.stability=constrain(stability,0,1);return;}
    if(!initialized){azimuth=raw;if(positionObserved){positionX=scan.positionXM;positionZ=scan.positionZM;
        }stability=quality;initialized=true;}
    else{
      float delta=raw-azimuth;float allowed=cfg.trackingMaxJumpDeg*lerp(.55f,1.0f,quality);
      delta=constrain(delta,-allowed,allowed);
      float a=lerp(cfg.trackingSlowAlpha,cfg.trackingFastAlpha,smooth01(0.04f,0.34f,quality));
      azimuth+=delta*a;
      float agreement=1.0f-constrain(abs(raw-azimuth)/max(1.0f,cfg.trackingMaxJumpDeg),0,1);
      stability=lerp(stability,agreement*lerp(.45f,1.0f,quality),.18f);
      if(positionObserved){if(!Float.isFinite(positionX)||!Float.isFinite(positionZ)){positionX=scan.positionXM;
          positionZ=scan.positionZM;}else{float pa=cfg.trackingPositionAlpha*lerp(.55f,1.0f,quality);
          positionX=lerp(positionX,scan.positionXM,pa);positionZ=lerp(positionZ,scan.positionZM,pa);
          }}
    }
    scan.azimuthDeg=constrain(azimuth,-90,90);scan.stability=constrain(stability,0,1);
    if(positionObserved&&Float.isFinite(positionX)&&Float.isFinite(positionZ)){scan.positionXM=positionX;
      scan.positionZM=positionZ;}
  }
  float smooth01(float lo,float hi,float v){if(hi<=lo)return v>=hi?1:0;float t=constrain((v-lo)/(hi-lo),0,1);
    return t*t*(3-2*t);}
}

class SpatialAutoSteerer {
  final SpatialAudioConfig cfg;final float[] angleHistory=new float[96],weightHistory=new float[96];
  int historyCount=0,historyHead=0;
  long lastVoiceMs=0,lastUpdateMs=0;float lockedAngle=0;boolean locked=false;
  SpatialAutoSteerer(SpatialAudioConfig c){cfg=c;}
  void reset(){historyCount=historyHead=0;lastVoiceMs=lastUpdateMs=0;locked=false;
    lockedAngle=0;}
  float update(SpatialAudioScanFrame scan,float current,long now){
    if(scan==null)return current;long clock=scan.tickMs>0?scan.tickMs:(scan.frameNumber>0?scan.frameNumber*16L:now);
    
    if(scan.autoEligible){lastVoiceMs=clock;push(scan.azimuthDeg,max(0.005f,scan.voiceProbability*max(.02f,scan.confidence)));
      }
    else{if(lastVoiceMs>0&&clock-lastVoiceMs>cfg.autoHoldMs){historyCount=0;locked=false;
        }return current;}
    RobustCluster cluster=bestCluster();
    if(cluster==null||cluster.count<cfg.autoDwellFrames||cluster.inlierFraction<.62f||cluster.spread>cfg.autoMaxSpreadDeg)return current;
    
    lockedAngle=cluster.mean;locked=true;
    long elapsed=lastUpdateMs==0?cfg.autoUpdateMinMs:clock-lastUpdateMs;if(elapsed<cfg.autoUpdateMinMs)return current;
    
    lastUpdateMs=clock;
    float delta=lockedAngle-current;if(abs(delta)<=cfg.autoDeadbandDeg)return current;
    
    float maxStep=cfg.autoMaxSlewDegPerSec*constrain(elapsed/1000.0f,.010f,.25f);
    
    return constrain(current+constrain(delta,-maxStep,maxStep),-90,90);
  }
  void push(float angle,float weight){int cap=min(angleHistory.length,max(cfg.autoDwellFrames*4,32));
    angleHistory[historyHead]=angle;weightHistory[historyHead]=weight;historyHead=(historyHead+1)%cap;
    if(historyCount<cap)historyCount++;}
  RobustCluster bestCluster(){if(historyCount==0)return null;int cap=min(angleHistory.length,max(cfg.autoDwellFrames*4,32));
    float radius=max(cfg.autoMaxSpreadDeg*1.8f,10.0f),total=0;for(int i=0;i<historyCount;i++){int q=(historyHead-1-i+cap)%cap;
      total+=max(.001f,weightHistory[q]);}
    RobustCluster best=null;for(int c=0;c<historyCount;c++){int cq=(historyHead-1-c+cap)%cap;
      float center=angleHistory[cq],sw=0,sx=0;int count=0;for(int i=0;i<historyCount;i++){int q=(historyHead-1-i+cap)%cap,dummy=0;
        float d=abs(angleHistory[q]-center);if(d>radius)continue;float w=max(.001f,weightHistory[q]);
        sw+=w;sx+=angleHistory[q]*w;count++;}if(count<cfg.autoDwellFrames||sw<=0)continue;
      float mean=sx/sw,var=0;for(int i=0;i<historyCount;i++){int q=(historyHead-1-i+cap)%cap;
        float d=angleHistory[q]-mean;if(abs(d)>radius)continue;float w=max(.001f,weightHistory[q]);
        var+=d*d*w;}float spread=sqrt(var/sw),fraction=sw/max(.001f,total);if(best==null||sw>best.weight)best=new RobustCluster(mean,spread,fraction,sw,
        count);}
    return best;
  }
  class RobustCluster {final float mean,spread,inlierFraction,weight;final int count;
    RobustCluster(float m,float s,float f,float w,int c){mean=m;spread=s;inlierFraction=f;
      weight=w;count=c;}}
}

class VoiceNoiseSuppressor {
  final SpatialAudioConfig cfg;final int N=512,H=256;
  final float[] prev=new float[H],re=new float[N],im=new float[N],noise=new float[N/2+1],gain=new float[N/2+1],cleanPower=new float[N/2+1],ola=new float[N];
  boolean initialized=false;
  VoiceNoiseSuppressor(SpatialAudioConfig c){cfg=c;Arrays.fill(gain,1.0f);}
  void reset(){Arrays.fill(prev,0);Arrays.fill(noise,0);Arrays.fill(gain,1);Arrays.fill(cleanPower,0);Arrays.fill(ola,0);
    initialized=false;}
  short[] process(short[] input,SpatialAudioScanFrame scan,SpatialAudioEngine fftOwner){if(!cfg.noiseSuppress||input==null||input.length!=H)return input;
    boolean firstBlock=!initialized;
    for(int i=0;i<N;i++){float x=i<H?prev[i]:input[i-H]/32768.0f;float w=sqrt(max(0,0.5f-0.5f*(float)Math.cos(2*Math.PI*i/(N-1))));
      re[i]=x*w;im[i]=0;}for(int i=0;i<H;i++)prev[i]=input[i]/32768.0f;fftOwner.fft(re,im,false);
    
    for(int k=0;k<=N/2;k++){
      float p=re[k]*re[k]+im[k]*im[k]+1e-12f;
      if(!initialized){noise[k]=p;cleanPower[k]=p;}

      float n=max(1e-12f,noise[k]);
      if(initialized){
        float riseAdapt=(scan!=null&&scan.speech)?cfg.noiseSpeechAdapt:cfg.noiseAdapt;
        float spectralAdapt=p<n?min(.18f,max(riseAdapt*3.0f,.02f)):riseAdapt;
        noise[k]=noise[k]*(1-spectralAdapt)+p*spectralAdapt;
        n=max(1e-12f,noise[k]);
      }
      float posterior=p/n;
      float instantaneous=max(0,posterior-cfg.noiseOverSubtract);
      float prior=.92f*(cleanPower[k]/n)+.08f*instantaneous;
      float wiener=prior/(1.0f+prior);
      float hz=k*16000.0f/N;
      boolean speechBand=hz>=cfg.voiceLowHz&&hz<=cfg.voiceHighHz;
      float preserve=(scan!=null&&scan.speech&&speechBand)?max(cfg.noiseMinGain,.20f):cfg.noiseMinGain;
      float target=constrain(wiener,preserve,1);
      gain[k]=.78f*gain[k]+.22f*target;
      cleanPower[k]=gain[k]*gain[k]*p;
      re[k]*=gain[k];im[k]*=gain[k];
      if(k>0&&k<N/2){int mirror=N-k;re[mirror]*=gain[k];im[mirror]*=gain[k];}
    }
    initialized=true;
    if(firstBlock){Arrays.fill(ola,0);return input;}
    fftOwner.fft(re,im,true);short[] out=new short[H];
    for(int i=0;i<N;i++){float w=sqrt(max(0,0.5f-0.5f*(float)Math.cos(2*Math.PI*i/(N-1))));ola[i]+=re[i]*w;}
    float gate=(scan!=null&&scan.voiceProbability<.20f&&scan.snrDb<cfg.vadSnrOffDb)?.34f:1.0f;
    for(int i=0;i<H;i++){float v=constrain(ola[i]*gate,-1,1);out[i]=(short)Math.round(v*32767);
      ola[i]=ola[i+H];ola[i+H]=0;}return out;}
}

class SpatialAudioEngine {
  final int FFT=512,BINS=181;
 final SpatialAudioConfig cfg;
 final int[][] pairs={{0,1},{0,2},{0,3},{1,2},{1,3},{2,3}};
 final float[][] spectrumRe=new float[4][FFT],spectrumIm=new float[4][FFT];
 final float[][] pairCorr=new float[6][FFT];
 final float[] pairWeight=new float[6];
 final float[] corrRe=new float[FFT],corrIm=new float[FFT];
 final float[] occupancy=new float[BINS];
 final VoiceNoiseSuppressor suppressor;final SpatialAudioTemporalTracker tracker;
  float noiseFloorRms=0.0015f;SpatialAudioScanFrame lastScan=null;
 int voiceAttackCount=0,voiceReleaseCount=0;boolean voiceLatched=false;

  SpatialAudioEngine(SpatialAudioConfig cfg){this.cfg=cfg;suppressor=new VoiceNoiseSuppressor(cfg);
    tracker=new SpatialAudioTemporalTracker(cfg);Arrays.fill(pairWeight,1.0f);}
  void reset(){Arrays.fill(occupancy,0);Arrays.fill(pairWeight,1.0f);noiseFloorRms=0.0015f;
    lastScan=null;suppressor.reset();tracker.reset();}

  SpatialAudioScanFrame process(SpatialAudioFrame frame){
    SpatialAudioScanFrame out=new SpatialAudioScanFrame();out.frameNumber=frame.frameNumber;
    out.tickMs=frame.tickMs;float rmsAccum=0;int validChannels=0;
    for(int ch=0;ch<SpatialAudioFrame.CHANNELS;ch++){
      if(frame.valid(ch)){rmsAccum+=prepare(frame.samples[ch],spectrumRe[ch],spectrumIm[ch]);validChannels++;}
      else{Arrays.fill(spectrumRe[ch],0);Arrays.fill(spectrumIm[ch],0);}
    }
    out.rms=validChannels>0?sqrt(rmsAccum/(validChannels*(float)SpatialAudioFrame.SAMPLES)):0;
    buildCorrelations(frame);
    float minScore=Float.MAX_VALUE,maxScore=-Float.MAX_VALUE;int peak=0;
    for(int bin=0;bin<BINS;bin++){
      float deg=-90+bin,s=(float)Math.sin(Math.toRadians(deg)),score=0,weightSum=0;
      
      for(int p=0;p<pairs.length;p++){
        int a=pairs[p][0],b=pairs[p][1];float dx=cfg.microphoneXM[b]-cfg.microphoneXM[a];
        float lag=dx*s*16000/cfg.soundSpeedMps,w=pairWeight[p];
        score+=corrAt(pairCorr[p],lag)*w;weightSum+=w;
      }
      if(weightSum>0)score/=weightSum;
      out.directional[bin]=score;if(score<minScore)minScore=score;if(score>maxScore){maxScore=score;
        peak=bin;}
    }
    float span=maxScore-minScore,second=0;
    for(int bin=0;bin<BINS;bin++){
      float normalized=span>1e-9f?(out.directional[bin]-minScore)/span:0;out.directional[bin]=normalized;
      
      if(bin+3<peak||bin>peak+3)second=max(second,normalized);
      float injection=out.rms>=cfg.minimumRms?normalized*constrain(out.rms*8.0f,0,1):0;
      
      occupancy[bin]=cfg.occupancyDecay*occupancy[bin]+(1-cfg.occupancyDecay)*injection;
      out.occupancy[bin]=occupancy[bin];
    }
    float refined=-90+peak;if(peak>0&&peak+1<BINS){float y0=out.directional[peak-1],y1=out.directional[peak],y2=out.directional[peak+1],d=y0-2*y1+y2;
      if(abs(d)>1e-6f)refined+=constrain(0.5f*(y0-y2)/d,-0.5f,0.5f);}
    out.rawAzimuthDeg=refined;out.azimuthDeg=refined;out.peakScore=out.directional[peak];
    out.confidence=constrain(out.peakScore-second,0,1);
    evaluateVoice(frame,out);locateNearField(out);tracker.update(out);
    // Range from a linear four-microphone array is only an approximate display aid.
    // AUTO steering is therefore gated by speech evidence + angular confidence, not by the coarse x/z estimate.
    out.autoEligible=out.speech&&out.confidence>=cfg.autoConfidence*.25f&&out.stability>=cfg.trackingMinStability;
    lastScan=out;
    return out;
  }

  void evaluateVoice(SpatialAudioFrame frame,SpatialAudioScanFrame out){
    double total=0,voice=0,logVoice=0;
    int voiceBins=0,nyquist=FFT/2;
    for(int k=1;k<nyquist;k++){
      float hz=k*16000.0f/FFT;
      double p=0;
      for(int ch=0;ch<4;ch++)p+=spectrumRe[ch][k]*spectrumRe[ch][k]+spectrumIm[ch][k]*spectrumIm[ch][k];
      p=max(1e-18f,(float)p);
      total+=p;
      if(hz>=cfg.voiceLowHz&&hz<=cfg.voiceHighHz){
        voice+=p;
        logVoice+=Math.log(p);
        voiceBins++;
      }
    }
    out.voiceBandRatio=(float)(voice/Math.max(1e-12,total));
    if(voiceBins>0&&voice>0){
      double geometric=Math.exp(logVoice/voiceBins);
      double arithmetic=voice/voiceBins;
      out.spectralFlatness=constrain((float)(geometric/Math.max(1e-18,arithmetic)),0,1);
    }

    int crossings=0,validSamples=0;
    float previous=0;
    boolean havePrevious=false;
    for(int n=0;n<SpatialAudioFrame.SAMPLES;n++){
      double sum=0;int channels=0;
      for(int ch=0;ch<SpatialAudioFrame.CHANNELS;ch++){if(frame.valid(ch)){sum+=frame.samples[ch][n]/2147483648.0;channels++;}}
      if(channels==0)continue;
      float mono=(float)(sum/channels);
      if(havePrevious&&((mono>=0)!=(previous>=0)))crossings++;
      previous=mono;havePrevious=true;validSamples++;
    }
    out.zeroCrossingRate=validSamples>1?crossings/(float)(validSamples-1):0;

    float coherenceSum=0;int coherencePairs=0;
    for(int p=0;p<pairWeight.length;p++){
      if(pairWeight[p]<=0)continue;
      float normalized=(pairWeight[p]-cfg.pairWeightFloor)/max(1e-6f,1.0f-cfg.pairWeightFloor);
      coherenceSum+=constrain(normalized,0,1);coherencePairs++;
    }
    out.coherence=coherencePairs==0?0:coherenceSum/coherencePairs;

    float rawNoise=max(1e-6f,noiseFloorRms);
    float snr=20.0f*(float)Math.log10(max(1e-6f,out.rms)/rawNoise);
    out.snrDb=snr;out.noiseFloorRms=noiseFloorRms;

    float snrScore=smooth01(cfg.vadSnrOffDb,cfg.vadSnrOnDb+5,snr);
    float bandScore=smooth01(cfg.voiceBandMinRatio-.12f,cfg.voiceBandMinRatio+.18f,out.voiceBandRatio);
    float energyScore=smooth01(cfg.minimumRms,cfg.minimumRms*3.5f,out.rms);
    float doaScore=smooth01(cfg.autoConfidence*.45f,max(cfg.autoConfidence+.10f,.24f),out.confidence);
    float coherenceScore=smooth01(cfg.voiceCoherenceMin,min(.95f,cfg.voiceCoherenceMin+.42f),out.coherence);
    float flatnessScore=1.0f-smooth01(cfg.voiceFlatnessMax,min(.995f,cfg.voiceFlatnessMax+.20f),out.spectralFlatness);
    float zcrLow=smooth01(cfg.voiceZcrMin*.45f,cfg.voiceZcrMin*1.35f,out.zeroCrossingRate);
    float zcrHigh=1.0f-smooth01(cfg.voiceZcrMax*.82f,cfg.voiceZcrMax*1.20f,out.zeroCrossingRate);
    float zcrScore=constrain(min(zcrLow,zcrHigh),0,1);

    out.voiceProbability=constrain(.27f*snrScore+.24f*bandScore+.13f*energyScore+.10f*doaScore+
      .13f*coherenceScore+.08f*flatnessScore+.05f*zcrScore,0,1);

    boolean speechShape=out.voiceBandRatio>=cfg.voiceBandMinRatio&&
      out.spectralFlatness<=min(.98f,cfg.voiceFlatnessMax+.14f)&&
      out.zeroCrossingRate>=cfg.voiceZcrMin*.55f&&out.zeroCrossingRate<=cfg.voiceZcrMax*1.12f;
    boolean strongVoice=out.rms>=cfg.minimumRms&&out.snrDb>=cfg.vadSnrOnDb&&speechShape&&
      out.coherence>=cfg.voiceCoherenceMin*.72f&&out.voiceProbability>=cfg.vadProbability;
    boolean sustainVoice=out.rms>=cfg.minimumRms*.80f&&out.snrDb>=cfg.vadSnrOffDb&&
      out.voiceBandRatio>=cfg.voiceBandMinRatio*.84f&&out.voiceProbability>=cfg.vadProbability*.75f;

    if(!voiceLatched){
      if(strongVoice){
        voiceAttackCount++;
        if(voiceAttackCount>=cfg.vadAttackFrames){voiceLatched=true;voiceReleaseCount=0;}
      }else voiceAttackCount=0;
    }else{
      if(sustainVoice)voiceReleaseCount=0;
      else if(++voiceReleaseCount>=cfg.vadReleaseFrames){voiceLatched=false;voiceAttackCount=0;voiceReleaseCount=0;}
    }
    out.speech=voiceLatched;
    float a=out.rms<noiseFloorRms?cfg.noiseFloorAdaptDown:(out.speech?cfg.noiseSpeechAdapt:cfg.noiseFloorAdaptUp);
    noiseFloorRms=constrain(lerp(noiseFloorRms,max(1e-6f,out.rms),a),1e-6f,.10f);
    out.noiseFloorRms=noiseFloorRms;
  }
  float smooth01(float lo,float hi,float v){if(hi<=lo)return v>=hi?1:0;float t=constrain((v-lo)/(hi-lo),0,1);
    return t*t*(3-2*t);}

  void locateNearField(SpatialAudioScanFrame out){
    if(out.rms<cfg.minimumRms)return;
    float best=-Float.MAX_VALUE,bestX=Float.NaN,bestZ=Float.NaN;
    int xs=max(2,cfg.locateXSteps),zs=max(2,cfg.locateZSteps);
    for(int iz=0;iz<zs;iz++){
      float z=lerp(cfg.locateZMinM,cfg.locateZMaxM,iz/(float)(zs-1));
      for(int ix=0;ix<xs;ix++){
        float x=lerp(cfg.locateXMinM,cfg.locateXMaxM,ix/(float)(xs-1));
        float score=0;
        for(int p=0;p<pairs.length;p++){
          int a=pairs[p][0],b=pairs[p][1];
          float da=sqrt((x-cfg.microphoneXM[a])*(x-cfg.microphoneXM[a])+z*z);
          float db=sqrt((x-cfg.microphoneXM[b])*(x-cfg.microphoneXM[b])+z*z);
          // GCC-PHAT lag convention used by the far-field scan above.
          float lag=-(db-da)*16000/cfg.soundSpeedMps;
          score+=corrAt(pairCorr[p],lag)*pairWeight[p];
        }
        if(score>best){best=score;bestX=x;bestZ=z;}
      }
    }
    if(Float.isFinite(bestX)&&Float.isFinite(bestZ)){out.positionXM=bestX;out.positionZM=bestZ;
      out.positionScore=best;}
  }

  short[] beamform(SpatialAudioFrame frame,float azimuthDeg){return beamform(frame,azimuthDeg,lastScan);}
  short[] beamform(SpatialAudioFrame frame,float azimuthDeg,SpatialAudioScanFrame scan){
    int n=SpatialAudioFrame.SAMPLES;short[] out=new short[n];
    float center=0;for(float x:cfg.microphoneXM)center+=x;center/=cfg.microphoneXM.length;
    
    float steer=(float)Math.sin(Math.toRadians(constrain(azimuthDeg,-90,90)));
    for(int i=0;i<n;i++){
      double sum=0;int valid=0;
      for(int ch=0;ch<4;ch++){
        if(!frame.valid(ch))continue;
        float shift=(cfg.microphoneXM[ch]-center)*steer*16000/cfg.soundSpeedMps;
        sum+=sampleLinear(frame.samples[ch],i-shift)/2147483648.0;valid++;
      }
      double v=valid==0?0:(sum/valid)*cfg.beamOutputGain;
      v=Math.max(-1.0,Math.min(1.0,v));out[i]=(short)Math.round(v*32767.0);
    }
    return suppressor.process(out,scan,this);
  }
  float sampleLinear(int[] data,float index){
    int i0=(int)Math.floor(index);float f=index-i0;if(i0<0||i0>=data.length)return 0;
    int i1=i0+1;
    float a=data[i0],b=i1<data.length?data[i1]:a;return a+(b-a)*f;
  }

  float prepare(int[] samples,float[] re,float[] im){
    Arrays.fill(re,0);Arrays.fill(im,0);double mean=0;for(int v:samples)mean+=v;mean/=samples.length;
    float e=0;
    for(int i=0;i<samples.length;i++){float x=(float)(((double)samples[i]-mean)/2147483648.0);
      float w=0.5f-0.5f*(float)Math.cos(2*Math.PI*i/(samples.length-1));float v=x*w;
      re[i]=v;e+=v*v;}
    fft(re,im,false);return e;
  }
  void buildCorrelations(SpatialAudioFrame frame){
    for(int p=0;p<pairs.length;p++){int a=pairs[p][0],b=pairs[p][1];
      if(!frame.valid(a)||!frame.valid(b)){
        Arrays.fill(pairCorr[p],0);pairWeight[p]=0;continue;
      }
      for(int k=0;k<FFT;k++){float hz=(k<=FFT/2?k:FFT-k)*16000.0f/FFT;if(hz<cfg.localizationLowHz||hz>cfg.localizationHighHz){corrRe[k]=corrIm[k]=0;
          continue;}float ar=spectrumRe[a][k],ai=spectrumIm[a][k],br=spectrumRe[b][k],bi=spectrumIm[b][k],cr=ar*br+ai*bi,ci=ai*br-ar*bi,mag=sqrt(cr*cr+ci*ci)+1e-12f;
        corrRe[k]=cr/mag;corrIm[k]=ci/mag;}
      fft(corrRe,corrIm,true);arrayCopy(corrRe,pairCorr[p]);pairWeight[p]=pairReliability(pairCorr[p],a,b);
    }
  }
  float pairReliability(float[] corr,int a,int b){
    float spacing=abs(cfg.microphoneXM[b]-cfg.microphoneXM[a]),maxLag=spacing*16000.0f/cfg.soundSpeedMps+2.0f;
    int radius=max(2,ceil(maxLag)),peakLag=0;float peak=0;
    for(int lag=-radius;lag<=radius;lag++){float v=abs(corrAt(corr,lag));if(v>peak){peak=v;
        peakLag=lag;}}
    float second=0;for(int lag=-radius;lag<=radius;lag++){if(abs(lag-peakLag)<=1)continue;
      second=max(second,abs(corrAt(corr,lag)));}
    float sharpness=peak<=1e-8f?0:constrain((peak-second)/peak,0,1);return constrain(cfg.pairWeightFloor+(1.0f-cfg.pairWeightFloor)*sharpness*cfg.pairSharpnessGain,
      cfg.pairWeightFloor,1.0f);
  }
  float corrAt(float[] corr,float lag){float w=lag;while(w<0)w+=FFT;while(w>=FFT)w-=FFT;
    int i0=(int)Math.floor(w),i1=(i0+1)%FFT;float f=w-i0;return corr[i0]*(1-f)+corr[i1]*f;
    }
  void fft(float[] re,float[] im,boolean inverse){
    int n=re.length,j=0;for(int i=1;i<n;i++){int bit=n>>1;for(;((j&bit)!=0);bit>>=1)j^=bit;
      j^=bit;if(i<j){float t=re[i];re[i]=re[j];re[j]=t;t=im[i];im[i]=im[j];im[j]=t;
        }}
    for(int len=2;len<=n;len<<=1){double ang=(inverse?2:-2)*Math.PI/len;float wr0=(float)Math.cos(ang),wi0=(float)Math.sin(ang);
      for(int i=0;i<n;i+=len){float wr=1,wi=0;for(int k=0;k<len/2;k++){int q=i+k+len/2;
          float vr=re[q]*wr-im[q]*wi,vi=re[q]*wi+im[q]*wr,ur=re[i+k],ui=im[i+k];re[i+k]=ur+vr;
          im[i+k]=ui+vi;re[q]=ur-vr;im[q]=ui-vi;float nr=wr*wr0-wi*wi0;wi=wr*wi0+wi*wr0;
          wr=nr;}}}
    if(inverse)for(int i=0;i<n;i++){re[i]/=n;im[i]/=n;}
  }
}



// ===== Shared per-Kinect spatial-audio transport =====
class SpatialAudioProtocol {
  final int MAGIC=0x414D4D52;
  final int FRAME_MAGIC=0x464D4D52;
  final int VERSION=1;
  final int CMD_SUBSCRIBE=1;
  final int SAMPLE_RATE=16000;
  final int CHANNELS=4;
  final int SAMPLES=256;
  final int SAMPLE_FORMAT_S32LE=1;
  final int BYTES_PER_SAMPLE=4;
  final int PAYLOAD_BYTES=CHANNELS*SAMPLES*BYTES_PER_SAMPLE;
  final int REQUEST_BYTES=16;
  final int REPLY_BYTES=32;
  final int HEADER_BYTES=48;
  final int REQUIRED_CAPABILITIES=0x3;
  final int VALID_CHANNEL_MASK=(1<<CHANNELS)-1;
}

interface SpatialAudioSessionListener {
  void onSpatialAudioFrame(SpatialAudioFrame frame,SpatialAudioScanFrame scan);
}

class SpatialAudioSessionRegistry {
  final HashMap<String,SpatialAudioDeviceSession> sessions=new HashMap<String,SpatialAudioDeviceSession>();
  SpatialAudioConfig sharedConfig;

  synchronized SpatialAudioConfig config(){
    if(sharedConfig==null){
      sharedConfig=new SpatialAudioConfig();
      sharedConfig.load(studio.services.paths.resource("spatial-audio","config.properties"),"spatial-audio");
    }
    return sharedConfig;
  }

  synchronized SpatialAudioDeviceSession attach(String deviceId,SpatialAudioSessionListener listener){
    if(deviceId==null||deviceId.trim().isEmpty()||listener==null)return null;
    String key=deviceId.trim();
    SpatialAudioDeviceSession session=sessions.get(key);
    if(session==null){
      session=new SpatialAudioDeviceSession(key,config());
      sessions.put(key,session);
    }
    session.addListener(listener);
    return session;
  }

  void detach(String deviceId,SpatialAudioSessionListener listener){
    if(deviceId==null||listener==null)return;
    SpatialAudioDeviceSession toStop=null;
    synchronized(this){
      String key=deviceId.trim();
      SpatialAudioDeviceSession session=sessions.get(key);
      if(session!=null&&session.removeListener(listener)){
        sessions.remove(key);
        toStop=session;
      }
    }
    // Do not leave an old transport worker alive after the last consumer
    // detaches. A later attach for the same device-id must never overlap a
    // previous capture session.
    if(toStop!=null)toStop.stop();
  }

  synchronized SpatialAudioDeviceSession session(String deviceId){
    return deviceId==null?null:sessions.get(deviceId);
  }

  void stopAll(){
    ArrayList<SpatialAudioDeviceSession> stale;
    synchronized(this){
      stale=new ArrayList<SpatialAudioDeviceSession>(sessions.values());
      sessions.clear();
    }
    for(SpatialAudioDeviceSession session:stale)if(session!=null)session.stop();
  }
}

class SpatialAudioDeviceSession {
  final String deviceId;
  final SpatialAudioConfig cfg;
  final SpatialAudioEngine analysis;
  final Object listenerLock=new Object();
  final Object pipeLock=new Object();
  final ArrayList<SpatialAudioSessionListener> listeners=new ArrayList<SpatialAudioSessionListener>();

  volatile boolean running=false,connected=false,immediateReconnect=false;
  volatile long runGeneration=0,frameCount=0,payloadBytesReceived=0;
  volatile long connectedSinceMs=0,lastFrameArrivalMs=0,connectionEpoch=0,reconnectKicks=0,lastReconnectKickMs=0;
  volatile String stateKey="source.starting",detail="",connectedPipe="";
  volatile LocalTransport activePipe;
  volatile SpatialAudioFrame latest;
  volatile SpatialAudioScanFrame latestScan;
  Thread worker;

  SpatialAudioDeviceSession(String deviceId,SpatialAudioConfig cfg){
    this.deviceId=deviceId;
    this.cfg=cfg;
    this.analysis=new SpatialAudioEngine(cfg);
  }

  void addListener(SpatialAudioSessionListener listener){
    synchronized(listenerLock){
      if(!listeners.contains(listener))listeners.add(listener);
    }
    start();
  }

  boolean removeListener(SpatialAudioSessionListener listener){
    synchronized(listenerLock){
      listeners.remove(listener);
      return listeners.isEmpty();
    }
  }

  synchronized void start(){
    if(running)return;
    running=true;
    final long generation=++runGeneration;
    worker=studio.services.workers.start("SpatialAudio-"+deviceId,new Runnable(){public void run(){loop(generation);}});
  }

  void requestStop(){
    Thread t;
    synchronized(this){
      if(!running)return;
      running=false;
      ++runGeneration;
      closeActivePipe();
      t=worker;
      worker=null;
    }
    if(t!=null&&t!=Thread.currentThread())t.interrupt();
    connected=false;
  }

  void stop(){
    Thread t;
    synchronized(this){
      running=false;
      ++runGeneration;
      closeActivePipe();
      t=worker;
      worker=null;
    }
    if(t!=null&&t!=Thread.currentThread()){
      t.interrupt();
      try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}
    }
    connected=false;
  }

  String displayStateKey(){
    if(!connected)return stateKey;
    long now=System.currentTimeMillis();
    if(lastFrameArrivalMs>0&&now-lastFrameArrivalMs>cfg.connectionStaleMs){
      requestReconnect("stale-session",false);
      return "source.reconnecting";
    }
    long anchor=lastFrameArrivalMs>0?lastFrameArrivalMs:connectedSinceMs;
    if(anchor>0&&now-anchor>cfg.noFrameWarningMs)return lastFrameArrivalMs>0?"source.stale":"source.reconnecting";
    return stateKey;
  }

  void resetAnalysis(){analysis.reset();latestScan=null;}

  void requestReconnect(String reason,boolean force){
    if(!running)return;
    long now=System.currentTimeMillis();
    if(!force&&now-lastReconnectKickMs<Math.max(100,cfg.reconnectMs))return;
    lastReconnectKickMs=now;
    reconnectKicks++;
    stateKey="source.reconnecting";
    detail=reason==null?"":reason;
    if(force){latest=null;latestScan=null;analysis.reset();immediateReconnect=true;}
    final LocalTransport reconnectPipe=detachActivePipe();
    studio.services.workers.start("SpatialAudio-Reconnect-"+deviceId,new Runnable(){public void run(){closePipe(reconnectPipe);}});
  }

  void loop(long generation){
    while(running&&generation==runGeneration){
      LocalTransport pipe=null;
      try{
        connected=false;
        stateKey="source.connecting";
        detail="";
        lastFrameArrivalMs=0;
        pipe=openPipeWithRetry();
        setActivePipe(pipe);
        subscribe(pipe);
        connected=true;
        connectedSinceMs=System.currentTimeMillis();
        connectionEpoch++;
        stateKey="source.streaming";
        long lastFrame=-1;
        SpatialAudioProtocol protocol=studio.services.spatialAudioProtocol;
        byte[] headerBytes=new byte[protocol.HEADER_BYTES];
        byte[] payload=new byte[protocol.PAYLOAD_BYTES];

        while(running&&generation==runGeneration){
          pipe.readFully(headerBytes);
          ByteBuffer h=ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);
          int magic=h.getInt(),version=h.getInt(),rate=h.getInt(),channels=h.getInt();
          int format=h.getInt(),samples=h.getInt(),payloadBytes=h.getInt(),channelMask=h.getInt();
          long frameNumber=h.getLong(),tickMs=h.getLong();
          validateFrameHeader(magic,version,rate,channels,format,samples,payloadBytes,channelMask,frameNumber,lastFrame);
          lastFrame=frameNumber;
          pipe.readFully(payload);
          payloadBytesReceived+=payload.length;
          SpatialAudioFrame frame=decodeFrame(payload,frameNumber,tickMs,channelMask);
          SpatialAudioScanFrame scan=analysis.process(frame);
          latest=frame;
          latestScan=scan;
          frameCount++;
          lastFrameArrivalMs=System.currentTimeMillis();
          dispatch(frame,scan);
        }
      }catch(IOException e){
        if(generation==runGeneration){
          connected=false;
          if(running){stateKey="source.reconnecting";detail=safeMessage(e);}
        }
      }finally{
        clearActivePipe(pipe);
        closePipe(pipe);
      }
      if(running&&generation==runGeneration){
        if(immediateReconnect){immediateReconnect=false;continue;}
        try{Thread.sleep(cfg.reconnectMs);}
        catch(InterruptedException e){
          if(!running||generation!=runGeneration)return;
          Thread.currentThread().interrupt();
          return;
        }
      }
    }
  }

  void dispatch(SpatialAudioFrame frame,SpatialAudioScanFrame scan){
    ArrayList<SpatialAudioSessionListener> copy;
    synchronized(listenerLock){copy=new ArrayList<SpatialAudioSessionListener>(listeners);}
    for(SpatialAudioSessionListener listener:copy){
      try{listener.onSpatialAudioFrame(frame,scan);}
      catch(RuntimeException e){detail="consumer: "+safeMessage(e);}
    }
  }

  LocalTransport openPipeWithRetry()throws IOException{
    IOException last=null;
    TransportEndpoint endpoint=studio.services.endpoints.audioFor(deviceId);
    connectedPipe=endpoint.label;
    for(int attempt=1;attempt<=cfg.pipeOpenAttempts&&running;attempt++){
      try{return studio.services.transportFactory.open(endpoint.windowsPath,endpoint.linuxPath);}
      catch(IOException e){
        last=e;
        if(attempt<cfg.pipeOpenAttempts){
          try{Thread.sleep(cfg.pipeOpenRetryMs);}
          catch(InterruptedException interrupted){
            Thread.currentThread().interrupt();
            throw new IOException("audio-open interrupted",interrupted);
          }
        }
      }
    }
    throw last==null?new IOException("raw audio bus unavailable"):last;
  }

  void subscribe(LocalTransport pipe)throws IOException{
    SpatialAudioProtocol protocol=studio.services.spatialAudioProtocol;
    ByteBuffer request=ByteBuffer.allocate(protocol.REQUEST_BYTES).order(ByteOrder.LITTLE_ENDIAN);
    request.putInt(protocol.MAGIC).putInt(protocol.VERSION).putInt(protocol.CMD_SUBSCRIBE).putInt(0);
    pipe.write(request.array());
    byte[] bytes=new byte[protocol.REPLY_BYTES];
    pipe.readFully(bytes);
    ByteBuffer reply=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
    int magic=reply.getInt(),version=reply.getInt(),result=reply.getInt(),rate=reply.getInt();
    int channels=reply.getInt(),format=reply.getInt(),maxPayload=reply.getInt(),capabilities=reply.getInt();
    if(magic!=protocol.MAGIC||version!=protocol.VERSION||result<0||rate!=protocol.SAMPLE_RATE||
       channels!=protocol.CHANNELS||format!=protocol.SAMPLE_FORMAT_S32LE||maxPayload<protocol.PAYLOAD_BYTES||
       (capabilities&protocol.REQUIRED_CAPABILITIES)!=protocol.REQUIRED_CAPABILITIES){
      throw new IOException("protocol-subscribe");
    }
  }

  void validateFrameHeader(int magic,int version,int rate,int channels,int format,int samples,int payloadBytes,int mask,long frameNumber,long lastFrame)throws IOException{
    SpatialAudioProtocol protocol=studio.services.spatialAudioProtocol;
    if(magic!=protocol.FRAME_MAGIC||version!=protocol.VERSION)throw new IOException("protocol-frame");
    if(rate!=protocol.SAMPLE_RATE||channels!=protocol.CHANNELS||format!=protocol.SAMPLE_FORMAT_S32LE||
       samples!=protocol.SAMPLES||payloadBytes!=protocol.PAYLOAD_BYTES)throw new IOException("protocol-format");
    if(mask==0||(mask&~protocol.VALID_CHANNEL_MASK)!=0)throw new IOException("protocol-channel-mask");
    if(lastFrame>=0&&frameNumber<=lastFrame)throw new IOException("protocol-frame-order");
  }

  SpatialAudioFrame decodeFrame(byte[] payload,long frameNumber,long tickMs,int channelMask){
    SpatialAudioProtocol protocol=studio.services.spatialAudioProtocol;
    SpatialAudioFrame frame=new SpatialAudioFrame();
    frame.frameNumber=frameNumber;
    frame.tickMs=tickMs;
    frame.channelMask=channelMask;
    ByteBuffer pcm=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
    for(int sample=0;sample<protocol.SAMPLES;sample++){
      for(int mic=0;mic<protocol.CHANNELS;mic++)frame.samples[mic][sample]=pcm.getInt();
    }
    for(int mic=0;mic<protocol.CHANNELS;mic++){
      long peak=0;
      for(int sample=0;sample<protocol.SAMPLES;sample++){
        long value=frame.samples[mic][sample];
        long magnitude=value==Integer.MIN_VALUE?2147483648L:Math.abs(value);
        if(magnitude>peak)peak=magnitude;
      }
      frame.peak[mic]=peak/2147483648.0f;
    }
    return frame;
  }

  void setActivePipe(LocalTransport pipe){synchronized(pipeLock){activePipe=pipe;}}
  void clearActivePipe(LocalTransport pipe){synchronized(pipeLock){if(activePipe==pipe)activePipe=null;}}
  LocalTransport detachActivePipe(){synchronized(pipeLock){LocalTransport pipe=activePipe;activePipe=null;return pipe;}}
  void closeActivePipe(){closePipe(detachActivePipe());}
  void closePipe(LocalTransport pipe){
    if(pipe==null)return;
    try{pipe.close();}catch(IOException e){if(running)detail=safeMessage(e);}
  }
  String safeMessage(Exception e){String message=e.getMessage();return message==null||message.isEmpty()?e.getClass().getSimpleName():message;}
}
