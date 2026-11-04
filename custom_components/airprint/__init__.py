from __future__ import annotations

import inspect
import logging

from homeassistant.config_entries import ConfigEntry, ConfigSubentry
from homeassistant.const import CONF_HOST, CONF_PORT, Platform
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import ConfigEntryNotReady
from homeassistant.helpers import issue_registry as ir

from .const import DOMAIN, SUBENTRY, device_name, label
from .coordinator import AirPrintCoordinator

_LOGGER = logging.getLogger(__name__)

PLATFORMS = [Platform.BINARY_SENSOR, Platform.SENSOR]

type AirPrintConfigEntry = ConfigEntry[AirPrintCoordinator]

NO_DRIVER = "no_driver_"

# Home Assistant 2026.11 can tie a repair to its config entry (removed with the
# entry, hidden while it is disabled). Older versions do not take the argument.
_ISSUE_TAKES_ENTRY = "config_entry_id" in inspect.signature(ir.async_create_issue).parameters


def _printer(data: dict) -> dict:
    printer = {
        "name": data.get("name", ""),
        "location": data.get("location", ""),
        "device": data.get("device", ""),
    }

    if data.get("icon"):
        printer = {"icon": data["icon"], **printer}

    if data.get("driver"):
        printer["driver"] = data["driver"]

    return printer


async def async_setup_entry(hass: HomeAssistant, entry: AirPrintConfigEntry) -> bool:
    coordinator = AirPrintCoordinator(hass, entry.data[CONF_HOST], entry.data[CONF_PORT])
    await coordinator.async_config_entry_first_refresh()

    entry.runtime_data = coordinator

    if not entry.subentries:
        for printer in await coordinator.async_get_printers():
            hass.config_entries.async_add_subentry(
                entry,
                ConfigSubentry(
                    data=_printer(printer),
                    subentry_type=SUBENTRY,
                    title=printer.get("name", ""),
                    unique_id=printer.get("device") or printer.get("name"),
                ),
            )

    for subentry in entry.subentries.values():
        data = dict(subentry.data)
        device = data.get("device", "")

        name = data.get("name", "")
        if "://" in name:
            name = ""

        discovered = data.get("discovered_name", "")
        if "://" in discovered:
            discovered = ""

        model = coordinator.data.get(device, {}).get("model", "")

        if model and discovered == device_name(device):
            discovered = model
        if model and name == device_name(device):
            name = model

        discovered = discovered or model or name or device_name(device)
        repaired = {**data, "discovered_name": discovered, "name": name or discovered}

        if repaired != data:
            hass.config_entries.async_update_subentry(entry, subentry, data=repaired)

    for subentry in entry.subentries.values():
        if subentry.title != label(subentry.data):
            hass.config_entries.async_update_subentry(
                entry, subentry, title=label(subentry.data)
            )

    # The add-on restarts with the new printer list. Its entities come back
    # with the next status poll; setup does not wait for that.
    wanted = [_printer(subentry.data) for subentry in entry.subentries.values()]
    if wanted != await coordinator.async_get_printers():
        _LOGGER.info("Updating the AirPrint add-on with %d printer(s)", len(wanted))
        try:
            await coordinator.async_save_printers(wanted)
        except Exception as err:
            raise ConfigEntryNotReady(f"Could not update the AirPrint add-on: {err}") from err

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    @callback
    def _check() -> None:
        _async_check_drivers(hass, entry)

    _check()
    entry.async_on_unload(coordinator.async_add_listener(_check))

    entry.async_on_unload(entry.add_update_listener(async_reload_entry))
    # Still a boolean: Home Assistant before 2026.11 reads None as a failure.
    return True


@callback
def _async_check_drivers(hass: HomeAssistant, entry: AirPrintConfigEntry) -> None:
    coordinator = entry.runtime_data
    printers = list(coordinator.data.values())
    extra = {"config_entry_id": entry.entry_id} if _ISSUE_TAKES_ENTRY else {}

    for printer in printers:
        issue_id = f"{NO_DRIVER}{printer['id']}"

        if printer.get("driver"):
            ir.async_delete_issue(hass, DOMAIN, issue_id)
            continue

        ir.async_create_issue(
            hass,
            DOMAIN,
            issue_id,
            is_fixable=False,
            severity=ir.IssueSeverity.ERROR,
            translation_key="no_driver",
            translation_placeholders={"name": printer.get("model") or printer["id"]},
            learn_more_url="https://github.com/Gyang91/ha-airprint#drivers",
            **extra,
        )

    # A printer that was removed or renamed leaves its repair behind. Only
    # clean up from a full report: right after a restart the add-on lists no
    # printers yet, and deleting then would also forget an issue's "ignore".
    if not printers or not coordinator.last_update_success:
        return

    current = {f"{NO_DRIVER}{printer['id']}" for printer in printers}
    for domain, issue_id in list(ir.async_get(hass).issues):
        if domain == DOMAIN and issue_id.startswith(NO_DRIVER) and issue_id not in current:
            ir.async_delete_issue(hass, DOMAIN, issue_id)


async def async_reload_entry(hass: HomeAssistant, entry: AirPrintConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: AirPrintConfigEntry) -> bool:
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
