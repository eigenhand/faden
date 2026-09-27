# Faden

*[English](README.md) · Deutsch*

[![Tests](https://github.com/eigenhand/faden/actions/workflows/tests.yml/badge.svg)](https://github.com/eigenhand/faden/actions/workflows/tests.yml)

Ein KI-Chat-Client fürs iPhone, der nur die Oberfläche mitbringt. Modell, Endpoint,
API-Schlüssel und Suchanbieter kommen von dir. Keine Zwischenserver, keine Konten,
keine Telemetrie — die App spricht ausschließlich mit den Adressen, die du einträgst.

Was die App schützt und was nicht: [SECURITY.de.md](SECURITY.de.md). Wie sie gebaut
ist: [ARCHITECTURE.de.md](ARCHITECTURE.de.md). Ein Assistent mit Werkzeugen liest
fremden Text und kann handeln — [„Bewusste Kompromisse“](SECURITY.de.md#bewusste-kompromisse)
sagt, wo die Schutzmaßnahmen enden.

## Stand und Voraussetzungen

- **Stand:** Version 1.0, ein Freizeitprojekt in aktiver Entwicklung. Noch nicht im
  App Store — du baust es aus dem Quellcode.
- **Gerät:** iPhone mit iOS 17 oder neuer; Apples Modell auf dem Gerät braucht iOS 26
  und Apple Intelligence.
- **Werkzeuge zum Bauen:** Xcode (getestet mit 26.6, wie in der CI) und
  [XcodeGen](https://github.com/yonaskolb/XcodeGen). Sonst keine Abhängigkeiten.
- **Sprachen:** Deutsch und Englisch.

## Was du zum Benutzen brauchst

Mindestens ein Chat-Modell:

- **Ein API-Schlüssel** für die Anthropic-API oder einen OpenAI-kompatiblen Dienst.
  Voreinstellungen für OpenAI, Anthropic, OpenRouter, Groq, Cerebras, Mistral,
  DeepSeek, xAI, Together, Fireworks und TensorX; jeden anderen Endpoint trägst du von
  Hand ein.
- **Ein eigener Server**, der das OpenAI-Format spricht, etwa Ollama, vLLM oder LM
  Studio. Der Schlüssel ist optional. Im Heimnetz funktioniert einfaches `http://` mit
  einer IP-Adresse oder einem `.local`-Namen; alles andere braucht `https://`.
- **Apples Modell auf dem Gerät** — kein Endpoint, kein Schlüssel, nichts verlässt das
  Telefon, dafür keine Werkzeuge, keine Bilder und ein kleines Kontextfenster.

Optional: ein Suchanbieter, eigene Sprach-Endpoints und Einbettungen für das
Gedächtnis — von einem eigenen OpenAI-kompatiblen Einbettungs-Endpoint (die
Voreinstellung, genauer) oder direkt auf dem iPhone mit Apples eingebautem Einbettungsmodell berechnet, ganz
ohne Endpoint.

## Was dein Telefon verlässt

Nur, was an die Dienste geht, die du eingetragen hast:

- **Modell-Endpoint:** die Unterhaltung, Bilder, Werkzeugergebnisse — auch Einträge
  aus dem Bestand und Inhalte aus dem Ordner, die das Modell nachschlägt.
- **Suchanbieter:** die Suchanfrage. **Webseiten:** ein einfacher Seitenabruf.
- **Einbettungs-Endpoint:** Text, der zur Erinnerung wird — nur, wenn du ihn statt
  der Einbettungen auf dem Gerät wählst.
- **Sprach-Endpoints:** deine Aufnahme und der vorzulesende Text, falls eingerichtet.

Verlauf, Einstellungen, Erinnerungen und der Dokumentindex bleiben auf dem Gerät;
API-Schlüssel bleiben im Schlüsselbund. Vollständige Tabelle:
[SECURITY.de.md](SECURITY.de.md#was-das-gerät-verlässt).

## Funktionen

- **Eigenes Modell.** Anthropic- und OpenAI-kompatible APIs, mit Streaming,
  Werkzeugaufrufen und Gedankengang.
- **Eigene Websuche.** Fertige Rezepte für Brave, Tavily, Serper, SearXNG und Exa; für
  jeden anderen Anbieter schreibt eines deiner Modelle einmalig einen Parser.
- **Agentisch.** Der Assistent sucht, wenn es nötig ist, lädt Webseiten und merkt sich,
  was zählt.
- **Bilder.** Ob ein Modell sehen kann, misst der Verbindungstest, statt zu raten.
- **Modelle und Grenzen.** Die Modellliste kommt vom Endpoint; Kontext und
  Antwortlänge folgen dem Anbieter oder deinen Reglern.
- **Sprechen und Hören.** Diktieren über Apple oder deinen eigenen Whisper-Endpoint;
  Antworten liest dein Sprachdienst vor oder die Stimme des iPhones.
- **Gedächtnis.** Ein Wissensgraph aus deinen Gesprächen, portiert von
  [cognee](https://github.com/topoteretes/cognee), gespeichert auf dem Gerät,
  einsehbar und Eintrag für Eintrag löschbar. Einbettungen auf dem iPhone oder von
  deinem Endpoint.
- **Deine Stimme.** Anrede, Ausführlichkeit und Ton legst du fest.
- **Antworten sagen, wer sie geschrieben hat**, wenn mehr als ein Modell im Spiel ist.
- **Nachbessern.** Kopieren, neu holen, kürzer, ausführlicher; per langem Druck
  zitieren; eine Frage bearbeiten und neu stellen.
- **Barrierefrei.** Text skaliert bis zur größten Stufe; VoiceOver sagt an, was
  passiert, nicht jedes Token.
- **Lange Unterhaltungen.** Eine Haarlinie zeigt, wie voll der Kontext ist; ab 75 %
  (einstellbar) wird der ältere Verlauf im Hintergrund zusammengefasst.

**Optionale Anbindungen**, nur lesend und erst nach dem Verbinden angeboten:

- **[Fundus](https://github.com/eigenhand/fundus)**, eine Inventar-App fürs iPhone:
  Der Assistent kann nachsehen, wo etwas liegt und wie viel noch da ist.
- **Ein Ordner in der Dateien-App** — iCloud Drive oder etwa eine Hetzner Storage Box,
  eingebunden über [Spind](https://github.com/eigenhand/spind). Der Assistent listet,
  findet und liest Dateien und durchsucht PDFs (auch gescannte), Office-, iWork-,
  OpenDocument-, EPUB-, RTF-, HTML-, Text- und Quelldateien — mit Angabe von Dokument
  und Seite.

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
