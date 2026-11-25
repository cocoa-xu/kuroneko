defmodule Kuroneko.DeviceSocket do
  @moduledoc """
  The device page's live data, a WebSocket of text messages: one with each
  sample of `NanoKVMGo.Metrics`, `{"metrics": sample, "status": status}` (see
  `Kuroneko.DeviceInfo.status/0`). The first also has the metrics'
  `"history"`, and every 30th the `"storage"`, whose use changes slowly
  and costs a df(1) to read.

  Without `NanoKVMGo.Metrics`, as on a computer in development, the status
  comes each second alone. The socket closes, with 1011, when the metrics
  stop: the page connects again.
  """
  @behaviour WebSock

  alias Kuroneko.DeviceInfo
  alias Kuroneko.Subscription
  alias NanoKVMGo.Metrics

  @status_ms 1_000
  @storage_every 30

  @impl WebSock
  def init(_args) do
    state = %{sent: 0}

    case Subscription.subscribe(Metrics, &subscribe/1) do
      {:ok, _monitor, {current, history}} -> push(%{metrics: current, history: history}, state)
      :not_running -> push(%{metrics: nil, history: nil}, status_later(state))
      :stopped -> {:stop, :normal, {1011, "the metrics stopped"}, state}
    end
  end

  @impl WebSock
  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({Metrics, sample}, state), do: push(%{metrics: sample}, state)
  def handle_info(:status, state), do: push(%{metrics: nil}, status_later(state))

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state),
    do: {:stop, :normal, {1011, "the metrics stopped"}, state}

  def handle_info(_message, state), do: {:ok, state}

  defp subscribe(metrics) do
    :ok = Metrics.subscribe(metrics)
    {Metrics.current(metrics), Metrics.history(metrics)}
  end

  defp status_later(state) do
    Process.send_after(self(), :status, @status_ms)
    state
  end

  defp push(message, state) do
    message = Map.put(message, :status, DeviceInfo.status())

    message =
      if rem(state.sent, @storage_every) == @storage_every - 1,
        do: Map.put(message, :storage, NanoKVMGo.Hardware.storage()),
        else: message

    {:push, {:text, Jason.encode!(message)}, %{state | sent: state.sent + 1}}
  end
end
