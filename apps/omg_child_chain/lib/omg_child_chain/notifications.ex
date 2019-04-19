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

defmodule OMG.ChildChain.Notifications do
  @moduledoc """
  Allows to react on activities done in the child chain server
  """

  # FIXME: ffix dependencies
  alias OMG.ChildChain.Notifications.Core
  alias OMG.RPC.Web.Endpoint
  alias OMG.Utils.HttpRPC.Response
  alias OMG.Watcher.Eventer

  def trigger(api_call, call_data) do
    with {:ok, event_triggers} = Core.triggers_for(api_call, call_data) do
      # TODO: the notification "backend" we're pushing to here is 99% incorrect, this is just PoC
      #       The PoC assumes that subscribers will connect to ws on the child chain server, which is bad
      #       Alternatives to put in here:
      #         - broadcast as it is now, but to an Endpoint being run on a completetly separate Phoenix app
      #           (potentially living on a remote node?)
      #         - push the trigger to a Phoenix.Channels-driven notification service, but via HTTP or WS or anything
      #         - push the trigger to an entirely different notification service
      event_triggers
      |> Eventer.Core.pair_events_with_topics()
      |> Enum.each(fn {topic, event_name, event} ->
        :ok = Endpoint.broadcast!(topic, event_name, event |> Response.sanitize())
      end)

      :ok
    end
  end
end
