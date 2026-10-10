import sys
import unittest
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
from datetime import datetime, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PowerProfileCloudHistory import normalize
import PowerProfileCloudHistory as helper

class HistoryTests(unittest.TestCase):
    def test_china_midnight_and_skip_unfinished_today(self):
        rows = [{'time': 1767283200, 'value': '[150]'}, {'time':1767196800, 'value':'[0]'}]
        days = normalize(rows, .01, datetime(2026, 1, 2, 4, tzinfo=timezone.utc))
        self.assertNotIn('2026-01-02', days)
        self.assertEqual(days['2026-01-01']['KWh'], 0)
    def test_scaling_and_duplicates(self):
        row={'time':1767196800,'value':'[150]'}
        days=normalize([row,row],.01,datetime(2026,1,3,tzinfo=timezone.utc))
        self.assertEqual(len(days),1)
        self.assertEqual(days['2026-01-01']['KWh'],1.5)
    def test_bad_statistics(self):
        for value in ('[-1]','[NaN]','[10000]','[true]','[1,2]'):
            with self.assertRaises(ValueError):
                normalize([{'time':1767196800,'value':value}],1,datetime(2026,1,3,tzinfo=timezone.utc))

    def test_login_refresh_uses_distinct_images_and_cleans_up(self):
        images = []
        api = SimpleNamespace(_get_qr_login_data=lambda: {'loginUrl':'fixture'},
            _complete_qr_login=lambda data: None)
        def record(phase, message, **extra):
            if phase == 'scan':
                image = Path(extra['image'])
                self.assertTrue(image.exists())
                images.append(image)
        fake_qrcode = SimpleNamespace(make=lambda value: SimpleNamespace(
            save=lambda path: Path(path).write_bytes(b'fixture')))
        with tempfile.TemporaryDirectory() as directory, patch.object(helper, 'PRIVATE', Path(directory)), \
             patch.object(helper, 'client', return_value=api), patch.object(helper, 'status', side_effect=record), \
             patch.dict(sys.modules, {'qrcode': fake_qrcode}):
            helper.run(SimpleNamespace(action='login'))
            helper.run(SimpleNamespace(action='login'))
            self.assertNotEqual(images[0], images[1])
            self.assertFalse(any(image.exists() for image in images))

if __name__=='__main__': unittest.main()
