defmodule Phoenix.Template.HEExEngine.BodyAnnot do
  @moduledoc false

  @doc false
  def handle_body_annot({:__block__, meta, entries}, {annot_before, annot_after}) do
    {dynamic, [{:safe, binary}]} = Enum.split(entries, -1)

    binary =
      case binary do
        [] ->
          ["#{annot_before}#{annot_after}"]

        [head | tail] ->
          List.update_at(
            [to_string(annot_before) <> head | tail],
            -1,
            &(&1 <> to_string(annot_after))
          )
      end

    {:__block__, meta, dynamic ++ [{:safe, binary}]}
  end

  def handle_body_annot({:__block__, _, _} = ast, _) do
    ast
  end
end
