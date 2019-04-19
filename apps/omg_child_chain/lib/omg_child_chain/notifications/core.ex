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

defmodule OMG.ChildChain.Notifications.Core do
  @moduledoc """
  Decides whether and how to reacto on notifications from the activities in the child chain server
  """

  alias OMG.State.Transaction

  # FIXME: specs docs

  def triggers_for(
        :submit,
        %{tx: %Transaction.Recovered{}, exec_response: {:ok, {_hash, blknum, txindex}}} = event_trigger
      ),
      do: {:ok, [event_trigger |> Map.put_new(:child_blknum, blknum) |> Map.put_new(:child_txindex, txindex)]}

  def triggers_for(:submit, %{tx: %Transaction.Recovered{}, exec_response: _}),
    do: {:ok, []}

  def triggers_for(_, _),
    do: {:error, :unknown_action}
end
