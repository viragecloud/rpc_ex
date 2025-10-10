defmodule Benchmarks.Fixtures do
  @moduledoc """
  Shared test data for benchmarks.
  """

  @doc """
  Returns payloads of various sizes for codec benchmarking.
  """
  def payloads do
    %{
      tiny: tiny_payload(),
      small: small_payload(),
      medium: medium_payload(),
      large: large_payload(),
      xlarge: xlarge_payload()
    }
  end

  @doc """
  Tiny payload (~50 bytes): Simple map with a few keys
  """
  def tiny_payload do
    %{
      id: 123,
      status: :ok,
      timestamp: 1234567890
    }
  end

  @doc """
  Small payload (~500 bytes): Typical RPC response
  """
  def small_payload do
    %{
      user: %{
        id: 123,
        name: "Alice Johnson",
        email: "alice@example.com",
        role: :admin,
        active: true
      },
      meta: %{
        request_id: "req_abc123",
        timestamp: 1234567890,
        version: "1.0.0"
      },
      permissions: [:read, :write, :delete]
    }
  end

  @doc """
  Medium payload (~5KB): List of records
  """
  def medium_payload do
    %{
      users: for i <- 1..50 do
        %{
          id: i,
          name: "User #{i}",
          email: "user#{i}@example.com",
          created_at: 1234567890 + i * 1000,
          metadata: %{
            login_count: i * 10,
            last_seen: 1234567890 + i * 1000,
            preferences: %{
              theme: :dark,
              notifications: true,
              language: "en"
            }
          }
        }
      end,
      pagination: %{
        page: 1,
        per_page: 50,
        total: 1000,
        total_pages: 20
      }
    }
  end

  @doc """
  Large payload (~50KB): Complex nested structure
  """
  def large_payload do
    %{
      data: for i <- 1..100 do
        %{
          id: i,
          type: :record,
          attributes: %{
            name: "Record #{i}",
            description: String.duplicate("Description text for record #{i}. ", 10),
            tags: Enum.map(1..10, &"tag_#{&1}"),
            metadata: %{
              created_at: 1234567890 + i,
              updated_at: 1234567890 + i + 1000,
              author: %{
                id: rem(i, 10) + 1,
                name: "Author #{rem(i, 10) + 1}"
              }
            }
          },
          relationships: for j <- 1..5 do
            %{type: :related, id: j, name: "Related #{j}"}
          end
        }
      end,
      included: for i <- 1..50 do
        %{
          id: i,
          type: :meta,
          data: String.duplicate("x", 100)
        }
      end,
      meta: %{
        total: 100,
        version: "2.0.0"
      }
    }
  end

  @doc """
  Extra large payload (~500KB): Very large dataset
  """
  def xlarge_payload do
    %{
      dataset: for i <- 1..1000 do
        %{
          id: i,
          data: :crypto.strong_rand_bytes(400),
          metadata: %{
            index: i,
            checksum: :crypto.hash(:sha256, <<i::32>>) |> Base.encode16(),
            tags: Enum.map(1..10, &"tag_#{&1}")
          }
        }
      end,
      summary: %{
        count: 1000,
        total_bytes: 400_000
      }
    }
  end

  @doc """
  Returns a simple router module for benchmarking.
  """
  def simple_router do
    defmodule Benchmarks.SimpleRouter do
      use RpcEx.Router

      call :noop do
        _ = args
        _ = context
        _ = opts
        {:ok, :ok}
      end

      call :echo do
        _ = context
        _ = opts
        {:ok, args}
      end

      call :compute do
        _ = context
        _ = opts
        # Simple computation
        result = Enum.reduce(1..100, 0, fn i, acc -> acc + i end)
        {:ok, result}
      end

      cast :notify do
        _ = args
        _ = context
        _ = opts
        :ok
      end
    end

    Benchmarks.SimpleRouter
  end

  @doc """
  Returns a router with middleware for benchmarking middleware overhead.
  """
  def router_with_middleware do
    defmodule Benchmarks.TracingMiddleware do
      def before(:call, _route, args, context, _opts) do
        {:cont, Map.put(context, :traced, true)}
      end

      def after_handle(:call, _route, result, context, _opts) do
        {:cont, result, context}
      end
    end

    defmodule Benchmarks.RouterWithMiddleware do
      use RpcEx.Router

      middleware Benchmarks.TracingMiddleware

      call :echo do
        _ = context
        _ = opts
        {:ok, args}
      end
    end

    Benchmarks.RouterWithMiddleware
  end

  @doc """
  Returns a router with multiple routes for lookup benchmarking.
  """
  def router_with_many_routes(count \\ 100) do
    routes =
      for i <- 1..count do
        quote do
          call unquote(:"route_#{i}") do
            _ = args
            _ = context
            _ = opts
            {:ok, unquote(i)}
          end
        end
      end

    Module.create(
      :"Benchmarks.RouterWith#{count}Routes",
      quote do
        use RpcEx.Router
        unquote_splicing(routes)
      end,
      Macro.Env.location(__ENV__)
    )

    :"Benchmarks.RouterWith#{count}Routes"
  end
end
