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

defmodule OMG.ChildChain.Integration.SocketTest do
  @moduledoc """
  Tests the experimental/unstable support for push events from the child chain server,
  see `OMG.RPC.Web.Socket` for details
  """

  use ExUnitFixtures
  use ExUnit.Case, async: false
  use Plug.Test
  use Phoenix.ChannelTest

  alias OMG.RPC.Web.Channel
  alias OMG.RPC.Web.TestHelper
  alias OMG.State.Transaction
  alias OMG.Utils.HttpRPC.Encoding

  @moduletag :integration

  @eth OMG.Eth.RootChain.eth_pseudo_address()

  @endpoint OMG.RPC.Web.Endpoint

  @tag fixtures: [:alice, :bob, :omg_child_chain, :alice_deposits]
  test "notifications get pushed to channels on a successful tx",
       %{alice: alice, bob: bob, alice_deposits: {deposit_blknum, _}} do
    raw_tx = Transaction.new([{deposit_blknum, 0, 0}], [{bob.addr, @eth, 7}], <<0::256>>)

    tx = raw_tx |> OMG.TestHelper.sign_encode([alice.priv, <<>>])

    {:ok, _, _socket} =
      subscribe_and_join(socket(OMG.RPC.Web.Socket), Channel.Transfer, "transfer:" <> Encoding.to_hex(bob.addr))

    %{"success" => true} = TestHelper.rpc_call(:post, "/transaction.submit", %{transaction: Encoding.to_hex(tx)})

    assert_push("address_received", %{})
  end
end
