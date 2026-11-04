"""Power control (power.py): plugs and pressers such as a SwitchBot Bot."""

from __future__ import annotations

from datetime import timedelta

import pytest
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import async_mock_service

from custom_components.airprint.power import PrinterPower

NOW = dt_util.utcnow()


def at(minutes: float):
    return NOW + timedelta(minutes=minutes)


def status(jobs=0, online=False):
    return {"jobs": jobs, "online": online}


@pytest.fixture
def plug(hass):
    hass.states.async_set("switch.printer_plug", "off")
    calls = {
        "on": async_mock_service(hass, "switch", "turn_on"),
        "off": async_mock_service(hass, "switch", "turn_off"),
    }
    power = PrinterPower(hass, {"name": "P", "device": "d", "power_switch": "switch.printer_plug", "power_off_after": 15})
    return power, calls


@pytest.fixture
def bot(hass):
    hass.states.async_set("button.printer_bot", "unknown")
    presses = async_mock_service(hass, "button", "press")
    power = PrinterPower(hass, {"name": "P", "device": "d", "power_switch": "button.printer_bot", "power_off_after": 10})
    return power, presses


async def test_plug_on_for_a_job_and_off_when_idle(hass, plug):
    power, calls = plug
    power.async_update(status(jobs=1), at(0))
    await hass.async_block_till_done()
    assert len(calls["on"]) == 1

    hass.states.async_set("switch.printer_plug", "on")
    power.async_update(status(jobs=1, online=True), at(1))
    power.async_update(status(jobs=0, online=True), at(2))  # printed: idle from here
    power.async_update(status(jobs=0, online=True), at(16))
    await hass.async_block_till_done()
    assert calls["off"] == []
    power.async_update(status(jobs=0, online=True), at(17))
    await hass.async_block_till_done()
    assert len(calls["off"]) == 1


async def test_plug_switched_on_by_hand_stays_on(hass, plug):
    power, calls = plug
    hass.states.async_set("switch.printer_plug", "on")
    power.async_update(status(jobs=1, online=True), at(0))
    power.async_update(status(jobs=0, online=True), at(1))
    power.async_update(status(jobs=0, online=True), at(60))
    await hass.async_block_till_done()
    assert calls["on"] == [] and calls["off"] == []


async def test_plug_already_on_while_booting_is_not_switched_again(hass, plug):
    power, calls = plug
    hass.states.async_set("switch.printer_plug", "on")
    power.async_update(status(jobs=1, online=False), at(0))
    await hass.async_block_till_done()
    assert calls["on"] == []


async def test_new_job_restarts_the_idle_time(hass, plug):
    power, calls = plug
    power.async_update(status(jobs=1), at(0))
    hass.states.async_set("switch.printer_plug", "on")
    power.async_update(status(jobs=0, online=True), at(1))
    power.async_update(status(jobs=1, online=True), at(10))
    power.async_update(status(jobs=0, online=True), at(11))
    power.async_update(status(jobs=0, online=True), at(20))
    await hass.async_block_till_done()
    assert calls["off"] == []


async def test_zero_minutes_leaves_it_on(hass):
    hass.states.async_set("switch.printer_plug", "off")
    off = async_mock_service(hass, "switch", "turn_off")
    async_mock_service(hass, "switch", "turn_on")
    power = PrinterPower(hass, {"name": "P", "device": "d", "power_switch": "switch.printer_plug", "power_off_after": 0})
    power.async_update(status(jobs=1), at(0))
    hass.states.async_set("switch.printer_plug", "on")
    power.async_update(status(jobs=0, online=True), at(1))
    power.async_update(status(jobs=0, online=True), at(500))
    await hass.async_block_till_done()
    assert off == []


async def test_bot_presses_once_while_the_printer_boots(hass, bot):
    power, presses = bot
    power.async_update(status(jobs=1, online=False), at(0))
    # Still booting: pressing again would switch it off.
    power.async_update(status(jobs=1, online=False), at(1))
    power.async_update(status(jobs=1, online=False), at(4))
    await hass.async_block_till_done()
    assert len(presses) == 1


async def test_bot_tries_twice_at_most(hass, bot):
    power, presses = bot
    for minute in (0, 6, 12, 18, 24):
        power.async_update(status(jobs=1, online=False), at(minute))
    await hass.async_block_till_done()
    assert len(presses) == 2


async def test_bot_presses_off_only_while_the_printer_is_on(hass, bot):
    power, presses = bot
    power.async_update(status(jobs=1, online=False), at(0))
    power.async_update(status(jobs=0, online=True), at(2))
    power.async_update(status(jobs=0, online=True), at(13))
    await hass.async_block_till_done()
    assert len(presses) == 2  # on, then off


async def test_bot_leaves_a_printer_that_went_to_standby(hass, bot):
    power, presses = bot
    power.async_update(status(jobs=1, online=False), at(0))
    power.async_update(status(jobs=0, online=True), at(2))
    # It went into standby by itself: pressing now would switch it on.
    power.async_update(status(jobs=0, online=False), at(8))
    power.async_update(status(jobs=0, online=False), at(30))
    await hass.async_block_till_done()
    assert len(presses) == 1


async def test_bot_cancelled_job_while_booting_still_switches_off(hass, bot):
    power, presses = bot
    power.async_update(status(jobs=1, online=False), at(0))
    power.async_update(status(jobs=0, online=False), at(1))  # cancelled, still booting
    power.async_update(status(jobs=0, online=True), at(3))
    power.async_update(status(jobs=0, online=True), at(14))
    await hass.async_block_till_done()
    assert len(presses) == 2


async def test_switch_in_press_mode_counts_as_a_presser(hass):
    hass.states.async_set("switch.bot", "off", {"assumed_state": True})
    on = async_mock_service(hass, "switch", "turn_on")
    power = PrinterPower(hass, {"name": "P", "device": "d", "power_switch": "switch.bot", "power_off_after": 10})
    power.async_update(status(jobs=1, online=False), at(0))
    power.async_update(status(jobs=1, online=False), at(2))
    await hass.async_block_till_done()
    assert len(on) == 1


async def test_unavailable_switch_is_left_alone(hass, plug):
    power, calls = plug
    hass.states.async_set("switch.printer_plug", "unavailable")
    power.async_update(status(jobs=1), at(0))
    await hass.async_block_till_done()
    assert calls["on"] == []
