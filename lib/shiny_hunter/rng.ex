defmodule ShinyHunter.Rng do
  @moduledoc """
  The Gen 3 linear congruential generator, as Pokémon FireRed (USA) v1.0
  implements it at `0x8044EC8`:

      seed = seed * 0x41C64E6D + 0x6073   (mod 2^32)
      return seed >>> 16

  The multiplication is split into 16-bit halves so every intermediate value
  stays a BEAM small integer; a full 32x32-bit product would become a bignum.
  """

  import Bitwise

  @mult 0x41C64E6D
  @inc 0x6073
  @mask 0xFFFFFFFF

  @doc "Advances the seed by one step."
  @spec next(non_neg_integer()) :: non_neg_integer()
  def next(seed), do: mul_add(seed, @mult, @inc)

  @doc "The value `Random()` returns for the seed it just produced."
  @spec value(non_neg_integer()) :: non_neg_integer()
  def value(seed), do: seed >>> 16

  @doc "Advances the seed `n` steps in O(log n)."
  @spec jump(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def jump(seed, n), do: jump(seed, n, jump_table())

  defp jump(seed, 0, _table), do: seed

  defp jump(seed, n, [{a, c} | rest]) do
    seed = if (n &&& 1) == 1, do: mul_add(seed, a, c), else: seed
    jump(seed, n >>> 1, rest)
  end

  # {multiplier, increment} that advance the seed 2^i steps, for i in 0..31.
  defp jump_table do
    :persistent_term.get({__MODULE__, :jump_table}, nil) ||
      (
        table =
          Enum.scan(1..31, {@mult, @inc}, fn _, {a, c} -> {mul(a, a), mul_add(c, a, c)} end)

        table = [{@mult, @inc} | table]
        :persistent_term.put({__MODULE__, :jump_table}, table)
        table
      )
  end

  @compile {:inline, mul_add: 3, mul: 2}

  # (x * a + c) mod 2^32 with small-integer intermediates.
  defp mul_add(x, a, c), do: mul(x, a) + c &&& @mask

  defp mul(x, a) do
    lo = (x &&& 0xFFFF) * a
    hi = (x >>> 16) * (a &&& 0xFFFF) &&& 0xFFFF
    lo + (hi <<< 16) &&& @mask
  end
end
