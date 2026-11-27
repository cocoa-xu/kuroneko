defmodule KuronekoWeb.KVMLive do
  @moduledoc """
  The KVM page: the target's picture, keyboard, mouse and sound, which the
  browser runs (the `KVM` hook, `assets/js/kvm.js`), and the NanoKVM menu,
  rendered here. Its rows open panels of their own in the menu, as Control
  Center's do: the USB devices, the screen, Wi-Fi, Bluetooth and
  Wake-on-LAN, changing a password and restarting.

  While the menu is open the state it shows comes anew with each metrics
  sample; closed, the page asks for nothing.
  """

  use KuronekoWeb, :live_view

  import KuronekoWeb.KVMLive.Menu

  alias Kuroneko.{Subscription, USBSettings}
  alias KuronekoWeb.KVMLive.Menu
  alias NanoKVMGo.Metrics

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "NanoKVM-Go",
        menu: :main,
        menu_open: false,
        status: nil,
        metrics: nil,
        usb: USBSettings.saved(),
        usb_busy: false,
        wifi: nil,
        wifi_join: nil,
        wake_mac: Kuroneko.WakeOnLan.saved_mac(),
        message: nil
      )

    {:ok, if(connected?(socket), do: subscribe(socket), else: socket)}
  end

  defp subscribe(socket) do
    case Subscription.subscribe(Metrics, &subscribe_metrics/1) do
      {:ok, _monitor, current} -> assign(socket, metrics: current)
      _not_running -> socket
    end
  end

  defp subscribe_metrics(metrics) do
    :ok = Metrics.subscribe(metrics)
    Metrics.current(metrics)
  end

  @impl true
  def handle_info({Metrics, sample}, socket) do
    socket = assign(socket, metrics: sample)
    {:noreply, if(socket.assigns.menu_open, do: Menu.refresh(socket), else: socket)}
  end

  def handle_info(:wifi, socket), do: {:noreply, Menu.refresh(socket)}

  def handle_info({:restart, reboot}, socket) do
    reboot.()
    {:noreply, socket}
  end

  # The metrics stopped; the menu shows what it last had.
  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("menu", params, socket) do
    open = Map.get(params, "open", socket.assigns.menu_open)

    socket =
      socket
      |> assign(menu_open: open, message: nil, wifi_join: nil)
      |> then(&if(panel = Menu.panel(params["panel"]), do: assign(&1, menu: panel), else: &1))

    {:noreply, if(open, do: Menu.refresh(socket), else: socket)}
  end

  def handle_event("screen:" <> event, params, socket),
    do: KuronekoWeb.DeviceLive.Screen.event(event, params, socket)

  def handle_event("bluetooth:" <> event, params, socket),
    do: KuronekoWeb.DeviceLive.Bluetooth.event(event, params, socket)

  def handle_event(event, params, socket), do: Menu.event(event, params, socket)

  @impl true
  def handle_async(:usb, result, socket), do: Menu.usb_applied(result, socket)
end
