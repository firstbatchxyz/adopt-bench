#!/usr/bin/env bash
# adopt-bench in-loop watchmen curator. Invoked by the orchestrator after
# day N (where N == ADOPTBENCH_WATCHMEN_AT_DAY - 1) completes.
#
# Reads session jsonls written by claude-code-cli / codex-cli-cli during
# days 1..N, runs watchmen analyze + curate, drops the resulting bundle
# at /tmp/watchmen-bundle/{CLAUDE.md,AGENTS.md}.
#
# Inputs (env):
#   ADOPTBENCH_STACK_NAME  cell identifier (used as watchmen project key)
#   SWEEP_ADAPTER        claude-code-cli | codex-cli-cli
#   OPENROUTER_API_KEY   model creds for watchmen analyze/curate
#
# Usage: watchmen-curate.sh
set -uo pipefail

if [[ -z "${ADOPTBENCH_STACK_NAME:-}" ]]; then
    echo "[watchmen-curate] ERROR: ADOPTBENCH_STACK_NAME unset"
    exit 1
fi
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[watchmen-curate] WARN: OPENROUTER_API_KEY unset; watchmen will fail"
fi

PROJECT_KEY="adoptbench-${ADOPTBENCH_STACK_NAME}-inloop"
SOURCE_REPO="/tmp/adoptbench-watchmen-src"
WATCHMEN=/app/adopt-bench/.venv/bin/watchmen

# Patch installed watchmen's curate.py to allow Stage 3 to run with 0
# candidates (when --skip-skills is set). The runner image installs
# dria-watchmen from PyPI which doesn't have this fix.
PYTHON=/app/adopt-bench/.venv/bin/python3
"$PYTHON" -c "
import watchmen.curate, inspect
p = inspect.getsourcefile(watchmen.curate)
s = open(p).read()
if 'running stage 3 (CLAUDE.md) only' not in s:
    s = s.replace(
        'if not candidates:\n            print(\"no candidates — stopping.\", flush=True)\n            return',
        'if not candidates and not args.skip_skills:\n            print(\"no candidates — stopping.\", flush=True)\n            return\n        if not candidates and args.skip_skills:\n            print(\"no candidates — running stage 3 (CLAUDE.md) only.\", flush=True)'
    )
    open(p, 'w').write(s)
    print('[watchmen-curate] patched curate.py for --skip-skills support')
" 2>&1 | tail -3

mkdir -p "$SOURCE_REPO"
echo "adoptbench in-loop watchmen for ${ADOPTBENCH_STACK_NAME}" > "$SOURCE_REPO/README.md"

# Consolidate session jsonls under a single encoded-cwd so watchmen ingest
# sees them as one project. Each per-cycle work dir wrote sessions to its
# own ~/.claude/projects/-tmp-adoptbench-<adapter>-N-<ts>/ subdirectory.
COMBO_NAME="-tmp-adoptbench-watchmen-src"
COMBO_DIR="${HOME}/.claude/projects/${COMBO_NAME}"
mkdir -p "$COMBO_DIR"

case "${SWEEP_ADAPTER:-}" in
    claude-code-cli)
        find "${HOME}/.claude/projects/" -maxdepth 1 -name '-tmp-adoptbench-claude-cli-*' -type d 2>/dev/null \
            | while read d; do
                cp "$d"/*.jsonl "$COMBO_DIR/" 2>/dev/null || true
            done
        ;;
    codex-cli-cli)
        # codex-cli sessions get archived per-cycle by the codex_cli_cli adapter
        # to ~/.codex-archive/ (rollout-*.jsonl). Watchmen's claude_code adapter
        # expects user/assistant message events with specific fields; codex's
        # rollout format is different. Translate inline: each rollout's
        # "response_item" entries with role:user/assistant become claude-shape
        # entries. Best-effort; watchmen's claude_code adapter tolerates
        # missing optional fields.
        ARCHIVE="${HOME}/.codex-archive"
        if [[ -d "$ARCHIVE" ]]; then
            for src in "$ARCHIVE"/rollout-*.jsonl; do
                [[ -f "$src" ]] || continue
                base=$(basename "$src")
                # Pass agent-controlled filenames via argv into a quoted heredoc;
                # never interpolate them into Python source (code-injection risk).
                python3 - "$src" "$COMBO_DIR/$base" <<'PY' 2>/dev/null || true
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
base = os.path.basename(src)
out_lines = []
sid = base[:-len('.jsonl')].split('rollout-')[1] if 'rollout-' in base else 'codex-session'
with open(src) as f:
    for line in f:
        line=line.strip()
        if not line: continue
        try: e=json.loads(line)
        except: continue
        if e.get('type')!='response_item': continue
        payload = e.get('payload') or {}
        role = payload.get('role')
        content = payload.get('content')
        if role not in ('user','assistant') or content is None: continue
        # codex content is a list of {type:'input_text'|'output_text', text}; convert to plain string
        text=''
        if isinstance(content, list):
            for blk in content:
                if isinstance(blk, dict) and 'text' in blk: text += blk['text']
                elif isinstance(blk, str): text += blk
        elif isinstance(content, str): text=content
        ts = e.get('timestamp') or e.get('time') or ''
        out_lines.append(json.dumps({'type':role, 'timestamp':ts, 'sessionId':sid, 'message':{'role':role, 'content':text}}))
with open(dst,'w') as f:
    for l in out_lines: f.write(l+'\n')
PY
            done
        fi
        ;;
    *)
        echo "[watchmen-curate] adapter ${SWEEP_ADAPTER} unsupported; bailing"
        exit 0
        ;;
esac

N_SESSIONS=$(ls "$COMBO_DIR"/*.jsonl 2>/dev/null | wc -l)
echo "[watchmen-curate] consolidated $N_SESSIONS session jsonl(s) into $COMBO_DIR"
if [[ "$N_SESSIONS" -lt 3 ]]; then
    echo "[watchmen-curate] too few sessions ($N_SESSIONS); bailing"
    exit 0
fi

# Track + analyze + curate
"$WATCHMEN" ingest 2>&1 | tail -3
"$WATCHMEN" track "$PROJECT_KEY" --repo "$SOURCE_REPO" 2>&1 | tail -1 || true

# Override source_repo in state.db to match the decoded encoded-cwd path
DECODED_PATH="/tmp/adoptbench/watchmen/src"
mkdir -p "$DECODED_PATH"
python3 - "$PROJECT_KEY" <<'PY' 2>&1 | tail -3
import sqlite3, os, sys
project_key = sys.argv[1]
db = os.path.expanduser('~/.watchmen/state.db')
conn = sqlite3.connect(db)
conn.execute('UPDATE projects SET source_repo=? WHERE project_key=?', (
    '/tmp/adoptbench-watchmen-src', project_key))
conn.commit()
conn.close()
PY

"$WATCHMEN" analyze "$PROJECT_KEY" --full --model deepseek/deepseek-v4-flash 2>&1 | tail -3
"$WATCHMEN" curate "$PROJECT_KEY" --model deepseek/deepseek-v4-flash 2>&1 | tail -5

# Fallback: if full curate produced no CLAUDE.md (e.g. 0 skill candidates from
# the candidate-finder when corpus is sparse), force --regen-claude to at least
# produce a workspace brief from the analyst's thesis. This stage uses our
# control-flow fix that allows stage 3 to run with empty candidates.
BUNDLE_SRC="${HOME}/.watchmen/bundles/${PROJECT_KEY}"
if [[ ! -f "$BUNDLE_SRC/CLAUDE.md" ]]; then
    echo "[watchmen-curate] no CLAUDE.md from full curate — forcing --regen-claude"
    "$WATCHMEN" curate "$PROJECT_KEY" --regen-claude --model deepseek/deepseek-v4-flash 2>&1 | tail -5
fi

# Copy bundle to where adapter expects it
mkdir -p /tmp/watchmen-bundle
if [[ -f "$BUNDLE_SRC/CLAUDE.md" ]]; then
    cp "$BUNDLE_SRC/CLAUDE.md" /tmp/watchmen-bundle/
    echo "[watchmen-curate] bundle CLAUDE.md = $(wc -c < /tmp/watchmen-bundle/CLAUDE.md) bytes"
fi
if [[ -f "$BUNDLE_SRC/AGENTS.md" ]]; then
    cp "$BUNDLE_SRC/AGENTS.md" /tmp/watchmen-bundle/
    echo "[watchmen-curate] bundle AGENTS.md = $(wc -c < /tmp/watchmen-bundle/AGENTS.md) bytes"
fi
echo "[watchmen-curate] done"
