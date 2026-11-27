defmodule KuronekoWeb.DeviceLive.Network do
  @moduledoc false
  # The network interfaces, and the USB network's MAC and IP addresses.

  use KuronekoWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias KuronekoWeb.Format

  @kinds %{
    wifi: {"Wi-Fi", "hero-wifi"},
    usb: {"USB network", "hero-bolt"},
    ethernet: {"Ethernet", "hero-globe-alt"}
  }
  @mac ~r/^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$/i
  @mac_errors %{
    invalid_address: "Not a MAC address",
    multicast_address: "A multicast address: the first byte has to be even",
    same_addresses: "Each end needs an address of its own",
    no_default_addresses: "There is no default: the NanoKVM has no serial number"
  }
  @ip_errors %{
    invalid_address: "Not an address: four numbers from 0 to 255, then /prefix",
    invalid_prefix: "The prefix goes from 8 to 30",
    reserved_address: "A reserved address: loopback, link-local or multicast",
    not_a_host: "That is the network's own address or its broadcast address",
    overlaps: "Another network of the NanoKVM's, such as the Wi-Fi, uses those addresses"
  }

  attr :network, :map, required: true
  attr :rates, :map, default: %{}
  attr :usb, :map, required: true
  attr :mac_form, :map, default: nil
  attr :ip_form, :map, default: nil

  def network_card(assigns) do
    interfaces =
      assigns.network
      |> Enum.sort_by(fn {name, _i} -> {name != "wlan0", name} end)
      |> Enum.map(fn {name, i} ->
        {label, icon} = Map.get(@kinds, i.kind, {name, "hero-globe-alt"})

        %{
          name: name,
          label: label,
          icon: icon,
          connection: i.connection,
          rows: interface_rows(i, assigns.rates[name]),
          setup: i.kind == :wifi and online_kind(i.connection) != :ok
        }
      end)

    assigns = assign(assigns, interfaces: interfaces)

    ~H"""
    <.card id="network" title="Network" icon="hero-globe-alt">
      <div class="space-y-3">
        <div :for={i <- @interfaces} class="rounded-field bg-base-200/70 p-3">
          <div class="mb-2 flex items-center gap-2 text-sm">
            <.icon name={i.icon} class="size-4 text-base-content/60" />
            <b class="font-semibold">{i.label}</b>
            <span class="font-mono text-xs text-base-content/50">{i.name}</span>
            <span class="ml-auto"><.badge kind={online_kind(i.connection)}>
              {online_text(i.connection)}
            </.badge></span>
          </div>
          <.facts rows={i.rows} />
          <a :if={i.setup} href="/settings#wifi" class="btn btn-primary btn-sm mt-3">Set up Wi-Fi</a>
        </div>
        <p :if={@interfaces == []} class="text-sm text-base-content/60">No network interfaces.</p>
      </div>

      <div class="mt-5 border-t border-base-300/60 pt-4">
        <div class="mb-2 flex items-center justify-between">
          <h3 class="text-sm font-semibold">USB network MAC addresses</h3>
          <.button size={:sm} phx-click="network:mac_edit" disabled={!@usb.network}>Change…</.button>
        </div>
        <%= if @usb.network do %>
          <.facts rows={[
            {"NanoKVM", mac_value(@usb.network, :device_address)},
            {"Target computer", mac_value(@usb.network, :host_address)}
          ]} />
        <% else %>
          <p class="text-sm text-base-content/60">Unknown: the USB functions are not running.</p>
        <% end %>
        <p class="mt-2 text-xs text-base-content/55">
          The target computer keeps one network adapter for the NanoKVM as long as these stay the same, restart
          after restart.
        </p>
      </div>

      <div class="mt-5 border-t border-base-300/60 pt-4">
        <div class="mb-2 flex items-center justify-between">
          <h3 class="text-sm font-semibold">USB network addresses</h3>
          <.button size={:sm} phx-click="network:ip_edit" disabled={!@usb.addresses}>Change…</.button>
        </div>
        <.facts
          :if={@usb.addresses}
          rows={[
            {"NanoKVM", @usb.addresses.address || "–"},
            {"Computer", @usb.addresses.computer || "–"},
            {"Set by",
             if(@usb.addresses.default, do: "Default, from the NanoKVM's name", else: "You")}
          ]}
        />
        <p class="mt-2 text-xs text-base-content/55">
          By default the NanoKVM takes a /30 in 172.31.0.0/16, made from its name. Choose other addresses where
          those are taken on the computer's networks.
        </p>
      </div>

      <.modal
        :if={@mac_form}
        id="mac-dialog"
        title="USB network MAC addresses"
        cancel="network:mac_cancel"
      >
        <form
          id="mac-form"
          phx-change="network:mac_check"
          phx-submit="network:mac_apply"
          class="space-y-3"
        >
          <p class="text-sm text-base-content/70">
            Leave a field empty for the default, which comes from the NanoKVM's serial number.
          </p>
          <.mac_field name="device_address" label="NanoKVM" sub="its end, usb0" form={@mac_form} />
          <.mac_field
            name="host_address"
            label="Target computer"
            sub="the network adapter it sees"
            form={@mac_form}
          />
          <div class="flex gap-2 rounded-field bg-warning/12 p-3 text-xs">
            <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning" />
            <p>
              The target computer sees the NanoKVM's USB devices unplugged and plugged in again. This page reconnects
              by itself.{if Enum.any?(@usb[:media] || []),
                do: " Eject the virtual disk on the target computer first."}
            </p>
          </div>
          <p :if={@mac_form.error} class="text-sm text-error">{@mac_form.error}</p>
          <div class="flex gap-2 pt-1">
            <.button type="button" phx-click="network:mac_defaults">Use defaults</.button>
            <span class="flex-1" />
            <.button type="button" phx-click="network:mac_cancel">Cancel</.button>
            <.button type="submit" kind={:primary} disabled={!@mac_form.valid}>Apply</.button>
          </div>
        </form>
      </.modal>

      <.modal :if={@ip_form} id="ip-dialog" title="USB network addresses" cancel="network:ip_cancel">
        <form
          id="ip-form"
          phx-change="network:ip_check"
          phx-submit="network:ip_apply"
          class="space-y-3"
        >
          <p class="text-sm text-base-content/70">
            The NanoKVM's address and prefix, such as 10.55.0.1/24: the computer gets the next one. Empty for the
            default.
          </p>
          <input
            type="text"
            name="address"
            value={@ip_form.text}
            placeholder="172.31.x.y/30"
            spellcheck="false"
            autocomplete="off"
            class="input w-full font-mono"
            phx-debounce="150"
          />
          <p class="text-xs text-base-content/60">{@ip_form.hint}</p>
          <p :if={@ip_form.error} class="text-sm text-error">{@ip_form.error}</p>
          <div class="flex gap-2 pt-1">
            <.button type="button" phx-click="network:ip_defaults">Use the default</.button>
            <span class="flex-1" />
            <.button type="button" phx-click="network:ip_cancel">Cancel</.button>
            <.button type="submit" kind={:primary}>Apply</.button>
          </div>
        </form>
      </.modal>
    </.card>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :sub, :string, required: true
  attr :form, :map, required: true

  defp mac_field(assigns) do
    assigns =
      assign(assigns,
        value: assigns.form.values[assigns.name],
        hint: assigns.form.hints[assigns.name]
      )

    ~H"""
    <label class="block">
      <span class="text-sm">{@label} <i class="text-base-content/50">({@sub})</i></span>
      <input
        type="text"
        name={@name}
        value={@value}
        placeholder={@form.defaults[@name] || "02:12:34:56:78:9a"}
        maxlength="17"
        spellcheck="false"
        autocomplete="off"
        class={["input mt-1 w-full font-mono", elem(@hint, 0) == :error && "input-error"]}
      />
      <span class={[
        "mt-1 block text-xs",
        if(elem(@hint, 0) == :error, do: "text-error", else: "text-base-content/55")
      ]}>
        {elem(@hint, 1)}
      </span>
    </label>
    """
  end

  defp online_kind(c) when c in [:internet, :lan], do: :ok
  defp online_kind(_c), do: nil

  defp online_text(:internet), do: "Internet"
  defp online_text(:lan), do: "Local"
  defp online_text(:disconnected), do: "Disconnected"
  defp online_text(nil), do: "–"
  defp online_text(other), do: to_string(other)

  defp interface_rows(i, rate) do
    ap = i[:wifi]

    [
      {"Wi-Fi", ap && (ap[:ssid] || "hidden network")},
      {"Signal",
       ap && ap[:signal_dbm] &&
         "#{ap.signal_dbm} dBm (#{ap[:signal_percent]}%)#{if ap[:band], do: ", #{ap.band}, channel #{ap[:channel]}"}"},
      {"Link",
       ap && ap[:link_speed] && "#{ap.link_speed} Mb/s#{if ap[:width], do: ", #{ap.width}"}"},
      {"Addresses", if(i.addresses == [], do: "none", else: Enum.join(i.addresses, ", "))},
      {"MAC", i[:mac]},
      {"Traffic", rate && "↓ #{Format.rate(rate.down)}  ↑ #{Format.rate(rate.up)}"}
    ]
  end

  defp mac_value(network, key) do
    value = network[key]
    default = get_in(network, [:default_addresses, key])
    "#{value}, #{if value == default, do: "default", else: "custom"}"
  end

  # Events

  def event("mac_edit", _params, socket) do
    network = socket.assigns.status.usb.network

    defaults =
      Map.new(
        [:device_address, :host_address],
        &{to_string(&1), get_in(network, [:default_addresses, &1])}
      )

    values =
      Map.new([:device_address, :host_address], fn key ->
        value = network[key]
        {to_string(key), if(value == defaults[to_string(key)], do: "", else: value)}
      end)

    {:noreply, assign(socket, mac_form: check_macs(values, defaults, values))}
  end

  def event("mac_check", params, socket) do
    form = socket.assigns.mac_form

    {:noreply,
     assign(socket,
       mac_form:
         check_macs(
           Map.take(params, ["device_address", "host_address"]),
           form.defaults,
           form.initial
         )
     )}
  end

  def event("mac_defaults", _params, socket) do
    form = socket.assigns.mac_form

    {:noreply,
     assign(socket,
       mac_form:
         check_macs(%{"device_address" => "", "host_address" => ""}, form.defaults, form.initial)
     )}
  end

  def event("mac_cancel", _params, socket), do: {:noreply, assign(socket, mac_form: nil)}

  def event("mac_apply", params, socket) do
    form =
      check_macs(
        Map.take(params, ["device_address", "host_address"]),
        socket.assigns.mac_form.defaults,
        socket.assigns.mac_form.initial
      )

    server = Application.get_env(:kuroneko, :usb_server, Kuroneko.Gadget)

    settings =
      for key <- [:device_address, :host_address] do
        text = String.trim(form.values[to_string(key)] || "")
        {key, if(text == "", do: :default, else: text)}
      end

    with true <- form.valid,
         :ok <- Kuroneko.Gadget.validate_network_addresses(server, settings) do
      # The page may come over this network: the reply first.
      Task.start(fn -> Kuroneko.Gadget.set_network_addresses(server, settings) end)

      {:noreply,
       socket
       |> assign(mac_form: nil)
       |> put_flash(:info, "Changing the addresses: the USB devices reconnect")}
    else
      false ->
        {:noreply, assign(socket, mac_form: form)}

      {:error, {reason, _field, _value}} ->
        {:noreply, assign(socket, mac_form: %{form | error: @mac_errors[reason]})}

      {:error, reason} ->
        {:noreply,
         assign(socket, mac_form: %{form | error: @mac_errors[reason] || inspect(reason)})}
    end
  end

  def event("ip_edit", _params, socket) do
    a = socket.assigns.status.usb.addresses
    {:noreply, assign(socket, ip_form: ip_form(if(a.default, do: "", else: a.address)))}
  end

  def event("ip_check", %{"address" => text}, socket),
    do: {:noreply, assign(socket, ip_form: ip_form(text))}

  def event("ip_defaults", _params, socket), do: {:noreply, assign(socket, ip_form: ip_form(""))}
  def event("ip_cancel", _params, socket), do: {:noreply, assign(socket, ip_form: nil)}

  def event("ip_apply", %{"address" => text}, socket) do
    text = String.trim(text)
    address = if text == "", do: nil, else: text
    usb_network = Application.get_env(:kuroneko, :usb_network, Kuroneko.USBNetwork)

    case usb_network.check(address) do
      :ok ->
        Task.start(fn -> usb_network.set(address) end)

        {:noreply,
         socket
         |> assign(ip_form: nil)
         |> put_flash(
           :info,
           if(address,
             do: "The NanoKVM moves to #{address} on the USB network",
             else: "The USB network goes back to its default addresses"
           )
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, ip_form: %{ip_form(text) | error: @ip_errors[reason] || inspect(reason)})}
    end
  end

  defp check_macs(values, defaults, initial) do
    hints =
      Map.new(values, fn {key, text} ->
        {key, mac_hint(String.trim(text || ""), defaults[key])}
      end)

    wanted = Map.new(hints, fn {key, {_kind, _text, mac}} -> {key, mac} end)
    same = wanted["device_address"] && wanted["device_address"] == wanted["host_address"]

    hints =
      if same,
        do:
          Map.put(
            hints,
            "host_address",
            {:error, "The NanoKVM's end has this address: each end needs an address of its own",
             nil}
          ),
        else: hints

    valid =
      Enum.all?(hints, fn {_key, {kind, _text, _mac}} -> kind != :error end) and values != initial

    %{
      values: values,
      defaults: defaults,
      initial: initial,
      hints: Map.new(hints, fn {key, {kind, text, _mac}} -> {key, {kind, text}} end),
      valid: valid,
      error: nil
    }
  end

  defp mac_hint("", nil), do: {:error, @mac_errors.no_default_addresses, nil}
  defp mac_hint("", default), do: {:ok, "The default", default}

  defp mac_hint(text, default) do
    mac = text |> String.downcase() |> String.replace("-", ":")
    {first, _} = Integer.parse(String.slice(mac, 0, 2), 16)

    cond do
      not Regex.match?(@mac, text) -> {:error, "Six bytes in hex, such as 02:12:34:56:78:9a", nil}
      Bitwise.band(first, 1) == 1 -> {:error, @mac_errors.multicast_address, nil}
      mac == "00:00:00:00:00:00" -> {:error, "No device can have this address", nil}
      mac == default -> {:ok, "The default, as it is", mac}
      default -> {:ok, "The default is #{default}", mac}
      true -> {:ok, "", mac}
    end
  rescue
    _ -> {:error, "Six bytes in hex, such as 02:12:34:56:78:9a", nil}
  end

  defp ip_form(text) do
    hint =
      case {String.trim(text), next_address(String.trim(text))} do
        {"", _} -> "The default"
        {_, nil} -> ""
        {_, peer} -> "The computer: #{peer}"
      end

    %{text: text, hint: hint, error: nil}
  end

  # The computer's address as the NanoKVM will give it, while typing.
  defp next_address(text) do
    with [_, a, b, c, d | prefix] <- Regex.run(~r/^(\d+)\.(\d+)\.(\d+)\.(\d+)(?:\/(\d+))?$/, text),
         parts = Enum.map([a, b, c, d], &String.to_integer/1),
         prefix = if(prefix in [[], [""]], do: 24, else: String.to_integer(hd(prefix))),
         true <- Enum.all?(parts, &(&1 <= 255)) and prefix in 8..30 do
      n = Enum.reduce(parts, 0, &(&2 * 256 + &1))
      size = Integer.pow(2, 32 - prefix)
      base = n - rem(n, size)
      last = base + size - 1

      if n in [base, last] do
        nil
      else
        peer = if n + 1 < last, do: n + 1, else: n - 1
        Enum.map_join([24, 16, 8, 0], ".", &(peer |> Bitwise.bsr(&1) |> Bitwise.band(255)))
      end
    else
      _ -> nil
    end
  end
end
