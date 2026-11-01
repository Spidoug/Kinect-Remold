#!/usr/bin/env python3
"""Configure the common tracking backend on Linux and Windows."""
import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / 'applications/processing/SynKinectStudio/data/skeleton/config/config.properties'
MODELS = {
    'rgb': 'data/skeleton/movenet.onnx',
    'depth': 'data/skeleton/SynSkeleton.onnx',
}

def update_mode(text, mode):
    lines = text.splitlines(keepends=True)
    key = 'tracking.mode='
    found = False
    result = []
    for line in lines:
        if line.lstrip().startswith(key):
            if found:
                continue
            result.append(key + mode + '\n')
            found = True
        else:
            result.append(line)
    if not found:
        result.append('\n' + key + mode + '\n')
    return ''.join(result)

def main(argv=None):
    parser = argparse.ArgumentParser(description='Select the SynKinect Studio ONNX tracking backend')
    parser.add_argument('--mode', choices=tuple(MODELS), required=True)
    parser.add_argument('--model', type=Path, help='Optional ONNX model to copy to the Studio resources')
    args = parser.parse_args(argv)
    destination = ROOT / 'applications/processing/SynKinectStudio' / MODELS[args.mode]
    if args.model is not None:
        if not args.model.is_file() or args.model.stat().st_size == 0 or args.model.suffix.lower() != '.onnx':
            parser.error('--model must be a nonempty ONNX file')
        destination.parent.mkdir(parents=True, exist_ok=True)
        import shutil
        if args.model.resolve() != destination.resolve():
            shutil.copy2(args.model, destination)
    if not destination.is_file() or destination.stat().st_size == 0:
        parser.error('Missing ONNX model: %s. Provide --model with the corresponding network.' % destination)
    source = CONFIG.read_text(encoding='utf-8')
    updated = update_mode(source, args.mode)
    if updated != source:
        CONFIG.write_text(updated, encoding='utf-8')
    print('Tracking mode: %s' % args.mode)
    print('Model: %s' % destination)
    print('Restart the Studio to apply the new mode.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
