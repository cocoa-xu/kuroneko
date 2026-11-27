defmodule KuronekoWeb.SignedIn do
  @moduledoc """
  LiveViews only for a session the password opened, as `Kuroneko.Web` lets
  through: the socket checks it again, and anyone else goes to the login
  page.
  """

  import Phoenix.LiveView

  alias Kuroneko.Auth

  def on_mount(:default, _params, session, socket) do
    if Auth.password_set?() and session["generation"] == Auth.generation(),
      do: {:cont, socket},
      else: {:halt, redirect(socket, to: "/")}
  end
end
