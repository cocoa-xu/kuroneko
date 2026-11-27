defmodule KuronekoWeb.DeviceLive do
  @moduledoc """
  The device page: the NanoKVM's hardware, state and settings, live. Each
  metrics sample brings the state anew, as `Kuroneko.DeviceInfo.status/0`
  has it; Bluetooth's events bring it at once.
  """

  use KuronekoWeb, :live_view

  import KuronekoWeb.DeviceLive.{
    Bluetooth,
    Expansion,
    Metrics,
    Network,
    Overview,
    Screen,
    System,
    USB,
    Video
  }

  alias Kuroneko.{DeviceInfo, Subscription}
  alias KuronekoWeb.DeviceLive.USB
  alias NanoKVMGo.Metrics

  @status_ms 1_000
  @storage_every 30

  @impl true
  def mount(_params, _session, socket) do
    overview = DeviceInfo.overview()
    usb = USB.config()

    socket =
      assign(socket,
        page_title: overview.hostname,
        overview: overview,
        status: overview.status,
        metrics: overview.metrics.current,
        history: overview.metrics.history,
        storage: overview.storage,
        samples: 0,
        restarting: false,
        screen_custom: false,
        mac_form: nil,
        ip_form: nil,
        encoding: KuronekoWeb.DeviceLive.Video.encoding(),
        usb_config: usb,
        usb_draft: usb.settings,
        usb_busy: false,
        usb_error: nil,
        disk_dialog: nil
      )
      |> USB.refresh_drives()

    {:ok, if(connected?(socket), do: subscribe(socket), else: socket)}
  end

  defp subscribe(socket) do
    case Subscription.subscribe(Metrics, &subscribe_metrics/1) do
      {:ok, _monitor, {current, history}} ->
        socket |> assign(metrics: current, history: history) |> subscribe_bluetooth()

      _not_running ->
        Process.send_after(self(), :status, @status_ms)
        subscribe_bluetooth(socket)
    end
  end

  defp subscribe_metrics(metrics) do
    :ok = Metrics.subscribe(metrics)
    {Metrics.current(metrics), Metrics.history(metrics)}
  end

  defp subscribe_bluetooth(socket) do
    if Kuroneko.Bluetooth.status(), do: NanoKVMGo.Bluetooth.subscribe()
    socket
  catch
    :exit, _not_running -> socket
  end

  @impl true
  def handle_info({Metrics, sample}, socket) do
    samples = socket.assigns.samples + 1

    socket =
      socket
      |> assign(metrics: sample, samples: samples)
      |> status()
      |> push_event("metrics", chart_sample(sample))

    {:noreply,
     if(rem(samples, @storage_every) == 0,
       do: assign(socket, storage: NanoKVMGo.Hardware.storage()),
       else: socket
     )}
  end

  def handle_info(:status, socket) do
    Process.send_after(self(), :status, @status_ms)
    {:noreply, status(socket)}
  end

  def handle_info({NanoKVMGo.Bluetooth, _event}, socket),
    do: {:noreply, assign(socket, status: DeviceInfo.status())}

  def handle_info({KuronekoWeb.DiskDialog, :closed}, socket),
    do: {:noreply, socket |> assign(disk_dialog: nil) |> USB.refresh_drives()}

  def handle_info({:restart, reboot}, socket) do
    reboot.()
    {:noreply, socket}
  end

  # The metrics stopped: the page shows the state each second without them.
  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, socket) do
    Process.send_after(self(), :status, @status_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_event("keep", _params, socket) do
    validate = Application.get_env(:kuroneko, :validate, &Nerves.Runtime.validate_firmware/0)

    case validate.() do
      :ok -> {:noreply, socket |> assign(status: DeviceInfo.status()) |> put_flash(:info, "Kept")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Not kept: #{inspect(reason)}")}
    end
  end

  def handle_event("restart", _params, socket) do
    reboot = Application.get_env(:kuroneko, :reboot, &Nerves.Runtime.reboot/0)
    # The page's reply first: the restart takes the socket with it.
    Process.send_after(self(), {:restart, reboot}, 300)
    {:noreply, assign(socket, restarting: true)}
  end

  def handle_event("bluetooth:" <> event, params, socket),
    do: KuronekoWeb.DeviceLive.Bluetooth.event(event, params, socket)

  def handle_event("screen:" <> event, params, socket),
    do: KuronekoWeb.DeviceLive.Screen.event(event, params, socket)

  def handle_event("expansion:" <> event, params, socket),
    do: KuronekoWeb.DeviceLive.Expansion.event(event, params, socket)

  def handle_event("video:" <> event, params, socket),
    do: KuronekoWeb.DeviceLive.Video.event(event, params, socket)

  def handle_event("network:" <> event, params, socket),
    do: KuronekoWeb.DeviceLive.Network.event(event, params, socket)

  def handle_event("usb:" <> event, params, socket), do: USB.event(event, params, socket)

  @impl true
  def handle_async(:usb_apply, result, socket), do: USB.applied(result, socket)

  # The state anew, with the drives, and the USB devices when they changed
  # elsewhere.
  defp status(socket) do
    functions = socket.assigns.status.usb.functions

    socket
    |> assign(status: DeviceInfo.status())
    |> USB.follow(functions)
    |> USB.refresh_drives()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.top_bar restarting={@restarting} />
    <main class="mx-auto max-w-6xl space-y-5 px-4 pb-16 pt-20 sm:px-6">
      <.hero overview={@overview} status={@status} metrics={@metrics} />
      <.trial_banner trial={@status.trial} />
      <.tiles metrics={@metrics} history={@history} />

      <div class="columns-1 gap-5 lg:columns-2 [&>*]:mb-5 [&>*]:break-inside-avoid">
        <.screen_card screen={@status.screen} custom={@screen_custom} />
        <.expansion_card expansion={@status.expansion} />
        <.bluetooth_card bluetooth={@status[:bluetooth]} />
        <.video_card video={@status.video} components={@overview.components} encoding={@encoding} />
        <.network_card
          network={@status.network}
          rates={(@metrics && @metrics.network) || %{}}
          usb={@status.usb}
          mac_form={@mac_form}
          ip_form={@ip_form}
        />
        <.firmware_card firmware={@overview.firmware} trial={@status.trial} />
        <.software_card overview={@overview} beam={@status.beam} />
      </div>

      <.usb_card
        usb={@status.usb}
        config={@usb_config}
        draft={@usb_draft}
        busy={@usb_busy}
        error={@usb_error}
        disk={@disk}
      />
      <.storage_card storage={@storage} />
      <.hardware_card components={@overview.components} />
    </main>
    <.live_component
      module={KuronekoWeb.DiskDialog}
      id="disk"
      open={@disk_dialog != nil}
      drive={@disk_dialog && @disk_dialog.drive}
    />
    <.flash_group flash={@flash} />
    """
  end

  # The newest sample, for the charts the page draws itself.
  defp chart_sample(sample) do
    total =
      Enum.reduce(Map.values(sample.network), %{down: 0, up: 0}, fn n, t ->
        %{down: t.down + n.down, up: t.up + n.up}
      end)

    %{
      cpu: sample.cpu.total,
      memory: sample.memory.percent,
      temperature: sample.temperature,
      down: total.down,
      up: total.up
    }
  end
end
