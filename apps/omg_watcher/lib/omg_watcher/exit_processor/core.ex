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

defmodule OMG.Watcher.ExitProcessor.Core do
  @moduledoc """
  Encapsulates managing and executing the behaviors related to treating exits by the child chain and watchers
  Keeps a state of exits that are in progress, updates it with news from the root chain, compares to the
  state of the ledger (`OMG.State`), issues notifications as it finds suitable.

  Should manage all kinds of exits allowed in the protocol and handle the interactions between them.

  This is the functional, zero-side-effect part of the exit processor. Logic should go here:
    - orchestrating the persistence of the state
    - finding invalid exits, disseminating them as events according to rules
    - enabling to challenge invalid exits
    - figuring out critical failure of invalid exit challenging (aka `:unchallenged_exit` event)
    - MoreVP protocol managing in general

  For the imperative shell, see `OMG.Watcher.ExitProcessor`
  """

  alias OMG.Block
  alias OMG.Crypto
  alias OMG.State.Transaction
  alias OMG.TypedDataHash
  alias OMG.Utxo
  alias OMG.Watcher.Event
  alias OMG.Watcher.ExitProcessor
  alias OMG.Watcher.ExitProcessor.CompetitorInfo
  alias OMG.Watcher.ExitProcessor.ExitInfo
  alias OMG.Watcher.ExitProcessor.InFlightExitInfo
  alias OMG.Watcher.ExitProcessor.TxAppendix

  require Utxo
  require Transaction

  use OMG.Utils.LoggerExt

  @default_sla_margin 10
  @zero_address OMG.Eth.zero_address()

  # TODO: divide into inputs and outputs: prevent contract's implementation from leaking into watcher
  # https://github.com/omisego/elixir-omg/pull/361#discussion_r247926222
  # <- TODO: contract implementation detail leaking here
  @type output_offset() :: 0..7

  defstruct [:sla_margin, exits: %{}, in_flight_exits: %{}, competitors: %{}]

  @type t :: %__MODULE__{
          sla_margin: non_neg_integer(),
          exits: %{Utxo.Position.t() => ExitInfo.t()},
          in_flight_exits: %{Transaction.tx_hash() => InFlightExitInfo.t()},
          competitors: %{Transaction.tx_hash() => CompetitorInfo.t()}
        }

  @type check_validity_result_t :: {:ok | {:error, :unchallenged_exit}, list(Event.byzantine_t())}

  @type competitor_data_t :: %{
          in_flight_txbytes: binary(),
          in_flight_input_index: non_neg_integer(),
          competing_txbytes: binary(),
          competing_input_index: non_neg_integer(),
          competing_sig: binary(),
          competing_tx_pos: Utxo.Position.t(),
          competing_proof: binary()
        }

  @type prove_canonical_data_t :: %{
          in_flight_txbytes: binary(),
          in_flight_tx_pos: Utxo.Position.t(),
          in_flight_proof: binary()
        }

  @type input_challenge_data :: %{
          in_flight_txbytes: Transaction.tx_bytes(),
          in_flight_input_index: 0..3,
          spending_txbytes: Transaction.tx_bytes(),
          spending_input_index: 0..3,
          spending_sig: <<_::520>>
        }

  @type output_challenge_data :: %{
          in_flight_txbytes: Transaction.tx_bytes(),
          in_flight_output_pos: pos_integer(),
          in_flight_input_index: 4..7,
          spending_txbytes: Transaction.tx_bytes(),
          spending_input_index: 0..3,
          spending_sig: <<_::520>>
        }
  @type piggyback_challenge_data_error() ::
          :unknown_ife
          | Transaction.decode_error()
          | :no_double_spend_on_particular_piggyback
          | :no_double_spend_on_particular_piggyback

  @type spent_blknum_result_t() :: pos_integer | :not_found

  defmodule KnownTx do
    @moduledoc """
    Wrapps information about a particular signed transaction known from somewhere, optionally with its UTXO position

    Private
    """
    defstruct [:signed_tx, :utxo_pos]

    @type t() :: %__MODULE__{
            signed_tx: Transaction.Signed.t(),
            utxo_pos: Utxo.Position.t()
          }
  end

  @doc """
  Reads database-specific list of exits and turns them into current state
  """
  @spec init(
          db_exits :: [{{pos_integer, non_neg_integer, non_neg_integer}, map}],
          db_in_flight_exits :: [{Transaction.tx_hash(), InFlightExitInfo.t()}],
          db_competitors :: [{Transaction.tx_hash(), CompetitorInfo.t()}],
          sla_margin :: non_neg_integer
        ) :: {:ok, t()}
  def init(db_exits, db_in_flight_exits, db_competitors, sla_margin \\ @default_sla_margin) do
    {:ok,
     %__MODULE__{
       exits: db_exits |> Enum.map(&ExitInfo.from_db_kv/1) |> Map.new(),
       in_flight_exits: db_in_flight_exits |> Enum.map(&InFlightExitInfo.from_db_kv/1) |> Map.new(),
       competitors: db_competitors |> Enum.map(&CompetitorInfo.from_db_kv/1) |> Map.new(),
       sla_margin: sla_margin
     }}
  end

  @doc """
  Add new exits from Ethereum events into tracked state.

  The list of `exit_contract_statuses` is used to track current (as in wall-clock "now", not syncing "now") status.
  This is to prevent spurious invalid exit events being fired during syncing for exits that were challenged/finalized
  Still we do want to track these exits when syncing, to have them spend from `OMG.State` on their finalization
  """
  @spec new_exits(t(), list(map()), list(map)) :: {t(), list()} | {:error, :unexpected_events}
  def new_exits(state, new_exits, exit_contract_statuses)

  def new_exits(_, new_exits, exit_contract_statuses) when length(new_exits) != length(exit_contract_statuses) do
    {:error, :unexpected_events}
  end

  def new_exits(%__MODULE__{exits: exits} = state, new_exits, exit_contract_statuses) do
    new_exits_kv_pairs =
      new_exits
      |> Enum.zip(exit_contract_statuses)
      |> Enum.map(fn {event, contract_status} ->
        %{eth_height: eth_height, call_data: %{utxo_pos: utxo_pos, output_tx: txbytes}} = event
        Utxo.position(_, _, oindex) = utxo_pos_decoded = Utxo.Position.decode!(utxo_pos)
        {:ok, raw_tx} = Transaction.decode(txbytes)
        %{amount: amount, currency: currency, owner: owner} = raw_tx |> Transaction.get_outputs() |> Enum.at(oindex)

        {utxo_pos_decoded,
         %ExitInfo{
           amount: amount,
           currency: currency,
           owner: owner,
           is_active: parse_contract_exit_status(contract_status),
           eth_height: eth_height
         }}
      end)

    db_updates =
      new_exits_kv_pairs
      |> Enum.map(&ExitInfo.make_db_update/1)

    new_exits_map = Map.new(new_exits_kv_pairs)

    {%{state | exits: Map.merge(exits, new_exits_map)}, db_updates}
  end

  defp parse_contract_exit_status({@zero_address, _contract_token, _contract_amount, _contract_position}), do: false
  defp parse_contract_exit_status({_contract_owner, _contract_token, _contract_amount, _contract_position}), do: true

  # TODO: syncing problem (look new exits)
  @doc """
   Add new in flight exits from Ethereum events into tracked state.
  """
  @spec new_in_flight_exits(t(), list(map()), list(map())) :: {t(), list()} | {:error, :unexpected_events}
  def new_in_flight_exits(state, new_ifes_events, contract_statuses)

  def new_in_flight_exits(_state, new_ifes_events, contract_statuses)
      when length(new_ifes_events) != length(contract_statuses),
      do: {:error, :unexpected_events}

  def new_in_flight_exits(%__MODULE__{in_flight_exits: ifes} = state, new_ifes_events, contract_statuses) do
    new_ifes_kv_pairs =
      new_ifes_events
      |> Enum.zip(contract_statuses)
      |> Enum.map(fn {%{eth_height: eth_height, call_data: %{in_flight_tx: tx_bytes, in_flight_tx_sigs: signatures}},
                      {timestamp, contract_ife_id} = contract_status} ->
        is_active = parse_contract_in_flight_exit_status(contract_status)
        InFlightExitInfo.new(tx_bytes, signatures, <<contract_ife_id::192>>, timestamp, is_active, eth_height)
      end)

    db_updates =
      new_ifes_kv_pairs
      |> Enum.map(&InFlightExitInfo.make_db_update/1)

    new_ifes = new_ifes_kv_pairs |> Map.new()

    {%{state | in_flight_exits: Map.merge(ifes, new_ifes)}, db_updates}
  end

  defp parse_contract_in_flight_exit_status({timestamp, _contract_id}), do: timestamp != 0

  @doc """
    Add piggybacks from Ethereum events into tracked state.
  """
  @spec new_piggybacks(t(), [%{tx_hash: Transaction.tx_hash(), output_index: output_offset()}]) :: {t(), list()}
  def new_piggybacks(%__MODULE__{} = state, piggybacks) when is_list(piggybacks) do
    {updated_state, updated_pairs} = Enum.reduce(piggybacks, {state, %{}}, &process_piggyback/2)
    {updated_state, Enum.map(updated_pairs, &InFlightExitInfo.make_db_update/1)}
  end

  defp process_piggyback(
         %{tx_hash: tx_hash, output_index: output_index},
         {%__MODULE__{in_flight_exits: ifes} = state, db_updates}
       ) do
    {:ok, ife} = Map.fetch(ifes, tx_hash)
    {:ok, updated_ife} = InFlightExitInfo.piggyback(ife, output_index)

    updated_state = %{state | in_flight_exits: Map.put(ifes, tx_hash, updated_ife)}
    {updated_state, Map.put(db_updates, tx_hash, updated_ife)}
  end

  @doc """
  Finalize exits based on Ethereum events, removing from tracked state if valid.

  Invalid finalizing exits should continue being tracked as `is_active`, to continue emitting events.
  This includes non-`is_active` exits that finalize invalid, which are turned to be `is_active` now.
  """
  @spec finalize_exits(t(), validities :: {list(Utxo.Position.t()), list(Utxo.Position.t())}) :: {t(), list(), list()}
  def finalize_exits(%__MODULE__{exits: exits} = state, {valid_finalizations, invalid}) do
    # handling valid finalizations
    exit_event_triggers =
      valid_finalizations
      |> Enum.map(fn utxo_pos ->
        %ExitInfo{owner: owner, currency: currency, amount: amount} = exits[utxo_pos]

        %{exit_finalized: %{owner: owner, currency: currency, amount: amount, utxo_pos: utxo_pos}}
      end)

    state_without_valid_ones = %{state | exits: Map.drop(exits, valid_finalizations)}
    db_updates = delete_positions(valid_finalizations)

    # invalid ones - activating, in case they were inactive, to keep being invalid forever
    {new_state, activating_db_updates} = activate_on_invalid_finalization(state_without_valid_ones, invalid)

    {new_state, exit_event_triggers, db_updates ++ activating_db_updates}
  end

  defp activate_on_invalid_finalization(%__MODULE__{exits: exits} = state, invalid_finalizations) do
    exits_to_activate =
      exits
      |> Map.take(invalid_finalizations)
      |> Enum.map(fn {k, v} -> {k, Map.update!(v, :is_active, fn _ -> true end)} end)
      |> Map.new()

    activating_db_updates =
      exits_to_activate
      |> Enum.map(&ExitInfo.make_db_update/1)

    state = %{state | exits: Map.merge(exits, exits_to_activate)}
    {state, activating_db_updates}
  end

  @spec challenge_exits(t(), list(map)) :: {t(), list}
  def challenge_exits(%__MODULE__{exits: exits} = state, challenges) do
    challenged_positions = get_positions_from_events(challenges)
    state = %{state | exits: Map.drop(exits, challenged_positions)}
    db_updates = delete_positions(challenged_positions)
    {state, db_updates}
  end

  defp get_positions_from_events(exits) do
    exits
    |> Enum.map(fn %{utxo_pos: utxo_pos} = _finalization_info -> Utxo.Position.decode!(utxo_pos) end)
  end

  defp delete_positions(utxo_positions),
    do: utxo_positions |> Enum.map(&{:delete, :exit_info, Utxo.Position.to_db_key(&1)})

  # TODO: simplify flow
  # https://github.com/omisego/elixir-omg/pull/361#discussion_r247481397
  @spec new_ife_challenges(t(), [map()]) :: {t(), list()}
  def new_ife_challenges(%__MODULE__{in_flight_exits: ifes, competitors: competitors} = state, challenges_events) do
    challenges =
      challenges_events
      |> Enum.map(fn %{
                       call_data: %{
                         competing_tx: competing_tx_bytes,
                         competing_tx_input_index: competing_input_index,
                         competing_tx_sig: signature
                       }
                     } ->
        CompetitorInfo.new(competing_tx_bytes, competing_input_index, signature)
      end)

    new_competitors = challenges |> Map.new()
    competitors_db_updates = challenges |> Enum.map(&CompetitorInfo.make_db_update/1)

    updated_ifes =
      challenges_events
      |> Enum.map(fn %{tx_hash: tx_hash, competitor_position: position} ->
        updated_ife = ifes |> Map.fetch!(tx_hash) |> InFlightExitInfo.challenge(position)
        {tx_hash, updated_ife}
      end)

    ife_db_updates = updated_ifes |> Enum.map(&InFlightExitInfo.make_db_update/1)

    state = %{
      state
      | competitors: Map.merge(competitors, new_competitors),
        in_flight_exits: Map.merge(ifes, Map.new(updated_ifes))
    }

    {state, competitors_db_updates ++ ife_db_updates}
  end

  @spec respond_to_in_flight_exits_challenges(t(), [map()]) :: {t(), list()}
  def respond_to_in_flight_exits_challenges(%__MODULE__{in_flight_exits: _ifes} = state, _responds_events) do
    # TODO: implement and test (in InFlightExitInfo callback is already written)
    {state, []}
  end

  # TODO: simplify flow
  # https://github.com/omisego/elixir-omg/pull/361#discussion_r247483185
  @spec challenge_piggybacks(t(), [map()]) :: {t(), list()}
  def challenge_piggybacks(%__MODULE__{in_flight_exits: ifes} = state, challenges) do
    ifes_to_update =
      challenges
      |> Enum.map(fn %{tx_hash: tx_hash} -> tx_hash end)
      |> (&Map.take(ifes, &1)).()
      # initializes all ifes as not updated
      |> Enum.map(fn {key, value} -> {key, {value, false}} end)
      |> Map.new()

    updated_ifes =
      challenges
      |> Enum.reduce(ifes_to_update, fn %{tx_hash: tx_hash, output_index: output_index}, acc ->
        with {:ok, {ife, _}} <- Map.fetch(acc, tx_hash),
             {:ok, updated_ife} <- InFlightExitInfo.challenge_piggyback(ife, output_index) do
          # mark as updated
          %{acc | tx_hash => {updated_ife, true}}
        else
          _ -> acc
        end
      end)
      |> Enum.reduce([], fn
        {tx_hash, {ife, true}}, acc -> [{tx_hash, ife} | acc]
        _, acc -> acc
      end)
      |> Map.new()

    db_updates = updated_ifes |> Enum.map(&InFlightExitInfo.make_db_update/1)

    {%{state | in_flight_exits: Map.merge(ifes, updated_ifes)}, db_updates}
  end

  @doc """
  Returns a tuple of {:ok, map in-flight exit id => {finalized input exits, finalized output exits}}.
  finalized input exits and finalized output exits structures both fit into `OMG.State.exit_utxos/1`.

  When there are invalid finalizations, returns one of the following:
    - {:unknown_piggybacks, list of piggybacks that exit processor state is not aware of}
    - {:unknown_in_flight_exit, set of in-flight exit ids that exit processor is not aware of}
  """
  @spec prepare_utxo_exits_for_in_flight_exit_finalizations(t(), [map()]) ::
          {:ok, map()}
          | {:unknown_piggybacks, list()}
          | {:unknown_in_flight_exit, MapSet.t(non_neg_integer())}
  def prepare_utxo_exits_for_in_flight_exit_finalizations(%__MODULE__{in_flight_exits: ifes}, finalizations) do
    # convert ife_id from int (given by contract) to a binary
    finalizations =
      finalizations
      |> Enum.map(fn %{in_flight_exit_id: id} = map -> Map.replace!(map, :in_flight_exit_id, <<id::192>>) end)

    with {:ok, ifes_by_id} <- get_all_finalized_ifes_by_ife_contract_id(finalizations, ifes),
         {:ok, []} <- known_piggybacks?(finalizations, ifes_by_id) do
      {exits_by_ife_id, _} =
        finalizations
        |> Enum.reduce({%{}, ifes_by_id}, &prepare_utxo_exits_for_finalization/2)

      {:ok, exits_by_ife_id}
    end
  end

  defp get_all_finalized_ifes_by_ife_contract_id(finalizations, ifes) do
    finalizations_ids =
      finalizations
      |> Enum.map(fn %{in_flight_exit_id: id} -> id end)
      |> MapSet.new()

    by_contract_id =
      ifes
      |> Enum.map(fn {tx_hash, %InFlightExitInfo{contract_id: id} = ife} -> {id, {tx_hash, ife}} end)
      |> Map.new()

    known_ifes =
      by_contract_id
      |> Map.keys()
      |> MapSet.new()

    unknown_ifes = MapSet.difference(finalizations_ids, known_ifes)

    if Enum.empty?(unknown_ifes) do
      {:ok, by_contract_id}
    else
      {:unknown_in_flight_exit, unknown_ifes}
    end
  end

  defp known_piggybacks?(finalizations, ifes_by_id) do
    not_piggybacked =
      finalizations
      |> Enum.filter(fn %{in_flight_exit_id: ife_id, output_index: output} ->
        {_, ife} = Map.get(ifes_by_id, ife_id)
        not InFlightExitInfo.is_piggybacked?(ife, output)
      end)

    if Enum.empty?(not_piggybacked) do
      {:ok, []}
    else
      {:unknown_piggybacks, not_piggybacked}
    end
  end

  defp prepare_utxo_exits_for_finalization(
         %{in_flight_exit_id: ife_id, output_index: output},
         {exits, ifes_by_id} = acc
       ) do
    {tx_hash, ife} = Map.get(ifes_by_id, ife_id)

    if InFlightExitInfo.is_active?(ife, output) do
      {input_exits, output_exits} =
        if output >= 4 do
          {[], [%{tx_hash: tx_hash, output_index: output}]}
        else
          %InFlightExitInfo{tx: %Transaction.Signed{raw_tx: tx}} = ife
          input_exit = tx |> Transaction.get_inputs() |> Enum.at(output)
          {[input_exit], []}
        end

      {input_exits_acc, output_exits_acc} = Map.get(exits, ife_id, {[], []})
      exits = Map.put(exits, ife_id, {input_exits ++ input_exits_acc, output_exits ++ output_exits_acc})
      {exits, ifes_by_id}
    else
      acc
    end
  end

  @doc """
  Finalizes in-flight exits.

  Returns a tuple of {:ok, updated state, database updates}.
  When there are invalid finalizations, returns one of the following:
    - {:unknown_piggybacks, list of piggybacks that exit processor state is not aware of}
    - {:unknown_in_flight_exit, set of in-flight exit ids that exit processor is not aware of}
  """
  @spec finalize_in_flight_exits(t(), [map()], map()) ::
          {:ok, t(), list()}
          | {:unknown_piggybacks, list()}
          | {:unknown_in_flight_exit, MapSet.t(non_neg_integer())}
  def finalize_in_flight_exits(%__MODULE__{in_flight_exits: ifes} = state, finalizations, invalidities_by_ife_id) do
    # convert ife_id from int (given by contract) to a binary
    finalizations =
      finalizations
      |> Enum.map(fn %{in_flight_exit_id: id} = map -> Map.replace!(map, :in_flight_exit_id, <<id::192>>) end)

    with {:ok, ifes_by_id} <- get_all_finalized_ifes_by_ife_contract_id(finalizations, ifes),
         {:ok, []} <- known_piggybacks?(finalizations, ifes_by_id) do
      {ifes_by_id, updated_ifes} =
        finalizations
        |> Enum.reduce({ifes_by_id, MapSet.new()}, &finalize_single_exit/2)
        |> activate_on_invalid_utxo_exits(invalidities_by_ife_id)

      db_updates =
        Map.new(ifes_by_id)
        |> Map.take(updated_ifes)
        |> Enum.map(fn {_, value} -> value end)
        |> Enum.map(&InFlightExitInfo.make_db_update/1)

      ifes =
        ifes_by_id
        |> Enum.map(fn {_, value} -> value end)
        |> Map.new()

      {:ok, %{state | in_flight_exits: ifes}, db_updates}
    end
  end

  defp finalize_single_exit(
         %{in_flight_exit_id: ife_id, output_index: output},
         {ifes_by_id, updated_ifes}
       ) do
    {tx_hash, ife} = Map.get(ifes_by_id, ife_id)

    if InFlightExitInfo.is_active?(ife, output) do
      {:ok, finalized_ife} = InFlightExitInfo.finalize(ife, output)
      ifes_by_id = Map.put(ifes_by_id, ife_id, {tx_hash, finalized_ife})
      updated_ifes = MapSet.put(updated_ifes, ife_id)

      {ifes_by_id, updated_ifes}
    else
      {ifes_by_id, updated_ifes}
    end
  end

  defp activate_on_invalid_utxo_exits({ifes_by_id, updated_ifes}, invalidities_by_ife_id) do
    ifes_to_activate =
      invalidities_by_ife_id
      |> Enum.filter(fn {_ife_id, invalidities} -> not Enum.empty?(invalidities) end)
      |> Enum.map(fn {ife_id, _invalidities} -> ife_id end)
      |> MapSet.new()

    ifes_by_id = Enum.map(ifes_by_id, &activate_in_flight_exit(&1, ifes_to_activate))

    updated_ifes = MapSet.to_list(ifes_to_activate) ++ MapSet.to_list(updated_ifes)
    updated_ifes = MapSet.new(updated_ifes)

    {ifes_by_id, updated_ifes}
  end

  defp activate_in_flight_exit({ife_id, {tx_hash, ife}}, ifes_to_activate) do
    if MapSet.member?(ifes_to_activate, ife_id) do
      activated_ife = InFlightExitInfo.activate(ife)
      {ife_id, {tx_hash, activated_ife}}
    else
      {ife_id, {tx_hash, ife}}
    end
  end

  @doc """
  Only for the active output piggybacks for in-flight exits, based on the current tracked state.
  Only for IFEs which transactions where included into the chain and whose outputs were potentially spent.

  Compare with determine_utxo_existence_to_get/2.
  """
  @spec determine_ife_input_utxos_existence_to_get(ExitProcessor.Request.t(), t()) :: ExitProcessor.Request.t()
  def determine_ife_input_utxos_existence_to_get(
        %ExitProcessor.Request{blknum_now: blknum_now} = request,
        %__MODULE__{in_flight_exits: ifes}
      )
      when is_integer(blknum_now) do
    piggybacked_output_utxos =
      ifes
      |> Map.values()
      |> Enum.filter(& &1.is_active)
      |> Enum.filter(&(InFlightExitInfo.piggybacked_outputs(&1) != []))
      |> Enum.flat_map(&Transaction.get_inputs(&1.tx))
      |> Enum.filter(fn Utxo.position(blknum, _, _) -> blknum < blknum_now end)
      |> :lists.usort()

    %{request | ife_input_utxos_to_check: piggybacked_output_utxos}
  end

  @doc """
  All the active exits, in-flight exits, exiting output piggybacks etc., based on the current tracked state
  """
  @spec determine_utxo_existence_to_get(ExitProcessor.Request.t(), t()) :: ExitProcessor.Request.t()
  def determine_utxo_existence_to_get(
        %ExitProcessor.Request{blknum_now: blknum_now} = request,
        %__MODULE__{} = state
      )
      when is_integer(blknum_now) do
    %{request | utxos_to_check: do_determine_utxo_existence_to_get(state, blknum_now)}
  end

  defp do_determine_utxo_existence_to_get(%__MODULE__{exits: exits, in_flight_exits: ifes}, blknum_now) do
    standard_exits_pos =
      exits
      |> Enum.filter(fn {_key, %ExitInfo{is_active: is_active}} -> is_active end)
      |> Enum.map(fn {utxo_pos, _value} -> utxo_pos end)

    active_ifes = ifes |> Map.values() |> Enum.filter(& &1.is_active)
    ife_inputs_pos = active_ifes |> Enum.flat_map(&Transaction.get_inputs(&1.tx))
    ife_outputs_pos = active_ifes |> Enum.flat_map(&InFlightExitInfo.get_piggybacked_outputs_positions/1)

    (ife_outputs_pos ++ ife_inputs_pos ++ standard_exits_pos)
    |> Enum.filter(fn Utxo.position(blknum, _, _) -> blknum != 0 and blknum < blknum_now end)
    |> :lists.usort()
  end

  @doc """
  Figures out which numbers of "spending transaction blocks" to get for the utxos, based on the existence reported by
  `OMG.State` and possibly other factors, eg. only take the non-existent UTXOs spends (naturally) and ones that
  pertain to IFE transaction inputs.

  Assumes that UTXOs that haven't been checked (i.e. not a key in `utxo_exists?` map) **exist**

  To proceed with validation/proof building, this function must ask for blocks that satisfy following criteria:
    1/ blocks where any input to any IFE was spent
    2/ blocks where any output to any IFE was spent
    3/ blocks where the whole IFE transaction **might've** been included, to get piggyback availability and to get InvalidIFEChallenge's
  """
  @spec determine_spends_to_get(ExitProcessor.Request.t(), __MODULE__.t()) :: ExitProcessor.Request.t()
  def determine_spends_to_get(
        %ExitProcessor.Request{
          utxos_to_check: utxos_to_check,
          utxo_exists_result: utxo_exists_result
        } = request,
        %__MODULE__{in_flight_exits: ifes}
      ) do
    utxo_exists? = Enum.zip(utxos_to_check, utxo_exists_result) |> Map.new()

    spends_to_get =
      ifes
      |> Map.values()
      |> Enum.flat_map(fn %{tx: tx} = ife ->
        InFlightExitInfo.get_piggybacked_outputs_positions(ife) ++ Transaction.get_inputs(tx)
      end)
      |> only_utxos_checked_and_missing(utxo_exists?)
      |> :lists.usort()

    %{request | spends_to_get: spends_to_get}
  end

  @doc """
  Figures out which numbers of "spending transaction blocks" to get for the outputs on IFEs utxos.

  To proceed with validation/proof building, this function must ask for blocks that satisfy following criteria:
    1/ blocks, where any output from an IFE tx might have been created, by including such IFE tx

  Similar to `determine_spends_to_get`, otherwise.
  """
  @spec determine_ife_spends_to_get(ExitProcessor.Request.t(), __MODULE__.t()) :: ExitProcessor.Request.t()
  def determine_ife_spends_to_get(
        %ExitProcessor.Request{
          ife_input_utxos_to_check: utxos_to_check,
          ife_input_utxo_exists_result: utxo_exists_result
        } = request,
        %__MODULE__{in_flight_exits: ifes}
      ) do
    utxo_exists? = Enum.zip(utxos_to_check, utxo_exists_result) |> Map.new()

    spends_to_get =
      ifes
      |> Map.values()
      |> Enum.flat_map(&Transaction.get_inputs(&1.tx))
      |> only_utxos_checked_and_missing(utxo_exists?)
      |> :lists.usort()

    %{request | ife_input_spends_to_get: spends_to_get}
  end

  @doc """
  Filters out all the spends that have not been found (`:not_found` instead of a block)
  This might occur if a UTXO is exited by exit finalization. A block spending such UTXO will not exist.
  """
  @spec handle_spent_blknum_result(list(spent_blknum_result_t()), list(Utxo.Position.t())) :: list(pos_integer())
  def handle_spent_blknum_result(spent_blknum_result, spent_positions_to_get) do
    {not_founds, founds} =
      Stream.zip(spent_positions_to_get, spent_blknum_result)
      |> Enum.split_with(fn {_utxo_pos, result} -> result == :not_found end)

    {_, blknums_to_get} = Enum.unzip(founds)

    warn? = !Enum.empty?(not_founds)
    _ = if warn?, do: Logger.warn("UTXO doesn't exists but no spend registered (spent in exit?) #{inspect(not_founds)}")

    Enum.uniq(blknums_to_get)
  end

  @doc """
  Based on the result of exit validity (utxo existence), return invalid exits or appropriate notifications

  NOTE: We're using `ExitStarted`-height with `sla_exit_margin` added on top, to determine old, unchallenged invalid
        exits. This is different than documented, according to what we ought to be using
        `exitable_at - sla_exit_margin_s` to determine such exits.

  NOTE: If there were any exits unchallenged for some time in chain history, this might detect breach of SLA,
        even if the exits were eventually challenged (e.g. during syncing)
  """
  @spec check_validity(ExitProcessor.Request.t(), t()) :: check_validity_result_t()
  def check_validity(
        %ExitProcessor.Request{
          eth_height_now: eth_height_now,
          utxos_to_check: utxos_to_check,
          utxo_exists_result: utxo_exists_result
        } = request,
        %__MODULE__{exits: exits, sla_margin: sla_margin} = state
      )
      when is_integer(eth_height_now) do
    utxo_exists? = Enum.zip(utxos_to_check, utxo_exists_result) |> Map.new()

    invalid_exit_positions =
      exits
      |> Enum.filter(fn {_key, %ExitInfo{is_active: is_active}} -> is_active end)
      |> Enum.map(fn {utxo_pos, _value} -> utxo_pos end)
      |> only_utxos_checked_and_missing(utxo_exists?)

    # get exits which are still invalid and after the SLA margin
    late_invalid_exits =
      exits
      |> Map.take(invalid_exit_positions)
      |> Enum.filter(fn {_, %ExitInfo{eth_height: eth_height}} -> eth_height + sla_margin <= eth_height_now end)

    non_late_events =
      invalid_exit_positions
      |> Enum.map(fn position -> ExitInfo.make_event_data(Event.InvalidExit, position, exits[position]) end)

    ifes_with_competitors_events =
      get_ifes_with_competitors(request, state)
      |> Enum.map(fn txbytes -> %Event.NonCanonicalIFE{txbytes: txbytes} end)

    invalid_piggybacks =
      get_invalid_piggybacks(request, state)
      |> Enum.map(fn {txbytes, inputs, outputs} ->
        %Event.InvalidPiggyback{txbytes: txbytes, inputs: inputs, outputs: outputs}
      end)

    # TODO: late piggybacks are critical, to be implemented in OMG-408
    late_invalid_piggybacks = []

    has_no_late_invalid_exits = Enum.empty?(late_invalid_exits) and Enum.empty?(late_invalid_piggybacks)

    invalid_ife_challenges_events =
      get_invalid_ife_challenges(request, state)
      |> Enum.map(fn txbytes -> %Event.InvalidIFEChallenge{txbytes: txbytes} end)

    available_piggybacks_events =
      get_ifes_to_piggyback(request, state)
      |> Enum.flat_map(&prepare_available_piggyback/1)

    late_invalid_exits_events =
      late_invalid_exits
      |> Enum.map(fn {position, late_exit} -> ExitInfo.make_event_data(Event.UnchallengedExit, position, late_exit) end)

    # get exits which are invalid because of being spent in IFEs
    invalid_exit_events =
      get_invalid_exits_based_on_ifes(state)
      |> Enum.map(fn {position, exit_info} -> ExitInfo.make_event_data(Event.InvalidExit, position, exit_info) end)
      |> Enum.concat(non_late_events)
      |> Enum.uniq_by(fn %Event.InvalidExit{utxo_pos: utxo_pos} -> utxo_pos end)

    events =
      [
        late_invalid_exits_events,
        invalid_exit_events,
        invalid_piggybacks,
        late_invalid_piggybacks,
        ifes_with_competitors_events,
        invalid_ife_challenges_events,
        available_piggybacks_events
      ]
      |> Enum.concat()

    chain_validity = if has_no_late_invalid_exits, do: :ok, else: {:error, :unchallenged_exit}

    {chain_validity, events}
  end

  def get_input_challenge_data(request, state, txbytes, input_index) do
    case input_index in 0..(Transaction.max_inputs() - 1) do
      true -> get_piggyback_challenge_data(request, state, txbytes, input_index)
      false -> {:error, :piggybacked_index_out_of_range}
    end
  end

  def get_output_challenge_data(request, state, txbytes, output_index) do
    case output_index in 0..(Transaction.max_outputs() - 1) do
      true -> get_piggyback_challenge_data(request, state, txbytes, output_index + 4)
      false -> {:error, :piggybacked_index_out_of_range}
    end
  end

  defdelegate determine_standard_challenge_queries(request, state), to: ExitProcessor.StandardExitChallenge
  defdelegate determine_exit_txbytes(request, state), to: ExitProcessor.StandardExitChallenge
  defdelegate create_challenge(request, state), to: ExitProcessor.StandardExitChallenge

  defp produce_invalid_piggyback_proof(%ExitProcessor.Request{blocks_result: blocks}, state, tx, pb_index) do
    known_txs = get_known_txs(blocks) ++ get_known_txs(state)

    with {:ok, {ife, _encoded_tx, bad_inputs, bad_outputs, proofs}} <-
           get_proofs_for_particular_ife(tx, pb_index, known_txs, state),
         true <-
           is_piggyback_in_the_list_of_known_doublespends?(pb_index, bad_inputs, bad_outputs) ||
             {:error, :no_double_spend_on_particular_piggyback} do
      challenge_data = prepare_piggyback_challenge_proofs(ife, tx, pb_index, proofs)
      {:ok, hd(challenge_data)}
    end
  end

  defp get_proofs_for_particular_ife(tx, pb_index, known_txs, state) do
    encoded_tx = Transaction.raw_txbytes(tx)

    case pb_index < Transaction.max_inputs() do
      true -> get_invalid_piggybacks_on_inputs(known_txs, state)
      false -> get_invalid_piggybacks_on_outputs(known_txs, state)
    end
    |> Enum.filter(fn {_, ife_tx, _, _, _} ->
      encoded_tx == ife_tx
    end)
    |> case do
      [] -> {:error, :no_double_spend_on_particular_piggyback}
      [proof] -> {:ok, proof}
    end
  end

  defp is_piggyback_in_the_list_of_known_doublespends?(pb_index, bad_inputs, bad_outputs),
    do: pb_index in bad_inputs or (pb_index - 4) in bad_outputs

  defp prepare_piggyback_challenge_proofs(_ife, tx, input_index, proofs)
       when input_index in 0..(Transaction.max_inputs() - 1) do
    for {competing_ktx, _utxo_of_doublespend, his_doublespend_input_index} <- Map.get(proofs, input_index),
        do: %{
          in_flight_txbytes: Transaction.raw_txbytes(tx),
          in_flight_input_index: input_index,
          spending_txbytes: Transaction.raw_txbytes(competing_ktx.signed_tx),
          spending_input_index: his_doublespend_input_index,
          spending_sig: Enum.at(competing_ktx.signed_tx.sigs, his_doublespend_input_index)
        }
  end

  defp prepare_piggyback_challenge_proofs(ife, tx, output_index, proofs) when output_index in 4..7 do
    for {competing_ktx, utxo_of_doublespend, his_doublespend_input_index} <- Map.get(proofs, output_index - 4) do
      {_, inclusion_proof} = ife.tx_seen_in_blocks_at

      %{
        in_flight_txbytes: Transaction.raw_txbytes(tx),
        in_flight_output_pos: utxo_of_doublespend,
        in_flight_proof: inclusion_proof,
        spending_txbytes: Transaction.raw_txbytes(competing_ktx.signed_tx),
        spending_input_index: his_doublespend_input_index,
        spending_sig: Enum.at(competing_ktx.signed_tx.sigs, his_doublespend_input_index)
      }
    end
  end

  @spec get_invalid_piggybacks(ExitProcessor.Request.t(), __MODULE__.t()) :: [
          {binary, [Transaction.input_index_t()], [Transaction.input_index_t()]}
        ]
  defp get_invalid_piggybacks(
         %ExitProcessor.Request{blocks_result: blocks},
         state
       ) do
    known_txs = get_known_txs(state) ++ get_known_txs(blocks)
    bad_piggybacks_on_inputs = get_invalid_piggybacks_on_inputs(known_txs, state)
    bad_piggybacks_on_outputs = get_invalid_piggybacks_on_outputs(known_txs, state)
    # produce only one event per IFE, with both piggybacks on inputs and outputs
    (bad_piggybacks_on_inputs ++ bad_piggybacks_on_outputs)
    |> Enum.group_by(&elem(&1, 1), fn {_, _, ins, outs, _} ->
      {ins, outs}
    end)
    |> Enum.map(fn {txhash, zipped_bad_piggyback_indexes} ->
      {all_ins, all_outs} = Enum.unzip(zipped_bad_piggyback_indexes)
      {txhash, List.flatten(all_ins), List.flatten(all_outs)}
    end)
  end

  @spec get_invalid_piggybacks_on_inputs([KnownTx.t()], t()) :: [
          {InFlightExitInfo.t(), Transaction.tx_hash(), [input_pb, ...], [],
           %{
             input_pb => [
               {double_spending_tx :: KnownTx.t(), input_utxo :: Utxo.Position.t(),
                doublespend_index :: Transaction.input_index_t()}
             ]
           }}
        ]
        when input_pb: Transaction.input_index_t()
  defp get_invalid_piggybacks_on_inputs(known_txs, %__MODULE__{in_flight_exits: ifes}) do
    known_txs = :lists.usort(known_txs)

    # getting invalid piggybacks on inputs
    ifes
    |> Map.values()
    |> Enum.map(fn %InFlightExitInfo{tx: tx} = ife ->
      inputs =
        tx
        |> Transaction.get_inputs()
        |> Enum.with_index()
        |> Enum.filter(fn {_input, index} -> InFlightExitInfo.is_input_piggybacked?(ife, index) end)

      {ife, inputs}
    end)
    |> Enum.filter(fn {_ife, inputs} -> inputs != [] end)
    |> Enum.map(fn {ife, inputs} ->
      proof_materials = find_spends(inputs, known_txs, ife.tx.raw_tx)
      {ife, Transaction.raw_txbytes(ife.tx), Map.keys(proof_materials), [], proof_materials}
    end)
    |> Enum.filter(fn {_, _, on_inputs, _, _} -> on_inputs != [] end)
  end

  @spec get_invalid_piggybacks_on_outputs([KnownTx.t()], t()) :: [
          {InFlightExitInfo.t(), Transaction.tx_hash(), [], [output_pb, ...],
           %{
             output_pb => [
               {double_spending_tx :: KnownTx.t(), input_utxo :: Utxo.Position.t(),
                his_doublespend :: Transaction.input_index_t()}
             ]
           }}
        ]
        when output_pb: Transaction.input_index_t()
  defp get_invalid_piggybacks_on_outputs(known_txs, %__MODULE__{in_flight_exits: ifes}) do
    # To find bad piggybacks on outputs of IFE, we need to find spends on those outputs.
    # To do that, we first need to find IFE inclusion position.
    # If IFE was included, the value of :tx_seen_in_blocks_at is set.
    # Next, check its spends, which are already included into request.blocks_result

    # TODO: drop next line
    known_txs = :lists.usort(known_txs)

    ifes
    |> Map.values()
    |> Enum.map(fn ife ->
      piggybacked_output_utxos =
        ife
        |> InFlightExitInfo.get_piggybacked_outputs_positions()
        |> Enum.map(&{&1, Utxo.Position.oindex(&1)})

      {ife, piggybacked_output_utxos}
    end)
    |> Enum.filter(fn {_ife, piggybacked_output_utxos} -> piggybacked_output_utxos != [] end)
    |> Enum.map(fn {ife, piggybacked_output_utxos} ->
      proof_materials = find_spends(piggybacked_output_utxos, known_txs, ife.tx.raw_tx)
      {ife, Transaction.raw_txbytes(ife.tx), [], Map.keys(proof_materials), proof_materials}
    end)
    |> Enum.filter(fn {_, _, _, on_outputs, _} -> on_outputs != [] end)
  end

  defp find_spends(single_tx_indexed_inputs, known_txs, original_tx) do
    # Will find all spenders of provided indexed inputs.
    known_txs
    |> Enum.filter(&(original_tx != &1.signed_tx.raw_tx))
    |> Enum.map(fn ktx -> {ktx, get_double_spends(single_tx_indexed_inputs, ktx)} end)
    |> Enum.filter(fn {_ktx, doublespends} -> doublespends != [] end)
    |> Enum.flat_map(fn {ktx, dbl_spends} ->
      {my_indexes, utxo_poses, his_indexes} = :lists.unzip3(dbl_spends)
      Enum.zip([my_indexes, List.duplicate(ktx, length(my_indexes)), utxo_poses, his_indexes])
    end)
    |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
  end

  @spec get_piggyback_challenge_data(ExitProcessor.Request.t(), t(), Transaction.Signed.tx_bytes(), 0..7) ::
          {:ok, input_challenge_data() | output_challenge_data()} | {:error, piggyback_challenge_data_error()}
  defp get_piggyback_challenge_data(request, %__MODULE__{in_flight_exits: ifes} = state, txbytes, pb_index) do
    with {:ok, tx} <- Transaction.decode(txbytes),
         true <- Map.has_key?(ifes, Transaction.raw_txhash(tx)) || {:error, :unknown_ife},
         do: produce_invalid_piggyback_proof(request, state, tx, pb_index)
  end

  @spec get_invalid_exits_based_on_ifes(t()) :: list(%{Utxo.Position.t() => ExitInfo.t()})
  defp get_invalid_exits_based_on_ifes(%__MODULE__{exits: exits} = state) do
    exiting_utxo_positions =
      state
      |> TxAppendix.get_all()
      |> Enum.flat_map(&Transaction.get_inputs/1)

    exits
    |> Enum.filter(fn {utxo_pos, _exit_info} ->
      Enum.find(exiting_utxo_positions, &match?(^utxo_pos, &1))
    end)
  end

  # Gets the list of open IFEs that have the competitors _somewhere_
  @spec get_ifes_with_competitors(ExitProcessor.Request.t(), __MODULE__.t()) :: list(binary())
  defp get_ifes_with_competitors(
         %ExitProcessor.Request{blocks_result: blocks},
         %__MODULE__{in_flight_exits: ifes} = state
       ) do
    known_txs = get_known_txs(blocks) ++ get_known_txs(state)

    ifes
    |> Map.values()
    |> Stream.filter(&InFlightExitInfo.is_canonical?/1)
    |> Stream.map(fn %InFlightExitInfo{tx: tx} -> tx end)
    # TODO: expensive!
    |> Stream.filter(fn tx -> known_txs |> Enum.find(&competitor_for(tx, &1)) end)
    |> Stream.map(&Transaction.raw_txbytes/1)
    |> Enum.uniq()
  end

  # Gets the list of open IFEs that have the competitors _somewhere_
  @spec get_invalid_ife_challenges(ExitProcessor.Request.t(), __MODULE__.t()) :: list(binary())
  defp get_invalid_ife_challenges(
         %ExitProcessor.Request{blocks_result: blocks},
         %__MODULE__{in_flight_exits: ifes}
       ) do
    known_txs = get_known_txs(blocks)

    ifes
    |> Map.values()
    |> Stream.filter(&(not InFlightExitInfo.is_canonical?(&1)))
    |> Stream.map(fn %InFlightExitInfo{tx: %Transaction.Signed{raw_tx: raw_tx}} -> raw_tx end)
    # TODO: expensive!
    |> Stream.filter(fn raw_tx ->
      is_among_known_txs?(raw_tx, known_txs)
    end)
    |> Stream.map(&Transaction.raw_txbytes/1)
    |> Enum.uniq()
  end

  @spec get_ifes_to_piggyback(ExitProcessor.Request.t(), __MODULE__.t()) ::
          list(InFlightExitInfo.t())
  defp get_ifes_to_piggyback(
         %ExitProcessor.Request{blocks_result: blocks},
         %__MODULE__{in_flight_exits: ifes}
       ) do
    known_txs = get_known_txs(blocks)

    ifes
    |> Map.values()
    |> Stream.filter(fn %InFlightExitInfo{is_active: is_active} -> is_active end)
    # TODO: expensive!
    |> Stream.filter(fn %InFlightExitInfo{tx: %Transaction.Signed{raw_tx: raw_tx}} ->
      !is_among_known_txs?(raw_tx, known_txs)
    end)
    |> Enum.uniq_by(fn %InFlightExitInfo{tx: signed_tx} -> signed_tx end)
  end

  @spec prepare_available_piggyback(InFlightExitInfo.t()) :: list(Event.PiggybackAvailable.t())
  defp prepare_available_piggyback(%InFlightExitInfo{tx: signed_tx} = ife) do
    outputs = Transaction.get_outputs(signed_tx)
    {:ok, input_owners} = Transaction.Signed.get_spenders(signed_tx)

    available_inputs =
      input_owners
      |> Enum.filter(&zero_address?/1)
      |> Enum.with_index()
      |> Enum.filter(fn {_, index} -> not InFlightExitInfo.is_input_piggybacked?(ife, index) end)
      |> Enum.map(fn {owner, index} -> %{index: index, address: owner} end)

    available_outputs =
      outputs
      |> Enum.filter(fn %{owner: owner} -> zero_address?(owner) end)
      |> Enum.with_index()
      |> Enum.filter(fn {_, index} -> not InFlightExitInfo.is_output_piggybacked?(ife, index) end)
      |> Enum.map(fn {%{owner: owner}, index} -> %{index: index, address: owner} end)

    if Enum.empty?(available_inputs) and Enum.empty?(available_outputs) do
      []
    else
      [
        %Event.PiggybackAvailable{
          txbytes: Transaction.raw_txbytes(signed_tx),
          available_outputs: available_outputs,
          available_inputs: available_inputs
        }
      ]
    end
  end

  @doc """
  Returns a map of active in flight exits, where keys are IFE hashes and values are IFES
  """
  @spec get_active_in_flight_exits(__MODULE__.t()) :: list(map)
  def get_active_in_flight_exits(%__MODULE__{in_flight_exits: ifes}) do
    ifes
    |> Enum.filter(fn {_, %InFlightExitInfo{is_active: is_active}} -> is_active end)
    |> Enum.map(&prepare_in_flight_exit/1)
  end

  defp prepare_in_flight_exit({txhash, ife_info}) do
    %{tx: tx, eth_height: eth_height} = ife_info

    %{
      txhash: txhash,
      txbytes: Transaction.raw_txbytes(tx),
      eth_height: eth_height,
      piggybacked_inputs: InFlightExitInfo.piggybacked_inputs(ife_info),
      piggybacked_outputs: InFlightExitInfo.piggybacked_outputs(ife_info)
    }
  end

  @doc """
  If IFE's spend is in blocks, find its txpos and update the IFE.
  Note: this change is not persisted later!
  """
  def find_ifes_in_blocks(
        %ExitProcessor.Request{ife_input_spending_blocks_result: blocks},
        %__MODULE__{in_flight_exits: ifes} = state
      ) do
    updated_ifes =
      ifes
      |> Enum.filter(fn {_, ife} -> ife.tx_seen_in_blocks_at == nil end)
      |> Enum.map(fn {hash, ife} -> {hash, ife, find_ife_in_blocks(ife, blocks)} end)
      |> Enum.filter(fn {_hash, _ife, maybepos} -> maybepos != nil end)
      |> Enum.map(fn {hash, ife, {block, position}} ->
        proof = Block.inclusion_proof(block, Utxo.Position.txindex(position))
        {hash, %InFlightExitInfo{ife | tx_seen_in_blocks_at: {position, proof}}}
      end)
      |> Map.new()

    %{state | in_flight_exits: Map.merge(ifes, updated_ifes)}
  end

  defp find_ife_in_blocks(ife, blocks) do
    txbody = Transaction.Signed.encode(ife.tx)

    search_in_block = fn block, _ ->
      case find_tx_in_block(txbody, block) do
        nil ->
          {:cont, nil}

        txindex ->
          {:halt, {block, Utxo.position(block.number, txindex, 0)}}
      end
    end

    blocks
    |> Enum.filter(&(&1 != :not_found))
    |> Enum.reduce_while(nil, search_in_block)
  end

  defp find_tx_in_block(txbody, block) do
    block.transactions
    |> Enum.find_index(fn tx -> txbody == tx end)
  end

  @doc """
  Gets the root chain contract-required set of data to challenge a non-canonical ife
  """
  @spec get_competitor_for_ife(ExitProcessor.Request.t(), __MODULE__.t(), binary()) ::
          {:ok, competitor_data_t()} | {:error, :competitor_not_found}
  def get_competitor_for_ife(
        %ExitProcessor.Request{blocks_result: blocks},
        %__MODULE__{} = state,
        ife_txbytes
      ) do
    known_txs = get_known_txs(blocks) ++ get_known_txs(state)

    # find its competitor and use it to prepare the requested data
    with {:ok, ife_tx} <- Transaction.decode(ife_txbytes),
         {:ok, %InFlightExitInfo{tx: signed_ife_tx}} <- get_ife(ife_tx, state),
         {:ok, known_signed_tx} <- find_competitor(known_txs, signed_ife_tx),
         do: {:ok, prepare_competitor_response(known_signed_tx, signed_ife_tx, blocks)}
  end

  @doc """
  Gets the root chain contract-required set of data to challenge an ife appearing as non-canonical in the root chain
  contract but which is known to be canonical locally because included in one of the blocks
  """
  @spec prove_canonical_for_ife(ExitProcessor.Request.t(), binary()) ::
          {:ok, prove_canonical_data_t()} | {:error, :canonical_not_found}
  def prove_canonical_for_ife(
        %ExitProcessor.Request{blocks_result: blocks},
        ife_txbytes
      ) do
    known_txs = get_known_txs(blocks)

    with {:ok, raw_ife_tx} <- Transaction.decode(ife_txbytes),
         {:ok, %KnownTx{utxo_pos: known_tx_utxo_pos}} <- find_canonical(known_txs, raw_ife_tx),
         do: {:ok, prepare_canonical_response(ife_txbytes, known_tx_utxo_pos, blocks)}
  end

  defp prepare_competitor_response(
         %KnownTx{signed_tx: known_signed_tx, utxo_pos: known_tx_utxo_pos},
         signed_ife_tx,
         blocks
       ) do
    ife_inputs = Transaction.get_inputs(signed_ife_tx)

    known_spent_inputs = Transaction.get_inputs(known_signed_tx)
    {:ok, input_owners} = Transaction.Signed.get_spenders(signed_ife_tx)

    # get info about the double spent input and it's respective indices in transactions
    spent_input = competitor_for(signed_ife_tx, known_signed_tx)
    in_flight_input_index = Enum.find_index(ife_inputs, &(&1 == spent_input))
    competing_input_index = Enum.find_index(known_spent_inputs, &(&1 == spent_input))

    owner = Enum.at(input_owners, in_flight_input_index)

    %{
      in_flight_txbytes: signed_ife_tx |> Transaction.raw_txbytes(),
      in_flight_input_index: in_flight_input_index,
      competing_txbytes: known_signed_tx |> Transaction.raw_txbytes(),
      competing_input_index: competing_input_index,
      competing_sig: find_sig!(known_signed_tx, owner),
      competing_tx_pos: known_tx_utxo_pos || Utxo.position(0, 0, 0),
      competing_proof: maybe_calculate_proof(known_tx_utxo_pos, blocks)
    }
  end

  defp prepare_canonical_response(ife_txbytes, known_tx_utxo_pos, blocks) do
    %{
      in_flight_txbytes: ife_txbytes,
      in_flight_tx_pos: known_tx_utxo_pos,
      in_flight_proof: maybe_calculate_proof(known_tx_utxo_pos, blocks)
    }
  end

  defp maybe_calculate_proof(nil, _), do: <<>>

  defp maybe_calculate_proof(Utxo.position(blknum, txindex, _), blocks) do
    blocks
    |> Enum.find(fn %Block{number: number} -> blknum == number end)
    |> Block.inclusion_proof(txindex)
  end

  defp find_competitor(known_txs, signed_ife_tx) do
    known_txs
    |> Enum.find(fn known -> competitor_for(signed_ife_tx, known) end)
    |> case do
      nil -> {:error, :competitor_not_found}
      value -> {:ok, value}
    end
  end

  defp find_canonical(known_txs, raw_ife_tx) do
    known_txs
    |> Enum.find(fn %KnownTx{signed_tx: %Transaction.Signed{raw_tx: block_raw_tx}} -> block_raw_tx == raw_ife_tx end)
    |> case do
      nil -> {:error, :canonical_not_found}
      value -> {:ok, value}
    end
  end

  # Tells whether a single transaction is a competitor for another single transactions, by returning nil or the
  # UTXO position of the input double spent.
  # Returns single result, even if there are multiple double-spends!
  @spec competitor_for(Transaction.Signed.t(), Transaction.Signed.t() | KnownTx.t() | Transaction.t()) ::
          Utxo.Position.t() | nil

  # this function doesn't care, if the second argument holds additional information about the utxo position
  defp competitor_for(signed1, %KnownTx{signed_tx: signed2}),
    do: competitor_for(signed1, signed2)

  defp competitor_for(tx, known_tx) do
    inputs = Transaction.get_inputs(tx)
    known_spent_inputs = Transaction.get_inputs(known_tx)

    with true <- Transaction.raw_txhash(known_tx) != Transaction.raw_txhash(tx),
         Utxo.position(_, _, _) = double_spent_input <- inputs |> Enum.find(&Enum.member?(known_spent_inputs, &1)),
         do: double_spent_input
  end

  # Intersects utxos, looking for duplicates. Gives full list of double-spends with indexes for
  # a pair of transactions.
  @spec get_double_spends(tx_input_info, tx_input_info) :: [
          {Transaction.input_index_t(), Utxo.Position.t(), Transaction.input_index_t()}
        ]
        when tx_input_info:
               Transaction.Signed.t()
               | Transaction.t()
               | KnownTx.t()
               | [{Transaction.input(), Transaction.input_index_t()}]
  defp get_double_spends(inputs, known_spent_inputs) when is_list(inputs) and is_list(known_spent_inputs) do
    # TODO: possibly ineffective if Transaction.max_inputs >> 4
    list =
      for {left, left_index} <- inputs,
          {right, right_index} <- known_spent_inputs,
          left == right,
          do: {left_index, left, right_index}

    :lists.usort(list)
  end

  defp get_double_spends(inputs, known_spent_inputs) do
    get_double_spends(index_inputs(inputs), index_inputs(known_spent_inputs))
  end

  defp index_inputs(inputs_list) when is_list(inputs_list) do
    inputs_list
  end

  defp index_inputs(%KnownTx{signed_tx: signed}), do: index_inputs(signed)

  defp index_inputs(tx) do
    tx
    |> Transaction.get_inputs()
    |> Enum.with_index()
  end

  defp get_known_txs(%__MODULE__{} = state) do
    TxAppendix.get_all(state)
    |> Enum.map(fn signed -> %KnownTx{signed_tx: signed} end)
  end

  defp get_known_txs(%Block{transactions: txs, number: blknum}) do
    txs
    |> Enum.map(fn tx_bytes ->
      {:ok, signed} = Transaction.Signed.decode(tx_bytes)
      signed
    end)
    |> Enum.with_index()
    |> Enum.map(fn {signed, txindex} -> %KnownTx{signed_tx: signed, utxo_pos: Utxo.position(blknum, txindex, 0)} end)
  end

  defp get_known_txs([]), do: []

  # we're sorting the blocks by their blknum here, because we wan't oldest (best) competitors first always
  defp get_known_txs([%Block{} | _] = blocks),
    do: blocks |> Enum.sort_by(fn block -> block.number end) |> Enum.flat_map(&get_known_txs/1)

  # based on an enumberable of `Utxo.Position` and a mapping that tells whether one exists it will pick
  # only those that **were checked** and were missing
  # (i.e. those not checked are assumed to be present)
  defp only_utxos_checked_and_missing(utxo_positions, utxo_exists?) do
    # the default value below is true, so that the assumption is that utxo not checked is **present**
    # TODO: rather inefficient, but no as inefficient as the nested `filter` calls in searching for competitors
    #       consider optimizing using `MapSet`

    Enum.filter(utxo_positions, fn utxo_pos -> !Map.get(utxo_exists?, utxo_pos, true) end)
  end

  defp is_among_known_txs?(raw_tx, known_txs) do
    Enum.find(known_txs, fn %KnownTx{signed_tx: %Transaction.Signed{raw_tx: block_raw_tx}} ->
      raw_tx == block_raw_tx
    end)
  end

  defp zero_address?(address) do
    address != @zero_address
  end

  defp get_ife(ife_tx, %__MODULE__{in_flight_exits: ifes}) do
    case ifes[Transaction.raw_txhash(ife_tx)] do
      nil -> {:error, :ife_not_known_for_tx}
      value -> {:ok, value}
    end
  end

  # Finds the exact signature which signed the particular transaction for the given owner address
  @spec find_sig(Transaction.Signed.t(), Crypto.address_t()) :: {:ok, Crypto.sig_t()} | nil
  defp find_sig(%Transaction.Signed{sigs: sigs, raw_tx: raw_tx}, owner) do
    tx_hash = TypedDataHash.hash_struct(raw_tx)

    Enum.find(sigs, fn sig ->
      {:ok, owner} == Crypto.recover_address(tx_hash, sig)
    end)
    |> case do
      nil -> nil
      other -> {:ok, other}
    end
  end

  def find_sig!(tx, owner) do
    # at this point having a tx that wasn't actually signed is an error, hence pattern match
    # if this returns nil it means somethings very wrong - the owner taken (effectively) from the contract
    # doesn't appear to have signed the potential competitor, which means that some prior signature checking was skipped
    {:ok, sig} = find_sig(tx, owner)
    sig
  end
end
