# The Contractor

Run your farm as an agricultural contracting business in Farming Simulator 25. The Contractor replaces vanilla contracts with its own jobs, staff and business management.

## Getting started

1. Open the in-game menu and go to the new **Contractor** page.
2. On the **Overview** tab, create your company and give it a name.
3. Job offers arrive in the **Inbox**. Accept or negotiate them, then book who does each job and with which machines on the **Calendar**.
4. Hire workers on the **Staff** tab, or do the work yourself.
5. Place **parking slots** and **standing spots** from the construction menu (Buildings, Contractor tab), so machines coming back from jobs and idle staff have somewhere to go.

## Features

### Your company
- Found a contracting company for your farm from the new **Contractor** menu
- **Reputation** grows with good work and drops with missed or botched jobs, and it decides how much work comes your way
- **Advertising** campaigns (newspapers through to TV) bring in extra work
- Your own **company logo** on the Overview (see [Company logo](#company-logo))

### Jobs
- Vanilla contracts are switched off and replaced by the mod's own job offers
- Every vanilla field job type: harvesting, mowing, tedding, baling, wrapping, cultivating, ploughing, sowing, fertilising, spraying, weeding, hoeing, stone picking
- **Harvest & haul** and **straw bale delivery** jobs, where the crop or bales have to reach a selling point
- Offers are matched to the machines you own, and some are booked ahead for crops that aren't ready yet
- **Price negotiation**: counter-offer, but push too hard and the client walks away
- **Calendar** of booked jobs, and a choice of who does each job and with which machines (a worker or you)
- Progress is read from the field itself, whoever's driving
- Missed deadlines have consequences

### Staff
- Hire workers from a pool of candidates, each with their own skills, potential and personality
- Hired workers drive the real vanilla AI helper to the field, do the work and come home
- Skills grow with experience. Skills affect speed, quality, machine wear, and how clean the kit comes back
- Monthly salaries at real UK rates, pay reviews and rising market value
- Morale, bonuses, quitting, retirement, holidays and sickness
- Notice and redundancy pay when you let someone go
- Spraying certificates and paid training
- Each worker has their own look, a live 3D portrait, and can be renamed and restyled
- Idle staff stand around the yard on placeable **standing spots**
- AutoDrive and Courseplay vehicles get a driver from your staff

### Running the business
- Jobs are **invoiced**. Clients pay late, and some never pay
- Recurring **overheads**: mandatory insurance, plus optional public liability, machinery insurance (with levels of cover), a trade association, legal cover and a health and safety programme
- Compensation claims when a job goes wrong
- An **office administrator** to keep invoicing and credit control on track
- **Finances** tab with year-to-date figures and a cash forecast
- Job diesel, seed, fertiliser and other supplies come from your own farm stock, and a **Supplies** tab shows what you've got
- A **Logbook** of every job and every machine's history: who had it, what it was doing, and what state it came back in

### Equipment
- Machines out on a job leave the yard and come back to placeable **parking slots** (three sizes, for vehicles or implements, plus a harvester slot)
- Stuck AI helpers are detected and dealt with
- Advanced Damage System support: careless workers cause ADS breakdowns, and its workshop stock shows in the Supplies tab

### Random events
- **Vehicle theft**, with police reports, insurance claims and a courtesy vehicle while you wait
- **Joyriders** tearing up grass fields, which can turn into repair work for you

### General
- Full multiplayer support, with everything farm by farm
- Settings for job pay rate, late invoices, random event frequency and more, in the game's own Settings page
- Works with FS25_EconomyScale
- Console commands for tailoring your game (see [Console commands](#console-commands))

## Company logo

The Overview's company card shows a logo. To use your own, save it as `logo.dds` or `logo.png` in `Documents/My Games/FarmingSimulator2025/modSettings/FS25_TheContractor/` (the mod creates the folder the first time a save loads).

- It must be square, with sides a multiple of 4 (512×512 or 1024×1024 work well). Any other shape is stretched to fit.
- If both files are there, `logo.dds` is used.
- A PNG works fine but puts a few harmless performance warnings in the game log. A DDS with mipmaps (GIANTS Texture Tool, or paint.net's DDS export) avoids them.
- A new logo shows the next time you open the menu, but replacing one you've already seen needs a game restart.
- The logo is read from your own PC only: in multiplayer, other players see their own logo file, or the default.

## Console commands

Type `tcHelp` in the developer console to list the mod's commands. Each group (`tcWorker`, `tcJob`, `tcFinance`, `tcCompany`) lists its own subcommands when typed on its own. They're all documented in [docs/commands.md](docs/commands.md).

## Support

For bug reports, feature requests, or questions, visit the [GitHub Issues page](https://github.com/Ozz-Modding/FS25_TheContractor/issues).

## Discord

[![Discord](https://img.shields.io/discord/1415966930799693847?logo=discord)](https://discord.gg/9pVhkV9KRQ)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/M4M41K5NPV)
