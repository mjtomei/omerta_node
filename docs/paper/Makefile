# Makefile for participation verification paper

PAPER = participation-verification
LATEX = pdflatex
BIBTEX = bibtex

.PHONY: all clean

all: $(PAPER).pdf

$(PAPER).pdf: $(PAPER).tex
	$(LATEX) $(PAPER)
	$(LATEX) $(PAPER)

clean:
	rm -f $(PAPER).pdf $(PAPER).aux $(PAPER).log $(PAPER).out $(PAPER).toc
