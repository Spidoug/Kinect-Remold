"""Protocol tests for the Studio microphone endpoints."""
import io
import struct
import unittest
from unittest.mock import patch

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "drivers/modules/kinect-one-remold/audio"))
import kinect_v2_audio_service as audio


class FakeStream:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, samples):
        return (struct.pack('<i', 12345) * (samples * 4), False)


class FakeSound:
    def RawInputStream(self, **kwargs):
        assert kwargs['channels'] == 4
        assert kwargs['samplerate'] == 16000
        return FakeStream()


class ProtocolTests(unittest.TestCase):
    def test_control(self):
        service = audio.AudioService(FakeSound(), 0)
        out = []
        service.control(io.BytesIO(struct.pack('<4I', audio.CONTROL_MAGIC, 1, 2, 40)).read, out.append)
        self.assertEqual(struct.unpack('<IIiII', out[0]), (audio.CONTROL_MAGIC, 1, 0, 40, 0))
        service.control(io.BytesIO(struct.pack('<4I', audio.CONTROL_MAGIC, 1, 3, 1)).read, out.append)
        self.assertEqual(struct.unpack('<IIiII', out[1]), (audio.CONTROL_MAGIC, 1, 0, 40, 1))
        service.control(io.BytesIO(struct.pack('<4I', audio.CONTROL_MAGIC, 1, 2, 101)).read, out.append)
        self.assertEqual(struct.unpack('<IIiII', out[2])[2], -1)

    def test_stream(self):
        service = audio.AudioService(FakeSound(), 0)
        output = []
        def send(data):
            output.append(data)
            if len(output) >= 2:
                service.running = False
        service.audio(io.BytesIO(struct.pack('<4I', audio.MAGIC, 1, 1, 0)).read, send)
        self.assertEqual(struct.unpack('<8I', output[0]), (audio.MAGIC, 1, 0, 16000, 4, 1, 4096, 3))
        self.assertEqual(len(output[1]), 48 + 4096)
        self.assertEqual(struct.unpack('<8I2Q', output[1][:48])[:8],
                         (audio.FRAME_MAGIC, 1, 16000, 4, 1, 256, 4096, 15))

    def test_empty_device_rejected(self):
        class Devices:
            @staticmethod
            def query_devices():
                return [dict(name='Kinect', max_input_channels=4)]
        with self.assertRaises(ValueError):
            audio.capture_device(Devices(), ' ')

    def test_ambiguous_device_rejected(self):
        class Devices:
            @staticmethod
            def query_devices():
                return [dict(name='Kinect A', max_input_channels=4),
                        dict(name='Kinect B', max_input_channels=4)]
        with self.assertRaises(ValueError):
            audio.capture_device(Devices(), 'Kinect')


if __name__ == '__main__':
    unittest.main()

class SocketLifecycleTests(unittest.TestCase):
    def test_linux_endpoint_receives_control_request(self):
        import os
        import socket
        import tempfile
        import threading
        import time
        if os.name == 'nt':
            self.skipTest('Unix domain socket test')
        service = audio.AudioService(FakeSound(), 0)
        with tempfile.TemporaryDirectory() as directory:
            endpoint = os.path.join(directory, 'control.sock')
            ready = threading.Event()
            worker = threading.Thread(target=audio.serve_linux,
                                      args=(endpoint, service.control, service, ready))
            worker.start()
            self.assertTrue(ready.wait(2))
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(endpoint)
                client.sendall(struct.pack('<4I', audio.CONTROL_MAGIC, 1, 2, 75))
                response = audio.recv_exact(client.recv, 20)
                self.assertEqual(struct.unpack('<IIiII', response),
                                 (audio.CONTROL_MAGIC, 1, 0, 75, 0))
            service.running = False
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertFalse(os.path.exists(endpoint))

    def test_stream_rejects_wrong_protocol(self):
        service = audio.AudioService(FakeSound(), 0)
        sent = []
        service.audio(io.BytesIO(struct.pack('<4I', 0, 1, 1, 0)).read, sent.append)
        self.assertEqual(sent, [])
