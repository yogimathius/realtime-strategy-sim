defmodule RealtimeStrategySim.World.WorldManager do
  @moduledoc """
  Manages world state, spatial indexing, and environmental simulation.
  
  The WorldManager handles:
  - 10km x 10km battlefield state management
  - Quadtree spatial indexing for efficient proximity queries
  - Terrain and environmental effects
  - Physics simulation and collision detection
  - World state synchronization across distributed nodes
  """
  
  use GenServer
  require Logger
  
  alias RealtimeStrategySim.World.{SpatialIndex, TerrainManager, PhysicsEngine}

  @default_world_size {10_000, 10_000} # 10km x 10km
  @spatial_index_depth 8 # Quadtree depth for spatial indexing
  
  @type position :: {float(), float()}
  @type world_id :: String.t()
  @type entity_id :: String.t()
  @type player_id :: String.t()
  
  @type world_config :: %{
    width: integer(),
    height: integer(),
    max_players: integer(),
    max_entities: integer(),
    terrain_type: atom(),
    weather_enabled: boolean()
  }
  
  @type world_state :: %{
    id: world_id(),
    config: world_config(),
    entities: %{entity_id() => map()},
    players: %{player_id() => map()},
    spatial_index: pid(),
    terrain: map(),
    physics: map(),
    environment: map(),
    created_at: integer(),
    last_update: integer()
  }

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create_world(world_id(), world_config()) :: {:ok, pid()} | {:error, term()}
  def create_world(world_id, world_config) do
    GenServer.call(__MODULE__, {:create_world, world_id, world_config})
  end

  @spec get_world_info(pid()) :: map()
  def get_world_info(world_pid) do
    GenServer.call(world_pid, :get_world_info)
  end

  @spec add_entity(pid(), entity_id(), map()) :: :ok
  def add_entity(world_pid, entity_id, entity_data) do
    GenServer.call(world_pid, {:add_entity, entity_id, entity_data})
  end

  @spec remove_entity(pid(), entity_id()) :: :ok
  def remove_entity(world_pid, entity_id) do
    GenServer.call(world_pid, {:remove_entity, entity_id})
  end

  @spec update_entity_position(pid(), entity_id(), position()) :: :ok
  def update_entity_position(world_pid, entity_id, new_position) do
    GenServer.call(world_pid, {:update_entity_position, entity_id, new_position})
  end

  @spec add_player(pid(), player_id(), map()) :: :ok
  def add_player(world_pid, player_id, player_config) do
    GenServer.call(world_pid, {:add_player, player_id, player_config})
  end

  @spec remove_player(pid(), player_id()) :: :ok
  def remove_player(world_pid, player_id) do
    GenServer.call(world_pid, {:remove_player, player_id})
  end

  @spec get_entities_in_area(pid(), position(), float()) :: [map()]
  def get_entities_in_area(world_pid, center_position, radius) do
    GenServer.call(world_pid, {:get_entities_in_area, center_position, radius})
  end

  @spec get_nearest_entities(pid(), position(), integer()) :: [map()]
  def get_nearest_entities(world_pid, position, count) do
    GenServer.call(world_pid, {:get_nearest_entities, position, count})
  end

  @spec broadcast_message(pid(), term()) :: :ok
  def broadcast_message(world_pid, message) do
    GenServer.cast(world_pid, {:broadcast_message, message})
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("WorldManager starting up")
    {:ok, %{worlds: %{}}}
  end

  @impl true
  def handle_call({:create_world, world_id, world_config}, _from, state) do
    case create_world_process(world_id, world_config) do
      {:ok, world_pid} ->
        updated_worlds = Map.put(state.worlds, world_id, world_pid)
        updated_state = %{state | worlds: updated_worlds}
        
        Logger.info("Created world #{world_id} with dimensions #{world_config.width}x#{world_config.height}")
        {:reply, {:ok, world_pid}, updated_state}
        
      {:error, reason} ->
        Logger.error("Failed to create world #{world_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    world_stats = state.worlds
    |> Enum.map(fn {world_id, world_pid} ->
      if Process.alive?(world_pid) do
        world_info = GenServer.call(world_pid, :get_world_info)
        {world_id, %{
          entity_count: map_size(world_info.entities),
          player_count: map_size(world_info.players),
          uptime_ms: :os.system_time(:millisecond) - world_info.created_at
        }}
      else
        {world_id, :dead}
      end
    end)
    |> Map.new()
    
    stats = %{
      active_worlds: map_size(state.worlds),
      world_details: world_stats,
      total_entities: calculate_total_entities(world_stats),
      total_players: calculate_total_players(world_stats)
    }
    
    {:reply, stats, state}
  end

  # World Process Implementation

  defp create_world_process(world_id, world_config) do
    initial_state = %{
      id: world_id,
      config: normalize_world_config(world_config),
      entities: %{},
      players: %{},
      spatial_index: nil,
      terrain: %{},
      physics: initialize_physics(),
      environment: initialize_environment(),
      created_at: :os.system_time(:millisecond),
      last_update: :os.system_time(:millisecond)
    }
    
    case GenServer.start_link(__MODULE__.WorldProcess, initial_state) do
      {:ok, world_pid} ->
        {:ok, world_pid}
      error ->
        error
    end
  end

  defp normalize_world_config(config) do
    %{
      width: Map.get(config, :width, 10_000),
      height: Map.get(config, :height, 10_000),
      max_players: Map.get(config, :max_players, 64),
      max_entities: Map.get(config, :max_entities, 50_000),
      terrain_type: Map.get(config, :terrain_type, :mixed),
      weather_enabled: Map.get(config, :weather_enabled, true)
    }
  end

  defp initialize_physics do
    %{
      gravity: -9.81,
      air_resistance: 0.02,
      collision_detection: true,
      physics_steps_per_tick: 1
    }
  end

  defp initialize_environment do
    %{
      weather: :clear,
      temperature: 20.0, # Celsius
      wind_speed: 5.0, # km/h
      wind_direction: 0.0, # degrees
      visibility: 10.0 # km
    }
  end

  defp calculate_total_entities(world_stats) do
    world_stats
    |> Enum.reduce(0, fn 
      {_world_id, :dead}, acc -> acc
      {_world_id, world_data}, acc -> acc + world_data.entity_count
    end)
  end

  defp calculate_total_players(world_stats) do
    world_stats
    |> Enum.reduce(0, fn 
      {_world_id, :dead}, acc -> acc
      {_world_id, world_data}, acc -> acc + world_data.player_count
    end)
  end
end

defmodule RealtimeStrategySim.World.WorldManager.WorldProcess do
  @moduledoc """
  Individual world process handling a single game world instance.
  """
  
  use GenServer
  require Logger
  
  alias RealtimeStrategySim.World.{SpatialIndex, TerrainManager}

  # Server Callbacks for Individual World Process

  @impl true
  def init(world_state) do
    Logger.info("World #{world_state.id} process starting")
    
    # Initialize spatial indexing system
    {:ok, spatial_index_pid} = start_spatial_index(world_state.config)
    
    updated_state = %{world_state | 
      spatial_index: spatial_index_pid,
      terrain: initialize_terrain(world_state.config)
    }
    
    {:ok, updated_state}
  end

  @impl true
  def handle_call(:get_world_info, _from, state) do
    world_info = %{
      id: state.id,
      config: state.config,
      entities: state.entities,
      players: state.players,
      environment: state.environment,
      created_at: state.created_at,
      last_update: state.last_update,
      stats: %{
        entity_count: map_size(state.entities),
        player_count: map_size(state.players),
        uptime_ms: :os.system_time(:millisecond) - state.created_at
      }
    }
    
    {:reply, world_info, state}
  end

  @impl true
  def handle_call({:add_entity, entity_id, entity_data}, _from, state) do
    if map_size(state.entities) >= state.config.max_entities do
      Logger.warning("World #{state.id} at maximum entity capacity")
      {:reply, {:error, :max_entities_reached}, state}
    else
      # Add entity to spatial index
      position = Map.get(entity_data, :position, {0.0, 0.0})
      add_to_spatial_index(state.spatial_index, entity_id, position)
      
      updated_entities = Map.put(state.entities, entity_id, entity_data)
      updated_state = %{state | 
        entities: updated_entities,
        last_update: :os.system_time(:millisecond)
      }
      
      Logger.debug("Added entity #{entity_id} to world #{state.id} at #{inspect(position)}")
      {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call({:remove_entity, entity_id}, _from, state) do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:reply, :ok, state}
        
      entity_data ->
        # Remove from spatial index
        position = Map.get(entity_data, :position, {0.0, 0.0})
        remove_from_spatial_index(state.spatial_index, entity_id, position)
        
        updated_entities = Map.delete(state.entities, entity_id)
        updated_state = %{state | 
          entities: updated_entities,
          last_update: :os.system_time(:millisecond)
        }
        
        Logger.debug("Removed entity #{entity_id} from world #{state.id}")
        {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call({:update_entity_position, entity_id, new_position}, _from, state) do
    case Map.get(state.entities, entity_id) do
      nil ->
        {:reply, {:error, :entity_not_found}, state}
        
      entity_data ->
        old_position = Map.get(entity_data, :position, {0.0, 0.0})
        
        # Update spatial index
        remove_from_spatial_index(state.spatial_index, entity_id, old_position)
        add_to_spatial_index(state.spatial_index, entity_id, new_position)
        
        # Update entity data
        updated_entity_data = Map.put(entity_data, :position, new_position)
        updated_entities = Map.put(state.entities, entity_id, updated_entity_data)
        
        updated_state = %{state | 
          entities: updated_entities,
          last_update: :os.system_time(:millisecond)
        }
        
        {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call({:add_player, player_id, player_config}, _from, state) do
    if map_size(state.players) >= state.config.max_players do
      Logger.warning("World #{state.id} at maximum player capacity")
      {:reply, {:error, :max_players_reached}, state}
    else
      player_data = Map.merge(player_config, %{
        joined_at: :os.system_time(:millisecond),
        last_active: :os.system_time(:millisecond)
      })
      
      updated_players = Map.put(state.players, player_id, player_data)
      updated_state = %{state | 
        players: updated_players,
        last_update: :os.system_time(:millisecond)
      }
      
      Logger.info("Player #{player_id} joined world #{state.id}")
      {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call({:remove_player, player_id}, _from, state) do
    updated_players = Map.delete(state.players, player_id)
    updated_state = %{state | 
      players: updated_players,
      last_update: :os.system_time(:millisecond)
    }
    
    Logger.info("Player #{player_id} left world #{state.id}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:get_entities_in_area, center_position, radius}, _from, state) do
    entities = query_spatial_area(state.spatial_index, center_position, radius)
    
    entity_data = entities
    |> Enum.map(fn entity_id -> {entity_id, Map.get(state.entities, entity_id)} end)
    |> Enum.filter(fn {_id, data} -> data != nil end)
    |> Map.new()
    
    {:reply, entity_data, state}
  end

  @impl true
  def handle_call({:get_nearest_entities, position, count}, _from, state) do
    entities = query_nearest_entities(state.spatial_index, position, count)
    
    entity_data = entities
    |> Enum.map(fn entity_id -> {entity_id, Map.get(state.entities, entity_id)} end)
    |> Enum.filter(fn {_id, data} -> data != nil end)
    |> Enum.take(count)
    |> Map.new()
    
    {:reply, entity_data, state}
  end

  @impl true
  def handle_cast({:broadcast_message, message}, state) do
    Logger.debug("Broadcasting message to world #{state.id}: #{inspect(message)}")
    
    # In a full implementation, this would send the message to all connected players
    # For now, just log the broadcast
    
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("World #{state.id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("World #{state.id} terminating: #{inspect(reason)}")
    :ok
  end

  # Private Helper Functions for Spatial Indexing

  defp start_spatial_index(config) do
    # For now, return a mock PID - in a full implementation this would start a proper spatial index process
    {:ok, spawn(fn -> spatial_index_process(config) end)}
  end

  defp spatial_index_process(config) do
    Logger.info("Spatial index started for world #{config.width}x#{config.height}")
    receive do
      _ -> spatial_index_process(config)
    end
  end

  defp add_to_spatial_index(_spatial_index_pid, entity_id, position) do
    Logger.debug("Adding entity #{entity_id} to spatial index at #{inspect(position)}")
    :ok
  end

  defp remove_from_spatial_index(_spatial_index_pid, entity_id, position) do
    Logger.debug("Removing entity #{entity_id} from spatial index at #{inspect(position)}")
    :ok
  end

  defp query_spatial_area(_spatial_index_pid, center_position, radius) do
    Logger.debug("Querying spatial area at #{inspect(center_position)} with radius #{radius}")
    [] # Return empty list for now
  end

  defp query_nearest_entities(_spatial_index_pid, position, count) do
    Logger.debug("Querying #{count} nearest entities to #{inspect(position)}")
    [] # Return empty list for now
  end

  defp initialize_terrain(config) do
    Logger.info("Initializing terrain for #{config.terrain_type} world")
    
    %{
      type: config.terrain_type,
      elevation_map: generate_elevation_map(config.width, config.height),
      obstacles: generate_obstacles(config),
      resources: generate_resource_nodes(config)
    }
  end

  defp generate_elevation_map(width, height) do
    Logger.debug("Generating elevation map for #{width}x#{height} terrain")
    %{min_elevation: 0, max_elevation: 100, resolution: 100}
  end

  defp generate_obstacles(config) do
    Logger.debug("Generating obstacles for #{config.terrain_type} terrain")
    []
  end

  defp generate_resource_nodes(config) do
    Logger.debug("Generating resource nodes for world")
    []
  end
end