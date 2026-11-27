defmodule KuronekoWeb.DeviceLive.Metrics do
  @moduledoc false
  # The live tiles: CPU, memory, temperature and network, each with the last
  # five minutes as a chart that the page draws and adds each sample to.

  use KuronekoWeb, :html

  alias KuronekoWeb.Format

  @colors %{
    cpu: "#0a84ff",
    memory: "#bf5af2",
    temperature: "#ff9f0a",
    down: "#30d158",
    up: "#64d2ff"
  }

  attr :metrics, :map, default: nil
  attr :history, :map, default: nil

  def tiles(assigns) do
    m = assigns.metrics
    history = assigns.history || %{cpu: [], memory: [], temperature: [], network: %{}}

    assigns =
      assign(assigns,
        m: m,
        history: history,
        colors: @colors,
        traffic:
          m &&
            Enum.reduce(
              Map.values(m.network),
              %{down: 0, up: 0},
              &%{down: &2.down + &1.down, up: &2.up + &1.up}
            )
      )

    ~H"""
    <section class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4" aria-label="Live metrics">
      <.tile icon="hero-cpu-chip" title="CPU">
        <:value>{if @m, do: round(@m.cpu.total), else: "–"}<small :if={@m}>%</small></:value>
        <:detail :if={@m && @m.load != []}>
          Load {Enum.map_join(@m.load, ", ", &Format.decimals(&1, 2))}
        </:detail>
        <.chart
          id="chart-cpu"
          kind="percent"
          label="CPU use, last five minutes"
          series={[%{field: "cpu", values: @history.cpu, color: @colors.cpu, fill: true}]}
        />
        <div :if={@m} class="mt-2 flex gap-1">
          <span
            :for={{percent, core} <- Enum.with_index(@m.cpu.cores)}
            class="h-1 flex-1 overflow-hidden rounded-full bg-base-300"
            title={"Core #{core}: #{round(percent)}%"}
          >
            <i
              class="block h-full rounded-full transition-[width] duration-500"
              style={"width: #{min(percent, 100)}%; background: #{@colors.cpu}"}
            />
          </span>
        </div>
      </.tile>

      <.tile icon="hero-square-3-stack-3d" title="Memory">
        <:value>{if @m, do: round(@m.memory.percent), else: "–"}<small :if={@m}>%</small></:value>
        <:detail :if={@m}>
          {Format.bytes(@m.memory.used)} of {Format.bytes(@m.memory.total)} in use
        </:detail>
        <.chart
          id="chart-memory"
          kind="percent"
          label="Memory use, last five minutes"
          series={[%{field: "memory", values: @history.memory, color: @colors.memory, fill: true}]}
        />
      </.tile>

      <.tile icon="hero-fire" title="SoC temperature">
        <:value>{temperature(@m)}<small :if={@m && @m.temperature}> °C</small></:value>
        <:detail>{temperature_detail(@m, @history.temperature)}</:detail>
        <.chart
          id="chart-temperature"
          kind="temperature"
          label="SoC temperature, last five minutes"
          series={[
            %{
              field: "temperature",
              values: @history.temperature,
              color: @colors.temperature,
              fill: true
            }
          ]}
        />
      </.tile>

      <.tile icon="hero-arrows-up-down" title="Network">
        <:value>{if @traffic, do: Format.rate(@traffic.down + @traffic.up), else: "–"}</:value>
        <:detail :if={@traffic}>
          <span style={"color: #{@colors.down}"}>↓ {Format.rate(@traffic.down)}</span>
          <span class="ml-2" style={"color: #{@colors.up}"}>↑ {Format.rate(@traffic.up)}</span>
        </:detail>
        <.chart
          id="chart-network"
          kind="rate"
          label="Network traffic, last five minutes"
          series={[
            %{
              field: "down",
              values: total(@history.network, :down),
              color: @colors.down,
              fill: true,
              label: "↓"
            },
            %{field: "up", values: total(@history.network, :up), color: @colors.up, label: "↑"}
          ]}
        />
      </.tile>
    </section>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :value, required: true
  slot :detail
  slot :inner_block, required: true

  defp tile(assigns) do
    ~H"""
    <article class="rounded-box bg-base-100 p-4 shadow-sm">
      <h2 class="flex items-center gap-1.5 text-xs font-medium text-base-content/60">
        <.icon name={@icon} class="size-4" /> {@title}
      </h2>
      <div class="mt-1.5 text-2xl font-semibold tabular-nums [&_small]:ml-0.5 [&_small]:text-sm [&_small]:font-normal [&_small]:text-base-content/60">
        {render_slot(@value)}
      </div>
      <div class="mt-0.5 min-h-4 truncate text-xs text-base-content/60 tabular-nums">
        {render_slot(@detail)}
      </div>
      {render_slot(@inner_block)}
    </article>
    """
  end

  defp temperature(%{temperature: t}) when is_number(t), do: Format.decimals(t, 1)
  defp temperature(_), do: "–"

  defp temperature_detail(%{temperature: t}, history) when is_number(t) do
    valid = Enum.reject(history, &is_nil/1)

    word =
      cond do
        t >= 95 -> "Hot"
        t >= 80 -> "Warm"
        true -> "Normal"
      end

    if valid == [],
      do: word,
      else:
        "#{word} (#{Format.decimals(Enum.min(valid), 1)} to #{Format.decimals(Enum.max(valid), 1)} °C)"
  end

  defp temperature_detail(%{}, _history), do: "No sensor"
  defp temperature_detail(nil, _history), do: nil

  # The interfaces' traffic summed, aligned on the newest sample.
  defp total(network, direction) do
    lists = for {_name, n} <- network, do: Map.fetch!(n, direction)
    length = lists |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    lists
    |> Enum.map(&(List.duplicate(0, length - length(&1)) ++ &1))
    |> Enum.zip_with(&Enum.sum/1)
  end

  attr :id, :string, required: true
  attr :kind, :string, required: true, doc: "percent, temperature or rate"
  attr :label, :string, required: true
  attr :series, :list, required: true

  defp chart(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".Chart"
      phx-update="ignore"
      data-kind={@kind}
      data-series={Jason.encode!(@series)}
      class="relative mt-3 h-14"
    >
      <canvas class="block h-full w-full" role="img" aria-label={@label}></canvas>
      <div
        data-tip
        hidden
        class="pointer-events-none absolute -top-7 z-10 -translate-x-1/2 whitespace-nowrap rounded-md bg-base-content px-2 py-0.5 text-[11px] text-base-100 shadow"
      >
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Chart">
      const HISTORY = 300
      const niceMax = (values, least) => {
        const top = Math.max(least, ...values)
        const power = 10 ** Math.floor(Math.log10(top))
        return [1, 2, 5, 10].map((m) => m * power).find((m) => m >= top)
      }
      const rate = (n) => n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB/s`
        : n >= 1e3 ? `${Math.round(n / 1e3)} kB/s` : `${Math.round(n)} B/s`
      const ago = (s) => s < 1 ? "now" : s < 60 ? `${s} s ago`
        : `${Math.floor(s / 60)} min${s % 60 ? ` ${s % 60} s` : ""} ago`
      const KINDS = {
        percent: { min: () => 0, max: () => 100, format: (v) => `${Math.round(v)}%` },
        temperature: {
          min: (vs) => Math.min(30, Math.floor((Math.min(...vs) - 5) / 10) * 10),
          max: (vs) => Math.max(90, Math.ceil((Math.max(...vs) + 5) / 10) * 10),
          format: (v) => `${v.toFixed(1)} °C`,
        },
        rate: { min: () => 0, max: (vs) => niceMax(vs, 10e3), format: rate },
      }

      export default {
        mounted() {
          this.kind = KINDS[this.el.dataset.kind]
          this.series = JSON.parse(this.el.dataset.series)
          this.canvas = this.el.querySelector("canvas")
          this.tip = this.el.querySelector("[data-tip]")
          this.hover = null
          this.canvas.addEventListener("pointermove", (e) => { this.hover = e.offsetX; this.draw() })
          this.canvas.addEventListener("pointerleave", () => { this.hover = null; this.draw() })
          this.resize = new ResizeObserver(() => this.draw())
          this.resize.observe(this.canvas)
          this.handleEvent("metrics", (sample) => {
            for (const s of this.series) {
              s.values.push(sample[s.field] ?? null)
              if (s.values.length > HISTORY) s.values.splice(0, s.values.length - HISTORY)
            }
            this.draw()
          })
          this.draw()
        },

        destroyed() {
          this.resize.disconnect()
        },

        range() {
          const values = this.series.flatMap((s) => s.values).filter((v) => v != null)
          if (!values.length) return [0, 1]
          const min = this.kind.min(values)
          return [min, Math.max(this.kind.max(values), min + 1)]
        },

        draw() {
          const canvas = this.canvas, dpr = window.devicePixelRatio || 1
          const w = canvas.clientWidth, ht = canvas.clientHeight
          if (!w || !ht) return
          if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(ht * dpr)) {
            canvas.width = Math.round(w * dpr)
            canvas.height = Math.round(ht * dpr)
          }
          const g = canvas.getContext("2d")
          g.setTransform(dpr, 0, 0, dpr, 0, 0)
          g.clearRect(0, 0, w, ht)
          const [min, max] = this.range()
          const step = w / (HISTORY - 1)
          const x = (i, length) => w - (length - 1 - i) * step
          const y = (v) => ht - 3 - ((Math.min(Math.max(v, min), max) - min) / (max - min)) * (ht - 8)

          g.strokeStyle = "rgba(127, 127, 127, 0.15)"
          g.lineWidth = 1
          for (const f of [0.5, 1]) {
            const gy = Math.round(ht - 3 - f * (ht - 8)) + 0.5
            g.beginPath(); g.moveTo(0, gy); g.lineTo(w, gy); g.stroke()
          }

          for (const { values, color, fill } of this.series) {
            const points = values.map((v, i) => (v == null ? null : [x(i, values.length), y(v)]))
            const runs = []
            for (const p of points) {
              if (!p) runs.push([])
              else (runs.length ? runs[runs.length - 1] : runs[runs.push([]) - 1]).push(p)
            }
            for (const run of runs.filter((r) => r.length)) {
              if (fill) {
                const gradient = g.createLinearGradient(0, 0, 0, ht)
                gradient.addColorStop(0, `${color}55`)
                gradient.addColorStop(1, `${color}00`)
                g.fillStyle = gradient
                g.beginPath()
                g.moveTo(run[0][0], ht)
                for (const [px, py] of run) g.lineTo(px, py)
                g.lineTo(run[run.length - 1][0], ht)
                g.closePath()
                g.fill()
              }
              g.strokeStyle = color
              g.lineWidth = 1.7
              g.lineJoin = "round"
              g.beginPath()
              run.forEach(([px, py], i) => (i ? g.lineTo(px, py) : g.moveTo(px, py)))
              g.stroke()
            }
            const last = points[points.length - 1]
            if (last) {
              g.fillStyle = color
              g.beginPath(); g.arc(last[0], last[1], 2.6, 0, Math.PI * 2); g.fill()
            }
          }
          this.drawHover(g, w, ht, y, step)
        },

        drawHover(g, w, ht, y, step) {
          const longest = Math.max(0, ...this.series.map((s) => s.values.length))
          const back = this.hover == null ? null : Math.round((w - this.hover) / step)
          if (back == null || back >= longest) { this.tip.hidden = true; return }
          const px = w - back * step
          g.strokeStyle = "rgba(127, 127, 127, 0.5)"
          g.beginPath(); g.moveTo(px + 0.5, 0); g.lineTo(px + 0.5, ht); g.stroke()
          const parts = []
          for (const { values, color, label } of this.series) {
            const v = values[values.length - 1 - back]
            if (v == null) continue
            g.fillStyle = color
            g.beginPath(); g.arc(px, y(v), 3, 0, Math.PI * 2); g.fill()
            parts.push(`${label ? `${label} ` : ""}${this.kind.format(v)}`)
          }
          this.tip.textContent = `${parts.join(", ")}, ${ago(back)}`
          this.tip.hidden = false
          const half = this.tip.offsetWidth / 2
          this.tip.style.left = `${Math.min(Math.max(px, half), w - half)}px`
        },
      }
    </script>
    """
  end
end
