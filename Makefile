.PHONY: test test.lua test.py

LUA ?= lua
PYTEST ?= pytest

TEST_LUA := $(LUA) tests/run.lua
TEST_PY := $(PYTEST) tests/python

test: test.lua test.py

# Run Lua unit tests (dispatch, term_ipy, ...)
test.lua:
	@echo "==> Running Lua tests"
	@$(TEST_LUA)

# Run Python unit tests (kernel client)
test.py:
	@echo "==> Running Python tests"
	@$(TEST_PY)
