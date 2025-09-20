-- IPython execution magics for ipybridge.nvim
-- Provides Python code string that defines runcell/runfile line magics.

local M = {}

function M.build()
  return [[
import io, os, re, shlex, contextlib, sys, traceback, threading, time
from IPython.core.magic import register_line_magic

_CELL_RE = re.compile(r'^# %%+')

# Matplotlib import is optional and lazily used inside debugfile.
try:
    import matplotlib.pyplot as _mi_plt
except Exception:
    _mi_plt = None

def _mi_get_qapp():
    """Return a running Qt application instance if available."""
    candidates = [
        ('qtpy.QtWidgets', 'QApplication'),
        ('PyQt6.QtWidgets', 'QApplication'),
        ('PySide6.QtWidgets', 'QApplication'),
        ('PyQt5.QtWidgets', 'QApplication'),
        ('PySide2.QtWidgets', 'QApplication'),
    ]
    for mod_name, cls_name in candidates:
        try:
            module = __import__(mod_name, fromlist=[cls_name])
            cls = getattr(module, cls_name)
            app = cls.instance()
            if app is None:
                # Avoid creating a brand-new QApplication because the user session
                # may not expect it; only reuse existing ones.
                continue
            return app
        except Exception:
            continue
    return None

_mi_qt_pump_thread = None
def _mi_start_qt_pump(interval=0.03):
    global _mi_qt_pump_thread
    if _mi_qt_pump_thread is not None and _mi_qt_pump_thread.is_alive():
        return

    thread = None

    def _pump():
        while True:
            app = None
            try:
                app = _mi_get_qapp()
            except Exception:
                app = None
            if app is not None:
                try:
                    app.processEvents()
                except Exception:
                    pass
            time.sleep(interval)

    thread = threading.Thread(target=_pump, name='ipybridge-qt-pump', daemon=True)
    thread.start()
    _mi_qt_pump_thread = thread

def _mi_process_qt_once():
    app = _mi_get_qapp()
    if app is None:
        return
    try:
        app.processEvents()
    except Exception:
        pass

_mi_kernel_input_patched = False

def _mi_patch_kernel_input():
    global _mi_kernel_input_patched
    if _mi_kernel_input_patched:
        return
    try:
        from ipykernel import kernelbase as _mi_kbase
        from ipykernel.jsonutil import json_clean
        import zmq
    except Exception:
        return

    def _ipybridge_input_request(self, prompt, ident, parent, password=False):
        sys.stderr.flush()
        sys.stdout.flush()

        while True:
            try:
                self.stdin_socket.recv_multipart(zmq.NOBLOCK)
            except zmq.ZMQError as exc:
                if exc.errno == zmq.EAGAIN:
                    break
                raise

        assert self.session is not None
        content = json_clean(dict(prompt=prompt, password=password))
        self.session.send(self.stdin_socket, "input_request", content, parent, ident=ident)

        while True:
            _mi_process_qt_once()
            try:
                ready, _, xready = zmq.select([self.stdin_socket], [], [self.stdin_socket], 0.01)
                if ready or xready:
                    ident_reply, reply = self.session.recv(self.stdin_socket)
                    if (ident_reply, reply) != (None, None):
                        break
            except KeyboardInterrupt:
                raise KeyboardInterrupt("Interrupted by user") from None
            except Exception:
                self.log.warning("Invalid Message:", exc_info=True)

        try:
            value = reply["content"]["value"]
        except Exception:
            self.log.error("Bad input_reply: %s", parent)
            value = ""
        if value == "\x04":
            raise EOFError
        return value

    _mi_kbase.Kernel._input_request = _ipybridge_input_request
    _mi_kernel_input_patched = True

_MI_QT_BACKENDS = ('qt', 'qt5', 'qt6')

def _mi_enable_matplotlib(backends=_MI_QT_BACKENDS):
    shells = []
    try:
        from ipykernel.kernelapp import IPKernelApp
        app = IPKernelApp.instance()
    except Exception:
        app = None
    if app is not None:
        try:
            shell = getattr(app, 'shell', None)
        except Exception:
            shell = None
        if shell is not None:
            shells.append(shell)
    try:
        from IPython import get_ipython
        ip = get_ipython()
    except Exception:
        ip = None
    if ip is not None and ip not in shells:
        shells.append(ip)
    for shell in shells:
        for backend in backends:
            try:
                shell.enable_matplotlib(backend)
                return True
            except Exception:
                try:
                    shell.run_line_magic('matplotlib', backend)
                    return True
                except Exception:
                    continue
    if ip is not None:
        for backend in backends:
            try:
                ip.run_line_magic('matplotlib', backend)
                return True
            except Exception:
                try:
                    ip.enable_matplotlib(backend)
                    return True
                except Exception:
                    continue
    return False

def _mi_enable_gui(backends=_MI_QT_BACKENDS):
    try:
        from ipykernel.kernelapp import IPKernelApp
        app = IPKernelApp.instance()
    except Exception:
        app = None
    if app is not None:
        for backend in backends:
            try:
                if getattr(app, '_gui', None) == backend:
                    return True
                app.enable_gui(backend)
                return True
            except Exception:
                continue
    try:
        from ipykernel import eventloops as _mi_eventloops
        for backend in backends:
            try:
                _mi_eventloops.enable_gui(backend)
                return True
            except Exception:
                continue
    except Exception:
        pass
    return False

@contextlib.contextmanager
def _mi_qt_events(interval=0.03):
    """Ensure the IPython inputhook is configured for Qt during debugging."""
    _mi_patch_kernel_input()
    _mi_enable_matplotlib()
    _mi_enable_gui()
    _mi_start_qt_pump(interval)
    try:
        yield
    finally:
        pass

class _MiQtAwarePdb:
    """Factory for a Qt-aware Pdb subclass (lazily created)."""

    _cls = None

    @classmethod
    def get(cls):
        if cls._cls is not None:
            return cls._cls
        try:
            from IPython.core.debugger import Pdb
        except Exception:
            return None

        class QtAwarePdb(Pdb):
            def interaction(self, *args, **kwargs):
                with _mi_qt_events():
                    return super().interaction(*args, **kwargs)

        cls._cls = QtAwarePdb
        return cls._cls

@contextlib.contextmanager
def _mi_cwd(path):
    if not path:
        yield; return
    try:
        old = os.getcwd()
    except Exception:
        old = None
    try:
        os.chdir(path)
        yield
    finally:
        if old is not None:
            try:
                os.chdir(old)
            except Exception:
                pass

@contextlib.contextmanager
def _mi_exec_env(filename):
    g = globals()
    prev_file = g.get('__file__', None)
    added = False
    try:
        fdir = os.path.dirname(os.path.abspath(filename))
        if fdir and fdir not in sys.path:
            sys.path.insert(0, fdir)
            added = True
        g['__file__'] = filename
        yield
    finally:
        if added:
            try:
                sys.path.remove(fdir)
            except Exception:
                pass
        if prev_file is None:
            g.pop('__file__', None)
        else:
            g['__file__'] = prev_file

def runcell(index, filename, cwd=None):
    try:
        idx = int(index)
    except Exception:
        print('runcell: invalid index'); return
    try:
        with io.open(filename, 'r', encoding='utf-8') as f:
            lines = f.read().splitlines()
    except Exception as e:
        print(f'runcell: cannot read {filename}: {e}'); return
    # Compute cell starts using only explicit markers ('# %%'), index is 0-based over markers
    starts = [i for i, ln in enumerate(lines) if _CELL_RE.match(ln)]
    starts = sorted(set(starts))
    if idx < 0 or idx >= len(starts):
        print(f'runcell: index out of range: {idx}'); return
    s = starts[idx]
    # Next marker (or EOF)
    e = (starts[idx + 1] - 1) if (idx + 1) < len(starts) else (len(lines) - 1)
    code = '\n'.join(lines[s:e+1]) + '\n'
    with _mi_cwd(cwd):
        with _mi_exec_env(filename):
            try:
                exec(compile(code, filename, 'exec'), globals(), globals())
            except SystemExit:
                # Allow graceful exits without noisy tracebacks
                pass
            except Exception:
                traceback.print_exc()

@register_line_magic('runcell')
def _runcell_magic(line):
    try:
        parts = shlex.split(line)
    except Exception:
        print('Usage: %runcell <index> <path> [cwd]'); return
    if len(parts) < 2:
        print('Usage: %runcell <index> <path> [cwd]'); return
    try:
        idx = int(parts[0])
    except Exception:
        print('runcell: invalid index'); return
    cwd = parts[2] if len(parts) > 2 else None
    runcell(idx, parts[1], cwd)
 
def runfile(filename, cwd=None):
    try:
        with io.open(filename, 'r', encoding='utf-8') as f:
            src = f.read()
    except Exception as e:
        print(f'runfile: cannot read {filename}: {e}'); return
    with _mi_cwd(cwd):
        with _mi_exec_env(filename):
            try:
                exec(compile(src, filename, 'exec'), globals(), globals())
            except SystemExit:
                pass
            except Exception:
                traceback.print_exc()

@register_line_magic('runfile')
def _runfile_magic(line):
    try:
        parts = shlex.split(line)
    except Exception:
        print('Usage: %runfile <path> [cwd]'); return
    if len(parts) < 1:
        print('Usage: %runfile <path> [cwd]'); return
    path = parts[0]
    cwd = parts[1] if len(parts) > 1 else None
    runfile(path, cwd)

def debugfile(filename, cwd=None):
    pdb_cls = _MiQtAwarePdb.get()
    if pdb_cls is None:
        print('debugfile: IPython debugger is unavailable'); return
    try:
        with io.open(filename, 'r', encoding='utf-8') as f:
            src = f.read()
    except Exception as e:
        print(f'debugfile: cannot read {filename}: {e}'); return
    try:
        if _mi_plt is not None:
            _mi_plt.ion()
            _mi_start_qt_pump()
            if not hasattr(_mi_plt, '_myipy_orig_show'):
                _mi_plt._myipy_orig_show = _mi_plt.show

                def _mi_debug_show(*args, **kwargs):
                    kwargs.setdefault('block', False)
                    result = _mi_plt._myipy_orig_show(*args, **kwargs)
                    app = _mi_get_qapp()
                    if app is not None:
                        for _ in range(5):
                            try:
                                app.processEvents()
                            except Exception:
                                break
                            time.sleep(0.01)
                    return result

                _mi_plt.show = _mi_debug_show
    except Exception:
        pass
    _mi_enable_matplotlib()
    _mi_enable_gui()
    glbs = globals()
    dbg = pdb_cls()
    try:
        dbg.clear_all_breaks()
    except Exception:
        pass
    try:
        bp_map = glbs.get('__ipybridge_breakpoints__', {})
    except Exception:
        bp_map = {}
    if isinstance(bp_map, dict):
        for bp_file, bp_lines in bp_map.items():
            if not isinstance(bp_lines, (list, tuple, set)):
                continue
            for bp_line in bp_lines:
                try:
                    line_no = int(bp_line)
                except Exception:
                    continue
                try:
                    dbg.set_break(bp_file, line_no)
                except Exception:
                    pass
    old_break_hook = getattr(sys, 'breakpointhook', None)
    try:
        sys.breakpointhook = dbg.set_trace
    except Exception:
        old_break_hook = None
    try:
        with _mi_cwd(cwd):
            with _mi_exec_env(filename):
                code = compile(src, filename, 'exec')
                dbg.reset()
                dbg.runctx(code, glbs, glbs)
    except SystemExit:
        pass
    except Exception:
        traceback.print_exc()
    finally:
        if _mi_plt is not None and hasattr(_mi_plt, '_myipy_orig_show'):
            try:
                _mi_plt.show = _mi_plt._myipy_orig_show
            except Exception:
                pass
            try:
                delattr(_mi_plt, '_myipy_orig_show')
            except Exception:
                pass
        if old_break_hook is not None:
            try:
                sys.breakpointhook = old_break_hook
            except Exception:
                pass
        else:
            try:
                del sys.breakpointhook
            except Exception:
                pass
        try:
            dbg.quitting = True
        except Exception:
            pass

@register_line_magic('debugfile')
def _debugfile_magic(line):
    try:
        parts = shlex.split(line)
    except Exception:
        print('Usage: %debugfile <path> [cwd]'); return
    if len(parts) < 1:
        print('Usage: %debugfile <path> [cwd]'); return
    path = parts[0]
    cwd = parts[1] if len(parts) > 1 else None
    debugfile(path, cwd)
  ]]
end

return M
