# Architektur

*[English](ARCHITECTURE.md) · Deutsch*

Wofür dieses Dokument da ist: Die README sagt, was Faden tut, `SECURITY.de.md` sagt,
was es schützt. Dieses hier sagt, wie es gebaut ist und welche Entscheidungen man
kennen muss, bevor man etwas ändert.

## Die Form

Zwölf Ordner, keine externen Abhängigkeiten, etwa 15 000 Zeilen. Der
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
| `Agent/` | Die Zugschleife, die vier Werkzeuge, die Einfassung fremden Textes, die Adressprüfung |
| `Search/` | Rezept-Format, lokale Ausführung, fertige Anbieter, Autokonfiguration |
| `Memory/` | Der Wissensgraph nach cognee: Identität, Extraktion, Einbettung, Tripel-Suche |
| `Context/` | Token-Schätzung, Verdichten, Titel |
| `Speech/` | Diktat, Aufnahme, eigene STT-/TTS-Endpoints |
| `Media/` | Bildaufbereitung und die Vision-Prüfung |
| `Storage/` | Schlüsselbund, Dateipersistenz, die Import-Entschärfung |
| `App/` | `AppModel`, der Zustand je Unterhaltung, der Einstieg, die App Intents |
| `UI/` | 25 SwiftUI-Ansichten, 6 100 Zeilen — der mit Abstand größte Ordner, und zu Recht |
| `Design/` | Eine Datei: Palette, Schriftskala, Bausteine |

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
man längst woanders liest. Die Alternative — ein globales „es streamt gerade" — ist
das, was die meisten Chat-Clients tun, und sie verliert die Antwort in dem Moment, in
dem jemand wegtippt.

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

Der Grund ist überall derselbe: Ein Schweigen in einer Modellliste ist kein „nein". Ein
Modell, von dem die App nie gehört hat, muss benutzbar sein, und eines, das still eine
Fähigkeit verloren hat, darf die App nicht brechen.

## Die Sicherheitsgrenze

Zwei Dateien ziehen sie, und beide liegen in `Agent/`.

`UntrustedContent` fasst alles ein, was aus `web_search` und `fetch_page` zurückkommt,
mit einer je Aufruf gewürfelten Kennung. `FetchTarget` entscheidet, welche Adressen ein
Werkzeug überhaupt laden darf, einschließlich jeder Weiterleitung.

Beide sind reine Funktionen über Zeichenketten und Adressen, beide haben Tests, und
keine weiß, was mit ihrem Ergebnis geschieht. Die Einzelheiten und — wichtiger — die
Grenzen stehen in [SECURITY.de.md](SECURITY.de.md).

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

96 Unittests, alle ohne Netz, dazu UI-Tests, die die echte App im Simulator fahren. Die
Teilung ist Absicht: Was sich aus Werten entscheiden lässt, ist ein Unittest; was einen
Bildschirm braucht, ist ein UI-Test; alles andere ist nicht geprüft und sagt das.

`./run-tests.sh` führt die Unittests auf einem Simulator aus. Die CI führt sie bei
jedem Push aus, der etwas anderes anfasst als eine `.md`-Datei.
