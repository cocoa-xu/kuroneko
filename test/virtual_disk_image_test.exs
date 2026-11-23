defmodule Kuroneko.VirtualDisk.ImageTest do
  use ExUnit.Case, async: true

  alias Kuroneko.VirtualDisk.Image

  @moduletag :tmp_dir
  @sector 2048

  # An image of `sectors` sectors with what `parts` puts at their sectors.
  defp image(tmp, name, sectors, parts) do
    path = Path.join(tmp, name)
    {:ok, file} = File.open(path, [:write, :binary])
    for {sector, data} <- parts, do: :ok = :file.pwrite(file, sector * @sector, data)
    {:ok, _} = :file.position(file, sectors * @sector)
    :ok = :file.truncate(file)
    File.close(file)
    path
  end

  defp pad(data, size \\ @sector), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  defp primary(label, sectors) do
    pad(
      <<1, "CD001", 1, 0, String.pad_trailing("", 32)::binary,
        String.pad_trailing(label, 32)::binary, 0::64, sectors::little-32, sectors::big-32>>
    )
  end

  defp joliet(label) do
    id = :unicode.characters_to_binary(label, :utf8, {:utf16, :big})
    pad(<<2, "CD001", 1, 0, 0::256, pad(id, 32)::binary, 0::128, "%/E">>)
  end

  defp boot_record(catalog),
    do:
      pad(
        <<0, "CD001", 1, pad("EL TORITO SPECIFICATION", 32)::binary, 0::256, catalog::little-32>>
      )

  defp terminator, do: pad(<<255, "CD001", 1>>)

  # A BIOS default entry and a section of UEFI entries.
  defp catalog do
    validation = <<1, 0, 0::16, pad("", 24)::binary, 0::16, 0x55, 0xAA>>
    default = pad(<<0x88, 0, 0::16, 0, 0, 4::little-16, 30::little-32>>, 32)
    uefi_header = <<0x91, 0xEF, 1::little-16, pad("", 28)::binary>>
    uefi = pad(<<0x88, 0, 0::16, 0, 0, 0::little-16, 31::little-32>>, 32)
    pad(validation <> default <> uefi_header <> uefi)
  end

  defp vrs(nsr), do: [pad(<<0, "BEA01", 1>>), pad(<<0, nsr::binary, 1>>), pad(<<0, "TEA01", 1>>)]

  defp anchor(location),
    do: pad(<<2::little-16, 0::112, 3 * @sector::little-32, location::little-32>>)

  defp logical_volume(label, revision) do
    name = <<8, label::binary>>
    name = pad(name, 127) <> <<byte_size(label) + 1>>

    pad(
      <<6::little-16, 0::112, 0::32, 0::512, name::binary, @sector::little-32, 0,
        pad("*OSTA UDF Compliant", 23)::binary, revision::little-16>>
    )
  end

  defp partition(access), do: pad(<<5::little-16, 0::size(182 * 8), access::little-32>>)
  defp terminating, do: pad(<<8::little-16>>)

  defp sectors_at(start, list),
    do: list |> Enum.with_index(start) |> Enum.map(fn {d, i} -> {i, d} end)

  test "a Windows installer: ISO 9660, UDF 1.02 and El Torito, two-layer DVD", %{tmp_dir: tmp} do
    parts =
      sectors_at(16, [
        primary("CCCOMA_X64FRE_EN-US_DV9", 2_998_523),
        boot_record(30),
        terminator()
      ]) ++
        sectors_at(19, vrs("NSR02")) ++
        [{30, catalog()}, {256, anchor(257)}] ++
        sectors_at(257, [
          logical_volume("CCCOMA_X64FRE_EN-US_DV9", 0x0102),
          partition(1),
          terminating()
        ])

    assert {:ok, info} = Image.probe(image(tmp, "win.iso", 2_998_523, parts))

    assert %{
             disc: :dvd,
             layers: 2,
             iso9660: true,
             udf: "1.02",
             udf_access: :read_only,
             boot: [:bios, :uefi],
             partitions: nil,
             label: "CCCOMA_X64FRE_EN-US_DV9"
           } = info
  end

  test "ISO 9660 alone is a CD, a DVD past a CD's 99 minutes", %{tmp_dir: tmp} do
    parts = sectors_at(16, [primary("SMALL", 0), joliet("照片 2026"), terminator()])

    assert {:ok, %{disc: :cd, layers: 1, joliet: true, label: "照片 2026"}} =
             Image.probe(image(tmp, "cd.iso", 300_000, parts))

    assert {:ok, %{disc: :dvd, layers: 1}} = Image.probe(image(tmp, "big.iso", 500_000, parts))
  end

  test "UDF 2.50 is the Blu-ray format, whatever its size", %{tmp_dir: tmp} do
    parts =
      sectors_at(16, vrs("NSR03")) ++
        [{256, anchor(257)}] ++
        sectors_at(257, [logical_volume("MOVIE", 0x0250), partition(2), terminating()])

    assert {:ok,
            %{disc: :bd, iso9660: false, udf: "2.50", udf_access: :write_once, label: "MOVIE"}} =
             Image.probe(image(tmp, "bd.iso", 10_000, parts))
  end

  test "a partition table at the start boots as a USB drive", %{tmp_dir: tmp} do
    mbr = pad(<<0::size(446 * 8), 0x80, 0::24, 0x17, 0::size(11 * 8)>>, 510) <> <<0x55, 0xAA>>
    parts = [{0, mbr} | sectors_at(16, [primary("LIVE", 0), terminator()])]
    assert {:ok, %{disc: :cd, partitions: :mbr}} = Image.probe(image(tmp, "live.iso", 400, parts))

    gpt = pad(mbr, 512) <> "EFI PART"

    assert {:ok, %{disc: nil, partitions: :gpt}} =
             Image.probe(image(tmp, "disk.img", 400, [{0, gpt}]))

    assert {:ok, %{disc: nil, partitions: nil}} = Image.probe(image(tmp, "zero.img", 400, []))
  end

  test "the disc of a format" do
    assert Image.disc(0x0102, true, 100) == :dvd
    assert Image.disc(0x0150, false, 100) == :dvd
    assert Image.disc(0x0102, true, 5_000_000) == :bd
    assert Image.disc(0x0260, false, 100) == :bd
    assert Image.disc(0, false, 100) == :dvd
    assert Image.disc(nil, true, 445_500) == :cd
    assert Image.disc(nil, true, 445_501) == :dvd
    assert Image.disc(nil, false, 100) == nil
  end
end
