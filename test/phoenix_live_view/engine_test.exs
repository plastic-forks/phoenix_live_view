defmodule Phoenix.LiveView.EngineTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Engine

  describe "rendering" do
    test "escapes HTML" do
      template = """
      <start> <%= "<escaped>" %>
      """

      assert render(template) == "<start> &lt;escaped&gt;\n"
    end

    test "escapes HTML from nested content" do
      template = """
      <%= Phoenix.LiveView.EngineTest.unsafe do %>
        <foo>
      <% end %>
      """

      assert render(template) == "\n  &lt;foo&gt;\n\n"
    end

    test "does not escape safe expressions" do
      assert render("Safe <%= {:safe, \"<value>\"} %>") == "Safe <value>"
    end

    test "nested content is always safe" do
      template = """
      <%= Phoenix.LiveView.EngineTest.safe do %>
        <foo>
      <% end %>
      """

      assert render(template) == "\n  <foo>\n\n"

      template = """
      <%= Phoenix.LiveView.EngineTest.safe do %>
        <%= "<foo>" %>
      <% end %>
      """

      assert render(template) == "\n  &lt;foo&gt;\n\n"
    end

    test "handles assigns" do
      assert render("<%= @foo %>", %{foo: "<hello>"}) == "&lt;hello&gt;"
    end

    test "supports non-output expressions" do
      template = """
      <% foo = @foo %>
      <%= foo %>
      """

      assert render(template, %{foo: "<hello>"}) == "\n&lt;hello&gt;\n"
    end

    test "supports mixed non-output expressions" do
      template = """
      prea
      <% @foo %>
      posta
      <%= @foo %>
      preb
      <% @foo %>
      middleb
      <% @foo %>
      postb
      """

      assert render(template, %{foo: "<hello>"}) ==
               "prea\n\nposta\n&lt;hello&gt;\npreb\n\nmiddleb\n\npostb\n"
    end

    test "raises KeyError for missing assigns" do
      assert_raise KeyError, fn -> render("<%= @foo %>", %{bar: true}) end
    end
  end

  describe "rendered structure" do
    test "contains two static parts and one dynamic" do
      template = "foo<%= 123 %>bar"
      assert render_to_iodata(template) == ["foo", "123", "bar"]
    end

    test "contains one static part at the beginning and one dynamic" do
      template = "foo<%= 123 %>"
      assert render_to_iodata(template) == ["foo", "123"]
      # assert render_to_iodata(template) == ["foo", "123", ""]
    end

    test "contains one static part at the end and one dynamic" do
      template = "<%= 123 %>bar"
      assert render_to_iodata(template) == ["123", "bar"]
      # assert render_to_iodata(template) == ["", "123", "bar"]
    end

    test "contains one dynamic only" do
      template = "<%= 123 %>"
      assert render_to_iodata(template) == ["123"]
      # assert render_to_iodata(template) == ["", "123", ""]
    end

    test "contains two dynamics only" do
      template = "<%= 123 %><%= 456 %>"
      assert render_to_iodata(template) == ["123", "456"]
      # assert render_to_iodata(template) == ["", "123", "", "456", ""]
    end

    test "contains two static parts and two dynamics" do
      template = "foo<%= 123 %><%= 456 %>bar"
      assert render_to_iodata(template) == ["foo", "123", "456", "bar"]
      # assert render_to_iodata(template) == ["foo", "123", "", "456", "bar"]
    end

    test "contains three static parts and two dynamics" do
      template = "foo<%= 123 %>bar<%= 456 %>baz"
      assert render_to_iodata(template) == ["foo", "123", "bar", "456", "baz"]
    end

    test "contains optimized comprehensions" do
      template = """
      before
      <%= for point <- @points do %>
        x: <%= point.x %>
        y: <%= point.y %>
      <% end %>
      after
      """

      assert render_to_iodata(template, %{points: [%{x: 1, y: 2}, %{x: 3, y: 4}]}) == [
               "before\n",
               [["\n  x: ", "1", "\n  y: ", "2", "\n"], ["\n  x: ", "3", "\n  y: ", "4", "\n"]],
               "\nafter\n"
             ]
    end
  end

  def safe(do: {:safe, _} = safe), do: safe
  def unsafe(do: {:safe, content}), do: content

  defp render_to_iodata(string, assigns \\ %{}) do
    string
    |> eval(assigns)
    |> Phoenix.HTML.Safe.to_iodata()
  end

  defp render(string, assigns \\ %{}) do
    string
    |> eval(assigns)
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp eval(string, assigns) do
    EEx.eval_string(string, [assigns: assigns], file: __ENV__.file, engine: Engine)
  end
end
