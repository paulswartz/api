defmodule State.SqlServer.Supervisor do
  @moduledoc """
  Supervisor wrapping the SqlServer GenServer, and the two DBConnection pools (Writer and Reader)
  """
  alias State.Sqlite, as: Sql

  def start_link(module) do
    database = State.SqlServer.table_name(module) <> ".db"

    children = [
      Supervisor.child_spec(
        {Sql, name: Module.concat(module, Writer), database: database, pool_size: 1},
        id: Module.concat(module, Writer)
      ),
      Supervisor.child_spec(
        {Sql,
         name: Module.concat(module, Reader), database: database, mode: :readonly, pool_size: 5},
        id: Module.concat(module, Reader)
      ),
      %{
        id: module,
        start: {GenServer, :start_link, [module, nil, [name: module]]},
        type: :worker
      }
    ]

    Supervisor.start_link(children,
      strategy: :rest_for_one,
      name: Module.concat(module, Supervisor)
    )
  end

  def child_spec(module) do
    %{
      id: Module.concat(module, Supervisor),
      start: {__MODULE__, :start_link, [module]},
      type: :supervisor
    }
  end

  def stop(module) do
    Supervisor.stop(Module.concat(module, Supervisor))
  end
end
