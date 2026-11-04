from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant.config_entries import (
    ConfigEntry,
    ConfigFlow,
    ConfigFlowResult,
    ConfigSubentryData,
    ConfigSubentryFlow,
    SubentryFlowResult,
)
from homeassistant.const import CONF_HOST, CONF_PORT
from homeassistant.core import callback
from homeassistant.helpers.selector import (
    EntitySelector,
    EntitySelectorConfig,
    NumberSelector,
    NumberSelectorConfig,
    NumberSelectorMode,
    SelectOptionDict,
    SelectSelector,
    SelectSelectorConfig,
    SelectSelectorMode,
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)
from homeassistant.helpers.service_info.zeroconf import ZeroconfServiceInfo

from .const import (
    CONF_POWER_OFF_AFTER,
    CONF_POWER_SWITCH,
    DEFAULT_ICON,
    DEFAULT_POWER_OFF_AFTER,
    DEFAULT_PORT,
    DOMAIN,
    ICONS,
    SUBENTRY,
    device_name,
    driver_error,
    label,
)
from .coordinator import async_fetch_status

# The add-on and Home Assistant both run on the host network, so a manual
# setup on the same machine reaches the status feed here.
DEFAULT_HOST = "127.0.0.1"


def driver_field() -> TextSelector:
    return TextSelector(TextSelectorConfig(type=TextSelectorType.URL))


DRIVER_SCHEMA = vol.Schema({vol.Optional("driver"): driver_field()})


def printer_schema(discovered: list[dict], editing: bool = False) -> vol.Schema:
    fields: dict[Any, Any] = {vol.Optional("name"): TextSelector()}

    if not editing:
        if len(discovered) > 1:
            fields[vol.Required("device", default=discovered[0]["device"])] = SelectSelector(
                SelectSelectorConfig(
                    options=[
                        SelectOptionDict(
                            value=found["device"],
                            label=f"{found['name']} ({found['address']})",
                        )
                        for found in discovered
                    ],
                    mode=SelectSelectorMode.LIST,
                )
            )
        elif not discovered:
            fields[vol.Required("device", default="")] = TextSelector()

    fields[vol.Optional("location")] = TextSelector()
    fields[vol.Optional("icon")] = SelectSelector(
        SelectSelectorConfig(options=ICONS, mode=SelectSelectorMode.DROPDOWN)
    )
    # A smart plug (switch) or a presser such as a SwitchBot Bot (button, or a
    # switch in press mode). See power.py.
    fields[vol.Optional(CONF_POWER_SWITCH)] = EntitySelector(
        EntitySelectorConfig(domain=["switch", "button"])
    )
    fields[vol.Optional(CONF_POWER_OFF_AFTER)] = NumberSelector(
        NumberSelectorConfig(
            min=0, max=240, step=1, unit_of_measurement="min", mode=NumberSelectorMode.BOX
        )
    )

    if editing:
        fields[vol.Optional("driver")] = driver_field()

    return vol.Schema(fields)


def found_text(discovered: list[dict]) -> str:
    if not discovered:
        return "No new printers found on the network. Enter the printer's IP address below."
    return "Found on your network: " + ", ".join(
        f"{found['name']} ({found['address']})" for found in discovered
    )


def printer_suggested(discovered: list[dict], current: dict[str, Any] | None = None) -> dict:
    current = current or {}
    return {
        "name": current.get("name")
        or (discovered[0].get("name", "") if discovered else ""),
        "location": current.get("location", ""),
        "icon": current.get("icon", DEFAULT_ICON),
        "driver": current.get("driver", ""),
        CONF_POWER_SWITCH: current.get(CONF_POWER_SWITCH, ""),
        CONF_POWER_OFF_AFTER: current.get(CONF_POWER_OFF_AFTER, DEFAULT_POWER_OFF_AFTER),
    }


def printer_data(
    user_input: dict[str, Any], discovered: list[dict], current: dict[str, Any] | None = None
) -> dict[str, Any]:
    current = current or {}

    device = user_input.get("device") or current.get("device")
    found = next((d for d in discovered if d["device"] == device), None)

    if not device and discovered:
        device = discovered[0]["device"]
        found = discovered[0]

    discovered_name = (
        current.get("discovered_name")
        or (found or {}).get("name")
        or device_name(device or "")
    )
    name = user_input.get("name", "").strip() or discovered_name

    return {
        "icon": user_input.get("icon", ""),
        "name": name,
        "device": device or "",
        "driver": user_input.get("driver", current.get("driver", "")).strip(),
        "location": user_input.get("location", ""),
        "discovered_name": discovered_name,
        CONF_POWER_SWITCH: user_input.get(CONF_POWER_SWITCH, current.get(CONF_POWER_SWITCH, "")),
        CONF_POWER_OFF_AFTER: int(
            user_input.get(
                CONF_POWER_OFF_AFTER, current.get(CONF_POWER_OFF_AFTER, DEFAULT_POWER_OFF_AFTER)
            )
        ),
    }


def has_driver(discovered: list[dict], device: str) -> bool:
    """False only for a printer on the network that no driver matched."""
    found = next((d for d in discovered if d["device"] == device), None)
    return bool(found is None or found.get("driver"))


class PrinterSteps:
    """Adding a printer, shared by the first setup and "Add a printer".

    A subclass provides _discovered and _finish (which creates the entry).
    """

    _discovered: list[dict]
    _printer: dict[str, Any] | None = None

    def _finish(self, printer: dict[str, Any]) -> Any:
        raise NotImplementedError

    async def _async_add(self, user_input: dict[str, Any]) -> Any:
        printer = printer_data(user_input, self._discovered)

        if not has_driver(self._discovered, printer["device"]):
            self._printer = printer
            return await self.async_step_driver()

        return self._finish(printer)

    def _show_printer_form(self, step_id: str, placeholders: dict[str, str]) -> Any:
        suggested = printer_suggested(self._discovered)
        return self.async_show_form(
            step_id=step_id,
            data_schema=self.add_suggested_values_to_schema(
                printer_schema(self._discovered), suggested
            ),
            description_placeholders={
                **placeholders,
                "default": suggested["name"] or "the printer's name",
                "found": found_text(self._discovered),
            },
        )

    async def async_step_driver(self, user_input: dict[str, Any] | None = None) -> Any:
        assert self._printer is not None
        errors: dict[str, str] = {}

        if user_input is not None:
            url = user_input.get("driver", "").strip()
            if error := driver_error(url):
                errors["driver"] = error
            else:
                return self._finish({**self._printer, "driver": url})

        return self.async_show_form(
            step_id="driver",
            data_schema=self.add_suggested_values_to_schema(DRIVER_SCHEMA, user_input or {}),
            errors=errors,
            description_placeholders={"name": self._printer["name"]},
        )


class AirPrintConfigFlow(PrinterSteps, ConfigFlow, domain=DOMAIN):
    VERSION = 1

    def __init__(self) -> None:
        self._host: str | None = None
        self._port: int = DEFAULT_PORT
        self._discovered: list[dict] = []
        self._printer: dict[str, Any] | None = None

    @classmethod
    @callback
    def async_get_supported_subentry_types(
        cls, config_entry: ConfigEntry
    ) -> dict[str, type[ConfigSubentryFlow]]:
        return {SUBENTRY: PrinterSubentryFlow}

    async def _async_status(self) -> dict[str, Any]:
        try:
            return await async_fetch_status(self.hass, self._host, self._port)
        except Exception:
            return {}

    async def async_step_zeroconf(self, discovery_info: ZeroconfServiceInfo) -> ConfigFlowResult:
        self._host = discovery_info.host
        self._port = discovery_info.port or DEFAULT_PORT

        await self.async_set_unique_id(DOMAIN)
        self._abort_if_unique_id_configured(updates={CONF_HOST: self._host, CONF_PORT: self._port})

        status = await self._async_status()
        self._discovered = status.get("discovered", [])
        printers = status.get("printers", [])

        if self._discovered:
            name = self._discovered[0].get("name") or "AirPrint"
        elif printers:
            name = printers[0].get("name") or "AirPrint"
        else:
            name = "AirPrint"

        self.context["title_placeholders"] = {"host": self._host, "name": name}

        if printers:
            return self.async_create_entry(
                title="AirPrint", data={CONF_HOST: self._host, CONF_PORT: self._port}
            )

        return await self.async_step_confirm()

    def _finish(self, printer: dict[str, Any]) -> ConfigFlowResult:
        return self.async_create_entry(
            title="AirPrint",
            data={CONF_HOST: self._host, CONF_PORT: self._port},
            subentries=[
                ConfigSubentryData(
                    data=printer,
                    subentry_type=SUBENTRY,
                    title=label(printer),
                    unique_id=printer["device"] or printer["name"],
                )
            ],
        )

    async def async_step_confirm(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is not None:
            return await self._async_add(user_input)

        return self._show_printer_form("confirm", {"host": self._host or ""})

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is not None:
            await self.async_set_unique_id(DOMAIN)
            self._abort_if_unique_id_configured()
            return self.async_create_entry(title="AirPrint", data=user_input)

        return self.async_show_form(
            step_id="user",
            data_schema=vol.Schema(
                {
                    vol.Required(CONF_HOST, default=DEFAULT_HOST): str,
                    vol.Required(CONF_PORT, default=DEFAULT_PORT): int,
                }
            ),
        )


class PrinterSubentryFlow(PrinterSteps, ConfigSubentryFlow):
    def __init__(self) -> None:
        self._printer: dict[str, Any] | None = None

    @property
    def _discovered(self) -> list[dict]:
        return self._get_entry().runtime_data.discovered

    def _finish(self, printer: dict[str, Any]) -> SubentryFlowResult:
        return self.async_create_entry(
            title=label(printer),
            data=printer,
            unique_id=printer["device"] or printer["name"],
        )

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> SubentryFlowResult:
        if user_input is not None:
            return await self._async_add(user_input)

        return self._show_printer_form("user", {})

    async def async_step_reconfigure(
        self, user_input: dict[str, Any] | None = None
    ) -> SubentryFlowResult:
        subentry = self._get_reconfigure_subentry()
        current = dict(subentry.data)
        errors: dict[str, str] = {}

        if user_input is not None:
            # A cleared field is left out of the form's data: no driver, no switch.
            user_input = {
                **user_input,
                "driver": user_input.get("driver", ""),
                CONF_POWER_SWITCH: user_input.get(CONF_POWER_SWITCH, ""),
            }
            if error := driver_error(user_input["driver"], current.get("driver", "")):
                errors["driver"] = error
            else:
                printer = printer_data(user_input, self._discovered, current)
                return self.async_update_and_abort(
                    self._get_entry(), subentry, title=label(printer), data=printer
                )

        return self.async_show_form(
            step_id="reconfigure",
            data_schema=self.add_suggested_values_to_schema(
                printer_schema(self._discovered, editing=True),
                {**printer_suggested(self._discovered, current), **(user_input or {})},
            ),
            errors=errors,
            description_placeholders={
                "default": current.get("discovered_name") or current.get("name", "")
            },
        )
