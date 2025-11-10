"""Helper script injected via ZMQ to set debugfile auto-import statements."""

import json
import sys

try:
    _myipy_set_debugfile_imports
except NameError as exc:  # pragma: no cover
    raise RuntimeError("ipybridge bootstrap helpers are not loaded") from exc

_IMPORTS = json.loads(r"""__IMPORTS_JSON__""")
if not isinstance(_IMPORTS, str):
    _IMPORTS = ""

try:
    _myipy_set_debugfile_imports(_IMPORTS)
except Exception as exc:  # pragma: no cover - best effort logging
    sys.stderr.write("[ipybridge] set debugfile imports failed: %s\n" % (exc,))
