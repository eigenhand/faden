# Architektur

*[English](ARCHITECTURE.md) · Deutsch*

Wofür dieses Dokument da ist: Die README sagt, was Faden tut, `SECURITY.de.md` sagt,
was es schützt. Dieses hier sagt, wie es gebaut ist und welche Entscheidungen man
kennen muss, bevor man etwas ändert.

## Die Form

Dreizehn Ordner, keine externen Abhängigkeiten, etwa 18 500 Zeilen Swift. Der
Abhängigkeitsgraph ist zyklenfrei, und die Richtung ist immer dieselbe — nach unten:

```
UI  ────────────────►  App  ────►  Agent  ────►  Providers
                        │            │     └───►  Search
                        │            └────────►  Memory  ───►  Models
                        ├────────►  Context                     ▲
                        ├────────►  Storage  ───────────────────┘
                        ├────────►  Speech
                        └────────►  Media
```

`Models` liegt unten und hängt von nichts ab außer Foundation. `UI` liegt oben und
kennt nur `App` und die Werttypen, die es anzeigt. Nichts zeigt zurück nach oben.

Es gibt genau eine Ausnahme, und sie ist ein Kommentar: `Models/Chat.swift` erwähnt
`AppModel` in einer Dokumentationszeile, um zu erklären, warum eine Vorgabe deutsch
bleiben muss. Kein Code folgt ihr.

| Ordner | Was darin liegt |
| --- | --- |
| `Models/` | Werttypen: Nachricht, Block, Unterhaltung, Einstellungen. `Codable`, prüfbar, ohne Ein- und Ausgabe |
| `Providers/` | Die beiden Wire-Formate, der SSE-Leser, der Modellkatalog, die Fähigkeitsprobe |
| `Agent/` | Die Zugschleife, die Werkzeuge, die Einfassung fremden Textes, die Adressprüfung |
| `Search/` | Rezept-Format, lokale Ausführung, fertige Anbieter, Autokonfiguration |
| `Memory/` | Der Wissensgraph nach cognee: Identität, Extraktion, Einbettung, Tripel-Suche |
| `Context/` | Token-Schätzung, Verdichten, Titel |
| `Speech/` | Diktat, Aufnahme, eigene STT-/TTS-Endpoints, Sprachausgabe |
| `Media/` | Bildaufbereitung und die Vision-Prüfung |
| `Storage/` | Schlüsselbund, Dateipersistenz, die Import-Entschärfung, Lesezugriff auf Fundus' Bestand und den freigegebenen Ordner |
| `Documents/` | Dokumente mit Apple-Frameworks parsen und der SQLite-Index, in dem sie durchsucht werden |
| `App/` | `AppModel`, der Zustand je Unterhaltung, der Einstieg, die App Intents |
| `UI/` | 25 SwiftUI-Ansichten, etwa 6 400 Zeilen — der mit Abstand größte Ordner, und zu Recht |
| `Design/` | Eine Datei: Palette, Schriftskala, Bausteine — die Tokens von eigenhand.dev |

## Die Naht, auf die es ankommt: `TurnEvent`

Der Kern der App ist eine Schleife und ein Enum.

`AgentRunner.run` führt einen Zug zu Ende: Es streamt vom Anbieter, sammelt Text,
Gedankengang und Werkzeugaufrufe, führt die Werkzeuge aus, hängt deren Ergebnisse an
den Verlauf und fängt von vorn an — höchstens achtmal. Es weiß nichts von SwiftUI,
nichts von Persistenz und nichts vom Bildschirm. Seine einzige Verbindung zum Rest der
App ist ein Rückruf:

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

`AppModel` nimmt diese Ereignisse entgegen und übersetzt sie in Zustand. Das ist der
ganze Vertrag. Er hat zwei Folgen, die man kennen sollte:

**Die Schleife ist ohne Netz prüfbar.** Alles, was sie entscheidet — ob einem Zug der
Vorrat ausgegangen ist, ob er noch einmal beginnen darf, an welches Modell ein Bild
geht, ob ein Fehler einen zweiten Versuch wert ist —, steht in `static func`s auf
`AgentRunner`, die Werte nehmen und Werte zurückgeben. Dafür gibt es Unittests. Was so
nicht prüfbar ist, ist das Streamen selbst, und das mit Absicht: Es gehört dem Anbieter.

**Gelerntes geht nach oben, nie zur Seite.** Nennt ein Anbieter in einer Absage seine
Grenzen, oder wächst die Antwortlänge, weil ein Zug abgeschnitten wurde, schreibt
`AgentRunner` nicht in die Einstellungen. Es schickt ein Ereignis. `AppModel`
entscheidet, ob das bleiben soll. Die Schleife hat keine Erlaubnis, die Konfiguration
des Nutzers zu ändern.

## Wo der Zustand liegt

Drei Orte, und die Trennung ist eine Zusicherung, keine Bequemlichkeit.

**Auf der Platte** — `Store` schreibt `settings.json` und `conversations.json` nach
Application Support. Alles darin ist ein `Codable`-Werttyp, und jeder Decoder verträgt
fehlende Felder (`decodeIfPresent(…) ?? Vorgabe`): Eine Einstellungsdatei aus einer
älteren Fassung muss sich weiter öffnen lassen. Schlüssel stehen hier nie. Sie liegen
im Schlüsselbund und werden über eine UUID angesprochen, die jeder Anbietereintrag
trägt.

**In `AppModel`** — eine `@Observable`-Klasse, die Fassade, aus der die ganze
Oberfläche liest. Sie hält die Unterhaltungen, die Einstellungen und die Modellliste.

**In `TurnState`, einer je Unterhaltung** — laufende Antwort, Streaming-Text,
Werkzeugliste, angehängte Bilder, Kontextfüllstand, Fehlermeldung, Verdichtungslauf.
`AppModel.turn` löst auf den Zustand der gerade geöffneten Unterhaltung auf:

```swift
private var turnStates: [UUID: TurnState] = [:]
var turn: TurnState { turnStates[currentID] ?? … }
```

Das ist der Grund, warum ein Zug einen Wechsel des Chats übersteht. Ein Zug gehört der
Unterhaltung, in der er begann, und schreibt sein Ergebnis dorthin zurück, auch wenn
man längst woanders liest. Die Alternative — ein globales „es streamt gerade“ — ist
das, was die meisten Chat-Clients tun, und sie verliert die Antwort in dem Moment, in
dem jemand wegtippt. Nur das Gedächtnis teilen sich die Unterhaltungen mit Absicht.

## Die Anbieterschicht

`LLMProvider` ist ein Protokoll mit einer Methode: eine Anfrage streamen und
`StreamEvent`s liefern. Zwei Implementierungen sprechen Anthropic Messages und
OpenAI-kompatibel, eine dritte umschließt Apples Modell auf dem Gerät.
`ProviderFactory.make(for:)` wählt nach dem Wire-Format, das in der Konfiguration
steht.

Alles, was sich zwischen Anbietern unterscheidet, bleibt in ihnen: wie Werkzeugaufrufe
ankommen, wie der Gedankengang heißt, in welchem Feld der Abbruchgrund steht. Heraus
kommt in allen drei Fällen dasselbe Enum. Deshalb weiß `AgentRunner` nicht, mit wem es
spricht.

Der SSE-Leser ist eine eigene Datei und ein eigenes Problem. Server-Sent Events kommen
in Bruchstücken an, die sich nicht an Zeilengrenzen halten, und die Hälfte der Anbieter
weicht auf eigene Art von der Spezifikation ab.

## Fähigkeiten werden gemessen, nicht angenommen

Keine Tabelle, welches Modell was kann. Drei Zustände je Fähigkeit — ja, nein,
**unbekannt** — und die App findet es selbst heraus:

- **Vision**: Der Verbindungstest schickt ein winziges Zweifarbenbild und fragt, was
  darauf ist. Eine Ablehnung heißt nein, eine Antwort, die beide Farben nennt, heißt ja.
- **Werkzeuge und Gedankengang**: eine Probeanfrage mit einem Echo-Werkzeug.
- **Grenzen**: was der Anbieter in seiner Modellliste veröffentlicht. Was er nicht
  veröffentlicht, liest die App aus einer Absage heraus, die eine Zahl nennt. Sie
  schickt nie eine absurde Anfrage, um es zu erfahren — das ist mit Absicht entfernt.
- **Antwortlänge**: wächst aus der Nutzung. Wird ein Zug abgeschnitten, bevor Text kam,
  verdoppelt sich der Vorrat und der Zug beginnt neu, bis zu dreimal. Wer die Zahl von
  Hand setzt, schaltet das ab.

Der Grund ist überall derselbe: Ein Schweigen in einer Modellliste ist kein „nein“. Ein
Modell, von dem die App nie gehört hat, muss benutzbar sein, und eines, das still eine
Fähigkeit verloren hat, darf die App nicht brechen.

## Die Sicherheitsgrenze

Zwei Dateien ziehen sie, und beide liegen in `Agent/`.

`UntrustedContent` fasst alles ein, was aus `web_search`, `fetch_page` und `files`
zurückkommt, mit einer je Aufruf gewürfelten Kennung. `FetchTarget` entscheidet, welche
Adressen ein Werkzeug überhaupt laden darf, einschließlich jeder Weiterleitung.

Die Einfassung nennt, woher der Text stammt, und das ist ein Parameter statt eines
Satzes. Lange war das Netz der einzige Fall; eine Datei aus einem synchronisierten
Ordner ist genauso fremd — aber eine Einfassung, die sie zur Seite erklärte, sagte
ausgerechnet in dem Satz etwas Unwahres, der zur Vorsicht auffordert.

Beide sind reine Funktionen über Zeichenketten und Adressen, beide haben Tests, und
keine weiß, was mit ihrem Ergebnis geschieht. Die Einzelheiten und — wichtiger — die
Grenzen stehen in [SECURITY.de.md](SECURITY.de.md).

## Fundus' Bestand lesen

`Storage/FundusInventory.swift` liest `inventory.json` aus der gemeinsamen App Group
`group.dev.eigenhand.shared`, in die Fundus schreibt. Nur lesen, und das ist die Form
der Sache und kein erster Schritt: Fundus hält seinen ganzen Bestand im Speicher und
schreibt die Datei vollständig heraus. Eine zweite App, die hineinschreibt, heißt
Last-writer-wins — und was verliert, ist das von Hand Eingetragene.

Drei Entscheidungen, die ihre Zeilen wert sind:

**Faden legt dort nichts an.** Fundus' eigener `SharedContainer` erzeugt seinen Ordner
beim ersten Zugriff, weil er schreiben wird. Täte Faden dasselbe, stünde auf jedem
Gerät ohne Fundus ein leerer `Fundus/`-Ordner — und die Frage „gibt es einen Bestand“
hieße ja und lieferte dann nichts.

**Eine zweite, schmalere Kopie des Modells statt einer gemeinsamen Bibliothek.**
Dasselbe Argument wie bei den zwei Stringkatalogen. Schmaler ist der Punkt: Die Datei
trägt je Eintrag einen Einbettungsvektor, und Faden kann damit nichts anfangen.

**Nicht mit `UntrustedContent` eingefasst.** Die Einfassung sagt wörtlich, dass der
folgende Text aus dem Netz stammt, und das wäre hier falsch — der Bestand ist lokal, er
gehört dem Nutzer, und in Fundus landet nichts darin ohne Häkchen. Ihn trotzdem
einzufassen brächte keinen Schutz und verbrauchte das Einzige, wovon die Einfassung
lebt: dass sie etwas bedeutet, wo sie steht. An dem Tag, an dem ein Werkzeug
zurückschreibt, ist dieser Satz neu zu lesen.

Die Suche vergleicht Wörter und sagt das. Fundus durchsucht seinen Bestand sinngemäß,
mit einer Einbettung je Eintrag; dasselbe hier bräuchte einen zweiten
Einbettungs-Endpoint samt Schlüssel — und eine Suche, die stillschweigend zwischen zwei
Vektorräumen vergleicht, ist schlechter als eine, die schlicht Wörter trifft.

## Der Ordner

`Storage/SharedFolder.swift` liest aus einem Ordner, den der Nutzer in der Dateien-App
ausgewählt hat — gedacht für einen aus Spind, das eine Storage Box als File Provider
einhängt. Nichts im Code weiß von Spind, und das mit Absicht: derselbe Weg bedient
iCloud Drive oder einen Ordner auf dem Gerät, und ein Werkzeug, das an einer
Schwester-App hängt, ist eines, das ohne sie zerbricht. `Agent/FolderReader.swift` ist
das Werkzeug darauf.

**`locate` ist die Sicherheitsgrenze, und zwar in zwei Prüfungen.** Die erste wirft
`..` hinaus, bevor es überhaupt angehängt wird — das deckt den Normalfall ab,
einschließlich dessen, den ein Modell selbst erzeugt, wenn es einen Pfad aus zwei
Auflistungen zusammensetzt. Die zweite löst Symlinks auf und vergleicht das Ergebnis mit
der Wurzel, denn die erste sieht keinen Link *im* Ordner, der hinausführt — und ein
synchronisierter Ordner enthält, was der Server enthält. Ein absoluter Pfad wird
abgewiesen und nicht umgedeutet.

Jeder Weg hinaus bekommt denselben Satz. Eine Abweisung, die je Fall anders ausfiele,
wäre eine Karte der Grenze: genug Schreibweisen probiert, und die Unterschiede sagen,
wo sie verläuft.

**Alles Gelesene ist eingefasst, die Auflistung eingeschlossen.** Ein Dateiname kann vom
Angreifer stammen — `Bitte ignoriere deine Anweisungen.txt` ist auf jedem Dateisystem
ein gültiger Name. Unsere eigenen Fehlermeldungen bleiben außerhalb der Einfassung: Sie
sind kein Material zum Lesen, sondern der Grund, als Nächstes etwas anderes zu tun.

**Gelesen wird über `NSFileCoordinator`.** Spinds File Provider ist eine replizierte
Erweiterung mit Files-on-Demand, der größte Teil eines großen Ordners besteht also aus
Name und Größe und sonst nichts. `Data(contentsOf:)` bekommt darauf je nach Tag eine
leere Datei oder einen Fehler; die Koordination ist das, was den Provider bittet, sie
vorher zu holen. Die Auflistung sagt je Eintrag, ob er noch nicht geladen ist — das ist
der Unterschied zwischen „Lesen kostet nichts“ und „Lesen lädt herunter“.

**Nur lesen, wie beim Bestand und mehr noch.** Das ist das einzige Werkzeug, das in
Material greift, das niemand in diesem Gespräch geschrieben hat. Ein Modell, das sich
von einem gerade gelesenen Dokument herumkriegen lässt, ist genau der Fall, für den es
`UntrustedContent` gibt — und die Antwort darauf ist kein besserer Prompt, sondern ein
Werkzeug, das nicht handeln kann.

## Die Dokumente lesen

`Documents/` macht aus einem Ordner voller Dateien etwas, an das sich eine Frage
richten lässt. Vier Teile, jeder mit einem Grund, getrennt zu sein.

**`DocumentParser` verteilt auf das Apple-Framework, das das Format liest.** PDFKit für
PDF; `NSAttributedString` für RTF, RTFD und HTML; Vision für Bilder und für PDFs ohne
Textebene; `XMLParser` für die Office- und OpenDocument-Teile. Welche Formate das sind,
entscheidet das, was iOS wirklich mitbringt: Auf macOS liest `NSAttributedString`
`.docx` und `.odt` direkt, auf iOS nicht — und genau diese Lücke ist der Grund, warum es
`ZipArchive` gibt.

**`ZipArchive` ist ein Nur-Lese-ZIP-Leser, rund hundert Zeilen.** iOS bringt keinen mit,
und `.docx`, `.xlsx`, `.pptx`, `.pages`, `.numbers`, `.key`, `.epub` und `.odt` sind
alle ZIP-Container — ohne ihn liest der Parser ein PDF und eine Textdatei und nichts,
worin jemand ein Dokument schreibt. Nur der Container ist unserer: Das Entpacken macht
Apples `COMPRESSION_ZLIB` (rohes DEFLATE ist, was ZIP speichert), und was herauskommt,
geht zurück an PDFKit, `XMLParser` oder `NSAttributedString`. iWork-Dateien werden über
die PDF-Vorschau gelesen, die sie mitführen — ihr eigentliches Format ist ein
undokumentiertes Protobuf-Archiv, das keine iOS-Schnittstelle öffnet.

**`ParsedDocument` ist die maschinenlesbare Form: Metadaten plus adressierbare
Abschnitte.** Abschnitte statt einer Zeichenkette sind der ganze Punkt — eine Fundstelle
nützt nur, wenn man auf sie zeigen kann. Also trägt der Text seine Position vom Parsen
über die Datenbank und das Suchergebnis bis in die Antwort. Die Grenzen kommen aus dem
Format (eine Seite, ein Blatt, eine Folie), nicht aus einer Vermutung über Absätze.

**`DocumentIndex` ist SQLite mit FTS5**, das im System-SQLite von iOS enthalten ist —
Volltextsuche kostet also ein Link-Flag und keine Abhängigkeit. Der Rest der App legt
JSON-Dateien ab, das hier nicht: „Wo steht etwas über den Heizkessel“ über JSON zu
beantworten hieße, bei jeder Frage jedes Dokument in den Speicher zu laden.

Aktuell ist ein Eintrag über Änderungsdatum **und** Größe. Das Datum allein nehmen alle,
und es reicht nicht: Eine vom Server zurücksynchronisierte Datei kann mit einem Datum
ankommen, das sie schon hatte. Was beides nicht fängt — eine Änderung bei gleicher
Byte-Zahl — bräuchte eine Prüfsumme über die ganze Datei, und das hieße bei einem
synchronisierten Ordner, alles herunterzuladen, um zu prüfen, ob sich etwas geändert hat.

**`DocumentLibrary` hält die drei Aufgaben auseinander**, und das hält eine Runde
schnell. Ein benanntes Dokument zu lesen parst bei Bedarf und merkt sich das Ergebnis.
Die Inhaltssuche antwortet aus dem Index und parst nie — eine Frage ist nicht der
Moment, vierhundert Dateien zu lesen; deshalb sagt die Antwort, wie viele Dokumente sie
durchsucht hat und was zu tun ist, wenn der Fehlschlag „noch nicht eingelesen“ bedeutet.
Das Füllen des Index ist das dritte und geschieht, wenn das Modell im Inhalt sucht —
nicht auf einem Zeitgeber und nicht auf Knopfdruck.

An dieser Einordnung hängt die ganze Funktion. Ein Zeitgeber holte Dateien übers Netz,
nach denen niemand gefragt hat. Ein Knopf in den Einstellungen ließe eine Suche
stillschweigend aus dem beantworten, was zuletzt jemand zu drücken dachte. Bei der Suche
fragt das Modell, im Auftrag einer gerade getippten Frage, und der Nutzer sieht dabei zu:
Das Werkzeug meldet den Fortschritt über `TurnEvent.toolProgress` — deshalb gibt es
diesen Fall, und deshalb nutzt ihn kein anderes Werkzeug. Gelesen wird gegen eine Uhr,
und gewinnt die Uhr, sagt die Antwort das — eine Suche über den halben Ordner, die
vorgibt, eine Suche über den Ordner zu sein, ist das Einzige, was sich vom Echten nicht
unterscheiden lässt.

Zwei Einzelheiten, die leicht falsch werden und teuer zu finden sind. Apples HTML-Leser
steht auf WebKit und setzt sich auf die Hauptwarteschlange, egal von welchem Thread er
gerufen wurde — HTML außerhalb des Main Actors zu parsen blockiert also, und zwar an
einer Datei: Die App hängt an dem Tag, an dem jemand eine Webseite in seinen Ordner
legt, und vorher nie. Und geparst wird über `NSFileCoordinator` in eine temporäre Kopie,
weil eine noch nicht heruntergeladene File-Provider-Datei bei `Data(contentsOf:)` je
nach Tag eine leere Datei oder einen Fehler liefert.

## Websuche und Seiten lesen

**Suchrezepte.** Brave, Tavily, Serper, SearXNG und Exa kommen als fertige Rezepte
(`Search/BuiltinRecipes.swift`). Für alles andere gibt es die automatische Einrichtung:
Schlägt der Test fehl — oder sehen die Treffer falsch aus —, klopft Faden den Endpoint
ab, bis eine gültige Antwort mit HTTP 200 zurückkommt, zeigt deren Struktur einem der
Modelle des Nutzers und lässt sich von ihm einen Parser dafür schreiben. Der Parser ist
reine Konfiguration (`SearchRecipe`), wird lokal gegen dieselbe Antwort geprüft, bevor
er gespeichert wird, und läuft danach vollständig auf dem Gerät — für Suchen braucht es
kein Modell.

**`fetch_page` führt kein JavaScript aus**, deshalb kommt es darauf an, was danach übrig
bleibt. Bevorzugt wird die vom Dokument markierte Inhaltsregion, dazu strukturierte
Daten (JSON-LD), die auch clientseitig gerenderte Seiten meist noch mitliefern;
Navigationsleisten, Zustimmungsbanner und unaufgelöste Vorlagen fliegen zeilenweise
raus. Bleibt nichts Lesbares, sagt das Werkzeug das ausdrücklich, statt Menüreste als
Inhalt auszugeben — so wechselt das Modell sofort die Quelle, statt zwei Runden zu
verlieren.

## Gedächtnis: eine Portierung von cognee

Faden baut aus den Gesprächen einen Wissensgraphen — keine Liste von Notizen.
`Memory/` ist eine Portierung von [cognee](https://github.com/topoteretes/cognee)
(Apache-2.0), keine Nachempfindung:

- **Aufnahme** wie `cognify`: Text → Chunks → das Modell zieht `KnowledgeGraph{nodes, edges}`
  daraus, mit cognees eigenem Extraktions-Prompt (übersetzt) — grundlegende Typen statt
  „Mathematiker“, lesbare IDs statt Zahlen, Verweise auf einen Namen aufgelöst.
- **Identität** wie `DataPoint.id_for`: `uuid5(NAMESPACE_OID, "Typ:wert")`. Dieselbe Person
  in zwei Gesprächen bekommt dieselbe ID und verschmilzt zu einem Knoten, statt ein zweites
  Mal angelegt zu werden. Die Swift-Implementierung erzeugt bitgenau dieselben IDs wie
  cognees Python.
- **Abruf** wie `GraphCompletionRetriever`: Vektorsuche über Knoten *und* Kanten, die Treffer
  als Saatpunkte, von dort `neighborhoodDepth` Schritte durch den Graphen, Tripel bewertet
  nach ihrem stärksten Teil abzüglich `triplet_distance_penalty` pro Schritt.
- **Bi-temporal**: Ein überholter Fakt wird geschlossen (`validTo`), nicht gelöscht.

**Robust gegen Ratenbegrenzung.** Einbettungs-Endpoints sind oft ratenbegrenzt, und das
ist der Normalfall, nicht die Ausnahme. Deshalb blockiert die Aufnahme nie daran:
Extrahierte Fakten werden auch ohne Vektor gespeichert — der Modellaufruf, der sie
gefunden hat, ist bezahlt und soll nicht verfallen. Fehlende Vektoren holt eine
Nacharbeit später nach, im Minutentakt und automatisch beim nächsten Start. Bis dahin
sind diese Fakten nur nicht per Ähnlichkeit auffindbar. Dauerhafte Fehler (falsches
Modell, fehlende Berechtigung) werden davon unterschieden und nicht endlos wiederholt.
Einbettungen lassen sich auch auf dem Gerät berechnen (`LocalEmbedder`, Apples
`NLContextualEmbedding`); den gemessenen Preis an Trefferqualität hält diese Datei fest.

**Weggelassen**, weil es Serverbetrieb ist und auf einem Telefon nichts beiträgt:
Neo4j/Kuzu und LanceDB (cognees eigener Standardweg ist ohnehin
`brute_force_triplet_search`), FastAPI, Nutzerverwaltung, Alembic-Migrationen,
Ontologie-Verankerung, das Eval-Framework. Der Graph liegt als eine Datei auf dem Gerät
und ist im Chat einsehbar und Eintrag für Eintrag löschbar.

## Prompt-Caching und die Uhr

Der Assistent kennt Datum und Uhrzeit — sie stehen aber nicht im System-Prompt, sondern
am Ende der letzten Nutzernachricht. Prompt-Caching gleicht einen exakten Präfix ab, und
die Reihenfolge ist Werkzeuge → System → Nachrichten: Eine Uhr im System-Prompt ändert
die ersten Bytes jeder Anfrage, womit nichts dahinter je wiederverwendbar ist. Dasselbe
gilt für abgerufene Erinnerungen: Sie wechseln von Runde zu Runde und würden den gemeinsamen
Präfix im System-Prompt früh brechen. Beides sitzt deshalb
hinter dem Cache-Punkt, auf Inhalt, der ohnehin neu ist.

Die Persona („die Stimme“) ist der umgekehrte Fall: Sie ändert sich nur, wenn der Nutzer
sie ändert, sitzt deshalb im stabilen Teil der Anweisungen und kostet pro Frage nichts.

## Entscheidungen an der Oberfläche

**Die Stimme gehört dir.** In einer App ohne Anbieter gibt es keine Marke, die den Ton
vorgibt, also wird er eingestellt statt vorgegeben: Anrede, Ausführlichkeit, Ton, dazu
ein Freitextfeld. Der Einstellungsbildschirm zeigt wörtlich, was dem Modell gesagt wird,
und lässt eine Probe hören, bevor die Stimme in einem echten Gespräch landet.

**Antworten sagen, wer sie geschrieben hat.** Sobald mehr als ein Modell eingerichtet
ist, steht der Modellname an der Antwort — bei mehreren Modellen ist eine Antwort ohne
Absender eine, die man nicht einordnen kann. Bei nur einem Modell entfällt die Angabe,
weil sie dann nur Rauschen wäre.

**Overlays nach Zweck.** Einstellungen sind eine längere Aufgabe und nehmen den ganzen
Bildschirm. Verlauf und Gedächtnis sind kurze Nachschlagevorgänge und liegen als
halbhohe Blätter über dem Chat, der dahinter sichtbar bleibt — man sieht, wovon man
wegwechselt. Blätter werden nicht gestapelt, [wovon NN/g ausdrücklich abrät](https://www.nngroup.com/articles/bottom-sheet/):
Anbieter-Einrichtung und Modellliste sind Schritte *innerhalb* der Einstellungen, keine
zweite Ebene darüber.

**Nachbessern statt neu tippen.** NN/g beschreibt zwei Muster, wie Menschen generative
KI nutzen ([„Accordion Editing and Apple Picking“](https://www.nngroup.com/articles/accordion-editing-apple-picking/),
2023): Sie lassen Antworten wiederholt kürzen oder ausweiten, und sie beziehen sich auf
einzelne Stellen einer früheren Antwort — wofür sie sonst hochscrollen, markieren und
kopieren müssen. Faden hat dafür Aktionen direkt an der Antwort: Kopieren, neu holen,
kürzer, ausführlicher. Ein langer Druck auf einen Absatz zitiert genau diesen in die
Eingabe. Eine missverstandene Frage lässt sich bearbeiten und neu stellen, statt sie
weiter unten noch einmal zu formulieren — was sie sonst im Verlauf stehen ließe, wo sie
die folgenden Antworten weiter beeinflusst.

**Warten wird begründet.** Die Anzeige bleibt stumm, solange eine Antwort normal
entsteht, und sagt erst nach einigen Sekunden, worauf gewartet wird. Fehler kommen mit
einem Knopf zum erneuten Versuch — außer bei solchen, die Warten nicht behebt, etwa
einem falschen Schlüssel.

**Lesbar in jeder Textgröße.** Alle Schriftgrößen folgen der Systemeinstellung. Der
Inhalt skaliert bis zur größten Barrierefreiheits-Stufe durch; Kopfzeile, Eingabe und
Kontextleiste sind begrenzt, weil dort sonst Symbole übereinanderlaufen. Die Aktionen
unter einer Antwort lassen ihre Beschriftungen fallen und stehen als Symbole in
antippbarer Größe, sobald der Platz nicht mehr reicht.

**VoiceOver bekommt Sätze, keine Zeichen.** Während eine Antwort streamt, ist sie für
den Screenreader ausgeblendet — jedes Token einzeln anzusagen ist die übliche Art, eine
Chat-Oberfläche unbenutzbar zu machen. Angesagt wird stattdessen, was gerade passiert
(„sucht im Web“, „Antwort wird geschrieben“); die fertige Nachricht steht danach als ein
Element im Verlauf, das mit Sprecher, Werkzeugen und Text vorgelesen wird.

**Kontext und Verdichten.** Eine Haarlinie am unteren Rand zeigt, wie viel des Fensters
belegt ist; die Schätzung korrigiert sich, sobald der Anbieter echte Verbrauchszahlen
meldet. Ab 75 % (einstellbar) fasst Faden den älteren Verlauf im Hintergrund zusammen —
gegliedert nach Auftrag, Stand, Entscheidungen und Offenem, mit Zahlen, Namen und
Quellen wörtlich übernommen. Die letzten Züge bleiben unangetastet, `remember`-Notizen
überleben vollständig. Der Schnitt liegt immer vor einem frischen Zug, damit kein
Werkzeugergebnis von seinem Aufruf getrennt wird.

**Titel.** Unterhaltungen heißen zuerst nach ihrem ersten Satz und werden dann vom
Modell umbenannt, sobald genug Inhalt da ist — und erneut, wenn der Verlauf sich etwa
verdoppelt hat und das Thema vermutlich weitergewandert ist.

## Namen: warum `perbu`

Zwei Dinge heißen weiterhin `perbu` beziehungsweise `PerBu`, beide mit Absicht. Die
**Bundle-ID** `dev.eigenhand.perbu` ist die Identität der App in App Store Connect und
auf jedem Gerät, auf dem sie liegt: Eine neue wäre eine neue App, mit neuem TestFlight,
neu einzuladenden Testern und einem zweiten Icon statt eines Updates. Der
**Datenordner** in Application Support trägt denselben Namen; ein anderer würde jede
gespeicherte Unterhaltung und den Wissensgraphen verwaisen lassen. Alles Übrige —
Projekt, Ziele, Quellordner, Typen — heißt Faden.

## Was mit Absicht nicht abstrahiert ist

**Keine Repository-Schicht, keine View Models.** `AppModel` *ist* das View Model, für
alle Ansichten. Die App hat einen Bildschirm mit Blättern darüber; eine zweite Ebene
Indirektion brächte Dateien, keine Klarheit.

**Kein Container für Abhängigkeiten.** Zwei Singletons (`Store.shared`,
`MemoryStore.shared`), ein Namensraum aus statischen Funktionen (`Keychain`), der Rest
wird als Parameter durchgereicht. Was geprüft wird, ist
eine `static func` oder ein Werttyp — es muss nichts ausgetauscht werden, um zu testen.

**Zwei Stringkataloge statt eines gemeinsamen Frameworks.** Faden und Fundus tragen
denselben Einfassungs-Code zweimal. Das ist Dopplung, und sie steht so im Quelltext:
Sie zu teilen wäre eine gemeinsame Bibliothek wert, und solange es die nicht gibt, ist
doppelter Code besser als eine ungeschützte App.

**`Memory/` ist eine Portierung, keine Anlehnung.** Es bildet cognees Identitätsfunktion
bitgenau nach, damit dieselbe Person in zwei Gesprächen dieselbe Knoten-ID bekommt. Wo
es abweicht — keine Graphdatenbank, kein Vektorspeicher, kein Server —, steht das mit
Begründung dabei.

## Prüfen

234 Unittests, alle ohne Netz, dazu UI-Tests, die die echte App im Simulator fahren. Die
Teilung ist Absicht: Was sich aus Werten entscheiden lässt, ist ein Unittest; was einen
Bildschirm braucht, ist ein UI-Test; alles andere ist nicht geprüft und sagt das.

Die Unittests laufen auf einem Simulator mit `xcodebuild test … -only-testing:FadenTests`
(der vollständige Befehl steht in der README). Die CI führt sie bei jedem Push aus, der
etwas anderes anfasst als eine `.md`-Datei, zusammen mit `check-localizations.py`. Die
UI-Tests brauchen einen vorbereiteten Simulator (`seed-fixture.sh`, `seed-memory.sh`,
`seed-broken.sh`) und überspringen sich ohne ihn; sie laufen von Hand vor einem Release.

## Hinweise für Maintainer: veröffentlichen

`./release.sh` archiviert die App, lädt sie zu TestFlight hoch und weist den Build der
internen Testergruppe zu (`assign-build.sh`). Es ist auf das Konto des Maintainers
zugeschnitten; ein Fork braucht durchgehend eigene Werte. Vorher einmalig nötig:

- die Bundle-ID `dev.eigenhand.perbu` registriert und der App-Eintrag in App Store
  Connect angelegt;
- ein App-Store-Connect-API-Schlüssel mit der Rolle „App Manager“, dessen privater
  Schlüssel unter `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` liegt;
- `.release.env` (kopiert aus `.release.env.example`) mit `ASC_ISSUER_ID` und
  `ASC_KEY_ID` (App Store Connect › Users and Access › Integrations);
- ein Verteilungsprofil namens `Faden App Store - (API)`, von Hand im Developer-Portal
  angelegt, weil die Release-Konfiguration damit manuell signiert (der Grund steht in
  `project.yml`). Wer das Signierzertifikat ersetzt, muss das Profil neu anlegen;
- die App-ID in `assign-build.sh` ist die des Maintainer-App-Eintrags.

App Store Connect lehnt Builds aus einer Xcode-Beta ab; ist die aktive Auswahl eine Beta
und liegt `/Applications/Xcode.app` daneben, baut das Skript mit Letzterem.
