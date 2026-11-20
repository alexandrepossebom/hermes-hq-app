#!/usr/bin/env python3
"""[goals steps 3-5] The stand-in's goal contract against the real add-on's.

Sends one sequence of requests (make a goal, patch every 0.9.66 field, each goal offer kind accepted, declined and
undone, a held offer, a replaced offer, a looks-done answered both ways, the number read by its bot, a task in and out
of a goal, the Goal Page) to the stand-in's route functions (scripts/pages-fixture-gateway.py, imported) and to the
hermes-hq-push add-on's FastAPI router (dashboard/plugin_api.py, imported read-only), and prints every difference in a
status code or in an answer's keys and values. Ids, times, revs and positions are left out of the comparison (each side
makes its own); an id is compared as "an id of this side", so a field pointing at the wrong thing still shows.

Run it with Hermes's own interpreter (it has FastAPI):

    ~/.hermes/hermes-agent/venv/bin/python scripts/fixture-support/goals_contract_check.py [--addon <hermes-hq-push dir>]

Nothing is written in the add-on's folder (no bytecode; its data goes to a temp HERMES_HQ_PUSH_DATA_DIR, HERMES_HOME is
a temp folder, the relay is off, and no bot's home is looked up, so no scheduled job is made). Exit 0 when nothing
differs, 1 otherwise.
"""
import argparse, importlib.util, json, os, sys, tempfile
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
STANDIN = HERE.parent / 'pages-fixture-gateway.py'
DEFAULT_ADDON = Path.home() / '.hermes/plugins/hermes-hq-push'   # the installed add-on; --addon names another copy
BASE = '/api/plugins/hermes-hq-push'

TIME_KEYS = {'at', 'created_at', 'updated_at', 'status_at', 'answered_at', 'kept_at', 'done_at', 'checked_at', 'page_at'}
TASK_KEYS = ('title', 'who', 'bot', 'status', 'goal', 'milestone', 'due', 'created_by', 'source')


# ---------------------------------------------------------------------------------------------------------------------
# The two sides: request(method, path, body, params) -> (status, body); offer(...) and update(...) as a bot's tools
# ---------------------------------------------------------------------------------------------------------------------

class AddOn:
    name = 'addon'

    def __init__(self, folder: Path):
        home = Path(tempfile.mkdtemp(prefix='goals-contract-'))
        os.environ['HERMES_HOME'] = str(home / 'hermes-home')
        os.environ.setdefault('HERMES_DISABLE_LAZY_INSTALLS', '1')
        os.environ['HERMES_HQ_PUSH_DATA_DIR'] = str(home / 'data')
        os.environ['HERMES_HQ_PUSH_RELAY_URL'] = 'off'
        (home / 'hermes-home').mkdir(parents=True)

        def load(name, file):
            if name in sys.modules: return sys.modules[name]
            spec = importlib.util.spec_from_file_location(name, folder / file)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
            return module

        self.tasks = load('hermes_hq_tasks', 'tasks.py')
        self.goals = load('hermes_hq_goals', 'goals.py')
        push = load('hermes_hq_push_core', 'push.py')
        push._watcher_started = True
        self.tasks.bot_home = lambda profile: None   # no bot's real schedule is ever reached
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        api = load('hermes_hq_push_api_contract_check', 'dashboard/plugin_api.py')
        app = FastAPI()
        app.include_router(api.router, prefix=BASE)
        self.client, self.api = TestClient(app), api

    def request(self, method, path, body=None, params=None):
        answer = self.client.request(method, BASE + path, json=body, params=params)
        if answer.headers.get('content-type', '').startswith('text/html'): return answer.status_code, {'html': answer.text}
        try: return answer.status_code, answer.json()
        except ValueError: return answer.status_code, {'text': answer.text}

    def offer(self, bot, kind, args, session='s1', with_person=True):
        try: return 200, self.goals.offer(self.api._tasks_store(), bot, session, kind, args, with_person=with_person)
        except self.tasks.TaskError as error: return error.status_code, {'detail': error.detail}

    def update(self, bot, goal, **kw):
        try: return 200, self.goals.update(self.api._tasks_store(), bot, goal, **kw)
        except self.tasks.TaskError as error: return error.status_code, {'detail': error.detail}


class StandIn:
    name = 'standin'

    def __init__(self):
        os.environ.setdefault('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238')
        spec = importlib.util.spec_from_file_location('pages_fixture_contract_check', STANDIN)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.GOAL_BOTS = m.TASK_GOAL_BOTS = True   # as --task-goal-bots: a reseed keeps it
        m.TASK_GOALS, m.TASK_LISTS = False, False
        m.reseed()
        m.GOALS_ON = True   # as an add-on that keeps goals, with none yet
        m.TASKS.clear(); m.GOALS.clear(); m.OFFERS.clear(); m.GOAL_PAGES.clear(); m.IDEAS.clear()
        m.TSTATE['sections'] = []
        self.m = m

    def request(self, method, path, body=None, params=None):
        m, full = self.m, BASE + path
        query = {k: [v] for k, v in (params or {}).items()}
        if path == '/status': code, out = m.addon_status()
        elif full == m.TASKS_ROUTE or full.startswith(m.TASKS_ROUTE + '/'): code, out = m.tasks_route(method, full, query, body or {})
        elif full == m.GOALS_ROUTE or full.startswith(m.GOALS_ROUTE + '/'): code, out = m.goals_route(method, full, body or {}, query)
        else: return 404, {'detail': 'Not Found'}
        if isinstance(out, tuple): return code, {'html': out[1].decode()}
        return code, json.loads(json.dumps(out))

    def offer(self, bot, kind, args, session='s1', with_person=True):
        try: return 200, json.loads(json.dumps(self.m.goal_offer(bot, session, kind, args, with_person=with_person)))
        except self.m.GoalError as error: return error.code, {'detail': error.detail}

    def update(self, bot, goal, **kw):
        try: return 200, json.loads(json.dumps(self.m.goal_update(bot, goal, **kw)))
        except self.m.GoalError as error: return error.code, {'detail': error.detail}


# ---------------------------------------------------------------------------------------------------------------------
# The sequence: each step is (label, status, body); the same steps run on each side
# ---------------------------------------------------------------------------------------------------------------------

def sequence(side):
    out, ids = [], {}

    def step(label, code, body, keep=None):
        out.append((label, code, keep(body) if keep and code == 200 else body))
        return body

    def goal(key):
        code, body = side.request('GET', '/tasks')
        return next((g for g in body.get('goals') or [] if g['id'] == ids.get(key)), None)

    def listing(label):
        code, body = side.request('GET', '/tasks')
        step(label, code, body, lambda b: {'goal_bots': b.get('goal_bots'), 'goals': b.get('goals'), 'offers': b.get('offers'),
                                           'tasks': [{k: t.get(k) for k in TASK_KEYS} for t in b.get('tasks') or []]})
        return body

    code, body = side.request('GET', '/status')
    step('GET /status', code, body, lambda b: {k: b.get(k) for k in ('goal_bots', 'goal_pages', 'task_goals')})
    listing('GET /tasks, nothing yet')

    # A goal, and every field 0.9.66 adds
    code, a = side.request('POST', '/goals', {'title': 'Ship the beta', 'why': 'So testers can start.',
                                              'measure': {'unit': 'testers', 'start': 0, 'target': 10}})
    ids['a'] = a.get('id'); step('POST /goals', code, a)
    code, b = side.request('POST', '/goals', {'title': 'Learn to sail', 'lead': 'otto', 'helpers': ['wren']})
    ids['b'] = b.get('id'); step('POST /goals with a lead (POST takes none)', code, b)
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'lead': 'otto', 'helpers': ['wren', 'otto', 'wren'],
                                                         'adds': 'auto', 'known_to_all': False,
                                                         'chat': {'profile': 'otto', 'session_id': 'g1'},
                                                         'measure': {'source': {'bot': 'ivy', 'what': 'the sign-up sheet'}}})
    step('PATCH lead, helpers, adds, known_to_all, chat, measure.source', code, a)
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'review': {'day': 3, 'time': '07:15'}})
    step('PATCH review', code, a)
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'review': None})
    step('PATCH review null', code, a)
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'keep': True})
    step('PATCH keep', code, a)
    for label, bad in (('review day 7', {'review': {'day': 7, 'time': '08:00'}}), ('adds sometimes', {'adds': 'sometimes'}),
                       ('offer_answer later', {'offer_answer': 'later'}), ('lead with a space', {'lead': 'two words'}),
                       ('six helpers', {'helpers': ['a', 'b', 'c', 'd', 'e', 'f']}), ('measure.source 5', {'measure': {'source': 5}}),
                       ('a stale rev', {'lead': 'wren', 'rev': 1})):
        code, body = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], **bad})
        step(f'PATCH refused: {label}', code, body if code != 409 else {'goal_title': (body.get('detail') or {}).get('goal', {}).get('title')})
    code, body = side.request('PATCH', '/goals/nope', {'rev': 1, 'lead': 'otto'})
    step('PATCH an unknown goal', code, body)
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'lead': None})
    step('PATCH lead null (helpers stay)', code, a)
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'lead': 'otto'})
    step('PATCH a lead again (review back to Monday 08:00)', code, a)
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'helpers': ['otto', 'wren']})
    step('PATCH helpers naming the lead', code, a)
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'milestones': [{'title': 'Venue booked'}, {'title': 'Invites out'}]})
    ids['m1'], ids['m2'] = (a['milestones'][0]['id'], a['milestones'][1]['id']) if code == 200 else (None, None)
    step('PATCH milestones', code, a)

    # A task in and out of a goal
    code, t = side.request('POST', '/tasks', {'title': 'Write the notes', 'goal': ids['a'], 'milestone': ids['m1']})
    step('POST /tasks in a goal and milestone', code, t, lambda b: {k: b.get(k) for k in TASK_KEYS})
    code, t = side.request('PATCH', f"/tasks/{t['id']}", {'rev': t['rev'], 'goal': None})
    step('PATCH /tasks out of its goal', code, t, lambda b: {k: b.get(k) for k in TASK_KEYS})

    # Offers: tasks from the lead (Just Tasks), a goal (no plan), a plan (accept, undo), a helper's plan, a check-in
    code, o = side.offer('otto', 'tasks', {'goal': ids['a'], 'tasks': [{'title': 'Draft the invite', 'who': 'bot'},
                                                                     {'title': 'Call the venue', 'milestone': 'Venue booked'}]})
    ids['o_tasks'] = o.get('id'); step('offer tasks (lead)', code, o)
    listing('GET /tasks with a tasks offer')
    code, body = side.request('POST', f"/tasks/offers/{ids['o_tasks']}", {'action': 'accept', 'in_goal': False})
    step('accept tasks, in_goal false', code, body)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_tasks']}", {'action': 'accept'})
    step('accept it again', code, body)
    code, body = side.request('POST', '/tasks/offers/nope', {'action': 'accept'})
    step('answer an unknown offer', code, body)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_tasks']}", {'action': 'move'})
    step('a list-only action on a goal offer', code, body)
    code, body = side.offer('juno', 'goal', {'title': 'Learn to sail'})
    step('offer a goal they have', code, body)
    code, o = side.offer('juno', 'goal', {'title': 'Run a marathon', 'why': 'For the fun of it.', 'due': '2027-04-11',
                                          'measure': {'unit': 'miles', 'start': 0, 'target': 26},
                                          'milestones': [{'title': 'A 10K'}, {'title': 'A half'}],
                                          'tasks': [{'title': 'Buy shoes'}, {'title': 'Find a plan', 'who': 'bot', 'milestone': 'A 10K'}]})
    ids['o_goal'] = o.get('id'); step('offer a goal', code, o)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_goal']}", {'action': 'accept', 'plan': False})
    step('accept the goal, no plan', code, body)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_goal']}", {'action': 'undo'})
    step('undo the goal', code, body)
    # Add-on 0.9.66 keeps the goal here (its updated_at is stamped a moment after made.at, so it reads as "changed
    # since"): a bug in the add-on, reported. Take it away on that side so it doesn't carry into every later step.
    for g in body.get('goals') or []:
        if g['title'] == 'Run a marathon': side.request('DELETE', f"/goals/{g['id']}")
    code, o = side.offer('juno', 'goal', {'title': 'Plant a hedge', 'milestones': [{'title': 'Dig'}], 'tasks': [{'title': 'Buy plants', 'milestone': 'Dig'}]})
    ids['o_goal2'] = o.get('id'); step('offer another goal', code, o)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_goal2']}", {'action': 'accept'})
    step('accept it with its plan', code, body)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_goal2']}", {'action': 'decline'})
    step('decline an accepted offer', code, body)
    code, body = side.offer('wren', 'plan', {'goal': ids['a'], 'milestones': [{'title': 'X'}]})
    step('offer a plan as a helper', code, body)
    code, o = side.offer('otto', 'plan', {'goal': ids['a'], 'milestones': [{'title': 'Venue booked'}, {'title': 'Menu set', 'due': '2026-12-20'}],
                                          'tasks': [{'title': 'Taste three menus', 'milestone': 'Menu set'}, {'title': 'Book a room', 'who': 'bot'}]})
    ids['o_plan'] = o.get('id'); step('offer a plan', code, o)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_plan']}", {'action': 'accept'})
    step('accept the plan', code, body)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_plan']}", {'action': 'undo'})
    step('undo the plan', code, body)
    code, o = side.offer('otto', 'plan', {'goal': ids['a'], 'tasks': [{'title': 'Pick a date'}]})
    ids['o_plan2'] = o.get('id'); step('offer a plan again', code, o)
    code, body = side.request('POST', f"/tasks/offers/{ids['o_plan2']}", {'action': 'accept', 'plan': False})
    step('Keep the Goal, No Plan on a plan (declines it)', code, body)
    code, body = side.offer('otto', 'plan', {'goal': ids['a'], 'tasks': [{'title': 'Pick a date'}]})
    step('a plan after Keep the Goal, No Plan', code, body)

    # Held and replaced offers, and the check-in that folds the held ones
    code, o = side.offer('juno', 'tasks', {'goal': ids['a'], 'tasks': [{'title': 'Ask the neighbours'}]})
    ids['o_held'] = o.get('id'); step('offer tasks from a bot not on the goal (held)', code, o)
    code, o = side.offer('wren', 'tasks', {'goal': ids['a'], 'tasks': [{'title': 'Print the flyers'}]}, with_person=False)
    step('offer tasks from a helper, no person in the chat (held)', code, o)
    code, o1 = side.offer('wren', 'tasks', {'goal': ids['a'], 'tasks': [{'title': 'Order the cake'}]})
    code, o2 = side.offer('wren', 'tasks', {'goal': ids['a'], 'tasks': [{'title': 'Order the cake'}, {'title': 'Order candles'}]})
    step('offer tasks twice (the second replaces the first)', code, o2)
    listing('GET /tasks with held and replaced offers')
    code, body = side.offer('otto', 'checkin', {'goal': ids['a']})
    step('a check-in with no summary', code, body)
    code, o = side.offer('otto', 'checkin', {'goal': ids['a'], 'summary': 'Two of three done. The venue is booked.',
                                             'tasks': [{'title': 'Send the invites', 'due': '2026-12-01'}, {'title': 'Draft the toast', 'who': 'bot'}]})
    ids['o_checkin'] = o.get('id'); step('offer a check-in', code, o)
    step('the goal after the check-in', 200, goal('a'))
    listing('GET /tasks after the check-in (held ones folded)')
    code, body = side.request('POST', f"/tasks/offers/{ids['o_checkin']}", {'action': 'decline'})
    step('decline the check-in', code, body)
    code, body = side.offer('otto', 'checkin', {'goal': ids['a'], 'summary': 'Trying again.'})
    step('a second check-in this week', code, body)

    # Where it stands, the page, looks-done answered both ways, the number read by its bot
    code, body = side.update('otto', ids['a'], stands={'text': 'The venue is booked.', 'next': 'the invites'},
                             page={'worked': 'Calling ahead.'}, looks_done=ids['m2'], why='The invites went out.')
    step('goals_update stands, page, looks_done', code, {})
    step('the goal with where it stands and a looks-done', 200, goal('a'))
    a = goal('a')
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'offer_answer': 'keep'})
    step('PATCH offer_answer keep (Not Yet)', code, a)
    code, body = side.update('otto', ids['a'], looks_done=ids['m2'])
    step('looks-done again with nothing ticked since', code, body if code != 200 else {})
    code, body = side.update('otto', ids['a'], looks_done='Venue booked')
    step('looks-done for the first milestone', code, {} if code == 200 else body)
    a = goal('a')
    code, a = side.request('PATCH', f"/goals/{ids['a']}", {'rev': a['rev'], 'offer_answer': 'done'})
    step('PATCH offer_answer done (Mark Done)', code, a)
    code, body = side.update('ivy', ids['a'], measure_now=4)
    step('the number read by its bot', code, {} if code == 200 else body)
    code, body = side.update('otto', ids['a'], measure_now=5)
    step('the number set by another bot', code, body)
    step('the goal after the reading', 200, goal('a'))

    # The Goal Page
    code, body = side.request('GET', f"/goals/{ids['a']}/page", params={'names': json.dumps({'otto': 'Otto'})})
    step('GET the Goal Page', code, {'html': 'html' in body, 'led_by': 'Led by Otto' in body.get('html', ''),
                                     'title': 'Ship the beta' in body.get('html', ''), 'stands': 'The venue is booked.' in body.get('html', '')})
    code, body = side.request('GET', '/goals/nope/page')
    step('GET an unknown goal\'s page', code, body)
    listing('GET /tasks at the end')
    code, body = side.request('DELETE', f"/goals/{ids['a']}")
    step('DELETE the goal', code, body)
    listing('GET /tasks after the delete')
    return out


# ---------------------------------------------------------------------------------------------------------------------
# Comparing: ids, times, revs and positions aside
# ---------------------------------------------------------------------------------------------------------------------

def collect_ids(value, found):
    if isinstance(value, dict):
        for key, inner in value.items():
            if key in ('id', 'made_goal') and isinstance(inner, str): found.add(inner)
            if key in ('added', 'kept') and isinstance(inner, list):
                found.update(i for i in inner if isinstance(i, str))
            collect_ids(inner, found)
    elif isinstance(value, list):
        for inner in value: collect_ids(inner, found)


def normal(value, ids, key=None):
    if isinstance(value, dict):
        return {k: normal(v, ids, k) for k, v in value.items()}
    if isinstance(value, list):
        items = [normal(v, ids) for v in value]
        if items and all(isinstance(i, dict) for i in items):
            items.sort(key=lambda i: json.dumps(i, sort_keys=True))
        return items
    if key in TIME_KEYS and value: return '<time>'
    if key in ('rev', 'position') and isinstance(value, (int, float)) and not isinstance(value, bool): return f'<{key}>'
    if isinstance(value, str) and value in ids: return '<id>'
    if isinstance(value, (int, float)) and not isinstance(value, bool): return float(value)
    return value


def differences(path, a, b, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if key not in b: out.append(f'{path}.{key}: only the add-on has it ({json.dumps(a[key])[:120]})')
            elif key not in a: out.append(f'{path}.{key}: only the stand-in has it ({json.dumps(b[key])[:120]})')
            else: differences(f'{path}.{key}', a[key], b[key], out)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)): differences(f'{path}[{i}]', x, y, out)
    elif isinstance(a, list) and isinstance(b, list):
        out.append(f'{path}: add-on has {len(a)}, stand-in has {len(b)}')
        for i in range(max(len(a), len(b))):
            x = a[i] if i < len(a) else None
            y = b[i] if i < len(b) else None
            if x != y: out.append(f'    [{i}] add-on {json.dumps(x)[:300]}\n        stand-in {json.dumps(y)[:300]}')
    elif a != b:
        out.append(f'{path}: add-on {json.dumps(a)[:160]} · stand-in {json.dumps(b)[:160]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--addon', type=Path, default=DEFAULT_ADDON)
    args = parser.parse_args()
    addon, standin = AddOn(args.addon), StandIn()
    runs = {}
    for side in (addon, standin):
        steps = sequence(side)
        found = set()
        collect_ids([body for _, _, body in steps], found)
        runs[side.name] = [(label, code, normal(body, found)) for label, code, body in steps]
    total = 0
    for (label, code_a, body_a), (_, code_b, body_b) in zip(runs['addon'], runs['standin']):
        found = []
        if code_a != code_b: found.append(f'status: add-on {code_a} · stand-in {code_b}')
        differences('body', body_a, body_b, found)
        mark = 'same' if not found else f'{len(found)} differ'
        print(f'[{mark}] {label} ({code_a})')
        for line in found: print(f'    {line}')
        total += len(found)
    print(f'\n{len(runs["addon"])} steps, {total} differences')
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
