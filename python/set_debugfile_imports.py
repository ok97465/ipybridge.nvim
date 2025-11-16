"""Helper script injected via ZMQ to set debugfile auto-import statements."""

import json
import sys

try:
    _myipy_set_debugfile_imports
except NameError as exc:  # pragma: no cover
    raise RuntimeError("ipybridge bootstrap helpers are not loaded") from exc

# JSON payload wrapped in a multiline raw string to avoid syntax errors when
# the encoded string itself is empty (e.g. JSON is just "").
_IMPORTS_JSON = r"""
__IMPORTS_JSON__
""".strip()
_IMPORTS = json.loads(_IMPORTS_JSON)
if not isinstance(_IMPORTS, str):
    _IMPORTS = ""

try:
    _myipy_set_debugfile_imports(_IMPORTS)
except Exception as exc:  # pragma: no cover - best effort logging
    sys.stderr.write("[ipybridge] set debugfile imports failed: %s\n" % (exc,))
