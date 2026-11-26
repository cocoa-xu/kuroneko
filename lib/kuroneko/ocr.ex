defmodule Kuroneko.OCR do
  @moduledoc """
  Reads the text in a part of the target's picture on the NanoKVM's NPU:
  `read/1` takes the next captured frame's region from `NanoKVMGo.Video`
  and runs PP-OCR on it with `AxeraNPU.OCR`.

  The models are files in a directory, `:kuroneko, :ocr_models` (the app's
  `priv/ocr` by default): `det.axmodel` (text detection), `rec.axmodel`
  (recognition) and `keys.txt` (the recognizer's dictionary). They load on
  the first read and stay loaded. Without them, or without the NPU, which
  the NanoKVM-Go with 256 MiB leaves off by default, `available?/0` is false.
  """
  use GenServer

  @read_timeout 15_000

  @typedoc "A part of the picture as fractions of its width and height."
  @type area() :: %{x: float(), y: float(), width: float(), height: float()}

  @typedoc """
  A line of text, its box in the input's pixels `{x0, y0, x1, y1}` and the
  recognizer's confidence from 0 to 1.
  """
  @type line() :: %{
          text: String.t(),
          box: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()},
          confidence: float()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether text can be read: the NPU's device and the models are there.
  """
  @spec available?() :: boolean()
  def available?, do: File.exists?("/dev/npu") and models_present?(models_dir())

  @doc """
  The lines of text in an area of the picture, top to bottom.

  `{:error, :unavailable}` without the NPU or the models, `:no_input` or
  `:timeout` when there is no picture, `:empty_area` for an area of no pixels.
  """
  @spec read(area()) :: {:ok, [line()]} | {:error, term()}
  def read(area), do: GenServer.call(__MODULE__, {:read, area}, @read_timeout)

  @impl GenServer
  def init(_opts), do: {:ok, %{ocr: nil}}

  @impl GenServer
  def handle_call({:read, area}, _from, state) do
    with true <- available?() || {:error, :unavailable},
         {:ok, region} <- region(area),
         {:ok, picture} <- NanoKVMGo.Video.snapshot(NanoKVMGo.Video, region),
         {:ok, state} <- loaded(state),
         {:ok, lines} <- read_picture(state.ocr, picture) do
      {:reply, {:ok, place(lines, region)}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # The area in the input's pixels, cut to the picture.
  defp region(%{x: x, y: y, width: w, height: h}) do
    case NanoKVMGo.Video.input(NanoKVMGo.Video) do
      %{width: iw, height: ih} ->
        x0 = clamp(round(x * iw), iw)
        y0 = clamp(round(y * ih), ih)
        x1 = clamp(round((x + w) * iw), iw)
        y1 = clamp(round((y + h) * ih), ih)

        if x1 - x0 >= 2 and y1 - y0 >= 2,
          do: {:ok, {x0, y0, x1 - x0, y1 - y0}},
          else: {:error, :empty_area}

      _ ->
        {:error, :no_input}
    end
  end

  defp clamp(value, max), do: value |> max(0) |> min(max)

  defp loaded(%{ocr: nil} = state) do
    dir = models_dir()

    case AxeraNPU.OCR.load(
           Path.join(dir, "det.axmodel"),
           Path.join(dir, "rec.axmodel"),
           Path.join(dir, "keys.txt")
         ) do
      {:ok, ocr} -> {:ok, %{state | ocr: ocr}}
      {:error, reason} -> {:error, {:models, reason}}
    end
  end

  defp loaded(state), do: {:ok, state}

  defp read_picture(_ocr, %{width: 0}), do: {:ok, []}

  defp read_picture(ocr, %{width: w, height: h, data: rgb}),
    do: AxeraNPU.OCR.read(ocr, rgb, w, h)

  # Boxes from the region's pixels to the input's, top to bottom.
  defp place(lines, {rx, ry, _w, _h}) do
    lines
    |> Enum.map(fn line ->
      {x0, y0, x1, y1} = line.box
      %{text: line.text, box: {x0 + rx, y0 + ry, x1 + rx, y1 + ry}, confidence: line.confidence}
    end)
    |> Enum.sort_by(fn %{box: {x0, y0, _x1, _y1}} -> {y0, x0} end)
  end

  defp models_dir,
    do: Application.get_env(:kuroneko, :ocr_models, Application.app_dir(:kuroneko, "priv/ocr"))

  defp models_present?(dir),
    do: Enum.all?(~w(det.axmodel rec.axmodel keys.txt), &File.regular?(Path.join(dir, &1)))
end
