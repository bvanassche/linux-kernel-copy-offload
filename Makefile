all: README.html Meeting-Minutes.html

%.html: %.md
	pandoc <$< --to=html >$@
