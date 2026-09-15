# Faden

Ein Chatbot fürs iPhone, der nichts mitbringt außer der Oberfläche. Modell, Endpoint,
API-Key und Suchanbieter kommen von dir. Keine Zwischenserver, keine Konten, keine
Telemetrie — die App spricht ausschließlich mit den Adressen, die du einträgst.

Design nach [eigenhand.dev](https://eigenhand.dev).

## Was drin ist

**Eigenes Modell.** Zwei Wire-Formate: Anthropic Messages (`/v1/messages`) und
OpenAI-kompatibel (`/v1/chat/completions`) — letzteres deckt Groq, Together,
OpenRouter, Mistral, Ollama, vLLM, LM Studio und die meisten Proxys ab. Streaming,
Werkzeugaufrufe und Gedankengang (`reasoning_content` bzw. `thinking`) inklusive.

**Eigene Websuche.** Fertige Rezepte für Brave, Tavily, Serper, SearXNG und Exa.
Für alles andere gibt es die automatische Einrichtung: Schlägt der Test fehl — oder
sehen die Treffer falsch aus — klopft Faden den Endpoint selbst ab, bis eine gültige
Antwort mit HTTP 200 zurückkommt, zeigt deren Struktur einem deiner Modelle und lässt
sich daraus einen Parser schreiben. Der Parser ist reine Konfiguration
(`SearchRecipe`), wird lokal gegen dieselbe Antwort geprüft, bevor er gespeichert
wird, und läuft danach vollständig auf dem Gerät — für Suchen wird kein Modell mehr
gebraucht.

**Agentisch.** Der Assistent sucht von sich aus, wenn eine Frage es verlangt, führt
mehrere gezielte Suchen statt einer breiten, lädt Seiten nach (`fetch_page`) und hält
Wichtiges mit `remember` fest. Er kennt Datum und Zeitzone des Geräts.

**Seiten lesen.** `fetch_page` führt kein JavaScript aus — deshalb kommt es darauf an,
was danach übrig bleibt. Bevorzugt wird die vom Dokument markierte Inhaltsregion, dazu
strukturierte Daten (JSON-LD), die auch client-seitig gerenderte Seiten meist noch
mitliefern; Navigationsleisten, Zustimmungsbanner und unaufgelöste Templates fliegen
zeilenweise raus. Bleibt nichts Lesbares, sagt das Werkzeug das ausdrücklich, statt
Menüreste als Inhalt auszugeben — so wechselt das Modell sofort die Quelle, statt zwei
Runden zu verlieren.

**Bilder.** Kann das Modell sie lesen, erscheint im Eingabefeld ein Plus zum Anhängen.
Ob es das kann, findet der Verbindungstest selbst heraus: er schickt ein winziges
Zweifarbenbild und fragt, was darauf ist. Ein abgelehnter Upload heißt nein, eine
Antwort, die beide Farben nennt, heißt ja — geraten wird nichts. Fotos werden vor dem
Senden verkleinert, damit ein Schnappschuss nicht den halben Kontext frisst.

**Modelle und Grenzen.** Der Editor lädt die Modellliste direkt vom Endpoint, mit dem,
was der Anbieter über Kontext, Ausgabelänge und Preis verrät. Sagt er nichts, versucht
die App die Grenzen aus einer bewusst überzogenen Anfrage herauszulesen — und merkt
sich sonst, welche Prompt-Größe nachweislich durchging. Kontextfenster und maximale
Antwortlänge stellst du mit logarithmischen Reglern ein.

**Sprechen und Hören.** Im Eingabefeld sitzt eine Mikrofontaste: gedrückt halten,
sprechen, loslassen. Der Text kommt entweder von Apples Spracherkennung — wo möglich
auf dem Gerät, dann verlässt nichts das iPhone — oder von deinem eigenen
Whisper-Endpoint (`/v1/audio/transcriptions`, mit `faster-whisper` getestet).
Antworten liest Faden auf Wunsch vor, über einen eigenen Sprachdienst
(`/v1/audio/speech`) oder die im iPhone eingebaute Stimme. Fällt der eigene Dienst
aus, springt die Apple-Stimme ein, statt die Antwort verstummen zu lassen.

**Gedächtnis (nach cognee).** Faden baut aus euren Gesprächen einen Wissensgraphen —
nicht eine Liste von Notizen. Das System ist [cognee](https://github.com/topoteretes/cognee)
(Apache-2.0) portiert, nicht nachempfunden:

- **Aufnahme** wie `cognify`: Text → Chunks → das Modell zieht `KnowledgeGraph{nodes, edges}`
  daraus, mit cognees eigenem Extraktions-Prompt (übersetzt) — grundlegende Typen statt
  „Mathematiker", lesbare IDs statt Zahlen, Referenzen auf einen Namen aufgelöst.
- **Identität** wie `DataPoint.id_for`: `uuid5(NAMESPACE_OID, "Typ:wert")`. Dieselbe Person
  in zwei Gesprächen bekommt dieselbe ID und verschmilzt zu einem Knoten, statt ein zweites
  Mal angelegt zu werden. Die Swift-Implementierung erzeugt bitgenau dieselben IDs wie
  cognees Python.
- **Abruf** wie `GraphCompletionRetriever`: Vektorsuche über Knoten *und* Kanten, die Treffer
  als Saatpunkte, von dort `neighborhoodDepth` Schritte durch den Graphen, Tripel bewertet
  nach ihrem stärksten Teil abzüglich `triplet_distance_penalty` pro Schritt.
- **Bi-temporal**: Ein überholter Fakt wird geschlossen (`validTo`), nicht gelöscht.

**Ausfallsicher.** Einbettungs-Endpoints sind oft mengenbegrenzt, und das ist der
Normalfall, nicht die Ausnahme. Deshalb blockiert die Aufnahme nie daran: extrahierte
Fakten werden auch ohne Vektor gespeichert — der Modellaufruf, der sie gefunden hat, ist
bezahlt und soll nicht verfallen. Fehlende Vektoren holt eine Nacharbeit später nach, im
Minutentakt und automatisch beim nächsten Start. Bis dahin sind diese Fakten nur nicht per
Ähnlichkeit auffindbar. Dauerhafte Fehler (falsches Modell, fehlende Berechtigung) werden
davon unterschieden und nicht endlos wiederholt.

Weggelassen, weil es Serverbetrieb ist und auf einem Telefon nichts beiträgt: Neo4j/Kuzu
und LanceDB (cognees eigener Standardweg ist ohnehin `brute_force_triplet_search`), FastAPI,
Nutzerverwaltung, Alembic-Migrationen, Ontologie-Verankerung, das Eval-Framework. Der Graph
liegt als eine Datei auf dem Gerät und ist im Chat einsehbar und einzeln löschbar.

**Titel.** Unterhaltungen heißen zuerst nach ihrem ersten Satz und werden dann vom
Modell umbenannt, sobald genug Inhalt da ist — und erneut, wenn der Verlauf sich
verdoppelt hat und das Thema vermutlich weitergewandert ist.

**Zeit ohne Cache-Bruch.** Der Assistent kennt Datum und Uhrzeit — sie stehen aber
nicht im System-Prompt, sondern am Ende der letzten Nutzernachricht. Prompt-Caching
gleicht einen exakten Präfix ab, und die Reihenfolge ist Werkzeuge → System → Nachrichten:
eine Uhr im System-Prompt ändert die ersten Bytes jeder Anfrage, womit nichts dahinter je
wiederverwendbar ist. Dasselbe galt für die abgerufenen Erinnerungen — gemessen brach der
gemeinsame Präfix dadurch schon nach 1965 von 2521 Zeichen. Beides sitzt jetzt hinter dem
Cache-Punkt, auf Inhalt, der ohnehin neu ist.

**Unterhaltungen sind getrennt.** Jeder Chat hat seinen eigenen Laufzeitzustand —
laufende Antwort, Streaming-Text, Werkzeugliste, angehängte Bilder, Kontextfüllstand,
Fehlermeldung, Verdichtungslauf. Ein Zug wird der Unterhaltung zugeordnet, in der er
begann, und schreibt sein Ergebnis dorthin zurück, auch wenn währenddessen ein anderer
Chat geöffnet wurde. Nur das Gedächtnis ist bewusst gemeinsam.

**Die Stimme gehört dir.** In einer App ohne Anbieter gibt es keine fremde Marke, die
den Ton vorgibt. Untersuchungen zu Markenidentität in Dialogsystemen finden, dass
Engagement mit der Passung zwischen Person und Stimme steigt — also wird sie eingestellt,
nicht vorgegeben: Anrede, Ausführlichkeit, Ton, dazu ein Freitextfeld. Der Einstellungs-
bildschirm zeigt wörtlich, was dem Modell gesagt wird, und lässt eine Probe hören, bevor
die Stimme in einem echten Gespräch landet. Weil sie sich nur ändert, wenn du sie
änderst, sitzt sie im stabilen Teil der Anweisungen und kostet pro Frage nichts.

**Antworten sagen, wer sie geschrieben hat.** Sobald mehr als ein Modell eingerichtet ist,
steht der Modellname an der Antwort. Dieselbe Forschung findet, dass visuelle Gestaltung
*ohne* Transparenz die Bereitschaft senkt, ein System weiter zu nutzen — und bei mehreren
Modellen ist eine Antwort ohne Absender genau das. Bei nur einem Modell entfällt die
Angabe, weil sie dann nur Rauschen wäre.

**Overlays nach Zweck.** Einstellungen sind eine längere Aufgabe und nehmen den ganzen
Bildschirm. Verlauf und Gedächtnis sind kurze Nachschlagevorgänge und liegen als halbhohe
Blätter über dem Chat, der dahinter sichtbar bleibt — man sieht, wovon man wegwechselt.
Gestapelte Blätter, die NN/g ausdrücklich abrät, gibt es nicht mehr: Anbieter-Einrichtung
und Modell-Liste sind Schritte *innerhalb* der Einstellungen, keine zweite Ebene darüber.

**Nachbessern statt neu tippen.** Untersuchungen dazu, wie Menschen generative KI
tatsächlich nutzen (NN/g), zeigen zwei Muster: Sie lassen Antworten wiederholt kürzen
oder ausweiten („accordion editing"), und sie beziehen sich auf einzelne Stellen einer
früheren Antwort („apple picking") — wofür sie sonst hochscrollen, markieren und
kopieren müssen. Faden hat dafür Aktionen direkt an der Antwort: Kopieren, neu holen,
kürzer, ausführlicher. Ein langer Druck auf einen Absatz zitiert genau diesen in die
Eingabe. Eine missverstandene Frage lässt sich bearbeiten und neu stellen, statt sie
weiter unten noch einmal zu formulieren — was sie sonst im Verlauf stehen ließe, wo sie
die folgenden Antworten weiter beeinflusst.

**Warten wird begründet.** Studien zu Antwortverzögerungen finden, dass eine Erklärung
des Wartens Vertrauen und wahrgenommene Transparenz stärker hebt als das Verkürzen
selbst. Der Punkt bleibt stumm, solange eine Antwort normal entsteht, und sagt erst nach
einigen Sekunden, worauf gewartet wird. Fehler kommen mit einem Knopf zum erneuten
Versuch — außer bei solchen, die Warten nicht behebt, etwa einem falschen Schlüssel.

**Lesbar in jeder Textgröße.** Alle Schriftgrößen wachsen mit der Systemeinstellung —
vorher waren 112 Stellen auf feste Punktgrößen verdrahtet, sodass eine größere Systemschrift
in Faden schlicht wirkungslos blieb. Der Inhalt skaliert bis zur größten
Barrierefreiheits-Stufe durch; Kopfzeile, Eingabe und Kontextleiste sind begrenzt, weil
dort sonst Symbole übereinanderlaufen. Die Aktionen unter einer Antwort lassen ihre
Beschriftungen fallen und stehen als Symbole in Tap-Größe, sobald der Platz nicht mehr
reicht.

**VoiceOver bekommt Sätze, keine Zeichen.** Während eine Antwort streamt, ist sie für
den Screenreader ausgeblendet — jedes Token einzeln anzusagen ist die übliche Art, ein
Chat-Interface unbenutzbar zu machen. Angesagt wird stattdessen, was gerade passiert
(„sucht im Web", „Antwort wird geschrieben"); die fertige Nachricht steht danach als ein
Element im Verlauf, das mit Sprecher, Werkzeugen und Text vorgelesen wird.

**Kontextanzeige.** Eine Haarlinie am unteren Rand zeigt laufend, wie viel des
Fensters belegt ist. Die Schätzung korrigiert sich selbst, sobald der Anbieter echte
Verbrauchszahlen meldet.

**Automatisches Verdichten.** Ab 75 % (einstellbar) fasst Faden den älteren Verlauf
im Hintergrund zusammen — gegliedert nach Auftrag, Stand, Entscheidungen und Offenem,
mit Zahlen, Namen und Quellen wörtlich übernommen. Die letzten Turns bleiben
unangetastet, `remember`-Notizen überleben vollständig. Der Schnitt liegt immer vor
einem frischen Turn, damit kein Werkzeugergebnis von seinem Aufruf getrennt wird.

## Bauen

```bash
xcodegen generate
open PerBu.xcodeproj
```

Braucht Xcode 16+ und zielt auf iOS 17. Keine externen Abhängigkeiten.

Das Xcode-Projekt, der Quellordner und die Bundle-ID heißen weiterhin `PerBu` — das
war der Arbeitsname. Umbenannt wurde nur, was Nutzer sehen. Die Bundle-ID ist die
Identität der App in App Store Connect: eine neue wäre eine neue App, mit neuem
TestFlight und neu einzuladenden Testern. Der Datenordner trägt denselben Namen, und
ein anderer würde jede gespeicherte Unterhaltung verwaisen lassen.

## Auf ein Gerät bringen

`./release.sh` archiviert und lädt zu TestFlight hoch. Vorher einmalig nötig:
Bundle-ID `dev.eigenhand.perbu` registrieren, App-Eintrag in App Store Connect anlegen,
und `ASC_ISSUER_ID` setzen (App Store Connect › Users and Access › Integrations).

## Wo was liegt

| Ordner | Inhalt |
|---|---|
| `Design/` | Farben, Typografie und Bausteine — die Tokens von eigenhand.dev |
| `Models/` | Nachrichten, Blöcke, Einstellungen, ein dynamischer JSON-Typ |
| `Providers/` | Die beiden Wire-Formate und der SSE-Leser |
| `Search/` | Rezept-Format, lokale Ausführung, fertige Anbieter, Autokonfiguration |
| `Agent/` | Werkzeuge und die Schleife, die sie ausführt |
| `Context/` | Token-Schätzung und das Verdichten |
| `Media/` | Bildaufbereitung und die Vision-Prüfung |
| `Speech/` | Diktat, Aufnahme, eigene STT-/TTS-Endpoints, Sprachausgabe |
| `Memory/` | Der Wissensgraph nach cognee: Identität, Extraktion, Einbettung, Tripel-Suche |
| `Storage/` | Schlüsselbund und Dateipersistenz |
| `UI/` | Chat, Kontextleiste, Einstellungen, Einrichtungsassistent |

Keys liegen im Schlüsselbund des Geräts, alles andere als JSON in Application Support.

## Lizenz

Apache-2.0. Siehe [LICENSE](LICENSE). Copyright 2026 eigenhand.

Permissiv und nicht Copyleft: Faden läuft auf einem Telefon und spricht mit Endpoints,
die dem Nutzer gehören — es gibt hier nichts, was jemand als Dienst übernehmen und
schliessen könnte. Apache-2.0 statt MIT wegen der ausdrücklichen Patentlizenz.
