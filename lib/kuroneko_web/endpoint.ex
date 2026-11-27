defmodule KuronekoWeb.Endpoint do
  @moduledoc """
  The endpoint of the LiveView pages. `Kuroneko.Web` serves HTTP and HTTPS,
  with the session fetched and the password checked, and hands it the
  pages, their socket and their assets.
  """

  use Phoenix.Endpoint, otp_app: :kuroneko

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: {Kuroneko.Web, :session_options, []}],
      check_origin: :conn
    ],
    longpoll: false

  plug Plug.Static, at: "/", from: :kuroneko, gzip: false, only: KuronekoWeb.static_paths()
  plug KuronekoWeb.Router
end
