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

defmodule OMG.DB do
  @moduledoc """
  DB API module provides an interface to all needed functions that need to be implemented by the
  underlying database layer.
  """
  use OMG.Utils.Metrics
  @type utxo_pos_db_t :: {pos_integer, non_neg_integer, non_neg_integer}

  @callback start_link(term) :: GenServer.on_start()
  @callback child_spec() :: Supervisor.child_spec()
  @callback child_spec(term) :: Supervisor.child_spec()
  @callback init(String.t()) :: :ok
  @callback init() :: :ok
  @callback initiation_multiupdate() :: :ok | {:error, any}

  @callback multi_update(term()) :: :ok | {:error, any}
  @callback blocks(block_to_fetch :: list()) :: {:ok, list(term)}
  @callback utxos() :: {:ok, list(term)}
  @callback exit_infos() :: {:ok, list(term)}
  @callback in_flight_exits_info() :: {:ok, list(term)}
  @callback competitors_info() :: {:ok, list(term)}
  @callback exit_info({pos_integer, non_neg_integer, non_neg_integer}) :: {:ok, map} | {:error, atom}
  @callback spent_blknum(utxo_pos_db_t()) :: {:ok, pos_integer} | {:error, atom}
  @callback block_hashes(integer()) :: list()
  @callback last_deposit_child_blknum() :: list()
  @callback child_top_block_number() :: {:ok, non_neg_integer()}

  # callbacks useful for injecting a specific server implementation
  @callback initiation_multiupdate(GenServer.server()) :: :ok | {:error, any}
  @callback multi_update(term(), GenServer.server()) :: :ok | {:error, any}
  @callback blocks(block_to_fetch :: list(), GenServer.server()) :: {:ok, list()} | {:error, any}
  @callback utxos(GenServer.server()) :: {:ok, list(term)} | {:error, any}
  @callback exit_infos(GenServer.server()) :: {:ok, list(term)} | {:error, any}
  @callback in_flight_exits_info(GenServer.server()) :: {:ok, list(term)} | {:error, any}
  @callback competitors_info(GenServer.server()) :: {:ok, list(term)} | {:error, any}
  @callback exit_info({pos_integer, non_neg_integer, non_neg_integer}, GenServer.server()) ::
              {:ok, map} | {:error, atom}
  @callback spent_blknum(utxo_pos_db_t(), GenServer.server()) :: {:ok, pos_integer} | {:error, atom}
  @callback block_hashes(integer(), GenServer.server()) :: list()
  @callback last_deposit_child_blknum(GenServer.server()) :: list()
  @callback child_top_block_number(GenServer.server()) :: {:ok, non_neg_integer()}
  @optional_callbacks child_spec: 1,
                      initiation_multiupdate: 1,
                      multi_update: 2,
                      blocks: 2,
                      utxos: 1,
                      exit_infos: 1,
                      in_flight_exits_info: 1,
                      competitors_info: 1,
                      exit_info: 2,
                      spent_blknum: 2,
                      block_hashes: 2,
                      last_deposit_child_blknum: 1,
                      child_top_block_number: 1

  def start_link(args), do: driver().start_link(args)

  def child_spec, do: driver().child_spec()
  def child_spec(args), do: driver().child_spec(args)

  def init(path), do: driver().init(path)
  def init, do: driver().init()

  @doc """
  Puts all zeroes and other init values to a generically initialized `OMG.DB`
  """
  @decorate measure_event()
  def initiation_multiupdate, do: driver().initiation_multiupdate
  def initiation_multiupdate(server), do: driver().initiation_multiupdate(server)

  @decorate measure_event()
  def multi_update(db_updates), do: driver().multi_update(db_updates)
  def multi_update(db_updates, server), do: driver().multi_update(db_updates, server)

  @decorate measure_event()
  def blocks(blocks_to_fetch), do: driver().blocks(blocks_to_fetch)
  def blocks(blocks_to_fetch, server), do: driver().blocks(blocks_to_fetch, server)

  @decorate measure_event()
  def utxos, do: driver().utxos()
  def utxos(server), do: driver().utxos(server)

  @decorate measure_event()
  def exit_infos, do: driver().exit_infos
  def exit_infos(server), do: driver().exit_infos(server)

  @decorate measure_event()
  def in_flight_exits_info, do: driver().in_flight_exits_info()
  def in_flight_exits_info(server), do: driver().in_flight_exits_info(server)

  @decorate measure_event()
  def competitors_info, do: driver().competitors_info
  def competitors_info(server), do: driver().competitors_info(server)

  @decorate measure_event()
  def exit_info(utxo_pos), do: driver().exit_info(utxo_pos)

  @decorate measure_event()
  def spent_blknum(utxo_pos), do: driver().spent_blknum(utxo_pos)
  def spent_blknum(utxo_pos, server), do: driver().spent_blknum(utxo_pos, server)

  @decorate measure_event()
  def block_hashes(block_numbers_to_fetch), do: driver().block_hashes(block_numbers_to_fetch)
  def block_hashes(block_numbers_to_fetch, server), do: driver().block_hashes(block_numbers_to_fetch, server)

  @decorate measure_event()
  def last_deposit_child_blknum, do: driver().last_deposit_child_blknum()

  @decorate measure_event()
  def child_top_block_number, do: driver().child_top_block_number

  @decorate measure_event()
  def get_single_value(parameter_name), do: driver().get_single_value(parameter_name)
  def get_single_value(parameter_name, server), do: driver().get_single_value(parameter_name, server)

  @doc """
  A list of all atoms that we use as single-values stored in the database (i.e. markers/flags of all kinds)
  """
  def single_value_parameter_names do
    [
      :child_top_block_number,
      :last_deposit_child_blknum,
      :last_block_getter_eth_height,
      :last_depositor_eth_height,
      :last_convenience_deposit_processor_eth_height,
      :last_exiter_eth_height,
      :last_piggyback_exit_eth_height,
      :last_in_flight_exit_eth_height,
      :last_exit_processor_eth_height,
      :last_convenience_exit_processor_eth_height,
      :last_exit_finalizer_eth_height,
      :last_exit_challenger_eth_height,
      :last_in_flight_exit_processor_eth_height,
      :last_piggyback_processor_eth_height,
      :last_competitor_processor_eth_height,
      :last_challenges_responds_processor_eth_height,
      :last_piggyback_challenges_processor_eth_height,
      :last_ife_exit_finalizer_eth_height
    ]
  end

  defp driver do
    case Application.get_env(:omg_db, :type) do
      :rocksdb -> OMG.DB.RocksDB
      :leveldb -> OMG.DB.LevelDB
    end
  end
end
