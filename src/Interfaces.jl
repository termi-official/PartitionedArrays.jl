
abstract type Backend end

# Should return a DistributedData{Int}
function get_parts(b::Backend,nparts::Integer)
  @abstractmethod
end

function get_parts(b::Backend,nparts::Tuple)
  get_parts(b,prod(nparts))
end

# This can be overwritten to add a finally clause
function distributed_run(driver::Function,b::Backend,nparts)
  part = get_parts(b,nparts)
  driver(part)
end

# Data distributed in parts of type T
abstract type DistributedData{T} end

num_parts(a::DistributedData) = @abstractmethod

get_backend(a::DistributedData) = @abstractmethod

get_parts(a::DistributedData) = get_parts(get_backend(a),num_parts(a))

function map_parts(task::Function,a::DistributedData...)
  @abstractmethod
end

function i_am_master(::DistributedData)
  @abstractmethod
end

# Non-blocking in-place exchange
# In this version, sending a number per part is enough
# We have another version below to send a vector of numbers per part (compressed in a Table)
# Starts a non-blocking exchange. It returns a DistributedData of Julia Tasks. Calling schedule and wait on these
# tasks will wait until the exchange is done in the corresponding part
# (i.e., at this point it is save to read/write the buffers again).
function async_exchange!(
  data_rcv::DistributedData,
  data_snd::DistributedData,
  parts_rcv::DistributedData,
  parts_snd::DistributedData,
  t_in::DistributedData)

  @abstractmethod
end

function async_exchange!(
  data_rcv::DistributedData,
  data_snd::DistributedData,
  parts_rcv::DistributedData,
  parts_snd::DistributedData)

  t_in = map_parts(parts_rcv) do parts_rcv
    @task nothing
  end
  async_exchange!(data_rcv,data_snd,parts_rcv,parts_snd,t_in)
end

function async_exchange!(
  data_rcv::DistributedData,
  data_snd::DistributedData,
  parts_rcv::DistributedData,
  parts_snd::DistributedData,
  t_in::Nothing)

  async_exchange!(data_rcv,data_snd,parts_rcv,parts_snd)
end

# Non-blocking allocating exchange
# the returned data_rcv cannot be consumed in a part until the corresponding task in t is done.
function async_exchange(
  data_snd::DistributedData,
  parts_rcv::DistributedData,
  parts_snd::DistributedData,
  t_in::DistributedData)

  data_rcv = map_parts(data_snd,parts_rcv) do data_snd, parts_rcv
    similar(data_snd,eltype(data_snd),length(parts_rcv))
  end

  t_out = async_exchange!(data_rcv,data_snd,parts_rcv,parts_snd,t_in)

  data_rcv, t_out
end

function async_exchange(
  data_snd::DistributedData,
  parts_rcv::DistributedData,
  parts_snd::DistributedData)

  t_in = map_parts(parts_rcv) do parts_rcv
    @task nothing
  end
  async_exchange(data_snd,parts_rcv,parts_snd,t_in)
end

function async_exchange(
  data_snd::DistributedData,
  parts_rcv::DistributedData,
  parts_snd::DistributedData,
  t_in::Nothing)

  async_exchange(data_rcv,data_snd,parts_rcv,parts_snd)
end

# Non-blocking in-place exchange variable length (compressed in a Table)
function async_exchange!(
  data_rcv::DistributedData{<:Table},
  data_snd::DistributedData{<:Table},
  parts_rcv::DistributedData,
  parts_snd::DistributedData,
  t_in::DistributedData)

  @abstractmethod
end

# Non-blocking allocating exchange variable length (compressed in a Table)
function async_exchange(
  data_snd::DistributedData{<:Table},
  parts_rcv::DistributedData,
  parts_snd::DistributedData,
  t_in::DistributedData)

  # Allocate empty data
  data_rcv = map_parts(empty_table,data_snd)
  n_snd = map_parts(parts_snd) do parts_snd
    Int[]
  end

  # wait data_snd to be in a correct state and
  # Count how many we snd to each part
  t1 = map_parts(n_snd,data_snd,t_in) do n_snd,data_snd,t_in
    @task begin
      wait(schedule(t_in))
      resize!(n_snd,length(data_snd))
      for i in 1:length(n_snd)
        n_snd[i] = data_snd.ptrs[i+1] - data_snd.ptrs[i]
      end
    end
  end

  # Count how many we rcv from each part
  n_rcv, t2 = async_exchange(n_snd,parts_rcv,parts_snd,t1)

  # Wait n_rcv to be in a correct state and
  # resize data_rcv to the correct size
  t3 = map_parts(n_rcv,t2,data_rcv) do n_rcv,t2,data_rcv
    @task begin
      wait(schedule(t2))
      resize!(data_rcv.ptrs,length(n_rcv)+1)
      for i in 1:length(n_rcv)
        data_rcv.ptrs[i+1] = n_rcv[i]
      end
      length_to_ptrs!(data_rcv.ptrs)
      ndata = data_rcv.ptrs[end]-1
      resize!(data_rcv.data,ndata)
    end
  end

  # Do the actual exchange
  t4 = async_exchange!(data_rcv,data_snd,parts_rcv,parts_snd,t3)

  data_rcv, t4
end

# Blocking in-place exchange
function exchange!(args...;kwargs...)
  t = async_exchange!(args...;kwargs...)
  map_parts(schedule,t)
  map_parts(wait,t)
  first(args)
end

# Blocking allocating exchange
function exchange(args...;kwargs...)
  data_rcv, t = async_exchange(args...;kwargs...)
  map_parts(schedule,t)
  map_parts(wait,t)
  data_rcv
end

# Discover snd parts from rcv assuming that srd is a subset of neighbors
# Assumes that neighbors is a symmetric communication graph
function discover_parts_snd(parts_rcv::DistributedData, neighbors::DistributedData)
  @assert num_parts(parts_rcv) == num_parts(neighbors)

  # Tell the neighbors whether I want to receive data from them
  data_snd = map_parts(neighbors,parts_rcv) do part, neighbors, parts_rcv
    dict_snd = Dict(( n=>-1 for n in neighbors))
    for i in parts_rcv
      dict_snd[i] = part
    end
    [ dict_snd[n] for n in neighbors ]
  end
  data_rcv = exchange(data_snd,neighbors,neighbors)

  # build parts_snd
  parts_snd = DistributedData(data_rcv) do part, data_rcv
    k = findall(j->j>0,data_rcv)
    data_rcv[k]
  end

  parts_snd
end

# If neighbors not provided, all procs are considered neighbors (to be improved)
function discover_parts_snd(parts_rcv::DistributedData)
  comm = get_comm(parts_rcv)
  nparts = num_parts(comm)
  neighbors = DistributedData(parts_rcv) do part, parts_rcv
    T = eltype(parts_rcv)
    [T(i) for i in 1:nparts if i!=part]
  end
  discover_parts_snd(parts_rcv,neighbors)
end

function discover_parts_snd(parts_rcv::DistributedData,::Nothing)
  discover_parts_snd(parts_rcv)
end
