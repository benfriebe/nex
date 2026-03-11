PREFIX ?= /usr/local
BINARY = nexus-notify

.PHONY: build install clean

build:
	swiftc -O -o $(BINARY) nexus-notify.swift

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BINARY) $(PREFIX)/bin/$(BINARY)

clean:
	rm -f $(BINARY)
