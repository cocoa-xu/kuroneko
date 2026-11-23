defmodule Kuroneko.VirtualDisk.Cue do
  @moduledoc """
  CUE sheets: the tracks of a CD, and the files that hold their sectors.

  A sheet whose tracks are all in one BIN file, without gaps it leaves to
  the player to make, goes in the drive as it is: its tracks tell the kernel
  where each one is in the file. Any other sheet (a file a track, WAVE or
  AIFF files, `PREGAP` or `POSTGAP`) is laid out first as one image of the
  disc's sectors (`layout/1`, `write/3`).

  The drive takes audio tracks and data tracks of mode 1 and mode 2, as
  `Kuroneko.Gadget.Storage` does. Audio comes from raw CD audio (`BINARY`),
  its big-endian form (`MOTOROLA`), or WAVE and AIFF files of CD audio: 44.1
  kHz, 16 bits, stereo (`Kuroneko.VirtualDisk.Cue.Audio`).
  """

  alias Kuroneko.VirtualDisk.Cue.Audio

  @modes %{
    "AUDIO" => {:audio, 2352},
    "MODE1/2048" => {:mode1, 2048},
    "MODE1/2352" => {:mode1, 2352},
    "MODE2/2336" => {:mode2, 2336},
    "MODE2/2352" => {:mode2, 2352},
    "CDI/2336" => {:mode2, 2336},
    "CDI/2352" => {:mode2, 2352}
  }
  @file_types %{"BINARY" => :binary, "MOTOROLA" => :motorola, "WAVE" => :wave, "AIFF" => :aiff}
  @flags %{"DCP" => :copy_permitted, "PRE" => :pre_emphasis, "4CH" => :four_channel}
  @gaps ["INDEX", "PREGAP", "POSTGAP", "FLAGS"]

  @typedoc """
  A track as the sheet gives it: the file it is in and the file's type, its
  mode and the size of its sectors there, its indexes in sectors from the
  start of the file, and the silence before and after it that no file
  holds.
  """
  @type track() :: %{
          number: 1..99,
          mode: :audio | :mode1 | :mode2,
          size: 2048 | 2336 | 2352,
          file: Path.t(),
          type: :binary | :motorola | :wave | :aiff,
          indexes: %{non_neg_integer() => non_neg_integer()},
          pregap: non_neg_integer(),
          postgap: non_neg_integer(),
          flags: [:copy_permitted | :pre_emphasis | :four_channel]
        }

  @typedoc """
  Where the image's bytes come from, in order: a part of a file, from a byte
  offset (`:swap` for big-endian audio), or silence.
  """
  @type piece() ::
          {:file, Path.t(), non_neg_integer(), non_neg_integer(), :copy | :swap}
          | {:zeros, non_neg_integer()}

  @doc "The tracks of a sheet, its files in `dir` unless it names them whole."
  @spec parse(String.t(), Path.t()) :: {:ok, [track()]} | {:error, term()}
  def parse(text, dir) do
    text
    |> String.replace_prefix("﻿", "")
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{file: nil, tracks: []}}, fn {line, number}, {:ok, acc} ->
      case command(String.trim(line), acc, dir) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:line, number, reason}}}
      end
    end)
    |> case do
      {:ok, %{tracks: []}} -> {:error, :no_tracks}
      {:ok, %{tracks: tracks}} -> check(Enum.reverse(tracks))
      error -> error
    end
  end

  defp command("", acc, _dir), do: {:ok, acc}

  defp command(line, acc, dir) do
    {keyword, rest} =
      case String.split(line, ~r/\s+/, parts: 2) do
        [keyword, rest] -> {String.upcase(keyword), rest}
        [keyword] -> {String.upcase(keyword), ""}
      end

    command(keyword, rest, acc, dir)
  end

  defp command("FILE", rest, acc, dir) do
    with {:ok, name, type} <- file_name(rest),
         {:ok, type} <- fetch(@file_types, String.upcase(type), :file_type),
         do: {:ok, %{acc | file: {Path.expand(name, dir), type}}}
  end

  defp command("TRACK", _rest, %{file: nil}, _dir), do: {:error, :track_without_file}

  defp command("TRACK", rest, %{file: {path, type}} = acc, _dir) do
    with [number, mode] <- String.split(rest),
         {number, ""} when number in 1..99 <- Integer.parse(number),
         {:ok, {mode, size}} <- fetch(@modes, String.upcase(mode), :mode),
         :ok <-
           if(type == :binary or mode == :audio, do: :ok, else: {:error, :data_in_audio_file}) do
      track = %{
        number: number,
        mode: mode,
        size: size,
        file: path,
        type: type,
        indexes: %{},
        pregap: 0,
        postgap: 0,
        flags: []
      }

      {:ok, %{acc | tracks: [track | acc.tracks]}}
    else
      {:error, reason} -> {:error, reason}
      _bad -> {:error, :track}
    end
  end

  defp command(keyword, rest, %{tracks: [track | tracks]} = acc, _dir) when keyword in @gaps do
    with {:ok, track} <- track_command(keyword, rest, track),
         do: {:ok, %{acc | tracks: [track | tracks]}}
  end

  defp command(keyword, _rest, _acc, _dir) when keyword in @gaps, do: {:error, :before_track}

  # CATALOG, ISRC, CD-TEXT and remarks: nothing the drive needs.
  defp command(_keyword, _rest, acc, _dir), do: {:ok, acc}

  defp track_command("INDEX", rest, track) do
    with [number, time] <- String.split(rest),
         {number, ""} when number in 0..99 <- Integer.parse(number),
         {:ok, sector} <- msf(time) do
      {:ok, %{track | indexes: Map.put(track.indexes, number, sector)}}
    else
      {:error, reason} -> {:error, reason}
      _bad -> {:error, :index}
    end
  end

  defp track_command("FLAGS", rest, track) do
    flags =
      for flag <- String.split(String.upcase(rest)), Map.has_key?(@flags, flag), do: @flags[flag]

    {:ok, %{track | flags: Enum.uniq(flags)}}
  end

  defp track_command(gap, rest, track) do
    with {:ok, sectors} <- msf(String.trim(rest)),
         do: {:ok, Map.put(track, if(gap == "PREGAP", do: :pregap, else: :postgap), sectors)}
  end

  # "name with spaces.bin" BINARY, or name.bin BINARY
  defp file_name(rest) do
    case Regex.run(~r/^"([^"]*)"\s+(\S+)$|^(\S+)\s+(\S+)$/, String.trim(rest)) do
      [_all, name, type] -> {:ok, name, type}
      [_all, "", "", name, type] -> {:ok, name, type}
      _bad -> {:error, :file}
    end
  end

  defp fetch(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, reason}
    end
  end

  @doc false
  # mm:ss:ff, in the CD's sectors of 1/75 s
  @spec msf(String.t()) :: {:ok, non_neg_integer()} | {:error, :time}
  def msf(time) do
    with [m, s, f] <- String.split(time, ":"),
         {m, ""} when m >= 0 <- Integer.parse(m),
         {s, ""} when s in 0..59 <- Integer.parse(s),
         {f, ""} when f in 0..74 <- Integer.parse(f) do
      {:ok, (m * 60 + s) * 75 + f}
    else
      _bad -> {:error, :time}
    end
  end

  # Numbered one after the other, each with an index 1 not before its index
  # 0, and in its file after the tracks before it there.
  defp check(tracks) do
    tracks
    |> Enum.with_index()
    |> Enum.find_value(fn {track, i} -> problem(track, Enum.take(tracks, i)) end)
    |> case do
      nil -> {:ok, tracks}
      reason -> {:error, {:track, reason}}
    end
  end

  defp problem(track, before) do
    previous = List.last(before)
    in_file = Enum.filter(before, &(&1.file == track.file))

    cond do
      not Map.has_key?(track.indexes, 1) -> {track.number, :no_index_1}
      first(track) > track.indexes[1] -> {track.number, :index_order}
      previous && track.number != previous.number + 1 -> {track.number, :number}
      Enum.any?(in_file, &(first(&1) >= first(track))) -> {track.number, :index_order}
      true -> nil
    end
  end

  # A track's first sector in its file: index 0, else index 1.
  defp first(track), do: Map.get(track.indexes, 0, track.indexes[1])

  @doc """
  How the drive takes the tracks: `{:direct, bin, tracks}` when one BIN
  file holds them as the disc has them, with the tracks for
  `Kuroneko.Gadget.Storage`; else `{:layout, pieces, tracks}`, the pieces of
  one image to write (`write/3`) and the tracks in it. Reads the sizes, and
  the headers of WAVE and AIFF files.
  """
  @spec layout([track()]) ::
          {:ok, {:direct, Path.t(), [map()]} | {:layout, [piece()], [map()]}}
          | {:error, term()}
  def layout(tracks) do
    files = tracks |> Enum.map(& &1.file) |> Enum.uniq()
    offsets = file_offsets(tracks)

    with {:ok, sources} <- sources(tracks) do
      if match?([_one], files) and Enum.all?(tracks, &(&1.type == :binary)) and
           Enum.all?(tracks, &(&1.pregap == 0 and &1.postgap == 0)),
         do:
           {:ok, {:direct, hd(files), Enum.map(tracks, &table_track(&1, offsets[&1.number], 0))}},
         else: {:ok, laid_out(tracks, offsets, sources)}
    end
  end

  # Where each track starts in its file, in bytes: after the sectors of the
  # tracks before it there, each of its own size.
  defp file_offsets(tracks) do
    tracks
    |> Enum.group_by(& &1.file)
    |> Enum.flat_map(fn {_file, in_file} ->
      {offsets, _end} =
        Enum.map_reduce(in_file, {0, 0, nil}, fn track, {offset, sector, size} ->
          offset = offset + (first(track) - sector) * (size || track.size)
          {{track.number, offset}, {offset, first(track), track.size}}
        end)

      offsets
    end)
    |> Map.new()
  end

  # Each file's data: where it starts, its bytes, and whether its samples
  # are big-endian.
  defp sources(tracks) do
    tracks
    |> Enum.map(&{&1.file, &1.type})
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn {file, type}, {:ok, acc} ->
      case source(file, type) do
        {:ok, data} -> {:cont, {:ok, Map.put(acc, file, data)}}
        {:error, reason} -> {:halt, {:error, {Path.basename(file), reason}}}
      end
    end)
  end

  defp source(file, type) when type in [:binary, :motorola] do
    with {:ok, %{size: size}} <- File.stat(file),
         do: {:ok, {0, size, if(type == :motorola, do: :swap, else: :copy)}}
  end

  defp source(file, :wave), do: Audio.wave(file)
  defp source(file, :aiff), do: Audio.aiff(file)

  defp table_track(track, offset, silence) do
    %{
      number: track.number,
      mode: track.mode,
      size: track.size,
      offset: offset,
      pregap: silence + track.indexes[1] - first(track),
      flags: track.flags
    }
  end

  # One image: each track's silence before, its sectors from its file up to
  # the next track there or the file's end, its silence after.
  defp laid_out(tracks, offsets, sources) do
    {pieces, table, _at} =
      Enum.reduce(tracks, {[], [], 0}, fn track, {pieces, table, at} ->
        {data, data_bytes, order} = sources[track.file]
        next = Enum.find(tracks, &(&1.file == track.file and &1.number > track.number))
        to = if next, do: offsets[next.number], else: data_bytes
        bytes = div(max(to - offsets[track.number], 0), track.size) * track.size
        before = track.pregap * track.size
        after_ = track.postgap * track.size

        parts = [
          {:zeros, before},
          {:file, track.file, data + offsets[track.number], bytes, order},
          {:zeros, after_}
        ]

        {pieces ++ Enum.reject(parts, &(piece_size(&1) == 0)),
         table ++ [table_track(track, at, track.pregap)], at + before + bytes + after_}
      end)

    {:layout, pieces, table}
  end

  @doc "The bytes of the image the pieces make."
  @spec size([piece()]) :: non_neg_integer()
  def size(pieces), do: pieces |> Enum.map(&piece_size/1) |> Enum.sum()

  defp piece_size({:zeros, bytes}), do: bytes
  defp piece_size({:file, _file, _from, bytes, _order}), do: bytes

  @chunk 1_048_576

  @doc """
  Writes the image the pieces make, telling `progress` the bytes written
  after each MiB at most.
  """
  @spec write([piece()], Path.t(), (non_neg_integer() -> any())) :: :ok | {:error, term()}
  def write(pieces, path, progress \\ fn _bytes -> :ok end) do
    with {:ok, out} <- File.open(path, [:write, :binary, :raw]) do
      result =
        Enum.reduce_while(pieces, {:ok, 0}, fn piece, {:ok, done} ->
          case write_piece(out, piece, done, progress) do
            {:ok, done} -> {:cont, {:ok, done}}
            error -> {:halt, error}
          end
        end)

      closed = File.close(out)
      with {:ok, _done} <- result, do: closed
    end
  end

  defp write_piece(out, {:zeros, bytes}, done, progress) do
    zeros = :binary.copy(<<0>>, min(bytes, @chunk))
    each_chunk(bytes, done, progress, fn n, _at -> IO.binwrite(out, binary_part(zeros, 0, n)) end)
  end

  defp write_piece(out, {:file, file, from, bytes, order}, done, progress) do
    with {:ok, input} <- File.open(file, [:read, :binary, :raw]) do
      result =
        each_chunk(bytes, done, progress, fn n, at ->
          case :file.pread(input, from + at, n) do
            {:ok, data} when byte_size(data) == n ->
              IO.binwrite(out, if(order == :swap, do: swap(data), else: data))

            _short ->
              {:error, :short_file}
          end
        end)

      File.close(input)
      result
    end
  end

  # Calls write with each MiB, at most, of bytes and where it is.
  defp each_chunk(bytes, done, progress, write) do
    Enum.reduce_while(Stream.iterate(0, &(&1 + @chunk)), {:ok, done}, fn at, {:ok, done} ->
      n = min(@chunk, bytes - at)

      with true <- n > 0 || {:halt, {:ok, done}},
           :ok <- write.(n, at) do
        progress.(done + n)
        {:cont, {:ok, done + n}}
      else
        {:halt, _done} = halt -> halt
        error -> {:halt, error}
      end
    end)
  end

  # Big-endian 16-bit samples to the CD's little-endian ones.
  defp swap(data), do: for(<<a, b <- data>>, into: <<>>, do: <<b, a>>)
end
