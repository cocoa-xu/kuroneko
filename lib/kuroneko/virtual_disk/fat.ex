defmodule Kuroneko.VirtualDisk.FAT do
  @moduledoc """
  An empty FAT32 file system in a file, without a partition table, as on
  many USB sticks: the target computer mounts it as a removable drive.

  Only what is not zero is written: the boot sectors, the FSInfo sectors,
  their backups, the start of both FATs and the volume label. The rest of
  the file is a hole, so a large image takes room only as files go in.
  Cluster and FAT sizes follow Microsoft's FAT specification.
  """

  @sector 512
  @reserved 32
  @fats 2
  @min_clusters 65_525
  @max_clusters 0x0FFFFFF5

  @doc "The smallest image this makes: 64 MiB, room for FAT32's least clusters."
  @spec min_size() :: pos_integer()
  def min_size, do: 64 * 1024 * 1024

  @doc """
  Makes `path` an empty FAT32 file system of `size` bytes (rounded down to
  whole sectors). Option: `:label`, the volume's name (11 characters of
  A-Z, 0-9, spaces and a few symbols are kept; others become `_`).
  """
  @spec format(Path.t(), pos_integer(), keyword()) :: :ok | {:error, term()}
  def format(path, size, opts \\ []) do
    sectors = div(size, @sector)

    with {:ok, layout} <- layout(sectors),
         {:ok, file} <- File.open(path, [:write, :binary, :raw]) do
      try do
        write_all(file, layout, sectors, label(opts[:label]))
      after
        File.close(file)
      end
    end
  end

  @doc false
  @spec layout(non_neg_integer()) :: {:ok, map()} | {:error, :too_small | :too_large}
  def layout(sectors) do
    per_cluster = sectors_per_cluster(sectors)
    # Microsoft's formula: a FAT just large enough for the clusters it maps.
    divisor = div(256 * per_cluster + @fats, 2)
    fat = div(sectors - @reserved + divisor - 1, divisor)
    clusters = div(sectors - @reserved - @fats * fat, per_cluster)

    cond do
      clusters < @min_clusters -> {:error, :too_small}
      clusters >= @max_clusters -> {:error, :too_large}
      true -> {:ok, %{per_cluster: per_cluster, fat: fat, clusters: clusters}}
    end
  end

  # Cluster sizes by volume size, from the specification's table.
  defp sectors_per_cluster(sectors) when sectors <= 532_480, do: 1
  defp sectors_per_cluster(sectors) when sectors <= 16_777_216, do: 8
  defp sectors_per_cluster(sectors) when sectors <= 33_554_432, do: 16
  defp sectors_per_cluster(sectors) when sectors <= 67_108_864, do: 32
  defp sectors_per_cluster(_sectors), do: 64

  defp write_all(file, layout, sectors, label) do
    boot = boot_sector(layout, sectors, label)
    info = fs_info(layout.clusters - 1)
    # The third boot sector: only its signature.
    third = <<0::size(510 * 8), 0x55, 0xAA>>
    # Media byte, end of chain, and the root directory's one cluster.
    fat = <<0x0FFFFFF8::little-32, 0x0FFFFFFF::little-32, 0x0FFFFFFF::little-32>>
    data = (@reserved + @fats * layout.fat) * @sector

    writes =
      [{0, boot}, {@sector, info}, {2 * @sector, third}] ++
        [{6 * @sector, boot}, {7 * @sector, info}, {8 * @sector, third}] ++
        for(n <- 0..(@fats - 1), do: {(@reserved + n * layout.fat) * @sector, fat}) ++
        if(label, do: [{data, label_entry(label)}], else: [])

    with :ok <- Enum.reduce_while(writes, :ok, &pwrite(file, &1, &2)),
         {:ok, _} <- :file.position(file, sectors * @sector) do
      :file.truncate(file)
    end
  end

  defp pwrite(file, {offset, bytes}, :ok) do
    case :file.pwrite(file, offset, bytes) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp boot_sector(layout, sectors, label) do
    <<
      0xEB,
      0x58,
      0x90,
      "KURONEKO",
      @sector::little-16,
      layout.per_cluster,
      @reserved::little-16,
      @fats,
      0::little-16,
      0::little-16,
      0xF8,
      0::little-16,
      63::little-16,
      255::little-16,
      0::little-32,
      sectors::little-32,
      layout.fat::little-32,
      0::little-16,
      0::little-16,
      2::little-32,
      1::little-16,
      6::little-16,
      0::size(12 * 8),
      0x80,
      0,
      0x29,
      :crypto.strong_rand_bytes(4)::binary,
      label || "NO NAME    "::binary-size(11),
      "FAT32   ",
      # Boot code that waits forever: this disk does not start a computer.
      0xEB,
      0xFE,
      0::size(418 * 8),
      0x55,
      0xAA
    >>
  end

  defp fs_info(free) do
    <<0x41615252::little-32, 0::size(480 * 8), 0x61417272::little-32, free::little-32,
      3::little-32, 0::size(12 * 8), 0xAA550000::little-32>>
  end

  defp label_entry(label), do: <<label::binary-size(11), 0x08, 0::size(20 * 8)>>

  defp label(nil), do: nil

  defp label(name) do
    chars =
      name
      |> String.upcase()
      |> String.to_charlist()
      |> Enum.map(fn c ->
        if c in ?A..?Z or c in ?0..?9 or c in ~c" !#$%&'()-@^_`{}~", do: c, else: ?_
      end)
      |> Enum.take(11)

    if Enum.all?(chars, &(&1 in ~c"_ ")),
      do: nil,
      else: chars |> List.to_string() |> String.pad_trailing(11)
  end
end
