defmodule KuronekoWeb.DeviceLive.Bluetooth do
  @moduledoc false
  # Bluetooth: the controller, pairing for 2 minutes, the paired devices.

  use KuronekoWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kuroneko.DeviceInfo

  attr :bluetooth, :map, default: nil

  def bluetooth_card(assigns) do
    ~H"""
    <.card id="bluetooth" title="Bluetooth" icon="hero-signal">
      <:actions>
        <.button
          :if={@bluetooth}
          size={:sm}
          kind={if @bluetooth.pairing, do: :primary}
          phx-click="bluetooth:pairing"
          phx-value-open={to_string(!@bluetooth.pairing)}
        >
          {if @bluetooth.pairing, do: "Stop pairing", else: "Pair a device…"}
        </.button>
      </:actions>

      <%= if @bluetooth do %>
        <.facts rows={[
          {"Name", @bluetooth.name},
          {"Address", @bluetooth.address},
          {"Pairing",
           if(@bluetooth.pairing,
             do: "Open for 2 minutes: pair from the other device's Bluetooth settings",
             else: "Closed"
           )},
          {"Keyboard and mouse",
           if(@bluetooth.host, do: "In use by a paired device", else: "No paired device connected")}
        ]} />

        <ul
          :if={@bluetooth.devices != []}
          class="mt-4 divide-y divide-base-300/60 rounded-field bg-base-200/60"
        >
          <li :for={device <- @bluetooth.devices} class="flex items-center gap-3 px-3 py-2.5 text-sm">
            <.icon name={device_icon(device.icon)} class="size-5 text-base-content/50" />
            <span class="min-w-0 flex-1 truncate font-medium">{device.name || device.address}</span>
            <.badge kind={if device.connected, do: :ok}>
              {if device.connected, do: "Connected", else: "Paired"}
            </.badge>
            <.button
              size={:sm}
              kind={:danger}
              phx-click="bluetooth:forget"
              phx-value-address={device.address}
            >
              Forget
            </.button>
          </li>
        </ul>

        <p class="mt-4 text-xs text-base-content/55">
          While pairing is open, a phone, tablet or computer finds the NanoKVM in its Bluetooth settings as a
          keyboard and mouse, and stays paired. On the Remote page the mouse's menu then sends the keyboard
          and mouse there instead of to USB.
        </p>
      <% else %>
        <p class="text-sm text-base-content/60">Not running: the system has no Bluetooth.</p>
      <% end %>
    </.card>
    """
  end

  defp device_icon("phone"), do: "hero-device-phone-mobile"
  defp device_icon("computer"), do: "hero-computer-desktop"
  defp device_icon("input-keyboard"), do: "hero-command-line"
  defp device_icon(_), do: "hero-signal"

  def event("pairing", %{"open" => open}, socket) do
    change(socket, fn ->
      if open == "true",
        do: NanoKVMGo.Bluetooth.open_pairing(120),
        else: NanoKVMGo.Bluetooth.close_pairing()
    end)
  end

  def event("forget", %{"address" => address}, socket) do
    change(socket, fn -> NanoKVMGo.Bluetooth.forget(address) end)
  end

  defp change(socket, fun) do
    case fun.() do
      :ok -> {:noreply, assign(socket, status: DeviceInfo.status())}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Bluetooth: #{inspect(reason)}")}
    end
  catch
    :exit, _not_running -> {:noreply, put_flash(socket, :error, "Bluetooth is not running")}
  end
end
