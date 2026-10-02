# FS25_TheContractor

<placeholder: mod description>

## Console commands

All commands are typed into the developer console. They're only available when the game is started with cheats enabled (`g_addCheatCommands`), and they only work on the server: in single player or as the host of a multiplayer game, not on a joined client. Every command acts on **your current farm**, and most need that farm to have created a company first.

### Jobs

#### `tcOfferJob [jobType]`

Offers your farm a job of the given type right now, through the normal job generator. You get a real offer on a real field, with the usual price, deadline and required skill, so the game could have offered the same job by itself. This is useful for testing and for setting up a storyline.

- No `jobType` lists the available types.
- Job types (case-insensitive): `harvest`, `cultivate`, `sow`, `plow`, `mow`, `tedder`, `bale`, `baleWrap`, `fertilize`, `herbicide`, `weed`, `hoe`, `stonePick`.
- It picks a field your farm has the equipment for when it can, and falls back to any eligible field otherwise.
- It fails only when the generator itself couldn't offer that type right now. Examples are harvest in winter, weeding on a save with weeds off, or a crop whose ready date can't be predicted. The output says why. Use `tcJobAvailability` to see which types have work available.

```
tcOfferJob mow
```

#### `tcJobAvailability`

A dry run of job generation for your farm. It changes nothing. It shows the current hourly offer chance and the expected number of offers per period. For each job type it lists:

- **eligible fields**: fields you don't own that qualify for the job type right now
- **with target date**: eligible fields that also have a workable deadline
- **fulfillable**: fields from that list your farm owns the equipment for

#### `tcCreateTestJob jobType fieldId requiredSkillLevel price targetPeriod targetDayInPeriod`

Creates a job with every detail set by hand. Unlike `tcOfferJob`, nothing is checked: the field doesn't have to suit the job type and the date doesn't have to be workable. Use it to test specific edge cases.

| Argument | Meaning |
|---|---|
| `jobType` | One of the job types listed under `tcOfferJob` |
| `fieldId` | Field id |
| `requiredSkillLevel` | 1–10 |
| `price` | Payout in money |
| `targetPeriod` | Due period (1–12) |
| `targetDayInPeriod` | Due day within that period |

```
tcCreateTestJob plow 12 3 5000 4 1
```

#### `tcSetJobState jobId state`

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
tcSetJobState 7 accepted
```

### Reputation

#### `tcAddReputation amount`

Adds reputation points to your farm, or removes them with a negative amount.

```
tcAddReputation 100
tcAddReputation -50
```

### Staff

#### `tcListStaffPool`

Lists the candidates currently available to hire, with their id, name, work speed, salary and the tiers of work they can handle.

#### `tcHireWorker candidateId`

Hires a candidate from the staff pool. Get the id from `tcListStaffPool`.

```
tcHireWorker 3
```

#### `tcRetireWorker workerId [noticeMonths]`

Makes one of your hired workers hand in their retirement notice. `noticeMonths` defaults to 6; `0` retires them straight away.

```
tcRetireWorker 2
tcRetireWorker 2 0
```

### Notices

#### `tcPublishNotice ttlMonths|none text...`

Publishes a notice to your farm's Overview board. `ttlMonths` is how many months it stays up; `none` keeps it up until it's removed. Everything after the first argument is the notice text.

```
tcPublishNotice 3 Harvest season is coming, book your combines early
tcPublishNotice none Welcome to the company
```

#### `tcRemoveNotice noticeId`

Removes a notice from the Overview board. `tcPublishNotice` prints the id when it publishes a notice.

```
tcRemoveNotice 4
```
