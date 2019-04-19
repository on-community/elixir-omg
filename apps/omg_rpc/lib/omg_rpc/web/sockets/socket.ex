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

defmodule OMG.RPC.Web.Socket do
  @moduledoc """
  This is a PoC broadcast mechanism for the notifications pushed from the child chain server
  """

  # TODO: this shouldn't be here really, at a minimum let's move it to a separate Phoenix App
  #       see `OMG.ChildChain.Notifications.notify/2` for details

  # FIXME: SILENCE LOGS
  use Phoenix.Socket

  ## Channels
  channel("transfer:*", OMG.RPC.Web.Channel.Transfer)

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end
