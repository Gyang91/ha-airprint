import re
from urllib.parse import urlsplit

DOMAIN = "airprint"
DEFAULT_PORT = 8099
UPDATE_INTERVAL = 15
SUBENTRY = "printer"
DEVICE_NAME = "Printer"
ADDON_NAME = "AirPrint"

ICONS = ["🖨️", "📠", "📄", "📁", "☁️", "🏢", "🏠"]
DEFAULT_ICON = "🖨️"

# The files the add-on can install (drivers.sh). The link must end in one, as
# the add-on names the download after the last part of the link's path.
DRIVER_FILES = (".deb", ".ppd", ".ppd.gz", ".tar.gz", ".tgz")


def device_id(device: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "_", device).strip("_")


def device_name(device: str) -> str:
    if device.startswith("dnssd://"):
        return device.removeprefix("dnssd://").split("._", 1)[0] or DEVICE_NAME
    if "://" in device:
        return device.split("://", 1)[1].strip("/") or DEVICE_NAME
    return device or DEVICE_NAME


def label(printer: dict) -> str:
    icon = printer.get("icon", "")
    name = printer.get("name", "")
    return f"{icon} {name}".strip()


def driver_error(url: str, current: str = "") -> str | None:
    """Return why a driver link cannot be used, or None if it can.

    The add-on installs the download as root, so it must come over https. A
    link that is already saved (current) is left alone, so a printer set up
    before this check keeps working.
    """
    url = url.strip()
    if not url or url == current.strip():
        return None

    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname:
        return "driver_https"

    name = parts.path.rsplit("/", 1)[-1]
    if name.startswith(".") or not name.endswith(DRIVER_FILES):
        return "driver_file"

    return None
