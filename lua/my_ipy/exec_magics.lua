-- IPython execution magics for my_ipy.nvim
-- Provides Python code string that defines runcell/runfile line magics.

local M = {}

function M.build()
  return [[
import io, os, re, shlex, contextlib, sys, traceback
from IPython.core.magic import register_line_magic

_CELL_RE = re.compile(r'^# %%+')

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
  ]]
end

return M
