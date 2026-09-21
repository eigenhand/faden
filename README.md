# Faden

*English · [Deutsch](README.de.md)*

[![Tests](https://github.com/eigenhand/faden/actions/workflows/tests.yml/badge.svg)](https://github.com/eigenhand/faden/actions/workflows/tests.yml)

A chat client for the iPhone that brings nothing but the interface. The model, the
endpoint, the API key and the search provider come from you. No servers in between,
no accounts, no telemetry — the app speaks only to the addresses you enter.

Design after [eigenhand.dev](https://eigenhand.dev).

What the app protects and what it expressly does not: [SECURITY.md](SECURITY.md).
How it is put together: [ARCHITECTURE.md](ARCHITECTURE.md). An
assistant with tools reads foreign text and can act — the section “Deliberate
compromises” says where the measures stop.

## What is in it

**Your own model.** Two wire formats: Anthropic Messages (`/v1/messages`) and
OpenAI-compatible (`/v1/chat/completions`) — the latter covers Groq, Together,
OpenRouter, Mistral, Ollama, vLLM, LM Studio and most proxies. Streaming, tool calls
and reasoning (`reasoning_content` or `thinking`) included.

**Your own web search.** Ready-made recipes for Brave, Tavily, Serper, SearXNG and
Exa. For everything else there is automatic setup: if the test fails — or the results
look wrong — Faden probes the endpoint itself until a valid answer comes back with
HTTP 200, shows its structure to one of your models and has a parser written from it.
The parser is pure configuration (`SearchRecipe`), is checked locally against that
same answer before it is saved, and runs entirely on the device afterwards — searching
no longer needs a model.

**Agentic.** The assistant searches on its own when a question calls for it, runs
several targeted searches rather than one broad one, loads pages (`fetch_page`) and
holds on to what matters with `remember`. It knows the device's date and time zone.

**Reading pages.** `fetch_page` runs no JavaScript — so what is left afterwards
decides everything. Preference goes to the content region the document itself marks,
plus structured data (JSON-LD), which even client-rendered pages usually still carry;
navigation bars, consent banners and unresolved templates are dropped line by line. If
nothing readable remains, the tool says so plainly instead of returning menu debris as
content — the model then switches source at once instead of losing two rounds.

**Images.** If the model can read them, a plus appears in the input field. Whether it
can is something the connection test finds out for itself: it sends a tiny two-colour
picture and asks what is on it. A rejected upload means no, an answer that names both
colours means yes — nothing is guessed. Photos are scaled down before sending so a
snapshot does not eat half the context.

**Models and limits.** The editor loads the model list straight from the endpoint,
with whatever the provider reveals about context, output length and price. If it says
nothing, the app reads the limits out of a refusal that names them — and otherwise
remembers which prompt size demonstrably got through. You set the context window and
the maximum answer length with logarithmic sliders. As long as you have not set the
answer length yourself, it grows out of use: if an answer is cut off before any text
arrives, Faden doubles the budget and asks again.

**Speaking and listening.** The input field carries a microphone button: hold, speak,
let go. The text comes either from Apple's speech recognition — on the device where
possible, and then nothing leaves the iPhone — or from your own Whisper endpoint
(`/v1/audio/transcriptions`, tested with `faster-whisper`). Faden reads answers aloud
on request, through a speech service of your own (`/v1/audio/speech`) or the voice
built into the iPhone. If your own service fails, the Apple voice steps in rather than
letting the answer fall silent.

**Memory (after cognee).** Faden builds a knowledge graph out of your conversations —
not a list of notes. The system is a port of [cognee](https://github.com/topoteretes/cognee)
(Apache-2.0), not an imitation:

- **Ingestion** like `cognify`: text → chunks → the model pulls
  `KnowledgeGraph{nodes, edges}` out of them, with cognee's own extraction prompt
  (translated) — basic types rather than “mathematician”, readable IDs rather than
  numbers, references resolved to one name.
- **Identity** like `DataPoint.id_for`: `uuid5(NAMESPACE_OID, "type:value")`. The same
  person in two conversations gets the same ID and merges into one node instead of
  being created a second time. The Swift implementation produces bit-for-bit the same
  IDs as cognee's Python.
- **Retrieval** like `GraphCompletionRetriever`: vector search across nodes *and*
  edges, the hits as seed points, from there `neighborhoodDepth` steps through the
  graph, triples scored by their strongest part minus `triplet_distance_penalty` per
  step.
- **Bi-temporal**: a superseded fact is closed (`validTo`), not deleted.

**The inventory from Fundus.** Connect Fundus in the settings and the assistant can
look into your stock: where a thing is, how much of it there is, what stands in a
given room or shelf. It reads `inventory.json` out of the App Group the two apps
share — read only, so entering and changing still happens in Fundus, and it says so
rather than promising otherwise. A missing quantity is passed on as uncounted rather
than as zero, and a number a model read off a label keeps the caveat that it was read.
Until it is connected the tool is not offered at all, and without Fundus on the device
there is nothing to connect.

**Files out of Spind.** Point the app at a folder in the Files app — one out of Spind,
or iCloud Drive, or the device — and the assistant can look in it: list what is there,
find a file by name across every subfolder, and read text files, source files and PDFs.
Read only: it cannot write, rename or delete, and it says so instead of promising
otherwise. Paths that lead out of the folder are refused, and everything it reads is
fenced as foreign material — a file name is attacker chosen too. A listing says per
entry whether an item is still waiting to be downloaded, because that decides whether
reading it is free.

**Resilient.** Embedding endpoints are often rate-limited, and that is the normal case,
not the exception. Ingestion therefore never blocks on it: extracted facts are stored
even without a vector — the model call that found them is paid for and should not go
to waste. A catch-up run fetches the missing vectors later, every minute and
automatically on the next start. Until then those facts are merely not findable by
similarity. Permanent errors (wrong model, missing permission) are told apart from
this and not retried endlessly.

Left out because it is server operation and contributes nothing on a phone: Neo4j/Kuzu
and LanceDB (cognee's own default path is `brute_force_triplet_search` anyway),
FastAPI, user management, Alembic migrations, ontology anchoring, the eval framework.
The graph is one file on the device, visible in the chat and deletable entry by entry.

**Titles.** Conversations are first named after their first sentence and are then
renamed by the model once there is enough content — and again when the history has
doubled and the subject has probably moved on.

**Time without breaking the cache.** The assistant knows the date and time — but they
do not sit in the system prompt; they sit at the end of the last user message. Prompt
caching matches an exact prefix, and the order is tools → system → messages: a clock in
the system prompt changes the first bytes of every request, which makes nothing behind
it reusable. The same held for the recalled memories — measured, the shared prefix
broke after 1,965 of 2,521 characters because of them. Both now sit behind the cache
point, on content that is new anyway.

**Conversations are separate.** Every chat has its own runtime state — the running
answer, streaming text, tool list, attached images, context usage, error message,
compaction run. A turn belongs to the conversation it began in and writes its result
back there, even if another chat was opened meanwhile. Only the memory is deliberately
shared.

**The voice is yours.** In an app without a provider there is no foreign brand setting
the tone. Research on brand identity in dialogue systems finds that engagement rises
with the fit between person and voice — so it is set, not prescribed: form of address,
length, tone, plus a free-text field. The settings screen shows verbatim what the model
is told, and lets you hear a sample before the voice lands in a real conversation.
Because it changes only when you change it, it sits in the stable part of the
instructions and costs nothing per question.

**Answers say who wrote them.** As soon as more than one model is set up, the model
name stands on the answer. The same research finds that visual polish *without*
transparency lowers the willingness to keep using a system — and with several models,
an answer without a sender is exactly that. With only one model the note is dropped,
because it would be noise.

**Overlays by purpose.** Settings are a longer task and take the whole screen. History
and memory are short lookups and sit as half-height sheets over the chat, which stays
visible behind them — you can see what you are stepping away from. Stacked sheets,
which NN/g expressly advises against, are gone: provider setup and the model list are
steps *inside* the settings, not a second layer above them.

**Revising rather than retyping.** Research into how people actually use generative AI
(NN/g) shows two patterns: they have answers shortened or expanded repeatedly
(“accordion editing”), and they refer to single passages of an earlier answer (“apple
picking”) — for which they otherwise have to scroll up, select and copy. Faden has
actions right at the answer for that: copy, fetch again, shorter, longer. A long press
on a paragraph quotes exactly that one into the input. A misunderstood question can be
edited and asked again instead of being reformulated further down — which would leave
it standing in the history, where it keeps influencing the answers that follow.

**Waiting is explained.** Studies on response delays find that explaining the wait
raises trust and perceived transparency more than shortening it does. The indicator
stays silent while an answer is coming along normally, and says what is being waited
for only after a few seconds. Errors come with a button to try again — except for
those that waiting does not fix, such as a wrong key.

**Readable at any text size.** Every font size grows with the system setting — before,
112 places were wired to fixed point sizes, so a larger system font simply had no
effect in Faden. The content scales through to the largest accessibility step; the
header, the input and the context bar are capped, because symbols would otherwise
overlap there. The actions under an answer drop their labels and stand as symbols at
tap size as soon as the room runs out.

**VoiceOver gets sentences, not characters.** While an answer streams it is hidden from
the screen reader — announcing every token individually is the usual way to make a chat
interface unusable. What is announced instead is what is happening (“searching the
web”, “writing the answer”); the finished message then stands in the history as one
element that is read out with speaker, tools and text.

**Context display.** A hairline at the bottom edge shows continuously how much of the
window is taken. The estimate corrects itself as soon as the provider reports real
usage figures.

**Automatic compaction.** From 75 % (adjustable) Faden summarises the older history in
the background — organised by task, state, decisions and open points, with numbers,
names and sources carried over verbatim. The last turns stay untouched, `remember`
notes survive in full. The cut always lies before a fresh turn, so that no tool result
is separated from its call.

## Building

```bash
xcodegen generate
open Faden.xcodeproj
```

Needs Xcode 16+ and targets iOS 17. No external dependencies.

Two things are still called `perbu` and `PerBu` respectively, and both on purpose. The
**bundle ID** `dev.eigenhand.perbu` is the app's identity in App Store Connect and on
every device that carries it: a new one would be a new app, with a new TestFlight,
testers to invite again and a second icon instead of an update. The **data folder** in
Application Support carries the same name; a different one would orphan every saved
conversation and the knowledge graph. Everything else — project, targets, source
folder, types — is called Faden.

## Getting it onto a device

`./release.sh` archives and uploads to TestFlight. Needed once beforehand: register the
bundle ID `dev.eigenhand.perbu`, create the app record in App Store Connect, and set
`ASC_ISSUER_ID` (App Store Connect › Users and Access › Integrations).

## Where things are

| Folder | Contents |
|---|---|
| `Design/` | Colours, typography and building blocks — the tokens from eigenhand.dev |
| `Models/` | Messages, blocks, settings, a dynamic JSON type |
| `Providers/` | The two wire formats and the SSE reader |
| `Search/` | Recipe format, local execution, ready-made providers, auto-configuration |
| `Agent/` | The tools and the loop that runs them |
| `Context/` | Token estimation and compaction |
| `Media/` | Image preparation and the vision check |
| `Speech/` | Dictation, recording, your own STT/TTS endpoints, speech output |
| `Memory/` | The knowledge graph after cognee: identity, extraction, embedding, triple search |
| `Storage/` | Keychain, file persistence, read access to Fundus's inventory and to the shared folder |
| `UI/` | Chat, context bar, settings, setup assistant |

Keys live in the device's keychain, everything else as JSON in Application Support.

## Licence

Apache-2.0. See [LICENSE](LICENSE). Copyright 2026 Christoph Lindl-Guk.

Permissive and not copyleft: Faden runs on a phone and speaks to endpoints that belong
to the user — there is nothing here that anyone could take over as a service and close.
Apache-2.0 rather than MIT because of the express patent licence.
