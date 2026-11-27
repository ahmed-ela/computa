"""Run against a disposable stack, passing ./connect or an SSH command as argv."""
import base64
import json
import re
import socket
import subprocess
import sys
import time
import uuid
from contextlib import ExitStack, contextmanager

from websockets.sync.client import unix_connect


@contextmanager
def client(command):
    with ExitStack() as stack:
        local, child = socket.socketpair()
        stack.callback(local.close)
        with child:
            proxy = subprocess.Popen(command, stdin=child, stdout=child)
        def close_proxy():
            try:
                proxy.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proxy.terminate()
                proxy.wait(timeout=5)
        stack.callback(close_proxy)
        ws = stack.enter_context(unix_connect(sock=local, proxy=None, open_timeout=20,
                                              close_timeout=2, max_size=16 * 1024 * 1024))
        request_id = 0

        def call(method, params):
            nonlocal request_id
            request_id += 1
            ws.send(json.dumps({'id': request_id, 'method': method, 'params': params}))
            deadline = time.monotonic() + 40
            while True:
                message = json.loads(ws.recv(timeout=max(0, deadline - time.monotonic())))
                if 'method' in message or message.get('id') != request_id:
                    continue
                if 'error' in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message['result']

        call('initialize', {'clientInfo': {'name': 'kolmogor_workspace_test', 'version': '1'},
                            'capabilities': {'experimentalApi': True}})
        ws.send(json.dumps({'method': 'initialized'}))
        yield call


def browser(call, thread, tool, arguments):
    reply = call('mcpServer/tool/call', {'server': 'browser', 'threadId': thread,
                                         'tool': tool, 'arguments': arguments})
    text = '\n'.join(item['text'] for item in reply['content'] if item['type'] == 'text')
    if reply.get('isError'):
        raise RuntimeError(text)
    return text


def check(command):
    marker = 'roundtrip-' + uuid.uuid4().hex
    path = '/workspace/.' + marker
    with client(command) as call:
        thread = call('thread/start', {
            'cwd': '/workspace', 'modelProvider': 'fixture', 'model': 'test-model',
            'approvalPolicy': 'on-request', 'sandbox': 'workspace-write',
            'config': {'model_providers': {'fixture': {
                'name': 'Workspace fixture', 'base_url': 'http://fixture:8080/v1',
                'wire_api': 'responses', 'supports_websockets': False,
            }}},
        })['thread']['id']
        page = 'http://fixture:8080/page?check=' + marker
        navigation = browser(call, thread, 'browser_navigate', {'url': page})
        artifact = re.search(r'\[Snapshot\]\((browser-output/[\w.-]+\.yml)\)', navigation)
        if not artifact:
            raise RuntimeError('Chrome did not return a workspace snapshot file')
        saved = call('fs/readFile', {'path': '/workspace/' + artifact[1]})
        if b'Confirm workspace' not in base64.b64decode(saved['dataBase64']):
            raise RuntimeError('Agent could not read the browser snapshot')
        snapshot = browser(call, thread, 'browser_snapshot', {})
        if 'Confirm workspace' not in snapshot:
            raise RuntimeError('Chrome did not show the fixture button')
        browser(call, thread, 'browser_click', {'target': '#confirm'})
        if 'Browser confirmed ' + marker not in browser(call, thread, 'browser_snapshot', {}):
            raise RuntimeError('Chrome did not confirm the click')
        call('fs/writeFile', {'path': path, 'dataBase64': base64.b64encode(marker.encode()).decode()})
        edit = call('command/exec', {'cwd': '/workspace',
                    'sandboxPolicy': {'type': 'workspaceWrite', 'writableRoots': ['/workspace']},
                    'command': ['sh', '-ec', 'printf %s "-edited" >> "$1"', 'check', path]})
        if edit['exitCode'] != 0:
            raise RuntimeError('Terminal edit failed: ' + edit['stderr'])
        started = call('turn/start', {'threadId': thread,
                       'input': [{'type': 'text', 'text': marker}]})['turn']
        if started['status'] != 'inProgress':
            raise RuntimeError('Expected an in-flight turn at disconnect')
        turn = started['id']

    # A fresh SSH/Compose process reconnects while the fixture response is in flight.
    with client(command) as call:
        try:
            deadline = time.monotonic() + 35
            while True:
                history = call('thread/read', {'threadId': thread, 'includeTurns': True})['thread']
                matches = [t for t in history['turns'] if t['id'] == turn]
                if len(matches) == 1 and matches[0]['status'] == 'completed':
                    break
                if matches and matches[0]['status'] == 'failed':
                    raise RuntimeError(str(matches[0].get('error')))
                if time.monotonic() > deadline:
                    raise TimeoutError('Turn did not finish after disconnection')
                time.sleep(0.4)
            replies = [item['text'] for item in matches[0]['items'] if item['type'] == 'agentMessage']
            data = call('fs/readFile', {'path': path})['dataBase64']
            if replies != ['Finished ' + marker] or base64.b64decode(data).decode() != marker + '-edited':
                raise RuntimeError('Reconnected result or file contents differed')
        finally:
            call('fs/remove', {'path': path, 'recursive': False})
            call('thread/archive', {'threadId': thread})
    print('Passed: Chrome read and click, file write, terminal edit, completed turn after reconnect.')


if __name__ == '__main__':
    if len(sys.argv) == 1:
        raise SystemExit('Usage: check.py ./connect  (or pass an SSH command and its arguments)')
    check(sys.argv[1:])
