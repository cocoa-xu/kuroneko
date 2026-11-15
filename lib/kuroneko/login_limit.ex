defmodule Kuroneko.LoginLimit do
  @moduledoc """
  Failed logins: after five within a minute, logins are refused until that
  minute is over.
  """
  use Agent

  @window_ms 60_000
  @max_failures 5

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_arg), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @doc "Whether a login may be tried now."
  @spec allow?() :: boolean()
  def allow?, do: Agent.get(__MODULE__, &(length(recent(&1)) < @max_failures))

  @doc "Counts a failed login."
  @spec failed() :: :ok
  def failed, do: Agent.update(__MODULE__, &[now() | recent(&1)])

  @doc "Forgets the failures."
  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _failures -> [] end)

  defp recent(failures), do: Enum.filter(failures, &(now() - &1 < @window_ms))
  defp now, do: System.monotonic_time(:millisecond)
end
