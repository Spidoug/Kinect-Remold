#!/usr/bin/env python3
"""Standalone sanity probe for ScanHarness Kinect-v1 sensor profiles.
No Processing/JOGL dependencies are required. It samples the disparity model at
several ranges and image locations and reports axial error statistics.
"""
import math, random, statistics, sys
BASELINE=0.075; IR_F=580.0; Q=1/8
W,H=640,480; FX,FY,CX,CY=580.0,580.0,319.5,239.5

def fixed(u,v,stress=False):
    radial=((u-CX)/FX)**2+((v-CY)/FY)**2
    stripes=.018*math.sin(u*2*math.pi/31)+.010*math.sin(u*2*math.pi/7)
    field=(radial-.18)*(.050 if stress else .030)
    # deterministic pixel term with Python RNG seeded by pixel
    r=random.Random((v<<20)^u^0x6A09E667)
    pixel=(r.random()-.5)*(.045 if stress else .028)
    return stripes+field+pixel

def sample(profile,z,n=30000,seed=42):
    r=random.Random(seed+int(z*1000)); stress=profile=='stress'
    sigma=.075 if profile=='ideal' else (.105 if stress else .085)
    temporal=0.0; errs=[]
    for i in range(n):
        u=r.randrange(W); v=r.randrange(H)
        if profile!='ideal': temporal=.88*temporal+r.gauss(0,.018 if stress else .010)
        d=BASELINE*IR_F/z+r.gauss(0,sigma)
        if profile!='ideal':
            phase=2*math.pi*r.random()
            d+=fixed(u,v,stress)+temporal+(.020 if stress else .010)*math.sin(v*.075+phase+i*.035)
        d=round(d/Q)*Q
        if d<=1: continue
        zm=BASELINE*IR_F/d
        errs.append((zm-z)*1000)
    errs.sort(); mean=statistics.fmean(errs); sd=statistics.pstdev(errs)
    p95=errs[int(.975*len(errs))]-errs[int(.025*len(errs))]
    return mean,sd,p95

def main():
    profiles=['ideal','kinect360','stress'] if len(sys.argv)==1 else sys.argv[1:]
    print('profile       range   bias(mm) sigma(mm) shell95(mm)')
    out={}
    for p in profiles:
        out[p]=[]
        for z in (.6,1.0,2.0,3.0,4.0):
            m,s,w=sample(p,z); out[p].append(s)
            print(f'{p:12s} {z:4.1f}m {m:9.3f} {s:9.3f} {w:11.3f}')
    if all(p in out for p in ('ideal','kinect360','stress')):
        # Guardrail: realistic profiles must be harder and error must grow strongly with range.
        assert out['kinect360'][3] > out['ideal'][3]
        assert out['stress'][3] > out['kinect360'][3]
        assert out['kinect360'][4] > out['kinect360'][1]*8
        print('SENSOR PROFILE PROBE: PASS')
if __name__=='__main__': main()
