# Shiny Hunter

A shiny Pokémon hunter for **Pokémon FireRed (USA) v1.0**, written in Elixir with Phoenix LiveView.

The game logic (random number generator, wild Pokémon creation, shiny check and encounter tables) was reverse engineered from the ROM itself with [REA](ARCHITECTURE.md#rea) on top of Ghidra. The app tries every **initial seed × RNG advance** combination and lists the ones that produce the Pokémon you are looking for.

The search runs in parallel on every CPU core: about **5.6 million Pokémon per second** with 12 workers, and the full 655-million-Pokémon grid in under 2 minutes.

> The project started as a fun demo of parallel processing and fault tolerance on the BEAM. How it was built is described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Running with Docker](#running-with-docker)
- [Running locally](#running-locally)
- [The ROM (optional)](#the-rom-optional)
- [Quick start](#quick-start)
- [Form fields](#form-fields)
- [Progress panel](#progress-panel)
- [Results table](#results-table)
- [Concepts: seed, advance, slot](#concepts-seed-advance-slot)
- [Environment variables](#environment-variables)
- [Tests](#tests)
- [Limitations](#limitations)
- [Project layout](#project-layout)
- [Legal notice](#legal-notice)

## Features

- Reproduces, bit for bit, how FireRed creates a wild Pokémon: encounter slot, level, nature, PID, IVs and shininess.
- Filters by shiny, species (or slot), nature and minimum IVs.
- Splits the work into blocks of seeds, one BEAM process per block, and shows each worker's progress live in the browser.
- Survives worker crashes: the **Derrubar um worker** (kill a worker) button kills a process mid-search, its block goes back to the queue and no result is lost or counted twice.
- With a ROM configured, reads the game's 132 encounter tables so you can pick map and species by name.

## Requirements

Pick one path:

| Path | Needs |
| --- | --- |
| Docker | Docker (Compose v2 optional) |
| Local | Elixir 1.17+ with a compatible Erlang/OTP (built with Elixir 1.20.1 / OTP 29), `git` |
| Full test suite | Local setup plus `gcc`, and Python 3 with Unicorn for the ROM tests |

There is no database. Nothing is written to disk.

## Running with Docker

```bash
git clone https://github.com/patric-vinicios/shiny_hunter.git
cd shiny_hunter
docker compose up --build
```

Open http://localhost:4000.

Without Compose:

```bash
docker build -t shiny_hunter .
docker run --rm -p 4000:4000 shiny_hunter
```

With a ROM (see [The ROM](#the-rom-optional)):

```bash
docker run --rm -p 4000:4000 \
  -v "$PWD/rom/firered.gba:/rom/firered.gba:ro" \
  -e FIRERED_ROM=/rom/firered.gba \
  shiny_hunter
```

With Compose, uncomment the `FIRERED_ROM` and `volumes` lines in `docker-compose.yml` and place the ROM at `./rom/firered.gba` (the `rom/` folder is git-ignored).

The container runs a production release. If `SECRET_KEY_BASE` is not set, a key is generated at every boot; since the app has no login or persistent sessions, this has no practical effect.

## Running locally

```bash
mix setup          # fetch dependencies and build assets
mix phx.server     # or: iex -S mix phx.server
```

With a ROM:

```bash
FIRERED_ROM=/path/to/firered.gba mix phx.server
```

Open http://localhost:4000.

## The ROM (optional)

The app works **without a ROM**. In that mode you pick the encounter table *slot number* instead of a species, and the results table shows no species or level.

With a ROM, the **Mapa** (map) and **Espécie** (species) fields appear and each result gets its level.

- Only **FireRed (USA) v1.0** is accepted, SHA-1 `41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc`. Every address the app reads comes from that version; any other ROM is rejected.
- The ROM is **not part of this repository** and must never be committed. The legitimate way to get one is dumping your own cartridge (for example with a GBxCart RW).
- The ROM is read once, at boot. If it cannot be read, the page shows why under the title.

To check the hash:

```bash
sha1sum firered.gba
```

## Quick start

1. Enter your save's **TID** and **SID**.
2. Pick the **Mapa** (map), the **Encontro** (encounter type: grass, surf, Rock Smash or a rod) and optionally the **Espécie** (species). Without a ROM, pick the **Slot da tabela** (table slot).
3. Optionally filter by **Natureza** (nature) and minimum IVs. Keep **Só shiny** (shiny only) checked to hunt shinies.
4. Set the number of **Workers**. The default is the number of CPU cores.
5. Click **Caçar** (hunt). Results show up while the search runs.

A quick way to see the parallelism: run a hunt on Route 1 with `Workers = 1`, note the Pokémon per second, then run it again with the default. During the search, click **Derrubar um worker** a few times and check that the final total does not change.

## Form fields

The UI is in Portuguese. Each field is listed with its on-screen label and an English translation.

### Trainer

| Field | Values | Purpose |
| --- | --- | --- |
| **TID** | 0 – 65535 | Trainer ID, shown on the trainer card. Part of the shiny check. |
| **SID** | 0 – 65535 | Secret ID. Not shown in game; read it from your save with a tool such as PKHeX. Also part of the shiny check: with a wrong SID, the shinies found will not be shiny in your game. |

The game's shiny check is `TID xor SID xor PID_high xor PID_low < 8`, about 1 in 8,192.

### Encounter

| Field | Shown when | Purpose |
| --- | --- | --- |
| **Mapa** (map) | A ROM is configured | Where the encounter happens, with the name read from the ROM. Maps with several floors are numbered (`MT. MOON · 2`); alternate headers of the same map show as `variante N`. **Sem mapa (só slot)** (no map, slot only) switches back to slot search. |
| **Encontro** (encounter) | Always | The encounter type. With a map, only the types that map has are listed. Options: **Grama / caverna** (grass / cave), **Surf**, **Rock Smash**, **Vara velha** (Old Rod), **Vara boa** (Good Rod), **Super vara** (Super Rod). Each type has its own table and slot chances. |
| **Espécie** (species) | A map is selected | The Pokémon to find, with its level range and total chance (`PIKACHU (Nv. 3–5, 5%)`). A species can fill several slots; all of them are searched. **Qualquer** (any) accepts every species of the encounter. |
| **Slot da tabela** (table slot) | No map is selected | The encounter table position that must come out. **Qualquer** (any) accepts every slot of the chosen type. |

Slot chances per encounter type, as the game rolls them:

| Encounter | Slot: chance |
| --- | --- |
| Grass / cave | 0: 20%, 1: 20%, 2: 10%, 3: 10%, 4: 10%, 5: 10%, 6: 5%, 7: 5%, 8: 4%, 9: 4%, 10: 1%, 11: 1% |
| Surf and Rock Smash | 0: 60%, 1: 30%, 2: 5%, 3: 4%, 4: 1% |
| Old Rod | 0: 70%, 1: 30% |
| Good Rod | 2: 60%, 3: 20%, 4: 20% |
| Super Rod | 5: 40%, 6: 40%, 7: 15%, 8: 4%, 9: 1% |

The three rods share the map's single 10-entry fishing table; each rod uses its own range of slots.

### Filters

| Field | Values | Purpose |
| --- | --- | --- |
| **Natureza** (nature) | Any, or one of the 25 | Keeps only results with that nature. |
| **HP / Atk / Def / SpA / SpD / Spe mín.** | 0 – 31 | Minimum IV per stat. A result passes only if all six IVs are at or above their minimum. `0` means no filter. |
| **Só shiny** (shiny only) | Checked or not | Checked: only results that are shiny for the given TID/SID. Unchecked: any Pokémon that passes the other filters (useful for IV or nature hunts; combine it with filters, or almost everything passes). |

### Search space

| Field | Values | Purpose |
| --- | --- | --- |
| **Semente inicial de / até** (initial seed from / to) | 0 – 65535 | Range of initial seeds to try. The default `0 – 65535` covers every seed the game can start from. |
| **Avanço de / até** (advance from / to) | 0 – 10,000,000 | Range of RNG advances to try for each seed. Default `0 – 9999`. |
| **Workers** | 1 – 1024 | How many seed blocks are processed at the same time. The label shows the machine's core count; going above it gains nothing. Use `1` to compare with a sequential search. |

The number of Pokémon generated is `(seeds) × (advances)`. The default grid is 65,536 × 10,000 = 655 million.

### Buttons

| Button | What it does |
| --- | --- |
| **Caçar** (hunt) | Starts a new hunt. A hunt already running is replaced. |
| **Cancelar** (cancel) | Stops the current hunt. Results found so far stay on screen. |
| **Derrubar um worker** (kill a worker) | Kills a random worker with `Process.exit(pid, :kill)`. Its block goes back to the queue and is redone from scratch, with nothing counted twice. It exists to show fault tolerance. |

The hunt is global: it keeps running if you close the tab, and every open tab shows the same hunt.

## Progress panel

| Indicator | Meaning |
| --- | --- |
| Status | `parado` (idle), `caçando` (hunting), `concluído` (done) or `cancelado` (cancelled). |
| Pokémon gerados (generated) | How many of the total have been generated and checked, with a progress bar. |
| Pokémon por segundo (per second) | Rate, measured every 200 ms. |
| Tempo (time) | Time since the hunt started. |
| Encontrados (found) | Total results that passed the filters, including those that do not fit in the table. |
| Workers derrubados (workers killed) | How many times a worker died and had its block redone. |
| Worker cards | One per running process: its PID, the block's seed range and its progress. |

## Results table

The table shows up to 500 results; the **Encontrados** counter includes all of them.

| Column | Meaning |
| --- | --- |
| **Semente** (seed) | The initial seed, in hex. |
| **Slot** | The encounter table position rolled. |
| **Espécie** (species) / **Nível** (level) | The Pokémon and its level, from the map's table (ROM only). |
| **Avanço** (advance) | How many steps the RNG must have taken from the seed to the start of the encounter. |
| **PID** | The personality value, in hex. A sparkle icon marks shinies. |
| **Natureza** (nature) | `PID mod 25`. |
| **HP, Atk, Def, SpA, SpD, Spe** | The IVs. 31s are highlighted. |

## Concepts: seed, advance, slot

- **Seed**: at boot, FireRed reads the GBA's Timer 1 counter and uses that 16-bit value as the RNG seed. That is why there are only 65,536 initial seeds.
- **Advance**: every call to `Random()` moves the RNG state one step. The advance is the number of steps from the seed to the moment the encounter starts rolling. This follows the community calculators' convention: the per-step "is there an encounter" check is not counted.
- **Roll order** in a wild encounter: slot (`Random() % 100`), level, nature (`Random() % 25`), PID (rerolled until `PID % 25` matches the nature, low half first), then the two IV words.
- **Slot**: a position in the map's encounter table. Each slot holds a species and a level range.

## Environment variables

| Variable | Default | Use |
| --- | --- | --- |
| `FIRERED_ROM` | (unset) | Path to a FireRed (USA) v1.0 ROM. Without it, the app searches by slot. |
| `PORT` | `4000` | HTTP port. |
| `PHX_HOST` | `localhost` in Docker | Public host name, used to check the LiveView WebSocket origin. Set it when accessing the app by another name or IP. |
| `SECRET_KEY_BASE` | generated at boot (release/Docker) | Cookie signing key. Required for `MIX_ENV=prod mix phx.server`; generate one with `mix phx.gen.secret`. |

In production (`MIX_ENV=prod`) Phoenix forces HTTPS for hosts other than `localhost` and `127.0.0.1`. To expose the app on another host, put a TLS proxy in front of it that sends `X-Forwarded-Proto`.

## Tests

```bash
mix test                                                  # 20 tests, no ROM (needs gcc)
FIRERED_ROM=/path/to/firered.gba mix test --include rom   # 27 tests, with ROM and emulator
mix precommit                                             # warnings, formatting and tests
```

- The reference test compiles `test/support/reference/firered_wild.c`, a literal C translation of the pseudocode extracted from the ROM, and compares thousands of cases with the Elixir code. It needs `gcc`.
- Tests tagged `rom` run the ROM's own routines in an ARM emulator (Unicorn) and compare them with the Elixir code across all 6 encounter types. Set up the Python environment once:

  ```bash
  python3 -m venv .venv
  .venv/bin/pip install -r test/support/rom/requirements.txt
  ```

How the tests were designed is described in [ARCHITECTURE.md](ARCHITECTURE.md#verification).

## Limitations

- Advances are counted from the start of the encounter; the per-step encounter check (`0x8082BCC`) is not modelled.
- Unown (Tanoby Ruins) uses a different creation routine and is not supported. Legendaries, starters and gift Pokémon are not either.
- FireRed (USA) v1.0 only. LeafGreen, Ruby, Sapphire, Emerald and other regions use other addresses.
- The app does not help you hit a seed and advance in game; it tells you which combinations produce the Pokémon you want.

## Project layout

```
lib/shiny_hunter/
  rng.ex           the game's LCG and an O(log n) jump of N steps
  wild.ex          wild Pokémon generation: slot, level, nature, PID, IVs, shiny
  search.ex        seed-block search and filters
  hunt.ex          GenServer that runs the hunt, recovers workers and broadcasts progress
  rom.ex           validated reading of encounter tables and names from the ROM
  encounters.ex    loaded tables and the encounter type → slot area → table mapping
lib/shiny_hunter_web/live/hunt_live.ex   the LiveView page
test/support/reference/firered_wild.c    C reference built from the pseudocode
test/support/rom/emulate_wild.py         runs the ROM's code in an ARM emulator
```

## Legal notice

Non-commercial fan project, not affiliated with Nintendo, Game Freak, Creatures or The Pokémon Company. Pokémon and FireRed are trademarks of their respective owners.

The code reimplements formulas and reads data from the user's own ROM at runtime. It does not include or distribute any game code, images, text or ROMs.
