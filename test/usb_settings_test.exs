defmodule Kuroneko.USBSettingsTest do
  use ExUnit.Case, async: false

  alias Kuroneko.USBSettings

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "usb.json")
    Application.put_env(:kuroneko, :usb_settings_file, file)
    on_exit(fn -> Application.delete_env(:kuroneko, :usb_settings_file) end)
    %{settings_file: file}
  end

  test "the defaults without saved settings, or with broken ones", %{settings_file: file} do
    assert USBSettings.saved() == USBSettings.defaults()
    File.write!(file, "{")
    assert USBSettings.saved() == USBSettings.defaults()
    File.write!(file, ~s({"audio": "loud"}))
    assert USBSettings.saved() == USBSettings.defaults()
  end

  test "takes the audio mode the firmware before saved", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "audio_mode"), "duplex\n")
    assert USBSettings.saved()["audio"] == "duplex"
  end

  test "saved settings over the defaults", %{settings_file: file} do
    File.write!(file, ~s({"hid": false, "audio": "mic", "microphone": {"channels": 1}}))
    settings = USBSettings.saved()

    assert settings["hid"] == false
    assert settings["audio"] == "mic"

    assert settings["microphone"] == %{
             "channels" => 1,
             "rates" => [48_000, 44_100],
             "sample_bits" => 16
           }
  end

  test "the USB functions of settings" do
    settings =
      Map.merge(USBSettings.defaults(), %{
        "audio" => "duplex",
        "speaker" => %{"channels" => 6, "rates" => [48_000], "sample_bits" => 24}
      })

    assert USBSettings.functions(settings) == [
             {:network, name: "usb0"},
             :keyboard,
             {:mouse, mode: :absolute},
             :relative_mouse,
             :storage,
             {:microphone, channels: 2, rates: [48_000, 44_100], sample_bits: 16},
             {:speaker, channels: 6, rates: [48_000], sample_bits: 24}
           ]

    off = %{settings | "hid" => false, "storage" => false, "audio" => "off"}
    assert USBSettings.functions(off) == [{:network, name: "usb0"}]

    drives = %{off | "storage" => true, "drives" => 3}
    assert USBSettings.functions(drives) == [{:network, name: "usb0"}, {:storage, luns: 3}]

    more = %{off | "networks" => ["usb1"], "storages" => [%{"name" => "boot", "drives" => 2}]}

    assert USBSettings.functions(more) == [
             {:network, name: "usb0"},
             {:network, name: "usb1"},
             {:storage, name: "boot", luns: 2}
           ]

    touch = %{settings | "pointer" => "touch", "audio" => "off", "storage" => false}

    assert USBSettings.functions(touch) == [
             {:network, name: "usb0"},
             :keyboard,
             {:mouse, mode: :touch},
             :relative_mouse
           ]
  end

  test "the mode of the USB functions" do
    assert USBSettings.mode([:storage]) == "off"
    assert USBSettings.mode([:storage, :microphone]) == "mic"
    assert USBSettings.mode([:microphone, :keyboard, :speaker]) == "duplex"
    assert USBSettings.mode([:speaker]) == "off"
  end

  test "merges only changes the USB functions take" do
    defaults = USBSettings.defaults()

    assert {:ok, %{"audio" => "mic"}} = USBSettings.merge(defaults, %{"audio" => "mic"})
    assert {:error, {:invalid, "audio"}} = USBSettings.merge(defaults, %{"audio" => "loud"})
    assert {:error, {:invalid, "volume"}} = USBSettings.merge(defaults, %{"volume" => 11})
    assert {:ok, %{"drives" => 4}} = USBSettings.merge(defaults, %{"drives" => 4})
    assert {:error, {:invalid, "drives"}} = USBSettings.merge(defaults, %{"drives" => 17})

    # Two networks (4) and two disks (2) fit without the keyboard and mice.
    two = %{
      "hid" => false,
      "storages" => [%{"name" => "boot", "drives" => 2}],
      "networks" => ["usb1"]
    }

    assert {:ok, %{"storages" => [%{"name" => "boot"}]}} = USBSettings.merge(defaults, two)

    for bad <- [
          [%{"name" => "disk", "drives" => 1}],
          [%{"name" => "a.b", "drives" => 1}],
          [%{"name" => "x"}]
        ],
        do:
          assert(
            {:error, {:invalid, "storages"}} = USBSettings.merge(defaults, %{"storages" => bad})
          )

    assert {:error, {:invalid, "networks"}} =
             USBSettings.merge(defaults, %{"networks" => ["usb0"]})

    assert {:error, {:invalid, "network"}} = USBSettings.merge(defaults, %{"network" => false})

    # Seven IN endpoints: the network (2), three HID, the disk, the microphone,
    # and no room for another storage device.
    assert {:error, {:not_enough_endpoints, %{need: %{in: 8}}}} =
             USBSettings.merge(defaults, %{
               "audio" => "mic",
               "storages" => [%{"name" => "boot", "drives" => 1}]
             })

    assert {:error, {:invalid, "hid"}} = USBSettings.merge(defaults, %{"hid" => "yes"})
    assert {:ok, %{"pointer" => "stylus"}} = USBSettings.merge(defaults, %{"pointer" => "stylus"})
    assert {:error, {:invalid, "pointer"}} = USBSettings.merge(defaults, %{"pointer" => "pen"})

    # A direction the sound card does not have yet is checked all the same.
    assert {:error, {:invalid_sample_bits, :microphone, 20}} =
             USBSettings.merge(defaults, %{"microphone" => %{"sample_bits" => 20}})

    assert {:error, {:too_much_bandwidth, :speaker, _format}} =
             USBSettings.merge(defaults, %{
               "speaker" => %{"channels" => 8, "rates" => [384_000], "sample_bits" => 32}
             })

    assert {:error, :not_an_object} = USBSettings.merge(defaults, [1])
  end

  test "the endpoints the functions take, and those the device has" do
    defaults = USBSettings.defaults()

    # The network (2 + 1), three HID (3 + 0), the disk (1 + 1).
    assert USBSettings.endpoints(defaults) == %{in: 6, out: 2, have: %{in: 7, out: 7}}

    more = %{
      defaults
      | "hid" => false,
        "audio" => "duplex",
        "networks" => ["usb1"],
        "storages" => [%{"name" => "boot", "drives" => 1}]
    }

    # Two networks (4 + 2), two disks (2 + 2), the sound card (1 + 1).
    assert USBSettings.endpoints(more) == %{in: 7, out: 5, have: %{in: 7, out: 7}}
  end
end
