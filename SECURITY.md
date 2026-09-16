# Security

*English · [Deutsch](SECURITY.de.md)*

## Reporting a vulnerability

Please report security problems **not** as a public issue but by e-mail to
<christoph.lindl-guk@pm.me>. I answer as fast as I can — this is a spare-time project
with no promised response times.

## What leaves the device

Faden brings no infrastructure with it. There is no server of mine, no telemetry and no
account. What goes out goes to endpoints the user entered:

| Where | What | When |
| --- | --- | --- |
| Model endpoint | The whole conversation, images, tool results | On every turn |
| Search provider | The search query | When the model searches |
| Arbitrary web pages | Nothing but a page request | When the model loads a page |
| Embedding endpoint | Text that becomes memories | When the memory is on |

Everything else — history, settings, memories — lies in Application Support on the
device.

## Keys

API keys live in the **device's keychain**, never in the settings and never in a file
that travels when something is shared. A provider entry only refers to the keychain
entry.

Until September 2026 the TestFlight builds carried a key in the binary so that testers
could start right away. That was a deliberate trade-off and is no longer one: a key in
a shipped binary is readable by anyone who has the binary. Since then the app brings no
provider with it. A versioned `pre-commit` hook fires when something that looks like a
key finds its way into a commit.

## The architecture this is about

An assistant with tools reads foreign text and can act. To a language model both are
first of all the same thing: text. Most of what follows comes out of that.

**Foreign content is fenced.** What `web_search` and `fetch_page` return stands between
marks carrying an identifier rolled per call, and the system instruction says what
holds inside them: material, not instruction. Without the roll it would be decoration —
a prepared page would write the closing mark and then its instructions, which would
then appear to stand outside. Anything in the text that itself looks like a mark is
removed beforehand.

The occasion is concrete: Faden has a tool called `remember` whose notes survive the
compaction of the context verbatim. Without fencing, a page could dictate a permanent
entry in the user's memory.

**Tools load public pages only.** The model picks the address for `fetch_page`,
according to what stood in a search result — that is input from outside. Both the
address **and every redirect** are checked: kept out are the device itself, the private
ranges, link-local including `169.254.169.254`, carrier NAT, multicast, reserved space,
the names `localhost`, `.local`, `.lan`, `.internal`, `.home`, and everything but http
and https. Without the redirect check this would be a doorman who only looks at the
first guest.

**Shared conversations are defused.** A `.faden` file becomes your own prehistory when
you take it over, and from then on it travels with every turn. Removed in the process:
the “summary” flag (the system instruction declares summaries authoritative — a foreign
file may not decide that about its own content), reasoning (invisible, ineffective if
genuine, and the most persuasive voice in the history if forged) and incomplete tool
steps. Plus upper bounds on file size and message count. What was removed is said.

## Deliberate compromises

These points are not oversights but trade-offs.

**Your own endpoint is trusted.** Whoever enters an address and a key is saying: my
whole history may go there. Faden does not check what happens to the data there, and
cannot.

**The search provider may sit in your own network.** For `fetch_page` that is blocked,
for search it is not — a self-hosted SearXNG in the home network is a legitimate setup
and one of the shipped suggestions. The difference is who picks the address: for search
the user, for `fetch_page` the model.

**A name that points at a private address gets through.** What is checked is the
written address. A public-looking name that an attacker has resolve to `192.168.…`
bypasses the check. Only a resolver of our own would help — one that checks and then
uses exactly the address it checked — because otherwise a gap remains between the check
and the connection. That would be a network layer of its own.

**The fence is a request, not a barrier.** Whether the model holds to it cannot be
enforced by any line of code. Against a model that lets itself be talked round, the
only thing that helps in the end is giving it no dangerous tools — and the most
dangerous ones Faden does not have: it writes no files, sends nothing and buys nothing.
The worst a successful attack achieves is a wrong entry in the memory or a wrong
answer.

**No protection against a malicious model.** The endpoint receives the whole history
and answers freely. Whoever enters an endpoint they do not trust has a different problem
than this app.

## What is tested

The measures above have tests, and the tests check the mechanical part: that the
boundary holds, that a forged mark neither opens nor closes it, that
`192.168.example.com` gets through as an ordinary domain and `::ffff:192.168.0.1` does
not, that a complete tool pair survives the import unharmed. They run on every push.

What they do not check stands above under “Deliberate compromises”.
