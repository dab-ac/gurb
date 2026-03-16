.PHONY: lint deb clean

lint:
	perl -c pkg/usr/bin/gurb

deb:
	rm -rf _build
	cp -a pkg _build
	find _build -exec touch -d @0 {} +
	SOURCE_DATE_EPOCH=0 dpkg-deb --root-owner-group -Zxz -b _build gurb_1_amd64.deb
	rm -rf _build

clean:
	rm -rf _build gurb_1_amd64.deb
