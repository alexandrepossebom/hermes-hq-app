#!/usr/bin/env python3
"""Deterministic event gates for the loopback fixture: python3 scripts/test_activity_gateway_gates.py."""
import importlib.util
import io
import json
import pathlib
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location('activity_fixture', pathlib.Path(__file__).parent / 'fixtures/activity-gateway.py')
assert spec is not None and spec.loader is not None
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
base = fixture.base


class ActivityGateTests(unittest.TestCase):
    def setUp(self):
        self.profile = 'default'
        self.sent = []
        self.original_emit = base.emit
        base.emit = lambda profile, kind, payload=None: self.sent.append((profile, kind, payload or {}))
        self.handler = fixture.handler(type('Gateway', (), {'media': None, 'record': lambda *args: None})())
        base.MESSAGES[self.profile] = []
        base.PLANS.clear()
        base.LEDGER.clear()
        base.CANCEL[self.profile] = threading.Event()
        base.RUNNING[self.profile] = False
        self.threads = []
        self.barriers = []

    def tearDown(self):
        for barrier in self.barriers:
            barrier.set()
        base.CANCEL[self.profile].set()
        for gate in base.ACKS:
            gate.set()
        base.ACKS.clear()
        for thread in self.threads:
            thread.join(2)
        base.emit = self.original_emit

    def post(self, path, data):
        body = json.dumps(data).encode()
        handler = object.__new__(self.handler)
        handler.path, handler.headers, handler.rfile = path, {'Content-Length': str(len(body))}, io.BytesIO(body)
        handler.reply = lambda status, value: (status, value)
        return handler.do_POST()

    def until(self, predicate, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.005)
        self.fail('condition not reached before deadline')

    def plan(self, key='gate', timeout=1.0, hold_ack=False):
        return {'replyDelay': 0, 'holdAck': hold_ack, 'replyText': 'final', 'events': [
            {'type': 'tool.start', 'after': 0, 'payload': {'name': 'patch', 'tool_id': 'p', 'args': {'path': 'demo'}}},
            {'type': 'tool.complete', 'after': 0, 'payload': {'name': 'patch', 'tool_id': 'p', 'result': 'patched'}},
            {'type': 'tool.start', 'after': 0, 'waitFor': key, 'waitTimeout': timeout, 'payload': {'name': 'helper', 'tool_id': 'h'}},
            {'type': 'tool.complete', 'after': 0, 'payload': {'name': 'helper', 'tool_id': 'h', 'result': 'done'}},
        ]}

    def start(self, plan):
        base.PLANS.append(plan)
        client = base.Client(None)
        client.send = lambda frame: None
        thread = threading.Thread(target=client.prompt, args=({'id': 1, 'params': {'profile': self.profile, 'text': 'test'}},), daemon=True)
        self.threads.append(thread)
        thread.start()
        self.until(lambda: bool(base.LEDGER))

    def release(self, key='gate', profile='default'):
        return self.post('/__fixture/event', {'profile': profile, 'type': 'fixture.release', 'payload': {'key': key}})

    def kinds(self):
        return [kind for _, kind, _ in self.sent]

    def test_block_release_and_persist(self):
        self.start(self.plan())
        self.until(lambda: 'tool.complete' in self.kinds())
        time.sleep(.08)
        self.assertEqual(self.kinds().count('tool.start'), 1)
        self.assertTrue(base.RUNNING[self.profile])
        self.assertEqual([r.get('tool_call_id') for r in base.MESSAGES[self.profile] if r['role'] == 'tool'], ['p'])
        self.assertEqual(self.release()[0], 200)
        self.until(lambda: not base.RUNNING[self.profile])
        self.assertEqual([r.get('tool_call_id') for r in base.MESSAGES[self.profile] if r['role'] == 'tool'], ['p', 'h'])
        self.assertEqual(base.MESSAGES[self.profile][-1]['content'], 'final')
        self.assertIn('message.complete', self.kinds())
        self.assertNotIn('fixture.release', self.kinds())
        self.until(lambda: self.profile not in fixture.GATES)

    def test_release_before_stream_start_is_retained(self):
        self.start(self.plan(hold_ack=True))
        self.until(lambda: bool(base.ACKS))
        self.assertEqual(self.release()[0], 200)
        base.ACKS.pop().set()
        self.until(lambda: not base.RUNNING[self.profile])
        self.assertEqual(base.MESSAGES[self.profile][-1]['content'], 'final')

    def test_finish_cancels_and_old_release_does_not_leak(self):
        self.start(self.plan())
        self.until(lambda: 'tool.complete' in self.kinds())
        self.post('/__fixture/finish', {'profile': self.profile, 'text': 'stopped'})
        self.assertNotIn(self.profile, fixture.GATES)
        time.sleep(.08)
        self.assertEqual(self.release()[0], 409)
        self.assertNotIn('final', [r['content'] for r in base.MESSAGES[self.profile]])
        base.LEDGER.clear()
        self.sent.clear()
        self.start(self.plan())
        self.until(lambda: 'tool.complete' in self.kinds())
        time.sleep(.08)
        self.assertTrue(base.RUNNING[self.profile])
        self.assertEqual(self.kinds().count('tool.start'), 1)
        self.release()
        self.until(lambda: not base.RUNNING[self.profile])

    def test_timeout_stops_without_success_and_new_turn_is_isolated(self):
        started = time.monotonic()
        self.start(self.plan(timeout=.15))
        self.until(lambda: not base.RUNNING[self.profile], timeout=1)
        self.assertLess(time.monotonic() - started, .8)
        self.assertNotIn('message.complete', self.kinds())
        self.assertNotIn('final', [r['content'] for r in base.MESSAGES[self.profile]])
        self.assertEqual(fixture.GATE_ERRORS[self.profile], {'error': 'wait timeout', 'key': 'gate'})
        self.until(lambda: self.profile not in fixture.GATES)
        self.assertEqual(self.release()[0], 409)
        base.LEDGER.clear()
        self.sent.clear()
        self.start(self.plan(timeout=.8))
        self.until(lambda: 'tool.complete' in self.kinds())
        self.assertNotIn(self.profile, fixture.GATE_ERRORS)
        time.sleep(.08)
        self.assertTrue(base.RUNNING[self.profile])
        self.release()
        self.until(lambda: not base.RUNNING[self.profile])

    def test_finish_cleans_an_early_release_before_stream_start(self):
        self.start(self.plan(hold_ack=True))
        self.until(lambda: bool(base.ACKS))
        self.assertEqual(self.release()[0], 200)
        self.assertIn(self.profile, fixture.GATES)
        self.post('/__fixture/finish', {'profile': self.profile, 'text': 'stopped'})
        self.assertNotIn(self.profile, fixture.GATES)
        base.ACKS.pop().set()
        self.threads[-1].join(1)
        time.sleep(.04)
        self.assertNotIn('final', [r['content'] for r in base.MESSAGES[self.profile]])
        self.assertNotIn(self.profile, fixture.GATES)
        base.LEDGER.clear()
        self.sent.clear()
        self.start(self.plan())
        self.until(lambda: 'tool.complete' in self.kinds())
        time.sleep(.08)
        self.assertTrue(base.RUNNING[self.profile])
        self.assertEqual(self.kinds().count('tool.start'), 1)
        self.release()
        self.until(lambda: not base.RUNNING[self.profile])

    def test_normal_ungated_turn_is_unchanged(self):
        plan = self.plan()
        del plan['events'][2]['waitFor']
        self.start(plan)
        self.until(lambda: not base.RUNNING[self.profile])
        self.assertEqual(base.MESSAGES[self.profile][-1]['content'], 'final')
        self.assertEqual([r['tool_call_id'] for r in base.MESSAGES[self.profile] if r['role'] == 'tool'], ['p', 'h'])

    def test_wrong_key_and_profile_do_not_release(self):
        self.start(self.plan())
        self.until(lambda: 'tool.complete' in self.kinds())
        self.assertEqual(self.release('unknown')[0], 409)
        other = next(p for p in base.MESSAGES if p != self.profile)
        self.assertEqual(self.release(profile=other)[0], 409)
        time.sleep(.08)
        self.assertTrue(base.RUNNING[self.profile])
        self.release()
        self.until(lambda: not base.RUNNING[self.profile])


    def test_cancelled_held_ack_cannot_revive_after_new_turn_starts(self):
        old = self.plan(key='old-gate', hold_ack=True)
        old['replyText'] = 'old final'
        del old['events'][2]['waitFor']
        old_stream_done = threading.Event()
        original_stream = base.stream
        def observed_stream(profile, plan):
            try:
                return original_stream(profile, plan)
            finally:
                if plan.get('replyText') == 'old final':
                    old_stream_done.set()
        base.stream = observed_stream
        self.addCleanup(setattr, base, 'stream', original_stream)
        self.start(old)
        self.until(lambda: bool(base.ACKS))
        old_ack = base.ACKS.pop()
        self.assertEqual(self.post('/__fixture/finish', {'profile': self.profile, 'text': 'stopped'})[0], 200)

        # B must be accepted, streaming, and blocked at its gate before A's ACK.
        new = {'replyDelay': 0, 'replyText': 'new final', 'events': [
            {'type': 'message.delta', 'after': 0, 'waitFor': 'new-gate', 'waitTimeout': 2,
             'payload': {'text': 'new delta'}}]}
        base.LEDGER.clear()
        self.sent.clear()
        self.start(new)
        self.until(lambda: 'message.start' in self.kinds())
        self.assertTrue(base.RUNNING[self.profile])
        self.assertIn('new-gate', fixture.GATES[self.profile][1])
        new_gate = fixture.GATES[self.profile][1]['new-gate']
        before_events = list(self.sent)
        before_rows = list(base.MESSAGES[self.profile])
        old_ack.set()
        self.assertTrue(old_stream_done.wait(1), 'old stream did not exit')
        self.assertEqual(self.sent, before_events)
        self.assertEqual(base.MESSAGES[self.profile], before_rows)
        self.assertTrue(base.RUNNING[self.profile])
        self.assertIs(fixture.GATES[self.profile][1]['new-gate'], new_gate)
        self.assertFalse(new_gate.is_set())
        self.assertEqual(self.release('new-gate')[0], 200)
        self.until(lambda: not base.RUNNING[self.profile])
        self.assertEqual(base.MESSAGES[self.profile][-1]['content'], 'new final')
        self.assertEqual(self.kinds().count('message.complete'), 1)

    def test_discard_pending_plans_is_scoped_and_preserves_active_turn(self):
        self.start(self.plan(key='remove-me'))
        self.until(lambda: 'tool.complete' in self.kinds())
        match = self.plan(key='remove-me')
        other = self.plan(key='keep-me')
        match2 = self.plan(key='remove-me')
        self.assertEqual(self.post('/__fixture/plan', {'plans': [match, other, match2]})[0], 200)
        self.assertEqual(self.post('/__fixture/discard-plans', {'waitFor': 'remove-me'}), (200, {'removed': 2}))
        self.assertEqual(base.PLANS, [other])
        self.assertTrue(base.RUNNING[self.profile])
        self.assertEqual(self.post('/__fixture/discard-plans', {'waitFor': 'not-found'}), (200, {'removed': 0}))
        self.assertEqual(base.PLANS, [other])
        self.assertEqual(self.release('remove-me')[0], 200)
        self.until(lambda: not base.RUNNING[self.profile])

    def test_discard_rejects_invalid_keys_without_mutation(self):
        plan = self.plan(key='keep-me')
        base.PLANS.append(plan)
        for data in ({}, {'waitFor': ''}, {'waitFor': '   '}, {'waitFor': None}, {'waitFor': 3}, {'waitFor': []}):
            with self.subTest(data=data):
                self.assertEqual(self.post('/__fixture/discard-plans', data)[0], 400)
                self.assertEqual(base.PLANS, [plan])


    def test_event_commit_after_replacement_is_discarded(self):
        arrived, resume, done = threading.Event(), threading.Event(), threading.Event()
        original_wait = fixture.wait_gate
        def blocked_wait(*args):
            result = original_wait(*args)
            if args[1] is old_cancel:
                arrived.set()
                if not resume.wait(3):
                    raise RuntimeError('event barrier timeout')
            return result
        setattr(fixture, 'wait_gate', blocked_wait)
        self.addCleanup(setattr, fixture, 'wait_gate', original_wait)
        self.barriers.append(resume)
        old_cancel = threading.Event()
        base.CANCEL[self.profile] = old_cancel
        base.RUNNING[self.profile] = True
        old = fixture.AcceptedPlan({'replyDelay': 0, 'replyText': 'old final', 'events': [
            {'type': 'tool.complete', 'after': 0, 'payload': {'name': 'stale', 'tool_id': 'old', 'result': 'bad'}}]})
        old.cancel = old_cancel
        def run_old():
            try:
                fixture.stream(self.profile, old)
            finally:
                done.set()
        thread = threading.Thread(target=run_old, daemon=True)
        self.threads.append(thread)
        thread.start()
        self.assertTrue(arrived.wait(2))
        self.start({'replyDelay': 0, 'replyText': 'new', 'events': [
            {'type': 'message.delta', 'after': 0, 'waitFor': 'successor', 'waitTimeout': 5, 'payload': {'text': 'new'}}]})
        self.until(lambda: self.profile in fixture.GATES and 'successor' in fixture.GATES[self.profile][1])
        self.until(lambda: self.kinds().count('message.start') == 2)
        successor_gate = fixture.GATES[self.profile][1]['successor']
        before = list(self.sent), list(base.MESSAGES[self.profile])
        resume.set()
        self.assertTrue(done.wait(2))
        self.assertEqual((self.sent, base.MESSAGES[self.profile]), before)
        self.assertTrue(base.RUNNING[self.profile])
        self.assertIs(fixture.GATES[self.profile][1]['successor'], successor_gate)
        self.assertEqual(self.release('successor')[0], 200)
        self.until(lambda: not base.RUNNING[self.profile])
        self.assertEqual(base.MESSAGES[self.profile][-1]['content'], 'new')

    def test_final_commit_after_replacement_is_discarded(self):
        arrived, resume, done = threading.Event(), threading.Event(), threading.Event()
        class PausedCancel(threading.Event):
            def wait(self, timeout=None):
                if timeout == .357:
                    arrived.set()
                    if not resume.wait(3):
                        raise RuntimeError('final barrier timeout')
                    return False
                return super().wait(timeout)
        self.barriers.append(resume)
        old_cancel = PausedCancel()
        base.CANCEL[self.profile] = old_cancel
        base.RUNNING[self.profile] = True
        old = fixture.AcceptedPlan({'replyDelay': 0, 'holdAfter': .357, 'replyText': 'old final', 'events': []})
        old.cancel = old_cancel
        def run_old():
            try:
                fixture.stream(self.profile, old)
            finally:
                done.set()
        thread = threading.Thread(target=run_old, daemon=True)
        self.threads.append(thread)
        thread.start()
        self.assertTrue(arrived.wait(2))
        self.start({'replyDelay': 0, 'replyText': 'new', 'events': [
            {'type': 'message.delta', 'after': 0, 'waitFor': 'successor', 'waitTimeout': 5, 'payload': {'text': 'new'}}]})
        self.until(lambda: self.profile in fixture.GATES and 'successor' in fixture.GATES[self.profile][1])
        self.until(lambda: self.kinds().count('message.start') == 2)
        successor_gate = fixture.GATES[self.profile][1]['successor']
        before = list(self.sent), list(base.MESSAGES[self.profile])
        resume.set()
        self.assertTrue(done.wait(2))
        self.assertEqual((self.sent, base.MESSAGES[self.profile]), before)
        self.assertTrue(base.RUNNING[self.profile])
        self.assertIs(fixture.GATES[self.profile][1]['successor'], successor_gate)
        self.assertEqual(self.release('successor')[0], 200)
        self.until(lambda: not base.RUNNING[self.profile])
        self.assertEqual(base.MESSAGES[self.profile][-1]['content'], 'new')

    def test_only_running_finish_is_idle_noop_and_default_unconditional(self):
        before = list(self.sent), list(base.MESSAGES[self.profile])
        self.assertEqual(self.post('/__fixture/finish', {'onlyRunning': True}), (200, {'ok': True}))
        self.assertEqual(self.post('/__fixture/finish', {'onlyRunning': True}), (200, {'ok': True}))
        self.assertEqual((self.sent, base.MESSAGES[self.profile]), before)
        self.assertEqual(self.post('/__fixture/finish', {'text': 'unconditional'})[0], 200)
        self.assertEqual(base.MESSAGES[self.profile][-1]['content'], 'unconditional')
        self.assertEqual(self.kinds(), ['message.start', 'message.complete'])

    def test_only_running_finish_stops_active_and_clears_gates(self):
        self.start(self.plan(hold_ack=True))
        self.until(lambda: bool(base.ACKS))
        self.assertEqual(self.release()[0], 200)
        self.assertIn(self.profile, fixture.GATES)
        self.assertEqual(self.post('/__fixture/finish', {'onlyRunning': True, 'text': 'cleanup'}), (200, {'ok': True}))
        self.assertFalse(base.RUNNING[self.profile])
        self.assertTrue(base.CANCEL[self.profile].is_set())
        self.assertNotIn(self.profile, fixture.GATES)
        self.assertEqual(base.MESSAGES[self.profile][-1]['content'], 'cleanup')
        self.assertEqual(self.kinds(), ['message.start', 'message.complete'])
        before = list(self.sent), list(base.MESSAGES[self.profile])
        self.assertEqual(self.post('/__fixture/finish', {'onlyRunning': True}), (200, {'ok': True}))
        self.assertEqual((self.sent, base.MESSAGES[self.profile]), before)


    def test_event_state_after_interrupt_or_finish_is_discarded(self):
        for action in ('interrupt', 'finish'):
            with self.subTest(action=action):
                arrived, resume, done = threading.Event(), threading.Event(), threading.Event()
                original_wait = fixture.wait_gate
                def blocked_wait(*args):
                    result = original_wait(*args)
                    arrived.set()
                    if not resume.wait(3):
                        raise RuntimeError('event barrier timeout')
                    return result
                setattr(fixture, 'wait_gate', blocked_wait)
                self.addCleanup(setattr, fixture, 'wait_gate', original_wait)
                self.barriers.append(resume)
                fixture.TODO_STATE.pop(self.profile, None)
                old_cancel = threading.Event()
                base.CANCEL[self.profile] = old_cancel
                base.RUNNING[self.profile] = True
                old = fixture.AcceptedPlan({'replyDelay': 0, 'events': [
                    {'type': 'todo.updated', 'after': 0, 'payload': {'todos': ['stale'], 'revision': 123}}]})
                old.cancel = old_cancel
                def run_old():
                    try:
                        fixture.stream(self.profile, old)
                    finally:
                        done.set()
                thread = threading.Thread(target=run_old, daemon=True)
                self.threads.append(thread)
                thread.start()
                self.assertTrue(arrived.wait(2))
                if action == 'interrupt':
                    self.assertEqual(fixture.rpc('session.interrupt', {'profile': self.profile})['status'], 'interrupted')
                else:
                    self.assertEqual(self.post('/__fixture/finish', {'text': 'stopped'})[0], 200)
                before = list(self.sent), list(base.MESSAGES[self.profile])
                resume.set()
                self.assertTrue(done.wait(2))
                setattr(fixture, 'wait_gate', original_wait)
                self.assertEqual((self.sent, base.MESSAGES[self.profile]), before)
                self.assertNotIn(self.profile, fixture.TODO_STATE)

    def test_start_commit_after_replacement_is_discarded(self):
        arrived, resume, done = threading.Event(), threading.Event(), threading.Event()
        class PausedCancel(threading.Event):
            def wait(self, timeout=None):
                if timeout == .453:
                    arrived.set()
                    if not resume.wait(3):
                        raise RuntimeError('start barrier timeout')
                    return False
                return super().wait(timeout)
        self.barriers.append(resume)
        old_cancel = PausedCancel()
        base.CANCEL[self.profile] = old_cancel
        base.RUNNING[self.profile] = True
        old = fixture.AcceptedPlan({'replyDelay': .453, 'events': []})
        old.cancel = old_cancel
        def run_old():
            try:
                fixture.stream(self.profile, old)
            finally:
                done.set()
        thread = threading.Thread(target=run_old, daemon=True)
        self.threads.append(thread)
        thread.start()
        self.assertTrue(arrived.wait(2))
        self.start({'holdAck': True, 'events': []})
        self.until(lambda: bool(base.ACKS))
        before = list(self.sent), list(base.MESSAGES[self.profile])
        resume.set()
        self.assertTrue(done.wait(2))
        self.assertEqual((self.sent, base.MESSAGES[self.profile]), before)
        self.assertTrue(base.RUNNING[self.profile])

    def test_performance_fallback_after_replacement_is_discarded(self):
        arrived, resume, done = threading.Event(), threading.Event(), threading.Event()
        class PausedCancel(threading.Event):
            def wait(self, timeout=None):
                if timeout == .417:
                    arrived.set()
                    if not resume.wait(3):
                        raise RuntimeError('fallback barrier timeout')
                    return False
                return super().wait(timeout)
        self.barriers.append(resume)
        old_cancel = PausedCancel()
        base.CANCEL[self.profile] = old_cancel
        base.RUNNING[self.profile] = True
        old = fixture.AcceptedPlan({'replyDelay': 0, 'chunkDelay': .417, 'replyText': 'old fallback'})
        old.cancel = old_cancel
        def run_old():
            try:
                fixture.stream(self.profile, old)
            finally:
                done.set()
        thread = threading.Thread(target=run_old, daemon=True)
        self.threads.append(thread)
        thread.start()
        self.assertTrue(arrived.wait(2))
        self.start({'holdAck': True, 'events': []})
        self.until(lambda: bool(base.ACKS))
        before = list(self.sent), list(base.MESSAGES[self.profile])
        resume.set()
        self.assertTrue(done.wait(2))
        self.assertEqual((self.sent, base.MESSAGES[self.profile]), before)
        self.assertTrue(base.RUNNING[self.profile])


    def test_performance_fallback_normal_and_hidden_prompt(self):
        base.PLANS.append({'replyDelay': 0, 'chunkDelay': 0, 'chunks': ['a', 'b'], 'tools': 1, 'toolBytes': 20})
        client = base.Client(None)
        client.send = lambda frame: None
        client.prompt({'id': 2, 'params': {'profile': self.profile, 'text': 'hidden request', 'display_kind': 'hidden'}})
        self.until(lambda: not base.RUNNING[self.profile])
        rows = base.MESSAGES[self.profile]
        self.assertEqual(rows[0]['display_kind'], 'hidden')
        self.assertEqual(rows[-1]['content'], 'ab')
        self.assertEqual([row.get('tool_call_id') for row in rows if row['role'] == 'tool'], ['performance-tool-0'])
        self.assertEqual(self.kinds(), ['message.start', 'message.delta', 'tool.start', 'tool.complete', 'message.delta', 'message.complete'])

    def test_acceptance_and_finish_are_serialized(self):
        entered, resume, finish_started, finish_done = (threading.Event() for _ in range(4))
        original_append = base.append
        def paused_append(profile, role, text):
            row = original_append(profile, role, text)
            if role == 'user':
                entered.set()
                if not resume.wait(3):
                    raise RuntimeError('acceptance barrier timeout')
            return row
        base.append = paused_append
        self.addCleanup(setattr, base, 'append', original_append)
        self.barriers.append(resume)
        base.PLANS.append({'holdAck': True, 'events': []})
        client = base.Client(None)
        client.send = lambda frame: None
        prompt = threading.Thread(target=client.prompt, args=({'id': 3, 'params': {'profile': self.profile, 'text': 'x'}},), daemon=True)
        self.threads.append(prompt)
        prompt.start()
        self.assertTrue(entered.wait(2))
        def finish():
            finish_started.set()
            self.post('/__fixture/finish', {'onlyRunning': True, 'text': 'stopped'})
            finish_done.set()
        finisher = threading.Thread(target=finish, daemon=True)
        self.threads.append(finisher)
        finisher.start()
        self.assertTrue(finish_started.wait(2))
        self.assertFalse(finish_done.wait(.05), 'finish passed partial acceptance')
        resume.set()
        self.assertTrue(finish_done.wait(2))
        self.assertFalse(base.RUNNING[self.profile])
        self.assertTrue(base.CANCEL[self.profile].is_set())
        self.assertEqual([row['content'] for row in base.MESSAGES[self.profile]], ['x', 'stopped'])


if __name__ == '__main__':
    unittest.main(verbosity=2)