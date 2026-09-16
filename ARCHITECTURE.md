# Architecture

*English · [Deutsch](ARCHITECTURE.de.md)*

What this document is for: the README says what Faden does, `SECURITY.md` says what it
protects. This one says how it is put together and which decisions you have to know
before you change something.

## The shape

Twelve folders, no external dependencies, about 15,000 lines. The dependency graph is
acyclic, and the direction is always the same — downwards:

```
UI  ────────────────►  App  ────►  Agent  ────►  Providers
                        │            │     └───►  Search
                        │            └────────►  Memory  ───►  Models
                        ├────────►  Context                     ▲
                        ├────────►  Storage  ───────────────────┘
                        ├────────►  Speech
                        └────────►  Media
```

`Models` is at the bottom and depends on nothing but Foundation. `UI` is at the top and
knows only `App` plus the value types it displays. Nothing points back upwards.

There is exactly one exception, and it is a comment: `Models/Chat.swift` mentions
`AppModel` in a doc comment to explain why a default value has to stay German. No code
follows it.

| Folder | What lives there |
| --- | --- |
| `Models/` | Value types: message, block, conversation, settings. `Codable`, testable, no I/O |
| `Providers/` | The two wire formats, the SSE reader, the model catalogue, the capability probe |
| `Agent/` | The turn loop, the four tools, the fencing of foreign text, the address check |
| `Search/` | Recipe format, local execution, ready-made providers, auto-configuration |
| `Memory/` | The knowledge graph after cognee: identity, extraction, embedding, triple search |
| `Context/` | Token estimation, compaction, titling |
| `Speech/` | Dictation, recording, your own STT/TTS endpoints |
| `Media/` | Image preparation and the vision check |
| `Storage/` | Keychain, file persistence, the import guard |
| `App/` | `AppModel`, the per-conversation state, the app entry, the App Intents |
| `UI/` | 25 SwiftUI views, 6,100 lines — the largest folder by far, and rightly so |
| `Design/` | One file: the palette, the type scale, the building blocks |

## The seam that matters: `TurnEvent`

The core of the app is one loop and one enum.

`AgentRunner.run` drives a turn to completion: it streams from the provider, collects
text, reasoning and tool calls, runs the tools, appends their results to the history and
starts over — at most eight times. It knows nothing about SwiftUI, nothing about
persistence and nothing about the screen. Its only contact with the rest of the app is a
callback:

```swift
enum TurnEvent {
    case thinking(String), text(String)
    case toolStarted(id:name:summary:), toolFinished(id:ok:summary:)
    case usage(input:output:)
    case learnedLimits(context:output:)
    case grewOutputBudget(Int)
    case restarted(reason: String)
    case finished, failed(String)
}
```

`AppModel` receives these events and translates them into state. That is the whole
contract. It has two consequences worth knowing:

**The loop is testable without a network.** Everything the loop decides — whether a
turn ran out of room, whether it may start over, which model an image goes to, whether
an error is worth retrying — sits in `static func`s on `AgentRunner` that take values
and return values. They have unit tests. What cannot be tested that way is the
streaming itself, and that is deliberate: it belongs to the provider.

**Learning goes upwards, never sideways.** When a provider names its limits in a
refusal, or the answer budget grows because a turn was cut off, `AgentRunner` does not
write to the settings. It sends an event. `AppModel` decides whether that is worth
persisting. The loop has no permission to change the user's configuration.

## Where state lives

Three places, and the separation is an invariant, not a convenience.

**On disk** — `Store` writes `settings.json` and `conversations.json` into Application
Support. Everything in them is a `Codable` value type, and every decoder tolerates
missing fields (`decodeIfPresent(…) ?? default`): a settings file from an older version
must keep opening. Keys never appear here. They live in the keychain and are referenced
by a UUID that each provider entry carries.

**In `AppModel`** — one `@Observable` class, the facade the whole UI reads. It holds the
conversations, the settings and the model list.

**In `TurnState`, one per conversation** — the running answer, streaming text, tool
list, attached images, context usage, error message, compaction run. `AppModel.turn`
resolves to the state of the conversation currently open:

```swift
private var turnStates: [UUID: TurnState] = [:]
var turn: TurnState { turnStates[currentID] ?? … }
```

That is the reason a turn survives switching chats. A turn belongs to the conversation
it began in and writes its result back there, even if you have long since been reading
somewhere else. The alternative — one global “is streaming” — is what most chat clients
do, and it loses the answer the moment someone taps away.

## The provider layer

`LLMProvider` is a protocol with one method: stream a request, yield `StreamEvent`s.
Two implementations speak Anthropic Messages and OpenAI-compatible; a third wraps
Apple's on-device model. `ProviderFactory.make(for:)` picks by the wire format stored in
the config.

Everything that differs between providers stays inside them: how tool calls arrive, what
reasoning is called, which field carries the stop reason. What comes out is the same
enum in all three cases. That is why `AgentRunner` has no idea which provider it is
talking to.

The SSE reader is its own file and its own problem. Server-sent events arrive in
fragments that do not respect line boundaries, and half the providers deviate from the
specification in their own way.

## Capabilities are measured, not assumed

No table of which model can do what. Three states per capability — yes, no, **unknown** —
and the app finds out itself:

- **Vision**: the connection test sends a tiny two-colour image and asks what is on it.
  A rejection means no, an answer naming both colours means yes.
- **Tools and reasoning**: a probe request with one echo tool.
- **Limits**: whatever the provider publishes in its model list. Whatever it does not
  publish, the app reads out of a refusal that names a number. It never sends an absurd
  request to find out — that was removed on purpose.
- **Answer length**: grows out of use. If a turn is cut off before any text arrives, the
  budget doubles and the turn starts over, up to three times. Whoever sets the number by
  hand switches that off.

The reason for all of it is the same: a silence in a model list is not a “no”. A model
the app has never heard of must be usable, and one that quietly lost a capability must
not break the app.

## The security boundary

Two files draw it, and both sit in `Agent/`.

`UntrustedContent` fences everything that comes back from `web_search` and
`fetch_page`, with an identifier rolled per call. `FetchTarget` decides which addresses
a tool may load at all, including every redirect.

Both are pure functions over strings and URLs, both have tests, and neither knows what
happens with its result. The details and — more importantly — the limits are in
[SECURITY.md](SECURITY.md).

## What is deliberately not abstracted

**No repository layer, no view models.** `AppModel` is the view model, for all views.
The app has one screen with sheets over it; a second layer of indirection would add
files, not clarity.

**No dependency injection container.** Two singletons (`Store.shared`,
`MemoryStore.shared`), one namespace of static functions (`Keychain`), and the rest is
passed in as parameters. Everything
tested is a `static func` or a value type, so nothing has to be swapped out for testing.

**Two localisation catalogues, not one shared framework.** Faden and Fundus carry the
same fencing code twice. That is duplication, and it says so in the source: sharing it
would be worth a common library, and until that exists, duplicated code is better than
one unprotected app.

**`Memory/` is a port, not an inspiration.** It reproduces cognee's identity function
bit for bit, so that the same person in two conversations gets the same node ID. Where
it deviates — no graph database, no vector store, no server — that is written down with
the reason.

## Testing

96 unit tests, all of them without a network, plus UI tests that drive the real app in
the simulator. The split is on purpose: everything decidable from values is a unit
test; everything that needs a screen is a UI test; everything else is not tested and
says so.

`./run-tests.sh` runs the unit tests on a simulator. The CI runs them on every push
that touches something other than a `.md` file.
