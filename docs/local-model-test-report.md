# Local Model Test Report — Claude Code + Ollama

- Date: 2026-02-27
- Claude Code version: v2.1.56
- Environment: macOS, ~/Documents/GitHub/test_local_cc
- Task: Simple "Hello World" Python script creation and execution

---

## Test Results Summary

| # | Model | Tool Call Attempted | Result | Failure Type |
|---|-------|-------------------|--------|-------------|
| 1 | qwen3.5:35b | Yes | Failed | Path hallucination |
| 2 | qwen3-coder:30b-a3b-q4_K_M | No | Failed | No tool use |
| 3 | qwen2.5-coder:32b | No | Failed | No tool use |
| 4 | GLM-4.7-Flash | No | Failed | No tool use (user-reported) |

**All 4 models failed.** None successfully completed a basic file write + execute task.

---

## Detailed Failure Analysis

### Test 1: qwen3.5:35b

**Log:** `conversation-2026-02-27-050643.txt`

**Behavior:**
- Tool calls were attempted, but with hallucinated file paths
- Used literal `/path/to/hello.py` instead of the actual working directory
- Claimed success despite `ENOENT` errors
- Repeated the same mistake on a second attempt (FastAPI file)

**Failure pattern:**
```
Write(/path/to/hello.py)
  Error: ENOENT: no such file or directory, mkdir '/path/to'

Model response: "The Python code has been written and saved"  ← false
```

**Root cause:** Model treated placeholder path `/path/to/` as a real path. Could not resolve the working directory from the system prompt context. Hallucinated success by ignoring tool error output.

---

### Test 2: qwen3-coder:30b-a3b-q4_K_M

**Log:** `2026-02-27-053657-hello-world.txt`

**Behavior:**
- No tool calls at all
- Responded conversationally: "I can help you create a Python script! Let me know what you'd like to do"
- Even after rephrasing the request, gave the same non-action response

**Failure pattern:**
```
User: hello world 파이썬 스크립트 만들고 실행
Model: "I can help you create a Python script! Let me know what you'd like to do"

User: make python 'hello world' script file
Model: "I can help you create a Python script! ...if you want a script that prints 'Hello, World!' to the console, I can create that."
```

**Root cause:** Model did not understand it had tools available. MoE architecture with only 3B active parameters likely insufficient to process Claude Code's large system prompt containing tool definitions. Q4 quantization may have further degraded instruction-following for structured tool call generation.

---

### Test 3: qwen2.5-coder:32b

**Log:** `2026-02-27-054652-write-a-hello-world-python-script.txt`

**Behavior:**
- No tool calls at all
- Output code as plain text in the chat instead of writing to a file
- Even when explicitly told "파일을 쓰라고" (write a file), still just output text

**Failure pattern:**
```
User: write a hello world python script
Model: # Hello World Script
       print("Hello, World!")        ← plain text, not a file write

User: 파일을 쓰라고
Model: # Hello World Python Script
       print("Hello, World!")        ← still plain text
```

**Root cause:** Dense 32B model could generate code but did not invoke the Write tool. Behaved as a standard chat completion model, not as an agentic tool-calling model. The Anthropic Messages API tool calling format was not properly produced.

---

### Test 4: GLM-4.7-Flash

**Log:** Not captured (user-reported failure)

**Behavior:** Failed similarly — no successful tool use.

---

## Common Factors Across All Failures

1. **Ollama version:** Stable Ollama has a known issue where streaming tool calls are broken. Pre-release 0.14.3-rc1+ is required for proper tool call streaming, which Claude Code depends on.

2. **Context window:** Ollama defaults to 4K context. Claude Code's system prompt (tool definitions, rules, context) can exceed this, causing tool definitions to be truncated. Minimum 16K–32K context is required (`OLLAMA_NUM_CTX=32768`).

3. **API format mismatch:** Claude Code expects Anthropic Messages API tool call format. Ollama's compatibility layer translates this, but the translation may be incomplete in stable versions, causing models to not recognize they should produce tool calls.

4. **Stop hooks:** Every session showed "Stop hook prevented continuation," which cut off any potential self-correction. However, even without this, none of the models showed intent to use tools correctly.

---

## Conclusion

The failures are primarily an **infrastructure compatibility issue** (Ollama stable ↔ Claude Code tool calling), not a model capability issue. The models were never properly receiving or understanding tool call instructions due to:

1. Ollama stable's broken streaming tool call support
2. Potentially truncated system prompts from insufficient context windows
3. Incomplete Anthropic API compatibility layer in Ollama

**Recommended next steps:**
- Upgrade Ollama to pre-release 0.14.3-rc1+
- Set `OLLAMA_NUM_CTX=32768` or higher
- Re-test with qwen2.5-coder:32b or GLM-4.7-Flash after the above fixes
- If local remains unstable, consider OpenRouter as an API proxy to cloud models
