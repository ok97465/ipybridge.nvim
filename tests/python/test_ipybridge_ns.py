import importlib.util
from pathlib import Path


def load_ns_module():
    module_path = Path(__file__).resolve().parents[2] / 'python' / 'ipybridge_ns.py'
    spec = importlib.util.spec_from_file_location('ipybridge_ns_test', module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_list_variables_filters_names_and_types():
    mod = load_ns_module()
    mod.set_var_filters(names=['skip_me'], types_=['Custom'], max_repr=10)
    class Custom:
        pass
    ns = {
        '_hidden': 1,
        'skip_me': 2,
        'visible': Custom(),
        'other': [1, 2, 3],
    }
    result = mod.list_variables(ns)
    assert 'skip_me' not in result
    assert 'visible' not in result
    assert 'other' in result
    assert result['other']['repr'].endswith('...') is False


def test_resolve_path_handles_index_and_attribute():
    mod = load_ns_module()
    ns = {
        'item': {'child': [10, 20, 30]},
    }
    ok, value, err = mod.resolve_path("item['child'][1]", ns)
    assert ok is True
    assert value == 20
    assert err is None


def test_preview_data_with_sequence():
    mod = load_ns_module()
    ns = {'numbers': list(range(5))}
    preview = mod.preview_data('numbers', namespace=ns, max_rows=3)
    assert preview['name'] == 'numbers'
    assert preview['kind'] == 'object'
    assert 'values1d' in preview or 'repr' in preview
