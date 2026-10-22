defmodule PhoenixKitWarehouse.Test.InventoryAIStub do
  @moduledoc """
  The AI provider of the photo inventory tests. `PhoenixKitAI` posts through
  Req, and its `:req_options` app env is the seam a test routes to a
  `Req.Test` plug. The env is global: a test that installs the stub is
  `async: false`, and `install/0` puts the old value back on exit.

  The stub runs in the process that posts - the run's task, which has the
  test in its `$callers` - so no `Req.Test.allow/3` is needed. Every request
  body is sent to the test as `{:ai_request, body}`.
  """

  @doc "Routes PhoenixKitAI's HTTP to this stub until the test ends."
  def install do
    previous = Application.fetch_env(:phoenix_kit_ai, :req_options)
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__})

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit_ai, :req_options, value)
        :error -> Application.delete_env(:phoenix_kit_ai, :req_options)
      end
    end)
  end

  @doc "The model answers `json`, encoded the way a model writes it."
  def answer(json), do: respond(200, completion(Jason.encode!(json)))

  @doc "The model answers `text` as its message."
  def answer_text(text), do: respond(200, completion(text))

  @doc "The provider answers with an HTTP error."
  def fail(status) do
    respond(status, %{"error" => %{"message" => "provider error", "code" => status}})
  end

  @doc """
  Holds the request until the test sends `:go` to the process it reports in
  `{:ai_waiting, pid}`, then answers `json`.
  """
  def answer_when_released(json) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:ai_request, request_body(conn)})
      send(owner, {:ai_waiting, self()})

      receive do
        :go -> :ok
      after
        10_000 -> :ok
      end

      conn
      |> Plug.Conn.put_status(200)
      |> Req.Test.json(completion(Jason.encode!(json)))
    end)
  end

  defp completion(text) do
    %{
      "id" => "gen-test",
      "model" => "test/vision-model",
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => text}, "finish_reason" => "stop"}
      ],
      "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}
    }
  end

  defp respond(status, body) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:ai_request, request_body(conn)})

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp request_body(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn, length: 100_000_000)
    Jason.decode!(raw)
  end
end
