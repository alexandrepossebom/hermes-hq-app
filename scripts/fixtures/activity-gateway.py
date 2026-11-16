#!/usr/bin/env python3
"""HQ Native activity fixture (docs/spec/1x-activity.md §15): REF's performance fixture plus what the
activity stream needs. Scripted turn events (plan key "events"), Hermes-strict params for the subagent and
session-control methods (unknown key -> 4000, as tui_gateway/contracts/base.py), a live roster behind
subagent.list / delegation.status, subagent.tail / steer / interrupt, session.control.read / session.control
with a goal, todo_state on resume, seeded tool-call history (/__fixture/rows) and /api/config display
overrides. Loopback only; every value is invented; nothing is forwarded anywhere.
An event may set waitFor to a unique nonempty key and waitTimeout (seconds, default 30, clamped to
0.01–45). POST /__fixture/event with type fixture.release and payload {"key": key} releases the active
profile's gate, even before streaming begins. Timeout stops the turn without a completion event; inspect
/__fixture/activity gate_errors. Keys are turn-local and must not be reused within a plan.
POST /__fixture/discard-plans with {"waitFor": key} removes only matching pending plans.
"""
import importlib.util, io, json, math, os, pathlib, socket, threading, time
from typing import Optional
from urllib.parse import urlparse, parse_qs

REF = pathlib.Path('/Users/me/Projects/hermes-hq-native-ref238/scripts')
_spec = importlib.util.spec_from_file_location('hqn_activity_perf', REF / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)
base = perf.base            # the build47 module: emit, append, owner, MESSAGES, RUNNING, CANCEL, LOCK, voice
LOCK = base.LOCK

SNAPSHOT_FIELDS = ('subagent_id', 'parent_id', 'depth', 'goal', 'delegation_id', 'model', 'started_at', 'status',
                   'tool_count', 'last_tool', 'accepting_steer')
SESSION = {'session_id', 'profile'}
ALLOWED = {
    'subagent.list': SESSION, 'subagent.tail': SESSION | {'subagent_id'}, 'subagent.interrupt': SESSION | {'subagent_id'},
    'subagent.steer': SESSION | {'subagent_id', 'text'}, 'delegation.status': {'profile'},
    'session.control.read': SESSION, 'session.control': SESSION | {'action', 'args'},
}
ACTIONS = {'goal.pause', 'goal.resume', 'goal.clear', 'goal.unwait', 'loop.pause', 'loop.resume', 'loop.stop',
           'subgoal.add', 'subgoal.remove', 'subgoal.clear', 'heartbeat.pause', 'heartbeat.resume', 'heartbeat.clear'}
EMPTY_CONTROL = {'goal': None, 'loop': None, 'heartbeat': None, 'revision': '', 'updated_at': 0}

SUBAGENTS = {}      # subagent_id -> roster record (only SNAPSHOT_FIELDS go on the wire)
FAILED = []         # subagent.list "delegations"
TAILS = {}          # subagent_id -> {"text", "truncated"}
CONTROL = {p: dict(EMPTY_CONTROL) for p in base.voice.SIDS}
TODO_STATE = {}     # profile -> {"todos", "revision"} (attached to session.resume / activate answers)
DISPLAY = {}        # profile -> /api/config "display" overrides
FAIL = {}           # method -> {"code", "message", "times"} (times -1 = always)
CALLS, VIOLATIONS, STEERS = [], [], []
GATES = {}          # profile -> (turn's cancellation event, pending key -> release event)
GATE_ERRORS = {}    # profile -> latest timeout (fixture control metadata only)


# Each accepted plan carries the cancellation identity chosen with its user row.
class AcceptedPlan(dict):
    cancel: Optional[threading.Event] = None


def turn_gates(profile, cancel, plan):
    """Create all unique turn gates before any event waits; caller holds LOCK."""
    current = GATES.get(profile)
    if current and current[0] is cancel:
        return current[1]
    events = plan.get('events') if isinstance(plan.get('events'), list) else []
    gates = {event['waitFor']: threading.Event() for event in events
             if isinstance(event.get('waitFor'), str) and event['waitFor']}
    GATES[profile] = (cancel, gates)
    GATE_ERRORS.pop(profile, None)
    return gates


def clear_gates(profile, cancel):
    with LOCK:
        if profile in GATES and GATES[profile][0] is cancel:
            del GATES[profile]


def wait_gate(profile, cancel, gates, event):
    key = event.get('waitFor')
    if not key:
        return not cancel.is_set()
    try:
        timeout = float(event.get('waitTimeout', 30))
        if not math.isfinite(timeout):
            raise ValueError('non-finite timeout')
        timeout = min(45, max(.01, timeout))
    except (TypeError, ValueError):
        timeout = 30
    deadline = time.monotonic() + timeout
    gate = gates[key]
    while not cancel.is_set():
        with LOCK:
            if cancel.is_set():
                return False
            if gate.is_set():
                gates.pop(key, None)
                return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                if base.CANCEL[profile] is cancel and not cancel.is_set():
                    GATE_ERRORS[profile] = {'error': 'wait timeout', 'key': key}
                    base.RUNNING[profile] = False
                return False
        cancel.wait(min(.025, remaining))
    return False


def err(code, message):
    return {'__error__': {'code': code, 'message': message}}


# build47 answers every RPC as {"result": …} (its websocket turns ValueError into -32001). A result carrying
# __error__ goes out as a JSON-RPC error with Hermes's own code instead.
_send = base.Client.send
def _send_with_errors(self, value):
    result = value.get('result') if isinstance(value, dict) else None
    if isinstance(result, dict) and '__error__' in result:
        value = {'jsonrpc': '2.0', 'id': value.get('id'), 'error': result['__error__']}
    return _send(self, value)
base.Client.send = _send_with_errors


def note_subagent(kind, payload):
    sid = payload.get('subagent_id')
    if not sid:
        return
    with LOCK:
        if kind == 'subagent.complete':
            SUBAGENTS.pop(sid, None)
            return
        record = SUBAGENTS.setdefault(sid, {'subagent_id': sid, 'started_at': time.time(), 'accepting_steer': True})
        for key in SNAPSHOT_FIELDS:
            if key in payload and key not in ('subagent_id', 'started_at'):
                record[key] = payload[key]
        if payload.get('tool_name'):
            record['last_tool'] = payload['tool_name']
        record['status'] = payload.get('status') or ('queued' if kind == 'subagent.spawn_requested' else 'running')


def note_event(profile, kind, payload):
    if kind.startswith('subagent.'):
        note_subagent(kind, payload)
    elif kind == 'todo.updated':
        TODO_STATE[profile] = {'todos': payload.get('todos', []), 'revision': payload.get('revision', 0)}
    elif kind == 'session.control.update' and isinstance(payload.get('control'), dict):
        CONTROL[profile] = payload['control']


def persist_tool(profile, payload, start, reasoning):
    args = payload.get('args') or (start or {}).get('args') or {}
    tool_id = payload.get('tool_id') or f'fixture-tool-{time.time_ns()}'
    result = payload.get('result')
    with LOCK:
        base.append(profile, 'assistant', '')
        row = base.MESSAGES[profile][-1]
        row['tool_calls'] = [{'id': tool_id, 'type': 'function', 'function': {'name': payload.get('name'), 'arguments': json.dumps(args)}}]
        if reasoning:
            row['reasoning'] = reasoning
        base.append(profile, 'tool', result if isinstance(result, str) else json.dumps(result))
        tool = base.MESSAGES[profile][-1]
        tool.update(tool_call_id=tool_id, tool_name=payload.get('name'))
        if payload.get('inline_diff'):
            tool['display_metadata'] = {'tool_result_metadata': {'inline_diff': payload['inline_diff']}}


def stream(profile, plan):
    events = plan.get('events')
    cancel = getattr(plan, 'cancel', None) or base.CANCEL[profile]
    if cancel.is_set():
        return
    if not isinstance(events, list):
        return stream_performance(profile, plan, cancel)
    with LOCK:
        if cancel.is_set() or base.CANCEL[profile] is not cancel:
            return
        gates = turn_gates(profile, cancel, plan)
    try:
        return stream_events(profile, plan, events, cancel, gates)
    finally:
        clear_gates(profile, cancel)


def stream_performance(profile, plan, cancel):
    """Inherited performance stream, with each write committed to its accepted turn."""
    if cancel.wait(float(plan.get('replyDelay', .1))):
        return
    chunks = plan.get('chunks') or [plan.get('replyText', 'Synthetic performance reply.')]
    if chunks == [None]:
        return
    tools = min(100, max(0, int(plan.get('tools', 0))))
    output_bytes = min(2 * 1024 * 1024, max(0, int(plan.get('toolBytes', 2048))))
    with LOCK:
        if cancel.is_set() or base.CANCEL[profile] is not cancel:
            return
        base.emit(profile, 'message.start')
    for index, chunk in enumerate(chunks):
        if cancel.wait(float(plan.get('chunkDelay', .015))):
            return
        call_id = f'performance-tool-{index}'
        args = {'command': f'printf synthetic-step-{index}', 'timeout': 5}
        with LOCK:
            if cancel.is_set() or base.CANCEL[profile] is not cancel:
                return
            base.emit(profile, 'message.delta', {'text': chunk})
            if index < tools:
                base.emit(profile, 'tool.start', {'name': 'terminal', 'tool_id': call_id, 'args': args})
        if index < tools:
            if cancel.wait(.015):
                return
            output = ('synthetic output\n' * (output_bytes // 17 + 1))[:output_bytes]
            result = {'stdout': output, 'stderr': '', 'exit_code': 0}
            with LOCK:
                if cancel.is_set() or base.CANCEL[profile] is not cancel:
                    return
                base.append(profile, 'assistant', '')
                base.MESSAGES[profile][-1]['tool_calls'] = [{'id': call_id, 'type': 'function', 'function': {'name': 'terminal', 'arguments': json.dumps(args)}}]
                base.append(profile, 'tool', json.dumps(result))
                base.MESSAGES[profile][-1]['tool_call_id'] = call_id
                base.emit(profile, 'tool.complete', {'name': 'terminal', 'tool_id': call_id, 'args': args, 'result': result})
    text = ''.join(chunks)
    with LOCK:
        if cancel.is_set() or base.CANCEL[profile] is not cancel:
            return
        row = base.append(profile, 'assistant', text)
        base.RUNNING[profile] = False
        base.emit(profile, 'message.complete', {'text': text, 'row_id': row})


def stream_events(profile, plan, events, cancel, gates):
    if cancel.wait(float(plan.get('replyDelay', .1))):
        return
    with LOCK:
        if cancel.is_set() or base.CANCEL[profile] is not cancel:
            return
        base.emit(profile, 'message.start')
    text, reasoning, starts = '', '', {}
    for event in events:
        if cancel.wait(float(event.get('after', .05))):
            return
        if not wait_gate(profile, cancel, gates, event):
            return
        with LOCK:
            if cancel.is_set() or base.CANCEL[profile] is not cancel:
                return
            kind, payload = event['type'], dict(event.get('payload') or {})
            if kind == 'message.delta':
                text += payload.get('text', '')
            elif kind == 'reasoning.delta':
                reasoning += payload.get('text', '')
            elif kind == 'reasoning.available':
                reasoning = payload.get('text', '')
            elif kind == 'tool.start':
                starts[payload.get('tool_id')] = payload
            elif kind == 'tool.complete':
                persist_tool(profile, payload, starts.get(payload.get('tool_id')), reasoning)
                reasoning = ''
            note_event(profile, kind, payload)
            base.emit(profile, kind, payload)
    if cancel.wait(float(plan.get('holdAfter', 0))):
        return
    final = plan.get('replyText', text)
    with LOCK:
        if cancel.is_set() or base.CANCEL[profile] is not cancel:
            return
        row = base.append(profile, 'assistant', final)
        if reasoning:
            base.MESSAGES[profile][-1]['reasoning'] = reasoning
        base.RUNNING[profile] = False
        base.emit(profile, 'message.complete', {'text': final, 'status': 'complete', 'row_id': row})
base.stream = stream


def control_action(profile, params):
    action = (params.get('action') or '').strip() if isinstance(params.get('action'), str) else ''
    if not action:
        return err(4004, 'action is required')
    if action not in ACTIONS:
        return err(4004, f'unknown action: {action}')
    args = params.get('args', {})
    if not isinstance(args, dict):
        return err(4004, 'args must be an object')
    if set(args) - {'text', 'index'}:
        with LOCK:
            VIOLATIONS.append({'method': 'session.control', 'unknown': sorted(set(args) - {'text', 'index'})})
        return err(4000, 'unknown args')
    control = json.loads(json.dumps(CONTROL[profile]))
    goal = control.get('goal')
    dispatch = {'type': 'exec', 'output': None, 'notice': None, 'message': None, 'display': None}
    if not action.startswith(('goal.', 'subgoal.')):
        return err(4004, f'No active {action.split(".")[0]}')
    if not goal:
        return err(4004, 'No active goal')
    if action == 'goal.pause':
        goal.update(status='paused', paused_reason='Paused from the app')
        dispatch['output'] = '⏸ Goal paused: ' + goal['title']
    elif action == 'goal.resume':
        goal['status'] = 'active'
        goal.pop('paused_reason', None)          # Hermes omits empty optionals (methods_session_control.py:73-82)
        dispatch = {'type': 'send', 'output': None, 'notice': '▶ Goal resumed: ' + goal['title'] +
                    '\nContinuing now — taking the next step.',
                    'message': '[Continue working toward the standing goal: ' + goal['title'] + ']', 'display': '/goal resume'}
    elif action == 'goal.unwait':
        goal.pop('wait_barrier', None)
    elif action == 'goal.clear':
        control['goal'] = None
    elif action == 'subgoal.add':
        text = args.get('text')
        if not isinstance(text, str) or not text.strip():
            return err(4004, 'subgoal text is required')
        goal['subgoals'].append(text.strip())
    elif action == 'subgoal.remove':
        index = args.get('index')
        if type(index) is not int:
            return err(4004, 'subgoal index must be an integer')
        if index < 1 or index > len(goal['subgoals']):
            return err(4004, 'subgoal index out of range')
        del goal['subgoals'][index - 1]
    elif action == 'subgoal.clear':
        goal['subgoals'] = []
    control['revision'] = f'fixture-{time.time_ns()}'
    control['updated_at'] = time.time()
    with LOCK:
        CONTROL[profile] = control
    base.emit(profile, 'session.control.update', {'control': control})
    return {'control': control, 'dispatch': dispatch}


def finish_interrupt(profile, record):
    time.sleep(.3)
    payload = {'goal': record.get('goal') or '', 'task_count': 1, 'task_index': 0, 'subagent_id': record['subagent_id'],
               'status': 'interrupted', 'summary': 'Interrupted from the app'}
    note_subagent('subagent.complete', payload)
    base.emit(profile, 'subagent.complete', payload)


_prev_rpc = base.rpc
def rpc(method, params):
    profile = base.owner(params)
    if method in ALLOWED:
        with LOCK:
            CALLS.append({'method': method, 'params': params, 'at': time.time()})
        extra = sorted(set(params) - ALLOWED[method])
        if extra:
            with LOCK:
                VIOLATIONS.append({'method': method, 'unknown': extra})
            return err(4000, 'unknown params: ' + ', '.join(extra))
        fail = FAIL.get(method)
        if fail and fail.get('times', 0) != 0:
            if fail['times'] > 0:
                fail['times'] -= 1
            return err(int(fail.get('code', 5000)), str(fail.get('message', 'fixture failure')))
        if method.startswith('subagent.') and method != 'subagent.list' and not str(params.get('subagent_id') or ''):
            return err(4000, 'subagent_id required')
    if method == 'subagent.list':
        with LOCK:
            return {'subagents': [{k: r.get(k) for k in SNAPSHOT_FIELDS} for r in SUBAGENTS.values()], 'delegations': list(FAILED)}
    if method == 'delegation.status':
        with LOCK:
            active = [{'subagent_id': r['subagent_id'], 'goal': r.get('goal'), 'status': r.get('status', 'running'),
                       'started_at': r.get('started_at'), 'owner_agent_session_id': 'fixture-agent'} for r in SUBAGENTS.values()]
        return {'active': active, 'paused': False, 'max_spawn_depth': 1, 'max_concurrent_children': 3}
    if method == 'subagent.tail':
        tail = TAILS.get(params['subagent_id'])
        return {'subagent_id': params['subagent_id'], 'available': tail is not None,
                'text': (tail or {}).get('text', ''), 'truncated': bool((tail or {}).get('truncated'))}
    if method == 'subagent.steer':
        text = (params.get('text') or '').strip()
        if not text:
            return err(4002, 'text is required')
        record = SUBAGENTS.get(params['subagent_id'])
        queued = bool(record) and record.get('accepting_steer', True) is not False
        with LOCK:
            STEERS.append({'subagent_id': params['subagent_id'], 'text': text, 'queued': queued})
        return {'status': 'queued' if queued else 'rejected', 'subagent_id': params['subagent_id'], 'text': text}
    if method == 'subagent.interrupt':
        record = SUBAGENTS.get(params['subagent_id'])
        if record:
            threading.Thread(target=finish_interrupt, args=(profile, dict(record)), daemon=True).start()
        return {'found': bool(record), 'subagent_id': params['subagent_id']}
    if method == 'session.control.read':
        return {'control': CONTROL[profile]}
    if method == 'session.control':
        return control_action(profile, params)
    if method == 'session.interrupt':
        with LOCK:
            cancel = base.CANCEL[profile]
            answer = _prev_rpc(method, params)
            clear_gates(profile, cancel)
            return answer
    answer = _prev_rpc(method, params)
    if method in ('session.resume', 'session.activate') and profile in TODO_STATE and isinstance(answer, dict):
        answer = {**answer, 'todo_state': TODO_STATE[profile]}
    return answer
base.rpc = rpc


# A goal continuation is submitted with display_kind "hidden" (contracts/prompt_voice.py:26-35): Hermes stores that
# prompt with display_kind "hidden", so the transcript never shows it. build47 stores every prompt as a plain user row.
_HIDDEN = threading.local()
_append = base.append
def _append_hidden(profile, role, text):
    row = _append(profile, role, text)
    if role == 'user' and getattr(_HIDDEN, 'on', False):
        with LOCK:
            for stored in reversed(base.MESSAGES[profile]):
                if stored.get('row_id') == row:
                    stored['display_kind'] = 'hidden'
                    break
    return row
base.append = _append_hidden

# Mirror inherited prompt acceptance as one transaction; its ACK wait must remain outside LOCK.
def _prompt_hidden(self, frame):
    params = frame.get('params') or {}
    profile = base.owner(params)
    _HIDDEN.on = params.get('display_kind') == 'hidden'
    try:
        with LOCK:
            plan = AcceptedPlan(base.PLANS.pop(0) if base.PLANS else {})
            base.voice.state['rpc'].append({'method': 'prompt.submit', 'params': params})
            base.voice.state['promptAttempts'] += 1
            entry = {'profile': profile, 'method': 'prompt.submit', 'text': params.get('text', ''),
                     'accepted': not plan.get('reject') and plan.get('persist', True), 'plan': plan}
            if entry['accepted']:
                entry['row_id'] = base.append(profile, 'user', params.get('text', ''))
                old_cancel = base.CANCEL[profile]
                old_cancel.set()
                clear_gates(profile, old_cancel)
                cancel = threading.Event()
                base.CANCEL[profile] = cancel
                plan.cancel = cancel
                base.RUNNING[profile] = True
            base.LEDGER.append(entry)
        if plan.get('disconnect'):
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            return
        if plan.get('holdAck'):
            gate = threading.Event()
            with LOCK:
                base.ACKS.append(gate)
            gate.wait(90)
        else:
            time.sleep(float(plan.get('ackDelay', 0)))
        if plan.get('dropAck'):
            return
        try:
            if plan.get('reject'):
                self.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': plan.get('code', -32001), 'message': plan['reject']}})
            else:
                self.send({'jsonrpc': '2.0', 'id': frame['id'], 'result': {'status': 'streaming', 'user_row_id': entry['row_id']}})
                threading.Thread(target=base.stream, args=(profile, plan), daemon=True).start()
        except OSError:
            pass
    finally:
        _HIDDEN.on = False
base.Client.prompt = _prompt_hidden


_perf_handler = base.handler
def handler(gateway):
    # HQN_ACTIVITY_MEDIA=<dir>: /api/fs/download serves files under it (the fake gateway's --media-dir), e.g. a
    # generated image whose host_image path is <dir>/x.png.
    if os.environ.get('HQN_ACTIVITY_MEDIA'):
        gateway.media = os.environ['HQN_ACTIVITY_MEDIA']
    parent = _perf_handler(gateway)

    class Handler(parent):
        def body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            return json.loads(raw or b'{}')

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == '/api/config':
                profile = parse_qs(parsed.query).get('profile', ['default'])[0]
                return self.reply(200, {'model': 'fixture-model', 'provider': 'fixture', 'stt': {'enabled': False},
                                        'display': {'resume_last_session': True, **DISPLAY.get(profile, {})}})
            # action-voice answers every other /api/ GET with {} first, so the fake gateway's download never runs.
            if parsed.path == '/api/fs/download' and gateway.media:
                return self.media() if self.session() else self.reply(401, {'detail': 'unauthorized'})
            if parsed.path == '/__fixture/activity':
                with LOCK:
                    return self.reply(200, {'calls': list(CALLS), 'violations': list(VIOLATIONS), 'steers': list(STEERS),
                                            'subagents': dict(SUBAGENTS), 'control': CONTROL, 'todo_state': TODO_STATE,
                                            'display': DISPLAY, 'gate_errors': dict(GATE_ERRORS)})
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/discard-plans':
                body = self.body()
                key = body.get('waitFor') if isinstance(body, dict) else None
                if not isinstance(key, str) or not key.strip():
                    return self.reply(400, {'detail': 'waitFor must be a nonempty string'})
                def matches(plan):
                    events = plan.get('events') if isinstance(plan, dict) else None
                    return isinstance(events, list) and any(
                        isinstance(event, dict) and event.get('waitFor') == key for event in events)
                with LOCK:
                    before = len(base.PLANS)
                    base.PLANS[:] = [plan for plan in base.PLANS if not matches(plan)]
                    removed = before - len(base.PLANS)
                return self.reply(200, {'removed': removed})
            if path == '/__fixture/finish':
                raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
                body = json.loads(raw or b'{}')
                profile = body.get('profile', 'default')
                with LOCK:
                    if body.get('onlyRunning') is True and not base.RUNNING[profile]:
                        return self.reply(200, {'ok': True})
                    cancel = base.CANCEL[profile]
                    self.rfile = io.BytesIO(raw)
                    try:
                        return super().do_POST()
                    finally:
                        clear_gates(profile, cancel)
            if path == '/__fixture/event':
                body = self.body()
                profile = body.get('profile', 'default')
                if profile not in base.MESSAGES or not isinstance(body.get('type'), str):
                    return self.reply(400, {'detail': 'profile and type'})
                payload = body.get('payload') or {}
                if body['type'] == 'fixture.release':
                    key = payload.get('key') if isinstance(payload, dict) else None
                    with LOCK:
                        cancel = base.CANCEL[profile]
                        entry = next((item for item in reversed(base.LEDGER)
                                      if item['profile'] == profile and item['accepted']), None)
                        if not base.RUNNING[profile] or cancel.is_set() or not entry or not isinstance(key, str):
                            return self.reply(409, {'detail': 'No matching active gate'})
                        gates = turn_gates(profile, cancel, entry['plan'])
                        gate = gates.get(key)
                        if gate is None:
                            return self.reply(409, {'detail': 'No matching active gate'})
                        gate.set()
                    return self.reply(200, {'ok': True})
                note_event(profile, body['type'], payload)
                base.emit(profile, body['type'], payload)
                return self.reply(200, {'ok': True})
            if path == '/__fixture/rows':
                body = self.body()
                profile = body.get('profile', 'default')
                if profile not in base.MESSAGES:
                    return self.reply(404, {'detail': 'Unknown synthetic profile'})
                with LOCK:
                    if base.RUNNING[profile]:
                        return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                    ids = []
                    for raw in body.get('rows', []):
                        ids.append(base.append(profile, raw.get('role', 'assistant'), raw.get('content', '')))
                        base.MESSAGES[profile][-1].update({k: v for k, v in raw.items() if k not in ('role', 'content', 'row_id', 'timestamp')})
                return self.reply(200, {'ok': True, 'row_ids': ids})
            if path == '/__fixture/control':
                body = self.body()
                profile = body.get('profile', 'default')
                control = {**EMPTY_CONTROL, **(body.get('control') or {})}
                control['revision'] = control.get('revision') or f'fixture-{time.time_ns()}'
                with LOCK:
                    CONTROL[profile] = control
                if body.get('emit', True):
                    base.emit(profile, 'session.control.update', {'control': control})
                return self.reply(200, {'ok': True})
            if path == '/__fixture/subagents':
                body = self.body()
                with LOCK:
                    SUBAGENTS.clear()
                    for record in body.get('subagents', []):
                        SUBAGENTS[record['subagent_id']] = {'started_at': time.time(), 'status': 'running', **record}
                    FAILED[:] = body.get('delegations', [])
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tail':
                body = self.body()
                TAILS[body['subagent_id']] = {'text': body.get('text', ''), 'truncated': bool(body.get('truncated'))}
                return self.reply(200, {'ok': True})
            if path == '/__fixture/config':
                body = self.body()
                DISPLAY[body.get('profile', 'default')] = body.get('display') or {}
                return self.reply(200, {'ok': True})
            if path == '/__fixture/fail':
                body = self.body()
                FAIL[body['method']] = {'code': body.get('code', 5000), 'message': body.get('message', 'fixture failure'),
                                        'times': int(body.get('times', 1))}
                return self.reply(200, {'ok': True})
            if path == '/__fixture/todo-state':
                body = self.body()
                TODO_STATE[body.get('profile', 'default')] = {'todos': body.get('todos', []), 'revision': body.get('revision', 1)}
                return self.reply(200, {'ok': True})
            return super().do_POST()
    return Handler
base.handler = handler


if __name__ == '__main__':
    base.main()
