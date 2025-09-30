defmodule RealtimeStrategySim.Entity.EntitySupervisor do
  @moduledoc """
  Dynamic supervisor for managing thousands of entity actors in the RTS simulation.
  
  Features:
  - Automatic fault tolerance with supervisor restarts
  - Load balancing across BEAM schedulers  
  - Efficient spawning and termination of entities
  - Performance monitoring and statistics
  - Support for 50,000+ concurrent actors
  """
  
  use DynamicSupervisor
  require Logger
  alias RealtimeStrategySim.Entity.UnitActor

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts)
  end

  @spec spawn_unit(pid(), map()) :: {:ok, pid()} | {:error, term()}
  def spawn_unit(supervisor_pid, unit_spec) do
    child_spec = %{
      id: unit_spec.id,
      start: {UnitActor, :start_link, [unit_spec]},
      restart: :permanent,
      type: :worker
    }
    
    case DynamicSupervisor.start_child(supervisor_pid, child_spec) do
      {:ok, child_pid} ->
        Logger.debug("Spawned unit #{unit_spec.id} under supervisor")
        {:ok, child_pid}
        
      {:error, reason} ->
        Logger.error("Failed to spawn unit #{unit_spec.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec spawn_building(pid(), map()) :: {:ok, pid()} | {:error, term()}
  def spawn_building(supervisor_pid, building_spec) do
    # For now, use UnitActor for buildings too - in a full implementation
    # this would use a specialized BuildingActor
    building_spec_with_type = Map.put(building_spec, :type, :building)
    spawn_unit(supervisor_pid, building_spec_with_type)
  end

  @spec spawn_resource(pid(), map()) :: {:ok, pid()} | {:error, term()}
  def spawn_resource(supervisor_pid, resource_spec) do
    # For now, use UnitActor for resources too - in a full implementation
    # this would use a specialized ResourceActor
    resource_spec_with_type = Map.put(resource_spec, :type, :resource)
    spawn_unit(supervisor_pid, resource_spec_with_type)
  end

  @spec terminate_unit(pid(), String.t()) :: :ok | {:error, term()}
  def terminate_unit(supervisor_pid, unit_id) do
    # For now, find unit by iterating through children (less efficient but simpler)
    children = DynamicSupervisor.which_children(supervisor_pid)
    case find_child_by_id(children, unit_id) do
      {:ok, unit_pid} ->
        case DynamicSupervisor.terminate_child(supervisor_pid, unit_pid) do
          :ok ->
            Logger.info("Terminated unit #{unit_id}")
            :ok
          {:error, reason} ->
            Logger.error("Failed to terminate unit #{unit_id}: #{inspect(reason)}")
            {:error, reason}
        end
      {:error, :not_found} ->
        Logger.warning("Unit #{unit_id} not found for termination")
        {:error, :not_found}
    end
  end

  # Helper to find child by asking each unit for their ID
  defp find_child_by_id(children, target_id) do
    Enum.find_value(children, {:error, :not_found}, fn {_, pid, _, _} when is_pid(pid) ->
      try do
        case UnitActor.get_state(pid) do
          %{id: ^target_id} -> {:ok, pid}
          _ -> nil
        end
      rescue
        _ -> nil
      end
    end)
  end

  @spec get_stats(pid()) :: %{
    active_children: non_neg_integer(),
    supervisor_pid: pid(),
    memory_usage_kb: non_neg_integer()
  }
  def get_stats(supervisor_pid) do
    children = DynamicSupervisor.which_children(supervisor_pid)
    active_count = length(children)
    
    # Calculate memory usage for all child processes
    memory_usage = children
    |> Enum.map(fn {_, pid, _, _} when is_pid(pid) ->
      case Process.info(pid, :memory) do
        {:memory, mem} -> mem
        _ -> 0
      end
    end)
    |> Enum.sum()
    |> div(1024) # Convert to KB
    
    %{
      active_children: active_count,
      supervisor_pid: supervisor_pid, 
      memory_usage_kb: memory_usage
    }
  end

  @spec find_unit(pid(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find_unit(supervisor_pid, unit_id) do
    children = DynamicSupervisor.which_children(supervisor_pid)
    find_child_by_id(children, unit_id)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("EntitySupervisor started")
    
    # Configure for high-performance concurrent operations
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 5,
      max_children: 100_000 # Support up to 100K entities
    )
  end
end