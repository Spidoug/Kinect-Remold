#!/usr/bin/env python3
"""Body3D shared viewport regression benchmark.

Exercises the failure mode that used to affect Interactivity/Motion Capture:
- stale origin when tracking ids restart after tab/device changes;
- lateral/depth body motion;
- arms/legs changing the point-cloud envelope;
- compact/resized panels;
- Kinect-v1-like range noise and sparse edge outliers.

The script has no Processing dependency so it can run in CI before the Studio jars
are staged. It also verifies that the project source contains the shared framing and
hard-clipping hooks exercised by the model below.
"""
from __future__ import annotations
import math, random, statistics, sys
from dataclasses import dataclass
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'applications/processing/SynKinectStudio/BodyTracking.pde'
INTER=ROOT/'applications/processing/SynKinectStudio/Interactivity.pde'
MOCAP=ROOT/'applications/processing/SynKinectStudio/MotionCapture.pde'

REQUIRED={
 SRC:['class BodyViewFrame','BodyViewFrame prepareFrame','bodyViewOrigin=PVector.lerp','targetScale<bodyViewScale','insideViewport(p,1)','void reset()'],
 INTER:['ui.preview.reset()','clampToViewport'],
 MOCAP:['ui.preview.reset()','final BodySkeletonPreview preview=new BodySkeletonPreview()'],
}
for path,needles in REQUIRED.items():
    text=path.read_text(encoding='utf-8')
    for n in needles:
        if n not in text:
            raise SystemExit(f'SOURCE CONTRACT FAIL: {path.name} missing {n!r}')

@dataclass
class P:
    x:float; y:float; z:float

def lerp(a,b,t): return a+(b-a)*t

def local(q:P,o:P,yaw=-.30,pitch=.08,ysign=-1.0):
    lx,ly,lz=q.x-o.x,q.y-o.y,q.z-o.z
    dx=-lx;dy=ysign*ly;dz=lz;c=math.cos(yaw);sn=math.sin(yaw)
    x1=dx*c-dz*sn;z1=dx*sn+dz*c;cp=math.cos(pitch);sp=math.sin(pitch)
    y1=dy*cp-z1*sp;z2=dy*sp+z1*cp
    return P(x1,y1,z2)

def screen(lp:P,cx,cy,sc): return P(cx+lp.x*sc,cy-lp.y*sc,lp.z)

def add_cloud_bone(out,a,b,r,n,rng,zsensor):
    for i in range(n):
        t=(i+rng.random())/n
        x=lerp(a.x,b.x,t); y=lerp(a.y,b.y,t); z=lerp(a.z,b.z,t)
        ang=rng.random()*math.tau; rr=r*(.65+.35*rng.random())
        # crude camera-surface shell; enough to stress envelope/framing.
        x+=math.cos(ang)*rr; y+=math.sin(ang)*rr
        sigma=.0022*max(.55,zsensor+z)**2
        z+=rng.gauss(0,sigma)
        z=round(z*1000)/1000.0
        if rng.random()<.018: continue
        out.append(P(x,y,z))

def human_cloud(rootx,rootz,phase,rng):
    hip=P(rootx,.10,2.25+rootz); spine=P(rootx,-.18,2.25+rootz); sh=P(rootx,-.48,2.24+rootz); head=P(rootx,-.72,2.23+rootz)
    ls=P(rootx+.19,-.48,2.24+rootz); rs=P(rootx-.19,-.48,2.24+rootz)
    # alternate T-pose / reach / overhead to change projected envelope.
    mode=int(phase*3)%3
    if mode==0:
        lh=P(rootx+.76,-.48,2.22+rootz); rh=P(rootx-.76,-.48,2.22+rootz)
    elif mode==1:
        lh=P(rootx+.35,-.42,1.75+rootz); rh=P(rootx-.35,-.42,1.75+rootz)
    else:
        lh=P(rootx+.27,-1.08,2.22+rootz); rh=P(rootx-.27,-1.08,2.22+rootz)
    lhip=P(rootx+.10,.10,2.25+rootz); rhip=P(rootx-.10,.10,2.25+rootz)
    lf=P(rootx+.12,.93,2.28+rootz); rf=P(rootx-.12,.93,2.28+rootz)
    pts=[]
    for a,b,r,n in [(head,sh,.10,380),(sh,hip,.17,1050),(ls,lh,.05,520),(rs,rh,.05,520),(lhip,lf,.065,650),(rhip,rf,.065,650)]:
        add_cloud_bone(pts,a,b,r,n,rng,0)
    # Sparse segmentation-edge mistakes; real renderer should cull these and robust fit ignores implausible points.
    for _ in range(8): pts.append(P(rootx+rng.choice((-1,1))*rng.uniform(1.4,1.8),rng.uniform(-1.3,1.2),2.25+rootz+rng.uniform(-.4,.4)))
    joints=[hip,spine,sh,head,ls,rs,lh,rh,lhip,rhip,lf,rf]
    return joints,pts

def anchor(j):
    # same torso weighting as BodySkeletonPreview.bodyAnchor
    hip,spine,sh=j[0],j[1],j[2]
    lhip,rhip=j[8],j[9];ls,rs=j[4],j[5]
    weights=[(spine,4),(hip,3),(sh,3),(lhip,1),(rhip,1),(ls,1),(rs,1)]
    sw=sum(w for _,w in weights)
    return P(sum(p.x*w for p,w in weights)/sw,sum(p.y*w for p,w in weights)/sw,sum(p.z*w for p,w in weights)/sw)

def plausible(q,o): return q.z>0 and abs(q.x-o.x)<=1.35 and abs(q.y-o.y)<=1.45 and abs(q.z-o.z)<=1.20

class NewView:
    def __init__(self): self.reset()
    def reset(self):
        self.origin=None;self.tid=None;self.panx=self.pany=0.;self.scale=float('nan');self.lastw=self.lasth=-1
    def frame(self,joints,cloud,w,h,tid=1):
        target=anchor(joints); idchg=self.origin is None or (tid and tid!=self.tid)
        resized=self.lastw>0 and (abs(w-self.lastw)>max(18,self.lastw*.12) or abs(h-self.lasth)>max(18,self.lasth*.12))
        if idchg or resized or self.origin is None:
            self.origin=P(target.x,target.y,target.z);self.panx=self.pany=0;self.scale=float('nan')
        else:
            self.origin=P(lerp(self.origin.x,target.x,.68),lerp(self.origin.y,target.y,.68),lerp(self.origin.z,target.z,.68))
        self.tid=tid;self.lastw=w;self.lasth=h
        vals=[local(q,self.origin) for q in cloud+joints if plausible(q,self.origin)]
        if len(vals)<2: vals=[P(-1.05,-1.05,0),P(1.05,1.05,0)]
        minx=min(p.x for p in vals)-.055;maxx=max(p.x for p in vals)+.055;miny=min(p.y for p in vals)-.075;maxy=max(p.y for p in vals)+.075
        spanx=max(.30,maxx-minx);spany=max(.55,maxy-miny);tx=(minx+maxx)/2;ty=(miny+maxy)/2
        if idchg or resized or not math.isfinite(self.scale): self.panx,self.pany=tx,ty
        else:
            if abs(tx-self.panx)>=.010:self.panx=lerp(self.panx,tx,.42)
            if abs(ty-self.pany)>=.010:self.pany=lerp(self.pany,ty,.42)
        fixed=min(h*.84/2.10,w*.86/2.10);fit=min(max(4,w-12)*.94/spanx,max(4,h-12)*.94/spany);targetscale=max(4,min(fixed,fit))
        if not math.isfinite(self.scale) or idchg or resized:self.scale=targetscale
        elif targetscale<self.scale:self.scale=targetscale
        else:self.scale=lerp(self.scale,targetscale,.10)
        self.scale=max(4,min(self.scale,fit))
        cx=w*.5-self.panx*self.scale;cy=h*.5+self.pany*self.scale-(-.03)*self.scale
        return self.origin,cx,cy,self.scale,(minx,maxx,miny,maxy)

class OldView:
    def __init__(self): self.origin=None;self.tid=None
    def reset(self): self.origin=None;self.tid=None
    def frame(self,joints,cloud,w,h,tid=1):
        if self.origin is None or (tid and tid!=self.tid): self.origin=P(joints[0].x,joints[0].y,joints[0].z);self.tid=tid
        fixedh=2.10;fixedw=2.10
        scaleh=h*.84/fixedh;scalew=w*.86/fixedw
        lo=min(w,h)*.36;hi=min(w,h)*1.28;sc=max(lo,min(hi,min(scaleh,scalew)))
        cx=w*.5;cy=h*.52-(-.03)*sc
        vals=[local(q,self.origin) for q in cloud+joints if plausible(q,self.origin)]
        if not vals: vals=[P(0,0,0)]
        return self.origin,cx,cy,sc,(min(p.x for p in vals),max(p.x for p in vals),min(p.y for p in vals),max(p.y for p in vals))

def metrics(view,panel,frames=150,reset_mid=False):
    rng=random.Random(0x360);w,h=panel;outside=[];centers=[];occ=[]
    for f in range(frames):
        t=f/(frames-1);x=.78*math.sin(t*math.tau);z=.48*math.sin(t*math.tau*1.35)
        joints,cloud=human_cloud(x,z,t,rng)
        if reset_mid and f==frames//2:
            # New session reuses tracking id 1 at a different physical position.
            x=-.62;joints,cloud=human_cloud(x,0,t,rng)
            if isinstance(view,NewView): view.reset()
        o,cx,cy,sc,b=view.frame(joints,cloud,w,h,1)
        good=[q for q in cloud if plausible(q,o)]
        ps=[screen(local(q,o),cx,cy,sc) for q in good]
        out=sum(1 for p in ps if p.x<1 or p.x>w-1 or p.y<1 or p.y>h-1)
        outside.append(out/max(1,len(ps)))
        if ps:
            minx,maxx=min(p.x for p in ps),max(p.x for p in ps);miny,maxy=min(p.y for p in ps),max(p.y for p in ps)
            centers.append(math.hypot((minx+maxx)/2-w/2,(miny+maxy)/2-h/2))
            occ.append(max((maxx-minx)/w,(maxy-miny)/h))
    return {'outside_max':max(outside),'outside_mean':statistics.mean(outside),'center_mean':statistics.mean(centers),'center_max':max(centers),'occ_max':max(occ)}


def metrics_resize(view,frames=150):
    rng=random.Random(0x1473);outside=[];centers=[];occ=[];norm_center=[]
    panels=[(760,430),(360,220),(520,270),(760,430)]
    for f in range(frames):
        w,h=panels[min(len(panels)-1,(f*len(panels))//frames)]
        t=f/(frames-1);x=.74*math.sin(t*math.tau*1.15);z=.40*math.sin(t*math.tau*.8)
        joints,cloud=human_cloud(x,z,t,rng);o,cx,cy,sc,b=view.frame(joints,cloud,w,h,1)
        good=[q for q in cloud if plausible(q,o)];ps=[screen(local(q,o),cx,cy,sc) for q in good]
        out=sum(1 for pt in ps if pt.x<1 or pt.x>w-1 or pt.y<1 or pt.y>h-1);outside.append(out/max(1,len(ps)))
        if ps:
            minx,maxx=min(pt.x for pt in ps),max(pt.x for pt in ps);miny,maxy=min(pt.y for pt in ps),max(pt.y for pt in ps)
            ce=math.hypot((minx+maxx)/2-w/2,(miny+maxy)/2-h/2);centers.append(ce);norm_center.append(ce/min(w,h));occ.append(max((maxx-minx)/w,(maxy-miny)/h))
    return {'outside_max':max(outside),'outside_mean':statistics.mean(outside),'center_mean':statistics.mean(centers),'center_max':max(centers),'center_norm_max':max(norm_center),'occ_max':max(occ)}

def fmt(m): return f"outside mean/max={m['outside_mean']*100:.2f}/{m['outside_max']*100:.2f}% center mean/max={m['center_mean']:.1f}/{m['center_max']:.1f}px occupancy max={m['occ_max']:.3f}"

panels=[(760,430),(520,270),(360,220)]
passes=[]
print('Body3D viewport benchmark (Kinect360-like cloud + lateral/depth motion)')
for panel in panels:
    old=metrics(OldView(),panel);new=metrics(NewView(),panel)
    ok=new['outside_max']==0 and new['center_max']<=min(panel)*.085 and new['occ_max']<=.98
    passes.append(ok)
    print(f'  {panel[0]}x{panel[1]} old: {fmt(old)}')
    print(f'  {panel[0]}x{panel[1]} new: {fmt(new)} -> {"PASS" if ok else "FAIL"}')
# stale tracking-id restart is a separate historical regression.
old_restart=metrics(OldView(),(520,270),90,True);new_restart=metrics(NewView(),(520,270),90,True)
restart_ok=new_restart['outside_max']==0 and new_restart['center_max']<=270*.085
passes.append(restart_ok)
print('  session/id-reuse old:',fmt(old_restart))
print('  session/id-reuse new:',fmt(new_restart),'->', 'PASS' if restart_ok else 'FAIL')
resize_old=metrics_resize(OldView());resize_new=metrics_resize(NewView())
resize_ok=resize_new['outside_max']==0 and resize_new['center_norm_max']<=.085 and resize_new['occ_max']<=.98
passes.append(resize_ok)
print('  live-resize old:',fmt(resize_old))
print('  live-resize new:',fmt(resize_new),'->', 'PASS' if resize_ok else 'FAIL')
print('SOURCE CONTRACT: PASS')
print('BODY3D VIEWPORT RESULT:', 'PASS' if all(passes) else 'FAIL')
sys.exit(0 if all(passes) else 1)
