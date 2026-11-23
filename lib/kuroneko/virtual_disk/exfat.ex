defmodule Kuroneko.VirtualDisk.ExFAT do
  @moduledoc """
  An empty exFAT file system in a file, without a partition table, made by
  exfatprogs' `mkfs.exfat`. exFAT holds files of any size, and Windows,
  macOS and Linux 5.7 or later read and write it.

  The file is sparse: it takes room as files go in.
  """

  import Bitwise

  @label_bytes 22

  @doc "Whether this system makes and mounts exFAT: `mkfs.exfat` and the kernel's driver."
  @spec available?() :: boolean()
  def available? do
    case File.read("/proc/filesystems") do
      {:ok, filesystems} ->
        String.contains?(filesystems, "\texfat\n") and System.find_executable("mkfs.exfat") != nil

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Makes `path` an empty exFAT file system of `size` bytes. Option: `:label`,
  the volume's name, of 11 characters at most.
  """
  @spec format(Path.t(), pos_integer(), keyword()) :: :ok | {:error, term()}
  def format(path, size, opts \\ []) do
    with :ok <- sparse_file(path, size),
         :ok <- mkfs(path, size) do
      set_label(path, opts[:label])
    end
  end

  @doc false
  # Clusters of 32 KiB at most, as FAT32's: a file wastes no more than that.
  @spec cluster_size(pos_integer()) :: pos_integer()
  def cluster_size(size) when size < 256 * 1024 * 1024, do: 4 * 1024
  def cluster_size(_size), do: 32 * 1024

  @doc false
  # The volume label is written here and not by mkfs.exfat, which reads it in
  # the C locale: no characters beyond ASCII.
  @spec set_label(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  def set_label(path, label) do
    case label_bytes(label) do
      "" ->
        :ok

      bytes ->
        File.open(path, [:read, :write, :binary, :raw], &write_label(&1, bytes)) |> unwrap()
    end
  end

  defp sparse_file(path, size) do
    with {:ok, file} <- File.open(path, [:write, :binary, :raw]) do
      try do
        with {:ok, _position} <- :file.position(file, size), do: :file.truncate(file)
      after
        File.close(file)
      end
    end
  end

  defp mkfs(path, size) do
    args = ["-c", Integer.to_string(cluster_size(size)), path]

    case System.find_executable("mkfs.exfat") do
      nil ->
        {:error, :no_exfat}

      mkfs ->
        case System.cmd(mkfs, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, {:mkfs, String.trim(output)}}
        end
    end
  end

  defp write_label(file, bytes) do
    with {:ok,
          <<_jump::binary-size(3), "EXFAT   ", _::binary-size(77), heap::little-32,
            _clusters::little-32, root::little-32, _::binary-size(8), sector_shift, cluster_shift,
            _::binary>>} <- :file.pread(file, 0, 512),
         cluster = 1 <<< (sector_shift + cluster_shift),
         offset = (heap <<< sector_shift) + (root - 2) * cluster,
         {:ok, entries} <- :file.pread(file, offset, cluster),
         {:ok, index} <- label_slot(entries) do
      entry =
        <<0x83, div(byte_size(bytes), 2), bytes::binary,
          0::size(@label_bytes * 8 - bit_size(bytes)), 0::64>>

      :file.pwrite(file, offset + index * 32, entry)
    else
      {:ok, _other} -> {:error, :not_exfat}
      error -> error
    end
  end

  # The volume label's entry, used or not, else the end of the directory.
  defp label_slot(entries) do
    entries
    |> chunks()
    |> Enum.find_index(fn <<type, _::binary>> -> type in [0x83, 0x03, 0x00] end)
    |> case do
      nil -> {:error, :root_directory_full}
      index -> {:ok, index}
    end
  end

  defp chunks(<<entry::binary-size(32), rest::binary>>), do: [entry | chunks(rest)]
  defp chunks(_rest), do: []

  # UTF-16 for 11 characters at most, without those no exFAT name takes.
  defp label_bytes(nil), do: ""

  defp label_bytes(label) do
    label
    |> String.trim()
    |> String.to_charlist()
    |> Enum.reject(&(&1 < 32 or &1 in ~c"\"*/:<>?\\|"))
    |> Enum.reduce_while("", fn char, bytes ->
      next = bytes <> :unicode.characters_to_binary([char], :unicode, {:utf16, :little})
      if byte_size(next) <= @label_bytes, do: {:cont, next}, else: {:halt, bytes}
    end)
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap(error), do: error
end
