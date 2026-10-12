#!/usr/bin/env python3
"""Deterministic local worker. Emits CLI frames without contacting a provider."""
import json
import re
import sys
import time
from pathlib import Path

scenario = json.loads(Path('workflow-scenario.json').read_text())
args = sys.argv[1:]
agent = Path(sys.argv[0]).name
prompt = '\n'.join(args)
# Previous node outputs can contain other report types. Identify the current
# contract, which comes after that evidence, rather than any marker in the prompt.
contracts = re.findall(r'(?m)^ORBIT_(PLAN|REVIEW|ACTION|SCORE)_REPORT: \{"token":"([A-Fa-f0-9-]+)"', prompt)
contract, current_token = contracts[-1] if contracts else ('', '')
is_review = contract == 'REVIEW'
is_plan = contract == 'PLAN'
is_action = contract == 'ACTION'
is_score = contract == 'SCORE'
with open('worker-launches.jsonl', 'a') as log:
    log.write(json.dumps({'agent': agent, 'review': is_review, 'plan': is_plan, 'action': is_action, 'score': is_score, 'args': args}) + '\n')
time.sleep(scenario.get('delay', 0.12))
if is_plan:
    token = current_token
    if scenario.get('planStale'): token = '00000000-0000-0000-0000-000000000000'
    text = 'ORBIT_PLAN_REPORT: ' + json.dumps({'token': token, 'verdict': 'blocked' if scenario.get('planBlocked') else 'ready',
        'summary': 'Piano basato sui file del progetto', 'steps': ['Modificare implementation.txt', 'Verificare il requisito con il comando configurato']})
    if scenario.get('planMalformed'): text = 'No structured plan'
    if scenario.get('planDuplicate'): text += '\n' + text
elif is_score:
    token = current_token
    if scenario.get('scoreStale'): token = '00000000-0000-0000-0000-000000000000'
    scores = [json.loads(line) for line in Path('worker-launches.jsonl').read_text().splitlines() if json.loads(line).get('score')]
    sequence = scenario.get('scoreSequence', [95])
    score = sequence[min(len(scores)-1, len(sequence)-1)]
    text = 'ORBIT_SCORE_REPORT: ' + json.dumps({'token': token, 'verdict': 'blocked' if scenario.get('scoreBlocked') else 'scored', 'score': None if scenario.get('scoreBlocked') else score, 'summary': 'Evidenze: criterio verificato. Migliorare copertura e precisione.'})
    if scenario.get('scoreMalformed'): text = 'No structured score report'
    if scenario.get('scoreDuplicate'): text += '\n' + text
elif is_action:
    token = current_token
    if scenario.get('actionStale'): token = '00000000-0000-0000-0000-000000000000'
    actions = [json.loads(line) for line in Path('worker-launches.jsonl').read_text().splitlines() if json.loads(line).get('action')]
    sequence = scenario.get('actionSequence', [])
    verdict = sequence[min(len(actions)-1, len(sequence)-1)] if sequence else scenario.get('actionVerdict', 'passed')
    Path('action.txt').write_text('Executed custom action')
    text = 'ORBIT_ACTION_REPORT: ' + json.dumps({'token': token, 'verdict': verdict, 'summary': 'Esito azione personalizzata'})
    if scenario.get('actionMalformed'): text = 'No structured action report'
    if scenario.get('actionDuplicate'): text += '\n' + text
elif is_review:
    token = current_token
    if scenario.get('staleToken'):
        token = '00000000-0000-0000-0000-000000000000'
    reviews = [json.loads(line) for line in Path('worker-launches.jsonl').read_text().splitlines() if json.loads(line)['review']]
    sequence = scenario.get('reviewSequence', [])
    verdict = sequence[min(len(reviews)-1, len(sequence)-1)] if sequence else scenario.get('verdict', 'passed')
    text = 'ORBIT_REVIEW_REPORT: ' + json.dumps({'token': token, 'verdict': verdict,
        'summary': 'Checked project files', 'findings': [] if verdict == 'passed' else ['implementation.txt:1: Incorrect result']})
    if scenario.get('malformed'):
        text = 'Looks fine without a report'
    if scenario.get('duplicate'):
        text = text + '\n' + text
else:
    Path('implementation.txt').write_text('Implemented requirement')
    if 'Orbit automatic correction' in prompt:
        Path('corrected.txt').write_text('Corrected requirement')
        time.sleep(scenario.get('correctionDelay', 0))
    text = 'Implemented requirement; inspect implementation.txt.'
if agent == 'claude':
    print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'worker-context'}))
    print(json.dumps({'type': 'result', 'subtype': 'success', 'result': text, 'is_error': False}))
else:
    print(json.dumps({'type': 'thread.started', 'thread_id': 'worker-context'}))
    print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': text}}))
    print(json.dumps({'type': 'turn.completed'}))
sys.stdout.flush()
sys.exit(scenario.get('actionExit' if is_action else 'reviewExit' if is_review else 'implementationExit', 0))
