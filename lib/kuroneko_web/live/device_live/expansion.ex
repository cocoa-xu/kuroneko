defmodule KuronekoWeb.DeviceLive.Expansion do
  @moduledoc false
  # The auxiliary USB-C port's two lines: their mode, and each line's GPIO
  # level or PWM output.

  use KuronekoWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kuroneko.DeviceInfo
  alias KuronekoWeb.DeviceLive.Screen

  @modes %{
    "off" => {"Off", "Off: inputs pulled down"},
    "uart" => {"UART", "UART, ttyS3 (TXD idles high)"},
    "gpio" => {"GPIO", "Two GPIOs"},
    "pwm" => {"PWM", "Two PWM outputs"},
    "pwm_gpio" => {"PWM + GPIO", "PWM out, GPIO in (Finger Robot)"},
    "gpio_pwm" => {"GPIO + PWM", "GPIO, then PWM out"},
    "i2c" => {"I2C", "I2C bus, i2c-2"}
  }
  @roles %{
    "off" => "Off",
    "uart_txd" => "UART TXD",
    "uart_rxd" => "UART RXD",
    "gpio" => "GPIO",
    "pwm" => "PWM",
    "i2c_sda" => "I2C SDA",
    "i2c_scl" => "I2C SCL"
  }
  @role_text %{
    "off" => "An input, pulled down: nothing is driven.",
    "uart_txd" => "Sends ttyS3's data; high while idle.",
    "uart_rxd" => "Receives ttyS3's data.",
    "i2c_sda" => "Data of the I2C bus i2c-2, pulled up.",
    "i2c_scl" => "Clock of the I2C bus i2c-2, pulled up."
  }
  @pads ["UART3_TXD pad", "UART3_RXD pad"]

  attr :expansion, :map, default: nil

  def expansion_card(assigns) do
    assigns = assign(assigns, modes: @modes, roles: @roles, role_text: @role_text, pads: @pads)

    ~H"""
    <.card id="expansion" title="Auxiliary port" icon="hero-bolt">
      <:actions>
        <.badge :if={@expansion} kind={if to_string(@expansion.mode) != "off", do: :ok}>
          {@modes |> Map.get(to_string(@expansion.mode), {to_string(@expansion.mode), nil}) |> elem(0)}
        </.badge>
        <.badge :if={!@expansion} kind={:bad}>No driver</.badge>
      </:actions>

      <%= if @expansion do %>
        <.row label="Its two lines">
          <form id="expansion-mode" phx-change="expansion:mode" phx-auto-recover="ignore">
            <select name="mode" class="select select-sm w-60">
              <option :for={mode <- @expansion.modes} value={mode} selected={mode == @expansion.mode}>
                {@modes |> Map.get(to_string(mode), {nil, to_string(mode)}) |> elem(1)}
              </option>
            </select>
          </form>
        </.row>

        <div class="mt-3 grid gap-3 sm:grid-cols-2">
          <div :for={line <- @expansion.lines} class="rounded-field bg-base-200/70 p-3">
            <div class="flex items-center gap-2 text-sm">
              <b class="font-semibold">Line {line.line}</b>
              <span class="text-xs text-base-content/50">{Enum.at(@pads, line.line)}</span>
              <span class="ml-auto"><.badge>
                {Map.get(@roles, to_string(line.role), to_string(line.role))}
              </.badge></span>
            </div>

            <%= case to_string(line.role) do %>
              <% "gpio" -> %>
                <.facts
                  class="mt-2"
                  rows={[
                    {"Level", gpio_level(line[:gpio])},
                    {"Edges",
                     line[:edges] && "#{line.edges.total}, #{line.edges.per_second} a second"}
                  ]}
                />
                <div class="mt-2 flex gap-1.5">
                  <.button
                    size={:sm}
                    phx-click="expansion:gpio"
                    phx-value-line={line.line}
                    phx-value-value="input"
                  >Input</.button>
                  <.button
                    size={:sm}
                    phx-click="expansion:gpio"
                    phx-value-line={line.line}
                    phx-value-value="0"
                  >Low</.button>
                  <.button
                    size={:sm}
                    phx-click="expansion:gpio"
                    phx-value-line={line.line}
                    phx-value-value="1"
                  >High</.button>
                </div>
              <% "pwm" -> %>
                <.facts class="mt-2" rows={[{"Output", pwm_text(line[:pwm])}]} />
                <form
                  id={"expansion-pwm-#{line.line}"}
                  phx-submit="expansion:pwm"
                  class="mt-2 flex flex-wrap items-center gap-1.5"
                >
                  <input type="hidden" name="line" value={line.line} />
                  <label class="input input-sm w-28">
                    <input
                      type="number"
                      name="hz"
                      min="0"
                      step="any"
                      value={pwm_hz(line[:pwm])}
                      aria-label="Frequency"
                    />
                    <span class="text-xs text-base-content/50">Hz</span>
                  </label>
                  <label class="input input-sm w-32">
                    <input
                      type="number"
                      name="us"
                      min="0"
                      step="any"
                      value={pwm_us(line[:pwm])}
                      aria-label="High time"
                    />
                    <span class="text-xs text-base-content/50">µs high</span>
                  </label>
                  <.button size={:sm} type="submit">Set</.button>
                  <.button
                    size={:sm}
                    type="button"
                    phx-click="expansion:stop"
                    phx-value-line={line.line}
                  >Stop</.button>
                </form>
              <% role -> %>
                <p class="mt-2 text-xs text-base-content/60">{Map.get(@role_text, role, "")}</p>
            <% end %>
          </div>
        </div>

        <p class="mt-3 text-xs text-base-content/55">
          The USB-C port with the lightning icon carries two lines besides power. Off drives nothing, and the
          choice stays after a restart. Which contacts carry the lines, and at what voltage (most likely 3.3 V),
          is not confirmed yet: measure before connecting anything but the Finger Robot.
        </p>
      <% else %>
        <p class="text-sm text-base-content/60">
          This system's kernel has no driver for the auxiliary port's lines.
        </p>
      <% end %>
    </.card>
    """
  end

  defp gpio_level(nil), do: "–"

  defp gpio_level(gpio),
    do:
      "#{if gpio.value == 1, do: "High", else: "Low"}, #{if to_string(gpio.direction) == "output", do: "driven", else: "input"}"

  defp pwm_text(nil), do: "Stopped"

  defp pwm_text(%{period: period, duty_cycle: duty}) do
    "#{Screen.hertz(1.0e9 / period)}, high #{Float.round(duty / 1000, 1)} µs (#{Float.round(100 * duty / period, 1)}%)"
  end

  defp pwm_hz(nil), do: 50
  defp pwm_hz(%{period: period}), do: Float.round(1.0e9 / period, 3)
  defp pwm_us(nil), do: 1500
  defp pwm_us(%{duty_cycle: duty}), do: Float.round(duty / 1000, 3)

  def event("mode", %{"mode" => mode}, socket) do
    case Map.fetch(@modes, mode) do
      {:ok, {_short, long}} ->
        change(
          socket,
          &NanoKVMGo.Expansion.set_mode(&1, String.to_existing_atom(mode), []),
          "Auxiliary port: #{long}"
        )

      :error ->
        {:noreply, put_flash(socket, :error, "Auxiliary port: no such mode")}
    end
  end

  def event("gpio", %{"line" => line, "value" => value}, socket) do
    line = String.to_integer(line)

    case value do
      "input" ->
        change(socket, &NanoKVMGo.Expansion.read(&1, line), "Line #{line} is an input")

      level ->
        change(
          socket,
          &NanoKVMGo.Expansion.write(&1, line, String.to_integer(level)),
          "Line #{line} driven #{if level == "1", do: "high", else: "low"}"
        )
    end
  end

  def event("pwm", %{"line" => line, "hz" => hz, "us" => us}, socket) do
    line = String.to_integer(line)

    with {hz, ""} when hz > 0 <- Float.parse(hz),
         {us, ""} when us >= 0 <- Float.parse(us),
         period when period in 1000..10_000_000_000 <- round(1.0e9 / hz),
         duty when duty <= period <- round(us * 1000) do
      change(
        socket,
        &NanoKVMGo.Expansion.set_pwm(&1, line, period, duty),
        "Line #{line}: #{Screen.hertz(hz)}, high #{us} µs"
      )
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A frequency from 0.1 Hz to 1 MHz, and a high time that fits in its period"
         )}
    end
  end

  def event("stop", %{"line" => line}, socket) do
    line = String.to_integer(line)
    change(socket, &NanoKVMGo.Expansion.stop_pwm(&1, line), "Line #{line} stopped")
  end

  defp change(socket, call, done) do
    server = Application.get_env(:kuroneko, :expansion_server, NanoKVMGo.Expansion)

    case call.(server) do
      :ok ->
        {:noreply, socket |> assign(status: DeviceInfo.status()) |> put_flash(:info, done)}

      {:ok, _value} ->
        {:noreply, socket |> assign(status: DeviceInfo.status()) |> put_flash(:info, done)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Something else still holds those lines")}

      {:error, {reason, _line}} when reason in [:not_gpio, :not_pwm] ->
        {:noreply, put_flash(socket, :error, "The lines are in another mode now")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Auxiliary port: #{inspect(reason)}")}
    end
  end
end
