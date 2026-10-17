import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('tracking_config', ROOT/'scripts/configure_tracking.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class TrackingConfigurationTests(unittest.TestCase):
    def test_changes_mode_without_modifying_other_properties(self):
        text = '# Config\nvision.minDepthMm=550\ntracking.mode=rgb\n'
        value = module.update_mode(text, 'depth')
        self.assertIn('tracking.mode=depth', value)
        self.assertIn('vision.minDepthMm=550', value)
    def test_prevents_duplicate_keys(self):
        value = module.update_mode('tracking.mode=rgb\ntracking.mode=depth\n', 'rgb')
        self.assertEqual(value.count('tracking.mode='), 1)
    def test_appends_missing_setting(self):
        self.assertIn('tracking.mode=rgb', module.update_mode('key=value\n', 'rgb'))

if __name__ == '__main__': unittest.main()
