defmodule KuronekoWeb.DeviceLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Kuroneko.Auth

  @endpoint KuronekoWeb.Endpoint
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:kuroneko, :auth_file, Path.join(tmp_dir, "auth.json"))
    on_exit(fn -> Application.delete_env(:kuroneko, :auth_file) end)
    :ok = Auth.set_password("correct horse")
    %{conn: init_test_session(build_conn(), %{"generation" => Auth.generation()})}
  end

  test "the device page for a session", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/device")
    assert html =~ "Bluetooth"
  end

  test "without a session, the login page" do
    assert {:error, {:redirect, %{to: "/"}}} = live(init_test_session(build_conn(), %{}), "/device")
  end
end
