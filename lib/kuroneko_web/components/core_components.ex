defmodule KuronekoWeb.CoreComponents do
  @moduledoc """
  The pages' building blocks, in the manner of Apple's settings: cards of
  grouped rows, switches, segmented controls and badges, styled with
  Tailwind CSS and daisyUI.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  A Heroicon, `hero-*`: outline by default, `-solid`, `-mini` and `-micro`
  for the others.
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-5"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  @doc "A card: a title with an icon, actions at its right, and what it holds."
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section id={@id} class={["rounded-box bg-base-100 p-5 shadow-sm", @class]}>
      <header class="mb-4 flex items-center gap-2.5">
        <.icon :if={@icon} name={@icon} class="size-5 text-primary" />
        <h2 class="text-[15px] font-semibold">{@title}</h2>
        <div class="ml-auto flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "Rows of a term and its value; rows without a value are left out."
  attr :rows, :list, required: true, doc: "`{term, value}`, the value text or nil"
  attr :class, :any, default: nil

  def facts(assigns) do
    assigns = assign(assigns, :rows, Enum.reject(assigns.rows, fn {_t, v} -> v in [nil, ""] end))

    ~H"""
    <dl class={["grid grid-cols-[minmax(7rem,max-content)_1fr] gap-x-4 gap-y-1.5 text-sm", @class]}>
      <%= for {term, value} <- @rows do %>
        <dt class="text-base-content/55">{term}</dt>
        <dd class="min-w-0 break-words">{value}</dd>
      <% end %>
    </dl>
    """
  end

  @doc "A row of a setting: its label and what it says at the left, the control at the right."
  attr :label, :string, required: true
  attr :detail, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def row(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-4 border-t border-base-300/60 py-3 first:border-t-0 first:pt-0",
      @class
    ]}>
      <div class="min-w-0 flex-1">
        <div class="text-sm">{@label}</div>
        <div :if={@detail} class="mt-0.5 truncate text-xs text-base-content/55">{@detail}</div>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "An on/off switch that sends `event` with `value` the new state."
  attr :checked, :boolean, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true, doc: "for screen readers"
  attr :disabled, :boolean, default: false
  attr :rest, :global

  def switch(assigns) do
    ~H"""
    <input
      type="checkbox"
      class="toggle toggle-success"
      checked={@checked}
      disabled={@disabled}
      aria-label={@label}
      phx-click={@event}
      phx-value-on={to_string(!@checked)}
      {@rest}
    />
    """
  end

  @doc "A segmented control: one of `options`, sent as `event` with `value`."
  attr :options, :list, required: true, doc: "`{value, label}`"
  attr :value, :any, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def segmented(assigns) do
    ~H"""
    <div
      role="group"
      aria-label={@label}
      class={["inline-flex gap-0.5 rounded-field bg-base-300/70 p-0.5", @class]}
      {@rest}
    >
      <button
        :for={{value, label} <- @options}
        type="button"
        disabled={@disabled}
        aria-pressed={to_string(to_string(value) == to_string(@value))}
        phx-click={@event}
        phx-value-value={value}
        class={[
          "h-7 rounded-[calc(var(--radius-field)-2px)] px-3 text-[13px] transition disabled:opacity-40",
          if(to_string(value) == to_string(@value),
            do: "bg-base-100 font-medium shadow-sm",
            else: "text-base-content/70 hover:text-base-content"
          )
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  @doc "A small label: `:ok`, `:warn`, `:bad` or plain."
  attr :kind, :atom, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-selector px-2.5 py-0.5 text-xs font-medium",
      case @kind do
        :ok -> "bg-success/15 text-success"
        :warn -> "bg-warning/15 text-warning"
        :bad -> "bg-error/15 text-error"
        _ -> "bg-base-300 text-base-content/70"
      end
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc "A bar that fills to `percent`, warmer as it fills."
  attr :percent, :any, required: true
  attr :class, :any, default: "h-1.5"

  def meter(assigns) do
    assigns = assign(assigns, :percent, min(max(assigns.percent || 0, 0), 100))

    ~H"""
    <div class={["w-full overflow-hidden rounded-full bg-base-300", @class]}>
      <div
        class={[
          "h-full rounded-full transition-[width] duration-500",
          cond do
            @percent >= 85 -> "bg-error"
            @percent >= 60 -> "bg-warning"
            true -> "bg-success"
          end
        ]}
        style={"width: #{@percent}%"}
      />
    </div>
    """
  end

  @doc "A button: `:primary`, `:danger` (a quiet red), `:destructive` (a solid one) or plain."
  attr :kind, :atom, default: nil
  attr :size, :atom, default: :md
  attr :rest, :global, include: ~w(disabled type phx-click phx-value-name href target)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      class={[
        "btn border-0 font-medium shadow-none",
        @size == :sm && "btn-sm",
        case @kind do
          :primary -> "btn-primary"
          :danger -> "bg-error/12 text-error hover:bg-error/20"
          :destructive -> "btn-error"
          _ -> "bg-base-300/80 hover:bg-base-300"
        end
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  A modal sheet over the page: Escape, the backdrop and its close button
  send `cancel`, to `target` when a component's. With `show` false it stays
  in the page, hidden.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :cancel, :string, required: true
  attr :target, :any, default: nil
  attr :show, :boolean, default: true
  attr :class, :any, default: "max-w-[30rem]"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["fixed inset-0 z-50 overflow-y-auto", !@show && "hidden"]}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@show && @cancel}
      phx-key="Escape"
      phx-target={@target}
    >
      <div
        class="fixed inset-0 bg-black/35 backdrop-blur-[2px]"
        phx-click={@cancel}
        phx-target={@target}
      />
      <div class={[
        "relative mx-4 my-10 rounded-box bg-base-100 p-6 shadow-2xl sm:mx-auto sm:my-20",
        @class
      ]}>
        <div class="mb-3 flex items-start justify-between gap-4">
          <h3 id={"#{@id}-title"} class="text-lg font-semibold">{@title}</h3>
          <button
            type="button"
            class="btn btn-circle btn-ghost btn-sm -mr-2 -mt-1"
            aria-label="Close"
            phx-click={@cancel}
            phx-target={@target}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "The flash messages, as toasts at the bottom; a click dismisses one."
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="toast toast-center toast-bottom z-50">
      <div
        :for={{kind, message} <- @flash}
        role="alert"
        phx-click={JS.push("lv:clear-flash", value: %{key: kind}) |> JS.hide()}
        class={[
          "glass cursor-pointer rounded-box px-4 py-2.5 text-sm shadow-lg",
          kind == "error" && "text-error"
        ]}
      >
        {message}
      </div>
    </div>
    """
  end
end
