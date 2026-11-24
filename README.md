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

## Vereisten

- Python 3.10 of nieuwer (alleen standaardbibliotheek)
- Ghostscript (`gs`, op Windows `gswin64c`)
  - macOS: `brew install ghostscript`
  - Debian/Ubuntu: `sudo apt install ghostscript`

## Gebruik

```bash
./convertpdf.py "/pad/naar/map"
./convertpdf.py "/pad/naar/map" --timeout 600   # max. seconden per bestand (standaard 300)
```

Exit codes: `0` alles gelukt, `1` minstens één bestand mislukt of een fout vooraf,
`2` ongeldige argumenten, `130` afgebroken met Ctrl+C.

## PowerShell-versie

`ConvertPdf.ps1` doet hetzelfde en werkt met Windows PowerShell 5.1 en PowerShell 7
(Windows, macOS, Linux). Python is dan niet nodig.

```powershell
.\ConvertPdf.ps1 -Path 'C:\Scans'
.\ConvertPdf.ps1 -Path 'C:\Scans' -TimeoutSeconds 600
.\ConvertPdf.ps1 -Path 'C:\Scans' -GhostscriptPath 'C:\Tools\gs\bin\gswin64c.exe'
Get-Help .\ConvertPdf.ps1 -Detailed
```

Ghostscript wordt gezocht in `PATH` en daarna in `C:\Program Files\gs\<versie>\bin`, waar de
Windows-installer het neerzet. Met `-GhostscriptPath` geef je zelf een pad op.

Exit codes: `0` alles gelukt, `1` minstens één bestand mislukt of een fout vooraf, `2` geen map
opgegeven.

**Execution policy:** Windows blokkeert gedownloade scripts. Bekijk het script en deblokkeer
het daarna eenmalig met `Unblock-File .\ConvertPdf.ps1`. Zet de execution policy liever niet
op `Bypass` of `Unrestricted`.

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
