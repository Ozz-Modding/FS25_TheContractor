# Console commands

You type these into the developer console. You don't need cheats on. There are four group commands and a help command:

| Command | What it covers |
|---|---|
| `tcHelp` | Lists the groups below |
| `tcWorker` | Hire, list and change your staff |
| `tcJob` | List, offer, create and force jobs |
| `tcFinance` | Invoices, claims and botched jobs |
| `tcCompany` | Reputation, Overview notices and random events |

Type a group on its own (or with `help`) to list its subcommands and their arguments. Subcommand names aren't case-sensitive. If you get the arguments wrong, the command prints that subcommand's usage.

- **Your farm:** every command acts on your current farm. Most need that farm to have created a company first.
- **Server only:** commands that change something only work on the server, which means single player or the host of a multiplayer game. The read-only lists `tcWorker list`, `tcWorker pool`, `tcJob list`, `tcJob log`, `tcCompany storages`, `tcCompany notices`, `tcCompany vehicleLog`, `tcCompany events` and `tcWorker standing` also work on a joined client.
- **`<worker>`:** a hired worker's id, or the start of their first or last name. `amy`, `Hall` and `3` could all mean Amy Hall (#3). If a name matches more than one worker, the command lists them and asks for the id. `tcWorker list` shows ids and names.

## Workers — `tcWorker`

### `tcWorker list`

Lists your farm's hired workers with their ids. Each line shows the name, status, age, morale (0-100, with its band) and crop care skill, then where they stand on the spraying certificate:
- certified
- booked, with the course days left, the next course day and the assessment day (monotonic days)
- failed, retake due
- not certified, ready or not ready

If any apply, it also shows declined training requests, a booked holiday or one they've asked for (monotonic days), holiday requests refused this year (server only) and when they're leaving (retiring or quitting).

```
Farm 1 workers (today is day 104):
#3 Amy Hall - training, age 34, morale 72 (content), crop care 5, spraying: booked (1 course day(s) left, next day 104, assessment day 107)
#7 John Smith - idle, age 58, morale 24 (unhappy), crop care 2, spraying: not certified, not ready; quitting March, Year 3
```

### `tcWorker pool`

Lists the candidates currently available to hire, with their id, name, work speed, salary (the full-month rate, see `tcWorker pay`), the tractor sizes they can drive and their operation skills.

### `tcWorker hire <candidate>`

Hires a candidate from the staff pool. Like `<worker>`, `<candidate>` is an id or the start of a name, from `tcWorker pool`.

```
tcWorker hire 3
tcWorker hire smith
```

### `tcWorker rename <worker> <new name>`

Renames one of your hired workers, the same as the Staff tab's Edit without changing their gender or look. Everything after `<worker>` is the new name, so it can have spaces. Leading and trailing spaces are trimmed, and the name must be 1-30 characters.

```
tcWorker rename 2 Jane Smith
tcWorker rename amy Amelia
```

### `tcWorker retire <worker> [noticeMonths]`

Makes one of your hired workers hand in their retirement notice. `noticeMonths` defaults to 6; `0` retires them straight away.

```
tcWorker retire 2
tcWorker retire amy 0
```

### `tcWorker quit <worker> [noticeMonths]`

Makes one of your hired workers quit, as if their morale had run out. They leave like a retiring worker: a notification, an Overview notice, and they go at the start of the month `noticeMonths` from now. `noticeMonths` defaults to 1; `0` makes them leave straight away (or as soon as they're back from a job). It fails if the worker is already leaving.

```
tcWorker quit 2
tcWorker quit amy 0
```

### `tcWorker morale <worker> [value]`

Shows one of your hired workers' morale, its band, this month's busy and idle days, the morale it's drifting toward at the next month roll, and their chance of quitting then. The target includes how their pay against what they expect moves it (`pay`, see `tcWorker pay`). With `value` (0-100), it sets their morale first. The change syncs to everyone.

```
tcWorker morale 2
tcWorker morale amy 20
```

Prints, for example:

```
Amy Hall: morale 20.0 (unhappy), 3 busy / 1 idle days this month (target 62.0, pay -8.0), quit chance 8%
```

### `tcWorker pay <worker> [salary]`

Shows one of your hired workers' pay and what drives their pay reviews:
- **paid:** their monthly pay.
- **market value:** what hiring them new would cost.
- **expects:** their expected pay, and how far their pay is above or below it.
- **loyalty:** the discount their years of service give.
- **morale target:** how their pay moves their monthly morale drift.
- **last review:** when they last had a pay review.

With `salary`, it sets their monthly pay first. This can cut it, which the game itself never does. The change syncs to everyone.

All figures here, and the `salary` you give, are full-month rates. With fewer than 5 days per month the game pays less than that: 60% at 1 day, rising evenly to the full rate at 5. The menu shows the reduced amount, so it won't match these figures.

```
tcWorker pay 2
tcWorker pay amy 2500
```

Prints, for example:

```
Amy Hall: paid 2500, market value 2985, expects 2910 (-14.1%), loyalty 0.95 after 1 year(s), morale target -9.1, last review March, Year 3
```

### `tcWorker payReview <worker> [expected]`

Gives one of your hired workers their pay review now, as if it were their hire anniversary. They roll a new expected pay, or take `expected` if you give it, but never less than they're paid. If it's more than 5% above their pay, they ask for a rise in your inbox, replacing any request they already had open.

```
tcWorker payReview 2
tcWorker payReview amy 3200
```

### `tcWorker harvestBonus`

Posts the harvest bonus question to your inbox now, as if it were the start of August. It does nothing if you have no staff, or the question is already in your inbox.

```
tcWorker harvestBonus
```

### `tcWorker sick <worker> [inspect]`

Makes one of your hired workers fall sick now, through the same path as the daily sickness roll.
- **With the health and safety programme:** the bout uses the programme's shorter spells.
- **Without it:** the inspection roll (3%) runs. `inspect` makes the inspection certain, so you can see the fine, notice and reputation hit.

A worker out on a job goes off sick once they're back. It fails if the worker is already sick or on holiday.

```
tcWorker sick 2
tcWorker sick amy inspect
```

### `tcWorker holidayRequest`

Has one of your hired workers ask for a holiday now, as the daily roll would, but certainly and for the earliest start: an inbox request you can approve or decline, starting in 3 days (the usual notice) for half to all of their allowance. It takes no arguments. Whoever has been refused most this year goes first (then the lowest id), so running it again walks one worker through a decline, the warning on the second refusal and then a holiday booked without asking. A worker running out of year also books without asking. Workers who already have a holiday booked or asked for, are leaving, are booked on training or have no allowance left are skipped.

```
tcWorker holidayRequest
```

### `tcWorker train <worker> [daysFromNow] [pass|fail|mechanic|electrician|bodyworker]`

Books one of your hired workers on spraying training, or on an Advanced Damage System workshop trade course (092), for free, skipping the readiness check.
- **What gets booked:** a worker who failed their assessment gets the retake (an assessment day only). Anyone else gets the 2-day course, with the assessment 2-5 days after it (at short months the course is capped at a month and the wait shrinks with it: at 1 day a month, a 1-day course and the assessment the next day).
- **`daysFromNow`:** defaults to 0, so an idle worker starts today.
- **`pass` or `fail`:** fixes the assessment's result. Without it, the result is rolled from their crop care skill.
- **`mechanic`, `electrician` or `bodyworker`:** books a trade course instead (`diagnostician`, ADS's own id for the electrician, works too): the next level of that trade (level 1 if they don't have it), with no assessment. The trade goes up a level when the last course day is done. It works without ADS, but not past level 3 or for a third trade.

It fails if the worker is already certified (for spraying) or already has training booked.

```
tcWorker train 2
tcWorker train amy 0 fail
tcWorker train amy 0 mechanic
```

### `tcWorker askTraining <worker>`

Makes one of your hired workers ask for spraying training now, through the inbox, as if the monthly roll had come up. They must be ready (crop care 4+), not certified and not already booked or asking.

```
tcWorker askTraining 2
```

### `tcWorker certify <worker> [on|off]`

Gives one of your hired workers the spraying certificate, or takes it away with `off`. `on` is the default. Useful for testing who can be allocated to herbicide jobs.

```
tcWorker certify 2
tcWorker certify 2 off
```

### `tcWorker standing`

Shows, for each of your hired workers, whether they're standing on one of your farm's standing spots, and if not, why. Only workers who are idle or in a cooldown stand, and only between 07:00 and 19:00 game time. Outside those hours a line under the heading says so and every idle worker shows `gone home` (or `gone home once you look away`, if they're still on a spot you can see). Otherwise each line gives the spot they're assigned today (its position in decimetres) and how far it is from the camera, then one of:
- waiting until you look away (nobody appears on a spot you can see)
- waiting for another worker to leave the spot
- standing, model not loaded (models load within 150 m)
- standing, model loading
- standing, shown, or hidden (too far)
- standing, but their look couldn't be loaded

This only shows what your own machine is displaying, so it also works on a joined client.

```
Farm 1: 2 standing spot(s), day 104
#3 Amy Hall - wants spot 1203:-455, 12 m away, standing, shown
#7 John Smith - not standing (assigned)
```

### `tcWorker adsSkill <worker> <mechanic|electrician|bodyworker> <0-3>`

Sets one of a hired worker's Advanced Damage System workshop skills (091) to a level, or removes it with `0`. The trades are named as ADS shows them; `diagnostician`, its own id for the electrician, works too. A worker can have at most two: set one to `0` before adding a third. Removing the skill a worker is working in the workshop as takes them out of the workshop. `<worker>` is their id or name. It prints the worker's skills afterwards. It works without ADS too, but the skills only show and count toward pay while ADS's own workshop is taking your staff.

```
tcWorker adsSkill 7 mechanic 2
tcWorker adsSkill Sam Hill bodyworker 0
```

## Jobs — `tcJob`

### `tcJob list [state|all]`

Lists your farm's jobs with their ids, for the other job commands. Each line shows the job, its field, state and price. Where they apply, it adds how far along it is, when it's due (date and monotonic day) and who's on it: worker names, or "you" for a job you're doing yourself. Read-only, so it also works on a joined client.

| Argument | Meaning |
|---|---|
| `state` | Optional. With no argument it lists open jobs (not yet completed, declined or missed). Give a state to list only that one (`offered`, `negotiating`, `accepted`, `allocated`, `in_progress`, `completed`, `declined`, `missed`), or `all` for every job. |

```
tcJob list
tcJob list accepted
```

```
Farm 1 jobs (open, today is day 212):
#12 Harvest & Haul (Canola), field 37 - in_progress, 4,267 €, 45% done, due August 1, Year 1 (day 213), crew John White, Grace Hughes
#14 Cultivate, field 12 - accepted, 1,180 €, due September 1, Year 1 (day 244)
```

### `tcJob offer <jobType>`

Offers your farm a job of the given type right now, through the normal job generator. You get a real offer on a real field, with the usual price, deadline and required skill, so the game could have offered the same job by itself. This is useful for testing and for setting up a storyline.

- No `jobType` lists the available types.
- Job types (case-insensitive): `harvest`, `cultivate`, `sow`, `plow`, `mow`, `tedder`, `bale`, `baleWrap`, `strawDelivery`, `fertilize`, `herbicide`, `weed`, `hoe`, `stonePick`.
- A `harvest` offer, or a `bale` offer on a straw crop, sometimes includes delivery (Harvest & Haul, Bale & Deliver), just as a generated offer would. `strawDelivery` is only possible when a selling point on the map takes straw bales.
- It picks a field your farm has the equipment for when it can, and falls back to any eligible field otherwise.
- It fails only when the generator itself couldn't offer that type right now, and the output says why. Examples are harvest in winter, weeding on a save with weeds off, or a crop whose ready date can't be predicted. Use `tcJob availability` to see which types have work available.

```
tcJob offer mow
```

### `tcJob availability`

A dry run of job generation for your farm. It changes nothing. It shows the current hourly offer chance and the expected number of offers per period. For each job type it lists:

- **eligible fields**: fields you don't own that qualify for the job type right now
- **with target date**: eligible fields that also have a workable deadline
- **fulfillable**: fields from that list your farm owns the equipment for

### `tcJob create <jobType> <fieldId> <skill> <price> <period> <day>`

Creates a job with every detail set by hand. Unlike `tcJob offer`, nothing is checked: the field doesn't have to suit the job type and the date doesn't have to be workable. Use it to test specific edge cases.

| Argument | Meaning |
|---|---|
| `jobType` | One of the job types listed under `tcJob offer` |
| `fieldId` | Field id |
| `skill` | Expected skill level, 1–10 |
| `price` | Payout in money, at the current price level. With FS25_EconomyScale loaded, the job's price follows that mod's factor afterwards, like any other job |
| `period` | Due period (1–12) |
| `day` | Due day within that period |

```
tcJob create plow 12 3 5000 4 1
```

### `tcJob state <jobId> <state>`

Forces a job into another state. Only legal transitions are allowed:

| From | To |
|---|---|
| `offered` | `negotiating`, `accepted`, `declined` |
| `negotiating` | `accepted`, `declined` |
| `accepted` | `allocated`, `missed` |
| `allocated` | `in_progress`, `completed`, `missed`, `accepted` |
| `in_progress` | `completed`, `missed`, `accepted` |

`completed`, `declined` and `missed` are final.

`completed` and `missed` work the same as a real finish or deadline, whatever the job's progress:
- **`completed`:** a hired worker's AI is stopped where it is, even mid-field or on the road. The job's invoiced and earns reputation. The crew and machines go through the usual trip back and parking, and the logbook records it.
- **`missed`:** the usual missed-deadline reputation penalty (less whatever progress was made), and the crew and machines are released the same way.
- **`accepted`** (from `allocated` or `in_progress`): unallocates the job, the same as the Unallocate button in the Calendar's Job Details. The crew and machines come back (into cooldown if any work was done), and the job keeps its progress for whoever's allocated next. No reputation is lost.

Other states only change the job's state.

Leave the state out, or give one the job can't go to, and it tells you the job's current state and the states it can go to instead, without changing anything. Get job ids from `tcJob list`.

```
tcJob state 7 accepted
tcJob state 7
```

```
Job 7 is accepted. It can go to: allocated, missed
```

### `tcJob log [jobId]`

Shows a job's entry in the Logbook. That's the crew, each machine's condition going out and coming back, the time split, supplies, costs, margin, reputation and any claim. With no job id it lists the farm's last 10 logged jobs, newest first, with their ids and margins. Read-only, so it also works on a joined client.

| Argument | Meaning |
|---|---|
| `jobId` | Optional. The job to show. Leave it out to list the last 10. |

```
tcJob log
tcJob log 42
```

### `tcJob park`

Parks the vehicle you're sitting in, for testing parking slots. You're put out of the vehicle and it's unhitched from anything it's pulling. It then goes to a random free spot in one of your farm's parking slots of its type: harvester parking slots for self-propelled harvesters, vehicle parking slots for anything else drivable, implement parking slots for everything else. If none is free (or you haven't placed any), it's hidden and joins the parking queue, the same as equipment back from a job: it's parked within about 5 seconds of a slot coming free. Takes no arguments. It has to be your farm's vehicle and not out on a job.

```
tcJob park
```

## Finances — `tcFinance`

### `tcFinance invoices`

Lists your farm's invoices, including the hidden rolls the Finances tab doesn't show. Takes no arguments and changes nothing. Days are the game's running day count, and the output starts with today's.

Each line shows the invoice id, job id, amount, issue day, due day, status (`outstanding`, `overdue`, `pursuing`, `paid`, `writtenOff`) and what will really happen:

- `pays on time`: pays on its due day.
- `late, pays day N`: a late payer. It shows as overdue after its due day and pays on day N.
- `bad debt, never pays`: never pays by itself. Only pursuing it (053) can recover it.

For an invoice being pursued (053) it also shows:
- when the pursuit started,
- whether it's under legal cover or a solicitor (with the fee),
- the day it resolves.

Use this to find an overdue invoice to pursue, and to know when to fast-forward to for the outcome.

```
tcFinance invoices
```

```
#4 job 12: 4000, issued day 90, due day 95, pursuing (bad debt, never pays; pursued since day 101 (solicitor, fee 700), resolves day 104)
```

### `tcFinance claims`

Lists the claims that haven't arrived yet (amount, arrival day, insured or not, reputation hit), then your farm's claims in the last 3 years and the current public liability premium.

### `tcFinance botch [daysUntilClaim]`

Makes the next hired worker who finishes a job botch it, so the customer makes a compensation claim.
- **What uses it up:** jobs the player drives don't, and nor do job types that can't cause a claim (stone picking, tedding). It waits for the next job that can.
- **`daysUntilClaim`:** sets when the claim arrives. Without it, it's the usual 2–7 days. `0` brings it at the next day change.

The setting isn't saved.

```
tcFinance botch
tcFinance botch 0
```

### `tcFinance insurance`

Shows your farm's machinery insurance: whether you're insured and at what level of cover (and any change from renewal), what your fleet is worth, and how many claims you've had in the last 3 years. Then each level's premium today (after the claims loading) and what it pays out, and your open claims: the stolen vehicle, its value and level of cover, whether the claim is waiting to be submitted or the day it settles, and the courtesy vehicle you've been lent for it on comprehensive cover (with its vehicle id). A settled claim whose courtesy vehicle is still busy is listed too, until the insurer collects it. Read-only, so it also works on a joined client.

```
Farm 1: insured, standard cover. Fleet value 412000, 0 claim(s) in the last 3 years
  basic: 4120 a year, pays 80% less 5000 excess
  standard: 5768 a year, pays 90% less 2500 excess
  comprehensive: 7416 a year, pays 100% less 1250 excess
Open claims: 1
  #3 Fendt 724 Vario (98000, comprehensive): settles day 112, courtesy John Deere 6R 250 (412)
```

## Company — `tcCompany`

### `tcCompany rep <amount>`

Adds reputation points to your farm, or removes them with a negative amount.

```
tcCompany rep 100
tcCompany rep -50
```

### `tcCompany notices`

Lists the notices on your farm's Overview board with their ids (which the board doesn't show) and when each one expires.

### `tcCompany notice <months|none> <text...>`

Publishes a notice to your farm's Overview board. `months` is how many months it stays up; `none` keeps it up until it's removed. Everything after the first argument is the notice text. It prints the new notice's id.

```
tcCompany notice 3 Harvest season is coming, book your combines early
tcCompany notice none Welcome to the company
```

### `tcCompany removeNotice <noticeId>`

Takes a notice off your farm's Overview board. `tcCompany notices` shows the ids.

```
tcCompany removeNotice 4
```

### `tcCompany vehicleLog <vehicle>`

Shows a vehicle's Logbook history for the last year. You get a summary line (jobs, hours worked, faults caused by your staff, wear cost), then every logged use: jobs, staff drivers and players, with who, how long and its condition before and after. `<vehicle>` is any part of its name, case-insensitive. Words after the first are included, so names with spaces work. Every logged vehicle that matches is shown. Only vehicles with history on your farm are searched. Read-only, so it also works on a joined client.

```
tcCompany vehicleLog fendt
tcCompany vehicleLog 942 Vario
```

### `tcCompany storages [fillType]`

Lists the storages your farm owns that the Supplies tab counts, to track one down. For each one it shows the building's name, the mod it comes from (in brackets, if it's from a mod), how much is in it out of its room for that product, and how far away it is and in which direction from you. With no argument it covers every supply the tab lists; give a fill type's name (e.g. `SEEDS`, `FERTILIZER`, `DIESEL`, case-insensitive) for just that one. A storage shared between products shows its room for each one, so the same building can appear under several. Read-only, so it also works on a joined client.

```
tcCompany storages
tcCompany storages seeds
```

```
Seeds:
  Farm Silo [FS25_SomeMap] - 0 of 500000, 1.2 km north-east of you
```

### `tcCompany event <type> [details]`

Makes a random event happen to your farm now, ignoring the odds, the Random events setting, the event type's cooldown, its months (poaching only comes March to May) and its time of day (diesel theft normally comes to light between 07:00 and 09:00). It still needs something to act on (a theft needs a vehicle that can be stolen, joyriders a grass field outside winter, fly-tipping an NPC's field with no job on it, diesel theft some diesel in a storage of yours or in a parked machine, poaching a worker who isn't leaving), and says so if there isn't anything. It starts the event's cooldown like a real one. `<type>` is the event type's key, case-insensitive. With no type, or an unknown one, it lists the ones there are.

`[details]` picks what the event acts on, for the types that take one (any other type refuses them):

- `goodNews [story]`: that story, or a random one other than the last you had, even before your first completed job. The story's reward is applied and its inbox message posted. `[story]` is case-insensitive; an unknown one lists them: `photoPosted`, `parishNews`, `parishCouncil`, `youngFarmers` (reputation, scaled to your tier), `supplierRefund`, `loyaltyRebate`, `ratesRefund` (cash, scaled by the job pay setting).
- `poaching [worker]`: the rival goes after that worker (a `<worker>` as for `tcWorker`: an id or the start of a name), however long they've been with you. Without one it picks as the real event does: someone with at least 3 months' service, nearly always one of your most valuable. Not someone who's leaving or already has an offer.

The events that happen as a job ends (`kettle`, `paidEarly`, `stepsUp`, `roadAccident`, `sprayDrift`) use your latest completed job they can act on, whatever its quality score: one with hired workers for `kettle`, one whose invoice isn't due yet for `paidEarly` (so none with the late invoices setting off), one with a worker rated 5 or under for their part of it for `stepsUp`, and one a hired worker drove whose machines are still yours for `roadAccident` (its machines are damaged wherever they are now), and a hired worker's herbicide job with no botch claim on its way for `sprayDrift` (judged on the wind right now, not on the day). Use `tcCompany outcome` first to decide how an event comes out.

```
tcCompany event theft
tcCompany event joyriders
tcCompany event flyTipping
tcCompany event dieselTheft
tcCompany event goodNews
tcCompany event goodNews supplierRefund
tcCompany event kettle
tcCompany event paidEarly
tcCompany event stepsUp
tcCompany event roadAccident
tcCompany event sprayDrift
tcCompany event poaching
tcCompany event poaching amy
```

### `tcCompany events`

Lists every random event type with its odds for your farm (a month and a day, after the Random events setting; for an event that happens as a job ends, the chance on each completed job, or "depends on the job" for one whose odds come from the job itself like `sprayDrift`, and the quality score it needs) and any cooldown left (and, for an event with a time of day, its hours), then any event that's been rolled and is waiting for its hour (the day and hour it's due), then your farm's open incidents: the stage each one is at, the day it moves on (or "waiting" if it's waiting on something else, like a reply in the inbox), when it started and the event's own details. Read-only, so it also works on a joined client.

### `tcCompany outcome <type> <outcome>`

Decides how the next event of that type comes out, instead of the usual roll. It applies once, to the next incident of that type to reach that point, then the odds are back to normal. Pair it with `tcCompany event` to try each outcome. With no type, or one that has no outcomes, it lists the types that do. Both arguments are case-insensitive.

| Type | Outcomes | What it decides |
|---|---|---|
| `theft` | `recovered`, `lost` | The next police report on a stolen vehicle: `recovered` brings it back (damaged, through the parking queue), `lost` writes it off and removes it (or, if the farm had machinery insurance on the day of the theft, starts the insurance claim, and the vehicle goes when it settles). Normally a 35% chance of recovery. |
| `roadAccident` | `ours`, `theirs` | Who's to blame for the next road accident: `ours` (a claim through public liability, a reputation hit and a morale knock for the driver), `theirs` (the other driver's insurer pays an estimated repair cost a month or two later). Normally rolled from the driver's tractor rating and the state of the machines. |
| `sprayDrift` | `upheld`, `cleared` | The findings on the next spray drift complaint: `upheld` (the complainant's claim through public liability, a reputation hit and a morale knock for the operator), `cleared` (nothing else happens). Normally rolled from the operator's crop care and the wind. |
| `poaching` | `stays`, `leaves` | What the next poached worker you do nothing about decides (matching the offer always keeps them): `stays` on the same pay, or `leaves`, handing in a month's notice. Normally they stay with a 5-25% chance, from their morale and their pay against what they expect. |

```
tcCompany outcome theft recovered
tcCompany event theft

tcCompany outcome roadAccident theirs
tcCompany event roadAccident

tcCompany outcome poaching leaves
tcCompany event poaching amy
```

### `tcCompany office`

Lists your farm's office staff (090): for the administrator and the storekeeper, who's employed, their id, level, whether they're in the office or training (and until which day), and their monthly salary. The last line says whether Advanced Damage System's own workshop is taking your staff, and what state its staff provider is in. Read-only, so it also works on a joined client.

```
tcCompany office
```

### `tcCompany officeLevel <administrator|storekeeper> <1-3>`

Sets an office role's level straight away, with that level's salary, and ends any course they're on, for testing Advanced Damage System's workshop at each level. The role has to be filled.

```
tcCompany officeLevel administrator 3
tcCompany officeLevel storekeeper 2
```

### `tcCompany debris [count] [prop]`

Drops a pile of loose debris about 4 m in front of you, the same props fly-tipping (075) dumps, for testing props the player can pick up and carry by hand. Debris from here belongs to no job: a disposal skip takes it away free. Every piece weighs 10 kg. `[count]` defaults to 8 (at most 50). Without `[prop]` each piece is a random prop; name one to spawn only that: `barrel`, `pipe`, `bicycle`, `board`, `cardboard`, `sawhorse`, `trashCan`, `trashCan2`, `wheelBarrow`, `chair`, `ladder`, `grill`, `stool`, `pitchFork`, `crate`, `crate2`, `crate3`, or `bakeryBox` (a vanilla prop already built to move, never picked at random, used to check whether a prop's collision is the problem). An unknown prop lists them. The pieces are saved with the savegame. Needs a local player, so it doesn't work from a dedicated server's console.

```
tcCompany debris
tcCompany debris 20 ladder
```

### `tcCompany debrisClear`

Removes every piece of debris from the map.
