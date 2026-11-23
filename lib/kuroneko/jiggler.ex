defmodule Kuroneko.Jiggler do
  @moduledoc """
  Moves the relative mouse a pixel right and back each minute while the
  `"jiggler"` setting is on, so that the target does not go to sleep.
  """
  use GenServer

  @every_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    every = Keyword.get(opts, :every_ms, @every_ms)
    Process.send_after(self(), :jiggle, every)
    {:ok, %{every: every, input: Keyword.get(opts, :input, Kuroneko.Gadget.Input)}}
  end

  @impl GenServer
  def handle_info(:jiggle, state) do
    Process.send_after(self(), :jiggle, state.every)

    if Kuroneko.USBSettings.saved()["jiggler"] do
      Kuroneko.Gadget.Input.relative(state.input, dx: 1)
      Kuroneko.Gadget.Input.relative(state.input, dx: -1)
    end

    {:noreply, state}
  end
end
