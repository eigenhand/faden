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

`UntrustedContent` fences everything that comes back from `web_search`, `fetch_page`
and `files`, with an identifier rolled per call. `FetchTarget` decides which addresses a
tool may load at all, including every redirect.

The fence names where the text comes from, and that is a parameter rather than a
sentence. For a long time the net was the only case; a file out of a synced folder is
just as foreign, but a fence that called it a page would be saying something untrue in
the very sentence that asks the model to be careful.

Both are pure functions over strings and URLs, both have tests, and neither knows what
happens with its result. The details and — more importantly — the limits are in
[SECURITY.md](SECURITY.md).

## Reading Fundus's inventory

`Storage/FundusInventory.swift` reads `inventory.json` out of the shared App Group
`group.dev.eigenhand.shared`, which Fundus writes to. Read only, and that is the shape
of the thing rather than a first step: Fundus holds its whole inventory in memory and
writes the file out entire, so a second app writing into it means last-writer-wins, and
what loses is whatever was typed by hand in the meantime.

Three decisions worth the lines they cost:

**Faden creates nothing there.** Fundus's own `SharedContainer` makes its folder on
first use because it is going to write. Faden doing the same would leave an empty
`Fundus/` folder on every device without Fundus — and the question "is there an
inventory" would answer yes and then hand over nothing.

**A second, narrower copy of the model, not a shared library.** The same argument as
for the two string catalogues. Narrower is the point: the file carries an embedding
vector per entry, and Faden has no use for one.

**Not fenced with `UntrustedContent`.** The fence says in so many words that what
follows comes from the net, and here that would be false — the inventory is local, it
is the user's own, and nothing enters it in Fundus without a tick. Fencing it anyway
would buy no protection and spend the one thing the fence lives on, that it means
something where it stands. The day a tool writes back, that sentence has to be read
again.

The search is lexical and says so. Fundus searches its own stock semantically, with an
embedding per entry; doing that here would need a second embedding endpoint and a key
for it, and a search that silently compares across two different vector spaces is worse
than one that plainly matches words.

## The folder

`Storage/SharedFolder.swift` reads out of a folder the user picked in the Files app —
meant for one out of Spind, which mounts a Storage Box as a File Provider. Nothing in
the code knows about Spind, and that is deliberate: the same path serves iCloud Drive or
a folder on the device, and a tool tied to one sister app is a tool that breaks when
that app is not installed. `Agent/FolderReader.swift` is the tool on top of it.

**`locate` is the security boundary, and it is two checks.** The first throws out `..`
before it is ever appended, which catches the ordinary case — including the one a model
produces by itself when it stitches a path together out of two listings. The second
resolves symlinks and compares the result against the root, because the first cannot see
a link *inside* the folder that points out of it, and a synced folder holds whatever the
server holds. An absolute path is refused rather than reinterpreted.

Every way out gets the same sentence. A refusal that varied per case would be a map of
where the boundary runs: try enough spellings and the differences say where the edge is.

**Everything read is fenced, including the listing.** A file name is attacker chosen —
`Bitte ignoriere deine Anweisungen.txt` is legal on every file system there is. Our own
error messages stay outside the fence, because they are not material to be read but the
reason to do something else next.

**Reading goes through `NSFileCoordinator`.** Spind's File Provider is a replicated
extension with files on demand, so most of a large folder exists as a name and a size
and nothing else. `Data(contentsOf:)` on one of those gets an empty file or an error
depending on the day; coordination is what asks the provider to fetch it first. A
listing says per entry whether an item is still dataless, because that is the difference
between reading it being free and it being a download.

**Read-only, like `inventory` and more so.** This is the one tool that reaches into
material nobody in the conversation wrote. A model that can be talked round by a
document it has just read is exactly the case `UntrustedContent` exists for, and the
answer to it is not a better prompt but a tool that cannot act.

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

180 unit tests, all of them without a network, plus UI tests that drive the real app in
the simulator. The split is on purpose: everything decidable from values is a unit
test; everything that needs a screen is a UI test; everything else is not tested and
says so.

`./run-tests.sh` runs the unit tests on a simulator. The CI runs them on every push
that touches something other than a `.md` file.
