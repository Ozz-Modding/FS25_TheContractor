# Console commands

You type these into the developer console. You don't need cheats on. Each group is a command of its own, with subcommands:

| Command | What it covers |
|---|---|
| `tcHelp` | Lists the groups below |
| `tcWorker` | Hire, list and manage your staff |
| `tcJob` | List, offer, create and force jobs |
| `tcFinance` | Your claims and machinery insurance |
| `tcCompany` | Reputation, Overview notices, the office, storages and vehicle history |
| `tcEvent` | Random events: their odds, and making one happen |
| `tcFarmer` | The map's farmers: who they are, their machines, your relationships, a new land split |
| `tcYard` | Farm yards: list them, check a farmland, mark them on the map, override detection |
| `tcAuction` | The machinery auction: see it, announce one, call it off |
| `tcLog` | Toggles the mod's detailed log ([below](#tclog)) |

Testing tools that aren't part of the game (spikes, forced rolls, readouts of hidden state) are a separate group, `tcDebug`, for development only. It only appears with a marker file in place.

Type a group on its own (or with `help`) to list its subcommands and their arguments. Subcommand names aren't case-sensitive. If you get the arguments wrong, or leave out one it needs, the command prints that subcommand's usage.

- **Finding what a command takes:** nothing should need these docs to find. Under a subcommand's usage, and under a group's list, each argument that's an id or a name says where to find it, usually a list command: `<worker>` from `tcWorker list`, `<jobId>` from `tcJob list`, `<farmer>` from `tcFarmer list`, `<farmlandId>` from `tcYard list`, `<noticeId>` from `tcCompany notices`. An argument with a fixed set of values lists them, inline (`<on|off>`) or under the usage when there are many (`<jobType>`, `<eventType>`). A wrong name lists the right ones.
- **Your farm:** every command acts on your current farm. Most need that farm to have created a company first.
- **Server only:** commands that change something run on the server. In single player, or as the host, they run as you type them. As an admin on a joined client (a dedicated server's admins included) they're sent to the server and run there for your farm, where you're standing and the vehicle you're in, and the answer is printed when it comes back. Other players can't use them. The read-only lists `tcWorker list`, `tcWorker pool`, `tcWorker hours`, `tcJob list`, `tcJob types`, `tcJob log`, `tcFinance insurance`, `tcCompany notices`, `tcCompany office`, `tcCompany storages`, `tcCompany vehicleLog`, `tcEvent list`, `tcFarmer list`, `tcFarmer preview`, `tcFarmer show`, `tcFarmer hide`, `tcFarmer relationships`, `tcYard list`, `tcYard check`, `tcYard show` and `tcYard hide` also work on a joined client.
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

### `tcWorker morale <worker> <value 0-100>`

Sets one of your hired workers' morale, exactly: their temperament doesn't scale it. The change syncs to everyone. It prints their morale and its band.

```
tcWorker morale amy 80
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

### `tcWorker certify <worker> [on|off]`

Gives one of your hired workers the spraying certificate, or takes it away with `off`. `on` is the default. Useful for testing who can be allocated to herbicide jobs.

```
tcWorker certify 2
tcWorker certify 2 off
```

### `tcWorker hours`

Shows the game time and whether it's working hours (08:00 to 18:00), then each of your hired workers: their status (an idle worker shows `atHome`, `comingIn`, `stayingLate` or `onBreak` instead of `idle` when that's where they are), the time they're on duty until if they've been kept on (and when they'll be in, if they've been called back and aren't there yet), their overtime so far this month in minutes and money, and what an hour of overtime costs them now. On the server it also lists today's breaks (`morning`, `lunch`, `afternoon`), each `taken`, `missed`, `excused` (away, or not hired yet, when its time passed), `off` (turned off by the Staff breaks setting when its time passed) or `-` (still to come), and when the break they're on ends. Read-only, so it also works on a joined client, which shows only the break they're on.

```
Farm 1, 12:20: working hours 08:00-18:00, at work
#3 Amy Hall - onBreak, overtime 70 min this month (12 owed), 10.71 an hour, breaks: morning missed, lunch taken, afternoon -, on break until 12:50
#7 John Smith - assigned, overtime 0 min this month (0 owed), 10.71 an hour, breaks: morning taken, lunch -, afternoon -
```

### `tcWorker break <worker>`

Sends a worker on their next break of the day (morning, lunch or afternoon, whichever they haven't had yet) straight away, whatever the time, for its full length (15, 30 or 15 minutes). They have to be free: idle and at work, not already on a break. `<worker>` is their id or name. Prints when the break ends, or why it couldn't.

```
tcWorker break Amy
```

### `tcWorker duty <worker> <hour|home>`

Keeps a worker on until `hour` (0-24, the next time the clock reads it): Stay late if they're at work, or Call back if they've gone home (they're in 25 game minutes later). `home` sends a worker who's been kept on home now. The same checks as the Staff tab's Manage options apply: not while they're sick, on holiday or training, after 18:00 (or after they'd turn up), and no later than the next 08:00. They're paid overtime for every minute of it outside working hours. Prints their line as `tcWorker hours` does, or why it couldn't.

```
tcWorker duty Amy 22
tcWorker duty 7 home
```

### `tcWorker adsSkill <worker> <mechanic|electrician|bodyworker|storekeeper> <0-3>`

Sets one of a hired worker's Advanced Damage System workshop skills (091, and the storekeeper since 098) to a level, or removes it with `0`. The trades are named as ADS shows them; `diagnostician`, its own id for the electrician, works too. A worker can have at most two: set one to `0` before adding a third. Removing the skill a worker is working in the workshop as takes them out of the workshop. `<worker>` is their id or name. It prints the worker's skills afterwards. It works without ADS too, but the skills only show and count toward pay while ADS's own workshop is taking your staff.

```
tcWorker adsSkill 7 mechanic 2
tcWorker adsSkill Sam Hill bodyworker 0
tcWorker adsSkill 7 storekeeper 1
```

## Jobs — `tcJob`

### `tcJob list [state|all]`

Lists your farm's jobs with their ids, for the other job commands. Each line shows the job, its field, state and price. Where they apply, it adds how far along it is, when it's ready from for a job that can't be worked yet (a future harvest), when it's due (date and monotonic day) and who's on it: worker names, or "you" for a job you're doing yourself. Read-only, so it also works on a joined client.

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
#15 Harvest (Wheat), field 8 - accepted, 6,920 €, ready from October 2, Year 1 (day 275), due October 4, Year 1 (day 277)
```

### `tcJob types`

Lists the job types `tcJob offer` and `tcJob create` take: the generated ones, then the Advanced Damage System repair contract kinds. The same list is printed under the usage of `tcJob offer` and `tcJob create`. Read-only, so it also works on a joined client.

```
tcJob types
```

### `tcJob offer <jobType> [severity 1-3]`

Offers your farm a job of the given type right now, through the normal job generator. You get a real offer on a real field, with the usual price, deadline and required skill, so the game could have offered the same job by itself. This is useful for testing and for setting up a storyline.

- No `jobType` prints the usage, which lists the types (so does `tcJob types`).
- Job types (case-insensitive): `harvest`, `cultivate`, `sow`, `plow`, `mow`, `tedder`, `bale`, `baleWrap`, `strawDelivery`, `fertilize`, `herbicide`, `weed`, `hoe`, `stonePick`, `lime`, plus `repair`, `maintenance` and `parts` (see below).
- A `harvest` offer, or a `bale` offer on a straw crop, sometimes includes delivery (Harvest & Haul, Bale & Deliver), just as a generated offer would. `strawDelivery` is only possible when a selling point on the map takes straw bales.
- It picks a field your farm has the equipment for when it can, and falls back to any eligible field otherwise.
- It fails only when the generator itself couldn't offer that type right now, and the output says why. Examples are harvest in winter, weeding on a save with weeds off, lime on a save that doesn't require it, or a crop whose ready date can't be predicted. Use `tcJob availability` to see which types have work available.

```
tcJob offer mow
```

**Repair contracts** (needs FS25_AdvancedDamageSystem): `repair`, `maintenance` and `parts` send a customer's machine to your first free repair zone bay instead. It's queued like a normal arrival and placed within a couple of seconds, then ADS prepares it and the job offer goes up in your Inbox. The model is picked at random from those the zone takes (its type, its filter, what fits a bay). Field breakdowns aren't offered here: use `tcEvent trigger fieldBreakdown`.

| Argument | Meaning |
|---|---|
| `repair\|maintenance\|parts` | A repair (hidden faults), a service (worn oils, filters and grease), or a parts service: a service of only the stock parts (the battery and/or the air filter), found on inspection and charged with labour like any service. `parts` needs a version of ADS that takes service targets. |
| `severity` | Optional, 1-3, and only for these three. How big a job: more or later faults, or more worn consumables. Rolled if left out (20% 1, 30% 2, 50% 3). |

```
tcJob offer repair
tcJob offer maintenance 3
tcJob offer parts
```

```
Queued data/vehicles/fendt/vario900/vario900.xml (repair, severity 3) for bay 2.
```

### `tcJob availability`

A dry run of job generation for your farm. It changes nothing. It shows the current hourly offer chance and the expected number of offers per period. For each job type it lists:

- **eligible fields**: fields you don't own that qualify for the job type right now
- **with target date**: eligible fields that also have a workable deadline
- **fulfillable**: fields from that list your farm owns the equipment for

### `tcJob create <jobType> <fieldId> <skill> <price> <period> <day>`

Creates a job with every detail set by hand. Unlike `tcJob offer`, nothing is checked: the field doesn't have to suit the job type and the date doesn't have to be workable. Use it to test specific edge cases. It prints the new job's id.

| Argument | Meaning |
|---|---|
| `jobType` | One of the job types `tcJob types` lists, or an event's own job type by its exact key. An unknown one lists the types |
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
| `accepted` | `allocated`, `missed`, `completed` (a workshop job only) |
| `allocated` | `in_progress`, `completed`, `missed`, `accepted` |
| `in_progress` | `completed`, `missed`, `accepted` |

`completed`, `declined` and `missed` are final.

`completed` and `missed` work the same as a real finish or deadline, whatever the job's progress:
- **`completed`:** a hired worker's AI is stopped where it is, even mid-field or on the road. The job's invoiced and earns reputation. The crew and machines go through the usual trip back and parking, and the logbook records it.
- **`missed`:** the usual missed-deadline reputation penalty (less whatever progress was made), and the crew and machines are released the same way.
- A workshop job (a customer's machine in a repair zone, needs FS25_AdvancedDamageSystem) goes straight from `accepted` to `completed`: invoiced and rewarded as if ADS said the work was done. `missed` judges it as the deadline would: a machine that's worse than it came in costs double the reputation and may bring a claim. Either way the customer comes for the machine.
- **`accepted`** (from `allocated` or `in_progress`): unallocates the job, the same as the Unallocate button in the Jobs tab's Job Details. The crew and machines come back (into cooldown if any work was done), and the job keeps its progress for whoever's allocated next. No reputation is lost.

Other states only change the job's state.

Leave the state out, or give one the job can't go to, and it tells you the job's current state and the states it can go to instead, without changing anything. Otherwise it prints the state the job ended up in. Get job ids from `tcJob list`.

```
tcJob state 7 accepted
tcJob state 7
```

```
Job 7 is accepted. It can go to: allocated, missed
```

### `tcJob log [jobId]`

Shows a job's entry in the Logbook. That's the crew, each machine's condition going out and coming back (for an FS25_AdvancedDamageSystem machine, what its last inspection showed and any fault found during the job), the time split, supplies, costs, margin, reputation and any claim. With no job id it lists the farm's last 10 logged jobs, newest first, with their ids and margins. Read-only, so it also works on a joined client.

| Argument | Meaning |
|---|---|
| `jobId` | Optional. The job to show. Leave it out to list the last 10. |

```
tcJob log
tcJob log 42
```

## Finances — `tcFinance`

### `tcFinance claims`

Your farm's claims in the last 3 years (when, and how much), and the current public liability premium, with whether you're insured. Server only. Claims that haven't arrived yet are a testing readout, `tcDebug claims`.

```
tcFinance claims
```

### `tcFinance insurance`

Shows your farm's machinery insurance: whether you're insured and at what level of cover (and any change from renewal), what your fleet is worth, and how many claims you've had in the last 3 years. If any of your vehicles have FS25_AdvancedDamageSystem's anti-theft system fitted, a second line says how many and the value the premium is worked out on (theirs counted at 15% less). Then each level's premium today (after the claims loading) and what it pays out, and your open claims: the stolen vehicle, its value and level of cover, whether the claim is waiting to be submitted or the day it settles, and the courtesy vehicle you've been lent for it on comprehensive cover (with its vehicle id). A settled claim whose courtesy vehicle is still busy is listed too, until the insurer collects it. Read-only, so it also works on a joined client.

```
Farm 1: insured, standard cover. Fleet value 412000, 0 claim(s) in the last 3 years
  2 vehicle(s) with an anti-theft system: priced on 389500 (15% off theirs)
  basic: 3895 a year, pays 80% less 5000 excess
  standard: 5453 a year, pays 90% less 2500 excess
  comprehensive: 7011 a year, pays 100% less 1250 excess
Open claims: 1
  #3 Fendt 724 Vario (98000, comprehensive): settles day 112, courtesy John Deere 6R 250 (412)
```

## Company — `tcCompany`

### `tcCompany rep <amount>`

Adds reputation points to your farm, or removes them with a negative amount, and prints the new score.

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

### `tcCompany office`

Lists your farm's office staff (090): for the administrator, who's employed, their id, level, whether they're in the office or training (and until which day), and their monthly salary. The last line says whether Advanced Damage System's own workshop is taking your staff, and what state its staff provider is in. Read-only, so it also works on a joined client.

```
tcCompany office
```

### `tcCompany vehicleLog <vehicle>`

Shows a vehicle's Logbook history for the last year. You get a summary line (jobs, hours worked, how many uses a fault was found in, wear cost), then every logged use: jobs, staff drivers and players, with who, how long and its condition before and after. `<vehicle>` is any part of its name, case-insensitive. Words after the first are included, so names with spaces work. Every logged vehicle that matches is shown. Only vehicles with history on your farm are searched. Read-only, so it also works on a joined client.

```
tcCompany vehicleLog fendt
tcCompany vehicleLog 942 Vario
```

### `tcCompany storages [fillType]`

Lists the storages your farm owns that the Supplies tab counts, to track one down. For each one it shows the building's name, the mod it comes from (in brackets, if it's from a mod), how much is in it out of its room for that product, and how far away it is and in which direction from you. With no argument it covers every supply the tab lists; give a fill type's name (e.g. `SEEDS`, `FERTILIZER`, `DIESEL`, case-insensitive) for just that one; one it doesn't know lists your supplies' names. A storage shared between products shows its room for each one, so the same building can appear under several. Read-only, so it also works on a joined client.

```
tcCompany storages
tcCompany storages seeds
```

```
Seeds:
  Farm Silo [FS25_SomeMap] - 0 of 500000, 1.2 km north-east of you
```

## Random events — `tcEvent`

### `tcEvent list`

Lists every random event type with its odds for your farm (a month and a day, after the Random events setting; for an event that happens as a job ends, the chance on each completed job, or "depends on the job" for one whose odds come from the job itself like `sprayDrift`, and the quality score it needs; for one that follows bad weather like `fallenTree`, the chance each time a spell of it ends) and any cooldown left (and, for an event with a time of day, its hours), Each type is shown with the details `tcEvent trigger` takes for it (`flyTipping [field|road]`). Read-only, so it also works on a joined client. What's been rolled and is waiting, and your open incidents with their hidden data, are a testing readout, `tcDebug incidents`.

```
tcEvent list
```

### `tcEvent trigger <eventType> [details]`

Makes a random event happen to your farm now, ignoring the odds, the Random events setting, the event type's cooldown, its months (poaching only comes March to May) and its time of day (diesel theft normally comes to light between 07:00 and 09:00, an injury between 09:00 and 17:00). It still needs something to act on (a theft needs a vehicle that can be stolen, joyriders a grass field outside winter, fly-tipping an NPC's field with no job on it or a road verge with room for the pile, diesel theft some diesel in a storage of yours or in a parked machine, poaching a worker who isn't leaving, an injury a field worker who isn't already off sick, on holiday, training or due to be off sick (at work or not: the real event only picks someone in the yard during working hours or out working), a field breakdown needs FS25_AdvancedDamageSystem, an NPC's field with no job on it and no other breakdown of yours on the go), and says so if there isn't anything. It starts the event's cooldown like a real one. `<eventType>` is the event type's key, case-insensitive. With no type it prints the usage, which lists every type with the details it takes; an unknown one lists them too, as does `tcEvent list`.

`[details]` picks what the event acts on, for the types that take one (any other type refuses them). Left out, it picks as the real event does:

- `goodNews [story]`: that story, or a random one other than the last you had, even before your first completed job. The story's reward is applied and its inbox message posted. `[story]` is case-insensitive; an unknown one lists them: `photoPosted`, `parishNews`, `parishCouncil`, `youngFarmers` (reputation, scaled to your tier), `supplierRefund`, `loyaltyRebate`, `ratesRefund` (cash, scaled by the job pay setting).
- `poaching [worker]`: the rival goes after that worker (a `<worker>` as for `tcWorker`: an id or the start of a name), however long they've been with you. Without one it picks as the real event does: someone with at least 3 months' service, nearly always one of your most valuable. Not someone who's leaving or already has an offer.
- `flyTipping [field|road]`: the pile lands just inside an NPC's field (`field`, offered by its farmer) or on a road's verge (`road`, offered by the local official for the council). Without one it picks as the real event does: either, even odds, trying the other if the first has nowhere to go. With one it's only that, and it says there's nothing to act on if there's nowhere for it. A verge needs an AI road spline with flat ground 6 m out from the road's middle, level with the road, nothing in the way, no other road within 5 m, no player within 150 m and a field within 2 km to name it by.
- `fallenTree [here]`: 2 to 4 fully grown beeches come down across roads and the council's job to clear them all goes up in your Inbox, due today, with a map marker on each tree once you take it on. Without `here` the roads are picked as the real event does (on AI road splines, with room for each tree, no player within 150 m, a field within 2 km to name each by, every tree at least 200 m from any other and the rest within 1 km of the first), and it says there's nothing to act on if fewer than 2 will do or you've one already. With `here` the first falls across the way you're facing, about 8 m ahead, which needs you in the game (an admin on a joined client counts), and the rest are picked as usual (it goes ahead with just that one if there's nowhere else). The trees are cut and laid down 3 seconds after they're planted.
- `protest [now]`: locals protest on the roads near your farm's base (the middle of the farmland with most of your own sheds, silos, pens, houses and other yard buildings), 2 or 3 round crowds of 15 to 20 in the middle of the road, most holding placards. Without `now` it's set for tomorrow as the real event is: the local official's warning goes up in your Inbox (with Show on map), and the people are out from 07:00 to 19:00 the next day. It says there's nothing to act on if tomorrow is in winter, an auction's sale day, or another farm's protest day, if you own no buildings, or if no road 60-500 m from your base will take a group (not on a bridge, at a junction, on a steep slope or against a wall). With `now` there's no warning: they're out at once, whatever the hour or season, until the day changes (`tcDebug protest clear` ends it sooner).
- `fieldBreakdown [player|mobile]`: a customer's machine breaks down on an NPC's field, fixable on the spot with ADS's tool box (`player`) or only with a mobile workshop (`mobile`). Without one it picks as the real event does: even odds, or mostly `player` if you've a tool box and no mobile workshop. The machine is the field's farmer's own (one of their machines ADS can take that isn't out already, their combine one time in five outside winter, with its header on), and the farmer's the customer. About a third of the time a farmer with a yard has it break down there instead, on a yard spot where it fits on open ground (on the field if there's no room); a field no farmer holds, or a farmer with nothing ADS can take, gets a random customer's tractor or harvester. The machine is placed like a repair zone arrival (within a couple of seconds) and the offer, due today, goes up in your Inbox.
- `farmerFavour [farmer]`: one of the map's farmers asks you to fit a new battery or air filter to their own machine (needs FS25_AdvancedDamageSystem with its repair contract targets). The farmer is an id or full name from `tcFarmer list`; without one it picks as the real event does, weighted by your relationships, never someone you've fallen out with, and never one who's already asked any farm. The machine is one of theirs that ADS can take and isn't out already (`tcFarmer fleet` lists them; a telehandler comes with its bale fork on), placed in their yard if it has room, or on the headland of one of their fields, within a couple of seconds; the part is the battery or the air filter (whichever the machine has, and not one fitted to it within a year), and the offer goes up in your Inbox to accept or decline. It says there's nothing to act on if you've a favour on already, or the farmer has no land.

- `yardBales [straw|hay|silage] [farmer]`: a farmer with a yard is short of straw, hay or silage and asks for some of your own bales (loose ones and those in your bale storages both count; a wrapped bale counts as silage only once it's fermented). `straw`, `hay` or `silage` picks which; without one it's any of them you hold enough of. The farmer is an id or full name from `tcFarmer list`; without one it picks as the real event does, weighted by your relationships, never someone you've fallen out with or who's already asking. They ask for 30-70% of the bales you hold of your commonest size, 6 to 24 of them, and it says there's nothing to act on if you've fewer than 6 of that size, you've an order on already, or no farmer with a yard no player owns has their telehandler and bale fork free (`tcFarmer fleet` lists them). A drop area of 12 x 12 m is picked on open ground in their yard, with room for the telehandler beside it (no offer if there isn't any), and the offer, due in 2 or 3 days, goes up in your Inbox. Accept it and the telehandler comes out by the area, fork on, within a couple of seconds.
- `yardHaul [crop] [injured|sick|left] [farmer]`: a farmer with a yard has nobody to drive (their worker's hurt, off sick or has walked out: the reason picks which, random without one) and asks you to take their trailer, full, to a selling point and tip it there. `[crop]` is a fill type name (`wheat`, `barley`, ...) the trailer carries and a selling point buys; without one it's a crop on the farmer's own fields that will do, else wheat or barley. The farmer is an id or full name from `tcFarmer list`; without one it picks as the real event does, weighted by your relationships, never someone you've fallen out with or who has a job on in their yard already (this one or `yardBales`). It says there's nothing to act on if you've a load on already, no farmer with a yard no player owns has their trailer free (`tcFarmer fleet` lists them), there's no room for it on a spot in the yard, or nowhere buys a crop it carries. The load is 90-100% of the trailer's capacity, the selling point the one paying most for it, and the offer, due in 2 or 3 days, goes up in your Inbox. Accept it and the trailer comes out to its yard spot, full, within a couple of seconds.
- `emergencyRefuel [headland|gauge|forgot] [combine] [farmer]`: one of a farmer's machines has run out of diesel on one of their fields, and they ask you to bring some, today. The reason (finishing the headland, a broken fuel gauge, forgot to fill up) picks the offer's wording, random without one. `combine` makes it their combine (with its header on) at any time of year; without it it's one of their tractors, or now and then their combine from July to October. The farmer is an id or full name from `tcFarmer list`; without one it picks as the real event does, weighted by your relationships, never the local official, someone you've fallen out with or anyone who's already got a refuel on with any farm. The machine must be free (`tcFarmer fleet` lists them) and run on diesel, and the field one of theirs that no player owns and nobody has a job on. It says there's nothing to act on if you've a refuel on already, or no farmer has a field and a machine that will do. The offer asks for a quarter of the machine's tank and goes up in your Inbox, due today; it pays for that diesel at half as much again as the diesel price, plus a call-out fee. Accept it and the machine comes out on the field's headland, its tank empty, within a couple of seconds, and the farmer waits beside it. It's done once the tank's at least a quarter full, however the diesel got there.
- `fieldSold [retiring|selling|bereavement] [farmer]`: a farmer lets one of their farmlands go to a neighbour, for the whole map. The reason (cutting back, selling to a neighbour, a death in the family) picks the notice's wording, random without one. The farmer (the seller) is an id or full name from `tcFarmer list`; without one it's any farmer with a sale they could make. A seller needs more than one farmland that no player owns, and never lets go of the one their yard's on. The farmland goes by the same rule as land a player sells: the nearby farmer with the fewest acres for their target. If that would be the seller again, it's no sale, and it says there's nothing to act on if no farmer has a sale. Every farm with a company gets a notice naming both farmers and the field (or the farmland, when it has several fields). Jobs already agreed there stay with the old owner; new ones come from the new one.
- `farmerRetirement [farmer]`: a farmer retires and a new person takes over their farm, for the whole map. This works even with the Farmer retirements setting off (the real event only comes with it on). The farmer is an id or full name from `tcFarmer list`; without one it's any farmer, never the local official. The successor gets a new id, a new name and look, and takes over the land, the yard, the machines (any you've edited stay as they are) and every job, inbox message and machine on its way for the old farmer. Every farm's relationship with them starts at half what it was with the old farmer, rounded towards 0. The old farmer is gone from the People tab, and every farm with a company gets a notice.

The events that happen as a job ends (`kettle`, `paidEarly`, `stepsUp`, `roadAccident`, `tippedTrailer`, `sprayDrift`) use your latest completed job they can act on, whatever its quality score: one with hired workers for `kettle`, one whose invoice isn't due yet for `paidEarly` (so none with the late invoices setting off), one with a worker rated 5 or under for their part of it for `stepsUp`, and one a hired worker drove whose machines are still yours for `roadAccident` (its machines are damaged wherever they are now), a harvest & haul job with a hired hauler whose trailer is still yours, not stolen, not already on its side and not out on another job for `tippedTrailer` (the trailer is taken from wherever it is now, even a parking slot, and laid on its side in that job's field, 10-20 m from its middle, with the job's haul tractor left beside it if that's free too; the field needs room for it. Its load is spilt beside it and the urgent delivery job (106) starts at once, due by the end of tomorrow, if that job's crop can lie on the ground and has somewhere to go), and a hired worker's herbicide job with no botch claim on its way for `sprayDrift` (judged on the wind right now, not on the day). Deciding how an event comes out is a development tool (`tcDebug outcome`).

```
tcEvent trigger theft
tcEvent trigger joyriders
tcEvent trigger flyTipping
tcEvent trigger flyTipping road
tcEvent trigger protest
tcEvent trigger protest now
tcEvent trigger dieselTheft
tcEvent trigger goodNews
tcEvent trigger goodNews supplierRefund
tcEvent trigger kettle
tcEvent trigger paidEarly
tcEvent trigger stepsUp
tcEvent trigger roadAccident
tcEvent trigger tippedTrailer
tcEvent trigger sprayDrift
tcEvent trigger poaching
tcEvent trigger poaching amy
tcEvent trigger injury
tcEvent trigger fieldBreakdown
tcEvent trigger fieldBreakdown mobile
tcEvent trigger farmerFavour
tcEvent trigger farmerFavour 4
tcEvent trigger fallenTree
tcEvent trigger fallenTree here
tcEvent trigger yardBales
tcEvent trigger yardBales hay 4
tcEvent trigger yardBales silage
tcEvent trigger yardHaul
tcEvent trigger yardHaul barley sick 4
tcEvent trigger emergencyRefuel
tcEvent trigger emergencyRefuel gauge combine 4
tcEvent trigger fieldSold
tcEvent trigger fieldSold bereavement 4
tcEvent trigger farmerRetirement
tcEvent trigger farmerRetirement 4
```

## Farmers — `tcFarmer`

### `tcFarmer list`

The map's farmers and the local official (110), who the jobs come from. The farmers are made the first time the mod runs on a save, by sharing out every farmland with a field that no player owns (see `tcFarmer preview`), and they're the same for every farm. A farmer can lose all their land to players and still be on the list; land a player sells goes to a farmer near it. Jobs on a farmer's land are for that farmer, and anything else (jobs on land no farmer has, a fallen tree) is for the local official.

One line per farmer with their id, name and gender, their acres (and the target they were made with), their farmlands, and their yard (or "yard off the map"), then the local official. These are the ids and names `<farmer>` takes. Read-only, so it also works on a joined client.

```
tcFarmer list
```

```
Farmers (5), from a split at 30 acres a farmer, seed 1234:
  #2 Tom Hargreaves (male): 92 acres (target 88), 3 farmland(s): 12, 14, 15, yard 12
  #3 Ruth Bell (female): no land, yard off the map
  ...
Local official: #1 Alan Price (male)
```

### `tcFarmer preview [targetAcres] [seed]`

How the land would be split now, without changing anything. The total acres and number of farmers, then one line per farmer with their acres (and target), how many farmlands and which, and their yard (`(start)` if the farmer started there). Last, the largest and smallest holdings, how many yards were used and how many balancing moves were made.

The split: only farmlands with at least one field and no player owner, every one of them to a farmer, a farmland's size its fields' area in acres; one farmer per `targetAcres` (default 50), at least 4, each aiming for that size give or take up to 30%; farm yards (`tcYard list`) on or near field land start a farmer, the most yard-like first (a declared one, then one that isn't small, then one without a sell point, then the most yard buildings, then the most sheds and farmhouses), and any yard left over, in the same order, goes to a nearby farmer who has none. A small yard (4 yard buildings or fewer) never starts a farmer: it's only ever a leftover, for a farmer who ended up without a yard (a declared one, `tcYard set <id> on`, to the nearest farmer without one however far, and its land isn't shared out as fields). Read-only.

`seed`: the same seed always gives the same split. Without one a random one is used, and the first line says which, so a split you like can be shown again.

```
tcFarmer preview
tcFarmer preview 80
tcFarmer preview 80 1234
```

### `tcFarmer show [targetAcres] [seed]`

The same as `tcFarmer preview`, and a label on the map at the middle of each farmland's fields with its farmer's number, and `Y` and the number on each farmer's yard, one colour per farmer, on this machine only. Use it to choose a `targetAcres` before `tcFarmer regenerate`.

```
tcFarmer show 80 1234
```

### `tcFarmer hide`

Clears `tcFarmer show`'s labels.

### `tcFarmer fleet [farmer]`

Each farmer's machines (121), or one farmer's (an id or full name from `tcFarmer list`): a line per farmer with their acres and yard, then one per machine with its id, role (`smallTractor`, `mediumTractor`, `largeTractor`, `combine`, `header`, `trailer`, `telehandler`, `baleFork`), model, what it's hitched to (`on <id>`, for a header or a bale fork), its operating hours once it's been out, and `out now` while it's on a job or on its way. Every farmer has a small and a medium tractor, a combine with a header and a trailer; about half a second small tractor; one with a yard a telehandler and a bale fork; and the biggest 10% of farmers by land, if they're over 50 acres, a large tractor as well. Machines are only ever added (a new yard brings a telehandler), never taken away. A bale fork is always a spike (125): one that isn't, such as a bale grab from an older save, is changed to a spike on loading, under the same id (unless it's out, then on a later load). Server only.

```
tcFarmer fleet
tcFarmer fleet Tom Hargreaves
```

### `tcFarmer regenerate [targetAcres]`

Throws the farmers away and makes new ones from a fresh split at `targetAcres` (default 50), with new names, looks and ids. The local official stays. Every job loses its link to the old farmers, and every farm its relationships with them (`tcFarmer relationships`; the official's are kept): jobs are linked again from their fields, and the command says how many changed. Server only.

```
tcFarmer regenerate 60
```

### `tcFarmer relationships`

Your farm's relationship with each farmer and the local official (113), from -100 to 100. Everyone starts at 0. Completed jobs raise it (more for better quality, and poor work lowers it). Missed, declined and lapsed offers, a counter-offer they walked away from, and an invoice you pursue all lower it. Every month it drifts 5 back towards 0. Good relationships bring more of that customer's offers and more room to haggle. Below -40 they offer you no work at all.

When it goes bad (129): a missed job, or one done under 50% quality, that leaves a customer at `poor` (-40 to -15) gets a complaint from them in your Inbox, at most once a month each. A customer dropping below -40 tells the neighbours: every farmer with land or a yard within 500 m of theirs drops 5 with you, your reputation drops 15, and a notice names them. Their drops never spread word further.

One line per person (the official first) with their id, name, score and band (`excellent`, `good`, `neutral`, `poor`, `fallenOut`). Read-only, so it also works on a joined client.

```
tcFarmer relationships
```

```
Farm 1's relationships (-100 to 100, refusing work below -40):
  #1 Alan Price (local official): 0 (neutral)
  #2 Tom Hargreaves: 18 (good)
  #3 Ruth Bell: -45 (fallenOut)
```

### `tcFarmer relationship <farmer> <amount>`

Changes your farm's relationship with a farmer or the local official (their id or full name, from `tcFarmer relationships`) by `amount`, which can be negative. The result is kept within -100 to 100. It goes through the same path as the game's own changes, so taking someone from -40 or above to below it spreads word to their neighbours (see `tcFarmer relationships`; a complaint only comes from a job). Server only.

```
tcFarmer relationship 4 -50
tcFarmer relationship Tom Hargreaves 20
```

## Yards — `tcYard`

### `tcYard list`

A spike for finding the map's farm yards (108), where the generated farmers will live. A yard is a farmland with at least 2 buildings that change hands with the land (sheds, silos, animal pens, farmhouses, ...; the map's own, preplaced or from its default placeables), at least one of them a shed or a farmhouse and one not a farmhouse (a working building), and no more than 5 farmhouses (more is a village). Detection runs on the live map each time; only your overrides (`tcYard set`) are saved. Read-only, so it also works on a joined client.

One line per yard with its farmland id, owner farm (0 for nobody), how it became a yard (`detected`, or `declared` with `tcYard set`), its buildings by store category, whether any has a sell point or unloading station, its standing spots (how many it keeps, spread over the yard, of how many open ones it found) and where its middle is (`(centre marker)` when a yard centre marker sets it, 146). Then the farmlands that have such buildings but aren't yards (the near misses, including any you ruled out), and every store category seen, so the rule's categories can be set from real maps. Spots are worked out as you ask (it can take a moment); on a joined client the navigation map check is skipped, so the count can be higher than the server's.

```
tcYard list
```

```
Yards (1):
  #12 owner 0, detected, 4 building(s) (ANIMALPENS 1, SHEDS 2, SILOS 1), unloading, spots 40 of 212, at 412, -318
Farmlands with buildings but no yard (1):
  #5 owner 0, 1 building(s) (SHEDS 1)
Categories seen: ANIMALPENS 1, SHEDS 3, SILOS 1
```

### `tcYard check <farmlandId|here>`

Why a farmland (`<farmlandId>`, or `here` for the one you're standing on) is or isn't a yard: why that farmland is or isn't a yard. First whether it's a yard and how (with its override), then what detection alone makes of it and, if it fails, every reason (too few yard buildings, no shed or farmhouse, no yard building that isn't a farmhouse, more than 5 farmhouses, no buildings that count). For a yard, next comes where its middle is and where that comes from: its yard centre marker (146), the middle of its buildings, or the farmland's label on the map (where the map maker put its name, not necessarily the farm). Then the buildings it counts, one per line, with name, store category, whether that category counts towards a yard (`(yard)`), stations and position. Then every other placeable standing on the farmland, with whether it's preplaced (built into the map's i3d) or placed (the map's default placeables, or the player's), its owner farm, and every reason it isn't counted: its store item isn't sold with the farmland, the map or savegame says it isn't, or it's being deleted. With nothing at all on the farmland it says so: buildings built into the map's own scene aren't placeables, so detection can't see them, and `tcYard set <id> on` is the way to make it a yard, with a yard centre marker (the construction menu's Contractor tab) to say where on the farmland the yard is. For a yard, last comes how its standing spots came out, worked out again as you ask: how many it keeps of how many open ones, from how many candidate points; the server's list (what its farmer stands on); how many candidates each check ruled out (too close to a kept spot, inside a building's footprint, off the farmland, indoors by the indoor mask, too steep, on a field, off the AI navigation map, or something solid in the way); and what was in the way, most first: for a footprint, its building's name; for something solid, the placeable or vehicle, then the node it hit. Use it when a map's farm isn't picked up, or its farmer has no spots to stand on. Read-only, so it also works on a joined client.

```
tcYard check 12
tcYard check here
```

```
Farmland 30: declared (override on)
  Detection alone: not a yard: no buildings that count
  Middle at 1210, -455, from its yard centre marker
```

```
Farmland 5: not a yard (override auto)
  Detection alone: not a yard: 1 yard building(s), needs 2
Counted (1):
  Machine Shed [SHEDS] (yard) at 980, 214
Not counted (1):
  Grain Silo [SILOS] at 1002, 230 (placed, owner 0): its store item isn't sold with the farmland
```

```
Spots: 0 kept of 0 open, from 214 candidates
  The server's list for the farmer: 0
  22 inside a building's footprint
  18 off the farmland
  174 something solid in the way
  In the way:
    Concrete Slab (collision): 120
    Machine Shed (wall): 30
```

### `tcYard show [farmlandId]`

A red circle on the map at every yard, on this machine only. With a `farmlandId`, just that yard, with a small circle on each of its standing spots: the server's list, the one its farmer stands on (114), worked out once a load and again when the yard's override changes. Each farmhouse in the yard also gets a big circle 10 m out along its own +Z (the direction the model faces in its file), and a small one on its spawn node (where a player appears on their farm) if it has one. The command lists each farmhouse with its +Z direction and how far, and how many degrees clockwise from +Z, its spawn node is, to check which side of a house is its front.

```
tcYard show
tcYard show 12
```

### `tcYard hide`

Clears `tcYard show`'s circles.

### `tcYard set <farmlandId> <on|off|auto>`

Overrides yard detection for a farmland, for every farm (it's saved and sent to everyone): `on` makes it a yard whatever's on it (with no buildings it sits at the farmland's middle), `off` rules it out, and `auto` goes back to detection. The farmers' yards follow straight away. A yard you declare (`on`) isn't field land: whoever farmed it loses it, and it goes to the nearest farmer without a yard, however far. A farmer whose yard is ruled out loses it. Land a player owns is never a farmer's yard. Server only. The in-game map does the same from a farmland's box ("Set as farmer yard" / "Unset as farmer yard", for the host or an admin, on land no player owns).

```
tcYard set 12 off
tcYard set 30 on
tcYard set 30 auto
```

## Auction — `tcAuction`

### `tcAuction status`

The machinery auction (137) and its sale (139). One is announced now and then by itself (about one a year, now and then two, never within 3 months of the last one ending, for a sale in spring or autumn, 2 to 4 months ahead); this shows it or makes one happen. One started here counts as the last one when it ends.

The auction, if there's one: its id, field, host farmer and state (`announced`, `signsUp`, `setOut`, `onSale` or `collection`), the day it was announced, the day its signs go up, its reminder day and its sale day, its entrance, and once the signs are up (136) each sign's position (world x, z, as `tcDebug auctionSigns` lists them). `tcAuction start` and `tcDebug auctionDay` print the same, so the signs' positions are in the log as soon as they're up. Server only.

```
tcAuction status
```

```
Auction 1 on field 12, held by Tom Hargreaves: signsUp.
  Announced March 4, Year 2; signs up April 10, Year 2; reminder May 3, Year 2; sale May 10, Year 2 (viewing and bidding from 08:00, lots closing from 17:00).
  Entrance at 512, -88.
```

### `tcAuction start [fieldId|auto] [days]`

Announces one now, ignoring the season and the monthly roll. If the sale's in this month, every company farm gets its attend-the-auction job (141) at once; otherwise on the first day of the sale's month. Its field is picked as a real one is (a grass, bare or harvested field nobody's farm owns, held by a farmer, with no live job, that can hold a sale; at random among the best 3), its sale 2 to 4 months ahead. The signs go up 3 months before the sale, or at once if it's nearer. Every company farm gets the message, and every player the map marker.
- `<fieldId>`: on that field instead (`tcAuction fields` lists the fields that can hold one). No farm may own it, a farmer must hold it, and it can't have a live job; it doesn't have to be grass, bare or harvested, or a candidate (whatever's on it is put down to grass on the sale day and put back after).
- `auto`: the field picked as above, so `[days]` can be given without a field.
- `[days]`: the sale that many days from today (at least 1), not 2 to 4 months. The signs go up 3 months before the sale, or at once if the sale's nearer than that.

There's only ever one auction: `start` refuses while one's on. The auction is saved, and a player joining gets it.

```
tcAuction start
tcAuction start 12
tcAuction start 12 3
tcAuction start auto 3
```

### `tcAuction cancel`

Calls it off: no more lots are sold, anything already won and still on the field is delivered, anything else on the field is deleted, the signs come down, the field's free again, and every company farm is told. Any attend-the-auction job (141) not yet done is taken away.

```
tcAuction cancel
```

### `tcAuction fields`

The fields that could hold a machinery auction, best first: the candidates a real auction picks from, for `tcAuction start <fieldId>`. A candidate is a field no farm owns that's grass, bare (no crop) or harvested (its crop cut, not sown, growing or withered), with no live job, of 1 ha or more. A sale takes as many lots as its field fits, up to 120, so each field is measured against a typical 120-lot sale. Each line has the field's id and the farmer who holds it, its area, how many of the 120 fit, its slope (the steepest rise between ground samples 8 m apart, the average, and the whole rise in metres), how far the nearest road is from its edge, and whether it can hold a sale. It can't if fewer than 30 lots fit, the steepest slope is over 8%, or there's no road within 60 m. Those that can come first, the most lots first, then the biggest. The last line says how many can, and how long the check took. With a test site up (`tcDebug auctionSite`) it starts with that. Server only.

```
tcAuction fields
```

```
Auction site candidates (grass, bare or harvested, nobody's farm, no live job, 1 ha or more), measured against a sale of 120 lots, a sale needing 30, most lots first:
  field 12 (Tom Hughes): 6.40 ha, 120 of 120 lots fit, slope steepest 4.1%, average 1.2%, rise 3.0 m, road 14 m from the edge - can hold the sale
  field 31: 2.10 ha, 22 of 120 lots fit, slope steepest 2.0%, average 0.8%, rise 1.1 m, road 40 m from the edge - too small
1 of 2 candidates can hold the sale (64 fields on the map), checked in 410 ms.
```

## Log — `tcLog`

### `tcLog`

Toggles the mod's detailed log (jobs dispatched, invoices paid, events rolled and so on) in `log.txt`, and says whether it's now on or off. It takes no arguments. It's on by default, so a bug report's `log.txt` already has it; warnings and errors are logged whether it's on or not. The switch belongs to this machine only (it works from any player's console, and isn't synced) and is remembered across loads in `modSettings/FS25_TheContractor/debugLog.xml`, so turn it on and reload to catch a save loading.

```
tcLog
```
