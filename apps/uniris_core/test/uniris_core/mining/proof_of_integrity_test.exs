defmodule UnirisCore.Mining.ProofOfIntegrityTest do
  use ExUnit.Case

  alias UnirisCore.Transaction
  alias UnirisCore.Transaction.ValidationStamp
  alias UnirisCore.Transaction.ValidationStamp.NodeMovements
  alias UnirisCore.Transaction.ValidationStamp.LedgerMovements
  alias UnirisCore.Mining.ProofOfIntegrity
  alias UnirisCore.Crypto

  test "compute/1 should produce a hash of the pending transaction when only one transaction" do
    chain = [generate_pending_transaction()]

    assert ProofOfIntegrity.compute(chain) ==
             <<0, 115, 157, 85, 192, 127, 253, 230, 88, 26, 84, 149, 167, 167, 104, 245, 105, 111,
               151, 120, 45, 240, 113, 66, 30, 105, 172, 216, 161, 91, 157, 141, 219>>
  end

  test "compute/1 should produce a hash of the pending transaction with the previous proof of integrity when there is chain" do
    chain = [generate_pending_transaction(), generate_previous_transaction()]

    assert ProofOfIntegrity.compute(chain) ==
             Crypto.hash([
               <<0, 115, 157, 85, 192, 127, 253, 230, 88, 26, 84, 149, 167, 167, 104, 245, 105,
                 111, 151, 120, 45, 240, 113, 66, 30, 105, 172, 216, 161, 91, 157, 141, 219>>,
               <<6, 228, 101, 3, 9, 194, 111, 2, 16, 36, 134, 76, 42, 82, 18, 231, 226, 104, 55,
                 36, 66, 121, 135, 4, 126, 193, 156, 134, 50, 78, 167, 45>>
             ])
  end

  defp generate_pending_transaction() do
    %Transaction{
      address:
        <<0, 65, 9, 62, 32, 153, 130, 11, 166, 32, 35, 227, 206, 83, 128, 215, 234, 180, 244, 7,
          135, 104, 16, 239, 82, 32, 33, 7, 240, 127, 111, 29, 27>>,
      type: :transfer,
      timestamp: 1_585_562_790,
      data: %{},
      previous_public_key:
        <<0, 221, 228, 196, 111, 16, 222, 0, 119, 32, 150, 228, 25, 206, 79, 37, 213, 8, 130, 22,
          212, 99, 55, 72, 11, 248, 250, 11, 140, 137, 167, 118, 253>>,
      previous_signature:
        <<232, 186, 237, 220, 71, 212, 177, 17, 156, 167, 145, 125, 92, 70, 213, 120, 216, 215,
          255, 158, 104, 117, 162, 18, 142, 75, 73, 205, 71, 7, 141, 90, 178, 239, 212, 227, 167,
          161, 155, 143, 43, 50, 6, 7, 97, 130, 134, 174, 7, 235, 183, 88, 165, 197, 25, 219, 84,
          232, 135, 42, 112, 58, 181, 13>>,
      origin_signature:
        <<232, 186, 237, 220, 71, 212, 177, 17, 156, 167, 145, 125, 92, 70, 213, 120, 216, 215,
          255, 158, 104, 117, 162, 18, 142, 75, 73, 205, 71, 7, 141, 90, 178, 239, 212, 227, 167,
          161, 155, 143, 43, 50, 6, 7, 97, 130, 134, 174, 7, 235, 183, 88, 165, 197, 25, 219, 84,
          232, 135, 42, 112, 58, 181, 13>>
    }
  end

  defp generate_previous_transaction() do
    %Transaction{
      address:
        <<0, 65, 9, 62, 32, 153, 130, 11, 166, 32, 35, 227, 206, 83, 128, 215, 234, 180, 244, 7,
          135, 104, 16, 239, 82, 32, 33, 7, 240, 127, 111, 29, 27>>,
      type: :transfer,
      timestamp: 1_585_562_790,
      data: %{},
      previous_public_key:
        <<0, 221, 228, 196, 111, 16, 222, 0, 119, 32, 150, 228, 25, 206, 79, 37, 213, 8, 130, 22,
          212, 99, 55, 72, 11, 248, 250, 11, 140, 137, 167, 118, 253>>,
      previous_signature:
        <<232, 186, 237, 220, 71, 212, 177, 17, 156, 167, 145, 125, 92, 70, 213, 120, 216, 215,
          255, 158, 104, 117, 162, 18, 142, 75, 73, 205, 71, 7, 141, 90, 178, 239, 212, 227, 167,
          161, 155, 143, 43, 50, 6, 7, 97, 130, 134, 174, 7, 235, 183, 88, 165, 197, 25, 219, 84,
          232, 135, 42, 112, 58, 181, 13>>,
      origin_signature:
        <<232, 186, 237, 220, 71, 212, 177, 17, 156, 167, 145, 125, 92, 70, 213, 120, 216, 215,
          255, 158, 104, 117, 162, 18, 142, 75, 73, 205, 71, 7, 141, 90, 178, 239, 212, 227, 167,
          161, 155, 143, 43, 50, 6, 7, 97, 130, 134, 174, 7, 235, 183, 88, 165, 197, 25, 219, 84,
          232, 135, 42, 112, 58, 181, 13>>,
      validation_stamp: %ValidationStamp{
        proof_of_work: "",
        proof_of_integrity:
          <<6, 228, 101, 3, 9, 194, 111, 2, 16, 36, 134, 76, 42, 82, 18, 231, 226, 104, 55, 36,
            66, 121, 135, 4, 126, 193, 156, 134, 50, 78, 167, 45>>,
        ledger_movements: %LedgerMovements{},
        node_movements: %NodeMovements{fee: 0, rewards: []},
        signature: ""
      }
    }
  end
end