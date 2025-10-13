defmodule RpcEx.Protocol.Frame do
  @moduledoc """
  Represents an encoded protocol frame exchanged over the WebSocket transport.
  """

  alias RpcEx.Codec

  @type message_type ::
          :hello
          | :welcome
          | :close
          | :call
          | :cast
          | :reply
          | :error
          | :notify
          | :discover
          | :discover_reply
          | :heartbeat
          | :stream
          | :stream_end
          | :stream_error

  @enforce_keys [:type, :payload]
  defstruct type: nil, version: 1, payload: %{}

  @type t :: %__MODULE__{
          type: message_type(),
          version: pos_integer(),
          payload: map()
        }

  @doc """
  Builds a new frame struct, validating basic shape.
  """
  @spec new(message_type(), map(), keyword()) :: t()
  def new(type, payload, opts \\ []) when is_atom(type) and is_map(payload) do
    version = Keyword.get(opts, :version, 1)

    %__MODULE__{
      type: type,
      version: version,
      payload: payload
    }
  end

  @doc """
  Serializes a frame into ETF binary using `RpcEx.Codec`.
  """
  @spec encode(t(), keyword()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(%__MODULE__{} = frame, opts \\ []) do
    Codec.encode({frame.type, frame.version, frame.payload}, opts)
  end

  @doc """
  Serializes a frame into ETF binary, raising on failure.
  """
  @spec encode!(t(), keyword()) :: binary()
  def encode!(%__MODULE__{} = frame, opts \\ []) do
    Codec.encode!({frame.type, frame.version, frame.payload}, opts)
  end

  @doc """
  Decodes a binary into a frame struct if the schema matches `{type, version, payload}`.
  """
  @spec decode(binary(), keyword()) :: {:ok, t()} | {:error, Exception.t() | :invalid_envelope}
  def decode(binary, opts \\ []) when is_binary(binary) do
    with {:ok, {type, version, payload}} <- Codec.decode(binary, opts),
         true <- valid?(type, version, payload) do
      {:ok, %__MODULE__{type: type, version: version, payload: payload}}
    else
      {:ok, other} ->
        {:error, {:unexpected_term, other}}

      false ->
        {:error, :invalid_envelope}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Decodes a binary into a frame struct, raising on failure.
  """
  @spec decode!(binary(), keyword()) :: t()
  def decode!(binary, opts \\ []) do
    case decode(binary, opts) do
      {:ok, frame} -> frame
      {:error, reason} -> raise ArgumentError, "invalid frame: #{inspect(reason)}"
    end
  end

  defp valid?(type, version, payload)
       when is_atom(type) and is_integer(version) and version > 0 and is_map(payload),
       do: true

  defp valid?(_, _, _), do: false
end
