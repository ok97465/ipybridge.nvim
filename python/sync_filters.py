"""Synchronise variable explorer filters inside the kernel."""

import json
import sys

try:
    _myipy_sync_var_filters
    _myipy_set_debug_logging
except NameError:  # pragma: no cover
    raise RuntimeError("ipybridge bootstrap helpers are not loaded")

_names = json.loads(r'''__NAMES_JSON__''')
_types = json.loads(r'''__TYPES_JSON__''')
_max_repr = __MAX_REPR__
_enable_logs = __ENABLE_LOGS__

try:
    _myipy_sync_var_filters(_names, _types, _max_repr)
except Exception as exc:
    sys.stderr.write('[ipybridge] sync filters failed: %s\n' % (exc,))

try:
    _myipy_set_debug_logging(_enable_logs)
except Exception:
    pass
