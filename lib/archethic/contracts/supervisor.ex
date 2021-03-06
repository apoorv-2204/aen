defmodule ArchEthic.Contracts.Supervisor do
  @moduledoc false

  use Supervisor

  alias ArchEthic.Contracts.Loader
  alias ArchEthic.Contracts.TransactionLookup

  alias ArchEthic.Utils

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: ArchEthic.ContractsSupervisor)
  end

  def init(_args) do
    optional_children = [{TransactionLookup, []}, {Loader, [], []}]

    static_children = [
      {Registry, keys: :unique, name: ArchEthic.ContractRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: ArchEthic.ContractSupervisor}
    ]

    children = static_children ++ Utils.configurable_children(optional_children)
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
