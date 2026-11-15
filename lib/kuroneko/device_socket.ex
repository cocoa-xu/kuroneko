defmodule Kuroneko.DeviceSocket do
  @moduledoc """
  The device page's live data, a WebSocket of text messages: one with each
  sample of `NanoKVMGo.Metrics`, `{"metrics": sample, "status": status}` (see
  `Kuroneko.DeviceInfo.status/0`). The first also has the metrics'
  `"history"`, and every 30th the `"storage"`, whose use changes slowly
  and costs a df(1) to read.

  While `NanoKVMGo.Metrics` is not running, the status still comes each
  second, and the socket subscribes again once it is back.
  """
  @behaviour WebSock

  alias NanoKVMGo.Metrics
  alias Kuroneko.DeviceInfo

  @retry_ms 1_000
  @storage_every 30

  @impl WebSock
  def init(_args) do
    state = subscribe(%{metrics: nil, sent: 0})
    current = if state.metrics, do: safely(&Metrics.current/0)
    history = if state.metrics, do: safely(&Metrics.history/0)
    push(%{metrics: current, history: history}, state)
  end

  @impl WebSock
  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({Metrics, sample}, state), do: push(%{metrics: sample}, state)

  def handle_info(:retry, %{metrics: nil} = state) do
    state = subscribe(state)
    push(%{metrics: nil}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{metrics: ref} = state) do
    {:ok, retry(%{state | metrics: nil})}
  end

  def handle_info(_message, state), do: {:ok, state}

  defp push(message, state) do
    message = Map.put(message, :status, DeviceInfo.status())

    message =
      if rem(state.sent, @storage_every) == @storage_every - 1,
        do: Map.put(message, :storage, NanoKVMGo.Hardware.storage()),
        else: message

    {:push, {:text, Jason.encode!(message)}, %{state | sent: state.sent + 1}}
  end

  # Monitors the sampler, so as to subscribe again when it restarts.
  defp subscribe(state) do
    case GenServer.whereis(Metrics) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)

        if safely(fn -> Metrics.subscribe(pid) end) == :ok do
          %{state | metrics: ref}
        else
          Process.demonitor(ref, [:flush])
          retry(state)
        end

      _not_running ->
        retry(state)
    end
  end

  defp retry(state) do
    Process.send_after(self(), :retry, @retry_ms)
    state
  end

  defp safely(fun) do
    fun.()
  catch
    :exit, _reason -> nil
  end
end
