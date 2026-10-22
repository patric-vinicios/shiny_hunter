defmodule ShinyHunter.Hunt do
  @moduledoc """
  Owns the current hunt: hands search chunks to supervised tasks, at most
  `concurrency` at a time, and collects their matches.

  Tasks are not linked to the hunt. When one dies (or is killed from the UI),
  its chunk goes back to the queue and its partial progress is discarded, so
  every chunk is counted exactly once. Progress is broadcast on `topic/0`.
  """

  use GenServer

  alias ShinyHunter.Search
  alias ShinyHunter.Search.Params

  @topic "hunt"
  @tick_ms 200
  @max_matches 500

  def topic, do: @topic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts a new hunt, killing the workers of the previous one."
  def start(%Params{} = params, concurrency, context \\ %{}),
    do: GenServer.call(__MODULE__, {:start, params, concurrency, context})

  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @doc "Kills one running worker at random, to show the hunt recovering."
  def kill_worker, do: GenServer.call(__MODULE__, :kill_worker)

  @doc "The current stats and matches, for a page that just connected."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(_opts) do
    {:ok, idle()}
  end

  defp idle do
    %{
      status: :idle,
      params: nil,
      # caller-supplied display data, returned unchanged in stats
      context: %{},
      concurrency: 0,
      queue: [],
      # task pid => %{ref, chunk, done}
      running: %{},
      completed: 0,
      total: 0,
      matches: [],
      match_count: 0,
      crashes: 0,
      started_at: nil,
      elapsed_ms: 0,
      rate: 0,
      last_tick: {0, nil}
    }
  end

  @impl true
  def handle_call({:start, params, concurrency, context}, _from, state) do
    kill_all(state)
    now = now()

    state = %{
      idle()
      | status: :running,
        params: params,
        context: context,
        concurrency: concurrency,
        queue: Search.chunks(params),
        total: Search.total(params),
        started_at: now,
        last_tick: {0, now}
    }

    state = fill(state)
    Process.send_after(self(), :tick, @tick_ms)
    broadcast({:reset, stats(state)})
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, %{status: :running} = state) do
    kill_all(state)
    state = finish(%{state | running: %{}, queue: []}, :cancelled)
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  # The worker leaves `running` now rather than on its :DOWN, so a second kill
  # never picks it again. A reply it may already have sent is ignored like any
  # unknown ref, and its chunk is redone once.
  def handle_call(:kill_worker, _from, %{running: running} = state) when map_size(running) > 0 do
    {pid, worker} = Enum.random(running)
    Process.exit(pid, :kill)
    Process.demonitor(worker.ref, [:flush])
    {:reply, {:ok, pid}, requeue(state, pid, worker)}
  end

  def handle_call(:kill_worker, _from, state), do: {:reply, :none, state}

  def handle_call(:snapshot, _from, state), do: {:reply, {stats(state), state.matches}, state}

  @impl true
  def handle_info({:progress, pid, n}, state) do
    case state.running do
      %{^pid => worker} ->
        {:noreply, put_in(state.running[pid], %{worker | done: worker.done + n})}

      _ ->
        {:noreply, state}
    end
  end

  # A task finished its chunk.
  def handle_info({ref, {matches, _truncated}}, state) when is_reference(ref) do
    case pop_by_ref(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {{_pid, worker}, running} ->
        Process.demonitor(ref, [:flush])
        {chunk_first, chunk_last} = worker.chunk
        chunk_total = (chunk_last - chunk_first + 1) * Range.size(state.params.advances)

        kept = Enum.take(matches, max(@max_matches - length(state.matches), 0))
        if kept != [], do: broadcast({:matches, kept})

        state = %{
          state
          | running: running,
            completed: state.completed + chunk_total,
            matches: state.matches ++ kept,
            match_count: state.match_count + length(matches)
        }

        {:noreply, state |> fill() |> maybe_finish()}
    end
  end

  # A task died before finishing: its chunk goes back to the queue.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.running, fn {_pid, w} -> w.ref == ref end) do
      nil -> {:noreply, state}
      {pid, worker} -> {:noreply, requeue(state, pid, worker)}
    end
  end

  def handle_info(:tick, %{status: :running} = state) do
    now = now()
    done = done(state)
    {last_done, last_time} = state.last_tick

    rate =
      if now > last_time, do: div((done - last_done) * 1000, now - last_time), else: state.rate

    state = %{state | rate: rate, last_tick: {done, now}, elapsed_ms: now - state.started_at}
    broadcast({:tick, stats(state)})
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp fill(%{status: :running, queue: [chunk | rest]} = state)
       when map_size(state.running) < state.concurrency do
    hunt = self()
    params = state.params

    %Task{pid: pid, ref: ref} =
      Task.Supervisor.async_nolink(ShinyHunter.TaskSupervisor, fn ->
        Search.search_chunk(chunk, params, fn n -> send(hunt, {:progress, self(), n}) end)
      end)

    fill(%{
      state
      | queue: rest,
        running: Map.put(state.running, pid, %{ref: ref, chunk: chunk, done: 0})
    })
  end

  defp fill(state), do: state

  defp requeue(state, pid, worker) do
    fill(%{
      state
      | running: Map.delete(state.running, pid),
        queue: [worker.chunk | state.queue],
        crashes: state.crashes + 1
    })
  end

  defp maybe_finish(%{queue: [], running: running} = state) when map_size(running) == 0,
    do: finish(state, :done)

  defp maybe_finish(state), do: state

  defp finish(state, status) do
    state = %{state | status: status, elapsed_ms: now() - state.started_at}
    broadcast({:tick, stats(state)})
    state
  end

  defp kill_all(state), do: Enum.each(state.running, fn {pid, _} -> Process.exit(pid, :kill) end)

  defp pop_by_ref(running, ref) do
    case Enum.find(running, fn {_pid, w} -> w.ref == ref end) do
      nil -> {nil, running}
      {pid, _} = entry -> {entry, Map.delete(running, pid)}
    end
  end

  defp done(state), do: state.completed + Enum.sum_by(state.running, fn {_, w} -> w.done end)

  defp stats(state) do
    per_chunk_seed = if state.params, do: Range.size(state.params.advances), else: 0

    %{
      status: state.status,
      context: state.context,
      tid: state.params && state.params.tid,
      sid: state.params && state.params.sid,
      total: state.total,
      done: done(state),
      rate: state.rate,
      elapsed_ms: state.elapsed_ms,
      match_count: state.match_count,
      crashes: state.crashes,
      concurrency: state.concurrency,
      queued: length(state.queue),
      workers:
        state.running
        |> Enum.map(fn {pid, w} ->
          {first, last} = w.chunk

          %{
            pid: inspect(pid),
            chunk: w.chunk,
            done: w.done,
            total: (last - first + 1) * per_chunk_seed
          }
        end)
        |> Enum.sort_by(& &1.chunk)
    }
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(ShinyHunter.PubSub, @topic, message)

  defp now, do: System.monotonic_time(:millisecond)
end
