PREFIX ?= /usr/local
BINARY = nex-notify

.PHONY: build install clean

build:
	swiftc -O -o $(BINARY) nex-notify.swift

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BINARY) $(PREFIX)/bin/$(BINARY)

clean:
	rm -f $(BINARY)
