defmodule KuronekoWeb.KVMLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Kuroneko.Auth

  @endpoint KuronekoWeb.Endpoint
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:kuroneko, :auth_file, Path.join(tmp_dir, "auth.json"))
    Application.put_env(:kuroneko, :usb_settings_file, Path.join(tmp_dir, "usb.json"))
    Application.put_env(:kuroneko, :wake_file, Path.join(tmp_dir, "wake_mac"))

    on_exit(fn ->
      for key <- [:auth_file, :usb_settings_file, :wake_file, :reboot],
          do: Application.delete_env(:kuroneko, key)
    end)

    :ok = Auth.set_password("correct horse")
    %{conn: init_test_session(build_conn(), %{"generation" => Auth.generation()})}
  end

  test "the picture and its tools for the hook, the menu from here", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ ~s(id="canvas")
    assert has_element?(view, ~s(#fullscreen[aria-label="Fullscreen"]))
    assert has_element?(view, "#exitfullscreen", "Exit fullscreen")
    assert has_element?(view, "#gamecontrol", "Fullscreen game control")
    assert has_element?(view, ~s(button[data-keys="MetaLeft+KeyQ"]), "Send Command Q")
    assert has_element?(view, "#fullscreenstrip", "Shift + Esc exits")
    assert has_element?(view, ~s(#kvm-page[phx-hook="KVM"][phx-update="ignore"]))
    assert has_element?(view, "#pop-kvm .menu-row", "USB devices")
    assert has_element?(view, ~s(#pop-kvm a[href="/device"]), "Status and hardware")
  end

  test "a row opens its panel in the menu, and back", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_hook(view, "menu", %{"panel" => "main", "open" => true})

    view |> element("#pop-kvm .menu-row", "USB devices") |> render_click()
    assert has_element?(view, "#pop-kvm h4", "USB devices")
    assert has_element?(view, ~s(#pop-kvm .toggle[phx-value-key="network"][aria-checked="true"]))

    view |> element("#pop-kvm .menu-back") |> render_click()
    assert has_element?(view, "#pop-kvm h4", "NanoKVM")
  end

  test "a USB switch applies at once", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#pop-kvm .menu-row", "USB devices") |> render_click()
    view |> element(~s(#pop-kvm .toggle[phx-value-key="network"])) |> render_click()

    render_async(view)
    assert %{"network" => false} = Jason.decode!(File.read!(Path.join(tmp_dir, "usb.json")))
    assert has_element?(view, ~s(#pop-kvm .toggle[phx-value-key="network"][aria-checked="false"]))
  end

  test "Wake on LAN says what it cannot take", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#pop-kvm .menu-row", "Wake on LAN") |> render_click()

    html = view |> form("#menu-wake", %{"mac" => "nope"}) |> render_submit()
    assert html =~ "Not a MAC address"
  end

  test "restarting tells the page first", %{conn: conn} do
    test = self()
    Application.put_env(:kuroneko, :reboot, fn -> send(test, :rebooted) end)

    {:ok, view, _html} = live(conn, "/")
    view |> element("#pop-kvm .menu-row", "Restart the NanoKVM") |> render_click()
    view |> element("#pop-kvm .button.destructive", "Restart") |> render_click()

    assert_push_event(view, "kvm:restarting", %{})
    assert_receive :rebooted, 1_000
  end

  test "the password goes as a request, from the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#pop-kvm .menu-row", "Change password") |> render_click()
    assert has_element?(view, ~s(#menu-password[phx-submit*="kvm:password"]))
  end
end
