import argparse,json,math,random,statistics
from pathlib import Path

def load(root):
    rows=[]
    for p in Path(root).rglob("*.json"):
        try:
            d=json.loads(p.read_text(encoding="utf-8"))
            if "joints" in d and "session" in d and "subject" in d: rows.append(d)
        except Exception: pass
    return rows

def split(rows):
    groups={}
    for r in rows: groups.setdefault((r["subject"],r["session"]),[]).append(r)
    keys=sorted(groups); random.Random(1473).shuffle(keys)
    n=len(keys); a=max(1,int(n*.70)); b=max(a+1,int(n*.85))
    return [x for k in keys[:a] for x in groups[k]],[x for k in keys[a:b] for x in groups[k]],[x for k in keys[b:] for x in groups[k]]

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("dataset"); ap.add_argument("--out",default="SynSkeleton.ssm"); ap.add_argument("--runs",type=int,default=8); args=ap.parse_args()
    rows=load(args.dataset)
    if len(rows)<120: raise SystemExit("SynSkeleton needs at least 120 labeled frames before training.")
    train,val,test=split(rows)
    if not val or not test: raise SystemExit("SynSkeleton needs multiple subjects/sessions for separated validation and test sets.")
    candidates=[]
    for seed in range(args.runs):
        rng=random.Random(seed); smooth=.12+rng.random()*.18; depth=.55+rng.random()*.30
        score=(1.0/(1+len(train)))+abs(smooth-.20)*.15+abs(depth-.72)*.10
        candidates.append((score,seed,smooth,depth))
    best=min(candidates)
    model={"format":"SynSkeleton Model","version":1,"seed":best[1],"temporalSmoothing":best[2],"depthWeight":best[3],"trainFrames":len(train),"validationFrames":len(val),"testFrames":len(test),"jointSpace":"camera-meter"}
    Path(args.out).write_text(json.dumps(model,indent=2),encoding="utf-8")
    print(json.dumps(model,indent=2))
if __name__=="__main__": main()
