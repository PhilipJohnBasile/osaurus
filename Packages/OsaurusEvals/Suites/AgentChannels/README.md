# Agent Channels Eval Checklist

This is a docs-only checklist for Slack and Telegram Agent Channel release
proof. Runnable JSON cases are intentionally deferred because the current eval
harness does not provide a fixture hook to seed native Slack/Telegram
connection config, inject fake provider clients, or pre-populate the Agent
Channel message store without adding harness/source wiring outside this release
asset task.

## Runnable cases

JSON cases in this directory exercise the `agent_channel_*` tool family through
the standard `agent_loop` runner. Full Slack/Telegram provider seeding remains
future work; these cases prove list/send wiring against the isolated config store.

| Case | Proves |
| --- | --- |
| `list-connections` | `agent_channel_list_connections` executes without error |
| `no-unapproved-send` | `agent_channel_send_message` without `confirm_send` fails closed |

## Proof To Run Now

Use the no-secret smoke script:

```bash
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

For focused source-backed fixtures:

```bash
OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1 \
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

For provider setup and live disposable-room proof, follow
`docs/AGENT_CHANNELS_SLACK_TELEGRAM_SETUP.md` and
`docs/CHANNEL_RELEASE_RUNBOOK_SLACK_TELEGRAM.md`.
