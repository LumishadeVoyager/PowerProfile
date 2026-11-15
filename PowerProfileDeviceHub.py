"""Local Xiaomi switch hub and bounded daily guard scheduler (China time)."""
import argparse
import hashlib
import json
import os
import time
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CN = timezone(timedelta(hours=8))
SERVICES = {'light', 'outlet', 'air-purifier', 'air-conditioner', 'fan', 'switch'}
ALL_DAYS = list(range(1, 8))


def is_plug(device):
    return bool(device.get('isPlug') or device.get('computerPower') or '.plug.' in device.get('model', '') or '.acpartner.' in device.get('model', ''))


def require_power_ack(device, value, acknowledged):
    if not value and is_plug(device) and acknowledged is not True:
        raise ValueError('插座断电需要确认供电风险；电脑插座断电不等于正常关机')


def run_at(rule):
    value = datetime.fromisoformat(rule.get('runAt', '').replace('Z', '+00:00'))
    if value.tzinfo is None:
        raise ValueError('单次任务必须包含时区')
    return value.astimezone(CN)


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('w', encoding='utf-8') as stream:
            json.dump(data, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def load(path, default):
    try:
        return json.loads(path.read_text(encoding='utf-8-sig'))
    except FileNotFoundError:
        return default


def validate(config):
    if not isinstance(config, dict) or type(config.get('enabled')) is not bool:
        raise ValueError('中枢配置无效')
    rules = config.get('rules', [])
    if not isinstance(rules, list) or len(rules) > 32:
        raise ValueError('最多支持 32 个设备任务')
    ids = set()
    for rule in rules:
        if not isinstance(rule, dict) or not isinstance(rule.get('id'), str) or not rule['id'] or rule['id'] in ids:
            raise ValueError('任务标识无效或重复')
        ids.add(rule['id'])
        for key in ('did', 'model', 'name'):
            if not isinstance(rule.get(key), str) or not rule[key] or len(rule[key]) > 200:
                raise ValueError('请选择已发现的设备')
        if type(rule.get('enabled')) is not bool or type(rule.get('value')) is not bool:
            raise ValueError('任务状态无效')
        if 'powerRiskAcknowledged' in rule and type(rule['powerRiskAcknowledged']) is not bool:
            raise ValueError('断电确认状态无效')
        if rule.get('mode') not in ('once', 'guard', 'at'):
            raise ValueError('任务类型无效')
        if rule['mode'] == 'at':
            run_at(rule)
            continue
        days = rule.get('days', ALL_DAYS)
        if not isinstance(days, list) or not days or any(type(d) is not int or not 1 <= d <= 7 for d in days) or len(days) != len(set(days)):
            raise ValueError('请选择有效的重复星期')
        start, end = rule.get('startMinute'), rule.get('endMinute')
        if type(start) is not int or not 0 <= start < 1440:
            raise ValueError('开始时间无效')
        if end is not None and (type(end) is not int or not 0 <= end < 1440 or end == start):
            raise ValueError('结束时间应与开始时间不同；持续保持请勾选直到暂停')
    # Opposite rules on the same device must never fight each other.
    for i, first in enumerate(rules):
        for second in rules[i+1:]:
            if rules_conflict(first, second):
                raise ValueError('同一设备存在相反的启用任务，请先暂停其中一个')
    return config


def rule_minutes(rule):
    if rule['mode'] == 'once':
        return {rule['startMinute']}
    if rule.get('endMinute') is None:
        return set(range(1440))  # A latched task can extend into any later day.
    start, end = rule['startMinute'], rule['endMinute']
    return {m for m in range(1440) if (start <= m < end if start < end else m >= start or m < end)}


def guard_active(rule, now, state):
    minute = now.hour * 60 + now.minute
    start, end = rule['startMinute'], rule.get('endMinute')
    if end is None:
        return bool(state.get('latched')) or (now.isoweekday() in rule.get('days', ALL_DAYS) and minute >= start)
    if start < end:
        return now.isoweekday() in rule.get('days', ALL_DAYS) and start <= minute < end
    origin_day = now.isoweekday() if minute >= start else (now-timedelta(days=1)).isoweekday()
    return origin_day in rule.get('days', ALL_DAYS) and (minute >= start or minute < end)


def week_minutes(rule):
    if rule['mode'] == 'guard' and rule.get('endMinute') is None:
        return set(range(10080))
    result = set()
    for day in rule.get('days', ALL_DAYS):
        start = (day-1)*1440+rule['startMinute']
        length = 1 if rule['mode'] == 'once' else (rule['endMinute']-rule['startMinute']) % 1440
        result.update((start+i) % 10080 for i in range(length))
    return result


def rules_conflict(first, second):
    if first['did'] != second['did'] or first['value'] == second['value'] or not first['enabled'] or not second['enabled']:
        return False
    if first['mode'] == 'at' and second['mode'] == 'at':
        return int(run_at(first).timestamp()//60) == int(run_at(second).timestamp()//60)
    if first['mode'] == 'at' or second['mode'] == 'at':
        dated, repeating = (first, second) if first['mode'] == 'at' else (second, first)
        point = run_at(dated)
        return (point.isoweekday()-1)*1440+point.hour*60+point.minute in week_minutes(repeating)
    return bool(week_minutes(first) & week_minutes(second))


def switch_property(spec):
    candidates = []
    for service in spec.get('services', []):
        if service.get('type', '').split(':')[3:4] and service['type'].split(':')[3] in SERVICES:
            for prop in service.get('properties', []):
                if prop.get('type', '').split(':')[3:4] == ['on'] and prop.get('format') == 'bool' and {'read', 'write'} <= set(prop.get('access', [])) and type(service.get('iid')) is int and type(prop.get('iid')) is int and service['iid'] > 0 and prop['iid'] > 0:
                    candidates.append({'siid': service['iid'], 'piid': prop['iid']})
    return candidates[0] if len(candidates) == 1 else None


def value_from(result, target):
    rows = result if isinstance(result, list) else [result]
    for row in rows:
        if isinstance(row, dict) and str(row.get('did')) == target['did'] and row.get('siid') == target['switch']['siid'] and row.get('piid') == target['switch']['piid']:
            if type(row.get('code')) is int and row['code'] == 0 and type(row.get('value')) is bool:
                return row['value']
    raise ValueError('设备未返回有效开关状态；不将离线视为关闭')


class Hub:
    def __init__(self, root=ROOT, api=None):
        self.root = Path(root)
        self.private = self.root / '.codex' / 'device-hub'
        self.config_path = self.root / 'devices.hub.json'
        self.status_path = self.private / 'status.json'
        self.runtime_path = self.private / 'runtime.json'
        self.api = api
        self.devices = []
        self.events = []
        self.runtime = load(self.runtime_path, {})
        self.config = {'enabled': False, 'rules': []}
        self.message = '设备中枢等待连接'
        self.last_discovery = 0
        self.last_check = 0
        self.auth_stamp = None
        self.retry_after = 0
        self.last_minute = None
        self.last_publish = 0
        self.published = None

    def event(self, message):
        self.events.append({'at': datetime.now(CN).isoformat(), 'message': message})
        self.events = self.events[-60:]

    def publish(self):
        body = {'pid': os.getpid(), 'codeVersion': 2,
            'message': self.message, 'devices': self.devices, 'events': self.events[-12:],
            'rules': self.runtime, 'enabled': self.config['enabled']}
        digest = json.dumps(body, sort_keys=True)
        if digest == self.published and time.monotonic()-self.last_publish < 15:
            return
        body['observedAt'] = datetime.now(timezone.utc).isoformat()
        atomic(self.status_path, body)
        self.published = digest
        self.last_publish = time.monotonic()

    def connect(self):
        from PowerProfileCloudHistory import client
        stamp = (self.root / '.codex' / 'energy-cloud-auth.bin').stat().st_mtime_ns
        if self.api is None or self.auth_stamp != stamp:
            self.api = client()
            self.auth_stamp = stamp
        if not self.api.auth_data:
            raise ValueError('请先在米家历史窗口扫码授权')

    def discover(self):
        import requests
        rows = self.api.get_devices_list()
        devices = []
        energy = load(self.root / 'energy.settings.json', {})
        computer_id = str(energy.get('DeviceId') or '')
        for row in rows:
            device = {k: str(row.get(k, '')) for k in ('did', 'name', 'model')}
            device.update(online=bool(row.get('isOnline')), switch=None, state=None, observedAt=None, message='只读设备 / 无通用开关')
            device.update(computerPower=(device['did'] == computer_id), isPlug=is_plug(device))
            if row.get('spec_type', '').split(':')[3:4] and row['spec_type'].split(':')[3] in SERVICES:
                try:
                    urn = row['spec_type']
                    cache = self.private / 'specs' / (hashlib.sha256(urn.encode()).hexdigest() + '.json')
                    spec = load(cache, None)
                    if spec is None:
                        response = requests.get('https://miot-spec.org/miot-spec-v2/instance', params={'type': urn}, timeout=10)
                        response.raise_for_status()
                        spec = response.json()
                        if spec.get('type') != urn:
                            raise ValueError('规格型号不匹配')
                        atomic(cache, spec)
                    if spec.get('type') != urn:
                        raise ValueError('缓存规格型号不匹配')
                    device['switch'] = switch_property(spec)
                    device['isPlug'] = device['isPlug'] or any(s.get('type', '').split(':')[3:4] == ['outlet'] for s in spec.get('services', []))
                    if device['switch']:
                        device['message'] = '等待读取'
                except Exception:
                    device['message'] = '规格读取失败 · 稍后刷新重试'
            devices.append(device)
        self.devices = devices
        self.last_discovery = time.monotonic()
        self.message = '米家设备已同步'

    def target(self, did, model):
        device = next((d for d in self.devices if d['did'] == did and d['model'] == model), None)
        if not device or not device['switch']:
            raise ValueError('设备身份或可写开关属性未验证')
        return device

    @staticmethod
    def prop(device):
        return dict(did=device['did'], **device['switch'])

    def read(self):
        targets = [d for d in self.devices if d['switch']]
        if not targets:
            return
        try:
            rows = self.api.get_devices_prop([self.prop(d) for d in targets])
            for device in targets:
                try:
                    device['state'] = value_from(rows, device)
                    device['message'] = '开启' if device['state'] else '关闭'
                    device['observedAt'] = datetime.now(timezone.utc).isoformat()
                except ValueError:
                    device['state'] = None
                    device['message'] = '读取失败 / 设备离线'
        except Exception:
            for device in targets:
                device['state'] = None
                device['message'] = '连接失败 · 状态未知'
            raise

    def set(self, device, desired):
        if type(desired) is not bool:
            raise ValueError('开关命令必须为布尔值')
        result = self.api.set_devices_prop(dict(self.prop(device), value=desired))
        rows = result if isinstance(result, list) else [result]
        if not any(str(r.get('did')) == device['did'] and r.get('siid') == device['switch']['siid'] and r.get('piid') == device['switch']['piid'] and type(r.get('code')) is int and r['code'] in (0, 1) for r in rows):
            raise ValueError('设备未确认指令')
        actual = value_from(self.api.get_devices_prop(self.prop(device)), device)
        if actual != desired:
            raise ValueError('指令已发送，但开关读回不一致')
        device.update(state=actual, message='开启' if actual else '关闭', observedAt=datetime.now(timezone.utc).isoformat())

    def schedule(self, now):
        today = now.date().isoformat()
        minute = now.hour * 60 + now.minute
        active_ids = {r['id'] for r in self.config['rules'] if r['enabled']}
        for key in list(self.runtime):
            if key not in active_ids:
                self.runtime.pop(key)
        for rule in self.config['rules']:
            if not rule['enabled']:
                continue
            state = self.runtime.setdefault(rule['id'], {})
            # Editing a task invalidates its old latch and previous command result.
            fingerprint = json.dumps(rule, sort_keys=True)
            if state.get('fingerprint') != fingerprint:
                completed = rule['mode'] == 'at' and state.get('completed') and state.get('scheduledAt') == rule.get('runAt')
                previous_message = state.get('message', '单次任务已完成')
                state.clear()
                state['fingerprint'] = fingerprint
                if rule['mode'] == 'at':
                    state['scheduledAt'] = rule['runAt']
                    if completed:
                        state.update(completed=True, message=previous_message, active=False)
            if rule['mode'] == 'at':
                if state.get('completed'):
                    continue
                delay = (now-run_at(rule)).total_seconds()
                if delay < 0:
                    state.update(message='等待单次执行时间', active=False)
                    continue
                if delay > 120:
                    state.update(completed=True, message='已错过时间 · 未补执行', active=False)
                    continue
                due = True
            elif rule['mode'] == 'guard':
                active = guard_active(rule, now, state)
                if not active:
                    state.update(message='等待生效时段', active=False, entered=False)
                    continue
                if rule.get('endMinute') is None:
                    state['latched'] = True
                due = not state.get('entered') or (now.timestamp()-state.get('lastCommand', 0)) >= 300
            else:
                if now.isoweekday() not in rule.get('days', ALL_DAYS):
                    state.update(message='等待所选星期', active=False)
                    continue
                active = minute >= rule['startMinute'] and state.get('executedDay') != today
                if not active:
                    continue
                if minute-rule['startMinute'] > 10:
                    state.update(executedDay=today, message='已错过时间 · 未补执行', active=False)
                    continue
                due = True
            state['active'] = True
            try:
                device = self.target(rule['did'], rule['model'])
                try:
                    require_power_ack(device, rule['value'], rule.get('powerRiskAcknowledged'))
                except ValueError:
                    state.update(message='请编辑任务并确认插座断电风险', active=False, entered=False)
                    continue
                if device['state'] is None:
                    # Still send the fixed desired value, then require an actual readback.
                    due = True
                if due or device['state'] != rule['value']:
                    self.set(device, rule['value'])
                    state['lastCommand'] = now.timestamp()
                    self.event(rule['name']+'：指令确认并已读回')
                state.update(entered=True, message='保持关闭 · 已读回' if not rule['value'] else '保持开启 · 已读回', lastVerified=now.isoformat())
                if rule['mode'] == 'once':
                    state.update(executedDay=today, message='今日已执行并读回', active=False)
                elif rule['mode'] == 'at':
                    state.update(completed=True, message='单次任务已执行并读回', active=False)
            except Exception:
                state.update(message='执行或读回失败 · 下次检查重试', entered=False)
        atomic(self.runtime_path, self.runtime)

    def requests(self, now):
        for path in sorted((self.private / 'queue').glob('*.json'))[:20]:
            try:
                request = load(path, {})
                stamp = datetime.fromisoformat(request.get('createdAt', '').replace('Z', '+00:00'))
                age = (now-stamp).total_seconds()
                if stamp.tzinfo is None or not 0 <= age <= 120:
                    raise ValueError('操作请求已过期，请重新操作')
                if request.get('action') == 'refresh':
                    self.discover()
                    self.read()
                elif request.get('action') == 'set':
                    device = self.target(request.get('did'), request.get('model'))
                    value = request.get('value')
                    if type(value) is not bool:
                        raise ValueError('无效开关值')
                    require_power_ack(device, value, request.get('powerRiskAcknowledged'))
                    for rule in self.config['rules']:
                        if rule['enabled'] and rule['mode'] == 'guard' and rule['did'] == device['did'] and rule['value'] != value and guard_active(rule, now, self.runtime.get(rule['id'], {})):
                            raise ValueError('请先暂停该设备的保持状态任务')
                    self.set(device, value)
                    self.event(device['name']+'：手动指令已读回')
                else:
                    raise ValueError('不支持的操作')
                self.message = '设备操作完成'
            except ValueError as exc:
                self.message = str(exc)
                self.event(self.message)
            except Exception:
                self.message = '设备操作失败 · 检查网络、网关或重新授权'
                self.event(self.message)
            finally:
                path.unlink(missing_ok=True)

    def run(self):
        import msvcrt
        self.private.mkdir(parents=True, exist_ok=True)
        (self.private / 'queue').mkdir(exist_ok=True)
        with (self.private / 'worker.lock').open('a+b') as lock:
            if lock.tell() == 0:
                lock.write(b'0'); lock.flush()
            lock.seek(0)
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                return
            while True:
                now = datetime.now(CN)
                try:
                    self.config = validate(load(self.config_path, {'enabled': False, 'rules': []}))
                    if not self.config['enabled']:
                        self.message = '设备中枢已暂停；不会执行设备任务'
                    elif time.monotonic() >= self.retry_after:
                        self.connect()
                        if not self.devices or time.monotonic()-self.last_discovery >= 3600:
                            self.message = '正在同步米家设备…';self.publish();self.discover()
                        self.requests(now)
                        if time.monotonic()-self.last_check >= 30 or self.last_minute != (now.hour, now.minute):
                            self.last_check = time.monotonic()
                            self.last_minute = (now.hour, now.minute)
                            self.read()
                            self.config = validate(load(self.config_path, {'enabled': False, 'rules': []}))
                            if self.config['enabled']:
                                self.schedule(datetime.now(CN))
                            self.message = '设备中枢运行中 · 每 30 秒检查状态'
                except ValueError as exc:
                    self.message = str(exc)
                    self.retry_after = time.monotonic()+30
                except Exception:
                    self.message = '连接失败 · 检查网络 / 网关，或在米家历史重新扫码授权'
                    self.retry_after = time.monotonic()+30
                    for device in self.devices:
                        device.update(state=None, message='状态未知 · 连接异常')
                self.publish()
                time.sleep(2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=ROOT)
    Hub(parser.parse_args().root).run()
