# Joule

Zeigt, wofür der Akku dieses MacBooks draufgeht – live, im Verlauf und pro App – und meldet sich, wenn etwas aus dem Ruder läuft.

## Was gemessen wird

| Größe | Quelle | Genauigkeit |
|---|---|---|
| Leistung des ganzen Macs | `AppleSmartBattery` → `PowerTelemetryData.SystemLoad`, alle 10 s | direkt gemessen (inkl. Display) |
| Energie pro Prozess | `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj`, jede Minute (live alle 3 s) | direkt gemessen, nur Prozessor |
| GPU-Zeit pro App | `IOAccelerator`-Clients, `accumulatedGPUTime` | gemessen (Zeit, nicht Energie) |
| CPU-Zeit fremder Prozesse (WindowServer …) | `/bin/ps` (von macOS mit Root-Rechten ausgestattet), Energie = CPU-Zeit × J pro CPU-Sekunde der messbaren Prozesse | geschätzt, markiert mit ≈
| Zuordnung Helfer → App | äußerstes `.app`-Bundle, sonst „verantwortlicher Prozess“ (wie Aktivitätsanzeige) | z. B. WebKit-Prozesse → Safari |
| Ruhezustand-Blocker | `IOPMCopyAssertionsByProcess` | exakt |
| Display & Hardware | Gesamtleistung minus gemessene Prozesse | berechneter Rest |

kernel_task ist auch über ps nicht sichtbar und landet im Rest „Display & Hardware“. CPU-Zeiten aus `rusage` sind Mach-Ticks und werden in Nanosekunden umgerechnet.

## Warnungen

App zieht dauerhaft viel (Vordergrund / Hintergrund), hoher Gesamtverbrauch, etwas hält den Mac wach, Akkuverlust im Ruhezustand, optional niedriger Akku. Schwellen, Abklingzeit und stummgeschaltete Apps in den Einstellungen (⌘,).

## Bauen

Braucht nur die Command Line Tools (kein Xcode):

```bash
./scripts/install.sh            # prüfen, bauen, nach /Applications installieren bzw. aktualisieren
./scripts/install.sh --login    # dasselbe und Autostart einschalten
./scripts/check.sh              # nur die Prüfungen des Messkerns
open -n .build/Joule.app --args --demo        # zwei Wochen Beispieldaten, zeichnet nichts auf
/Applications/Joule.app/Contents/MacOS/Joule --probe   # eine Messung im Terminal
```

Ein Update behält Verlauf, Einstellungen und Autostart; Joule wird dabei kurz beendet und neu gestartet (es fehlt höchstens die laufende Minute).

Daten: `~/Library/Application Support/Joule/history.sqlite` (Minutenwerte 7 Tage, Stundenwerte 90 Tage).
