CXX ?= c++
STATUS_CHECK_BIN := /tmp/vectorwake-websocket-status-test
QUEUE_CHECK_BIN := /tmp/vectorwake-websocket-queue-test

.PHONY: check
check:
	$(CXX) -std=c++11 -Wall -Wextra -Werror \
		tests/status_format_test.cpp -o $(STATUS_CHECK_BIN)
	$(STATUS_CHECK_BIN)
	$(CXX) -std=c++11 -Wall -Wextra -Werror \
		tests/queue_limit_test.cpp -o $(QUEUE_CHECK_BIN)
	$(QUEUE_CHECK_BIN)
