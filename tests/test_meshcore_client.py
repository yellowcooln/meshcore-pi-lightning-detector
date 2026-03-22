from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock

from meshcore.events import Event, EventType

from app.config import MeshCoreSettings
from app.meshcore_client import MeshCoreChannelClient


def make_settings() -> MeshCoreSettings:
    return MeshCoreSettings(
        host="0.0.0.0",
        port=5000,
        channel_name="#lightning",
        channel_key="",
        channel_slot=0,
        always_configure_channel=True,
        connect_timeout_seconds=10.0,
    )


def make_client_with_send_result(result: Event) -> tuple[MeshCoreChannelClient, AsyncMock]:
    commands = SimpleNamespace(send_chan_msg=AsyncMock(return_value=result))
    mc = SimpleNamespace(commands=commands)
    client = MeshCoreChannelClient(make_settings())
    client._ensure_connected = AsyncMock(return_value=mc)
    client._configure_channel = AsyncMock()
    client.close = AsyncMock()
    return client, commands.send_chan_msg


class MeshCoreClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_send_message_does_not_retry_when_delivery_is_unconfirmed(self) -> None:
        client, send_chan_msg = make_client_with_send_result(
            Event(EventType.ERROR, {"reason": "no_event_received"})
        )

        with self.assertLogs("app.meshcore_client", level="WARNING") as logs:
            await client.send_message("test")

        self.assertEqual(send_chan_msg.await_count, 1)
        self.assertIn("may still have been delivered", "\n".join(logs.output))

    async def test_verify_channel_does_not_retry_when_probe_delivery_is_unconfirmed(self) -> None:
        client, send_chan_msg = make_client_with_send_result(
            Event(EventType.ERROR, {"reason": "no_event_received"})
        )

        with self.assertLogs("app.meshcore_client", level="WARNING") as logs:
            await client.verify_channel(probe_message="probe")

        self.assertEqual(send_chan_msg.await_count, 1)
        self.assertIn("probe may still have been delivered", "\n".join(logs.output))

    async def test_send_message_still_raises_for_real_errors(self) -> None:
        client, send_chan_msg = make_client_with_send_result(
            Event(EventType.ERROR, {"reason": "permission_denied"})
        )

        with self.assertRaisesRegex(RuntimeError, "permission_denied"):
            await client.send_message("test")

        self.assertEqual(send_chan_msg.await_count, 2)


if __name__ == "__main__":
    unittest.main()
