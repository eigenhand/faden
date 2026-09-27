# Faden

*[English](README.md) · Deutsch*

[![Tests](https://github.com/eigenhand/faden/actions/workflows/tests.yml/badge.svg)](https://github.com/eigenhand/faden/actions/workflows/tests.yml)

Ein KI-Chat-Client fürs iPhone, der nur die Oberfläche mitbringt. Modell, Endpoint,
API-Schlüssel und Suchanbieter kommen von dir. Keine Zwischenserver, keine Konten,
keine Telemetrie — die App spricht ausschließlich mit den Adressen, die du einträgst.

Die Gestaltung folgt [eigenhand.dev](https://eigenhand.dev). Was die App schützt und
was ausdrücklich nicht: [SECURITY.de.md](SECURITY.de.md). Wie sie gebaut ist:
[ARCHITECTURE.de.md](ARCHITECTURE.de.md). Ein Assistent mit Werkzeugen liest
fremden Text und kann handeln — [„Bewusste Kompromisse“](SECURITY.de.md#bewusste-kompromisse)
sagt, wo die Schutzmaßnahmen enden.

## Stand und Voraussetzungen

- **Stand:** Version 1.0, ein Freizeitprojekt in aktiver Entwicklung. Noch nicht im
  App Store — du baust es aus dem Quellcode.
- **Gerät:** iPhone mit iOS 17 oder neuer. Apples Modell auf dem Gerät braucht
  zusätzlich iOS 26 und Apple Intelligence.
- **Werkzeuge zum Bauen:** Xcode (getestet mit Xcode 26.6, der Version der CI) und
  [XcodeGen](https://github.com/yonaskolb/XcodeGen). Sonst keine Abhängigkeiten.
- **Sprachen:** Deutsch und Englisch.

## Was du zum Benutzen brauchst

Mindestens ein Chat-Modell, aus einer dieser Quellen:

- **Ein API-Schlüssel** für die Anthropic-API oder einen OpenAI-kompatiblen Dienst.
  Voreinstellungen gibt es für OpenAI, Anthropic, OpenRouter, Groq, Cerebras, Mistral,
  DeepSeek, xAI, Together, Fireworks und TensorX; jeden anderen Endpoint trägst du
  von Hand ein.
- **Ein eigener Server**, der das OpenAI-Format spricht, etwa Ollama, vLLM oder LM
  Studio. Der Schlüssel ist optional; der Server muss vom iPhone aus erreichbar sein. Im
  Heimnetz funktioniert einfaches `http://` mit einer IP-Adresse oder einem `.local`-Namen
  (iOS fragt einmal nach dem Zugriff aufs lokale Netzwerk); alles andere braucht `https://`.
- **Apples Modell auf dem Gerät** — kein Endpoint, kein Schlüssel, nichts verlässt das
  Telefon. Der Preis: keine Werkzeuge, keine Bilder, ein kleines Kontextfenster.

Optional: ein Suchanbieter (siehe Funktionen), ein Einbettungs-Endpoint für das
Gedächtnis (oder Einbettungen auf dem Gerät) und eigene Sprach-Endpoints.

## Was dein Telefon verlässt

Nur, was an die Dienste geht, die du eingetragen hast:

- **Modell-Endpoint:** die Unterhaltung, angehängte Bilder, Werkzeugergebnisse — auch
  Einträge aus dem Bestand und Inhalte aus dem Ordner, wenn das Modell dort nachsieht.
- **Suchanbieter:** die Suchanfrage. **Webseiten:** ein einfacher Seitenabruf.
- **Einbettungs-Endpoint:** Text, der zur Erinnerung wird, falls du einen nutzt.
- **Sprach-Endpoints:** deine Aufnahme und der vorzulesende Text, falls eingerichtet.
  Apples Diktat läuft auf dem Gerät, wo das Gerät es unterstützt.

Verlauf, Einstellungen, Erinnerungen und der Dokumentindex bleiben im Speicher der App
auf dem Gerät; API-Schlüssel bleiben im Schlüsselbund. Die vollständige Tabelle steht
in [SECURITY.de.md](SECURITY.de.md#was-das-gerät-verlässt).

## Funktionen

- **Eigenes Modell.** Anthropic Messages (`/v1/messages`) und OpenAI-kompatibel
  (`/v1/chat/completions`), mit Streaming, Werkzeugaufrufen und Gedankengang
  (`reasoning_content` bzw. `thinking`).
- **Eigene Websuche.** Fertige Rezepte für Brave, Tavily, Serper, SearXNG und Exa. Bei
  jedem anderen Anbieter klopft Faden den Endpoint ab, zeigt die Struktur der Antwort
  einem deiner Modelle und lässt sich von ihm einen Parser dafür schreiben. Der Parser
  ist reine Konfiguration, wird lokal geprüft und läuft danach auf dem Gerät — für
  Suchen braucht es kein Modell.
- **Agentisch.** Der Assistent sucht, wenn eine Frage es verlangt, führt mehrere
  gezielte Suchen, lädt Seiten nach (`fetch_page`, ohne JavaScript, nur Hauptinhalt
  und JSON-LD) und hält Wichtiges mit `remember` fest. Er kennt Datum und Zeitzone.
- **Bilder.** Ob ein Modell sehen kann, misst der Verbindungstest, statt zu raten.
  Fotos werden vor dem Senden verkleinert.
- **Modelle und Grenzen.** Die Modellliste kommt vom Endpoint; Grenzen stammen aus
  dem, was der Anbieter veröffentlicht oder in einer Absage nennt. Kontextfenster und
  Antwortlänge stellst du mit Reglern ein, oder der Antwortvorrat wächst mit der Nutzung.
- **Sprechen und Hören.** Gedrückt halten zum Diktieren, über Apples Spracherkennung
  oder deinen eigenen Whisper-Endpoint. Antworten liest dein eigener Sprachdienst vor
  oder die eingebaute iPhone-Stimme, die auch einspringt, wenn dein Dienst ausfällt.
- **Gedächtnis.** Ein Wissensgraph aus deinen Gesprächen — eine Portierung von
  [cognee](https://github.com/topoteretes/cognee) (Apache-2.0), gespeichert auf dem
  Gerät, einsehbar und Eintrag für Eintrag löschbar.
- **Die Stimme gehört dir.** Anrede, Ausführlichkeit, Ton und Freitext; die
  Einstellungen zeigen wörtlich, was dem Modell gesagt wird.
- **Antworten sagen, wer sie geschrieben hat**, sobald mehr als ein Modell eingerichtet ist.
- **Nachbessern statt neu tippen.** Kopieren, neu holen, kürzer, ausführlicher; einen
  Absatz per langem Druck zitieren; eine Frage bearbeiten und neu stellen.
- **Warten wird begründet.** Die Anzeige sagt nach einigen Sekunden, worauf sie wartet;
  Fehler, die ein neuer Versuch beheben kann, kommen mit einem Knopf dafür.
- **Overlays nach Zweck.** Einstellungen nehmen den ganzen Bildschirm; Verlauf und
  Gedächtnis liegen als halbhohe Blätter über dem Chat.
- **Barrierefrei.** Text skaliert bis zur größten Barrierefreiheits-Stufe; VoiceOver
  sagt an, was gerade passiert, nicht jedes gestreamte Token.
- **Lange Unterhaltungen.** Eine Haarlinie zeigt, wie voll der Kontext ist; ab 75 %
  (einstellbar) wird der ältere Verlauf im Hintergrund zusammengefasst. Titel schreibt
  das Modell.

**Optionale Anbindungen**, erst nach dem Verbinden in den Einstellungen angeboten und
nur lesend:

- **[Fundus](https://github.com/eigenhand/fundus)**, eine Inventar-App fürs iPhone:
  Der Assistent kann nachsehen, wo etwas liegt und wie viel davon da ist.
- **Ein Ordner in der Dateien-App** — etwa einer aus
  [Spind](https://github.com/eigenhand/spind), das eine Hetzner Storage Box als
  Cloud-Laufwerk einbindet, oder aus iCloud Drive. Der Assistent kann Dateien
  auflisten, finden und lesen und den Inhalt von PDFs (auch gescannten), Office-,
  iWork-, OpenDocument-, EPUB-, RTF-, HTML-, Text- und Quelldateien durchsuchen —
  mit Angabe von Dokument und Seite.

## Bauen

```bash
brew install xcodegen
xcodegen generate
open Faden.xcodeproj
```

Im Simulator läuft das Schema `Faden` unverändert. Für ein Gerät ersetzt du vorher
diese Werte durch deine eigenen:

- `DEVELOPMENT_TEAM` in `project.yml`
- die Bundle-IDs `dev.eigenhand.perbu` (und `.tests`, `.uitests`) in `project.yml`
- die App Group `group.dev.eigenhand.shared` und die Schlüsselbund-Gruppen in
  `Faden/Faden.entitlements` — ohne die App Group wird die Fundus-Anbindung einfach
  nicht angeboten

Dann startest du aus Xcode (Debug, automatische Signierung). Die Release-Konfiguration
signiert mit dem Verteilungsprofil des Maintainers; das Veröffentlichen beschreibt
[ARCHITECTURE.de.md](ARCHITECTURE.de.md#hinweise-für-maintainer-veröffentlichen).

Unittests:

```bash
xcodebuild test -project Faden.xcodeproj -scheme Faden \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:FadenTests CODE_SIGNING_ALLOWED=NO
```

## Lizenz

Apache-2.0. Siehe [LICENSE](LICENSE). Copyright 2026 Christoph Lindl-Guk.

Freizügig, kein Copyleft: Faden läuft auf deinem Telefon und spricht mit Endpoints, die
dir gehören — es gibt hier nichts, was jemand zu einem geschlossenen gehosteten Dienst
machen könnte. Apache-2.0 statt MIT wegen der ausdrücklichen Patentlizenz.
