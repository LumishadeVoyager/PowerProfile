import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
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
            hub.require_power_ack(dict(model='cuco.plug.v3'), False, None)

    def test_plug_off_requires_ack_but_same_model_is_not_read_only(self):
        self.target.update(model='cuco.plug.v3', isPlug=True, computerPower=True)
        task = rule(model='cuco.plug.v3', mode='once', powerRiskAcknowledged=True)
        self.worker.config = hub.validate(dict(enabled=True, rules=[task]))
        self.assertIs(self.worker.target('light-1', 'cuco.plug.v3'), self.target)
        self.worker.schedule(self.now)
        self.assertEqual(self.api.commands, [False])
        self.worker.config['rules'][0].pop('powerRiskAcknowledged')
        self.worker.runtime.clear()
        self.worker.schedule(self.now)
        self.assertEqual(self.api.commands, [False])
        self.assertNotIn('lastVerified', self.worker.runtime['night'])

    def test_manual_plug_off_cannot_bypass_risk_confirmation(self):
        self.target.update(model='cuco.plug.v3', isPlug=True)
        self.worker.config['rules'] = []
        queue = self.worker.private / 'queue';queue.mkdir(parents=True)
        request = dict(action='set', did='light-1', model='cuco.plug.v3', value=False, createdAt=self.now.isoformat())
        hub.atomic(queue / 'off.json', request);self.worker.requests(self.now)
        self.assertFalse(self.api.commands)
        request['powerRiskAcknowledged'] = True
        hub.atomic(queue / 'off.json', request);self.worker.requests(self.now)
        self.assertEqual(self.api.commands, [False])

    def test_legacy_unconfirmed_plug_task_does_not_block_other_devices(self):
        plug = dict(self.target, did='plug', model='lumi.acpartner.mcn02', isPlug=True)
        self.worker.devices.append(plug)
        self.worker.config = hub.validate(dict(enabled=True, rules=[rule(id='plug', did='plug', model=plug['model']), rule()]))
        self.worker.schedule(self.now)
        self.assertIn('确认', self.worker.runtime['plug']['message'])
        self.assertEqual(self.api.commands, [False])
        self.assertIn('lastVerified', self.worker.runtime['night'])

    def test_discovery_marks_only_matching_device_as_computer_plug(self):
        urn = 'urn:miot-spec-v2:device:outlet:0000A002:test:1'
        prop = dict(iid=1, type='urn:miot-spec-v2:property:on:00000006:x:1', format='bool', access=['read', 'write'])
        spec = dict(type=urn, services=[dict(iid=2, type='urn:miot-spec-v2:service:outlet:00007802:x:1', properties=[prop])])
        cache = self.worker.private / 'specs' / (hub.hashlib.sha256(urn.encode()).hexdigest()+'.json')
        hub.atomic(cache, spec)
        hub.atomic(self.worker.root / 'energy.settings.json', dict(DeviceId='plug-a'))
        self.api.get_devices_list = lambda: [dict(did=d, name=d, model='cuco.plug.v3', isOnline=True, spec_type=urn) for d in ('plug-a', 'plug-b')]
        with patch.dict('sys.modules', requests=SimpleNamespace()):
            self.worker.discover()
        self.assertTrue(self.worker.devices[0]['computerPower'])
        self.assertFalse(self.worker.devices[1]['computerPower'])
        for device in self.worker.devices:
            self.assertTrue(device['isPlug'])
            self.assertEqual(device['switch'], dict(siid=2, piid=1))

    def test_selected_weekdays_and_cross_midnight_origin_day(self):
        monday = self.now.replace(day=16, hour=23)
        task = rule(startMinute=1380, endMinute=420, days=[1])
        self.assertTrue(hub.guard_active(task, monday, {}))
        self.assertTrue(hub.guard_active(task, monday+timedelta(hours=2), {}))
        self.assertFalse(hub.guard_active(task, monday+timedelta(days=1), {}))
        self.worker.config['rules'] = [rule(mode='once', days=[1])]
        self.worker.schedule(self.now)
        self.assertFalse(self.api.commands)
        self.worker.schedule(self.now+timedelta(days=1))
        self.assertEqual(self.api.commands, [False])

    def test_dated_countdown_fires_once_and_persists_after_restart(self):
        task = rule(mode='at', runAt=(self.now+timedelta(minutes=30)).isoformat())
        self.worker.config = hub.validate(dict(enabled=True, rules=[task]))
        self.worker.schedule(self.now)
        self.assertFalse(self.api.commands)
        self.worker.schedule(self.now+timedelta(minutes=30, seconds=15))
        self.assertEqual(self.api.commands, [False])
        self.worker.runtime = hub.load(self.worker.runtime_path, {})
        self.worker.schedule(self.now+timedelta(minutes=31))
        self.assertEqual(self.api.commands, [False])
        self.assertTrue(self.worker.runtime['night']['completed'])
        self.worker.config['rules'][0]['revision'] = 'after-pause-resume'
        self.worker.schedule(self.now+timedelta(minutes=31, seconds=15))
        self.assertEqual(self.api.commands, [False])

    def test_dated_overdue_task_does_not_cut_power_after_wake(self):
        self.worker.config['rules'] = [rule(mode='at', runAt=self.now.isoformat())]
        self.worker.schedule(self.now+timedelta(minutes=3))
        self.assertFalse(self.api.commands)
        self.assertTrue(self.worker.runtime['night']['completed'])
        self.assertIn('错过', self.worker.runtime['night']['message'])

    def test_weekly_and_dated_conflicts_respect_actual_days(self):
        night = rule(days=[1], startMinute=1380, endMinute=420)
        monday_on = rule(id='on', mode='once', days=[1], startMinute=120, value=True)
        tuesday_on = dict(monday_on, days=[2])
        self.assertFalse(hub.rules_conflict(night, monday_on))
        self.assertTrue(hub.rules_conflict(night, tuesday_on))
        dated = rule(id='dated', mode='at', value=True, runAt='2026-11-17T02:00:00+08:00')
        self.assertTrue(hub.rules_conflict(night, dated))
        dated['runAt'] = '2026-11-16T02:00:00+08:00'
        self.assertFalse(hub.rules_conflict(night, dated))

    def test_invalid_days_or_unzoned_dates_rejected(self):
        for values in (dict(days=[]), dict(days=[0]), dict(days=[True]), dict(days=[1, 1]), dict(days=[{}]), dict(mode='at', runAt='2026-11-15T01:00:00')):
            with self.assertRaises(ValueError):
                hub.validate(dict(enabled=True, rules=[rule(**values)]))

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

    def test_operation_feedback_distinguishes_ack_and_actual_readback(self):
        self.worker.config['rules'] = []
        queue = self.worker.private / 'queue';queue.mkdir(parents=True)
        phases = []
        original = self.worker.operation
        def observe(ident, phase, message):
            phases.append(phase)
            original(ident, phase, message)
        self.worker.operation = observe
        hub.atomic(queue / 'success.json', dict(action='set', did='light-1', model='test.light.v1', value=True, createdAt=self.now.isoformat()))
        self.worker.requests(self.now)
        self.assertEqual(phases, ['sending', 'checking', 'confirmed'])
        self.assertEqual(self.worker.operations['success']['phase'], 'confirmed')
        phases.clear();self.api.bad_read = True
        hub.atomic(queue / 'failure.json', dict(action='set', did='light-1', model='test.light.v1', value=False, createdAt=self.now.isoformat()))
        self.worker.requests(self.now)
        self.assertEqual(phases, ['sending', 'checking', 'failed'])
        self.assertEqual(hub.load(self.worker.operations_path, {})['failure']['phase'], 'failed')

    def test_restart_never_claims_inflight_operation_succeeded(self):
        self.worker.operation('unfinished', 'checking', 'waiting')
        restarted = hub.Hub(self.tmp.name, api=self.api)
        self.assertEqual(restarted.operations['unfinished']['phase'], 'failed')
        self.assertFalse(self.api.commands)

    def test_paused_hub_allows_read_only_refresh_but_never_switches(self):
        self.worker.config['enabled'] = False
        self.worker.discover = lambda: None
        self.worker.read = lambda: None
        queue = self.worker.private / 'queue';queue.mkdir(parents=True)
        hub.atomic(queue / 'refresh.json', dict(action='refresh', createdAt=self.now.isoformat()))
        self.worker.requests(self.now)
        self.assertEqual(self.worker.operations['refresh']['phase'], 'confirmed')
        hub.atomic(queue / 'switch.json', dict(action='set', did='light-1', model='test.light.v1', value=True, createdAt=self.now.isoformat()))
        self.worker.requests(self.now)
        self.assertEqual(self.worker.operations['switch']['phase'], 'failed')
        self.assertFalse(self.api.commands)
        self.assertFalse(self.worker.config['enabled'])


if __name__ == '__main__':
    unittest.main()
