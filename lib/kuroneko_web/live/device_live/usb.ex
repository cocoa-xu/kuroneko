defmodule KuronekoWeb.DeviceLive.USB do
  @moduledoc false
  # USB to the target: the link, the devices it sees, the endpoints they take
  # and the virtual disk's drives. The devices are edited as a draft and
  # applied together, since applying reconnects them; the jiggler applies at
  # once, as it changes no device.

  use KuronekoWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]

  alias Kuroneko.USBSettings
  alias KuronekoWeb.{DiskDialog, Format}

  @pointers [
    {"absolute", "Absolute mouse"},
    {"stylus", "Pen (Android, iPad)"},
    {"touch", "Touch screen"}
  ]
  @pointer_names %{"absolute" => "Absolute mouse", "stylus" => "Pen", "touch" => "Touch screen"}
  @colors %{
    network: "#30d158",
    keyboard: "#0a84ff",
    mouse: "#64d2ff",
    relative_mouse: "#5e5ce6",
    storage: "#ff9f0a",
    microphone: "#ff6482",
    speaker: "#bf5af2"
  }
  @kinds Map.keys(@colors)
  @rates [
    8000,
    11_025,
    16_000,
    22_050,
    32_000,
    44_100,
    48_000,
    88_200,
    96_000,
    176_400,
    192_000,
    352_800,
    384_000
  ]
  @channels %{"microphone" => [1, 2], "speaker" => [1, 2, 6, 8]}
  @channel_names %{1 => "Mono", 2 => "Stereo", 6 => "5.1", 8 => "7.1"}
  @sample_bits [16, 24, 32]
  @sample_formats %{s16_le: 16, s24_3le: 24, s24_le: 24, s32_le: 32}
  @invalid %{
    "networks" =>
      ~s(Give each network its own name, not usb0, of up to 32 letters, digits, "-" and "_". Up to 4 networks.),
    "storages" =>
      ~s(Give each storage device its own name, not disk, of up to 32 letters, digits, "-" and "_". Up to 4 storage devices.)
  }

  @doc "What the card edits from: the saved settings, the devices there are, their endpoints, the formats in use."
  def config do
    settings = USBSettings.saved()

    %{
      settings: settings,
      instances: safely(&Kuroneko.Gadget.instances/0) || [],
      have: USBSettings.endpoints(settings).have,
      costs:
        Map.new(@kinds, fn kind ->
          {kind, kind |> List.wrap() |> Kuroneko.Gadget.endpoints() |> elem(1)}
        end),
      formats: %{
        "microphone" => safely(&NanoKVMGo.Microphone.format/0),
        "speaker" => safely(fn -> NanoKVMGo.Audio.format(Kuroneko.Speaker) end)
      }
    }
  end

  defp safely(call) do
    call.()
  catch
    :exit, _not_running -> nil
  end

  attr :usb, :map, required: true
  attr :config, :map, required: true
  attr :draft, :map, required: true
  attr :busy, :boolean, required: true
  attr :error, :string, default: nil
  attr :disk, :map, default: nil

  def usb_card(assigns) do
    %{config: config, draft: draft, usb: usb} = assigns
    devices = devices(draft, config.costs)
    {bars, fits} = bars(devices, config.have)
    {state, kind} = Format.usb_state(usb.connection)
    c = usb.connection

    assigns =
      assign(assigns,
        state: state,
        kind: kind,
        link: [
          {"Link",
           cond do
             c == nil -> "The USB controller is not bound"
             to_string(c.state) == "configured" -> Format.usb_speed(c[:speed])
             true -> state
           end},
          {"Controller", c && c[:controller]}
        ],
        devices: devices,
        bars: bars,
        fits: fits,
        dirty: draft != config.settings,
        jiggler: config.settings["jiggler"],
        hid_saved: config.settings["hid"]
      )

    ~H"""
    <.card id="usb" title="USB to the target" icon="hero-bolt">
      <:actions>
        <.badge kind={@kind}>{@state}</.badge>
      </:actions>

      <.facts rows={@link} />

      <section class="mt-5 border-t border-base-300/60 pt-4" aria-label="Devices">
        <h3 class="mb-1 text-sm font-semibold">Devices</h3>
        <.row label="Keyboard and mice" detail="A keyboard, the pointer chosen and a relative mouse">
          <form id="usb-pointer" phx-change="usb:pointer">
            <select
              name="pointer"
              class="select select-sm w-40"
              disabled={!@draft["hid"]}
              aria-label="The pointer"
            >
              <option
                :for={{value, label} <- pointers()}
                value={value}
                selected={value == @draft["pointer"]}
              >
                {label}
              </option>
            </select>
          </form>
          <.switch
            checked={@draft["hid"]}
            event="usb:toggle"
            phx-value-key="hid"
            label="Keyboard and mice"
          />
        </.row>
        <.row
          label="Mouse jiggler"
          detail="A pixel and back each minute, so that the target stays awake"
          class="pl-5"
        >
          <.switch
            checked={@jiggler}
            event="usb:jiggler"
            label="Mouse jiggler"
            disabled={!@hid_saved or !@draft["hid"]}
          />
        </.row>

        <.row label="Network" detail="usb0, the NanoKVM's own">
          <.switch
            checked={@draft["network"]}
            event="usb:toggle"
            phx-value-key="network"
            label="Network usb0"
          />
        </.row>
        <div
          :for={{name, i} <- Enum.with_index(@draft["networks"])}
          class="flex items-center gap-2 pb-2 pl-5"
        >
          <form
            id={"usb-network-#{i}"}
            phx-change="usb:network_name"
            class="flex min-w-0 flex-1 items-center gap-2"
          >
            <input type="hidden" name="index" value={i} />
            <input
              type="text"
              name="name"
              value={name}
              maxlength="32"
              spellcheck="false"
              autocomplete="off"
              phx-debounce="300"
              class="input input-sm w-36"
              aria-label="The network's name"
            />
            <span :if={interface(@config, name)} class="truncate text-xs text-base-content/55">
              interface {interface(@config, name)}
            </span>
          </form>
          <.button size={:sm} kind={:danger} phx-click="usb:remove_network" phx-value-index={i}>Remove</.button>
        </div>
        <div class="pb-3 pl-5">
          <.button size={:sm} phx-click="usb:add_network" disabled={length(@draft["networks"]) >= 4}>
            <.icon name="hero-plus-mini" class="size-4" /> Add a network
          </.button>
        </div>

        <.row label="Virtual disk" detail="Its drives, each a LUN">
          <form id="usb-drives" phx-change="usb:drives">
            <select
              name="drives"
              class="select select-sm w-20"
              disabled={!@draft["storage"]}
              aria-label="Drives"
            >
              <option :for={n <- 1..16} value={n} selected={n == @draft["drives"]}>{n}</option>
            </select>
          </form>
          <.switch
            checked={@draft["storage"]}
            event="usb:toggle"
            phx-value-key="storage"
            label="Virtual disk"
          />
        </.row>
        <div
          :for={{storage, i} <- Enum.with_index(@draft["storages"])}
          class="flex items-center gap-2 pb-2 pl-5"
        >
          <form
            id={"usb-storage-#{i}"}
            phx-change="usb:storage"
            class="flex min-w-0 flex-1 items-center gap-2"
          >
            <input type="hidden" name="index" value={i} />
            <input
              type="text"
              name="name"
              value={storage["name"]}
              maxlength="32"
              spellcheck="false"
              autocomplete="off"
              phx-debounce="300"
              class="input input-sm w-36"
              aria-label="The storage device's name"
            />
            <select name="drives" class="select select-sm w-20" aria-label="Its drives">
              <option :for={n <- 1..16} value={n} selected={n == storage["drives"]}>{n}</option>
            </select>
          </form>
          <.button size={:sm} kind={:danger} phx-click="usb:remove_storage" phx-value-index={i}>Remove</.button>
        </div>
        <div class="pb-3 pl-5">
          <.button size={:sm} phx-click="usb:add_storage" disabled={length(@draft["storages"]) >= 4}>
            <.icon name="hero-plus-mini" class="size-4" /> Add a storage device
          </.button>
        </div>

        <.row label="Sound card">
          <.segmented
            label="Sound card"
            event="usb:audio"
            value={@draft["audio"]}
            options={[{"off", "Off"}, {"mic", "Mic"}, {"duplex", "Mic and speaker"}]}
          />
        </.row>
        <.audio_format
          :for={direction <- directions(@draft["audio"])}
          direction={direction}
          format={@draft[direction]}
          using={@config.formats[direction]}
        />
      </section>

      <section class="mt-5 border-t border-base-300/60 pt-4" aria-label="Endpoints">
        <div class="mb-3 flex flex-wrap items-baseline justify-between gap-x-3">
          <h3 class="text-sm font-semibold">Endpoints</h3>
          <span :if={!@fits} class="text-xs font-medium text-error">
            Too many: turn something off or remove it.
          </span>
        </div>
        <div class="space-y-2.5">
          <div :for={bar <- @bars} class="flex items-center gap-3">
            <span class="w-8 text-xs font-medium text-base-content/55">{bar.label}</span>
            <div
              class="grid h-2.5 flex-1 gap-0.5 overflow-hidden rounded-full bg-base-300"
              style={"grid-template-columns: repeat(#{bar.columns}, minmax(0, 1fr))"}
            >
              <div
                :for={cell <- bar.cells}
                title={cell.title}
                class={cell.over && "opacity-60"}
                style={cell_style(cell)}
              />
            </div>
            <span class={[
              "w-12 text-right text-xs tabular-nums",
              if(bar.over, do: "font-semibold text-error", else: "text-base-content/60")
            ]}>
              {bar.count}
            </span>
          </div>
        </div>
        <ul id="usb-legend" class="mt-4 flex flex-wrap gap-x-6 gap-y-1.5 text-xs">
          <li :for={device <- @devices} class="flex items-center gap-2">
            <span class="size-2.5 shrink-0 rounded-full" style={"background: #{color(device.kind)}"} />
            <span class="font-medium">{device.name}</span>
            <span class="text-base-content/50">{cost_text(device.cost)}</span>
          </li>
        </ul>
        <p class="mt-3 text-xs text-base-content/55">
          Each device takes some of the USB controller's endpoints, besides endpoint 0: a network two IN and
          one OUT, the keyboard and each mouse one IN, a storage device one of each however many drives it
          has, the microphone one IN, the speaker one OUT. The bars count the devices above, changes
          included.
        </p>
      </section>

      <section class="mt-5 border-t border-base-300/60 pt-4" aria-label="Drives">
        <div class="mb-2 flex items-center justify-between">
          <h3 class="text-sm font-semibold">Drives</h3>
          <.button size={:sm} phx-click="usb:disk">Virtual disk…</.button>
        </div>
        <.drives disk={@disk} />
      </section>

      <div
        :if={@dirty or @error}
        class="glass sticky bottom-4 z-10 mt-5 flex flex-wrap items-center gap-3 rounded-box p-3 shadow-lg ring-1 ring-base-content/10"
      >
        <p class="min-w-0 flex-1 basis-56 text-xs text-base-content/70">
          Applying reconnects the NanoKVM's USB devices on the target: the keyboard and mice go away for a
          moment.
        </p>
        <.button size={:sm} phx-click="usb:revert" disabled={!@dirty or @busy}>Revert</.button>
        <.button
          size={:sm}
          kind={:primary}
          phx-click="usb:apply"
          disabled={!@dirty or !@fits or @busy}
        >
          {if @busy, do: "Applying…", else: "Apply"}
        </.button>
        <p :if={@error} class="basis-full text-sm text-error">{@error}</p>
      </div>
    </.card>
    """
  end

  attr :direction, :string, required: true
  attr :format, :map, required: true
  attr :using, :map, default: nil

  defp audio_format(assigns) do
    assigns =
      assign(assigns, rates: @rates, channels: @channels[assigns.direction], bits: @sample_bits)

    ~H"""
    <div class="mb-3 ml-5 rounded-field bg-base-200/60 p-3">
      <div class="mb-2 flex flex-wrap items-baseline gap-x-2 text-sm">
        <b class="font-semibold">{if @direction == "microphone", do: "Microphone", else: "Speaker"}</b>
        <span class="text-xs text-base-content/55">
          {if @direction == "microphone",
            do: "the browser's, to the target",
            else: "the target's, to the browser"}
        </span>
      </div>
      <form id={"usb-format-#{@direction}"} phx-change="usb:format" class="space-y-2.5">
        <input type="hidden" name="direction" value={@direction} />
        <div class="flex flex-wrap gap-x-4 gap-y-2 text-xs">
          <label class="flex items-center gap-1.5">
            Channels
            <select name="channels" class="select select-xs w-24">
              <option :for={n <- @channels} value={n} selected={n == @format["channels"]}>
                {channel_name(n)}
              </option>
            </select>
          </label>
          <label class="flex items-center gap-1.5">
            Samples
            <select name="sample_bits" class="select select-xs w-20">
              <option :for={b <- @bits} value={b} selected={b == @format["sample_bits"]}>
                {b}-bit
              </option>
            </select>
          </label>
          <label class="flex items-center gap-1.5">
            Starts at
            <select name="start" class="select select-xs w-28" disabled={length(@format["rates"]) < 2}>
              <option
                :for={rate <- @format["rates"]}
                value={rate}
                selected={rate == hd(@format["rates"])}
              >
                {khz(rate)}
              </option>
            </select>
          </label>
        </div>
        <div class="flex flex-wrap gap-1.5">
          <input type="hidden" name="rates[]" value="" />
          <label
            :for={rate <- @rates}
            class="cursor-pointer select-none rounded-selector px-2 py-0.5 text-xs ring-1 ring-base-content/15 transition has-checked:bg-primary has-checked:text-primary-content has-checked:ring-primary"
          >
            <input
              type="checkbox"
              name="rates[]"
              value={rate}
              checked={rate in @format["rates"]}
              class="sr-only"
            />
            {khz(rate)}
          </label>
        </div>
      </form>
      <p :if={@using} class="mt-2 text-xs text-base-content/55">
        The target uses {describe_format(@using)}.
      </p>
    </div>
    """
  end

  attr :disk, :map, default: nil

  defp drives(%{disk: nil} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">The virtual disk is not running.</p>
    """
  end

  defp drives(%{disk: %{drives: []}} = assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">No drives: the virtual disk is off.</p>
    """
  end

  defp drives(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <div
        :for={d <- @disk.drives}
        class="flex items-center gap-3 rounded-field bg-base-200/70 px-3 py-2"
      >
        <.icon
          name={if d.medium, do: "hero-circle-stack-solid", else: "hero-circle-stack"}
          class={["size-5 shrink-0", if(d.medium, do: "text-primary", else: "text-base-content/35")]}
        />
        <div class="min-w-0 flex-1">
          <div class="truncate text-sm font-medium">
            {DiskDialog.drive_name(@disk, d)}{if d.medium, do: ": #{d.medium.name}"}
          </div>
          <div class="truncate text-xs text-base-content/55">{drive_detail(@disk, d)}</div>
        </div>
        <.button
          size={:sm}
          phx-click="usb:disk"
          phx-value-drive={d.drive}
          disabled={@disk.busy != nil}
        >
          {if d.medium, do: "Change…", else: "Insert…"}
        </.button>
        <.button
          :if={d.medium}
          size={:sm}
          phx-click="usb:eject"
          phx-value-drive={d.drive}
          disabled={@disk.busy != nil}
        >
          Eject
        </.button>
      </div>
    </div>
    """
  end

  defp drive_detail(%{busy: %{action: :making, drive: n} = busy}, %{drive: n}) do
    percent =
      if busy[:total] && busy.total > 0, do: " #{div(100 * busy.done, busy.total)}%", else: ""

    "Making a drive from #{busy.name}:#{percent}"
  end

  defp drive_detail(_disk, %{medium: nil}), do: "Empty"
  defp drive_detail(_disk, %{medium: medium}), do: DiskDialog.describe(medium)

  # What does not fit is striped.
  defp cell_style(cell) do
    style = "grid-column: span #{cell.span}; background-color: #{cell.color}"

    if cell.over,
      do:
        style <>
          "; background-image: repeating-linear-gradient(135deg, transparent 0 3px, rgb(255 255 255 / .7) 3px 5px)",
      else: style
  end

  defp pointers, do: @pointers
  defp color(kind), do: @colors[kind]

  defp interface(config, name) do
    Enum.find_value(config.instances, fn instance ->
      to_string(instance[:kind]) == "network" and instance[:name] == name and instance[:interface]
    end)
  end

  defp directions("mic"), do: ["microphone"]
  defp directions("duplex"), do: ["microphone", "speaker"]
  defp directions(_off), do: []

  defp channel_name(n), do: Map.get(@channel_names, n, "#{n} channels")

  defp khz(rate) when rem(rate, 1000) == 0, do: "#{div(rate, 1000)} kHz"

  defp khz(rate),
    do: "#{rate |> Kernel./(1000) |> Format.decimals(3) |> String.trim_trailing("0")} kHz"

  defp describe_format(format) do
    bits = Map.get(@sample_formats, format[:sample_format], 16)
    "#{khz(format.rate)} #{String.downcase(channel_name(format.channels))} #{bits}-bit"
  end

  defp cost_text(cost) do
    [cost.in > 0 && "#{cost.in} IN", cost.out > 0 && "#{cost.out} OUT"]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  # The devices of settings, in the order the gadget has them, each with
  # the endpoints a device of its kind takes.
  defp devices(d, costs) do
    pointer = Map.get(@pointer_names, d["pointer"], "Absolute mouse")
    drives = fn n -> "#{n} drive#{if n > 1, do: "s"}" end

    Enum.concat([
      if(d["network"], do: [{:network, "Network usb0", "usb0"}], else: []),
      Enum.map(d["networks"], &{:network, "Network #{&1}", &1}),
      if(d["hid"],
        do: [
          {:keyboard, "Keyboard", "Keyboard"},
          {:mouse, pointer, pointer},
          {:relative_mouse, "Relative mouse", "Relative"}
        ],
        else: []
      ),
      if(d["storage"],
        do: [{:storage, "Virtual disk, #{drives.(d["drives"])}", "Disk"}],
        else: []
      ),
      Enum.map(
        d["storages"],
        &{:storage, "Storage #{&1["name"]}, #{drives.(&1["drives"])}", &1["name"]}
      ),
      Enum.map(
        directions(d["audio"]),
        &{String.to_existing_atom(&1), String.capitalize(&1),
         if(&1 == "microphone", do: "Mic", else: "Speaker")}
      )
    ])
    |> Enum.map(fn {kind, name, short} ->
      %{kind: kind, name: name, short: short, cost: costs[kind]}
    end)
  end

  # Each direction's endpoints as a bar, the devices in turn, what does not
  # fit marked; and whether they all fit.
  defp bars(devices, have) do
    use =
      Enum.reduce(
        devices,
        %{in: 0, out: 0},
        &%{in: &2.in + &1.cost.in, out: &2.out + &1.cost.out}
      )

    bars =
      for dir <- [:in, :out] do
        limit = if have, do: have[dir], else: use[dir]

        {cells, taken} =
          Enum.flat_map_reduce(devices, 0, fn device, taken ->
            case device.cost[dir] do
              0 ->
                {[], taken}

              n ->
                cell = %{
                  span: n,
                  over: taken + n > limit,
                  color: @colors[device.kind],
                  short: device.short,
                  title: "#{device.name}: #{n} #{String.upcase(to_string(dir))}"
                }

                {[cell], taken + n}
            end
          end)

        %{
          label: String.upcase(to_string(dir)),
          cells: cells,
          free: max(limit - taken, 0),
          columns: max(max(limit, taken), 1),
          count: if(have, do: "#{use[dir]} of #{have[dir]}", else: "#{use[dir]}"),
          over: have != nil and use[dir] > have[dir]
        }
      end

    {bars, have == nil or (use.in <= have.in and use.out <= have.out)}
  end

  # Events

  def event("toggle", %{"key" => key, "on" => on}, socket) when key in ~w(hid network storage),
    do: draft(socket, &Map.put(&1, key, on == "true"))

  def event("pointer", %{"pointer" => pointer}, socket) when is_map_key(@pointer_names, pointer),
    do: draft(socket, &Map.put(&1, "pointer", pointer))

  def event("drives", %{"drives" => drives}, socket),
    do: draft(socket, &Map.put(&1, "drives", String.to_integer(drives)))

  def event("audio", %{"value" => audio}, socket) when audio in ~w(off mic duplex),
    do: draft(socket, &Map.put(&1, "audio", audio))

  def event("add_network", _params, socket) do
    draft(socket, fn d ->
      Map.update!(d, "networks", &(&1 ++ [free_name("usb", ["usb0" | &1], 1)]))
    end)
  end

  def event("network_name", %{"index" => i, "name" => name}, socket),
    do:
      draft(socket, fn d ->
        Map.update!(d, "networks", &List.replace_at(&1, String.to_integer(i), String.trim(name)))
      end)

  def event("remove_network", %{"index" => i}, socket),
    do:
      draft(socket, fn d ->
        Map.update!(d, "networks", &List.delete_at(&1, String.to_integer(i)))
      end)

  def event("add_storage", _params, socket) do
    draft(socket, fn d ->
      Map.update!(d, "storages", fn storages ->
        name = free_name("disk", ["disk" | Enum.map(storages, & &1["name"])], 2)
        storages ++ [%{"name" => name, "drives" => 1}]
      end)
    end)
  end

  def event("storage", %{"index" => i, "name" => name, "drives" => drives}, socket) do
    storage = %{"name" => String.trim(name), "drives" => String.to_integer(drives)}

    draft(socket, fn d ->
      Map.update!(d, "storages", &List.replace_at(&1, String.to_integer(i), storage))
    end)
  end

  def event("remove_storage", %{"index" => i}, socket),
    do:
      draft(socket, fn d ->
        Map.update!(d, "storages", &List.delete_at(&1, String.to_integer(i)))
      end)

  def event("format", %{"direction" => direction} = params, socket)
      when is_map_key(@channels, direction) do
    draft(socket, fn d ->
      format = d[direction]
      ticked = Enum.filter(@rates, &(Integer.to_string(&1) in List.wrap(params["rates"])))

      first =
        case params do
          %{"_target" => ["start"], "start" => start} -> String.to_integer(start)
          _other -> List.first(format["rates"])
        end

      rates = if first in ticked, do: [first | List.delete(ticked, first)], else: ticked

      Map.put(d, direction, %{
        format
        | "rates" => rates,
          "channels" => integer(params["channels"], format["channels"]),
          "sample_bits" => integer(params["sample_bits"], format["sample_bits"])
      })
    end)
  end

  def event("revert", _params, socket),
    do: {:noreply, assign(socket, usb_draft: socket.assigns.usb_config.settings, usb_error: nil)}

  def event("apply", _params, socket) do
    draft = socket.assigns.usb_draft

    {:noreply,
     socket
     |> assign(usb_busy: true, usb_error: nil)
     |> start_async(:usb_apply, fn -> USBSettings.update(draft) end)}
  end

  def event("jiggler", %{"on" => on}, socket) do
    on = on == "true"

    case USBSettings.update(%{"jiggler" => on}) do
      {:ok, _settings} ->
        config = put_in(socket.assigns.usb_config, [:settings, "jiggler"], on)

        {:noreply,
         socket
         |> assign(
           usb_config: config,
           usb_draft: Map.put(socket.assigns.usb_draft, "jiggler", on)
         )
         |> put_flash(
           :info,
           if(on, do: "The mouse jiggler is on", else: "The mouse jiggler is off")
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Mouse jiggler: #{error_text(reason)}")}
    end
  end

  def event("eject", %{"drive" => drive}, socket) do
    case disk().eject(String.to_integer(drive)) do
      :ok ->
        {:noreply, refresh_drives(socket)}

      {:error, reason} ->
        {:noreply, socket |> refresh_drives() |> put_flash(:error, DiskDialog.error_text(reason))}
    end
  end

  def event("disk", params, socket) do
    drive = if params["drive"], do: String.to_integer(params["drive"])
    {:noreply, assign(socket, disk_dialog: %{drive: drive})}
  end

  @doc "The outcome of Apply."
  def applied({:ok, {:ok, _settings}}, socket) do
    config = config()

    {:noreply,
     socket
     |> assign(usb_config: config, usb_draft: config.settings, usb_busy: false)
     |> refresh_drives()
     |> put_flash(:info, "USB devices set")}
  end

  def applied({:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, usb_busy: false, usb_error: error_text(reason))}

  def applied({:exit, reason}, socket),
    do: {:noreply, assign(socket, usb_busy: false, usb_error: "USB: #{inspect(reason)}")}

  @doc """
  Takes the devices in anew when they changed elsewhere, such as the sound
  card from the KVM page, unless they are being edited here.
  """
  def follow(socket, functions_before) do
    a = socket.assigns

    if a.status.usb.functions != functions_before and a.usb_draft == a.usb_config.settings and
         not a.usb_busy do
      config = config()
      assign(socket, usb_config: config, usb_draft: config.settings)
    else
      socket
    end
  end

  @doc "What is in the drives now."
  def refresh_drives(socket) do
    assign(socket, disk: disk().drives())
  catch
    :exit, _not_running -> assign(socket, disk: nil)
  end

  defp disk, do: Application.get_env(:kuroneko, :virtual_disk, Kuroneko.VirtualDisk)

  defp draft(socket, change),
    do: {:noreply, assign(socket, usb_draft: change.(socket.assigns.usb_draft), usb_error: nil)}

  defp free_name(prefix, taken, from) do
    Enum.find_value(Stream.iterate(from, &(&1 + 1)), fn n ->
      "#{prefix}#{n}" not in taken && "#{prefix}#{n}"
    end)
  end

  defp integer(nil, default), do: default

  defp integer(text, default),
    do: with({n, ""} <- Integer.parse(text), do: n, else: (_ -> default))

  defp error_text({:invalid, setting}),
    do: Map.get(@invalid, setting, "The #{setting} setting is not one the NanoKVM takes.")

  defp error_text({:invalid_rates, direction, _detail}),
    do: "Tick 1 to 10 sample rates for the #{direction}."

  defp error_text({:too_much_bandwidth, direction, _detail}),
    do:
      "The #{direction} format is more than USB carries: fewer channels, a smaller sample size or lower rates."

  defp error_text({:invalid_channels, direction, _detail}),
    do: "The #{direction} cannot have that many channels."

  defp error_text({:invalid_sample_bits, direction, _detail}),
    do: "The #{direction} cannot have that sample size."

  defp error_text({:not_enough_endpoints, %{need: need, have: have}}) do
    "These take #{need.in} IN and #{need.out} OUT endpoints; the NanoKVM has #{have.in} and #{have.out}. " <>
      "Turn something off."
  end

  defp error_text(reason), do: "USB: #{inspect(reason)}"
end
