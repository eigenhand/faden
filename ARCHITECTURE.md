# Architecture

*English · [Deutsch](ARCHITECTURE.de.md)*

What this document is for: the README says what Faden does, `SECURITY.md` says what it
protects. This one says how it is put together and which decisions you have to know
before you change something.

## The shape

Thirteen folders, no external dependencies, about 18,500 lines of Swift. The dependency graph is
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
| `Agent/` | The turn loop, the tools, the fencing of untrusted text, the address check |
| `Search/` | Recipe format, local execution, ready-made providers, auto-configuration |
| `Memory/` | The knowledge graph after cognee: identity, extraction, embedding, triple search |
| `Context/` | Token estimation, compaction, titling |
| `Speech/` | Dictation, recording, your own STT/TTS endpoints, speech output |
| `Media/` | Image preparation and the vision check |
| `Storage/` | Keychain, file persistence, the import guard, read access to Fundus's inventory and to the shared folder |
| `Documents/` | Parsing documents with Apple frameworks, and the SQLite index they are searched in |
| `App/` | `AppModel`, the per-conversation state, the app entry, the App Intents |
| `UI/` | 25 SwiftUI views, about 6,400 lines — the largest folder by far, and rightly so |
| `Design/` | One file: the palette, the type scale, the building blocks — the tokens from eigenhand.dev |

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
do, and it loses the answer the moment someone taps away. Only the memory is
deliberately shared between conversations.

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

**Everything read is fenced, including the listing.** A file name is attacker-controlled —
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

## Reading the documents

`Documents/` turns a folder of files into something a question can be asked of. Four
pieces, each with a reason to be separate.

**`DocumentParser` dispatches to whichever Apple framework reads the format.** PDFKit
for PDF; `NSAttributedString` for RTF, RTFD and HTML; Vision for images and for PDFs
with no text layer; `XMLParser` for the Office and OpenDocument parts. The set is
decided by what iOS actually ships: on macOS `NSAttributedString` reads `.docx` and
`.odt` directly, on iOS it does not, and that single gap is why `ZipArchive` exists.

**`ZipArchive` is a read-only ZIP reader, about a hundred lines.** iOS ships none, and
`.docx`, `.xlsx`, `.pptx`, `.pages`, `.numbers`, `.key`, `.epub` and `.odt` are all ZIP
containers — without it the parser reads a PDF and a text file and nothing anybody
writes a document in. Only the container is ours: the decompression is Apple's
`COMPRESSION_ZLIB` (raw DEFLATE is what ZIP stores), and what comes out goes back to
PDFKit, `XMLParser` or `NSAttributedString`. iWork files are read through the PDF
preview they carry, because their real format is an undocumented protobuf archive that
no iOS API opens.

**`ParsedDocument` is the machine-readable form: metadata plus addressable blocks.**
Blocks rather than one string is the whole point — a hit is only useful if it can be
pointed at, so the text carries its position from the parse into the database, the
search result and the answer. The boundaries come from the format (a page, a sheet, a
slide) rather than from a guess at paragraphs.

**`DocumentIndex` is SQLite with FTS5**, which is part of the system SQLite on iOS, so
full-text search costs a link flag and no dependency. The rest of the app stores JSON
files; this does not, because answering "where does it say anything about the boiler"
over JSON means loading every document into memory on every question.

Freshness is the modification date **and** the size. The date alone is what everybody
uses and it is not enough: a file synced back from a server can arrive carrying a date
it already had. What neither catches — an edit that keeps the byte count — would need a
hash of the whole file, which for a synced folder means downloading everything to check
whether anything changed.

**`DocumentLibrary` keeps the three jobs apart**, and that is what keeps a turn fast.
Reading one named document parses on demand and caches. Searching contents answers from
the index and never parses — a question is not the moment to read four hundred files,
so the answer says how many documents it looked through and what to do when the miss
means "not read yet". Filling the index is a third thing, and it happens when the model
runs a content search — not on a background timer, and not from a button.

That placement is the decision the feature turns on. A timer would fetch files over the
network that nobody asked about. A button in the settings would make a search answer
silently from whatever somebody last remembered to press. On the search it is the model
asking, on behalf of a question that was just typed, and the user watches it happen: the
tool reports progress through `TurnEvent.toolProgress`, which is why that case exists
and why no other tool uses it. The read runs against a wall clock, and when the clock
wins the answer says so — a search over half a folder that claims to be a search over
the folder is the one outcome nobody can tell from the real thing.

Two details that are easy to get wrong and expensive to find. Apple's HTML reader is
built on WebKit and puts itself on the main queue whatever thread called it, so parsing
HTML off the main actor deadlocks — on a file, which means the app hangs the day
somebody puts a web page in their folder and never before. And parsing goes through
`NSFileCoordinator` into a temporary copy, because a File Provider file that is not
downloaded yet gives `Data(contentsOf:)` an empty file or an error depending on the day.

## Web search and reading pages

**Search recipes.** Brave, Tavily, Serper, SearXNG and Exa come as ready-made recipes
(`Search/BuiltinRecipes.swift`). For everything else there is automatic setup: if the
test fails — or the results look wrong — Faden probes the endpoint until a valid answer
comes back with HTTP 200, shows its structure to one of the user's models and asks it to
write a parser for it. The parser is pure configuration (`SearchRecipe`), is checked
locally against that same answer before it is saved, and afterwards runs entirely on the
device — searching needs no model.

**`fetch_page` runs no JavaScript**, so what is left afterwards decides everything.
Preference goes to the content region the document itself marks, plus structured data
(JSON-LD), which even client-rendered pages usually still carry; navigation bars,
consent banners and unresolved templates are dropped line by line. If nothing readable
remains, the tool says so plainly instead of returning menu debris as content — the
model then switches source at once instead of losing two rounds.

## Memory: a port of cognee

Faden builds a knowledge graph out of the conversations — not a list of notes. `Memory/`
is a port of [cognee](https://github.com/topoteretes/cognee) (Apache-2.0), not an
imitation:

- **Ingestion** like `cognify`: text → chunks → the model extracts
  `KnowledgeGraph{nodes, edges}` from them, with cognee's own extraction prompt
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

**Resilient to rate limits.** Embedding endpoints are often rate-limited, and that is
the normal case, not the exception. Ingestion therefore never blocks on it: extracted
facts are stored even without a vector — the model call that found them is paid for and
should not go to waste. A catch-up run fetches the missing vectors later, every minute
and automatically on the next start. Until then those facts are merely not findable by
similarity. Permanent errors (wrong model, missing permission) are told apart from this
and not retried endlessly. Embeddings can also be computed on the device
(`LocalEmbedder`, Apple's `NLContextualEmbedding`); the measured price in retrieval
quality is written down in that file.

**Left out**, because it is server operation and contributes nothing on a phone:
Neo4j/Kuzu and LanceDB (cognee's own default path is `brute_force_triplet_search`
anyway), FastAPI, user management, Alembic migrations, ontology anchoring, the eval
framework. The graph is one file on the device, visible in the chat and deletable entry
by entry.

## Prompt caching and the clock

The assistant knows the date and time — but they do not sit in the system prompt; they
sit at the end of the last user message. Prompt caching matches an exact prefix, and
the order is tools → system → messages: a clock in the system prompt changes the first
bytes of every request, which makes nothing behind it reusable. The same holds for
recalled memories: they change from turn to turn, so in the system prompt they would break
the shared prefix early. Both therefore sit behind the cache
point, on content that is new anyway.

The persona (“the voice”) is the opposite case: it changes only when the user changes
it, so it sits in the stable part of the instructions and costs nothing per question.

## Interface decisions

**The voice is yours.** In an app without a provider there is no brand setting the
tone, so it is set rather than prescribed: form of address, length, tone, plus a
free-text field. The settings screen shows verbatim what the model is told, and lets
you hear a sample before the voice lands in a real conversation.

**Answers say who wrote them.** As soon as more than one model is set up, the model name
stands on the answer — with several models, an answer without a sender is an answer you
cannot judge. With only one model the note is dropped, because it would be noise.

**Overlays by purpose.** Settings are a longer task and take the whole screen. History
and memory are short lookups and sit as half-height sheets over the chat, which stays
visible behind them — you can see what you are stepping away from. Sheets are not
stacked, [as NN/g advises](https://www.nngroup.com/articles/bottom-sheet/): provider
setup and the model list are steps *inside* the settings, not a second layer above them.

**Revising rather than retyping.** NN/g describes two patterns in how people use
generative AI ([“Accordion Editing and Apple Picking”](https://www.nngroup.com/articles/accordion-editing-apple-picking/),
2023): they have answers shortened or expanded repeatedly, and they refer back to single
passages of an earlier answer — for which they otherwise have to scroll up, select and
copy. Faden has actions right at the answer for that: copy, fetch again, shorter,
longer. A long press on a paragraph quotes exactly that one into the input. A
misunderstood question can be edited and asked again instead of being reformulated
further down — which would leave it standing in the history, where it keeps influencing
the answers that follow.

**Waiting is explained.** The indicator stays silent while an answer is coming along
normally, and says what is being waited for only after a few seconds. Errors come with a
button to try again — except for those that waiting does not fix, such as a wrong key.

**Readable at any text size.** Every font size follows the system setting. The content
scales through to the largest accessibility size; the header, the input and the context
bar are capped, because symbols would otherwise overlap there. The actions under an
answer drop their labels and become tappable-size symbols as soon as the room runs out.

**VoiceOver gets sentences, not characters.** While an answer streams it is hidden from
the screen reader — announcing every token individually is the usual way to make a chat
interface unusable. What is announced instead is what is happening (“searching the
web”, “writing the answer”); the finished message then stands in the history as one
element that is read out with speaker, tools and text.

**Context and compaction.** A hairline at the bottom edge shows how much of the window
is taken; the estimate corrects itself as soon as the provider reports real usage. At
75% (adjustable) Faden summarises the older history in the background — organised by
task, state, decisions and open points, with numbers, names and sources carried over
verbatim. The last turns stay untouched, `remember` notes survive in full. The cut
always lies before a fresh turn, so that no tool result is separated from its call.

**Titles.** Conversations are first named after their first sentence and are then
renamed by the model once there is enough content — and again when the history has
roughly doubled and the subject has probably moved on.

## Naming: why `perbu`

Two things are still called `perbu` and `PerBu` respectively, both on purpose. The
**bundle ID** `dev.eigenhand.perbu` is the app's identity in App Store Connect and on
every device that carries it: a new one would be a new app, with a new TestFlight,
testers to invite again and a second icon instead of an update. The **data folder** in
Application Support carries the same name; a different one would orphan every saved
conversation and the knowledge graph. Everything else — project, targets, source
folder, types — is called Faden.

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

234 unit tests, all of them without a network, plus UI tests that drive the real app in
the simulator. The split is on purpose: everything decidable from values is a unit
test; everything that needs a screen is a UI test; everything else is not tested and
says so.

The unit tests run on a simulator with `xcodebuild test … -only-testing:FadenTests`
(the full command is in the README). The CI runs them on every push that touches
something other than a `.md` file, together with `check-localizations.py`. The UI tests
need a seeded simulator (`seed-fixture.sh`, `seed-memory.sh`, `seed-broken.sh`) and
skip themselves without it; they are run by hand before a release.

## Maintainer notes: releasing

`./release.sh` archives the app, uploads it to TestFlight and assigns the build to the
internal tester group (`assign-build.sh`). It is written for the maintainer's account;
a fork needs its own values throughout. Needed once beforehand:

- the bundle ID `dev.eigenhand.perbu` registered and the app record created in App Store
  Connect;
- an App Store Connect API key with the “App Manager” role, its private key at
  `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`;
- `.release.env` (copied from `.release.env.example`) with `ASC_ISSUER_ID` and
  `ASC_KEY_ID` (App Store Connect › Users and Access › Integrations);
- a distribution provisioning profile named `Faden App Store - (API)`, made by hand in
  the developer portal, because the Release configuration signs manually with it (the
  reason is in `project.yml`). Replacing the signing certificate means making the
  profile again;
- the app ID in `assign-build.sh` is the maintainer's app record.

App Store Connect rejects builds from an Xcode beta; if the active Xcode is a beta and
`/Applications/Xcode.app` exists, the script builds with the latter.
