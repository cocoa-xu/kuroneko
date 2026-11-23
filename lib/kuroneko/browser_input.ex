defmodule Kuroneko.BrowserInput do
  @moduledoc """
  Input events from the viewer page, JSON over the `/ws` WebSocket, to
  `Kuroneko.Gadget.Input`:

    * `{"type": "key", "code": KeyboardEvent.code, "down": boolean}`
    * `{"type": "mouse", "x": 0..1, "y": 0..1, "buttons": MouseEvent.buttons,
      "wheel": steps down, "pan": steps right}`: the absolute pointer
    * `{"type": "relative", "dx": pixels, "dy": pixels, "buttons": ...,
      "wheel": ..., "pan": ...}`: the relative mouse, with the pointer locked
    * `{"type": "touch", "touches": [[id, x, y], ...]}`: the touches on the
      picture now, ids 0 to 9, x and y 0..1
    * `{"type": "text", "text": string}`: typed on the target, as a US
      keyboard would, after any text before
    * `{"type": "release"}` when the page loses focus
  """

  import Bitwise

  alias Kuroneko.Gadget.Input

  @max_text 10_000

  @type action() ::
          {:key, Kuroneko.Gadget.Input.key(), :down | :up}
          | {:pointer, [Kuroneko.Gadget.Input.pointer_change()]}
          | {:relative, [Kuroneko.Gadget.Input.relative_change()]}
          | {:touch, [Kuroneko.Gadget.Input.contact()]}
          | {:text, String.t()}
          | :release
          | :ignore

  @doc """
  Passes an event on to `Kuroneko.Gadget.Input`.
  """
  @spec handle(map(), GenServer.server()) :: :ok
  def handle(event, input \\ Input) do
    case parse(event) do
      {:key, key, action} -> Input.key(input, key, action)
      {:pointer, changes} -> Input.pointer(input, changes)
      {:relative, changes} -> Input.relative(input, changes)
      {:touch, contacts} -> Input.touch(input, contacts)
      {:text, text} -> Input.type(input, text)
      :release -> Input.release_all(input)
      :ignore -> :ok
    end
  end

  @doc """
  What an event asks for.
  """
  @spec parse(map()) :: action()
  def parse(%{"type" => "key", "code" => code, "down" => down})
      when is_binary(code) and is_boolean(down) do
    {:key, code, if(down, do: :down, else: :up)}
  end

  def parse(%{"type" => "mouse", "x" => x, "y" => y} = event)
      when is_number(x) and is_number(y) do
    {:pointer, [x: x, y: y] ++ buttons_and_wheels(event)}
  end

  def parse(%{"type" => "relative", "dx" => dx, "dy" => dy} = event)
      when is_integer(dx) and is_integer(dy) do
    {:relative, [dx: dx, dy: dy] ++ buttons_and_wheels(event)}
  end

  def parse(%{"type" => "touch", "touches" => touches}) when is_list(touches) do
    contacts = for [id, x, y] <- touches, id in 0..9, is_number(x), is_number(y), do: {id, x, y}
    {:touch, Enum.take(contacts, 10)}
  end

  def parse(%{"type" => "text", "text" => text})
      when is_binary(text) and byte_size(text) <= @max_text,
      do: {:text, text}

  def parse(%{"type" => "release"}), do: :release
  def parse(_event), do: :ignore

  defp buttons_and_wheels(event) do
    [
      buttons: buttons(event["buttons"]),
      wheel: steps(event["wheel"], -1),
      pan: steps(event["pan"], 1)
    ]
  end

  # MouseEvent.buttons: 1 primary, 2 secondary, 4 auxiliary, 8 back, 16 forward.
  @buttons [{1, :left}, {2, :right}, {4, :middle}, {8, :back}, {16, :forward}]

  defp buttons(bits) when is_integer(bits) do
    for {bit, button} <- @buttons, (bits &&& bit) != 0, do: button
  end

  defp buttons(_bits), do: []

  # The page's wheel steps are positive down, the HID wheel's up; both pans
  # are positive to the right.
  defp steps(steps, sign) when is_number(steps), do: sign * round(steps)
  defp steps(_steps, _sign), do: 0
end
