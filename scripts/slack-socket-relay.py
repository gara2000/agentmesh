#!/usr/bin/env python3
"""slack-socket-relay.py — Socket Mode WebSocket relay daemon

Connects to Slack via Socket Mode, forwards inbound thread replies to
signals/slackbridge-queue and fires slackbridge-event to wake SlackBridge.

This replaces the polling-based slack-poller.sh with a push-based approach:
instead of waking SlackBridge on a fixed timer, this daemon delivers events
immediately when Slack sends them over the WebSocket connection.

Usage:
    SLACK_APP_TOKEN=xapp-... python3 slack-socket-relay.py

Environment:
    SLACK_APP_TOKEN  — Slack App-Level Token (required, must start with xapp-)

Queue entry format written to signals/slackbridge-queue:
    slack-message:<channel_id>:<thread_ts>:<user_id>:<text_escaped>

Only thread replies are forwarded. Top-level messages, bot messages, and
non-message events are silently ignored.

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
    retries), then filters down to qualifying thread-reply message events and
    writes them to slackbridge-queue.
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

    thread_ts = event.get("thread_ts")
    ts = event.get("ts", "")

    # Skip top-level (non-threaded) messages and the parent message itself.
    # A thread reply has thread_ts set to the parent's ts, and its own ts differs.
    if not thread_ts or ts == thread_ts:
        return

    channel_id = event.get("channel", "")
    user_id = event.get("user", "")
    text = event.get("text", "")

    # Skip events missing required fields.
    if not channel_id or not user_id:
        return

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
