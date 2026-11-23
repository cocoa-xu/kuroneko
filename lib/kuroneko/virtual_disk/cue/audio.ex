defmodule Kuroneko.VirtualDisk.Cue.Audio do
  @moduledoc """
  Where the samples of a WAVE or an AIFF file are, when they are CD audio:
  PCM, 44.1 kHz, 16 bits, two channels. A CD has them as they are in a WAVE
  file, least significant byte first; AIFF has them the other way round,
  but for AIFF-C's `sowt`.
  """

  # 44100 as the 80-bit extended float of AIFF's COMM chunk
  @rate_44100 <<0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0>>

  @typedoc "Where the samples start, their bytes, and their byte order."
  @type samples() :: {non_neg_integer(), non_neg_integer(), :copy | :swap}

  @doc "The samples of a WAVE file."
  @spec wave(Path.t()) :: {:ok, samples()} | {:error, term()}
  def wave(path) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(file, 0, 12) do
          {:ok, <<"RIFF", _size::little-32, "WAVE">>} -> wave_chunks(file, 12, nil)
          _other -> {:error, :not_wave}
        end
      after
        File.close(file)
      end
    end
  end

  defp wave_chunks(file, at, format) do
    case :file.pread(file, at, 8) do
      {:ok, <<"fmt ", size::little-32>>} ->
        with {:ok, fmt} <- :file.pread(file, at + 8, size),
             do: wave_chunks(file, at + 8 + size + rem(size, 2), wave_format(fmt))

      {:ok, <<"data", size::little-32>>} when format == :cd ->
        {:ok, {at + 8, size, :copy}}

      {:ok, <<"data", _size::little-32>>} ->
        {:error, :not_cd_audio}

      {:ok, <<_id::binary-size(4), size::little-32>>} ->
        wave_chunks(file, at + 8 + size + rem(size, 2), format)

      _end ->
        {:error, :no_samples}
    end
  end

  # PCM, or WAVE_FORMAT_EXTENSIBLE of PCM
  defp wave_format(
         <<tag::little-16, 2::little-16, 44_100::little-32, _rate::32, 4::little-16,
           16::little-16, rest::binary>>
       )
       when tag == 1 or
              (tag == 0xFFFE and binary_part(rest, 8, 2) == <<1, 0>>),
       do: :cd

  defp wave_format(_fmt), do: :other

  @doc "The samples of an AIFF or AIFF-C file."
  @spec aiff(Path.t()) :: {:ok, samples()} | {:error, term()}
  def aiff(path) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(file, 0, 12) do
          {:ok, <<"FORM", _size::32, kind::binary-size(4)>>} when kind in ["AIFF", "AIFC"] ->
            aiff_chunks(file, 12, nil)

          _other ->
            {:error, :not_aiff}
        end
      after
        File.close(file)
      end
    end
  end

  defp aiff_chunks(file, at, order) do
    case :file.pread(file, at, 8) do
      {:ok, <<"COMM", size::32>>} ->
        with {:ok, comm} <- :file.pread(file, at + 8, size),
             do: aiff_chunks(file, at + 8 + size + rem(size, 2), aiff_order(comm))

      {:ok, <<"SSND", size::32>>} when order in [:copy, :swap] ->
        with {:ok, <<offset::32, _block::32>>} <- :file.pread(file, at + 8, 8),
             do: {:ok, {at + 16 + offset, size - 8 - offset, order}}

      {:ok, <<"SSND", _size::32>>} ->
        {:error, :not_cd_audio}

      {:ok, <<_id::binary-size(4), size::32>>} ->
        aiff_chunks(file, at + 8 + size + rem(size, 2), order)

      _end ->
        {:error, :no_samples}
    end
  end

  defp aiff_order(<<2::16, _frames::32, 16::16, @rate_44100, rest::binary>>) do
    case rest do
      <<"sowt", _name::binary>> -> :copy
      <<"NONE", _name::binary>> -> :swap
      "" -> :swap
      _other -> :other
    end
  end

  defp aiff_order(_comm), do: :other
end
