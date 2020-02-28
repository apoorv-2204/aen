defmodule UnirisNetwork.DefaultImpl do
  @moduledoc false

  alias UnirisNetwork.Node
  alias UnirisNetwork.P2P.Connection
  alias UnirisNetwork.NodeRegistry
  alias UnirisNetwork.NodeSupervisor
  alias UnirisNetwork.ConnectionSupervisor
  alias __MODULE__.SharedSecretStore

  @behaviour UnirisNetwork.Impl

  @impl true
  @spec storage_nonce() :: binary()
  def storage_nonce() do
    SharedSecretStore.storage_nonce()
  end

  @impl true
  @spec daily_nonce() :: binary()
  def daily_nonce() do
    SharedSecretStore.daily_nonce()
  end

  @impl true
  @spec set_daily_nonce(binary()) :: :ok
  def set_daily_nonce(nonce) do
    SharedSecretStore.set_daily_nonce(nonce)
  end

  @impl true
  @spec origin_public_keys() :: list(UnirisCrypto.key())
  def origin_public_keys() do
    SharedSecretStore.origin_public_keys()
  end

  @impl true
  @spec list_nodes() :: list(Node.t())
  def list_nodes() do
    DynamicSupervisor.which_children(NodeSupervisor)
    |> Task.async_stream(fn {:undefined, pid, _, _} -> Node.details(pid) end)
    |> Enum.into([], fn {:ok, res} -> res end)
  end

  @impl true
  @spec add_node(Node.t()) :: :ok
  def add_node(%Node{
        first_public_key: first_public_key,
        last_public_key: last_public_key,
        ip: ip,
        port: port
      }) do
    {:ok, _} =
      DynamicSupervisor.start_child(
        NodeSupervisor,
        {Node,
         first_public_key: first_public_key, last_public_key: last_public_key, ip: ip, port: port}
      )

    {:ok, _} =
      DynamicSupervisor.start_child(
        ConnectionSupervisor,
        {Connection, public_key: first_public_key, ip: ip, port: port}
      )

    :ok
  end

  @impl true
  @spec node_info(UnirisCrypto.key()) :: Node.t()
  def node_info(<<public_key::binary-33>>) do
    Node.details(public_key)
  end

  @impl true
  @spec node_info(:inet.ip_address()) :: Node.t()
  def node_info({_, _, _, _} = ip) do
    case Registry.lookup(NodeRegistry, ip) do
      [{pid, _}] ->
        Node.details(pid)
    end
  end

  @impl true
  @spec send_message(Node.t(), term()) :: {:ok, term()}
  def send_message(%Node{} = node, message) do
    Node.send_message(node, message)
  end
end