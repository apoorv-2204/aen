defmodule Uniris.SelfRepair.Sync.BeaconSummaryHandler do
  @moduledoc false

  alias Uniris.BeaconChain
  alias Uniris.BeaconChain.Slot, as: BeaconSlot
  alias Uniris.BeaconChain.Summary, as: BeaconSummary

  alias Uniris.Crypto

  alias Uniris.DB

  alias Uniris.Election

  alias Uniris.P2P
  alias Uniris.P2P.Message.GetBeaconSlot
  alias Uniris.P2P.Message.GetBeaconSummary

  alias __MODULE__.NetworkStatistics
  alias __MODULE__.TransactionHandler

  alias Uniris.TransactionChain

  alias Uniris.Utils

  require Logger

  @doc """
  Retrieve the list of missed beacon summaries from a given date.

  It request every subsets to find out the missing ones by querying beacon pool nodes.
  """
  @spec get_beacon_summaries(BeaconChain.pools(), binary()) :: Enumerable.t()
  def get_beacon_summaries(summary_pools, patch) when is_binary(patch) do
    Enum.map(summary_pools, fn {subset, nodes_by_summary_time} ->
      Enum.map(nodes_by_summary_time, fn {summary_time, nodes} ->
        {nodes, subset, summary_time}
      end)
    end)
    |> :lists.flatten()
    |> Task.async_stream(
      fn {nodes, subset, summary_time} ->
        do_fetch_summary(subset, summary_time, nodes, patch)
      end,
      on_timeout: :kill_task,
      max_concurrency: 256
    )
    |> Stream.filter(&match?({:ok, {:ok, %BeaconSummary{}}}, &1))
    |> Stream.map(fn {:ok, {:ok, res}} -> res end)
  end

  defp do_fetch_summary(subset, summary_time, nodes, patch) do
    if Utils.key_in_node_list?(nodes, Crypto.node_public_key(0)) do
      case DB.get_beacon_summary(subset, summary_time) do
        {:ok, summary} ->
          {:ok, summary}

        _ ->
          # If the node did not receive the beacon summary it can request another remote node
          # to find it
          download_summary(nodes, subset, summary_time, patch)
      end
    else
      download_summary(nodes, subset, summary_time, patch)
    end
  end

  defp download_summary(nodes, subset, summary_time, patch) do
    nodes
    |> Enum.reject(&(&1.first_public_key == Crypto.node_public_key(0)))
    |> P2P.reply_atomic(3, %GetBeaconSummary{subset: subset, date: summary_time}, patch: patch)
  end

  @doc """
  Retrieve the list of missed beacon summaries slots a given date.

  It request every subsets to find out the missing ones by querying beacon pool nodes.
  """
  @spec get_beacon_slots(BeaconChain.pools(), binary()) :: Enumerable.t()
  def get_beacon_slots(slot_pools, patch) do
    Enum.map(slot_pools, fn {subset, nodes_by_slot_time} ->
      Enum.map(nodes_by_slot_time, fn {slot_time, nodes} ->
        {nodes, subset, slot_time}
      end)
    end)
    |> :lists.flatten()
    |> Task.async_stream(
      fn {nodes, subset, slot_time} ->
        P2P.reply_atomic(nodes, 3, %GetBeaconSlot{subset: subset, slot_time: slot_time},
          patch: patch
        )
      end,
      on_timeout: :kill_task,
      max_concurrency: 256
    )
    |> Stream.filter(&match?({:ok, {:ok, %BeaconSlot{}}}, &1))
    |> Stream.map(fn {:ok, {:ok, res}} -> res end)
  end

  @doc """
  Process beacon slots to synchronize the transactions involving.

  Each transactions from the beacon slots will be analyzed to determine
  if the node is a storage node for this transaction. If so, it will download the
  transaction from the closest storage nodes and replicate it locally.

  The P2P view will also be updated if some node information are inside the beacon slots
  """
  @spec handle_missing_summaries(Enumerable.t() | list(BeaconSummary.t()), binary()) :: :ok
  def handle_missing_summaries(summaries, node_patch) when is_binary(node_patch) do
    load_summaries_in_db(summaries)

    %{transactions: transactions, ends_of_sync: ends_of_sync, stats: stats} =
      reduce_summaries(summaries)

    synchronize_transactions(transactions, node_patch)

    Enum.each(ends_of_sync, &P2P.set_node_globally_available(&1.public_key))

    update_statistics(stats)
  end

  defp load_summaries_in_db(summaries) do
    Task.async_stream(
      summaries,
      fn summary = %BeaconSummary{subset: subset, summary_time: summary_time} ->
        node_list = [P2P.get_node_info() | P2P.authorized_nodes()] |> P2P.distinct_nodes()

        beacon_nodes =
          Election.beacon_storage_nodes(
            subset,
            summary_time,
            node_list,
            Election.get_storage_constraints()
          )

        if Utils.key_in_node_list?(beacon_nodes, Crypto.node_public_key(0)) do
          DB.register_beacon_summary(summary)
        end
      end
    )
    |> Stream.run()
  end

  defp reduce_summaries(summaries) do
    Enum.reduce(
      summaries,
      %{transactions: [], ends_of_sync: [], stats: %{}},
      &do_reduce_summary/2
    )
    |> Map.update!(:transactions, &List.flatten/1)
    |> Map.update!(:ends_of_sync, &List.flatten/1)
  end

  defp do_reduce_summary(
         %BeaconSummary{
           transaction_summaries: transaction_summaries,
           end_of_node_synchronizations: ends_of_sync,
           summary_time: summary_time
         },
         acc
       ) do
    acc
    |> Map.update!(:transactions, &[transaction_summaries | &1])
    |> Map.update!(:ends_of_sync, &[ends_of_sync | &1])
    |> update_in([:stats, Access.key(summary_time, 0)], &(&1 + length(transaction_summaries)))
  end

  defp synchronize_transactions(transaction_summaries, node_patch) do
    transactions_to_sync =
      transaction_summaries
      |> Enum.uniq_by(& &1.address)
      |> Enum.sort_by(& &1.timestamp)
      |> Enum.reject(&TransactionChain.transaction_exists?(&1.address))
      |> Enum.filter(&TransactionHandler.download_transaction?/1)

    Logger.info("Need to synchronize #{Enum.count(transactions_to_sync)} transactions")

    Enum.each(transactions_to_sync, &TransactionHandler.download_transaction(&1, node_patch))
  end

  defp update_statistics(stats) do
    Enum.each(stats, fn {date, nb_transactions} ->
      previous_summary_time =
        date
        |> Utils.truncate_datetime()
        |> BeaconChain.previous_summary_time()

      nb_seconds = abs(DateTime.diff(previous_summary_time, date))
      tps = nb_transactions / nb_seconds

      NetworkStatistics.register_tps(date, tps, nb_transactions)
      NetworkStatistics.increment_number_transactions(nb_transactions)
    end)
  end
end
