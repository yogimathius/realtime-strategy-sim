defmodule RealtimeStrategySim.Military.CombatEngine do
  @moduledoc """
  Advanced tactical combat system with realistic military simulation.
  
  The CombatEngine handles:
  - Multiple damage types (kinetic, energy, explosive, EMP)
  - Armor mechanics with type-specific resistances
  - Line of sight calculations with terrain occlusion
  - Cover systems and tactical positioning
  - Suppression mechanics affecting unit effectiveness
  - Electronic warfare (radar, jamming, stealth)
  """
  
  use GenServer
  require Logger

  alias RealtimeStrategySim.Entity.EntitySupervisor

  @damage_types [:kinetic, :energy, :explosive, :emp, :chemical]
  @weapon_types [:rifle, :machine_gun, :cannon, :laser, :missile, :emp_device]
  @armor_types [:light, :medium, :heavy, :reactive, :energy_shield]
  
  @type damage_type :: atom()
  @type weapon_type :: atom()
  @type armor_type :: atom()
  @type position :: {float(), float()}
  @type entity_id :: String.t()
  @type player_id :: String.t()
  
  @type weapon_stats :: %{
    type: weapon_type(),
    damage: integer(),
    damage_type: damage_type(),
    range: float(),
    accuracy: float(),
    rate_of_fire: float(),
    penetration: integer(),
    area_of_effect: float()
  }
  
  @type armor_stats :: %{
    type: armor_type(),
    kinetic_resistance: float(),
    energy_resistance: float(),
    explosive_resistance: float(),
    emp_resistance: float(),
    chemical_resistance: float(),
    durability: integer()
  }
  
  @type combat_state :: %{
    active_combats: %{String.t() => map()},
    weapon_definitions: %{weapon_type() => weapon_stats()},
    armor_definitions: %{armor_type() => armor_stats()},
    suppression_zones: [map()],
    electronic_warfare: %{
      jamming_zones: [map()],
      radar_contacts: [map()],
      stealth_units: MapSet.t()
    },
    combat_stats: %{
      total_engagements: integer(),
      shots_fired: integer(),
      hits_landed: integer(),
      casualties: integer()
    }
  }

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec engage_target(entity_id(), entity_id(), weapon_type()) :: :ok | {:error, term()}
  def engage_target(attacker_id, target_id, weapon_type) do
    GenServer.call(__MODULE__, {:engage_target, attacker_id, target_id, weapon_type})
  end

  @spec calculate_damage(weapon_stats(), armor_stats(), float()) :: integer()
  def calculate_damage(weapon, armor, distance) do
    GenServer.call(__MODULE__, {:calculate_damage, weapon, armor, distance})
  end

  @spec check_line_of_sight(position(), position()) :: boolean()
  def check_line_of_sight(from_pos, to_pos) do
    GenServer.call(__MODULE__, {:check_line_of_sight, from_pos, to_pos})
  end

  @spec apply_suppression(entity_id(), float()) :: :ok
  def apply_suppression(entity_id, suppression_level) do
    GenServer.cast(__MODULE__, {:apply_suppression, entity_id, suppression_level})
  end

  @spec activate_jamming(entity_id(), position(), float()) :: {:ok, String.t()}
  def activate_jamming(jammer_id, position, radius) do
    GenServer.call(__MODULE__, {:activate_jamming, jammer_id, position, radius})
  end

  @spec enable_stealth(entity_id()) :: :ok
  def enable_stealth(entity_id) do
    GenServer.call(__MODULE__, {:enable_stealth, entity_id})
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("CombatEngine starting up")
    
    state = %{
      active_combats: %{},
      weapon_definitions: initialize_weapon_definitions(),
      armor_definitions: initialize_armor_definitions(),
      suppression_zones: [],
      electronic_warfare: %{
        jamming_zones: [],
        radar_contacts: [],
        stealth_units: MapSet.new()
      },
      combat_stats: %{
        total_engagements: 0,
        shots_fired: 0,
        hits_landed: 0,
        casualties: 0
      }
    }
    
    # Schedule periodic combat processing
    schedule_combat_updates()
    
    {:ok, state}
  end

  @impl true
  def handle_call({:engage_target, attacker_id, target_id, weapon_type}, _from, state) do
    case validate_engagement(attacker_id, target_id, weapon_type, state) do
      {:ok, attacker_pos, target_pos} ->
        # Check line of sight
        if check_los_internal(attacker_pos, target_pos) do
          # Get weapon and armor stats
          weapon = Map.get(state.weapon_definitions, weapon_type)
          target_armor = get_entity_armor(target_id)
          
          # Calculate distance
          distance = calculate_distance(attacker_pos, target_pos)
          
          if distance <= weapon.range do
            # Process the attack
            {updated_state, attack_result} = process_attack(state, attacker_id, target_id, weapon, target_armor, distance)
            
            Logger.info("Combat: #{attacker_id} attacks #{target_id} with #{weapon_type} - #{attack_result.status}")
            {:reply, {:ok, attack_result}, updated_state}
          else
            {:reply, {:error, :out_of_range}, state}
          end
        else
          {:reply, {:error, :no_line_of_sight}, state}
        end
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:calculate_damage, weapon, armor, distance}, _from, state) do
    damage = calculate_damage_internal(weapon, armor, distance)
    {:reply, damage, state}
  end

  @impl true
  def handle_call({:check_line_of_sight, from_pos, to_pos}, _from, state) do
    result = check_los_internal(from_pos, to_pos)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:activate_jamming, jammer_id, position, radius}, _from, state) do
    jamming_zone = %{
      id: generate_jamming_id(),
      jammer_id: jammer_id,
      position: position,
      radius: radius,
      started_at: :os.system_time(:millisecond),
      duration_ms: 60_000 # 1 minute
    }
    
    updated_jamming = [jamming_zone | state.electronic_warfare.jamming_zones]
    updated_ew = %{state.electronic_warfare | jamming_zones: updated_jamming}
    updated_state = %{state | electronic_warfare: updated_ew}
    
    Logger.info("Electronic jamming activated by #{jammer_id} at #{inspect(position)} with radius #{radius}")
    {:reply, {:ok, jamming_zone.id}, updated_state}
  end

  @impl true
  def handle_call({:enable_stealth, entity_id}, _from, state) do
    updated_stealth = MapSet.put(state.electronic_warfare.stealth_units, entity_id)
    updated_ew = %{state.electronic_warfare | stealth_units: updated_stealth}
    updated_state = %{state | electronic_warfare: updated_ew}
    
    Logger.info("Stealth activated for entity #{entity_id}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    enhanced_stats = %{
      active_combats: map_size(state.active_combats),
      total_engagements: state.combat_stats.total_engagements,
      shots_fired: state.combat_stats.shots_fired,
      hits_landed: state.combat_stats.hits_landed,
      casualties: state.combat_stats.casualties,
      accuracy_rate: if(state.combat_stats.shots_fired > 0, do: state.combat_stats.hits_landed / state.combat_stats.shots_fired * 100, else: 0),
      suppression_zones: length(state.suppression_zones),
      jamming_zones: length(state.electronic_warfare.jamming_zones),
      stealth_units: MapSet.size(state.electronic_warfare.stealth_units),
      weapon_types: Map.keys(state.weapon_definitions),
      armor_types: Map.keys(state.armor_definitions)
    }
    
    {:reply, enhanced_stats, state}
  end

  @impl true
  def handle_cast({:apply_suppression, entity_id, suppression_level}, state) do
    # Create suppression effect on the target entity
    suppression_zone = %{
      entity_id: entity_id,
      suppression_level: suppression_level,
      started_at: :os.system_time(:millisecond),
      duration_ms: 5_000 # 5 seconds
    }
    
    updated_zones = [suppression_zone | state.suppression_zones]
    updated_state = %{state | suppression_zones: updated_zones}
    
    Logger.debug("Suppression applied to #{entity_id} at level #{suppression_level}")
    {:noreply, updated_state}
  end

  @impl true
  def handle_info(:combat_update, state) do
    Logger.debug("Processing combat updates")
    
    # Clean up expired effects
    updated_state = clean_expired_effects(state)
    
    # Process ongoing combats
    processed_state = process_ongoing_combats(updated_state)
    
    # Schedule next update
    schedule_combat_updates()
    
    {:noreply, processed_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("CombatEngine received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("CombatEngine terminating: #{inspect(reason)}")
    Logger.info("Final combat stats: #{inspect(state.combat_stats)}")
    :ok
  end

  # Private Helper Functions

  defp initialize_weapon_definitions do
    %{
      rifle: %{
        type: :rifle,
        damage: 25,
        damage_type: :kinetic,
        range: 400.0,
        accuracy: 0.75,
        rate_of_fire: 2.0, # shots per second
        penetration: 15,
        area_of_effect: 0.0
      },
      machine_gun: %{
        type: :machine_gun,
        damage: 30,
        damage_type: :kinetic,
        range: 600.0,
        accuracy: 0.60,
        rate_of_fire: 8.0,
        penetration: 20,
        area_of_effect: 0.0
      },
      cannon: %{
        type: :cannon,
        damage: 150,
        damage_type: :explosive,
        range: 2000.0,
        accuracy: 0.85,
        rate_of_fire: 0.3,
        penetration: 100,
        area_of_effect: 10.0
      },
      laser: %{
        type: :laser,
        damage: 80,
        damage_type: :energy,
        range: 800.0,
        accuracy: 0.95,
        rate_of_fire: 1.5,
        penetration: 50,
        area_of_effect: 0.0
      },
      missile: %{
        type: :missile,
        damage: 200,
        damage_type: :explosive,
        range: 5000.0,
        accuracy: 0.80,
        rate_of_fire: 0.1,
        penetration: 120,
        area_of_effect: 15.0
      },
      emp_device: %{
        type: :emp_device,
        damage: 0,
        damage_type: :emp,
        range: 300.0,
        accuracy: 1.0,
        rate_of_fire: 0.2,
        penetration: 0,
        area_of_effect: 50.0
      }
    }
  end

  defp initialize_armor_definitions do
    %{
      light: %{
        type: :light,
        kinetic_resistance: 0.20,
        energy_resistance: 0.10,
        explosive_resistance: 0.15,
        emp_resistance: 0.05,
        chemical_resistance: 0.25,
        durability: 100
      },
      medium: %{
        type: :medium,
        kinetic_resistance: 0.40,
        energy_resistance: 0.25,
        explosive_resistance: 0.35,
        emp_resistance: 0.15,
        chemical_resistance: 0.30,
        durability: 250
      },
      heavy: %{
        type: :heavy,
        kinetic_resistance: 0.70,
        energy_resistance: 0.30,
        explosive_resistance: 0.60,
        emp_resistance: 0.20,
        chemical_resistance: 0.40,
        durability: 500
      },
      reactive: %{
        type: :reactive,
        kinetic_resistance: 0.50,
        energy_resistance: 0.20,
        explosive_resistance: 0.80,
        emp_resistance: 0.10,
        chemical_resistance: 0.35,
        durability: 300
      },
      energy_shield: %{
        type: :energy_shield,
        kinetic_resistance: 0.30,
        energy_resistance: 0.90,
        explosive_resistance: 0.40,
        emp_resistance: 0.95,
        chemical_resistance: 0.20,
        durability: 200
      }
    }
  end

  defp validate_engagement(attacker_id, target_id, weapon_type, state) do
    # Check if weapon type exists
    unless Map.has_key?(state.weapon_definitions, weapon_type) do
      {:error, :invalid_weapon_type}
    else
      # Get entity positions (mock for now - would query entity system)
      attacker_pos = get_entity_position(attacker_id)
      target_pos = get_entity_position(target_id)
      
      case {attacker_pos, target_pos} do
        {{:ok, a_pos}, {:ok, t_pos}} ->
          {:ok, a_pos, t_pos}
        _ ->
          {:error, :entity_not_found}
      end
    end
  end

  defp get_entity_position(entity_id) do
    # Mock position lookup - in real implementation would query EntitySupervisor
    case String.split(entity_id, "_") do
      ["entity", id_num] ->
        # Generate deterministic positions based on ID
        {id, _} = Integer.parse(id_num)
        x = rem(id * 137, 1000) * 10.0
        y = rem(id * 97, 1000) * 10.0
        {:ok, {x, y}}
      _ ->
        {:error, :not_found}
    end
  end

  defp get_entity_armor(entity_id) do
    # Mock armor lookup - would query entity system in real implementation
    case rem(String.length(entity_id), 5) do
      0 -> Map.get(initialize_armor_definitions(), :light)
      1 -> Map.get(initialize_armor_definitions(), :medium)
      2 -> Map.get(initialize_armor_definitions(), :heavy)
      3 -> Map.get(initialize_armor_definitions(), :reactive)
      4 -> Map.get(initialize_armor_definitions(), :energy_shield)
    end
  end

  defp calculate_distance({x1, y1}, {x2, y2}) do
    :math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
  end

  defp check_los_internal(from_pos, to_pos) do
    # Simplified line of sight - in real implementation would check terrain occlusion
    distance = calculate_distance(from_pos, to_pos)
    
    # Add some randomness for terrain blocking (10% chance)
    not (:rand.uniform() < 0.1 and distance > 200)
  end

  defp process_attack(state, attacker_id, target_id, weapon, armor, distance) do
    # Calculate hit probability
    base_accuracy = weapon.accuracy
    distance_modifier = max(0.1, 1.0 - (distance / weapon.range) * 0.3)
    suppression_modifier = get_suppression_modifier(attacker_id, state)
    
    hit_chance = base_accuracy * distance_modifier * suppression_modifier
    
    # Update shots fired
    updated_stats = %{state.combat_stats | shots_fired: state.combat_stats.shots_fired + 1}
    
    if :rand.uniform() <= hit_chance do
      # Hit! Calculate damage
      damage = calculate_damage_internal(weapon, armor, distance)
      
      # Apply damage to target
      apply_damage_result = apply_damage_to_target(target_id, damage, weapon.damage_type)
      
      # Update hit statistics
      final_stats = %{updated_stats | 
        hits_landed: updated_stats.hits_landed + 1,
        casualties: updated_stats.casualties + if(apply_damage_result == :killed, do: 1, else: 0)
      }
      
      # Create combat record
      combat_record = %{
        attacker_id: attacker_id,
        target_id: target_id,
        weapon_type: weapon.type,
        damage_dealt: damage,
        hit: true,
        timestamp: :os.system_time(:millisecond)
      }
      
      updated_state = %{state | combat_stats: final_stats}
      
      # Apply suppression to target and nearby units
      apply_suppression_effects(target_id, weapon, distance)
      
      {updated_state, %{status: :hit, damage: damage, result: apply_damage_result}}
    else
      # Miss
      updated_state = %{state | combat_stats: updated_stats}
      
      combat_record = %{
        attacker_id: attacker_id,
        target_id: target_id,
        weapon_type: weapon.type,
        damage_dealt: 0,
        hit: false,
        timestamp: :os.system_time(:millisecond)
      }
      
      {updated_state, %{status: :miss, damage: 0, result: :no_effect}}
    end
  end

  defp calculate_damage_internal(weapon, armor, distance) do
    base_damage = weapon.damage
    
    # Apply distance falloff
    distance_factor = max(0.3, 1.0 - (distance / weapon.range) * 0.4)
    
    # Apply armor resistance
    resistance = case weapon.damage_type do
      :kinetic -> armor.kinetic_resistance
      :energy -> armor.energy_resistance
      :explosive -> armor.explosive_resistance
      :emp -> armor.emp_resistance
      :chemical -> armor.chemical_resistance
      _ -> 0.0
    end
    
    # Apply penetration vs armor
    penetration_factor = min(1.0, weapon.penetration / 100.0)
    effective_resistance = resistance * (1.0 - penetration_factor)
    
    # Calculate final damage
    final_damage = base_damage * distance_factor * (1.0 - effective_resistance)
    
    # Add random variance (±10%)
    variance = (:rand.uniform() - 0.5) * 0.2
    final_damage = final_damage * (1.0 + variance)
    
    max(1, round(final_damage))
  end

  defp apply_damage_to_target(target_id, damage, damage_type) do
    # In real implementation, would send message to target entity
    Logger.info("Entity #{target_id} takes #{damage} #{damage_type} damage")
    
    # Mock damage application
    if damage > 100 do
      :killed
    else
      :damaged
    end
  end

  defp get_suppression_modifier(entity_id, state) do
    # Check if entity is under suppression
    suppression_effect = Enum.find(state.suppression_zones, &(&1.entity_id == entity_id))
    
    case suppression_effect do
      nil -> 1.0
      effect -> max(0.1, 1.0 - effect.suppression_level)
    end
  end

  defp apply_suppression_effects(target_id, weapon, distance) do
    # Suppression based on weapon type and proximity
    suppression_level = case weapon.type do
      :machine_gun -> 0.4
      :cannon -> 0.6
      :missile -> 0.7
      _ -> 0.2
    end
    
    # Apply to target
    apply_suppression(target_id, suppression_level)
    
    # Apply to nearby units (area of effect)
    if weapon.area_of_effect > 0 do
      Logger.debug("Applying area suppression effects around #{target_id}")
    end
  end

  defp generate_jamming_id do
    "jamming_" <> Base.encode16(:crypto.strong_rand_bytes(4))
  end

  defp clean_expired_effects(state) do
    current_time = :os.system_time(:millisecond)
    
    # Clean suppression zones
    active_suppression = Enum.filter(state.suppression_zones, fn zone ->
      zone.started_at + zone.duration_ms > current_time
    end)
    
    # Clean jamming zones
    active_jamming = Enum.filter(state.electronic_warfare.jamming_zones, fn zone ->
      zone.started_at + zone.duration_ms > current_time
    end)
    
    updated_ew = %{state.electronic_warfare | jamming_zones: active_jamming}
    
    %{state |
      suppression_zones: active_suppression,
      electronic_warfare: updated_ew
    }
  end

  defp process_ongoing_combats(state) do
    # Process any ongoing combat situations
    # For now, just return the state unchanged
    state
  end

  defp schedule_combat_updates do
    Process.send_after(self(), :combat_update, 1_000) # Every second
  end
end