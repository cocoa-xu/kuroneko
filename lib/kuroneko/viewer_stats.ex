defmodule Kuroneko.ViewerStats do
  @moduledoc """
  What the viewers' pages saw of the video, a sample a second from each over
  the input socket: frames received and the longest gap between two,
  frames decoded, drawn and shown, the time to decode and to draw, the
  decoder's queue, the input's round trip and how far behind smooth
  playback keeps the picture. Rates use the actual sample duration;
  visibility distinguishes foreground and background samples. The last
  300 samples across viewers are kept for investigating stalls.
  """
  use Agent

  @keep 300
  @numbers Map.new(
             ~w(received mbit gap_max_ms decoded decode_ms decode_max_ms drawn shown draw_max_ms queue_max rtt_ms delay_ms late_max_ms elapsed_ms visible recoveries)a,
             &{Atom.to_string(&1), &1}
           )

  @doc false
  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts), do: Agent.start_link(&:queue.new/0, name: __MODULE__)

  @doc "Keeps a page's sample, its numbers with the viewer's id and the time."
  @spec put(term(), map()) :: :ok
  def put(viewer, sample) when is_map(sample) do
    numbers =
      for {key, value} <- sample,
          is_map_key(@numbers, key),
          is_number(value),
          into: %{},
          do: {@numbers[key], value}

    sample = Map.merge(numbers, %{viewer: viewer, at: System.system_time(:millisecond)})

    Agent.cast(__MODULE__, fn queue ->
      queue = :queue.in(sample, queue)
      if :queue.len(queue) > @keep, do: :queue.drop(queue), else: queue
    end)
  end

  @doc "The samples kept, the oldest first."
  @spec samples() :: [map()]
  def samples, do: Agent.get(__MODULE__, &:queue.to_list/1)
end
