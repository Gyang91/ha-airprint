"""The "needs a driver" repair: Fix asks for the link and saves it on the printer."""

from __future__ import annotations

from homeassistant.components.repairs import repairs_flow_manager
from homeassistant.data_entry_flow import FlowResultType
from homeassistant.helpers import issue_registry as ir
from homeassistant.setup import async_setup_component

from custom_components.airprint.const import DOMAIN

from .conftest import URL
from .test_entities import entry_with_printer

ISSUE = "no_driver_HP_Laser"


async def _setup_without_driver(hass, aioclient_mock, status):
    status["printers"][0]["driver"] = ""
    aioclient_mock.get(URL, json=status)
    assert await async_setup_component(hass, "repairs", {})
    entry = entry_with_printer()
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    issue = ir.async_get(hass).async_get_issue(DOMAIN, ISSUE)
    assert issue is not None and issue.is_fixable
    return entry


async def _start(hass):
    manager = repairs_flow_manager(hass)
    result = await manager.async_init(DOMAIN, data={"issue_id": ISSUE})
    return manager, result


async def test_fix_saves_the_driver(hass, aioclient_mock, status, addon):
    entry = await _setup_without_driver(hass, aioclient_mock, status)
    manager, result = await _start(hass)
    assert result["type"] is FlowResultType.FORM
    assert result["step_id"] == "driver"
    assert result["description_placeholders"] == {"name": "HP Laser MFP 131 133 135-138"}

    result = await manager.async_configure(result["flow_id"], {"driver": "http://x.example.com/a.deb"})
    assert result["errors"] == {"driver": "driver_https"}

    url = "https://x.example.com/hp_amd64.deb"
    result = await manager.async_configure(result["flow_id"], {"driver": url})
    assert result["type"] is FlowResultType.CREATE_ENTRY
    await hass.async_block_till_done()

    (subentry,) = entry.subentries.values()
    assert subentry.data["driver"] == url
    # The add-on is given the link and restarted to install it.
    assert addon.options["printers"][0]["driver"] == url
    addon.async_restart_addon.assert_called()


async def test_fix_needs_a_link(hass, aioclient_mock, status, addon):
    await _setup_without_driver(hass, aioclient_mock, status)
    manager, result = await _start(hass)
    result = await manager.async_configure(result["flow_id"], {"driver": "  "})
    assert result["errors"] == {"driver": "driver_required"}


async def test_fix_for_a_removed_printer(hass, aioclient_mock, status, addon):
    entry = await _setup_without_driver(hass, aioclient_mock, status)
    (subentry,) = entry.subentries.values()
    hass.config_entries.async_remove_subentry(entry, subentry.subentry_id)
    await hass.async_block_till_done()
    manager, result = await _start(hass)
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "printer_removed"
