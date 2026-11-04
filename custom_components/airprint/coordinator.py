from __future__ import annotations

import logging
from datetime import timedelta
from typing import Any

import aiohttp
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.hassio import is_hassio
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .const import ADDON_NAME, DOMAIN, UPDATE_INTERVAL

_LOGGER = logging.getLogger(__name__)


async def async_fetch_status(hass: HomeAssistant, host: str, port: int) -> dict[str, Any]:
    """Read the add-on's status feed (/status.json). Raises on any failure."""
    session = async_get_clientsession(hass)
    async with session.get(
        f"http://{host}:{port}/status.json", timeout=aiohttp.ClientTimeout(total=15)
    ) as response:
        response.raise_for_status()
        return await response.json(content_type=None)


class AirPrintCoordinator(DataUpdateCoordinator):
    def __init__(self, hass: HomeAssistant, host: str, port: int) -> None:
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=UPDATE_INTERVAL),
        )
        self._host = host
        self._port = port
        self.slug: str | None = None
        self.discovered: list[dict] = []

    async def _async_update_data(self) -> dict:
        try:
            data = await async_fetch_status(self.hass, self._host, self._port)
        except Exception as err:
            raise UpdateFailed(f"Cannot reach the AirPrint add-on: {err}") from err

        self.slug = data.get("slug") or self.slug
        self.discovered = data.get("discovered", [])

        return {printer["device"]: printer for printer in data.get("printers", [])}

    def _addon(self):
        if not is_hassio(self.hass):
            raise RuntimeError("Not running under the Home Assistant Supervisor")

        # Imported here: the hassio component only exists under the Supervisor.
        from homeassistant.components.hassio import AddonManager

        return AddonManager(self.hass, _LOGGER, ADDON_NAME, self.slug)

    async def async_get_options(self) -> dict:
        if not self.slug:
            return {}
        info = await self._addon().async_get_addon_info()
        return dict(info.options or {})

    async def async_get_printers(self) -> list[dict]:
        return (await self.async_get_options()).get("printers", [])

    async def async_save_printers(self, printers: list[dict]) -> None:
        if not self.slug:
            raise RuntimeError("The AirPrint add-on was not found")

        options = await self.async_get_options()
        options["printers"] = printers

        addon = self._addon()
        await addon.async_set_addon_options(options)
        await addon.async_restart_addon()
