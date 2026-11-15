defmodule Kuroneko.KmsgLogger do
  @moduledoc """
  `:logger` handler that copies log events into the kernel log, where the RAM
  console keeps them across the reboot that ends a failed trial boot.
  """

  @formatter %{single_line: true, template: [:level, " ", :msg], chars_limit: 800}
  # /dev/kmsg rejects records longer than 1024 bytes
  @max_bytes 900

  @doc "Adds the handler."
  @spec add() :: :ok | {:error, term()}
  def add() do
    :logger.add_handler(:kmsg, __MODULE__, %{
      level: :info,
      filters: [progress: {&:logger_filters.progress/2, :stop}]
    })
  end

  # Kernel messages that nerves_logging forwards into Logger: writing them
  # back would feed them around forever.
  @doc false
  def log(%{meta: %{application: :"$kmsg"}}, _config), do: :ok

  # Opened per event: logger calls adding_handler/1 from a short-lived
  # process, which would take a file opened there down with it.
  def log(event, _config) do
    text = event |> :logger_formatter.format(@formatter) |> IO.chardata_to_string()
    text = binary_part(text, 0, min(byte_size(text), @max_bytes))
    _ = File.write("/dev/kmsg", ["<", Integer.to_string(priority(event.level)), ">erl: ", text])
    :ok
  rescue
    _ -> :ok
  end

  defp priority(:emergency), do: 0
  defp priority(:alert), do: 1
  defp priority(:critical), do: 2
  defp priority(:error), do: 3
  defp priority(:warning), do: 4
  defp priority(:notice), do: 5
  defp priority(_), do: 6
end
