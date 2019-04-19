# Copyright 2018 OmiseGO Pte Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule OMG.ChildChain.Notifications.CoreTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias OMG.ChildChain.Notifications.Core
  alias OMG.State
  alias OMG.TestHelper
  alias OMG.Watcher.Eventer

  @eth OMG.Eth.RootChain.eth_pseudo_address()

  setup do
    alice = TestHelper.generate_entity()
    bob = TestHelper.generate_entity()
    {:ok, child_block_interval} = OMG.Eth.RootChain.get_child_block_interval()
    {:ok, state_empty} = State.Core.extract_initial_state([], 0, 0, child_block_interval)

    state =
      state_empty
      |> TestHelper.do_deposit(alice, %{amount: 10, currency: @eth, blknum: 1})

    tx = TestHelper.create_recovered([{1, 0, 0, alice}], @eth, [{bob, 10}])
    {:ok, %{alice: alice, bob: bob, tx: tx, state: state}}
  end

  test "no triggers for failed txs", %{tx: tx, state: state} do
    {:ok, _, state} = State.Core.exec(state, tx, :ignore)
    {fail_exec_response, _state} = State.Core.exec(state, tx, :ignore)
    assert {:ok, []} = Core.triggers_for(:submit, %{tx: tx, exec_response: fail_exec_response})
  end

  test "single trigger for successful tx submission", %{tx: tx, state: state} do
    # FIXME: refactor exec returns to make sense here
    {ok_exec_response1, ok_exec_response2, _state} = State.Core.exec(state, tx, :ignore)
    ok_exec_response = Tuple.append({ok_exec_response1}, ok_exec_response2)

    assert {:ok, [%{tx: tx, child_blknum: 1000, child_txindex: 0}]} =
             Core.triggers_for(:submit, %{tx: tx, exec_response: ok_exec_response})
  end

  test "submit produces triggers digestible by the `Eventer",
       %{alice: alice, bob: bob, tx: tx, state: state} do
    # FIXME: probably misplaced or unnecessarily elaborate test
    #        it should mainly focus on whether the result from `Notifications` is digestible to the next step
    %{addr: alice_addr} = alice
    %{addr: bob_addr} = bob
    alice_addr_hex = OMG.Utils.HttpRPC.Encoding.to_hex(alice_addr)
    bob_addr_hex = OMG.Utils.HttpRPC.Encoding.to_hex(bob_addr)
    alice_topic = "transfer:#{alice_addr_hex}"
    bob_topic = "transfer:#{bob_addr_hex}"

    {ok_exec_response1, ok_exec_response2, _} = State.Core.exec(state, tx, :ignore)
    ok_exec_response = Tuple.append({ok_exec_response1}, ok_exec_response2)
    {:ok, triggers} = Core.triggers_for(:submit, %{tx: tx, exec_response: ok_exec_response})

    assert [
             {^bob_topic, "address_received",
              %OMG.Watcher.Event.AddressReceived{
                child_blknum: 1000,
                child_block_hash: nil,
                child_txindex: 0,
                submited_at_ethheight: nil,
                tx: %{
                  signed_tx: %{raw_tx: %{outputs: [%{amount: 10, currency: @eth, owner: ^bob_addr} | _]}},
                  spenders: [^alice_addr]
                }
                # FIXME: assert that the events contain flag status: tracked as opposed to status: included to be added
              }},
             {^alice_topic, "address_spent",
              %OMG.Watcher.Event.AddressSpent{
                child_blknum: 1000,
                child_block_hash: nil,
                child_txindex: 0,
                submited_at_ethheight: nil,
                tx: %{
                  signed_tx: %{raw_tx: %{outputs: [%{amount: 10, currency: @eth, owner: ^bob_addr} | _]}},
                  spenders: [^alice_addr]
                }
              }}
           ] = Eventer.Core.pair_events_with_topics(triggers)
  end

  test "unknown action/data produces explicit error" do
    assert {:error, :unknown_action} = Core.triggers_for(:unknown, %{})
    assert {:error, :unknown_action} = Core.triggers_for(:submit, %{})
  end
end
