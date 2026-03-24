PREFIX ?= /usr/local
BINARY = nex

.PHONY: build install clean

build:
	swiftc -O -o $(BINARY) nex.swift

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BINARY) $(PREFIX)/bin/$(BINARY)

clean:
	rm -f $(BINARY)
