# Outbound API: Telegram bot and JSON webhook

xDrip4iOS can send every new glucose reading to a Telegram bot or to a web address of your own, as
a message you design. It is a port of the "Outbound API" of JugglucoNG (`OutboundApi.kt`,
`OutboundApiSettings.kt`), without the VK and Delta Chat presets. Nothing is sent until you add a
destination and switch it on.

**Status:** written without a Swift compiler and never tried against the real Telegram API or a
real webhook. The pure parts (template, trigger, interval, message editing, validation, requests,
response parsing, the dispatcher over a fake transport) have unit tests whose expected values
come from a Python port of the same logic.

## Where

Settings → Sharing and services → **Outbound API**. Add a destination with **Add a Telegram bot**
or **Add a JSON webhook**. Each destination has its own switch, trigger and interval, so one reading
can go to several places.

Every destination has a **Send a test message** button. It sends the newest reading of the last 12
hours at once, whatever the trigger, the interval and the unchanged-value rule say, and shows
whether the server accepted it.

## When a reading is sent

A reading is offered to the destinations when the app stores it: in the foreground, or during a
Bluetooth background wake (the app asks iOS for a few seconds of background time for the request).
The hook is in `RootApplicationCoordinator.processNewGlucoseData`, next to the Dexcom Share upload.
There is **no background timer** on iOS, so nothing is sent while no reading arrives.

For each destination that is on and complete, in this order (JugglucoNG order):

1. The reading must be usable (above 0 mg/dL) and at most 15 minutes old.
2. **Trigger**: *Every reading*, *Only when low* (at or below the low threshold), *Only when high*
   (at or above the high threshold) or *Only when low or high*. Both thresholds are inclusive and are
   edited in your glucose unit; they are stored in mg/dL, clamped to 1 to 600.
3. **Interval** (*At most every*, minutes): the time between the readings that were sent, taken from
   the readings' own time with 10 seconds of slack, so 5 minutes sends every reading of a sensor that
   reads every 5 minutes. 0 sends every reading. A reading already sent is never sent twice.
4. **Power saving** (Settings → Experimental features): while it applies and the value is not
   urgent (out of range), the interval is at least 5 minutes. Readings and alarms are not affected.

A send that fails is not repeated; the next reading is sent as usual. The state of each destination
(last sent, last attempt, last answer, last error) is shown on its screen.

## Telegram bot

Create a bot with @BotFather, paste its token, write to the bot (or add it to a group or channel)
and enter the chat id: a number (negative for groups and channels) or `@channelname`. Several chats
can be entered, separated by comma, semicolon or new line; each gets its own message.

Requests are `POST https://api.telegram.org/bot{token}/sendMessage` with `chat_id` and `text`
(JSON, text cut to 4096 characters). The token must look like `<digits>:<letters, digits, _ or ->`
so it cannot change the path of the URL.

- **Edit the last message** (default on, for 15 minutes, 1 to 60): inside that window the next
  reading edits the last message with `editMessageText` instead of posting a new one, so a chat does
  not fill with one message per reading. If Telegram answers "message is not modified" this counts
  as done; if the message is gone or cannot be edited, a new one is sent; after a rate limit
  (429) or a server error the message is kept for the next reading.
- **Skip a reading that did not change** (default 1 mg/dL, 0 to 100): inside the window a reading
  that differs from the shown value by less than this sends nothing, but keeps the message fresh.
  A test message is never skipped.
- **Note a gap in the readings**: JugglucoNG posts a "stale" and a "missed" message from a timer.
  iOS has no timer, so the silence is noticed when the **next** reading arrives: if the reading
  before it was received 10 minutes or more ago (*Stale after*) a note "Stale: no reading from
  HH:MM to HH:MM." is posted first, and after 15 minutes (*Missed after*) a "Missed readings" note.
  The reading after a note starts a new message instead of editing the one above the note. A phone
  that is off, or a sensor that never reconnects, therefore sends nothing at all.

## Custom JSON webhook

The reading is sent to the address with `POST`. The address and the headers are secrets (a
webhook URL often contains a key, a header often an `Authorization` value). Headers are one per line,
`Name: value`; a line without a name or value is ignored, and `Content-Type` is always
`application/json; charset=UTF-8`. Use `https`: iOS refuses plain `http` to most servers.

**Standard body** (when the body template is empty), schema `xdrip.outbound.glucose.v1`:

| Field | Meaning |
|---|---|
| `schema`, `type` | `xdrip.outbound.glucose.v1`, `glucose` |
| `destination_id`, `destination_preset` | the destination, `custom_json` |
| `event_id` | `{sensor}:{timestamp}:{mg/dL}`, stable for retries on your side |
| `test` | true for the test button |
| `app`, `sensor_id` | the app name, the sensor id |
| `timestamp` | time of the reading, milliseconds since 1970 |
| `glucose_mgdl`, `glucose_mmol` | rounded mg/dL, mmol/L with 2 decimals |
| `display_value`, `display_unit` | the value in your unit, and its unit |
| `trend`, `trend_arrow` | Nightscout trend name, arrow |
| `status` | `in_range`, `low` or `high` (against the trigger thresholds) |
| `message` | the rendered message template |
| `rate_mgdl_per_min`, `rate_mmol_per_min` | only when the app has a slope |

**Body template** (optional): a raw JSON text with placeholders, sent as it is. Values are escaped
for the inside of a JSON string, so put quotes around text values and none around numbers:
`{"bg": {mgdl}, "text": "{message}"}`. An invalid JSON template is the user's responsibility.

## Message template and placeholders

Both presets have a message template (Telegram: the text; webhook: `{message}`). A `{name}` is
replaced when it is known; an unknown `{name}` stays as written; inserted values are never scanned
again. A name holds no brace or whitespace.

| Placeholder | Value |
|---|---|
| `{value}`, `{unit}` | in your unit (mg/dL integer, mmol/L one decimal), and the unit |
| `{mgdl}`, `{mmol}` | always mg/dL (integer) and mmol/L (2 decimals) |
| `{trend}`, `{trend_arrow}` | Nightscout trend name and arrow; both empty when the trend is unknown |
| `{rate_mgdl}`, `{rate_mmol}` | change per minute (1 and 3 decimals); empty without a slope |
| `{status}`, `{status_emoji}` | `in_range`, `low`, `high` and a green, red or yellow circle |
| `{time}`, `{timestamp}` | date and time of the reading in your region's short format, milliseconds since 1970 |
| `{sensor}`, `{event_id}`, `{recipient}`, `{test}` | sensor id, event id, the chat id (Telegram), `true` or `false` |
| `{message}` | the rendered message template, only in a webhook body template |

Default Telegram text: `{status_emoji} {value} {unit} {trend_arrow} {time}`.

## Storage and privacy

- The bot token, the webhook URL and the headers are stored in the Keychain, one item per
  destination (generic password, *after first unlock, this device only*, not synchronised), so a
  Bluetooth wake with the phone locked can still send.
- Everything else (name, chat id, templates, trigger, interval) is JSON in UserDefaults
  (`outboundApiDestinations`); the delivery state is in `outboundApiState`. Both keys are excluded
  from backups, and so are the secrets.
- A stored error text is redacted: the token and the URL are replaced with `***`, because a server may
  echo the URL it was called with.
- Readings leave the phone only for destinations that are on. Telegram sees the messages you send
  to it; your webhook sees the body.

## Code

| File | What |
|---|---|
| `xDrip/Managers/OutboundApi/OutboundApi.swift` | model, template, trigger, interval, planner, requests, parsers, Keychain store, dispatcher, `OutboundApiManager` |
| `xDrip/SwiftUIViews/Settings/OutboundApiSettingsView.swift` | the settings screens |
| `xDrip Tests/OutboundApiTests.swift` | unit tests |
| `xDrip/Storyboards/{en,uk}.lproj/SettingsViews.strings` | strings, keys `outbound.*` |

The core types are plain values and thread-safe classes (`OutboundApiStore` takes a lock);
only `OutboundApiManager` runs on the main actor. Sending goes through the `OutboundApiTransport`
protocol, so the tests use a fake one.

## Not ported

- The VK and Delta Chat presets.
- JugglucoNG placeholders for insulin, carbs, raw values, battery, temperature, alarms and the
  journal (`{iob}`, `{cob}`, `{raw*}`, `{battery}`, `{temp}`, `{alarm}` and per-insulin tokens).
- The timer-based stale and missed message (replaced by the note before the next reading, see above).
- Automatic retries of a failed send, and an Activity Log entry per send (the result is on the
  destination's screen and in the debug trace).
- Sending from the calibration-accepted path or while live downstream work is paused: only the
  normal new-reading path sends.
- JugglucoNG shows a flat arrow for an unknown trend; here `{trend_arrow}` is empty, because a flat
  arrow for a slope the app could not compute would be wrong.
