CXX ?= c++
CHECK_BIN := /tmp/vectorwake-websocket-status-test

.PHONY: check
check:
	$(CXX) -std=c++11 -Wall -Wextra -Werror \
		tests/status_format_test.cpp -o $(CHECK_BIN)
	$(CHECK_BIN)
