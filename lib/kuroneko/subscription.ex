defmodule Kuroneko.Subscription do
  @moduledoc false
  # A subscription to a registered process, with a monitor of it: the
  # monitor's :DOWN is the end of the subscription.

  @spec subscribe(atom(), (pid() -> result)) ::
          {:ok, reference(), result} | :not_running | :stopped
        when result: term()
  def subscribe(name, subscribe) do
    case GenServer.whereis(name) do
      nil -> :not_running
      pid -> monitored(pid, subscribe)
    end
  end

  # Stopped between the lookup and the call: no subscription.
  defp monitored(pid, subscribe) do
    monitor = Process.monitor(pid)

    try do
      {:ok, monitor, subscribe.(pid)}
    catch
      :exit, {:noproc, _call} ->
        Process.demonitor(monitor, [:flush])
        :stopped
    end
  end
end
