"""Setting up: syncing the add-on, and the "needs a driver" repair."""

from __future__ import annotations

import time

from homeassistant.helpers import issue_registry as ir

from custom_components.airprint.const import DOMAIN

from .conftest import OPTION, URL
from .test_entities import entry_with_printer


async def test_setup_does_not_wait_for_the_addon(hass, feed, addon):
    # The add-on still has an old printer list: it is updated and restarted,
    # and setup carries on instead of polling until the add-on is back.
    addon.options = {"printers": [], "networks": ["10.6.0.0/24"]}
    entry = entry_with_printer()
    entry.add_to_hass(hass)

    started = time.monotonic()
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    assert time.monotonic() - started < 2

    assert addon.options == {"printers": [OPTION], "networks": ["10.6.0.0/24"]}
    addon.async_restart_addon.assert_called_once()
    assert hass.states.get("sensor.hp_laser_status").state == "Ready"


async def test_save_failure_retries_setup(hass, feed, addon):
    addon.options = {"printers": []}
    addon.async_set_addon_options.side_effect = RuntimeError("Supervisor said no")
    entry = entry_with_printer()
    entry.add_to_hass(hass)

    assert not await hass.config_entries.async_setup(entry.entry_id)
    assert entry.state.name == "SETUP_RETRY"


async def test_no_driver_repair(hass, aioclient_mock, status, addon):
    status["printers"][0]["driver"] = ""
    aioclient_mock.get(URL, json=status)
    entry = entry_with_printer()
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    issues = ir.async_get(hass)
    assert (DOMAIN, "no_driver_HP_Laser") in issues.issues
    assert hass.states.get("sensor.hp_laser_status").state == "No driver"

    # The driver is added: the repair goes.
    status["printers"][0]["driver"] = "everywhere"
    aioclient_mock.clear_requests()
    aioclient_mock.get(URL, json=status)
    await entry.runtime_data.async_refresh()
    await hass.async_block_till_done()
    assert (DOMAIN, "no_driver_HP_Laser") not in issues.issues


async def test_stale_repair_is_removed(hass, feed, addon):
    # Left by a printer that has since been removed or renamed.
    ir.async_create_issue(
        hass, DOMAIN, "no_driver_Old_Printer", is_fixable=False,
        severity=ir.IssueSeverity.ERROR, translation_key="no_driver",
        translation_placeholders={"name": "Old"},
    )
    entry = entry_with_printer()
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    assert (DOMAIN, "no_driver_Old_Printer") not in ir.async_get(hass).issues


async def test_repairs_kept_while_addon_restarts(hass, aioclient_mock, status, addon):
    # Right after a restart the add-on reports no printers yet: keep the
    # repairs (and their "ignore") instead of deleting and re-raising them.
    ir.async_create_issue(
        hass, DOMAIN, "no_driver_Canon", is_fixable=False,
        severity=ir.IssueSeverity.ERROR, translation_key="no_driver",
        translation_placeholders={"name": "Canon"},
    )
    status["printers"] = []
    aioclient_mock.get(URL, json=status)
    entry = entry_with_printer()
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    assert (DOMAIN, "no_driver_Canon") in ir.async_get(hass).issues


async def test_unload(hass, feed, addon):
    entry = entry_with_printer()
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    assert await hass.config_entries.async_unload(entry.entry_id)
    assert entry.state.name == "NOT_LOADED"


async def test_printers_imported_once_from_the_addon(hass, feed, addon):
    from pytest_homeassistant_custom_component.common import MockConfigEntry

    # An install from before the integration owned the printer list.
    entry = MockConfigEntry(domain=DOMAIN, unique_id=DOMAIN, data={"host": "192.168.1.100", "port": 8099})
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    (subentry,) = entry.subentries.values()
    assert subentry.data["name"] == "HP Laser"
    assert entry.data["imported"] is True

    # Removing the last printer keeps it removed (it used to be re-imported).
    hass.config_entries.async_remove_subentry(entry, subentry.subentry_id)
    await hass.async_block_till_done()
    assert not entry.subentries
    assert addon.options["printers"] == []


async def test_existing_install_is_marked_imported(hass, feed, addon):
    entry = entry_with_printer()
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    assert entry.data["imported"] is True
    assert len(entry.subentries) == 1


async def test_power_switch_wakes_the_printer(hass, aioclient_mock, status, addon):
    from pytest_homeassistant_custom_component.common import async_mock_service

    status["printers"][0].update(online=False, jobs=1)
    aioclient_mock.get(URL, json=status)
    hass.states.async_set("switch.printer_plug", "off")
    calls = async_mock_service(hass, "switch", "turn_on")

    entry = entry_with_printer()
    (subentry,) = entry.subentries.values()
    entry = type(entry)(
        domain=DOMAIN, unique_id=DOMAIN, title="AirPrint", data=dict(entry.data),
        subentries_data=[{
            "data": {**subentry.data, "power_switch": "switch.printer_plug"},
            "subentry_type": "printer", "title": subentry.title, "unique_id": subentry.unique_id,
        }],
    )
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await entry.runtime_data.async_refresh()
    await hass.async_block_till_done()
    assert len(calls) == 1
    assert calls[0].data == {"entity_id": "switch.printer_plug"}
    # The power settings stay in Home Assistant: the add-on is not told.
    assert "power_switch" not in addon.options["printers"][0]
