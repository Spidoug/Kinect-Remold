#!/usr/bin/env python3
"""Expose Kinect v2 OS microphone capture through the Studio spatial-audio IPC."""
import argparse
import os
from pathlib import Path
import socket
import struct
import sys
import threading
import time

MAGIC = 0x414D4D52
FRAME_MAGIC = 0x464D4D52
CONTROL_MAGIC = 0x43414D52
RATE = 16000
CHANNELS = 4
SAMPLES = 256
PAYLOAD = SAMPLES * CHANNELS * 4


def capture_device(sd, selector):
    devices = [(i, d) for i, d in enumerate(sd.query_devices()) if int(d['max_input_channels']) >= 4]
    selector = str(selector).strip()
    if not selector:
        raise ValueError('Input device selector cannot be empty')
    if selector.isdecimal():
        candidates = [(i, d) for i, d in devices if i == int(selector)]
    else:
        candidates = [(i, d) for i, d in devices if selector.casefold() in str(d['name']).casefold()]
    if len(candidates) != 1:
        raise ValueError('Exactly one four-channel input must match --device; found %d' % len(candidates))
    return candidates[0][0]


def recv_exact(recv, count):
    result = bytearray()
    while len(result) < count:
        chunk = recv(count - len(result))
        if not chunk:
            raise EOFError('Client disconnected')
        result.extend(chunk)
    return bytes(result)


class AudioService:
    def __init__(self, sd, device):
        self.sd, self.device = sd, device
        self.volume = 100
        self.muted = False
        self.lock = threading.Lock()
        self.running = True
        self.client_slots = threading.BoundedSemaphore(8)

    def audio(self, recv, send):
        request = struct.unpack('<4I', recv_exact(recv, 16))
        if request[:3] != (MAGIC, 1, 1):
            return
        send(struct.pack('<8I', MAGIC, 1, 0, RATE, CHANNELS, 1, PAYLOAD, 3))
        frame_number = 0
        with self.sd.RawInputStream(device=self.device, channels=CHANNELS, samplerate=RATE,
                                    dtype='int32', blocksize=SAMPLES) as stream:
            while self.running:
                chunk, overflow = stream.read(SAMPLES)
                if overflow:
                    continue
                with self.lock:
                    volume, muted = self.volume, self.muted
                if muted or volume == 0:
                    pcm = bytes(PAYLOAD)
                elif volume == 100:
                    pcm = bytes(chunk)
                else:
                    import array
                    samples = array.array('i')
                    samples.frombytes(chunk)
                    if sys.byteorder != 'little':
                        samples.byteswap()
                    for i, value in enumerate(samples):
                        samples[i] = int(value * volume / 100)
                    if sys.byteorder != 'little':
                        samples.byteswap()
                    pcm = samples.tobytes()
                if len(pcm) != PAYLOAD:
                    continue
                header = struct.pack('<8I2Q', FRAME_MAGIC, 1, RATE, CHANNELS, 1,
                                     SAMPLES, PAYLOAD, 15, frame_number, int(time.monotonic() * 1000))
                send(header + pcm)
                frame_number += 1

    def control(self, recv, send):
        magic, version, command, value = struct.unpack('<4I', recv_exact(recv, 16))
        result = 0
        with self.lock:
            if magic != CONTROL_MAGIC or version != 1:
                result = -1
            elif command == 2:
                if value > 100:
                    result = -1
                else:
                    self.volume = value
            elif command == 3:
                if value not in (0, 1):
                    result = -1
                else:
                    self.muted = bool(value)
            elif command not in (0, 1):
                result = -1
            reply = struct.pack('<IIiII', CONTROL_MAGIC, 1, result, self.volume, int(self.muted))
        send(reply)


def serve_linux(path, handler, service, ready=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if path.is_socket():
            probe = socket.socket(socket.AF_UNIX)
            try:
                probe.settimeout(0.3)
                probe.connect(str(path))
                raise RuntimeError('Endpoint is already owned by another process: ' + str(path))
            except (ConnectionRefusedError, FileNotFoundError):
                path.unlink()
            finally:
                probe.close()
        else:
            raise RuntimeError('Endpoint path is not a socket: ' + str(path))
    listener = socket.socket(socket.AF_UNIX)
    owned_inode = None
    try:
        listener.bind(str(path))
        owned_inode = path.stat().st_ino
        os.chmod(path, 0o660)
        listener.listen(8)
        listener.settimeout(0.5)
        if ready is not None:
            ready.set()
        while service.running:
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            if not service.client_slots.acquire(blocking=False):
                client.close()
                continue
            def run(c):
                try:
                    with c:
                        try:
                            handler(c.recv, c.sendall)
                        except (OSError, EOFError, ValueError):
                            pass
                finally:
                    service.client_slots.release()
            try:
                threading.Thread(target=run, args=(client,), daemon=True).start()
            except Exception:
                client.close()
                service.client_slots.release()
                raise
    finally:
        listener.close()
        try:
            if owned_inode is not None and path.is_socket() and path.stat().st_ino == owned_inode:
                path.unlink(missing_ok=True)
        except FileNotFoundError:
            pass


def serve_windows(path, handler, service, ready=None):
    try:
        import win32pipe
        import win32file
        import pywintypes
    except ImportError as exc:
        raise RuntimeError('Windows named-pipe endpoints require pywin32') from exc
    while service.running:
        # Bound concurrent sessions to prevent unbounded worker/thread creation.
        service.client_slots.acquire()
        try:
            pipe = win32pipe.CreateNamedPipe(path, win32pipe.PIPE_ACCESS_DUPLEX,
                        win32pipe.PIPE_TYPE_BYTE | win32pipe.PIPE_READMODE_BYTE | win32pipe.PIPE_WAIT |
                        win32pipe.PIPE_REJECT_REMOTE_CLIENTS, 8, 8192, 8192, 0, None)
        except Exception:
            service.client_slots.release()
            raise
        handed_off = False
        try:
            if ready is not None:
                ready.set()
            try:
                win32pipe.ConnectNamedPipe(pipe, None)
            except pywintypes.error as exc:
                if exc.winerror != 535:
                    raise
            def run(p):
                def recv(n):
                    _, data = win32file.ReadFile(p, n)
                    return bytes(data)
                def send(data):
                    win32file.WriteFile(p, data)
                try:
                    handler(recv, send)
                except (OSError, EOFError, ValueError, pywintypes.error):
                    pass
                finally:
                    win32file.CloseHandle(p)
                    service.client_slots.release()
            threading.Thread(target=run, args=(pipe,), daemon=True).start()
            handed_off = True
        finally:
            if not handed_off:
                win32file.CloseHandle(pipe)
                service.client_slots.release()


def main(argv=None):
    parser = argparse.ArgumentParser(description='Kinect v2 Studio four-channel audio endpoint service')
    parser.add_argument('--device', default='kinect', help='Four-channel operating-system input name or index')
    parser.add_argument('--list-devices', action='store_true', help='List available four-channel audio input devices')
    parser.add_argument('--socket-dir', default='/run/kinect-one-remold', help='Linux SDK runtime directory')
    args = parser.parse_args(argv)
    try:
        import sounddevice as sd
        if args.list_devices:
            for i, info in enumerate(sd.query_devices()):
                if int(info['max_input_channels']) >= CHANNELS:
                    print('%d: %s (%s channels)' % (i, info['name'], info['max_input_channels']))
            return 0
        device = capture_device(sd, args.device)
        # Validate the device before exposing any endpoint to Studio.
        sd.check_input_settings(device=device, channels=CHANNELS, samplerate=RATE, dtype='int32')
        service = AudioService(sd, device)
        if os.name == 'nt':
            prefix = r'\\.\pipe\KinectOneRemold'
            endpoints = [(prefix + 'Audio', service.audio), (prefix + 'AudioControl', service.control)]
            worker = serve_windows
        else:
            base = Path(args.socket_dir)
            endpoints = [(str(base / 'audio.sock'), service.audio),
                         (str(base / 'audio-control.sock'), service.control)]
            worker = serve_linux
        ready_events = []
        threads = []
        failures = []
        def run_endpoint(address, handler, event):
            try:
                worker(address, handler, service, event)
            except Exception as exc:
                failures.append('%s: %s' % (address, exc))
            finally:
                service.running = False
                event.set()
        for address, handler in endpoints:
            ready = threading.Event()
            thread = threading.Thread(target=run_endpoint, args=(address, handler, ready), daemon=True)
            thread.start()
            ready_events.append(ready)
            threads.append(thread)
        for event in ready_events:
            if not event.wait(timeout=5):
                raise RuntimeError('Timed out initializing an audio endpoint')
        if failures or not all(t.is_alive() for t in threads):
            raise RuntimeError('; '.join(failures) or 'An audio endpoint stopped during initialization')
        print('Studio microphone endpoints ready for input device %d' % device, flush=True)
        try:
            while all(t.is_alive() for t in threads):
                time.sleep(0.5)
        except KeyboardInterrupt:
            return 0
        if failures:
            raise RuntimeError('; '.join(failures))
        return 1
    except (ImportError, OSError, ValueError, RuntimeError) as exc:
        print('Kinect v2 microphone service unavailable: %s' % exc, file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
