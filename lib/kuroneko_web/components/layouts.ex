defmodule KuronekoWeb.Layouts do
  @moduledoc false
  use KuronekoWeb, :html

  embed_templates "layouts/*"

  @themes [
    {"system", "System", "hero-computer-desktop"},
    {"light", "Light", "hero-sun"},
    {"dark", "Dark", "hero-moon"}
  ]

  @doc """
  The appearance: as the system has it, light or dark. The choice is this
  browser's (`phx:theme` in its local storage), set before the page shows.
  """
  def theme_toggle(assigns) do
    assigns = assign(assigns, themes: @themes)

    ~H"""
    <div class="dropdown dropdown-end">
      <button
        type="button"
        tabindex="0"
        class="btn btn-square btn-ghost btn-sm"
        aria-label="Appearance"
        title="Appearance"
      >
        <.icon name="hero-computer-desktop" class="size-[18px] [[data-theme]_&]:hidden" />
        <.icon name="hero-sun" class="hidden size-[18px] [[data-theme=light]_&]:inline-block" />
        <.icon name="hero-moon" class="hidden size-[18px] [[data-theme=dark]_&]:inline-block" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-50 mt-2 w-44 rounded-box bg-base-100 p-1 shadow-lg ring-1 ring-base-content/10"
      >
        <li :for={{theme, label, icon} <- @themes}>
          <button
            type="button"
            data-phx-theme={theme}
            phx-click={JS.dispatch("phx:set-theme")}
          >
            <.icon name={icon} class="size-4" />
            {label}
            <.icon name="hero-check-mini" class={["ml-auto size-4", check(theme)]} />
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp check("system"), do: "[[data-theme]_&]:invisible"
  defp check("light"), do: "invisible [[data-theme=light]_&]:visible"
  defp check("dark"), do: "invisible [[data-theme=dark]_&]:visible"
end
