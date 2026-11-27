defmodule KuronekoWeb.Router do
  use KuronekoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KuronekoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", KuronekoWeb do
    pipe_through :browser

    live_session :signed_in, on_mount: KuronekoWeb.SignedIn do
      live "/device", DeviceLive
    end

    # The KVM page has a layout of its own: its CSS, not the app's.
    live_session :kvm,
      on_mount: KuronekoWeb.SignedIn,
      root_layout: {KuronekoWeb.Layouts, :kvm_root} do
      live "/", KVMLive
    end
  end
end
