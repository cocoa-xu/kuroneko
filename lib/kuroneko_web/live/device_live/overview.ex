defmodule KuronekoWeb.DeviceLive.Overview do
  @moduledoc false
  # The page's bar, its title with the state in chips, and the trial's banner.

  use KuronekoWeb, :html

  alias KuronekoWeb.Format

  attr :restarting, :boolean, required: true

  def top_bar(assigns) do
    ~H"""
    <header class="glass fixed inset-x-0 top-0 z-40 border-b border-base-content/10">
      <div class="mx-auto flex h-14 max-w-6xl items-center gap-3 px-4 sm:px-6">
        <a href="/" class="flex items-center gap-2.5 font-semibold">
          <span class="grid size-7 place-items-center rounded-lg bg-primary text-primary-content">
            <.icon name="hero-computer-desktop-mini" class="size-4" />
          </span>
          <span class="hidden sm:inline">NanoKVM-Go</span>
        </a>
        <nav
          class="ml-2 flex gap-0.5 rounded-field bg-base-300/70 p-0.5 text-[13px]"
          aria-label="Pages"
        >
          <a
            href="/"
            class="rounded-[calc(var(--radius-field)-2px)] px-3 py-1 text-base-content/70 hover:text-base-content"
          >Remote</a>
          <a
            href="/device"
            aria-current="page"
            class="rounded-[calc(var(--radius-field)-2px)] bg-base-100 px-3 py-1 font-medium shadow-sm"
          >Device</a>
          <a
            href="/settings"
            class="rounded-[calc(var(--radius-field)-2px)] px-3 py-1 text-base-content/70 hover:text-base-content"
          >Settings</a>
        </nav>
        <div class="flex-1" />
        <span class="hidden items-center gap-1.5 text-xs text-base-content/60 phx-connected:inline-flex">
          <span class="size-2 animate-pulse rounded-full bg-success" /> Live
        </span>
        <span class="inline-flex items-center gap-1.5 text-xs text-warning phx-connected:hidden">
          <span class="size-2 rounded-full bg-warning" /> Connecting
        </span>
        <.button
          size={:sm}
          kind={:danger}
          phx-click={JS.show(to: "#restart-dialog")}
          disabled={@restarting}
        >
          <.icon name="hero-power-mini" class="size-4" /> Restart
        </.button>
      </div>
    </header>

    <div
      id="restart-dialog"
      class="fixed inset-0 z-50 hidden"
      role="dialog"
      aria-modal="true"
      aria-labelledby="restart-title"
    >
      <div class="absolute inset-0 bg-black/40" phx-click={JS.hide(to: "#restart-dialog")} />
      <div class="relative mx-auto mt-40 w-[min(26rem,calc(100vw-2rem))] rounded-box bg-base-100 p-6 shadow-2xl">
        <h3 id="restart-title" class="text-lg font-semibold">Restart the NanoKVM?</h3>
        <p class="mt-2 text-sm text-base-content/70">
          Video, keyboard and mouse stop for about 30 seconds. This page reconnects by itself.
        </p>
        <div class="mt-5 flex justify-end gap-2">
          <.button phx-click={JS.hide(to: "#restart-dialog")}>Cancel</.button>
          <.button
            kind={:destructive}
            phx-click={JS.push("restart") |> JS.hide(to: "#restart-dialog")}
          >
            Restart
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :overview, :map, required: true
  attr :status, :map, required: true
  attr :metrics, :map, default: nil

  def hero(assigns) do
    hw = assigns.overview.hardware

    subtitle =
      [
        hw[:model],
        hw[:soc],
        hw[:cpu][:cores] && "#{hw.cpu.cores} × #{hw.cpu[:model] || "CPU"}",
        hw[:memory] && "#{Format.bytes(hw.memory)} memory"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    assigns = assign(assigns, subtitle: subtitle, chips: chips(assigns))

    ~H"""
    <section class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3">
      <div class="min-w-0">
        <h1 class="text-3xl font-semibold tracking-tight">{@overview.hostname}</h1>
        <p class="mt-1 text-sm text-base-content/60">{@subtitle}</p>
      </div>
      <div class="flex flex-wrap gap-2" aria-live="polite">
        <span
          :for={{icon, kind, label, value} <- @chips}
          class="inline-flex items-center gap-1.5 rounded-full bg-base-100 px-3 py-1.5 text-xs shadow-sm"
        >
          <.icon name={icon} class={["size-4", chip_color(kind)]} />
          <span class="text-base-content/60">{label}</span>
          <b class="font-semibold tabular-nums">{value}</b>
        </span>
      </div>
    </section>
    """
  end

  defp chips(%{overview: overview, status: status, metrics: metrics}) do
    input = status.video.input

    wifi =
      status.network
      |> Map.values()
      |> Enum.find(&(&1.kind == :wifi))

    running = Enum.find(overview.firmware.slots, & &1.active)

    [
      {"hero-tv",
       if(is_map(input), do: :ok, else: if(input in [:unsupported, "unsupported"], do: :bad)),
       "HDMI", Format.input(input)},
      usb_chip(status.usb.connection),
      wifi_chip(wifi),
      bluetooth_chip(status[:bluetooth]),
      metrics && {"hero-clock", nil, "Up", Format.duration(metrics.uptime)},
      running &&
        {"hero-cube", if(status.trial.validated, do: nil, else: :warn), "Firmware",
         running.version || "?"}
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp usb_chip(connection) do
    {text, kind} = Format.usb_state(connection)
    {"hero-bolt", kind, "Target", text}
  end

  defp wifi_chip(nil), do: nil

  defp wifi_chip(%{wifi: %{signal_dbm: dbm}}) when is_number(dbm),
    do: {"hero-wifi", Format.signal(dbm), "Wi-Fi", "#{dbm} dBm"}

  defp wifi_chip(%{connection: connection}) do
    up = connection in [:internet, :lan]

    {"hero-wifi", if(up, do: :ok, else: :warn), "Wi-Fi",
     if(up, do: "connected", else: "not connected")}
  end

  defp bluetooth_chip(nil), do: nil

  defp bluetooth_chip(bt) do
    {"hero-signal", if(bt.host, do: :ok), "Bluetooth",
     cond do
       bt.host -> "host connected"
       bt.pairing -> "pairing"
       true -> "on"
     end}
  end

  defp chip_color(:ok), do: "text-success"
  defp chip_color(:warn), do: "text-warning"
  defp chip_color(:bad), do: "text-error"
  defp chip_color(_), do: "text-base-content/50"

  attr :trial, :map, required: true

  def trial_banner(assigns) do
    trial = assigns.trial
    firmware = !trial.validated
    memory = trial.memory

    assigns =
      assign(assigns,
        show: firmware or memory != nil,
        text: trial_text(firmware, memory, trial.revert_in),
        button:
          cond do
            firmware and memory -> "Keep both"
            firmware -> "Keep this firmware"
            true -> "Keep these sizes"
          end
      )

    ~H"""
    <div
      :if={@show}
      class="flex items-center gap-3 rounded-box bg-warning/12 px-4 py-3 text-sm"
      role="status"
    >
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-warning" />
      <p class="flex-1">{@text}</p>
      <.button size={:sm} kind={:primary} phx-click="keep">{@button}</.button>
    </div>
    """
  end

  defp trial_text(firmware, memory, revert_in) do
    when_ =
      if revert_in do
        left = div(revert_in + 999, 1000)

        "in #{div(left, 60)}:#{left |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
      else
        "after the next restart"
      end

    sizes =
      memory &&
        "memory sizes (video #{mib(memory.video)}, NPU #{mib(memory.npu)})"

    {what, one} =
      cond do
        firmware and memory -> {"This firmware and the #{sizes} are", false}
        firmware -> {"This firmware is", true}
        true -> {"The #{sizes} are", false}
      end

    "#{what} on trial: the NanoKVM goes back to the previous #{if one, do: "one", else: "ones"} #{when_} unless you keep #{if one, do: "it", else: "them"}."
  end

  defp mib(:default), do: "default"
  defp mib("default"), do: "default"
  defp mib(size), do: "#{size} MiB"
end
