defmodule ShinyHunter.Encounters do
  @moduledoc """
  The encounter tables read from the ROM at `:rom_path` when the app starts,
  and the mapping from an encounter kind to the slot area `Wild` draws with
  and the table it reads.

  Without a configured or readable ROM the hunt still works by slot number;
  `status/0` says why tables are missing.
  """

  require Logger
  alias ShinyHunter.{Rom, Wild}

  @unown 0xC9

  @kinds [
    land: {"Grass / cave", :land, :land},
    water: {"Surf", :water, :water},
    rock_smash: {"Rock Smash", :water, :rock_smash},
    old_rod: {"Old Rod", :old_rod, :fishing},
    good_rod: {"Good Rod", :good_rod, :fishing},
    super_rod: {"Super Rod", :super_rod, :fishing}
  ]

  @doc "Loads the tables once; called from the application start."
  def load do
    status =
      case Application.get_env(:shiny_hunter, :rom_path) do
        nil ->
          :not_configured

        path ->
          case Rom.load(path) do
            {:ok, encounters} ->
              {:ok, label(encounters)}

            {:error, reason} = error ->
              Logger.warning("Encounter tables unavailable from #{path}: #{inspect(reason)}")
              error
          end
      end

    :persistent_term.put(__MODULE__, status)
    status
  end

  @doc "`{:ok, encounters}`, `{:error, reason}` or `:not_configured`."
  def status, do: :persistent_term.get(__MODULE__, :not_configured)

  def list do
    case status() do
      {:ok, encounters} -> encounters
      _ -> []
    end
  end

  def get(index), do: Enum.find(list(), &(&1.index == index))

  def kinds, do: Keyword.keys(@kinds)

  def kind_label(kind), do: kind |> spec() |> elem(0)

  @doc "The slot area `Wild` draws with for an encounter kind."
  def wild_area(kind), do: kind |> spec() |> elem(1)

  @doc "The kinds an encounter's tables allow, or every kind without one."
  def kinds_for(nil), do: kinds()

  def kinds_for(encounter) do
    Enum.filter(kinds(), &Map.has_key?(encounter.tables, table_key(&1)))
  end

  @doc "The table entry the game uses for a slot, or nil without tables."
  def entry(nil, _kind, _slot), do: nil

  def entry(encounter, kind, slot),
    do: encounter.tables |> Map.get(table_key(kind), []) |> Enum.at(slot)

  @doc """
  The species a kind can produce on an encounter, each with its slots, its
  chance and its level range. Unown is left out: the game creates it through
  a routine `Wild` does not model.
  """
  def species(encounter, kind) do
    chances = Wild.slot_chances(wild_area(kind))

    for slot <- Wild.slots(wild_area(kind)),
        entry = entry(encounter, kind, slot),
        entry.species != @unown do
      entry
    end
    |> Enum.group_by(& &1.species)
    |> Enum.map(fn {species, entries} ->
      %{
        species: species,
        name: hd(entries).name,
        slots: Enum.map(entries, & &1.slot),
        chance: entries |> Enum.map(&chances[&1.slot]) |> Enum.sum(),
        min: entries |> Enum.map(&min(&1.min, &1.max)) |> Enum.min(),
        max: entries |> Enum.map(&max(&1.min, &1.max)) |> Enum.max()
      }
    end)
    |> Enum.sort_by(&{-&1.chance, &1.name})
  end

  def unown?(entry), do: entry.species == @unown

  defp table_key(kind), do: kind |> spec() |> elem(2)

  defp spec(kind), do: Keyword.fetch!(@kinds, kind)

  # Several maps share a section name (Mt. Moon's floors) and one map has
  # several headers (Altering Cave's Mystery Gift variants).
  defp label(encounters) do
    floors =
      encounters
      |> Enum.uniq_by(&{&1.group, &1.num})
      |> Enum.group_by(& &1.map_name, &{&1.group, &1.num})

    variants = Enum.group_by(encounters, &{&1.group, &1.num}, & &1.index)

    Enum.map(encounters, fn e ->
      name = e.map_name || "Map #{e.group}.#{e.num}"
      maps = floors[e.map_name] || []
      headers = variants[{e.group, e.num}]

      label =
        cond do
          length(headers) > 1 ->
            "#{name} · variant #{Enum.find_index(headers, &(&1 == e.index))}"

          length(maps) > 1 ->
            "#{name} · #{Enum.find_index(maps, &(&1 == {e.group, e.num})) + 1}"

          true ->
            name
        end

      Map.put(e, :label, label)
    end)
  end
end
