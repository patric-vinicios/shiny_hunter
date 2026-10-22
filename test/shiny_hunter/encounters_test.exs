defmodule ShinyHunter.EncountersTest do
  use ExUnit.Case, async: true

  alias ShinyHunter.{Encounters, Rom}

  defp entries(species_by_slot) do
    for {species, slot} <- Enum.with_index(species_by_slot),
        do: %{slot: slot, min: slot + 1, max: slot + 2, species: species, name: "S#{species}"}
  end

  defp encounter do
    %Rom.Encounter{
      index: 0,
      group: 1,
      num: 2,
      map_name: "TEST",
      tables: %{
        land: entries([10, 20, 10, 20, 0xC9, 30, 10, 10, 10, 10, 10, 10]),
        fishing: entries([40, 40, 41, 42, 42, 43, 43, 43, 43, 44])
      }
    }
  end

  test "kinds follow the tables an encounter has" do
    assert Encounters.kinds_for(encounter()) == [:land, :old_rod, :good_rod, :super_rod]
    assert Encounters.kinds_for(nil) == Encounters.kinds()
  end

  test "species group their slots, sum their chances and leave Unown out" do
    land = Encounters.species(encounter(), :land)

    assert Enum.map(land, &{&1.species, &1.slots, &1.chance}) == [
             {10, [0, 2, 6, 7, 8, 9, 10, 11], 50},
             {20, [1, 3], 30},
             {30, [5], 10}
           ]

    refute Enum.any?(land, &(&1.species == 0xC9))
    assert hd(land).min == 1 and hd(land).max == 13
  end

  test "each rod reads its own share of the fishing table" do
    assert [%{species: 40, slots: [0, 1], chance: 100}] =
             Encounters.species(encounter(), :old_rod)

    assert Enum.map(Encounters.species(encounter(), :good_rod), & &1.slots) == [[2], [3, 4]]

    assert Enum.map(Encounters.species(encounter(), :super_rod), & &1.slots) == [
             [5, 6, 7, 8],
             [9]
           ]
  end

  test "a ROM other than FireRed (USA) v1.0 is refused" do
    assert Rom.parse(:crypto.strong_rand_bytes(1024)) == {:error, :unsupported_rom}
  end
end
