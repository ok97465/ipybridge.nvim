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
