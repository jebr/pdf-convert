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

CI draait lint, mypy, Bandit, pip-audit en de tests (Linux en macOS, Python 3.10 t/m 3.13,
met echte Ghostscript). CodeQL scant wekelijks en bij elke pull request.
