# Receiving push notifications from the child chain

**NOTE** unstable and experimental. Don't rely on this! See `OMG.RPC.Web.Socket` for details

The following demo is a mix of commands executed in IEx (Elixir's) REPL (see README.md for instructions) and shell.

Run a developer's Child chain server and start IEx REPL with code and config loaded, as described in README.md instructions.

```elixir

### PREPARATIONS

# we're going to be using the exthereum's client to geth's JSON RPC
{:ok, _} = Application.ensure_all_started(:omg_eth)
{:ok, _} = Application.ensure_all_started(:omg_socket_client)

alias OMG.Eth
alias OMG.Crypto
alias OMG.State.Transaction
alias OMG.TestHelper
alias OMG.Integration.DepositHelper

alice = TestHelper.generate_entity()
bob = TestHelper.generate_entity()
eth = Eth.RootChain.eth_pseudo_address()

{:ok, bob_enc} = Crypto.encode_address(bob.addr)

{:ok, _} = Eth.DevHelpers.import_unlock_fund(alice)

child_chain_url = "localhost:9656"
watcher_url = "localhost:7434"

# sends a deposit transaction _to Ethereum_
# we need to uncover the height at which the deposit went through on the root chain
deposit_blknum = DepositHelper.deposit_to_child_chain(alice.addr, 10)

### START DEMO HERE

tx =
  TestHelper.create_encoded([{deposit_blknum, 0, 0, alice}], eth, [{bob, 9}]) |>
  OMG.Utils.HttpRPC.Encoding.to_hex()

# socket_opts = [url: "ws://#{child_chain_url}/unstable_experimental_socket/websocket"]
socket_opts = [url: "ws://#{watcher_url}/socket/websocket"]

{:ok, socket} = PhoenixClient.Socket.start_link(socket_opts)

# wait a bit!

{:ok, _response, channel} = PhoenixClient.Channel.join(socket, "transfer:#{bob_enc}")

%{"data" => %{"blknum" => child_tx_block_number}} =
  ~c(echo '{"transaction": "#{tx}"}' | http POST #{child_chain_url}/transaction.submit) |>
  :os.cmd() |>
  Jason.decode!()

flush

# possibly flush again - the second event on tx inclusion comes an instant later


###
# after demo is done - disconnect to stop receiving events

PhoenixClient.Socket.stop(socket)

```
