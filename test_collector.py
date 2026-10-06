import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import threading
import time
import queue
import argparse
from contextlib import closing
import sqlite3
import collector

from collector import BEIJING, LocalTelemetry, Rollout


class NotificationTests(unittest.TestCase):
    def event(self, payload, kind='response_item'):
        return {'timestamp': '2026-10-06T01:00:00Z', 'type': kind, 'payload': payload}

    def ask(self, rollout, count=1):
        rollout.consume(self.event({'type':'function_call', 'name':'request_user_input_async',
            'call_id':'ask', 'arguments':json.dumps({'questions':[{'title':'demo'}]*count})}))

    def answer(self, rollout, index=0, role='user'):
        text = '<send_user_message_question_reply>' + json.dumps([{
            'questionItemId':json.dumps(['request_user_input_async','ask',index]), 'answer':'yes'
        }]) + '</send_user_message_question_reply>'
        rollout.consume(self.event({'type':'message','role':role,'content':[{'type':'input_text','text':text}]}))

    def test_async_ack_and_turn_completion_do_not_dismiss_question(self):
        r = Rollout(Path('unused')); self.ask(r)
        r.consume(self.event({'type':'function_call_output','call_id':'ask','output':'{"accepted":true}'}))
        r.consume(self.event({'type':'task_complete'}, 'event_msg'))
        self.assertFalse(r.active); self.assertTrue(r.async_pending)
        self.answer(r,role='assistant'); self.assertTrue(r.async_pending)
        self.answer(r); self.assertFalse(r.async_pending)

    def test_partial_answers_keep_remaining_questions(self):
        r=Rollout(Path('unused')); self.ask(r,2)
        self.answer(r,0); self.assertTrue(r.async_pending)
        self.answer(r,1); self.assertFalse(r.async_pending)

    def test_failed_request_and_interruption_clear_question(self):
        r=Rollout(Path('unused')); self.ask(r)
        r.consume(self.event({'type':'function_call_output','call_id':'ask','output':'{"accepted":false}'}))
        self.assertFalse(r.async_pending)
        self.ask(r); r.consume(self.event({'type':'turn_aborted'},'event_msg'))
        self.assertFalse(r.async_pending)

    def setup_catalog(self, root):
        with closing(sqlite3.connect(root/'state_5.sqlite')) as c, c:
            c.execute('CREATE TABLE threads(id,title,rollout_path,archived)')
            c.executemany('INSERT INTO threads VALUES(?,?,?,?)', [('one','演示任务',str(root/'one.jsonl'),0),('old','归档',str(root/'old.jsonl'),1)])

    def unread(self, root, ids):
        data={'electron-thread-read-state-v1':{'version':1,'unreadByIdentity':{'demo':{
            'local:host':ids, 'ssh:remote':['one']}}}}
        (root/'.codex-global-state.json').write_text(json.dumps(data),encoding='utf-8')

    def test_unread_priority_dedup_clear_and_partial_read(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); self.setup_catalog(root); self.unread(root,['one','one','old','unknown'])
            local=LocalTelemetry(root)
            s=local.snapshot(); self.assertEqual(s['status'],'notification')
            self.assertEqual(s['taskTitle'],'演示任务'); self.assertEqual(s['notificationCount'],1)
            (root/'.codex-global-state.json').write_text('{',encoding='utf-8')
            s=local.snapshot(); self.assertEqual(s['status'],'notification'); self.assertEqual(s['notificationReadErrors'],1)
            self.unread(root,[]); self.assertEqual(local.snapshot()['status'],'idle')

    def test_question_has_priority_over_unread_and_busy(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); self.setup_catalog(root); self.unread(root,['one'])
            (root/'one.jsonl').write_text('',encoding='utf-8')
            local=LocalTelemetry(root); local.snapshot()
            r=local.rollouts[root/'one.jsonl']; self.ask(r)
            r.active=True
            s=local.snapshot(); self.assertEqual(s['status'],'needs_input')
            self.assertEqual(s['notificationCount'],1)
            self.answer(r); self.assertEqual(local.snapshot()['status'],'notification')
            self.unread(root,[]); self.assertEqual(local.snapshot()['status'],'working')

    def test_unread_inbox_disappears_when_codex_marks_it_read(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); (root/'sqlite').mkdir(); db=root/'sqlite/codex-dev.db'
            with closing(sqlite3.connect(db)) as c, c:
                c.execute('CREATE TABLE inbox_items(id,title,thread_id,read_at,created_at)')
                c.execute('INSERT INTO inbox_items VALUES(?,?,?,?,?)',('demo','演示收件箱',None,None,1))
            local=LocalTelemetry(root); self.assertEqual(local.snapshot()['status'],'notification')
            with closing(sqlite3.connect(db)) as c, c: c.execute('UPDATE inbox_items SET read_at=1')
            self.assertEqual(local.snapshot()['status'],'idle')


class TelemetryTests(unittest.TestCase):
    def event(self, stamp, kind, payload):
        return {'timestamp': stamp, 'type': kind, 'payload': payload}

    def write(self, path, events):
        path.write_text(''.join(json.dumps(e) + '\n' for e in events), encoding='utf-8')

    def test_midnight_response_dedup_and_inclusive_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'sessions').mkdir()
            events = [
                self.event('2026-10-05T15:59:59Z', 'token_usage_record', {'response_id': 'before', 'usage': {'total_tokens': 999}}),
                self.event('2026-10-05T16:00:00Z', 'token_usage_record', {'response_id': 'at', 'usage': {'total_tokens': 120, 'input_tokens': 100, 'output_tokens': 20, 'reasoning_output_tokens': 10, 'cached_input_tokens': 70}}),
                self.event('2026-10-06T01:00:00Z', 'event_msg', {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': 1119}}}),
            ]
            self.write(root / 'sessions/a.jsonl', events)
            self.write(root / 'sessions/fork.jsonl', events)
            state = LocalTelemetry(root).snapshot(dt.datetime(2026, 10, 6, 12, tzinfo=BEIJING).timestamp())
            self.assertEqual(state['todayTokens'], 120)
            self.assertEqual(state['outputTokens'], 20)
            self.assertEqual(state['cachedTokens'], 70)

    def test_incomplete_line_retry_and_task_finish(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a.jsonl'
            started = self.event('2026-10-06T01:00:00Z', 'event_msg', {'type': 'task_started'})
            done = json.dumps(self.event('2026-10-06T01:01:00Z', 'event_msg', {'type': 'task_complete'}))
            self.write(path, [started])
            with path.open('a') as f:
                f.write(done[:25])
            r = Rollout(path); r.update()
            self.assertTrue(r.active)
            with path.open('a') as f:
                f.write(done[25:] + '\n')
            r.update()
            self.assertFalse(r.active)

    def test_legacy_repeated_cumulative_counter(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a.jsonl'
            self.write(path, [self.event('2026-10-06T01:00:00Z', 'event_msg', {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': n}}}) for n in (100, 100, 150)])
            r = Rollout(path); r.update()
            self.assertEqual(sum(v[1]['total_tokens'] for v in r.legacy.values()), 150)

    def test_pending_input_resolves(self):
        with tempfile.TemporaryDirectory() as temp:
            r = Rollout(Path(temp) / 'a.jsonl')
            r.consume(self.event('2026-10-06T01:00:00Z', 'response_item', {'type': 'function_call', 'name': 'request_user_input', 'call_id': 'input'}))
            self.assertTrue(r.pending)
            r.consume(self.event('2026-10-06T01:00:10Z', 'response_item', {'type': 'function_call_output', 'call_id': 'input'}))
            self.assertFalse(r.pending)

    def test_code_mention_of_escalation_is_not_approval(self):
        with tempfile.TemporaryDirectory() as temp:
            r = Rollout(Path(temp) / 'a.jsonl')
            r.consume(self.event('2026-10-06T01:00:00Z', 'response_item', {'type': 'custom_tool_call', 'name': 'functions.exec', 'call_id': 'code', 'input': 'write file containing require_escalated'}))
            self.assertFalse(r.pending)


    def test_latest_request_replaces_initial_title(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / 'sessions').mkdir()
            events = [
                self.event('2026-10-06T01:00:00Z', 'session_meta', {'id':'demo'}),
                self.event('2026-10-06T01:00:01Z', 'event_msg', {'type':'user_message','message':'old request'}),
                self.event('2026-10-06T02:00:00Z', 'event_msg', {'type':'task_started'}),
                self.event('2026-10-06T02:00:01Z', 'event_msg', {'type':'user_message','message':'add reset countdown'}),
            ]
            self.write(root / 'sessions/demo.jsonl', events)
            local = LocalTelemetry(root); local.titles['demo'] = 'initial conversation title'
            state = local.snapshot(dt.datetime(2026,10,6,12,tzinfo=BEIJING).timestamp())
            self.assertEqual(state['taskTitle'], 'add reset countdown')

    def test_request_summary_filters_metadata_and_file_list(self):
        summary = collector.request_summary('# Files mentioned by the user:\nsecret-path.png\n## My request:\nAdd countdown\nplease')
        self.assertEqual(summary, 'Add countdown please')
        self.assertEqual(collector.request_summary('<environment_context>metadata</environment_context>'), '')
        self.assertEqual(collector.request_summary('# AGENTS.md instructions\n<INSTRUCTIONS>defaults</INSTRUCTIONS>'), '')
        self.assertEqual(collector.request_summary('<send_user_message_question_reply>[]</send_user_message_question_reply>'), '')

class RegressionTests(unittest.TestCase):
    event = TelemetryTests.event
    write = TelemetryTests.write
    def test_missing_usage_does_not_reset_baseline(self):
        r = Rollout(Path('unused'))
        for n in (100, None, 150):
            r.consume(self.event('2026-10-06T01:00:00Z', 'event_msg', {'type': 'token_count', 'info': None if n is None else {'total_token_usage': {'total_tokens': n}}}))
        self.assertEqual(sum(v[1]['total_tokens'] for v in r.legacy.values()), 150)

    def test_counter_reset_retains_both_epochs(self):
        r = Rollout(Path('unused'))
        for n in (100, 50, 100):
            r.consume(self.event('2026-10-06T01:00:00Z', 'event_msg', {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': n}}}))
        self.assertEqual(sum(v[1]['total_tokens'] for v in r.legacy.values()), 200)

    def test_migration_keeps_older_usage(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / 'sessions').mkdir()
            self.write(root / 'sessions/a.jsonl', [
                self.event('2026-10-06T01:00:00Z', 'event_msg', {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': 100}}}),
                self.event('2026-10-06T01:00:00Z', 'token_usage_record', {'response_id': 'new', 'usage': {'total_tokens': 20}}),
                self.event('2026-10-06T01:00:01Z', 'event_msg', {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': 120}}})])
            self.assertEqual(LocalTelemetry(root).snapshot(dt.datetime(2026,10,6,12,tzinfo=BEIJING).timestamp())['todayTokens'], 120)

    def test_mirrored_transition_not_counted_twice(self):
        r = Rollout(Path('unused'))
        r.consume(self.event('2026-10-06T01:00:00Z', 'event_msg', {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': 20}}}))
        r.consume(self.event('2026-10-06T01:00:00Z', 'token_usage_record', {'response_id': 'same', 'usage': {'total_tokens': 20}}))
        self.assertFalse(r.legacy)
        self.assertEqual(r.records['same'][1]['total_tokens'], 20)

    def test_same_length_rewrite_and_rewrite_plus_append(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a.jsonl'
            a = self.event('2026-10-06T01:00:00Z', 'token_usage_record', {'response_id': 'aaa', 'usage': {'total_tokens': 20}})
            b = self.event('2026-10-06T01:00:00Z', 'token_usage_record', {'response_id': 'bbb', 'usage': {'total_tokens': 20}})
            self.write(path, [a]); r = Rollout(path); r.update()
            self.write(path, [b]); r.update()
            self.assertEqual(list(r.records), ['bbb'])
            self.write(path, [a, b]); r.update()
            self.assertEqual(set(r.records), {'aaa', 'bbb'})

    def test_malformed_json_structures_and_numbers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / 'sessions').mkdir()
            events = [[], {'payload': []}, self.event('2026-10-06T01:00:00Z', 'token_usage_record', {'usage': []}),
                self.event('2026-10-06T01:00:00Z', 'token_usage_record', {'response_id': 'a', 'usage': {'total_tokens': '100'}})]
            self.write(root / 'sessions/a.jsonl', events)
            state = LocalTelemetry(root).snapshot(dt.datetime(2026,10,6,12,tzinfo=BEIJING).timestamp())
            self.assertEqual(state['todayTokens'], 0)
            self.assertGreaterEqual(state['readErrors'], 2)

    def test_running_collector_crosses_midnight(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / 'sessions').mkdir()
            self.write(root / 'sessions/a.jsonl', [self.event('2026-10-05T15:59:59Z', 'token_usage_record', {'response_id': 'before', 'usage': {'total_tokens': 99}}),
                self.event('2026-10-05T16:00:00Z', 'token_usage_record', {'response_id': 'after', 'usage': {'total_tokens': 10}})])
            local = LocalTelemetry(root)
            midnight = dt.datetime(2026,10,6,tzinfo=BEIJING).timestamp()
            self.assertEqual(local.snapshot(midnight - 1)['todayTokens'], 99)
            self.assertEqual(local.snapshot(midnight)['todayTokens'], 10)

    def test_initialize_failure_closes_process(self):
        process = mock.Mock(); process.poll.return_value = None
        with mock.patch.object(collector.shutil, 'which', return_value='codex'), mock.patch.object(collector.subprocess, 'Popen', return_value=process), mock.patch.object(collector.threading, 'Thread'), mock.patch.object(collector.AccountReader, 'call', side_effect=TimeoutError):
            with self.assertRaises(TimeoutError):
                collector.AccountReader(Path('.'))
        process.terminate.assert_called_once()
        process.wait.assert_called_once()

    def test_calls_cancel_and_eof_without_timeout(self):
        reader = collector.AccountReader.__new__(collector.AccountReader)
        reader.stop_event = threading.Event(); reader.closed = threading.Event()
        reader.messages = queue.Queue(); reader.serial = 0; reader.process = mock.Mock()
        reader.messages.put(None)
        start = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, 'closed'):
            reader.call('account/rateLimits/read')
        self.assertLess(time.monotonic() - start, .5)
        reader.stop_event.set()
        with self.assertRaisesRegex(RuntimeError, 'cancelled'):
            reader.call('account/rateLimits/read')

    def test_slow_initialize_does_not_block_snapshot_and_cancels(self):
        entered = threading.Event()
        def slow(home, stop):
            entered.set(); stop.wait(2)
            raise RuntimeError('cancelled')
        with mock.patch.object(collector, 'AccountReader', side_effect=slow):
            poller = collector.AccountPoller(Path('.'))
            self.assertTrue(entered.wait(1))
            start = time.monotonic(); poller.snapshot()
            self.assertLess(time.monotonic() - start, .1)
            poller.close()
            self.assertFalse(poller.thread.is_alive())

    def test_atomic_write_retry_cleanup_and_distinct_names(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'state.json'
            replace = collector.os.replace
            names = []
            def flaky(src, dst):
                names.append(str(src))
                if len(names) == 1:
                    raise PermissionError('reader lock')
                replace(src, dst)
            with mock.patch.object(collector.os, 'replace', side_effect=flaky):
                collector.atomic_json(path, {'a': 1})
                collector.atomic_json(path, {'a': 2})
            self.assertEqual(json.loads(path.read_text()), {'a': 2})
            self.assertNotEqual(names[0], names[-1])
            with mock.patch.object(collector.os, 'replace', side_effect=PermissionError):
                with self.assertRaises(PermissionError):
                    collector.atomic_json(path, {'a': 3})
            self.assertEqual(list(Path(temp).glob('*.tmp')), [])

    def test_run_finally_closes_poller_on_local_failure(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(collector, 'AccountPoller') as poll, mock.patch.object(collector.LocalTelemetry, 'snapshot', side_effect=RuntimeError('bad')):
            args = argparse.Namespace(codex_home=temp, state=str(Path(temp)/'state.json'), stop=None, local_only=False, once=False)
            with self.assertRaises(RuntimeError): collector.run(args)
            poll.return_value.close.assert_called_once()

    def test_run_publishes_local_state_while_account_initializes(self):
        entered = threading.Event()
        def slow(home, stop):
            entered.set(); stop.wait(2)
            raise RuntimeError('cancelled')
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp) / 'state.json'; marker = Path(temp) / 'stop'
            original = collector.atomic_json
            def write_and_stop(path, data):
                original(path, data); marker.write_text('stop')
            args = argparse.Namespace(codex_home=temp, state=str(state), stop=str(marker), local_only=False, once=False)
            with mock.patch.object(collector, 'AccountReader', side_effect=slow), mock.patch.object(collector, 'atomic_json', side_effect=write_and_stop):
                start = time.monotonic(); collector.run(args)
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic() - start, 1)
            self.assertEqual(json.loads(state.read_text())['status'], 'idle')
            self.assertFalse(marker.exists())

    def test_reset_credit_count_uses_authoritative_count(self):
        self.assertEqual(collector.reset_credit_count({'rateLimitResetCredits': {'availableCount': 4, 'credits': [{}]}}), 4)
        self.assertEqual(collector.reset_credit_count({'rateLimitResetCredits': {'availableCount': 0}}), 0)
        for value in (None, {}, {'credits': [{}]}, {'availableCount': -1}, {'availableCount': True}, {'availableCount': '2'}):
            self.assertIsNone(collector.reset_credit_count({'rateLimitResetCredits': value}))

    def test_optional_usage_failure_preserves_quota(self):
        called = threading.Event()
        reader = mock.Mock()
        def call(method):
            if method == 'account/rateLimits/read':
                return {'rateLimits': {'primary': {'usedPercent': 10}}}
            called.set(); raise RuntimeError('not supported')
        reader.call.side_effect = call
        with mock.patch.object(collector, 'AccountReader', return_value=reader):
            poller = collector.AccountPoller(Path('.'))
            self.assertTrue(called.wait(1))
            self.assertEqual(poller.snapshot()['rateLimits']['primary']['usedPercent'], 10)
            poller.close()
        reader.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
