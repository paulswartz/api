defmodule State.Sqlite do
  @moduledoc false

  def start_link(opts) do
    Exqlite.start_link(default_opts(opts))
  end

  def child_spec(opts) do
    {:ok, _} = Application.ensure_all_started(:db_connection)
    Exqlite.child_spec(default_opts(opts))
  end

  defdelegate run(name, fun), to: DBConnection
  defdelegate transaction(name, fun, opts \\ []), to: DBConnection

  def stream(conn, statement, params, opts \\ []) do
    q = %Exqlite.Query{statement: statement}
    DBConnection.stream(conn, q, params, opts)
  end

  defdelegate query(conn, statement, params), to: Exqlite
  defdelegate prepare(conn, name, statement), to: Exqlite
  defdelegate execute(conn, query, params), to: Exqlite
  defdelegate close(conn, query), to: Exqlite

  defp default_opts(opts) do
    priv_dir = :code.priv_dir(:state)

    {database, opts} = Keyword.pop(opts, :database, "state.db")

    Keyword.merge(
      [
        database: Path.join(priv_dir, database),
        journal_mode: :wal,
        cache_size: -64_000,
        temp_store: :memory,
        auto_vacuum: :incremental,
        foreign_keys: :off,
        chunk_size: 100
      ],
      opts
    )
  end
end
