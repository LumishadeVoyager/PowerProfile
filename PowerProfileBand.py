"""Built-in outbound band sync. No listening port or conversation content upload."""
import argparse
import concurrent.futures
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import sqlite3
import subprocess
import threading
import time
from datetime import datetime, timedelta, timezone
import urllib.request
from urllib.parse import urlsplit

UTC = timezone.utc
BJ = timezone(timedelta(hours=8))

def stamp(value=None):
    return datetime.fromtimestamp(time.time() if value is None else value, UTC).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

def read(path, fallback=None):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8-sig'))
    except (OSError, ValueError):
        return fallback

def atomic(path, value):
    path = Path(path)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    os.replace(temporary, path)

def config(path):
    value = read(path, {})
    url = urlsplit(value.get('endpoint', ''))
    if (url.scheme != 'https' or url.username or url.password or url.port not in (None, 443)
        or url.path not in ('', '/') or url.query or url.fragment
        or not re.fullmatch(r'[a-z0-9.-]+\.[a-z]{2,}', url.hostname or '')
        or url.hostname.endswith('.local') or not re.fullmatch('[a-f0-9]{64}', value.get('pcToken', ''))):
        raise ValueError('invalid_relay_config')
    return {'endpoint': 'https://' + url.netloc, 'pcToken': value['pcToken']}

def metric(value, at):
    return {'value': value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else None,
            'source': 'PowerProfile', 'observedAt': at}

def snapshot(root, quota=None, now=None):
    root = Path(root)
    now = now or datetime.now(UTC)
    day = now.astimezone(BJ).strftime('%Y-%m-%d')
    def ledger(name):
        path = root / name
        value = read(path, {})
        try: at = stamp(path.stat().st_mtime)
        except OSError: at = None
        return value, at
    e, ea = ledger('energy.history.json')
    u, ua = ledger('usage.logs.history.json')
    ai, aa = ledger('ai.snapshot.json')
    e, u = e.get('Days', {}).get(day, {}), u.get('Days', {}).get(day, {})
    def coverage(field):
        rows = [metric(e.get(field), ea), metric(u.get(field), ua)]
        return max((r for r in rows if r['value'] is not None), key=lambda r: r['value'], default=metric(None, None))
    rows = [r for r in ai.get('combinedDaily', []) if r.get('date') == day]
    tokens = sum(r['tokens'] for r in rows) if rows and all(metric(r.get('tokens'), None)['value'] is not None for r in rows) else None
    return {'protocol': 1, 'entryId': 'powerprofile', 'type': 'powerprofile_snapshot', 'day': day, 'generatedAt': stamp(now.timestamp()),
            'usageSeconds': coverage('Seconds'), 'energyKWh': metric(e.get('KWh'), ea), 'gameSeconds': coverage('GameSeconds'),
            'aiTokens': metric(tokens, ai.get('updatedAt') or aa), 'quota': quota}

def normalize_quota(result):
    limits = result.get('rateLimits') or {}
    def window(minutes):
        for item in (limits.get('primary'), limits.get('secondary')):
            if not item or item.get('windowDurationMins') != minutes: continue
            used, reset = item.get('usedPercent'), item.get('resetsAt')
            if metric(used, None)['value'] is not None and used <= 100 and isinstance(reset, int) and reset > 0:
                return {'windowMinutes': minutes, 'usedPercent': used, 'remainingPercent': 100-used, 'resetsAt': reset}
        return None
    return {'observedAt': stamp(), 'fiveHour': window(300), 'weekly': window(10080)}

def quota_read(executable):
    child = subprocess.Popen([str(executable), 'app-server', '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, encoding='utf-8', creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    lines = queue.Queue()
    def reader():
        for line in child.stdout: lines.put(line)
        lines.put(None)
    threading.Thread(target=reader, daemon=True).start()
    def send(value): child.stdin.write(json.dumps(value)+'\n'); child.stdin.flush()
    try:
        send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'powerprofile-band', 'version': '1.10.0'}, 'capabilities': {'experimentalApi': True}}})
        deadline = time.monotonic()+20
        while True:
            line = lines.get(timeout=max(.01, deadline-time.monotonic()))
            if line is None: raise ValueError('quota_process_exited')
            try: reply = json.loads(line)
            except ValueError: continue
            if reply.get('error'): raise ValueError('quota_read_failed')
            if reply.get('id') == 1:
                send({'method': 'initialized', 'params': {}})
                send({'id': 2, 'method': 'account/rateLimits/read', 'params': None})
            elif reply.get('id') == 2: return normalize_quota(reply['result'])
    finally:
        child.kill(); child.wait(timeout=5)
        child.stdin.close(); child.stdout.close()

class Events:
    def __init__(self, file):
        self.db = sqlite3.connect(file)
        self.started = time.time()
        self.db.executescript('CREATE TABLE IF NOT EXISTS cursors(file TEXT PRIMARY KEY,offset INTEGER); CREATE TABLE IF NOT EXISTS completions(id TEXT PRIMARY KEY,at TEXT,ack INTEGER DEFAULT 0);')
    def scan(self, root, now=None):
        now = time.time() if now is None else now
        for delta in (1, 0):
            directory = Path(root) / datetime.fromtimestamp(now-delta*86400, UTC).strftime('%Y/%m/%d')
            for file in directory.glob('*.jsonl'):
                try:
                    stat = file.stat()
                    previous = self.db.execute('SELECT offset FROM cursors WHERE file=?', (str(file),)).fetchone()
                    offset = previous[0] if previous else (stat.st_size if stat.st_ctime < self.started else 0)
                    if offset > stat.st_size: offset = 0
                    with file.open('rb') as stream: stream.seek(offset); chunk = stream.read(2*1024*1024)
                    end = chunk.rfind(b'\n')
                    if end >= 0:
                        for line in chunk[:end].split(b'\n'):
                            try:
                                event = json.loads(line)
                                at = datetime.fromisoformat(event['timestamp'].replace('Z', '+00:00')).timestamp()
                                if event.get('type') == 'event_msg' and event.get('payload', {}).get('type') == 'task_complete' and max(now-86400, self.started if not previous else 0) <= at <= now+300:
                                    identity = hashlib.sha256((str(file)+':'+str(offset)).encode()).hexdigest()
                                    self.db.execute('INSERT OR IGNORE INTO completions(id,at) VALUES(?,?)', (identity, stamp(at)))
                            except (ValueError, KeyError, TypeError): pass
                            offset += len(line)+1
                    elif len(chunk) == 2*1024*1024: offset += len(chunk)
                    self.db.execute('INSERT OR REPLACE INTO cursors VALUES(?,?)', (str(file), offset))
                except OSError: continue
        self.db.execute('DELETE FROM completions WHERE at < ?', (stamp(now-86400),)); self.db.commit()
    def pending(self):
        return [dict(zip(('id', 'at'), row)) for row in self.db.execute('SELECT id,at FROM completions WHERE ack=0 ORDER BY at LIMIT 20')]
    def ack(self, ids):
        self.db.executemany('UPDATE completions SET ack=1 WHERE id=?', [(x,) for x in ids]); self.db.commit()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None

def publish(settings, value, events):
    body = json.dumps({'protocol': 1, 'entryId': 'powerprofile', 'snapshot': value, 'events': events}).encode()
    request = urllib.request.Request(settings['endpoint']+'/relay/publish', data=body, headers={'Authorization': 'Bearer '+settings['pcToken'], 'Content-Type': 'application/json', 'User-Agent': 'PowerProfile/1.10.0 BandSync'})
    # Fixed public HTTPS origin; platform CA/hostname validation stays enabled.
    with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=20) as response:
        raw = response.read(200001)
        if len(raw) > 200000: raise ValueError('response_too_large')
        result = json.loads(raw)
    ids = result.get('ackedIds')
    if result.get('accepted') is not True or not isinstance(ids, list) or len(ids) > 20 or any(not isinstance(x, str) or not re.fullmatch('[a-f0-9]{64}', x) for x in ids): raise ValueError('invalid_relay_response')
    # Only a receipt for an event actually in this upload can retire local work.
    allowed = {e['id'] for e in events}
    return [x for x in ids if x in allowed], result.get('report')

class Parent:
    def __init__(self, pid):
        self.pid = pid; self.handle = None
        if os.name == 'nt' and pid:
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.OpenProcess.restype = ctypes.c_void_p
            self.kernel = kernel; self.handle = kernel.OpenProcess(0x100000, False, pid)
    def alive(self):
        if not self.pid: return True
        if os.name == 'nt':
            return bool(self.handle) and self.kernel.WaitForSingleObject(ctypes.c_void_p(self.handle), 0) == 258
        try: os.kill(self.pid, 0); return True
        except OSError: return False

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, default=Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'PowerProfile/band')
    parser.add_argument('--parent-pid', type=int, default=0)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args(); runtime = args.runtime; runtime.mkdir(parents=True, exist_ok=True)
    lock = (runtime/'worker.lock').open('a+b'); lock.seek(0); lock.write(b'0'); lock.flush(); lock.seek(0)
    if os.name == 'nt':
        import msvcrt
        try: msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError: return
    else:
        import fcntl
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError: return
    parent = Parent(args.parent_pid)
    events = Events(runtime/'completions.sqlite')
    codex = Path(os.environ.get('LOCALAPPDATA', ''))/'Programs/OpenAI/Codex/bin/codex.exe'
    quota = None; next_quota = 0; future = None
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    try:
        while parent.alive():
            start = time.monotonic()
            try:
                settings = config(runtime/'config.json')
                if future and future.done():
                    try: quota = future.result()
                    except Exception: pass
                    future = None
                if not future and start >= next_quota:
                    future = executor.submit(quota_read, codex); next_quota = start+60
                events.scan(Path.home()/'.codex/sessions')
                ids, report = publish(settings, snapshot(args.root, quota), events.pending())
                events.ack(ids)
                status = {'online': True, 'uploadedAt': stamp(), 'processId': os.getpid(), 'parentPid': args.parent_pid}
                if isinstance(report, dict):
                    atomic(runtime/'device-latest.json', {k: report.get(k) for k in ('snapshotAt', 'versionCode', 'receivedAt', 'transport')})
            except Exception as error:
                # Never persist exception text, URLs, headers or credentials.
                status = {'online': False, 'attemptedAt': stamp(), 'error': type(error).__name__, 'processId': os.getpid(), 'parentPid': args.parent_pid}
            atomic(runtime/'status.json', status)
            if args.once: break
            while parent.alive() and time.monotonic()-start < 10: time.sleep(.5)
    finally:
        events.db.close(); executor.shutdown(wait=True); lock.close()

if __name__ == '__main__': main()
