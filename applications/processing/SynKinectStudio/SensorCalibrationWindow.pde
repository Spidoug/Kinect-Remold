class SensorCalibrationWindow {
  KinectDevice device;
  final ModuleI18n i18n;final RgbdSession rgbd;final DepthCalibrationStore store;final StudioSwingTheme theme=new StudioSwingTheme();
  final JFrame frame;final CalibrationImagePanel rgbPanel,depthPanel;final JLabel titleLabel,deviceLabel,quality,metrics,instruction;
  final StudioSwingButton calibrate,reset,save,applyReference;final JLabel referenceLabel;final JTextField referenceField;DepthCorrectionProfile metricsProfile=null;
  javax.swing.Timer timer;DepthCalibrationSession session;DepthCorrectionProfile candidate,qualityProfile;long sequence=-1;
  float wallRmsMm=Float.NaN,wallCoverage=0,rgbWhiteRatio=Float.NaN;boolean wallReady=false,qualityUnsaved=false;volatile boolean closed=false;
  String instructionKey="calwindow.guide",metricsKey="calwindow.no_profile";Object[] instructionArgs=new Object[0],metricsArgs=new Object[0];boolean metricsWall=false;

  SensorCalibrationWindow(KinectDevice device){
    this.device=device;this.i18n=new ModuleI18n("scanner",studio.currentLanguage());this.rgbd=studio.services.processingBlocks.openRgbd(i18n,device);this.store=rgbd.calibrationStore;
    frame=new JFrame();titleLabel=new JLabel();deviceLabel=new JLabel();quality=new JLabel();metrics=new JLabel(" ");instruction=new JLabel(" ");
    rgbPanel=new CalibrationImagePanel("",theme);depthPanel=new CalibrationImagePanel("",theme);
    calibrate=new StudioSwingButton("",theme,true);reset=new StudioSwingButton("",theme,false);save=new StudioSwingButton("",theme,false);
    applyReference=new StudioSwingButton("",theme,false);referenceLabel=new JLabel();referenceField=new JTextField(9);
    rgbd.setDepthOnlyRequested(false);rgbd.setHqColorRequested(false);buildUi();applyLocale();updateSavedQuality();
  }
  void showWindow(){SwingUtilities.invokeLater(new Runnable(){public void run(){frame.setVisible(true);frame.toFront();frame.requestFocus();rgbd.start();timer.start();}});}
  void buildUi(){
    studioApplyWindowIcon(frame);frame.setDefaultCloseOperation(WindowConstants.DISPOSE_ON_CLOSE);frame.setSize(1220,790);frame.setMinimumSize(new java.awt.Dimension(980,680));frame.setLocationRelativeTo(null);
    JPanel root=new JPanel(new java.awt.BorderLayout(14,14));root.setBorder(BorderFactory.createEmptyBorder(16,16,16,16));root.setBackground(theme.window);
    JPanel top=new JPanel(new java.awt.BorderLayout(12,0));top.setOpaque(false);
    JPanel heading=new JPanel();heading.setLayout(new BoxLayout(heading,BoxLayout.Y_AXIS));heading.setOpaque(false);
    titleLabel.setForeground(theme.text);titleLabel.setFont(titleLabel.getFont().deriveFont(java.awt.Font.BOLD,24f));deviceLabel.setForeground(theme.muted);deviceLabel.setFont(deviceLabel.getFont().deriveFont(13f));
    heading.add(titleLabel);heading.add(Box.createVerticalStrut(3));heading.add(deviceLabel);quality.setForeground(theme.accent);quality.setFont(quality.getFont().deriveFont(java.awt.Font.BOLD,18f));
    top.add(heading,java.awt.BorderLayout.WEST);top.add(quality,java.awt.BorderLayout.EAST);root.add(top,java.awt.BorderLayout.NORTH);
    JPanel views=new JPanel(new java.awt.GridLayout(1,2,12,0));views.setOpaque(false);views.add(rgbPanel);views.add(depthPanel);root.add(views,java.awt.BorderLayout.CENTER);
    JPanel bottom=new JPanel();bottom.setLayout(new BoxLayout(bottom,BoxLayout.Y_AXIS));bottom.setBackground(theme.panel);bottom.setBorder(BorderFactory.createCompoundBorder(BorderFactory.createLineBorder(theme.border),BorderFactory.createEmptyBorder(12,14,12,14)));
    instruction.setForeground(theme.text);metrics.setForeground(theme.muted);bottom.add(instruction);bottom.add(Box.createVerticalStrut(5));bottom.add(metrics);bottom.add(Box.createVerticalStrut(10));
    JPanel buttons=new JPanel(new java.awt.FlowLayout(java.awt.FlowLayout.LEFT,8,0));buttons.setOpaque(false);buttons.add(calibrate);buttons.add(reset);buttons.add(save);save.setEnabled(false);
    // Optional absolute reference: tape-measured sensor-to-wall distance(s) of captured stations.
    referenceLabel.setForeground(theme.muted);referenceLabel.setFont(referenceLabel.getFont().deriveFont(13f));referenceField.setBackground(theme.button);referenceField.setForeground(theme.text);referenceField.setCaretColor(theme.text);
    referenceField.setFont(referenceField.getFont().deriveFont(13f));referenceField.setBorder(BorderFactory.createCompoundBorder(BorderFactory.createLineBorder(theme.border),BorderFactory.createEmptyBorder(5,8,5,8)));
    buttons.add(Box.createHorizontalStrut(16));buttons.add(referenceLabel);buttons.add(referenceField);buttons.add(applyReference);bottom.add(buttons);root.add(bottom,java.awt.BorderLayout.SOUTH);frame.setContentPane(root);
    calibrate.addActionListener(new java.awt.event.ActionListener(){public void actionPerformed(java.awt.event.ActionEvent e){beginCalibration();}});
    reset.addActionListener(new java.awt.event.ActionListener(){public void actionPerformed(java.awt.event.ActionEvent e){resetCalibration();}});
    save.addActionListener(new java.awt.event.ActionListener(){public void actionPerformed(java.awt.event.ActionEvent e){saveCalibration();}});
    java.awt.event.ActionListener refAction=new java.awt.event.ActionListener(){public void actionPerformed(java.awt.event.ActionEvent e){applyReferenceDistances(false);}};
    applyReference.addActionListener(refAction);referenceField.addActionListener(refAction);
    frame.addWindowListener(new java.awt.event.WindowAdapter(){public void windowClosed(java.awt.event.WindowEvent e){close();}});
    timer=new javax.swing.Timer(66,new java.awt.event.ActionListener(){public void actionPerformed(java.awt.event.ActionEvent e){tick();}});
  }
  void contextChanged(final org.synkinect.studio.api.StudioContextEvent event){if(closed||event==null)return;SwingUtilities.invokeLater(new Runnable(){public void run(){
      if(closed)return;if(event.localeChanged())applyLocale();if(event.selectionChanged()||event.devicesChanged())bindSelectedDevice();
    }});}
  void bindSelectedDevice(){KinectDevice selected=studio.selectedKinect();if(selected!=null&&!selected.hasCapability("depth"))selected=null;
    String before=device==null?"":device.registryKey(),after=selected==null?"":selected.registryKey();if(Objects.equals(before,after))return;
    if(session!=null)session.cancel();session=null;candidate=null;qualityUnsaved=false;save.setEnabled(false);sequence=-1;device=selected;rgbPanel.setImage(null);depthPanel.setImage(null);
    rgbd.clearConsumerPairs();rgbd.requestReconnect("sensor-calibration-device",true);updateSavedQuality();applyLocale();
  }
  void applyLocale(){String locale=studio.currentLanguage();if(!Objects.equals(i18n.language,locale))i18n.setLanguage(locale);
    frame.setTitle("SynKinect Studio — "+i18n.tr("calwindow.title"));titleLabel.setText(i18n.tr("calwindow.title"));
    deviceLabel.setText(device==null?i18n.tr("calwindow.no_device"):i18n.format("calwindow.device",device.label==null||device.label.trim().isEmpty()?device.registryKey():device.label));
    rgbPanel.setTitle(i18n.tr("calwindow.rgb"));depthPanel.setTitle(i18n.tr("calwindow.depth"));calibrate.setText(i18n.tr("calwindow.calibrate"));reset.setText(i18n.tr("calwindow.reset"));save.setText(i18n.tr("calwindow.save"));
    referenceLabel.setText(i18n.tr("calwindow.reference_label"));referenceField.setToolTipText(i18n.tr("calwindow.reference_hint"));referenceLabel.setToolTipText(i18n.tr("calwindow.reference_hint"));applyReference.setText(i18n.tr("calwindow.reference_apply"));
    renderQuality();renderInstruction();renderMetrics();refreshActionState();frame.repaint();
  }
  void tick(){if(closed)return;if(!Objects.equals(i18n.language,studio.currentLanguage()))applyLocale();
    RgbdFramePair pair=rgbd.latestRgbdPairAfter(sequence);if(pair==null||pair.depth==null)return;sequence=pair.sequence;updateDepth(pair.depth);updateRgb(pair);assessWall(pair.depth);
    if(session!=null&&session.active){try{DepthCorrectionProfile done=session.offer(pair.depth);if(done!=null){candidate=done;qualityProfile=done;qualityUnsaved=true;save.setEnabled(true);setInstruction("calwindow.candidate_complete");
        if(referenceField.getText().trim().length()>0)applyReferenceDistances(true);showProfileMetrics(done);renderQuality();refreshActionState();}
      else updateCaptureInstruction();}catch(Exception ex){session.cancel();setInstruction("calwindow.failed",safeExceptionMessage(ex));}}
  }
  void beginCalibration(){if(device==null)return;candidate=null;qualityUnsaved=false;save.setEnabled(false);session=new DepthCalibrationSession(rgbd.config,rgbd.calibration,store,device.id,false);session.start();metricsProfile=null;setInstruction("calwindow.start");refreshActionState();}
  void resetCalibration(){if(device==null)return;if(session!=null)session.cancel();session=null;candidate=null;qualityProfile=null;qualityUnsaved=false;save.setEnabled(false);
    boolean ok=store.delete(device.id);rgbd.calibration.selectDevice(device.id,null);rgbd.registration.clearPreparedFrame();studio.notifyDepthCalibrationChanged();
    renderQuality();setMetrics(ok?"calwindow.reset_ok":"calwindow.reset_fail");setInstruction("calwindow.reset_instruction");refreshActionState();}
  void saveCalibration(){if(candidate==null||device==null)return;try{store.save(candidate);rgbd.calibration.selectDevice(device.id,candidate);rgbd.registration.clearPreparedFrame();qualityProfile=candidate;qualityUnsaved=false;save.setEnabled(false);
      studio.notifyDepthCalibrationChanged();renderQuality();setInstruction("calwindow.saved");showProfileMetrics(candidate);refreshActionState();
    }catch(Exception ex){setInstruction("calwindow.save_fail",safeExceptionMessage(ex));}}
  void updateSavedQuality(){if(device==null){qualityProfile=null;qualityUnsaved=false;metricsWall=false;setMetrics("calwindow.no_device");refreshActionState();return;}
    DepthCorrectionProfile p=store.load(device.id,device.depthWidth>0?device.depthWidth:studio.services.scannerProtocol.WIDTH,device.depthHeight>0?device.depthHeight:studio.services.scannerProtocol.HEIGHT);qualityProfile=p;qualityUnsaved=false;
    if(p==null)setMetrics("calwindow.no_profile");else showProfileMetrics(p);renderQuality();refreshActionState();}
  void refreshActionState(){boolean depth=device!=null&&device.hasCapability("depth");calibrate.setEnabled(depth);reset.setEnabled(depth);save.setEnabled(depth&&candidate!=null);
    boolean grid=qualityProfile!=null&&qualityProfile.modelType==DepthCorrectionProfile.MODEL_DISPARITY_GRID&&(session==null||!session.active);applyReference.setEnabled(depth&&grid);}
  // Parses "1.20" or "1.20; 2.40" (metres) and re-estimates the absolute scale of the
  // candidate or loaded grid profile; the result must be saved to take effect.
  void applyReferenceDistances(boolean quiet){DepthCorrectionProfile p=candidate!=null?candidate:qualityProfile;
    if(p==null||p.modelType!=DepthCorrectionProfile.MODEL_DISPARITY_GRID){if(!quiet)setInstruction("calwindow.reference_needs_profile");return;}
    String text=referenceField.getText().trim();float[] refs=new float[0];
    if(text.length()>0){String[] parts=text.split("[;\\s]+");refs=new float[parts.length];
      try{for(int i=0;i<parts.length;i++){refs[i]=Float.parseFloat(parts[i].replace(',','.'));if(!(refs[i]>0.2f&&refs[i]<10f))throw new NumberFormatException(parts[i]);}}
      catch(NumberFormatException ex){setInstruction("calwindow.reference_invalid");return;}}
    int matched=p.applyReferences(refs,rgbd.config);
    if(matched<0)setInstruction("calwindow.reference_rejected",rgbd.config.calibrationReferenceMaxScaleError*100);
    else if(matched==0&&refs.length>0)setInstruction("calwindow.reference_unmatched",rgbd.config.calibrationReferenceMatchTolerance*100);
    else if(matched>0)setInstruction("calwindow.reference_applied_short",matched);
    else setInstruction("calwindow.reference_cleared");
    if(candidate==null){candidate=p;}qualityProfile=p;qualityUnsaved=true;save.setEnabled(device!=null);showProfileMetrics(p);renderQuality();}
  float qualityRmsBefore(DepthCorrectionProfile p){return p!=null&&Float.isFinite(p.validationRmsBeforeMm)?p.validationRmsBeforeMm:(p==null?Float.NaN:p.trainingRmsBeforeMm);}
  float qualityRmsAfter(DepthCorrectionProfile p){return p!=null&&Float.isFinite(p.validationRmsAfterMm)?p.validationRmsAfterMm:(p==null?Float.NaN:p.trainingRmsAfterMm);}
  String qualityCode(DepthCorrectionProfile p){if(p==null||!p.calibrated)return "none";float before=qualityRmsBefore(p),after=qualityRmsAfter(p),improvement=Float.isFinite(before)&&Float.isFinite(after)?before-after:0;if(p.coverage>=.70f&&Float.isFinite(after)&&after<=8&&improvement>=0)return "good";if(p.coverage>=.50f&&Float.isFinite(after)&&after<=16)return "regular";return "poor";}
  String qualityLabel(DepthCorrectionProfile p){return i18n.tr("calwindow."+qualityCode(p));}
  void renderQuality(){String label=qualityLabel(qualityProfile);if(qualityUnsaved&&qualityProfile!=null)label+=" — "+i18n.tr("calwindow.not_saved");quality.setText(label);}
  void showProfileMetrics(DepthCorrectionProfile p){if(p==null){setMetrics("calwindow.no_profile");return;}String q=qualityCode(p),impact="good".equals(q)?i18n.tr("calwindow.impact.good"):("regular".equals(q)?i18n.tr("calwindow.impact.regular"):i18n.tr("calwindow.impact.poor"));
    metricsWall=false;metricsKey="calwindow.metrics";metricsArgs=new Object[]{p.coverage*100,qualityRmsBefore(p),qualityRmsAfter(p),impact};metricsProfile=p;renderMetrics();}
  String html(String s){return s.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;");}
  String fmt(String key,Object... args){return String.format(Locale.US,i18n.tr(key),args);}
  // Result text: summary, absolute-scale status and per-station leave-one-station-out metrics.
  String profileMetricsHtml(DepthCorrectionProfile p){String q=qualityCode(p),impact="good".equals(q)?i18n.tr("calwindow.impact.good"):("regular".equals(q)?i18n.tr("calwindow.impact.regular"):i18n.tr("calwindow.impact.poor"));
    StringBuilder b=new StringBuilder("<html>").append(html(fmt("calwindow.metrics",p.coverage*100,qualityRmsBefore(p),qualityRmsAfter(p),impact)));
    if(p.modelType!=DepthCorrectionProfile.MODEL_DISPARITY_GRID)return b.append("<br>").append(html(i18n.tr("calwindow.legacy_profile"))).append("</html>").toString();
    b.append("<br>").append(html(p.referenceCount>0?fmt("calwindow.reference_applied",p.globalScale(),p.referenceCount,p.referenceRmsMm):i18n.tr("calwindow.reference_none")));
    if(p.stationCenterM.length>0){b.append("<br>").append(html(i18n.tr("calwindow.validation_header")));
      for(int s=0;s<p.stationCenterM.length;s++){float ref=p.stationReferenceM.length>s?p.stationReferenceM[s]:Float.NaN;
        String refText=Float.isNaN(ref)?"":fmt("calwindow.station_ref",ref,(p.stationRawCenterM[s]-ref)*1000,(p.stationCenterAfterM(s)-ref)*1000);
        b.append("<br>&nbsp;&nbsp;").append(html(fmt("calwindow.station_row",s+1,p.stationRawCenterM[s],refText,p.stationRmsBeforeMm[s],p.stationRmsAfterMm[s],p.stationMaeBeforeMm[s],p.stationMaeAfterMm[s],p.stationP95BeforeMm[s],p.stationP95AfterMm[s])));}}
    return b.append("</html>").toString();}
  void updateCaptureInstruction(){if(session==null)return;if(session.fitting){setInstruction("calwindow.fitting");return;}if(!wallReady){setInstruction("calwindow.wall_not_ready");return;}if(session.waitingForDistance)setInstruction("calwindow.move_station",session.stations.size(),rgbd.config.calibrationStations,rgbd.config.calibrationDistanceSeparationM*100);else setInstruction("calwindow.capturing",session.stations.size()+1,rgbd.config.calibrationStations,session.capturedFrames,rgbd.config.calibrationFramesPerStation);}
  void setInstruction(String key,Object... args){instructionKey=key;instructionArgs=args==null?new Object[0]:args;renderInstruction();}
  void renderInstruction(){String pattern=i18n.tr(instructionKey);instruction.setText(instructionArgs.length==0?pattern:String.format(Locale.US,pattern,instructionArgs));}
  void setMetrics(String key,Object... args){metricsWall=false;metricsProfile=null;metricsKey=key;metricsArgs=args==null?new Object[0]:args;renderMetrics();}
  void renderMetrics(){if(metricsWall){metrics.setText(String.format(Locale.US,i18n.tr("calwindow.wall_metrics"),i18n.tr(wallReady?"calwindow.ready":"calwindow.adjust"),wallCoverage*100,Float.isFinite(wallRmsMm)?String.format(Locale.US,"%.1f",wallRmsMm):"—",Float.isFinite(rgbWhiteRatio)?String.format(Locale.US,"%.0f%%",rgbWhiteRatio*100):"—"));return;}
    if(metricsProfile!=null){metrics.setText(profileMetricsHtml(metricsProfile));return;}
    String pattern=i18n.tr(metricsKey);metrics.setText(metricsArgs.length==0?pattern:String.format(Locale.US,pattern,metricsArgs));}
  void assessWall(DepthFrame d){float[] z=new float[d.depth.length];int valid=0;for(int i=0;i<z.length;i++){int mm=d.depth[i]&0xffff;if(mm>350&&mm<rgbd.config.maxDepthM*1000){z[i]=mm*.001f;valid++;}}PlaneModel plane=fitCalibrationPlane(z,d.width,d.height,rgbd.calibration,4);wallCoverage=valid/(float)max(1,z.length);wallRmsMm=plane.valid()?plane.rms*1000:Float.NaN;wallReady=plane.valid()&&wallCoverage>.55f&&plane.rmsAt1m()<=rgbd.config.calibrationPlaneResidualMaxM;
    if(session==null||!session.active){metricsWall=true;renderMetrics();}}
  void updateDepth(DepthFrame d){BufferedImage img=new BufferedImage(d.width,d.height,BufferedImage.TYPE_INT_RGB);int[] px=new int[d.depth.length];for(int i=0;i<px.length;i++){int mm=d.depth[i]&0xffff;if(mm==0){px[i]=0x10151a;continue;}float t=constrain((mm-450)/3000f,0,1);int r=(int)(22+45*(1-t)),g=(int)(62+137*(1-t)),b=(int)(82+161*(1-t));px[i]=(r<<16)|(g<<8)|b;}img.setRGB(0,0,d.width,d.height,px,0,d.width);depthPanel.setImage(img);}
  void updateRgb(RgbdFramePair pair){RawRgbFrame r=pair.rgb;if(r==null||r.data==null)return;int[] px=new int[r.width*r.height];if(!rgbd.source.decodeRgbPayloadToArgb(r.data,r.width,r.height,r.pixelFormat,px))return;int white=0,samples=0;int step=4;for(int y=r.height/8;y<r.height*7/8;y+=step)for(int x=r.width/8;x<r.width*7/8;x+=step){int c=px[y*r.width+x],rr=(c>>16)&255,gg=(c>>8)&255,bb=c&255,maxc=max(rr,max(gg,bb)),minc=min(rr,min(gg,bb));samples++;if((rr+gg+bb)/3>=165&&maxc-minc<=55)white++;}rgbWhiteRatio=samples>0?white/(float)samples:Float.NaN;BufferedImage img=new BufferedImage(r.width,r.height,BufferedImage.TYPE_INT_RGB);img.setRGB(0,0,r.width,r.height,px,0,r.width);rgbPanel.setImage(img);}
  void close(){if(closed)return;closed=true;if(timer!=null)timer.stop();if(session!=null)session.cancel();rgbd.requestStop(true);}
}

class CalibrationImagePanel extends JPanel {
  private static final long serialVersionUID=1L;transient volatile BufferedImage image;volatile String title="";final StudioSwingTheme theme;
  CalibrationImagePanel(String title,StudioSwingTheme theme){this.title=title==null?"":title;this.theme=theme;setBackground(new java.awt.Color(0x0C,0x10,0x14));setBorder(BorderFactory.createLineBorder(theme.border));}
  void setTitle(String value){title=value==null?"":value;repaint();}void setImage(BufferedImage image){this.image=image;repaint();}
  protected void paintComponent(java.awt.Graphics g){super.paintComponent(g);java.awt.Graphics2D g2=(java.awt.Graphics2D)g.create();g2.setRenderingHint(java.awt.RenderingHints.KEY_INTERPOLATION,java.awt.RenderingHints.VALUE_INTERPOLATION_BILINEAR);BufferedImage im=image;if(im!=null){float sc=min(getWidth()/(float)im.getWidth(),(getHeight()-34)/(float)im.getHeight());int w=round(im.getWidth()*sc),h=round(im.getHeight()*sc),x=(getWidth()-w)/2,y=30+(getHeight()-30-h)/2;g2.drawImage(im,x,y,w,h,null);}g2.setColor(theme.text);g2.setFont(getFont().deriveFont(java.awt.Font.BOLD,14f));g2.drawString(title,12,20);g2.dispose();}
}
