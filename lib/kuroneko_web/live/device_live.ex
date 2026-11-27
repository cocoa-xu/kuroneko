defmodule KuronekoWeb.DeviceLive do
  @moduledoc "The device page: the NanoKVM's hardware, state and settings."

  use KuronekoWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Device")}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-6xl p-6">
      <.card title="Bluetooth" icon="hero-signal">
        <.facts rows={[{"State", "On"}]} />
      </.card>
    </main>
    """
  end
end
