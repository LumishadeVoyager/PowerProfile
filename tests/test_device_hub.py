import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timedelta

MODULE = Path(__file__).resolve().parents[1] / 'PowerProfileDeviceHub.py'
spec = importlib.util.spec_from_file_location('hub', MODULE)
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)


def rule(**values):
    result = dict(id='night', name='Night light', did='light-1', model='test.light.v1', enabled=True,
                  value=False, mode='guard', startMinute=0, endMinute=420)
    result.update(values)
    return result


class FakeAPI:
    def __init__(self):
        self.value = False
        self.commands = []
        self.bad_read = False
        self.bad_ack = False

    def get_devices_prop(self, data):
        data = data[0] if isinstance(data, list) else data
        return dict(data, code=-1 if self.bad_read else 0, value=self.value)

    def set_devices_prop(self, data):
        self.commands.append(data['value'])
        if not self.bad_ack:
            self.value = data['value']
        return dict(data, code=-1 if self.bad_ack else 0)


class HubTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.api = FakeAPI()
        self.worker = hub.Hub(self.tmp.name, api=self.api)
        self.target = dict(did='light-1', name='Light', model='test.light.v1', switch=dict(siid=2, piid=1), state=False)
        self.worker.devices = [self.target]
        self.worker.config = hub.validate(dict(enabled=True, rules=[rule()]))
        self.now = datetime(2026, 11, 15, 0, 0, tzinfo=hub.CN)

    def test_midnight_enters_and_reopened_light_is_closed_again(self):
        self.worker.schedule(self.now)
        self.assertEqual(self.api.commands, [False])
        self.target['state'] = self.api.value = True
        self.worker.schedule(self.now+timedelta(seconds=30))
        self.assertEqual(self.api.commands, [False, False])
        self.assertFalse(self.target['state'])
        self.worker.schedule(self.now+timedelta(hours=7))
        self.assertEqual(len(self.api.commands), 2)
        self.assertFalse(self.worker.runtime['night']['active'])

    def test_repeated_closed_reads_do_not_spam_commands_but_force_refresh(self):
        self.worker.schedule(self.now)
        self.worker.schedule(self.now+timedelta(seconds=30))
        self.assertEqual(len(self.api.commands), 1)
        self.worker.schedule(self.now+timedelta(minutes=5))
        self.assertEqual(len(self.api.commands), 2)

    def test_midnight_crossing_window(self):
        task = rule(startMinute=1380, endMinute=420)
        self.assertTrue(hub.guard_active(task, self.now, {}))
        self.assertFalse(hub.guard_active(task, self.now.replace(hour=12), {}))

    def test_until_pause_latches_and_disabling_clears_latch(self):
        self.worker.config['rules'] = [rule(startMinute=60, endMinute=None)]
        self.worker.schedule(self.now)
        self.assertFalse(self.api.commands)
        self.worker.schedule(self.now.replace(hour=1))
        self.worker.schedule(self.now+timedelta(days=1))
        self.assertTrue(self.worker.runtime['night']['latched'])
        self.worker.config['rules'][0]['enabled'] = False
        self.worker.schedule(self.now+timedelta(days=1, minutes=1))
        self.assertNotIn('night', self.worker.runtime)

    def test_failed_ack_or_readback_never_reports_success(self):
        self.api.bad_ack = True
        self.worker.schedule(self.now)
        self.assertNotIn('lastVerified', self.worker.runtime['night'])
        self.api.bad_ack = False
        self.api.bad_read = True
        self.worker.schedule(self.now+timedelta(seconds=30))
        self.assertNotIn('lastVerified', self.worker.runtime['night'])

    def test_daily_one_shot_persists_and_missed_tasks_are_not_run_late(self):
        self.worker.config['rules'] = [rule(mode='once')]
        self.worker.schedule(self.now)
        self.worker.runtime = hub.load(self.worker.runtime_path, {})
        self.worker.schedule(self.now+timedelta(seconds=30))
        self.assertEqual(len(self.api.commands), 1)
        self.worker.schedule(self.now+timedelta(days=1, hours=3))
        self.assertEqual(len(self.api.commands), 1)
        self.assertIn('错过', self.worker.runtime['night']['message'])

    def test_identity_and_computer_plug_are_protected(self):
        with self.assertRaises(ValueError):
            self.worker.target('other-device', 'test.light.v1')
        with self.assertRaises(ValueError):
            hub.validate(dict(enabled=True, rules=[rule(model='cuco.plug.v3')]))

    def test_opposing_overlapping_rules_rejected_but_daytime_once_allowed(self):
        with self.assertRaises(ValueError):
            hub.validate(dict(enabled=True, rules=[rule(), rule(id='on', value=True, mode='once', startMinute=120)]))
        hub.validate(dict(enabled=True, rules=[rule(), rule(id='on', value=True, mode='once', startMinute=480)]))

    def test_unsupported_or_ambiguous_spec_is_read_only(self):
        prop = dict(iid=1, type='urn:miot-spec-v2:property:on:00000006:x:1', format='bool', access=['read', 'write'])
        service = dict(iid=2, type='urn:miot-spec-v2:service:light:00007802:x:1', properties=[prop])
        self.assertEqual(hub.switch_property(dict(services=[service])), dict(siid=2, piid=1))
        self.assertIsNone(hub.switch_property(dict(services=[service, service])))

    def test_stale_manual_requests_never_execute_later(self):
        queue = self.worker.private / 'queue'
        queue.mkdir(parents=True)
        hub.atomic(queue / 'old.json', dict(action='set', did='light-1', model='test.light.v1', value=True, createdAt=(self.now-timedelta(minutes=5)).isoformat()))
        self.worker.requests(self.now)
        self.assertFalse(self.api.commands)
        self.assertFalse(list(queue.glob('*.json')))

    def test_manual_on_is_blocked_during_off_guard(self):
        queue = self.worker.private / 'queue';queue.mkdir(parents=True)
        hub.atomic(queue / 'on.json', dict(action='set', did='light-1', model='test.light.v1', value=True, createdAt=self.now.isoformat()))
        self.worker.requests(self.now)
        self.assertFalse(self.api.commands)


if __name__ == '__main__':
    unittest.main()
