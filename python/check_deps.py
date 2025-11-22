# Simple dependency checker for ipybridge.
# Given a list of module names as command-line arguments, this script tries to
# import each one and prints the names of any that fail to stdout.

import sys
import importlib

if __name__ == "__main__":
    missing = []
    for mod in sys.argv[1:]:
        try:
            importlib.import_module(mod)
        except ImportError:
            missing.append(mod)

    if missing:
        # Print one per line so it's easy to parse from Lua.
        print("\n".join(missing))
