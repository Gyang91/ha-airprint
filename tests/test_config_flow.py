"""Adding and editing printers."""

from __future__ import annotations

import pytest
from homeassistant import config_entries
from homeassistant.data_entry_flow import FlowResultType
from homeassistant.helpers.service_info.zeroconf import ZeroconfServiceInfo

from custom_components.airprint.const import DOMAIN, driver_error

from .conftest import DEVICE, HOST, OTHER, PORT, URL
from .test_entities import entry_with_printer

ZEROCONF = ZeroconfServiceInfo(
    ip_address=HOST,
    ip_addresses=[HOST],
    hostname="homeassistant.local.",
    name="AirPrint add-on._airprint-status._tcp.local.",
    port=PORT,
    type="_airprint-status._tcp.local.",
    properties={},
)


@pytest.mark.parametrize(
    ("url", "current", "error"),
    [
        ("", "", None),
        ("https://cdn.example.com/drivers/cnrdrvcups-ufr2-uk_6.30-1.10_amd64.deb", "", None),
        ("https://cdn.example.com/Canon.tar.gz?token=abc", "", None),
        ("https://cdn.example.com/x.ppd.gz", "", None),
        ("https://cdn.example.com/x.tgz", "", None),
        ("http://cdn.example.com/x.deb", "", "driver_https"),
        ("ftp://cdn.example.com/x.deb", "", "driver_https"),
        ("https:///x.deb", "", "driver_https"),
        ("https://cdn.example.com/download?id=12", "", "driver_file"),
        ("https://cdn.example.com/", "", "driver_file"),
        ("https://cdn.example.com/.downloaded.deb", "", "driver_file"),
        ("https://cdn.example.com/x.DEB", "", "driver_file"),
        # Saved before the check existed: kept as it is.
        ("http://cdn.example.com/x.deb", "http://cdn.example.com/x.deb", None),
    ],
)
def test_driver_error(url, current, error):
    assert driver_error(url, current) == error


def status_with(discovered: list[dict], printers: list[dict] | None = None) -> dict:
    return {"slug": "0f9301c3_airprint", "printers": printers or [], "discovered": discovered}


FOUND = {"device": DEVICE, "uri": DEVICE, "name": "HP Laser MFP 131 133 135-138", "address": "192.168.1.50", "device_id": "", "driver": "everywhere"}
NO_DRIVER = {"device": OTHER, "uri": OTHER, "name": "Canon MF4800", "address": "192.168.1.51", "device_id": "", "driver": ""}


async def test_zeroconf_adds_printer(hass, aioclient_mock):
    aioclient_mock.get(URL, json=status_with([FOUND]))

    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_ZEROCONF}, data=ZEROCONF
    )
    assert result["type"] is FlowResultType.FORM
    assert result["step_id"] == "confirm"

    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"name": "", "location": "Office", "icon": "🖨️"}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"] == {"host": HOST, "port": PORT}
    entry = result["result"]
    (subentry,) = entry.subentries.values()
    assert subentry.title == "🖨️ HP Laser MFP 131 133 135-138"
    assert subentry.data == {
        "icon": "🖨️",
        "name": "HP Laser MFP 131 133 135-138",
        "device": DEVICE,
        "driver": "",
        "location": "Office",
        "discovered_name": "HP Laser MFP 131 133 135-138",
    }


async def test_zeroconf_asks_for_driver(hass, aioclient_mock):
    aioclient_mock.get(URL, json=status_with([NO_DRIVER]))

    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_ZEROCONF}, data=ZEROCONF
    )
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"name": "Canon"})
    assert result["step_id"] == "driver"

    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {"driver": "http://cdn.example.com/canon.deb"}
    )
    assert result["type"] is FlowResultType.FORM
    assert result["errors"] == {"driver": "driver_https"}

    url = "https://cdn.example.com/canon_amd64.deb"
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"driver": url})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    (subentry,) = result["result"].subentries.values()
    assert subentry.data["driver"] == url
    assert subentry.data["name"] == "Canon"


async def test_driver_can_be_skipped(hass, aioclient_mock):
    aioclient_mock.get(URL, json=status_with([NO_DRIVER]))
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_ZEROCONF}, data=ZEROCONF
    )
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    (subentry,) = result["result"].subentries.values()
    assert subentry.data["driver"] == ""


async def test_manual_setup_defaults_to_this_host(hass):
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": config_entries.SOURCE_USER}
    )
    schema = {str(key): key.default() for key in result["data_schema"].schema}
    assert schema == {"host": "127.0.0.1", "port": 8099}


async def _setup(hass, feed):
    entry = entry_with_printer()
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    return entry


async def _reconfigure(hass, entry, user_input):
    (subentry,) = entry.subentries.values()
    result = await entry.start_subentry_reconfigure_flow(hass, subentry.subentry_id)
    assert result["step_id"] == "reconfigure"
    return await hass.config_entries.subentries.async_configure(result["flow_id"], user_input)


async def test_reconfigure_validates_new_link(hass, feed, addon):
    entry = await _setup(hass, feed)

    result = await _reconfigure(hass, entry, {"name": "HP Laser", "driver": "http://x.example.com/a.deb"})
    assert result["type"] is FlowResultType.FORM
    assert result["errors"] == {"driver": "driver_https"}


async def test_reconfigure_keeps_saved_http_link(hass, feed, addon):
    entry = await _setup(hass, feed)
    (subentry,) = entry.subentries.values()
    hass.config_entries.async_update_subentry(
        entry, subentry, data={**subentry.data, "driver": "http://x.example.com/a.deb"}
    )
    await hass.async_block_till_done()

    result = await _reconfigure(
        hass, entry, {"name": "HP Laser", "location": "Office", "icon": "🖨️", "driver": "http://x.example.com/a.deb"}
    )
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "reconfigure_successful"
    await hass.async_block_till_done()
    (subentry,) = entry.subentries.values()
    assert subentry.data["driver"] == "http://x.example.com/a.deb"


async def test_reconfigure_clears_driver(hass, feed, addon):
    entry = await _setup(hass, feed)
    (subentry,) = entry.subentries.values()
    hass.config_entries.async_update_subentry(
        entry, subentry, data={**subentry.data, "driver": "https://x.example.com/a.deb"}
    )
    await hass.async_block_till_done()

    # The frontend leaves a cleared field out.
    result = await _reconfigure(hass, entry, {"name": "HP Laser", "location": "Office", "icon": "🖨️"})
    assert result["reason"] == "reconfigure_successful"
    await hass.async_block_till_done()
    (subentry,) = entry.subentries.values()
    assert subentry.data["driver"] == ""
    # ...and the add-on is told.
    assert "driver" not in addon.options["printers"][0]


async def test_add_printer_subentry(hass, aioclient_mock, status, addon):
    status["discovered"] = [NO_DRIVER]
    aioclient_mock.get(URL, json=status)
    entry = await _setup(hass, None)

    result = await hass.config_entries.subentries.async_init(
        (entry.entry_id, "printer"), context={"source": config_entries.SOURCE_USER}
    )
    assert result["step_id"] == "user"
    result = await hass.config_entries.subentries.async_configure(result["flow_id"], {"name": "Canon"})
    assert result["step_id"] == "driver"
    result = await hass.config_entries.subentries.async_configure(
        result["flow_id"], {"driver": "https://cdn.example.com/canon.ppd"}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY
    await hass.async_block_till_done()

    names = sorted(p["name"] for p in addon.options["printers"])
    assert names == ["Canon", "HP Laser"]
    canon = next(p for p in addon.options["printers"] if p["name"] == "Canon")
    assert canon == {"name": "Canon", "location": "", "device": OTHER, "driver": "https://cdn.example.com/canon.ppd"}
    addon.async_restart_addon.assert_called()
