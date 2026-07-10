support_dir = Path.expand("support", __DIR__)

["test_repo.ex", "data_case.ex"]
|> Enum.each(&Code.require_file(&1, support_dir))

db_name =
  Application.get_env(:phoenix_kit_warehouse, PhoenixKitWarehouse.Test.Repo)[:database] ||
    "phoenix_kit_warehouse_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` client not on PATH — don't crash the whole suite. Fall back to a
    # direct connection probe below, which degrades to excluding :integration
    # when no database is reachable.
    _ -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `createdb #{db_name}` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitWarehouse.Test.Repo.start_link()
      PhoenixKit.Migration.ensure_current(PhoenixKitWarehouse.Test.Repo, log: false)
      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitWarehouse.Test.Repo, :manual)
      true
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] ->
        IO.puts("""
        \n  Could not connect to test database — integration tests will be excluded.
           Run `createdb #{db_name}` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests will be excluded.
           Run `createdb #{db_name}` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_warehouse, :test_repo_available, repo_available)

exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
