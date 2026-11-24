"""Tests voor convertpdf.py.

De meeste tests gebruiken een nep-Ghostscript (klein Python-script) zodat
ze zonder Ghostscript draaien. De integratietest onderaan gebruikt de echte
Ghostscript en wordt overgeslagen als die niet geïnstalleerd is.
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

import convertpdf

MINIMAL_PDF = b"""%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj
trailer << /Root 1 0 R >>
%%EOF
"""

FAKE_GS = """#!{python}
import sys
args = sys.argv[1:]
out = next(a.split("=", 1)[1] for a in args if a.startswith("-sOutputFile="))
src = args[-1]
mode = "{mode}"
if mode == "fail":
    sys.stderr.write("Error: /syntaxerror in pdf\\n")
    sys.exit(1)
if mode == "empty":
    open(out, "wb").close()
    sys.exit(0)
with open(src, "rb") as f:
    data = f.read()
with open(out.replace("%%", "%"), "wb") as f:
    f.write(b"CONVERTED\\n" + data)
"""


def make_fake_gs(tmp_path: Path, mode: str = "ok") -> str:
    script = tmp_path / f"fake_gs_{mode}"
    script.write_text(FAKE_GS.format(python=sys.executable, mode=mode))
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return str(script)


@pytest.fixture
def pdf_dir(tmp_path: Path) -> Path:
    folder = tmp_path / "pdfs"
    folder.mkdir()
    return folder


def no_temp_files(folder: Path) -> bool:
    return not any(p.name.startswith(convertpdf.TEMP_PREFIX) for p in folder.iterdir())


# --- find_pdfs ---------------------------------------------------------------


def test_find_pdfs_filters(pdf_dir: Path, tmp_path: Path) -> None:
    (pdf_dir / "b.pdf").write_bytes(MINIMAL_PDF)
    (pdf_dir / "A.PDF").write_bytes(MINIMAL_PDF)
    (pdf_dir / "original_c.pdf").write_bytes(MINIMAL_PDF)
    (pdf_dir / ".hidden.pdf").write_bytes(MINIMAL_PDF)
    (pdf_dir / "notes.txt").write_text("x")
    (pdf_dir / "sub.pdf").mkdir()
    outside = tmp_path / "outside.pdf"
    outside.write_bytes(MINIMAL_PDF)
    (pdf_dir / "link.pdf").symlink_to(outside)

    assert [p.name for p in convertpdf.find_pdfs(pdf_dir)] == ["A.PDF", "b.pdf"]


# --- build_command -----------------------------------------------------------


def test_build_command_is_safe(tmp_path: Path) -> None:
    src = tmp_path / "-dangerous.pdf"
    out = tmp_path / "out%d.pdf"
    cmd = convertpdf.build_command("/usr/bin/gs", src, out)
    assert "-dSAFER" in cmd
    assert cmd[-1] == str(src)
    assert cmd[-1].startswith("/")
    assert f"-sOutputFile={tmp_path}/out%%d.pdf" in cmd


# --- convert_file ------------------------------------------------------------


def test_convert_file_success(pdf_dir: Path, tmp_path: Path) -> None:
    pdf = pdf_dir / "doc.pdf"
    pdf.write_bytes(MINIMAL_PDF)
    pdf.chmod(0o640)

    original = convertpdf.convert_file(make_fake_gs(tmp_path), pdf)

    assert original == pdf_dir.resolve() / "original_doc.pdf"
    assert original.read_bytes() == MINIMAL_PDF
    assert pdf.read_bytes().startswith(b"CONVERTED")
    assert stat.S_IMODE(pdf.stat().st_mode) == 0o640
    assert no_temp_files(pdf_dir)


def test_convert_file_gs_failure_keeps_original(pdf_dir: Path, tmp_path: Path) -> None:
    pdf = pdf_dir / "doc.pdf"
    pdf.write_bytes(MINIMAL_PDF)

    with pytest.raises(convertpdf.ConvertError, match="syntaxerror"):
        convertpdf.convert_file(make_fake_gs(tmp_path, "fail"), pdf)

    assert pdf.read_bytes() == MINIMAL_PDF
    assert not (pdf_dir / "original_doc.pdf").exists()
    assert no_temp_files(pdf_dir)


def test_convert_file_empty_output(pdf_dir: Path, tmp_path: Path) -> None:
    pdf = pdf_dir / "doc.pdf"
    pdf.write_bytes(MINIMAL_PDF)

    with pytest.raises(convertpdf.ConvertError, match="leeg"):
        convertpdf.convert_file(make_fake_gs(tmp_path, "empty"), pdf)

    assert pdf.read_bytes() == MINIMAL_PDF
    assert no_temp_files(pdf_dir)


def test_convert_file_existing_original(pdf_dir: Path, tmp_path: Path) -> None:
    pdf = pdf_dir / "doc.pdf"
    pdf.write_bytes(MINIMAL_PDF)
    (pdf_dir / "original_doc.pdf").write_bytes(b"older")

    with pytest.raises(convertpdf.ConvertError, match="bestaat al"):
        convertpdf.convert_file(make_fake_gs(tmp_path), pdf)

    assert (pdf_dir / "original_doc.pdf").read_bytes() == b"older"
    assert no_temp_files(pdf_dir)


def test_convert_file_timeout(pdf_dir: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pdf = pdf_dir / "doc.pdf"
    pdf.write_bytes(MINIMAL_PDF)

    def fake_run(*args: object, **kwargs: object) -> None:
        raise subprocess.TimeoutExpired(cmd="gs", timeout=1)

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(convertpdf.ConvertError, match="time-out"):
        convertpdf.convert_file("gs", pdf, timeout=1)

    assert pdf.read_bytes() == MINIMAL_PDF
    assert no_temp_files(pdf_dir)


def test_convert_file_rollback_when_replace_fails(
    pdf_dir: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pdf = pdf_dir / "doc.pdf"
    pdf.write_bytes(MINIMAL_PDF)

    def broken_replace(src: object, dst: object) -> None:
        raise OSError("schijf vol")

    monkeypatch.setattr(os, "replace", broken_replace)
    with pytest.raises(convertpdf.ConvertError, match="schijf vol"):
        convertpdf.convert_file(make_fake_gs(tmp_path), pdf)

    assert pdf.read_bytes() == MINIMAL_PDF
    assert not (pdf_dir / "original_doc.pdf").exists()
    assert no_temp_files(pdf_dir)


def test_convert_file_rollback_on_interrupt(
    pdf_dir: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pdf = pdf_dir / "doc.pdf"
    pdf.write_bytes(MINIMAL_PDF)

    def interrupted(src: object, dst: object) -> None:
        raise KeyboardInterrupt

    monkeypatch.setattr(os, "replace", interrupted)
    with pytest.raises(KeyboardInterrupt):
        convertpdf.convert_file(make_fake_gs(tmp_path), pdf)

    assert pdf.read_bytes() == MINIMAL_PDF
    assert no_temp_files(pdf_dir)


def test_convert_file_dash_name_relative_cwd(
    pdf_dir: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pdf = pdf_dir / "-dNOSAFER.pdf"
    pdf.write_bytes(MINIMAL_PDF)
    monkeypatch.chdir(pdf_dir)

    convertpdf.convert_file(make_fake_gs(tmp_path), Path("-dNOSAFER.pdf"))

    assert (pdf_dir / "original_-dNOSAFER.pdf").read_bytes() == MINIMAL_PDF
    assert pdf.read_bytes().startswith(b"CONVERTED")


# --- collect_targets / convert_paths / main -----------------------------------


def test_collect_targets_mix_of_files_and_folders(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    map1 = tmp_path / "map1"
    map2 = tmp_path / "map2"
    map1.mkdir()
    map2.mkdir()
    (map1 / "a.pdf").write_bytes(MINIMAL_PDF)
    (map1 / "b.pdf").write_bytes(MINIMAL_PDF)
    (map2 / "c.pdf").write_bytes(MINIMAL_PDF)
    los = tmp_path / "los.PDF"
    los.write_bytes(MINIMAL_PDF)

    targets = convertpdf.collect_targets([los, map1, map1 / "a.pdf", map2])

    assert [p.name for p in targets.pdfs] == ["los.PDF", "a.pdf", "b.pdf", "c.pdf"]
    assert targets.skipped == 0
    assert targets.missing == 0


def test_collect_targets_skips_and_missing(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    txt = tmp_path / "notities.txt"
    txt.write_text("x")
    orig = tmp_path / "original_x.pdf"
    orig.write_bytes(MINIMAL_PDF)
    real = tmp_path / "echt.pdf"
    real.write_bytes(MINIMAL_PDF)
    link = tmp_path / "link.pdf"
    link.symlink_to(real)

    targets = convertpdf.collect_targets([txt, orig, link, tmp_path / "weg.pdf"])

    assert targets.pdfs == []
    assert targets.skipped == 3
    assert targets.missing == 1
    out = capsys.readouterr()
    assert "is geen PDF" in out.out
    assert "is al een origineel" in out.out
    assert "is een symlink" in out.out
    assert "weg.pdf' bestaat niet" in out.err


def test_convert_paths_counts_failures(
    pdf_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (pdf_dir / "a.pdf").write_bytes(MINIMAL_PDF)
    (pdf_dir / "b.pdf").write_bytes(MINIMAL_PDF)
    (pdf_dir / "original_b.pdf").write_bytes(b"older")
    txt = tmp_path / "x.txt"
    txt.write_text("x")

    failed = convertpdf.convert_paths(
        [pdf_dir, txt, tmp_path / "bestaat-niet"], make_fake_gs(tmp_path)
    )

    assert failed == 2
    assert (pdf_dir / "original_a.pdf").exists()
    out = capsys.readouterr()
    assert "1 omgezet, 2 mislukt, 1 overgeslagen" in out.out
    assert "b.pdf" in out.err


def test_convert_paths_single_file(pdf_dir: Path, tmp_path: Path) -> None:
    (pdf_dir / "a.pdf").write_bytes(MINIMAL_PDF)
    (pdf_dir / "b.pdf").write_bytes(MINIMAL_PDF)

    assert convertpdf.convert_paths([pdf_dir / "b.pdf"], make_fake_gs(tmp_path)) == 0

    assert (pdf_dir / "original_b.pdf").exists()
    assert not (pdf_dir / "original_a.pdf").exists()


def test_convert_paths_empty(pdf_dir: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert convertpdf.convert_paths([pdf_dir], "gs") == 0
    assert "Geen nieuwe PDF's" in capsys.readouterr().out


def test_convert_paths_only_missing(tmp_path: Path) -> None:
    assert convertpdf.convert_paths([tmp_path / "weg"], "gs") == 1


def test_second_run_is_idempotent(pdf_dir: Path, tmp_path: Path) -> None:
    (pdf_dir / "a.pdf").write_bytes(MINIMAL_PDF)
    gs = make_fake_gs(tmp_path)
    assert convertpdf.convert_paths([pdf_dir], gs) == 0
    # Tweede keer: a.pdf heeft nu een original_ naast zich en wordt overgeslagen
    assert convertpdf.convert_paths([pdf_dir], gs) == 1
    assert (pdf_dir / "original_a.pdf").read_bytes() == MINIMAL_PDF


def test_main_missing_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(convertpdf, "find_ghostscript", lambda: "gs")
    assert convertpdf.main([str(tmp_path / "bestaat-niet")]) == 1
    assert "bestaat niet" in capsys.readouterr().err


def test_main_multiple_paths(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    map1 = tmp_path / "map1"
    map1.mkdir()
    (map1 / "a.pdf").write_bytes(MINIMAL_PDF)
    los = tmp_path / "los.pdf"
    los.write_bytes(MINIMAL_PDF)
    gs = make_fake_gs(tmp_path)
    monkeypatch.setattr(convertpdf, "find_ghostscript", lambda: gs)

    assert convertpdf.main([str(map1), str(los)]) == 0

    assert (map1 / "original_a.pdf").exists()
    assert (tmp_path / "original_los.pdf").exists()


def test_main_without_ghostscript(
    pdf_dir: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(convertpdf, "find_ghostscript", lambda: None)
    assert convertpdf.main([str(pdf_dir)]) == 1
    assert "Ghostscript" in capsys.readouterr().err


def test_main_success(pdf_dir: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (pdf_dir / "a.pdf").write_bytes(MINIMAL_PDF)
    gs = make_fake_gs(tmp_path)
    monkeypatch.setattr(convertpdf, "find_ghostscript", lambda: gs)
    assert convertpdf.main([str(pdf_dir)]) == 0


def test_main_invalid_timeout(pdf_dir: Path) -> None:
    with pytest.raises(SystemExit) as exc:
        convertpdf.main([str(pdf_dir), "--timeout", "0"])
    assert exc.value.code == 2


def test_main_requires_argument() -> None:
    with pytest.raises(SystemExit) as exc:
        convertpdf.main([])
    assert exc.value.code == 2


# --- integratie met echte Ghostscript ----------------------------------------


@pytest.mark.skipif(convertpdf.find_ghostscript() is None, reason="Ghostscript niet geïnstalleerd")
def test_integration_real_ghostscript(pdf_dir: Path) -> None:
    pdf = pdf_dir / "echt.pdf"
    pdf.write_bytes(MINIMAL_PDF)

    assert convertpdf.main([str(pdf_dir)]) == 0

    assert (pdf_dir / "original_echt.pdf").read_bytes() == MINIMAL_PDF
    new = pdf.read_bytes()
    assert new.startswith(b"%PDF-1.7")
    assert new != MINIMAL_PDF
    assert no_temp_files(pdf_dir)


@pytest.mark.skipif(convertpdf.find_ghostscript() is None, reason="Ghostscript niet geïnstalleerd")
def test_integration_broken_pdf(pdf_dir: Path) -> None:
    pdf = pdf_dir / "kapot.pdf"
    pdf.write_bytes(b"dit is geen pdf")

    assert convertpdf.main([str(pdf_dir)]) == 1
    assert pdf.read_bytes() == b"dit is geen pdf"
    assert not (pdf_dir / "original_kapot.pdf").exists()
    assert no_temp_files(pdf_dir)


def test_script_is_executable() -> None:
    script = Path(convertpdf.__file__)
    assert os.access(script, os.X_OK)


def test_main_keyboard_interrupt(pdf_dir: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def interrupted(*args: object, **kwargs: object) -> int:
        raise KeyboardInterrupt

    monkeypatch.setattr(convertpdf, "find_ghostscript", lambda: "gs")
    monkeypatch.setattr(convertpdf, "convert_paths", interrupted)
    assert convertpdf.main([str(pdf_dir)]) == 130
