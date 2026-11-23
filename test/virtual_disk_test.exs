defmodule Kuroneko.VirtualDiskTest do
  use ExUnit.Case, async: true

  alias Kuroneko.VirtualDisk
  alias Kuroneko.VirtualDisk.{ExFAT, FAT}

  @moduletag :tmp_dir
  @gib 1024 * 1024 * 1024

  test "a drive for the page: what the gadget has in it, nil when it is empty" do
    slot = {"disk", 0}
    dvd = %{image: "/root/images/win.iso", as: :dvd, read_only: true, tracks: nil}

    game = %{
      image: "/root/images/game.bin",
      as: :cd,
      read_only: true,
      tracks: [
        %{number: 1, mode: :mode1, size: 2352, offset: 0},
        %{number: 2, mode: :audio, size: 2352, offset: 1_058_400}
      ]
    }

    assert VirtualDisk.drive_medium(nil, {:ok, nil}, slot) == nil
    assert VirtualDisk.drive_medium(%{image: dvd.image, name: "win.iso"}, {:ok, nil}, slot) == nil
    assert VirtualDisk.drive_medium(nil, {:error, :no_storage}, slot) == nil

    assert %{name: "win.iso", kind: :image, cdrom: true, disc: :dvd, remember: false} =
             VirtualDisk.drive_medium(nil, {:ok, dvd}, slot)

    ours = %{image: dvd.image, name: "Windows/win.iso", kind: :image, remember: true, drive: 0}

    assert %{name: "Windows/win.iso", remember: true, storage: "disk", lun: 0} =
             medium = VirtualDisk.drive_medium(ours, {:ok, dvd}, slot)

    refute Map.has_key?(medium, :drive)
    refute Map.has_key?(medium, :as)
    assert %{cdrom: true, disc: :cd, tracks: 2} = VirtualDisk.drive_medium(nil, {:ok, game}, slot)
  end

  test "the library takes relative names without hidden or parent parts" do
    for name <- ["debian.iso", "Photos/2026/a.jpg", "照片/a b.jpg"] do
      assert VirtualDisk.library_path(name) == {:ok, name}, name
    end

    for name <- [
          "",
          "../x",
          "a/../b",
          ".hidden",
          "a/.DS_Store",
          "/etc/passwd",
          "a//b",
          "a/",
          nil,
          1
        ] do
      assert VirtualDisk.library_path(name) == {:error, :invalid_name}, inspect(name)
    end
  end

  test "a folder's drive: its files, room to write when writable, a GiB left free" do
    assert VirtualDisk.drive_size(1000, 3, false, 100 * @gib) == {:ok, FAT.min_size()}

    assert {:ok, size} = VirtualDisk.drive_size(10 * @gib, 100, true, 100 * @gib)
    assert size > 18 * @gib and size < 19 * @gib

    assert {:ok, smaller} = VirtualDisk.drive_size(10 * @gib, 100, true, 12 * @gib)
    assert smaller < 11 * @gib
    assert VirtualDisk.drive_size(10 * @gib, 100, false, 10 * @gib) == {:error, :no_room}
  end

  test "what goes in again after a restart, as it was asked for" do
    for {kind, opts} <- [
          image: [media: :dvd],
          image: [media: :drive, read_only: false],
          image: [],
          folder: [filesystem: :fat32, read_only: true]
        ] do
      json = "照片" |> VirtualDisk.memory(kind, opts) |> Jason.encode!() |> Jason.decode!()
      assert {:ok, %{name: "照片", kind: ^kind, opts: back}} = VirtualDisk.from_memory(json)
      assert Enum.sort(back) == Enum.sort(opts)
    end

    odd = %{
      "name" => "x",
      "kind" => "image",
      "opts" => %{"media" => "floppy", "read_only" => "yes"}
    }

    assert VirtualDisk.from_memory(odd) == {:ok, %{name: "x", kind: :image, opts: []}}
    assert VirtualDisk.from_memory(%{"name" => "x", "kind" => "tape", "opts" => %{}}) == :error
  end

  test "names no drive takes", %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "ok/照片"))
    File.write!(Path.join(tmp, "ok/照片/a b (1).jpg"), "")
    assert VirtualDisk.bad_name(Path.join(tmp, "ok")) == nil

    File.mkdir_p!(Path.join(tmp, "odd/sub"))
    File.write!(Path.join(tmp, "odd/sub/what?.txt"), "")
    assert VirtualDisk.bad_name(Path.join(tmp, "odd")) == "sub/what?.txt"
  end

  test "copies a folder's files and folders with their times, not its links", %{tmp_dir: tmp} do
    from = Path.join(tmp, "from")
    to = Path.join(tmp, "to")
    File.mkdir_p!(Path.join(from, "sub/深"))
    File.write!(Path.join(from, "a.txt"), "hello")
    File.write!(Path.join(from, "sub/深/b.bin"), :binary.copy(<<7>>, 3000))
    File.mkdir_p!(Path.join(from, "empty"))
    File.ln_s!("a.txt", Path.join(from, "link"))
    File.touch!(Path.join(from, "a.txt"), 1_700_000_000)
    File.mkdir_p!(to)

    assert VirtualDisk.measure(from) == {3005, 5, 3000}

    test = self()
    assert VirtualDisk.copy_tree(from, to, &send(test, {:done, &1})) == :ok

    assert File.read!(Path.join(to, "a.txt")) == "hello"
    assert File.read!(Path.join(to, "sub/深/b.bin")) == :binary.copy(<<7>>, 3000)
    assert File.dir?(Path.join(to, "empty"))
    refute File.exists?(Path.join(to, "link"))
    assert File.stat!(Path.join(to, "a.txt"), time: :posix).mtime == 1_700_000_000
    assert_receive {:done, 3005}
  end

  test "what the computer's system leaves on a drive does not go back", %{tmp_dir: tmp} do
    from = Path.join(tmp, "drive")
    to = Path.join(tmp, "folder")
    File.mkdir_p!(Path.join(from, ".fseventsd"))
    File.write!(Path.join(from, ".fseventsd/log"), "x")
    File.mkdir_p!(Path.join(from, "System Volume Information"))
    File.write!(Path.join(from, "._a.txt"), "resource fork")
    File.write!(Path.join(from, ".DS_Store"), "x")
    File.write!(Path.join(from, "a.txt"), "mine")
    File.write!(Path.join(from, ".env"), "also mine")
    File.mkdir_p!(to)

    assert VirtualDisk.copy_tree(from, to, fn _done -> :ok end, &VirtualDisk.system_file?/1) ==
             :ok

    assert Enum.sort(File.ls!(to)) == [".env", "a.txt"]
  end

  test "a path as the drive reports it, links resolved", %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "root/images"))
    File.ln_s!("root", Path.join(tmp, "data"))
    File.ln_s!("images", Path.join(tmp, "root/library"))

    real = VirtualDisk.real_path(tmp)

    assert VirtualDisk.real_path(Path.join(tmp, "data/images/a.img")) ==
             Path.join(real, "root/images/a.img")

    assert VirtualDisk.real_path(Path.join(tmp, "data/library/x")) ==
             Path.join(real, "root/images/x")
  end

  describe "FAT32" do
    test "clusters and FATs by size, from 64 MiB" do
      assert FAT.layout(div(64 * 1024 * 1024, 512)) ==
               {:ok, %{per_cluster: 1, fat: 1016, clusters: 129_008}}

      assert {:ok, %{per_cluster: 8}} = FAT.layout(div(300 * 1024 * 1024, 512))
      assert {:ok, %{per_cluster: 64}} = FAT.layout(div(40 * @gib, 512))
      assert FAT.layout(div(16 * 1024 * 1024, 512)) == {:error, :too_small}
    end

    test "an empty file system with its label", %{tmp_dir: tmp} do
      image = Path.join(tmp, "disk.img")
      assert FAT.format(image, FAT.min_size(), label: "photos 2026") == :ok
      assert File.stat!(image).size == FAT.min_size()

      {:ok, file} = File.open(image, [:read, :binary])
      read = fn offset, length -> :file.pread(file, offset, length) |> elem(1) end

      <<_jump::binary-size(11), 512::little-16, 1, 32::little-16, 2, _::binary-size(15),
        sectors::little-32, fat::little-32, _::binary-size(4), 2::little-32, 1::little-16,
        6::little-16, _::binary-size(19), label::binary-size(11), "FAT32   ", _::binary-size(420),
        0x55, 0xAA>> = boot = read.(0, 512)

      assert sectors == div(FAT.min_size(), 512)
      assert label == "PHOTOS 2026"
      assert read.(6 * 512, 512) == boot

      <<0x41615252::little-32, _::binary-size(480), 0x61417272::little-32, free::little-32,
        3::little-32, _::binary-size(12), 0xAA550000::little-32>> = read.(512, 512)

      assert free == 129_007

      assert read.(32 * 512, 12) ==
               <<0x0FFFFFF8::little-32, 0x0FFFFFFF::little-32, 0x0FFFFFFF::little-32>>

      assert read.((32 + fat) * 512, 4) == <<0x0FFFFFF8::little-32>>
      assert <<"PHOTOS 2026", 0x08, _::binary>> = read.((32 + 2 * fat) * 512, 32)
      File.close(file)
    end

    test "in a partition of a disk image, its other bytes kept", %{tmp_dir: tmp} do
      image = Path.join(tmp, "disk.img")
      File.write!(image, :binary.copy(<<0xAB>>, 1024 * 1024))
      start = 1024 * 1024

      assert FAT.format(image, FAT.min_size(), label: "PART", offset: start) == :ok
      assert File.stat!(image).size == start + FAT.min_size()

      {:ok, file} = File.open(image, [:read, :binary])
      assert {:ok, <<0xAB, 0xAB>>} = :file.pread(file, start - 2, 2)

      # The sectors before the partition, as BIOSes and Windows expect.
      assert {:ok, <<0xEB, 0x58, 0x90, "KURONEKO", _::binary-size(17), hidden::little-32>>} =
               :file.pread(file, start, 32)

      assert hidden == 2048
      File.close(file)

      assert FAT.format(image, FAT.min_size(), offset: 100) == {:error, :offset}
    end

    test "no image under 64 MiB", %{tmp_dir: tmp} do
      assert FAT.format(Path.join(tmp, "small.img"), 16 * 1024 * 1024) == {:error, :too_small}
    end
  end

  describe "exFAT" do
    test "clusters of 4 KiB for small drives, else 32 KiB" do
      assert ExFAT.cluster_size(FAT.min_size()) == 4096
      assert ExFAT.cluster_size(40 * @gib) == 32 * 1024
    end

    # What mkfs.exfat leaves: the boot sector, and the root directory in the
    # cluster heap with an empty volume label, the bitmap and the up-case table.
    defp empty_exfat(path) do
      boot =
        <<0xEB, 0x76, 0x90, "EXFAT   ", 0::size(53 * 8), 0::64, 131_072::little-64,
          2048::little-32, 16::little-32, 4096::little-32, 15_872::little-32, 5::little-32,
          0x12345678::little-32, 0x0100::little-16, 0::little-16, 9, 3, 1, 0x80, 0,
          0::size(7 * 8), 0::size(390 * 8), 0x55, 0xAA>>

      root = (4096 + 3 * 8) * 512
      entries = <<0x83, 0::size(31 * 8), 0x81, 0::size(31 * 8), 0x82, 0::size(31 * 8)>>
      File.write!(path, boot)
      {:ok, file} = File.open(path, [:read, :write, :binary])
      :ok = :file.pwrite(file, root, entries <> <<0::size(4096 * 8 - bit_size(entries))>>)
      File.close(file)
      root
    end

    defp label_entry(path, root) do
      {:ok, file} = File.open(path, [:read, :binary])
      {:ok, entry} = :file.pread(file, root, 32)
      File.close(file)
      entry
    end

    test "the volume label in UTF-16, 11 characters at most", %{tmp_dir: tmp} do
      image = Path.join(tmp, "x.img")
      root = empty_exfat(image)

      assert ExFAT.set_label(image, "照片 2026") == :ok
      label = :unicode.characters_to_binary("照片 2026", :utf8, {:utf16, :little})
      assert label_entry(image, root) == <<0x83, 7, label::binary, 0::size(8 * 8), 0::64>>

      assert ExFAT.set_label(image, "Photos: from the trip😀") == :ok
      label = :unicode.characters_to_binary("Photos from", :utf8, {:utf16, :little})
      assert label_entry(image, root) == <<0x83, 11, label::binary, 0::64>>

      assert ExFAT.set_label(image, "abcdefghij😀") == :ok
      label = :unicode.characters_to_binary("abcdefghij", :utf8, {:utf16, :little})
      assert label_entry(image, root) == <<0x83, 10, label::binary, 0::size(2 * 8), 0::64>>
    end

    test "no label for a name of nothing it takes", %{tmp_dir: tmp} do
      image = Path.join(tmp, "x.img")
      root = empty_exfat(image)
      assert ExFAT.set_label(image, "???") == :ok
      assert label_entry(image, root) == <<0x83, 0::size(31 * 8)>>
      assert ExFAT.set_label(Path.join(tmp, "x.img"), nil) == :ok
    end

    test "only on exFAT", %{tmp_dir: tmp} do
      image = Path.join(tmp, "fat.img")
      assert FAT.format(image, FAT.min_size(), label: "x") == :ok
      assert ExFAT.set_label(image, "y") == {:error, :not_exfat}
    end
  end
end
