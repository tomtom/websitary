include Makefile.config

all: dbk html pdf tex text man

dvi: ${BASE}.dvi
dbk: ${BASE}.dbk
html: ${BASE}.html
pdf:
	make DFLAGS="${DFLAGS} --pdf" "${BASE}.pdf"
php: ${BASE}.php
tex: ${BASE}.tex
text: ${BASE}.text
man: ${BASE}.1

pdfclean: pdf cleantex
dviclean: dvi cleantex

makefile:
	${DEPLATE} -m makefile ${DFLAGS} ${BASE}.txt ${OTHER}

website:
	make prepare_website
	${DEPLATE} ${DFLAGS} ${WEBSITE_DFLAGS} ${FILE} ${OTHER}
	echo ${WEBSITE_DIR}/${BASE}.html > .last_output

%.html: %.txt
	make prepare_html
	${DEPLATE} ${DFLAGS} ${HTML_DFLAGS} $< ${OTHER}
	echo ${HTML_DIR}/$@ > .last_output

%.text: %.txt
	make prepare_text
	${DEPLATE} ${DFLAGS} ${TEXT_DFLAGS} $< ${OTHER}
	echo ${TEXT_DIR}/$@ > .last_output

%.php: %.txt
	make prepare_php
	${DEPLATE} ${DFLAGS} ${PHP_DFLAGS} $< ${OTHER}
	echo ${PHP_DIR}/$@ > .last_output

%.dbk: %.txt
	make prepare_dbk
	${DEPLATE} ${DFLAGS} ${DBK_DFLAGS} $< ${OTHER}
	echo ${DBK_DIR}/$@ > .last_output

%.tex: %.txt
	make prepare_tex
	${DEPLATE} ${DFLAGS} ${TEX_DFLAGS} $< ${OTHER}
	echo ${TEX_DIR}/$@ > .last_output

%.ref: %.txt
	make prepare_ref
	${DEPLATE} ${DFLAGS} ${REF_DFLAGS} -o $@ $< ${OTHER}
	echo ${REF_DIR}/$@ > .last_output

%.dvi: %.tex
	make prepare_dvi
	cd ${TEX_DIR}; \
	latex ${LATEX_FLAGS} $<; \
	bibtex ${BIBTEX_FLAGS} $*; \
	latex ${LATEX_FLAGS} $<; \
	latex ${LATEX_FLAGS} $<;
	echo ${TEX_DIR}/$@ > .last_output

%.pdf: %.tex
	make prepare_pdf
	cd ${TEX_DIR}; \
	pdflatex ${PDFLATEX_FLAGS} $<; \
	bibtex ${BIBTEX_FLAGS} $*; \
	pdflatex ${PDFLATEX_FLAGS} $<; \
	pdflatex ${PDFLATEX_FLAGS} $<
	echo ${TEX_DIR}/$@ > .last_output

%.1: %.ref
	cd ${REF_DIR}; \
	xmlto man $<
	echo ${REF_DIR}/$@ > .last_output

view: show
show:
	cygstart `cat .last_output`

cleantex:
	cd ${TEX_DIR}; \
	rm -f *.toc *.aux *.log *.cp *.fn *.tp *.vr *.pg *.ky \
	*.blg *.bbl *.out *.lot *.ind *.4tc *.4ct \
	*.ilg *.idx *.idv *.lg *.xref || echo Nothing to be done!

