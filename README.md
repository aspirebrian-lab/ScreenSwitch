# ScreenSwitch

Een kleine macOS-menubalk-app die het "eerste klik focust alleen"-gedrag van macOS oplost.
Klik je op een venster van een andere app, dan wordt die klik meteen ook uitgevoerd, zoals op Windows.

## Installeren

**Via de installer (aanbevolen)**
1. Download de nieuwste `ScreenSwitch-x.y.z.dmg` onder [Releases](../../releases).
2. Open de DMG en sleep ScreenSwitch naar Programma's.
3. Start de app en geef toestemming onder Systeeminstellingen → Privacy en beveiliging → Toegankelijkheid.

> Is de DMG niet genotariseerd, dan toont macOS een waarschuwing. Open de app dan eenmalig
> via rechtsklik → Open.

**Vanuit de broncode** (Xcode Command Line Tools nodig)
```bash
git clone <deze-repo>
cd ScreenSwitch
./build.sh        # bouwt en installeert in /Applications
```

## Een installer maken
```bash
VERSION=1.0.0 ./package.sh
```
Het resultaat staat in `dist/`. Voor een DMG zonder Gatekeeper-waarschuwing is een
Developer ID-certificaat en notarisatie nodig, zie de uitleg bovenaan [package.sh](package.sh).

## Instellingen
Klik op het icoon in de menubalk → **Settings…** om met een slider de vertraging (0–500 ms)
voor de tweede klik in te stellen. Standaard is 120 ms.

## Starten bij inloggen
Systeeminstellingen → Algemeen → Inloggen en toevoegen → **+** → ScreenSwitch.

## Hoe het werkt
Een event tap volgt linkermuisklikken. Hoort het venster onder de cursor bij een niet-actieve app,
dan laat ScreenSwitch die klik door (macOS focust) en stuurt ~0,12 s later dezelfde klik opnieuw.
Slepen wordt overgeslagen.
