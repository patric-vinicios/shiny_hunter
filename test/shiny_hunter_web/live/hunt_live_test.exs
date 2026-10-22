defmodule ShinyHunterWeb.HuntLiveTest do
  use ShinyHunterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    on_exit(fn -> ShinyHunter.Hunt.cancel() end)
  end

  test "a small hunt streams its shinies into the table", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    Phoenix.PubSub.subscribe(ShinyHunter.PubSub, ShinyHunter.Hunt.topic())

    view
    |> form("#hunt-form",
      hunt: %{seed_from: "0", seed_to: "255", adv_from: "0", adv_to: "1999", workers: "4"}
    )
    |> render_submit()

    assert_receive {:tick, %{status: :done, match_count: count}}, 30_000
    assert count > 0
    # The LiveView received the same broadcasts before the test process did.
    assert has_element?(view, "#hunt-status", "done")
    assert has_element?(view, "#matches tr")
  end

  test "invalid input is reported, not started", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    before = ShinyHunter.Hunt.snapshot()

    html = view |> form("#hunt-form", hunt: %{seed_to: "70000"}) |> render_submit()

    assert html =~ "seed_to out of range"
    assert ShinyHunter.Hunt.snapshot() == before
  end

  test "the slot list follows the encounter kind and rejects slots outside it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> form("#hunt-form", hunt: %{kind: "super_rod"}) |> render_change()
    assert html =~ "Slot 9"
    refute html =~ "Slot 0<"

    before = ShinyHunter.Hunt.snapshot()

    # The old rod only has slots 0 and 1; slot 7 is sent past the select.
    html =
      view
      |> form("#hunt-form", hunt: %{kind: "old_rod"})
      |> render_submit(%{hunt: %{slot: "7"}})

    assert html =~ "slot outside the area"
    assert ShinyHunter.Hunt.snapshot() == before
  end

  @tag :rom
  test "with the ROM, a hunt on a map shows the chosen species and its levels", %{conn: conn} do
    route1 =
      Enum.find(ShinyHunter.Encounters.list(), &(&1.map_name == "ROUTE 1")) ||
        flunk("ROM not loaded")

    pidgey = Enum.find(ShinyHunter.Encounters.species(route1, :land), &(&1.name == "PIDGEY"))

    {:ok, view, _html} = live(conn, ~p"/")
    Phoenix.PubSub.subscribe(ShinyHunter.PubSub, ShinyHunter.Hunt.topic())

    view |> form("#hunt-form", hunt: %{encounter: to_string(route1.index)}) |> render_change()

    view
    |> form("#hunt-form",
      hunt: %{
        encounter: to_string(route1.index),
        kind: "land",
        species: to_string(pidgey.species),
        shiny_only: "false",
        seed_from: "0",
        seed_to: "3",
        adv_from: "0",
        adv_to: "49",
        workers: "2"
      }
    )
    |> render_submit()

    assert_receive {:tick, %{status: :done, match_count: count}}, 30_000
    assert count > 0

    rows = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#matches tr")

    cells =
      Enum.map(rows, fn row -> row |> LazyHTML.query("td") |> Enum.map(&LazyHTML.text/1) end)

    for [_seed, _slot, species, level | _] <- cells do
      assert String.trim(species) == "PIDGEY"
      assert String.to_integer(String.trim(level)) in 2..5
    end

    assert length(cells) == count
  end
end
