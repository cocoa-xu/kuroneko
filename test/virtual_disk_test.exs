defmodule Kuroneko.VirtualDiskTest do
  use ExUnit.Case, async: true

  alias Kuroneko.VirtualDisk
  alias Kuroneko.VirtualDisk.FAT

  @moduletag :tmp_dir
  @gib 1024 * 1024 * 1024

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

    test "no image under 64 MiB", %{tmp_dir: tmp} do
      assert FAT.format(Path.join(tmp, "small.img"), 16 * 1024 * 1024) == {:error, :too_small}
    end
  end
end
