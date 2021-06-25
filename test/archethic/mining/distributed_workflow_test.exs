defmodule ArchEthic.Mining.DistributedWorkflowTest do
  use ArchEthicCase, async: false

  @moduletag capture_log: false
  import ExUnit.CaptureLog

  alias ArchEthic.Crypto

  alias ArchEthic.BeaconChain
  alias ArchEthic.BeaconChain.SlotTimer, as: BeaconSlotTimer
  alias ArchEthic.BeaconChain.SubsetRegistry

  alias ArchEthic.Election

  alias ArchEthic.TransactionChain.Transaction
  alias ArchEthic.TransactionChain.Transaction.CrossValidationStamp
  alias ArchEthic.TransactionChain.Transaction.ValidationStamp
  alias ArchEthic.TransactionChain.TransactionData

  alias ArchEthic.Mining.DistributedWorkflow, as: Workflow
  alias ArchEthic.Mining.ValidationContext

  alias ArchEthic.P2P
  alias ArchEthic.P2P.Message.AddMiningContext
  alias ArchEthic.P2P.Message.CrossValidate
  alias ArchEthic.P2P.Message.CrossValidationDone
  alias ArchEthic.P2P.Message.GetP2PView
  alias ArchEthic.P2P.Message.GetTransaction
  alias ArchEthic.P2P.Message.GetUnspentOutputs
  alias ArchEthic.P2P.Message.NotFound
  alias ArchEthic.P2P.Message.Ok
  alias ArchEthic.P2P.Message.P2PView
  alias ArchEthic.P2P.Message.ReplicateTransaction
  alias ArchEthic.P2P.Message.UnspentOutputList
  alias ArchEthic.P2P.Node

  alias ArchEthic.Replication

  import Mox

  setup do
    start_supervised!({BeaconSlotTimer, interval: "* * * * * *"})
    Enum.each(BeaconChain.list_subsets(), &Registry.register(SubsetRegistry, &1, []))

    P2P.add_and_connect_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      first_public_key: Crypto.first_node_public_key(),
      last_public_key: Crypto.last_node_public_key(),
      authorized?: true,
      authorization_date: DateTime.utc_now(),
      available?: true,
      network_patch: "AAA",
      geo_patch: "AAA",
      enrollment_date: DateTime.utc_now(),
      reward_address: :crypto.strong_rand_bytes(32)
    })

    {pub, _} = Crypto.generate_deterministic_keypair("seed")

    P2P.add_and_connect_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      first_public_key: pub,
      last_public_key: pub,
      authorized?: true,
      authorization_date: DateTime.utc_now(),
      available?: true,
      network_patch: "BBB",
      geo_patch: "BBB",
      enrollment_date: DateTime.utc_now(),
      reward_address: :crypto.strong_rand_bytes(32)
    })

    certificate = Crypto.get_key_certificate(Crypto.first_node_public_key())

    tx =
      Transaction.new(:node, %TransactionData{
        content:
          <<127, 0, 0, 1, 3000::16, 1, 0, 16, 233, 156, 172, 143, 228, 236, 12, 227, 76, 1, 80,
            12, 236, 69, 10, 209, 6, 234, 172, 97, 188, 240, 207, 70, 115, 64, 117, 44, 82, 132,
            186, byte_size(certificate)::16, certificate::binary>>
      })

    {:ok,
     %{
       tx: tx,
       sorting_seed: Election.validation_nodes_election_seed_sorting(tx, ~U[2021-05-11 08:50:21Z])
     }}
  end

  describe "start_link/1" do
    test "should start mining by fetching the transaction context and elect storage nodes", %{
      tx: tx,
      sorting_seed: sorting_seed
    } do
      validation_nodes =
        Election.validation_nodes(
          tx,
          sorting_seed,
          Replication.chain_storage_nodes_with_type(tx.address, tx.type),
          P2P.authorized_nodes()
        )

      MockClient
      |> stub(:send_message, fn
        _, %GetP2PView{node_public_keys: public_keys} ->
          {:ok,
           %P2PView{
             nodes_view: Enum.reduce(public_keys, <<>>, fn _, acc -> <<1::1, acc::bitstring>> end)
           }}

        _, %GetUnspentOutputs{} ->
          {:ok, %UnspentOutputList{}}

        _, %GetTransaction{} ->
          {:ok, %Transaction{}}

        _, %AddMiningContext{} ->
          {:ok, %Ok{}}
      end)

      {:ok, pid} =
        Workflow.start_link(
          transaction: tx,
          welcome_node: %Node{},
          validation_nodes: validation_nodes
        )

      assert {_,
              %{
                context: %ValidationContext{
                  chain_storage_nodes_view: _,
                  beacon_storage_nodes_view: _,
                  previous_transaction: _,
                  unspent_outputs: _,
                  previous_storage_nodes: _
                }
              }} = :sys.get_state(pid)
    end

    test "should shortcut the transaction context retrieval if the transaction is invalid", %{
      sorting_seed: sorting_seed
    } do
      tx = Transaction.new(:node, %TransactionData{})

      MockClient
      |> stub(:send_message, fn
        _, %CrossValidate{} ->
          {:ok, %Ok{}}
      end)

      validation_nodes =
        Election.validation_nodes(
          tx,
          sorting_seed,
          P2P.authorized_nodes(),
          Replication.chain_storage_nodes_with_type(tx.address, tx.type)
        )

      welcome_node = %Node{
        ip: {127, 0, 0, 1},
        port: 3005,
        first_public_key: "key1",
        last_public_key: "key1",
        reward_address: :crypto.strong_rand_bytes(32)
      }

      P2P.add_and_connect_node(welcome_node)

      fun = fn ->
        {:ok, pid} =
          Workflow.start_link(
            transaction: tx,
            welcome_node: welcome_node,
            validation_nodes: validation_nodes,
            node_public_key: List.first(validation_nodes).last_public_key
          )

        assert {:wait_cross_validation_stamps,
                %{
                  context: %ValidationContext{
                    validation_stamp: %ValidationStamp{errors: [:pending_transaction]}
                  }
                }} = :sys.get_state(pid)
      end

      assert capture_log(fun) =~ "Invalid node transaction content"
    end
  end

  describe "add_mining_context/6" do
    test "should aggregate context and wait enough confirmed validation nodes context building",
         %{tx: tx, sorting_seed: sorting_seed} do
      P2P.add_and_connect_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        last_public_key: "other_validator_key",
        first_public_key: "other_validator_key",
        authorized?: true,
        authorization_date: DateTime.utc_now(),
        available?: true,
        network_patch: "AAA",
        geo_patch: "AAA",
        enrollment_date: DateTime.utc_now(),
        reward_address: :crypto.strong_rand_bytes(32)
      })

      P2P.add_and_connect_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        last_public_key: "other_validator_key2",
        first_public_key: "other_validator_key2",
        authorized?: true,
        authorization_date: DateTime.utc_now(),
        available?: true,
        network_patch: "DEF",
        geo_patch: "DEF",
        enrollment_date: DateTime.utc_now(),
        reward_address: :crypto.strong_rand_bytes(32)
      })

      validation_nodes =
        Election.validation_nodes(
          tx,
          sorting_seed,
          P2P.authorized_nodes(),
          Replication.chain_storage_nodes_with_type(tx.address, tx.type)
        )

      MockClient
      |> stub(:send_message, fn
        _, %GetP2PView{node_public_keys: public_keys1} ->
          view = Enum.reduce(public_keys1, <<>>, fn _, acc -> <<1::1, acc::bitstring>> end)
          {:ok, %P2PView{nodes_view: view}}

        _, %GetUnspentOutputs{} ->
          {:ok, %UnspentOutputList{}}

        _, %GetTransaction{} ->
          {:ok, %Transaction{}}

        _, %AddMiningContext{} ->
          {:ok, %Ok{}}
      end)

      welcome_node = %Node{
        ip: {127, 0, 0, 1},
        port: 3005,
        first_public_key: "key1",
        last_public_key: "key1",
        reward_address: :crypto.strong_rand_bytes(32)
      }

      {:ok, coordinator_pid} =
        Workflow.start_link(
          transaction: tx,
          welcome_node_public_key: welcome_node,
          validation_nodes: validation_nodes,
          node_public_key: List.first(validation_nodes).last_public_key
        )

      previous_storage_nodes = [
        %Node{
          ip: {127, 0, 0, 1},
          port: 3000,
          first_public_key: "key10",
          last_public_key: "key10",
          authorized?: true,
          authorization_date: DateTime.utc_now(),
          geo_patch: "AAA",
          network_patch: "AAA"
        },
        %Node{
          ip: {127, 0, 0, 1},
          port: 3002,
          first_public_key: "key23",
          last_public_key: "key23",
          authorized?: true,
          authorization_date: DateTime.utc_now()
        }
      ]

      Workflow.add_mining_context(
        coordinator_pid,
        List.last(validation_nodes).last_public_key,
        previous_storage_nodes,
        <<1::1, 1::1, 1::1>>,
        <<0::1, 1::1, 0::1, 1::1>>,
        <<1::1, 1::1, 0::1, 1::1>>
      )

      {:coordinator,
       %{
         context: %ValidationContext{
           chain_storage_nodes_view: chain_storage_nodes_view,
           beacon_storage_nodes_view: beacon_storage_nodes_view,
           validation_nodes_view: validation_nodes_view,
           cross_validation_nodes_confirmation: confirmed_validation_nodes
         }
       }} = :sys.get_state(coordinator_pid)

      assert validation_nodes_view == <<1::1, 1::1, 1::1>>
      assert chain_storage_nodes_view == <<1::1, 1::1, 1::1, 1::1>>
      assert beacon_storage_nodes_view == <<1::1, 1::1, 1::1, 1::1>>
      assert <<0::1, 1::1>> == confirmed_validation_nodes
    end

    test "aggregate context and create validation stamp when enough context are retrieved", %{
      tx: tx,
      sorting_seed: sorting_seed
    } do
      validation_nodes =
        Election.validation_nodes(
          tx,
          sorting_seed,
          P2P.authorized_nodes(),
          Replication.chain_storage_nodes_with_type(tx.address, tx.type)
        )

      MockClient
      |> stub(:send_message, fn
        _, %GetP2PView{node_public_keys: public_keys} ->
          view = Enum.reduce(public_keys, <<>>, fn _, acc -> <<1::1, acc::bitstring>> end)
          {:ok, %P2PView{nodes_view: view}}

        _, %GetUnspentOutputs{} ->
          {:ok, %UnspentOutputList{}}

        _, %GetTransaction{} ->
          {:ok, %NotFound{}}

        _, %AddMiningContext{} ->
          {:ok, %Ok{}}

        _, %CrossValidate{} ->
          {:ok, %Ok{}}
      end)

      welcome_node = %Node{
        ip: {127, 0, 0, 1},
        port: 3005,
        first_public_key: "key1",
        last_public_key: "key1",
        reward_address: :crypto.strong_rand_bytes(32)
      }

      P2P.add_and_connect_node(welcome_node)

      {:ok, coordinator_pid} =
        Workflow.start_link(
          transaction: tx,
          welcome_node: welcome_node,
          validation_nodes: validation_nodes,
          node_public_key: List.first(validation_nodes).last_public_key
        )

      previous_storage_nodes = [
        %Node{
          ip: {127, 0, 0, 1},
          port: 3000,
          first_public_key: "key10",
          last_public_key: "key10",
          reward_address: :crypto.strong_rand_bytes(32),
          authorized?: true,
          authorization_date: DateTime.utc_now(),
          geo_patch: "AAA",
          network_patch: "AAA"
        },
        %Node{
          ip: {127, 0, 0, 1},
          port: 3002,
          first_public_key: "key23",
          last_public_key: "key23",
          reward_address: :crypto.strong_rand_bytes(32),
          authorized?: true,
          authorization_date: DateTime.utc_now(),
          geo_patch: "AAA",
          network_patch: "AAA"
        }
      ]

      Enum.each(previous_storage_nodes, &P2P.add_and_connect_node/1)

      Workflow.add_mining_context(
        coordinator_pid,
        List.last(validation_nodes).last_public_key,
        previous_storage_nodes,
        <<1::1, 1::1>>,
        <<0::1, 1::1>>,
        <<1::1, 1::1>>
      )

      {:wait_cross_validation_stamps,
       %{
         context: %ValidationContext{
           validation_nodes_view: validation_nodes_view,
           chain_storage_nodes_view: chain_storage_nodes_view,
           beacon_storage_nodes_view: beacon_storage_nodes_view,
           cross_validation_nodes_confirmation: confirmed_cross_validations,
           validation_stamp: %ValidationStamp{}
         }
       }} = :sys.get_state(coordinator_pid)

      assert validation_nodes_view == <<1::1, 1::1>>
      assert confirmed_cross_validations == <<1::1>>
      assert chain_storage_nodes_view == <<1::1, 1::1>>
      assert beacon_storage_nodes_view == <<1::1, 1::1>>
    end
  end

  describe "cross_validate/2" do
    test "should cross validate the validation stamp and the replication tree and then notify other node about it",
         %{tx: tx, sorting_seed: sorting_seed} do
      {pub, _} = Crypto.generate_deterministic_keypair("seed3")

      P2P.add_and_connect_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        last_public_key: pub,
        first_public_key: pub,
        authorized?: true,
        authorization_date: DateTime.utc_now(),
        available?: true,
        geo_patch: "AAA",
        network_patch: "AAA",
        enrollment_date: DateTime.utc_now(),
        reward_address: :crypto.strong_rand_bytes(32)
      })

      validation_nodes =
        Election.validation_nodes(
          tx,
          sorting_seed,
          P2P.authorized_nodes(),
          Replication.chain_storage_nodes_with_type(tx.address, tx.type)
        )

      me = self()

      MockClient
      |> stub(:send_message, fn
        _, %GetP2PView{node_public_keys: public_keys} ->
          view = Enum.reduce(public_keys, <<>>, fn _, acc -> <<1::1, acc::bitstring>> end)
          {:ok, %P2PView{nodes_view: view}}

        _, %GetUnspentOutputs{} ->
          {:ok, %UnspentOutputList{}}

        _, %GetTransaction{} ->
          {:ok, %NotFound{}}

        _, %AddMiningContext{} ->
          {:ok, %Ok{}}

        _, %CrossValidate{validation_stamp: stamp, replication_tree: tree} ->
          send(me, {stamp, tree})
          {:ok, %Ok{}}

        _, %CrossValidationDone{cross_validation_stamp: stamp} ->
          send(me, {:cross_validation_done, stamp})
          {:ok, %Ok{}}
      end)

      welcome_node = %Node{
        ip: {127, 0, 0, 1},
        port: 3005,
        first_public_key: "key1",
        last_public_key: "key1",
        reward_address: :crypto.strong_rand_bytes(32)
      }

      P2P.add_and_connect_node(welcome_node)

      {:ok, coordinator_pid} =
        Workflow.start_link(
          transaction: tx,
          welcome_node: welcome_node,
          validation_nodes: validation_nodes,
          node_public_key: List.first(validation_nodes).last_public_key
        )

      {:ok, cross_validator_pid} =
        Workflow.start_link(
          transaction: tx,
          welcome_node: welcome_node,
          validation_nodes: validation_nodes,
          node_public_key: List.last(validation_nodes).last_public_key
        )

      previous_storage_nodes = [
        %Node{
          ip: {127, 0, 0, 1},
          port: 3000,
          first_public_key: "key10",
          last_public_key: "key10",
          reward_address: :crypto.strong_rand_bytes(32),
          authorized?: true,
          authorization_date: DateTime.utc_now(),
          geo_patch: "AAA",
          network_patch: "AAA"
        },
        %Node{
          ip: {127, 0, 0, 1},
          port: 3002,
          first_public_key: "key23",
          last_public_key: "key23",
          reward_address: :crypto.strong_rand_bytes(32),
          authorized?: true,
          authorization_date: DateTime.utc_now(),
          geo_patch: "AAA",
          network_patch: "AAA"
        }
      ]

      Enum.each(previous_storage_nodes, &P2P.add_and_connect_node/1)

      Workflow.add_mining_context(
        coordinator_pid,
        Enum.at(validation_nodes, 1).last_public_key,
        previous_storage_nodes,
        <<1::1, 1::1, 1::1>>,
        <<0::1, 1::1, 0::1>>,
        <<1::1, 1::1, 1::1>>
      )

      Workflow.add_mining_context(
        coordinator_pid,
        List.last(validation_nodes).last_public_key,
        previous_storage_nodes,
        <<1::1, 1::1, 1::1>>,
        <<0::1, 1::1, 0::1>>,
        <<1::1, 1::1, 1::1>>
      )

      {:wait_cross_validation_stamps, _} = :sys.get_state(coordinator_pid)

      receive do
        {stamp = %ValidationStamp{},
         tree = %{chain: chain_tree, beacon: beacon_tree, IO: io_tree}} ->
          assert Enum.all?(chain_tree, &(bit_size(&1) == 3))

          assert Enum.all?(io_tree, &(bit_size(&1) == 5))

          assert Enum.all?(beacon_tree, &(bit_size(&1) == 3))

          Workflow.cross_validate(cross_validator_pid, stamp, tree)

          {:wait_cross_validation_stamps,
           %{context: %ValidationContext{cross_validation_stamps: cross_validation_stamps}}} =
            :sys.get_state(cross_validator_pid)

          assert length(cross_validation_stamps) == 1
      end

      receive do
        {:cross_validation_done, _stamp} ->
          {:wait_cross_validation_stamps,
           %{context: %ValidationContext{validation_stamp: validation_stamp}}} =
            :sys.get_state(coordinator_pid)

          [_ | cross_validation_nodes] = validation_nodes

          {pub, priv} = Crypto.generate_deterministic_keypair("seed")
          {pub3, priv3} = Crypto.generate_deterministic_keypair("seed3")

          if Enum.any?(cross_validation_nodes, &(&1.last_public_key == pub)) do
            sig =
              validation_stamp
              |> ValidationStamp.serialize()
              |> Crypto.sign(priv)

            stamp = %CrossValidationStamp{
              inconsistencies: [],
              signature: sig,
              node_public_key: pub
            }

            Workflow.add_cross_validation_stamp(coordinator_pid, stamp)
          else
            sig =
              validation_stamp
              |> ValidationStamp.serialize()
              |> Crypto.sign(priv3)

            stamp = %CrossValidationStamp{
              inconsistencies: [],
              signature: sig,
              node_public_key: pub3
            }

            Workflow.add_cross_validation_stamp(coordinator_pid, stamp)
          end

          {:wait_cross_validation_stamps,
           %{context: %ValidationContext{cross_validation_stamps: cross_validation_stamps}}} =
            :sys.get_state(coordinator_pid)

          assert length(cross_validation_stamps) == 1
      end
    end

    test "should cross validate and start replication when all cross validations are received", %{
      tx: tx,
      sorting_seed: sorting_seed
    } do
      validation_nodes =
        Election.validation_nodes(
          tx,
          sorting_seed,
          P2P.authorized_nodes(),
          Replication.chain_storage_nodes_with_type(tx.address, tx.type)
        )

      me = self()

      MockClient
      |> stub(:send_message, fn
        _, %GetP2PView{node_public_keys: public_keys} ->
          view = Enum.reduce(public_keys, <<>>, fn _, acc -> <<1::1, acc::bitstring>> end)
          {:ok, %P2PView{nodes_view: view}}

        _, %GetUnspentOutputs{} ->
          {:ok, %UnspentOutputList{}}

        _, %GetTransaction{} ->
          {:ok, %NotFound{}}

        _, %AddMiningContext{} ->
          {:ok, %Ok{}}

        _, %CrossValidate{validation_stamp: stamp, replication_tree: tree} ->
          send(me, {:cross_validate, stamp, tree})
          {:ok, %Ok{}}

        _, %CrossValidationDone{cross_validation_stamp: stamp} ->
          send(me, {:cross_validation_done, stamp})

          {:ok, %Ok{}}

        _, %ReplicateTransaction{transaction: tx} ->
          send(me, {:replicate_transaction, tx})
          {:ok, %Ok{}}
      end)

      P2P.add_and_connect_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        last_public_key: "key10",
        first_public_key: "key10",
        network_patch: "AAA",
        geo_patch: "AAA",
        available?: true,
        enrollment_date: DateTime.utc_now(),
        reward_address: :crypto.strong_rand_bytes(32),
        authorized?: true,
        authorization_date: DateTime.utc_now()
      })

      P2P.add_and_connect_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        last_public_key: "key23",
        first_public_key: "key23",
        network_patch: "AAA",
        geo_patch: "AAA",
        available?: true,
        enrollment_date: DateTime.utc_now(),
        reward_address: :crypto.strong_rand_bytes(32),
        authorized?: true,
        authorization_date: DateTime.utc_now()
      })

      welcome_node = %Node{
        ip: {127, 0, 0, 1},
        port: 3005,
        first_public_key: "key1",
        last_public_key: "key1",
        reward_address: :crypto.strong_rand_bytes(32)
      }

      P2P.add_and_connect_node(welcome_node)

      {:ok, coordinator_pid} =
        Workflow.start_link(
          transaction: tx,
          welcome_node: welcome_node,
          validation_nodes: validation_nodes,
          node_public_key: List.first(validation_nodes).last_public_key
        )

      {:ok, cross_validator_pid} =
        Workflow.start_link(
          transaction: tx,
          welcome_node: welcome_node,
          validation_nodes: validation_nodes,
          node_public_key: List.last(validation_nodes).last_public_key
        )

      previous_storage_nodes = [
        %Node{
          ip: {127, 0, 0, 1},
          port: 3000,
          first_public_key: "key10",
          last_public_key: "key10",
          reward_address: :crypto.strong_rand_bytes(32),
          authorized?: true,
          authorization_date: DateTime.utc_now()
        },
        %Node{
          ip: {127, 0, 0, 1},
          port: 3002,
          first_public_key: "key23",
          last_public_key: "key23",
          reward_address: :crypto.strong_rand_bytes(32),
          authorized?: true,
          authorization_date: DateTime.utc_now()
        }
      ]

      Enum.each(previous_storage_nodes, &P2P.add_and_connect_node/1)

      Workflow.add_mining_context(
        coordinator_pid,
        List.last(validation_nodes).last_public_key,
        previous_storage_nodes,
        <<1::1, 1::1>>,
        <<0::1, 1::1, 0::1, 1::1>>,
        <<1::1, 1::1, 1::1, 1::1>>
      )

      {:wait_cross_validation_stamps, _} = :sys.get_state(coordinator_pid)

      receive do
        {:cross_validate, stamp, tree} ->
          Workflow.cross_validate(cross_validator_pid, stamp, tree)

          Process.sleep(200)
          assert !Process.alive?(cross_validator_pid)
      end

      receive do
        {:cross_validation_done, _stamp} ->
          {_, %{context: %ValidationContext{validation_stamp: validation_stamp}}} =
            :sys.get_state(coordinator_pid)

          if List.last(validation_nodes).last_public_key == Crypto.last_node_public_key() do
            stamp = CrossValidationStamp.sign(%CrossValidationStamp{}, validation_stamp)
            Workflow.add_cross_validation_stamp(coordinator_pid, stamp)
          else
            {pub, priv} = Crypto.generate_deterministic_keypair("seed")

            sig =
              validation_stamp
              |> ValidationStamp.serialize()
              |> Crypto.sign(priv)

            stamp = %CrossValidationStamp{
              signature: sig,
              node_public_key: pub,
              inconsistencies: []
            }

            Workflow.add_cross_validation_stamp(coordinator_pid, stamp)
          end

          Process.sleep(200)
          assert !Process.alive?(coordinator_pid)

          # receive do
          #   {:replicate_transaction, %Transaction{cross_validation_stamps: stamps}} ->
          #     assert length(stamps) == 1
          # end
      end
    end
  end
end