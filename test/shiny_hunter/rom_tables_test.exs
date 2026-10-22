defmodule ShinyHunter.RomTablesTest do
  @moduledoc """
  Encounter tables read from the real ROM, checked against places whose
  encounters are well known. Needs `FIRERED_ROM`; run with
  `mix test --include rom`.
  """
  use ExUnit.Case, async: true

  alias ShinyHunter.{Encounters, Rom}

  @moduletag :rom

  setup_all do
    path = System.get_env("FIRERED_ROM") || flunk("set FIRERED_ROM")
    {:ok, encounters} = Rom.load(path)
    %{encounters: encounters}
  end

  defp find(encounters, name), do: Enum.filter(encounters, &(&1.map_name == name))

  test "every header has a map name and the list ends where the game stops", %{
    encounters: encounters
  } do
    assert length(encounters) == 132
    assert Enum.all?(encounters, &is_binary(&1.map_name))
    assert Enum.map(encounters, & &1.index) == Enum.to_list(0..131)
  end

  test "Route 1 is Pidgey and Rattata, half each", %{encounters: encounters} do
    [route1] = find(encounters, "ROUTE 1")

    assert [
             %{name: "PIDGEY", chance: 50, min: 2, max: 5},
             %{name: "RATTATA", chance: 50, min: 2, max: 4}
           ] =
             Encounters.species(route1, :land)
  end

  test "Pikachu is a 5% encounter in Viridian Forest", %{encounters: encounters} do
    [forest] = find(encounters, "VIRIDIAN FOREST")
    assert %{chance: 5} = Enum.find(Encounters.species(forest, :land), &(&1.name == "PIKACHU"))
  end

  test "Altering Cave has nine headers and the Tanoby chambers only Unown", %{
    encounters: encounters
  } do
    assert length(find(encounters, "ALTERING CAVE")) == 9
    assert [%{name: "ZUBAT"}] = Encounters.species(hd(find(encounters, "ALTERING CAVE")), :land)

    for chamber <- Enum.filter(encounters, &String.ends_with?(&1.map_name, "CHAMBER")) do
      assert Enum.all?(chamber.tables.land, &Encounters.unown?/1)
      assert Encounters.species(chamber, :land) == []
    end
  end

  test "names decode without unknown characters", %{encounters: encounters} do
    names =
      Enum.flat_map(encounters, fn e ->
        [e.map_name | e.tables |> Map.values() |> List.flatten() |> Enum.map(& &1.name)]
      end)

    refute Enum.any?(names, &String.contains?(&1, "?"))
    assert "POKéMON TOWER" in names
    assert "NIDORAN♂" in names
  end
end
