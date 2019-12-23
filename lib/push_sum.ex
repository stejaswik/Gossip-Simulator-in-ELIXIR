defmodule Push_Sum_supervisor do
  use Supervisor

  def start_link(topology) do
    Supervisor.start_link(__MODULE__, topology)
  end

  def init(topology) do
    worker_list = Map.keys(topology)
    workers = length(worker_list)
    children = Enum.map(1..workers, fn(worker_id) ->
      worker(Push_Sum_nodes, [[worker_id] ++ [worker_id,1,worker_id,3] ++Map.get(topology,worker_id)], [id: worker_id, restart: :permanent])
    end)

    supervise(children, strategy: :one_for_one, name: Supervise_topology)
  end
end

defmodule Push_Sum_nodes do
  use GenServer

  def start_link(list) do
    GenServer.start_link(__MODULE__, list)
  end

  def init(stack) do
    {:ok, stack}
  end

  def send_msg(pid) do
    GenServer.cast(pid, :sendmsg)
  end

  def timely_send(pid) do
    #Gossip algorithm nodes keep sending message periodically
    Process.sleep(20)
    send_msg(pid)
  end

  def receive_msg(pid, s, w) do
    GenServer.cast(pid, {:receivemsg, s, w})
  end

  def update_neighbors(pid, id) do
    GenServer.cast(pid, {:update_neighbor, id})
  end

  def handle_cast(:sendmsg, stack) do
    if stack != [] do
      [worker_id, s, w, prev_ratio, count | list] = stack
      if length(list) > 0 do
        curr_ratio = s/w
        diff = abs(curr_ratio - prev_ratio)
        count = if diff > :math.pow(10,-10) do
                  count
                else
                  count - 1
                end
        s = s/2
        w = w/2
        stack = [worker_id, s, w, curr_ratio, count | list]
        #IO.inspect(stack)
        #IO.puts("worker: #{worker_id}, count: #{count}")
        if count <= 0 do
          #Save converged node id in Dispstore_ps state
          Dispstore_ps.save_node(worker_id)
          #IO.puts("terminate worker: #{worker_id}")
          #Update converged node's neighbors that it has terminated
          Store_pid_ps.update(worker_id, list)
          {:noreply, []}
        else
          index = Enum.random(0..length(list)-1)
          Store_pid_ps.receive(Enum.at(list,index),s,w)
          timely_send(self())
          {:noreply, stack}
        end
      else
        {:noreply, []}
      end
    else
      {:noreply, []}
    end
  end    
  def handle_cast({:receivemsg, add_s, add_w}, stack) do
    if stack != [] do
      [worker_id, s, w, prev_ratio, count | list] = stack
      s = s+add_s
      w = w+add_w
      #curr_ratio = s/w
      #IO.puts("Receive part: worker: #{worker_id}, count: #{count}, s: #{s}, w: #{w}")
      stack = [worker_id, s, w, prev_ratio, count | list]
      #keep passing message if count>0
      send_msg(self())
      {:noreply, stack}
    else
      {:noreply, []}
    end
  end

  def handle_cast({:update_neighbor,id}, stack) do
    if stack != [] do
      [worker_id, s, w, prev_ratio, count | list] = stack
      #Remove converged node id from list of neighbors and update state
      list = List.delete(list,id)
      stack = [worker_id, s, w, prev_ratio, count | list]
      #IO.inspect(stack)
      if length(list) > 0 do
        #if current node has other neighbors, update stack
        #IO.puts("update stack: #{worker_id}")
        {:noreply, stack}
      else
        #current node doesnot have any neighbors left after update, then terminate
        #IO.puts("terminate worker update part: #{worker_id}")
        Dispstore_ps.save_node(worker_id)
        {:noreply, []}
      end
    else
      {:noreply, []}
    end
  end
end

defmodule Store_pid_ps do
  use GenServer

  def start_link(stack) do
    GenServer.start_link(__MODULE__, stack, name: __MODULE__)
  end

  def init(stack) do
    start(stack)
    {:ok, stack}
  end

  def start(stack) do
    pid_first = List.first(stack)
    #pid_first = Enum.at(stack,25)
    #initiate gossip from first node
    Push_Sum_nodes.send_msg(pid_first)
    #nodes removed is always zero during initialization
    nodes_removed = 0 
    #start failure model 
    gossip_failure_model(nodes_removed)
  end

  def gossip_failure_model(nodes_removed) do
    GenServer.cast(__MODULE__, {:failure_model, nodes_removed})  
  end

  def receive(node,s,w) do
    GenServer.cast(__MODULE__, {:saveval, node, s, w})
  end

  def update(id, list) do
    update_list = List.flatten([id] ++ [list])
    GenServer.cast(__MODULE__, {:update_nodes, update_list})
  end

  def handle_cast({:failure_model, nodes_removed}, stack) do
    #Extract total nodes and nodes to be removed information from state
    nodes = length(stack) - 1
    remove_nodes = List.last(stack)
    if nodes_removed < remove_nodes do
      # add cases to handle different start values, helpful in case of line topology
      start = 1
      #start = round(nodes/3)
      node = Enum.random(start..nodes)
      #keep updating state value recursively for the nodes removed until nodes_removed == remove_nodes
      #every node removed should be unique
      if Enum.at(stack, node-1) == "kill" do
        gossip_failure_model(nodes_removed)
        {:noreply, stack}
      else
        #node_pid = Enum.at(stack, node-1) 
        stack = List.delete_at(stack, node-1)
        stack = List.insert_at(stack, node-1, "kill")
        gossip_failure_model(nodes_removed+1)
        {:noreply, stack}
      end
    else
      {:noreply, stack}
    end
  end

  def handle_cast({:saveval, node, s, w}, stack) do
    #Nodes will be able to receive message only when alive
      if Enum.at(stack,(node-1)) != "kill"  do
        #IO.puts("received: #{node}")
        #Process.sleep(1)
        Push_Sum_nodes.receive_msg(Enum.at(stack,(node-1)), s, w)
      end
    {:noreply, stack}
  end

  def handle_cast({:update_nodes, update_list}, stack) do
    [id | list] = update_list
    #send update about current nodes convergence to neighboring nodes who are alive
    #avoid sending updates to converged nodes
    if length(list) >= 1 do
      Enum.each(list, fn x-> if Enum.at(stack,x-1) != "kill" do
                                Push_Sum_nodes.update_neighbors(Enum.at(stack,x-1), id)
                                end 
                                end)
    end
    {:noreply, stack}
  end
end

defmodule Dispstore_ps do
  use GenServer

  def start_link(stack) do
    GenServer.start_link(__MODULE__, stack, name: __MODULE__)
  end

  def init(stack) do
    {:ok, stack}
  end

  def save_node(node) do
    GenServer.cast(__MODULE__, {:savenode, [node]})
  end

  def print() do
    GenServer.call(__MODULE__, :printval) 
  end

  def handle_cast({:savenode, list}, stack) do
    #keep adding converged nodes to existing state
    stack = List.flatten([list] ++ [stack])
    len = length(stack)

    #retrieve initialized convergence_rate, start_time values from stack
    convergence_rate = List.last(stack)
    start_time = Enum.at(stack, len-2)

    #compute time taken to converge everytime a node converges
    stop_time = System.system_time(:millisecond)
    curr_diff = stop_time - start_time

    #update state with current time difference everytime a node converges
    stack = List.delete_at(stack, len-3)
    stack = List.insert_at(stack, len-3, curr_diff)

    #No Failure: Donot exit until 100% convergence is achieved
    #Failure model: Exit once the user specified convergence_rate is achieved
    #A factor of 4 is added because the state "stack" is initialized with a 4-list
    if length(stack) >= convergence_rate+4 do
      parent_pid = Enum.at(stack, len-4)
      send(parent_pid, :work_is_done)
    end
    {:noreply, stack}
  end

  def handle_call(:printval, _from, stack) do
    {:reply, stack, stack}
  end
end

