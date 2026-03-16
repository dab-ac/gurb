.PHONY: lint deb clean

VERSION ?= $(shell v=$$(git describe --tags 2>/dev/null) && echo "$$v" | grep -qP '^v\d+\.\d+[\.\d]*(-[a-zA-Z][a-zA-Z0-9.]*)?(-[1-9]\d*-g[0-9a-f]+)?$$' && echo "$$v" | sed 's/^v//; s/-\([0-9]*\)-g/+\1.g/; s/-/~/g' || { echo "bad tag: $$v" >&2; exit 1; })

lint:
	perl -c pkg/usr/bin/gurb

deb:
	rm -rf _build
	cp -a pkg _build
	sed -i 's/^Version:.*/Version: $(VERSION)/' _build/DEBIAN/control
	find _build -exec touch -d @0 {} +
	SOURCE_DATE_EPOCH=0 dpkg-deb --root-owner-group -Zxz -b _build gurb_$(VERSION)_amd64.deb
	rm -rf _build

clean:
	rm -rf _build gurb_*_amd64.deb
