#!/usr/bin/env python3
"""Zet alle PDF's in een map opnieuw om via Ghostscript (pdfwrite).

Per bestand:
  1. Ghostscript schrijft naar een tijdelijk bestand in dezelfde map.
  2. Het origineel wordt hernoemd naar ``original_<naam>``.
  3. Het tijdelijke bestand krijgt de originele naam.

Gaat stap 3 mis, dan wordt stap 2 teruggedraaid. Het origineel blijft
dus altijd bewaard.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

ORIGINAL_PREFIX = "original_"
TEMP_PREFIX = ".pdfconvert-"
DEFAULT_TIMEOUT = 300  # seconden per bestand


class ConvertError(Exception):
    """Fout bij het omzetten van een enkel bestand."""


def find_ghostscript() -> str | None:
    """Geef het volledige pad naar Ghostscript terug, of None."""
    for name in ("gs", "gswin64c", "gswin32c"):
        path = shutil.which(name)
        if path:
            return path
    return None


def find_pdfs(folder: Path) -> list[Path]:
    """Zoek PDF's die nog niet verwerkt zijn.

    Overgeslagen worden: submappen, symlinks (voorkomt verwerken van
    bestanden buiten de map), verborgen bestanden (o.a. eigen tijdelijke
    bestanden) en bestanden die al met ``original_`` beginnen.
    """
    return sorted(
        p
        for p in folder.iterdir()
        if p.suffix.lower() == ".pdf"
        and not p.is_symlink()
        and p.is_file()
        and not p.name.startswith((ORIGINAL_PREFIX, "."))
    )


def build_command(gs: str, source: Path, target: Path) -> list[str]:
    """Bouw het Ghostscript-commando. Paden moeten absoluut zijn."""
    return [
        gs,
        "-dSAFER",
        "-dBATCH",
        "-dNOPAUSE",
        "-dQUIET",
        "-sDEVICE=pdfwrite",
        "-dCompatibilityLevel=1.7",
        "-dAutoRotatePages=/None",
        # '%' in de uitvoernaam is voor Ghostscript een opmaakteken
        f"-sOutputFile={str(target).replace('%', '%%')}",
        # Absoluut pad, zodat een bestandsnaam als '-x.pdf' nooit als optie telt
        str(source),
    ]


def convert_file(gs: str, pdf: Path, timeout: int = DEFAULT_TIMEOUT) -> Path:
    """Zet één PDF om. Geeft het pad van het bewaarde origineel terug."""
    pdf = pdf.resolve()
    original = pdf.with_name(ORIGINAL_PREFIX + pdf.name)
    if original.exists():
        raise ConvertError(f"'{original.name}' bestaat al, overgeslagen.")

    fd, tmp_name = tempfile.mkstemp(dir=pdf.parent, prefix=TEMP_PREFIX, suffix=".tmp")
    os.close(fd)
    temp_pdf = Path(tmp_name)

    try:
        try:
            subprocess.run(
                build_command(gs, pdf, temp_pdf),
                check=True,
                timeout=timeout,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
            )
        except subprocess.TimeoutExpired as exc:
            raise ConvertError(f"time-out na {timeout} s.") from exc
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or "").strip().splitlines()
            msg = f"Ghostscript exit code {exc.returncode}"
            if detail:
                msg += f": {detail[-1]}"
            raise ConvertError(msg) from exc

        if temp_pdf.stat().st_size == 0:
            raise ConvertError("Ghostscript leverde een leeg bestand op.")

        shutil.copymode(pdf, temp_pdf)

        pdf.rename(original)
        try:
            os.replace(temp_pdf, pdf)
        except BaseException as exc:  # ook bij Ctrl+C het origineel terugzetten
            original.rename(pdf)
            if isinstance(exc, OSError):
                raise ConvertError(f"kon nieuw bestand niet plaatsen: {exc}") from exc
            raise
    finally:
        temp_pdf.unlink(missing_ok=True)

    return original


def convert_folder(folder: Path, gs: str, timeout: int = DEFAULT_TIMEOUT) -> int:
    """Verwerk alle PDF's in de map. Geeft het aantal mislukte bestanden terug."""
    pdfs = find_pdfs(folder)
    if not pdfs:
        print("Geen nieuwe PDF's gevonden om om te zetten.")
        return 0

    failed = 0
    for pdf in pdfs:
        print(f"Omzetten: {pdf.name}")
        try:
            original = convert_file(gs, pdf, timeout=timeout)
        except ConvertError as exc:
            failed += 1
            print(f"Mislukt bij '{pdf.name}': {exc} Origineel is niet aangepast.", file=sys.stderr)
            continue
        print(f"Klaar: '{original.name}' (origineel) en '{pdf.name}' (nieuw).")

    done = len(pdfs) - failed
    print(f"Afgerond: {done} omgezet, {failed} mislukt.")
    return failed


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="convertpdf.py",
        description="Zet alle PDF's in een map opnieuw om met Ghostscript. "
        "Originelen blijven bewaard als original_<naam>.",
    )
    parser.add_argument("folder", type=Path, help="map met PDF-bestanden")
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"maximale tijd per bestand in seconden (standaard {DEFAULT_TIMEOUT})",
    )
    args = parser.parse_args(argv)
    if args.timeout <= 0:
        parser.error("--timeout moet groter dan 0 zijn")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    folder: Path = args.folder.expanduser().resolve()

    if not folder.is_dir():
        print(f"Fout: '{folder}' is geen bestaande map.", file=sys.stderr)
        return 1

    gs = find_ghostscript()
    if gs is None:
        print("Fout: Ghostscript ('gs') staat niet in je PATH.", file=sys.stderr)
        return 1

    try:
        failed = convert_folder(folder, gs, timeout=args.timeout)
    except KeyboardInterrupt:
        print("\nAfgebroken door gebruiker.", file=sys.stderr)
        return 130
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
