defmodule ShinyHunterWeb.HuntLive do
  use ShinyHunterWeb, :live_view

  import Bitwise
  alias ShinyHunter.{Encounters, Hunt, Wild}
  alias ShinyHunter.Search.Params

  @defaults %{
    "tid" => "12345",
    "sid" => "54321",
    "seed_from" => "0",
    "seed_to" => "65535",
    "adv_from" => "0",
    "adv_to" => "9999",
    "encounter" => "",
    "kind" => "land",
    "species" => "",
    "slot" => "",
    "nature" => "",
    "shiny_only" => "true",
    "min_hp" => "0",
    "min_atk" => "0",
    "min_def" => "0",
    "min_spa" => "0",
    "min_spd" => "0",
    "min_spe" => "0"
  }

  @iv_fields ~w(min_hp min_atk min_def min_spa min_spd min_spe)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ShinyHunter.PubSub, Hunt.topic())

    {stats, matches} = Hunt.snapshot()
    schedulers = System.schedulers_online()
    input = Map.put(@defaults, "workers", to_string(schedulers))

    socket =
      socket
      |> assign(
        schedulers: schedulers,
        stats: stats,
        iv_fields: @iv_fields,
        rom_status: Encounters.status(),
        encounter_options: [
          {"No map (slot only)", ""}
          | Enum.map(Encounters.list(), &{&1.label, to_string(&1.index)})
        ],
        nature_options: [{"Any", ""} | Enum.with_index(Wild.natures(), &{&1, to_string(&2)})]
      )
      |> assign_form(input)
      |> stream(:matches, Enum.map(matches, &row(&1, stats)))

    {:ok, socket}
  end

  # The form and the choices that depend on it: kinds follow the map, and
  # species (with a map) or slots (without one) follow the kind.
  defp assign_form(socket, input) do
    encounter = encounter(input["encounter"])
    kinds = Encounters.kinds_for(encounter)

    input =
      if kind(input["kind"]) in kinds,
        do: input,
        else: Map.put(input, "kind", to_string(hd(kinds)))

    kind = kind(input["kind"])

    assign(socket,
      form: to_form(input, as: :hunt),
      encounter: encounter,
      kind_options: Enum.map(kinds, &{Encounters.kind_label(&1), to_string(&1)}),
      species_options:
        if(encounter,
          do: [
            {"Any", ""} | Enum.map(Encounters.species(encounter, kind), &species_option/1)
          ],
          else: []
        ),
      slot_options: [
        {"Any", ""}
        | Enum.map(Wild.slots(Encounters.wild_area(kind)), &{"Slot #{&1}", to_string(&1)})
      ]
    )
  end

  defp species_option(s) do
    levels = if s.min == s.max, do: "Lv. #{s.min}", else: "Lv. #{s.min}–#{s.max}"
    {"#{s.name} (#{levels}, #{s.chance}%)", to_string(s.species)}
  end

  @impl true
  def handle_event("validate", %{"hunt" => input}, socket) do
    {:noreply, assign_form(socket, input)}
  end

  def handle_event("start", %{"hunt" => input}, socket) do
    case parse(input) do
      {:ok, params, workers, context} ->
        :ok = Hunt.start(params, workers, context)
        {:noreply, socket |> assign_form(input) |> clear_flash()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel", _, socket) do
    Hunt.cancel()
    {:noreply, socket}
  end

  def handle_event("kill", _, socket) do
    case Hunt.kill_worker() do
      {:ok, pid} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Worker #{inspect(pid)} killed. Its block went back to the queue."
         )}

      :none ->
        {:noreply, put_flash(socket, :error, "No worker running.")}
    end
  end

  @impl true
  def handle_info({:reset, stats}, socket) do
    {:noreply, socket |> assign(stats: stats) |> stream(:matches, [], reset: true)}
  end

  def handle_info({:tick, stats}, socket), do: {:noreply, assign(socket, stats: stats)}

  def handle_info({:matches, matches}, socket) do
    stats = socket.assigns.stats
    {:noreply, Enum.reduce(matches, socket, &stream_insert(&2, :matches, row(&1, stats)))}
  end

  defp row({seed, advance, mon}, stats) do
    described = Wild.describe(mon, stats.tid, stats.sid)
    context = stats.context

    entry =
      context[:encounter] &&
        Encounters.entry(Encounters.get(context.encounter), context.kind, described.slot)

    described
    |> Map.merge(%{id: "m-#{seed}-#{advance}", seed: seed, advance: advance})
    |> Map.put(:species, entry && entry.name)
    |> Map.put(:level, entry && Wild.level(described.level_roll, entry.min, entry.max))
  end

  defp parse(input) do
    with {:ok, tid} <- int(input, "tid", 0..0xFFFF),
         {:ok, sid} <- int(input, "sid", 0..0xFFFF),
         {:ok, seed_from} <- int(input, "seed_from", 0..0xFFFF),
         {:ok, seed_to} <- int(input, "seed_to", seed_from..0xFFFF//1),
         {:ok, adv_from} <- int(input, "adv_from", 0..10_000_000),
         {:ok, adv_to} <- int(input, "adv_to", adv_from..10_000_000//1),
         {:ok, workers} <- int(input, "workers", 1..1024),
         {:ok, ivs} <- ivs(input),
         {:ok, mask} <- nature_mask(input["nature"]),
         {:ok, encounter} <- parse_encounter(input["encounter"]),
         {:ok, kind} <- parse_kind(input["kind"], encounter),
         {:ok, slot_mask} <- slot_mask(input, encounter, kind) do
      params = %Params{
        tid: tid,
        sid: sid,
        seeds: seed_from..seed_to,
        advances: adv_from..adv_to,
        shiny_only: input["shiny_only"] == "true",
        nature_mask: mask,
        area: Encounters.wild_area(kind),
        slot_mask: slot_mask,
        min_ivs: ivs,
        chunk_size: 16
      }

      {:ok, params, workers, %{encounter: encounter && encounter.index, kind: kind}}
    end
  end

  defp int(input, key, range) do
    case Integer.parse(String.trim(input[key] || "")) do
      {n, ""} ->
        if n in range, do: {:ok, n}, else: {:error, "#{key} out of range #{inspect(range)}"}

      _ ->
        {:error, "#{key} must be an integer"}
    end
  end

  defp ivs(input) do
    Enum.reduce_while(@iv_fields, {:ok, []}, fn key, {:ok, acc} ->
      case int(input, key, 0..31) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      # IV order in the search: HP, Atk, Def, Spe, SpA, SpD
      {:ok, [spe, spd, spa, def, atk, hp]} -> {:ok, {hp, atk, def, spe, spa, spd}}
      error -> error
    end
  end

  defp encounter(value) do
    case parse_encounter(value) do
      {:ok, encounter} -> encounter
      _ -> nil
    end
  end

  defp parse_encounter(value) when value in ["", nil], do: {:ok, nil}

  defp parse_encounter(value) do
    with {n, ""} <- Integer.parse(value), %{} = encounter <- Encounters.get(n) do
      {:ok, encounter}
    else
      _ -> {:error, "invalid map"}
    end
  end

  defp kind(value), do: Enum.find(Encounters.kinds(), :land, &(Atom.to_string(&1) == value))

  defp parse_kind(value, encounter) do
    case Enum.find(Encounters.kinds_for(encounter), &(Atom.to_string(&1) == value)) do
      nil -> {:error, "invalid encounter type for this map"}
      kind -> {:ok, kind}
    end
  end

  # Without a map the caller picks a slot number; with one, a species, which
  # may occupy several slots. Unown slots are never searched.
  defp slot_mask(input, nil, kind) do
    case input["slot"] do
      value when value in ["", nil] ->
        {:ok, 0xFFF}

      value ->
        case Integer.parse(value) do
          {n, ""} ->
            if n in Wild.slots(Encounters.wild_area(kind)),
              do: {:ok, 1 <<< n},
              else: {:error, "slot outside the area"}

          _ ->
            {:error, "invalid slot"}
        end
    end
  end

  defp slot_mask(input, encounter, kind) do
    species = Encounters.species(encounter, kind)

    chosen =
      case input["species"] do
        value when value in ["", nil] -> species
        value -> Enum.filter(species, &(to_string(&1.species) == value))
      end

    case chosen do
      [] -> {:error, "no supported species in this encounter (Unown uses another routine)"}
      list -> {:ok, list |> Enum.flat_map(& &1.slots) |> Enum.reduce(0, &(&2 ||| 1 <<< &1))}
    end
  end

  defp nature_mask(""), do: {:ok, 0x1FFFFFF}
  defp nature_mask(nil), do: {:ok, 0x1FFFFFF}

  defp nature_mask(value) do
    case Integer.parse(value) do
      {n, ""} when n in 0..24 -> {:ok, 1 <<< n}
      _ -> {:error, "invalid nature"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-1">
        <h1 class="text-2xl font-bold">Pokémon FireRed shiny hunter</h1>
        <p class="text-sm opacity-70">
          RNG and wild Pokémon generation rebuilt from the ROM with REA.
          Each block of seeds runs as a BEAM process, in parallel on every core.
        </p>
      </section>

      <p :if={@rom_status == :not_configured} id="rom-status" class="text-xs opacity-70">
        No ROM configured: the search works by slot number. Set <code>FIRERED_ROM</code>
        to the path of a FireRed (USA) v1.0 ROM to pick map and species.
      </p>
      <p :if={match?({:error, _}, @rom_status)} id="rom-status" class="text-xs text-error">
        Could not read the encounter tables from the ROM: {inspect(elem(@rom_status, 1))}
      </p>

      <.form
        for={@form}
        id="hunt-form"
        phx-change="validate"
        phx-submit="start"
        class="card bg-base-200 p-4"
      >
        <div class="grid grid-cols-2 gap-x-4 sm:grid-cols-5">
          <.input field={@form[:tid]} label="TID" />
          <.input field={@form[:sid]} label="SID" />
          <.input
            :if={@encounter_options != [{"No map (slot only)", ""}]}
            field={@form[:encounter]}
            type="select"
            label="Map"
            options={@encounter_options}
          />
          <.input field={@form[:kind]} type="select" label="Encounter" options={@kind_options} />
          <.input
            :if={@encounter}
            field={@form[:species]}
            type="select"
            label="Species"
            options={@species_options}
          />
          <.input
            :if={!@encounter}
            field={@form[:slot]}
            type="select"
            label="Table slot"
            options={@slot_options}
          />
          <.input field={@form[:nature]} type="select" label="Nature" options={@nature_options} />
          <.input field={@form[:workers]} type="number" label={"Workers (cores: #{@schedulers})"} />
          <.input field={@form[:seed_from]} label="Initial seed from" />
          <.input field={@form[:seed_to]} label="to" />
          <.input field={@form[:adv_from]} label="Advance from" />
          <.input field={@form[:adv_to]} label="to" />
        </div>
        <div class="grid grid-cols-3 gap-x-4 sm:grid-cols-6">
          <.input
            :for={{key, label} <- Enum.zip(@iv_fields, ~w(HP Atk Def SpA SpD Spe))}
            field={@form[key]}
            type="number"
            label={"Min #{label}"}
          />
        </div>
        <div class="flex flex-wrap items-center gap-3">
          <.input field={@form[:shiny_only]} type="checkbox" label="Shiny only" />
          <.button id="start-hunt" variant="primary" phx-disable-with="Starting...">
            <.icon name="hero-play" class="size-4" /> Hunt
          </.button>
          <.button
            id="cancel-hunt"
            type="button"
            phx-click="cancel"
            disabled={@stats.status != :running}
          >
            Cancel
          </.button>
          <.button
            id="kill-worker"
            type="button"
            phx-click="kill"
            disabled={@stats.status != :running}
          >
            <.icon name="hero-bolt" class="size-4" /> Kill a worker
          </.button>
        </div>
      </.form>

      <section id="hunt-stats" class="card bg-base-200 p-4 space-y-3">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <span id="hunt-status" class={["badge", status_class(@stats.status)]}>{status_label(
            @stats.status
          )}</span>
          <span class="font-mono text-sm">
            {fmt(@stats.done)} / {fmt(@stats.total)} Pokémon generated
          </span>
        </div>
        <progress
          class="progress progress-warning w-full"
          value={@stats.done}
          max={max(@stats.total, 1)}
        />
        <div class="stats stats-vertical w-full sm:stats-horizontal">
          <div class="stat">
            <div class="stat-title">Pokémon per second</div>
            <div class="stat-value text-2xl">{fmt(@stats.rate)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Time</div>
            <div class="stat-value text-2xl">{seconds(@stats.elapsed_ms)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Found</div>
            <div class="stat-value text-2xl">{fmt(@stats.match_count)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Workers killed</div>
            <div class="stat-value text-2xl">{@stats.crashes}</div>
            <div class="stat-desc">blocks redone without losing anything</div>
          </div>
        </div>

        <div
          :if={@stats.workers != []}
          id="workers"
          class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3"
        >
          <div :for={w <- @stats.workers} class="rounded-box bg-base-100 p-2 text-xs">
            <div class="flex justify-between font-mono">
              <span>{w.pid}</span>
              <span class="opacity-60">seeds {elem(w.chunk, 0)}–{elem(w.chunk, 1)}</span>
            </div>
            <progress class="progress progress-success w-full" value={w.done} max={max(w.total, 1)} />
          </div>
        </div>
        <p :if={@stats.status == :running} class="text-xs opacity-60">
          {length(@stats.workers)} active workers, {@stats.queued} blocks queued
        </p>
      </section>

      <section class="space-y-2">
        <h2 class="text-lg font-semibold">Results</h2>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Seed</th>
                <th>Slot</th>
                <th>Species</th>
                <th>Level</th>
                <th>Advance</th>
                <th>PID</th>
                <th>Nature</th>
                <th>HP</th>
                <th>Atk</th>
                <th>Def</th>
                <th>SpA</th>
                <th>SpD</th>
                <th>Spe</th>
              </tr>
            </thead>
            <tbody id="matches" phx-update="stream">
              <tr :for={{id, m} <- @streams.matches} id={id}>
                <td class="font-mono">{hex(m.seed, 4)}</td>
                <td>{m.slot}</td>
                <td>{m.species || "—"}</td>
                <td>{m.level || "—"}</td>
                <td class="font-mono">{fmt(m.advance)}</td>
                <td class="font-mono">
                  {hex(m.pid, 8)}
                  <.icon :if={m.shiny} name="hero-sparkles" class="size-4 text-warning" />
                </td>
                <td>{m.nature}</td>
                <td
                  :for={k <- [:hp, :atk, :def, :spa, :spd, :spe]}
                  class={m.ivs[k] == 31 && "font-bold text-success"}
                >
                  {m.ivs[k]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-xs opacity-60">
          Shows up to 500 results; the counter above includes all of them.
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp status_label(:idle), do: "idle"
  defp status_label(:running), do: "hunting"
  defp status_label(:done), do: "done"
  defp status_label(:cancelled), do: "cancelled"

  defp status_class(:running), do: "badge-warning"
  defp status_class(:done), do: "badge-success"
  defp status_class(_), do: "badge-ghost"

  defp hex(n, width), do: "0x" <> String.pad_leading(Integer.to_string(n, 16), width, "0")

  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> " s"

  defp fmt(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
