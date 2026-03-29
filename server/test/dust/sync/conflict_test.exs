defmodule Dust.Sync.ConflictTest do
  use ExUnit.Case, async: true

  alias Dust.Sync.Conflict

  describe "apply_set/2" do
    test "replaces value at exact path" do
      entries = %{"posts.hello" => %{value: %{"title" => "Old"}, type: "map"}}
      result = Conflict.apply_set(entries, "posts.hello", %{"title" => "New"}, "map")
      assert result["posts.hello"].value == %{"title" => "New"}
    end

    test "deletes descendant entries when setting ancestor" do
      entries = %{
        "posts.hello.title" => %{value: "Hello", type: "string"},
        "posts.hello.body" => %{value: "Body", type: "string"},
        "posts.other" => %{value: "Other", type: "string"}
      }
      result = Conflict.apply_set(entries, "posts.hello", %{"title" => "Replaced"}, "map")
      assert Map.has_key?(result, "posts.hello")
      refute Map.has_key?(result, "posts.hello.title")
      refute Map.has_key?(result, "posts.hello.body")
      assert Map.has_key?(result, "posts.other")
    end
  end

  describe "apply_delete/2" do
    test "removes path and descendants" do
      entries = %{
        "posts.hello" => %{value: %{}, type: "map"},
        "posts.hello.title" => %{value: "Hello", type: "string"},
        "posts.other" => %{value: "Other", type: "string"}
      }
      result = Conflict.apply_delete(entries, "posts.hello")
      refute Map.has_key?(result, "posts.hello")
      refute Map.has_key?(result, "posts.hello.title")
      assert Map.has_key?(result, "posts.other")
    end
  end

  describe "apply_merge/2" do
    test "updates named children, leaves siblings alone" do
      entries = %{
        "settings.theme" => %{value: "light", type: "string"},
        "settings.locale" => %{value: "en", type: "string"}
      }
      result = Conflict.apply_merge(entries, "settings", %{"theme" => "dark"}, "string")
      assert result["settings.theme"].value == "dark"
      assert result["settings.locale"].value == "en"
    end

    test "creates new children that don't exist" do
      entries = %{
        "settings.theme" => %{value: "light", type: "string"}
      }
      result = Conflict.apply_merge(entries, "settings", %{"locale" => "en"}, "string")
      assert result["settings.theme"].value == "light"
      assert result["settings.locale"].value == "en"
    end
  end
end
