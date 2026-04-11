defmodule Dust.ActivityBufferTest do
  use ExUnit.Case, async: true

  setup do
    name = :"activity_buf_#{System.unique_integer([:positive])}"
    :ignore = Dust.ActivityBuffer.start_link(name: name)
    %{buf: name}
  end

  test "append and recent", %{buf: buf} do
    Dust.ActivityBuffer.append(buf, "test/store", %{
      path: "posts.hello",
      op: :set,
      source: :server,
      seq: 1
    })

    entries = Dust.ActivityBuffer.recent(buf, "test/store")
    assert length(entries) == 1
    assert hd(entries).path == "posts.hello"
    assert hd(entries).op == :set
    assert %DateTime{} = hd(entries).timestamp
  end

  test "recent returns newest first", %{buf: buf} do
    for i <- 1..5 do
      Dust.ActivityBuffer.append(buf, "test/store", %{
        path: "item.#{i}",
        op: :set,
        source: :server,
        seq: i
      })
    end

    entries = Dust.ActivityBuffer.recent(buf, "test/store")
    seqs = Enum.map(entries, & &1.seq)
    assert seqs == [5, 4, 3, 2, 1]
  end

  test "caps at 100 entries per store", %{buf: buf} do
    for i <- 1..150 do
      Dust.ActivityBuffer.append(buf, "test/store", %{
        path: "item.#{i}",
        op: :set,
        source: :server,
        seq: i
      })
    end

    entries = Dust.ActivityBuffer.recent(buf, "test/store")
    assert length(entries) == 100
    # Newest entries kept
    assert hd(entries).seq == 150
    assert List.last(entries).seq == 51
  end

  test "stores are independent", %{buf: buf} do
    Dust.ActivityBuffer.append(buf, "store/a", %{path: "x", op: :set, source: :local, seq: 1})
    Dust.ActivityBuffer.append(buf, "store/b", %{path: "y", op: :delete, source: :server, seq: 1})

    assert length(Dust.ActivityBuffer.recent(buf, "store/a")) == 1
    assert length(Dust.ActivityBuffer.recent(buf, "store/b")) == 1
    assert Dust.ActivityBuffer.recent(buf, "store/c") == []
  end

  test "recent with limit", %{buf: buf} do
    for i <- 1..10 do
      Dust.ActivityBuffer.append(buf, "test/store", %{path: "item.#{i}", op: :set, source: :server, seq: i})
    end

    entries = Dust.ActivityBuffer.recent(buf, "test/store", 3)
    assert length(entries) == 3
    assert hd(entries).seq == 10
  end
end
