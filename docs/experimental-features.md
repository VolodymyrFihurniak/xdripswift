# Experimental features

Settings → **Experimental features**. Everything here is off by default except the chart cursor,
and mostly changes the main chart on the Home screen; where a feature reaches widgets, the
watch, alerts or Nightscout, its section says so. AID sharing is never affected. The models are
ported from JugglucoNG (see `THIRD_PARTY_NOTICES.md`).

## Glucose on the chart

**Points** is xDrip's usual one dot per reading. **Line** joins the readings in their range
colour, as JugglucoNG does. The line breaks where two readings are more than 17 minutes apart
(JugglucoNG `GlucoseChartGap`), so missing data still looks missing.

The choice also applies to the home screen and lock screen widgets, the Live Activity (Dynamic
Island, Smart Stack and CarPlay included), the watch app and the rotated day-comparison chart
(landscape, and the iPad AGP view). Companions pick it up with the next reading. The small
overview chart under the main chart keeps its dots.

## Chart cursor

JugglucoNG's scrub cursor, on by default. Touch the glucose line (within 26 points; JugglucoNG
uses 32 dp), or hold a finger still anywhere on the main chart for 0.4 s, then slide. A thin
vertical line and a ring mark the nearest reading within 15 minutes, or the forecast point to
the right of the newest reading. A card above the chart shows:

- the time (with the weekday when it is not today) and the glucose;
- IOB and every insulin still on board at that moment, with the experimental insulins on;
  otherwise xDrip's own IOB and COB when the Treatments curves are shown;
- the bolus, basal injection and carbs logged at that moment.

The cursor stays after the finger lifts; the next touch, a pinch or a double tap clears it.
Each new reading under the finger gives a light haptic tick.

## Glucose prediction

A dashed line to the right of the main chart, for 1–4 hours (default 2). It is JugglucoNG's
`GlucosePredictionKernel`:

- it starts at the newest reading, and only if that reading is at most 15 minutes old;
- **Follow the trend** adds the recent slope that the logged treatments do not explain
  (least squares over up to 10 readings in the last 45 minutes, at most 3 mg/dL or
  0.16 mmol/L a minute), fading as `t·e^(−t/70)`;
- a slow pull toward the middle of the low/high range: 18 % of the distance over about 4 hours;
- the effect of logged treatments from the last 36 hours:
  - carbs: `grams ÷ carb ratio × sensitivity`, absorbed along a smoothstep over
    `grams ÷ absorption rate` (30 minutes to 6 hours);
  - boluses: `units × sensitivity`, delivered along the insulin's action curve;
  - exercise: JugglucoNG's unknown-intensity drop for the logged duration;
  - basal and premixed insulins are not counted, as in JugglucoNG presets.

Defaults are JugglucoNG's: sensitivity 54 mg/dL (3.0 mmol/L) per unit, carb ratio 10 g/U,
absorption 35 g/h. It is an estimate for orientation, never a dosing tool.

While **Show prediction** is on, the forecast is also drawn on the medium and large widgets, the
Live Activity and the watch chart. It travels as a start time plus five-minute values, so the
Live Activity payload stays small; data from older builds decodes without it. The landscape view
is a day-by-day AGP comparison, not a live chart, so it does not show the forecast.

Model refinements (JugglucoNG `PredictionModelProfile`, `JournalHumanProfile`, `JournalFoodMath`):

- **Time-of-day periods**: up to seven start times after midnight, each with its own sensitivity,
  carb ratio and absorption. Each treatment uses the values in force when it was logged.
- **Body weight** (10–400 kg, optional): curves measured per kilogram (Fiasp, Levemir, regular,
  NovoMix) are interpolated at `units ÷ weight` instead of the study's reference dose.
- **Protein and fat**: with the switch on, the treatment editor asks for protein and fat on a
  carb entry (stored in its notes as `P:20 F:15`). They add a delayed carb-equivalent rise:
  fat-protein units `(4·protein + 9·fat) ÷ 100`, 30–65 % of 10 g per unit, starting 50–110 min
  after the meal and lasting 90–480 min.
- **Exercise intensity**: the editor offers light, moderate or intense (notes `intensity:light`),
  scaling the drop by 0.35, 0.65 or 1; not set keeps 0.5.

### Adaptive prediction

JugglucoNG's adaptive ("personal") forecast (`AdaptiveGlucoseForecast`), off by default. It
learns from your own readings what the standard model assumes: how much of the recent movement
tends to carry on, and how strongly glucose drifts back toward your own average.

- One ridge regression (λ = 1) per horizon, every 5 minutes out to 2 hours, predicting the
  change from the current reading. Eight features from CGM history only: the change over the
  last 5, 15, 30 and 60 minutes, the distance from the 24-hour mean, the level and the time of
  day. Logged insulin and carbs are not used (on JugglucoNG's data they made it worse).
- Trained on the last 28 days on a 5-minute grid, from the displayed value; it needs 576 rows
  (two days) before it answers. A value is never read across a sensor change or a gap longer
  than 2.5 readings, and the hour behind a reading must be continuous, so a new sensor's first
  hour and the hour after a gap have no adaptive forecast.
- With four days or more, the last two days are held back once: if the model's 30-minute error
  there is more than 2 % worse than assuming no change, it is not used.
- It relearns once a day on a background queue (after a new reading, or when the chart asks);
  a fit that found too little data is retried after six hours. **Relearn now** forgets the model.
  The model is stored in the app's settings; **Learned model** shows learning, learned from N
  days, or not better than no change yet.
- Drawn dotted, at most 2 hours ahead, also on widgets, Live Activity and the watch. When it
  cannot answer, the standard forecast without the trend momentum is drawn instead, as
  JugglucoNG does. The predicted low alert and the Nightscout upload always use the standard
  forecast; the chart cursor reads whichever is drawn.
- With **Record accuracy** on, the adaptive forecast from the same reading is recorded too, and
  **Prediction accuracy** shows the two side by side.

### Prediction accuracy

**Record accuracy** keeps the forecast every five minutes for 14 days (a file in Application
Support) and **Prediction accuracy** compares it with the glucose that followed, as JugglucoNG's
prediction analysis does: for 15, 30, 60 and 120 minutes ahead it shows the mean absolute error,
the bias (positive means the forecast ran high) and the error of simply assuming no change.
Readings are interpolated across gaps of at most 2.5 reading intervals (6–20 minutes). A horizon
needs at least 36 compared forecasts before it says much.

### Nightscout

**Upload to Nightscout** sends the forecast every five minutes as an OpenAPS-style devicestatus
(`openaps.suggested.predBGs.IOB`, five-minute steps from the newest reading), the way AAPS does,
so Nightscout's forecast lines show it with the openaps plugin enabled. It is unavailable while
xDrip follows an AID's status from Nightscout, so the AID's own lines stay the only ones. Boluses
upload the chosen insulin as `notes`, carb entries their `protein` and `fat`, exercise its
intensity note.

### Predicted low alert

Settings → Alerts → **Predicted Low** (off by default) warns before a low: it fires when the
forecast falls below the alarm value within the lead time (15–45 minutes, default 20, set in
Experimental features → Glucose prediction) while glucose is still above that value. Once glucose
is below it, the ordinary Low alarm takes over. Sound, schedule and snooze work as for every alarm.
The alert uses the prediction model even when the forecast is not drawn on the chart.

## Insulins

Each insulin has its own action curve from JugglucoNG's catalogue (model version 3): Fiasp,
Lyumjev (dose-dependent), NovoRapid/NovoLog, Humalog, Apidra, regular, NPH, Lantus, Toujeo,
Levemir, Tresiba, Awiqli, U-500, Ryzodeg and the premixes. xDrip has no body weight, so curves
measured per kilogram use the study's reference dose.

- A bolus or basal injection uses the insulin named in its notes ("Tresiba", "NovoRapid",
  "Humalog Mix 25", Ukrainian names too). With the feature on, the treatment editor offers a
  picker for boluses and a list for basal injections. Otherwise the default bolus insulin
  (initially the Treatments insulin type) or basal insulin applies.
- **Show insulin activity on the chart** draws how fast each insulin is working, in units per
  hour, as coloured layers stacked along the bottom (JugglucoNG `InsulinActivityStack`). One
  dose's layer adds up to the dose. Steady-state curves (Toujeo, Tresiba) are reduced to one
  daily dose as `S(t) − S(t + 24 h)`. A curve ends where its source stopped measuring.
- A legend at the top left of the main chart names the colour of each insulin in view.
- **Insulin on board** (JugglucoNG `JournalIobMath`): each dose's remaining units are the share
  of its action curve still to come, all of it at the injection and none once the curve ends.
  The shapes are the chart band's, so what is left matches the area still to be drawn. The card
  at the top left of the main chart shows IOB of the rapid insulins (the ones that count toward
  the forecast) and the basal insulin still on board now; a tap lists each insulin with its
  units and when its last dose stops acting. The chart cursor shows the same at any moment.
- On the chart, a basal injection sits on the bolus row and is moved sideways when a bolus
  marker would cover it. The treatment editor and the Treatments filters list basal right
  after bolus.
- The IOB/COB numbers and curves of the Treatments settings are unchanged.

## Power saving

Settings → Experimental features → **Power saving**: Off (default), On, or Automatic (while iPhone
Low Power Mode is on or the battery is at 25 % or less). Nothing is saved while the phone charges.
While it saves:

- Nightscout, Apple Health and Dexcom Share take one reading per five minutes instead of every
  reading (the "every reading" toggles are kept and apply again afterwards);
- the Live Activity and the widgets refresh at most every five minutes, at once when the newest
  reading is at or outside the low/high marks;
- the Home chart redraws xDrip's IOB/COB, the forecast and the insulin layers every five minutes
  instead of every minute (a new reading still redraws the forecast);
- the adaptive prediction does not relearn until the phone charges.

Readings, alarms (the predicted low alert included), the watch and the Nightscout forecast upload
are never slowed down.

## Basal insulin and the chart

A basal injection is stored with Nightscout's Note event type. Before this fork's fix it was taken
for an imported note once uploaded, so Tresiba and the other basal insulins had no activity layer
and no insulin on board. Basal injections now always count. With the insulin layers on, xDrip's
own IOB curve is not drawn (it covered them in the same colour); COB stays.

## Additions from JugglucoNG 1.2–1.3

- **Predicted low: Consider IOB and recent glucose** (JugglucoNG `ForecastLowConfidencePolicy`,
  off by default). The alert then needs a falling trend (at least 0.5 mg/dL a minute over the
  last ten minutes) and carbs on board that do not cover the shortfall. It alerts at once within
  15 mg/dL of the value, when the current rate reaches it within ten minutes, or when insulin
  acting in the next 30 minutes explains half the distance (and 10 mg/dL). With no insulin on
  board, a fall that only returns from a recent rise (quiet five-minute baseline, then at least
  15 mg/dL up in 3–15 minutes) waits while glucose is above baseline − 3 mg/dL. Otherwise two
  readings a minute apart must agree. Low and Very Low are untouched.
- **Alarms** screen: *No High alarm while falling* (High stays quiet while glucose falls by
  0.5 mg/dL a minute or more; Very High always alarms) and *Notify when signal is restored* (one
  notification when readings return after a gap as long as the Missed Reading delay, or 30 min).
- **eIOB** on the active insulin card: IOB weighted by how hard each dose is acting now.
- **Nightscout**: the forecast devicestatus also carries `openaps.iob.iob` and `suggested.COB`
  from the logged treatments.
- **Grouped markers**: boluses (and carbs) closer together than a marker's width are drawn as one
  marker with their total and count, e.g. `7.5 ×3`.
- Sibionics battery level is read and shown for Sibionics 2 only, as JugglucoNG does.

Sensor expiry already has two alarms upstream (Sensor Ending Soon, Expected Expiry), so
JugglucoNG's multiple expiry warnings were not ported.

## Alarm episodes

Settings → Experimental features → Alarms, both off by default (adapted from JugglucoNG's alert
episodes to xDrip's snooze-based alarms):

- **End snooze when back in range** — a snoozed Low, Very Low, High or Very High alarm is unsnoozed
  once glucose is at least 9 mg/dL (0.5 mmol/L) back on the safe side of its value. A second low
  an hour after the first then alarms at once instead of waiting out the old snooze. The margin
  keeps a value hovering on the limit from re-alarming; Snooze All is not affected.
- **Fast change alarms once per episode** — Fast Drop and Fast Rise alarm once, then stay quiet
  until a reading no longer meets their condition.

## Dose hints

Settings → Experimental features → Glucose prediction → **Dose hints** (off by default). A port of
JugglucoNG's `StateDoseHintCalculator`: one line above the Home chart, read off the current state.
**It is arithmetic, not medical advice.**

- *Carbs*: glucose is falling (recency-weighted slope over 30 minutes at or below −0.3 mg/dL a
  minute, no rise in the last five minutes), insulin is on board, and at this rate glucose is
  below the dose target within 45 minutes. Amount = the gap between the 45-minute projection and
  the target ÷ sensitivity × carb ratio, rounded up, at least 5 g.
- *Correction*: glucose is above the range (or, with *Also correct inside the range*, more than
  25 mg/dL above the target) and has not been coming down for 20 minutes. Amount = (current −
  target) ÷ sensitivity − all IOB, rounded **down** to 0.5 U.
- Nothing within 20 mg/dL of the target. Dose target 70–180 mg/dL, default 90.

## Restricted mode

Settings → Experimental features → **Restricted mode**: with a 4–8 digit PIN set, the Settings and
Devices tabs open only after it is entered, and lock again when the app goes to the background.
Readings, alarms, the chart and treatments stay available. The PIN is kept in the app's settings
unencrypted; reinstalling the app removes it.

## Food library

In the treatment editor, a carbs entry has a **Food library** button (it needs no setting). Pick
foods, set their amounts in grams (or tap a portion such as "+1 piece"), and **Use** fills in the
meal's carbs — and its protein and fat when *Protein and fat* is on. The meal itself is not stored,
only the totals; the amount last used for a food is remembered.

- **Staples**: JugglucoNG's 232 common foods with values per 100 g, named in Ukrainian or English.
- **Your own foods**: *New food*, from a nutrition label (per 100 g, optional portion weight).
  Swipe to delete.
- **Open Food Facts**: packaged products by name (*Search Open Food Facts*, on a button — the
  project asks apps not to search on every keystroke) or by barcode (*Scan a barcode*, iOS 16
  devices that support live scanning). A product you pick is kept with your own foods, so it works
  offline next time. Products without a carbohydrate value are left out.

Nothing is sent anywhere until you search or scan: a search sends the typed words, a scan sends the
barcode, to `openfoodfacts.org`. Open Food Facts is filled in by volunteers — check the figures
against the package.

## Insulin pens (NFC)

Settings → Experimental features → **Insulin pens (NFC)** reads the dose log of a **NovoPen 6** or
**NovoPen Echo Plus** and adds the doses you confirm to the treatments.

> This reader is a port of JugglucoNG's (itself from xDrip+'s OpenNov) and has **not yet been
> confirmed on a real pen from an iPhone**. Its protocol code is tested against a simulated pen
> only. Check the first imports against the pen's own display.

1. **Scan a pen** and hold the top of the iPhone against the pen's dose display until the system
   sheet says the pen was read. A long log takes several seconds; if the read is cut short, what
   arrived is still offered (the pen sends its newest doses first) and the next scan gets the rest.
2. A new pen is listed under **Pens** by its serial number. Choose its insulin: a pen with a basal
   or premixed insulin logs basal injections, any other pen logs boluses named after the insulin,
   so the insulin curves and insulin on board use the right profile.
3. The review lists the doses newer than the last import, newest first. Ticked doses become
   treatments. A dose of 2 U or less within a minute before another is taken for an air shot and
   starts unticked; so does a dose that already has a treatment of the same size within five
   minutes. Unticked doses are not offered again, unless **Read the whole log next time** is on.

The pen has no clock, only a counter: dose times are that counter set against the phone's clock at
the moment of the scan. Doses older than 100 days are ignored. Nothing is imported without the
review, and iOS only reads a pen while this screen's scan is running.
