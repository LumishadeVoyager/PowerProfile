"""Explicit read-only cloud health check. Never processes rules or queue actions."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
from PowerProfileDeviceHub import Hub, atomic


def probe(root):
    target = Path(root) / '.codex' / 'connection-probe.json'
    atomic(target, dict(phase='checking', message='正在验证云端授权与设备读取'))
    try:
        worker = Hub(root)
        worker.connect()
        worker.discover()
        worker.read()
        result = dict(phase='connected', message='云端授权与设备读取通过', devices=len(worker.devices),
                      controllable=sum(bool(d['switch']) for d in worker.devices),
                      observedAt=datetime.now(timezone.utc).isoformat())
    except Exception:
        result = dict(phase='error', message='云端验证失败：检查网络、米家区域或重新扫码授权；没有启用或执行设备任务。',
                      observedAt=datetime.now(timezone.utc).isoformat())
    atomic(target, result)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent)
    probe(parser.parse_args().root)
