defmodule KuronekoWeb.DeviceLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Kuroneko.Auth

  @endpoint KuronekoWeb.Endpoint
  @moduletag :tmp_dir

  defmodule FakeDisk do
    def state do
      %{
        items: [
          %{
            name: "debian.iso",
            kind: :image,
            size: 3_000_000_000,
            format: %{disc: :dvd, iso9660: true, udf: "1.02", boot: [:bios, :uefi]},
            makers: []
          },
          %{name: "drivers", kind: :folder, size: 4_000, makers: []}
        ],
        drives: [
          %{drive: 0, storage: "disk", medium: nil},
          %{
            drive: 1,
            storage: "disk",
            medium: %{
              name: "old.iso",
              kind: :image,
              cdrom: true,
              disc: :cd,
              read_only: true,
              remember: true
            }
          }
        ],
        busy: nil,
        free: 9_000_000_000,
        error: nil
      }
    end

    def drives, do: Map.take(state(), [:drives, :busy])

    def insert(name, opts), do: tell({:insert, name, opts})
    def eject(drive), do: tell({:eject, drive})
    def delete("busy.iso"), do: {:error, :busy}
    def delete(name), do: tell({:delete, name})

    defp tell(message) do
      send(KuronekoWeb.DeviceLiveTest, message)
      :ok
    end
  end

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:kuroneko, :auth_file, Path.join(tmp_dir, "auth.json"))
    Application.put_env(:kuroneko, :usb_settings_file, Path.join(tmp_dir, "usb.json"))
    Application.put_env(:kuroneko, :video_settings_file, Path.join(tmp_dir, "video.json"))

    on_exit(fn ->
      for key <- [:auth_file, :usb_settings_file, :video_settings_file],
          do: Application.delete_env(:kuroneko, key)
    end)

    :ok = Auth.set_password("correct horse")
    %{conn: init_test_session(build_conn(), %{"generation" => Auth.generation()})}
  end

  test "the device page for a session", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/device")
    assert html =~ "Bluetooth"
  end

  test "without a session, the login page" do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(init_test_session(build_conn(), %{}), "/device")
  end

  describe "USB devices" do
    test "are a draft until applied", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, "/device")
      assert has_element?(view, "#usb-legend", "Network usb0")
      refute has_element?(view, "#usb button", "Apply")

      view |> element(~s(#usb input[phx-value-key="network"])) |> render_click()
      refute has_element?(view, "#usb-legend", "Network usb0")
      assert has_element?(view, "#usb button", "Apply")
      refute File.exists?(Path.join(tmp_dir, "usb.json"))

      view |> element("#usb button", "Apply") |> render_click()
      assert render_async(view) =~ "USB devices set"
      assert %{"network" => false} = Jason.decode!(File.read!(Path.join(tmp_dir, "usb.json")))
      refute has_element?(view, "#usb button", "Apply")
    end

    test "revert to what is saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/device")
      view |> element("#usb button", "Add a network") |> render_click()
      assert has_element?(view, "#usb-legend", "Network usb1")

      view |> element("#usb button", "Revert") |> render_click()
      refute has_element?(view, "#usb-legend", "Network usb1")
    end

    test "more than the endpoints there are cannot be applied", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/device")
      view |> element("#usb button", "Add a network") |> render_click()

      assert render(view) =~ "Too many: turn something off or remove it."
      assert has_element?(view, "#usb button[disabled]", "Apply")
    end

    test "a refused change says why", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/device")
      view |> element("#usb button", "Add a network") |> render_click()
      view |> element(~s(#usb input[phx-value-key="hid"])) |> render_click()

      view
      |> form("#usb form[phx-change='usb:network_name']", %{"index" => "0", "name" => "usb0"})
      |> render_change()

      view |> element("#usb button", "Apply") |> render_click()
      assert render_async(view) =~ "Give each network its own name, not usb0"
    end

    test "the jiggler applies at once", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, "/device")

      assert view |> element(~s(#usb input[phx-click="usb:jiggler"])) |> render_click() =~
               "The mouse jiggler is on"

      assert %{"jiggler" => true} = Jason.decode!(File.read!(Path.join(tmp_dir, "usb.json")))
      refute has_element?(view, "#usb button", "Apply")
    end

    test "sample rates ticked, and the one the target starts at", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/device")
      view |> element(~s(#usb button[phx-value-value="mic"])) |> render_click()

      view
      |> form("#usb form[phx-change='usb:format']")
      |> render_change(%{"rates" => ["", "44100", "48000", "96000"], "_target" => ["rates"]})

      view
      |> form("#usb form[phx-change='usb:format']")
      |> render_change(%{"start" => "96000", "_target" => ["start"]})

      assert has_element?(
               view,
               ~s(#usb-format-microphone select[name=start] option[selected][value="96000"])
             )

      refute has_element?(view, ~s(#usb-format-microphone input[value="8000"][checked]))
      assert has_element?(view, ~s(#usb-format-microphone input[value="44100"][checked]))
    end
  end

  describe "the virtual disk" do
    setup do
      Process.register(self(), KuronekoWeb.DeviceLiveTest)
      Application.put_env(:kuroneko, :virtual_disk, FakeDisk)
      on_exit(fn -> Application.delete_env(:kuroneko, :virtual_disk) end)
    end

    test "the drives on the card, and ejecting one", %{conn: conn} do
      {:ok, view, html} = live(conn, "/device")
      assert html =~ "Drive 2: old.iso"
      assert html =~ "CD-ROM, read-only, in again after a restart"

      view |> element(~s(#usb button[phx-click="usb:eject"])) |> render_click()
      assert_received {:eject, 1}
    end

    test "the library, and an image inserted as chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/device")
      refute has_element?(view, "#disk-item-0")

      html = view |> element(~s(#usb button[phx-value-drive="0"]), "Insert") |> render_click()
      assert html =~ "3.0 GB, DVD format (ISO 9660, UDF 1.02); boots BIOS and UEFI"
      assert html =~ "Auto: DVD-ROM"

      view
      |> form("#disk-item-0 form")
      |> render_change(%{"name" => "debian.iso", "mode" => "drive-ro"})

      view |> element("#disk-item-0 button", "Insert") |> render_click()
      assert_received {:insert, "debian.iso", opts}

      assert Enum.sort(opts) ==
               Enum.sort(drive: 0, remember: true, media: :drive, read_only: true)
    end

    test "a folder goes in as a drive made from it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/device")
      view |> element("#usb button", "Virtual disk…") |> render_click()

      view
      |> form("#disk-item-1 form")
      |> render_change(%{"name" => "drivers", "mode" => "fat32-rw"})

      view |> element("#disk-item-1 button", "Insert") |> render_click()

      assert_received {:insert, "drivers", opts}
      assert opts[:filesystem] == :fat32 and opts[:read_only] == false and opts[:drive] == 0
    end

    test "deleting, and what goes wrong", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/device")
      view |> element("#usb button", "Virtual disk…") |> render_click()
      view |> element(~s(#disk-item-0 button[phx-click="delete"])) |> render_click()
      assert_received {:delete, "debian.iso"}

      html =
        view
        |> element("#disk-upload")
        |> render_hook("upload_failed", %{"name" => "big.iso", "error" => "no_room"})

      assert html =~ "Upload of “big.iso”: Not enough free space on the NanoKVM."
    end

    test "closing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/device")
      view |> element("#usb button", "Virtual disk…") |> render_click()
      refute has_element?(view, "#disk-sheet.hidden")

      view |> element("#disk-sheet button[aria-label=Close]") |> render_click()
      assert has_element?(view, "#disk-sheet.hidden")
      refute has_element?(view, "#disk-item-0")
    end
  end

  test "the video stream's settings apply at once", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, "/device")
    assert view |> element(~s(#video button[phx-value-value="h265"])) |> render_click() =~ "H.265"
    assert %{"codec" => "h265"} = Jason.decode!(File.read!(Path.join(tmp_dir, "video.json")))

    view
    |> form("#video form[phx-change='video:bitrate']", %{"bitrate" => "4000000"})
    |> render_change()

    assert %{"bitrate" => 4_000_000} = Jason.decode!(File.read!(Path.join(tmp_dir, "video.json")))
  end
end
