"""Power control: switch a printer on when a job waits, and off again when idle.

Two kinds of power switch:
- a plug (a switch entity with a real state): on and off are safe to repeat;
- a presser (a button entity, or a switch that only assumes its state, like a
  SwitchBot Bot): every press toggles the printer. The printer's own Online
  state decides instead: press to wake it only while it is offline, wait
  before pressing again, and never more than twice for the same jobs, so a
  printer that is still booting is not pressed off again.

Only a printer this switched on is switched off again: one someone switched
on by hand (to copy or scan) is left alone.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta

from homeassistant.core import HomeAssistant, callback
from homeassistant.util import dt as dt_util

from .const import CONF_POWER_OFF_AFTER, CONF_POWER_SWITCH, DEFAULT_POWER_OFF_AFTER

_LOGGER = logging.getLogger(__name__)

# A woken printer is given this long to answer before it is pressed again.
WAKE_RETRY = timedelta(minutes=5)
WAKE_ATTEMPTS = 2


class PrinterPower:
    def __init__(self, hass: HomeAssistant, printer: dict) -> None:
        self.hass = hass
        self.name = printer.get("name", "")
        self.device = printer.get("device", "")
        self.entity_id = printer.get(CONF_POWER_SWITCH, "")
        minutes = printer.get(CONF_POWER_OFF_AFTER, DEFAULT_POWER_OFF_AFTER)
        self.off_after = timedelta(minutes=float(minutes or 0))

        self.woken = False  # switched on by this, so it may switch it off
        self.attempts = 0
        self.last_attempt: datetime | None = None
        self.idle_since: datetime | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.entity_id)

    def _is_presser(self, state) -> bool:
        return self.entity_id.startswith("button.") or bool(state.attributes.get("assumed_state"))

    @callback
    def async_update(self, status: dict | None, now: datetime | None = None) -> None:
        """Called with the printer's status after every poll."""
        if not self.enabled or status is None:
            return
        state = self.hass.states.get(self.entity_id)
        if state is None or state.state == "unavailable":
            return

        now = now or dt_util.utcnow()
        presser = self._is_presser(state)
        online = bool(status.get("online"))

        if status.get("jobs"):
            self.idle_since = None
            self._wake(state, presser, online, now)
            return

        self.attempts = 0
        self._maybe_switch_off(state, presser, online, now)

    def _wake(self, state, presser: bool, online: bool, now: datetime) -> None:
        if online:
            self.attempts = 0
            return
        if not presser and state.state == "on":
            # Powered, still booting: nothing to switch.
            return
        if self.attempts >= WAKE_ATTEMPTS:
            return
        if self.last_attempt and now - self.last_attempt < WAKE_RETRY:
            return

        self.attempts += 1
        self.last_attempt = now
        self.woken = True
        _LOGGER.info("%s: a job is waiting, switching it on (%s)", self.name, self.entity_id)
        self._call("on", presser)

    def _maybe_switch_off(self, state, presser: bool, online: bool, now: datetime) -> None:
        if not self.woken or not self.off_after:
            return

        # Pressed on a moment ago and still booting: not off, wait.
        if presser and not online and self.last_attempt and now - self.last_attempt < WAKE_RETRY:
            return

        # Already off: switched off by hand, or went into standby by itself.
        if (presser and not online) or (not presser and state.state == "off"):
            self.woken = False
            self.idle_since = None
            return

        if self.idle_since is None:
            self.idle_since = now
            return
        if now - self.idle_since < self.off_after:
            return

        _LOGGER.info("%s: idle for %s, switching it off (%s)", self.name, self.off_after, self.entity_id)
        self.woken = False
        self.idle_since = None
        self._call("off", presser)

    def _call(self, action: str, presser: bool) -> None:
        domain = self.entity_id.split(".", 1)[0]
        if domain == "button":
            service = "press"
        elif presser and domain == "switch":
            # A presser toggles whichever service is called; "on" reads right.
            service = "turn_on" if action == "on" else "turn_off"
        else:
            service = f"turn_{action}"
        self.hass.async_create_task(
            self.hass.services.async_call(domain, service, {"entity_id": self.entity_id}),
            f"airprint power {self.entity_id}",
        )
