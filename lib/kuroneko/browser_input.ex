defmodule Kuroneko.BrowserInput do
  @moduledoc """
  Input events from the viewer page, JSON over the `/ws` WebSocket, to
  `Kuroneko.Gadget.HID`:

    * `{"type": "key", "code": KeyboardEvent.code, "down": boolean}`
    * `{"type": "mouse", "x": 0..1, "y": 0..1, "buttons": MouseEvent.buttons,
      "wheel": steps down, "pan": steps right}`: the absolute pointer
    * `{"type": "relative", "dx": pixels, "dy": pixels, "buttons": ...,
      "wheel": ..., "pan": ...}`: the relative mouse, with the pointer locked
    * `{"type": "touch", "touches": [[id, x, y], ...]}`: the touches on the
      picture now, ids 0 to 9, x and y 0..1
    * `{"type": "text", "text": string}`: typed on the target, as a US
      keyboard would, one text at a time
    * `{"type": "release"}` when the page loses focus
  """

  import Bitwise

  @max_text 10_000

  @type action() ::
          {:key, Kuroneko.Gadget.HID.key(), :down | :up}
          | {:pointer, [Kuroneko.Gadget.HID.pointer_change()]}
          | {:relative, [Kuroneko.Gadget.HID.relative_change()]}
          | {:touch, [Kuroneko.Gadget.HID.contact()]}
          | {:text, String.t()}
          | :release
          | :ignore

  @doc """
  Passes an event on to `Kuroneko.Gadget.HID`.
  """
  @spec handle(map(), GenServer.server()) :: :ok
  def handle(event, hid \\ Kuroneko.Gadget.HID) do
    case parse(event) do
      {:key, key, action} -> Kuroneko.Gadget.HID.key(hid, key, action)
      {:pointer, changes} -> Kuroneko.Gadget.HID.pointer(hid, changes)
      {:relative, changes} -> Kuroneko.Gadget.HID.relative(hid, changes)
      {:touch, contacts} -> Kuroneko.Gadget.HID.touch(hid, contacts)
      {:text, text} -> type(hid, text)
      :release -> Kuroneko.Gadget.HID.release_all(hid)
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

  # Outside the socket's process, which goes on taking input; a second text
  # while one is typed is dropped.
  defp type(hid, text) do
    {:ok, _pid} =
      Task.start(fn ->
        if register(), do: Kuroneko.Gadget.HID.type(hid, text)
      end)

    :ok
  end

  defp register do
    Process.register(self(), Kuroneko.Typing)
  rescue
    ArgumentError -> false
  end

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
