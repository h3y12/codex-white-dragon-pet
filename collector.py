"""Read-only Codex telemetry. No inference, key extraction, or account mutations."""
import argparse
import datetime as dt
import json
import math
import tempfile
import os
from pathlib import Path
import queue
import shutil
import sqlite3
import subprocess
import threading
import time

BEIJING = dt.timezone(dt.timedelta(hours=8))


def timestamp(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.timestamp()
    except (ValueError, AttributeError, OverflowError, OSError):
        return 0


def number(value, default=0):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else default


def valid_usage(value):
    if not isinstance(value, dict):
        return None
    fields = ('total_tokens', 'input_tokens', 'output_tokens', 'cached_input_tokens')
    if not any(k in value for k in fields):
        return None
    clean = {k: value[k] for k in fields if k in value and number(value[k], None) is not None}
    return clean or None


class Rollout:
    def __init__(self, path):
        self.path = path
        self.offset = 0
        self.records = {}
        self.legacy = {}
        self.previous_total = 0
        self.has_records = False
        self.session_id = str(path)
        self.active = False
        self.stage = 'working'
        self.last_event = 0
        self.started = 0
        self.pending = {}
        self.rate = None
        self.rate_time = 0
        self.child = False
        self.epoch = 0
        self.signature = None
        self.head = b''
        self.tail = b''
        self.bad_records = 0

    def update(self):
        stat = self.path.stat()
        signature = (stat.st_dev, stat.st_ino, stat.st_mtime_ns, stat.st_size)
        with self.path.open('rb') as stream:
            changed = self.signature is not None and signature != self.signature
            rewrite = stat.st_size < self.offset
            if self.signature:
                rewrite |= signature[:2] != self.signature[:2]
                rewrite |= changed and stat.st_size <= self.signature[3]
                # Fixed anchors at the already-read boundary detect prefix rewrites
                # without re-reading an ever-growing history on each poll.
                stream.seek(0)
                rewrite |= stream.read(len(self.head)) != self.head
                stream.seek(max(0, self.offset - len(self.tail)))
                rewrite |= stream.read(len(self.tail)) != self.tail
            if rewrite:
                self.__init__(self.path)
            stream.seek(self.offset)
            while True:
                position = stream.tell()
                line = stream.readline()
                if not line or not line.endswith(b'\n'):
                    self.offset = position
                    break
                self.offset = stream.tell()
                try:
                    self.consume(json.loads(line))
                except (ValueError, TypeError, KeyError, AttributeError, OverflowError):
                    self.bad_records += 1
            stream.seek(0)
            self.head = stream.read(min(256, self.offset))
            stream.seek(max(0, self.offset - 256))
            self.tail = stream.read(min(256, self.offset))
            self.signature = signature

    def consume(self, event):
        if not isinstance(event, dict) or not isinstance(event.get('payload', {}), dict):
            raise ValueError('Invalid event structure')
        p = event.get('payload') or {}
        kind = p.get('type', event.get('type'))
        ts = timestamp(event.get('timestamp'))
        if event.get('type') == 'session_meta':
            ident = p.get('id', p.get('session_id'))
            if isinstance(ident, str):
                self.session_id = ident
            source = p.get('source')
            self.child = isinstance(source, dict) and 'subagent' in source
        if event.get('type') == 'token_usage_record':
            usage = valid_usage(p.get('usage'))
            if usage is not None:
                # Legacy snapshots after migration describe the same responses.
                # Keep older deltas, but remove an exact mirrored first delta.
                if not self.has_records:
                    for oldkey, (oldts, oldusage) in list(self.legacy.items()):
                        if oldts == ts and oldusage.get('total_tokens') == usage.get('total_tokens'):
                            del self.legacy[oldkey]
                self.has_records = True
                key = p.get('response_id')
                if not isinstance(key, str):
                    key = self.session_id + ':' + str(event.get('ordinal', ts))
                self.records[key] = (ts, usage)
        if kind == 'token_count':
            info = p.get('info')
            usage = valid_usage(info.get('total_token_usage')) if isinstance(info, dict) else None
            if usage is not None and 'total_tokens' in usage:
                total = usage['total_tokens']
                if total < self.previous_total:
                    self.epoch += 1
                    self.previous_total = 0
                delta = total - self.previous_total
                self.previous_total = total
                if delta and not self.has_records:
                    key = (self.session_id, self.epoch, total)
                    self.legacy[key] = (ts, {'total_tokens': delta})
            if isinstance(p.get('rate_limits'), dict):
                self.rate, self.rate_time = p['rate_limits'], ts
        if kind == 'task_started':
            self.active = True
            self.stage = 'thinking'
            self.started = ts
            self.pending.clear()
        elif kind in ('task_complete', 'turn_aborted'):
            self.active = False
            self.pending.clear()
        elif kind in ('error', 'task_failed'):
            self.active = False
            self.stage = 'error'
        if event.get('type') == 'response_item':
            if kind in ('function_call', 'custom_tool_call'):
                self.stage = 'working'
                name = p.get('name', '')
                args = str(p.get('arguments', p.get('input', '')))
                approval = False
                if name.endswith('exec_command'):
                    try:
                        approval = json.loads(args).get('sandbox_permissions') == 'require_escalated'
                    except (ValueError, AttributeError):
                        pass
                if ('request_user_input' in name and 'async' not in name) or approval:
                    self.pending[p.get('call_id', name)] = ts
            elif kind in ('function_call_output', 'custom_tool_call_output'):
                self.pending.pop(p.get('call_id'), None)
            elif kind == 'reasoning':
                self.stage = 'thinking'
        if ts:
            self.last_event = max(self.last_event, ts)


class LocalTelemetry:
    def __init__(self, home):
        self.home = home
        self.rollouts = {}
        self.titles = {}
        self.next_discovery = 0
        self.read_errors = 0

    def discover(self):
        paths = set()
        self.read_errors = 0
        for folder in ('sessions', 'archived_sessions'):
            base = self.home / folder
            if base.exists():
                paths.update(base.rglob('*.jsonl'))
        database = self.home / 'state_5.sqlite'
        if database.exists():
            try:
                with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=1) as con:
                    for row in con.execute('SELECT id, title, rollout_path FROM threads'):
                        self.titles[row[0]] = row[1]
                        path = Path(row[2])
                        if path.exists():
                            paths.add(path)
            except sqlite3.Error:
                self.read_errors += 1
        # Archived and active copies can coexist; response IDs are deduplicated later.
        for path in paths:
            self.rollouts.setdefault(path, Rollout(path))
        for path in list(self.rollouts):
            if not path.exists():
                del self.rollouts[path]

    def snapshot(self, now=None):
        now = now or time.time()
        if now >= self.next_discovery:
            self.discover()
            self.next_discovery = now + 15
        day = dt.datetime.fromtimestamp(now, BEIJING).date()
        seen = set()
        total = cached = output = 0
        active = []
        recent_error = None
        rate = None
        rate_time = 0
        errors = self.read_errors
        for rollout in self.rollouts.values():
            try:
                rollout.update()
            except OSError:
                errors += 1
                continue
            errors += rollout.bad_records
            records = {**rollout.legacy, **rollout.records}
            for key, (ts, usage) in records.items():
                if key in seen:
                    continue
                seen.add(key)
                if dt.datetime.fromtimestamp(ts, BEIJING).date() == day and ts <= now:
                    total += usage.get('total_tokens', usage.get('input_tokens', 0) + usage.get('output_tokens', 0))
                    cached += usage.get('cached_input_tokens', 0)
                    output += usage.get('output_tokens', 0)
            if rollout.rate_time > rate_time:
                rate, rate_time = rollout.rate, rollout.rate_time
            if rollout.child:
                continue
            if rollout.active and now - rollout.last_event < 86400:
                active.append(rollout)
            elif rollout.stage == 'error' and now - rollout.last_event < 120:
                recent_error = rollout
        def priority(r):
            return (bool(r.pending), r.last_event)
        current = max(active, key=priority) if active else recent_error
        status = 'idle'
        title = ''
        stale = False
        if current:
            status = 'needs_input' if current.pending else current.stage
            title = self.titles.get(current.session_id, 'Codex 浠诲姟')
            stale = now - current.last_event > 600
        return {
            'date': str(day), 'todayTokens': total, 'cachedTokens': cached,
            'outputTokens': output, 'status': status, 'taskTitle': title,
            'activeCount': len(active), 'statusStale': stale,
            'rateLimits': rate, 'rateUpdatedAt': rate_time,
            'localCoverage': len(self.rollouts), 'readErrors': errors,
        }


class AccountReader:
    """Bounded, cancellable read-only stdio connection."""
    def __init__(self, home, stop_event=None):
        self.stop_event = stop_event or threading.Event()
        self.process = self.reader = None
        self.closed = threading.Event()
        self.messages = queue.Queue()
        self.serial = 0
        executable = shutil.which('codex')
        if not executable:
            candidates = list((Path(os.environ.get('LOCALAPPDATA', '')) / 'OpenAI/Codex/bin').glob('*/codex.exe'))
            executable = str(max(candidates, key=lambda p: p.stat().st_mtime)) if candidates else None
        if not executable or self.stop_event.is_set():
            raise RuntimeError('Codex unavailable or reader cancelled')
        try:
            self.process = subprocess.Popen([executable, 'app-server', '--stdio'], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding='utf-8',
                env=dict(os.environ, CODEX_HOME=str(home)), creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            self.reader = threading.Thread(target=self._read, daemon=True)
            self.reader.start()
            self.call('initialize', {'clientInfo': {'name': 'white-dragon-pet', 'version': '1.0'}, 'capabilities': {'experimentalApi': True}})
            self.send({'method': 'initialized'})
        except BaseException:
            self.close()
            raise

    def _read(self):
        try:
            for line in self.process.stdout:
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        self.messages.put(value)
                except ValueError:
                    pass
        except (OSError, ValueError):
            pass
        finally:
            self.messages.put(None)

    def send(self, payload):
        if self.stop_event.is_set() or self.closed.is_set():
            raise RuntimeError('Reader cancelled')
        self.process.stdin.write(json.dumps(payload) + '\n')
        self.process.stdin.flush()

    def call(self, method, params=None):
        self.serial += 1
        ident = self.serial
        payload = {'id': ident, 'method': method}
        if params is not None:
            payload['params'] = params
        self.send(payload)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if self.stop_event.is_set() or self.closed.is_set():
                raise RuntimeError('Reader cancelled')
            try:
                response = self.messages.get(timeout=min(.1, max(.001, deadline - time.monotonic())))
            except queue.Empty:
                continue
            if response is None:
                raise RuntimeError('Codex read connection closed')
            if response.get('id') == ident:
                if 'error' in response or not isinstance(response.get('result', {}), dict):
                    raise RuntimeError('Read endpoint unavailable or invalid result')
                return response.get('result', {})
        raise TimeoutError('Codex read timed out')

    def close(self):
        self.closed.set()
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=1)
            if self.reader is not None and self.reader is not threading.current_thread():
                self.reader.join(timeout=1)
            for stream in (self.process.stdin, self.process.stdout):
                if stream:
                    stream.close()


class AccountPoller:
    """Account I/O never blocks the two-second local telemetry loop."""
    def __init__(self, home):
        self.home = home
        self.stop_event = threading.Event()
        self.ready = threading.Event()
        self.lock = threading.Lock()
        self.cache = {'rateLimits': None, 'rateUpdatedAt': 0, 'officialBuckets': None, 'accountConnected': False}
        self.thread = threading.Thread(target=self._poll, daemon=True)
        self.thread.start()

    def snapshot(self):
        with self.lock:
            return dict(self.cache)

    def _poll(self):
        account = None
        try:
            while not self.stop_event.is_set():
                try:
                    if account is None:
                        account = AccountReader(self.home, self.stop_event)
                    reply = account.call('account/rateLimits/read')
                    limits = reply.get('rateLimitsByLimitId')
                    rate = (limits.get('codex') if isinstance(limits, dict) else None) or reply.get('rateLimits')
                    with self.lock:
                        self.cache.update(rateLimits=rate if isinstance(rate, dict) else None,
                            rateUpdatedAt=time.time(), accountConnected=True)
                    self.ready.set()
                    try:
                        buckets = account.call('account/usage/read').get('dailyUsageBuckets')
                        with self.lock:
                            self.cache['officialBuckets'] = buckets if isinstance(buckets, list) else None
                    except (OSError, RuntimeError, TimeoutError, queue.Empty):
                        with self.lock:
                            self.cache['officialBuckets'] = None
                except (OSError, RuntimeError, TimeoutError, queue.Empty):
                    if account:
                        account.close()
                    account = None
                    with self.lock:
                        self.cache['accountConnected'] = False
                finally:
                    self.ready.set()
                self.stop_event.wait(60)
        finally:
            if account:
                account.close()

    def close(self):
        self.stop_event.set()
        self.thread.join(timeout=4)


def atomic_json(path, value):
    handle, filename = tempfile.mkstemp(prefix=path.name + '-', suffix='.tmp', dir=path.parent)
    temp = Path(filename)
    try:
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, allow_nan=False)
        for attempt in range(6):
            try:
                os.replace(temp, path)
                return
            except PermissionError:
                if attempt == 5:
                    raise
                time.sleep(.02 * (attempt + 1))
    finally:
        temp.unlink(missing_ok=True)


def run(args):
    home = Path(args.codex_home or os.environ.get('CODEX_HOME') or (Path.home() / '.codex')).resolve()
    destination = Path(args.state).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    local = LocalTelemetry(home)
    poller = None
    stop = Path(args.stop) if args.stop else None
    try:
        if not args.local_only and not (stop and stop.exists()):
            poller = AccountPoller(home)
            if args.once:
                poller.ready.wait(15)
        while not (stop and stop.exists()):
            now = time.time()
            state = local.snapshot(now)
            state.update(updatedAt=now, accountConnected=False, officialDayTokens=None)
            if poller:
                account = poller.snapshot()
                state['accountConnected'] = account['accountConnected']
                if account['rateLimits'] and account['rateUpdatedAt'] >= state['rateUpdatedAt']:
                    state['rateLimits'] = account['rateLimits']
                    state['rateUpdatedAt'] = account['rateUpdatedAt']
                state['officialDayTokens'] = next((number(b.get('tokens')) for b in account['officialBuckets'] or []
                    if isinstance(b, dict) and b.get('startDate') == state['date']), None)
            if stop and stop.exists():
                break
            try:
                atomic_json(destination, state)
            except PermissionError:
                if args.once:
                    raise
                # A transient Windows reader handle must not stop telemetry.
            if args.once:
                return
            for _ in range(10):
                if stop and stop.exists():
                    break
                time.sleep(.2)
    finally:
        if poller:
            poller.close()
        if stop:
            stop.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', default=str(Path(__file__).with_name('runtime') / 'state.json'))
    parser.add_argument('--codex-home')
    parser.add_argument('--stop')
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--local-only', action='store_true')
    run(parser.parse_args())
