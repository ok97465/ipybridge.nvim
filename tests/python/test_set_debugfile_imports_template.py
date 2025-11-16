import json
from pathlib import Path

import pytest


TEMPLATE_PATH = Path(__file__).resolve().parents[2] / "python" / "set_debugfile_imports.py"


def _render_template(block: str) -> str:
    template = TEMPLATE_PATH.read_text()
    payload = json.dumps(block)
    return template.replace("__IMPORTS_JSON__", payload)


@pytest.mark.parametrize(
    "block",
    [
        "",
        "import math",
        "import os as o\nimport sys",
        "print('value \"quoted\" and escaped')",
        r"path = r\"C:\\temp\\\"",
    ],
)
def test_set_debugfile_imports_template_executes(block):
    script = _render_template(block)
    received = {}

    def _capture(value):
        received["value"] = value

    namespace = {"_myipy_set_debugfile_imports": _capture}
    exec(compile(script, str(TEMPLATE_PATH), "exec"), namespace)
    assert received["value"] == block
