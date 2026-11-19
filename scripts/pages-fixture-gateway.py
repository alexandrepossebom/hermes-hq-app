#!/usr/bin/env python3
"""A stateful stand-in gateway for the native Jobs, Kanban and Artifacts pages (docs/spec/1x-pages.md §9.3).

Stdlib only. It loads the reference repo's action-voice fixture ($HQN_REF/scripts/action-voice-fixture-gateway.py)
for the password sign-in, the ws-ticket and the WebSocket JSON-RPC base, and overrides `rpc`, `websocket` and the
REST handler. Everything it serves is invented. It binds 127.0.0.1 only and has no network client.

  python3 scripts/pages-fixture-gateway.py --port 9735 --credentials <scratch>/pages.json --files <scratch>/files
  python3 scripts/pages-fixture-gateway.py --port 9737 --credentials <scratch>/pages-nok.json --files <scratch>/files2 --no-kanban

Flags: --no-kanban (every /api/plugins/kanban/* answers 404), --empty-kanban (boards hold no tasks),
--trigger-seconds N (a job trigger blocks N s, default 3), --tick-seconds N (a cron.changed broadcast every N s,
default 60; 0 = off), --hermes-cookies (inherited session gating).

Test hooks (no auth):
  GET  /__fixture/state      {"rest":[{method,path,query,body}],"rpc":[...],"dispatch":n,"beacon":n}
  POST /__fixture/fail       {"method","path","status","detail","count"} or {"method","path","delay"}
  POST /__fixture/rpc-fail   {"method","action","delay","error","count"}: that RPC waits and/or fails (a plugin install)
  POST /__fixture/reset      forget the logs and failures, re-seed every table
  POST /__fixture/tile-job   a job of deploys that rewrites site/tile.html hourly, last run 5 minutes ago ([tiles])
                             ({"status": "error", "error": …, "model": …}: its last run failed, the model it names)
  POST /__fixture/live-bump  site/live.html's sales go from 12 to 13 ([live-tiles]: the tile's own refresh reads it)
  POST /__fixture/tile-edit  {"from","to"}: the tile's bot edited the page's look ([tile-versions])
  POST /__fixture/tile-ran   that job ran just now and rewrote the page (the headline becomes Revenue $14K)
  POST /__fixture/broadcast  {"type":"cron.changed"} to every open socket
  POST /__fixture/turn-end   {"match","text"} or {"match","error"}: the last streaming prompt holding `match` ends ([tiles])
  POST /__fixture/append     {"session_id","role","text"}: a new message (its session's count and last_active move)
  POST /__fixture/finish     {"job_id"}: the job's run out ends, as Hermes ends one (marked run, attempt completed);
                             with "bot":"claimed" (or "queued") a bot is still working on what it handed over
  POST /__fixture/bot-done   {"job_id"}: that bot is done (a cron.changed too, so the app reads now; Hermes sends none
                             then, and the app's 30 s backstop finds it)
  GET  /__fixture/beacon     counts a fetch (an HTML file's <img>; Quick Look must never fetch it)

Tasks ([tasks], hermes-hq-push 0.9.32, docs/tasks.md): /api/plugins/hermes-hq-push/tasks (GET ?since, POST),
/tasks/{id} (PATCH with rev: a stale one is a 409 {"detail": {"task": …}}; DELETE), /tasks/settings (GET, PUT), and
the add-on's /status with every flag on (tasks: true), POST /tasks/prep-job/{profile}. Seeded with the owner-approved
mockup's list and a chat ('s-tasks') where Hermes adds two with tasks_add; --tasks-chat puts that exchange at the end of
Hermes's own Bot Chat too; --no-tasks answers 404 for the routes (an add-on older than 0.9.32).

Goals ([goals], hermes-hq-push 0.9.65, docs/goals.md): `goals` in the list answer, POST /goals, PATCH /goals/{id} with
rev (a stale one is a 409 {"detail": {"goal": …}}; `measure_now` adds a reading), DELETE /goals/{id} (its tasks keep no
goal), `goal`/`milestone` on tasks (an unknown goal is a 400; clearing the goal clears the milestone) and `task_goals`
in /status. --task-goals or /__fixture/tasks-mode {"goals": true} seeds five made-up goals; older_addon leaves it all out.
"""
import shutil
import argparse, base64, copy, datetime, hashlib, importlib.util, json, mimetypes, os, pathlib, re, socket, struct, sys, threading, time, zlib
from urllib.parse import urlparse, parse_qs, unquote

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
_spec = importlib.util.spec_from_file_location('fx', REF / 'scripts/action-voice-fixture-gateway.py')
fx = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(fx)

HOME = '/home/hermes'
FILES = pathlib.Path('/tmp/pages-fixture-files')
PERF_LOGS = pathlib.Path(__file__).resolve().parent / 'fixture-support' / 'perf_logs.py'   # copy of the plugin's log writer
TASK_PAGE = pathlib.Path(__file__).resolve().parent / 'fixture-support' / 'task_page.py'   # copy of the plugin's Task Page (0.9.38)
NO_KANBAN = False
EMPTY_KANBAN = False
TRIGGER_SECONDS = 3.0
lock = threading.RLock()
state = {'rest': [], 'rpc': [], 'dispatch': 0, 'beacon': 0}
fails = []
sockets = set()
T0 = 0.0

def now(): return time.time()
def local(ts): return datetime.datetime.fromtimestamp(ts).astimezone()
def iso(dt): return dt.isoformat(timespec='seconds') if dt else None
def minute(dt): return dt.replace(second=0, microsecond=0)

# ---- the roster ----------------------------------------------------------------------------------------
BOTS = [('default', 'Hermes', 'Your right hand'), ('inbox', 'Inbox', 'Triage, replies and follow-ups'),
        ('deploys', 'Deploys', 'Releases, builds and checks'), ('research', 'Research', 'Reading and summaries'),
        ('finance', 'Finance', 'Books, invoices and reports')]
# HQN_REAL_LISTING / HQN_REAL_MESSAGES: JSON files outside the repo with a real gateway's per-profile listing and its
# chats' messages (key "profile\x1fid"), so Artifacts runs over real data. The roster becomes that listing's profiles.
REAL_LISTING = json.load(open(os.environ['HQN_REAL_LISTING'])) if os.environ.get('HQN_REAL_LISTING') else None
REAL_MESSAGES = json.load(open(os.environ['HQN_REAL_MESSAGES'])) if os.environ.get('HQN_REAL_MESSAGES') else {}
if REAL_LISTING:
    BOTS = [(n, 'Hermes' if n == 'default' else n.replace('-', ' ').title(), 'Real') for n in sorted(REAL_LISTING)]
# HQN_FIXTURE_EXTRA_BOTS=N: N more plain bots, so the Bots list is long enough to scroll (bar screenshots).
BOTS += [(f'extra{i + 1}', f'Helper {i + 1}', 'Odds and ends') for i in range(int(os.environ.get('HQN_FIXTURE_EXTRA_BOTS', '0') or 0))]
BOT_NAMES = {name: title for name, title, _ in BOTS}

SESSIONS = {}
def add_session(sid, profile, title, messages, last_active, source='desktop', cwd=f'{HOME}/app', hidden=False, listed=True):
    for index, message in enumerate(messages):
        message.setdefault('id', index + 1)
        message.setdefault('timestamp', last_active - (len(messages) - index) * 5)
    SESSIONS[sid] = {'id': sid, 'profile': profile, 'title': title, 'messages': messages, 'last_active': last_active,
                     'started_at': last_active - 600, 'source': source, 'cwd': cwd, 'hidden': hidden, 'listed': listed}

def session_row(sid):
    s = SESSIONS[sid]
    last = next((m for m in reversed(s['messages']) if m['role'] == 'assistant' and isinstance(m.get('content'), str)), None)
    preview = (last['content'] if last else '').split('\n')[0][:140]
    return {'id': sid, 'title': s['title'], 'preview': preview, 'profile': s['profile'], 'profile_name': s['profile'],
            'is_default_profile': s['profile'] == 'default', 'hidden': s['hidden'], 'pinned': False, 'unread': False,
            'archived': False, 'model': 'hermes-4', 'billing_provider': 'nous', 'source': s['source'],
            'message_count': len(s['messages']), 'started_at': s['started_at'], 'last_active': s['last_active'],
            'ended_at': None, 'is_active': False, 'cwd': s['cwd']}

STREAMING = set()   # [tiles] runtime ids of tile changes still working (session.active_list lists them)
def runtime(sid): return hashlib.sha256(sid.encode()).hexdigest()[:8]
def find_session(asked):
    for sid in SESSIONS:
        if asked in (sid, runtime(sid)): return sid
    return None

def bot_chat_id(profile): return f'20261009_090000_bc{hashlib.sha256(profile.encode()).hexdigest()[:6]}'

def roster():
    rows = []
    for index, (name, title, about) in enumerate(BOTS):
        sid = bot_chat_id(name)
        canon = session_row(sid)
        short = {'id': sid, 'resolved_id': sid, 'title': 'Bot Chat', 'preview': canon['preview'], 'last_active': canon['last_active'],
                 'message_count': canon['message_count']}
        meta = {'title': title, 'description': about, 'pinned': name in ('default', 'deploys'), 'created': 1790000000000 + index}
        rows.append({'name': name, 'path': f'{HOME}/profiles/{name}', 'is_default': name == 'default', 'is_active': name == 'default',
                     'model': 'hermes-4', 'provider': 'nous', 'display_name': title, 'description': about,
                     'canonical_session': short, 'last_session': short, 'worker_session': None, 'sessions': [canon],
                     'ui_meta': {'hermes-bots': meta}, 'ui_meta_revisions': {'hermes-bots': 1}})
    return {'active': 'default', 'profiles': rows, 'bot_mode_protocol': True}

# ---- jobs -------------------------------------------------------------------------------------------------
JOBS = {}      # key "<profile>|<id>" → job
RUNS = {}      # job id → [run rows], newest first
RUNNING = set()
BOT_WORKING = {}   # key "<profile>|<id>" → the add-on's cron/working row (hermes-hq-push 0.9.2)

def job_record(jid, name, profile, schedule, **extra):
    job = {'id': jid, 'name': name, 'prompt': extra.pop('prompt', name), 'skills': [], 'script': None, 'no_agent': False,
           'schedule': schedule, 'schedule_display': schedule.get('display') or schedule.get('expr'), 'enabled': True,
           'state': 'scheduled', 'next_run_at': None, 'last_run_at': None, 'last_status': None, 'last_error': None,
           'deliver': 'local', 'origin': None, 'model': None, 'provider': None, 'profile': profile, 'profile_name': profile,
           'hermes_home': f'{HOME}/profiles/{profile}', 'is_default_profile': profile == 'default',
           # Hermes never stores a "running" state: a run out is the latest attempt's (cron/executions.py).
           'latest_execution': None}
    job.update(extra)
    return job

def execution(jid, status, claimed, finished=None):
    """A row of Hermes's run ledger as `latest_execution` carries it."""
    return {'id': f'exec-{jid}-{int(claimed.timestamp())}', 'job_id': jid, 'source': 'tick', 'status': status,
            'claimed_at': claimed.isoformat(), 'started_at': claimed.isoformat(),
            'finished_at': finished.isoformat() if finished else None, 'error': None}

def finish_run(job):
    """The job's run out ends: Hermes marks the job run, then completes the attempt."""
    stamp = local(now())
    job['last_run_at'] = iso(stamp); job['last_status'] = 'ok'; job['last_error'] = None
    if job.get('latest_execution'):
        job['latest_execution'].update(status='completed', finished_at=stamp.isoformat())
    for run in RUNS.get(job['id'], []):
        if run.get('is_active'): run.update(is_active=False, ended_at=now())

def seed_jobs():
    JOBS.clear(); RUNS.clear(); RUNNING.clear(); BOT_WORKING.clear()
    t0 = local(T0)
    def weekday_after(d, hour, minute_=0):
        day = (d + datetime.timedelta(days=1)).replace(hour=hour, minute=minute_, second=0, microsecond=0)
        while day.weekday() >= 5: day += datetime.timedelta(days=1)
        return day
    def weekday_before(d, hour):
        day = (d - datetime.timedelta(days=1)).replace(hour=hour, minute=0, second=0, microsecond=0)
        while day.weekday() >= 5: day -= datetime.timedelta(days=1)
        return day
    run_at = (t0 + datetime.timedelta(days=2)).replace(hour=9, minute=0, second=0, microsecond=0)
    monday = (t0 + datetime.timedelta(days=(7 - t0.weekday()) % 7 or 7)).replace(hour=6, minute=0, second=0, microsecond=0)
    east = datetime.timezone(t0.utcoffset() + datetime.timedelta(hours=5))
    zone_next = monday.replace(tzinfo=None).replace(hour=6).replace(tzinfo=east)
    quarter = minute(t0) + datetime.timedelta(minutes=15 - t0.minute % 15)
    last_triage = weekday_before(t0, 8)
    jobs = [
        job_record('j-triage', 'Morning inbox triage', 'inbox', {'kind': 'cron', 'expr': '0 8 * * 1-5', 'display': '0 8 * * 1-5'},
                   next_run_at=iso(weekday_after(t0, 8)), last_run_at=iso(last_triage), last_status='ok', deliver='origin',
                   origin={'platform': 'telegram', 'chat_id': '100000001', 'chat_name': 'Juno Example', 'thread_id': None},
                   prompt='Triage the inbox. Draft replies for anything that needs <name>, and file the rest & move on.'),
        job_record('j-watch', 'release-watch', 'deploys', {'kind': 'interval', 'minutes': 30, 'display': 'every 30m'},
                   next_run_at=iso(minute(t0) + datetime.timedelta(minutes=12)),
                   last_run_at=iso(minute(t0) - datetime.timedelta(minutes=18)), last_status='ok',
                   latest_execution=execution('j-watch', 'running', minute(t0) - datetime.timedelta(minutes=2))),
        job_record('j-once', 'Pay the venue deposit', 'inbox',
                   {'kind': 'once', 'run_at': iso(run_at), 'display': run_at.strftime('once at %Y-%m-%d %H:%M')},
                   next_run_at=iso(run_at)),
        job_record('j-paused', 'Nightly finance report', 'finance', {'kind': 'cron', 'expr': '0 2 * * *', 'display': '0 2 * * *'},
                   enabled=False, state='paused', last_run_at=iso((t0 - datetime.timedelta(days=3)).replace(hour=2, minute=0, second=0, microsecond=0)),
                   last_status='ok'),
        job_record('j-fail', 'gbrain-daily-update-check-local', 'research', {'kind': 'cron', 'expr': '0 6 * * *', 'display': '0 6 * * *'},
                   next_run_at=iso((t0 + datetime.timedelta(days=1)).replace(hour=6, minute=0, second=0, microsecond=0)),
                   last_run_at=iso(t0.replace(hour=6, minute=0, second=0, microsecond=0) - datetime.timedelta(days=0 if t0.hour >= 6 else 1)),
                   last_status='error',
                   last_error="RuntimeError: Cron job 'x' has no model configured (job.model=None). Set a per-job model via `hermes cron edit`."),
        job_record('j-late', 'Weekly reading list', 'research', {'kind': 'cron', 'expr': '0 7 * * 1', 'display': '0 7 * * 1'},
                   next_run_at=iso(minute(t0) - datetime.timedelta(minutes=20))),
        job_record('j-done', 'One-off backup', 'default',
                   {'kind': 'once', 'run_at': iso(t0 - datetime.timedelta(days=4)), 'display': 'once at ' + (t0 - datetime.timedelta(days=4)).strftime('%Y-%m-%d %H:%M')},
                   enabled=False, state='completed', last_run_at=iso(t0 - datetime.timedelta(days=4)), last_status='ok'),
        job_record('j-script', 'Disk space check', 'deploys', {'kind': 'cron', 'expr': '*/15 * * * *', 'display': '*/15 * * * *'},
                   no_agent=True, script='check_disk.sh', prompt='', next_run_at=iso(quarter),
                   last_run_at=iso(quarter - datetime.timedelta(minutes=15)), last_status='ok'),
        job_record('j-zone', 'Weekly health check', 'default', {'kind': 'cron', 'expr': '0 6 * * 1', 'display': '0 6 * * 1'},
                   next_run_at=zone_next.isoformat(timespec='seconds')),
    ]
    for job in jobs: JOBS[f"{job['profile']}|{job['id']}"] = job
    # j-triage: three agent runs (sessions), one of them the cwd-less cron session for the Artifacts check.
    triage = []
    day = last_triage
    for n in range(3):
        stamp = day.strftime('%Y%m%d_%H%M%S')
        sid = f'cron_j-triage_{stamp}'
        add_session(sid, 'inbox', f"Morning inbox triage · {day.strftime('%b')} {day.day} 08:00", [
            {'role': 'user', 'content': '[IMPORTANT: You are running as a scheduled cron job. DELIVER your answer to the origin chat.]\n\nTriage the inbox'},
            {'role': 'assistant', 'content': f'Drafted 3 replies. The full triage is in {HOME}/inbox/triage.md.'},
            {'role': 'user', 'content': 'Morning inbox triage'},
            {'role': 'assistant', 'content': 'Drafted 3 replies\n\n' + 'Three threads need you today: the contract redline, the venue deposit, and a reply to Priya. ' * 3},
        ], day.timestamp() + 60, source='cron', listed=False)
        triage.append({'id': sid, 'source': 'cron', 'title': SESSIONS[sid]['title'], 'preview': 'Drafted 3 replies', 'message_count': 4,
                       'started_at': day.timestamp(), 'last_active': day.timestamp() + 60, 'ended_at': day.timestamp() + 60,
                       'is_active': False, 'scheduler_owned': True, 'profile': 'inbox'})
        day = weekday_before(day, 8)
    RUNS['j-triage'] = triage
    watch = minute(t0) - datetime.timedelta(minutes=2)
    wsid = f"cron_j-watch_{watch.strftime('%Y%m%d_%H%M%S')}"
    add_session(wsid, 'deploys', f"release-watch · {watch.strftime('%b')} {watch.day} {watch.strftime('%H:%M')}",
                [{'role': 'user', 'content': '[CRON] Watch the release.'}, {'role': 'assistant', 'content': 'Watching the 2.4 checks.'}],
                watch.timestamp(), source='cron', listed=False)
    RUNS['j-watch'] = [{'id': wsid, 'source': 'cron', 'title': SESSIONS[wsid]['title'], 'preview': 'Watching the 2.4 checks.',
                        'message_count': 2, 'started_at': watch.timestamp(), 'last_active': now(), 'ended_at': None,
                        'is_active': True, 'scheduler_owned': True, 'profile': 'deploys'}]
    RUNS['j-script'] = [
        {'id': 'cron_output:j-script:2026-10-09_08-00-00', 'source': 'cron_output', 'title': 'COMPLETED · Disk 71% used',
         'preview': None, 'message_count': 0, 'started_at': local(T0).replace(hour=8, minute=0, second=0, microsecond=0).timestamp() - 86400,
         'last_active': None, 'ended_at': None, 'is_active': False, 'profile': 'deploys'},
        {'id': 'cron_output:j-script:exec:2', 'source': 'cron_output', 'title': 'FAILED · PermissionError: Permission denied',
         'preview': None, 'message_count': 0, 'started_at': local(T0).replace(hour=7, minute=45, second=0, microsecond=0).timestamp() - 86400,
         'last_active': None, 'ended_at': None, 'is_active': False, 'profile': 'deploys'},
    ]

RUN_DOCUMENT = ('# Cron Job: Disk space check\n\n**Job ID:** j-script\n**Run Time:** 2026-10-09 08:00:00\n\n'
                '## Prompt\n\nRun check_disk.sh and say how full the disk is.\n\n'
                '## Response\n\nDisk 71% used. The largest folder is ~/Library/Caches (12 GB).\n')

def jobs_for(profile):
    rows = list(JOBS.values())
    if profile and profile != 'all': rows = [j for j in rows if j['profile'] == profile]
    return rows

def job_by(jid, profile):
    if profile and f'{profile}|{jid}' in JOBS: return JOBS[f'{profile}|{jid}']
    return next((j for j in JOBS.values() if j['id'] == jid), None)

def broadcast(kind='cron.changed'):
    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'session_id': '', 'payload': {}}}
    for send in list(sockets):
        try: send(frame)
        except Exception: sockets.discard(send)

def trigger(job):
    key = f"{job['profile']}|{job['id']}"
    with lock:
        if key in RUNNING: return 409, {'detail': 'Job is already running or was claimed by another scheduler'}
        RUNNING.add(key)
        if not job['enabled'] or job['state'] == 'paused':
            job['enabled'] = True; job['state'] = 'scheduled'
        job['latest_execution'] = execution(job['id'], 'running', local(now()))
    broadcast()
    try:
        time.sleep(TRIGGER_SECONDS)
        with lock:
            stamp = local(now())
            if job['no_agent']:
                RUNS.setdefault(job['id'], []).insert(0, {'id': f"cron_output:{job['id']}:{stamp.strftime('%Y-%m-%d_%H-%M-%S')}",
                    'source': 'cron_output', 'title': 'COMPLETED · Disk 72% used', 'preview': None, 'message_count': 0,
                    'started_at': now(), 'last_active': None, 'ended_at': None, 'is_active': False, 'profile': job['profile']})
            else:
                sid = f"cron_{job['id']}_{stamp.strftime('%Y%m%d_%H%M%S')}"
                add_session(sid, job['profile'], f"{job['name']} · {stamp.strftime('%b')} {stamp.day} {stamp.strftime('%H:%M')}",
                            [{'role': 'user', 'content': f"[IMPORTANT: You are running as a scheduled cron job.]\n\n{job['prompt']}"},
                             {'role': 'assistant', 'content': 'Ran it now. Drafted 2 replies.'}], now(), source='cron', listed=False)
                RUNS.setdefault(job['id'], []).insert(0, {'id': sid, 'source': 'cron', 'title': SESSIONS[sid]['title'],
                    'preview': 'Ran it now. Drafted 2 replies.', 'message_count': 2, 'started_at': now() - TRIGGER_SECONDS,
                    'last_active': now(), 'ended_at': now(), 'is_active': False, 'scheduler_owned': True, 'profile': job['profile']})
            finish_run(job)
            answer = copy.deepcopy(job)
    finally:
        with lock: RUNNING.discard(key)
    broadcast()
    return 200, answer

# ---- kanban -----------------------------------------------------------------------------------------------
HOUR, DAY, MIN = 3600, 86400, 60
KCOLUMNS = ['triage', 'todo', 'scheduled', 'ready', 'running', 'blocked', 'review', 'done']
BOARDS = {}
KSTATE = {'current': 'release-2-4', 'event': 42}

def tid(title): return 't_' + hashlib.sha256(title.encode()).hexdigest()[:8]
def ktask(title, status, assignee, age, **extra):
    t0 = int(now())
    t = {'id': tid(title), 'title': title, 'status': status, 'assignee': assignee, 'priority': extra.pop('priority', 1),
         'created_at': t0 - age, 'comment_count': 0, 'link_counts': {'parents': 0, 'children': 0}, 'progress': None,
         'body': extra.pop('body', title + '.'), 'created_by': 'default', 'latest_summary': None, 'result': None,
         'workspace_path': None, 'model_override': None, 'consecutive_failures': 0, 'parents': [], 'comments': [],
         'events': [{'id': 1, 'kind': 'created', 'payload': {'status': status, 'assignee': assignee}, 'created_at': t0 - age}],
         'attachments': []}
    for key in ('started_at', 'current_run_started_at', 'last_heartbeat_at', 'completed_at'):
        if key in extra: extra[key] = t0 - extra[key]
    comments = extra.pop('comments', 0)
    for n in range(comments):
        t['comments'].append({'id': n + 1, 'author': assignee or 'default', 'created_at': t0 - age + HOUR,
                              'body': 'Want the export section first, or keep the order from the changelog?'})
    t['comment_count'] = comments
    t.update(extra); return t

def seed_kanban():
    BOARDS.clear(); KSTATE['current'] = 'release-2-4'; KSTATE['event'] = 42
    running = ktask('Run the 2.4 test suite', 'running', 'deploys', 40 * MIN, started_at=25 * MIN, current_run_started_at=25 * MIN,
                    latest_summary='148 of 212 checks passed', workspace_path='/Users/demo/.hermes/kanban/boards/release-2-4/workspaces/t_run24',
                    body='Run the whole 2.4 suite on the release branch: unit, UI and the export checks. Note anything flaky, '
                         'file a task for each real failure, write the summary to docs/release/2.4-tests.md and commit.')
    release = [
        ktask('Approve the 2.4 release notes', 'blocked', 'deploys', 3 * HOUR, block_kind='needs_input', comments=2,
              warnings={'count': 1, 'highest_severity': 'warning'}, priority=3,
              body='The notes are drafted. Needs a **yes**, or a list of changes, before the tag goes out.'),
        ktask('Confirm the venue deposit', 'blocked', 'inbox', DAY + 2 * HOUR, block_kind='needs_input', comments=1),
        ktask('Draft the launch thread', 'triage', 'research', 2 * HOUR, priority=0),
        ktask('Collect beta feedback', 'triage', None, 5 * HOUR, priority=0),
        ktask('Record the export demo', 'todo', 'deploys', DAY + 4 * HOUR, priority=2, comments=1),
        ktask('Send the September invoices', 'todo', 'finance', DAY),
        ktask('Publish the 2.4 changelog', 'todo', 'deploys', 3 * HOUR, parents=[running['id']],
              link_counts={'parents': 1, 'children': 0}, body='Waits for the test suite.'),
        ktask('Nightly finance report', 'scheduled', 'finance', 3 * DAY),
        ktask('Tidy the issue tracker', 'ready', None, 2 * HOUR),
        running,
        ktask('Summarize the open-planning paper', 'review', 'research', 6 * HOUR, result='One page, three takeaways'),
        ktask('Cut the 2.4 branch', 'done', 'deploys', 2 * DAY, completed_at=HOUR, result='Branch cut from main at a41f2c9'),
        ktask('Reconcile Q3', 'done', 'finance', 4 * DAY, completed_at=DAY, result='One duplicate charge, disputed'),
        ktask('Archive the 2.2 builds', 'done', 'deploys', 50 * DAY, completed_at=40 * DAY),
    ]
    attach = next(t for t in release if t['title'] == 'Record the export demo')
    attach['attachments'] = [{'id': 'a1', 'task_id': attach['id'], 'filename': 'demo-script.txt', 'content_type': 'text/plain',
                              'size': 64, 'uploaded_by': 'desktop', 'stored_path': '/kanban/a1', 'created_at': int(now()) - HOUR}]
    home = [ktask('Book the pump install', 'ready', 'default', 2 * DAY), ktask('Cover the tomatoes', 'todo', 'default', DAY),
            ktask('Quote for the fence', 'done', 'default', 9 * DAY, completed_at=3 * DAY)]
    BOARDS['release-2-4'] = {'name': 'Release 2.4', 'tasks': {} if EMPTY_KANBAN else {t['id']: t for t in release}}
    BOARDS['home'] = {'name': 'Home', 'tasks': {} if EMPTY_KANBAN else {t['id']: t for t in home}}

def kboard(query):
    slug = (query.get('board') or [''])[0] or KSTATE['current']
    return slug, BOARDS.get(slug)

def public(t, detail=False):
    out = {k: v for k, v in t.items() if k not in ('parents', 'comments', 'events', 'attachments')}
    out['comment_count'] = len(t['comments'])
    if detail and t['status'] == 'blocked' and t.get('block_kind') == 'needs_input':
        out['diagnostics'] = [{'kind': 'needs_input', 'severity': 'warning', 'title': 'Waiting on you',
                               'detail': 'The worker asked a question it cannot answer itself.',
                               'actions': [{'kind': 'unblock', 'label': 'Unblock'}], 'count': 1,
                               'last_seen_at': t['created_at'] + HOUR, 'data': {}}]
    return out

def event(t, kind, payload):
    KSTATE['event'] += 1
    t['events'].append({'id': KSTATE['event'], 'kind': kind, 'payload': payload, 'created_at': int(now())})

def kanban(method, path, query, body):
    if NO_KANBAN: return 404, {'detail': 'Not Found'}
    sub = path[len('/api/plugins/kanban'):]
    slug, board = kboard(query)
    if board is None and sub not in ('/boards', '/profiles', '/orchestration', '/dispatch'):
        return 404, {'detail': f'board {slug} not found'}
    if method == 'GET' and sub == '/boards':
        rows = []
        for s, b in BOARDS.items():
            live = [t for t in b['tasks'].values() if t['status'] != 'archived']
            counts = {}
            for t in live: counts[t['status']] = counts.get(t['status'], 0) + 1
            rows.append({'slug': s, 'name': b['name'], 'description': None, 'is_current': s == KSTATE['current'], 'total': len(live),
                         'counts': counts, 'default_workdir': None, 'default_workspace_kind': 'scratch', 'project_id': None, 'project_name': None})
        return 200, {'boards': rows, 'current': KSTATE['current']}
    if method == 'GET' and sub == '/board':
        live = [t for t in board['tasks'].values() if t['status'] != 'archived']
        columns = []
        for c in KCOLUMNS:
            tasks = [public(t) for t in live if t['status'] == c]
            if c == 'done': tasks.sort(key=lambda t: -(t.get('completed_at') or 0))
            columns.append({'name': c, 'tasks': tasks})
        return 200, {'columns': columns, 'tenants': [], 'assignees': sorted({t['assignee'] for t in live if t['assignee']}),
                     'latest_event_id': KSTATE['event'], 'now': int(now())}
    if method == 'GET' and sub == '/profiles':
        return 200, {'profiles': [{'name': n, 'is_default': n == 'default', 'model': 'hermes-4', 'provider': 'nous', 'description': a,
                                   'description_auto': False, 'skill_count': 4} for n, _, a in BOTS]}
    if method == 'GET' and sub == '/orchestration':
        return 200, {'orchestrator_profile': '', 'default_assignee': '', 'auto_decompose': True,
                     'resolved_orchestrator_profile': 'default', 'resolved_default_assignee': 'default'}
    if method == 'POST' and sub == '/dispatch':
        state['dispatch'] += 1
        return 200, {'spawned': []}
    if sub.startswith('/attachments/') and method == 'DELETE':
        aid = sub.split('/')[2]
        for b in BOARDS.values():
            for t in b['tasks'].values():
                if any(a['id'] == aid for a in t['attachments']):
                    t['attachments'] = [a for a in t['attachments'] if a['id'] != aid]
                    return 200, {'ok': True}
        return 404, {'detail': 'attachment not found'}
    if sub.startswith('/attachments/'):
        aid = sub.split('/')[2]
        for b in BOARDS.values():
            for t in b['tasks'].values():
                if any(a['id'] == aid for a in t['attachments']): return 200, b'Open on the export menu. Show Markdown, then JSON. Say it is twice as fast.\n'
        return 404, {'detail': 'attachment not found'}
    if method == 'POST' and sub == '/tasks':
        title = (body.get('title') or '').strip()
        if not title: return 400, {'detail': 'title cannot be empty'}
        t = ktask(title, 'triage' if body.get('triage') else 'ready', body.get('assignee'), 0, priority=body.get('priority') or 0,
                  body=body.get('body'))
        t['id'] = 't_' + hashlib.sha256(f'{title}{now()}'.encode()).hexdigest()[:8]
        board['tasks'][t['id']] = t
        event(t, 'created', {'status': t['status'], 'assignee': t['assignee']})
        return 200, {'task': public(t)}
    parts = sub.split('/')
    if len(parts) < 3 or parts[1] != 'tasks': return 404, {'detail': 'not in this fixture'}
    t = board['tasks'].get(parts[2])
    if not t: return 404, {'detail': f'task {parts[2]} not found'}
    tail = '/'.join(parts[3:])
    if method == 'GET' and tail == '':
        links = {'parents': t['parents'], 'children': [x['id'] for x in board['tasks'].values() if t['id'] in x['parents']]}
        titles = [{'id': i, 'title': board['tasks'][i]['title'], 'status': board['tasks'][i]['status']} for i in links['parents'] + links['children'] if i in board['tasks']]
        return 200, {'task': public(t, detail=True), 'comments': t['comments'], 'events': t['events'], 'attachments': t['attachments'],
                     'links': links, 'link_tasks': titles, 'child_results': [],
                     'runs': [{'id': 1, 'profile': t['assignee'], 'status': 'done', 'outcome': 'completed', 'summary': t.get('result'),
                               'error': None, 'started_at': t['created_at'], 'ended_at': t['created_at'] + HOUR}] if t['status'] == 'done' else []}
    if method == 'POST' and tail == 'attachments':
        up = body.get('__upload') or {'filename': 'file', 'size': 0}
        aid = 'a' + hashlib.sha256(f"{up['filename']}{now()}".encode()).hexdigest()[:6]
        record = {'id': aid, 'task_id': t['id'], 'filename': up['filename'], 'content_type': 'application/octet-stream',
                  'size': up['size'], 'uploaded_by': 'desktop', 'stored_path': f'/kanban/{aid}', 'created_at': int(now())}
        t['attachments'].append(record)
        return 200, {'attachment': record}
    if method == 'DELETE' and tail.startswith('attachments/'):
        aid = tail.split('/')[1]
        t['attachments'] = [a for a in t['attachments'] if a['id'] != aid]
        return 200, {'ok': True}
    if method == 'GET' and tail == 'log':
        running = t['status'] == 'running'
        return 200, {'task_id': t['id'], 'path': '/fixture/worker.log', 'exists': running, 'size_bytes': 80 if running else 0,
                     'content': 'Checked out release/2.4\nRunning 212 checks...\n148 passed so far\n' if running else '', 'truncated': False}
    if method == 'PATCH' and tail == '':
        if 'status' in body:
            to = body['status']
            if to == 'running': return 400, {'detail': "Cannot set status to 'running' directly; use the dispatcher/claim path"}
            if to not in KCOLUMNS + ['archived']: return 400, {'detail': f'unknown status: {to}'}
            if to in ('scheduled', 'review'): return 409, {'detail': f"status transition to '{to}' not valid from current state"}
            if to == 'ready':
                blocking = [board['tasks'][p] for p in t['parents'] if p in board['tasks'] and board['tasks'][p]['status'] != 'done']
                if blocking:
                    b = blocking[0]
                    return 409, {'detail': f"Cannot move to 'ready': blocked by parent(s) not done — '{b['title']}' ({b['id']}, status={b['status']})"}
            t['status'] = to
            if to == 'done': t['completed_at'] = int(now())
            event(t, 'status', {'status': to})
        if 'priority' in body:
            t['priority'] = body['priority']; event(t, 'reprioritized', {'priority': body['priority']})
        if 'body' in body: t['body'] = body['body']; event(t, 'edited', {'field': 'body'})
        if 'title' in body:
            if not str(body['title']).strip(): return 400, {'detail': 'title cannot be empty'}
            t['title'] = body['title']
        return 200, {'task': public(t)}
    if method == 'DELETE' and tail == '':
        del board['tasks'][t['id']]
        return 200, {'deleted': True, 'task_id': t['id']}
    if method == 'POST' and tail == 'comments':
        text = (body.get('body') or '').strip()
        if not text: return 400, {'detail': 'comment body cannot be empty'}
        t['comments'].append({'id': len(t['comments']) + 1, 'author': body.get('author') or 'desktop', 'body': text, 'created_at': int(now())})
        event(t, 'commented', {'author': body.get('author') or 'desktop'})
        return 200, {'ok': True}
    if method == 'POST' and tail == 'reassign':
        t['assignee'] = body.get('profile') or None
        event(t, 'assigned', {'assignee': t['assignee']})
        return 200, {'ok': True, 'task_id': t['id'], 'assignee': t['assignee']}
    if method == 'POST' and tail == 'reclaim':
        if t['status'] != 'running': return 409, {'detail': f"cannot reclaim {t['id']}: not in a claimable state"}
        t['status'] = 'ready'; event(t, 'reclaimed', {})
        return 200, {'ok': True}
    if method == 'POST' and tail == 'estimate':
        return 200, {'ok': True, 'est_tokens': 42000, 'complexity': 'M'}
    return 404, {'detail': 'not in this fixture'}

# ---- tasks ([tasks], hermes-hq-push 0.9.32) ----------------------------------------------------------------
TASKS = {}
TPAGES = {}   # [tasks] what a bot wrote on each task's Task Page (hermes-hq-push 0.9.38's task_pages)
TSTATE = {'rev': 0, 'settings': {}, 'sections': []}
OFFERS = []   # [task-lists] hermes-hq-push 0.9.55: what bots offered (a list with tasks for it); nothing changes until you tap
TASK_LISTS = False   # --task-lists: start with lists, a kept list, a waiting offer and its chat (seed_task_lists)
LIST_COLORS = ('blue', 'green', 'orange', 'red', 'purple', 'pink', 'teal', 'yellow', 'gray')
LIST_KEYS = ('color', 'icon', 'bot', 'adds', 'today')
NO_TASKS = False
TASKS_CHAT = False
TASKS_JSON = None   # --tasks-json: a list exported from a real tasks.db (kept out of git), shown first
TASKS_ROUTE = '/api/plugins/hermes-hq-push/tasks'
# [goals] hermes-hq-push 0.9.65 (docs/goals.md): goals beside the list, sharing its rev. --task-goals (or
# /__fixture/tasks-mode {"goals": true}) turns goals on and seeds five made-up ones (seed_task_goals); {"goals": "empty"}
# turns them on with none. Otherwise, or as an older add-on (older_addon), `goals` is left out and the routes answer 404
# (the add-on the tests written before goals expect).
GOALS = {}
GOALS_ROUTE = '/api/plugins/hermes-hq-push/goals'
TASK_GOALS = False
GOAL_SEEDS = 0   # how many times seed_task_goals has run (its revs climb)
GOALS_ON = False   # the add-on keeps goals (0.9.65)
GOAL_STATUSES = ('active', 'paused', 'achieved', 'let_go')

# [plugin-pages] The "notes" page plugin's bundle: the dashboard SDK's components, its own API.
NOTES_PAGE_JS = r"""
(function () {
  const SDK = window.__HERMES_PLUGIN_SDK__;
  const h = SDK.React.createElement;
  const { useState, useEffect } = SDK.hooks;
  const { Card, CardHeader, CardTitle, CardContent, Button, Badge } = SDK.components;
  function Notes() {
    const [items, setItems] = useState(null);
    const [error, setError] = useState(null);
    const load = () => SDK.fetchJSON('/api/plugins/notes/items').then(r => setItems(r.items)).catch(e => setError(String(e.message || e)));
    useEffect(() => { load(); }, []);
    if (error) return h('div', { className: 'p-4' }, 'Error: ' + error);
    if (!items) return h('div', { className: 'p-4' }, 'Loading…');
    return h('div', { className: 'flex flex-col gap-3 p-4' },
      h('div', { className: 'flex items-center gap-2' }, h('h1', { className: 'text-xl font-semibold' }, 'Notes Board'), h(Badge, null, items.length + ' notes')),
      items.map((n, i) => h(Card, { key: i }, h(CardHeader, null, h(CardTitle, null, n.title)), h(CardContent, null, n.body))),
      h(Button, { onClick: load }, 'Refresh'));
  }
  window.__HERMES_PLUGINS__.register('notes', Notes);
})();
"""
TMODE = {'older_addon': False}   # [task-ideas] POST /__fixture/tasks-mode: act as an add-on before 0.9.39 (no Ideas)
IDEAS = {}    # [task-ideas] hermes-hq-push 0.9.39's task_ideas: suggested tasks, newest first; off until turned on
ISTATE = {'ran_at': None, 'asked_at': None}

def seed_tasks():
    TASKS.clear()
    TPAGES.clear()
    TSTATE['rev'] = 7 + int(time.time()) % 100000 * 10   # a new run never answers `unchanged` to the last run's cache
    TSTATE['settings'] = {'enabled': True, 'capture': 'ask', 'prep_per_day': 6, 'quiet_start': '22:00', 'quiet_end': '08:00', 'prep_every_hours': 3,
                          'group': 'smart', 'sort': 'smart', 'ideas': False, 'ideas_bot': 'default', 'ideas_at': '07:30', 'ideas_max': 3}
    TSTATE['sections'] = []
    OFFERS.clear()
    t0 = local(T0)
    today = t0.date()
    def day(n): return (today + datetime.timedelta(days=n)).isoformat()
    def at(n, hour, minute_=0): return iso(datetime.datetime.combine(today + datetime.timedelta(days=n), datetime.time(hour, minute_)).astimezone())
    def ago(minutes): return iso(t0 - datetime.timedelta(minutes=minutes))
    def step(i, title, who, done=False): return {'id': f's{i}', 'title': title, 'who': who, 'done': done}
    def task(tid, title, who='me', bot=None, status='open', note='', due=None, prep=False, steps=(), made=(), notes='',
             source=None, created=600, updated=None, repeat=None, done_at=None, log=()):
        TASKS[tid] = {'id': tid, 'rev': 3, 'title': title, 'notes': notes, 'who': who, 'bot': bot, 'status': status,
                      'status_note': note, 'due': due, 'repeat': repeat, 'prep': prep, 'steps': list(steps), 'made': list(made),
                      'source': source or {'kind': 'app'}, 'created_at': ago(created), 'updated_at': ago(updated if updated is not None else created),
                      'done_at': done_at, 'created_by': 'you' if not source or source.get('kind') != 'chat' else bot or 'default',
                      'log': list(log), 'section': None, 'position': (t0 - datetime.timedelta(minutes=created)).timestamp(),
                      'watch': '', 'chat': {},
                      # [tasks-first] hermes-hq-push 0.9.53: 0 none, 1 high, 2 medium, 3 low; minutes before; a day.
                      'priority': 0, 'tags': [], 'alert': None, 'starts': None}
    chat = lambda profile: {'kind': 'chat', 'profile': profile, 'session_id': 's-tasks' if profile == 'default' else bot_chat_id(profile)}
    task('t_dentist', 'Call the dentist', who='together', bot='default', status='ready', note='Number and a Dec 9 slot',
         due=day(0), prep=True, source=chat('default'), created=95, updated=12,
         notes="**Dr. Lee Dental** · (512) 555-0142\nOpen until 5:00 PM today\n\nYour last cleaning was May 2, so you're due. "
               "They have **Dec 9 at 10 AM** open.",
         steps=[step(1, 'Find the office number', 'bot', True), step(2, 'Check when I last went', 'bot', True),
                step(3, 'Call and book', 'me'), step(4, 'Add it to my calendar', 'bot')],
         made=[{'id': 'm1', 'title': 'Office hours and number', 'kind': 'note', 'ref': 'Dr. Lee Dental, (512) 555-0142. Mon-Fri 8-5.'},
               {'id': 'm2', 'title': 'Insurance card (from Files)', 'kind': 'file', 'ref': f'{HOME}/documents/insurance-card.pdf'}],
         log=[{'at': ago(95), 'by': 'default', 'text': 'Added from your chat'},
              {'at': ago(40), 'by': 'default', 'text': 'Found the office number'},
              {'at': ago(12), 'by': 'default', 'text': 'Ready: Number and a Dec 9 slot'}])
    task('t_ivy', 'Reply to Ivy about the venue', who='together', bot='default', status='ready', note='Draft ready',
         due=at(0, 17), prep=True, source=chat('default'), created=300, updated=30,
         steps=[step(1, 'Draft a reply', 'bot', True), step(2, 'Read it and send', 'me')],
         made=[{'id': 'm3', 'title': 'Reply to Ivy (draft)', 'kind': 'note', 'ref': 'Hi Ivy, the Elm Room works for us on the 14th...'}],
         log=[{'at': ago(30), 'by': 'default', 'text': 'Ready: Draft ready'}])
    task('t_passport', 'Renew passport', who='together', bot='default', status='working', note='Filling in the form',
         due=day(0), prep=True, source=chat('default'), created=95, updated=20,
         steps=[step(1, 'Find the renewal form', 'bot', True), step(2, 'Fill in what I know', 'bot', True),
                step(3, 'Get a new photo', 'me'), step(4, 'Mail it with the old passport', 'me')])
    task('t_cleaning', 'Pick up dry cleaning', due=at(0, 18), created=200)
    task('t_invoices', 'Summarize October invoices', who='bot', bot='finance', status='working', note='3 of 5 accounts',
         due=day(1), prep=True, created=500, updated=8,
         steps=[step(1, 'Pull the invoices', 'bot', True), step(2, 'Total by account', 'bot'), step(3, 'Write the summary', 'bot')])
    task('t_venues', 'Find 3 venues for the party', who='bot', bot='research', status='needs_you', note='What’s the budget?',
         due=day(4), prep=True, created=900, updated=25,
         log=[{'at': ago(25), 'by': 'research', 'text': 'Needs you: What’s the budget?'}])
    task('t_gift', 'Mom’s birthday gift', who='together', bot='default', due=day(8), created=1500)
    task('t_porch', 'Fix the porch light', created=4000)
    task('t_water', 'Pay the water bill', status='done', due=day(0), created=3000, updated=90, done_at=ago(90), repeat='monthly')
    task('t_flights', 'Book flights to Austin', who='together', bot='default', status='done', created=5000, updated=1500, done_at=ago(1500))
    # [tasks] UX pass 2026-11-04: shaped like the owner's first live tasks (places and numbers invented). A shortlist
    # written as one paragraph, a 200-character step, the bare "working"/"ready" log lines of 0.9.32/0.9.33, and paths.
    shortlist = f'{HOME}/documents/team-lunch-shortlist.md'
    task('t_lunch', 'Pick a spot for Friday’s team lunch', who='together', bot='default', status='ready',
         note='3 spots ready. Elm & Oak is my pick; pick one and give headcount', due=day(2), prep=True, created=60, updated=5,
         steps=[step(1, 'Shortlist 3 lunch spots near the office (100 Main St) for Fri: group-friendly, takes reservations or '
                        'large-party walk-ins, ~1hr lunch-friendly, with price range, drive time, and', 'bot', True),
                step(2, 'Pick one, confirm headcount, and approve the reservation', 'me')],
         made=[{'id': 'm4', 'title': 'Lunch shortlist: Elm & Oak (pick), Copper Kettle, Bayside Grill (+ Juniper Diner alt)',
                'kind': 'note',
                'ref': 'Elm & Oak: 410 Aspen Dr, ~5 min, $25 lunch prix fixe, book online up to 8 / call 9+ (512) 555-0168. '
                       'Copper Kettle: 402 Aspen Dr, ~5 min, ~$$, OpenTable + semi-private/patio for groups. Bayside Grill: '
                       '15 W Main St, ~6 min, $$-$$$, online up to 4 / call 5+ (512) 555-0177. Alt: Juniper Diner, 17 Harbor '
                       f'Blvd, ~4 min, call (512) 555-0190. Full table: {shortlist}'},
               {'id': 'm5', 'title': 'Shortlist file', 'kind': 'file', 'ref': shortlist}],
         log=[{'at': ago(60), 'by': 'default', 'text': 'Hermes taking the shortlist; you pick + approve booking.'},
              {'at': ago(58), 'by': 'default', 'text': 'working'}, {'at': ago(5), 'by': 'default', 'text': 'ready'}])
    task('t_apps', 'Go through the open job applications', due=at(0, 17), created=120, updated=20, source=chat('default'),
         notes='9 open (Design 3, Support 4, Ops 2). The review flagged what to check: 2 Support date + 1 '
               'Support place mismatches; Ops question wording flaw; 1 Design link broken.',
         log=[{'at': ago(100), 'by': 'default', 'text': f'Prep sheet ready: {HOME}/documents/review-sheet.md (9 open, 3 to check first).'},
              {'at': ago(20), 'by': 'default', 'text': 'Due corrected to today 5 PM'}])

    # [tasks-first] What a task manager's task has (0.9.53): a priority (the circle's colour), tags, an alert before
    # it's due, a file of your own, and a start day (it is in Today from then until it's due).
    TASKS['t_apps'].update(priority=1, tags=['hiring', 'q4'], alert=30)
    TASKS['t_apps']['made'].append({'id': 'm_y1', 'title': 'resume-review.pdf', 'kind': 'file',
                                    'ref': f'{HOME}/task-files/t_apps/resume-review.pdf', 'by': 'you'})
    TASKS['t_cleaning'].update(priority=2)
    TASKS['t_porch'].update(priority=3, tags=['home'])
    task('t_taxes', 'Gather the tax papers', due=day(12), created=2500)
    TASKS['t_taxes'].update(priority=2, tags=['money'], starts=day(-1))

    # [tasks] A task is a workspace (2026-11-04): Inbox watches for a reply and keeps the task's own chat.
    task('t_contract', 'Follow up with Ivy on the contract', who='together', bot='inbox', status='ready',
         note='No reply yet; a nudge is drafted', due=at(1, 10), prep=True, source=chat('inbox'), created=180, updated=15,
         steps=[step(1, 'Check for Ivy’s reply', 'bot', True), step(2, 'Draft a nudge', 'bot', True), step(3, 'Send the nudge', 'me')],
         made=[{'id': 'm6', 'title': 'Nudge to Ivy (draft)', 'kind': 'note',
                'ref': 'Hi Ivy, checking in on the contract. Anything you need from me to get it signed this week?'}],
         log=[{'at': ago(180), 'by': 'inbox', 'text': 'Added from your chat'}, {'at': ago(15), 'by': 'inbox', 'text': 'Ready: No reply yet; a nudge is drafted'}])
    TASKS['t_contract']['watch'] = 'a reply from Ivy with the signed contract, by email'
    # [tasks] 0.9.47 (owner 2026-11-09, the plain task view): one-tap answers, what Inbox just changed, its next look.
    TASKS['t_contract']['choices'] = ['Send the nudge', 'Let me edit it', 'Wait a day']
    TASKS['t_contract']['next_check'] = at(1, 9)
    TASKS['t_contract']['log'].append({'at': ago(15), 'by': 'inbox', 'text': 'Ticked \u201cDraft a nudge\u201d', 'kind': 'change'})
    TASKS['t_venues']['choices'] = ['Under $2,000', 'Under $5,000', 'Not sure yet']
    csid = '20261104_090000_tcsam01'
    add_session(csid, 'inbox', 'Task: Follow up with Ivy on the contract · t_cont', [
        {'role': 'user', 'content': 'Can you keep an eye out for it?\n\nAbout my task “Follow up with Ivy on the contract”\n(Task id t_contract)'},
        {'role': 'assistant', 'content': 'Yes. I’ll check your email an hour before it’s due. If Ivy has replied, I’ll tell you what Ivy said; '
                                         'if not, a short nudge will be ready to send.'},
        {'role': 'user', 'content': 'Keep the nudge friendly, not pushy.'},
        {'role': 'assistant', 'content': 'Done. The draft is under **Made**: one line, friendly, asks if Ivy needs anything from you.'},
    ], (t0 - datetime.timedelta(minutes=15)).timestamp(), hidden=True, listed=False)
    TASKS['t_contract']['chat'] = {'profile': 'inbox', 'session_id': csid}

    # [tasks] Owner's screenshot 2026-11-08: a long needs-you task (a long summary, the same draft saved twice, a reply
    # draft, three steps) whose brief met its chat in a jumble. Names and links invented.
    task('t_redlines', 'Follow up with Dana on Fixture Co redlines', who='together', bot='default', status='needs_you',
         note='Send the reply to Lee, or tell me it already went?', due=at(1, 8), prep=True, source=chat('default'),
         created=900, updated=720,
         steps=[step(1, 'Find Dana\u2019s redlines', 'bot', True), step(2, 'Draft a reply to Lee', 'bot'),
                step(3, 'Send the reply', 'me')],
         made=[{'id': 'm7', 'title': 'Nudge draft to Dana', 'kind': 'link', 'ref': 'https://sparkmailapp.com/d/1a2b'},
               {'id': 'm8', 'title': 'Nudge draft to Dana', 'kind': 'link', 'ref': 'https://sparkmailapp.com/d/3c4d'},
               {'id': 'm9', 'title': 'Reply to Lee (draft)', 'kind': 'link', 'ref': 'https://sparkmailapp.com/d/5e6f'}],
         log=[{'at': ago(900), 'by': 'default', 'text': 'Added from your chat'},
              {'at': ago(720), 'by': 'default', 'text': 'Needs you: Send the reply to Lee, or tell me it already went?'}])
    rsid = '20261107_170000_tcred01'
    add_session(rsid, 'default', 'Task: Follow up with Dana on Fixture Co redlines · t_redl', [
        {'role': 'user', 'content': 'Remind me Monday morning.\n\nAbout my task \u201cFollow up with Dana on Fixture Co redlines\u201d\n(Task id t_redlines)'},
        {'role': 'assistant', 'content': 'Will do. Monday at 8 AM I\u2019ll message you here in chat. Before it goes out, I\u2019ll check '
                                         'whether you\u2019ve already sent the reply, so if you have, it\u2019ll just confirm that instead.\n\n'
                                         'The draft to Lee is still waiting in your Spark drafts, with Dana cc\u2019d. Enjoy your weekend.'},
    ], (t0 - datetime.timedelta(minutes=19)).timestamp(), hidden=True, listed=False)
    TASKS['t_redlines']['chat'] = {'profile': 'default', 'session_id': rsid}
    TPAGES['t_redlines'] = {
        'summary': 'Dana\u2019s redlines came in Thursday at 4:15 PM, in Fixture Co\u2019s own shared doc. She struck auto-renewal and '
                   'the pay-through-termination clause, and asked about the Order Form fees. A reply to Lee is drafted.',
        'next': 'Monday 8 AM I\u2019ll message you to send the draft to Lee (or confirm it already went).', 'blocks': []}
    TASKS['t_redlines']['page_at'] = ago(720)

    # [tasks] Task Pages (0.9.38): what Inbox and Hermes wrote on two of them (names and numbers invented).
    TPAGES['t_contract'] = {
        'summary': 'No reply from Ivy yet. A friendly nudge is drafted and ready for you to send.',
        'next': 'You send the nudge; I check your email again tomorrow at 9 AM.',
        'blocks': [{'title': 'At a Glance', 'numbers': [{'label': 'Days since you sent it', 'value': '3'},
                                                        {'label': 'Emails checked', 'value': '14'}]},
                   {'title': 'What I Checked', 'text': '- [x] Your inbox and the **Contracts** folder\n- [x] Ivy’s out-of-office: none\n- [ ] A reply with the signed copy'}]}
    TASKS['t_contract']['page_at'] = ago(15)
    TPAGES['t_lunch'] = {
        'summary': '3 spots shortlisted near the office. **Elm & Oak** is my pick: 5 minutes away, $25 lunch, books online.',
        'next': 'You pick one and give the headcount; I hold the table.',
        'blocks': [{'title': 'Options', 'table': {'columns': ['Spot', 'Price', 'Drive', 'Booking'],
                                                  'rows': [['Elm & Oak', '$25 prix fixe', '5 min', 'Online up to 8'],
                                                           ['Copper Kettle', '$$', '5 min', 'OpenTable, patio'],
                                                           ['Bayside Grill', '$$-$$$', '6 min', 'Call for 5+']]}}]}
    TASKS['t_lunch']['page_at'] = ago(5)

    # [tasks] Ask First 2026-11-04: what bots added from chats weeks ago and nobody touched since sits under "Still
    # Need These?" (Keep / Done / Delete). One a bot works on, or with a date, is not asked about.
    task('t_desk', 'Look into a standing desk', source=chat('default'), created=20 * 1440)
    task('t_sitter', 'Find a plant sitter for December', source=chat('default'), created=17 * 1440)
    task('t_recipes', 'Collect the soup recipes from the group chat', who='together', bot='research', source=chat('research'),
         created=15 * 1440, steps=[step(1, 'Gather the recipes into one note', 'bot'), step(2, 'Pick two to try', 'me')])
    seed_ideas()
    if TASK_LISTS: seed_task_lists()
    global GOALS_ON
    GOALS.clear()
    GOALS_ON = TASK_GOALS
    if TASK_GOALS: seed_task_goals()

def seed_task_goals():
    """[goals] Step 1's boards (docs/goals.md, boards 1 and 2), with every name invented: a goal with a number, a date
    and five milestones (two done, the third open with its tasks); one with milestones and no number; one with only
    tasks; one paused; one achieved."""
    global GOAL_SEEDS
    GOALS.clear()
    # Each seeding's revs start above the last one's: the app keeps a task it holds at a higher rev than a read's (a
    # gateway's revs never go back), so a reset after a test ticked these tasks would otherwise keep them ticked.
    GOAL_SEEDS += 1
    seed_rev = 2 + GOAL_SEEDS * 100
    t0 = local(T0)
    today = t0.date()
    def day(n): return (today + datetime.timedelta(days=n)).isoformat()
    def ago_days(n): return iso(t0 - datetime.timedelta(days=n))
    def at(n, hour, minute_=0): return iso(datetime.datetime.combine(today + datetime.timedelta(days=n), datetime.time(hour, minute_)).astimezone())
    def milestone(mid, title, due, done_days=None):
        return {'id': mid, 'title': title, 'due': due, 'done': done_days is not None,
                'done_at': ago_days(done_days) if done_days is not None else None}
    def goal(gid, title, why='', status='active', status_days=None, color='blue', due=None, created_days=30, measure=None,
             milestones=(), order=0):
        GOALS[gid] = {'id': gid, 'rev': seed_rev, 'title': title, 'why': why, 'status': status,
                      'status_at': ago_days(status_days if status_days is not None else created_days), 'color': color, 'due': due,
                      'position': t0.timestamp() - 10_000 + order * 10, 'measure': measure,
                      'milestones': list(milestones), 'created_at': ago_days(created_days), 'updated_at': ago_days(1),
                      'log': [{'at': ago_days(created_days), 'by': 'you', 'text': 'Added'}]}
    def readings(values, days_back):
        return [{'at': ago_days(d), 'value': v} for v, d in zip(values, days_back)]
    def gtask(tid, title, goal_id, milestone_id=None, due=None, done_days=None, created=None, who='me', bot=None, status=None):
        stamp = ago_days(created if created is not None else 20)
        TASKS[tid] = {'id': tid, 'rev': seed_rev, 'title': title, 'notes': '', 'who': who, 'bot': bot,
                      'status': status or ('done' if done_days is not None else 'open'), 'status_note': '', 'due': due, 'repeat': None,
                      'prep': False, 'steps': [], 'made': [], 'source': {'kind': 'app'}, 'created_at': stamp, 'updated_at': stamp,
                      'done_at': ago_days(done_days) if done_days is not None else None, 'created_by': 'you', 'log': [],
                      'section': None, 'position': (t0 - datetime.timedelta(days=created if created is not None else 20)).timestamp(),
                      'watch': '', 'chat': {}, 'priority': 0, 'tags': [], 'alert': None, 'starts': None,
                      'goal': goal_id, 'milestone': milestone_id}
    # A number, a date and five milestones: 340 of 1,000, 48 days to go, an even pace would be 42% today (a week behind).
    goal('g_testers', '1,000 public testers', why='So the public launch opens to a crowd, not an empty room.', color='blue',
         due=day(48), created_days=36, order=0,
         measure={'unit': 'testers', 'start': 0, 'target': 1000, 'now': 340, 'at': ago_days(2), 'source': 'you',
                  'history': readings([60, 180, 250, 340], [26, 15, 8, 2])},
         milestones=[milestone('ms_beta', 'Beta page live on the website', day(-25), 25),
                     milestone('ms_250', 'First 250 testers', day(-12), 9),
                     milestone('ms_launch', 'Launch week', day(6)),
                     milestone('ms_500', '500 testers', day(27)),
                     milestone('ms_1000', '1,000 testers', day(48))])
    gtask('t_g_email', 'Write the launch email', 'g_testers', 'ms_launch', done_days=1, created=6)
    gtask('t_g_notes', 'Post the build notes to the forum', 'g_testers', 'ms_launch', due=day(0), created=5)
    gtask('t_g_reviews', 'Reply to the three beta reviews', 'g_testers', 'ms_launch', created=4)
    gtask('t_g_demo', 'Record the 60 second demo', 'g_testers', 'ms_launch', due=day(3), created=3)
    # Milestones and no number: one of four done, on pace for a day 17 weeks away; two tasks under the open one, one loose.
    goal('g_10k', 'Run a 10K', why='I said I would. A friend is running it too.', color='orange', due=day(120), created_days=40, order=1,
         milestones=[milestone('ms_2mi', 'Run 2 miles without stopping', day(-14), 14),
                     milestone('ms_5k', 'Run a 5K', day(18)),
                     milestone('ms_5mi', 'Run 5 miles', day(60)),
                     milestone('ms_race', 'Race day', day(120))])
    gtask('t_g_easy', 'Easy 3 mile run', 'g_10k', 'ms_5k', due=at(0, 17, 30), created=10)
    gtask('t_g_shoes', 'Buy real running shoes', 'g_10k', 'ms_5k', due=day(4), created=9)
    gtask('t_g_signup', 'Sign up for the race', 'g_10k', created=8)
    # Only tasks: four of six done, with Hermes helping on the next one.
    goal('g_trip', 'Family trip to the coast', color='green', due=day(13), created_days=20, order=2)
    for n, title in enumerate(['Pick the week', 'Book the cabin', 'Ask about the dog sitter', 'Rent the car seat']):
        gtask(f't_g_trip{n}', title, 'g_trip', done_days=10 - n * 2, created=19 - n)
    gtask('t_g_tickets', 'Book the aquarium tickets', 'g_trip', created=12, who='together', bot='default')
    gtask('t_g_pack', 'Make the packing list', 'g_trip', created=11)
    # Someday: paused 18 days ago, with one task waiting.
    goal('g_spanish', 'Learn conversational Spanish', why='To talk with the neighbours in their own words.', status='paused',
         status_days=18, color='purple', created_days=60, order=3,
         milestones=[milestone('ms_es1', 'Finish the first course', day(-30), 30), milestone('ms_es2', 'A ten minute chat', None)])
    gtask('t_g_lesson', 'Book a trial lesson', 'g_spanish', 'ms_es2', created=40)
    # Achieved three days ago.
    goal('g_books', 'Read 12 books this year', status='achieved', status_days=3, color='teal', due=day(40), created_days=200, order=4,
         measure={'unit': 'books', 'start': 0, 'target': 12, 'now': 12, 'at': ago_days(3), 'source': 'you',
                  'history': readings([4, 8, 12], [120, 60, 3])})
    TSTATE['rev'] += 1

def goals_shown():
    return [copy.deepcopy(g) for g in sorted(GOALS.values(), key=lambda g: (g['position'], g['id']))]

def goal_milestones(raw, was):
    """A PATCH's or POST's milestone list: in order, 30 at most; a known id keeps its done_at (unless its tick changed),
    one without an id gets one."""
    known = {m['id']: m for m in (was or [])}
    stamp = iso(local(now()))
    out = []
    for i, item in enumerate((raw or [])[:30]):
        title = (item.get('title') or '').strip()[:120]
        if not title: continue
        mid = item.get('id') if item.get('id') in known else 'ms_' + hashlib.sha256(f'{title}{now()}{i}'.encode()).hexdigest()[:8]
        done = bool(item.get('done'))
        before = known.get(mid)
        done_at = (before or {}).get('done_at') if before and before.get('done') == done else (stamp if done else None)
        out.append({'id': mid, 'title': title, 'due': item.get('due') or None, 'done': done, 'done_at': done_at})
    return out

def goal_measure(raw, was):
    if raw is None: return None
    stamp = iso(local(now()))
    start = float(raw.get('start') or 0); target = float(raw.get('target') or 0)
    measure = {'unit': (raw.get('unit') or '')[:20], 'start': start, 'target': target, 'source': 'you',
               'now': (was or {}).get('now', start), 'at': (was or {}).get('at'), 'history': list((was or {}).get('history') or [])}
    if 'now' in raw and raw['now'] is not None and float(raw['now']) != measure['now']:
        measure['now'] = float(raw['now']); measure['at'] = stamp
        measure['history'] = (measure['history'] + [{'at': stamp, 'value': measure['now']}])[-60:]
    return measure

def goals_route(method, path, body):
    if NO_TASKS or TMODE['older_addon'] or not GOALS_ON: return 404, {'detail': 'Not Found'}
    rest = path[len(GOALS_ROUTE):].strip('/')
    stamp = iso(local(now()))
    if rest == '' and method == 'POST':
        title = (body.get('title') or '').strip()[:200]
        if not title: return 422, {'detail': 'title is required'}
        gid = hashlib.sha256(f'{title}{now()}'.encode()).hexdigest()[:32]
        used = {g['color'] for g in GOALS.values() if g['status'] == 'active'}
        color = body.get('color') if body.get('color') in LIST_COLORS else next((c for c in LIST_COLORS if c not in used), 'blue')
        goal = {'id': gid, 'rev': 1, 'title': title, 'why': (body.get('why') or '')[:300], 'status': 'active', 'status_at': stamp,
                'color': color, 'due': body.get('due') or None, 'position': now(), 'measure': None,
                'milestones': goal_milestones(body.get('milestones'), []), 'created_at': stamp, 'updated_at': stamp,
                'log': [{'at': stamp, 'by': 'you', 'text': 'Added'}]}
        if body.get('measure'): goal['measure'] = goal_measure(dict(body['measure'], now=body['measure'].get('now', body['measure'].get('start'))), None)
        GOALS[gid] = goal; TSTATE['rev'] += 1
        return 200, copy.deepcopy(goal)
    goal = GOALS.get(unquote(rest))
    if not goal: return 404, {'detail': 'Goal not found'}
    if method == 'DELETE':
        GOALS.pop(goal['id'], None)
        for t in TASKS.values():
            if t.get('goal') == goal['id']: t['goal'] = None; t['milestone'] = None; t['rev'] += 1
        TSTATE['rev'] += 1
        return 200, {'ok': True}
    if method == 'PATCH':
        if int(body.get('rev', -1)) != goal['rev']: return 409, {'detail': {'goal': copy.deepcopy(goal)}}
        for key in ('title', 'why', 'color', 'position', 'due'):
            if key in body: goal[key] = body[key]
        if 'status' in body and body['status'] in GOAL_STATUSES and body['status'] != goal['status']:
            goal['status'] = body['status']; goal['status_at'] = stamp
            goal['log'].append({'at': stamp, 'by': 'you', 'text': f"Status: {body['status']}"})
        if 'measure' in body: goal['measure'] = goal_measure(body['measure'], goal['measure'])
        if 'measure_now' in body and goal['measure'] is not None:
            goal['measure'] = goal_measure(dict(goal['measure'], now=body['measure_now']), goal['measure'])
        if 'milestones' in body:
            goal['milestones'] = goal_milestones(body['milestones'], goal['milestones'])
            kept = {m['id'] for m in goal['milestones']}
            for t in TASKS.values():
                if t.get('goal') == goal['id'] and t.get('milestone') and t['milestone'] not in kept: t['milestone'] = None; t['rev'] += 1
        goal['log'] = goal['log'][-50:]
        goal['rev'] += 1; goal['updated_at'] = stamp; TSTATE['rev'] += 1
        return 200, copy.deepcopy(goal)
    return 405, {'detail': 'Method Not Allowed'}

def task_goal_fields(task, body):
    """[goals] A task's goal and milestone as the add-on keeps them: an unknown goal is a 400 (None), clearing the goal
    clears the milestone, and a milestone that isn't one of the goal's is cleared."""
    if TMODE['older_addon']: return True
    if 'goal' in body:
        if body['goal'] and body['goal'] not in GOALS: return None
        task['goal'] = body['goal'] or None
        if not task['goal']: task['milestone'] = None
    if 'milestone' in body: task['milestone'] = body['milestone'] or None
    goal = GOALS.get(task.get('goal') or '')
    if not goal or task.get('milestone') not in {m['id'] for m in goal['milestones']}: task['milestone'] = None
    return True

def seed_task_lists():
    """[task-lists] hermes-hq-push 0.9.55, the six boards the owner agreed to (2026-11-14): a Work list Hermes keeps,
    a Home list, tasks in drag order with no dates, one with where Hermes found it, one Hermes offers to close, and a
    list Hermes offers in a chat ('s-lists'). Every name and figure is invented."""
    t0 = local(T0)
    today = t0.date()
    def ago(minutes): return iso(t0 - datetime.timedelta(minutes=minutes))
    def day(n): return (today + datetime.timedelta(days=n)).isoformat()
    checked = iso(datetime.datetime.combine(today, datetime.time(8, 2)).astimezone())
    TSTATE['sections'] = [{'id': 'sec_work', 'name': 'Work', 'color': 'blue', 'icon': 'briefcase', 'bot': 'default', 'checked_at': checked},
                          {'id': 'sec_home', 'name': 'Home', 'color': 'green', 'icon': 'house'}]
    def mine(tid, title, section, place, by='you', source=None, **more):
        TASKS[tid] = {'id': tid, 'rev': 2, 'title': title, 'notes': '', 'who': 'me', 'bot': None, 'status': 'open', 'status_note': '',
                      'due': None, 'repeat': None, 'prep': False, 'steps': [], 'made': [], 'source': source or {'kind': 'app'},
                      'created_at': ago(3000 + place), 'updated_at': ago(3000 + place), 'done_at': None, 'created_by': by,
                      'log': [], 'section': section, 'position': float(place), 'watch': '', 'chat': {},
                      'priority': 0, 'tags': [], 'alert': None, 'starts': None}
        TASKS[tid].update(more)
    found = lambda who, n, ref: {'kind': 'chat', 'profile': 'default', 'session_id': bot_chat_id('default'),
                                 'from': {'app': 'Email', 'who': who, 'at': day(n), 'ref': ref, 'link': f'https://mail.example.com/t/{ref}'}}
    mine('t_w_deck', 'Send Wren the revised deck', 'sec_work', 1, by='default', source=found('Wren', -1, 'deck-41'))
    mine('t_w_budget', 'Approve the Q1 budget sheet', 'sec_work', 2, by='default', source=found('Juno', -2, 'budget-7'),
         offer={'kind': 'done', 'by': 'default', 'text': 'Juno wrote back that the sheet is approved', 'at': ago(40)})
    mine('t_w_review', 'Write Otto’s review notes', 'sec_work', 3)
    mine('t_w_vendor', 'Call the print vendor back', 'sec_work', 4, by='default', source=found('Herald', -3, 'print-12'))
    mine('t_w_roadmap', 'Draft the roadmap update', 'sec_work', 5)
    mine('t_w_expenses', 'File October expenses', 'sec_work', 6)
    mine('t_h_filter', 'Change the air filter', 'sec_home', 1)
    mine('t_h_gutters', 'Get a quote for the gutters', 'sec_home', 2)
    for tid, section in (('t_apps', 'sec_work'), ('t_porch', 'sec_home'), ('t_cleaning', 'sec_home')):
        if tid in TASKS: TASKS[tid]['section'] = section
    offer = {'id': 'of_party', 'bot': 'default', 'session_id': 's-lists', 'at': ago(6), 'list': 'Party', 'section': None, 'new': True,
             'why': 'Four things came up for the party while we talked, and two tasks you already have belong with them.',
             'tasks': [{'title': 'Send the invitations', 'due': day(3)}, {'title': 'Order the cake', 'due': day(6)},
                       {'title': 'Book the DJ'}, {'title': 'Make a playlist'}],
             'move': [{'id': tid, 'title': TASKS[tid]['title']} for tid in ('t_gift', 't_ivy') if tid in TASKS],
             'state': 'new', 'move_state': None, 'listed': None, 'added': [], 'answered_at': None}
    OFFERS[:] = [o for o in OFFERS if o['id'] != offer['id']] + [offer]   # asked twice: still one offer
    call = {'list': 'Party', 'why': offer['why'], 'tasks': offer['tasks'], 'move': [m['id'] for m in offer['move']]}
    add_session('s-lists', 'default', 'Party planning', [
        {'role': 'user', 'content': 'Help me keep the party planning on track. Invitations, cake, a DJ and a playlist are all still open.'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_o1', 'type': 'function', 'function': {'name': 'tasks_offer', 'arguments': json.dumps(call)}}]},
        {'role': 'tool', 'tool_call_id': 'call_o1', 'tool_name': 'tasks_offer', 'content': json.dumps({
            'offer': offer_shown(offer), 'say': 'Offered. Nothing is added until they tap the card.'})},
        {'role': 'assistant', 'content': 'I can keep those together in a Party list. Nothing is added until you tap the card.'},
    ], T0 - 360)

def offer_shown(offer):
    out = {k: copy.deepcopy(v) for k, v in offer.items() if k != 'made'}
    if out.get('move_state') is None: out.pop('move_state', None)
    if out.get('listed') is None: out.pop('listed', None)
    if out.get('answered_at') is None: out.pop('answered_at', None)
    return out

def offers_shown():
    since = iso(local(now() - 86400))
    return [offer_shown(o) for o in OFFERS if o['state'] == 'new' or (o.get('answered_at') or '') >= since]

def answer_offer(oid, body, stamp):
    """POST /tasks/offers/{id} (hermes-hq-push 0.9.55): accept (the list is made, kept by the bot, and the tasks go on;
    `list: false` adds them to no list), decline, move / leave (the tasks already on the page), undo."""
    action = body.get('action')
    if action not in ('accept', 'decline', 'move', 'leave', 'undo'): return 400, {'detail': 'action must be accept, decline, move, leave or undo.'}
    offer = next((o for o in OFFERS if o['id'] == oid), None)
    if offer is None: return 404, {'detail': 'No such offer.'}
    made = offer.setdefault('made', {})
    def home():
        wanted = offer.get('section') or made.get('section')
        if wanted and any(x['id'] == wanted for x in TSTATE['sections']): return wanted
        named = next((x for x in TSTATE['sections'] if x['name'].casefold() == offer['list'].casefold()), None)
        if named: return named['id']
        used = {x.get('color') for x in TSTATE['sections']}
        fresh = {'id': 'sec_' + hashlib.sha256(f"{offer['list']}{now()}".encode()).hexdigest()[:8], 'name': offer['list'],
                 'color': next((c for c in LIST_COLORS if c not in used), LIST_COLORS[0]), 'bot': offer['bot']}
        TSTATE['sections'].append(fresh); made['section'] = fresh['id']
        return fresh['id']
    if action == 'decline':
        if offer['state'] != 'new': return 409, {'detail': 'That offer was already answered.'}
        offer.update(state='declined', answered_at=stamp)
    elif action == 'accept':
        if offer['state'] != 'new': return 409, {'detail': 'That offer was already answered.'}
        target = home() if (body.get('list', True) is not False or not offer.get('new')) else None
        added = []
        for index, item in enumerate(offer['tasks']):
            tid = 't_' + hashlib.sha256(f"{item['title']}{now()}{index}".encode()).hexdigest()[:10]
            source = {'kind': 'chat', 'profile': offer['bot'], 'session_id': offer.get('session_id') or ''}
            if item.get('source'): source['from'] = item['source']
            TASKS[tid] = {'id': tid, 'rev': 1, 'title': item['title'], 'notes': item.get('notes') or '', 'who': 'me', 'bot': None,
                          'status': 'open', 'status_note': '', 'due': item.get('due'), 'repeat': None, 'prep': False, 'steps': [],
                          'made': [], 'source': source, 'created_at': stamp, 'updated_at': stamp, 'done_at': None,
                          'created_by': offer['bot'], 'log': [{'at': stamp, 'by': offer['bot'], 'text': 'Added'}], 'section': target,
                          'position': now() + index / 1000, 'watch': '', 'chat': {}, 'priority': 0, 'tags': [], 'alert': None, 'starts': None}
            added.append(tid)
        made['added'] = added
        offer.update(state='accepted', answered_at=stamp, listed=target is not None, added=added)
        if offer.get('move'): offer['move_state'] = 'new' if target is not None else 'left'
    elif action in ('move', 'leave'):
        if offer['state'] != 'accepted' or offer.get('move_state') != 'new': return 409, {'detail': 'Nothing is waiting to be moved.'}
        if action == 'move':
            target, moved = home(), made.setdefault('moved', {})
            for row in offer['move']:
                task = TASKS.get(row['id'])
                if task and task['status'] != 'done' and task.get('section') != target:
                    moved[row['id']] = task.get('section'); task['section'] = target; task['rev'] += 1
            offer['move_state'] = 'moved'
        else:
            offer['move_state'] = 'left'
        offer['answered_at'] = stamp
    else:
        if offer['state'] != 'accepted': return 409, {'detail': 'There is nothing to undo.'}
        for tid in made.get('added') or []: TASKS.pop(tid, None)
        kept = {x['id'] for x in TSTATE['sections']}
        for tid, old in (made.get('moved') or {}).items():
            if tid in TASKS: TASKS[tid]['section'] = old if old in kept else None; TASKS[tid]['rev'] += 1
        mine = made.get('section')
        if mine and not any(t.get('section') == mine for t in TASKS.values()):
            TSTATE['sections'] = [x for x in TSTATE['sections'] if x['id'] != mine]
        offer.update(state='undone', answered_at=stamp, added=[], made={})
        if offer.get('move'): offer['move_state'] = None
    TSTATE['rev'] += 1
    return 200, {'rev': TSTATE['rev'], 'offer': offer_shown(offer), 'sections': copy.deepcopy(TSTATE['sections'])}

def idea_row(iid, title, why='', source='', who='me', bot='default', help='', created=None):
    return {'id': iid, 'created_at': created or iso(local(now())), 'bot': bot, 'title': title, 'why': why, 'source': source,
            'who': who, 'help': help, 'state': 'new', 'task_id': None, 'decided_at': None}

def seed_ideas():
    IDEAS.clear()
    t0 = local(T0)
    def ago(minutes): return iso(t0 - datetime.timedelta(minutes=minutes))
    for row in (
        idea_row('i_registration', 'Renew the car registration', created=ago(182), source='Chat with Hermes, Mon',
                 why='You said it runs out at the end of the month, and the renewal needs the inspection done first.'),
        idea_row('i_internet', 'Compare internet plans before the promo ends', who='together', bot='finance', created=ago(181),
                 source='Chat with Finance, Tue', why='Your promo price ends on the 20th, and you asked which plans cost less.',
                 help='Compare the three plans you named and list the monthly prices.'),
        idea_row('i_offsite', 'Book the team offsite venue', who='together', bot='inbox', created=ago(180),
                 source='Chat with Inbox, yesterday', why='The offsite is in three weeks and the thread never picked a venue.',
                 help='Find three venues near the office for 12 people and draft the booking request.'),
    ):
        IDEAS[row['id']] = row
    ISTATE.update(ran_at=ago(180), asked_at=None)

def ideas_on(): return bool(TSTATE['settings'].get('ideas')) and TSTATE['settings'].get('enabled', True)

def ideas_new(): return sorted((i for i in IDEAS.values() if i['state'] == 'new'), key=lambda i: i['created_at'], reverse=True)

def ideas_page():
    st = TSTATE['settings']
    looking = bool(ISTATE['asked_at']) and ISTATE['asked_at'] > (ISTATE['ran_at'] or '')
    return {'on': ideas_on(), 'bot': st['ideas_bot'], 'at': st['ideas_at'], 'max': st['ideas_max'],
            'ideas': copy.deepcopy(ideas_new()), 'ran_at': ISTATE['ran_at'], 'looking': looking}

def ideas_looked():
    # Look Now's run answers 3 s later with one more idea.
    with lock:
        row = idea_row('i_meals', 'Plan dinners for next week', who='together', bot='research', source='Chat with Research, today',
                       why='You saved the soup recipes and said you want to cook more at home.',
                       help='Pick five dinners from your recipes and make one shopping list.')
        IDEAS.setdefault(row['id'], row)
        ISTATE['ran_at'] = iso(local(now()))
        TSTATE['rev'] += 1

def ideas_route(method, rest, body):
    if rest == 'ideas' and method == 'GET': return 200, ideas_page()
    if rest == 'ideas/run' and method == 'POST':
        if not ideas_on(): return 409, {'detail': 'Ideas is off.'}
        asked = ISTATE['asked_at']
        if asked and asked > iso(local(now() - 900)) and asked > (ISTATE['ran_at'] or ''): return 200, {'started': False}
        ISTATE['asked_at'] = iso(local(now()))
        threading.Timer(3, ideas_looked).start()
        return 200, {'started': True}
    parts = rest.split('/')
    if len(parts) != 3 or method != 'POST': return 405, {'detail': 'Method Not Allowed'}
    row = IDEAS.get(unquote(parts[1]))
    if not row: return 404, {'detail': 'No such idea.'}
    stamp = iso(local(now()))
    if parts[2] == 'dismiss':
        if row['state'] not in ('new', 'expired'): return 409, {'detail': 'That idea was already decided.'}
        row.update(state='dismissed', decided_at=stamp); TSTATE['rev'] += 1
        return 200, {'idea': copy.deepcopy(row)}
    if parts[2] == 'restore':
        if row['state'] != 'dismissed': return 409, {'detail': 'That idea was already decided.'}
        row.update(state='new', decided_at=None); TSTATE['rev'] += 1
        return 200, {'idea': copy.deepcopy(row)}
    if parts[2] == 'add':
        if row['state'] not in ('new', 'expired'): return 409, {'detail': 'That idea was already decided.'}
        start = bool(body.get('start')) and row['who'] != 'me'
        notes = '\n\n'.join(x for x in (row['why'], row['help']) if x)
        code, task = tasks_route('POST', TASKS_ROUTE, {}, {'title': row['title'], 'notes': notes, 'who': row['who'],
                                                         'bot': row['bot'], 'prep': start,
                                                         'source': {'kind': 'idea', 'idea': row['id'], 'profile': row['bot']}})
        if code != 200: return code, task
        if start:
            TASKS[task['id']].update(status='working', status_note='Getting it ready'); task = copy.deepcopy(TASKS[task['id']])
        row.update(state='added', task_id=task['id'], decided_at=stamp); TSTATE['rev'] += 1
        return 200, {'idea': copy.deepcopy(row), 'task': task, 'already': False}
    return 405, {'detail': 'Method Not Allowed'}

def load_tasks_json():
    if not TASKS_JSON: return
    for task in json.load(open(TASKS_JSON)):
        TASKS[task['id']] = task
    TSTATE['rev'] += 1

def tshown(task):
    """A task as the routes send it: with its Task Page's summary and next (hermes-hq-push 0.9.43), each ≤ 300
    characters, an empty one left out, and no `page` at all when the bot wrote neither."""
    out = copy.deepcopy(task)
    body = TPAGES.get(task['id']) or {}
    gist = {k: (body.get(k) or '').strip()[:300] for k in ('summary', 'next') if (body.get(k) or '').strip()}
    if gist: out['page'] = gist
    return out

def tasks_list(since):
    rev = TSTATE['rev']
    if since and since.isdigit() and int(since) == rev: return 200, {'rev': rev, 'unchanged': True}
    rows = sorted(TASKS.values(), key=lambda t: t['created_at'], reverse=True)
    answer = {'rev': rev, 'tasks': [tshown(t) for t in rows], 'settings': dict(TSTATE['settings']),
              'sections': copy.deepcopy(TSTATE['sections']), 'pages': True, 'ideas': len(ideas_new()) if ideas_on() else 0,
              'fields': True, 'files': True,   # [tasks-first] 0.9.53
              'lists': True, 'offers': offers_shown()}   # [task-lists] 0.9.55
    if GOALS_ON: answer['goals'] = goals_shown()   # [goals] 0.9.65
    if TMODE['older_addon']:
        answer.pop('ideas'); answer.pop('fields'); answer.pop('files'); answer.pop('lists'); answer.pop('offers'); answer.pop('goals', None)
        answer['sections'] = [{'id': x['id'], 'name': x['name']} for x in answer['sections']]
        hide = ('priority', 'tags', 'alert', 'starts', 'offer', 'edited', 'goal', 'milestone')
        answer['tasks'] = [{k: v for k, v in t.items() if k not in hide} for t in answer['tasks']]
        answer['settings'] = {k: v for k, v in answer['settings'].items() if not k.startswith('ideas')}
    return 200, answer

def tasks_route(method, path, query, body):
    if NO_TASKS: return 404, {'detail': 'Not Found'}
    rest = path[len(TASKS_ROUTE):].strip('/')
    stamp = iso(local(now()))
    if rest == '' and method == 'GET': return tasks_list((query.get('since') or [''])[0])
    if rest == '' and method == 'POST':
        title = (body.get('title') or '').strip()
        if not title: return 422, {'detail': 'title is required'}
        tid = 't_' + hashlib.sha256(f'{title}{now()}'.encode()).hexdigest()[:10]
        who = body.get('who') or 'me'
        task = {'id': tid, 'rev': 1, 'title': title, 'notes': body.get('notes') or '', 'who': who,
                'bot': (body.get('bot') or 'default') if who != 'me' else None, 'status': 'open', 'status_note': '',
                'due': body.get('due'), 'repeat': body.get('repeat') if who != 'bot' else None, 'prep': bool(body.get('prep')),
                'priority': body.get('priority') if body.get('priority') in (1, 2, 3) else 0,
                'tags': [str(x)[:30] for x in (body.get('tags') or [])][:10], 'alert': body.get('alert'), 'starts': body.get('starts'),
                'steps': [dict(s, id=s.get('id') or f's{i + 1}', done=bool(s.get('done'))) for i, s in enumerate(body.get('steps') or [])],
                'made': [], 'source': body.get('source') or {'kind': 'app'}, 'created_at': stamp, 'updated_at': stamp,
                'done_at': None, 'created_by': 'you', 'log': [{'at': stamp, 'by': 'you', 'text': 'Added'}],
                'section': body.get('section') if body.get('section') in {x['id'] for x in TSTATE['sections']} else None,
                'position': body.get('position') or now(), 'watch': body.get('watch') or '', 'chat': body.get('chat') or {},
                'goal': None, 'milestone': None}
        if task_goal_fields(task, body) is None: return 400, {'detail': 'Unknown goal'}   # [goals]
        TASKS[tid] = task; TSTATE['rev'] += 1
        return 200, copy.deepcopy(task)
    if rest == 'ideas' or rest.startswith('ideas/'):
        if TMODE['older_addon']: return 404, {'detail': 'Not Found'}
        return ideas_route(method, rest, body)
    if rest.startswith('prep-job/') and method == 'POST':
        return 200, {'ok': True}
    if rest == 'sections':   # hermes-hq-push 0.9.36: the whole list in order; a deleted one's tasks go to no section
        if method == 'PUT':
            clean, was = [], {x['id']: x for x in TSTATE['sections']}
            for i, x in enumerate(body.get('sections') or []):
                name = (x.get('name') or '').strip()[:60]
                if not name: continue
                sid = x.get('id') or 'sec_' + hashlib.sha256(f'{name}{now()}{i}'.encode()).hexdigest()[:8]
                # [task-lists] 0.9.55: a field left out is kept, an empty one is cleared; `today` is stored only when off
                row = dict(was.get(sid) or {}, id=sid, name=name)
                for key in LIST_KEYS if not TMODE['older_addon'] else ():
                    if key not in x: continue
                    if x[key] in (None, '') or (key == 'today' and x[key] is not False): row.pop(key, None)
                    else: row[key] = x[key]
                clean.append(row)
            kept = {x['id'] for x in clean}
            for t in TASKS.values():
                if t.get('section') and t['section'] not in kept: t['section'] = None; t['rev'] += 1
            TSTATE['sections'] = clean; TSTATE['rev'] += 1
        return 200, {'rev': TSTATE['rev'], 'sections': copy.deepcopy(TSTATE['sections'])}
    if rest.startswith('offers/') and method == 'POST':   # [task-lists] 0.9.55
        if TMODE['older_addon']: return 404, {'detail': 'Not Found'}
        return answer_offer(unquote(rest[len('offers/'):]), body, stamp)
    if rest == 'settings':
        if method == 'PUT':
            TSTATE['settings'].update({k: v for k, v in body.items() if k in TSTATE['settings']}); TSTATE['rev'] += 1
        return 200, dict(TSTATE['settings'])
    if rest.endswith('/page') and method == 'GET':   # hermes-hq-push 0.9.38: the task's Task Page, drawn now
        task = TASKS.get(unquote(rest[:-len('/page')]))
        if not task: return 404, {'detail': 'Task not found'}
        spec = importlib.util.spec_from_file_location('task_page', TASK_PAGE)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        try: names = json.loads((query.get('names') or ['{}'])[0])
        except ValueError: names = {}
        page = module.render(task, TPAGES.get(task['id']), names if isinstance(names, dict) else {})
        return 200, ('text/html; charset=utf-8', page.encode())
    # [tasks-first] hermes-hq-push 0.9.53: your own link, or a file as base64 (kept where the file routes find it).
    if rest.endswith('/attach') and method == 'POST':
        task = TASKS.get(unquote(rest[:-len('/attach')]))
        if not task: return 404, {'detail': 'Task not found'}
        if TMODE['older_addon']: return 404, {'detail': 'Not Found'}
        mid = 'm_' + hashlib.sha256(f'{len(task["made"])}{now()}'.encode()).hexdigest()[:8]
        if body.get('kind') == 'link':
            url = (body.get('url') or '').strip()
            if not url: return 400, {'detail': 'A link needs its address.'}
            entry = {'id': mid, 'title': (body.get('title') or '').strip() or url, 'kind': 'link', 'ref': url, 'by': 'you'}
        elif body.get('kind') == 'file':
            try: data = base64.b64decode(body.get('data') or '', validate=True)
            except ValueError: return 400, {'detail': 'The file could not be read.'}
            if not data: return 400, {'detail': 'The file is empty.'}
            name = pathlib.PurePosixPath((body.get('name') or 'file').replace('\\', '/')).name or 'file'
            (FILES / name).write_bytes(data)
            entry = {'id': mid, 'title': name, 'kind': 'file', 'ref': f'{HOME}/task-files/{task["id"]}/{name}', 'by': 'you'}
        else:
            return 400, {'detail': 'Attach a link or a file.'}
        task['made'].append(entry)
        task['log'].append({'at': stamp, 'by': 'you', 'text': f"Added {entry['title']}"})
        task['rev'] += 1; task['updated_at'] = stamp; TSTATE['rev'] += 1
        return 200, tshown(task)
    if '/made/' in rest and method == 'DELETE':
        tid, _, mid = rest.partition('/made/')
        task = TASKS.get(unquote(tid))
        if not task: return 404, {'detail': 'Task not found'}
        task['made'] = [m for m in task['made'] if m.get('id') != unquote(mid)]
        task['rev'] += 1; task['updated_at'] = stamp; TSTATE['rev'] += 1
        return 200, tshown(task)
    task = TASKS.get(unquote(rest))
    if not task: return 404, {'detail': 'Task not found'}
    if method == 'DELETE':
        TASKS.pop(task['id'], None); TSTATE['rev'] += 1
        return 200, {'ok': True}
    if method == 'PATCH':
        if int(body.get('rev', -1)) != task['rev']: return 409, {'detail': {'task': tshown(task)}}
        if body.get('goal') and body['goal'] not in GOALS and not TMODE['older_addon']: return 400, {'detail': 'Unknown goal'}
        for key, value in body.items():
            if key in ('rev', 'id', 'created_at', 'created_by', 'log', 'keep_open', 'goal', 'milestone'): continue
            task[key] = value
        task_goal_fields(task, body)   # [goals]
        if body.get('keep_open') and task.get('offer'): task['offer']['kept'] = True   # [task-lists] the bot isn't to ask again
        if body.get('status') == 'done': task.pop('offer', None)
        if any(k in body for k in ('title', 'notes', 'due')): task['edited'] = True
        if 'status' in body:
            task['done_at'] = stamp if body['status'] == 'done' else None
            task['log'].append({'at': stamp, 'by': 'you', 'text': 'Marked done' if body['status'] == 'done' else f"Status: {body['status']}"})
        task['rev'] += 1; task['updated_at'] = stamp; TSTATE['rev'] += 1
        return 200, tshown(task)
    return 405, {'detail': 'Method Not Allowed'}

def addon_status():
    flags = ['seal', 'ownChats', 'quietStandIns', 'desktopOpens', 'askCards', 'pagePreviews', 'warmup', 'desktopForward',
             'gatewayLogins', 'namedSites', 'deviceAccess', 'liveSteps', 'liveEnds', 'liveQuick', 'terminal']
    body = {flag: True for flag in flags}
    body.update({'replies': 'watcher', 'deviceAccessKinds': ['contacts', 'calendar', 'reminders', 'location', 'photos'],
                 'pluginVersion': '0.9.31' if NO_TASKS else '0.9.44'})
    if not NO_TASKS: body.update(tasks=True, task_pages=True, task_ideas=not TMODE['older_addon'],
                                 task_fields=not TMODE['older_addon'], task_files=not TMODE['older_addon'],
                                 task_goals=GOALS_ON and not TMODE['older_addon'])   # [goals] 0.9.65
    if TMODE['older_addon']: body['pluginVersion'] = '0.9.38'
    return 200, body

# ---- artifacts --------------------------------------------------------------------------------------------
def tool(name, payload): return {'role': 'tool', 'tool_name': name, 'content': json.dumps(payload)}

def seed_sessions():
    SESSIONS.clear()
    base = minute(local(T0)).timestamp()
    for index, (name, title, _) in enumerate(BOTS):
        add_session(bot_chat_id(name), name, 'Bot Chat', [
            {'role': 'user', 'content': 'Morning. Anything for me?'},
            {'role': 'assistant', 'content': f'Morning. {title} here: nothing urgent today.'},
        ], base - 3600 * (index + 1), hidden=True)
    # [tasks] Mockup 4-chat: Hermes adds two tasks with tasks_add; the card goes under its reply.
    def added(tid, title, due):
        return json.dumps({'id': tid, 'rev': 1, 'title': title, 'who': 'together', 'bot': 'default', 'status': 'open', 'due': due,
                           'undo': "Say 'undo' and I'll remove it, or tap Undo in the app"})
    week = (local(T0).date() + datetime.timedelta(days=2)).isoformat()
    later = (local(T0).date() + datetime.timedelta(days=16)).isoformat()
    exchange = [
        {'role': 'user', 'content': 'Ugh, I need to call the dentist this week. And renew my passport before Austin.'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_t1', 'type': 'function', 'function': {'name': 'tasks_add', 'arguments': json.dumps({'title': 'Call the dentist', 'who': 'together', 'due': week, 'prep': True})}},
            {'id': 'call_t2', 'type': 'function', 'function': {'name': 'tasks_add', 'arguments': json.dumps({'title': 'Renew passport', 'who': 'together', 'due': later, 'prep': True})}}]},
        {'role': 'tool', 'tool_call_id': 'call_t1', 'tool_name': 'tasks_add', 'content': added('t_dentist', 'Call the dentist', week)},
        {'role': 'tool', 'tool_call_id': 'call_t2', 'tool_name': 'tasks_add', 'content': added('t_passport', 'Renew passport', later)},
        {'role': 'assistant', 'content': "On it. I added both to your Tasks. I'll find the dentist's number now and start the passport form tonight."},
    ]
    add_session('s-tasks', 'default', 'Dentist and passport', copy.deepcopy(exchange), base - 60)
    # [tasks] hermes-hq-push 0.9.33 (owner, build 755: "it just added it to my to-do list"): a task of yours alone gets
    # "Ask Hermes to Help"; one Hermes can help with is split into steps and its own step starts at once.
    today5 = local(T0).replace(hour=17, minute=0, second=0, microsecond=0).isoformat(timespec='seconds')
    helped = [
        {'role': 'user', 'content': 'Remind me to call the vet tomorrow.'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_t3', 'type': 'function', 'function': {'name': 'tasks_add', 'arguments': json.dumps({'title': 'Call the vet', 'due': 'tomorrow'})}}]},
        {'role': 'tool', 'tool_call_id': 'call_t3', 'tool_name': 'tasks_add', 'content': json.dumps({
            'id': 't_vet', 'rev': 1, 'title': 'Call the vet', 'who': 'me', 'bot': None, 'status': 'open', 'steps': [], 'prep': False,
            'due': (local(T0).date() + datetime.timedelta(days=1)).isoformat(), 'due_said': 'tomorrow',
            'undo': "Say 'undo' and I'll remove it, or tap Undo in the app"})},
        {'role': 'assistant', 'content': "Added for tomorrow."},
        {'role': 'user', 'content': "I've really gotta remember to go through all of these job applications today."},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_t4', 'type': 'function', 'function': {'name': 'tasks_add', 'arguments': json.dumps({
                'title': 'Go through the open job applications in ADP', 'who': 'together', 'due': 'today 17:00', 'prep': True, 'start_now': True,
                'steps': [{'title': 'Rank all 167, flagged mismatches first', 'who': 'bot'},
                          {'title': 'Review the shortlist', 'who': 'me'}, {'title': 'Move the keepers forward in ADP', 'who': 'me'}]})}}]},
        {'role': 'tool', 'tool_call_id': 'call_t4', 'tool_name': 'tasks_add', 'content': json.dumps({
            'id': 't_apps', 'rev': 1, 'title': 'Go through the open job applications in ADP', 'who': 'together', 'bot': 'default',
            'status': 'open', 'due': today5, 'due_said': 'today, 5:00 PM', 'prep': True,
            'steps': [{'id': 'a1', 'title': 'Rank all 167, flagged mismatches first', 'who': 'bot', 'done': False},
                      {'id': 'a2', 'title': 'Review the shortlist', 'who': 'me', 'done': False},
                      {'id': 'a3', 'title': 'Move the keepers forward in ADP', 'who': 'me', 'done': False}],
            'start': 'started: your Task prep job is working on your step in the background now',
            'undo': "Say 'undo' and I'll remove it, or tap Undo in the app"})},
        {'role': 'assistant', 'content': "Added for today at 5 PM, and I've started on my part: I'm ranking all 167, "
                                         "with the 25 that Juno flagged at the top. You'll get the shortlist well "
                                         "before 5, so all you'll have to do is review it."},
    ]
    # Its own chat too, below the dentist one (testTasks_AskToHelp).
    add_session('s-help', 'default', 'Job applications', copy.deepcopy(helped), base - 1800)
    if TASKS_CHAT:   # --tasks-chat: Hermes's own Bot Chat ends with it too (-HQDebugOpenBot default opens it)
        chat = SESSIONS[bot_chat_id('default')]
        chat['messages'] += [dict(m, id=len(chat['messages']) + i + 1) for i, m in enumerate(copy.deepcopy(exchange + helped))]
        for i, m in enumerate(chat['messages']): m['timestamp'] = base - 60 - (len(chat['messages']) - i) * 5
        chat['last_active'] = base - 60
    research = f'{HOME}/reading'
    # HQN_FIXTURE_LONG_CHAT=1: earlier turns above it, so the transcript reaches under the bar (top edge shots).
    earlier = [m for n in range(8) for m in (
        {'role': 'user', 'content': f'What about paper {n + 1}?'},
        {'role': 'assistant', 'content': f'**Paper {n + 1}** is worth a skim. It shows each step as it happens, which makes '
                                         'long tasks easier to trust, and the appendix has the numbers if you want them.'},
    )] if os.environ.get('HQN_FIXTURE_LONG_CHAT') else []
    add_session('s-reading', 'research', 'Anything worth reading?', earlier + [
        {'role': 'user', 'content': 'Anything worth reading this morning?'},
        {'role': 'assistant', 'content': f'I put a one-page summary in {research}/summary.md and the chart in {research}/results.png. '
                                         'Sources: https://example.org/papers/open-planning and https://example.org/papers/long-memory'},
    ], base - 300)
    add_session('s-report', 'deploys', 'The 2.4 report', [
        {'role': 'user', 'content': 'Send me the report and the page.'},
        {'role': 'assistant', 'content': f'MEDIA:{HOME}/out/report.pdf'},
        {'role': 'assistant', 'content': 'Open [the page](#media:%2Fhome%2Fhermes%2Fsite%2Findex.html)'},
        {'role': 'assistant', 'content': f'MEDIA:{HOME}/app/Sources/App.swift'},
    ], base - 900)
    # HQN_FIXTURE_TILES=<folder>: every .html in it is a page a bot handed over (Dashboard tiles made with the add-on's
    # kit, for pictures of the Tiles page), newest first by name.
    tiles_folder = os.environ.get('HQN_FIXTURE_TILES')
    if tiles_folder:
        FILES.mkdir(parents=True, exist_ok=True)
        pages = sorted(pathlib.Path(tiles_folder).glob('*.html'))
        for page in pages: (FILES / page.name).write_text(page.read_text())
        add_session('s-tiles', 'default', 'My dashboard tiles', [{'role': 'user', 'content': 'Make my tiles.'}] + [
            {'role': 'assistant', 'content': f'MEDIA:{HOME}/tiles/{page.name}'} for page in pages], base - 60)
    add_session('s-release', 'deploys', 'Ship the 2.4 release notes', [
        {'role': 'user', 'content': 'Ship the 2.4 release notes.'},
        tool('write_file', {'path': f'{HOME}/app/release-notes.md'}),
        tool('terminal', {'output': f'Saved {HOME}/data/export.csv\nDownloading https://files.pythonhosted.org/packages/x/y/pkg-1.0-py3-none-any.whl'}),
        tool('read_file', {'path': f'{HOME}/app/CHANGELOG.md'}),
        {'role': 'assistant', 'content': 'Done. The notes are drafted.'},
    ], base - 3 * 3600)
    add_session('s-cut', 'inbox', 'A cut-off link', [
        {'role': 'user', 'content': 'Where is the telephony doc?'},
        {'role': 'assistant', 'content': 'see https://example.co…'},
    ], base - 26 * 3600)
    add_session('s-cron-nofolder', 'inbox', 'Morning inbox triage · run without a folder', [
        {'role': 'user', 'content': '[CRON] Summarize.'},
        {'role': 'assistant', 'content': 'wrote ./out/summary.md'},
    ], base - 27 * 3600, source='cron', cwd='')
    add_session('s-missing', 'research', 'An old chart', [
        {'role': 'user', 'content': 'Where did the old chart go?'},
        {'role': 'assistant', 'content': f'{HOME}/gone/old.png'},
    ], base - 2 * 86400)
    add_session('s-big', 'finance', 'The big log', [
        {'role': 'user', 'content': 'Show me the import log.'},
        {'role': 'assistant', 'content': f'{HOME}/big/log.txt'},
    ], base - 3 * 86400)
    for n in range(36):
        add_session(f's-note-{n:02d}', 'research', f'Reading note {n + 1}', [
            {'role': 'user', 'content': f'Note {n + 1}?'}, {'role': 'assistant', 'content': f'Reading note {n + 1}: nothing to keep.'},
        ], base - (4 + n) * 86400)

def listed_sessions(profile):
    rows = [session_row(sid) for sid, s in SESSIONS.items() if s['listed'] and (profile in ('', 'all') or s['profile'] == profile)]
    return sorted(rows, key=lambda r: -r['last_active'])

def png(width, height, pixel):
    raw = b''.join(b'\0' + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))
    chunk = lambda kind, data: struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

def pdf_one_page(text):
    stream = f'BT /F1 24 Tf 72 720 Td ({text}) Tj ET'.encode()
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
               b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    out, offsets = b'%PDF-1.4\n', []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out)); out += f'{i} 0 obj\n'.encode() + body + b'\nendobj\n'
    xref = len(out)
    out += f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'.encode() + b''.join(f'{o:010d} 00000 n \n'.encode() for o in offsets)
    out += f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return out

def make_files(port):
    FILES.mkdir(parents=True, exist_ok=True)
    for kept in FILES.glob('*.versions'): shutil.rmtree(kept, ignore_errors=True)   # [tile-versions] a run starts with none kept
    (FILES / 'summary.md').write_text('---\ntitle: Morning reading\ntags:\n- agents\n- memory\n---\n\n# Morning reading\n\n'
                                      '**Agents that plan in the open.** Showing each step as it happens makes long tasks easier to trust.\n\n'
                                      '- Small models, long memory\n- Evaluating tool use\n\n```python\nprint("three papers")\n```\n\n'
                                      '## Mail removed\n\n'   # [preview-tables] wider than the page: a card that scrolls sideways
                                      '| Sender | Date confirmed | Note |\n|---|---|---|\n'
                                      '| MailPrefs (most junk) | 2026-10-18 | active to 2036 |\n'
                                      '| Catalog list (credit/insurance offers) | 2026-10-18 | 5 yrs |\n'
                                      '| Shop A, Shop B, Shop C, Shop D | 2026-10-18–21 | web form confirmed |\n'
                                      '| Shop E | 2026-10-21 | 6–8 wks |\n\nWatch the mail for 6–8 weeks.\n')
    bars = [(.35, (46, 196, 182)), (.55, (0, 83, 253)), (.8, (148, 121, 255)), (.62, (255, 102, 173)), (.92, (255, 160, 67))]
    def pixel(x, y):
        u = (x - 45) / 62; column = int(u) if u >= 0 else -1; inside = 0 <= column < 5 and u % 1 < .72
        if inside and 350 - bars[column][0] * 280 < y < 350: return bars[column][1]
        return (10, 10, 10) if 350 <= y < 353 and 35 < x < 365 else (247, 245, 240)
    (FILES / 'results.png').write_bytes(png(400, 400, pixel))
    (FILES / 'report.pdf').write_bytes(pdf_one_page('Release 2.4 report'))
    (FILES / 'team-lunch-shortlist.md').write_text('# Friday team lunch\n\n| Place | Drive | Price | Book |\n|---|---|---|---|\n'
                                                  '| Elm & Oak | 5 min | $25 prix fixe | online up to 8 |\n'
                                                  '| Copper Kettle | 5 min | $$ | OpenTable |\n| Bayside Grill | 6 min | $$-$$$ | call 5+ |\n')
    (FILES / 'resume-review.pdf').write_bytes(pdf_one_page('Resume review'))   # [tasks-first] your own file on a task
    (FILES / 'review-sheet.md').write_text('# Open applications\n\n## Verify first\n- Support date: 2\n- Support place: 1\n')
    (FILES / 'export.csv').write_text('month,invoices,total\nJuly,12,4180\nAugust,14,5020\nSeptember,11,3890\n')
    (FILES / 'release-notes.md').write_text('# Release 2.4\n\n## New\n- Export any chat as Markdown or JSON\n- Sync is about twice as fast\n')
    (FILES / 'index.html').write_text(f'<!doctype html><html><body><h1>Release 2.4</h1><p>Export, faster sync, six fixes.</p>'
                                      f'<img src="http://127.0.0.1:{port}/__fixture/beacon" width="1" height="1"></body></html>')
    # [tiles] A tile: fills its window exactly, no scrolling, headline at the top and a footer at the bottom.
    (FILES / 'tile.html').write_text('<!doctype html><html><head><meta name="viewport" content="width=device-width">'
                                     '<title>Revenue This Week</title>'
                                     '<style>html,body{margin:0;height:100vh;overflow:hidden;background:#f4f4f4}'
                                     'body{display:flex;flex-direction:column;justify-content:space-between;font:16px -apple-system}'
                                     '</style></head><body><h1 style="margin:0">Revenue $12K</h1>'
                                     '<p style="margin:0">Updated Tue · 1:30 PM</p></body></html>')   # no <meta charset>: "·" must not read "Â·"
    # [live-tiles] A live tile: read again every 30 s, a button that asks its bot (the lower half, for a tap test).
    (FILES / 'live.html').write_text(live_page(12))
    (FILES / 'App.swift').write_text('import SwiftUI\n\n@main\nstruct ReleaseApp: App {\n    var body: some Scene {\n'
                                     '        WindowGroup { Text("Release 2.4") }\n    }\n}\n')
    line = 'INFO import row ok — 2026-10-09T08:00:00Z\n'
    (FILES / 'log.txt').write_text(line * ((3 << 20) // len(line) + 1))

def live_page(sales):
    return ('<!doctype html><html><head><meta name="viewport" content="width=device-width">'
            '<title>Sales Today</title><meta name="hq-tile-refresh" content="30">'
            '<style>html,body{margin:0;height:100vh;overflow:hidden;background:#eef6ff;font:16px -apple-system}'
            'h1{margin:8px}button{position:absolute;left:0;right:0;bottom:0;height:55%;font-size:18px;border:0;'
            'background:#0053fd;color:#fff}</style></head>'
            f'<body><h1 id="sales">Sales {sales}</h1>'
            '<button data-hermes-send="Add one more sale">Add one</button></body></html>')

def real_file(asked):
    # A file by its name; one in a tile's versions folder ("…/tile.versions/v1.html") keeps that folder ([tile-versions]).
    pure = pathlib.PurePosixPath(asked)
    if pure.parent.name.endswith('.versions'): return FILES / pure.parent.name / pure.name
    return FILES / pure.name

def paced(asked):
    # [tiles] A page whose name says how it answers, every time (a tile's pop-up on a slow or failing computer):
    # slow3-*/slow10-* wait 3 or 10 s, hang-* waits 90 s (past the app's own timeout), fail500-* is a 500.
    name = pathlib.PurePosixPath(asked).name
    slow = re.match(r'(slow(\d+)|hang)-', name)
    if slow: time.sleep(90 if slow.group(1) == 'hang' else int(slow.group(2)))
    if name.startswith('fail500-'): return 500, {'detail': 'Internal Server Error'}
    return None

def serve_file(gateway_handler, query, data_url):
    asked = (query.get('path') or [''])[0]
    sid = (query.get('session_id') or [''])[0]
    if sid:
        session = SESSIONS.get(sid)
        if not session: return 404, {'detail': 'Session not found'}
        if not asked.startswith(('/', '~')) and not session['cwd']:
            return 400, {'detail': 'Session working directory is unavailable'}
    if asked == f'{HOME}/profiles/deploys/cron/output/j-script/2026-10-09_08-00-00.md':
        content = RUN_DOCUMENT.encode()
        return 200, ('text/markdown', content)
    real = real_file(asked)
    paced_fail = paced(asked)
    if paced_fail: return paced_fail
    if not asked or not real.is_file(): return 404, {'detail': 'File not found'}
    data = real.read_bytes()
    kind = mimetypes.guess_type(real.name)[0] or 'application/octet-stream'
    if data_url:
        if len(data) > 16 * 1024 * 1024: return 413, {'detail': 'File too large to preview'}
        return 200, {'dataUrl': f'data:{kind};base64,' + base64.b64encode(data).decode()}
    return 200, (kind, data)

# ---- RPC and socket ---------------------------------------------------------------------------------------
_rpc = fx.rpc
def resumed(sid):
    s = SESSIONS[sid]
    info = {'model': 'hermes-4', 'provider': 'nous', 'cwd': s['cwd'], 'title': s['title'], 'tools': {}, 'skills': {}, 'mcp_servers': [],
            'lazy': True, 'running': False, 'stored_session_id': sid, 'profile_name': s['profile'], 'desktop_contract': 8}
    return {'session_id': runtime(sid), 'resumed': sid, 'session_key': sid, 'stored_session_id': sid, 'messages': [],
            'messages_omitted': True, 'message_count': len(s['messages']), 'status': 'idle', 'running': False, 'inflight': None, 'info': info}

RPC_FAILS = []   # [tiles] POST /__fixture/rpc-fail {"method","action","delay","error","count"}: a slow or failing RPC (a plugin install)

def rpc(method, params):
    with lock: state['rpc'].append({'method': method, 'params': {k: v for k, v in params.items() if k != 'data_url'}})
    fail = next((f for f in RPC_FAILS if f.get('method') == method and f.get('count', 1) > 0
                 and f.get('action') in (None, params.get('action'))), None)
    if fail:
        fail['count'] = fail.get('count', 1) - 1
        if fail.get('delay'): time.sleep(float(fail['delay']))
        if fail.get('error'): raise ValueError(fail['error'])
    profile = params.get('profile') or 'default'
    if method == 'profiles.list': return roster()
    if method == 'session.list':
        rows = [session_row(sid) for sid, s in SESSIONS.items() if s['profile'] == profile and (not params.get('title') or s['title'] == params['title'])]
        return {'sessions': rows, 'total': len(rows)}
    if method in ('session.resume', 'session.activate'):
        sid = find_session(params.get('session_id')) or bot_chat_id(profile if profile in BOT_NAMES else 'default')
        return resumed(sid)
    if method in ('session.info', 'session.get'):
        sid = find_session(params.get('session_id')) or bot_chat_id('default')
        return resumed(sid)['info']
    if method == 'session.active_list':   # [tiles] a tile change still working until /__fixture/turn-end
        with lock: return {'sessions': [{'session_id': rid, 'status': 'running'} for rid in sorted(STREAMING)]}
    # [tiles] New Tile's ask is taken and left running (a bot making a tile works for minutes): the Tiles page's
    # "making" row shows meanwhile.
    if method == 'session.create' and str(params.get('title') or '').startswith('Task: '):
        # [tasks] A task's own chat (2026-11-04): a titled create makes one hidden session per title (a taken title
        # reopens it, as Hermes's titled create does).
        title = params['title']
        sid = next((k for k, v in SESSIONS.items() if v['title'] == title), None)
        if not sid:
            sid = '20261104_120000_tc' + hashlib.sha256(title.encode()).hexdigest()[:6]
            add_session(sid, profile, title, [], now(), hidden=params.get('hidden') is True, listed=False)
        return resumed(sid)
    if method == 'session.create': return resumed(bot_chat_id(profile if profile in BOT_NAMES else 'default'))
    if method == 'prompt.submit' and ('live tile' in json.dumps(params) or 'Change my Hermes HQ Dashboard tile' in json.dumps(params)
                                      or 'I rolled my Hermes HQ tile' in json.dumps(params)   # [tile-versions] after a roll back
                                      or '(Task id ' in json.dumps(params)):   # [tasks] Ask Hermes to Help
        if 'Change my Hermes HQ Dashboard tile' in json.dumps(params) or 'I rolled my Hermes HQ tile' in json.dumps(params):
            with lock: STREAMING.add(params.get('session_id') or '')
        return {'status': 'streaming', 'user_row_id': 1}
    if method == 'prompt.submit' and SESSIONS.get(find_session(params.get('session_id')) or '', {}).get('title', '').startswith('Task: '):
        return {'status': 'streaming', 'user_row_id': 1}   # [tasks] a task's own chat takes any words
    if method == 'prompt.submit': raise ValueError('The pages fixture does not run prompts')
    return _rpc(method, params)
fx.rpc = rpc

def websocket(connection: socket.socket, key: str):
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    wlock = threading.Lock()
    def read(count):
        data = b''
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk: raise ConnectionError()
            data += chunk
        return data
    def send(value):
        body = json.dumps(value).encode(); size = len(body)
        header = bytes([0x81]) + (bytes([size]) if size < 126 else bytes([126]) + struct.pack('>H', size) if size < 65536 else bytes([127]) + struct.pack('>Q', size))
        with wlock: connection.sendall(header + body)
    sockets.add(send)
    try:
        send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {'heartbeat': True, 'change_events': True, 'replay_epoch': 'pages', 'desktop_contract': 8}}})
        fragments = bytearray()
        while True:
            first, second = read(2); opcode, length, final = first & 15, second & 127, bool(first & 128)
            if length == 126: length = struct.unpack('>H', read(2))[0]
            elif length == 127: length = struct.unpack('>Q', read(8))[0]
            mask = read(4) if second & 128 else b'\0\0\0\0'
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(length)))
            if opcode == 8: return
            if opcode == 9:
                with wlock: connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode == 1: fragments = bytearray(payload)
            elif opcode == 0: fragments.extend(payload)
            else: continue
            if not final: continue
            frame = json.loads(fragments); fragments.clear()
            if 'id' not in frame or 'method' not in frame: continue
            answer = {'jsonrpc': '2.0', 'id': frame['id']}
            try: answer['result'] = rpc(frame['method'], frame.get('params') or {})
            except ValueError as error: answer['error'] = {'code': -32001, 'message': str(error)}
            send(answer)
    except (ConnectionError, OSError, ValueError): return
    finally: sockets.discard(send)
fx.auth.websocket = websocket

# ---- REST -------------------------------------------------------------------------------------------------
_handler = fx.handler
def handler(gateway):
    base = _handler(gateway)
    class Handler(base):
        def body_json(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try: return json.loads(raw or b'{}')
            except ValueError:
                # A multipart upload (Kanban attachments): its file's name and size, for the attachment route.
                m = re.search(rb'filename="([^"]+)"', raw)
                return {'__upload': {'filename': m.group(1).decode('utf-8', 'replace') if m else 'file', 'size': len(raw)}}

        def answer(self, status, body):
            if isinstance(body, tuple):
                kind, data = body
                self.send_response(status)
                self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(data)))
                self.end_headers(); self.wfile.write(data)
                return
            if isinstance(body, bytes):
                return self.answer(status, ('application/octet-stream', body))
            self.reply(status, body)

        def logged(self, method, body=None):
            url = urlparse(self.path)
            query = {k: v[0] if len(v) == 1 else v for k, v in parse_qs(url.query).items()}
            with lock: state['rest'].append({'method': method, 'path': url.path, 'query': query, 'body': body})
            # A scripted failure or delay for the next matching request.
            for fail in list(fails):
                if fail.get('method', method) == method and fail.get('path') == url.path:
                    if fail.get('delay'):
                        with lock: fails.remove(fail)
                        time.sleep(float(fail['delay']))
                        return None
                    with lock:
                        fail['count'] = int(fail.get('count', 1)) - 1
                        if fail['count'] <= 0: fails.remove(fail)
                    return int(fail.get('status', 500)), {'detail': fail.get('detail', 'boom')}
            return None

        def route(self, method, body):
            url = urlparse(self.path); path, query = url.path, parse_qs(url.query)
            one = lambda key: (query.get(key) or [''])[0]
            if path == '/api/plugins/hermes-hq-push/logs' and method == 'POST':
                # The plugin's own writer (gateway-plugin/hermes-hq-push/perf_logs.py from the web app's reference),
                # into <files>/hq-logs: the native app's diagnostic log upload (HermesKit/Diagnostics/LogUploader.swift).
                spec = importlib.util.spec_from_file_location('perf_logs', PERF_LOGS)
                module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
                try:
                    return 200, module.write(pathlib.Path(FILES) / 'hq-logs', body.get('device', ''), body.get('lines', []),
                                             app=body.get('app', ''), reason=body.get('reason', ''), lost=bool(body.get('lost')))
                except module.LogError as error:
                    return error.status_code, {'detail': error.detail}
            if path == '/api/plugins/hermes-hq-push/cron/working' and method == 'GET':
                # hermes-hq-push 0.9.2: jobs whose latest run's output a bot is still working on (cron_working.py).
                with lock: return 200, {'jobs': list(copy.deepcopy(BOT_WORKING).values())}
            if path == TASKS_ROUTE or path.startswith(TASKS_ROUTE + '/'):
                with lock: return tasks_route(method, path, query, body)
            if path == GOALS_ROUTE or path.startswith(GOALS_ROUTE + '/'):   # [goals] 0.9.65
                with lock: return goals_route(method, path, body)
            if path == '/api/plugins/hermes-hq-push/status' and method == 'GET':
                return addon_status()
            # [plugin-pages] Page plugins (HermesKit/Plugins/DashboardPages.swift): "notes" works and calls its own API,
            # "broken" sends no files (404), "crashy" throws while it runs, "silent" never registers. Slow or down:
            # /__fixture/fail with that page's bundle path and a delay or a status.
            if path == '/api/dashboard/plugins' and method == 'GET':
                def page(name, label, icon, description):
                    return {'name': name, 'label': label, 'description': description, 'icon': icon, 'tab': {'path': '/' + name},
                            'entry': 'dist/index.js', 'css': None, 'has_api': name == 'notes', 'source': 'user', 'version': '1.0.0'}
                return 200, [page('notes', 'Notes Board', 'NotebookPen', 'Short notes your bots keep.'),
                             page('broken', 'Broken Page', 'Bug', 'A page whose files are missing.'),
                             page('crashy', 'Crashy Page', 'Flame', 'A page that throws while it starts.'),
                             page('silent', 'Silent Page', 'Moon', 'A page that never shows itself.')]
            if path == '/api/dashboard/plugins/rescan' and method == 'GET':
                return 200, {'ok': True}
            if path.startswith('/dashboard-plugins/') and method == 'GET':
                name = path.split('/')[2].lstrip('@')
                if path.split('/')[2].startswith('@'): name = path.split('/')[3]
                if name == 'notes' and path.endswith('/dist/index.js'):
                    return 200, ('application/javascript', NOTES_PAGE_JS.encode())
                if name == 'crashy' and path.endswith('/dist/index.js'):
                    return 200, ('application/javascript', b"throw new Error('the chart library is missing');")
                if name == 'silent' and path.endswith('/dist/index.js'):
                    return 200, ('application/javascript', b"console.log('loaded, never registers');")
                return 404, {'detail': 'Not Found'}
            if path == '/api/plugins/notes/items' and method == 'GET':
                return 200, {'items': [{'title': 'Renew the domain', 'body': 'gethermes.example runs out on Dec 2.'},
                                       {'title': 'Café order', 'body': 'Two crème brûlées for Friday — naïve test of UTF-8.'},
                                       {'title': 'A long note', 'body': 'This one is long on purpose so the narrow window has to wrap it across several lines without cutting words off or running past the edge.'}]}
            if path.startswith('/api/plugins/kanban'):
                with lock: return kanban(method, path, query, body)
            if path == '/api/cron/jobs' and method == 'GET':
                with lock: return 200, copy.deepcopy(jobs_for(one('profile')))
            if path == '/api/cron/jobs' and method == 'POST':
                # Hermes's create: the job as sent, a schedule string becoming a cron schedule.
                b = dict(body or {}); profile = one('profile') or 'default'
                expr = b.pop('schedule', '0 9 * * *')
                jid = 'j-' + hashlib.sha256(f'{expr}{now()}'.encode()).hexdigest()[:8]
                name = b.pop('name', None) or (b.get('prompt') or 'Job')[:50]
                with lock:
                    JOBS[f'{profile}|{jid}'] = job_record(jid, name, profile, {'kind': 'cron', 'expr': expr, 'display': expr}, **b)
                    answer = copy.deepcopy(JOBS[f'{profile}|{jid}'])
                broadcast(); return 200, answer
            if path.startswith('/api/cron/jobs/'):
                parts = [unquote(p) for p in path[len('/api/cron/jobs/'):].split('/')]
                with lock: job = job_by(parts[0], one('profile'))
                if not job: return 404, {'detail': 'Job not found'}
                action = parts[1] if len(parts) > 1 else ''
                if method == 'GET' and action == '':
                    with lock: return 200, copy.deepcopy(job)
                if method == 'GET' and action == 'runs':
                    limit = max(1, min(100, int(one('limit') or 20)))
                    with lock: return 200, {'runs': copy.deepcopy(RUNS.get(job['id'], [])[:limit]), 'limit': limit}
                if method == 'POST' and action == 'trigger': return trigger(job)
                if method == 'POST' and action in ('pause', 'resume'):
                    with lock:
                        job['enabled'] = action == 'resume'
                        job['state'] = 'paused' if action == 'pause' else 'scheduled'
                        answer = copy.deepcopy(job)
                    broadcast(); return 200, answer
                if method == 'PUT' and action == '':
                    # Hermes's edit: `{"updates": {...}}`; a schedule string becomes a cron schedule.
                    updates = (body or {}).get('updates') or {}
                    with lock:
                        for k, v in updates.items():
                            if k == 'schedule':
                                job['schedule'] = {'kind': 'cron', 'expr': v, 'display': v}; job['schedule_display'] = v
                            else: job[k] = v
                        answer = copy.deepcopy(job)
                    broadcast(); return 200, answer
                if method == 'DELETE' and action == '':
                    with lock: JOBS.pop(f"{job['profile']}|{job['id']}", None)
                    broadcast(); return 200, {'ok': True}
                return 404, {'detail': 'Not Found'}
            if path == '/api/profiles/sessions' and method == 'GET' and REAL_LISTING and one('profile') in REAL_LISTING:
                return 200, REAL_LISTING[one('profile')]
            if path.startswith('/api/sessions/') and path.endswith('/messages') and method == 'GET' and REAL_LISTING:
                sid = unquote(path[len('/api/sessions/'):].split('/')[0])
                rows = REAL_MESSAGES.get((one('profile') or 'default') + '\x1f' + sid, [])
                limit = int(one('limit') or 100); offset = int(one('offset') or 0)
                page = rows[offset:offset + limit]
                return 200, {'session_id': sid, 'profile': one('profile') or 'default', 'messages': page,
                             'pagination': {'limit': limit, 'offset': offset, 'order': one('order') or 'oldest', 'returned': len(page)}}
            if path in ('/api/profiles/sessions', '/api/sessions') and method == 'GET':
                rows = listed_sessions(one('profile'))
                limit = int(one('limit') or 30); offset = int(one('offset') or 0)
                return 200, {'sessions': rows[offset:offset + limit], 'total': len(rows), 'limit': limit, 'offset': offset}
            if path == '/api/profiles/sessions/sidebar' and method == 'GET':
                rows = sorted((session_row(sid) for sid, s in SESSIONS.items() if not s['hidden'] and s['source'] != 'cron'), key=lambda r: -r['last_active'])
                cron = sorted((session_row(sid) for sid, s in SESSIONS.items() if s['source'] == 'cron'), key=lambda r: -r['last_active'])
                return 200, {'recents': {'sessions': rows}, 'cron': {'sessions': cron}, 'messaging': {'sessions': []}}
            if path.startswith('/api/sessions/') and method == 'GET':
                sid = unquote(path[len('/api/sessions/'):].split('/')[0])
                s = SESSIONS.get(sid)
                if not s: return 404, {'detail': 'Session not found'}
                if path.endswith('/messages'):
                    rows = s['messages'] if one('order') != 'newest' else list(reversed(s['messages']))
                    limit = int(one('limit') or 100); offset = int(one('offset') or 0)
                    page = rows[offset:offset + limit]
                    return 200, {'session_id': sid, 'profile': s['profile'], 'messages': page,
                                 'pagination': {'limit': limit, 'offset': offset, 'order': one('order') or 'oldest', 'returned': len(page)}}
                return 200, session_row(sid)
            if path == '/api/profiles' and method == 'GET':
                return 200, {'profiles': [{'name': n, 'display_name': t, 'is_default': n == 'default', 'path': f'{HOME}/profiles/{n}',
                                           'model': 'hermes-4', 'provider': 'nous'} for n, t, _ in BOTS]}
            if path in ('/api/fs/download', '/api/fs/read-data-url') and method == 'GET':
                return serve_file(self, query, path.endswith('read-data-url'))
            # [tile-versions] The text routes a tile's versions are kept with.
            if path == '/api/fs/read-text' and method == 'GET':
                real = real_file(one('path') or '')
                paced_fail = paced(one('path') or '')
                if paced_fail: return paced_fail
                if not real.is_file(): return 404, {'detail': 'File not found'}
                data = real.read_bytes()
                return 200, {'path': one('path'), 'text': data.decode('utf-8', 'replace'), 'binary': False, 'truncated': False,
                             'byteSize': len(data)}
            if path == '/api/fs/write-text' and method == 'POST':
                real = real_file(body.get('path') or '')
                if not real.parent.is_dir(): return 400, {'detail': 'Parent directory does not exist'}
                real.write_text(body.get('content') or '')
                return 200, {'ok': True, 'path': body.get('path'), 'byteSize': real.stat().st_size}
            if path == '/api/files/mkdir' and method == 'POST':
                real_file((body.get('path') or '') + '/x').parent.mkdir(parents=True, exist_ok=True)
                return 200, {'ok': True, 'path': body.get('path')}
            return None

        def handle_api(self, method):
            body = self.body_json() if method in ('POST', 'PATCH', 'PUT', 'DELETE') else None
            failed = self.logged(method, body)
            if failed: return self.answer(*failed)
            result = self.route(method, body or {})
            if result is None:
                return super().do_GET() if method == 'GET' else self.answer(404, {'detail': 'Not Found'})
            return self.answer(*result)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__fixture/state':
                with lock: return self.reply(200, {'rest': state['rest'], 'rpc': state['rpc'], 'dispatch': state['dispatch'], 'beacon': state['beacon']})
            if path == '/__fixture/beacon':
                with lock: state['beacon'] += 1
                return self.answer(200, ('image/png', png(1, 1, lambda x, y: (0, 0, 0))))
            if path.startswith('/api/auth/') or path == '/api/ws' or path.startswith('/__fixture/') or path == '/api/status':
                return super().do_GET()
            return self.handle_api('GET')

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/fail':
                fail = self.body_json()
                with lock: fails.append(fail)
                return self.reply(200, {'ok': True})
            if path == '/__fixture/rpc-fail':
                with lock: RPC_FAILS.append(self.body_json())
                return self.reply(200, {'ok': True})
            if path == '/__fixture/reset':
                self.body_json()
                reseed()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tasks-mode':   # [task-ideas] {"older_addon": true} and/or {"empty": true} (no tasks); [goals] {"goals": true}
                mode = self.body_json()
                with lock:
                    TMODE['older_addon'] = bool(mode.get('older_addon'))
                    if mode.get('lists'): seed_task_lists()   # [task-lists] what --task-lists starts with
                    if mode.get('goals'):   # [goals] what --task-goals starts with; "empty": goals kept, none yet
                        global GOALS_ON
                        GOALS_ON = True
                        if mode['goals'] == 'empty': GOALS.clear(); TSTATE['rev'] += 1
                        else: seed_task_goals()
                    if mode.get('empty'): TASKS.clear()
                    # "keep_rev": as an add-on update does (before 0.9.40), the list's rev stays, so `?since=` says unchanged
                    if not mode.get('keep_rev'): TSTATE['rev'] += 1
                return self.reply(200, {'ok': True})
            if path == '/__fixture/kanban-many':   # {"count": 40, "status": "todo", "long": false}: fill one column
                body = self.body_json() or {}
                with lock:
                    board = BOARDS[KSTATE['current']]
                    for n in range(int(body.get('count', 40))):
                        title = (f'Long card {n + 1}: check every export path on the release branch and write down each one that '
                                 'fails, with the file it wrote and the error it showed' if body.get('long') else f'Filler card {n + 1}')
                        t = ktask(title, body.get('status', 'todo'), 'deploys' if n % 2 else None, n * MIN)
                        t['id'] = f't_many{n:03d}'
                        board['tasks'][t['id']] = t
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tile-job':
                # {"status": "error", "error": "…", "model": "…"}: a tile whose last update failed, run by that model.
                body = self.body_json() or {}
                t = local(now())
                with lock:
                    JOBS['deploys|j-tile'] = job_record(
                        'j-tile', 'Revenue tile', 'deploys', {'kind': 'cron', 'expr': '0 * * * *', 'display': '0 * * * *'},
                        prompt=f'Update the Dashboard tile {HOME}/site/tile.html with the dashboard-tile skill. Reply [SILENT].',
                        last_run_at=iso(t - datetime.timedelta(minutes=5)), last_status=body.get('status', 'ok'),
                        last_error=body.get('error'), model=body.get('model'),
                        next_run_at=iso(t + datetime.timedelta(minutes=55)))
                broadcast()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tile-ran':
                # [tiles] The tile's job ran just now and rewrote the page: the app draws it again.
                self.body_json()
                t = local(now())
                with lock:
                    job = JOBS.get('deploys|j-tile')
                    if job: job.update(last_run_at=iso(t), last_status='ok', last_error=None)
                    page = (FILES / 'tile.html').read_text().replace('Revenue $12K', 'Revenue $14K')
                    (FILES / 'tile.html').write_text(page)
                broadcast()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tile-edit':
                # [tile-versions] The tile's bot edited the page's look: {"from","to"} in its text.
                edit = self.body_json()
                with lock:
                    page = (FILES / 'tile.html').read_text().replace(edit.get('from', ''), edit.get('to', ''))
                    (FILES / 'tile.html').write_text(page)
                return self.reply(200, {'ok': True})
            if path == '/__fixture/live-bump':
                # [live-tiles] The live tile's page changes on disk (no broadcast: its own refresh reads it).
                self.body_json()
                with lock:
                    (FILES / 'live.html').write_text(live_page(13))
                return self.reply(200, {'ok': True})
            if path == '/__fixture/broadcast':
                kind = self.body_json().get('type') or 'cron.changed'
                broadcast(kind)
                return self.reply(200, {'ok': True, 'sockets': len(sockets)})
            if path == '/__fixture/finish':
                body = self.body_json(); jid = body.get('job_id')
                with lock:
                    job = next((j for j in JOBS.values() if j['id'] == jid), None)
                    if not job: return self.reply(404, {'detail': 'Job not found'})
                    finish_run(job)
                    if body.get('bot'):
                        BOT_WORKING[f"{job['profile']}|{jid}"] = {
                            'profile': job['profile'], 'id': jid, 'status': body['bot'],
                            'run': (job.get('latest_execution') or {}).get('id') or f'exec-{jid}', 'since': iso(local(now()))}
                broadcast()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/bot-done':
                jid = self.body_json().get('job_id')
                with lock:
                    for key in [k for k, row in BOT_WORKING.items() if row['id'] == jid]: del BOT_WORKING[key]
                broadcast()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/turn-end':
                # [tiles] The last streaming prompt whose words hold `match` ends: its reply `text` streams and completes
                # (or an `error` ends it), as a bot's turn ends on Hermes.
                body = self.body_json()
                match = body.get('match') or ''
                with lock:
                    asks = [r for r in state['rpc'] if r['method'] == 'prompt.submit' and match in json.dumps(r['params'])]
                if not asks: return self.reply(404, {'detail': 'No such prompt'})
                rid = asks[-1]['params'].get('session_id') or ''
                with lock: STREAMING.discard(rid)
                def event(kind, payload):
                    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'session_id': rid, 'payload': payload}}
                    for send in list(sockets):
                        try: send(frame)
                        except Exception: sockets.discard(send)
                if body.get('error'):
                    event('error', {'message': body['error']})
                else:
                    text = body.get('text') or ''
                    sid = find_session(rid)
                    if sid:
                        with lock:
                            SESSIONS[sid]['messages'].append({'id': len(SESSIONS[sid]['messages']) + 1, 'role': 'assistant',
                                                              'content': text, 'timestamp': now()})
                    event('message.delta', {'text': text})
                    event('message.complete', {'text': text, 'status': 'complete'})
                return self.reply(200, {'ok': True, 'session_id': rid})
            if path == '/__fixture/append':
                body = self.body_json()
                with lock:
                    s = SESSIONS.get(body.get('session_id'))
                    if not s: return self.reply(404, {'detail': 'Session not found'})
                    s['messages'].append({'id': len(s['messages']) + 1, 'role': body.get('role') or 'assistant',
                                          'content': body.get('text') or '', 'timestamp': now()})
                    s['last_active'] = now()
                return self.reply(200, {'ok': True, 'message_count': len(s['messages'])})
            if path.startswith('/auth/') or path.startswith('/api/auth/') or path.startswith('/__fixture/'):
                return super().do_POST()
            return self.handle_api('POST')

        def do_PATCH(self): return self.handle_api('PATCH')
        def do_DELETE(self): return self.handle_api('DELETE')
        def do_PUT(self): return self.handle_api('PUT')
    return Handler
fx.handler = handler

def reseed():
    global T0
    with lock:
        T0 = time.time()
        state['rest'].clear(); state['rpc'].clear(); state['dispatch'] = 0; state['beacon'] = 0
        fails.clear()
        TMODE['older_addon'] = False
        seed_sessions(); seed_jobs(); seed_kanban(); seed_tasks(); load_tasks_json()

def ticker(seconds):
    while True:
        time.sleep(seconds)
        broadcast()

def main():
    global NO_KANBAN, EMPTY_KANBAN, TRIGGER_SECONDS, FILES, NO_TASKS, TASKS_CHAT, TASKS_JSON, TASK_LISTS, TASK_GOALS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=9735)
    parser.add_argument('--credentials', required=True)
    parser.add_argument('--files', required=True)
    parser.add_argument('--no-kanban', action='store_true')
    parser.add_argument('--no-tasks', action='store_true')   # [tasks] an add-on older than 0.9.32
    parser.add_argument('--tasks-chat', action='store_true')   # [tasks] Hermes's Bot Chat ends with the tasks_add exchange
    parser.add_argument('--task-lists', action='store_true')   # [task-lists] lists, a kept list, an offer and its chat
    parser.add_argument('--task-goals', action='store_true')   # [goals] five made-up goals with milestones and tasks
    parser.add_argument('--tasks-json')   # [tasks] add tasks exported from a real tasks.db (a private file, never committed)
    parser.add_argument('--empty-kanban', action='store_true')
    parser.add_argument('--trigger-seconds', type=float, default=3)
    parser.add_argument('--tick-seconds', type=float, default=60)
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--hermes-cookies', action='store_true')
    args = parser.parse_args()
    NO_KANBAN, EMPTY_KANBAN, TRIGGER_SECONDS = args.no_kanban, args.empty_kanban, args.trigger_seconds
    NO_TASKS, TASKS_CHAT, TASKS_JSON = args.no_tasks, args.tasks_chat, args.tasks_json
    TASK_LISTS = args.task_lists
    TASK_GOALS = args.task_goals
    FILES = pathlib.Path(args.files)
    make_files(args.port)
    reseed()
    if args.tick_seconds > 0: threading.Thread(target=ticker, args=(args.tick_seconds,), daemon=True).start()
    sys.argv = [sys.argv[0], '--port', str(args.port), '--credentials', args.credentials] + \
               (['--keep-credentials'] if args.keep_credentials else []) + (['--hermes-cookies'] if args.hermes_cookies else [])
    print(f'Pages fixture listening on 127.0.0.1:{args.port}', flush=True)
    fx.main()

if __name__ == '__main__': main()
