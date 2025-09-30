defmodule RealtimeStrategySim.GameServer do
  @moduledoc """
  Central game server managing world instances, player connections, and game state.
  
  The GameServer acts as the main coordinator for all game activities:
  - Creating and managing game worlds
  - Player registration and authentication
  - Game session management
  - Real-time communication with clients
  - Game state synchronization
  """
  
  use GenServer
  require Logger
  
  alias RealtimeStrategySim.{
    World.WorldManager,
    Entity.EntitySupervisor,
    Economic.MarketSystem,
    Military.CombatEngine,
    AI.DecisionEngine
  }

  @type player_id :: String.t()
  @type world_config :: %{
    width: integer(),
    height: integer(),
    max_players: integer(),
    tick_rate: integer(),
    max_entities: integer()
  }
  
  @type game_state :: %{
    worlds: %{String.t() => pid()},
    players: %{player_id() => %{world_id: String.t(), pid: pid()}},
    active_games: MapSet.t(),
    stats: %{
      total_players: integer(),
      active_worlds: integer(),
      uptime: integer()
    }
  }

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create_world(world_config()) :: {:ok, String.t()} | {:error, term()}
  def create_world(world_config) do
    GenServer.call(__MODULE__, {:create_world, world_config})
  end

  @spec add_player(player_id(), map()) :: {:ok, pid()} | {:error, term()}
  def add_player(player_id, player_config) do
    GenServer.call(__MODULE__, {:add_player, player_id, player_config})
  end

  @spec remove_player(player_id()) :: :ok
  def remove_player(player_id) do
    GenServer.call(__MODULE__, {:remove_player, player_id})
  end

  @spec get_world_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_world_info(world_id) do
    GenServer.call(__MODULE__, {:get_world_info, world_id})
  end

  @spec list_worlds() :: [String.t()]
  def list_worlds do
    GenServer.call(__MODULE__, :list_worlds)
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @spec broadcast_to_world(String.t(), term()) :: :ok
  def broadcast_to_world(world_id, message) do
    GenServer.cast(__MODULE__, {:broadcast_to_world, world_id, message})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("GameServer starting up")
    
    state = %{
      worlds: %{},
      players: %{},
      active_games: MapSet.new(),
      stats: %{
        total_players: 0,
        active_worlds: 0,
        uptime: :os.system_time(:second)
      }
    }
    
    # Schedule periodic cleanup and stats update
    schedule_periodic_tasks()
    
    {:ok, state}
  end

  @impl true
  def handle_call({:create_world, world_config}, _from, state) do
    world_id = generate_world_id()
    
    case WorldManager.create_world(world_id, world_config) do
      {:ok, world_pid} ->
        updated_worlds = Map.put(state.worlds, world_id, world_pid)
        updated_active = MapSet.put(state.active_games, world_id)
        
        updated_state = %{state |
          worlds: updated_worlds,
          active_games: updated_active,
          stats: %{state.stats | active_worlds: map_size(updated_worlds)}
        }
        
        Logger.info("Created world #{world_id} with config: #{inspect(world_config)}")
        {:reply, {:ok, world_id}, updated_state}
        
      {:error, reason} ->
        Logger.error("Failed to create world: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:add_player, player_id, player_config}, _from, state) do
    world_id = Map.get(player_config, :world_id, select_available_world(state))
    
    case Map.get(state.worlds, world_id) do
      nil ->
        {:reply, {:error, :world_not_found}, state}
        
      world_pid ->
        player_data = %{
          world_id: world_id,
          pid: self(),
          joined_at: :os.system_time(:second),
          config: player_config
        }
        
        updated_players = Map.put(state.players, player_id, player_data)
        
        updated_state = %{state |
          players: updated_players,
          stats: %{state.stats | total_players: map_size(updated_players)}
        }
        
        # Notify world manager about new player
        WorldManager.add_player(world_pid, player_id, player_config)
        
        Logger.info("Player #{player_id} added to world #{world_id}")
        {:reply, {:ok, world_pid}, updated_state}
    end
  end

  @impl true
  def handle_call({:remove_player, player_id}, _from, state) do
    case Map.get(state.players, player_id) do
      nil ->
        {:reply, :ok, state}
        
      player_data ->
        world_id = player_data.world_id
        updated_players = Map.delete(state.players, player_id)
        
        updated_state = %{state |
          players: updated_players,
          stats: %{state.stats | total_players: map_size(updated_players)}
        }
        
        # Notify world manager about player leaving
        if world_pid = Map.get(state.worlds, world_id) do
          WorldManager.remove_player(world_pid, player_id)
        end
        
        Logger.info("Player #{player_id} removed from world #{world_id}")
        {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call({:get_world_info, world_id}, _from, state) do
    case Map.get(state.worlds, world_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
        
      world_pid ->
        world_info = WorldManager.get_world_info(world_pid)
        {:reply, {:ok, world_info}, state}
    end
  end

  @impl true
  def handle_call(:list_worlds, _from, state) do
    world_list = Map.keys(state.worlds)
    {:reply, world_list, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    current_time = :os.system_time(:second)
    uptime = current_time - state.stats.uptime
    
    enhanced_stats = %{
      total_players: state.stats.total_players,
      active_worlds: state.stats.active_worlds,
      uptime_seconds: uptime,
      worlds: state.worlds |> Map.keys(),
      players_per_world: calculate_players_per_world(state),
      memory_usage: get_memory_usage(),
      system_info: get_system_info()
    }
    
    {:reply, enhanced_stats, state}
  end

  @impl true
  def handle_cast({:broadcast_to_world, world_id, message}, state) do
    case Map.get(state.worlds, world_id) do
      nil ->
        Logger.warning("Cannot broadcast to non-existent world #{world_id}")
        
      world_pid ->
        WorldManager.broadcast_message(world_pid, message)
        Logger.debug("Broadcasted message to world #{world_id}")
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_cleanup, state) do
    Logger.debug("Running periodic cleanup")
    
    # Clean up dead worlds
    updated_worlds = clean_dead_worlds(state.worlds)
    
    # Clean up disconnected players
    updated_players = clean_disconnected_players(state.players)
    
    updated_state = %{state |
      worlds: updated_worlds,
      players: updated_players,
      stats: %{state.stats | 
        active_worlds: map_size(updated_worlds),
        total_players: map_size(updated_players)
      }
    }
    
    # Schedule next cleanup
    schedule_periodic_tasks()
    
    {:noreply, updated_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("GameServer received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("GameServer terminating: #{inspect(reason)}")
    :ok
  end

  # Private Helper Functions

  defp generate_world_id do
    "world_" <> Base.encode16(:crypto.strong_rand_bytes(8))
  end

  defp select_available_world(state) do
    # Simple load balancing - select world with fewest players
    state.players
    |> Enum.group_by(fn {_player_id, player_data} -> player_data.world_id end)
    |> Enum.min_by(fn {_world_id, players} -> length(players) end, fn -> {nil, []} end)
    |> elem(0)
    |> case do
      nil -> 
        # No worlds available, will need to create one
        "default_world"
      world_id -> 
        world_id
    end
  end

  defp calculate_players_per_world(state) do
    state.players
    |> Enum.group_by(fn {_player_id, player_data} -> player_data.world_id end)
    |> Enum.map(fn {world_id, players} -> {world_id, length(players)} end)
    |> Map.new()
  end

  defp clean_dead_worlds(worlds) do
    worlds
    |> Enum.filter(fn {_world_id, world_pid} -> Process.alive?(world_pid) end)
    |> Map.new()
  end

  defp clean_disconnected_players(players) do
    players
    |> Enum.filter(fn {_player_id, player_data} -> 
      Process.alive?(player_data.pid) 
    end)
    |> Map.new()
  end

  defp get_memory_usage do
    {:memory, memory_kb} = Process.info(self(), :memory)
    div(memory_kb, 1024)
  end

  defp get_system_info do
    %{
      schedulers: :erlang.system_info(:schedulers),
      processes: :erlang.system_info(:process_count),
      atoms: :erlang.system_info(:atom_count),
      beam_version: :erlang.system_info(:version)
    }
  end

  defp schedule_periodic_tasks do
    Process.send_after(self(), :periodic_cleanup, 30_000) # 30 seconds
  end
end