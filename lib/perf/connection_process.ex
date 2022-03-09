defmodule Perf.ConnectionProcess do
  use GenServer

  require Logger

  defstruct [:conn, :params, :conn_time, request: %{}]

  def start_link({scheme, host, port, id}) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {scheme, host, port}, name: id)
    send(pid, :late_init)
    {:ok, pid}
  end

  def request(pid, method, path, headers, body) do
    :timer.tc(fn  ->
      GenServer.call(pid, {:request, method, path, headers, body}, 15_000)
    end)
  end

  ## Callbacks

  @impl true
  def init({scheme, host, port}) do
    state = %__MODULE__{conn: nil, params: {scheme, host, port}}
    {:ok, state}
  end

  @compile {:inline, options: 1}
  defp options(:https) do
    [transport_opts: [verify: :verify_none]]
  end

  defp options(:http) do
    []
  end

  @impl true
  def handle_call({:request, _, _, _, _}, _, state = %__MODULE__{conn: nil}) do
    send(self(), :late_init)
    Process.sleep(200)
    {:reply, {:nil_conn, "Invalid connection state: nil"}, state}
  end

  @impl true
  def handle_call({:request, method, path, headers, body}, from, state) do
    response = RequestResult.new("sample", "#{inspect(self())}", get_endpoint(state.conn, path, method), String.length(body), state.conn_time)
    #IO.puts "Making Request!"
    start = :erlang.monotonic_time(:millisecond)
    case Mint.HTTP.request(state.conn, method, path, headers, body) do
      {:ok, conn, request_ref} ->
        conn_time = :erlang.monotonic_time(:millisecond) - start
        state = %{state | conn: conn, conn_time: conn_time, request: %{from: from, response: response, ref: request_ref, status: nil, headers: [], body: "", latency: 0}}
        {:noreply, state}

      {:error, conn, reason} ->
        state = put_in(state.conn, conn)
        send(self(), :late_init)
        {:reply, {:error_conn, reason}, state}
    end
  end

  @impl true
  def handle_info(:late_init, state = %__MODULE__{params: {scheme, host, port}}) do
    start = :erlang.monotonic_time(:millisecond)
    case Mint.HTTP.connect(scheme, host, port, options(scheme)) do
      {:ok, conn} -> {:noreply, %{state | conn: conn, conn_time: :erlang.monotonic_time(:millisecond) - start}}
      {:error, err} ->
        Logger.warn("Error creating connection with #{inspect({scheme, host, port})}: #{inspect(err)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(message, state = %__MODULE__{conn: nil}) do
    Logger.warn(fn -> "Received message with null conn: " <> inspect(message) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    case Mint.HTTP.stream(state.conn, message) do
      :unknown ->
        Logger.warn(fn -> "Received unknown message: " <> inspect(message) end)
        {:noreply, state}

      {:ok, conn, []} -> {:noreply, put_in(state.conn, conn)}

      {:ok, conn, responses} ->
        state = put_in(state.conn, conn)
        state = Enum.reduce(responses, state, process_response_fn(state))
        {:noreply, state}

      {:error, _conn, reason, _responses} ->
        #IO.puts("########ERROR########")
        #IO.inspect(reason)
        case state.request do
          %{from: from, ref: _request_ref} -> GenServer.reply(from, {:protocol_error, reason})
          _ -> nil
        end
        {:noreply, put_in(state.conn, nil)}
    end
  end

  defp process_response_fn(%__MODULE__{request: %{ref: original_ref}}) do
    fn (message, state) ->
      case message do
        {:status, ^original_ref, status} -> set_latency(state,:status, status)
        {:done, ^original_ref} -> process_response(message, state)
        {:headers, ^original_ref, headers} -> set_latency(state,:headers, headers)
        {:data, ^original_ref, data} -> set_latency(state,:body, data <> state.request.body)
        {:error, ^original_ref, _reason} -> process_response(message, state)
        _ -> state
      end
    end
  end

  defp set_latency(state, item, value) do
    new_state = put_in(state.request[item], value)
    if new_state.request.latency == 0 do
      put_in(new_state.request.latency, :erlang.monotonic_time(:millisecond))
    else
      new_state
    end
  end

  defp process_response({:done, _request_ref}, state = %__MODULE__{request: %{from: from, status: status, body: body, headers: headers, latency: latency, response: response}}) do
    #IO.puts("Done request!")
    final_result = RequestResult.complete(response, status, body, headers, latency)
    GenServer.reply(from, {status_for(status), final_result})
    %{state | request: %{}}
  end

  defp process_response({:error, _request_ref, reason}, state = %__MODULE__{request: %{from: from, init: _init}}) do
    GenServer.reply(from, {:protocol_error, reason})
    #IO.puts("Request error")
    IO.inspect(reason)
    %{state | request: %{}}
  end

  defp status_for(status) when status >= 200 and status < 400, do: :ok
  defp status_for(status), do: {:fail_http, status}


  defp get_endpoint(%{hostname: hostname, scheme: scheme, port: port}, path, method) do
    "#{method} -> #{scheme}://#{hostname}:#{port}#{path}"
  end

end
