defmodule ShinyHunter.Wild do
  @moduledoc """
  Generates a wild Pokémon from an RNG state the way FireRed (USA) v1.0 does,
  following the routines REA decompiled from the ROM, in the order the game
  draws from `Random()`:

    1. Slot: `Random() % 100` against the area's thresholds
       (`0x808274C` land, `0x8082808` water and Rock Smash, `0x808285C` fishing).
    2. Level: `min + Random() % (max - min + 1)` (`0x80828F8`). The level range
       belongs to the map's encounter table, so the raw draw is returned.
    3. Nature: `Random() % 25` (`0x80829FC`).
    4. PID: `lo | hi << 16`, low half first, redrawn until `PID % 25` equals
       that nature (`0x803DD98`).
    5. IVs: two words, five bits per stat, HP/Atk/Def then Spe/SpA/SpD
       (`0x803DAC4`, CreateBoxMon).

  Shiny: `TID ^ SID ^ PID_high ^ PID_low < 8`.

  The state passed in is the one right before the slot draw. Unown (species
  0xC9) takes a different creation path in the game and is not modelled.
  """

  import Bitwise
  alias ShinyHunter.Rng

  @natures ~w(Hardy Lonely Brave Adamant Naughty Bold Docile Relaxed Impish Lax
              Timid Hasty Serious Jolly Naive Modest Mild Quiet Bashful Rash
              Calm Gentle Sassy Careful Quirky)

  # Upper bounds (exclusive) of `Random() % 100` for consecutive slots, and the
  # first slot index, as the decompiled choosers compare them.
  @areas %{
    land: {0, [20, 40, 50, 60, 70, 80, 85, 90, 94, 98, 99, 100]},
    water: {0, [60, 90, 95, 99, 100]},
    old_rod: {0, [70, 100]},
    good_rod: {2, [60, 80, 100]},
    super_rod: {5, [40, 80, 95, 99, 100]}
  }

  @type area :: :land | :water | :old_rod | :good_rod | :super_rod
  @type mon ::
          {slot :: 0..11, level_roll :: 0..0xFFFF, pid :: non_neg_integer(),
           iv1 :: non_neg_integer(), iv2 :: non_neg_integer()}

  def natures, do: @natures

  def nature_name(index), do: Enum.at(@natures, index)

  def areas, do: [:land, :water, :old_rod, :good_rod, :super_rod]

  @doc "The table slots an area can produce."
  def slots(area) do
    {first, bounds} = Map.fetch!(@areas, area)
    first..(first + length(bounds) - 1)
  end

  @doc "Percent chance of each slot an area can produce."
  def slot_chances(area) do
    {first, bounds} = Map.fetch!(@areas, area)

    [0 | bounds]
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index(first)
    |> Map.new(fn {[low, high], slot} -> {slot, high - low} end)
  end

  @doc """
  Returns `{slot, level_roll, pid, iv1, iv2}` for the RNG state; the nature is
  `rem(pid, 25)`. Kept as a bare tuple because the search calls it billions of
  times.
  """
  @spec generate(non_neg_integer(), area()) :: mon()
  def generate(seed, area) do
    {slot, level_roll, pid, iv1, iv2, _seed} = generate_with_state(seed, area)
    {slot, level_roll, pid, iv1, iv2}
  end

  @doc "Like `generate/2`, plus the RNG state left after the last draw."
  def generate_with_state(seed, area) do
    seed = Rng.next(seed)
    slot = slot(area, rem(Rng.value(seed), 100))
    seed = Rng.next(seed)
    level_roll = Rng.value(seed)
    seed = Rng.next(seed)
    nature = rem(Rng.value(seed), 25)
    {seed, pid} = draw_pid(seed, nature)
    seed = Rng.next(seed)
    iv1 = Rng.value(seed)
    seed = Rng.next(seed)
    {slot, level_roll, pid, iv1, Rng.value(seed), seed}
  end

  for {area, {first, bounds}} <- @areas do
    defp slot(unquote(area), roll), do: unquote(first) + count_below(roll, unquote(bounds))
  end

  defp count_below(roll, [bound | rest]) when roll >= bound, do: 1 + count_below(roll, rest)
  defp count_below(_roll, _bounds), do: 0

  defp draw_pid(seed, nature) do
    seed = Rng.next(seed)
    lo = Rng.value(seed)
    seed = Rng.next(seed)
    pid = lo ||| Rng.value(seed) <<< 16

    if rem(pid, 25) == nature, do: {seed, pid}, else: draw_pid(seed, nature)
  end

  @doc "The level a table entry from `min` to `max` gets for a level roll."
  def level(level_roll, min, max) do
    {low, high} = if max < min, do: {max, min}, else: {min, max}
    low + rem(level_roll, high - low + 1)
  end

  @compile {:inline, shiny?: 3}

  @spec shiny?(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: boolean()
  def shiny?(pid, tid, sid), do: bxor(bxor(tid, sid), bxor(pid >>> 16, pid &&& 0xFFFF)) < 8

  @doc "IVs in game order: HP, Atk, Def, Spe, SpA, SpD."
  def ivs(iv1, iv2) do
    {iv1 &&& 31, iv1 >>> 5 &&& 31, iv1 >>> 10 &&& 31, iv2 &&& 31, iv2 >>> 5 &&& 31,
     iv2 >>> 10 &&& 31}
  end

  @doc "A displayable description of one generated Pokémon."
  def describe({slot, level_roll, pid, iv1, iv2}, tid, sid) do
    {hp, atk, def, spe, spa, spd} = ivs(iv1, iv2)

    %{
      slot: slot,
      level_roll: level_roll,
      pid: pid,
      nature: nature_name(rem(pid, 25)),
      shiny: shiny?(pid, tid, sid),
      ivs: %{hp: hp, atk: atk, def: def, spa: spa, spd: spd, spe: spe}
    }
  end
end
