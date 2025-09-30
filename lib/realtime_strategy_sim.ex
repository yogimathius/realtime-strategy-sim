defmodule RealtimeStrategySim do
  @moduledoc """
  Real-Time Strategy Simulation Engine
  
  A massive-scale distributed RTS simulation supporting:
  - 50,000+ concurrent entity actors
  - 64 players on 10km x 10km battlefield
  - Complex economic and military systems
  - Real-time AI decision making
  - High-performance tick-based simulation
  """

  use Application

  alias RealtimeStrategySim.{
    GameServer,
    SimulationTicker,
    Entity.EntitySupervisor,
    World.WorldManager,
    Economic.MarketSystem,
    Military.CombatEngine,
    AI.DecisionEngine
  }

  @doc """
  Start the RTS simulation application
  """
  def start(_type, _args) do
    children = [
      # Core system registry
      {Registry, keys: :unique, name: RealtimeStrategySim.Registry},
      
      # World state management
      WorldManager,
      
      # Entity management
      {DynamicSupervisor, name: EntitySupervisor, strategy: :one_for_one},
      
      # Economic system
      MarketSystem,
      
      # Combat system
      CombatEngine,
      
      # AI system
      DecisionEngine,
      
      # Main game server
      GameServer,
      
      # Simulation ticker (60 FPS)
      {SimulationTicker, tick_rate: 60}
    ]

    opts = [strategy: :one_for_one, name: RealtimeStrategySim.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Create a new game world instance
  """
  @spec create_world(map()) :: {:ok, pid()} | {:error, term()}
  def create_world(world_config \\ %{}) do
    default_config = %{
      width: 10_000,      # 10km
      height: 10_000,     # 10km
      max_players: 64,
      tick_rate: 60,
      max_entities: 50_000
    }
    
    config = Map.merge(default_config, world_config)
    GameServer.create_world(config)
  end

  @doc """
  Get simulation statistics
  """
  @spec get_stats() :: map()
  def get_stats do
    %{
      entities: EntitySupervisor.get_stats(EntitySupervisor),
      world: WorldManager.get_stats(),
      market: MarketSystem.get_stats(),
      combat: CombatEngine.get_stats(),
      simulation: SimulationTicker.get_stats()
    }
  end

  @doc """
  Spawn a new entity in the simulation
  """
  @spec spawn_entity(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def spawn_entity(entity_type, entity_spec) do
    case entity_type do
      "unit" -> 
        EntitySupervisor.spawn_unit(EntitySupervisor, entity_spec)
      "building" ->
        EntitySupervisor.spawn_building(EntitySupervisor, entity_spec)
      "resource" ->
        EntitySupervisor.spawn_resource(EntitySupervisor, entity_spec)
      _ ->
        {:error, :unknown_entity_type}
    end
  end

  @doc """
  Add player to the simulation
  """
  @spec add_player(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def add_player(player_id, player_config) do
    GameServer.add_player(player_id, player_config)
  end

  @doc """
  Start the real-time simulation
  """
  @spec start_simulation() :: :ok
  def start_simulation do
    SimulationTicker.start_ticking()
    :ok
  end

  @doc """
  Stop the simulation
  """
  @spec stop_simulation() :: :ok
  def stop_simulation do
    SimulationTicker.stop_ticking()
    :ok
  end
end
