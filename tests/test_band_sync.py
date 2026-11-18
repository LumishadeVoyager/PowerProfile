import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from datetime import datetime, timezone
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('band', Path(__file__).resolve().parents[1]/'PowerProfileBand.py')
band = importlib.util.module_from_spec(spec); spec.loader.exec_module(band)

class BandTests(unittest.TestCase):
    def test_snapshot_matches_merged_ledgers_and_beijing_midnight(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def write(name, data): (root/name).write_text(json.dumps(data))
            write('energy.history.json', {'Days': {'2026-11-19': {'Seconds': 100, 'GameSeconds': 30, 'KWh': .2}}})
            write('usage.logs.history.json', {'Days': {'2026-11-19': {'Seconds': 70, 'GameSeconds': 50}}})
            write('ai.snapshot.json', {'combinedDaily': [{'date': '2026-11-19', 'tokens': 42}]})
            result = band.snapshot(root, now=datetime(2026,11,18,16,0,1,tzinfo=timezone.utc))
            self.assertEqual(result['day'], '2026-11-19')
            self.assertEqual(result['usageSeconds']['value'], 100)
            self.assertEqual(result['gameSeconds']['value'], 50)
            self.assertEqual(result['aiTokens']['value'], 42)
            self.assertNotIn(directory, json.dumps(result))
            self.assertIsNone(band.snapshot(root/'missing')['usageSeconds']['value'])

    def test_quota_matches_real_window_and_unknown_is_not_zero(self):
        q = band.normalize_quota({'rateLimits': {'primary': {'windowDurationMins':300,'usedPercent':25,'resetsAt':1800000000},'secondary': {'windowDurationMins':1440,'usedPercent':10,'resetsAt':1800000000}}})
        self.assertEqual(q['fiveHour']['remainingPercent'], 75)
        self.assertIsNone(q['weekly'])

    def test_completion_restart_partial_line_and_ack(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); now=band.time.time()
            folder=root/datetime.fromtimestamp(now,timezone.utc).strftime('%Y/%m/%d'); folder.mkdir(parents=True)
            file=folder/'test.jsonl'; file.write_text('{}\n')
            events=band.Events(root/'events.sqlite'); events.scan(root)
            event=json.dumps({'timestamp':band.stamp(now+1),'type':'event_msg','payload':{'type':'task_complete','text':'PRIVATE'}})
            with file.open('a') as stream: stream.write(event)
            events.scan(root, now+2); self.assertEqual(events.pending(), [])
            with file.open('a') as stream: stream.write('\n')
            events.scan(root, now+2); rows=events.pending(); self.assertEqual(len(rows),1)
            events.db.close(); events=band.Events(root/'events.sqlite'); events.scan(root,now+3)
            self.assertEqual(events.pending(),rows)
            self.assertNotIn('PRIVATE',json.dumps(rows))
            events.ack([rows[0]['id']]); self.assertEqual(events.pending(),[]); events.db.close()

    def test_signed_origin_config_cannot_disable_tls_or_add_token_to_url(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'config.json'
            for endpoint in ['http://relay.example','https://127.0.0.1','https://relay.local','https://relay.example/path','https://user:password@relay.example','https://relay.example?token=secret']:
                file.write_text(json.dumps({'endpoint':endpoint,'pcToken':'a'*64}))
                with self.assertRaises(ValueError): band.config(file)
            file.write_text(json.dumps({'endpoint':'https://relay.example','pcToken':'a'*64}))
            self.assertEqual(band.config(file)['endpoint'],'https://relay.example')

    def test_unrelated_ack_cannot_retire_pending_events(self):
        class Reply:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self,limit): return json.dumps({'accepted':True,'ackedIds':['b'*64]}).encode()
        with patch.object(band.urllib.request,'build_opener') as opener:
            opener.return_value.open.return_value=Reply()
            ids,_=band.publish({'endpoint':'https://relay.example','pcToken':'a'*64},{},[{'id':'c'*64}])
            self.assertEqual(ids,[])
            req=opener.return_value.open.call_args.args[0]
            self.assertNotIn('pcToken',req.data.decode())

if __name__=='__main__': unittest.main()
