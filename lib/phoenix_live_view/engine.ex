defmodule Phoenix.LiveView.Component do
  defstruct [:id, :component, :assigns]
end

defmodule Phoenix.LiveView.Comprehension do
  defstruct [:static, :dynamics, :fingerprint, :stream]
end

defmodule Phoenix.LiveView.Rendered do
  defstruct [:static, :dynamic, :fingerprint, :root, caller: :not_available]
end

defmodule Phoenix.LiveView.Engine do
  @moduledoc false

  @doc "Initialize a new state."
  def init do
    %{
      binary: [],
      dynamic: [],
      # the engine evaluates slots in a non-linear order, which can
      # lead to variable conflicts. Therefore we use a counter to
      # ensure all variable names are unique.
      counter: Counter.new()
    }
  end

  @doc "Reset a state."
  def reset(state) do
    %{state | binary: [], dynamic: []}
  end

  @doc "Dump state to ast."
  def dump(state) do
    %{binary: binary, dynamic: dynamic} = state
    safe = {:safe, Enum.reverse(binary)}
    {:__block__, [], Enum.reverse([safe | dynamic])}
  end

  @doc "Accumulate text into state."
  def acc_text(state, text) do
    %{binary: binary} = state
    %{state | binary: [text | binary]}
  end

  @doc "Accumulate expr into state."
  def acc_expr(state, "=" = _marker, expr) do
    %{binary: binary, dynamic: dynamic, counter: counter} = state

    i = Counter.get(counter)

    var = Macro.var(:"v#{i}", __MODULE__)
    ast = quote do: unquote(var) = unquote(__MODULE__).to_safe(unquote(expr))

    Counter.inc(counter)
    %{state | dynamic: [ast | dynamic], binary: [var | binary]}
  end

  def acc_expr(state, "" = _marker, expr) do
    %{dynamic: dynamic} = state
    %{state | dynamic: [expr | dynamic]}
  end

  def acc_expr(state, marker, expr) do
    EEx.Engine.handle_expr(state, marker, expr)
  end

  # ================================
  # old ones

  def handle_body(state, opts \\ []) do
    ast =
      state
      |> dump_state_to_ast()
      |> maybe_add_body_annotation(opts)

    quote do
      require Phoenix.LiveView.Engine
      unquote(ast)
    end
  end

  # helpers

  defp dump_state_to_ast(state) do
    %{binary: binary, dynamic: dynamic} = state
    safe = {:safe, Enum.reverse(binary)}
    {:__block__, [], Enum.reverse([safe | dynamic])}
  end

  defp maybe_add_body_annotation({:__block__, meta, entries}, opts) do
    {dynamic, [{:safe, binary}]} = Enum.split(entries, -1)

    binary =
      case Keyword.fetch(opts, :body_annotation) do
        {:ok, {before, aft}} ->
          case binary do
            [] ->
              ["#{before}#{aft}"]

            [first | rest] ->
              List.update_at([to_string(before) <> first | rest], -1, &(&1 <> to_string(aft)))
          end

        :error ->
          binary
      end

    {:__block__, meta, dynamic ++ [{:safe, binary}]}
  end

  @doc false
  defmacro to_safe(ast) do
    to_safe(ast, line_from_expr(ast))
  end

  defp line_from_expr({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line_from_expr(_), do: 0

  defp to_safe(literal, _line)
       when is_binary(literal) or is_atom(literal) or is_number(literal) do
    literal
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp to_safe(literal, line) when is_list(literal) do
    quote line: line, do: Phoenix.HTML.Safe.List.to_iodata(unquote(literal))
  end

  # Calls to attributes escape is always safe
  defp to_safe(
         {{:., _, [Phoenix.LiveView.TagEngine, :attributes_escape]}, _, [_]} = safe,
         line,
         _extra_clauses?
       ) do
    quote line: line do
      elem(unquote(safe), 1)
    end
  end

  defp to_safe(expr, line) do
    quote line: line, do: unquote(__MODULE__).safe_to_iodata(unquote(expr))
  end

  @doc false
  def safe_to_iodata(expr) do
    case expr do
      {:safe, data} -> data
      bin when is_binary(bin) -> Plug.HTML.html_escape_to_iodata(bin)
      other -> Phoenix.HTML.Safe.to_iodata(other)
    end
  end
end

defmodule Counter do
  @moduledoc false

  def new, do: :counters.new(1, [])
  def inc(counter), do: :counters.add(counter, 1, 1)
  def get(counter), do: :counters.get(counter, 1)
end
