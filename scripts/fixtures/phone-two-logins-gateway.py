#!/usr/bin/env python3
"""SIMULATION ONLY. The Sessions fixture gateway with two independent logins (A and B), over loopback TLS.

Phone Calls is app-only (the app talks to samplehost itself), so this gateway serves nothing phone-related: it exists so
the Phone Calls UI acceptance can switch between two signed-in HQ accounts and prove one never sees the other's
samplehost key or calls. The fake samplehost is scripts/fixtures/fake-samplehost.py. Uses sessions-gateway and HQN_REF's
synthetic auth/WS fixture. No external network.
"""
import argparse, importlib.util, json, os, pathlib, secrets, ssl, threading
from http.server import ThreadingHTTPServer
from urllib.parse import urlparse

spec = importlib.util.spec_from_file_location('sessions', pathlib.Path(__file__).with_name('sessions-gateway.py'))
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
lock = threading.RLock()
passwords = {}
sessions = {}

original = s.fx.handler
def handler(gateway):
    base = original(gateway)
    class Handler(base):
        def principal(self):
            with lock:
                return sessions.get(self.cookies().get('fake_session'))
        def do_GET(self):
            if urlparse(self.path).path == '/api/auth/me':
                principal = self.principal()
                return self.reply(200, {'username': 'phone-simulation-' + principal.lower()}) if principal else self.reply(401, {'detail': 'unauthorized'})
            return super().do_GET()
        def do_POST(self):
            if urlparse(self.path).path == '/auth/password-login':
                body = self.body_json()
                principal = next((name for name, credentials in passwords.items() if credentials == (body.get('username'), body.get('password'))), None)
                if principal is None: return self.reply(401, {'detail': 'invalid credentials'})
                token = secrets.token_urlsafe(24)
                with lock:
                    sessions[token] = principal
                    gateway.sessions.add(token)
                return self.reply(200, {'ok': True}, cookie=token)
            return super().do_POST()
    return Handler
s.fx.handler = handler

def main():
    p = argparse.ArgumentParser(); p.add_argument('--port', type=int, required=True); p.add_argument('--credentials', required=True); p.add_argument('--cert', required=True); p.add_argument('--key', required=True); a = p.parse_args()
    s.reseed()
    for name in ('A', 'B'):
        username, password = 'phone-simulation-' + name.lower(), secrets.token_urlsafe(18)
        passwords[name] = (username, password)
        path = a.credentials if name == 'A' else a.credentials + '.b'
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f: json.dump({'url': f'https://127.0.0.1:{a.port}', 'username': username, 'password': password}, f)
    username, password = passwords['A']
    server = ThreadingHTTPServer(('127.0.0.1', a.port), handler(s.fx.auth.Gateway(username, password, True, None)))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(a.cert, a.key); server.socket = context.wrap_socket(server.socket, server_side=True)
    print('SIMULATED two-login gateway listening on loopback only', flush=True); server.serve_forever()
if __name__ == '__main__': main()
