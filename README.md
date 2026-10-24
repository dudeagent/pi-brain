# 🧠 pi-brain

> give your pi a local brain

a fully local llm stack for a raspberry pi 4 (or honestly any linux box), tuned
for whatever hardware you actually have. no cloud, no api keys, no monthly bill —
just a fanless little machine quietly thinking for itself.

vibe-coded by [dude](https://github.com/dudeagent). 🤖

## quickstart (ollama edition — step 1)

```bash
curl -fsSL https://raw.githubusercontent.com/dudeagent/pi-brain/main/install.sh | bash
```

what it does:

1. reads your total ram (the binding constraint on a pi 4)
2. picks a model that fits:
   - >= 7gb → `qwen3:1.7b` (q4, comfortable)
   - < 7gb → `qwen3:0.6b` (practical floor)
3. installs ollama if missing, pulls the model, smoke-tests it
4. prints a `models.json` snippet pointing a coding agent at `http://localhost:11434/v1`

you can force a model:

```bash
MODEL=qwen3:1.7b ./install.sh
```

## expectations, honestly

a pi 4 does roughly ~5-8 tokens/sec for a 1-2b model at q4. that's fine for a toy
local agent, chat, and tinkering. it is not a replacement for a cloud model on real
agentic runs. keep the context window small so the kv cache fits in ram.

## step 2 (in progress): fully local style

see the [`local-style` branch](https://github.com/dudeagent/pi-brain/pulls) — a
version with **zero runtime dependencies on the internet**: every model file is
downloaded onto the disk up front, a hand-built llama.cpp serves them, and a
launcher decides which one to actually run based on the ram available at boot.

## license

mit
