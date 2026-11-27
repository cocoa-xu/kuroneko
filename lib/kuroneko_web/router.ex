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
  end
end
