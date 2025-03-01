defmodule Phoenix.LiveView.TagEngine do
  @moduledoc """
  An EEx engine that understands tags.

  It supports:

    * HTML validation

  It cannot be directly used. Instead, it is the building block of
  other engines, such as `Phoenix.LiveView.HTMLEngine`.

  It is typically invoked like this:

      EEx.compile_string(source,
        engine: Phoenix.LiveView.TagEngine,
        tag_handler: ExampleTagHandler,
        line: 1,
        file: path,
        caller: __CALLER__,
        source: source
      )

  Where module specified by `:tag_handler`, implements the behaviour
  defined by `Phoenix.LiveView.TagHandler`.

  ## Features

  ### Root attributes

      attrs = %{name: "Zeke", gender: "male"}
      ~H\"\"\"
      <div {attrs}>
      \"\"\"

  ## Steps

  ### Step 1 - EEx's compiler

  EEx's compiler tokenizes original source into EEx's tokens. These tokens look like:

    * `{:text, chars, meta}`
    * `{:expr, mark, chars, meta}`
    * `{:start_expr, mark, chars, meta}`
    * `{:end_expr, mark, chars, meta}`
    * `{:eof, meta}`

  ### Step 2 - #{__MODULE__}

  As we said above, this module, as an EEx engine, understands tags.

  It transforms above tokens into more detailed tokens:

    * `{:text, text, meta}`
    * `{:expr, marker, expr}`
    * `{:body_expr, value, meta}`
    * `{:tag, name, attrs, meta}`
    * `{:close, :tag, name, meta}`
    * `{:remote_component, name, attrs, meta}`
    * `{:close, :remote_component, name, meta}`
    * `{:local_component, name, attrs, meta}`
    * `{:close, :local_component, name, meta}`
    * `{:slot, name, attrs, meta}`
    * `{:close, :slot, name, meta}`

  """

  alias Phoenix.LiveView.Tokenizer
  alias Phoenix.LiveView.Tokenizer.ParseError

  alias Phoenix.Template.HEExEngine.Assign

  @behaviour EEx.Engine

  @impl true
  def init(opts) do
    subengine = Phoenix.LiveView.Engine
    tag_handler = Keyword.fetch!(opts, :tag_handler)

    %{
      tag_handler: tag_handler,
      subengine: subengine,
      substate: subengine.init(),
      file: Keyword.get(opts, :file, "nofile"),
      indentation: Keyword.get(opts, :indentation, 0),
      caller: Keyword.fetch!(opts, :caller),
      source: Keyword.fetch!(opts, :source),
      tokens: [],
      previous_token_slot?: false,
      cont: {:text, :enabled}
    }
  end

  @impl true
  def handle_begin(state) do
    update_subengine(%{state | tokens: []}, :reset, [])
  end

  @impl true
  def handle_end(state) do
    %{tokens: tokens} = state
    tokens = Enum.reverse(tokens)

    state
    |> handle_tokens(tokens, context: "do-block")
    |> invoke_subengine(:dump, [])
  end

  @impl true
  def handle_body(state) do
    %{
      tag_handler: tag_handler,
      tokens: tokens,
      file: file,
      cont: cont,
      source: source,
      caller: caller
    } = state

    tokens = Tokenizer.finalize(tokens, file, cont, source)

    opts =
      if body_annotation = caller && has_tags?(tokens) && tag_handler.annotate_body(caller) do
        [body_annotation: body_annotation]
      else
        []
      end

    ast =
      state
      |> handle_tokens(tokens, context: "template")
      |> invoke_subengine(:handle_body, [opts])
      |> Assign.handle_assigns()

    quote do
      require Phoenix.LiveView.TagEngine
      unquote(ast)
    end
  end

  @impl true
  def handle_text(state, meta, text) do
    %{
      tag_handler: tag_handler,
      file: file,
      indentation: indentation,
      source: source,
      tokens: tokens,
      cont: cont
    } = state

    tokenizer_state = Tokenizer.init(indentation, file, source, tag_handler)
    {tokens, cont} = Tokenizer.tokenize(text, meta, tokens, cont, tokenizer_state)

    %{state | tokens: tokens, cont: cont}
  end

  @impl true
  def handle_expr(%{tokens: tokens} = state, marker, expr) do
    %{state | tokens: [{:expr, marker, expr} | tokens]}
  end

  # ----------------------------------

  defp handle_tokens(state, tokens, context: context) do
    %{
      tag_handler: tag_handler,
      subengine: subengine,
      substate: substate,
      file: file,
      indentation: indentation,
      caller: caller,
      source: source
    } = state

    token_state = %{
      tag_handler: tag_handler,
      subengine: subengine,
      substate: substate,
      file: file,
      indentation: indentation,
      caller: caller,
      source: source,
      previous_token_slot?: false,
      stack: [],
      tags: [],
      slots: []
    }

    tokens
    |> Stream.map(&preprocess_token(&1, token_state))
    |> Enum.map(& &1)
    # |> IO.inspect()
    |> Enum.reduce(token_state, &handle_token/2)
    |> validate_unclosed_tags!(context)
  end

  ## preprocess attrs

  defp preprocess_token({type, _name, _attrs, _meta} = token, state)
       when type in [:tag, :remote_component, :local_component, :slot] do
    rules = [
      {&remove_phx_no_attr/3, [:tag, :remote_component, :local_component, :slot]},
      {&validate_tag_attr!/3, [:tag]},
      {&validate_component_attr!/3, [:remote_component, :local_component]},
      {&pop_special_attr!/3, [:tag, :remote_component, :local_component]}
    ]

    Enum.reduce(rules, token, fn {fun, types}, acc ->
      if type in types,
        do: apply_rule(acc, fun, state),
        else: acc
    end)
  end

  defp preprocess_token(token, _state), do: token

  defp apply_rule({t_type, t_name, t_attrs, t_meta}, fun, state) do
    {t_type, t_name, new_t_attrs, new_t_meta} =
      Enum.reduce(t_attrs, {t_type, t_name, [], t_meta}, fn attr, acc ->
        fun.(attr, acc, state)
      end)

    new_t_attrs = Enum.reverse(new_t_attrs)

    {t_type, t_name, new_t_attrs, new_t_meta}
  end

  defp remove_phx_no_attr({"phx-no-format", _, _}, token, _state),
    do: token

  defp remove_phx_no_attr({"phx-no-curly-interpolation", _, _}, token, _state),
    do: token

  defp remove_phx_no_attr(attr, {t_type, t_name, t_attrs, t_meta}, _state),
    do: {t_type, t_name, [attr | t_attrs], t_meta}

  defp validate_tag_attr!(
         {":" <> _ = a_name, a_value, a_meta} = attr,
         {t_type, t_name, t_attrs, t_meta},
         state
       )
       when a_name in [":if", ":for"] do
    # validate duplicated attr
    case List.keyfind(t_attrs, a_name, 0) do
      nil ->
        :ok

      {_, _, dup_a_meta} ->
        message = """
        cannot define multiple #{a_name} attributes. \
        Another #{a_name} has already been defined at line #{dup_a_meta.line}\
        """

        raise_syntax_error!(message, a_meta, state)
    end

    # validate value of attr
    case a_value do
      {:expr, _, _} ->
        :ok

      _ ->
        message = "#{a_name} must be an expression between {...}"
        raise_syntax_error!(message, a_meta, state)
    end

    {t_type, t_name, [attr | t_attrs], t_meta}
  end

  defp validate_tag_attr!({":" <> _ = a_name, _, a_meta}, {t_type, t_name, _, _}, state) do
    message = "unsupported attribute #{inspect(a_name)} in #{humanize_t_type(t_type)}: #{t_name}"
    raise_syntax_error!(message, a_meta, state)
  end

  defp validate_tag_attr!(attr, {t_type, t_name, t_attrs, t_meta}, _state) do
    {t_type, t_name, [attr | t_attrs], t_meta}
  end

  defp validate_component_attr!(
         {":" <> _ = a_name, a_value, a_meta} = attr,
         {t_type, t_name, t_attrs, t_meta},
         state
       )
       when a_name in [":if", ":for", ":let"] do
    # validate duplicated attr
    case List.keyfind(t_attrs, a_name, 0) do
      nil ->
        :ok

      {_, _, dup_a_meta} ->
        message = """
        cannot define multiple #{a_name} attributes. \
        Another #{a_name} has already been defined at line #{dup_a_meta.line}\
        """

        raise_syntax_error!(message, a_meta, state)
    end

    # validate value of attr
    if a_name in [":if", ":for"] do
      case a_value do
        {:expr, _, _} ->
          :ok

        _ ->
          message = "#{a_name} must be an expression between {...}"
          raise_syntax_error!(message, a_meta, state)
      end
    end

    if a_name in [":let"] do
      case a_value do
        {:expr, _, _} ->
          :ok

        _ ->
          message =
            "#{a_name} must be a pattern between {...} in #{humanize_t_type(t_type)}: #{t_name}"

          raise_syntax_error!(message, a_meta, state)
      end

      case t_meta do
        %{closing: :self} ->
          message = "cannot use #{inspect(a_name)} on a component without inner content"
          raise_syntax_error!(message, a_meta, state)

        %{} ->
          :ok
      end
    end

    {t_type, t_name, [attr | t_attrs], t_meta}
  end

  defp validate_component_attr!({":" <> _ = a_name, _, a_meta}, {t_type, t_name, _, _}, state) do
    message = "unsupported attribute #{inspect(a_name)} in #{humanize_t_type(t_type)}: #{t_name}"
    raise_syntax_error!(message, a_meta, state)
  end

  defp validate_component_attr!(attr, {t_type, t_name, t_attrs, t_meta}, _state) do
    {t_type, t_name, [attr | t_attrs], t_meta}
  end

  defp pop_special_attr!(
         {":" <> _ = a_name, a_value, a_meta} = attr,
         {t_type, t_name, t_attrs, t_meta},
         state
       )
       when a_name in [":if", ":for"] do
    expr = parse_expr!(a_value, state)
    validate_quoted_special_attr!(a_name, expr, a_meta, state)

    key =
      case a_name do
        ":if" -> :if
        ":for" -> :for
      end

    t_meta = Map.put(t_meta, key, expr)
    {t_type, t_name, t_attrs, t_meta}
  end

  defp pop_special_attr!(attr, {t_type, t_name, t_attrs, t_meta}, _state) do
    {t_type, t_name, [attr | t_attrs], t_meta}
  end

  ## handle tokens

  # Text

  defp handle_token({:text, text, %{line_end: line, column_end: column}}, state) do
    text = if state.previous_token_slot?, do: String.trim_leading(text), else: text

    if text == "" do
      state
    else
      state
      |> update_subengine(:acc_text, [text])
    end
  end

  # Expr

  defp handle_token({:expr, marker, expr}, state) do
    state
    |> update_subengine(:acc_expr, [marker, expr])
  end

  defp handle_token({:body_expr, value, %{line: line, column: column}}, state) do
    expr = Code.string_to_quoted!(value, line: line, column: column, file: state.file)

    state
    |> update_subengine(:acc_expr, ["=", expr])
  end

  # HTML element (self close)

  defp handle_token({:tag, name, attrs, %{closing: closing} = tag_meta}, state) do
    suffix = if closing == :void, do: ">", else: "></#{name}>"

    if has_special_expr?(tag_meta) do
      state
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
      |> handle_tag_and_attrs(name, attrs, suffix, to_location(tag_meta))
      |> handle_special_expr(tag_meta)
    else
      state
      |> handle_tag_and_attrs(name, attrs, suffix, to_location(tag_meta))
    end
  end

  # HTML element

  defp handle_token({:tag, name, attrs, tag_meta} = token, state) do
    if has_special_expr?(tag_meta) do
      state
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
      |> push_tag({:tag, name, attrs, tag_meta})
      |> handle_tag_and_attrs(name, attrs, ">", to_location(tag_meta))
    else
      state
      |> push_tag(token)
      |> handle_tag_and_attrs(name, attrs, ">", to_location(tag_meta))
    end
  end

  defp handle_token({:close, :tag, name, tag_meta} = token, state) do
    {{:tag, _name, _attrs, tag_open_meta}, state} = pop_tag!(state, token)

    state
    |> update_subengine(:acc_text, ["</#{name}>"])
    |> handle_special_expr(tag_open_meta)
  end

  # Remote function component (self close)

  defp handle_token(
         {:remote_component, name, attrs, %{closing: :self} = tag_meta},
         state
       ) do
    {mod_ast, mod_size, fun} = decompose_remote_component_tag!(name, tag_meta, state)
    %{line: line, column: column} = tag_meta

    {assigns, attr_info} =
      build_self_close_component_assigns({"remote component", name}, attrs, tag_meta.line, state)

    mod = expand_with_line(mod_ast, line, state.caller)
    store_component_call({mod, fun}, attr_info, [], line, state)
    meta = [line: line, column: column + mod_size]
    call = {{:., meta, [mod_ast, fun]}, meta, []}

    ast =
      quote line: tag_meta.line do
        unquote(__MODULE__).component(
          &(unquote(call) / 1),
          unquote(assigns)
        )
      end

    if has_special_expr?(tag_meta) do
      state
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
      |> maybe_anno_caller(meta, state.file, line)
      |> update_subengine(:acc_expr, ["=", ast])
      |> handle_special_expr(tag_meta)
    else
      state
      |> maybe_anno_caller(meta, state.file, line)
      |> update_subengine(:acc_expr, ["=", ast])
    end
  end

  # Remote function component (with inner content)

  defp handle_token({:remote_component, name, attrs, tag_meta}, state) do
    mod_fun = decompose_remote_component_tag!(name, tag_meta, state)
    tag_meta = Map.put(tag_meta, :mod_fun, mod_fun)

    if has_special_expr?(tag_meta) do
      state
      |> push_tag({:remote_component, name, attrs, tag_meta})
      |> init_slots()
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
    else
      state
      |> push_tag({:remote_component, name, attrs, tag_meta})
      |> init_slots()
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
    end
  end

  defp handle_token({:close, :remote_component, _name, _tag_close_meta} = token, state) do
    {{:remote_component, name, attrs, tag_meta}, state} = pop_tag!(state, token)
    %{mod_fun: {mod_ast, mod_size, fun}, line: line, column: column} = tag_meta

    mod = expand_with_line(mod_ast, line, state.caller)

    {assigns, attr_info, slot_info, state} =
      build_component_assigns({"remote component", name}, attrs, line, tag_meta, state)

    store_component_call({mod, fun}, attr_info, slot_info, line, state)
    meta = [line: line, column: column + mod_size]
    call = {{:., meta, [mod_ast, fun]}, meta, []}

    ast =
      quote line: line do
        unquote(__MODULE__).component(
          &(unquote(call) / 1),
          unquote(assigns)
        )
      end
      |> tag_slots(slot_info)

    state
    |> pop_substate_from_stack()
    |> maybe_anno_caller(meta, state.file, line)
    |> update_subengine(:acc_expr, ["=", ast])
    |> handle_special_expr(tag_meta)
  end

  # Local function component (self close)

  defp handle_token({:local_component, name, attrs, %{closing: :self} = tag_meta}, state) do
    fun = String.to_atom(name)
    %{line: line, column: column} = tag_meta

    {assigns, attr_info} =
      build_self_close_component_assigns({"local component", fun}, attrs, line, state)

    mod = actual_component_module(state.caller, fun)
    store_component_call({mod, fun}, attr_info, [], line, state)
    meta = [line: line, column: column]
    call = {fun, meta, __MODULE__}

    ast =
      quote line: line do
        unquote(__MODULE__).component(
          &(unquote(call) / 1),
          unquote(assigns)
        )
      end

    if has_special_expr?(tag_meta) do
      state
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
      |> maybe_anno_caller(meta, state.file, line)
      |> update_subengine(:acc_expr, ["=", ast])
      |> handle_special_expr(tag_meta)
    else
      state
      |> maybe_anno_caller(meta, state.file, line)
      |> update_subengine(:acc_expr, ["=", ast])
    end
  end

  # Local function component (with inner content)

  defp handle_token({:local_component, name, attrs, tag_meta} = token, state) do
    if has_special_expr?(tag_meta) do
      state
      |> push_tag({:local_component, name, attrs, tag_meta})
      |> init_slots()
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
    else
      state
      |> push_tag(token)
      |> init_slots()
      |> push_substate_to_stack()
      |> update_subengine(:reset, [])
    end
  end

  defp handle_token({:close, :local_component, _name, _tag_close_meta} = token, state) do
    {{:local_component, name, attrs, tag_meta}, state} = pop_tag!(state, token)
    fun = String.to_atom(name)
    %{line: line, column: column} = tag_meta

    mod = actual_component_module(state.caller, fun)

    {assigns, attr_info, slot_info, state} =
      build_component_assigns({"local component", fun}, attrs, line, tag_meta, state)

    store_component_call({mod, fun}, attr_info, slot_info, line, state)
    meta = [line: line, column: column]
    call = {fun, meta, __MODULE__}

    ast =
      quote line: line do
        unquote(__MODULE__).component(
          &(unquote(call) / 1),
          unquote(assigns)
        )
      end
      |> tag_slots(slot_info)

    state
    |> pop_substate_from_stack()
    |> maybe_anno_caller(meta, state.file, line)
    |> update_subengine(:acc_expr, ["=", ast])
    |> handle_special_expr(tag_meta)
  end

  # Slot (self close)

  defp handle_token(
         {:slot, slot_name, attrs, %{closing: :self} = tag_meta},
         state
       ) do
    slot_name = String.to_atom(slot_name)
    validate_slot!(state, slot_name, tag_meta)

    %{line: line} = tag_meta
    {special, roots, attrs, attr_info} = split_component_attrs({"slot", slot_name}, attrs, state)
    let = special[":let"]

    with {_, let_meta} <- let do
      message = "cannot use :let on a slot without inner content"
      raise_syntax_error!(message, let_meta, state)
    end

    attrs = [__slot__: slot_name, inner_block: nil] ++ attrs
    assigns = wrap_special_slot(special, merge_component_attrs(roots, attrs, line))
    add_slot(state, slot_name, assigns, attr_info, tag_meta, special)
  end

  # Slot (with inner content)

  defp handle_token({:slot, slot_name, _attrs, tag_meta} = token, state) do
    validate_slot!(state, slot_name, tag_meta)

    state
    |> push_tag(token)
    |> push_substate_to_stack()
    |> update_subengine(:reset, [])
  end

  defp handle_token({:close, :slot, slot_name, _tag_close_meta} = token, state) do
    slot_name = String.to_atom(slot_name)
    {{:slot, _name, attrs, %{line: line} = tag_meta}, state} = pop_tag!(state, token)

    {special, roots, attrs, attr_info} = split_component_attrs({"slot", slot_name}, attrs, state)
    clauses = build_component_clauses(special[":let"], state)

    ast =
      quote line: line do
        Phoenix.LiveView.TagEngine.inner_block(unquote(slot_name), do: unquote(clauses))
      end

    attrs = [__slot__: slot_name, inner_block: ast] ++ attrs
    assigns = wrap_special_slot(special, merge_component_attrs(roots, attrs, line))
    inner = add_inner_block(attr_info, ast, tag_meta)

    state
    |> add_slot(slot_name, assigns, inner, tag_meta, special)
    |> pop_substate_from_stack()
  end

  defp has_special_expr?(tag_meta) do
    Map.has_key?(tag_meta, :for) or Map.has_key?(tag_meta, :if)
  end

  defp validate_unclosed_tags!(%{tags: []} = state, _context) do
    state
  end

  defp validate_unclosed_tags!(%{tags: [tag | _]} = state, context) do
    {_type, _name, _attrs, meta} = tag
    message = "end of #{context} reached without closing tag for <#{meta.tag_name}>"
    raise_syntax_error!(message, meta, state)
  end

  defp push_substate_to_stack(%{substate: substate, stack: stack} = state) do
    %{state | stack: [{:substate, substate} | stack]}
  end

  defp pop_substate_from_stack(%{stack: [{:substate, substate} | stack]} = state) do
    %{state | stack: stack, substate: substate}
  end

  defp invoke_subengine(%{subengine: subengine, substate: substate}, fun, args) do
    apply(subengine, fun, [substate | args])
  end

  defp update_subengine(state, fun, args) do
    %{state | substate: invoke_subengine(state, fun, args), previous_token_slot?: false}
  end

  defp init_slots(state) do
    %{state | slots: [[] | state.slots]}
  end

  defp add_inner_block({roots?, attrs, locs}, ast, tag_meta) do
    {roots?, [{:inner_block, ast} | attrs], [line_column(tag_meta) | locs]}
  end

  defp add_slot(state, slot_name, slot_assigns, slot_info, tag_meta, special_attrs) do
    %{slots: [slots | other_slots]} = state
    slot = {slot_name, slot_assigns, special_attrs, {tag_meta, slot_info}}
    %{state | slots: [[slot | slots] | other_slots], previous_token_slot?: true}
  end

  defp validate_slot!(%{tags: [{type, _, _, _} | _]}, _name, _tag_meta)
       when type in [:remote_component, :local_component],
       do: :ok

  defp validate_slot!(state, slot_name, meta) do
    message =
      "invalid slot entry <:#{slot_name}>. A slot entry must be a direct child of a component"

    raise_syntax_error!(message, meta, state)
  end

  defp pop_slots(%{slots: [slots | other_slots]} = state) do
    # Perform group_by by hand as we need to group two distinct maps.
    {acc_assigns, acc_info, specials} =
      Enum.reduce(slots, {%{}, %{}, %{}}, fn {key, assigns, special, info},
                                             {acc_assigns, acc_info, specials} ->
        special? = Map.has_key?(special, ":if") or Map.has_key?(special, ":for")
        specials = Map.update(specials, key, special?, &(&1 or special?))

        case acc_assigns do
          %{^key => existing_assigns} ->
            acc_assigns = %{acc_assigns | key => [assigns | existing_assigns]}
            %{^key => existing_info} = acc_info
            acc_info = %{acc_info | key => [info | existing_info]}
            {acc_assigns, acc_info, specials}

          %{} ->
            {Map.put(acc_assigns, key, [assigns]), Map.put(acc_info, key, [info]), specials}
        end
      end)

    acc_assigns =
      Enum.into(acc_assigns, %{}, fn {key, assigns_ast} ->
        cond do
          # No special entry, return it as a list
          not Map.fetch!(specials, key) ->
            {key, assigns_ast}

          # We have a special entry and multiple entries, we have to flatten
          match?([_, _ | _], assigns_ast) ->
            {key, quote(do: List.flatten(unquote(assigns_ast)))}

          # A single special entry is guaranteed to return a list from the expression
          true ->
            {key, hd(assigns_ast)}
        end
      end)

    {Map.to_list(acc_assigns), Map.to_list(acc_info), %{state | slots: other_slots}}
  end

  defp push_tag(state, token) do
    %{state | tags: [token | state.tags]}
  end

  defp pop_tag!(
         %{tags: [{type, tag_name, _attrs, _meta} = tag | tags]} = state,
         {:close, type, tag_name, _}
       ) do
    {tag, %{state | tags: tags}}
  end

  defp pop_tag!(
         %{tags: [{type, tag_open_name, _attrs, tag_open_meta} | _]} = state,
         {:close, type, tag_close_name, tag_close_meta}
       ) do
    hint = closing_void_hint(tag_close_name, state)

    message = """
    unmatched closing tag. Expected </#{tag_open_name}> for <#{tag_open_name}> \
    at line #{tag_open_meta.line}, got: </#{tag_close_name}>#{hint}\
    """

    raise_syntax_error!(message, tag_close_meta, state)
  end

  defp pop_tag!(state, {:close, _type, tag_name, tag_meta}) do
    hint = closing_void_hint(tag_name, state)
    message = "missing opening tag for </#{tag_name}>#{hint}"
    raise_syntax_error!(message, tag_meta, state)
  end

  defp closing_void_hint(tag_name, state) do
    if state.tag_handler.void?(tag_name) do
      " (note <#{tag_name}> is a void tag and cannot have any content)"
    else
      ""
    end
  end

  ## handle_tag_and_attrs

  defp handle_tag_and_attrs(state, name, attrs, suffix, meta) do
    state
    |> update_subengine(:acc_text, ["<#{name}"])
    |> handle_tag_attrs(meta, attrs)
    |> update_subengine(:acc_text, [suffix])
  end

  defp handle_tag_attrs(state, meta, attrs) do
    Enum.reduce(attrs, state, fn
      {:root, {:expr, _, _} = expr, _attr_meta}, state ->
        ast = parse_expr!(expr, state)

        # If we have a map of literal keys, we unpack it as a list
        # to simplify the downstream check.
        ast =
          with {:%{}, _meta, pairs} <- ast,
               true <- literal_keys?(pairs) do
            pairs
          else
            _ -> ast
          end

        handle_tag_expr_attrs(state, meta, ast)

      {name, {:expr, _, _} = expr, _attr_meta}, state ->
        handle_tag_expr_attrs(state, meta, [{name, parse_expr!(expr, state)}])

      {name, {:string, value, %{delimiter: ?"}}, _attr_meta}, state ->
        update_subengine(state, :acc_text, [~s( #{name}="#{value}")])

      {name, {:string, value, %{delimiter: ?'}}, _attr_meta}, state ->
        update_subengine(state, :acc_text, [~s( #{name}='#{value}')])

      {name, nil, _attr_meta}, state ->
        update_subengine(state, :acc_text, [" #{name}"])
    end)
  end

  defp handle_tag_expr_attrs(state, meta, ast) do
    # It is safe to List.wrap/1 because if we receive nil,
    # it would become the interpolation of nil, which is an
    # empty string anyway.
    case state.tag_handler.handle_attributes(ast, meta) do
      {:attributes, attrs} ->
        Enum.reduce(attrs, state, fn
          {name, value}, state ->
            state = update_subengine(state, :acc_text, [~s( #{name}=")])

            state =
              value
              |> List.wrap()
              |> Enum.reduce(state, fn
                binary, state when is_binary(binary) ->
                  update_subengine(state, :acc_text, [binary])

                expr, state ->
                  update_subengine(state, :acc_expr, ["=", expr])
              end)

            update_subengine(state, :acc_text, [~s(")])

          quoted, state ->
            update_subengine(state, :acc_expr, ["=", quoted])
        end)

      {:quoted, quoted} ->
        update_subengine(state, :acc_expr, ["=", quoted])
    end
  end

  defp parse_expr!({:expr, value, %{line: line, column: column}}, state) do
    Code.string_to_quoted!(value, line: line, column: column, file: state.file)
  end

  defp literal_keys?([{key, _value} | rest]) when is_atom(key) or is_binary(key),
    do: literal_keys?(rest)

  defp literal_keys?([]), do: true
  defp literal_keys?(_other), do: false

  defp handle_special_expr(state, tag_meta) do
    ast =
      case tag_meta do
        %{for: for_expr, if: if_expr} ->
          quote do
            for unquote(for_expr), unquote(if_expr),
              do: unquote(invoke_subengine(state, :dump, []))
          end

        %{for: for_expr} ->
          quote do
            for unquote(for_expr), do: unquote(invoke_subengine(state, :dump, []))
          end

        %{if: if_expr} ->
          quote do
            if unquote(if_expr), do: unquote(invoke_subengine(state, :dump, []))
          end

        %{} ->
          nil
      end

    if ast do
      state
      |> pop_substate_from_stack()
      |> update_subengine(:acc_expr, ["=", ast])
    else
      state
    end
  end

  ## build_self_close_component_assigns/build_component_assigns

  defp build_self_close_component_assigns(type_component, attrs, line, state) do
    IO.inspect({type_component, attrs, line})

    {special, roots, attrs, attr_info} =
      split_component_attrs(type_component, attrs, state) |> IO.inspect()

    # {assigns, attr_info}
    {merge_component_attrs(roots, attrs, line), attr_info}
  end

  defp build_component_assigns(type_component, attrs, line, tag_meta, state) do
    {special, roots, attrs, attr_info} = split_component_attrs(type_component, attrs, state)
    clauses = build_component_clauses(special[":let"], state)

    inner_block =
      quote line: line do
        Phoenix.LiveView.TagEngine.inner_block(:inner_block, do: unquote(clauses))
      end

    inner_block_assigns =
      quote line: line do
        %{
          __slot__: :inner_block,
          inner_block: unquote(inner_block)
        }
      end

    {slot_assigns, slot_info, state} = pop_slots(state)

    slot_info = [
      {:inner_block, [{tag_meta, add_inner_block({false, [], []}, inner_block, tag_meta)}]}
      | slot_info
    ]

    attrs = attrs ++ [{:inner_block, [inner_block_assigns]} | slot_assigns]
    {merge_component_attrs(roots, attrs, line), attr_info, slot_info, state}
  end

  defp split_component_attrs(type_component, attrs, state) do
    {special, roots, attrs, locs} =
      attrs
      |> Enum.reverse()
      |> Enum.reduce(
        {%{}, [], [], []},
        fn attr, acc ->
          split_component_attr(attr, acc, state, type_component)
        end
      )

    #           root_attributes
    #            |
    # {special, roots, attrs, attr_info}
    #                  |
    #                  regular attributes
    #                       has_root?
    {special, roots, attrs, {roots != [], attrs, locs}}
  end

  defp split_component_attr(
         {:root, {:expr, value, %{line: line, column: col}}, _attr_meta},
         {special, r, a, locs},
         state,
         _type_component
       ) do
    quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: state.file)
    quoted_value = quote line: line, do: Map.new(unquote(quoted_value))
    {special, [quoted_value | r], a, locs}
  end

  @special_attrs ~w(:let :if :for)
  defp split_component_attr(
         {attr, {:expr, value, %{line: line, column: col} = meta}, attr_meta},
         {special, r, a, locs},
         state,
         _type_component
       )
       when attr in @special_attrs do
    quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: state.file)
    validate_quoted_special_attr!(attr, quoted_value, attr_meta, state)
    {Map.put(special, attr, {quoted_value, attr_meta}), r, a, locs}
  end

  defp split_component_attr(
         {name, {:expr, value, %{line: line, column: col}}, attr_meta},
         {special, r, a, locs},
         state,
         _type_component
       ) do
    quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: state.file)
    {special, r, [{String.to_atom(name), quoted_value} | a], [line_column(attr_meta) | locs]}
  end

  defp split_component_attr(
         {name, {:string, value, _meta}, attr_meta},
         {special, r, a, locs},
         _state,
         _type_component
       ) do
    {special, r, [{String.to_atom(name), value} | a], [line_column(attr_meta) | locs]}
  end

  defp split_component_attr(
         {name, nil, attr_meta},
         {special, r, a, locs},
         _state,
         _type_component
       ) do
    {special, r, [{String.to_atom(name), true} | a], [line_column(attr_meta) | locs]}
  end

  defp line_column(%{line: line, column: column}), do: {line, column}

  defp merge_component_attrs(roots, attrs, line) do
    entries =
      case {roots, attrs} do
        {[], []} -> [{:%{}, [], []}]
        {_, []} -> roots
        {_, _} -> roots ++ [{:%{}, [], attrs}]
      end

    Enum.reduce(entries, fn expr, acc ->
      quote line: line, do: Map.merge(unquote(acc), unquote(expr))
    end)
  end

  defp decompose_remote_component_tag!(tag_name, tag_meta, state) do
    case String.split(tag_name, ".") |> Enum.reverse() do
      [<<first, _::binary>> = fun_name | rest] when first in ?a..?z ->
        size = Enum.sum(Enum.map(rest, &byte_size/1)) + length(rest) + 1
        aliases = rest |> Enum.reverse() |> Enum.map(&String.to_atom/1)
        fun = String.to_atom(fun_name)
        %{line: line, column: column} = tag_meta
        {{:__aliases__, [line: line, column: column], aliases}, size, fun}

      _ ->
        message = "invalid tag <#{tag_meta.tag_name}>"
        raise_syntax_error!(message, tag_meta, state)
    end
  end

  @doc false
  def __unmatched_let__!(pattern, value) do
    message = """
    cannot match arguments sent from render_slot/2 against the pattern in :let.

    Expected a value matching `#{pattern}`, got: #{inspect(value)}\
    """

    stacktrace =
      self()
      |> Process.info(:current_stacktrace)
      |> elem(1)
      |> Enum.drop(2)

    reraise(message, stacktrace)
  end

  defp build_component_clauses(let, state) do
    case let do
      # If we have a var, we can skip the catch-all clause
      {{var, _, ctx} = pattern, %{line: line}} when is_atom(var) and is_atom(ctx) ->
        quote line: line do
          unquote(pattern) -> unquote(invoke_subengine(state, :dump, []))
        end

      {pattern, %{line: line}} ->
        quote line: line do
          unquote(pattern) -> unquote(invoke_subengine(state, :dump, []))
        end ++
          quote line: line, generated: true do
            other ->
              Phoenix.LiveView.TagEngine.__unmatched_let__!(
                unquote(Macro.to_string(pattern)),
                other
              )
          end

      _ ->
        quote do
          _ -> unquote(invoke_subengine(state, :dump, []))
        end
    end
  end

  defp store_component_call(component, attr_info, slot_info, line, %{caller: caller} = state) do
    module = caller.module

    if module && Module.open?(module) do
      pruned_slots =
        for {slot_name, slot_values} <- slot_info, into: %{} do
          values =
            for {tag_meta, {root?, attrs, locs}} <- slot_values do
              %{line: tag_meta.line, attrs: attrs_for_call(attrs, locs)}
            end

          {slot_name, values}
        end

      {root?, attrs, locs} = attr_info
      pruned_attrs = attrs_for_call(attrs, locs)

      call = %{
        component: component,
        slots: pruned_slots,
        attrs: pruned_attrs,
        file: state.file,
        line: line,
        root: root?
      }

      # This may still fail under a very specific scenario where
      # we are defining a template dynamically inside a function
      # (most likely a test) that starts running while the module
      # is still open.
      try do
        Module.put_attribute(module, :__components_calls__, call)
      rescue
        _ -> :ok
      end
    end
  end

  defp attrs_for_call(attrs, locs) do
    for {{attr, value}, {line, column}} <- Enum.zip(attrs, locs),
        do: {attr, {line, column, attr_type(value)}},
        into: %{}
  end

  defp attr_type({:<<>>, _, _} = value), do: {:string, value}
  defp attr_type(value) when is_list(value), do: {:list, value}
  defp attr_type(value = {:%{}, _, _}), do: {:map, value}
  defp attr_type(value) when is_binary(value), do: {:string, value}
  defp attr_type(value) when is_integer(value), do: {:integer, value}
  defp attr_type(value) when is_float(value), do: {:float, value}
  defp attr_type(value) when is_boolean(value), do: {:boolean, value}
  defp attr_type(value) when is_atom(value), do: {:atom, value}
  defp attr_type({:fn, _, [{:->, _, [args, _]}]}), do: {:fun, length(args)}
  defp attr_type({:&, _, [{:/, _, [_, arity]}]}), do: {:fun, arity}

  # this could be a &myfun(&1, &2)
  defp attr_type({:&, _, args}) do
    {_ast, arity} =
      Macro.prewalk(args, 0, fn
        {:&, _, [n]} = ast, acc when is_integer(n) ->
          {ast, max(n, acc)}

        ast, acc ->
          {ast, acc}
      end)

    (arity > 0 && {:fun, arity}) || :any
  end

  defp attr_type(_value), do: :any

  defp to_location(%{line: line, column: column}), do: [line: line, column: column]

  defp actual_component_module(env, fun) do
    case Macro.Env.lookup_import(env, {fun, 1}) do
      [{_, module} | _] -> module
      _ -> env.module
    end
  end

  defp validate_quoted_special_attr!(":for", {:<-, _, [_, _]}, _attr_meta, _state) do
    :ok
  end

  defp validate_quoted_special_attr!(":for", quoted_value, attr_meta, state) do
    message = ":for must be a generator expression (pattern <- enumerable) between {...}"
    raise_syntax_error!(message, attr_meta, state)
  end

  defp validate_quoted_special_attr!(_attr, _quoted_value, _attr_meta, _state) do
    :ok
  end

  defp tag_slots({call, meta, args}, slot_info) do
    {call, [slots: Keyword.keys(slot_info)] ++ meta, args}
  end

  defp wrap_special_slot(special, ast) do
    case special do
      %{":for" => {for_expr, %{line: line}}, ":if" => {if_expr, %{line: _line}}} ->
        quote line: line do
          for unquote(for_expr), unquote(if_expr), do: unquote(ast)
        end

      %{":for" => {for_expr, %{line: line}}} ->
        quote line: line do
          for unquote(for_expr), do: unquote(ast)
        end

      %{":if" => {if_expr, %{line: line}}} ->
        quote line: line do
          if unquote(if_expr), do: [unquote(ast)], else: []
        end

      %{} ->
        ast
    end
  end

  defp expand_with_line(ast, line, env) do
    Macro.expand(ast, %{env | line: line})
  end

  defp raise_syntax_error!(message, meta, state) do
    raise ParseError,
      line: meta.line,
      column: meta.column,
      file: state.file,
      description: message <> ParseError.code_snippet(state.source, meta, state.indentation)
  end

  defp maybe_anno_caller(state, meta, file, line) do
    if anno = state.tag_handler.annotate_caller(file, line) do
      update_subengine(state, :acc_text, [anno])
    else
      state
    end
  end

  @doc """
  Renders a component defined by the given function.

  This function is rarely invoked directly by users. Instead, it is used by `~H`
  and other engine implementations to render `Phoenix.Component`s. For example,
  the following:

  ```heex
  <MyApp.Weather.city name="Kraków" />
  ```

  It is the same as:

  ```heex
  <%= component(&MyApp.Weather.city/1, [name: "Kraków"]) %>
  ```

  """
  def component(func, assigns)
      when is_function(func, 1) and (is_map(assigns) or is_list(assigns)) do
    assigns =
      case assigns do
        %{} -> assigns
        _ -> Map.new(assigns)
      end

    case func.(assigns) do
      {:safe, data} when is_list(data) or is_binary(data) ->
        {:safe, data}

      other ->
        raise RuntimeError, """
        expected #{inspect(func)} to return a tuple {:safe, iodata()}

        Ensure your render function uses ~H to define its template.

        Got:

            #{inspect(other)}

        """
    end
  end

  @doc """
  Define a inner block, generally used by slots.

  This macro is mostly used by custom HTML engines that provide
  a `slot` implementation and rarely called directly. The
  `name` must be the assign name the slot/block will be stored
  under.

  If you're using HEEx templates, you should use its higher
  level `<:slot>` notation instead. See `Phoenix.Component`
  for more information.
  """
  defmacro inner_block(name, do: do_block) do
    case do_block do
      [{:->, meta, _} | _] ->
        inner_fun = {:fn, meta, do_block}

        quote do
          fn arg ->
            unquote(inner_fun).(arg)
          end
        end

      _ ->
        quote do
          fn arg ->
            unquote(do_block)
          end
        end
    end
  end

  defp has_tags?(tokens) do
    Enum.any?(tokens, fn
      {:text, _, _} -> false
      {:expr, _, _} -> false
      {:body_expr, _, _} -> false
      _ -> true
    end)
  end

  defp humanize_t_type(:tag), do: "tag"
  defp humanize_t_type(:remote_component), do: "remote component"
  defp humanize_t_type(:local_component), do: "local component"
  defp humanize_t_type(:slot), do: "slot"
end
