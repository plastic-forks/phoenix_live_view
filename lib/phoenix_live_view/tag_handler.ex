defmodule Phoenix.LiveView.TagHandler do
  @moduledoc """
  A behaviour module for implementing the `:tag_handler` of
  `Phoenix.LiveView.TagEngine`.
  """

  @doc """
  Classify the tag type from the given binary.

  This must return a tuple containing the type of the tag and the name of tag.
  For instance, for LiveView which uses HTML as default tag handler this would
  return `{:tag, 'div'}` in case the given binary is identified as HTML tag.

  You can also return {:error, "reason"} so that the compiler will display this
  error.
  """
  @callback classify_type(name :: binary()) :: {type :: atom(), name :: binary()}

  @doc """
  Returns if the given binary is either void or not.

  That's mainly useful for HTML tags and used internally by the compiler. You
  can just implement as `def void?(_), do: false` if you want to ignore this.
  """
  @callback void?(name :: binary()) :: boolean()

  @doc """
  Implements processing of attributes.

  It returns a quoted expression or attributes. If attributes are returned,
  the second element is a list where each element in the list represents
  one attribute.If the list element is a two-element tuple, it is assumed
  the key is the name to be statically written in the template. The second
  element is the value which is also statically written to the template whenever
  possible (such as binaries or binaries inside a list).
  """
  @callback handle_attributes(ast :: Macro.t(), meta :: keyword) ::
              {:attributes, [{binary(), Macro.t()} | Macro.t()]} | {:quoted, Macro.t()}

  @doc """
  Callback invoked to add annotations around the whole body of a template.
  """
  @callback annotate_body(caller :: Macro.Env.t()) :: {String.t(), String.t()} | nil

  @doc """
  Callback invoked to add caller annotations before a function component is invoked.
  """
  @callback annotate_caller(file :: String.t(), line :: integer()) :: String.t() | nil
end
