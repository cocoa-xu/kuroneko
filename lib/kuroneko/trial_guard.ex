defmodule Kuroneko.TrialGuard do
  @moduledoc """
  Reboots after a while when this boot runs on trial, an unvalidated
  firmware or memory sizes on trial (`NanoKVMGo.CMA`), so that U-Boot goes
  back to the previous firmware and sizes; logs the network state as it
  changes meanwhile.
  Validate by hand once the device is reachable:
  `Nerves.Runtime.validate_firmware()`, or from the device page, keeps both.
  `remaining/0` tells how long is left.
  """
  use GenServer
  require Logger

  @timeout :timer.minutes(5)
  @interfaces ["usb0", "wlan0"]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Milliseconds until the reboot, `nil` when nothing was on trial at start.
  """
  @spec remaining() :: non_neg_integer() | nil
  def remaining do
    GenServer.call(__MODULE__, :remaining)
  catch
    :exit, {:noproc, _call} -> nil
  end

  @impl GenServer
  def init(_opts) do
    case on_trial() do
      [] ->
        :ignore

      trial ->
        Logger.warning(
          "trial guard: #{Enum.join(trial, " and ")} on trial, rebooting in 5 minutes"
        )

        Process.send_after(self(), :check, @timeout)

        for ifname <- @interfaces do
          :ok = Kuroneko.Network.subscribe(ifname, ["connection"])
          :ok = Kuroneko.Network.subscribe(ifname, ["addresses"])
          log_network(ifname)
        end

        {:ok, %{deadline: now() + @timeout}}
    end
  end

  @impl GenServer
  def handle_call(:remaining, _from, state) do
    {:reply, max(state.deadline - now(), 0), state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    case on_trial() do
      [] ->
        {:stop, :normal, state}

      trial ->
        Logger.warning("trial guard: #{Enum.join(trial, " and ")} still on trial, rebooting")
        Nerves.Runtime.reboot()
        {:noreply, state}
    end
  end

  def handle_info({VintageNet, ["interface", ifname, _key], _old, _new, _metadata}, state) do
    log_network(ifname)
    {:noreply, state}
  end

  # What to look at when the device cannot be reached to validate it.
  defp log_network(ifname) do
    connection = Kuroneko.Network.get(ifname, ["connection"])
    addresses = Kuroneko.Network.addresses(ifname)
    Logger.info("trial guard: #{ifname} #{inspect(connection)} #{Enum.join(addresses, " ")}")
  end

  defp on_trial do
    firmware = if Nerves.Runtime.firmware_valid?(), do: [], else: ["firmware"]
    memory = if match?(%{state: :running}, NanoKVMGo.CMA.trial()), do: ["memory sizes"], else: []
    firmware ++ memory
  end

  defp now, do: System.monotonic_time(:millisecond)
end
