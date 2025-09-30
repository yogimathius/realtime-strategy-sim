defmodule RealtimeStrategySim.Entity.UnitActor do
  @moduledoc """
  GenServer representing a single unit entity in the RTS simulation.
  
  Each unit has:
  - Position in 2D world coordinates
  - Health and energy resources
  - Type (soldier, vehicle, aircraft, etc.)
  - Combat and movement capabilities
  """
  
  use GenServer
  require Logger

  @type unit_type :: :soldier | :vehicle | :aircraft | :building
  @type position :: {float(), float()}
  @type unit_state :: %{
    id: String.t(),
    type: unit_type(),
    position: position(),
    health: integer(),
    energy: integer(),
    max_health: integer(),
    max_energy: integer()
  }

  # Client API

  @spec start_link(map()) :: {:ok, pid()} | {:error, term()}
  def start_link(unit_params) do
    GenServer.start_link(__MODULE__, unit_params)
  end

  @spec get_state(pid()) :: unit_state()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @spec move_to(pid(), position()) :: :ok
  def move_to(pid, new_position) do
    GenServer.call(pid, {:move_to, new_position})
  end

  @spec take_damage(pid(), integer()) :: :ok
  def take_damage(pid, damage_amount) do
    GenServer.call(pid, {:take_damage, damage_amount})
  end

  @spec consume_energy(pid(), integer()) :: :ok
  def consume_energy(pid, energy_amount) do
    GenServer.call(pid, {:consume_energy, energy_amount})
  end

  @spec attack_target(pid(), pid()) :: :ok
  def attack_target(attacker_pid, target_pid) do
    GenServer.cast(attacker_pid, {:attack_target, target_pid})
  end

  # Server Callbacks

  @impl true
  def init(unit_params) do
    state = %{
      id: Map.get(unit_params, :id, "unknown"),
      type: Map.get(unit_params, :type, :soldier),
      position: Map.get(unit_params, :position, {0.0, 0.0}),
      health: Map.get(unit_params, :health, 100),
      energy: Map.get(unit_params, :energy, 100),
      max_health: Map.get(unit_params, :health, 100),
      max_energy: Map.get(unit_params, :energy, 100)
    }
    
    Logger.info("Unit Actor #{state.id} spawned at #{inspect(state.position)}")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true  
  def handle_call({:move_to, new_position}, _from, state) do
    # Consume energy for movement
    energy_cost = calculate_movement_cost(state.position, new_position)
    
    if state.energy >= energy_cost do
      updated_state = %{state | 
        position: new_position,
        energy: state.energy - energy_cost
      }
      Logger.debug("Unit #{state.id} moved to #{inspect(new_position)}")
      {:reply, :ok, updated_state}
    else
      Logger.warn("Unit #{state.id} insufficient energy for movement")
      {:reply, {:error, :insufficient_energy}, state}
    end
  end

  @impl true
  def handle_call({:take_damage, damage_amount}, _from, state) do
    new_health = max(0, state.health - damage_amount)
    updated_state = %{state | health: new_health}
    
    Logger.info("Unit #{state.id} took #{damage_amount} damage, health: #{new_health}")
    
    if new_health <= 0 do
      Logger.info("Unit #{state.id} has died")
      # Unit dies - terminate the process
      {:stop, :normal, :ok, updated_state}
    else
      {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call({:consume_energy, energy_amount}, _from, state) do
    new_energy = max(0, state.energy - energy_amount)
    updated_state = %{state | energy: new_energy}
    
    Logger.debug("Unit #{state.id} consumed #{energy_amount} energy, remaining: #{new_energy}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_cast({:attack_target, target_pid}, state) do
    # Attack consumes energy
    attack_energy_cost = 15
    attack_damage = calculate_attack_damage(state.type)
    
    if state.energy >= attack_energy_cost and Process.alive?(target_pid) do
      # Consume energy for attack
      updated_state = %{state | energy: state.energy - attack_energy_cost}
      
      # Send damage to target
      take_damage(target_pid, attack_damage)
      
      Logger.info("Unit #{state.id} attacked target, dealing #{attack_damage} damage")
      {:noreply, updated_state}
    else
      Logger.warn("Unit #{state.id} cannot attack - insufficient energy or target dead")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unit #{state.id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Unit #{state.id} terminating: #{inspect(reason)}")
    :ok
  end

  # Private helper functions

  defp calculate_movement_cost(from, to) do
    # Simple distance-based energy cost
    {x1, y1} = from
    {x2, y2} = to
    distance = :math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
    round(distance / 10) # 1 energy per 10 units distance
  end

  defp calculate_attack_damage(unit_type) do
    case unit_type do
      :soldier -> 25
      :vehicle -> 40
      :aircraft -> 30
      _ -> 20
    end
  end
end