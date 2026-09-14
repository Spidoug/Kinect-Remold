#!/usr/bin/env python3
"""Prepare the exact Kinect Runtime v1.8 UACFirmware used by the Windows build.

Linux build parity pipeline:
  1. download Microsoft's pinned KinectRuntime-v1.8-Setup.exe;
  2. validate the exact Runtime SHA-256 used by the Windows V1 build;
  3. carve WiX Burn CAB containers from the bundle;
  4. extract MSI payloads with cabextract/msiextract;
  5. locate UACFirmware 01.02.709.00 and validate its pinned SHA-256;
  6. emit the C/C++ firmware symbols consumed by the audio bridge.

No firmware bytes are stored in the source archive. They are materialized only
in the local build/cache after the builder downloads the official Microsoft
Runtime package.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

RUNTIME_URL = (
    "https://download.microsoft.com/download/E/C/5/"
    "EC50686B-82F4-4DBF-A922-980183B214E6/KinectRuntime-v1.8-Setup.exe"
)
RUNTIME_FILENAME = "KinectRuntime-v1.8-Setup.exe"
RUNTIME_VERSION = "1.8.0.595"
RUNTIME_SHA256 = "f4d4143fb0f0a8d276889c077bfc8af42bfe99c128cadab5e316bf015a9858e9"
FIRMWARE_VERSION = "01.02.709.00"
FIRMWARE_SHA256 = "4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9"
FIRMWARE_MIN = 65536
FIRMWARE_MAX = 1048576
OLE_MAGIC = bytes.fromhex("d0cf11e0a1b11ae1")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def download_runtime(destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = destination.with_suffix(destination.suffix + ".download")
    if temp.exists():
        temp.unlink()
    request = urllib.request.Request(
        RUNTIME_URL,
        headers={"User-Agent": "Kinect-Xbox-360-Remold/1.0 Linux-build-parity"},
    )
    last: Exception | None = None
    for attempt in range(1, 4):
        try:
            print(f"Downloading pinned Microsoft Kinect for Windows Runtime v1.8 (attempt {attempt}/3)...")
            with urllib.request.urlopen(request, timeout=90) as src, temp.open("wb") as dst:
                while True:
                    chunk = src.read(1024 * 1024)
                    if not chunk:
                        break
                    dst.write(chunk)
            if temp.stat().st_size < 50 * 1024 * 1024:
                raise RuntimeError(f"download is unexpectedly small: {temp.stat().st_size} bytes")
            actual = sha256_file(temp)
            if actual != RUNTIME_SHA256:
                raise RuntimeError(
                    f"Kinect Runtime v1.8 SHA-256 mismatch: {actual}; expected {RUNTIME_SHA256}"
                )
            os.replace(temp, destination)
            return
        except Exception as exc:  # noqa: BLE001 - preserve useful network error
            last = exc
            try:
                temp.unlink()
            except FileNotFoundError:
                pass
            if attempt != 3:
                time.sleep(attempt * 2)
    raise RuntimeError(f"unable to download the pinned Microsoft Kinect Runtime v1.8: {last}")


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(
            f"required Linux extraction tool '{name}' was not found. "
            "Install cabextract and msitools, or run the project Linux installer/build bootstrap."
        )
    return path


def carve_burn_cabinets(bundle: Path, destination: Path) -> list[Path]:
    data = bundle.read_bytes()
    out: list[Path] = []
    pos = 0
    seen: set[tuple[int, int]] = set()
    while True:
        pos = data.find(b"MSCF", pos)
        if pos < 0:
            break
        # CFHEADER: signature(4), reserved1(4), cbCabinet(4), ...
        if pos + 12 <= len(data):
            size = struct.unpack_from("<I", data, pos + 8)[0]
            key = (pos, size)
            if 36 <= size <= len(data) - pos and key not in seen:
                # Basic CAB version sanity at offsets 24/25 (minor/major).
                minor = data[pos + 24] if pos + 25 < len(data) else 0
                major = data[pos + 25] if pos + 25 < len(data) else 0
                if major in (1, 2, 3, 4) and minor <= 9:
                    seen.add(key)
                    path = destination / f"burn-container-{len(out):02d}.cab"
                    path.write_bytes(data[pos : pos + size])
                    out.append(path)
                    pos += size
                    continue
        pos += 4
    if not out:
        raise RuntimeError("no valid WiX Burn CAB containers were found in the Microsoft Runtime bundle")
    return out


def run_quiet(command: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )


def extract_payloads(bundle: Path, work: Path) -> list[Path]:
    cabextract = require_tool("cabextract")
    msiextract = require_tool("msiextract")
    cabs_dir = work / "burn-cabs"
    cabs_dir.mkdir(parents=True, exist_ok=True)
    cabinets = carve_burn_cabinets(bundle, cabs_dir)

    extracted_roots: list[Path] = []
    for index, cab in enumerate(cabinets):
        target = work / f"container-{index:02d}"
        target.mkdir(parents=True, exist_ok=True)
        result = run_quiet([cabextract, "-q", "-d", str(target), str(cab)])
        if result.returncode == 0:
            extracted_roots.append(target)

    if not extracted_roots:
        raise RuntimeError("cabextract could not open any Burn container from the validated Runtime bundle")

    msi_count = 0
    for root in list(extracted_roots):
        for candidate in list(root.rglob("*")):
            if not candidate.is_file():
                continue
            try:
                with candidate.open("rb") as f:
                    magic = f.read(8)
            except OSError:
                continue
            if magic != OLE_MAGIC:
                continue
            msi_count += 1
            target = work / f"msi-{msi_count:03d}"
            target.mkdir(parents=True, exist_ok=True)
            result = run_quiet([msiextract, "-C", str(target), str(candidate)])
            if result.returncode == 0:
                extracted_roots.append(target)

    if msi_count == 0:
        raise RuntimeError("no MSI payloads were found inside the validated Kinect Runtime Burn bundle")
    return extracted_roots


def find_firmware(roots: list[Path]) -> Path:
    candidates: list[Path] = []
    for root in roots:
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            name = path.name.lower()
            if name == "uacfirmware" or name.startswith("uacfirmware.") or "uacfirmware" in name:
                candidates.append(path)
    # A correct hash is authoritative even if MSI extraction renamed the file.
    if not candidates:
        for root in roots:
            for path in root.rglob("*"):
                if not path.is_file():
                    continue
                try:
                    size = path.stat().st_size
                except OSError:
                    continue
                if FIRMWARE_MIN <= size <= FIRMWARE_MAX:
                    candidates.append(path)

    checked: set[Path] = set()
    for path in candidates:
        if path in checked:
            continue
        checked.add(path)
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if not (FIRMWARE_MIN <= size <= FIRMWARE_MAX):
            continue
        if sha256_file(path) == FIRMWARE_SHA256:
            return path
    raise RuntimeError(
        "UACFirmware 01.02.709.00 was not found in the validated Kinect Runtime v1.8 payloads "
        f"(expected SHA-256 {FIRMWARE_SHA256})"
    )


def write_header(firmware: bytes, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = output.with_suffix(output.suffix + ".tmp")
    with temp.open("w", encoding="utf-8", newline="\n") as f:
        f.write("#pragma once\n")
        f.write("// Generated during the Linux driver build from Microsoft Kinect Runtime v1.8 UACFirmware.\n")
        f.write(f'static const char gRemoldAudioFirmwareVersion[] = "{FIRMWARE_VERSION}";\n')
        f.write(f'static const char gRemoldAudioFirmwareSha256[] = "{FIRMWARE_SHA256}";\n')
        f.write("static const unsigned char gRemoldAudioFirmware[] = {\n")
        for offset in range(0, len(firmware), 16):
            chunk = firmware[offset : offset + 16]
            f.write("    " + ", ".join(f"0x{b:02X}" for b in chunk) + ",\n")
        f.write("};\n")
        f.write(f"static const unsigned long gRemoldAudioFirmwareSize = {len(firmware)}UL;\n")
    os.replace(temp, output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", required=True, type=Path)
    parser.add_argument("--output-header", required=True, type=Path)
    parser.add_argument("--output-bin", type=Path)
    args = parser.parse_args()

    args.cache_dir.mkdir(parents=True, exist_ok=True)
    runtime = args.cache_dir / RUNTIME_FILENAME
    if runtime.exists():
        actual = sha256_file(runtime)
        if actual != RUNTIME_SHA256:
            print(f"Discarding invalid cached Kinect Runtime (SHA-256 {actual}).")
            runtime.unlink()
    if not runtime.exists():
        download_runtime(runtime)

    runtime_hash = sha256_file(runtime)
    print(
        f"Kinect Runtime v1.8 integrity: PASS (version={RUNTIME_VERSION}, "
        f"SHA256={runtime_hash}, bytes={runtime.stat().st_size})"
    )

    cached_firmware = args.cache_dir / f"UACFirmware-{FIRMWARE_VERSION}"
    if cached_firmware.exists() and sha256_file(cached_firmware) == FIRMWARE_SHA256:
        firmware_path = cached_firmware
    else:
        with tempfile.TemporaryDirectory(prefix="remold-uac-") as tmp:
            roots = extract_payloads(runtime, Path(tmp))
            found = find_firmware(roots)
            shutil.copyfile(found, cached_firmware)
        firmware_path = cached_firmware

    firmware = firmware_path.read_bytes()
    if not (FIRMWARE_MIN <= len(firmware) <= FIRMWARE_MAX):
        raise RuntimeError(f"UACFirmware size is outside the expected range: {len(firmware)} bytes")
    actual_fw = hashlib.sha256(firmware).hexdigest()
    if actual_fw != FIRMWARE_SHA256:
        raise RuntimeError(f"UACFirmware SHA-256 mismatch: {actual_fw}; expected {FIRMWARE_SHA256}")

    write_header(firmware, args.output_header)
    if args.output_bin:
        args.output_bin.parent.mkdir(parents=True, exist_ok=True)
        temp = args.output_bin.with_suffix(args.output_bin.suffix + ".tmp")
        temp.write_bytes(firmware)
        os.replace(temp, args.output_bin)

    print(
        f"UACFirmware {FIRMWARE_VERSION} validation: PASS "
        f"(SHA256={actual_fw}, bytes={len(firmware)}, load=0x00080000, entry=0x00080030, models=1414,1473)"
    )
    print(f"Generated embedded firmware header: {args.output_header}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"Kinect Runtime/UACFirmware preparation failed: {exc}", file=sys.stderr)
        raise SystemExit(2)
