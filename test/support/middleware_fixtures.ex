defmodule RpcEx.Test.Middlewares.Trace do
  @moduledoc false

  @behaviour RpcEx.Router.Middleware

  def before(_kind, _route, args, context, opts) do
    tag = Keyword.fetch!(opts, :tag)
    new_args = Map.put(args, :trace, tag)
    new_context = Map.put(context, :trace, tag)
    {:replace, new_args, new_context}
  end

  def after_handle(_kind, _route, response, context, _opts) do
    {:cont, response, context}
  end
end

defmodule RpcEx.Test.Middlewares.Halt do
  @moduledoc false

  @behaviour RpcEx.Router.Middleware

  def before(_kind, _route, _args, context, opts) do
    reason = Keyword.get(opts, :reason, :halted)
    new_context = Map.put(context, :halted, true)
    {:halt, {:halted, reason}, new_context}
  end

  def after_handle(_kind, _route, response, context, _opts) do
    {:cont, {:after_halt, response}, Map.put(context, :after, true)}
  end
end
