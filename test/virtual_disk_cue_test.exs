defmodule Kuroneko.VirtualDisk.CueTest do
  use ExUnit.Case, async: true

  alias Kuroneko.VirtualDisk.Cue

  @moduletag :tmp_dir

  defp sectors(byte, n, size \\ 2352), do: :binary.copy(<<byte>>, n * size)

  defp wave(samples) do
    fmt =
      <<1::little-16, 2::little-16, 44_100::little-32, 176_400::little-32, 4::little-16,
        16::little-16>>

    body =
      "WAVE" <>
        "fmt " <>
        <<16::little-32>> <> fmt <> "data" <> <<byte_size(samples)::little-32>> <> samples

    "RIFF" <> <<byte_size(body)::little-32>> <> body
  end

  test "one BIN as the disc has it goes in as it is", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "game disc.bin"), sectors(1, 1000) <> sectors(2, 600))

    sheet = """
    ﻿REM a game
    FILE "game disc.bin" BINARY\r
      TRACK 01 MODE1/2352
        FLAGS DCP
        INDEX 01 00:00:00
      track 02 audio
        INDEX 00 00:13:25
        INDEX 01 00:15:25
    """

    assert {:ok, [one, two]} = Cue.parse(sheet, dir)

    assert %{number: 1, mode: :mode1, size: 2352, flags: [:copy_permitted], indexes: %{1 => 0}} =
             one

    assert %{number: 2, mode: :audio, indexes: %{0 => 1000, 1 => 1150}} = two

    assert Cue.layout([one, two]) ==
             {:ok,
              {:direct, Path.join(dir, "game disc.bin"),
               [
                 %{
                   number: 1,
                   mode: :mode1,
                   size: 2352,
                   offset: 0,
                   pregap: 0,
                   flags: [:copy_permitted]
                 },
                 %{
                   number: 2,
                   mode: :audio,
                   size: 2352,
                   offset: 1000 * 2352,
                   pregap: 150,
                   flags: []
                 }
               ]}}
  end

  test "sectors of 2048 bytes then audio, in one file", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mixed.bin"), sectors(1, 300, 2048) <> sectors(2, 400))

    sheet = """
    FILE mixed.bin BINARY
      TRACK 01 MODE1/2048
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        INDEX 01 00:04:00
    """

    assert {:ok, tracks} = Cue.parse(sheet, dir)
    assert {:ok, {:direct, _bin, [_one, two]}} = Cue.layout(tracks)
    assert two.offset == 300 * 2048
  end

  test "a file a track is laid out as one image", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "Track 01.bin"), sectors(1, 500))
    File.write!(Path.join(dir, "Track 02.bin"), sectors(0, 150) <> sectors(2, 300))

    sheet = """
    FILE "Track 01.bin" BINARY
      TRACK 01 MODE2/2352
        INDEX 01 00:00:00
    FILE "Track 02.bin" BINARY
      TRACK 02 AUDIO
        INDEX 00 00:00:00
        INDEX 01 00:02:00
    """

    assert {:ok, tracks} = Cue.parse(sheet, dir)
    assert {:ok, {:layout, pieces, table}} = Cue.layout(tracks)

    assert Enum.map(table, &{&1.number, &1.offset, &1.pregap}) == [
             {1, 0, 0},
             {2, 500 * 2352, 150}
           ]

    image = Path.join(dir, "image")
    assert :ok = Cue.write(pieces, image)
    assert File.read!(image) == sectors(1, 500) <> sectors(0, 150) <> sectors(2, 300)
    assert Cue.size(pieces) == 950 * 2352
  end

  test "WAVE files, big-endian audio and gaps no file holds", %{tmp_dir: dir} do
    samples = for i <- 1..(588 * 10), into: <<>>, do: <<i::little-16, -i::little-16>>
    File.write!(Path.join(dir, "one.wav"), wave(samples))
    File.write!(Path.join(dir, "two.raw"), <<1, 2, 3, 4>> |> :binary.copy(588 * 5))

    sheet = """
    FILE "one.wav" WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
    FILE "two.raw" MOTOROLA
      TRACK 02 AUDIO
        PREGAP 00:00:02
        INDEX 01 00:00:00
        POSTGAP 00:00:01
    """

    assert {:ok, tracks} = Cue.parse(sheet, dir)
    assert {:ok, {:layout, pieces, table}} = Cue.layout(tracks)
    assert Enum.map(table, &{&1.offset, &1.pregap}) == [{0, 0}, {10 * 2352, 2}]

    image = Path.join(dir, "image")
    progress = self()
    assert :ok = Cue.write(pieces, image, &send(progress, {:done, &1}))

    assert File.read!(image) ==
             samples <> sectors(0, 2) <> :binary.copy(<<2, 1, 4, 3>>, 588 * 5) <> sectors(0, 1)

    assert_received {:done, _bytes}
  end

  test "sheets the drive cannot take", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "x.wav"),
      wave(<<0::32>>) |> String.replace("D\xAC\0\0", "\"V\0\0")
    )

    for {sheet, reason} <- [
          {"TRACK 01 AUDIO", {:line, 1, :track_without_file}},
          {"FILE x.bin BINARY\nTRACK 01 MODE3/2352", {:line, 2, :mode}},
          {"FILE x.bin BINARY\nTRACK 01 AUDIO\nINDEX 01 00:61:00", {:line, 3, :time}},
          {"FILE x.wav WAVE\nTRACK 01 MODE1/2352", {:line, 2, :data_in_audio_file}},
          {"FILE x.bin BINARY\nTRACK 01 AUDIO\nINDEX 00 00:00:00", {:track, {1, :no_index_1}}},
          {"FILE x.bin BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 03 AUDIO\nINDEX 01 00:09:00",
           {:track, {3, :number}}},
          {"FILE x.bin BINARY\nTRACK 01 AUDIO\nINDEX 01 00:05:00\nTRACK 02 AUDIO\nINDEX 01 00:01:00",
           {:track, {2, :index_order}}},
          {"REM nothing", :no_tracks}
        ],
        do: assert(Cue.parse(sheet, dir) == {:error, reason})

    assert {:ok, tracks} = Cue.parse("FILE x.wav WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00", dir)
    assert Cue.layout(tracks) == {:error, {"x.wav", :not_cd_audio}}

    assert {:ok, tracks} =
             Cue.parse("FILE gone.bin BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00", dir)

    assert Cue.layout(tracks) == {:error, {"gone.bin", :enoent}}
  end
end
