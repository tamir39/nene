# Nene final report (LaTeX)

Vietnamese final report for the TDTU course *Phát triển ứng dụng di động*, built on the faculty template
[bnquys/report-latex-tdtu](https://github.com/bnquys/report-latex-tdtu)
(itself based on the Overleaf *Master Thesis Template for TDTU, Vietnamese version*).

## Build

- **Overleaf:** upload this folder, set the compiler to `pdfLaTeX` (Normal mode, TeX Live 2025) and the main document to `main.tex`.
- **Local / Docker:** `latexmk -pdf main.tex` (pdfLaTeX + biber).
  With Docker: `docker run --rm -v "$PWD:/work" -w /work texlive/texlive:latest latexmk -pdf -interaction=nonstopmode main.tex`.

## Layout

| Path | Content |
| --- | --- |
| `main.tex`, `format.tex` | Document order and formatting from the template |
| `coverpage.tex` … `PhuLuc.tex` | Front matter, bibliography and appendices |
| `NoiDungChinh/Chuong-1.tex` … `Chuong-5.tex` | Chapters 1–5 |
| `references/chN.bib` | Sources per chapter (biblatex APA; `keywords = {tiengviet}` for Vietnamese sources) |
| `picture/ch2` | UML/ER diagrams rendered from `picture/ch2/puml/*.puml` (PlantUML) |
| `picture/ch3`, `picture/ch4` | App screenshots rendered from the Flutter UI capture tests with synthetic data |
