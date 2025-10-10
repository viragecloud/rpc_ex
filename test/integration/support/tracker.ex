defmodule RpcEx.Test.Integration.Tracker do
  @moduledoc false

  use Agent

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> [] end, name: name)
  end

  def record(event, name \\ __MODULE__) do
    Agent.update(name, &[event | &1])
  end

  def drain(name \\ __MODULE__) do
    Agent.get_and_update(name, fn events -> {Enum.reverse(events), []} end)
  end
end
