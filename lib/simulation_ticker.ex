defmodule RealtimeStrategySim.SimulationTicker do
  @moduledoc """
  High-performance tick-based simulation engine running at 60 FPS.
  
  The SimulationTicker coordinates all time-based updates across the entire simulation:
  - Entity movement and AI updates
  - Combat resolution and damage calculations
  - Economic market fluctuations and trade processing
  - Physics simulation and collision detection
  - Network synchronization and state broadcasts
  """
  
  use GenServer
  require Logger
  
  alias RealtimeStrategySim.{
    Entity.EntitySupervisor,
    World.WorldManager,
    Economic.MarketSystem,
    Military.CombatEngine,
    AI.DecisionEngine
  }

  @default_tick_rate 60 # 60 FPS
  @tick_interval_ms 16 # 1000ms / 60 FPS ≈ 16.67ms
  
  @type tick_stats :: %{
    current_tick: integer(),
    tick_rate: integer(),
    avg_tick_time_ms: float(),
    max_tick_time_ms: integer(),
    min_tick_time_ms: integer(),
    ticks_processed: integer(),
    simulation_time_ms: integer(),
    performance_warnings: integer()
  }
  
  @type simulation_state :: %{
    is_running: boolean(),
    tick_rate: integer(),
    tick_interval_ms: integer(),
    current_tick: integer(),
    start_time: integer(),
    last_tick_time: integer(),
    tick_times: [integer()],
    stats: tick_stats(),
    registered_systems: [atom()]
  }

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_ticking() :: :ok
  def start_ticking do
    GenServer.call(__MODULE__, :start_ticking)
  end

  @spec stop_ticking() :: :ok
  def stop_ticking do
    GenServer.call(__MODULE__, :stop_ticking)
  end

  @spec is_running() :: boolean()
  def is_running do
    GenServer.call(__MODULE__, :is_running)
  end

  @spec get_stats() :: tick_stats()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @spec set_tick_rate(integer()) :: :ok
  def set_tick_rate(new_rate) when new_rate > 0 and new_rate <= 120 do
    GenServer.call(__MODULE__, {:set_tick_rate, new_rate})
  end

  @spec register_system(atom()) :: :ok
  def register_system(system_module) do
    GenServer.call(__MODULE__, {:register_system, system_module})
  end

  @spec unregister_system(atom()) :: :ok
  def unregister_system(system_module) do
    GenServer.call(__MODULE__, {:unregister_system, system_module})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    tick_rate = Keyword.get(opts, :tick_rate, @default_tick_rate)
    tick_interval = calculate_tick_interval(tick_rate)
    
    state = %{
      is_running: false,
      tick_rate: tick_rate,
      tick_interval_ms: tick_interval,
      current_tick: 0,
      start_time: 0,
      last_tick_time: 0,
      tick_times: [],
      stats: initialize_stats(tick_rate),
      registered_systems: [
        EntitySupervisor,
        WorldManager,
        MarketSystem,
        CombatEngine,
        DecisionEngine
      ]
    }
    
    Logger.info("SimulationTicker initialized with #{tick_rate} FPS (#{tick_interval}ms intervals)")
    {:ok, state}
  end

  @impl true
  def handle_call(:start_ticking, _from, state) do
    if state.is_running do
      {:reply, :already_running, state}
    else
      Logger.info("Starting real-time simulation at #{state.tick_rate} FPS")
      
      start_time = :os.system_time(:millisecond)
      schedule_next_tick(state.tick_interval_ms)
      
      updated_state = %{state |
        is_running: true,
        start_time: start_time,
        last_tick_time: start_time,
        current_tick: 0,
        tick_times: [],
        stats: reset_stats(state.stats, state.tick_rate)
      }
      
      {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call(:stop_ticking, _from, state) do
    if state.is_running do
      Logger.info("Stopping real-time simulation")
      
      updated_state = %{state | is_running: false}
      {:reply, :ok, updated_state}
    else
      {:reply, :already_stopped, state}
    end
  end

  @impl true
  def handle_call(:is_running, _from, state) do
    {:reply, state.is_running, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    current_stats = calculate_current_stats(state)
    {:reply, current_stats, state}
  end

  @impl true
  def handle_call({:set_tick_rate, new_rate}, _from, state) do
    new_interval = calculate_tick_interval(new_rate)
    
    updated_state = %{state |
      tick_rate: new_rate,
      tick_interval_ms: new_interval,
      stats: %{state.stats | tick_rate: new_rate}
    }
    
    Logger.info("Tick rate changed to #{new_rate} FPS (#{new_interval}ms intervals)")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:register_system, system_module}, _from, state) do
    updated_systems = [system_module | state.registered_systems] |> Enum.uniq()
    updated_state = %{state | registered_systems: updated_systems}
    
    Logger.info("Registered system: #{system_module}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:unregister_system, system_module}, _from, state) do
    updated_systems = Enum.reject(state.registered_systems, &(&1 == system_module))
    updated_state = %{state | registered_systems: updated_systems}
    
    Logger.info("Unregistered system: #{system_module}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.is_running do
      tick_start_time = :os.system_time(:millisecond)
      
      # Execute simulation tick
      execute_simulation_tick(state.current_tick, state.registered_systems)
      
      tick_end_time = :os.system_time(:millisecond)
      tick_duration = tick_end_time - tick_start_time
      
      # Update performance statistics
      updated_state = update_tick_stats(state, tick_duration, tick_end_time)
      
      # Schedule next tick if still running
      if updated_state.is_running do
        schedule_next_tick(state.tick_interval_ms)
      end
      
      {:noreply, updated_state}
    else
      # Simulation stopped, don't schedule next tick
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("SimulationTicker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("SimulationTicker terminating: #{inspect(reason)}")
    
    if state.is_running do
      Logger.info("Final simulation stats:")
      Logger.info("  Total ticks processed: #{state.current_tick}")
      Logger.info("  Average tick time: #{state.stats.avg_tick_time_ms}ms")
      Logger.info("  Performance warnings: #{state.stats.performance_warnings}")
    end
    
    :ok
  end

  # Private Helper Functions

  defp calculate_tick_interval(tick_rate) do
    round(1000 / tick_rate)
  end

  defp initialize_stats(tick_rate) do
    %{
      current_tick: 0,
      tick_rate: tick_rate,
      avg_tick_time_ms: 0.0,
      max_tick_time_ms: 0,
      min_tick_time_ms: 999_999,
      ticks_processed: 0,
      simulation_time_ms: 0,
      performance_warnings: 0
    }
  end

  defp reset_stats(stats, tick_rate) do
    %{stats |
      current_tick: 0,
      tick_rate: tick_rate,
      avg_tick_time_ms: 0.0,
      max_tick_time_ms: 0,
      min_tick_time_ms: 999_999,
      ticks_processed: 0,
      simulation_time_ms: 0,
      performance_warnings: 0
    }
  end

  defp schedule_next_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp execute_simulation_tick(tick_number, registered_systems) do
    Logger.debug("Executing simulation tick ##{tick_number}")
    
    # Execute tick for each registered system in parallel
    tasks = Enum.map(registered_systems, fn system ->
      Task.async(fn ->
        try do
          execute_system_tick(system, tick_number)
        rescue
          error ->
            Logger.error("Error in system #{system} during tick #{tick_number}: #{inspect(error)}")
            {:error, error}
        end
      end)
    end)
    
    # Wait for all systems to complete their tick processing
    Task.await_many(tasks, 15) # 15ms timeout to ensure we don't exceed tick budget
  end

  defp execute_system_tick(system, tick_number) do
    case system do
      EntitySupervisor ->
        # Update all entity actors - movement, AI, state changes
        update_entities(tick_number)
        
      WorldManager ->
        # Update world state - physics, environment, spatial indexing
        update_world_state(tick_number)
        
      MarketSystem ->
        # Process economic transactions and price updates
        update_market_systems(tick_number)
        
      CombatEngine ->
        # Resolve combat actions and damage calculations
        update_combat_systems(tick_number)
        
      DecisionEngine ->
        # Process AI decision-making for strategic planning
        update_ai_systems(tick_number)
        
      _ ->
        # Custom system - attempt to call tick function
        if function_exported?(system, :simulation_tick, 1) do
          system.simulation_tick(tick_number)
        end
    end
  end

  defp update_entities(tick_number) do
    # For now, just log that entity updates would happen
    # In a full implementation, this would:
    # 1. Get all active entities from EntitySupervisor
    # 2. Send tick messages to all entity processes
    # 3. Handle entity lifecycle (spawning/despawning)
    
    if rem(tick_number, 60) == 0 do # Log every second
      Logger.debug("Entities tick ##{tick_number} - updating all active entities")
    end
  end

  defp update_world_state(tick_number) do
    # World physics, collision detection, environmental effects
    if rem(tick_number, 60) == 0 do
      Logger.debug("World tick ##{tick_number} - updating physics and environment")
    end
  end

  defp update_market_systems(tick_number) do
    # Economic market fluctuations, trade processing
    if rem(tick_number, 300) == 0 do # Log every 5 seconds
      Logger.debug("Market tick ##{tick_number} - processing economic updates")
    end
  end

  defp update_combat_systems(tick_number) do
    # Combat resolution, damage calculations, weapon systems
    if rem(tick_number, 60) == 0 do
      Logger.debug("Combat tick ##{tick_number} - resolving combat actions")
    end
  end

  defp update_ai_systems(tick_number) do
    # AI decision-making, strategic planning, behavior trees
    if rem(tick_number, 180) == 0 do # Log every 3 seconds
      Logger.debug("AI tick ##{tick_number} - processing AI decisions")
    end
  end

  defp update_tick_stats(state, tick_duration, current_time) do
    new_tick_number = state.current_tick + 1
    simulation_time = current_time - state.start_time
    
    # Keep rolling window of last 60 tick times for averaging
    updated_tick_times = [tick_duration | Enum.take(state.tick_times, 59)]
    avg_tick_time = Enum.sum(updated_tick_times) / length(updated_tick_times)
    
    # Check for performance warnings
    performance_warnings = if tick_duration > state.tick_interval_ms * 1.5 do
      state.stats.performance_warnings + 1
    else
      state.stats.performance_warnings
    end
    
    updated_stats = %{state.stats |
      current_tick: new_tick_number,
      avg_tick_time_ms: Float.round(avg_tick_time, 2),
      max_tick_time_ms: max(state.stats.max_tick_time_ms, tick_duration),
      min_tick_time_ms: min(state.stats.min_tick_time_ms, tick_duration),
      ticks_processed: new_tick_number,
      simulation_time_ms: simulation_time,
      performance_warnings: performance_warnings
    }
    
    # Log performance warning if tick took too long
    if tick_duration > state.tick_interval_ms * 1.5 do
      Logger.warning("Slow tick ##{new_tick_number}: #{tick_duration}ms (target: #{state.tick_interval_ms}ms)")
    end
    
    %{state |
      current_tick: new_tick_number,
      last_tick_time: current_time,
      tick_times: updated_tick_times,
      stats: updated_stats
    }
  end

  defp calculate_current_stats(state) do
    current_time = :os.system_time(:millisecond)
    uptime_ms = if state.start_time > 0, do: current_time - state.start_time, else: 0
    
    %{state.stats |
      simulation_time_ms: uptime_ms
    }
  end
end