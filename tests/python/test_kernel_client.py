import builtins
import importlib.util
import io
import json
import sys
import types
from pathlib import Path

import pytest


def load_kernel_client():
    module_path = Path(__file__).resolve().parents[2] / 'python' / 'myipy_kernel_client.py'
    spec = importlib.util.spec_from_file_location('myipy_kernel_client_test', module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_main_reports_missing_jupyter(monkeypatch, tmp_path, capsys):
    module = load_kernel_client()
    conn = tmp_path / 'conn.json'
    conn.write_text('{}')

    monkeypatch.setattr(module.sys, 'argv', ['prog', '--conn-file', str(conn)])
    monkeypatch.setattr(module.sys, 'stdin', io.StringIO(''))

    original_import = builtins.__import__

    def fake_import(name, globals=None, locals=None, fromlist=(), level=0):
        if name == 'jupyter_client':
            raise ImportError('missing jupyter_client')
        return original_import(name, globals, locals, fromlist, level)

    monkeypatch.setattr(builtins, '__import__', fake_import)

    exit_code = module.main()
    captured = capsys.readouterr()

    assert exit_code == 1
    payload = json.loads(captured.out.strip())
    assert payload['ok'] is False
    assert payload['error'] == 'jupyter_client missing'
    assert captured.err == ''


def test_main_runs_with_stubbed_kernel(monkeypatch, tmp_path, capsys):
    module = load_kernel_client()
    conn = tmp_path / 'conn.json'
    conn.write_text('{}')

    class FakeKC:
        def __init__(self):
            self.loaded = None
            self.started = False
            self.executed = []
            self._prelude_status_sent = False
            stub_module.last_instance = self

        def load_connection_file(self, path):
            self.loaded = path

        def start_channels(self):
            self.started = True

        def execute(self, code, **kwargs):
            self.executed.append(code)
            return f'msg{len(self.executed)}'

        def get_shell_msg(self, timeout=None):
            return {}

        def get_iopub_msg(self, timeout=None):
            if not self._prelude_status_sent:
                self._prelude_status_sent = True
                return {'msg_type': 'status', 'content': {'execution_state': 'idle'}}
            raise Exception('idle reached')

    stub_module = types.ModuleType('jupyter_client')
    stub_module.BlockingKernelClient = FakeKC

    monkeypatch.setitem(sys.modules, 'jupyter_client', stub_module)
    monkeypatch.setattr(module.sys, 'argv', ['prog', '--conn-file', str(conn), '--debug'])
    monkeypatch.setattr(module.sys, 'stdin', io.StringIO(''))

    result = module.main()
    captured = capsys.readouterr()

    assert result is None
    assert '[myipy.zmq] channels started' in captured.err
    assert '[myipy.zmq] prelude ready' in captured.err
    assert captured.out == ''

    fake = stub_module.last_instance
    assert fake.loaded == str(conn)
    assert fake.started is True
    assert fake.executed and '__mi_list_vars' in fake.executed[0]


class DummyLogger:
    def __init__(self):
        self.messages = []

    def log(self, message):
        self.messages.append(message)


class FakeClientSuccess:
    def __init__(self):
        self.executed = []
        self._iopub_msgs = [
            {
                'parent_header': {'msg_id': 'msg1'},
                'msg_type': 'stream',
                'content': {'name': 'stdout', 'text': '{"answer": 42}'},
            },
            {
                'parent_header': {'msg_id': 'msg1'},
                'msg_type': 'status',
                'content': {'execution_state': 'idle'},
            },
        ]

    def load_connection_file(self, path):
        self.loaded = path

    def start_channels(self):
        self.started = True

    def execute(self, code, **kwargs):
        self.executed.append((code, kwargs))
        msg_id = f'msg{len(self.executed)}'
        if 'print(42)' in code or not self._iopub_msgs:
            self._iopub_msgs = [
                {
                    'parent_header': {'msg_id': msg_id},
                    'msg_type': 'stream',
                    'content': {'name': 'stdout', 'text': '{"answer": 42}'},
                },
                {
                    'parent_header': {'msg_id': msg_id},
                    'msg_type': 'status',
                    'content': {'execution_state': 'idle'},
                },
            ]
        return msg_id

    def get_iopub_msg(self, timeout=None):
        if self._iopub_msgs:
            return self._iopub_msgs.pop(0)
        raise Exception('idle reached')

    def get_shell_msg(self, timeout=None):
        return {'content': {'status': 'ok'}}


class FakeClientError(FakeClientSuccess):
    def execute(self, code, **kwargs):
        self.executed.append((code, kwargs))
        msg_id = f'err{len(self.executed)}'
        self._iopub_msgs = [
            {
                'parent_header': {'msg_id': msg_id},
                'msg_type': 'error',
                'content': {'traceback': ['Traceback', 'ValueError: boom']},
            },
        ]
        return msg_id

    def get_shell_msg(self, timeout=None):
        return {'content': {'status': 'error', 'ename': 'ValueError', 'evalue': 'boom'}}


class DummyPreview:
    def __init__(self, result):
        self.result = result
        self.calls = []

    def request(self, name, rows, cols, row_offset, col_offset):
        self.calls.append((name, rows, cols, row_offset, col_offset))
        return self.result


class DummyChannel:
    def __init__(self, payload):
        self.payload = payload
        self.calls = []

    def run_and_collect(self, code, **kwargs):
        self.calls.append(code)
        return self.payload


def test_kernel_channel_run_and_collect_success(monkeypatch):
    module = load_kernel_client()
    channel = module.KernelChannel(lambda: FakeClientSuccess(), DummyLogger())
    channel.connect('conn.json', 'print(1)')
    ok, data, err = channel.run_and_collect('print(42)')
    assert ok is True
    assert data == {'answer': 42}
    assert err is None


def test_kernel_channel_run_and_collect_error(monkeypatch):
    module = load_kernel_client()
    channel = module.KernelChannel(lambda: FakeClientError(), DummyLogger())
    channel.connect('conn.json', 'print(1)')
    ok, data, err = channel.run_and_collect('print(42)')
    assert ok is False
    assert data is None
    assert 'ValueError' in err


def test_request_processor_debug_preview_fallback(monkeypatch):
    module = load_kernel_client()
    channel = DummyChannel((True, {'name': 'foo'}, None))
    preview = DummyPreview((False, None, 'socket error'))
    processor = module.RequestProcessor(channel, preview, DummyLogger())
    response = processor._handle_preview('1', {
        'name': 'foo',
        'debug': True,
        'max_rows': 5,
        'max_cols': 4,
        'row_offset': 0,
        'col_offset': 0,
    })
    assert preview.calls
    assert any('__mi_debug_preview' in code for code in channel.calls)
    assert response['ok'] is True
    assert response['data'] == {'name': 'foo'}


def test_request_processor_preview_exec(monkeypatch):
    module = load_kernel_client()
    payload = (True, {'name': 'bar'}, None)
    channel = DummyChannel(payload)
    preview = DummyPreview((True, {'ok': True}, None))
    processor = module.RequestProcessor(channel, preview, DummyLogger())
    response = processor._handle_preview('2', {
        'name': 'bar',
        'debug': False,
        'max_rows': 10,
        'max_cols': 3,
        'row_offset': 2,
        'col_offset': 1,
    })
    assert '__mi_preview' in channel.calls[0]
    assert response['ok'] is True
    assert response['data'] == {'name': 'bar'}
