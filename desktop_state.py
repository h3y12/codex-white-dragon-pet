"""Read sidebar state through the local desktop app-tools pipe, without mutations."""
from contextlib import closing
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import sqlite3
import struct
import threading
import time
import uuid


def normalized_path(value):
    value = os.path.abspath(value)
    if value.startswith('\\\\?\\UNC\\'):
        value = '\\\\' + value[8:]
    elif value.startswith('\\\\?\\'):
        value = value[4:]
    return os.path.normcase(value)


def sidebar_unread(result):
    """Only explicit, local Codex read flags are authoritative; omission is unknown."""
    if not isinstance(result, dict) or result.get('success') is not True:
        raise ValueError('Desktop query failed')
    for item in result.get('contentItems', []):
        if item.get('type') != 'inputText':
            continue
        state = json.loads(item['text'])
        if not isinstance(state, dict) or state.get('schemaVersion') != 4:
            raise ValueError('Unsupported sidebar state')
        if not isinstance(state.get('threads'), list) or not isinstance(state.get('pinnedThreads'), list):
            raise ValueError('Incomplete sidebar state')
        return {row['id']: row['isUnread'] for row in state['pinnedThreads'] + state['threads']
            if isinstance(row, dict) and row.get('kind') == 'codex' and row.get('hostId') == 'local'
            and isinstance(row.get('id'), str) and type(row.get('isUnread')) is bool}
    raise ValueError('Missing sidebar state')


def thread_waiting(result, ident):
    if not isinstance(result, dict) or result.get('success') is not True:
        raise ValueError('Desktop metadata unavailable')
    for item in result.get('contentItems', []):
        if item.get('type') != 'inputText':
            continue
        data = json.loads(item['text'])
        thread = data.get('thread', {})
        if data.get('schemaVersion') != 1 or thread.get('id') != ident or thread.get('hostId') != 'local':
            raise ValueError('Unexpected desktop metadata')
        status = thread.get('status', {})
        if status.get('type') in ('idle', 'notLoaded', 'systemError'):
            return False
        flags = status.get('activeFlags')
        if status.get('type') != 'active' or not isinstance(flags, list):
            raise ValueError('Unknown desktop activity flags')
        return any(flag in ('waitingOnApproval', 'waitingOnUserInput') for flag in flags)
    raise ValueError('Missing desktop metadata')


class DesktopStateReader:
    def __init__(self, home, project):
        self.home, self.project = Path(home), Path(project)
        self.stop = threading.Event()
        self.refresh = threading.Event()
        self.ready = threading.Event()
        self.lock = threading.Lock()
        self.state = {'reads': {}, 'updatedAt': 0, 'connected': False}
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def snapshot(self):
        with self.lock:
            return dict(self.state, reads=dict(self.state['reads']))

    def caller(self):
        database = self.home / 'state_5.sqlite'
        with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=.2)) as con:
            # Prefer this project, but a downloaded pet may have no chat of its own.
            columns = {row[1] for row in con.execute('PRAGMA table_info(threads)')}
            source_column = 'source' if 'source' in columns else 'NULL'
            rows = con.execute('SELECT id, cwd, ' + source_column +
                ' FROM threads WHERE archived=0 ORDER BY updated_at DESC')
            fallback = None
            for ident, cwd, source in rows:
                if not isinstance(ident, str) or not ident:
                    continue
                if isinstance(source, str):
                    try:
                        source = json.loads(source)
                    except ValueError:
                        pass
                if source == 'subagent' or isinstance(source, dict) and 'subagent' in source:
                    continue
                fallback = fallback or ident
                if isinstance(cwd, str) and normalized_path(cwd) == normalized_path(str(self.project.resolve())):
                    return ident
            if fallback:
                return fallback
        raise ValueError('No user chat')

    def query(self, caller):
        result = self._request(caller, 'list_threads', {'limit': 50})
        reads = sidebar_unread(result)
        state = json.loads(next(item['text'] for item in result['contentItems'] if item.get('type') == 'inputText'))
        waiting = dict(self.snapshot().get('waiting', {}))
        errors = 0
        for row in state['pinnedThreads'] + state['threads']:
            if row.get('kind') != 'codex' or row.get('hostId') != 'local' or row.get('id') not in reads:
                continue
            ident = row['id']
            if row.get('status') != 'active' and not waiting.get(ident, {}).get('value'):
                continue
            if self.stop.is_set():
                break
            observed = time.time()
            try:
                metadata = self._request(caller, 'read_thread', {'threadId': ident, 'hostId': 'local', 'includeTurns': False})
                waiting[ident] = {'value': thread_waiting(metadata, ident), 'observedAt': observed}
            except (OSError, ValueError, TypeError, KeyError, AttributeError):
                errors += 1
        # Completed chats only need one final confirmation to retire their cached flag.
        waiting = {ident: event for ident, event in waiting.items() if ident in reads}
        return {'reads': reads, 'waiting': waiting, 'waitingReadErrors': errors}

    def _request(self, caller, tool, arguments):
        if tool not in ('list_threads', 'read_thread'):
            raise ValueError('Only read-only desktop state queries are allowed')
        if os.name != 'nt':
            raise OSError('Desktop pipe unavailable')
        paths = [name for name in os.listdir('\\\\.\\pipe\\') if name.startswith('codex-app-tools-')]
        if len(paths) != 1:
            raise OSError('Desktop instance ambiguous or unavailable')
        params = {'arguments': arguments, 'callerSource': 'codex', 'hostId': 'local',
            'namespace': 'codex_app', 'threadId': caller, 'tool': tool,
            'callId': 'pet-read-' + str(uuid.uuid4()), 'turnId': 'pet-read-' + str(uuid.uuid4())}
        # Only sidebar and metadata reads; never fetch turns or submit approvals.
        payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': params}).encode()
        import msvcrt
        peek = ctypes.WinDLL('kernel32', use_last_error=True).PeekNamedPipe
        peek.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, wintypes.LPVOID,
            ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
        peek.restype = wintypes.BOOL
        with open('\\\\.\\pipe\\' + paths[0], 'r+b', buffering=0) as pipe:
            pipe.write(struct.pack('<I', len(payload)) + payload)
            data = bytearray(); size = None
            deadline = time.monotonic() + 8
            while not self.stop.is_set() and time.monotonic() < deadline:
                available = wintypes.DWORD()
                if not peek(msvcrt.get_osfhandle(pipe.fileno()), None, 0, None, ctypes.byref(available), None):
                    raise OSError('Desktop pipe closed')
                if available.value:
                    data.extend(pipe.read(min(available.value, 65536)))
                if size is None and len(data) >= 4:
                    size = struct.unpack('<I', data[:4])[0]
                    if not 0 < size <= 8388608:
                        raise ValueError('Invalid desktop response size')
                if size is not None and len(data) >= size + 4:
                    response = json.loads(data[4:size + 4])
                    if response.get('id') != 1 or response.get('jsonrpc') != '2.0':
                        raise ValueError('Invalid desktop response')
                    return response.get('result')
                self.stop.wait(.02)
        raise TimeoutError('Desktop read timed out')

    def _run(self):
        while not self.stop.is_set():
            try:
                observed_at = time.time()
                snapshot = self.query(self.caller())
                with self.lock:
                    # A slow reply cannot confirm reading output completed mid-query.
                    self.state = dict(snapshot, updatedAt=observed_at, connected=True)
            except (OSError, ValueError, TypeError, KeyError, AttributeError, sqlite3.Error):
                # Keep observations and their timestamp, never manufacture an all-read snapshot.
                with self.lock:
                    self.state['connected'] = False
            finally:
                self.ready.set()
            self.refresh.wait(1)
            self.refresh.clear()

    def request_refresh(self):
        self.refresh.set()

    def close(self):
        self.stop.set()
        self.refresh.set()
        self.thread.join(timeout=2)
