defmodule KuronekoWeb.DeviceLive.System do
  @moduledoc false
  # What the NanoKVM runs and is made of: the firmware's slots, the software,
  # the microSD card's partitions and the hardware's parts.

  use KuronekoWeb, :html

  alias KuronekoWeb.Format

  @roles %{
    "boot" => {"Boot", "#8e8e93"},
    "rootfs_a" => {"Firmware A", "#0a84ff"},
    "rootfs_b" => {"Firmware B", "#5e5ce6"},
    "data" => {"Data", "#30d158"}
  }

  attr :firmware, :map, required: true
  attr :trial, :map, required: true

  def firmware_card(assigns) do
    slots =
      case assigns.firmware.slots do
        [] -> [%{slot: assigns.firmware.active || "?", active: true, version: nil, uuid: nil}]
        slots -> slots
      end

    assigns = assign(assigns, slots: slots, running: Enum.find(slots, %{}, & &1.active))

    ~H"""
    <.card id="firmware" title="Firmware" icon="hero-cube">
      <:actions>
        <.badge kind={if @trial.validated, do: :ok, else: :warn}>
          {if @trial.validated, do: "Validated", else: "On trial"}
        </.badge>
      </:actions>
      <div class="grid grid-cols-2 gap-3">
        <div
          :for={slot <- @slots}
          class={[
            "rounded-field p-3",
            if(slot.active, do: "bg-primary/10 ring-1 ring-primary/30", else: "bg-base-200/70")
          ]}
        >
          <div class="flex items-center justify-between text-xs text-base-content/60">
            <span>Slot {String.upcase(slot.slot)}</span>
            <.badge kind={if slot.active, do: :ok}>
              {if slot.active, do: "Running", else: "Standby"}
            </.badge>
          </div>
          <div class="mt-1.5 text-lg font-semibold tabular-nums">{slot.version || "–"}</div>
          <div class="mt-0.5 truncate font-mono text-xs text-base-content/50" title={slot.uuid}>
            {if slot.uuid, do: "UUID " <> String.slice(slot.uuid, 0, 8), else: "No firmware"}
          </div>
        </div>
      </div>
      <.facts
        class="mt-4"
        rows={[
          {"Product", @running[:product]},
          {"Platform",
           @running[:platform] &&
             Enum.join(Enum.reject([@running.platform, @running[:architecture]], &is_nil/1), ", ")},
          {"Author", @running[:author]},
          {"Source", @running[:vcs]}
        ]}
      />
    </.card>
    """
  end

  attr :overview, :map, required: true
  attr :beam, :map, required: true

  def software_card(assigns) do
    sw = assigns.overview.software
    hw = assigns.overview.hardware

    rows = [
      {"Linux", hw[:linux]},
      {"Erlang/OTP", sw.otp && "#{sw.otp}, ERTS #{sw.erts}"},
      {"Elixir", sw.elixir},
      {"Application", sw.app && "kuroneko #{sw.app}"},
      {"Libraries",
       [
         sw.nano_kvm_go && "nano_kvm_go #{sw.nano_kvm_go}",
         sw.kuroneko_gadget && "kuroneko_gadget #{sw.kuroneko_gadget}"
       ]
       |> Enum.reject(&(&1 in [nil, false]))
       |> Enum.join(", ")},
      {"BEAM",
       "#{Format.bytes(assigns.beam.memory)}, #{assigns.beam.processes} processes, #{assigns.beam.schedulers} schedulers"},
      {"Serial number", hw[:serial_number]}
    ]

    assigns = assign(assigns, rows: rows)

    ~H"""
    <.card id="software" title="Software" icon="hero-code-bracket">
      <.facts rows={@rows} />
    </.card>
    """
  end

  attr :storage, :map, default: nil

  def storage_card(assigns) do
    assigns = assign(assigns, layout: storage_layout(assigns.storage))

    ~H"""
    <.card id="storage" title="Storage" icon="hero-circle-stack">
      <:actions>
        <.badge>{card_label(@storage)}</.badge>
      </:actions>
      <%= if @layout do %>
        <div class="flex h-9 overflow-hidden rounded-field bg-base-300/70">
          <div
            :for={segment <- @layout.segments}
            title={segment.title}
            style={segment.style}
            class={[
              "relative flex min-w-0 items-center overflow-hidden px-2 text-[11px] font-medium text-white",
              segment.kind == :reserved && "w-1.5 shrink-0 bg-base-content/20 px-0",
              segment.kind == :free && "text-base-content/50"
            ]}
          >
            <div
              :if={segment.used}
              class="absolute inset-y-0 left-0 bg-black/20"
              style={"width: #{segment.used}%"}
            />
            <span :if={segment.text} class="relative truncate">{segment.text}</span>
          </div>
        </div>
        <ul class="mt-4 grid gap-2 sm:grid-cols-2">
          <li :for={{name, color, detail} <- @layout.legend} class="flex items-baseline gap-2 text-sm">
            <span class="size-2.5 shrink-0 translate-y-px rounded-sm" style={"background: #{color}"} />
            <span class="font-medium">{name}</span>
            <span class="truncate text-xs text-base-content/55">{detail}</span>
          </li>
        </ul>
        <p :if={@layout.note} class="mt-3 text-xs text-base-content/55">{@layout.note}</p>
      <% else %>
        <p class="text-sm text-base-content/60">No SD card found.</p>
      <% end %>
    </.card>
    """
  end

  defp card_label(%{card: %{} = card}) do
    [
      Enum.join(Enum.reject([card[:manufacturer], card[:name]], &is_nil/1), " "),
      Format.bytes(card.size),
      card[:date] && "made #{Format.month(card.date)}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  defp card_label(_storage), do: "No card"

  # The card from start to end: what comes before the first partition, the
  # partitions and what the last leaves, as wide as the square roots of their
  # sizes so that a 128 MB partition stays in sight beside 100 GB.
  defp storage_layout(%{card: %{size: size}, partitions: parts}) do
    first = if parts == [], do: size, else: hd(parts).start
    stop = Enum.reduce(parts, first, &max(&2, &1.start + &1.size))

    segments =
      Enum.concat([
        if(first > 0,
          do: [
            %{
              kind: :reserved,
              title: "Boot loader and settings: #{Format.bytes(first)}",
              style: nil,
              used: nil,
              text: nil
            }
          ],
          else: []
        ),
        Enum.map(parts, &part_segment/1),
        if(size - stop > 0,
          do: [
            %{
              kind: :free,
              title: "Not partitioned: #{Format.bytes(size - stop)}",
              style: "flex: #{:math.sqrt(size - stop)} 1 0",
              used: nil,
              text: "#{Format.bytes(size - stop)} not partitioned"
            }
          ],
          else: []
        )
      ])

    free = size - stop

    %{
      segments: segments,
      legend: Enum.map(parts, &legend/1),
      note:
        free >= size * 0.2 &&
          "#{Format.bytes(free)} of the card is in no partition: the data partition was made for a smaller image. " <>
            "Writing the firmware to the card with fwup lets the data partition fill it."
    }
  end

  defp storage_layout(_storage), do: nil

  defp part_segment(p) do
    {name, color} = role(p)
    fs = p[:filesystem]

    %{
      kind: :partition,
      title: "#{name}: #{Format.bytes(p.size)}",
      style: "flex: #{:math.sqrt(p.size)} 1 0; background: #{color}",
      used: fs && fs[:size] && to_string(p.role) == "data" && round(fs.used / fs.size * 100),
      text: name
    }
  end

  defp legend(p) do
    {name, color} = role(p)
    fs = p[:filesystem]
    running = p[:mount] == "/"

    detail =
      cond do
        fs && to_string(p.role) == "data" && fs[:size] ->
          "#{Format.bytes(p.size)}, #{fs.type}, #{Format.bytes(fs.used)} used, #{Format.bytes(fs.available)} free"

        fs && running ->
          "#{Format.bytes(p.size)}, #{fs.type} image of #{Format.bytes(fs.size)}"

        fs ->
          Format.bytes(p.size)

        true ->
          "#{Format.bytes(p.size)}, not mounted"
      end

    {if(running, do: "#{name}, running", else: name), color, detail}
  end

  defp role(p), do: Map.get(@roles, to_string(p[:role]), {"Partition #{p[:number]}", "#8e8e93"})

  attr :components, :list, required: true

  def hardware_card(assigns) do
    attention = Enum.count(assigns.components, &(!&1[:device] or !&1[:driver]))
    assigns = assign(assigns, attention: attention)

    ~H"""
    <.card id="hardware" title="Hardware" icon="hero-cpu-chip">
      <:actions>
        <.badge kind={if @attention > 0, do: :warn, else: :ok}>
          {if @attention > 0,
            do: "#{@attention} of #{length(@components)} need attention",
            else: "All #{length(@components)} parts working"}
        </.badge>
      </:actions>
      <div class="-mx-5 overflow-x-auto">
        <table class="w-full text-sm">
          <thead class="text-left text-xs text-base-content/55">
            <tr>
              <th class="px-5 py-2 font-medium">Part</th>
              <th class="px-2 py-2 font-medium">Chip</th>
              <th class="px-2 py-2 font-medium">Linux device</th>
              <th class="px-2 py-2 font-medium">Driver</th>
              <th class="px-5 py-2 font-medium">State</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300/60">
            <tr :for={c <- @components}>
              <td class="px-5 py-2">{c.name}</td>
              <td class="px-2 py-2 text-base-content/70">{c[:chip] || "–"}</td>
              <td class="px-2 py-2 font-mono text-xs">
                {if c[:device], do: "#{c[:bus]} #{c.device}", else: "–"}
              </td>
              <td class="px-2 py-2 font-mono text-xs">{c[:driver] || "–"}</td>
              <td class="px-5 py-2">
                <.badge kind={
                  cond do
                    !c[:device] -> :bad
                    !c[:driver] -> :warn
                    true -> :ok
                  end
                }>
                  {cond do
                    !c[:device] -> "Missing"
                    !c[:driver] -> "No driver"
                    true -> "Working"
                  end}
                </.badge>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="mt-3 text-xs text-base-content/55">
        Each part as the kernel sees it. Without a device the kernel made nothing of it: its driver is not
        built or its device tree node is off. A device without a driver failed to probe.
      </p>
    </.card>
    """
  end
end
