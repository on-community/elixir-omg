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

defmodule OMG.Watcher.Web.Channel.Transfer do
  @moduledoc """
  Channel Transfer
  """

  use Phoenix.Channel, log_join: :debug

  def join("transfer:" <> _address = topic, _params, socket) do
    notification_service_url = Application.fetch_env!(:omg_watcher, :notification_service_url)

    {:ok, external_socket} =
      [url: "#{notification_service_url}/unstable_experimental_socket/websocket"]
      |> PhoenixClient.Socket.start_link()

    # wait a bit!
    # FIXME: improve
    Process.sleep(1500)

    {:ok, _response, channel} = PhoenixClient.Channel.join(external_socket, topic)

    {:ok, socket}
  end

  def join(_, _, _), do: {:error, :invalid_parameter}

  def handle_info(%PhoenixClient.Message{event: event, payload: payload}, socket) do
    :ok = push(socket, event, payload)
    {:noreply, socket}
  end
end
