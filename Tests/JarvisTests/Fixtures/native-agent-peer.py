#!/usr/bin/env python3
"""Local protocol peer: no credentials, model calls or user data."""
import json
import re
import sys
import time
from pathlib import Path

args = sys.argv[1:]
agent = Path(sys.argv[0]).name
scenario = json.loads(Path('native-scenario.json').read_text())
native = 'app-server' in args or '--input-format' in args
is_plan = 'ORBIT_PLAN_REPORT:' in '\n'.join(args)
with open('native-launches.jsonl', 'a') as log:
    log.write(json.dumps({'agent': agent, 'args': args, 'native': native, 'plan': is_plan}) + '\n')

def emit(frame):
    print(json.dumps(frame), flush=True)

if not native:
    prompt = '\n'.join(args)
    token = re.search(r'"token":"([A-Fa-f0-9-]+)"', prompt).group(1)
    reviews = [json.loads(line) for line in Path('native-launches.jsonl').read_text().splitlines() if not json.loads(line)['native'] and not json.loads(line).get('plan')]
    sequence = scenario.get('reviewSequence', [])
    verdict = sequence[min(len(reviews)-1, len(sequence)-1)] if sequence else scenario.get('verdict', 'passed')
    text = 'ORBIT_REVIEW_REPORT: ' + json.dumps({'token': token, 'verdict': verdict, 'summary': 'Inspected files', 'findings': [] if verdict == 'passed' else ['implementation.txt:1: Incorrect result']})
    if is_plan:
        text = 'ORBIT_PLAN_REPORT: ' + json.dumps({'token': token, 'verdict': 'ready', 'summary': 'Piano del progetto', 'steps': ['Implementare il requisito', 'Review e verifica']})
    if agent == 'codex':
        emit({'type': 'thread.started', 'thread_id': 'review-context'})
        emit({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': text}})
        emit({'type': 'turn.completed'})
    else:
        emit({'type': 'result', 'session_id': 'review-context', 'subtype': 'success', 'is_error': False, 'result': text})
    sys.exit(0)

remote = 'bf32e3b2-1a28-431e-ad5a-2f42b5241a34'
turn = 'native-turn-1'
permission = 900 if agent == 'codex' else '900'
resumed = False
correction = False
permission_sent = False
mode = scenario.get('mode', 'approval')
if '--resume' in args:
    resumed = True
    remote = args[args.index('--resume') + 1]
elif '--session-id' in args:
    remote = args[args.index('--session-id') + 1]

def finish(interrupted=False):
    if agent == 'codex':
        if not interrupted:
            emit({'method': 'item/completed', 'params': {'threadId': remote, 'turnId': turn, 'item': {'id': 'message', 'type': 'agentMessage', 'text': 'Completed'}}})
        emit({'method': 'turn/completed', 'params': {'threadId': remote, 'turn': {'id': turn, 'status': 'interrupted' if interrupted else scenario.get('status', 'completed')}}})
    else:
        failed = scenario.get('status') == 'failed'
        emit({'type': 'result', 'session_id': remote, 'subtype': 'error_during_execution' if interrupted or failed else 'success',
            'is_error': interrupted or failed, 'errors': ['Interrupted by user'] if interrupted else ['Fixture failure'] if failed else [], 'result': 'Completed'})

def start_prompt():
    global permission_sent
    effective_mode = scenario.get('correctionMode', mode) if correction else mode
    if resumed or effective_mode == 'complete':
        Path('implementation.txt').write_text('Implemented')
        if correction or (resumed and scenario.get('correctionMode')): Path('corrected.txt').write_text('Corrected')
        finish()
        return
    if agent == 'codex':
        params = {'threadId': remote, 'turnId': 'stale-turn' if scenario.get('staleTurn') else turn, 'itemId': 'tool-1',
            'command': 'printf test > approval.txt', 'cwd': str(Path.cwd()), 'availableDecisions': ['accept', 'acceptForSession', 'decline', 'cancel']}
        method = 'item/commandExecution/requestApproval'
        if scenario.get('permissionsScope'):
            method = 'item/permissions/requestApproval'
            params['permissions'] = {'fileSystem': {'write': [str(Path.cwd() / 'outside')]}}
        emit({'id': permission, 'method': method, 'params': params})
    else:
        emit({'type': 'system', 'subtype': 'init', 'session_id': remote})
        emit({'type': 'control_request', 'request_id': permission, 'request': {'subtype': 'can_use_tool',
            'tool_name': 'Bash', 'tool_use_id': 'tool-1', 'input': {'command': 'printf test > approval.txt'}}})
    permission_sent = True
    if scenario.get('repeatID'):
        if agent == 'codex': emit({'id': permission, 'method': method, 'params': params})
        else: emit({'type': 'control_request', 'request_id': permission, 'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'input': {}}})
    if scenario.get('exitWaiting'): sys.exit(0)

for line in sys.stdin:
    frame = json.loads(line)
    with open('native-wire.jsonl', 'a') as log:
        log.write(json.dumps(frame) + '\n')
    if agent == 'codex':
        method = frame.get('method')
        if method == 'initialize': emit({'id': frame['id'], 'result': {'userAgent': 'fixture'}})
        elif method in ('thread/start', 'thread/resume'):
            resumed = method == 'thread/resume'
            if resumed: remote = frame['params']['threadId']
            emit({'id': frame['id'], 'result': {'thread': {'id': remote}}})
        elif method == 'turn/start':
            correction = 'Orbit automatic correction' in json.dumps(frame['params'])
            emit({'id': frame['id'], 'result': {'turn': {'id': turn, 'status': 'inProgress'}}})
            emit({'method': 'turn/started', 'params': {'threadId': remote, 'turn': {'id': turn, 'status': 'inProgress'}}})
            start_prompt()
        elif method == 'turn/interrupt':
            if scenario.get('ignoreInterrupt'): continue
            if permission_sent: emit({'method': 'serverRequest/resolved', 'params': {'threadId': remote, 'requestId': permission}})
            finish(interrupted=True)
            if not scenario.get('terminalWithoutAck'): emit({'id': frame['id'], 'result': {}})
            if scenario.get('terminalWithoutAck'): sys.exit(0)
        elif frame.get('id') == permission and 'result' in frame:
            if (scenario.get('correctionMode', mode) if correction else mode) == 'steer': continue
            result = frame['result']
            allowed = result.get('decision') == 'accept' or bool(result.get('permissions'))
            if allowed:
                Path('approved.txt').write_text('approved')
                if correction: Path('corrected.txt').write_text('Corrected')
            finish()
        elif 'error' in frame:
            finish()
    else:
        kind = frame.get('type')
        if kind == 'control_request':
            subtype = frame['request']['subtype']
            if subtype == 'initialize': emit({'type': 'control_response', 'response': {'request_id': frame['request_id'], 'subtype': 'success', 'response': {}}})
            elif subtype == 'interrupt':
                if scenario.get('ignoreInterrupt'): continue
                if permission_sent: emit({'type': 'control_cancel_request', 'request_id': permission})
                finish(interrupted=True)
                if not scenario.get('terminalWithoutAck'): emit({'type': 'control_response', 'response': {'request_id': frame['request_id'], 'subtype': 'success', 'response': {}}})
                if scenario.get('terminalWithoutAck'): sys.exit(0)
        elif kind == 'user': start_prompt()
        elif kind == 'control_response' and frame['response']['request_id'] == permission:
            if (scenario.get('correctionMode', mode) if correction else mode) == 'steer': continue
            if frame['response'].get('response', {}).get('behavior') == 'allow': Path('approved.txt').write_text('approved')
            finish()
sys.exit(scenario.get('exitCode', 0))
