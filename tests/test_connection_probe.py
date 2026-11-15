import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

MODULE = Path(__file__).resolve().parents[1] / 'PowerProfileConnectionProbe.py'
spec = importlib.util.spec_from_file_location('connection_probe', MODULE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ConnectionProbeTests(unittest.TestCase):
    def test_health_check_never_enables_hub_or_executes_controls(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'devices.hub.json'
            config.write_text('{"enabled":false,"rules":[]}', encoding='utf-8')
            worker = Mock()
            worker.devices = [dict(switch=None), dict(switch=dict(siid=2, piid=1))]
            with patch.object(probe, 'Hub', return_value=worker):
                probe.probe(tmp)
            worker.connect.assert_called_once()
            worker.read.assert_called_once()
            worker.schedule.assert_not_called()
            worker.set.assert_not_called()
            worker.requests.assert_not_called()
            worker.publish.assert_not_called()
            result = json.loads((Path(tmp) / '.codex/connection-probe.json').read_text(encoding='utf-8'))
            self.assertEqual(result['phase'], 'connected')
            self.assertEqual(result['controllable'], 1)
            self.assertFalse(json.loads(config.read_text())['enabled'])

    def test_authorization_failure_is_sanitized(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(probe, 'Hub', side_effect=RuntimeError('secret credential fixture')):
                probe.probe(tmp)
            text = (Path(tmp) / '.codex/connection-probe.json').read_text(encoding='utf-8')
            self.assertNotIn('secret', text)
            self.assertEqual(json.loads(text)['phase'], 'error')


if __name__ == '__main__':
    unittest.main()
