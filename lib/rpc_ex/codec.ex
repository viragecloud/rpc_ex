defmodule RpcEx.Codec do
  @moduledoc """
  Utilities for encoding and decoding protocol payloads.

  Messages are serialized using `:erlang.term_to_binary/2` with compression
  enabled by default and decoded via `:erlang.binary_to_term/2` in safe mode.
  """

  @default_encode_opts [:compressed, {:minor_version, 1}]
  @default_decode_opts [:safe]

  @type encode_option ::
          :compressed
          | {:compressed, 0..9}
          | {:minor_version, 0 | 1}

  @type decode_option :: :safe

  @doc """
  Serializes a term into a binary using ETF.
  """
  @spec encode(term(), [encode_option()]) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(term, opts \\ []) do
    {:ok, encode!(term, opts)}
  rescue
    exception -> {:error, exception}
  end

  @doc """
  Serializes a term into a binary using ETF, raising on failure.
  """
  @spec encode!(term(), [encode_option()]) :: binary()
  def encode!(term, opts \\ []) do
    term
    |> :erlang.term_to_binary(merge_encode_opts(opts))
  end

  @doc """
  Decodes a binary produced by `encode/2`.
  """
  @spec decode(binary(), [decode_option()]) :: {:ok, term()} | {:error, Exception.t()}
  def decode(binary, opts \\ []) when is_binary(binary) do
    {:ok, decode!(binary, opts)}
  rescue
    exception -> {:error, exception}
  end

  @doc """
  Decodes a binary produced by `encode!/2`, raising on failure.
  """
  @spec decode!(binary(), [decode_option()]) :: term()
  def decode!(binary, opts \\ []) when is_binary(binary) do
    :erlang.binary_to_term(binary, merge_decode_opts(opts))
  end

  defp merge_encode_opts(opts) do
    (@default_encode_opts ++ opts)
    |> Enum.reverse()
    |> Enum.uniq_by(fn
      {:compressed, _} -> :compressed
      {:minor_version, _} -> :minor_version
      other -> other
    end)
    |> Enum.reverse()
  end

  defp merge_decode_opts(opts) do
    (@default_decode_opts ++ opts)
    |> Enum.reverse()
    |> Enum.uniq()
  end
end
