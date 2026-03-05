# URC Response File Schema v1

## Location
`.urc/responses/{PANE}.json` — one file per pane, overwritten each turn.

## Fields
| Field | Type | Required | Source |
|---|---|---|---|
| v | integer | yes | schema version (always 1) |
| pane | string | yes | $TMUX_PANE |
| cli | string | yes | detected from payload structure |
| turn_id | string | no | from hook payload (turn-id for Codex, session_id for Gemini) |
| epoch | integer | yes | epoch seconds at hook execution |
| ts | string | yes | ISO-8601 timestamp |
| response | string | yes | last_assistant_message / prompt_response |
| input | string | no | input_messages / prompt |
| len | integer | yes | character length of response |
| sha256 | string | yes | sha256 of response text |

## Atomic Write Protocol
1. Write to `.urc/responses/.tmp.XXXXXX`
2. `mv` temp to `.urc/responses/{PANE}.json`

## Correlation Protocol
Dispatcher records `dispatch_timestamp` (epoch seconds) BEFORE sending.
Response file includes `epoch` from the hook (epoch seconds).
Dispatcher validates `response.epoch > dispatch_timestamp` before accepting.
If stale (epoch <= dispatch_timestamp), waits for the next signal.

## Signal Ordering (non-negotiable)
1. Write response file (data available)
2. Touch `signals/done_{PANE}` (durable signal for pre-check)
3. `tmux wait-for -S "urc_done_{PANE}"` (instant notification)
4. Append to JSONL stream (observability, best-effort)
