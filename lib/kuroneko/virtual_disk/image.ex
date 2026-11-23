defmodule Kuroneko.VirtualDisk.Image do
  @moduledoc """
  What an image file holds, read from its own structures: the file systems
  of an optical disc (ISO 9660, Joliet, UDF with its revision), the El
  Torito boot entries, and a partition table at its start, from which a USB
  drive boots.

  The disc an optical image belongs on follows from its format, as the disc
  specifications set them: UDF 2.50 and later is the Blu-ray format, other
  UDF the DVD format (the UDF Bridge of DVD-ROM), ISO 9660 alone the CD
  format. An image with more sectors than its disc can hold came from a
  larger one: ISO 9660 past a CD's 99 minutes from a DVD, past a two-layer
  DVD from a BD. The number of layers is not in an image either; a DVD that
  holds more than one layer has two.
  """

  import Bitwise

  @sector 2048
  @cd_sectors 99 * 60 * 75
  @dvd_layer_sectors 2_295_104
  @dvd_sectors 4_173_824

  @typedoc "An optical disc."
  @type disc() :: :cd | :dvd | :bd

  @type t() :: %{
          sectors: non_neg_integer(),
          iso9660: boolean(),
          joliet: boolean(),
          udf: String.t() | nil,
          udf_access: :read_only | :write_once | :rewritable | :overwritable | :other | nil,
          label: String.t() | nil,
          boot: [:bios | :uefi | :other],
          partitions: :mbr | :gpt | nil,
          disc: disc() | nil,
          layers: pos_integer() | nil
        }

  @doc "Reads what `path` holds; `disc` is `nil` when it is no optical disc image."
  @spec probe(Path.t()) :: {:ok, t()} | {:error, term()}
  def probe(path) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        {:ok, %{size: size}} = File.stat(path)
        {:ok, read(file, div(size, @sector))}
      after
        File.close(file)
      end
    end
  end

  defp read(file, sectors) do
    descriptors = descriptors(file, 16, [])
    primary = Enum.find_value(descriptors, &(match?({:iso9660, 1, _}, &1) && elem(&1, 2)))
    joliet = Enum.find(descriptors, &joliet?/1)
    udf = if Enum.any?(descriptors, &(&1 in [{:udf, "NSR02"}, {:udf, "NSR03"}])), do: udf(file)
    boot = Enum.find_value(descriptors, [], &boot_catalog/1) |> boot_platforms(file)
    disc = disc(udf && udf.revision, primary != nil, sectors)

    %{
      sectors: sectors,
      iso9660: primary != nil,
      joliet: joliet != nil,
      udf: udf && udf.revision && revision(udf.revision),
      udf_access: udf && udf.access,
      label:
        (udf && udf.label) || (joliet && joliet_label(joliet)) ||
          (primary && iso_label(primary)),
      boot: boot,
      partitions: partitions(file),
      disc: disc,
      layers: layers(disc, sectors)
    }
  end

  @doc false
  # The disc for a UDF revision (0x0250, 0 when unknown, nil without UDF),
  # ISO 9660 or not, and the number of sectors.
  @spec disc(non_neg_integer() | nil, boolean(), non_neg_integer()) :: disc() | nil
  def disc(udf, iso9660, sectors) do
    cond do
      udf != nil and udf >= 0x0250 -> :bd
      udf != nil -> if sectors > @dvd_sectors, do: :bd, else: :dvd
      iso9660 and sectors <= @cd_sectors -> :cd
      iso9660 and sectors <= @dvd_sectors -> :dvd
      iso9660 -> :bd
      true -> nil
    end
  end

  defp layers(:dvd, sectors) when sectors > @dvd_layer_sectors, do: 2
  defp layers(disc, _sectors) when disc in [:cd, :dvd], do: 1
  defp layers(_disc, _sectors), do: nil

  # The volume descriptors from sector 16: ISO 9660's set, then UDF's
  # recognition sequence.
  defp descriptors(file, sector, acc) when sector < 64 do
    case pread(file, sector * @sector, @sector) do
      <<type, "CD001", _version, _::binary>> = data when type != 255 ->
        descriptors(file, sector + 1, [{:iso9660, type, data} | acc])

      <<255, "CD001", _::binary>> ->
        descriptors(file, sector + 1, acc)

      <<0, id::binary-size(5), _::binary>>
      when id in ["BEA01", "NSR02", "NSR03", "TEA01", "BOOT2"] ->
        descriptors(file, sector + 1, [{:udf, id} | acc])

      _other ->
        Enum.reverse(acc)
    end
  end

  defp descriptors(_file, _sector, acc), do: Enum.reverse(acc)

  defp iso_label(<<_::binary-size(40), id::binary-size(32), _::binary>>),
    do: blank(String.trim(id))

  # A supplementary descriptor with one of Joliet's escape sequences.
  defp joliet?({:iso9660, 2, <<_::binary-size(88), esc::binary-size(3), _::binary>>}),
    do: esc in ["%/@", "%/C", "%/E"]

  defp joliet?(_descriptor), do: false

  defp joliet_label({:iso9660, 2, <<_::binary-size(40), id::binary-size(32), _::binary>>}),
    do: id |> utf16() |> String.trim() |> blank()

  defp boot_catalog(
         {:iso9660, 0,
          <<0, "CD001", 1, "EL TORITO SPECIFICATION", _::binary-size(41), lba::little-32,
            _::binary>>}
       ),
       do: lba

  defp boot_catalog(_descriptor), do: nil

  # The platforms of the bootable entries: the default one, then sections.
  defp boot_platforms([], _file), do: []

  defp boot_platforms(lba, file) do
    case pread(file, lba * @sector, @sector) do
      <<1, platform, _::binary-size(28), 0x55, 0xAA, default::binary-size(32), rest::binary>> ->
        initial = if bootable?(default), do: [platform(platform)], else: []
        Enum.uniq(initial ++ sections(rest))

      _other ->
        []
    end
  end

  defp sections(<<header, platform, count::little-16, _::binary-size(28), rest::binary>>)
       when header in [0x90, 0x91] do
    {entries, rest} = section_entries(rest, count, [])
    found = if Enum.any?(entries, &bootable?/1), do: [platform(platform)], else: []
    if header == 0x90, do: found ++ sections(rest), else: found
  end

  defp sections(_rest), do: []

  defp section_entries(rest, 0, acc), do: {acc, rest}

  defp section_entries(<<0x44, _::binary-size(31), rest::binary>>, count, acc),
    do: section_entries(rest, count, acc)

  defp section_entries(<<entry::binary-size(32), rest::binary>>, count, acc),
    do: section_entries(rest, count - 1, [entry | acc])

  defp section_entries(_rest, _count, acc), do: {acc, ""}

  defp bootable?(<<0x88, _::binary>>), do: true
  defp bootable?(_entry), do: false

  defp platform(0), do: :bios
  defp platform(0xEF), do: :uefi
  defp platform(_other), do: :other

  # UDF's anchor at sector 256 points to the main volume descriptors: the
  # logical volume (domain revision, name) and the partition (access).
  defp udf(file) do
    with <<2::little-16, _::binary-size(14), length::little-32, location::little-32, _::binary>> <-
           pread(file, 256 * @sector, @sector) do
      Enum.reduce_while(
        0..(div(length, @sector) - 1)//1,
        %{revision: nil, access: nil, label: nil},
        fn i, udf ->
          case pread(file, (location + i) * @sector, @sector) do
            <<6::little-16, _::binary-size(82), name::binary-size(128), _::binary-size(5),
              "*OSTA UDF Compliant", _::binary-size(4), revision::little-16, _::binary>> ->
              {:cont, %{udf | revision: revision, label: dstring(name)}}

            <<5::little-16, _::binary-size(182), access::little-32, _::binary>> ->
              {:cont, %{udf | access: access(access)}}

            <<8::little-16, _::binary>> ->
              {:halt, udf}

            _other ->
              {:cont, udf}
          end
        end
      )
    else
      _no_anchor -> %{revision: 0, access: nil, label: nil}
    end
  end

  defp revision(0), do: "?"

  defp revision(bcd),
    do: "#{bcd >>> 8}.#{String.pad_leading(Integer.to_string(bcd &&& 0xFF, 16), 2, "0")}"

  defp access(1), do: :read_only
  defp access(2), do: :write_once
  defp access(3), do: :rewritable
  defp access(4), do: :overwritable
  defp access(_other), do: :other

  # A dstring: compression 8 (one byte per character) or 16 (UTF-16BE), the
  # length in its last byte.
  defp dstring(<<_::binary-size(127), 0>>), do: nil

  defp dstring(<<compression, _::binary>> = field) do
    used = :binary.last(field)
    chars = binary_part(field, 1, max(used - 1, 0))

    text =
      case compression do
        8 -> :unicode.characters_to_binary(chars, :latin1)
        16 -> utf16(chars)
        _other -> ""
      end

    blank(String.trim(text))
  end

  defp utf16(bytes) do
    case :unicode.characters_to_binary(bytes, {:utf16, :big}) do
      text when is_binary(text) -> String.trim_trailing(text, <<0>>)
      _invalid -> ""
    end
  end

  defp partitions(file) do
    case pread(file, 0, 1024) do
      <<_::binary-size(512), "EFI PART", _::binary>> -> :gpt
      <<_::binary-size(446), table::binary-size(64), 0x55, 0xAA, _::binary>> -> mbr(table)
      _other -> nil
    end
  end

  defp mbr(table) do
    types = for <<_::binary-size(4), type, _::binary-size(11) <- table>>, do: type
    if Enum.any?(types, &(&1 != 0)), do: :mbr
  end

  defp blank(""), do: nil
  defp blank(text), do: text

  defp pread(file, offset, length) do
    case :file.pread(file, offset, length) do
      {:ok, data} -> data
      _eof_or_error -> ""
    end
  end
end
