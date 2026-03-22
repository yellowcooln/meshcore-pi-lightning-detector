from __future__ import annotations

from dataclasses import dataclass
import asyncio
import logging
import time

from meshcore import MeshCore
from meshcore.events import EventType

from app.config import MeshCoreSettings


logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ChannelTarget:
    name: str
    key_bytes: bytes
    slot: int
    always_configure_channel: bool


class MeshCoreChannelClient:
    def __init__(self, settings: MeshCoreSettings):
        self.settings = settings
        self.target = ChannelTarget(
            name=settings.channel_name,
            key_bytes=settings.channel_secret_bytes(),
            slot=settings.channel_slot,
            always_configure_channel=settings.always_configure_channel,
        )
        self._mc: MeshCore | None = None
        self._channel_loaded = False

    async def connect(self) -> None:
        logger.info("Connecting to MeshCore TCP node at %s:%d", self.settings.host, self.settings.port)
        self._mc = await asyncio.wait_for(
            MeshCore.create_tcp(
                host=self.settings.host,
                port=self.settings.port,
                auto_reconnect=False,
            ),
            timeout=self.settings.connect_timeout_seconds,
        )
        if self._mc is None:
            raise RuntimeError("MeshCore connection returned no client")
        self._channel_loaded = False

    async def close(self) -> None:
        if self._mc is not None:
            await self._mc.disconnect()
            self._mc = None
            self._channel_loaded = False

    async def send_message(self, text: str) -> None:
        last_error: Exception | None = None
        for attempt in range(2):
            try:
                mc = await self._ensure_connected()
                if self.target.always_configure_channel or not self._channel_loaded:
                    await self._configure_channel(mc)
                result = await mc.commands.send_chan_msg(
                    chan=self.target.slot,
                    msg=text,
                    timestamp=int(time.time()),
                )
                confirmed = self._raise_for_unexpected_result(
                    result,
                    no_response_message="MeshCore send returned no response",
                    error_prefix="MeshCore send failed",
                    ambiguous_warning=(
                        "MeshCore did not confirm the channel message for %s. "
                        "The message may still have been delivered, so the app will not retry."
                    ),
                )
                if confirmed:
                    logger.info("Sent channel message to %s", self.target.name)
                else:
                    logger.info(
                        "Submitted channel message to %s without confirmation",
                        self.target.name,
                    )
                return
            except Exception as exc:
                last_error = exc
                logger.warning("MeshCore send attempt %d failed: %s", attempt + 1, exc)
                await self.close()
        if last_error is not None:
            raise last_error
        raise RuntimeError("MeshCore send failed for an unknown reason")

    async def verify_channel(self, probe_message: str | None = None) -> None:
        last_error: Exception | None = None
        for attempt in range(2):
            try:
                mc = await self._ensure_connected()
                await self._configure_channel(mc)
                if probe_message:
                    result = await mc.commands.send_chan_msg(
                        chan=self.target.slot,
                        msg=probe_message,
                        timestamp=int(time.time()),
                    )
                    confirmed = self._raise_for_unexpected_result(
                        result,
                        no_response_message="MeshCore verify send returned no response",
                        error_prefix="MeshCore verify send failed",
                        ambiguous_warning=(
                            "MeshCore did not confirm the verification probe for %s. "
                            "The probe may still have been delivered, so the app will not retry."
                        ),
                    )
                    if confirmed:
                        logger.info("Sent verification probe to %s", self.target.name)
                    else:
                        logger.info(
                            "Submitted verification probe to %s without confirmation",
                            self.target.name,
                        )
                return
            except Exception as exc:
                last_error = exc
                logger.warning("MeshCore verify attempt %d failed: %s", attempt + 1, exc)
                await self.close()
        if last_error is not None:
            raise last_error
        raise RuntimeError("MeshCore verify failed for an unknown reason")

    async def _ensure_connected(self) -> MeshCore:
        if self._mc is None or not self._mc.is_connected:
            await self.connect()
        if self._mc is None:
            raise RuntimeError("MeshCore client is not connected")
        return self._mc

    async def _configure_channel(self, mc: MeshCore) -> None:
        logger.info("Configuring MeshCore channel slot %d for %s", self.target.slot, self.target.name)
        result = await mc.commands.set_channel(
            channel_idx=self.target.slot,
            channel_name=self.target.name,
            channel_secret=self.target.key_bytes,
        )
        if result is None:
            raise RuntimeError("MeshCore set_channel returned no response")
        if result.type == EventType.ERROR:
            raise RuntimeError(f"MeshCore set_channel failed: {result.payload}")
        self._channel_loaded = True

    def _raise_for_unexpected_result(
        self,
        result,
        *,
        no_response_message: str,
        error_prefix: str,
        ambiguous_warning: str,
    ) -> bool:
        if result is None:
            raise RuntimeError(no_response_message)
        if self._is_unconfirmed_success(result):
            logger.warning(ambiguous_warning, self.target.name)
            return False
        if result.type == EventType.ERROR:
            raise RuntimeError(f"{error_prefix}: {result.payload}")
        return True

    @staticmethod
    def _is_unconfirmed_success(result) -> bool:
        if result.type != EventType.ERROR:
            return False
        if not isinstance(result.payload, dict):
            return False
        return result.payload.get("reason") == "no_event_received"
