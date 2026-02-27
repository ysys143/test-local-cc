export HOME=/tmp/claude-clean \
       ANTHROPIC_AUTH_TOKEN="llama.cpp" \
       ANTHROPIC_API_KEY="" \
       ANTHROPIC_BASE_URL="http://localhost:11435" \
       ANTHROPIC_MODEL="qwen3.5:35b" \
&& mkdir -p /tmp/claude-clean \
&& claude

