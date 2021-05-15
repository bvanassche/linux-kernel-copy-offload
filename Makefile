README.html: README.md
	pandoc <$< --to=html >$@
