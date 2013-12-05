quickboot: buildMain.native

SOURCEDIRS = $(wildcard . src/ocp-build src/ocplib/* src/win32)

buildMain.native:
	ln -sf ../src .
	ocamlbuild buildMain.native -no-links
	cp _build/src/ocp-build/buildMain.native ocp-build
