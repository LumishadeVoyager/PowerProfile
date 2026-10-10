"""On-demand Xiaomi history helper. No power control and no background service."""
import argparse
import ctypes
import json
import logging
import math
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PRIVATE = ROOT / '.codex'
STATUS = PRIVATE / 'energy-cloud-status.json'
CN = timezone(timedelta(hours=8))


def atomic(path, data):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
    os.replace(temporary, path)


def status(phase, message, **extra):
    atomic(STATUS, dict(phase=phase, message=message, **extra))


def protect(data, decrypt=False):
    from ctypes import wintypes
    class Blob(ctypes.Structure):
        _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]
    buffer = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    source, target = Blob(len(data), buffer), Blob()
    crypt = ctypes.WinDLL('crypt32', use_last_error=True)
    if decrypt:
        ok = crypt.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target))
    else:
        ok = crypt.CryptProtectData(ctypes.byref(source), 'PowerProfile Xiaomi history', None, None, None, 1, ctypes.byref(target))
    if not ok:
        raise RuntimeError('Windows credential protection failed')
    try:
        return ctypes.string_at(target.data, target.size)
    finally:
        ctypes.windll.kernel32.LocalFree(target.data)


def client():
    # pythonw has no console streams; dependencies inspect stdout during import.
    if sys.stdout is None:
        sys.stdout = open(os.devnull, 'w', encoding='utf-8')
    if sys.stderr is None:
        sys.stderr = open(os.devnull, 'w', encoding='utf-8')
    from mijiaAPI import mijiaAPI
    import requests
    logging.disable(logging.CRITICAL)
    original = requests.Session.request
    def bounded(self, method, url, **kwargs):
        kwargs.setdefault('timeout', 20)
        return original(self, method, url, **kwargs)
    requests.Session.request = bounded

    class PrivateAPI(mijiaAPI):
        def _save_auth_data(self):
            path = PRIVATE / 'energy-cloud-auth.bin'
            temporary = path.with_suffix('.tmp')
            temporary.write_bytes(protect(json.dumps(self.auth_data).encode()))
            os.replace(temporary, path)
    api = PrivateAPI(str(PRIVATE / 'unused-cloud-auth.json'))
    api.locale = 'zh_CN'
    # Never send Xiaomi credentials to the library's alternative API domain.
    api.api_base_url = 'https://api.io.mi.com/app'
    api.service_login_url = 'https://account.xiaomi.com/pass/serviceLogin?_json=true&sid=xiaomiio&_locale=zh_CN'
    auth = PRIVATE / 'energy-cloud-auth.bin'
    if auth.exists():
        api.auth_data = json.loads(protect(auth.read_bytes(), decrypt=True))
        api._init_session()
    return api


def normalize(rows, multiplier, now=None):
    today = (now or datetime.now(CN)).date()
    days = {}
    for row in rows:
        date = datetime.fromtimestamp(int(row['time']), CN).date()
        if date >= today:
            continue  # unfinished today must not replace locally sampled energy
        values = json.loads(row['value']) if isinstance(row['value'], str) else row['value']
        if not isinstance(values, list) or len(values) != 1 or isinstance(values[0], bool):
            raise ValueError('Unsupported daily statistics shape')
        kwh = float(values[0]) * multiplier
        if not math.isfinite(kwh) or kwh < 0 or kwh > 88.32:
            raise ValueError('Daily energy outside plug rating')
        key = date.isoformat()
        if key in days and days[key]['KWh'] != kwh:
            raise ValueError('Conflicting records for the same date')
        days[key] = dict(KWh=kwh, Seconds=0, Source='MiHome')
    return days


def run(args):
    import msvcrt
    lock = open(PRIVATE / 'energy-cloud.lock', 'a+b')
    lock.seek(0)
    if lock.read(1) == b'':
        lock.write(b'0')
        lock.flush()
    lock.seek(0)
    try:
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        return  # another login/query owns the status; do not overwrite it
    api = client()
    if args.action == 'login':
        status('connecting', '正在申请小米登录二维码…')
        data = api._get_qr_login_data()
        if not data.get('refreshed'):
            import qrcode
            image = PRIVATE / 'energy-cloud-login.png'
            qrcode.make(data['loginUrl']).save(image)
            status('scan', '请用米家 App 扫码并确认登录；二维码约两分钟有效', image=str(image))
            api._complete_qr_login(data)
        status('authorized', '小米登录成功，可以查询历史用电。')
        return
    if not api.auth_data:
        status('error', '请先扫码登录小米账号。')
        return
    config = json.loads((ROOT / 'energy.settings.json').read_text(encoding='utf-8-sig'))
    did = str(config.get('DeviceId', 0))
    devices = api.get_devices_list()
    device = next((d for d in devices if str(d.get('did')) == did), None)
    if not device or device.get('model') != 'cuco.plug.v3':
        raise ValueError('Configured plug not present in this Xiaomi account')
    now = int(time.time())
    candidates = []
    # Bounded discovery of daily statistics formats used by Xiaomi plug firmware.
    for key, kind in [('11.1', 'stat_day'), ('11.1', 'stat_day_v3'), ('11.1', 'total_day'), ('powerCost', 'stat_day')]:
        try:
            rows = api.get_statistics(dict(did=did, key=key, data_type=kind,
                time_start=now-86400*365, time_end=now, limit=400))
            if rows:
                if not isinstance(rows, list):
                    continue
                # Some cloud endpoints cap pages below the requested limit.
                for page in range(3):
                    oldest = min(int(r['time']) for r in rows)
                    if oldest <= now-86400*365:
                        break
                    try:
                        older = api.get_statistics(dict(did=did, key=key, data_type=kind,
                            time_start=now-86400*365, time_end=oldest-1, limit=400))
                    except Exception:
                        break  # retain the page already retrieved
                    if not older or not isinstance(older, list) or min(int(r['time']) for r in older) >= oldest:
                        break
                    rows.extend(older)
                candidates.append(dict(key=key, data_type=kind, rows=rows))
        except Exception:
            continue
    if not candidates:
        status('error', '登录有效，但这些历史接口未返回数据；现有用电记录保持不变。')
        return
    atomic(PRIVATE / 'energy-cloud-raw.json', dict(DeviceId=int(did), Model='cuco.plug.v3', candidates=candidates))
    status('fetched', '已获取候选历史。请选择数据源及单位，并与米家核对后导入。')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['login', 'fetch'])
    args = parser.parse_args()
    try:
        run(args)
    except Exception as exc:
        # Exceptions from cloud libraries can contain credentials or raw responses.
        status('error', '查询或登录失败，请重试；可能是网络、授权过期或接口不兼容。', error_type=type(exc).__name__)
