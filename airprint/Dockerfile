FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# No snmp backend: its device discovery opens 9100 on every printer it finds,
# which wakes some printers (see CLAUDE.md). Nothing prints through snmp://;
# the monitor reads printer status with snmpget, not this backend. The debconf
# answer keeps a later reconfigure of cups (a vendor .deb pulling in packages)
# from putting it back.
#
# upgrade: the base image can lag behind Debian's security updates; every
# build takes the current ones (see the Security workflow). The layer cache
# would otherwise keep the first build's packages forever, because this RUN's
# text never changes: CI passes today's date as APT_REFRESH, so the packages
# are refreshed at most a day late.
ARG APT_REFRESH=""
RUN echo "apt refresh: ${APT_REFRESH:-none}" \
 && echo "cups cupsys/backend multiselect lpd, socket, usb, dnssd" | debconf-set-selections \
 && apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      avahi-daemon \
      avahi-utils \
      ca-certificates \
      cups \
      cups-bsd \
      cups-client \
      cups-filters \
      curl \
      dbus \
      jq \
      python3 \
      snmp \
 && apt-get install -y --no-install-recommends \
      printer-driver-all \
      printer-driver-brlaser \
      printer-driver-cups-pdf \
      openprinting-ppds \
      foomatic-db-compressed-ppds \
 && apt-get install -y --no-install-recommends \
      libcupsimage2 \
      libgtk-3-0 \
      libjpeg62-turbo \
      libjbig0 \
      libgcrypt20 \
      lsb-release \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/lib/cups/backend/snmp

COPY cupsd.conf /etc/cups/cupsd.conf
COPY cupsd.conf /usr/share/airprint/cupsd.conf
COPY avahi-daemon.conf /etc/avahi/avahi-daemon.conf
COPY printer.png /usr/share/airprint/printer.png
COPY run.sh /run.sh
COPY monitor.sh /monitor.sh
COPY drivers.sh /drivers.sh
COPY discover.sh /discover.sh
COPY queue.sh /queue.sh
COPY match.sh /match.sh
RUN chmod +x /run.sh /monitor.sh /drivers.sh /discover.sh /queue.sh

CMD ["/run.sh"]
