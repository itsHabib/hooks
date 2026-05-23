BATS := $(shell command -v bats 2>/dev/null || echo .deps/bats-core/bin/bats)
BATS_CORE_REPO := https://github.com/bats-core/bats-core.git

.PHONY: test deps

deps:
	@if [ ! -x .deps/bats-core/bin/bats ]; then \
		echo "Installing bats-core into .deps/..."; \
		mkdir -p .deps; \
		git clone --depth 1 $(BATS_CORE_REPO) .deps/bats-core; \
	fi

test: deps
	@if [ -d tests ] && ls tests/*.bats >/dev/null 2>&1; then \
		find scripts -name "*.sh" -exec chmod +x {} \; ; \
		$(BATS) tests/; \
	else \
		echo "no bats tests yet — added by follow-up PRs as hooks land"; \
	fi
