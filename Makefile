# $Id$

prefix=/usr/local
exec_prefix=${prefix}
sbindir=${exec_prefix}/sbin
mandir=${prefix}/man

INSTALL=/usr/bin/install -c
INSTALL_PROGRAM=${INSTALL}
INSTALL_DATA=${INSTALL} -m 644

all:

install:
	$(INSTALL) -d $(DESTDIR)$(sbindir)
	$(INSTALL_PROGRAM) freebsd-update-gc.sh \
		$(DESTDIR)$(sbindir)/freebsd-update-gc
	$(INSTALL) -d $(DESTDIR)$(mandir)/man8
	$(INSTALL_DATA) freebsd-update-gc.8 $(DESTDIR)$(mandir)/man8
