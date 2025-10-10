defmodule RpcExTest do
  use ExUnit.Case

  test "library module loads" do
    assert Code.ensure_loaded?(RpcEx)
  end
end
