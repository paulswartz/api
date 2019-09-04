defmodule QueryBench do
  def setup do
    Application.start(:logger)
    Logger.configure(level: :error)
    Application.ensure_all_started(:state)
    :ok = Events.subscribe({:new_state, State.Trip})
    :ok = Events.subscribe({:new_state, State.ServiceByDate})
    Application.start(:state_mediator)
    receive_items(State.ServiceByDate)
    receive_items(State.Trip)
    Application.stop(:state_mediator)
  end

  defp receive_items(module) do
    clear_inbox!()

    receive do
      {:event, {:new_state, ^module}, items, _} when items > 0 ->
        :ok
    end
  end

  defp clear_inbox! do
    receive do
      _ ->
        clear_inbox!()
    after
      0 ->
        :ok
    end
  end

  @date ~D[2019-10-10]

  def query(expected) do
    Enum.to_list(State.Server.QueryOld.query(State.Trip, %{
          route_id: ["442"],
          service_id: State.ServiceByDate.by_date(@date)
                     })) |> eq(expected)
  end

  def function(expected) do
    service_ids = MapSet.new(State.ServiceByDate.by_date(@date))

      Enum.to_list(State.Server.QueryOld.query(State.Trip, %{
          route_id: ["442"],
          service_id: &MapSet.member?(service_ids, &1)
                                             })) |> eq(expected)
    # [_ | _] = Enum.to_list(State.Server.QueryOld.query(State.Trip, %{
    #       route_id: ["442"],
    #       service_id:   &State.ServiceByDate.valid?(&1, @date)
    #                  }))
  end

  def query2(expected) do
      Enum.to_list(State.Server.Query.query(State.Trip, %{
          route_id: ["442"],
          service_id: State.ServiceByDate.by_date(@date)
                                             })) |> eq(expected)
  end

  def function2(expected) do
    service_ids = MapSet.new(State.ServiceByDate.by_date(@date))
    Enum.to_list(State.Server.Query.query(State.Trip, %{
          route_id: ["442"],
          service_id: &MapSet.member?(service_ids, &1)
                                             }))
                                             |> eq(expected)
    # [_ | _] = Enum.to_list(State.Server.Query.query(State.Trip, %{
    #       route_id: ["442"],
    #       service_id:   &State.ServiceByDate.valid?(&1, @date)
    #                  }))
  end

  def old(expected) do
    ["442"]
    |> State.Trip.by_route_ids()
    |> Enum.filter(&State.ServiceByDate.valid?(&1.service_id, @date))
    |> eq(expected)
  end

  def old_select(_expected) do
    [%{route_id: "442"}]
    |> State.Trip.select(:route_id)
    |> Enum.filter(&State.ServiceByDate.valid?(&1.service_id, @date))
    #|> eq(expected)
  end

  def eq(actual, expected) do
    ^expected = Enum.sort(actual)
    :ok
  end
end

QueryBench.setup()
inputs = %{
  expected: Enum.sort(QueryBench.old_select([]))
}
Benchee.run(%{
      query: &QueryBench.query/1,
      function: &QueryBench.function/1,
      query2: &QueryBench.query2/1,
      function2: &QueryBench.function2/1,
      old: &QueryBench.old/1,
      old_select: &QueryBench.old_select/1
            }, inputs: inputs)
