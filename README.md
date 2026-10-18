# TempReadingFilter für FHEM

`TempReadingFilter` gibt Temperaturwerte abhängig vom Zustand eines Aktors
weiter. Nach dem Einschalten des Aktors wartet das Modul eine einstellbare Zeit,
bevor es neue Messwerte übernimmt. Bei ausgeschaltetem Aktor kann der letzte
gültige Wert in einem einstellbaren Abstand aufgefrischt werden.

> **Status und Hinweis:** Eigenständiges Community-Modul, kein offizieller
> Bestandteil von FHEM. Das Modul und sein Verzögerungsverhalten wurden
> automatisiert sowie im praktischen FHEM-Betrieb geprüft. Vor der Installation
> eine Sicherung erstellen und das Verhalten an der eigenen Anlage kontrollieren.
> Nutzung in eigener Verantwortung.

Projektinformationen: [153er-netz.de – Entwicklung](https://153er-netz.de/seiten/entwicklung.html)

## Typische Anwendung

Bei einem Heizkreis soll die Rücklauftemperatur erst ausgewertet werden,
nachdem das Ventil einige Minuten geöffnet war. So werden Messwerte aus einer
inaktiven Phase nicht als aktuelle Heizkreistemperatur weitergegeben.

```text
define <Name> TempReadingFilter <Sensor> <Reading> <Aktor> <Aktivzustand>
```

Beispiel:

```text
define OG_Windfang_RL_TF TempReadingFilter OG_Windfang_RL realtemperature OG_Windfang_Ventil_PortB0 on
attr OG_Windfang_RL_TF delay 300
attr OG_Windfang_RL_TF keepAliveInterval 300
```

Die vollständige deutsche und englische Hilfe ist im Modul enthalten und in
FHEM mit `help TempReadingFilter` erreichbar.

## Installation und Updates

Vorher eine aktuelle FHEM-Sicherung anlegen. Die folgenden Befehle einzeln im
FHEM-Kommandoeingabefeld ausführen und jeweils die Rückmeldung abwarten.

```text
update add https://raw.githubusercontent.com/parussel/TempReadingFilter/main/controls_tempreadingfilter.txt
```

Vorschau prüfen:

```text
update check https://raw.githubusercontent.com/parussel/TempReadingFilter/main/controls_tempreadingfilter.txt
```

Nur wenn die Vorschau ausschließlich `FHEM/98_TempReadingFilter.pm` aufführt,
das Update ausführen:

```text
update all https://raw.githubusercontent.com/parussel/TempReadingFilter/main/controls_tempreadingfilter.txt
```

Wenn FHEM anschließend einen Neustart empfiehlt:

```text
shutdown restart
```

Die Steuerdatei enthält nur die Moduldatei. Definitionen, Attribute,
`fhem.cfg`, `fhem.save` und andere Nutzerdaten sind nicht Teil des Updates.
Nach `update add` wird diese Quelle auch bei einem normalen FHEM-Update
berücksichtigt. Mit `update list` lassen sich eingetragene Quellen anzeigen.

Quelle abmelden, ohne die installierte Moduldatei zu löschen:

```text
update delete https://raw.githubusercontent.com/parussel/TempReadingFilter/main/controls_tempreadingfilter.txt
```

## Fehlerkorrektur in Version 1.0.0.7

Wird ein Aktor während der Wartezeit wieder ausgeschaltet, wird der ausstehende
Start verworfen. Ein veralteter Timer kann eine neu begonnene Wartezeit nicht
mehr überspringen.

## Lizenz

GNU General Public License, Version 2 oder – nach eigener Wahl – eine spätere
Version (`GPL-2.0-or-later`). Siehe [LICENSE](LICENSE).
