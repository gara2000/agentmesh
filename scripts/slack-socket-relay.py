#!/usr/bin/env python3
"""slack-socket-relay.py — Socket Mode WebSocket relay daemon

Connects to Slack via Socket Mode, forwards inbound thread replies to
signals/slackbridge-queue and fires slackbridge-event to wake SlackBridge.

This replaces the polling-based slack-poller.sh with a push-based approach:
instead of waking SlackBridge on a fixed timer, this daemon delivers events
immediately when Slack sends them over the WebSocket connection.

Usage:
    SLACK_APP_TOKEN=xapp-... SLACK_BOT_TOKEN=xoxb-... python3 slack-socket-relay.py

Environment:
    SLACK_APP_TOKEN  — Slack App-Level Token (required, must start with xapp-)
    SLACK_BOT_TOKEN  — Slack Bot Token (optional, but strongly recommended).
                       When provided, the relay calls conversations.join at
                       startup so the bot is a member of the configured channel
                       (signals/slack-channel). Without channel membership,
                       Slack does not deliver message.channels events to the
                       Socket Mode connection.

Queue entry format written to signals/slackbridge-queue:
    slack-message:<channel_id>:<thread_ts>:<user_id>:<text_escaped>

Both thread replies and top-level channel messages are forwarded. Bot
messages and non-message events are silently ignored.

Log events emitted to signals/events.log (TSV):
    started, message-received, reconnecting, stopped
"""

import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths — all derived dynamically from script location
# ---------------------------------------------------------------------------

AGENTMESH = Path(__file__).parent.parent
SIGNALS = AGENTMESH / "signals"
LOG = SIGNALS / "events.log"
QUEUE = SIGNALS / "slackbridge-queue"

# ---------------------------------------------------------------------------
# Import guard — clear error if slack_sdk is not installed
# ---------------------------------------------------------------------------

try:
    from slack_sdk.socket_mode import SocketModeClient
    from slack_sdk.socket_mode.request import SocketModeRequest
    from slack_sdk.socket_mode.response import SocketModeResponse
except ImportError:
    print(
        "Error: slack_sdk is not installed. Install it with:\n"
        "    pip install slack-sdk",
        file=sys.stderr,
    )
    sys.exit(1)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def log_event(event_type: str, slug: str = "-") -> None:
    """Append a TSV entry to signals/events.log."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(LOG, "a") as f:
            f.write(f"{timestamp}\tslack-socket \t{event_type}\t{slug}\n")
    except OSError:
        pass  # best-effort; don't crash the relay over a log write failure


def fire_slackbridge_event() -> None:
    """Fire slackbridge-event to wake SlackBridge."""
    subprocess.run(
        ["tmux", "wait-for", "-S", "slackbridge-event"],
        check=False,
        capture_output=True,
    )


def append_to_queue(entry: str) -> None:
    """Append a single entry line to signals/slackbridge-queue."""
    with open(QUEUE, "a") as f:
        f.write(entry + "\n")


def join_channel(bot_token: str, channel_id: str) -> None:
    """Attempt to join the channel so message.channels events are delivered.

    Slack only pushes message.channels events to a bot that is a member of
    the channel. If the bot is not in the channel, the Socket Mode connection
    is established but receives no messages — this is the most common reason
    for the relay being connected yet silent.

    For public channels, conversations.join adds the bot automatically.
    For private channels, the bot must be invited manually.
    """
    from slack_sdk import WebClient  # type: ignore[import]

    web = WebClient(token=bot_token)
    try:
        web.conversations_join(channel=channel_id)
        print(f"[slack-socket-relay] joined channel {channel_id}", flush=True)
        log_event("channel-joined")
    except Exception as exc:
        err = str(exc)
        if "already_in_channel" in err:
            print(
                f"[slack-socket-relay] already a member of channel {channel_id}",
                flush=True,
            )
        elif "method_not_supported_for_channel_type" in err:
            print(
                f"[slack-socket-relay] warning: channel {channel_id} is private — "
                "invite the bot manually with /invite @<bot> in the channel.",
                file=sys.stderr,
                flush=True,
            )
        else:
            print(
                f"[slack-socket-relay] warning: could not join channel {channel_id}: {exc}",
                file=sys.stderr,
                flush=True,
            )


def escape_text(text: str) -> str:
    """Collapse the message text to a single line for the queue entry.

    Replaces newlines with the literal two-character sequence \\n and strips
    carriage returns so the queue entry remains one line per message.
    """
    return text.replace("\r", "").replace("\n", "\\n")


# ---------------------------------------------------------------------------
# Socket Mode event handler
# ---------------------------------------------------------------------------


def handle_socket_mode_request(client: SocketModeClient, req: SocketModeRequest) -> None:
    """Process an incoming Socket Mode request.

    Acknowledges every request immediately (required by Slack to suppress
    retries), then filters down to qualifying message events (both thread
    replies and top-level channel messages) and writes them to
    slackbridge-queue.

    Queue entry format:
        slack-message:<channel_id>:<thread_ts>:<user_id>:<text_escaped>

    For thread replies, thread_ts is the parent message ts.
    For top-level messages, thread_ts equals the message's own ts (consistent
    with how Slack identifies thread roots).
    """
    # Always acknowledge to suppress Slack delivery retries.
    client.send_socket_mode_response(SocketModeResponse(envelope_id=req.envelope_id))

    if req.type != "events_api":
        return

    payload = req.payload or {}
    event = payload.get("event", {})
    event_type = event.get("type", "")

    # Only handle message events (message.channels, message.im, etc.)
    if not event_type.startswith("message"):
        return

    # Skip bot messages.
    if event.get("bot_id") or event.get("subtype") == "bot_message":
        return

    ts = event.get("ts", "")
    channel_id = event.get("channel", "")
    user_id = event.get("user", "")
    text = event.get("text", "")

    # Skip events missing required fields.
    if not channel_id or not user_id or not ts:
        return

    # For thread replies, thread_ts is the parent's ts.
    # For top-level messages, use the message's own ts as the thread anchor
    # (consistent with how Slack identifies thread roots).
    thread_ts = event.get("thread_ts") or ts

    text_escaped = escape_text(text)
    entry = f"slack-message:{channel_id}:{thread_ts}:{user_id}:{text_escaped}"

    append_to_queue(entry)
    fire_slackbridge_event()
    log_event("message-received")


# ---------------------------------------------------------------------------
# Main — connection loop with automatic reconnection
# ---------------------------------------------------------------------------


def main() -> None:
    # Validate required environment variable.
    app_token = os.environ.get("SLACK_APP_TOKEN", "")
    if not app_token:
        print(
            "Error: SLACK_APP_TOKEN environment variable is not set.\n"
            "Provide a Slack App-Level Token (xapp-...) via SLACK_APP_TOKEN.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Ensure signals directory exists (created by bootstrap, but guard anyway).
    SIGNALS.mkdir(parents=True, exist_ok=True)

    # Attempt to join the configured Slack channel so message.channels events
    # are delivered. Slack only pushes messages from channels the bot belongs to.
    bot_token = os.environ.get("SLACK_BOT_TOKEN", "")
    channel_file = SIGNALS / "slack-channel"
    channel_id = channel_file.read_text().strip() if channel_file.exists() else ""

    if channel_id:
        if bot_token:
            join_channel(bot_token, channel_id)
        else:
            print(
                f"[slack-socket-relay] warning: SLACK_BOT_TOKEN is not set. "
                f"Cannot verify or join channel {channel_id} automatically. "
                "If no messages are received, set SLACK_BOT_TOKEN so the relay "
                "can join the channel, or invite the bot manually.",
                file=sys.stderr,
                flush=True,
            )

    # Graceful shutdown flag — set by SIGTERM or SIGINT.
    shutdown_requested = False

    def handle_signal(signum, frame):  # noqa: ANN001
        nonlocal shutdown_requested
        shutdown_requested = True

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    client: SocketModeClient | None = None

    while not shutdown_requested:
        client = None
        try:
            client = SocketModeClient(app_token=app_token)
            client.socket_mode_request_listeners.append(handle_socket_mode_request)
            client.connect()

            log_event("started")
            print("[slack-socket-relay] connected — listening for Slack events", flush=True)

            # Keep-alive loop: sleep until shutdown or connection drop.
            while not shutdown_requested:
                if not client.is_connected():
                    break
                time.sleep(1)

        except Exception as exc:
            if shutdown_requested:
                break
            print(f"[slack-socket-relay] connection error: {exc}", file=sys.stderr, flush=True)
            log_event("reconnecting")
            _close_client(client)
            time.sleep(5)
            continue

        if not shutdown_requested:
            log_event("reconnecting")
            print("[slack-socket-relay] disconnected — reconnecting in 5s", flush=True)
            _close_client(client)
            time.sleep(5)

    _close_client(client)
    log_event("stopped")
    print("[slack-socket-relay] stopped", flush=True)
    sys.exit(0)


def _close_client(client: "SocketModeClient | None") -> None:
    """Close the Socket Mode client, ignoring any errors."""
    if client is None:
        return
    try:
        client.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
