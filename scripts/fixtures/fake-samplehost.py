#!/usr/bin/env python3
"""SIMULATION ONLY. A fake samplehost v2 API on loopback TLS for the Phone Calls UI acceptance. Nothing is dialed.

The app's DEBUG build reaches it with the launch environment HQ_SAMPLEHOST_BASE_URL=https://127.0.0.1:<port>/v2.
Answers only the requests Phone Calls makes, in the shapes samplehost documents:
  GET  /v2/phone_numbers                       list-phone-numbers
  GET  /v2/ai/assistants                       list-assistants (none until the app creates one)
  POST /v2/ai/assistants                       create-an-assistant (checks name, instructions, Idempotency-Key)
  POST /v2/calls                               dial (checks connection_id/from/to/time_limit_secs/assistant/tools)
  GET  /v2/ai/conversations?metadata->call_control_id=eq.<id>   list-conversations
  GET  /v2/ai/conversations/<id>/messages      get-conversation-messages (an ask_owner tool call is scripted)
  POST /v2/calls/<id>/actions/ai_assistant_add_messages          add-messages-to-ai-assistant
  POST /v2/calls/<id>/actions/hangup           hangup-call (a second one answers 90018 "already ended")
  GET  /v2/calls/<id>                          retrieve-a-call-status
Only the synthetic key KEYTEST is accepted. The key is never stored or printed: requests are logged with
`auth_ok` and `key_in_url` flags only.

Test hooks (no auth): GET /__fixture/state, POST /__fixture/reset.
"""
import argparse, json, ssl, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

KEY = 'KEYTEST'
FROM = '+15550100001'
CONNECTION = 'conn-sim'
ASSISTANT = 'assistant-sim'
CALL = 'v3:sim-call-1'
CONVERSATION = 'conv-sim-1'
lock = threading.RLock()

def empty():
    return {'requests': [], 'problems': [], 'calls': [], 'answers': [], 'hangups': 0, 'assistants': [], 'created_keys': []}
state = empty()

def stamp(n):
    return '2026-01-01T00:00:%02d.000Z' % n

def messages(call):
    out = [
        {'role': 'assistant', 'text': 'Hello from the simulated agent.', 'created_at': stamp(1)},
        {'role': 'user', 'text': 'The simulated recipient has a question.', 'created_at': stamp(2)},
        {'role': 'assistant', 'text': '', 'created_at': stamp(3), 'tool_calls': [{'id': 'call_ask_1', 'type': 'function', 'function': {
            'name': 'ask_owner', 'arguments': json.dumps({'question': 'Which simulated time works?', 'choices': ['Morning', 'Afternoon']})}}]},
        {'role': 'tool', 'text': 'Request failed', 'created_at': stamp(4)},
    ]
    for i, answer in enumerate(call['answers']):
        out.append({'role': 'tool', 'text': answer['content'], 'created_at': stamp(5 + 2 * i)})
        out.append({'role': 'assistant', 'text': 'Simulated answer received: ' + answer['answer'], 'created_at': stamp(6 + 2 * i)})
    return list(reversed(out))   # newest first: the app must sort

def error(status, code, title, detail):
    return status, {'errors': [{'code': code, 'title': title, 'detail': detail}]}

def problem(text):
    state['problems'].append(text)

def check_dial(body):
    assistant = body.get('assistant') or {}
    tools = assistant.get('tools') or []
    webhook = next((t.get('webhook') or {} for t in tools if t.get('type') == 'webhook'), {})
    for name, ok in [('connection_id', body.get('connection_id') == CONNECTION), ('from', body.get('from') == FROM),
                     ('to', body.get('to') == '+15550100002'), ('time_limit_secs', body.get('time_limit_secs') == 60),
                     ('command_id', bool(body.get('command_id'))), ('assistant.id', assistant.get('id') == ASSISTANT),
                     ('assistant.instructions', 'Discuss simulated appointment' in (assistant.get('instructions') or '')),
                     ('ask_owner tool', webhook.get('name') == 'ask_owner' and webhook.get('url', '').endswith('.invalid/hermes-hq'))]:
        if not ok: problem('dial ' + name)

def route(method, path, query, body, headers=None):
    call = state['calls'][0] if state['calls'] else None
    if method == 'GET' and path == '/v2/phone_numbers':
        return 200, {'data': [{'id': '1293384261075731499', 'record_type': 'phone_number', 'phone_number': FROM, 'status': 'active',
                               'connection_id': CONNECTION, 'connection_name': 'Simulated connection'}],
                     'meta': {'total_pages': 1, 'total_results': 1, 'page_number': 1, 'page_size': 250}}
    if method == 'GET' and path == '/v2/ai/assistants':
        return 200, {'data': state['assistants']}
    if method == 'POST' and path == '/v2/ai/assistants':
        key = (headers or {}).get('Idempotency-Key') or ''
        if not key: problem('create assistant Idempotency-Key')
        if not (body or {}).get('name') or not (body or {}).get('instructions'): problem('create assistant required fields')
        if key not in state['created_keys']:
            state['created_keys'].append(key)
            state['assistants'].append({'id': ASSISTANT, 'name': (body or {}).get('name'), 'created_at': stamp(0)})
        return 200, dict(state['assistants'][-1], model='simulated-default')
    if method == 'POST' and path == '/v2/calls':
        check_dial(body or {})
        if call and call['command_id'] == (body or {}).get('command_id'):
            pass   # samplehost ignores a repeated command_id
        elif call and call['alive']:
            return error(422, '90000', 'Busy', 'A simulated call is already going.')
        else:
            state['calls'] = [{'id': CALL, 'command_id': (body or {}).get('command_id'), 'alive': True, 'answers': []}]
        return 200, {'data': {'call_control_id': CALL, 'call_leg_id': 'leg-sim', 'call_session_id': 'session-sim', 'is_alive': False, 'record_type': 'call'}}
    if method == 'GET' and path == '/v2/ai/conversations':
        wanted = (query.get('metadata->call_control_id') or [''])[0]
        if (query.get('limit') or [''])[0] != '1': problem('conversations limit')
        found = call and wanted == 'eq.' + call['id']
        return 200, {'data': [{'id': CONVERSATION, 'name': '', 'created_at': stamp(0), 'metadata': {'call_control_id': CALL}}] if found else []}
    if method == 'GET' and path == '/v2/ai/conversations/%s/messages' % CONVERSATION and call:
        data = messages(call)
        return 200, {'data': data, 'meta': {'total_pages': 1, 'total_results': len(data), 'page_number': 1, 'page_size': 100}}
    if call and path == '/v2/calls/' + call['id'] and method == 'GET':
        return 200, {'data': {'call_control_id': call['id'], 'call_leg_id': 'leg-sim', 'call_session_id': 'session-sim', 'is_alive': call['alive'], 'record_type': 'call'}}
    if call and method == 'POST' and path == '/v2/calls/%s/actions/ai_assistant_add_messages' % call['id']:
        if not call['alive']: return error(422, '90018', 'Call has already ended', "This call is no longer active and can't receive commands.")
        sent = (body or {}).get('messages') or []
        tool = next((m for m in sent if m.get('role') == 'tool'), {})
        if tool.get('tool_call_id') != 'call_ask_1' or (body or {}).get('trigger_response') is not True:
            problem('add_messages shape'); return error(422, '10004', 'Invalid', 'tool_call_id and trigger_response are required.')
        content = tool.get('content') or ''
        answer = content.split('): ', 1)[1] if '): ' in content else content
        call['answers'].append({'content': content, 'answer': answer})
        state['answers'].append({'tool_call_id': tool['tool_call_id'], 'answer': answer, 'roles': [m.get('role') for m in sent]})
        return 200, {'data': {'result': 'ok'}}
    if call and method == 'POST' and path == '/v2/calls/%s/actions/hangup' % call['id']:
        if not call['alive']: return error(422, '90018', 'Call has already ended', "This call is no longer active and can't receive commands.")
        call['alive'] = False; state['hangups'] += 1
        return 200, {'data': {'result': 'ok'}}
    return error(404, '10005', 'Resource not found', 'The requested resource or URL could not be found.')

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def handle_any(self, method):
        u = urlparse(self.path)
        path = unquote(u.path)
        if path == '/__fixture/state' and method == 'GET':
            with lock: return self.reply(200, json.loads(json.dumps(state)))
        if path == '/__fixture/reset' and method == 'POST':
            with lock: state.clear(); state.update(empty())
            return self.reply(200, {'ok': True})
        length = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(length) if length else b''
        try: body = json.loads(raw) if raw else None
        except ValueError: body = None
        auth_ok = self.headers.get('Authorization') == 'Bearer ' + KEY
        with lock:
            state['requests'].append({'method': method, 'path': path, 'auth_ok': auth_ok, 'key_in_url': KEY in self.path,
                                      'key_in_body': KEY.encode() in raw})
            if not auth_ok:
                return self.reply(*error(401, '10009', 'Authentication failed', 'Could not understand the provided credentials.'))
            status, obj = route(method, path, parse_qs(u.query), body, {'Idempotency-Key': self.headers.get('Idempotency-Key')})
        return self.reply(status, obj)
    def do_GET(self): self.handle_any('GET')
    def do_POST(self): self.handle_any('POST')

def main():
    p = argparse.ArgumentParser(); p.add_argument('--port', type=int, required=True); p.add_argument('--cert', required=True); p.add_argument('--key', required=True); a = p.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', a.port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(a.cert, a.key); server.socket = context.wrap_socket(server.socket, server_side=True)
    print('SIMULATED samplehost listening on loopback only', flush=True); server.serve_forever()
if __name__ == '__main__': main()
