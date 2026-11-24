# pdf-convert

Zet alle PDF's in een map opnieuw om met Ghostscript (`pdfwrite`, PDF 1.7). Handig om
afwijkende of slecht opgebouwde PDF's te normaliseren. Het origineel blijft altijd bewaard.

## Wat het doet

Voor elke `*.pdf` in de opgegeven map:

1. Ghostscript schrijft het resultaat naar een tijdelijk bestand in dezelfde map.
2. Het origineel wordt hernoemd naar `original_<naam>.pdf`.
3. Het nieuwe bestand krijgt de originele naam.

Mislukt de omzetting, dan blijft het origineel ongewijzigd staan en gaat het script door met
het volgende bestand. Overgeslagen worden: submappen, symlinks, verborgen bestanden,
bestanden die al met `original_` beginnen en PDF's waarvoor al een `original_` bestaat.

Er zijn twee versies met dezelfde werking. Kies er een:

| Versie | Bestand | Geschikt voor |
| --- | --- | --- |
| Python | `convertpdf.py` | macOS en Linux (werkt ook op Windows met Python) |
| PowerShell | `ConvertPdf.ps1` | Windows zonder Python (Windows PowerShell 5.1 of PowerShell 7) |

## Ghostscript installeren

Beide versies hebben Ghostscript nodig.

- **Windows:** download de installer van
  [ghostscript.com/releases](https://ghostscript.com/releases/gsdnld.html) (64-bit), of gebruik
  `choco install ghostscript`. Het PowerShell-script vindt Ghostscript daarna vanzelf.
- **macOS:** `brew install ghostscript`
- **Debian/Ubuntu:** `sudo apt install ghostscript`

## Gebruik met Python

Vereist Python 3.10 of nieuwer. Er zijn geen extra pakketten nodig.

```bash
./convertpdf.py "/pad/naar/map"
./convertpdf.py "/pad/naar/map" --timeout 600   # max. seconden per bestand (standaard 300)
./convertpdf.py --help
```

Exit codes: `0` alles gelukt, `1` minstens één bestand mislukt of een fout vooraf,
`2` ongeldige argumenten, `130` afgebroken met Ctrl+C.

## Gebruik met PowerShell

Werkt met Windows PowerShell 5.1 (standaard op Windows 10 en 11) en met PowerShell 7 op
Windows, macOS en Linux. Python is niet nodig.

### Eenmalig instellen (Windows)

1. Installeer Ghostscript (zie hierboven).
2. Download `ConvertPdf.ps1` en zet het in een vaste map, bijvoorbeeld `C:\Tools`.
3. Open PowerShell en sta lokale scripts toe voor je eigen account. Gedownloade scripts
   blijven dan geblokkeerd tot je ze zelf vrijgeeft:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```

4. Bekijk het script en geef het daarna vrij:

   ```powershell
   Unblock-File C:\Tools\ConvertPdf.ps1
   ```

Zet de execution policy liever niet op `Bypass` of `Unrestricted`.

### Script uitvoeren

```powershell
C:\Tools\ConvertPdf.ps1 -Path 'C:\Scans'
```

Of vanuit de map waar het script staat:

```powershell
cd C:\Tools
.\ConvertPdf.ps1 -Path 'C:\Scans'
```

Zet een pad met spaties tussen aanhalingstekens, bijvoorbeeld `-Path 'C:\Mijn scans'`.

Voorbeeld van de uitvoer:

```text
Omzetten: factuur.pdf
Klaar: 'original_factuur.pdf' (origineel) en 'factuur.pdf' (nieuw).
Afgerond: 1 omgezet, 0 mislukt.
```

### Parameters

| Parameter | Verplicht | Uitleg |
| --- | --- | --- |
| `-Path` | ja | Map met de PDF-bestanden. Mag ook zonder parameternaam: `.\ConvertPdf.ps1 'C:\Scans'` |
| `-TimeoutSeconds` | nee | Maximale tijd per bestand in seconden, standaard `300` |
| `-GhostscriptPath` | nee | Volledig pad naar `gswin64c.exe`, als Ghostscript niet vanzelf gevonden wordt |

Ghostscript wordt gezocht in `PATH` en daarna in `C:\Program Files\gs\<versie>\bin`, waar de
Windows-installer het neerzet. Alle uitleg staat ook in het script zelf:

```powershell
Get-Help C:\Tools\ConvertPdf.ps1 -Detailed
```

### Starten vanuit de opdrachtprompt of Taakplanner

```bat
powershell.exe -NoProfile -File "C:\Tools\ConvertPdf.ps1" -Path "C:\Scans"
```

Gebruik `pwsh.exe` in plaats van `powershell.exe` als je PowerShell 7 hebt.

Exit codes: `0` alles gelukt, `1` minstens één bestand mislukt of een fout vooraf, `2` geen map
opgegeven.

## Beveiliging

- Ghostscript draait met `-dSAFER`, zodat een kwaadaardige PDF geen bestanden kan lezen of
  schrijven buiten de opdracht.
- Geen shell: het commando wordt als argumentenlijst doorgegeven.
- Bestanden worden met hun absolute pad doorgegeven, zodat een bestandsnaam als `-x.pdf`
  nooit als optie wordt gelezen. Een `%` in de uitvoernaam wordt ge-escaped.
- Symlinks worden overgeslagen, zodat er niets buiten de map wordt aangepast.
- Time-out per bestand tegen vastlopende of zeer zware PDF's.
- Houd Ghostscript zelf up-to-date: kwetsbaarheden in Ghostscript zijn de grootste risicofactor
  bij het verwerken van PDF's van onbekende herkomst.

## Ontwikkelen

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest                    # tests (integratietests alleen als Ghostscript aanwezig is)
ruff check . && ruff format --check .
mypy
bandit -c pyproject.toml -r convertpdf.py
```

PowerShell (vereist [Pester 5](https://pester.dev) en PSScriptAnalyzer):

```powershell
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path ./ConvertPdf.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
```

CI draait lint, mypy, Bandit, pip-audit en de tests (Linux en macOS, Python 3.10 t/m 3.13,
met echte Ghostscript). De PowerShell-workflow draait PSScriptAnalyzer en Pester op Windows
PowerShell 5.1, PowerShell 7 op Windows en PowerShell 7 op Linux, ook met echte Ghostscript.
CodeQL scant wekelijks en bij elke pull request.
