defmodule ShinyHunter.WildTest do
  use ExUnit.Case, async: true

  alias ShinyHunter.{Rng, Wild}

  @reference Path.expand("../support/reference/firered_wild.c", __DIR__)

  describe "Rng" do
    test "matches the LCG step and the value Random() returns" do
      assert Rng.next(0) == 0x6073
      assert Rng.next(0xFFFFFFFF) == Bitwise.band(0xFFFFFFFF * 0x41C64E6D + 0x6073, 0xFFFFFFFF)
      assert Rng.value(0x12345678) == 0x1234
    end

    test "jump/2 equals stepping one at a time" do
      for seed <- [0, 1, 0xBEEF, 0xFFFFFFFF], n <- [0, 1, 2, 7, 1000, 65_537] do
        assert Rng.jump(seed, n) == Enum.reduce(1..n//1, seed, fn _, s -> Rng.next(s) end)
      end
    end
  end

  describe "Wild.generate/2 against the C reference built from the REA pseudocode" do
    @describetag :reference

    setup do
      gcc = System.find_executable("gcc") || flunk("gcc is required for the reference test")
      bin = Path.join(System.tmp_dir!(), "firered_wild_#{System.unique_integer([:positive])}")
      {_, 0} = System.cmd(gcc, ["-O2", "-o", bin, @reference], stderr_to_stdout: true)
      on_exit(fn -> File.rm(bin) end)
      %{bin: bin}
    end

    test "agrees on 5000 seed/advance pairs", %{bin: bin} do
      cases =
        for _ <- 1..5000 do
          {:rand.uniform(0x10000) - 1, :rand.uniform(3000) - 1}
        end ++ [{0, 0}, {0xFFFF, 0}, {0, 2999}]

      input = Enum.map_join(cases, "", fn {s, a} -> "#{s} #{a}\n" end)
      file = bin <> ".in"
      File.write!(file, input)
      on_exit(fn -> File.rm(file) end)

      {out, 0} = System.shell("#{bin} < #{file}")

      expected =
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          line |> String.split() |> Enum.map(&String.to_integer/1) |> List.to_tuple()
        end)

      actual = Enum.map(cases, fn {s, a} -> Wild.generate(Rng.jump(s, a), :land) end)

      assert length(expected) == length(cases)
      assert actual == expected
    end
  end

  test "shiny?/3 uses TID ^ SID ^ PID halves < 8" do
    assert Wild.shiny?(0x0000_0000, 0, 0)
    assert Wild.shiny?(0x1234_1234, 7, 0)
    refute Wild.shiny?(0x1234_1234, 8, 0)
    # tid ^ sid ^ hi ^ lo = 0x5A5A ^ 0xA5A5 ^ 0xFFFF ^ 0x0007 = 7
    assert Wild.shiny?(0xFFFF_0007, 0x5A5A, 0xA5A5)
  end
end
