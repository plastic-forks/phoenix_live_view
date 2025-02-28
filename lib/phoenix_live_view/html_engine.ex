defmodule Phoenix.LiveView.HTMLEngine do
  @moduledoc """
  The HTMLEngine that powers `.heex` templates and the `~H` sigil.

  It works by adding a HTML parsing and validation layer on top
  of `Phoenix.LiveView.TagEngine`.
  """

  @behaviour Phoenix.Template.Engine

  @impl true
  def compile(path, _name) do
    # We need access for the caller, so we return a call to a macro.
    quote do
      require Phoenix.LiveView.HTMLEngine
      Phoenix.LiveView.HTMLEngine.compile(unquote(path))
    end
  end

  @doc false
  defmacro compile(path) do
    trim = Application.get_env(:phoenix, :trim_on_html_eex_engine, true)
    source = File.read!(path)

    EEx.compile_string(source,
      engine: Phoenix.LiveView.TagEngine,
      line: 1,
      file: path,
      trim: trim,
      caller: __CALLER__,
      source: source,
      tag_handler: Phoenix.LiveView.HTMLTagHandler
    )
  end

  # TODO: remove it
  def debug() do
    source = """
    <% c = 1 %>
    <p phx-no-format>hello</p>
    <%= if 1 == 3 do %>
      <p>world</p>
    <% end %>
    """

    trim = Application.get_env(:phoenix, :trim_on_html_eex_engine, true)

    options = [
      engine: Phoenix.LiveView.TagEngine,
      line: 1,
      trim: trim,
      caller: nil,
      source: source,
      tag_handler: Phoenix.LiveView.HTMLTagHandler
    ]

    {:ok, tokens} = EEx.tokenize(source, options)
    IO.inspect(tokens)
    EEx.Compiler.compile(tokens, source, options)
  end
end
