defmodule ShinyHunter.HuntTest do
  use ExUnit.Case, async: false

  alias ShinyHunter.{Hunt, Search}
  alias ShinyHunter.Search.Params

  @params %Params{tid: 12_345, sid: 54_321, seeds: 0..255, advances: 0..2999, chunk_size: 16}

  setup do
    Phoenix.PubSub.subscribe(ShinyHunter.PubSub, Hunt.topic())
    on_exit(fn -> Hunt.cancel() end)
  end

  test "killed workers are redone and the hunt finds exactly what a plain search finds" do
    {expected, _} = Search.run(@params)

    :ok = Hunt.start(@params, 2)
    assert {:ok, _} = Hunt.kill_worker()
    assert {:ok, _} = Hunt.kill_worker()

    stats = await_status(:done)
    {_, matches} = Hunt.snapshot()

    assert stats.crashes == 2
    assert stats.done == stats.total
    assert stats.match_count == length(expected)
    assert Enum.sort(matches) == expected
  end

  test "cancel stops the hunt and its workers" do
    :ok = Hunt.start(%{@params | advances: 0..199_999}, 2)
    {stats, _} = Hunt.snapshot()
    pids = stats.workers

    :ok = Hunt.cancel()
    assert {%{status: :cancelled, workers: []}, _} = Hunt.snapshot()
    assert length(pids) == 2
  end

  defp await_status(status) do
    receive do
      {:tick, %{status: ^status} = stats} -> stats
      _ -> await_status(status)
    after
      30_000 -> flunk("hunt did not reach #{status}")
    end
  end
end
