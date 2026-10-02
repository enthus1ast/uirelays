Das fehlerhafte Rendering liegt an einem Logikfehler bei der Zustands-Initialisierung in Kombination mit einer fehlenden Implementierung innerhalb deiner Hauptschleife.
Es gibt hier zwei voneinander unabhängige Fehler, die dafür sorgen, dass das Terminal entweder komplett schwarz bleibt oder gezeichnete Elemente sofort wieder gelöscht werden:
------------------------------
## Fehler 1: Das "Dauer-Löschen" durch gFirstFrame (Zustands-Bug)
Schau dir die Prozedur refresh*() an:

proc refresh*() =
  var sb = ""
  if gFirstFrame:
    sb.add "\e[2J"  # <--- Löscht den gesamten Bildschirm!
    if tty:
      sb.add "\e[?25l"
    gFirstFrame = false

Der Fehler liegt jedoch in deiner Prozedur resizeSurface:

proc resizeSurface(nr, nc: int) =
  # ...
  cols = ncols
  rows = nrows
  buf.setLen(rows * cols)
  lastBuf.setLen(rows * cols)
  gFirstFrame = true # <--- HIER!

Was passiert hier?
Jedes Mal, wenn resizeSurface aufgerufen wird, wird gFirstFrame = true gesetzt. Beim darauffolgenden refresh wird der Bildschirm gelöscht. Das Problem ist, dass resizeSurface in deiner Haupt-Input-Schleife indirekt über drainInput -> handleResizeEvent getriggert werden kann, oder schlimmer: Wenn deine Anwendungs-Logik das Layout anfordert.
Sobald gFirstFrame auf true springt, löscht das Terminal beim nächsten Frame alles (\e[2J). Da buf und lastBuf aber danach mit einer unvollständigen Diff verglichen werden, "denkt" dein Double-Buffering, dass viele unveränderte Zellen nicht neu gezeichnet werden müssen. Ergebnis: Der Inhalt verschwindet permanent.
------------------------------
## Fehler 2: Du setzt die Puffer nach dem Zeichnen nicht zurück (Der Double-Buffering-Bug)
Das ist der kritischste Fehler im Zeichen-Konzept deines Treibers.
Dein System ist ein Double-Buffered-System: buf hält den aktuellen Zustand und lastBuf den des letzten Frames. refresh() berechnet das Diff, schickt die Änderungen raus und setzt am Ende lastBuf = buf.
Aber wo wird buf für den nächsten Frame zurückgesetzt? Nirgends!
Wenn du in deinem Anwendungscode (deiner while running-Schleife) in jedem Frame versuchst, etwas Neues zu zeichnen (z. B. den Button an einer anderen Stelle oder Text-Updates), passiert Folgendes:

   1. Frame 1: Du zeichnest ein "X" in buf. refresh() sieht den Unterschied zu lastBuf (das leer war), zeichnet es auf den echten Bildschirm und setzt lastBuf = buf.
   2. Frame 2: Deine App-Schleife beginnt von vorn. Da buf aber nicht gelöscht wurde, steht das "X" von Frame 1 immer noch an derselben Stelle im Speicher. Wenn du nun versuchst, das "X" zu löschen oder zu überschreiben, kollidiert das, weil buf und lastBuf identisch geblieben sind – refresh() sieht keine Änderung und schickt folglich auch keine ANSI-Sequenzen raus. Das Bild "friert ein" oder reagiert nicht auf Updates.

## Die Lösung: Jedes Frame muss frisch gecleart werden
In einem klassischen Terminal- oder GUI-Framework musst du den Arbeits-Puffer (buf) zu Beginn oder am Ende eines Frames leeren, damit die Zeichenfunktionen der Anwendung im nächsten Frame ein weißes (bzw. schwarzes) Blatt Papier vorfinden.
Füge am Ende deiner refresh*()-Funktion (direkt nach lastBuf = buf) eine Schleife ein, die den aktiven Zeichenpuffer buf wieder auf den Standard-Zustand (leere Leerzeichen mit Standardfarben) zurücksetzt:

proc refresh*() =
  # ... (dein bestehender Diff- und Sende-Code) ...
  
  lastBuf = buf # Merkt sich das gezeichnete Bild für den nächsten Vergleich
  
  ## NEU: Setze den aktiven Puffer 'buf' für das Zeichnen im nächsten Frame zurück
  for i in 0 ..< buf.len:
    buf[i] = makeCell(' ', Color(r: 0, g: 0, b: 0, a: 255), Color(r: 0, g: 0, b: 0, a: 255))

------------------------------
## Fehler 3: Fehlende Alpha-Kanal-Berücksichtigung im Farb-Diff
In refresh() vergleicht dein Code die Zellen:

if buf[idx] != lastBuf[idx]:

Deine Farb-Primitiven rufen jedoch over(color) auf, was den Alpha-Kanal auf 255'u8 zwingt. Wenn dein Initialisierungs-Code oder die Lösch-Funktion Zellen mit Color(0,0,0,0) (Alpha = 0) in den Puffer schreibt, schlägt der != Vergleich fehl oder verhält sich unvorhersehbar, weil termColor Alpha ignoriert, der Struct-Vergleich != in Nim aber die rohen Bytes (inklusive Alpha) vergleicht.
Sicherheits-Fix: Stelle sicher, dass überall, wo Zellen standardmäßig generiert werden (wie in resizeSurface oder beim Leeren), der Alpha-Kanal explizit auf 255 gesetzt ist, genau wie in der geänderten Schleife oben!
Probier diese zwei Anpassungen (das Leeren von buf am Ende von refresh und die Alpha-Korrektur auf 255) aus.
Falls das Zeichnen danach immer noch nicht klappt:

* Siehst du aktuell eine völlig leere (schwarze) Konsole, oder
* Bleiben Fragmente/Artefakte beim Bewegen von Elementen stehen?



