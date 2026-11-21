defmodule DiaWeb.CoreComponents do
  @moduledoc """
  Provides core light-theme UI components styled with custom Tailwind CSS classes.
  """
  use Phoenix.Component
  use Gettext, backend: DiaWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50 w-80 sm:w-96 max-w-[calc(100vw-2rem)]"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-xl border px-4 py-3 text-sm shadow-lg transition-all",
        @kind == :info && "border-sky-200 bg-sky-50 text-sky-900",
        @kind == :error && "border-rose-200 bg-rose-50 text-rose-900"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="mt-0.5 size-5 shrink-0 text-sky-600"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="mt-0.5 size-5 shrink-0 text-rose-600"
        />
        <div class="flex-1 min-w-0">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class="leading-5 break-words">{msg}</p>
        </div>
        <button
          type="button"
          class="ml-2 rounded-md p-1 text-slate-400 hover:bg-white/70 hover:text-slate-700 transition cursor-pointer"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil
  attr :variant, :string, default: "secondary", values: ~w(primary secondary danger ghost)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variant_classes = %{
      "primary" =>
        "bg-sky-700 text-white border border-sky-700 hover:bg-sky-800 shadow-xs focus-visible:outline-sky-700",
      "secondary" =>
        "bg-white text-slate-800 border border-slate-300 hover:bg-slate-50 hover:border-slate-400 shadow-xs focus-visible:outline-slate-400",
      "danger" =>
        "bg-rose-600 text-white border border-rose-600 hover:bg-rose-700 shadow-xs focus-visible:outline-rose-600",
      "ghost" =>
        "bg-transparent text-slate-700 border border-transparent hover:bg-slate-100 focus-visible:outline-slate-400"
    }

    base =
      "inline-flex items-center justify-center gap-2 rounded-lg px-3.5 py-2 text-sm font-medium transition-colors duration-150 focus-visible:outline-2 focus-visible:outline-offset-2 disabled:opacity-50 disabled:cursor-not-allowed cursor-pointer"

    assigns =
      assign(assigns, :computed_class, [
        base,
        Map.fetch!(variant_classes, assigns.variant),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-2">
      <label for={@id} class="inline-flex items-center gap-2 text-sm text-slate-700 cursor-pointer">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={
            @class ||
              "size-4 rounded border-slate-300 text-sky-700 focus:ring-sky-600 focus:ring-offset-0"
          }
          {@rest}
        />
        <span>{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span
          :if={@label}
          class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-600"
        >
          {@label}
        </span>
        <select
          id={@id}
          name={@name}
          class={[
            @class ||
              "block w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-2xs focus:border-sky-600 focus:outline-none focus:ring-2 focus:ring-sky-600/20",
            @errors != [] &&
              (@error_class || "border-rose-400 focus:border-rose-500 focus:ring-rose-500/20")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span
          :if={@label}
          class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-600"
        >
          {@label}
        </span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class ||
              "block w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-2xs focus:border-sky-600 focus:outline-none focus:ring-2 focus:ring-sky-600/20",
            @errors != [] &&
              (@error_class || "border-rose-400 focus:border-rose-500 focus:ring-rose-500/20")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id} class="block">
        <span
          :if={@label}
          class="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-600"
        >
          {@label}
        </span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class ||
              "block w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 placeholder:text-slate-400 shadow-2xs focus:border-sky-600 focus:outline-none focus:ring-2 focus:ring-sky-600/20",
            @errors != [] &&
              (@error_class || "border-rose-400 focus:border-rose-500 focus:ring-rose-500/20")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp error(assigns) do
    ~H"""
    <p class="mt-1 flex items-center gap-1.5 text-xs font-medium text-rose-600">
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[
      @actions != [] && "flex flex-wrap items-center justify-between gap-4",
      "pb-5 border-b border-slate-200"
    ]}>
      <div>
        <h1 class="text-2xl font-semibold tracking-tight text-slate-900">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-slate-600">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex flex-wrap items-center gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :row_id, :any, default: nil
  attr :row_click, :any, default: nil
  attr :row_item, :any, default: &Function.identity/1

  slot :col, required: true do
    attr :label, :string
  end

  slot :action

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto rounded-xl border border-slate-200 bg-white shadow-2xs">
      <table class="min-w-full divide-y divide-slate-200 text-left text-sm">
        <thead class="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-600">
          <tr>
            <th :for={col <- @col} class="px-4 py-3">{col[:label]}</th>
            <th :if={@action != []} class="px-4 py-3 text-right">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
          class="divide-y divide-slate-100 bg-white text-slate-800"
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="hover:bg-slate-50/80 transition-colors"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={["px-4 py-3 align-middle", @row_click && "hover:cursor-pointer"]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="whitespace-nowrap px-4 py-3 text-right font-medium">
              <div class="inline-flex items-center gap-3">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="divide-y divide-slate-200 rounded-xl border border-slate-200 bg-white">
      <div :for={item <- @item} class="px-4 py-3 sm:grid sm:grid-cols-3 sm:gap-4">
        <dt class="text-xs font-semibold uppercase tracking-wide text-slate-500">{item.title}</dt>
        <dd class="mt-1 text-sm text-slate-900 sm:col-span-2 sm:mt-0">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-out duration-200", "opacity-0 translate-y-2 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-2 sm:scale-95"}
    )
  end

  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(DiaWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(DiaWeb.Gettext, "errors", msg, opts)
    end
  end

  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
