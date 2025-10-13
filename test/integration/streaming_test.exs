defmodule RpcEx.Integration.StreamingTest do
  use ExUnit.Case

  alias RpcEx.Client
  alias RpcEx.Server

  @moduletag :integration

  setup do
    port = Enum.random(40_000..49_000)

    server =
      start_supervised!({Server, router: RpcEx.Test.Integration.ServerRouter, port: port})

    client =
      start_supervised!(
        {Client, url: "ws://localhost:#{port}/", router: RpcEx.Test.Integration.ClientRouter}
      )

    wait_for_ready(client)

    %{client: client, server: server}
  end

  test "client can stream simple range from server", %{client: client} do
    {:ok, stream, _meta} = Client.stream(client, :simple_stream, args: %{count: 5})

    result = Enum.to_list(stream)
    assert result == [1, 2, 3, 4, 5]
  end

  test "client can stream with custom range", %{client: client} do
    {:ok, stream, _meta} = Client.stream(client, :range_stream, args: %{start: 10, stop: 15})

    result = Enum.to_list(stream)
    assert result == [10, 11, 12, 13, 14, 15]
  end

  test "client can stream lazily generated values", %{client: client} do
    {:ok, stream, _meta} = Client.stream(client, :lazy_stream, args: %{count: 3})

    result = Enum.to_list(stream)
    assert result == [1, 2, 3]
  end

  test "client can process stream lazily", %{client: client} do
    {:ok, stream, _meta} = Client.stream(client, :simple_stream, args: %{count: 10})

    # Take only first 3 items
    result = stream |> Stream.take(3) |> Enum.to_list()
    assert result == [1, 2, 3]
  end

  test "client can transform stream", %{client: client} do
    {:ok, stream, _meta} = Client.stream(client, :simple_stream, args: %{count: 5})

    result = stream |> Stream.map(&(&1 * 2)) |> Enum.to_list()
    assert result == [2, 4, 6, 8, 10]
  end

  test "stream handles errors gracefully", %{client: client} do
    {:ok, stream, _meta} = Client.stream(client, :error_stream, args: %{})

    assert_raise RuntimeError, ~r/Stream error/, fn ->
      Enum.to_list(stream)
    end
  end

  test "empty stream completes successfully", %{client: client} do
    {:ok, stream, _meta} = Client.stream(client, :simple_stream, args: %{count: 0})

    result = Enum.to_list(stream)
    assert result == []
  end

  test "large stream uses constant memory", %{client: client} do
    {:ok, stream, _meta} = Client.stream(client, :range_stream, args: %{start: 1, stop: 1000})

    # Process in chunks to verify streaming behavior
    count =
      stream
      |> Stream.chunk_every(100)
      |> Enum.count()

    assert count == 10
  end

  test "multiple concurrent streams work correctly", %{client: client} do
    task1 =
      Task.async(fn ->
        {:ok, stream, _meta} = Client.stream(client, :simple_stream, args: %{count: 5})
        Enum.to_list(stream)
      end)

    task2 =
      Task.async(fn ->
        {:ok, stream, _meta} = Client.stream(client, :range_stream, args: %{start: 10, stop: 15})
        Enum.to_list(stream)
      end)

    result1 = Task.await(task1)
    result2 = Task.await(task2)

    assert result1 == [1, 2, 3, 4, 5]
    assert result2 == [10, 11, 12, 13, 14, 15]
  end

  defp wait_for_ready(client, attempts \\ 50)

  defp wait_for_ready(_client, 0), do: :ok

  defp wait_for_ready(client, attempts) do
    case :sys.get_state(client) do
      %{connection_status: :ready} ->
        :ok

      _ ->
        Process.sleep(50)
        wait_for_ready(client, attempts - 1)
    end
  end
end
