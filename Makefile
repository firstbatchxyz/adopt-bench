# adopt-bench — common dev tasks
.PHONY: demos test canary

# Render the README CLI demo GIFs from the VHS tapes in docs/demos/.
# Requires: vhs (https://github.com/charmbracelet/vhs) and the adoptbench CLI on
# PATH (`pip install -e .`).  Run from the repo root.
demos:
	@command -v vhs >/dev/null || { echo "vhs not found — install with: brew install vhs  (see github.com/charmbracelet/vhs)"; exit 1; }
	@command -v adoptbench >/dev/null || { echo "adoptbench not found — run: pip install -e ."; exit 1; }
	@for t in docs/demos/*.tape; do echo "→ rendering $$t"; vhs "$$t"; done

test:
	python -m pytest -q

canary:
	python tools/check_canary.py
