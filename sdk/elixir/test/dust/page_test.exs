defmodule Dust.PageTest do
  use ExUnit.Case, async: true

  test "new/1 builds a page with items and nil cursor" do
    page = Dust.Page.new(items: [1, 2, 3])
    assert page.items == [1, 2, 3]
    assert page.next_cursor == nil
  end

  test "new/1 accepts next_cursor" do
    page = Dust.Page.new(items: [1], next_cursor: "x")
    assert page.next_cursor == "x"
  end

  test "enumerates via Enumerable" do
    page = Dust.Page.new(items: [1, 2, 3])
    assert Enum.to_list(page) == [1, 2, 3]
    assert Enum.count(page) == 3
  end
end
