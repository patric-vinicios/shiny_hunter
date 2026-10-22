defmodule ShinyHunter.RomTest do
  @moduledoc """
  Checks `Wild` against FireRed's own code, run under an ARM emulator.

  Needs the ROM (FireRed USA v1.0) at `FIRERED_ROM` and the project venv with
  Unicorn (`python3 -m venv .venv && .venv/bin/pip install unicorn`).
  Excluded by default; run with `mix test --include rom`.
  """
  use ExUnit.Case, async: true

  alias ShinyHunter.Wild

  @moduletag :rom
  @rom_sha1 "41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc"
  @python Path.expand("../../.venv/bin/python", __DIR__)
  @script Path.expand("../support/rom/emulate_wild.py", __DIR__)

  setup_all do
    rom = System.get_env("FIRERED_ROM") || flunk("set FIRERED_ROM to the FireRed (USA) v1.0 ROM")
    sha1 = :crypto.hash(:sha, File.read!(rom)) |> Base.encode16(case: :lower)
    assert sha1 == @rom_sha1, "ROM is not FireRed (USA) v1.0"
    assert File.exists?(@python), "missing #{@python}; see the module doc"
    %{rom_path: rom}
  end

  @table_species 100

  # Encounter kinds as the emulator takes them, and the area each one uses.
  @encounters [land: 0, water: 1, water: 2, old_rod: 10, good_rod: 11, super_rod: 12]

  test "the game's own code creates the same wild Pokémon as Wild.generate/2", %{rom_path: rom} do
    fixed =
      for {area, code} <- @encounters,
          state <- [0, 0xFFFFFFFF, 0x12345678],
          do: {state, 12_345, 54_321, area, code}

    random =
      for _ <- 1..6000 do
        {area, code} = Enum.random(@encounters)

        {:rand.uniform(0x100000000) - 1, :rand.uniform(0x10000) - 1, :rand.uniform(0x10000) - 1,
         area, code}
      end

    cases = fixed ++ random
    results = emulate(rom, cases)
    assert length(results) == length(cases)

    for {{state, tid, sid, area, code}, line} <- Enum.zip(cases, results) do
      [slot, species, level, pid, ot_id, hp, atk, def, spe, spa, spd, state_after] = line

      {our_slot, level_roll, our_pid, iv1, iv2, our_state_after} =
        Wild.generate_with_state(state, area)

      where = "state #{state}, encounter #{code}"

      assert slot == our_slot, "slot differs for #{where}"
      assert species == @table_species + slot
      {min, max} = table_levels(slot)
      assert level == Wild.level(level_roll, min, max), "level differs for #{where}"

      assert {pid, ot_id} == {our_pid, Bitwise.bor(tid, Bitwise.bsl(sid, 16))},
             "PID differs for #{where}"

      assert {hp, atk, def, spe, spa, spd} == Wild.ivs(iv1, iv2), "IVs differ for #{where}"
      assert state_after == our_state_after, "RNG consumption differs for #{where}"
      assert Wild.shiny?(pid, tid, sid) == shiny_by_game_formula?(pid, ot_id)
    end

    # Every slot each area can produce came up at least once.
    seen =
      Enum.zip(cases, results)
      |> Enum.group_by(fn {{_, _, _, area, _}, _} -> area end, fn {_, [slot | _]} -> slot end)

    for area <- Wild.areas(),
        do: assert(MapSet.new(seen[area]) == MapSet.new(Wild.slots(area)), "#{area}")
  end

  # The synthetic table emulate_wild.py builds: slot i is species 100 + i.
  defp table_levels(i), do: {i + 2, i + 2 + rem(i, 4) * 3}

  # The comparison CreateBoxMon makes at 0x803DAC4, masks as read from the ROM.
  defp shiny_by_game_formula?(pid, ot_id) do
    import Bitwise

    bxor(
      bxor((ot_id &&& 0xFFFF0000) >>> 16, ot_id &&& 0xFFFF),
      bxor((pid &&& 0xFFFF0000) >>> 16, pid &&& 0xFFFF)
    ) <
      8
  end

  defp emulate(rom, cases) do
    input = Enum.map_join(cases, "", fn {s, t, i, _area, code} -> "#{s} #{t} #{i} #{code}\n" end)
    file = Path.join(System.tmp_dir!(), "rom_cases_#{System.unique_integer([:positive])}")
    File.write!(file, input)

    try do
      {out, 0} =
        System.cmd("sh", ["-c", ~s("$0" -I "$1" "$2" < "$3"), @python, @script, rom, file])

      out
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split() |> Enum.map(&String.to_integer/1) end)
    after
      File.rm(file)
    end
  end
end
