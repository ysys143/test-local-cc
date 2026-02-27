#!/usr/bin/env bash
set -euo pipefail

# ── Config ──
WORK_DIR="/Users/jaesolshin/Documents/GitHub/test_local_cc"
LOG_DIR="$WORK_DIR/benchmark"
LLAMA_URL="http://localhost:11435"
LLAMA_MODEL="qwen3.5:35b"
CLEAN_HOME="/tmp/claude-bench-clean"
LLAMA_BIN="/Users/jaesolshin/go/bin/llama"
DUMP_DIR="$WORK_DIR/dumps"

restart_server() {
  echo "  [*] Restarting llama serve (KV cache flush)..."
  pkill -f "llama-server" 2>/dev/null || true
  pkill -f "llama serve" 2>/dev/null || true
  sleep 2
  $LLAMA_BIN serve "$LLAMA_MODEL" bg --log-dir "$DUMP_DIR" >/dev/null 2>&1
  # Wait for health
  for i in $(seq 1 60); do
    if curl -s --max-time 1 http://127.0.0.1:11535/health 2>/dev/null | grep -q '"ok"'; then
      echo "  [*] Server ready."
      return
    fi
    sleep 2
  done
  echo "  [*] WARNING: Server health check timeout."
}

PROMPTS=(
  "Write a python script that prints 'hello world' and save it as hello.py, then execute it with bash."
  "Write a python script that prints fibonacci sequence from 1st to 50th term and save it as fib.py, then execute it with bash."
  "Write a simple FastAPI app with GET / and GET /health endpoints, save it as app.py."
)
PROMPT_NAMES=("hello" "fibonacci" "fastapi")

# ── Functions ──
timestamp() { python3 -c "import time; print(f'{time.time():.3f}')"; }

run_test() {
  local label="$1"    # "normal" or "clean"
  local prompt="$2"
  local name="$3"
  local run_dir="$LOG_DIR/$label"

  mkdir -p "$run_dir"

  # 1) Clean .py files
  rm -f "$WORK_DIR"/*.py

  # Build env
  local -a env_args=(
    ANTHROPIC_AUTH_TOKEN="llama.cpp"
    ANTHROPIC_API_KEY=""
    ANTHROPIC_BASE_URL="$LLAMA_URL"
    ANTHROPIC_MODEL="$LLAMA_MODEL"
  )

  if [[ "$label" == "clean" ]]; then
    mkdir -p "$CLEAN_HOME"
    env_args+=(HOME="$CLEAN_HOME")
  fi

  # 2) Run prompt
  echo "  [$label/$name] Sending prompt..."
  local t_start t_end elapsed
  t_start=$(timestamp)

  env "${env_args[@]}" claude -p \
    --output-format stream-json \
    --verbose \
    --no-session-persistence \
    --permission-mode bypassPermissions \
    "$prompt" \
    > "$run_dir/${name}.jsonl" 2>"$run_dir/${name}.stderr" || true

  t_end=$(timestamp)
  elapsed=$(python3 -c "print(f'{$t_end - $t_start:.1f}')")

  # 3) Delete generated files
  rm -f "$WORK_DIR"/*.py

  # Save timing
  echo "$t_start $t_end $elapsed" > "$run_dir/${name}.time"
  echo "  [$label/$name] ${elapsed}s"

  # Show response summary from stream-json (JSONL)
  if [[ -f "$run_dir/${name}.jsonl" ]] && [[ -s "$run_dir/${name}.jsonl" ]]; then
    python3 -c "
import json
texts = []
tools = []
try:
    with open('$run_dir/${name}.jsonl') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            ev = json.loads(line)
            t = ev.get('type','')
            if t == 'assistant' and 'message' in ev:
                msg = ev['message']
                if isinstance(msg, dict):
                    for b in msg.get('content', []):
                        if b.get('type') == 'text':
                            texts.append(b['text'])
                elif isinstance(msg, str):
                    texts.append(msg)
            elif t == 'result' and 'result' in ev:
                r = ev['result']
                if isinstance(r, str):
                    texts.append(r)
            elif t == 'tool_use':
                name_ = ev.get('tool', ev.get('name', '?'))
                tools.append(name_)
except Exception as e:
    print(f'  [${label}/${name}] (parse error: {e})')
else:
    if tools:
        print(f'  [${label}/${name}] Tools: {\" → \".join(tools)}')
    result = '\n'.join(texts).strip()
    if result:
        lines = result.split('\n')
        if len(lines) > 6:
            shown = '\n'.join(lines[:3]) + '\n    ... (' + str(len(lines)-3) + ' more lines)'
        else:
            shown = result
        print(f'  [${label}/${name}] Response:')
        for l in shown.split('\n'):
            print(f'    {l}')
    elif not tools:
        print(f'  [${label}/${name}] (no response)')
" 2>/dev/null || echo "  [$label/$name] (no parseable response)"
  else
    # Check stderr for errors
    if [[ -s "$run_dir/${name}.stderr" ]]; then
      echo "  [$label/$name] ERROR: $(head -1 "$run_dir/${name}.stderr")"
    else
      echo "  [$label/$name] (no response)"
    fi
  fi
  echo ""
}

# ── Main ──
echo "=== Claude Code Benchmark: Normal vs Clean ==="
echo "  Model: $LLAMA_MODEL"
echo "  Server: $LLAMA_URL"
echo ""

rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

# Snapshot llama serve log (before)
cp /tmp/llama_serve_qwen3.5.log "$LOG_DIR/serve_before.log" 2>/dev/null || true

# Each test gets a fresh server (cold KV cache) for fair comparison
for i in "${!PROMPTS[@]}"; do
  name="${PROMPT_NAMES[$i]}"
  prompt="${PROMPTS[$i]}"

  echo "── Round $((i+1)): $name ──"

  restart_server
  run_test "normal" "$prompt" "$name"

  restart_server
  run_test "clean" "$prompt" "$name"

  echo ""
done

# Snapshot llama serve log (after)
cp /tmp/llama_serve_qwen3.5.log "$LOG_DIR/serve_after.log" 2>/dev/null || true

# ── Summary ──
echo "================================================"
echo "=== Timing Results ==="
echo "================================================"
printf "%-12s %10s %10s %10s\n" "Test" "Normal" "Clean" "Diff"
printf "%-12s %10s %10s %10s\n" "----" "------" "-----" "----"

for name in "${PROMPT_NAMES[@]}"; do
  nt=$(awk '{print $3}' "$LOG_DIR/normal/${name}.time" 2>/dev/null || echo "?")
  ct=$(awk '{print $3}' "$LOG_DIR/clean/${name}.time" 2>/dev/null || echo "?")

  diff="?"
  if [[ "$nt" != "?" && "$ct" != "?" ]]; then
    diff=$(python3 -c "print(f'{float(\"$nt\")-float(\"$ct\"):+.1f}')")
  fi

  printf "%-12s %9ss %9ss %9ss\n" "$name" "$nt" "$ct" "$diff"
done

# ── Request Size Analysis ──
echo ""
echo "=== Request Sizes (from llama serve log) ==="
python3 << 'PYEOF'
import os

before = set()
bf = os.path.join(os.environ.get("LOG_DIR", "benchmark"), "serve_before.log")
af = os.path.join(os.environ.get("LOG_DIR", "benchmark"), "serve_after.log")

try:
    with open(bf) as f:
        before = set(f.readlines())
except FileNotFoundError:
    pass

try:
    with open(af) as f:
        for line in f:
            if line not in before and "/v1/messages" in line and "req:" in line:
                print(line.rstrip())
except FileNotFoundError:
    print("(no serve log found)")
PYEOF

echo ""
echo "Full logs: $LOG_DIR/"
