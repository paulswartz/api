defmodule State.Server.Query do
  @moduledoc """
  Queries a Server given a map of values.

  Given a Server module and a map of key -> [value], return the values from
  the Server where each of the keys has one of the values from the given
  list. A key without a provided list can have any value.

  An example query for schedules would look like:

  %{
     trip_id: ["1", "2"],
     stop_id: ["3", "4"]
  }

  And the results would be the schedules on trip 1 or 2, stopping at stop 3 or 4.
  """

  @type q :: map
  @type recordable :: struct
  @type index :: atom

  @spec query(module, q | [q]) :: [recordable] when q: map, recordable: struct
  def query(module, %{} = q) when is_atom(module) do
    do_query(module, [q])
  end

  def query(module, [%{} | _] = qs) do
    do_query(module, qs)
  end

  def query(_module, []) do
    []
  end

  defmodule Result do
    @moduledoc false
    @enforce_keys [:module, :recordable]
    defstruct [
      :module,
      :recordable,
      matches: [],
      selectors: [],
      seen: MapSet.new(),
      queued: []
    ]
  end

  alias __MODULE__.Result

  defp do_query(module, qs) do
    result = %Result{
      module: module,
      recordable: module.recordable()
    }

    Enum.reduce(qs, result, &accumulate/2)
  end

  def accumulate(q, %Result{module: module, recordable: recordable} = result)
      when map_size(q) > 0 do
    {is_db_index?, index} = first_index(module.indices(), q)
    rest = Map.delete(q, index)

    filter_fn = & &1

    case {is_db_index?,
          Enum.reduce_while(
            rest,
            {recordable.filled(:_), [], filter_fn, 1},
            &build_struct_and_guards/2
          )} do
      {true, {struct, [], filter_fn, _}} ->
        index_values = Map.get(q, index)

        %{result | matches: [{index, index_values, struct, filter_fn} | result.matches]}

      {_, {struct, guards, filter_fn, _}} ->
        # put shorter guards at the front
        guards = :lists.usort(guards)

        index_values = Map.get(q, index)

        selectors =
          for record <- records_from_struct_and_values(struct, index, index_values) do
            {
              record,
              guards,
              [:"$_"]
            }
          end

        %{result | selectors: [{selectors, filter_fn} | result.selectors]}

      {_, :empty} ->
        result
    end
  end

  def accumulate(_q, result) do
    result
  end

  defp records_from_struct_and_values(%{__struct__: recordable} = struct, index, index_values) do
    for value <- index_values do
      struct
      |> Map.put(index, value)
      |> recordable.to_record()
    end
  end

  @doc """
  Returns the first index which has a value in the query.

  If no index has a value in the query, return any key that's there.

  ## Examples

      iex> first_index([:a, :b], %{a: 1})
      {true, :a}
      iex> first_index([:a, :b], %{a: 1, b: 2})
      {true, :a}

      iex> first_index([:a, :b], %{b: 2})
      {true, :b}

      iex> first_index([:a, :b], %{c: 3})
      {false, :c}
  """
  @spec first_index([index, ...], q) :: {boolean, index}
  def first_index(indices, q) do
    index = Enum.find(indices, &Map.has_key?(q, &1))

    if index do
      {true, index}
    else
      {false, List.first(Map.keys(q))}
    end
  end

  @doc """
  Generate a guard for a match specification where the variable is one of the provided values.

  ## Examples
      iex> build_guard(:y, [1, 2])
      {:orelse, {:"=:=", :y, 1}, {:"=:=", :y, 2}}
  """
  @spec build_guard(variable, values) :: tuple when variable: atom, values: [any, ...]
  def build_guard(variable, [_, _ | _] = values) do
    guards = for value <- values, do: {:"=:=", variable, value}
    List.to_tuple([:orelse | guards])
  end

  defp build_struct_and_guards({key, [value]}, {struct, guards, filter_fn, i}) do
    struct = Map.put(struct, key, value)
    {:cont, {struct, guards, filter_fn, i}}
  end

  defp build_struct_and_guards({key, [_ | _] = values}, {struct, guards, filter_fn, i}) do
    query_variable = query_variable(i)
    struct = Map.put(struct, key, query_variable)
    guard = build_guard(query_variable, values)
    {:cont, {struct, [guard | guards], filter_fn, i + 1}}
  end

  defp build_struct_and_guards({key, fun}, {struct, guards, filter_fn, i})
       when is_function(fun, 1) do
    new_filter_fn = fn items ->
      for %{^key => value} = item <- filter_fn.(items),
          fun.(value) do
        item
      end
    end

    {:cont, {struct, guards, new_filter_fn, i}}
  end

  defp build_struct_and_guards({_key, []}, _) do
    {:halt, :empty}
  end

  # build query variables at compile time
  for i <- 1..20 do
    defp query_variable(unquote(i)), do: unquote(String.to_atom("$#{i}"))
  end
end

defimpl Enumerable, for: State.Server.Query.Result do
  alias State.Server

  def count(_result) do
    {:error, __MODULE__}
  end

  def member?(_result, _element) do
    {:error, __MODULE__}
  end

  def slice(_result) do
    {:error, __MODULE__}
  end

  def reduce(_result, {:halt, acc}, _fun) do
    {:halted, acc}
  end

  def reduce(result, {:suspend, acc}, fun) do
    {:suspended, acc, &reduce(result, &1, fun)}
  end

  def reduce(%{queued: [head | tail], seen: seen} = result, {:cont, acc} = cont, fun) do
    result = %{result | queued: tail}

    if MapSet.member?(seen, head) do
      reduce(result, cont, fun)
    else
      seen = MapSet.put(seen, head)
      result = %{result | seen: seen}
      reduce(result, fun.(head, acc), fun)
    end
  end

  def reduce(
        %{matches: [{index, [index_head | index_tail], struct, filter_fn} | tail]} = result,
        cont,
        fun
      ) do
    %{module: module, recordable: recordable} = result

    record =
      struct
      |> Map.put(index, index_head)
      |> recordable.to_record()

    queued = Server.by_index_match(record, module, index, [])
    queued = filter_fn.(queued)

    result = %{result | matches: [{index, index_tail, struct, filter_fn} | tail], queued: queued}
    reduce(result, cont, fun)
  end

  def reduce(%{matches: [{_index, [], _struct, _filter_fn} | tail]} = result, cont, fun) do
    result = %{result | matches: tail}
    reduce(result, cont, fun)
  end

  def reduce(%{module: module, selectors: [{head, filter_fn} | tail]} = result, cont, fun) do
    queued = Server.select_with_selectors(module, head)
    queued = filter_fn.(queued)
    result = %{result | selectors: tail, queued: queued}
    reduce(result, cont, fun)
  end

  def reduce(%{matches: [], selectors: [], queued: []}, {:cont, acc}, _fun) do
    {:done, acc}
  end
end
