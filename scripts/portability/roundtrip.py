#!/usr/bin/env python3
"""Cross-platform ZIP round-trip validator for Kinect Xbox 360 Remold.

Creates and extracts the project repeatedly, intentionally nesting each extraction,
then validates the relative runtime/build layout. It also normalizes archive names
and Unix executable attributes for shell launchers.
"""
from __future__ import annotations
import argparse, os, shutil, stat, sys, tempfile, zipfile
from pathlib import Path

MARKERS = ("VERSION", "drivers", "applications", "scripts")
REQUIRED = (
    "Kinect-Xbox-360-Remold.cmd", "Kinect-Xbox-360-Remold.sh", "VERSION",
    "scripts/windows/BUILD-STUDIO.cmd", "scripts/linux/BUILD-STUDIO.sh",
    "drivers/windows/BUILD.cmd", "drivers/linux/BUILD.sh",
    "applications/runtime-templates/windows-x64/SynKinectStudio.cmd",
    "applications/runtime-templates/linux-x64/SynKinectStudio.sh",
)
EXCLUDE_DIRS = {".git", ".idea", ".vs", "__pycache__"}

def repo_root(start: Path) -> Path:
    p = start.resolve()
    if p.is_file(): p = p.parent
    for _ in range(16):
        if all((p / m).exists() for m in MARKERS): return p
        if p.parent == p: break
        p = p.parent
    raise RuntimeError(f"repository root not found above {start}")

def validate(root: Path) -> None:
    missing=[r for r in REQUIRED if not (root/r).is_file()]
    if missing: raise RuntimeError("missing required files: " + ", ".join(missing))
    # Reject build-time absolute paths accidentally committed into text launchers.
    needles=(str(root).replace('\\','/'), str(root).replace('/','\\'))
    for rel in REQUIRED:
        p=root/rel
        if p.suffix.lower() not in {'.cmd','.sh','.ps1','.vbs'}: continue
        text=p.read_text(encoding='utf-8-sig', errors='replace')
        for n in needles:
            if len(n)>3 and n in text:
                raise RuntimeError(f"absolute repository path leaked into {rel}: {n}")

def add_tree(zf: zipfile.ZipFile, root: Path, top: str) -> None:
    for p in sorted(root.rglob('*')):
        rel=p.relative_to(root)
        if any(part in EXCLUDE_DIRS for part in rel.parts): continue
        if p.is_dir(): continue
        arc=(Path(top)/rel).as_posix()
        info=zipfile.ZipInfo.from_file(p, arcname=arc)
        # Explicitly preserve portable Unix permissions. Shell files must remain runnable.
        mode = p.stat().st_mode
        if p.suffix == '.sh': mode |= stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        info.external_attr = (mode & 0xFFFF) << 16
        with p.open('rb') as src, zf.open(info,'w') as dst: shutil.copyfileobj(src,dst)

def make_zip(root: Path, out: Path, top: str) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9,allowZip64=True) as zf:
        add_tree(zf,root,top)

def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument('--cycles',type=int,default=4)
    ap.add_argument('--output',type=Path,help='also write a final portable ZIP here')
    ns=ap.parse_args()
    if ns.cycles < 1: ap.error('--cycles must be >= 1')
    source=repo_root(Path(__file__))
    validate(source)
    top=source.name
    with tempfile.TemporaryDirectory(prefix='remold-roundtrip-') as td:
        work=Path(td); current=source
        for cycle in range(1,ns.cycles+1):
            archive=work/f'cycle-{cycle}.zip'
            make_zip(current,archive,top)
            dest=work/f'extract-{cycle}'/top/f'nested-{cycle}'
            dest.mkdir(parents=True)
            with zipfile.ZipFile(archive) as zf: zf.extractall(dest)
            current=dest/top
            validate(current)
            print(f'[OK] cycle {cycle}: {current}')
    if ns.output:
        make_zip(source,ns.output.resolve(),top)
        print(f'[OK] portable ZIP: {ns.output.resolve()}')
    print(f'[OK] {ns.cycles} ZIP/extraction cycles validated.')
    return 0
if __name__=='__main__': raise SystemExit(main())
