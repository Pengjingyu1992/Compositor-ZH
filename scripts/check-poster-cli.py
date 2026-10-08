"""Exercise the packaged CLI and stdio MCP against disposable synthetic projects."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('helper', type=Path)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
helper = str(args.helper.resolve())
root = args.output or Path(tempfile.mkdtemp(prefix='compositor-cli-check-'))
root.mkdir(parents=True, exist_ok=True)
checks = 0


def check(label, condition):
    global checks
    checks += 1
    if not condition:
        raise AssertionError(label)


def cli(*parameters, fails=False):
    result = subprocess.run([helper, *map(str, parameters)], capture_output=True, text=True, timeout=60)
    check('CLI exit code', (result.returncode != 0) == fails)
    if fails:
        check('CLI error JSON', 'error' in json.loads(result.stderr.strip().splitlines()[-1]))
        return None
    return json.loads(result.stdout)


server = subprocess.Popen([helper, 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, bufsize=1)
sequence = 0


def request(method, params):
    global sequence
    sequence += 1
    server.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': sequence, 'method': method, 'params': params}) + '\n')
    server.stdin.flush()
    response = json.loads(server.stdout.readline())
    check('JSON-RPC response identity', response.get('id') == sequence and 'error' not in response)
    return response['result']


def tool(name, fields, error=False):
    response = request('tools/call', {'name': name, 'arguments': fields})
    check(name + ' status', response.get('isError') is error)
    return response['content'][0]['text'] if error else json.loads(response['content'][0]['text'])


try:
    initialized = request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'Regression', 'version': '1'}})
    check('MCP version negotiation', initialized['protocolVersion'] == '2025-11-25')
    definitions = request('tools/list', {})['tools']
    check('MCP tools', len(definitions) == 10 and 'close_project' in [t['name'] for t in definitions])
    tool('new_project', {'width': True, 'height': 64}, error=True)
    created = tool('new_project', {'width': 160, 'height': 120})
    handle, state = created['handle'], created['state']
    example = cli('example')
    def edit(commands, document=state['documentID'], revision=None, lock_revision=None, error=False):
        return tool('edit_project', {'handle': handle, 'documentID': document,
                    'expectedRevision': revision or state['revision'], 'expectedLockRevision': lock_revision or state['lockRevision'], 'commands': commands}, error)
    initial = state.copy()
    state = edit(example)['state']
    check('MCP adds live fill', state['layers'][-1]['editableFill'] and state['revision'] != initial['revision'])
    changed = state.copy()
    edit([{'kind': 'opacity', 'opacity': 0.4}, {'kind': 'opacity', 'opacity': 3}], error=True)
    check('MCP failure rollback', tool('project_state', {'handle': handle}) == changed)
    edit([{'kind': 'remove'}], revision=initial['revision'], error=True)
    state = tool('set_layer_locks', {'handle': handle, 'expectedRevision': state['revision'], 'layerID': state['layers'][-1]['id'], 'locks': 2})
    check('Lock revision separate', state['revision'] == changed['revision'] and state['lockRevision'] != changed['lockRevision'])
    edit([{'kind': 'invert'}], error=True)
    edit([{'kind': 'opacity', 'opacity': 0.4}], lock_revision=changed['lockRevision'], error=True)
    state = tool('set_layer_locks', {'handle': handle, 'expectedRevision': state['revision'], 'layerID': state['layers'][-1]['id'], 'locks': 0})
    state = tool('undo', {'handle': handle, 'expectedRevision': state['revision']})
    check('MCP one-step undo', len(state['layers']) == len(initial['layers']))
    state = tool('redo', {'handle': handle, 'expectedRevision': state['revision']})
    check('MCP redo restores fill', state['layers'][-1]['editableFill'])
    project = root / 'source.comp'
    tool('save_project', {'handle': handle, 'expectedRevision': state['revision'], 'path': str(project)})
    tool('save_project', {'handle': handle, 'expectedRevision': state['revision'], 'path': str(project)}, error=True)
    tool('export_project', {'handle': handle, 'expectedRevision': state['revision'], 'path': str(root / 'mcp.png')})
    tool('export_project', {'handle': handle, 'expectedRevision': state['revision'], 'path': str(root / 'mcp.png')}, error=True)
    check('MCP closes project', tool('close_project', {'handle': handle})['closed'] == handle)
    tool('project_state', {'handle': handle}, error=True)
finally:
    server.stdin.close()
    try:
        server.wait(timeout=15)
    except subprocess.TimeoutExpired:
        server.kill()
        raise
    errors = server.stderr.read()
    check('MCP exits cleanly', server.returncode == 0)

inspected = cli('inspect', project)
check('CLI reads fill', inspected['layers'][-1]['editableFill'])
cli('preview', project, root / 'cli.png')
cli('preview', project, root / 'cli.png', fails=True)
commands = root / 'commands.json'
commands.write_text(json.dumps(example + [{'kind': 'opacity', 'opacity': 0.5}]))
cli('batch', project, commands, root / 'batch.comp', inspected['sourceFingerprint'])
check('CLI preserves source', cli('inspect', project)['sourceFingerprint'] == inspected['sourceFingerprint'])
check('CLI changes output', cli('inspect', root / 'batch.comp')['layers'][-1]['opacity'] == 0.5)
cli('batch', project, commands, root / 'batch.comp', inspected['sourceFingerprint'], fails=True)
cli('batch', project, commands, root / 'stale.comp', 'badsha', fails=True)
check('No stale output', not (root / 'stale.comp').exists())
commands.write_text(json.dumps(example + [{'kind': 'opacity', 'opacity': 5}]))
cli('batch', project, commands, root / 'failed.comp', inspected['sourceFingerprint'], fails=True)
check('No failed output', not (root / 'failed.comp').exists())
check('Failed batch keeps source', cli('inspect', project)['sourceFingerprint'] == inspected['sourceFingerprint'])
print(f'CLI/MCP: {checks} checks, 0 failures')
