import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock
import sqlite3
from contextlib import closing

from desktop_state import DesktopStateReader, sidebar_unread


class DesktopStateTests(unittest.TestCase):
    def result(self, rows):
        return {'success': True, 'contentItems': [{'type': 'inputText', 'text': json.dumps(
            {'schemaVersion': 4, 'pinnedThreads': [], 'threads': rows})}]}

    def test_only_explicit_local_codex_flags_are_authoritative(self):
        rows = [dict(id='one', kind='codex', hostId='local', isUnread=True),
            dict(id='two', kind='codex', hostId='local', isUnread=False),
            dict(id='remote', kind='codex', hostId='ssh', isUnread=False),
            dict(id='unknown', kind='codex', hostId='local'),
            dict(id='chatgpt', kind='chatgpt', hostId='local', isUnread=False)]
        self.assertEqual(sidebar_unread(self.result(rows)), {'one': True, 'two': False})

    def test_bad_or_new_schema_is_unknown_instead_of_all_read(self):
        for result in ({}, {'success': False}, {'success': True, 'contentItems': []},
                {'success': True, 'contentItems': [{'type': 'inputText', 'text': '{'}]},
                {'success': True, 'contentItems': [{'type': 'inputText', 'text': '{"schemaVersion":5}'}]}):
            with self.assertRaises(ValueError):
                sidebar_unread(result)

    def test_pipe_failure_keeps_timestamp_without_manufacturing_read_confirmations(self):
        with mock.patch.object(threading, 'Thread'):
            reader = DesktopStateReader(Path('unused'), Path('.'))
        reader.state = {'reads': {'one': False}, 'updatedAt': 10, 'connected': True}
        with mock.patch.object(reader, 'caller', return_value='caller'), \
                mock.patch.object(reader, 'query', side_effect=OSError), \
                mock.patch.object(reader.stop, 'wait', side_effect=lambda _: reader.stop.set()):
            reader._run()
        self.assertEqual(reader.snapshot(), {'reads': {'one': False}, 'updatedAt': 10, 'connected': False})

    def test_existing_project_chat_handles_windows_long_path_prefix(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'runtime') as temp, mock.patch.object(threading, 'Thread'):
            home = Path(temp)
            with closing(sqlite3.connect(home / 'state_5.sqlite')) as con, con:
                con.execute('CREATE TABLE threads(id,cwd,archived,updated_at)')
                con.execute('INSERT INTO threads VALUES(?,?,0,1)', ('one', '\\\\?\\' + str(home.resolve())))
            reader = DesktopStateReader(home, home)
            self.assertEqual(reader.caller(), 'one')

    def test_downloaded_pet_uses_existing_user_chat_and_skips_internal_agents(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent / 'runtime') as temp, mock.patch.object(threading, 'Thread'):
            home = Path(temp)
            with closing(sqlite3.connect(home / 'state_5.sqlite')) as con, con:
                con.execute('CREATE TABLE threads(id,cwd,archived,updated_at,source)')
                con.executemany('INSERT INTO threads VALUES(?,?,?,?,?)', [
                    ('child', str(home), 0, 4, json.dumps({'subagent': {}})),
                    ('archived', str(home), 1, 3, 'cli'),
                    ('recent', str(home / 'other'), 0, 2, 'cli'),
                    ('older', str(home / 'older'), 0, 1, 'cli')])
            reader = DesktopStateReader(home, home)
            self.assertEqual(reader.caller(), 'recent')
            with closing(sqlite3.connect(home / 'state_5.sqlite')) as con, con:
                con.execute('UPDATE threads SET cwd=? WHERE id=?', (str(home), 'older'))
            self.assertEqual(reader.caller(), 'older')

    def test_slow_reply_is_dated_before_output_that_arrives_during_query(self):
        with mock.patch.object(threading, 'Thread'):
            reader = DesktopStateReader(Path('unused'), Path('.'))
        with mock.patch.object(reader, 'caller', return_value='caller'), \
                mock.patch.object(reader, 'query', return_value={'one': False}), \
                mock.patch('desktop_state.time.time', side_effect=[100, 200]), \
                mock.patch.object(reader.stop, 'wait', side_effect=lambda _: reader.stop.set()):
            reader._run()
        self.assertEqual(reader.snapshot()['updatedAt'], 100)
