# Faden

*English · [Deutsch](README.de.md)*

[![Tests](https://github.com/eigenhand/faden/actions/workflows/tests.yml/badge.svg)](https://github.com/eigenhand/faden/actions/workflows/tests.yml)

An AI chat client for the iPhone that is just the interface. The model, the endpoint,
the API key and the search provider come from you. No servers in between, no accounts,
no telemetry — the app talks only to the addresses you enter.

Visual design follows [eigenhand.dev](https://eigenhand.dev). What the app protects,
and what it explicitly does not: [SECURITY.md](SECURITY.md). How it is put together:
[ARCHITECTURE.md](ARCHITECTURE.md). An assistant with tools reads untrusted text and
can act — [“Deliberate compromises”](SECURITY.md#deliberate-compromises) says where
the safeguards end.

## Status and requirements

- **Status:** version 1.0, a spare-time project in active development. Not on the App
  Store yet — build it from source.
- **Device:** iPhone with iOS 17 or later. Apple's on-device model additionally needs
  iOS 26 and Apple Intelligence.
- **Build tools:** Xcode (tested with Xcode 26.6, the version CI uses) and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen). No other dependencies.
- **Languages:** German and English.

## What you need to use it

At least one chat model, from one of these:

- **An API key** for the Anthropic API or any OpenAI-compatible service. Presets are
  included for OpenAI, Anthropic, OpenRouter, Groq, Cerebras, Mistral, DeepSeek, xAI,
  Together, Fireworks and TensorX; any other endpoint can be entered by hand.
- **A server of your own** that speaks the OpenAI format, such as Ollama, vLLM or LM
  Studio. The key is optional; the server has to be reachable from the phone.
- **Apple's on-device model** — no endpoint, no key, nothing leaves the phone. The
  price: no tools, no images, a small context window.

Optional: a search provider (see Features), an embedding endpoint for the memory
(or on-device embeddings), and speech endpoints of your own.

## What leaves your phone

Only what goes to the services you entered:

- **Model endpoint:** the conversation, attached images, tool results — including
  inventory entries and folder contents when the model looks them up.
- **Search provider:** the search query. **Web pages:** a plain page request.
- **Embedding endpoint:** text that becomes a memory, if you use one.
- **Speech endpoints:** your recording and the text to read aloud, if you set them up.
  Apple's dictation runs on the device where the device supports it.

History, settings, memories and the document index stay in the app's storage on the
device; API keys stay in the keychain. The full table is in
[SECURITY.md](SECURITY.md#what-leaves-the-device).

## Features

- **Your own model.** Anthropic Messages (`/v1/messages`) and OpenAI-compatible
  (`/v1/chat/completions`), with streaming, tool calls and reasoning
  (`reasoning_content` or `thinking`).
- **Your own web search.** Ready-made recipes for Brave, Tavily, Serper, SearXNG and
  Exa. For any other provider Faden probes the endpoint, shows the answer's structure
  to one of your models and asks it to write a parser for it. The parser is plain
  configuration, checked locally and then run on the device — no model needed to search.
- **Agentic.** The assistant searches when a question calls for it, runs several
  targeted searches, loads pages (`fetch_page`, no JavaScript, main content and
  JSON-LD only) and keeps what matters with `remember`. It knows the date and time zone.
- **Images.** Whether a model can see is measured by the connection test, not guessed.
  Photos are scaled down before sending.
- **Models and limits.** The model list comes from the endpoint; limits are taken from
  what the provider publishes or names in a refusal. Context window and answer length
  are set with sliders, or the answer budget grows with use.
- **Speaking and listening.** Hold to dictate, through Apple's speech recognition or
  your own Whisper endpoint. Answers are read aloud through your own speech service or
  the iPhone's built-in voice, which also steps in when your service fails.
- **Memory.** A knowledge graph built from your conversations — a port of
  [cognee](https://github.com/topoteretes/cognee) (Apache-2.0), stored on the device
  and visible and deletable entry by entry.
- **The voice is yours.** Form of address, length, tone and free text; the settings
  show verbatim what the model is told.
- **Answers say who wrote them** as soon as more than one model is set up.
- **Revising rather than retyping.** Copy, regenerate, shorter, longer; quote a
  paragraph by long-pressing it; edit a question and ask it again.
- **Waiting is explained.** The indicator says what it is waiting for after a few
  seconds; errors that retrying can fix come with a retry button.
- **Overlays by purpose.** Settings take the full screen; history and memory are
  half-height sheets over the chat.
- **Accessible.** Text scales up to the largest accessibility size; VoiceOver announces
  what is happening, not every streamed token.
- **Long conversations.** A hairline shows how full the context is; at 75% (adjustable)
  older history is summarised in the background. Titles are written by the model.

**Optional integrations**, offered only once connected in the settings, and read-only:

- **[Fundus](https://github.com/eigenhand/fundus)**, an inventory app for the iPhone:
  the assistant can look up where something is and how much of it there is.
- **A folder in the Files app** — for example one from
  [Spind](https://github.com/eigenhand/spind), which mounts a Hetzner Storage Box as
  a cloud drive, or iCloud Drive. The assistant can list, find and read files, and
  search the contents of PDFs (scanned ones too), Office, iWork, OpenDocument, EPUB,
  RTF, HTML, text and source files, citing document and page.

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

Permissive, not copyleft: Faden runs on your phone and talks to endpoints you own —
there is nothing here anyone could turn into a closed hosted service. Apache-2.0
rather than MIT for its explicit patent grant.
