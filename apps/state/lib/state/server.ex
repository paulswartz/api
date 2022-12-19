defmodule State.Server do
  @moduledoc """
  Generates an Mnesia database for structs, indexed by specified struct fields.

  ## Example

  defmodule Example do
    use Recordable, [:id, :data, :other_key]
  end

  defmodule ExampleServer do
    use State.Server, indices: [:id, :other_key], recordable: Example
  end

  Then, clients can do:

  State.ExampleServer.new_state([<list of structs>])
  State.ExampleServer.by_id(id)
  State.ExampleServer.by_ids([<list of ids>])
  State.ExampleServer.by_other_key(key)
  State.ExampleServer.by_other_keys([<list of key>])

  ## Metadata

  When a new state is loaded, the server's last-updated timestamp in `State.Metadata` is set to
  the current datetime.

  ## Parsers

  Servers can specify a `parser` module that implements the `Parse` behaviour. If so, `new_state`
  accepts a string in addition to a list of structs, and strings will be passed through the parser
  module.

  ## Events

  An event is published using `Events` whenever a new state is loaded, including on startup. The
  event name is `{:new_state, server_module}` and the data is the new count of structs.

  Servers can specify a `fetched_filename` option. If so, the server subscribes to events named
  `{:fetch, fetched_filename}`, and calls `new_state` with the event data.

  ## Callbacks

  Server modules can override any of these callbacks:

  * `handle_new_state/1` — Called with the value passed to any `new_state` call; can be used to
      accept state values that are not strings or struct lists. Should call `super` with a string
      or struct list to perform the actual update.

  * `pre_insert_hook/1` — Called with each struct before inserting it into the table. Must return
      a list of structs to insert (one struct can be transformed into zero or multiple).

  * `post_commit_hook/0` — Called once after a new state has been committed, but before the
      `:new_state` event has been published. Servers can use this to e.g. update additional data
      that needs to remain consistent with the main table.

  * `post_load_hook/1` — Called with the list of structs to be returned whenever data is requested
      from the server, e.g. using `all` or `by_*` functions. Must return the list of structs to be
      returned to the caller. Allows filtering or transforming results on load.
  """
  @callback handle_new_state(binary | [struct]) :: :ok
  @callback post_commit_hook() :: :ok
  @callback post_load_hook([struct]) :: [struct] when struct: any
  @callback pre_insert_hook(struct) :: [struct] when struct: any
  @optional_callbacks [post_commit_hook: 0, post_load_hook: 1, pre_insert_hook: 1]

  require Logger

  import Events
  import State.Logger

  defmacro __using__(opts) do
    indices = Keyword.fetch!(opts, :indices)
    hibernate? = Keyword.get(opts, :hibernate, true)

    recordable =
      case Keyword.fetch!(opts, :recordable) do
        {:__aliases__, _, module_parts} -> Module.concat(module_parts)
      end

    key_index = List.first(recordable.fields)

    quote do
      use Events.Server
      require Logger

      alias unquote(__MODULE__), as: Server
      alias unquote(opts[:recordable]), as: RECORDABLE

      @behaviour Server

      # Client functions

      @doc "Start the #{__MODULE__} server."
      def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

      @doc "Send a new state to the server."
      @spec new_state(any) :: :ok
      def new_state(state, timeout \\ 300_000),
        do: GenServer.call(__MODULE__, {:new_state, state}, timeout)

      @doc "Returns a timestamp of when the server was last updated with new data."
      @spec last_updated() :: DateTime.t() | nil
      def last_updated, do: GenServer.call(__MODULE__, :last_updated)

      @doc "Updates the server's metadata with when it was last updated."
      def update_metadata, do: GenServer.cast(__MODULE__, :update_metadata)

      @doc "Returns the number of elements in the server."
      @spec size() :: non_neg_integer
      def size, do: Server.size(__MODULE__)

      @doc "Returns all the #{__MODULE__} structs."
      @spec all(opts :: Keyword.t()) :: [RECORDABLE.t()]
      def all(opts \\ []), do: Server.all(__MODULE__, opts)

      @doc "Returns all the keys for #{__MODULE__}."
      @spec all_keys() :: [term]
      def all_keys, do: Server.all_keys(__MODULE__)

      @spec match(map, atom) :: [RECORDABLE.t()]
      @spec match(map, atom, opts :: Keyword.t()) :: [RECORDABLE.t()]
      def match(matcher, index, opts \\ []), do: Server.match(__MODULE__, matcher, index, opts)

      @spec select([map]) :: [RECORDABLE.t()]
      @spec select([map], atom | nil) :: [RECORDABLE.t()]
      def select(matchers, index \\ nil), do: Server.select(__MODULE__, matchers, index)

      @spec select_limit([map], pos_integer) :: [RECORDABLE.t()]
      def select_limit(matchers, num_objects),
        do: Server.select_limit(__MODULE__, matchers, num_objects)

      # define a `by_<index>` and `by_<index>s` method for each indexed field
      unquote(State.Server.def_by_indices(indices, key_index: key_index))

      # Metadata functions

      @doc """
      The _single_ filename that must be fetched to generate a new state.  If there is no file
      name OR there are multiple file names, this will be `nil`.
      """
      @spec fetched_filename :: String.t() | nil
      def fetched_filename, do: unquote(opts[:fetched_filename])

      @doc """
      indices in the `:mnesia` table where state is stored
      """
      @spec indices :: [atom]
      def indices, do: unquote(indices)

      @doc """
      The index for the primary key
      """
      @spec key_index :: atom
      def key_index, do: List.first(recordable().fields())

      @doc """
      Module that defines struct used in state list and implements `Recordable` behaviour.
      """
      @spec recordable :: module
      def recordable, do: unquote(opts[:recordable])

      @doc "Parser module that implements `Parse`."
      @spec parser :: module | nil
      def parser, do: unquote(opts[:parser])

      # Server functions

      @impl GenServer
      def init(nil), do: Server.init(__MODULE__)

      def shutdown(reason, _state), do: Server.shutdown(__MODULE__, reason)

      @impl GenServer
      def handle_call(request, from, state),
        do: Server.handle_call(__MODULE__, request, from, state)

      @impl GenServer
      def handle_cast(request, state), do: Server.handle_cast(__MODULE__, request, state)

      @impl State.Server
      def handle_new_state(new_state), do: Server.handle_new_state(__MODULE__, new_state)

      @impl State.Server
      def post_commit_hook, do: :ok

      @impl State.Server
      def post_load_hook(structs), do: structs

      @impl State.Server
      def pre_insert_hook(item), do: [item]

      @impl Events.Server
      def handle_event({:fetch, unquote(opts[:fetched_filename])}, body, _, state) do
        case handle_call({:new_state, body}, nil, state) do
          {:reply, _, new_state} ->
            maybe_hibernate({:noreply, new_state})

          {:reply, _, new_state, extra} ->
            maybe_hibernate({:noreply, new_state})
        end
      end

      unquote do
        if hibernate? do
          quote do
            def maybe_hibernate({:noreply, state}), do: {:noreply, state, :hibernate}
            def maybe_hibernate({:reply, reply, state}), do: {:reply, reply, state, :hibernate}
          end
        end
      end

      def maybe_hibernate(reply), do: reply

      # All functions that aren't metadata or have computed names, such as from def_by_indices,
      # should be marked overridable here
      defoverridable all: 0,
                     all: 1,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_new_state: 1,
                     init: 1,
                     last_updated: 0,
                     match: 2,
                     match: 3,
                     new_state: 1,
                     new_state: 2,
                     post_commit_hook: 0,
                     post_load_hook: 1,
                     pre_insert_hook: 1,
                     select: 1,
                     select: 2,
                     select_limit: 2,
                     shutdown: 2,
                     size: 0,
                     start_link: 0,
                     start_link: 1,
                     update_metadata: 0
    end
  end

  def handle_call(module, {:new_state, enum}, _from, state) do
    module.handle_new_state(enum)
    module.maybe_hibernate({:reply, :ok, state})
  end

  def handle_call(module, :last_updated, _from, state) do
    module.maybe_hibernate({:reply, Map.get(state, :last_updated), state})
  end

  def handle_cast(module, :update_metadata, state) do
    state = %{state | last_updated: DateTime.utc_now()}
    State.Metadata.state_updated(module, state.last_updated)
    module.maybe_hibernate({:noreply, state})
  end

  def handle_new_state(module, func) when is_function(func, 0) do
    do_handle_new_state(module, func)
  end

  def handle_new_state(module, new_state) do
    parser = module.parser()

    if not is_nil(parser) and is_binary(new_state) do
      parse_new_state(module, parser, new_state)
    else
      do_handle_new_state(module, fn -> new_state end)
    end
  end

  def init(module) do
    :ok = recreate_table(module)
    fetched_filename = module.fetched_filename()

    if fetched_filename do
      subscribe({:fetch, fetched_filename})
    end

    Events.publish({:new_state, module}, 0)

    {:ok, %{last_updated: nil, data: nil}, :hibernate}
  end

  @spec match(module, map, atom, opts :: Keyword.t()) :: [struct]
  def match(module, matcher, index, opts) when is_map(matcher) and is_atom(index) do
    {_, db} = :persistent_term.get(module)
    query = select_query([matcher])
    {:ok, select} = :esqlite3.prepare(db, query)

    for {value, index} <- Enum.with_index(Map.values(matcher), 1) do
      :ok = bind_value(select, index, value)
    end

    select
    |> :esqlite3.fetchall()
    |> to_structs(module, opts)
  end

  def recreate_table(module) do
    recordable = module.recordable()
    indices = module.indices()
    attributes = recordable.fields()
    priv_dir = :code.priv_dir(:state)
    {:ok, db} = :esqlite3.open('#{priv_dir}/#{module}.sqlite')
    {:ok, reader} = :esqlite3.open('#{priv_dir}/#{module}.sqlite')

    :esqlite3.exec(db, 'PRAGMA journal_mode=WAL')
    :esqlite3.exec(db, "BEGIN IMMEDIATE")
    :esqlite3.exec(db, 'DROP TABLE IF EXISTS t')

    columns =
      attributes
      |> Enum.map(fn column -> ~s["#{column}"] end)
      |> Enum.join(", ")
      |> io_inspect()

    :ok =
      case :esqlite3.exec(db, 'CREATE TABLE IF NOT EXISTS t (#{columns})') do
        :ok ->
          :ok

        _error ->
          :esqlite3.error_info(db)
      end

    for index <- indices do
      :ok = :esqlite3.exec(db, 'CREATE INDEX #{index} ON t (#{index})')
    end

    :persistent_term.put(module, {db, reader})
    :esqlite3.exec(db, "COMMIT")
    :ok
  end

  def shutdown(module, _reason) do
    {db, reader} = :persistent_term.get(module)
    :esqlite3.exec(db, "DROP TABLE IF EXISTS t")
    :esqlite3.close(db)
    :esqlite3.close(reader)
    :persistent_term.erase(module)
    :ok
  end

  def create!(func, module) do
    enum =
      debug_time(
        func,
        fn milliseconds ->
          "create_enum #{module} #{inspect(self())} took #{milliseconds}ms"
        end
      )

    if enum do
      create_children(enum, module)
    else
      :ok
    end
  end

  defp create_children(enum, module) do
    {db, _reader} = :persistent_term.get(module)
    :ok = :esqlite3.exec(db, 'BEGIN IMMEDIATE')
    :ok = :esqlite3.exec(db, 'DELETE FROM t')
    recordable = module.recordable()

    # insert_sql_fields =
    #   recordable.fields()
    #   |> Enum.map(&Atom.to_string/1)
    #   |> Enum.join(", ")

    insert_sql_params =
      recordable.fields()
      |> Enum.map(fn _ -> "?" end)
      |> Enum.join(", ")

    insert_sql = 'INSERT INTO t VALUES (#{insert_sql_params})' |> io_inspect()

    {:ok, insert} = :esqlite3.prepare(db, insert_sql)

    for pre_hook_record <- enum,
        record <- module.pre_insert_hook(pre_hook_record) do
      for {value, index} <-
            record
            |> recordable.to_record()
            |> Tuple.to_list()
            |> Enum.with_index()
            |> Enum.drop(1) do
        io_inspect({:insert_bind, index, value})
        :ok = bind_value(insert, index, value)
      end

      :ok =
        case :esqlite3.fetchall(insert) do
          [] ->
            :ok

          _other ->
            :esqlite3.error_info(db)
        end

      :esqlite3.reset(insert)
    end

    :ok = :esqlite3.exec(db, 'COMMIT')
  end

  defp bind_value(query, index, value)

  defp bind_value(query, index, value) when is_integer(value) do
    :esqlite3.bind_int64(query, index, value)
  end

  defp bind_value(query, index, nil) do
    :esqlite3.bind_null(query, index)
  end

  defp bind_value(query, index, value) do
    value = :erlang.term_to_binary(value)
    :esqlite3.bind_blob(query, index, value)
  end

  defp unbind_value(value)

  defp unbind_value(value) when is_integer(value) do
    value
  end

  defp unbind_value(:undefined) do
    nil
  end

  defp unbind_value(value) when is_binary(value) do
    :erlang.binary_to_term(value)
  end

  def size(module) do
    {_, db} = :persistent_term.get(module)
    [[count]] = :esqlite3.q(db, "SELECT COUNT(*) from t")
    count
  end

  def all(module, opts) do
    {_, db} = :persistent_term.get(module)

    db
    |> :esqlite3.q("SELECT * FROM t")
    |> to_structs(module, opts)
  end

  def all_keys(module) do
    {_, db} = :persistent_term.get(module)
    [first_key | _] = module.recordable().fields()

    db
    |> :esqlite3.q('SELECT "#{first_key}" from t')
    |> Enum.flat_map(& &1)
    |> Enum.map(&unbind_value/1)
  end

  def by_index(values, module, indicies, opts)

  def by_index([], _module, _indicies, _opts) do
    []
  end

  def by_index(values, module, {index, _key_index}, opts) do
    # IO.inspect({module, values, index, opts}, label: "by index")
    {_, db} = :persistent_term.get(module)

    {has_nil?, values} =
      if Enum.member?(values, nil) do
        {true, Enum.reject(values, &is_nil/1)}
      else
        {false, values}
      end

    query =
      case values do
        [] ->
          'SELECT * FROM t'

        [_] ->
          'SELECT * FROM t WHERE "#{index}" = ?'

        values ->
          query_values = values |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
          'SELECT * FROM t WHERE "#{index}" IN (#{query_values})'
      end

    query =
      cond do
        has_nil? and values == [] ->
          [query, ' WHERE "#{index}" IS NULL']

        has_nil? ->
          [query, ' OR "#{index}" IS NULL']

        true ->
          query
      end

    order_by =
      case values do
        [] ->
          []

        [_] ->
          []

        values ->
          [
            ' ORDER BY CASE "#{index}" ',
            values
            |> Enum.with_index()
            |> Enum.map(fn {_x, i} ->
              'WHEN ? THEN #{i} '
            end),
            'END'
          ]
      end

    query = [query, order_by] |> io_inspect()

    {:ok, select} = :esqlite3.prepare(db, query)

    for {value, index} <- Enum.with_index(values, 1) do
      io_inspect({:by_index_bind, index, value})
      :ok = bind_value(select, index, value)
    end

    if order_by != [] do
      for {value, index} <- Enum.with_index(values, 1 + length(values)) do
        io_inspect({:by_index_order_bind, index, value})
        :ok = bind_value(select, index, value)
      end
    end

    select
    |> :esqlite3.fetchall()
    |> to_structs(module, opts)
  end

  @spec select(module, [map], atom | nil) :: [struct]
  def select(module, matchers, index \\ nil)

  def select(_module, [], _index) do
    []
  end

  def select(module, matchers, index) when is_list(matchers) and is_atom(index) do
    {_, db} = :persistent_term.get(module)
    # IO.inspect({module, matchers, index}, label: "select")

    query = select_query(matchers)
    {:ok, select} = :esqlite3.prepare(db, query)

    for {{_key, value}, index} <- matchers |> Enum.flat_map(& &1) |> Enum.with_index(1) do
      io_inspect({:select_bind, index, value})
      :ok = bind_value(select, index, value)
    end

    select
    |> :esqlite3.fetchall()
    |> to_structs(module, [])
  end

  def select_limit(module, matchers, num_objects)

  def select_limit(_module, [], num_objects) when is_integer(num_objects) do
    []
  end

  def select_limit(module, matchers, num_objects) when is_integer(num_objects) do
    {_, db} = :persistent_term.get(module)
    query = select_query(matchers)
    query = [query, ' LIMIT ?']
    {:ok, select} = :esqlite3.prepare(db, query)

    for {{_key, value}, index} <- matchers |> Enum.flat_map(& &1) |> Enum.with_index(1) do
      io_inspect({:select_limit_bind, index, value})
      :ok = bind_value(select, index, value)
    end

    limit_index = Enum.reduce(matchers, 0, fn matcher, sum -> sum + map_size(matcher) end) + 1
    io_inspect({:bind_index, limit_index, num_objects})
    :ok = bind_value(select, limit_index, num_objects)

    select
    |> :esqlite3.fetchall()
    |> to_structs(module, [])
  end

  defp select_query(matchers) do
    # matches everything
    if Enum.member?(matchers, %{}) do
      ['SELECT * FROM t ']
    else
      match_queries =
        for matcher <- matchers do
          match_query =
            for {field, value} <- matcher do
              if is_nil(value) do
                '"#{field}" = ? OR "#{field}" IS NULL'
              else
                '"#{field}" = ?'
              end
            end
            |> Enum.intersperse(' AND ')

          ['(', match_query, ')']
        end
        |> Enum.intersperse(' OR ')

      ['SELECT * FROM t WHERE ', match_queries] |> io_inspect()
    end
  end

  defp to_structs(records, module, opts) do
    recordable = module.recordable()

    records
    |> Enum.map(fn x ->
      List.to_tuple([recordable | Enum.map(x, &unbind_value/1)])
    end)
    |> Enum.map(&recordable.from_record(&1))
    |> module.post_load_hook()
    |> State.all(opts)
  end

  def log_parse_error(module, e) do
    _ = Logger.error("#{module} error parsing binary state: #{inspect(e)}")
    _ = Logger.error(Exception.format(:error, e))
    nil
  end

  defp def_by_index(index, keywords) do
    key_index = Keyword.fetch!(keywords, :key_index)
    name = :"by_#{index}"
    plural_name = :"#{name}s"

    quote do
      def unquote(name)(value, opts \\ []) do
        Server.by_index([value], __MODULE__, {unquote(index), unquote(key_index)}, opts)
      end

      def unquote(plural_name)(values, opts \\ []) when is_list(values) do
        Server.by_index(values, __MODULE__, {unquote(index), unquote(key_index)}, [])
      end

      defoverridable [
        {unquote(name), 1},
        {unquote(name), 2},
        {unquote(plural_name), 1},
        {unquote(plural_name), 2}
      ]
    end
  end

  def def_by_indices(indices, keywords) do
    key_index = Keyword.fetch!(keywords, :key_index)

    for index <- indices do
      def_by_index(index, key_index: key_index)
    end
  end

  defp do_handle_new_state(module, func) do
    :ok =
      debug_time(
        fn -> create!(func, module) end,
        fn milliseconds ->
          "init_table #{module} #{inspect(self())} took #{milliseconds}ms"
        end
      )

    :ok =
      debug_time(
        &module.post_commit_hook/0,
        fn milliseconds ->
          # coveralls-ignore-start
          "post_commit #{module} #{inspect(self())} took #{milliseconds}ms"
          # coveralls-ignore-stop
        end
      )

    new_size = module.size()

    _ =
      Logger.info(fn ->
        "Update #{module} #{inspect(self())}: #{new_size} items"
      end)

    module.update_metadata()
    Events.publish({:new_state, module}, new_size)

    :ok
  end

  defp parse_new_state(module, parser, binary) when is_binary(binary) do
    do_handle_new_state(module, fn ->
      try do
        parser.parse(binary)
      rescue
        e -> log_parse_error(module, e)
      end
    end)
  end

  defp io_inspect(value) do
    # IO.inspect(value)
    value
  end
end
