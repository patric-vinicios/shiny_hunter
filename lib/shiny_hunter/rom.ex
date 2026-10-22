defmodule ShinyHunter.Rom do
  @moduledoc """
  Reads the wild encounter tables, map names and species names out of a
  Pokémon FireRed (USA) v1.0 ROM. Every address and layout below was found
  with REA in that ROM; other versions place them elsewhere, so the ROM's
  SHA-1 is checked first.

    * Encounter headers at `0x83C9CB8` (read by `0x8082934`): 20-byte records
      `{map group, map number, pad, land, water, rock smash, fishing}`, the
      last four pointing at `{rate, pad, pointer to entries}`; a map group of
      `0xFF` ends the list.
    * Entries `{min level, max level, species}` (read by `0x80828F8` and
      `0x8082AEC`): 12 for land, 5 for water and Rock Smash, 10 for fishing.
    * Map headers via the map group table at `0x83526A8` (`0x8055238`); byte
      `0x14` is the region map section (`0x8056260`).
    * Map names: 109 pointers at `0x83F1CAC`, indexed by section - `0x58`
      (`0x80C4D78`).
    * Species names: 11 bytes each at `0x8245EE0`, species below `0x19D`
      (`0x8040FD0`).
  """

  @sha1 "41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc"
  @base 0x08000000

  @headers 0x083C9CB8
  @map_groups 0x083526A8
  @map_names 0x083F1CAC
  @map_name_count 109
  @first_named_section 0x58
  @species_names 0x08245EE0
  @species_count 0x19D

  @areas [land: {4, 12}, water: {8, 5}, rock_smash: {12, 5}, fishing: {16, 10}]
  @max_headers 1024

  defmodule Encounter do
    @moduledoc "One wild encounter header: a map and its tables by area."
    defstruct [:index, :group, :num, :map_name, :tables]
  end

  @doc "Reads the ROM at `path`."
  def load(path) do
    with {:ok, rom} <- File.read(path), do: parse(rom)
  end

  @doc """
  Parses a FireRed (USA) v1.0 ROM image. Returns `{:ok, encounters}` or
  `{:error, reason}`; a single unreadable value fails the whole parse.
  """
  def parse(rom) do
    if :crypto.hash(:sha, rom) |> Base.encode16(case: :lower) == @sha1 do
      parse_headers(rom, 0, [])
    else
      {:error, :unsupported_rom}
    end
  catch
    {:bad_rom, reason} -> {:error, {:bad_rom, reason}}
  end

  defp parse_headers(_rom, index, _acc) when index >= @max_headers,
    do: throw({:bad_rom, :encounter_headers_not_terminated})

  defp parse_headers(rom, index, acc) do
    at = @headers + index * 20

    case u8(rom, at) do
      0xFF ->
        {:ok, Enum.reverse(acc)}

      group ->
        num = u8(rom, at + 1)

        tables =
          for {area, {offset, count}} <- @areas,
              info = u32(rom, at + offset),
              info != 0,
              into: %{},
              do: {area, entries(rom, u32(rom, pointer!(rom, info) + 4), count)}

        encounter = %Encounter{
          index: index,
          group: group,
          num: num,
          map_name: map_name(rom, group, num),
          tables: tables
        }

        parse_headers(rom, index + 1, [encounter | acc])
    end
  end

  defp entries(rom, pointer, count) do
    pointer!(rom, pointer)

    for slot <- 0..(count - 1) do
      at = pointer + slot * 4
      species = u16(rom, at + 2)
      if species == 0 or species >= @species_count, do: throw({:bad_rom, {:species, species}})

      %{
        slot: slot,
        min: u8(rom, at),
        max: u8(rom, at + 1),
        species: species,
        name: species_name(rom, species)
      }
    end
  end

  defp map_name(rom, group, num) do
    group_table = u32(rom, pointer!(rom, @map_groups) + group * 4)
    header = u32(rom, pointer!(rom, group_table) + num * 4)
    section = u8(rom, pointer!(rom, header) + 0x14)
    index = section - @first_named_section

    if index in 0..(@map_name_count - 1) do
      rom |> u32(@map_names + index * 4) |> then(&text(rom, pointer!(rom, &1), 32))
    else
      # 0x80C4D78 writes a blank name for these sections.
      nil
    end
  end

  defp species_name(rom, species), do: text(rom, @species_names + species * 11, 10)

  # Gen 3 text: 0xFF ends the string. Only the characters species and map
  # names use are mapped; anything else is kept visible as "?".
  defp text(rom, address, max) do
    rom
    |> binary_part(address - @base, max)
    |> :binary.bin_to_list()
    |> Enum.take_while(&(&1 != 0xFF))
    |> Enum.map(&char/1)
    |> IO.iodata_to_binary()
  end

  defp char(0x00), do: " "
  defp char(b) when b in 0xA1..0xAA, do: <<?0 + b - 0xA1>>
  defp char(0xAB), do: "!"
  defp char(0xAC), do: "?"
  defp char(0xAD), do: "."
  defp char(0xAE), do: "-"
  defp char(0xB4), do: "'"
  defp char(0xB5), do: "♂"
  defp char(0xB6), do: "♀"
  defp char(b) when b in 0xBB..0xD4, do: <<?A + b - 0xBB>>
  defp char(b) when b in 0xD5..0xEE, do: <<?a + b - 0xD5>>
  defp char(0x1B), do: "é"
  defp char(_), do: "?"

  defp pointer!(rom, address) do
    if address >= @base and address - @base < byte_size(rom),
      do: address,
      else: throw({:bad_rom, {:pointer, address}})
  end

  defp u8(rom, address), do: :binary.at(rom, offset!(rom, address, 1))

  defp u16(rom, address) do
    <<value::little-16>> = binary_part(rom, offset!(rom, address, 2), 2)
    value
  end

  defp u32(rom, address) do
    <<value::little-32>> = binary_part(rom, offset!(rom, address, 4), 4)
    value
  end

  defp offset!(rom, address, size) do
    offset = address - @base

    if offset >= 0 and offset + size <= byte_size(rom),
      do: offset,
      else: throw({:bad_rom, {:read, address}})
  end
end
