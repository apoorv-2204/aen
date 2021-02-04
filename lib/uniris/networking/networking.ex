defmodule Uniris.Networking do
  @moduledoc """
  Module defines networking configuration of the node.
  """

  alias __MODULE__.IPLookup.{Ipify, Nat, Static}

  # Public

  @doc """
  Provides current host IP address.
  1. Provider is defined in config - Static -> use hostname from config
  2. Provider is defined in config - IPIFY -> use IPIFY
  3a. Provider is defined in config - NAT -> use NAT.
  3b. Provider is not defined in config -> use NAT.
  4. NAT discovery failed -> use IPIFY.
  5. IPIFY discovery failed -> return error :not_recognizable_ip.
  """
  @spec get_node_ip() ::
          {:ok, :inet.ip_address()}
          | {:error, :invalid_ip_provider | :not_recognizable_ip | :ip_discovery_error}
  def get_node_ip do
    with config <- Application.get_env(:uniris, __MODULE__),
         {:ok, ip_provider} <- Keyword.fetch(config, :ip_provider) do
      {:ok, ip_provider}
    else
      :error -> get_external_ip()
    end
  end

  @doc """
  Provides P2P port number.
  Algo:
  1. Port in config && UPnP or NAT PMP is available - try to publish port from config.
  2. Port in config && Unable to publish port from config && UPnP or NAT PMP is available - get random port from the pool.
  3. Port in config && UPnP or NAT PMP not available -> return error :port_unassigned.
  """
  @spec get_p2p_port() :: {:ok, pos_integer()} | {:error, :port_unassigned}
  def get_p2p_port do
    with config <- Application.get_env(:uniris, __MODULE__),
         {:ok, port_to_open} <- Keyword.fetch(config, :port),
         {:ok, port} <- Nat.open_port(port_to_open) do
      {:ok, port}
    else
      :error -> assign_random_port()
      {:error, :port_unassigned} -> assign_random_port()
    end
  end

  # Private

  @spec get_external_ip() ::
          {:ok, :inet.ip_address()}
          | {:error, :invalid_ip_provider | :not_recognizable_ip | :ip_discovery_error}
  defp get_external_ip do
    case Nat.get_node_ip() do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> Ipify.get_node_ip()
    end
  end

  @spec assign_random_port() :: {:ok, pos_integer()} | {:error, :port_unassigned}
  defp assign_random_port do
    with config <- Application.get_env(:uniris, __MODULE__),
         :error <- Keyword.fetch(config, :ip_provider) do
      get_random_port()
    else
      {:ok, Static} -> {:error, :port_unassigned}
    end
  end

  @spec get_random_port() :: {:ok, pos_integer()} | {:error, :port_unassigned}
  defdelegate get_random_port, to: Nat
end