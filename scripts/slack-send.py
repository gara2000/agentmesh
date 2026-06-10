#!/usr/bin/env python3
"""slack-send.py — Post and update Slack messages via slack_sdk.WebClient.

This script replaces Slack MCP tool calls for sending messages. It reads the
message text from stdin so multiline content is handled safely.

Usage:
    # Post a new channel message:
    echo "text" | python3 slack-send.py post --channel CHANNEL_ID

    # Post a thread reply:
    echo "text" | python3 slack-send.py post --channel CHANNEL_ID --thread-ts THREAD_TS

    # Update an existing message:
    echo "new text" | python3 slack-send.py update --channel CHANNEL_ID --ts MSG_TS

Environment:
    SLACK_BOT_TOKEN — Slack Bot Token (required, must start with xoxb-)

Output: JSON on stdout.
    post:   {"ok": true, "ts": "...", "channel": "..."}
    update: {"ok": true, "ts": "...", "channel": "..."}

Exit codes:
    0 — success
    1 — error (slack_sdk not installed, token missing, API error)
"""

import argparse
import json
import os
import sys

# ---------------------------------------------------------------------------
# Import guard — clear error if slack_sdk is not installed
# ---------------------------------------------------------------------------

try:
    from slack_sdk import WebClient
    from slack_sdk.errors import SlackApiError
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


def get_client() -> WebClient:
    """Return a WebClient using SLACK_BOT_TOKEN from the environment."""
    token = os.environ.get("SLACK_BOT_TOKEN", "")
    if not token:
        print(
            "Error: SLACK_BOT_TOKEN environment variable is not set.\n"
            "Provide a Slack Bot Token (xoxb-...) via SLACK_BOT_TOKEN.",
            file=sys.stderr,
        )
        sys.exit(1)
    return WebClient(token=token)


def read_text() -> str:
    """Read message text from stdin."""
    return sys.stdin.read()


# ---------------------------------------------------------------------------
# Sub-commands
# ---------------------------------------------------------------------------


def cmd_post(args: argparse.Namespace) -> None:
    """Post a new message or thread reply via chat.postMessage."""
    client = get_client()
    text = read_text()

    kwargs: dict = {
        "channel": args.channel,
        "text": text,
    }
    if args.thread_ts:
        kwargs["thread_ts"] = args.thread_ts

    try:
        response = client.chat_postMessage(**kwargs)
    except SlackApiError as exc:
        print(
            f"Error: Slack API error: {exc.response['error']}",
            file=sys.stderr,
        )
        sys.exit(1)

    result = {
        "ok": True,
        "ts": response["ts"],
        "channel": response["channel"],
    }
    print(json.dumps(result))


def cmd_update(args: argparse.Namespace) -> None:
    """Update an existing message via chat.update."""
    client = get_client()
    text = read_text()

    try:
        response = client.chat_update(
            channel=args.channel,
            ts=args.ts,
            text=text,
        )
    except SlackApiError as exc:
        print(
            f"Error: Slack API error: {exc.response['error']}",
            file=sys.stderr,
        )
        sys.exit(1)

    result = {
        "ok": True,
        "ts": response["ts"],
        "channel": response["channel"],
    }
    print(json.dumps(result))


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Post or update Slack messages via slack_sdk.WebClient.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # post
    post_parser = subparsers.add_parser("post", help="Post a message (text from stdin)")
    post_parser.add_argument("--channel", required=True, help="Slack channel ID")
    post_parser.add_argument(
        "--thread-ts",
        metavar="THREAD_TS",
        default=None,
        help="Thread timestamp to reply into (omit for a top-level post)",
    )

    # update
    update_parser = subparsers.add_parser("update", help="Update a message (text from stdin)")
    update_parser.add_argument("--channel", required=True, help="Slack channel ID")
    update_parser.add_argument("--ts", required=True, help="Timestamp of the message to update")

    return parser


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "post":
        cmd_post(args)
    elif args.command == "update":
        cmd_update(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
