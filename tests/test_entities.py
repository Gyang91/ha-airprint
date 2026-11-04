"""What a printer looks like in Home Assistant. The snapshot must not change
between versions: entity IDs, unique IDs and names are what automations and
dashboards on an existing install rely on."""

from __future__ import annotations

import json

from homeassistant.config_entries import ConfigSubentryData
from homeassistant.helpers import device_registry as dr, entity_registry as er
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.airprint.const import DOMAIN

from .conftest import HOST, PORT, PRINTER

EXPECTED = {
    "binary_sensor.hp_laser_health": ["dnssd_HP_Laser_MFP_131_133_135-138__pdl-datastream__tcp_local_problem", "🖨️ HP Laser Health", "off", None],
    "binary_sensor.hp_laser_online": ["dnssd_HP_Laser_MFP_131_133_135-138__pdl-datastream__tcp_local_online", "🖨️ HP Laser Online", "on", None],
    "sensor.hp_laser_printed": ["dnssd_HP_Laser_MFP_131_133_135-138__pdl-datastream__tcp_local_pages", "🖨️ HP Laser Printed", "1234", "mdi:counter"],
    "sensor.hp_laser_queue": ["dnssd_HP_Laser_MFP_131_133_135-138__pdl-datastream__tcp_local_jobs", "🖨️ HP Laser Queue", "0", "mdi:tray-full"],
    "sensor.hp_laser_status": ["dnssd_HP_Laser_MFP_131_133_135-138__pdl-datastream__tcp_local_status", "🖨️ HP Laser Status", "Ready", "mdi:printer-check"],
    "sensor.hp_laser_toner": ["dnssd_HP_Laser_MFP_131_133_135-138__pdl-datastream__tcp_local_toner", "🖨️ HP Laser Toner", "64", "mdi:water-percent"],
}


def entry_with_printer() -> MockConfigEntry:
    return MockConfigEntry(
        domain=DOMAIN,
        unique_id=DOMAIN,
        title="AirPrint",
        data={"host": HOST, "port": PORT},
        subentries_data=[
            ConfigSubentryData(
                data=dict(PRINTER),
                subentry_type="printer",
                title="🖨️ HP Laser",
                unique_id=PRINTER["device"],
            )
        ],
    )


async def snapshot(hass) -> dict:
    registry = er.async_get(hass)
    result = {}
    for entity in sorted(registry.entities.values(), key=lambda e: e.entity_id):
        state = hass.states.get(entity.entity_id)
        # The icon comes from icons.json (translation key) or _attr_icon.
        icon = entity.original_icon
        if icon is None and entity.translation_key:
            from homeassistant.helpers.icon import async_get_icons

            icons = await async_get_icons(hass, "entity", {DOMAIN})
            icon = (
                icons.get(DOMAIN, {}).get(entity.domain, {}).get(entity.translation_key, {}).get("default")
            )
        result[entity.entity_id] = [
            entity.unique_id,
            state.attributes.get("friendly_name"),
            state.state,
            icon,
        ]
    return result


async def test_entities_unchanged(hass, feed, addon):
    entry = entry_with_printer()
    entry.add_to_hass(hass)

    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    got = await snapshot(hass)
    print(json.dumps(got, ensure_ascii=False, indent=1))
    assert got == EXPECTED

    devices = dr.async_entries_for_config_entry(dr.async_get(hass), entry.entry_id)
    assert len(devices) == 1
    device = devices[0]
    assert device.identifiers == {(DOMAIN, "dnssd_HP_Laser_MFP_131_133_135-138__pdl-datastream__tcp_local")}
    assert device.name == "🖨️ HP Laser"
    assert device.model == "HP Laser MFP 131 133 135-138"
    assert device.configuration_url == "http://192.168.1.50/"

    # The options already match, so the add-on is left alone.
    addon.async_set_addon_options.assert_not_called()
    addon.async_restart_addon.assert_not_called()


async def test_health_and_status(hass, aioclient_mock, status, addon):
    printer = status["printers"][0]
    printer.update(problem=False, reasons=["Out of paper"], jobs=2)
    aioclient_mock.get(f"http://{HOST}:{PORT}/status.json", json=status)

    entry = entry_with_printer()
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()

    assert hass.states.get("binary_sensor.hp_laser_health").state == "on"
    assert hass.states.get("binary_sensor.hp_laser_health").attributes["reason"] == "Out of paper"
    assert hass.states.get("sensor.hp_laser_status").state == "Out of paper"
    assert hass.states.get("sensor.hp_laser_queue").state == "2"
