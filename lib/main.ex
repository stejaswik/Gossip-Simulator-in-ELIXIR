defmodule Gossip_supervisor do
  use Supervisor

  def start_link(topology) do
    Supervisor.start_link(__MODULE__, topology)
  end

  def init(topology) do
    worker_list = Map.keys(topology)
    workers = length(worker_list)
    children = Enum.map(1..workers, fn(worker_id) ->
      worker(Gossip_nodes, [[worker_id] ++ [10] ++Map.get(topology,worker_id)], [id: worker_id, restart: :permanent])
    end)

    supervise(children, strategy: :one_for_one, name: Supervise_topology)
  end
end

defmodule Gossip_nodes do
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
    Process.sleep(10)
    send_msg(pid)
  end

  def receive_msg(pid) do
    GenServer.cast(pid, {:receivemsg, []})
  end

  def update_neighbors(pid, id) do
    GenServer.cast(pid, {:update_neighbor, id})
  end

  def handle_cast(:sendmsg, stack) do
    if stack != [] do
      [_worker_id | tail] = stack
      if length(tail) > 1 do
        [_count | list] = tail
        #will send message only if neighbors are present in list
        if length(list) > 0 do
          index = Enum.random(0..length(list)-1)
          #access Store_pid to get neighbors pid value, in order to send message
          #Store_pid has all children pids stored
          Store_pid.receive(Enum.at(list,index))
          timely_send(self())
          {:noreply, stack}
        else
          {:noreply, []}
        end
      else
        {:noreply, []}
      end
    else
      {:noreply, []}
    end
  end

  def handle_cast({:receivemsg, _val}, stack) do
    if stack != [] do
      [worker_id | tail] = stack
      if tail != [] do
        [count | list] = tail
        count = count-1
        stack = List.flatten([worker_id] ++ [count] ++ [list])
        if count <=0 do
          #Save converged node id in Dispstore state
          Dispstore.save_node(worker_id)
          #Update converged node's neighbors that it has terminated
          Store_pid.update(worker_id, list)
          {:noreply, []}
        else
          #keep passing message if count>0
          send_msg(self())
          {:noreply, stack}
        end
      else
        {:noreply, []}
      end
    else
      {:noreply, []}
    end
  end

  def handle_cast({:update_neighbor,id}, stack) do
    if stack != [] do
      [worker_id | tail] = stack
      if length(tail) >= 2 do
        [count | list] = tail
        #Remove converged node id from list of neighbors and update state
        list = list -- [id]
        stack = List.flatten([worker_id] ++ [count] ++ [list])
        if length(list) > 0 do
          #if current node has other neighbors, update stack
          {:noreply, stack}
        else
          #current node doesnot have any neighbors left after update, then terminate
          Dispstore.save_node(worker_id)
          {:noreply, []}
        end
      else
          {:noreply, []}
      end
    else
      {:noreply, []}
    end
  end
end

defmodule Store_pid do
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
    #initiate gossip from first node
    Gossip_nodes.send_msg(pid_first)
    #nodes removed is always zero during initialization
    nodes_removed = 0 
    #start failure model 
    gossip_failure_model(nodes_removed)
  end

  def gossip_failure_model(nodes_removed) do
    GenServer.cast(__MODULE__, {:failure_model, nodes_removed})  
  end

  def receive(node) do
    GenServer.cast(__MODULE__, {:saveval, node})
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

  def handle_cast({:saveval, node}, stack) do
    #Nodes will be able to receive message only when alive
      if Enum.at(stack,(node-1)) != "kill"  do
        Gossip_nodes.receive_msg(Enum.at(stack,(node-1)))
      end
    {:noreply, stack}
  end

  def handle_cast({:update_nodes, update_list}, stack) do
    [id | list] = update_list
    #send update about current nodes convergence to neighboring nodes who are alive
    #avoid sending updates to converged nodes
    if length(list) >= 1 do
      Enum.each(list, fn x-> if Enum.at(stack,x-1) != "kill" do
                                Gossip_nodes.update_neighbors(Enum.at(stack,x-1), id)
                                end 
                                end)
    end
    {:noreply, stack}
  end
end

defmodule Dispstore do
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

defmodule Topology do

def full_gossip(num) do

  #cli arguments for basic implementation: my_program numNodes topology algorithm 
  #cli arguments for failure model implementation: 
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor, 
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  #full topology
  l = for c<- 1..nodes, do: c
  m1 =  Enum.map(l, fn x-> {x,l -- [x]} end)
  map = Enum.into(m1, %{})

  {:ok, pid} = Gossip_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                40_000
              else
                10_000
              end
  #IO.puts("time wait- #{time_wait}")

  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes") 
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  #IO.puts("Total nodes - #{convergence_factor} nodes")
  #IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds") 

end

def full_push_sum(num) do
  #cli arguments for basic implementation: my_program numNodes topology algorithm 
  #cli arguments for failure model implementation: 
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor, 
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  #full topology
  l = for c<- 1..nodes, do: c
  m1 =  Enum.map(l, fn x-> {x,l -- [x]} end)
  map = Enum.into(m1, %{})
  {:ok, pid} = Push_Sum_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid_ps.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore_ps.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                40_000
              else
                10_000
              end


  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes") 
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore_ps.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  #IO.puts("Total nodes - #{convergence_factor} nodes")
  #IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds") 
end

def rand2D_gossip(num) do

  #cli arguments for basic implementation: my_program numNodes topology algorithm 
  #cli arguments for failure model implementation: 
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor, 
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  #rand2D topology
  y = num; # Rows
  x = 2; # Columns

  # Generate "y" random pairs of coordinates
  randpairs=1..y |> Enum.map(fn _ ->
    1..x |> Enum.map(fn _ ->
      (_y = Float.to_string(Float.ceil(:rand.uniform(),5)))
    end)
  end)

  r=List.flatten(randpairs)
  s=Enum.chunk_every(r, 2)
  t = for c <- 0..length(s)-1 do
          Enum.at(s, c) ++ [c+1]
      end

  map = %{}
  list2 = for a <- t do
    list = for b <- t do
      x1=String.to_float(Enum.at(a,0))
      y1=String.to_float(Enum.at(a,1))
      x2=String.to_float(Enum.at(b,0))
      y2=String.to_float(Enum.at(b,1))

      # Computing the distance between two coordinates,
      # A node is added as a neighbir if its distance from a
      # node is less than 0.1

      distance = (:math.sqrt(:math.pow((x2-x1),2)+:math.pow((y2-y1),2)))
      if distance <= 0.1 and distance != 0 do
        Map.put(map, Enum.at(a,2), Enum.at(b,2))
      else
        Map.put(map, Enum.at(a,2), [])
      end
    end

  l2 = Enum.filter(list, fn(x) -> x != nil end)
    if (l2 != []) do
      rmap=Enum.reduce(l2, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)
      val = Map.get(rmap, Enum.at(a,2))
      new_val = List.flatten([val]) 
      _rmap = Map.put(rmap, Enum.at(a,2), new_val)
    end  
  end

  l3 = Enum.filter(list2, fn(x) -> x != nil end)

  # Map containing the nodes and its neighbors
  map = if (l3 != []) do
    Enum.reduce(l3, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)
  end

  {:ok, pid} = Gossip_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                40_000
              else
                10_000
              end
  #IO.puts("time wait- #{time_wait}")

  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes") 
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  #IO.puts("Total nodes - #{convergence_factor} nodes")
  #IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds") 

end

def rand2D_push_sum(num) do
  #cli arguments for basic implementation: my_program numNodes topology algorithm 
  #cli arguments for failure model implementation: 
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor, 
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  #rand2D topology
  y = num; # Rows
  x = 2; # Columns

  # Generate "y" random pairs of coordinates
  randpairs=1..y |> Enum.map(fn _ ->
    1..x |> Enum.map(fn _ ->
      (_y = Float.to_string(Float.ceil(:rand.uniform(),5)))
    end)
  end)

  r=List.flatten(randpairs)
  s=Enum.chunk_every(r, 2)
  t = for c <- 0..length(s)-1 do
          Enum.at(s, c) ++ [c+1]
      end

  map = %{}
  list2 = for a <- t do
    list = for b <- t do
      x1=String.to_float(Enum.at(a,0))
      y1=String.to_float(Enum.at(a,1))
      x2=String.to_float(Enum.at(b,0))
      y2=String.to_float(Enum.at(b,1))

      # Computing the distance between two coordinates,
      # A node is added as a neighbir if its distance from a
      # node is less than 0.1

      distance = (:math.sqrt(:math.pow((x2-x1),2)+:math.pow((y2-y1),2)))
      if distance <= 0.1 and distance != 0 do
        Map.put(map, Enum.at(a,2), Enum.at(b,2))
      else
        Map.put(map, Enum.at(a,2), [])
      end
    end

  l2 = Enum.filter(list, fn(x) -> x != nil end)
    if (l2 != []) do
      rmap=Enum.reduce(l2, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)
      val = Map.get(rmap, Enum.at(a,2))
      new_val = List.flatten([val]) 
      _rmap = Map.put(rmap, Enum.at(a,2), new_val)
    end  
  end

  l3 = Enum.filter(list2, fn(x) -> x != nil end)

  # Map containing the nodes and its neighbors
  map = if (l3 != []) do
    Enum.reduce(l3, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)
  end


  {:ok, pid} = Push_Sum_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid_ps.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore_ps.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                40_000
              else
                10_000
              end


  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes") 
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore_ps.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  # IO.puts("Total nodes - #{convergence_factor} nodes")
  # IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds") 
  
end
  

def line_gossip(num) do

  #cli arguments for basic implementation: my_program numNodes topology algorithm 
  #cli arguments for failure model implementation: 
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor, 
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  # Line Topology
  # Mapping the nodes to their neighbors
  z=%{}
  z = for x <- 2..num-1 do
          Map.put(z, x, [x-1, x+1])
          end

  v = z ++ [%{1 => [2]}] ++ [%{num => [num-1]}]
  map = Enum.reduce(v, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)

  {:ok, pid} = Gossip_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                60_000
              else
                10_000
              end
  #IO.puts("time wait- #{time_wait}")

  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes") 
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  # IO.puts("Total nodes - #{convergence_factor} nodes")
  # IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds") 

end

def line_push_sum(num) do
  #cli arguments for basic implementation: my_program numNodes topology algorithm 
  #cli arguments for failure model implementation: 
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor, 
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  # Line Topology
  # Mapping the nodes to their neighbors
  z=%{}
  z = for x <- 2..num-1 do
          Map.put(z, x, [x-1, x+1])
          end

  v = z ++ [%{1 => [2]}] ++ [%{num => [num-1]}]
  map = Enum.reduce(v, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)

  {:ok, pid} = Push_Sum_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid_ps.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore_ps.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                60_000
              else
                10_000
              end


  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes") 
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore_ps.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  # IO.puts("Total nodes - #{convergence_factor} nodes")
  # IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds") 
end

def honeycomb_gossip(num) do

  #cli arguments for basic implementation: my_program numNodes topology algorithm 
  #cli arguments for failure model implementation: 
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor, 
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  # Honeycomb Topology
  square_root = round(:math.sqrt(num))
  num = if rem(square_root, 2) == 0 do
    _num = square_root + 1
  else
    _num = square_root
  end

  # Approximating the number of nodes to the nearest
  # square of odd number
  num = if num <5 do
    _num = 5
  else
    _num = num
  end
  num = num*num
  numstart = round(:math.sqrt(num))

  z=%{}

  #List of all the inner odd numbered nodes
  listodd=[]
  listodd = for x <- numstart+2..num-2 do
            lis = if rem(x,2) != 0 and (rem(x, numstart) != 0 or rem(x, numstart) != 1)do
              listodd ++ [x]
            end       
          lis
          end

  # List of all the inner even numbered nodes
  listeven=[]
  listeven = for x <- 2..num-numstart-2 do
            lis = if rem(x,2) == 0 and (rem(x,numstart) != 0 or rem(x, numstart) != 1) do
              listeven ++ [x]
            end       
          lis
          end

  # List of all the nodes at left edge of honeycomb
  lisleft=[]
  lisleft = for x <- 3..numstart-2 do
            lis = if rem(x,2) != 0 do
              lisleft ++ [x]
            end       
          lis
          end

  # List of all the nodes at right edge of honeycomb
  lisright = []
  lisright = for x <- num-numstart+2..num-1 do
            lis = if rem(x,2) == 0 do
              lisright ++ [x]
            end       
          lis
          end

  # List of odd numbered nodes on top edge
  listopodd = []
  listopodd = for x <- 2*numstart + 1..3*numstart+1 do
            lis = if rem(x,numstart) == 1 and rem(x,2) != 0 do
              listopodd ++ [x]
            end       
          lis
          end

  # List of even numbered nodes on top edge
  listopeven = []
  listopeven = for x <- numstart+1..num-2*numstart+1 do
            lis = if rem(x,numstart) == 1 and rem(x,2) == 0 do
              listopeven ++ [x]
            end       
          lis
          end

  # List of odd numbered nodes on bottom edge
  lisbotodd = []
  lisbotodd = for x <- 3*numstart..num-2*numstart do
            lis = if rem(x,numstart) ==0 and rem(x,2) != 0 do
              lisbotodd ++ [x]
            end       
          lis
          end

  # List of even numbered nodes on bottom edge
  lisboteven = []
  lisboteven = for x <- 2*numstart..num-numstart do
            lis = if rem(x,numstart) == 0 and rem(x,2) == 0 do
              lisboteven ++ [x]
            end       
          lis
          end

  list_teven = List.flatten(listeven) -- List.flatten(listopeven)
  list_teven = list_teven -- List.flatten(lisboteven)
  list_teven = list_teven -- List.flatten(listopeven)

  list_todd = List.flatten(listodd) -- List.flatten(listopodd)
  list_todd = list_todd -- List.flatten(lisbotodd)
  list_todd = list_todd -- List.flatten(lisright)
  list_todd = list_todd -- [num - numstart +  1]

  list_odd = List.flatten(Enum.filter(list_todd, & &1 != nil))
  list_even = List.flatten(Enum.filter(list_teven, & &1 != nil))
  list_left = List.flatten(Enum.filter(lisleft, & &1 != nil))
  list_right = List.flatten(Enum.filter(lisright, & &1 != nil))
  list_top_odd = List.flatten(Enum.filter(listopodd, & &1 != nil))
  list_top_even = List.flatten(Enum.filter(listopeven, & &1 != nil))
  list_bot_odd = List.flatten(Enum.filter(lisbotodd, & &1 != nil))
  list_bot_even = List.flatten(Enum.filter(lisboteven, & &1 != nil))

  list_top_odd = list_top_odd -- list_right

  # Mapping the inner odd nodes to the neighbors
  z = for x <- 0..length(list_odd)-1 do
          y = Enum.at(list_odd, x)
          Map.put(z, y, [y-1, y+1, y-numstart])
          end

  # Mapping the inner even nodes to the neighbors
  z1=%{}
  z1 = for x <- 0..length(list_even)-1 do
          y = Enum.at(list_even, x)
          Map.put(z1, y, [y-1, y+1, y+numstart])
          end

  # Mapping the left edge nodes to the neighbors
  z2=%{}
  z2 = for x <- 0..length(list_left)-1 do
          y = Enum.at(list_left, x)
          Map.put(z2, y, [y-1, y+1])
          end

  # Mapping the right edge nodes to the neighbors
  z3=%{}
  z3 = for x <- 0..length(list_right)-1 do
          y = Enum.at(list_right, x)
          Map.put(z3, y, [y-1, y+1])
          end

  # Mapping the top edge odd nodes to the neighbors
  z4=%{}
  z4 = for x <- 0..length(list_top_odd)-1 do
          y = Enum.at(list_top_odd, x)
          Map.put(z4, y, [y-numstart, y+1])
          end

  # Mapping the top edge even nodes to the neighbors
  z5=%{}
  z5 = for x <- 0..length(list_top_even)-1 do
          y = Enum.at(list_top_even, x)
          Map.put(z5, y, [y+1, y+numstart])
          end

  # Mapping the bottom edge odd nodes to the neighbors
  z6=%{}
  z6 = for x <- 0..length(list_bot_odd)-1 do
          y = Enum.at(list_bot_odd, x)
          Map.put(z6, y, [y-1, y-numstart])
          end

  # Mapping the bottom edge even nodes to the neighbors
  z7=%{}
  z7 = for x <- 0..length(list_bot_even)-1 do
          y = Enum.at(list_bot_even, x)
          Map.put(z7, y, [y-1, y+numstart])
          end

  # Mapping the corner nodes to their neighbors
  z = z ++ [%{1 => [2]}]
  z = z ++ [%{numstart => [numstart - 1]}]
  z = z ++ [%{num => [num - 1, num - numstart]}]

  x = num - numstart + 1
  z = z ++ [%{x => [x + 1, x - numstart]}]

  map = Enum.sort(z ++ z1 ++ z2 ++ z3 ++ z4 ++ z5 ++ z6 ++ z7)
  map = Enum.reduce(map, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)

  {:ok, pid} = Gossip_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]

  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                40_000
              else
                10_000
              end
  #IO.puts("time wait- #{time_wait}")

  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes") 
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  # IO.puts("Total nodes - #{convergence_factor} nodes")
  # IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds") 

end

def honeycomb_push_sum(num) do
  #cli arguments for basic implementation: my_program numNodes topology algorithm 
  #cli arguments for failure model implementation: 
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor, 
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  # Honeycomb Topology
  square_root = round(:math.sqrt(num))
  num = if rem(square_root, 2) == 0 do
    _num = square_root + 1
  else
    _num = square_root
  end

  # Approximating the number of nodes to the nearest
  # square of odd number
  num = if num <5 do
    _num = 5
  else
    _num = num
  end
  num = num*num
  numstart = round(:math.sqrt(num))

  z=%{}

  #List of all the inner odd numbered nodes
  listodd=[]
  listodd = for x <- numstart+2..num-2 do
            lis = if rem(x,2) != 0 and (rem(x, numstart) != 0 or rem(x, numstart) != 1)do
              listodd ++ [x]
            end       
          lis
          end

  # List of all the inner even numbered nodes
  listeven=[]
  listeven = for x <- 2..num-numstart-2 do
            lis = if rem(x,2) == 0 and (rem(x,numstart) != 0 or rem(x, numstart) != 1) do
              listeven ++ [x]
            end       
          lis
          end

  # List of all the nodes at left edge of honeycomb
  lisleft=[]
  lisleft = for x <- 3..numstart-2 do
            lis = if rem(x,2) != 0 do
              lisleft ++ [x]
            end       
          lis
          end

  # List of all the nodes at right edge of honeycomb
  lisright = []
  lisright = for x <- num-numstart+2..num-1 do
            lis = if rem(x,2) == 0 do
              lisright ++ [x]
            end       
          lis
          end

  # List of odd numbered nodes on top edge
  listopodd = []
  listopodd = for x <- 2*numstart + 1..3*numstart+1 do
            lis = if rem(x,numstart) == 1 and rem(x,2) != 0 do
              listopodd ++ [x]
            end       
          lis
          end

  # List of even numbered nodes on top edge
  listopeven = []
  listopeven = for x <- numstart+1..num-2*numstart+1 do
            lis = if rem(x,numstart) == 1 and rem(x,2) == 0 do
              listopeven ++ [x]
            end       
          lis
          end

  # List of odd numbered nodes on bottom edge
  lisbotodd = []
  lisbotodd = for x <- 3*numstart..num-2*numstart do
            lis = if rem(x,numstart) ==0 and rem(x,2) != 0 do
              lisbotodd ++ [x]
            end       
          lis
          end

  # List of even numbered nodes on bottom edge
  lisboteven = []
  lisboteven = for x <- 2*numstart..num-numstart do
            lis = if rem(x,numstart) == 0 and rem(x,2) == 0 do
              lisboteven ++ [x]
            end       
          lis
          end

  list_teven = List.flatten(listeven) -- List.flatten(listopeven)
  list_teven = list_teven -- List.flatten(lisboteven)
  list_teven = list_teven -- List.flatten(listopeven)

  list_todd = List.flatten(listodd) -- List.flatten(listopodd)
  list_todd = list_todd -- List.flatten(lisbotodd)
  list_todd = list_todd -- List.flatten(lisright)
  list_todd = list_todd -- [num - numstart +  1]

  list_odd = List.flatten(Enum.filter(list_todd, & &1 != nil))
  list_even = List.flatten(Enum.filter(list_teven, & &1 != nil))
  list_left = List.flatten(Enum.filter(lisleft, & &1 != nil))
  list_right = List.flatten(Enum.filter(lisright, & &1 != nil))
  list_top_odd = List.flatten(Enum.filter(listopodd, & &1 != nil))
  list_top_even = List.flatten(Enum.filter(listopeven, & &1 != nil))
  list_bot_odd = List.flatten(Enum.filter(lisbotodd, & &1 != nil))
  list_bot_even = List.flatten(Enum.filter(lisboteven, & &1 != nil))

  list_top_odd = list_top_odd -- list_right

  # Mapping the inner odd nodes to the neighbors
  z = for x <- 0..length(list_odd)-1 do
          y = Enum.at(list_odd, x)
          Map.put(z, y, [y-1, y+1, y-numstart])
          end

  # Mapping the inner even nodes to the neighbors
  z1=%{}
  z1 = for x <- 0..length(list_even)-1 do
          y = Enum.at(list_even, x)
          Map.put(z1, y, [y-1, y+1, y+numstart])
          end

  # Mapping the left edge nodes to the neighbors
  z2=%{}
  z2 = for x <- 0..length(list_left)-1 do
          y = Enum.at(list_left, x)
          Map.put(z2, y, [y-1, y+1])
          end

  # Mapping the right edge nodes to the neighbors
  z3=%{}
  z3 = for x <- 0..length(list_right)-1 do
          y = Enum.at(list_right, x)
          Map.put(z3, y, [y-1, y+1])
          end

  # Mapping the top edge odd nodes to the neighbors
  z4=%{}
  z4 = for x <- 0..length(list_top_odd)-1 do
          y = Enum.at(list_top_odd, x)
          Map.put(z4, y, [y-numstart, y+1])
          end

  # Mapping the top edge even nodes to the neighbors
  z5=%{}
  z5 = for x <- 0..length(list_top_even)-1 do
          y = Enum.at(list_top_even, x)
          Map.put(z5, y, [y+1, y+numstart])
          end

  # Mapping the bottom edge odd nodes to the neighbors
  z6=%{}
  z6 = for x <- 0..length(list_bot_odd)-1 do
          y = Enum.at(list_bot_odd, x)
          Map.put(z6, y, [y-1, y-numstart])
          end

  # Mapping the bottom edge even nodes to the neighbors
  z7=%{}
  z7 = for x <- 0..length(list_bot_even)-1 do
          y = Enum.at(list_bot_even, x)
          Map.put(z7, y, [y-1, y+numstart])
          end

  # Mapping the corner nodes to their neighbors
  z = z ++ [%{1 => [2]}]
  z = z ++ [%{numstart => [numstart - 1]}]
  z = z ++ [%{num => [num - 1, num - numstart]}]

  x = num - numstart + 1
  z = z ++ [%{x => [x + 1, x - numstart]}]

  map = Enum.sort(z ++ z1 ++ z2 ++ z3 ++ z4 ++ z5 ++ z6 ++ z7)
  map = Enum.reduce(map, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)

  {:ok, pid} = Push_Sum_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid_ps.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore_ps.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                40_000
              else
                10_000
              end


  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes") 
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore_ps.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  # IO.puts("Total nodes - #{convergence_factor} nodes")
  # IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds") 
end

def honeycombrand_gossip(num) do

  #cli arguments for basic implementation: my_program numNodes topology algorithm
  #cli arguments for failure model implementation:
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor,
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  #honeycombrand topology

square_root = round(:math.sqrt(num))
num = if rem(square_root, 2) == 0 do
  _num = square_root + 1
else
  _num = square_root
end

# Approximating the number of nodes to the nearest
# square of odd number
num = if num <5 do
  _num = 5
else
  _num = num
end
num = num*num
numstart = round(:math.sqrt(num))

z=%{}

#List of all the inner odd numbered nodes
listodd=[]
listodd = for x <- numstart+2..num-2 do
          lis = if rem(x,2) != 0 and (rem(x, numstart) != 0 or rem(x, numstart) != 1)do
            listodd ++ [x]
          end       
        lis
        end

# List of all the inner even numbered nodes
listeven=[]
listeven = for x <- 2..num-numstart-2 do
          lis = if rem(x,2) == 0 and (rem(x,numstart) != 0 or rem(x, numstart) != 1) do
            listeven ++ [x]
          end       
        lis
        end

# List of all the nodes at left edge of honeycomb
lisleft=[]
lisleft = for x <- 3..numstart-2 do
          lis = if rem(x,2) != 0 do
            lisleft ++ [x]
          end       
        lis
        end

# List of all the nodes at right edge of honeycomb
lisright = []
lisright = for x <- num-numstart+2..num-1 do
          lis = if rem(x,2) == 0 do
            lisright ++ [x]
          end       
        lis
        end

# List of odd numbered nodes on top edge
listopodd = []
listopodd = for x <- 2*numstart + 1..3*numstart+1 do
          lis = if rem(x,numstart) == 1 and rem(x,2) != 0 do
            listopodd ++ [x]
          end       
        lis
        end

# List of even numbered nodes on top edge
listopeven = []
listopeven = for x <- numstart+1..num-2*numstart+1 do
          lis = if rem(x,numstart) == 1 and rem(x,2) == 0 do
            listopeven ++ [x]
          end       
        lis
        end

# List of odd numbered nodes on bottom edge
lisbotodd = []
lisbotodd = for x <- 3*numstart..num-2*numstart do
          lis = if rem(x,numstart) ==0 and rem(x,2) != 0 do
            lisbotodd ++ [x]
          end       
        lis
        end

# List of even numbered nodes on bottom edge
lisboteven = []
lisboteven = for x <- 2*numstart..num-numstart do
          lis = if rem(x,numstart) == 0 and rem(x,2) == 0 do
            lisboteven ++ [x]
          end       
        lis
        end

list_teven = List.flatten(listeven) -- List.flatten(listopeven)
list_teven = list_teven -- List.flatten(lisboteven)
list_teven = list_teven -- List.flatten(listopeven)

list_todd = List.flatten(listodd) -- List.flatten(listopodd)
list_todd = list_todd -- List.flatten(lisbotodd)
list_todd = list_todd -- List.flatten(lisright)
list_todd = list_todd -- [num - numstart +  1]

list_odd = List.flatten(Enum.filter(list_todd, & &1 != nil))
list_even = List.flatten(Enum.filter(list_teven, & &1 != nil))
list_left = List.flatten(Enum.filter(lisleft, & &1 != nil))
list_right = List.flatten(Enum.filter(lisright, & &1 != nil))
list_top_odd = List.flatten(Enum.filter(listopodd, & &1 != nil))
list_top_even = List.flatten(Enum.filter(listopeven, & &1 != nil))
list_bot_odd = List.flatten(Enum.filter(lisbotodd, & &1 != nil))
list_bot_even = List.flatten(Enum.filter(lisboteven, & &1 != nil))

list_top_odd = list_top_odd -- list_right

# Mapping the inner odd nodes to the neighbors
z = for x <- 0..length(list_odd)-1 do
        y = Enum.at(list_odd, x)
        Map.put(z, y, [y-1, y+1, y-numstart])
        end

# Mapping the inner even nodes to the neighbors
z1=%{}
z1 = for x <- 0..length(list_even)-1 do
        y = Enum.at(list_even, x)
        Map.put(z1, y, [y-1, y+1, y+numstart])
        end

# Mapping the left edge nodes to the neighbors
z2=%{}
z2 = for x <- 0..length(list_left)-1 do
        y = Enum.at(list_left, x)
        Map.put(z2, y, [y-1, y+1])
        end

# Mapping the right edge nodes to the neighbors
z3=%{}
z3 = for x <- 0..length(list_right)-1 do
        y = Enum.at(list_right, x)
        Map.put(z3, y, [y-1, y+1])
        end

# Mapping the top edge odd nodes to the neighbors
z4=%{}
z4 = for x <- 0..length(list_top_odd)-1 do
        y = Enum.at(list_top_odd, x)
        Map.put(z4, y, [y-numstart, y+1])
        end

# Mapping the top edge even nodes to the neighbors
z5=%{}
z5 = for x <- 0..length(list_top_even)-1 do
        y = Enum.at(list_top_even, x)
        Map.put(z5, y, [y+1, y+numstart])
        end

# Mapping the bottom edge odd nodes to the neighbors
z6=%{}
z6 = for x <- 0..length(list_bot_odd)-1 do
        y = Enum.at(list_bot_odd, x)
        Map.put(z6, y, [y-1, y-numstart])
        end

# Mapping the bottom edge even nodes to the neighbors
z7=%{}
z7 = for x <- 0..length(list_bot_even)-1 do
        y = Enum.at(list_bot_even, x)
        Map.put(z7, y, [y-1, y+numstart])
        end

# Mapping the corner nodes to their neighbors
z = z ++ [%{1 => [2]}]
z = z ++ [%{numstart => [numstart - 1]}]
z = z ++ [%{num => [num - 1, num - numstart]}]

x = num - numstart + 1
z = z ++ [%{x => [x + 1, x - numstart]}]

map = Enum.sort(z ++ z1 ++ z2 ++ z3 ++ z4 ++ z5 ++ z6 ++ z7)
map = Enum.reduce(map, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)

  {:ok, pid} = Gossip_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                40_000
              else
                10_000
              end
  #IO.puts("time wait- #{time_wait}")

  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes")
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  # IO.puts("Total nodes - #{convergence_factor} nodes")
  # IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds")

end

def honeycombrand_push_sum(num) do
  #cli arguments for basic implementation: my_program numNodes topology algorithm
  #cli arguments for failure model implementation:
  #my_program numNodes topology algorithm remove_nodes convergence_factor

  nodes = num
  convergence_factor = nodes

  #Note: There are only 2 scenarios possible:
  #case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
  #case 2: gossip stops before reaching convergence_factor,
  #case 2 what happens during failure node implementation

  #Basic implementation: remove_node is specified as below, as there are zero failure nodes
  #remove_nodes = 0

  #Bonus part implementation: remove_nodes values are modified and observations are made
  remove_nodes = 10

  #honeycombrand topology

square_root = round(:math.sqrt(num))
num = if rem(square_root, 2) == 0 do
  _num = square_root + 1
else
  _num = square_root
end

# Approximating the number of nodes to the nearest
# square of odd number
num = if num <5 do
  _num = 5
else
  _num = num
end
num = num*num
numstart = round(:math.sqrt(num))

z=%{}

#List of all the inner odd numbered nodes
listodd=[]
listodd = for x <- numstart+2..num-2 do
          lis = if rem(x,2) != 0 and (rem(x, numstart) != 0 or rem(x, numstart) != 1)do
            listodd ++ [x]
          end       
        lis
        end

# List of all the inner even numbered nodes
listeven=[]
listeven = for x <- 2..num-numstart-2 do
          lis = if rem(x,2) == 0 and (rem(x,numstart) != 0 or rem(x, numstart) != 1) do
            listeven ++ [x]
          end       
        lis
        end

# List of all the nodes at left edge of honeycomb
lisleft=[]
lisleft = for x <- 3..numstart-2 do
          lis = if rem(x,2) != 0 do
            lisleft ++ [x]
          end       
        lis
        end

# List of all the nodes at right edge of honeycomb
lisright = []
lisright = for x <- num-numstart+2..num-1 do
          lis = if rem(x,2) == 0 do
            lisright ++ [x]
          end       
        lis
        end

# List of odd numbered nodes on top edge
listopodd = []
listopodd = for x <- 2*numstart + 1..3*numstart+1 do
          lis = if rem(x,numstart) == 1 and rem(x,2) != 0 do
            listopodd ++ [x]
          end       
        lis
        end

# List of even numbered nodes on top edge
listopeven = []
listopeven = for x <- numstart+1..num-2*numstart+1 do
          lis = if rem(x,numstart) == 1 and rem(x,2) == 0 do
            listopeven ++ [x]
          end       
        lis
        end

# List of odd numbered nodes on bottom edge
lisbotodd = []
lisbotodd = for x <- 3*numstart..num-2*numstart do
          lis = if rem(x,numstart) ==0 and rem(x,2) != 0 do
            lisbotodd ++ [x]
          end       
        lis
        end

# List of even numbered nodes on bottom edge
lisboteven = []
lisboteven = for x <- 2*numstart..num-numstart do
          lis = if rem(x,numstart) == 0 and rem(x,2) == 0 do
            lisboteven ++ [x]
          end       
        lis
        end

list_teven = List.flatten(listeven) -- List.flatten(listopeven)
list_teven = list_teven -- List.flatten(lisboteven)
list_teven = list_teven -- List.flatten(listopeven)

list_todd = List.flatten(listodd) -- List.flatten(listopodd)
list_todd = list_todd -- List.flatten(lisbotodd)
list_todd = list_todd -- List.flatten(lisright)
list_todd = list_todd -- [num - numstart +  1]

list_odd = List.flatten(Enum.filter(list_todd, & &1 != nil))
list_even = List.flatten(Enum.filter(list_teven, & &1 != nil))
list_left = List.flatten(Enum.filter(lisleft, & &1 != nil))
list_right = List.flatten(Enum.filter(lisright, & &1 != nil))
list_top_odd = List.flatten(Enum.filter(listopodd, & &1 != nil))
list_top_even = List.flatten(Enum.filter(listopeven, & &1 != nil))
list_bot_odd = List.flatten(Enum.filter(lisbotodd, & &1 != nil))
list_bot_even = List.flatten(Enum.filter(lisboteven, & &1 != nil))

list_top_odd = list_top_odd -- list_right

# Mapping the inner odd nodes to the neighbors
z = for x <- 0..length(list_odd)-1 do
        y = Enum.at(list_odd, x)
        Map.put(z, y, [y-1, y+1, y-numstart])
        end

# Mapping the inner even nodes to the neighbors
z1=%{}
z1 = for x <- 0..length(list_even)-1 do
        y = Enum.at(list_even, x)
        Map.put(z1, y, [y-1, y+1, y+numstart])
        end

# Mapping the left edge nodes to the neighbors
z2=%{}
z2 = for x <- 0..length(list_left)-1 do
        y = Enum.at(list_left, x)
        Map.put(z2, y, [y-1, y+1])
        end

# Mapping the right edge nodes to the neighbors
z3=%{}
z3 = for x <- 0..length(list_right)-1 do
        y = Enum.at(list_right, x)
        Map.put(z3, y, [y-1, y+1])
        end

# Mapping the top edge odd nodes to the neighbors
z4=%{}
z4 = for x <- 0..length(list_top_odd)-1 do
        y = Enum.at(list_top_odd, x)
        Map.put(z4, y, [y-numstart, y+1])
        end

# Mapping the top edge even nodes to the neighbors
z5=%{}
z5 = for x <- 0..length(list_top_even)-1 do
        y = Enum.at(list_top_even, x)
        Map.put(z5, y, [y+1, y+numstart])
        end

# Mapping the bottom edge odd nodes to the neighbors
z6=%{}
z6 = for x <- 0..length(list_bot_odd)-1 do
        y = Enum.at(list_bot_odd, x)
        Map.put(z6, y, [y-1, y-numstart])
        end

# Mapping the bottom edge even nodes to the neighbors
z7=%{}
z7 = for x <- 0..length(list_bot_even)-1 do
        y = Enum.at(list_bot_even, x)
        Map.put(z7, y, [y-1, y+numstart])
        end

# Mapping the corner nodes to their neighbors
z = z ++ [%{1 => [2]}]
z = z ++ [%{numstart => [numstart - 1]}]
z = z ++ [%{num => [num - 1, num - numstart]}]

x = num - numstart + 1
z = z ++ [%{x => [x + 1, x - numstart]}]

map = Enum.sort(z ++ z1 ++ z2 ++ z3 ++ z4 ++ z5 ++ z6 ++ z7)
map = Enum.reduce(map, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)

#IO.inspect map , charlists: false

n = num-1
m = round(n/2)

# Making unique pairs of random neighbors 
l1 = Enum.shuffle(Enum.to_list(1..m))
l2 = Enum.shuffle(Enum.to_list((m+1)..n))

l3=[]
l3 = for x<-0..length(l1)-1 do
  _l3 = l3 ++ [Enum.at(l1, x)] ++ [Enum.at(l2, x)]
end

m1=%{}

# Adding the random node

m1 = for val <-0..length(l3)-1 do
  lis = Enum.at(l3, val)

  val1 = List.first(lis)
  val2 = List.last(lis)
 
  x1 = Map.get(map, val1)

    y1 = x1 ++ [val2]

  Map.put(m1, val1, y1)

    end

m2=%{}
m2 = for val <-0..length(l3)-1 do
  lis = Enum.at(l3, val)

    val1 = List.first(lis)
  val2 = List.last(lis)

    x2 = Map.get(map, val2) 

    y2 = x2 ++ [val1]

  m2 = Map.put(m2, val2, y2)
  Map.put(m2, val2, y2)

    end

m = m1 ++ m2

m = m ++ [%{num => [num+1]}]
m = m ++ [%{num+1 => [num]}]

map = Enum.reduce(m, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)


  {:ok, pid} = Push_Sum_supervisor.start_link(map)

  #get supervisor children
  c = Supervisor.which_children(pid)
  c = Enum.sort(c)
  len = length(c)-1

  #create worker nodes pid's list
  pid_list = for i <- 0..len do
    head = Enum.at(c,i)
    h_list = Tuple.to_list(head)
    Enum.at(h_list,1)
  end

  #note time before starting algorithm
  start = System.system_time(:millisecond)
  diff = 0

  #send pid list of all nodes as argument
  pid_list = pid_list ++ [remove_nodes]
  {:ok, _pid} = Store_pid_ps.start_link(pid_list)

  #create a list consisting of current pid and start time
  parent = self()
  quit = [parent]++[diff]++[start]++[convergence_factor]


  #send the above created list to Dispstore so that it knows when to quit
  Task.start_link(fn ->
    Dispstore_ps.start_link(quit)
  end)

  time_wait = if remove_nodes == 0 do
                40_000
              else
                10_000
              end


  #Quit storing when we reach required convergence, otherwise wait till default time
  receive do
    :work_is_done -> :ok
  after
    # Optional timeout
    time_wait -> :timeout
  end

  #Print number of failed nodes
  if remove_nodes>0 do
    IO.puts("Number of failed nodes - #{remove_nodes} nodes")
  end

  #converged nodes are stored in Dispstore state
  list = Dispstore_ps.print()
  length_list = length(list)

  #Nodes converged and quit list parameters are stored in Dispstore state
  #nodes_converged = length_list - 4

  # IO.puts("Total nodes - #{convergence_factor} nodes")
  # IO.puts("Achieved convergence - #{nodes_converged} nodes")

  #time diff is being stored in Dispstore state after every node converges
  time_diff = Enum.at(list, length_list-3)
  IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds")
end
end

defmodule Torus3D do

def torus3D_gossip(num) do

#cli arguments for basic implementation: my_program numNodes topology algorithm
#cli arguments for failure model implementation:
#my_program numNodes topology algorithm remove_nodes convergence_factor

nodes = num
convergence_factor = nodes

#Note: There are only 2 scenarios possible:
#case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
#case 2: gossip stops before reaching convergence_factor,
#case 2 what happens during failure node implementation

#Basic implementation: remove_node is specified as below, as there are zero failure nodes
#remove_nodes = 0

#Bonus part implementation: remove_nodes values are modified and observations are made
remove_nodes = 10

x = cube_root(num, 2)
numstart = trunc(x)

# Approximating the number of nodes to nearest cube
num = numstart*numstart*numstart

# List of all nodes
list_all = Enum.to_list(1..num)

z=%{}
# List of inner nodes having 6 neighbors each
listinner=[]
listinner = for x <- numstart+2..num-numstart do
  _lis = if rem(x, numstart) != 1 and rem(x, numstart) !=0 do
     listinner ++ [x]
  end
end

# List of nodes at outer top edge of the cube
listoutertop=[]
n = numstart*numstart*(numstart-1) + 1
listoutertop = for x <- n..n+numstart-1 do
  _lis = listoutertop ++ [x]
  end

# List of nodes at top back edge of the cube
listoutertop1=[]
n = numstart*numstart*(numstart-1) + 1
listoutertop1 = for x<-n..n+numstart-1  do
  _lis = listoutertop1 ++ [x + (numstart*numstart - numstart)]
end

# List of nodes at bottom front edge of the cube 
listouterbot=[]
listouterbot = for x <- 1..numstart do
  _lis = listouterbot ++ [x]
  end

# List of nodes at bottom back edge of the cube
listouterbot1=[]
listouterbot1 = for x <- 1..numstart do
  _lis = listouterbot1 ++ [x + (numstart*numstart - numstart)]
  end

# List of nodes at bottom left side edge of the cube
listsidebot=[]
n = numstart*(numstart-2)
listsidebot = for x <- numstart..n do
  _lis = if rem(x, numstart) == 0 do
  listsidebot ++ [x + 1]
      end
  end

# List of nodes at bottom right side edge of the cube
listsidebot1=[]
listsidebot1 = for x<- numstart+1..numstart*numstart-1 do
  _lis = if rem(x, numstart) == 0 do
    listsidebot1 ++ [x]
  end
end

# List of nodes at top left side edge of the cube
listsidetop=[]
n = numstart*numstart*(numstart-1) + numstart + 1
listsidetop = for x<- n..num-numstart do
  _lis = if rem(x, numstart) == 1 do
    listsidetop ++ [x]
  end
end

# List of nodes at top right side edge of the cube
listsidetop1=[]
n = numstart*numstart*(numstart-1) + numstart + 1
listsidetop1 = for x<- n..num-numstart do
  _lis = if rem(x, numstart) == 0 do
    listsidetop1 ++ [x]
  end
end

# List of nodes at front left vertical edge
listvert1=[]
n = numstart*numstart*(numstart-1)
listvert1 = for x<- numstart..n do
  _lis = if rem(x, numstart*numstart) == 1 do
    listvert1 ++ [x]
  end
end

# List of nodes at front right vertical edge
listvert2=[]
n = numstart*numstart*(numstart-1)
listvert2 = for x<- numstart+1..n do
  _lis = if rem(x, numstart*numstart) == 1 do
    listvert2 ++ [x + numstart - 1 ]
  end
end

# List of nodes at back left vertical edge
listvert3=[]
listvert3 = for x<- numstart*numstart+1..numstart*numstart*(numstart-1) do
  _lis = if rem(x, numstart*numstart) == 0 do
    listvert3 ++ [x - (numstart - 1)]
  end
end

# List of nodes at back right vertical edge
listvert4=[]
listvert4 = for x<- numstart*numstart + 1..numstart*numstart*(numstart-1) do
  _lis = if rem(x, numstart*numstart) == 0 do
    listvert4 ++ [x]
  end
end

# List of nodes at left surface
list_surface1=[]
list_surface1 = for x<- 2..numstart-1 do
  _lis = for y<- 1..numstart-2 do
    _list_surface1 = list_surface1 ++ [x + y*numstart*numstart]
  end
end

# List of nodes at right surface
list_surface2=[]
a = 2 + numstart*(numstart-1)
list_surface2 = for x<- a..a+numstart-3 do
  _lis = for y<- 1..numstart-2 do
    _list_surface2 = list_surface2 ++ [x + y*numstart*numstart]
  end
end

listinner = List.flatten(Enum.filter(listinner, & &1 != nil))
listoutertop = List.flatten(Enum.filter(listoutertop, & &1 != nil))
listoutertop1 = List.flatten(Enum.filter(listoutertop1, & &1 != nil))
listouterbot = List.flatten(Enum.filter(listouterbot, & &1 != nil))
listouterbot1 = List.flatten(Enum.filter(listouterbot1, & &1 != nil))
listsidebot = List.flatten(Enum.filter(listsidebot, & &1 != nil))
listsidebot1 = List.flatten(Enum.filter(listsidebot1, & &1 != nil))
listsidetop = List.flatten(Enum.filter(listsidetop, & &1 != nil))
listsidetop1 = List.flatten(Enum.filter(listsidetop1, & &1 != nil))
listvert1 = List.flatten(Enum.filter(listvert1, & &1 != nil))
listvert2 = List.flatten(Enum.filter(listvert2, & &1 != nil))
listvert3 = List.flatten(Enum.filter(listvert3, & &1 != nil))
listvert4 = List.flatten(Enum.filter(listvert4, & &1 != nil))
list_surface1 = List.flatten(Enum.filter(list_surface1, & &1 != nil))
list_surface2 = List.flatten(Enum.filter(list_surface2, & &1 != nil))

list_all1 = listinner ++ listoutertop ++ listoutertop1 ++ listouterbot ++
            listouterbot1 ++ listsidebot ++ listsidebot1 ++ listsidetop ++
            listsidetop1 ++ listvert1 ++ listvert2 ++ listvert3 ++ listvert4

# List of nodes at front and back surface
lis = List.flatten(list_all) -- List.flatten(list_all1)

list_1=[]
list_1 = for x<- 0..length(lis)-1 do
  y = Enum.at(lis, x)
  _lis = if rem(y, numstart) == 0 do
    list_1 ++ y
  end
end

list_2 = List.flatten(lis) -- List.flatten(list_1)

list_1 = List.flatten(Enum.filter(list_1, & &1 != nil))
list_2 = List.flatten(Enum.filter(list_2, & &1 != nil))

val0 = 1
val1 = numstart
val2 = numstart*(numstart-1) + 1
val3 = numstart*numstart
val4 = numstart*numstart*(numstart-1) + 1
val5 = numstart*numstart*(numstart-1) + numstart
val6 = numstart*numstart*numstart - numstart + 1
val7 = numstart*numstart*numstart

listoutertop = List.flatten(listoutertop) -- [val4]
listoutertop = listoutertop -- [val5]

listoutertop1 = List.flatten(listoutertop1) -- [val6]
listoutertop1 = listoutertop1 -- [val7]

listouterbot = List.flatten(listouterbot) -- [val0]
listouterbot = listouterbot -- [val1]

listouterbot1 = List.flatten(listouterbot1) -- [val2]
listouterbot1 = listouterbot1 -- [val3]

# Getting the actual inner nodes by excluding all the other edge,
# vertex, and surface nodes
listinner = List.flatten(listinner) -- List.flatten(listoutertop)
listinner = listinner -- List.flatten(listoutertop1)
listinner = listinner -- List.flatten(listouterbot)
listinner = listinner -- List.flatten(listouterbot1)
listinner = listinner -- List.flatten(listsidebot1) 
listinner = listinner -- List.flatten(listsidetop)
listinner = listinner -- List.flatten(listsidetop1)
listinner = listinner -- List.flatten(listvert1)
listinner = listinner -- List.flatten(listvert2)
listinner = listinner -- List.flatten(listvert3)
listinner = listinner -- List.flatten(listvert4)
listinner = listinner -- List.flatten(list_surface1)
listinner = listinner -- List.flatten(list_surface2)

# Mapping of node and neighbors for inner nodes
z = for x <- 0..length(listinner)-1 do
        y = Enum.at(listinner, x)
        Map.put(z, y, [y-1, y+1, y-numstart, y+numstart, 
                         y-numstart*numstart, y+numstart*numstart])
    end

z = Enum.map(z, fn x ->                        
  Enum.map(x, fn {k,v} ->                      
  Map.put(x, k, Enum.filter(v, fn x -> x>0 end))
end) end)
z = Enum.map(z, fn x -> List.first(x) end)

var = numstart*numstart*numstart
z = Enum.map(z, fn x ->                        
  Enum.map(x, fn {k,v} ->                      
  Map.put(x, k, Enum.filter(v, fn x -> x<(var+1) end))
end) end)
z = Enum.map(z, fn x -> List.first(x) end)

# Mapping of node and neighbors for outer top edge
z1=%{}
z1 = for x <- 0..length(listoutertop)-1 do
        y = Enum.at(listoutertop, x)
        Map.put(z1, y, [y-1, y+1, y-numstart*numstart, y+numstart,
                        y - numstart*numstart*(numstart-1), y + numstart*(numstart-1)])
        end

# Mapping of node and neighbors for top back edge
z2=%{}
z2 = for x <- 0..length(listoutertop1)-1 do
        y = Enum.at(listoutertop1, x)
        Map.put(z2, y, [y-1, y+1, y-numstart*numstart, y-numstart,
                        y - numstart*numstart*(numstart-1), y - numstart*(numstart-1)])
        end

# Mapping of node and neighbors for outer bottom edge
z3=%{}
z3 = for x <- 0..length(listouterbot)-1 do
        y = Enum.at(listouterbot, x)
        Map.put(z3, y, [y-1, y+1, y+numstart*numstart, y+numstart,
                        y + numstart*numstart*(numstart-1), y + numstart*(numstart-1)])
        end

# Mapping of node and neighbors for bottom back edge
z4=%{}
z4 = for x <- 0..length(listouterbot1)-1 do
        y = Enum.at(listouterbot1, x)
        Map.put(z4, y, [y-1, y+1, y+numstart*numstart, y-numstart,
                        y + numstart*numstart*(numstart-1), y - numstart*(numstart-1)])
        end

# Mapping of node and neighbors for left side bottom edge
z5=%{}
z5 = for x <- 0..length(listsidebot)-1 do
        y = Enum.at(listsidebot, x)
        Map.put(z5, y, [y+1, y+numstart, y-numstart, y + numstart*numstart,
                        y + numstart - 1, y + numstart*numstart*(numstart-1)])
        end

# Mapping of node and neighbors for right side bottom edge
z6=%{}
z6 = for x <- 0..length(listsidebot1)-1 do
        y = Enum.at(listsidebot1, x)
        Map.put(z6, y, [y-1, y+numstart, y-numstart, y + numstart*numstart,
                        y - numstart + 1, y + numstart*numstart*(numstart-1)])
        end

# Mapping of node and neighbors for left top edge
z7=%{}
z7 = for x <- 0..length(listsidetop)-1 do
        y = Enum.at(listsidetop, x)
        Map.put(z7, y, [y+1, y+numstart, y-numstart, y - numstart*numstart,
                        y + numstart - 1, y - numstart*numstart*(numstart-1)])
        end

# Mapping of node and neighbors for right top edge
z8=%{}
z8 = for x <- 0..length(listsidetop1)-1 do
        y = Enum.at(listsidetop1, x)
        Map.put(z8, y, [y-1, y+numstart, y-numstart, y - numstart*numstart,
                        y - numstart + 1, y - numstart*numstart*(numstart-1)])
        end

# Mapping of node and neighbors for front left edge
z9=%{}
z9 = for x <- 0..length(listvert1)-1 do
        y = Enum.at(listvert1, x)
        Map.put(z9, y, [y+1, y + numstart*numstart, y - numstart*numstart,
                        y + numstart, y + numstart - 1, y + numstart*(numstart-1)])
        end

# Mapping of node and neighbors for front right edge
z10=%{}
z10 = for x <- 0..length(listvert2)-1 do
        y = Enum.at(listvert2, x)
        Map.put(z10, y, [y-1, y + numstart, y - numstart*numstart,
                        y + numstart*numstart, y - numstart + 1,
                        y + numstart*(numstart-1)])
        end

# Mapping of node and neighbors for back left edge
z11=%{}
z11 = for x <- 0..length(listvert3)-1 do
        y = Enum.at(listvert3, x)
        Map.put(z11, y, [y+1, y + numstart*numstart, y - numstart*numstart,
                        y - numstart*(numstart-1), y + numstart - 1])
        end

# Mapping of node and neighbors for back right edge
z12=%{}
z12 = for x <- 0..length(listvert4)-1 do
        y = Enum.at(listvert4, x)
        Map.put(z12, y, [y-1, y-numstart, y + numstart*numstart, y - numstart*numstart,
                         y - numstart*(numstart-1), y - numstart + 1])
        end

# Mapping of node and neighbors for front surface
z13=%{}
z13 = for x <- 0..length(list_1)-1 do
        y = Enum.at(list_1, x)
        Map.put(z13, y, [y-numstart, y+numstart, y-1, y - numstart*numstart,
                         y + numstart*numstart])
        end

# Mapping of node and neighbors for back surface
z14=%{}
z14 = for x <- 0..length(list_2)-1 do
        y = Enum.at(list_2, x)
        Map.put(z14, y, [y-numstart, y+numstart, y+1, y - numstart*numstart,
                         y + numstart*numstart])
        end

# Mapping of node and neighbors for left surface
z15=%{}
z15 = for x <- 0..length(list_surface1)-1 do
        y = Enum.at(list_surface1, x)
        Map.put(z15, y, [y-1, y+1, y - numstart*numstart,
                         y + numstart*numstart, y+numstart])
        end

# Mapping of node and neighbors for right surface
z16=%{}
z16 = for x <- 0..length(list_surface2)-1 do
        y = Enum.at(list_surface2, x)
        Map.put(z16, y, [y-1, y+1, y - numstart*numstart,
                         y + numstart*numstart, y-numstart])
        end

# Combining all the maps
map = Enum.sort(z ++ z1 ++ z2 ++ z3 ++ z4 ++ z5 ++ z6 ++ z7 ++ z8 ++ z9 ++ 
              z10 ++ z11 ++ z12 ++ z13 ++ z14 ++ z15 ++ z16)

# Mapping of the corners of the cube to its neighbors
# Vertex 1
map = map ++ [%{1 => [2, 1 + numstart, 1 + numstart*numstart, numstart,
                      1 + numstart*(numstart - 1), 1 + numstart*numstart*(numstart - 1)]}]

# Vertex 2
val1 = numstart
map = map ++ [%{val1 => [val1 - 1, val1*2, val1 + val1*val1, val1 + val1*(val1 - 1), 1,
                        val1 + val1*val1*(val1 - 1)]}]

# Vertex 3
val2 = numstart*(numstart-1) + 1
map = map ++ [%{val2 => [val2 + 1 , val2 + numstart*numstart, val2 - numstart,
                        val2 + numstart*numstart*(numstart - 1), val2 + numstart - 1 ]}]

# Vertex 4
val3 = numstart*numstart
map = map ++ [%{val3 => [(val3 - numstart), (val3 - 1), (val3 + numstart*numstart), 
                        (val3 - numstart*(numstart-1)), (val3 - numstart + 1), 
                        (val3 + numstart*numstart*(numstart-1))]}]                       

# Vertex 5
val4 = numstart*numstart*(numstart-1) + 1
map = map ++ [%{val4 => [val4 + 1, val4 + numstart, val4 - numstart*numstart, 
                         (val4 + numstart - 1), (val4 + (numstart*(numstart-1))), 
                         val4 - numstart*numstart*(numstart-1)]}]

# Vertex 6
val5 = numstart*numstart*(numstart-1) + numstart
map = map ++ [%{val5 => [val5 - 1, val5 + numstart, val5 - numstart*numstart,
                         val5 + numstart*(numstart-1), val5 - numstart + 1,
                         val5 - numstart*numstart*(numstart-1)]}]

# Vertex 7
val6 = numstart*numstart*numstart - numstart + 1
map = map ++ [%{val6 => [val6 - numstart, val6 + 1, val6 - numstart*numstart,
                         val6 - numstart*(numstart-1), val6 + numstart - 1,
                         val6 - numstart*numstart*(numstart-1)]}]

# Vertex 8
val7 = numstart*numstart*numstart
map = map ++ [%{val7 => [val7 - numstart, val7 - 1, (val7 - numstart*numstart),
                         val7 - numstart + 1, val7 - (numstart*(numstart-1)),
                         val7 - (numstart*numstart*(numstart-1))]}]

map = Enum.reduce(map, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)

{:ok, pid} = Gossip_supervisor.start_link(map)

#get supervisor children
c = Supervisor.which_children(pid)
c = Enum.sort(c)
len = length(c)-1

#create worker nodes pid's list
pid_list = for i <- 0..len do
head = Enum.at(c,i)
h_list = Tuple.to_list(head)
Enum.at(h_list,1)
end

#note time before starting algorithm
start = System.system_time(:millisecond)
diff = 0

#send pid list of all nodes as argument
pid_list = pid_list ++ [remove_nodes]
{:ok, _pid} = Store_pid.start_link(pid_list)

#create a list consisting of current pid and start time
parent = self()
quit = [parent]++[diff]++[start]++[convergence_factor]


#send the above created list to Dispstore so that it knows when to quit
Task.start_link(fn ->
Dispstore.start_link(quit)
end)

time_wait = if remove_nodes == 0 do
            40_000
          else
            10_000
          end
#IO.puts("time wait- #{time_wait}")

#Quit storing when we reach required convergence, otherwise wait till default time
receive do
:work_is_done -> :ok
after
# Optional timeout
time_wait -> :timeout
end

#Print number of failed nodes
if remove_nodes>0 do
IO.puts("Number of failed nodes - #{remove_nodes} nodes")
end

#converged nodes are stored in Dispstore state
list = Dispstore.print()
length_list = length(list)

#Nodes converged and quit list parameters are stored in Dispstore state
#nodes_converged = length_list - 4

# IO.puts("Total nodes - #{convergence_factor} nodes")
# IO.puts("Achieved convergence - #{nodes_converged} nodes")

#time diff is being stored in Dispstore state after every node converges
time_diff = Enum.at(list, length_list-3)
IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds")

end

def torus3D_push_sum(num) do

#cli arguments for basic implementation: my_program numNodes topology algorithm
#cli arguments for failure model implementation:
#my_program numNodes topology algorithm remove_nodes convergence_factor

nodes = num
convergence_factor = nodes

#Note: There are only 2 scenarios possible:
#case 1: gossip does not stop until it reaches convergence_factor, this is when there is 100% convergence
#case 2: gossip stops before reaching convergence_factor,
#case 2 what happens during failure node implementation

#Basic implementation: remove_node is specified as below, as there are zero failure nodes
#remove_nodes = 0

#Bonus part implementation: remove_nodes values are modified and observations are made
remove_nodes = 10

x = cube_root(num, 2)
numstart = trunc(x)

# Approximating the number of nodes to nearest cube
num = numstart*numstart*numstart

# List of all nodes
list_all = Enum.to_list(1..num)

z=%{}
# List of inner nodes having 6 neighbors each
listinner=[]
listinner = for x <- numstart+2..num-numstart do
  _lis = if rem(x, numstart) != 1 and rem(x, numstart) !=0 do
     listinner ++ [x]
  end
end

# List of nodes at outer top edge of the cube
listoutertop=[]
n = numstart*numstart*(numstart-1) + 1
listoutertop = for x <- n..n+numstart-1 do
  _lis = listoutertop ++ [x]
  end

# List of nodes at top back edge of the cube
listoutertop1=[]
n = numstart*numstart*(numstart-1) + 1
listoutertop1 = for x<-n..n+numstart-1  do
  _lis = listoutertop1 ++ [x + (numstart*numstart - numstart)]
end

# List of nodes at bottom front edge of the cube 
listouterbot=[]
listouterbot = for x <- 1..numstart do
  _lis = listouterbot ++ [x]
  end

# List of nodes at bottom back edge of the cube
listouterbot1=[]
listouterbot1 = for x <- 1..numstart do
  _lis = listouterbot1 ++ [x + (numstart*numstart - numstart)]
  end

# List of nodes at bottom left side edge of the cube
listsidebot=[]
n = numstart*(numstart-2)
listsidebot = for x <- numstart..n do
  _lis = if rem(x, numstart) == 0 do
  listsidebot ++ [x + 1]
      end
  end

# List of nodes at bottom right side edge of the cube
listsidebot1=[]
listsidebot1 = for x<- numstart+1..numstart*numstart-1 do
  _lis = if rem(x, numstart) == 0 do
    listsidebot1 ++ [x]
  end
end

# List of nodes at top left side edge of the cube
listsidetop=[]
n = numstart*numstart*(numstart-1) + numstart + 1
listsidetop = for x<- n..num-numstart do
  _lis = if rem(x, numstart) == 1 do
    listsidetop ++ [x]
  end
end

# List of nodes at top right side edge of the cube
listsidetop1=[]
n = numstart*numstart*(numstart-1) + numstart + 1
listsidetop1 = for x<- n..num-numstart do
  _lis = if rem(x, numstart) == 0 do
    listsidetop1 ++ [x]
  end
end

# List of nodes at front left vertical edge
listvert1=[]
n = numstart*numstart*(numstart-1)
listvert1 = for x<- numstart..n do
  _lis = if rem(x, numstart*numstart) == 1 do
    listvert1 ++ [x]
  end
end

# List of nodes at front right vertical edge
listvert2=[]
n = numstart*numstart*(numstart-1)
listvert2 = for x<- numstart+1..n do
  _lis = if rem(x, numstart*numstart) == 1 do
    listvert2 ++ [x + numstart - 1 ]
  end
end

# List of nodes at back left vertical edge
listvert3=[]
listvert3 = for x<- numstart*numstart+1..numstart*numstart*(numstart-1) do
  _lis = if rem(x, numstart*numstart) == 0 do
    listvert3 ++ [x - (numstart - 1)]
  end
end

# List of nodes at back right vertical edge
listvert4=[]
listvert4 = for x<- numstart*numstart + 1..numstart*numstart*(numstart-1) do
  _lis = if rem(x, numstart*numstart) == 0 do
    listvert4 ++ [x]
  end
end

# List of nodes at left surface
list_surface1=[]
list_surface1 = for x<- 2..numstart-1 do
  _lis = for y<- 1..numstart-2 do
    _list_surface1 = list_surface1 ++ [x + y*numstart*numstart]
  end
end

# List of nodes at right surface
list_surface2=[]
a = 2 + numstart*(numstart-1)
list_surface2 = for x<- a..a+numstart-3 do
  _lis = for y<- 1..numstart-2 do
    _list_surface2 = list_surface2 ++ [x + y*numstart*numstart]
  end
end

listinner = List.flatten(Enum.filter(listinner, & &1 != nil))
listoutertop = List.flatten(Enum.filter(listoutertop, & &1 != nil))
listoutertop1 = List.flatten(Enum.filter(listoutertop1, & &1 != nil))
listouterbot = List.flatten(Enum.filter(listouterbot, & &1 != nil))
listouterbot1 = List.flatten(Enum.filter(listouterbot1, & &1 != nil))
listsidebot = List.flatten(Enum.filter(listsidebot, & &1 != nil))
listsidebot1 = List.flatten(Enum.filter(listsidebot1, & &1 != nil))
listsidetop = List.flatten(Enum.filter(listsidetop, & &1 != nil))
listsidetop1 = List.flatten(Enum.filter(listsidetop1, & &1 != nil))
listvert1 = List.flatten(Enum.filter(listvert1, & &1 != nil))
listvert2 = List.flatten(Enum.filter(listvert2, & &1 != nil))
listvert3 = List.flatten(Enum.filter(listvert3, & &1 != nil))
listvert4 = List.flatten(Enum.filter(listvert4, & &1 != nil))
list_surface1 = List.flatten(Enum.filter(list_surface1, & &1 != nil))
list_surface2 = List.flatten(Enum.filter(list_surface2, & &1 != nil))

list_all1 = listinner ++ listoutertop ++ listoutertop1 ++ listouterbot ++
            listouterbot1 ++ listsidebot ++ listsidebot1 ++ listsidetop ++
            listsidetop1 ++ listvert1 ++ listvert2 ++ listvert3 ++ listvert4

# List of nodes at front and back surface
lis = List.flatten(list_all) -- List.flatten(list_all1)

list_1=[]
list_1 = for x<- 0..length(lis)-1 do
  y = Enum.at(lis, x)
  _lis = if rem(y, numstart) == 0 do
    list_1 ++ y
  end
end

list_2 = List.flatten(lis) -- List.flatten(list_1)

list_1 = List.flatten(Enum.filter(list_1, & &1 != nil))
list_2 = List.flatten(Enum.filter(list_2, & &1 != nil))

val0 = 1
val1 = numstart
val2 = numstart*(numstart-1) + 1
val3 = numstart*numstart
val4 = numstart*numstart*(numstart-1) + 1
val5 = numstart*numstart*(numstart-1) + numstart
val6 = numstart*numstart*numstart - numstart + 1
val7 = numstart*numstart*numstart

listoutertop = List.flatten(listoutertop) -- [val4]
listoutertop = listoutertop -- [val5]

listoutertop1 = List.flatten(listoutertop1) -- [val6]
listoutertop1 = listoutertop1 -- [val7]

listouterbot = List.flatten(listouterbot) -- [val0]
listouterbot = listouterbot -- [val1]

listouterbot1 = List.flatten(listouterbot1) -- [val2]
listouterbot1 = listouterbot1 -- [val3]

# Getting the actual inner nodes by excluding all the other edge,
# vertex, and surface nodes
listinner = List.flatten(listinner) -- List.flatten(listoutertop)
listinner = listinner -- List.flatten(listoutertop1)
listinner = listinner -- List.flatten(listouterbot)
listinner = listinner -- List.flatten(listouterbot1)
listinner = listinner -- List.flatten(listsidebot1) 
listinner = listinner -- List.flatten(listsidetop)
listinner = listinner -- List.flatten(listsidetop1)
listinner = listinner -- List.flatten(listvert1)
listinner = listinner -- List.flatten(listvert2)
listinner = listinner -- List.flatten(listvert3)
listinner = listinner -- List.flatten(listvert4)
listinner = listinner -- List.flatten(list_surface1)
listinner = listinner -- List.flatten(list_surface2)

# Mapping of node and neighbors for inner nodes
z = for x <- 0..length(listinner)-1 do
        y = Enum.at(listinner, x)
        Map.put(z, y, [y-1, y+1, y-numstart, y+numstart, 
                         y-numstart*numstart, y+numstart*numstart])
    end

z = Enum.map(z, fn x ->                        
  Enum.map(x, fn {k,v} ->                      
  Map.put(x, k, Enum.filter(v, fn x -> x>0 end))
end) end)
z = Enum.map(z, fn x -> List.first(x) end)

var = numstart*numstart*numstart
z = Enum.map(z, fn x ->                        
  Enum.map(x, fn {k,v} ->                      
  Map.put(x, k, Enum.filter(v, fn x -> x<(var+1) end))
end) end)
z = Enum.map(z, fn x -> List.first(x) end)

# Mapping of node and neighbors for outer top edge
z1=%{}
z1 = for x <- 0..length(listoutertop)-1 do
        y = Enum.at(listoutertop, x)
        Map.put(z1, y, [y-1, y+1, y-numstart*numstart, y+numstart,
                        y - numstart*numstart*(numstart-1), y + numstart*(numstart-1)])
        end

# Mapping of node and neighbors for top back edge
z2=%{}
z2 = for x <- 0..length(listoutertop1)-1 do
        y = Enum.at(listoutertop1, x)
        Map.put(z2, y, [y-1, y+1, y-numstart*numstart, y-numstart,
                        y - numstart*numstart*(numstart-1), y - numstart*(numstart-1)])
        end

# Mapping of node and neighbors for outer bottom edge
z3=%{}
z3 = for x <- 0..length(listouterbot)-1 do
        y = Enum.at(listouterbot, x)
        Map.put(z3, y, [y-1, y+1, y+numstart*numstart, y+numstart,
                        y + numstart*numstart*(numstart-1), y + numstart*(numstart-1)])
        end

# Mapping of node and neighbors for bottom back edge
z4=%{}
z4 = for x <- 0..length(listouterbot1)-1 do
        y = Enum.at(listouterbot1, x)
        Map.put(z4, y, [y-1, y+1, y+numstart*numstart, y-numstart,
                        y + numstart*numstart*(numstart-1), y - numstart*(numstart-1)])
        end

# Mapping of node and neighbors for left side bottom edge
z5=%{}
z5 = for x <- 0..length(listsidebot)-1 do
        y = Enum.at(listsidebot, x)
        Map.put(z5, y, [y+1, y+numstart, y-numstart, y + numstart*numstart,
                        y + numstart - 1, y + numstart*numstart*(numstart-1)])
        end

# Mapping of node and neighbors for right side bottom edge
z6=%{}
z6 = for x <- 0..length(listsidebot1)-1 do
        y = Enum.at(listsidebot1, x)
        Map.put(z6, y, [y-1, y+numstart, y-numstart, y + numstart*numstart,
                        y - numstart + 1, y + numstart*numstart*(numstart-1)])
        end

# Mapping of node and neighbors for left top edge
z7=%{}
z7 = for x <- 0..length(listsidetop)-1 do
        y = Enum.at(listsidetop, x)
        Map.put(z7, y, [y+1, y+numstart, y-numstart, y - numstart*numstart,
                        y + numstart - 1, y - numstart*numstart*(numstart-1)])
        end

# Mapping of node and neighbors for right top edge
z8=%{}
z8 = for x <- 0..length(listsidetop1)-1 do
        y = Enum.at(listsidetop1, x)
        Map.put(z8, y, [y-1, y+numstart, y-numstart, y - numstart*numstart,
                        y - numstart + 1, y - numstart*numstart*(numstart-1)])
        end

# Mapping of node and neighbors for front left edge
z9=%{}
z9 = for x <- 0..length(listvert1)-1 do
        y = Enum.at(listvert1, x)
        Map.put(z9, y, [y+1, y + numstart*numstart, y - numstart*numstart,
                        y + numstart, y + numstart - 1, y + numstart*(numstart-1)])
        end

# Mapping of node and neighbors for front right edge
z10=%{}
z10 = for x <- 0..length(listvert2)-1 do
        y = Enum.at(listvert2, x)
        Map.put(z10, y, [y-1, y + numstart, y - numstart*numstart,
                        y + numstart*numstart, y - numstart + 1,
                        y + numstart*(numstart-1)])
        end

# Mapping of node and neighbors for back left edge
z11=%{}
z11 = for x <- 0..length(listvert3)-1 do
        y = Enum.at(listvert3, x)
        Map.put(z11, y, [y+1, y + numstart*numstart, y - numstart*numstart,
                        y - numstart*(numstart-1), y + numstart - 1])
        end

# Mapping of node and neighbors for back right edge
z12=%{}
z12 = for x <- 0..length(listvert4)-1 do
        y = Enum.at(listvert4, x)
        Map.put(z12, y, [y-1, y-numstart, y + numstart*numstart, y - numstart*numstart,
                         y - numstart*(numstart-1), y - numstart + 1])
        end

# Mapping of node and neighbors for front surface
z13=%{}
z13 = for x <- 0..length(list_1)-1 do
        y = Enum.at(list_1, x)
        Map.put(z13, y, [y-numstart, y+numstart, y-1, y - numstart*numstart,
                         y + numstart*numstart])
        end

# Mapping of node and neighbors for back surface
z14=%{}
z14 = for x <- 0..length(list_2)-1 do
        y = Enum.at(list_2, x)
        Map.put(z14, y, [y-numstart, y+numstart, y+1, y - numstart*numstart,
                         y + numstart*numstart])
        end

# Mapping of node and neighbors for left surface
z15=%{}
z15 = for x <- 0..length(list_surface1)-1 do
        y = Enum.at(list_surface1, x)
        Map.put(z15, y, [y-1, y+1, y - numstart*numstart,
                         y + numstart*numstart, y+numstart])
        end

# Mapping of node and neighbors for right surface
z16=%{}
z16 = for x <- 0..length(list_surface2)-1 do
        y = Enum.at(list_surface2, x)
        Map.put(z16, y, [y-1, y+1, y - numstart*numstart,
                         y + numstart*numstart, y-numstart])
        end

# Combining all the maps
map = Enum.sort(z ++ z1 ++ z2 ++ z3 ++ z4 ++ z5 ++ z6 ++ z7 ++ z8 ++ z9 ++ 
              z10 ++ z11 ++ z12 ++ z13 ++ z14 ++ z15 ++ z16)

# Mapping of the corners of the cube to its neighbors
# Vertex 1
map = map ++ [%{1 => [2, 1 + numstart, 1 + numstart*numstart, numstart,
                      1 + numstart*(numstart - 1), 1 + numstart*numstart*(numstart - 1)]}]

# Vertex 2
val1 = numstart
map = map ++ [%{val1 => [val1 - 1, val1*2, val1 + val1*val1, val1 + val1*(val1 - 1), 1,
                        val1 + val1*val1*(val1 - 1)]}]

# Vertex 3
val2 = numstart*(numstart-1) + 1
map = map ++ [%{val2 => [val2 + 1 , val2 + numstart*numstart, val2 - numstart,
                        val2 + numstart*numstart*(numstart - 1), val2 + numstart - 1 ]}]

# Vertex 4
val3 = numstart*numstart
map = map ++ [%{val3 => [(val3 - numstart), (val3 - 1), (val3 + numstart*numstart), 
                        (val3 - numstart*(numstart-1)), (val3 - numstart + 1), 
                        (val3 + numstart*numstart*(numstart-1))]}]                       

# Vertex 5
val4 = numstart*numstart*(numstart-1) + 1
map = map ++ [%{val4 => [val4 + 1, val4 + numstart, val4 - numstart*numstart, 
                         (val4 + numstart - 1), (val4 + (numstart*(numstart-1))), 
                         val4 - numstart*numstart*(numstart-1)]}]

# Vertex 6
val5 = numstart*numstart*(numstart-1) + numstart
map = map ++ [%{val5 => [val5 - 1, val5 + numstart, val5 - numstart*numstart,
                         val5 + numstart*(numstart-1), val5 - numstart + 1,
                         val5 - numstart*numstart*(numstart-1)]}]

# Vertex 7
val6 = numstart*numstart*numstart - numstart + 1
map = map ++ [%{val6 => [val6 - numstart, val6 + 1, val6 - numstart*numstart,
                         val6 - numstart*(numstart-1), val6 + numstart - 1,
                         val6 - numstart*numstart*(numstart-1)]}]

# Vertex 8
val7 = numstart*numstart*numstart
map = map ++ [%{val7 => [val7 - numstart, val7 - 1, (val7 - numstart*numstart),
                         val7 - numstart + 1, val7 - (numstart*(numstart-1)),
                         val7 - (numstart*numstart*(numstart-1))]}]

map = Enum.reduce(map, fn(x, acc) -> Map.merge(x, acc, fn _k, v1, v2 -> [v1, v2] end) end)

{:ok, pid} = Push_Sum_supervisor.start_link(map)

#get supervisor children
c = Supervisor.which_children(pid)
c = Enum.sort(c)
len = length(c)-1

#create worker nodes pid's list
pid_list = for i <- 0..len do
head = Enum.at(c,i)
h_list = Tuple.to_list(head)
Enum.at(h_list,1)
end

#note time before starting algorithm
start = System.system_time(:millisecond)
diff = 0

#send pid list of all nodes as argument
pid_list = pid_list ++ [remove_nodes]
{:ok, _pid} = Store_pid_ps.start_link(pid_list)

#create a list consisting of current pid and start time
parent = self()
quit = [parent]++[diff]++[start]++[convergence_factor]


#send the above created list to Dispstore so that it knows when to quit
Task.start_link(fn ->
Dispstore_ps.start_link(quit)
end)

time_wait = if remove_nodes == 0 do
            40_000
          else
            10_000
          end


#Quit storing when we reach required convergence, otherwise wait till default time
receive do
:work_is_done -> :ok
after
# Optional timeout
time_wait -> :timeout
end

#Print number of failed nodes
if remove_nodes>0 do
IO.puts("Number of failed nodes - #{remove_nodes} nodes")
end

#converged nodes are stored in Dispstore state
list = Dispstore_ps.print()
length_list = length(list)

#Nodes converged and quit list parameters are stored in Dispstore state
#nodes_converged = length_list - 4

# IO.puts("Total nodes - #{convergence_factor} nodes")
# IO.puts("Achieved convergence - #{nodes_converged} nodes")

#time diff is being stored in Dispstore state after every node converges
time_diff = Enum.at(list, length_list-3)
IO.puts("Time taken to achieve convergence - #{time_diff} milliseconds")
end


def cube_root(x, precision \\ 1.0e-12) do
    f = fn(prev) -> (2 * prev + x / :math.pow(prev, 2)) / 3 end
    fixed_point(f, x, precision, f.(x))
end

def fixed_point(_, guess, tolerance, next) when abs(guess - next) < tolerance, do: next
   
def fixed_point(f, _, tolerance, next), do: fixed_point(f, next, tolerance, f.(next))

end

numnodes = Enum.at(System.argv(),0)
algorithm = Enum.at(System.argv(),1)
topology = Enum.at(System.argv(),2)

numnodes = String.to_integer(numnodes)

case topology do
  
  "full" -> if algorithm == "gossip", do: Topology.full_gossip(numnodes), else: Topology.full_push_sum(numnodes)

  "line" -> if algorithm == "gossip", do: Topology.line_gossip(numnodes), else: Topology.line_push_sum(numnodes)

  "rand2D" -> if algorithm == "gossip", do: Topology.rand2D_gossip(numnodes), else: Topology.rand2D_push_sum(numnodes)

  "honeycomb" -> if algorithm == "gossip", do: Topology.honeycomb_gossip(numnodes), else: Topology.honeycomb_push_sum(numnodes)

  "randhoneycomb" -> if algorithm == "gossip", do: Topology.honeycombrand_gossip(numnodes), else: Topology.honeycombrand_push_sum(numnodes)

  "3Dtorus" -> if algorithm == "gossip", do: Torus3D.torus3D_gossip(numnodes), else: Torus3D.torus3D_push_sum(numnodes)

  _ -> IO.puts "check input values"

end