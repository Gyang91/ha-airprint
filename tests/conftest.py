"""Shared fixtures. Runs against a real Home Assistant core
(pytest-homeassistant-custom-component), with the add-on's status feed and
the Supervisor mocked."""

from __future__ import annotations

import copy
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

HOST = "192.168.1.100"
PORT = 8099
URL = f"http://{HOST}:{PORT}/status.json"

DEVICE = "dnssd://HP Laser MFP 131 133 135-138._pdl-datastream._tcp.local/"
OTHER = "dnssd://Brother HL-L2350DW._pdl-datastream._tcp.local/"

# Shaped like the real feed (see the README's examples).
STATUS = {
    "slug": "0f9301c3_airprint",
    "printers": [
        {
            "id": "HP_Laser",
            "device": DEVICE,
            "name": "🖨️ HP Laser",
            "model": "HP Laser MFP 131 133 135-138",
            "driver": "everywhere",
            "host": "192.168.1.50",
            "online": True,
            "problem": False,
            "jobs": 0,
            "toner": 64,
            "supply": "Black Toner",
            "pages": 1234,
            "reasons": [],
        }
    ],
    "discovered": [],
}

PRINTER = {
    "icon": "🖨️",
    "name": "HP Laser",
    "device": DEVICE,
    "location": "Office",
    "discovered_name": "HP Laser MFP 131 133 135-138",
    "driver": "",
}

# What the add-on's options hold for PRINTER (the integration's _printer()).
OPTION = {"icon": "🖨️", "name": "HP Laser", "location": "Office", "device": DEVICE}


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations(enable_custom_integrations):
    yield


@pytest.fixture
def status():
    return copy.deepcopy(STATUS)


@pytest.fixture
def feed(aioclient_mock, status):
    aioclient_mock.get(URL, json=status)
    return aioclient_mock


@pytest.fixture
def addon():
    """The Supervisor side: what the add-on's options hold, and the calls made."""
    manager = MagicMock()
    manager.options = {"printers": [dict(OPTION)], "networks": []}

    async def info():
        return MagicMock(options=copy.deepcopy(manager.options))

    async def set_options(options):
        manager.options = copy.deepcopy(options)

    manager.async_get_addon_info = AsyncMock(side_effect=info)
    manager.async_set_addon_options = AsyncMock(side_effect=set_options)
    manager.async_restart_addon = AsyncMock()

    from custom_components.airprint.coordinator import AirPrintCoordinator

    if hasattr(AirPrintCoordinator, "_addon"):
        target = patch.object(AirPrintCoordinator, "_addon", return_value=manager)
    else:
        # The code before the AddonManager change, for comparing against it.
        async def supervisor(self, method, path, json=None):
            if path.endswith("/info"):
                return {"data": {"options": copy.deepcopy(manager.options)}}
            if path.endswith("/options"):
                manager.options = copy.deepcopy(json["options"])
            return {}

        target = patch.object(AirPrintCoordinator, "_supervisor", supervisor)

    with target:
        yield manager
