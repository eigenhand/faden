# Sicherheit

*[English](SECURITY.md) · Deutsch*

## Lücken melden

Sicherheitsprobleme bitte **nicht** als öffentliches Issue, sondern per E-Mail an
<christoph.lindl-guk@pm.me>. Ich antworte, so schnell ich kann – dies ist ein
Freizeitprojekt ohne zugesagte Reaktionszeiten.

## Was das Gerät verlässt

Faden bringt keine Infrastruktur mit. Es gibt keinen Server von mir, keine Telemetrie
und kein Konto. Was hinausgeht, geht an Endpoints, die der Nutzer selbst eingetragen
hat:

Jede Zeile unterhalb der ersten setzt einen Dienst voraus, den der Nutzer in den
Einstellungen verbunden hat — einen Suchanbieter, ein Einbettungsmodell, Fundus, einen
Ordner. Nicht verbunden heißt: das Werkzeug steht gar nicht in der Anfrage, das Modell
kann also weder danach greifen noch dazu überredet werden. Immer dabei ist nur
`remember`, das nichts erreicht: Es schreibt eine Notiz in das Gespräch, zu dem es
ohnehin gehört.

| Wohin | Was | Wann |
| --- | --- | --- |
| Modell-Endpoint | Der ganze Gesprächsverlauf, Bilder, Werkzeugergebnisse | Bei jedem Zug |
| Suchanbieter | Die Suchanfrage | Wenn das Modell sucht |
| Beliebige Webseiten | Nichts ausser einem Seitenabruf | Wenn das Modell eine Seite lädt |
| Einbettungs-Endpoint | Text, aus dem Erinnerungen werden | Wenn das Gedächtnis an ist |
| Modell-Endpoint | Einträge aus dem Fundus-Bestand | Wenn das Modell im Bestand nachsieht |
| Modell-Endpoint | Namen und Inhalte von Dateien aus dem freigegebenen Ordner | Wenn das Modell im Ordner nachsieht |
| Nirgendwohin | Der geparste Text der Dokumente | Bleibt in einem lokalen Index in Application Support |

Der Bestand ist das Einzige, was Faden liest und nicht selbst erzeugt hat. Er bleibt
auf dem Gerät, bis das Modell danach greift, und hinaus gehen dann die Einträge, die
gepasst haben — nicht der ganze Bestand. Nichts davon geht irgendwohin, bevor Fundus in den
Einstellungen verbunden ist; unverbunden wird das Werkzeug gar nicht erst angeboten.

Alles andere – Verlauf, Einstellungen, Erinnerungen – liegt in Application Support auf
dem Gerät.

## Schlüssel

API-Schlüssel liegen im **Schlüsselbund des Geräts**, nie in den Einstellungen und nie
in einer Datei, die beim Teilen mitgeht. Ein Anbietereintrag verweist nur auf den
Schlüsselbund-Eintrag.

Bis September 2026 trugen die TestFlight-Builds einen Schlüssel im Binary, damit
Tester sofort loslegen konnten. Das war eine bewusste Abwägung und ist keine mehr:
Ein Schlüssel im ausgelieferten Binary ist für jeden lesbar, der das Binary hat.
Seitdem bringt die App keinen Anbieter mehr mit. Ein versionierter `pre-commit`-Haken
schlägt an, wenn etwas, das nach einem Schlüssel aussieht, in einen Commit gerät.

## Die Bauart, um die es geht

Ein Assistent mit Werkzeugen liest fremden Text und kann handeln. Für ein
Sprachmodell ist beides erst einmal dasselbe: Text. Daraus folgt der grösste Teil
dessen, was hier steht.

**Fremde Inhalte sind eingefasst.** Was `web_search` und `fetch_page` zurückgeben,
steht zwischen Marken mit einer je Aufruf gewürfelten Kennung, und die
Systemanweisung sagt, was darin gilt: Material, keine Anweisung. Ohne die Würfelung
wäre es Dekoration – eine präparierte Seite schriebe die Schlussmarke hin und danach
ihre Anweisungen, die dann scheinbar ausserhalb stünden. Was im Text selbst wie eine
Marke aussieht, wird vorher entfernt.

Der Anlass ist konkret: Faden hat ein Werkzeug `remember`, dessen Notizen das
Verdichten des Kontexts wörtlich überleben. Ohne Einfassung könnte eine Seite dem
Modell einen dauerhaften Eintrag im Gedächtnis des Nutzers diktieren.

**Werkzeuge laden nur öffentliche Seiten.** Die Adresse für `fetch_page` wählt das
Modell, nach dem, was in einem Suchergebnis stand – das ist eine Eingabe von aussen.
Geprüft werden die Adresse und **jede Weiterleitung**: draussen bleiben das Gerät
selbst, die privaten Bereiche, link-local samt `169.254.169.254`, Carrier-NAT,
Multicast, Reserviertes, die Namen `localhost`, `.local`, `.lan`, `.internal`,
`.home`, und alles ausser http und https. Ohne die Prüfung der Weiterleitung wäre das
ein Türsteher, der nur den ersten Gast anschaut.

**Geteilte Unterhaltungen werden entschärft.** Eine `.faden`-Datei wird beim
Übernehmen zur eigenen Vorgeschichte und geht ab dann bei jedem Zug mit. Entfernt
werden dabei: das Kennzeichen „Zusammenfassung" (die Systemanweisung erklärt
Zusammenfassungen für massgeblich – eine fremde Datei darf das über ihren eigenen
Inhalt nicht entscheiden), Gedankengänge (unsichtbar, wirkungslos wenn echt, und die
überzeugendste Stimme im Verlauf wenn gefälscht) und unvollständige Werkzeugschritte.
Dazu Obergrenzen für Dateigrösse und Nachrichtenzahl. Was entfernt wurde, wird
gesagt.

## Bewusste Kompromisse

Diese Punkte sind keine Versehen, sondern Abwägungen.

**Der eigene Endpoint ist vertrauenswürdig.** Wer eine Adresse und einen Schlüssel
einträgt, sagt damit: dorthin darf mein ganzer Verlauf. Faden prüft nicht, was dort
mit den Daten geschieht, und kann es nicht.

**Der Suchanbieter darf im eigenen Netz liegen.** Für `fetch_page` ist das gesperrt,
für die Suche nicht – ein selbst betriebenes SearXNG im Heimnetz ist ein legitimer
Aufbau und einer der mitgelieferten Vorschläge. Der Unterschied ist, wer die Adresse
wählt: bei der Suche der Nutzer, bei `fetch_page` das Modell.

**Ein Name, der auf eine private Adresse zeigt, kommt durch.** Geprüft wird die
geschriebene Adresse. Ein öffentlich aussehender Name, den ein Angreifer auf
`192.168.…` auflösen lässt, umgeht die Prüfung. Dagegen hülfe nur ein eigener
Namensauflöser, der prüft und dann genau die geprüfte Adresse verwendet – sonst bleibt
zwischen Prüfung und Verbindung ein Spalt. Das wäre eine eigene Netzwerkschicht.

**Die Einfassung ist eine Bitte, keine Schranke.** Ob das Modell sich daran hält,
kann keine Zeile Code erzwingen. Gegen ein Modell, das sich überreden lässt, hilft am
Ende nur, ihm keine gefährlichen Werkzeuge zu geben – und die gefährlichsten hat
Faden nicht: es schreibt keine Dateien, verschickt nichts und kauft nichts. Das
Schlimmste, was ein erfolgreicher Angriff erreicht, ist ein falscher Eintrag im
Gedächtnis oder eine falsche Auskunft.

**Ein Ordner ist so vertrauenswürdig wie sein Inhalt.** Das Werkzeug `files` liest,
worauf der Nutzer es gerichtet hat, und ein synchronisierter Ordner enthält, was der
Server enthält — auch das, was jemand anderes über eine von Spinds Freigaben
hineingelegt hat. Alles daraus wird eingefasst, die Auflistung eingeschlossen, denn auch
ein Dateiname ist vom Angreifer gewählt. Das bringt den Unterschied zwischen ein
Dokument lesen und ihm folgen; eine Garantie ist es nicht, aus dem Grund im Absatz
darüber. Klein bleibt die Folge dadurch, dass das Werkzeug nicht schreiben kann: Das
Schlimmste, was ein präpariertes Dokument erreicht, ist eine falsche Auskunft über eine
andere Datei.

**Ein Dokument wird geparst, und Parsen ist Angriffsfläche.** Eine `.docx` zu lesen
heißt, ein ZIP nach Offsets abzulaufen und einen XML-Baum zu lesen, den jemand anderes
geschrieben hat. Größen werden gedeckelt, bevor irgendetwas entpackt wird — ein kleines
Archiv darf jede beliebige entpackte Größe behaupten —, der Container-Leser weist
zurück, was er nicht versteht, statt zu raten, und das XML geht durch Apples
`XMLParser` statt durch einen regulären Ausdruck über das Markup. Was herauskommt, ist
eingefasst wie jede andere Datei. Handeln kann es nicht: Das Werkzeug liest.

**Ein Pfad wird eingesperrt, nicht bereinigt.** `..`, absolute Pfade und Symlinks, die
aus dem Ordner herausführen, werden abgewiesen, und jeder Weg hinaus bekommt denselben
Satz — damit die Abweisungen keine Karte der Grenze sind. Innerhalb des Ordners gibt es
keine weitere Einschränkung: Wer den Ordner lesen darf, darf ihn ganz lesen.

**Kein Schutz gegen ein bösartiges Modell.** Der Endpoint bekommt den ganzen Verlauf
und antwortet frei. Wer einen Endpoint einträgt, dem er nicht traut, hat ein anderes
Problem als diese App.

## Was geprüft ist

Die Massnahmen oben haben Tests, und die Tests prüfen den mechanischen Teil: dass die
Grenze steht, dass eine gefälschte Marke sie nicht öffnet und nicht schliesst, dass
`192.168.example.com` als gewöhnliche Domain durchkommt und `::ffff:192.168.0.1`
nicht, dass ein vollständiges Werkzeugpaar den Import unbeschadet übersteht. Sie
laufen bei jedem Push.

Was sie nicht prüfen, steht oben unter „Bewusste Kompromisse".
