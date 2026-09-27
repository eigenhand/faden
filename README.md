# Faden

*English · [Deutsch](README.de.md)*

[![Tests](https://github.com/eigenhand/faden/actions/workflows/tests.yml/badge.svg)](https://github.com/eigenhand/faden/actions/workflows/tests.yml)

An AI chat client for the iPhone that is just the interface. The model, the endpoint,
the API key and the search provider come from you. No servers in between, no accounts,
no telemetry — the app talks only to the addresses you enter.

What the app protects, and what it doesn't: [SECURITY.md](SECURITY.md). How it is
built: [ARCHITECTURE.md](ARCHITECTURE.md). An assistant with tools reads untrusted text
and can act — [“Deliberate compromises”](SECURITY.md#deliberate-compromises) says where
the safeguards end.

## Status and requirements

- **Status:** version 1.0, a spare-time project in active development. Not on the App
  Store yet — build it from source.
- **Device:** iPhone with iOS 17 or later; Apple's on-device model needs iOS 26 and
  Apple Intelligence.
- **Build tools:** Xcode (tested with 26.6, as in CI) and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen). No other dependencies.
- **Languages:** English and German.

## What you need to use it

At least one chat model:

- **An API key** for the Anthropic API or any OpenAI-compatible service. Presets for
  OpenAI, Anthropic, OpenRouter, Groq, Cerebras, Mistral, DeepSeek, xAI, Together,
  Fireworks and TensorX; any other endpoint can be entered by hand.
- **Your own server** speaking the OpenAI format, such as Ollama, vLLM or LM Studio.
  A key is optional. On your home network, plain `http://` works with an IP address or
  a `.local` name; anything else needs `https://`.
- **Apple's on-device model** — no endpoint, no key, nothing leaves the phone, but no
  tools, no images and a small context window.

Optional: a search provider, your own speech endpoints, and embeddings for the memory —
from an OpenAI-compatible embedding endpoint of yours (the default, more accurate) or
computed on the iPhone with Apple's built-in embedding model, with no endpoint at all.

## What leaves your phone

Only what goes to the services you entered:

- **Model endpoint:** the conversation, images, tool results — including inventory
  entries and folder contents the model looks up.
- **Search provider:** the query. **Web pages:** a plain page request.
- **Embedding endpoint:** text that becomes a memory — only if you choose it over
  on-device embeddings.
- **Speech endpoints:** your recording and the text to read aloud, if you set them up.

History, settings, memories and the document index stay on the device; API keys stay
in the keychain. Full table: [SECURITY.md](SECURITY.md#what-leaves-the-device).

## Features

- **Your own model.** Anthropic and OpenAI-compatible APIs, with streaming, tool calls
  and reasoning.
- **Your own web search.** Ready-made recipes for Brave, Tavily, Serper, SearXNG and
  Exa; for any other provider, one of your models writes a parser once.
- **Agentic.** The assistant searches when needed, loads web pages and remembers what
  matters.
- **Images.** Whether a model can see is measured by the connection test, not guessed.
- **Models and limits.** The model list comes from the endpoint; context and answer
  length follow the provider or your sliders.
- **Speaking and listening.** Dictate through Apple or your own Whisper endpoint;
  answers are read aloud by your speech service or the iPhone's voice.
- **Memory.** A knowledge graph from your conversations, ported from
  [cognee](https://github.com/topoteretes/cognee), stored on the device, visible and
  deletable entry by entry. Embeddings on the iPhone or from your endpoint.
- **Your voice.** Set form of address, length and tone.
- **Answers say who wrote them** when more than one model is involved.
- **Revising.** Copy, regenerate, shorter, longer; quote by long-press; edit a question
  and ask again.
- **Accessible.** Text scales to the largest size; VoiceOver announces what is
  happening, not every token.
- **Long conversations.** A hairline shows how full the context is; at 75% (adjustable)
  older history is summarized in the background.

**Optional integrations**, read-only and offered only once connected:

- **[Fundus](https://github.com/eigenhand/fundus)**, an inventory app for the iPhone:
  the assistant can look up where something is and how much is left.
- **A folder in the Files app** — iCloud Drive, or for example a Hetzner Storage Box
  mounted by [Spind](https://github.com/eigenhand/spind). The assistant lists, finds
  and reads files and searches PDFs (scanned ones too), Office, iWork, OpenDocument,
  EPUB, RTF, HTML, text and source files, citing document and page.

## Building

```bash
brew install xcodegen
xcodegen generate
open Faden.xcodeproj
```

Run the `Faden` scheme on a simulator as is. For a device, change these to your own
values first:

- `DEVELOPMENT_TEAM` in `project.yml`
- the bundle IDs `dev.eigenhand.perbu` (and `.tests`, `.uitests`) in `project.yml`
- the app group `group.dev.eigenhand.shared` and the keychain groups in
  `Faden/Faden.entitlements` — without the app group, the Fundus integration is
  simply not offered

Then run from Xcode (Debug, automatic signing). The Release configuration signs with
the maintainer's distribution profile; the release process is described in
[ARCHITECTURE.md](ARCHITECTURE.md#maintainer-notes-releasing).

Unit tests:

```bash
xcodebuild test -project Faden.xcodeproj -scheme Faden \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:FadenTests CODE_SIGNING_ALLOWED=NO
```

## License

Apache-2.0. See [LICENSE](LICENSE). Copyright 2026 Christoph Lindl-Guk.
