defmodule ShinyHunter.SearchTest do
  use ExUnit.Case, async: true

  alias ShinyHunter.{Rng, Search, Wild}
  alias ShinyHunter.Search.Params

  test "parallel and sequential runs find the same matches" do
    p = %Params{tid: 12_345, sid: 54_321, seeds: 0..255, advances: 0..499, chunk_size: 16}

    {parallel, _} = Search.run(p)
    {sequential, _} = Search.run(p, max_concurrency: 1)

    assert parallel == sequential
  end

  test "every match passes the filter and reproduces from its seed and advance" do
    p = %Params{
      tid: 1,
      sid: 2,
      seeds: 0..127,
      advances: 0..999,
      area: :super_rod,
      slot_mask: Bitwise.bsl(1, 7),
      shiny_only: false,
      nature_mask: Bitwise.bsl(1, 3),
      min_ivs: {20, 20, 0, 0, 0, 0}
    }

    {matches, _} = Search.run(p)
    assert matches != []

    for {seed, advance, {slot, _level_roll, pid, iv1, iv2} = mon} <- matches do
      assert Wild.generate(Rng.jump(seed, advance), :super_rod) == mon
      assert slot == 7
      assert Wild.nature_name(rem(pid, 25)) == "Adamant"
      {hp, atk, _, _, _, _} = Wild.ivs(iv1, iv2)
      assert hp >= 20 and atk >= 20
    end
  end

  test "chunks cover the seed range exactly once" do
    p = %Params{seeds: 10..105, chunk_size: 32}
    covered = Enum.flat_map(Search.chunks(p), fn {a, b} -> Enum.to_list(a..b) end)
    assert covered == Enum.to_list(10..105)
  end
end
