BATS := $(shell command -v bats 2>/dev/null || echo .deps/bats-core/bin/bats)
BATS_CORE_REPO := https://github.com/bats-core/bats-core.git

.PHONY: test deps smoke check

deps:
	@if [ ! -x .deps/bats-core/bin/bats ]; then \
		echo "Installing bats-core into .deps/..."; \
		mkdir -p .deps; \
		git clone --depth 1 $(BATS_CORE_REPO) .deps/bats-core; \
	fi

test:
	@if [ -d tests ] && ls tests/*.bats >/dev/null 2>&1; then \
		if [ ! -x .deps/bats-core/bin/bats ]; then \
			echo "Installing bats-core into .deps/..."; \
			mkdir -p .deps; \
			git clone --depth 1 $(BATS_CORE_REPO) .deps/bats-core; \
		fi; \
		find scripts -name "*.sh" -exec chmod +x {} \; ; \
		$(BATS) tests/; \
	else \
		echo "no bats tests yet — added by follow-up PRs as hooks land"; \
	fi

# Live-corpus end-to-end smoke. Fires each hook against a real dossier
# binary against a tmp corpus. Catches mock-reality drift that the bats
# suite cannot. Requires DOSSIER_BIN, or pers/dossier built as a sibling
# at ../dossier/target/{release,debug}/dossier(.exe).
smoke:
	@find scripts -name "*.sh" -exec chmod +x {} \;
	@chmod +x tests/smoke.sh
	@tests/smoke.sh

# CI gate: bats (fast, mock-based) + smoke (slow, live-corpus).
check: test smoke
