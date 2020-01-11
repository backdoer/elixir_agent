defmodule NewRelic.Harvest.Collector.AgentRun do
  use GenServer

  # This GenServer is responsible for connecting to the collector
  # and holding onto the Agent Run connect response in an ETS table

  @moduledoc false

  alias NewRelic.Harvest.Collector

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    NewRelic.sample_process()
    :ets.new(__MODULE__, [:named_table, :public, :set])

    if NewRelic.Config.enabled?() do
      {:ok, %{status: :not_connected}, {:continue, :preconnect}}
    else
      {:ok, %{status: :not_connected}}
    end
  end

  def agent_run_id, do: lookup(:agent_run_id)
  def trusted_account_key, do: lookup(:trusted_account_key)
  def account_id, do: lookup(:account_id)
  def primary_application_id, do: lookup(:primary_application_id)

  def reconnect, do: send(__MODULE__, :reconnect)

  def ensure_init, do: GenServer.call(__MODULE__, :ping)

  def handle_continue(:preconnect, _state) do
    case Collector.Protocol.preconnect() do
      {:ok, %{"redirect_host" => redirect_host}} ->
        Application.put_env(:new_relic_agent, :collector_instance_host, redirect_host)
        {:noreply, %{status: :preconnected}, {:continue, :connect}}

      _error ->
        {:noreply, %{status: :error_during_preconnect}}
    end
  end

  def handle_continue(:connect, _state) do
    status = connect()
    {:noreply, %{status: status}}
  end

  def handle_info(:reconnect, _state) do
    status = connect()
    {:noreply, %{status: status}}
  end

  def handle_call(:ping, _from, state) do
    {:reply, true, state}
  end

  defp connect() do
    Collector.Connect.payload()
    |> Collector.Protocol.connect()
    |> store_agent_run()
  end

  defp store_agent_run({:ok, %{"agent_run_id" => _} = connect_response}) do
    store(:agent_run_id, connect_response["agent_run_id"])
    store(:trusted_account_key, connect_response["trusted_account_key"])
    store(:account_id, connect_response["account_id"])
    store(:primary_application_id, connect_response["primary_application_id"])

    store(:sampling_target, connect_response["sampling_target"])
    store(:sampling_target_period, connect_response["sampling_target_period_in_seconds"] * 1000)

    transaction_event = connect_response["data_methods"]["analytic_event_data"]
    store(:transaction_event_reservoir_size, transaction_event["max_samples_stored"])
    store(:transaction_event_harvest_cycle, transaction_event["report_period_in_seconds"] * 1000)

    custom_event = connect_response["data_methods"]["custom_event_data"]
    store(:custom_event_reservoir_size, custom_event["max_samples_stored"])
    store(:custom_event_harvest_cycle, custom_event["report_period_in_seconds"] * 1000)

    error_event = connect_response["data_methods"]["error_event_data"]
    store(:error_event_reservoir_size, error_event["max_samples_stored"])
    store(:error_event_harvest_cycle, error_event["report_period_in_seconds"] * 1000)

    span_event = connect_response["data_methods"]["span_event_data"]
    store(:span_event_reservoir_size, span_event["max_samples_stored"])
    store(:span_event_harvest_cycle, span_event["report_period_in_seconds"] * 1000)

    store(:data_report_period, connect_response["data_report_period"] * 1000)

    store(:apdex_t, connect_response["apdex_t"])

    :connected
  end

  defp store_agent_run(_bad_connect_response) do
    :bad_connect_response
  end

  def store(key, value) do
    :ets.insert(__MODULE__, {key, value})
  end

  def lookup(key) do
    Application.get_env(:new_relic_agent, key) ||
      case :ets.lookup(__MODULE__, key) do
        [{^key, value}] -> value
        [] -> nil
      end
  end
end
