#!/usr/bin/env python3
"""Zet PDF's opnieuw om via Ghostscript (pdfwrite).

Je kunt losse bestanden en mappen door elkaar opgeven. Van een map worden
alle PDF's direct in die map verwerkt (geen submappen).

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
from dataclasses import dataclass, field
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


@dataclass
class Targets:
    """Resultaat van het verzamelen van te verwerken bestanden."""

    pdfs: list[Path] = field(default_factory=list)
    skipped: int = 0
    missing: int = 0


def skip_reason(path: Path) -> str | None:
    """Reden om een los opgegeven bestand over te slaan, of None."""
    if path.is_symlink():
        return "is een symlink"
    if path.suffix.lower() != ".pdf":
        return "is geen PDF"
    if path.name.startswith(ORIGINAL_PREFIX):
        return "is al een origineel"
    return None


def collect_targets(paths: Sequence[Path]) -> Targets:
    """Verzamel de PDF's uit een mix van bestanden en mappen.

    Volgorde blijft zoals opgegeven; een bestand dat via meerdere paden
    wordt genoemd, wordt maar een keer verwerkt.
    """
    targets = Targets()
    seen: set[Path] = set()

    def add(pdf: Path) -> None:
        key = pdf.resolve()
        if key not in seen:
            seen.add(key)
            targets.pdfs.append(pdf)

    for raw in paths:
        path = raw.expanduser()
        if path.is_dir() and not path.is_symlink():
            for pdf in find_pdfs(path):
                add(pdf)
        elif path.is_file() or path.is_symlink():
            reason = skip_reason(path)
            if reason:
                targets.skipped += 1
                print(f"Overgeslagen: '{path}' {reason}.")
            else:
                add(path)
        else:
            targets.missing += 1
            print(f"Fout: '{path}' bestaat niet.", file=sys.stderr)
    return targets


def convert_paths(paths: Sequence[Path], gs: str, timeout: int = DEFAULT_TIMEOUT) -> int:
    """Verwerk bestanden en mappen. Geeft het aantal fouten terug.

    Mislukte bestanden en niet-bestaande paden tellen als fout,
    overgeslagen bestanden niet.
    """
    targets = collect_targets(paths)
    if not targets.pdfs:
        print("Geen nieuwe PDF's gevonden om om te zetten.")
        return targets.missing

    failed = 0
    for pdf in targets.pdfs:
        print(f"Omzetten: {pdf}")
        try:
            original = convert_file(gs, pdf, timeout=timeout)
        except ConvertError as exc:
            failed += 1
            print(f"Mislukt bij '{pdf}': {exc} Origineel is niet aangepast.", file=sys.stderr)
            continue
        print(f"Klaar: '{original.name}' (origineel) en '{pdf.name}' (nieuw).")

    done = len(targets.pdfs) - failed
    print(
        f"Afgerond: {done} omgezet, {failed + targets.missing} mislukt, "
        f"{targets.skipped} overgeslagen."
    )
    return failed + targets.missing


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="convertpdf.py",
        description="Zet PDF's opnieuw om met Ghostscript. Geef losse bestanden en/of "
        "mappen op. Originelen blijven bewaard als original_<naam>.",
    )
    parser.add_argument(
        "paths",
        nargs="+",
        type=Path,
        metavar="pad",
        help="PDF-bestand of map met PDF-bestanden (meerdere mogelijk)",
    )
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

    gs = find_ghostscript()
    if gs is None:
        print("Fout: Ghostscript ('gs') staat niet in je PATH.", file=sys.stderr)
        return 1

    try:
        failed = convert_paths(args.paths, gs, timeout=args.timeout)
    except KeyboardInterrupt:
        print("\nAfgebroken door gebruiker.", file=sys.stderr)
        return 130
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
