defmodule State.Server.QueryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  defmodule Example do
    @moduledoc false
    use Recordable, [:id, :data, :other_key]
    @opaque t :: %Example{}
  end

  defmodule Server do
    @moduledoc false
    use State.Server,
      indices: [:id, :other_key],
      recordable: State.Server.QueryTest.Example
  end

  alias State.Server.QueryTest.{Example, Server}
  import State.Server.Query

  doctest State.Server.Query

  describe "query/2" do
    setup :start_server

    def query_list(module, qs) do
      Enum.to_list(query(module, qs))
    end

    test "returns no items without a query" do
      Server.new_state([%Example{}])
      assert query_list(Server, %{}) == []
    end

    test "returns no items with an empty query" do
      Server.new_state([%Example{}])
      assert query_list(Server, %{id: []}) == []
    end

    test "given a query on the index, returns that item" do
      items = gen_items(2)
      Server.new_state(items)

      assert [%Example{id: 1}] = query_list(Server, %{id: [1]})
      assert [%Example{id: 1}] = query_list(Server, %{id: [0, 1]})
      assert [] = query_list(Server, %{id: [0]})
    end

    test "given multiple queries, combines them" do
      items = gen_items(2)
      Server.new_state(items)

      assert [%Example{id: 1}] = query_list(Server, %{id: [1], data: [1]})
      assert [%Example{id: 1}] = query_list(Server, %{id: [1], data: [1, :other]})
      assert [%Example{id: 1}] = query_list(Server, %{id: [0, 1], data: [1, :other]})
      assert [] = query_list(Server, %{id: [0], data: [1]})
      assert [] = query_list(Server, %{id: [1], data: [:other]})
    end

    test "can query against non-key indices" do
      items = gen_items(2)
      Server.new_state(items)

      assert [%Example{id: 1}] = query_list(Server, %{other_key: [10]})
      assert [%Example{id: 1}] = query_list(Server, %{other_key: [10], data: [1]})
    end

    test "can query against non-index values" do
      items = gen_items(2)
      Server.new_state(items)

      assert [%Example{id: 1}] = query_list(Server, %{data: [1]})
      assert [%Example{id: 1}] = query_list(Server, %{data: [0, 1]})
      assert [] = query_list(Server, %{data: [0]})
    end

    test "can accept multiple queries" do
      items = gen_items(3)
      Server.new_state(items)

      assert [] = query_list(Server, [])

      result = query(Server, [%{id: [1]}, %{id: [2]}])
      assert result |> Enum.map(& &1.id) |> Enum.sort() == [1, 2]
    end

    test "can accept a function to filter on" do
      items = gen_items(3)
      Server.new_state(items)

      assert [%Example{id: 1}] = query_list(Server, %{id: [1, 2], data: &(&1 == 1)})
    end
  end

  defp start_server(_) do
    Server.start_link()
    Server.new_state([])

    on_exit(fn ->
      try do
        GenServer.stop(Server, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp gen_items(count) do
    for i <- 1..count do
      %Example{id: i, data: i, other_key: 10 * i}
    end
  end
end
