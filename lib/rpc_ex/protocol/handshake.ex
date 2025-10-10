defmodule RpcEx.Protocol.Handshake do
  @moduledoc """
  Manages handshake negotiation between peers.

  This module is responsible for constructing the initial `:hello` message,
  validating `:welcome` replies, and deriving agreed-upon session parameters.
  """

  @enforce_keys [:protocol_version, :capabilities, :compression, :meta]
  defstruct protocol_version: 1,
            supported_encodings: [:etf],
            compression: :enabled,
            capabilities: [],
            meta: %{}

  @type compression :: :enabled | :disabled

  @type capability :: :calls | :casts | :discover | :notify | atom()

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          supported_encodings: [atom()],
          compression: compression(),
          capabilities: [capability()],
          meta: map()
        }

  @doc """
  Builds a handshake struct ready to be encoded as the `:hello` payload.
  """
  @spec build(keyword()) :: t()
  def build(opts \\ []) do
    %__MODULE__{
      protocol_version: Keyword.get(opts, :protocol_version, 1),
      supported_encodings: Keyword.get(opts, :supported_encodings, [:etf]),
      compression: Keyword.get(opts, :compression, :enabled),
      capabilities: Keyword.get(opts, :capabilities, default_capabilities(opts)),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc """
  Resolves final session parameters based on local and remote handshake data.
  """
  @spec negotiate(t(), map()) ::
          {:ok, map()}
          | {:error, :unsupported_version | :unsupported_encoding | :rejected}
  def negotiate(%__MODULE__{} = local, remote) when is_map(remote) do
    remote = normalize_keys(remote)

    case remote do
      %{"error" => _reason} ->
        {:error, :rejected}

      %{"protocol_version" => remote_version} ->
        do_negotiate(local, remote, remote_version)

      _ ->
        {:error, :unsupported_version}
    end
  end

  def negotiate(%__MODULE__{}, _other), do: {:error, :unsupported_version}

  defp do_negotiate(local, remote, remote_version) do
    with true <- compatible_protocol?(local.protocol_version, remote_version),
         {:ok, compression} <-
           negotiate_compression(local.compression, Map.get(remote, "compression")),
         {:ok, encoding} <-
           negotiate_encoding(
             local.supported_encodings,
             Map.get(remote, "supported_encodings", [:etf])
           ) do
      session = %{
        protocol_version: min(local.protocol_version, remote_version),
        compression: compression,
        encoding: encoding,
        remote_capabilities: Map.get(remote, "capabilities", []),
        local_capabilities: local.capabilities,
        meta: %{local: local.meta, remote: Map.get(remote, "meta", %{})}
      }

      {:ok, session}
    else
      false -> {:error, :unsupported_version}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compatible_protocol?(local_version, remote_version) when local_version >= 1 do
    remote_version >= 1 and abs(local_version - remote_version) <= 1
  end

  defp compatible_protocol?(_, _), do: false

  defp negotiate_compression(local, nil), do: {:ok, local}
  defp negotiate_compression(:enabled, :enabled), do: {:ok, :enabled}
  defp negotiate_compression(:disabled, _), do: {:ok, :disabled}
  defp negotiate_compression(:enabled, :disabled), do: {:ok, :disabled}
  defp negotiate_compression(_, _), do: {:error, :rejected}

  defp negotiate_encoding(local, remote) do
    case Enum.find(remote, &(&1 in local)) do
      nil -> {:error, :unsupported_encoding}
      encoding -> {:ok, encoding}
    end
  end

  defp default_capabilities(opts) do
    base = [:calls, :casts, :discover]

    case Keyword.get(opts, :enable_notifications, true) do
      true -> base ++ [:notify]
      false -> base
    end
  end

  defp normalize_keys(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end
end
