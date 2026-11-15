defmodule Kuroneko.ExpansionWatch do
  @moduledoc """
  Counts the edges of the expansion lines' GPIO inputs (`NanoKVMGo.Expansion`)
  for the device page. A PWM read back on the other line shows as two edges
  a period: the Finger Robot's servo at 50 Hz makes 100 a second.

  It subscribes again whenever `NanoKVMGo.Expansion` restarts.

  ## Options

    * `:name` - the name to register, this module by default
    * `:server` - the `NanoKVMGo.Expansion` to watch, by its registered name
  """
  use GenServer

  @lines [0, 1]

  @type edges() :: %{total: non_neg_integer(), per_second: non_neg_integer()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The edges of each line: all of them, and those of the last whole second.
  """
  @spec edges(GenServer.server()) :: %{(0 | 1) => edges()}
  def edges(server \\ __MODULE__), do: GenServer.call(server, :edges)

  @impl GenServer
  def init(opts) do
    send(self(), :subscribe)
    lines = Map.new(@lines, &{&1, %{total: 0, second: nil, count: 0, previous: 0}})
    {:ok, %{server: Keyword.get(opts, :server, NanoKVMGo.Expansion), lines: lines}}
  end

  @impl GenServer
  def handle_call(:edges, _from, state) do
    now = System.monotonic_time(:second)
    {:reply, Map.new(state.lines, fn {line, counts} -> {line, rate(counts, now)} end), state}
  end

  @impl GenServer
  def handle_info(:subscribe, state) do
    with pid when is_pid(pid) <- GenServer.whereis(state.server),
         :ok <- NanoKVMGo.Expansion.subscribe(pid) do
      Process.monitor(pid)
    else
      _ -> Process.send_after(self(), :subscribe, 1_000)
    end

    {:noreply, state}
  catch
    :exit, _reason ->
      Process.send_after(self(), :subscribe, 1_000)
      {:noreply, state}
  end

  def handle_info({NanoKVMGo.Expansion, {:edge, line, _value, _timestamp}}, state) do
    now = System.monotonic_time(:second)
    {:noreply, update_in(state.lines[line], &count(&1, now))}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Process.send_after(self(), :subscribe, 1_000)
    {:noreply, state}
  end

  # Edges are counted in the second they come in; the rate is the count of
  # the last whole second.
  defp count(%{second: now} = counts, now),
    do: %{counts | total: counts.total + 1, count: counts.count + 1}

  defp count(counts, now) do
    previous = if counts.second == now - 1, do: counts.count, else: 0
    %{counts | total: counts.total + 1, second: now, count: 1, previous: previous}
  end

  defp rate(counts, now) do
    per_second =
      cond do
        counts.second == now -> counts.previous
        counts.second == now - 1 -> counts.count
        true -> 0
      end

    %{total: counts.total, per_second: per_second}
  end
end
