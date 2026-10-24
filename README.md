# 🧠 pi-brain

> give your pi a local brain

a fully local llm stack for a raspberry pi 4 (or honestly any linux box), tuned
for whatever hardware you actually have. no cloud, no api keys, no monthly bill —
just a fanless little machine quietly thinking for itself.

vibe-coded by [dude](https://github.com/dudeagent). 🤖

## two editions

| | ollama edition (`install-ollama.sh`) | **local edition (`install.sh` + `serve.sh`)** |
|---|---|---|
| runtime | ollama daemon | llama.cpp built from source, neon-tuned |
| models | pulled on demand from the registry | **every model downloaded onto the disk, once** |
| picking | install time, total ram | **run time — serve.sh checks free ram and decides which file to actually run** |
| offline after install | ❌ | ✅ pull the network cable |

## local edition (the good one)

```bash
./install.sh          # build llama.cpp + download every model in models.manifest.tsv
./serve.sh --list     # peek: which brain would run right now?
./serve.sh            # pick + serve on http://localhost:8080/v1
```

what serve.sh does, given the ram available *right now*:

1. walks `models.manifest.tsv` biggest-brain-first, skipping anything that can't fit
2. sizes the context window to whatever ram is left over after the weights
3. launches `llama-server` (openai-compatible) and prints a `models.json` snippet
   so a coding agent can point at it

knobs:

```bash
MODEL_FILE=models/Qwen_Qwen3-1.7B-Q4_K_M.gguf ./serve.sh   # force a brain
PORT=9000 ./serve.sh                                        # different port
MODELS="qwen3-0.6b" ./install.sh                            # download a subset
SKIP_BUILD=1 ./install.sh                                   # skip the llama.cpp build
```

## models on the disk (q4_k_m)

| name | size | min ram | vibe |
|---|---|---|---|
| qwen3-0.6b | ~0.5gb | ~1.8gb | the floor. runs on anything |
| qwen3-1.7b | ~1.1gb | ~3.8gb | the sweet spot for an 8gb pi 4 |
| smollm3-3b | ~1.9gb | ~5.8gb | the ceiling. tight but real |

## expectations, honestly

a pi 4 does roughly ~5-8 tokens/sec for a 1-2b model at q4, ~2-4 for a 3b. fine
for a toy local agent, chat, and tinkering — not a replacement for a cloud model
on real agentic runs.

## tests

```bash
./test.sh    # unit + stubbed end-to-end, no real installs or downloads
```

## internet-in-a-box packer (`usb-pack.py`)

pack a 32 gb usb drive with an offline internet: curated kiwix zim archives
(wikipedia, gutenberg, ifixit, stackexchange, wikivoyage...) picked from kiwix's
live catalog to fit your budget, plus the **kiwix-js browser viewer bundled on
the drive** (unpacked chrome/edge extension + firefox xpi) and a `START_HERE.html`
that walks whoever plugs it in through opening the files — no internet needed.

```bash
python3 usb_pack.py --list                        # show the plan
python3 usb_pack.py --target /media/usb --budget-gib 26
python3 usb_pack.py --viewer-only --target /media/usb   # drive already has zims? just add the viewer
```

`--viewer-only` downloads nothing — it drops the kiwix-js viewer + a
`START_HERE.html` next to zim content that's already on the stick (it reads the
existing `manifest.tsv` if present, else globs `*.zim`).

## license

mit
