# Copyright 2018-2019 OmiseGO Pte Ltd
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

defmodule OMG.DB.ReleaseTasks.InitKeyValueDB do
  @moduledoc """
    Creates an empty instance of OMG DB storage and fills it with the required initial data.
  """

  @start_apps [:logger, :crypto, :ssl]
  alias OMG.Utils.CLI

  def run do
    path = Application.get_env(:omg_db, :leveldb_path)
    _ = process(path)
    :ok
  end

  defp process(path) do
    _ = CLI.info("Creating database at #{inspect(path)}")
    _ = Enum.each(@start_apps, &Application.ensure_all_started/1)
    _ = init_kv_db(path)
    Enum.each(Enum.reverse(@start_apps), &Application.stop/1)
  end

  defp init_kv_db(path) do
    case OMG.DB.init(path) do
      {:error, term} -> CLI.error("Could not initialize the DB in #{path}. Reason #{inspect(term)}")
      :ok -> CLI.info("The database at #{inspect(path)} has been created")
    end
  end
end
