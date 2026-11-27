defmodule KuronekoWeb.KVMLive.Menu do
  @moduledoc false
  # The KVM page's NanoKVM menu: the meters, then rows that open panels of
  # their own in the menu, then the pages and the session. Styled by the KVM
  # page's own CSS (the kvm_root layout).

  use KuronekoWeb, :html

  import Phoenix.LiveView, only: [push_event: 3, start_async: 3]

  alias Kuroneko.{DeviceInfo, USBSettings, WakeOnLan, WiFi}
  alias KuronekoWeb.Format

  @panels %{
    "main" => :main,
    "usb" => :usb,
    "screen" => :screen,
    "wifi" => :wifi,
    "bluetooth" => :bluetooth,
    "wake" => :wake,
    "password" => :password,
    "restart" => :restart
  }

  @doc false
  def panel(name), do: @panels[name]

  @doc false
  # What the open menu shows, anew.
  def refresh(socket) do
    wifi = if socket.assigns.menu == :wifi, do: safely(&WiFi.overview/0)

    assign(socket,
      status: safely(&DeviceInfo.status/0),
      usb: USBSettings.saved(),
      wifi: wifi || socket.assigns.wifi
    )
  end

  defp safely(fun) do
    fun.()
  catch
    :exit, _not_running -> nil
  end

  attr :panel, :atom, required: true
  attr :status, :map, default: nil
  attr :metrics, :map, default: nil
  attr :usb, :map, required: true
  attr :usb_busy, :boolean, required: true
  attr :wifi, :map, default: nil
  attr :wifi_join, :map, default: nil
  attr :wake_mac, :string, required: true
  attr :message, :any, default: nil

  def menu(%{panel: :main} = assigns) do
    ~H"""
    <h4>NanoKVM</h4>
    <section>
      <.usage label="CPU" percent={@metrics && @metrics.cpu.total} />
      <.usage label="Memory" percent={@metrics && @metrics.memory.percent} />
      <span :if={@metrics} id="net">{net_text(@metrics)}</span>
    </section>
    <section>
      <.entry panel="usb" label="USB devices" detail={usb_detail(@usb)} />
      <.entry panel="screen" label="Screen" detail={screen_detail(@status)} />
      <.entry panel="wifi" label="Wi-Fi" detail={wifi_detail(@status)} />
      <.entry panel="bluetooth" label="Bluetooth" detail={bluetooth_detail(@status)} />
      <.entry panel="wake" label="Wake on LAN" detail={@wake_mac} />
    </section>
    <section>
      <a class="menu-row" href="/device" target="kuroneko-device">Status and hardware</a>
      <a class="menu-row" href="/settings" target="kuroneko-settings">Settings</a>
      <button type="button" class="menu-row" phx-click="menu" phx-value-panel="password">
        Change password…
      </button>
      <button type="button" class="menu-row" phx-click={JS.dispatch("kvm:logout")}>Log out</button>
      <button type="button" class="menu-row danger" phx-click="menu" phx-value-panel="restart">
        Restart the NanoKVM…
      </button>
    </section>
    """
  end

  def menu(%{panel: :usb} = assigns) do
    ~H"""
    <.back title="USB devices" />
    <section>
      <.toggle
        label="Keyboard and mice"
        detail="A keyboard and two mice"
        on={@usb["hid"]}
        key="hid"
        disabled={@usb_busy}
      />
      <.toggle
        label="Mouse jiggler"
        detail="A pixel and back each minute"
        on={@usb["jiggler"]}
        key="jiggler"
        disabled={@usb_busy or not @usb["hid"]}
      />
      <.toggle
        label="Network"
        detail="usb0, the NanoKVM's own"
        on={@usb["network"]}
        key="network"
        disabled={@usb_busy}
      />
      <.toggle
        label="Virtual disk"
        detail={"#{@usb["drives"]} drive#{if @usb["drives"] != 1, do: "s"}"}
        on={@usb["storage"]}
        key="storage"
        disabled={@usb_busy}
      />
    </section>
    <section>
      <span class="label">Sound card</span>
      <div class="seg fit" role="group" aria-label="Sound card">
        <button
          :for={{value, label} <- [{"off", "Off"}, {"mic", "Mic"}, {"duplex", "Mic and speaker"}]}
          type="button"
          aria-pressed={to_string(@usb["audio"] == value)}
          disabled={@usb_busy}
          phx-click="usb_audio"
          phx-value-value={value}
        >
          {label}
        </button>
      </div>
      <p class="note">
        {if @usb_busy,
          do: "Reconnecting the USB devices…",
          else: "Each change reconnects the USB devices on the target."}
      </p>
      <.message message={@message} />
    </section>
    <.more href="/device#usb" label="All USB settings" />
    """
  end

  def menu(%{panel: :screen} = assigns) do
    assigns = assign(assigns, screen: assigns.status && assigns.status[:screen])

    ~H"""
    <.back title="Screen" />
    <%= if @screen do %>
      <section>
        <form id="menu-brightness" phx-change="screen:brightness" phx-auto-recover="ignore">
          <span class="label">Brightness</span>
          <input
            type="range"
            name="brightness"
            min="5"
            max="100"
            value={@screen.brightness}
            phx-debounce="120"
            aria-label="Brightness"
          />
        </form>
      </section>
      <section>
        <span class="label">Rotation</span>
        <div class="seg" role="group" aria-label="Rotation">
          <button
            :for={{value, label} <- [{0, "Upright"}, {180, "Upside down"}]}
            type="button"
            aria-pressed={to_string(@screen.rotate == value)}
            phx-click="screen:rotate"
            phx-value-value={value}
          >
            {label}
          </button>
        </div>
      </section>
      <section>
        <form id="menu-sleep" phx-change="screen:sleep" phx-auto-recover="ignore">
          <span class="label">Turns off</span>
          <select name="sleep" aria-label="Turns off">
            <option
              :for={
                {value, label} <- [
                  {0, "Never"},
                  {1, "After a minute"},
                  {5, "After 5 minutes"},
                  {15, "After 15 minutes"},
                  {60, "After an hour"}
                ]
              }
              value={value}
              selected={value == @screen.sleep}
            >
              {label}
            </option>
          </select>
        </form>
      </section>
    <% else %>
      <p class="note">The screen is not running.</p>
    <% end %>
    <.more href="/device#screen" label="All screen settings" />
    """
  end

  def menu(%{panel: :wifi} = assigns) do
    assigns =
      assign(assigns,
        current: assigns.wifi && assigns.wifi.network,
        networks: (assigns.wifi && assigns.wifi.networks) || []
      )

    ~H"""
    <.back title="Wi-Fi" />
    <section>
      <div class="heading">
        <span class="label">Networks in reach</span>
        <button type="button" class="button small" phx-click="wifi_scan">Look again</button>
      </div>
      <p :if={@wifi == nil} class="note">Looking for networks…</p>
      <p :if={@wifi && @networks == []} class="note">No networks in reach yet.</p>
      <button
        :for={network <- Enum.take(@networks, 8)}
        type="button"
        class={["net", network.ssid == @current && "current"]}
        phx-click="wifi_pick"
        phx-value-ssid={network.ssid}
      >
        <span class="name">{network.ssid}</span>
        <span class="meta">
          {if network.ssid == @current,
            do: connection_text(@wifi),
            else: security_text(network.security)}
        </span>
        <span class="meta">{network.signal_percent}%</span>
      </button>
    </section>
    <section :if={@wifi_join}>
      <form id="menu-wifi-join" phx-submit="wifi_join">
        <span class="label">Password for {@wifi_join.ssid}</span>
        <input type="hidden" name="ssid" value={@wifi_join.ssid} />
        <input
          type="password"
          name="passphrase"
          autocomplete="off"
          aria-label="Wi-Fi password"
          phx-mounted={JS.focus()}
        />
        <div class="actions">
          <button type="button" class="button" phx-click="wifi_cancel">Cancel</button>
          <button type="submit" class="button primary">Join</button>
        </div>
      </form>
    </section>
    <.message message={@message} />
    <.more href="/settings#wifi" label="Wi-Fi settings" />
    """
  end

  def menu(%{panel: :bluetooth} = assigns) do
    assigns = assign(assigns, bluetooth: assigns.status && assigns.status[:bluetooth])

    ~H"""
    <.back title="Bluetooth" />
    <%= if @bluetooth do %>
      <section>
        <button
          type="button"
          class="toggle"
          role="switch"
          aria-checked={to_string(@bluetooth.pairing)}
          phx-click="bluetooth:pairing"
          phx-value-open={to_string(not @bluetooth.pairing)}
        >
          <span class="t">
            <span class="t-label">Pairing</span>
            <span class="t-detail">
              {if @bluetooth.pairing,
                do: "Open: pair it as a keyboard and mouse",
                else: "For 2 minutes, when on"}
            </span>
          </span>
          <span class="switch"></span>
        </button>
      </section>
      <section>
        <span class="label">Paired devices</span>
        <p :if={@bluetooth.devices == []} class="note">None yet.</p>
        <div :for={device <- @bluetooth.devices} class="device-row">
          <span class="name">{device.name || device.address}</span>
          <span class="meta">{if device.connected, do: "Connected", else: "Paired"}</span>
          <button
            type="button"
            class="button small"
            phx-click="bluetooth:forget"
            phx-value-address={device.address}
          >
            Forget
          </button>
        </div>
        <p class="note">The mouse menu sends the keyboard and mouse to Bluetooth.</p>
      </section>
    <% else %>
      <p class="note">Not running: the system has no Bluetooth.</p>
    <% end %>
    <.more href="/device#bluetooth" label="Bluetooth on the device page" />
    """
  end

  def menu(%{panel: :wake} = assigns) do
    ~H"""
    <.back title="Wake on LAN" />
    <section>
      <form id="menu-wake" phx-submit="wake">
        <span class="label">The computer's MAC address</span>
        <input
          type="text"
          name="mac"
          value={@wake_mac}
          placeholder="aa:bb:cc:dd:ee:ff"
          spellcheck="false"
          autocomplete="off"
          aria-label="MAC address"
        />
        <div class="actions">
          <button type="submit" class="button primary">Wake</button>
        </div>
      </form>
      <.message message={@message} />
    </section>
    """
  end

  def menu(%{panel: :password} = assigns) do
    ~H"""
    <.back title="Change password" />
    <section>
      <form id="menu-password" phx-submit={JS.dispatch("kvm:password")}>
        <input
          type="password"
          name="current"
          placeholder="Current password"
          autocomplete="current-password"
          aria-label="Current password"
        />
        <input
          type="password"
          name="password"
          placeholder="New password, 8 characters or more"
          autocomplete="new-password"
          aria-label="New password"
        />
        <input
          type="password"
          name="again"
          placeholder="New password again"
          autocomplete="new-password"
          aria-label="New password again"
        />
        <p id="menu-password-state" class="message" phx-update="ignore"></p>
        <div class="actions">
          <button type="submit" class="button primary">Change</button>
        </div>
      </form>
    </section>
    """
  end

  def menu(%{panel: :restart} = assigns) do
    ~H"""
    <.back title="Restart the NanoKVM" />
    <section>
      <p class="note">
        Video, keyboard and mouse stop for about 30 seconds. This page reconnects by itself.
      </p>
      <div class="actions">
        <button type="button" class="button" phx-click="menu" phx-value-panel="main">Cancel</button>
        <button type="button" class="button destructive" phx-click="restart">Restart</button>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :percent, :any, default: nil

  defp usage(assigns) do
    ~H"""
    <div class="meterrow">
      <span>{@label}</span>
      <span class="meter">
        <i
          :if={@percent}
          class={
            cond do
              @percent >= 85 -> "hot"
              @percent >= 60 -> "warm"
              true -> nil
            end
          }
          style={"width: #{min(100, max(0, @percent))}%"}
        ></i>
      </span>
      <b>{if @percent, do: "#{round(@percent)}%", else: "–"}</b>
    </div>
    """
  end

  attr :panel, :string, required: true
  attr :label, :string, required: true
  attr :detail, :string, default: nil

  defp entry(assigns) do
    ~H"""
    <button type="button" class="menu-row" phx-click="menu" phx-value-panel={@panel}>
      <span>{@label}</span>
      <span class="detail">{@detail}</span>
      <span class="chevron" aria-hidden="true">›</span>
    </button>
    """
  end

  attr :title, :string, required: true

  defp back(assigns) do
    ~H"""
    <button type="button" class="menu-back" phx-click="menu" phx-value-panel="main">‹ NanoKVM</button>
    <h4>{@title}</h4>
    """
  end

  attr :label, :string, required: true
  attr :detail, :string, required: true
  attr :on, :boolean, required: true
  attr :key, :string, required: true
  attr :disabled, :boolean, default: false

  defp toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="toggle"
      role="switch"
      aria-checked={to_string(@on)}
      disabled={@disabled}
      phx-click="usb"
      phx-value-key={@key}
      phx-value-on={to_string(not @on)}
    >
      <span class="t"><span class="t-label">{@label}</span><span class="t-detail">{@detail}</span></span>
      <span class="switch"></span>
    </button>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true

  defp more(assigns) do
    ~H"""
    <section>
      <a class="menu-row" href={@href} target="kuroneko-device">{@label}</a>
    </section>
    """
  end

  attr :message, :any, default: nil

  defp message(assigns) do
    ~H"""
    <p :if={@message} class={["message", elem(@message, 0) == :error && "error"]}>
      {elem(@message, 1)}
    </p>
    """
  end

  defp net_text(metrics) do
    total =
      Enum.reduce(Map.values(metrics.network), %{down: 0, up: 0}, fn n, t ->
        %{down: t.down + n.down, up: t.up + n.up}
      end)

    "↓#{Format.rate(total.down)} ↑#{Format.rate(total.up)}"
  end

  defp usb_detail(usb) do
    [
      usb["hid"] && "keyboard",
      usb["network"] && "network",
      usb["storage"] && "disk",
      usb["audio"] != "off" && "sound"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "None"
      [first | rest] -> Enum.join([String.capitalize(first) | rest], ", ")
    end
  end

  defp screen_detail(%{screen: %{brightness: brightness}}), do: "#{brightness}%"
  defp screen_detail(%{screen: nil}), do: "Not running"
  defp screen_detail(_status), do: nil

  defp wifi_detail(%{network: network}) do
    case Enum.find(Map.values(network), &(&1.kind == :wifi)) do
      %{wifi: %{ssid: ssid}} when is_binary(ssid) -> ssid
      %{} -> "Not connected"
      nil -> "None"
    end
  end

  defp wifi_detail(_status), do: nil

  defp bluetooth_detail(%{bluetooth: nil}), do: "Off"
  defp bluetooth_detail(%{bluetooth: %{pairing: true}}), do: "Pairing"
  defp bluetooth_detail(%{bluetooth: %{host: true}}), do: "Connected"
  defp bluetooth_detail(%{bluetooth: %{devices: devices}}), do: "#{length(devices)} paired"
  defp bluetooth_detail(_status), do: nil

  defp connection_text(%{connection: connection}) when connection in [:internet, :lan],
    do: "Connected"

  defp connection_text(_wifi), do: "Joining"

  defp security_text(:open), do: "Open"
  defp security_text(_secured), do: "🔒"

  # Events

  @doc false
  def event("usb", %{"key" => key, "on" => on}, socket)
      when key in ~w(hid jiggler network storage),
      do: apply_usb(socket, %{key => on == "true"})

  def event("usb_audio", %{"value" => audio}, socket) when audio in ~w(off mic duplex),
    do: apply_usb(socket, %{"audio" => audio})

  def event("wifi_scan", _params, socket) do
    _ = safely(&WiFi.scan/0)
    Process.send_after(self(), :wifi, 3_000)
    {:noreply, assign(socket, message: {:info, "Looking for networks…"})}
  end

  def event("wifi_pick", %{"ssid" => ssid}, socket) do
    network =
      Enum.find((socket.assigns.wifi && socket.assigns.wifi.networks) || [], &(&1.ssid == ssid))

    cond do
      network == nil -> {:noreply, socket}
      network.security == :open -> join(socket, ssid, nil)
      true -> {:noreply, assign(socket, wifi_join: %{ssid: ssid}, message: nil)}
    end
  end

  def event("wifi_cancel", _params, socket),
    do: {:noreply, assign(socket, wifi_join: nil, message: nil)}

  def event("wifi_join", %{"ssid" => ssid, "passphrase" => passphrase}, socket),
    do: join(socket, ssid, passphrase)

  def event("wake", %{"mac" => text}, socket) do
    text = String.trim(text)

    with {:ok, mac} <- WakeOnLan.parse_mac(text),
         :ok <- WakeOnLan.wake(mac) do
      _ = WakeOnLan.save_mac(text)

      {:noreply,
       assign(socket, wake_mac: text, message: {:info, "Sent the magic packet to #{text}."})}
    else
      :error ->
        {:noreply,
         assign(socket,
           message: {:error, "Not a MAC address: six hex bytes, as aa:bb:cc:dd:ee:ff"}
         )}

      {:error, reason} ->
        {:noreply, assign(socket, message: {:error, "Not sent: #{inspect(reason)}"})}
    end
  end

  def event("restart", _params, socket) do
    reboot = Application.get_env(:kuroneko, :reboot, &Nerves.Runtime.reboot/0)
    # The page hears first: the restart takes the socket with it.
    Process.send_after(self(), {:restart, reboot}, 300)
    {:noreply, socket |> assign(menu: :main) |> push_event("kvm:restarting", %{})}
  end

  defp apply_usb(socket, changes) do
    {:noreply,
     socket
     |> assign(usb_busy: true, usb: Map.merge(socket.assigns.usb, changes), message: nil)
     |> start_async(:usb, fn -> USBSettings.update(changes) end)}
  end

  @doc false
  def usb_applied({:ok, {:ok, settings}}, socket),
    do: {:noreply, assign(socket, usb_busy: false, usb: settings)}

  def usb_applied(result, socket) do
    reason =
      case result do
        {:ok, {:error, reason}} -> reason
        {:exit, reason} -> reason
      end

    {:noreply,
     assign(socket,
       usb_busy: false,
       usb: USBSettings.saved(),
       message: {:error, "Not changed: #{inspect(reason)}"}
     )}
  end

  # Joining can take the page's own connection with it: the reply goes first.
  defp join(socket, ssid, passphrase) do
    case WiFi.config(ssid, passphrase) do
      {:ok, config} ->
        Task.start(fn -> WiFi.apply_config(config) end)
        {:noreply, assign(socket, wifi_join: nil, message: {:info, "Joining #{ssid}…"})}

      {:error, reason} ->
        {:noreply, assign(socket, message: {:error, "Not joined: #{reason}"})}
    end
  end
end
