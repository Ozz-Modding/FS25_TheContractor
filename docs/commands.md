# Console commands

You type these into the developer console. You don't need cheats on. There are four group commands and a help command:

| Command | What it covers |
|---|---|
| `tcHelp` | Lists the groups below |
| `tcWorker` | Hire, list and change your staff |
| `tcJob` | Offer, create and force jobs |
| `tcFinance` | Invoices, claims and botched jobs |
| `tcCompany` | Reputation and Overview notices |

Type a group on its own (or with `help`) to list its subcommands and their arguments. Subcommand names aren't case-sensitive. If you get the arguments wrong, the command prints that subcommand's usage.

- **Your farm:** every command acts on your current farm. Most need that farm to have created a company first.
- **Server only:** commands that change something only work on the server, which means single player or the host of a multiplayer game. The read-only lists `tcWorker list`, `tcWorker pool`, `tcJob log`, `tcCompany notices` and `tcCompany vehicleLog` also work on a joined client.
- **`<worker>`:** a hired worker's id, or the start of their first or last name. `amy`, `Hall` and `3` could all mean Amy Hall (#3). If a name matches more than one worker, the command lists them and asks for the id. `tcWorker list` shows ids and names.

## Workers — `tcWorker`

### `tcWorker list`

Lists your farm's hired workers with their ids. Each line shows the name, status, age, morale (0-100, with its band) and crop care skill, then where they stand on the spraying certificate:
- certified
- booked, with the course days left, the next course day and the assessment day (monotonic days)
- failed, retake due
- not certified, ready or not ready

If any apply, it also shows declined training requests, a booked holiday (monotonic days) and when they're leaving (retiring or quitting).

```
Farm 1 workers (today is day 104):
#3 Amy Hall - training, age 34, morale 72 (content), crop care 5, spraying: booked (1 course day(s) left, next day 104, assessment day 107)
#7 John Smith - idle, age 58, morale 24 (unhappy), crop care 2, spraying: not certified, not ready; quitting March, Year 3
```

### `tcWorker pool`

Lists the candidates currently available to hire, with their id, name, work speed, salary, the tractor sizes they can drive and their operation skills.

### `tcWorker hire <candidate>`

Hires a candidate from the staff pool. Like `<worker>`, `<candidate>` is an id or the start of a name, from `tcWorker pool`.

```
tcWorker hire 3
tcWorker hire smith
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

### `tcWorker holiday <worker> [daysFromNow] [days]`

Books a holiday for one of your hired workers, skipping the usual notice and allowance rules. `daysFromNow` defaults to 0 (starting today) and `days` defaults to 1. It fails if the worker already has a holiday booked.

```
tcWorker holiday 2
tcWorker holiday 2 3 5
```

### `tcWorker train <worker> [daysFromNow] [pass|fail]`

Books one of your hired workers on spraying training for free, skipping the readiness check.
- **What gets booked:** a worker who failed their assessment gets the retake (an assessment day only). Anyone else gets the 2-day course, with the assessment 2-5 days after it.
- **`daysFromNow`:** defaults to 0, so an idle worker starts today.
- **`pass` or `fail`:** fixes the assessment's result. Without it, the result is rolled from their crop care skill.

It fails if the worker is already certified or already has training booked.

```
tcWorker train 2
tcWorker train amy 0 fail
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

## Jobs — `tcJob`

### `tcJob offer <jobType>`

Offers your farm a job of the given type right now, through the normal job generator. You get a real offer on a real field, with the usual price, deadline and required skill, so the game could have offered the same job by itself. This is useful for testing and for setting up a storyline.

- No `jobType` lists the available types.
- Job types (case-insensitive): `harvest`, `cultivate`, `sow`, `plow`, `mow`, `tedder`, `bale`, `baleWrap`, `fertilize`, `herbicide`, `weed`, `hoe`, `stonePick`.
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
| `skill` | Required skill level, 1–10 |
| `price` | Payout in money |
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
| `allocated` | `in_progress`, `completed`, `missed` |
| `in_progress` | `completed`, `missed` |

`completed`, `declined` and `missed` are final.

```
tcJob state 7 accepted
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

Parks the vehicle you're sitting in, for testing parking slots. You're put out of the vehicle and it's unhitched from anything it's pulling. It then goes to a random free spot in one of your farm's parking slots. If none is free (or you haven't placed any), it's hidden and joins the parking queue, the same as equipment back from a job: it's parked within about 5 seconds of a slot coming free. Takes no arguments. It has to be your farm's vehicle and not out on a job.

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
