"""The "needs a driver" repair: Fix asks for the driver link right there."""

from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant.components.repairs import RepairsFlow
from homeassistant.core import HomeAssistant
from homeassistant.data_entry_flow import FlowResult

from .config_flow import driver_field
from .const import SUBENTRY, driver_error


async def async_create_fix_flow(
    hass: HomeAssistant, issue_id: str, data: dict[str, str | int | float | None] | None
) -> RepairsFlow:
    return DriverRepairFlow(data or {})


class DriverRepairFlow(RepairsFlow):
    def __init__(self, data: dict[str, Any]) -> None:
        self._entry_id = str(data.get("entry_id", ""))
        self._device = str(data.get("device", ""))
        self._name = str(data.get("name", ""))

    def _printer(self):
        entry = self.hass.config_entries.async_get_entry(self._entry_id)
        if entry is None:
            return None, None
        subentry = next(
            (
                sub
                for sub in entry.subentries.values()
                if sub.subentry_type == SUBENTRY and sub.data.get("device") == self._device
            ),
            None,
        )
        return entry, subentry

    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        return await self.async_step_driver()

    async def async_step_driver(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        entry, subentry = self._printer()
        if subentry is None:
            return self.async_abort(reason="printer_removed")

        errors: dict[str, str] = {}
        if user_input is not None:
            url = user_input.get("driver", "").strip()
            if not url:
                errors["driver"] = "driver_required"
            elif error := driver_error(url):
                errors["driver"] = error
            else:
                # Saving the printer reloads the integration, which hands the
                # link to the add-on; the add-on restarts and installs it. The
                # repair comes back if the driver still does not work.
                self.hass.config_entries.async_update_subentry(
                    entry, subentry, data={**subentry.data, "driver": url}
                )
                return self.async_create_entry(data={})

        return self.async_show_form(
            step_id="driver",
            data_schema=self.add_suggested_values_to_schema(
                vol.Schema({vol.Required("driver"): driver_field()}), user_input or {}
            ),
            errors=errors,
            description_placeholders={"name": self._name or subentry.title},
        )
