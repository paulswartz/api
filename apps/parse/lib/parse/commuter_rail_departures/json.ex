defmodule Parse.CommuterRailDepartures.JSON do
  @moduledoc """
  Parses an enhanced Trip Updates JSON file into a list of `%Model.Prediction{}` structs.

  This used to be only for Commuter Rail, but it's now generated for all modes.
  """
  @behaviour Parse

  @impl true
  def parse(body) do
    body
    |> Jason.decode!(strings: :copy)
    |> Map.get("entity")
    |> Enum.flat_map(&parse_entity/1)
  end

  def parse_entity(%{"trip_update" => %{"trip" => trip, "stop_time_update" => updates} = raw}) do
    base = base_prediction(trip, raw)

    for update <- updates do
      prediction(update, base)
    end
  end

  def parse_entity(%{}) do
    []
  end

  def base_prediction(trip, raw) do
    %Model.Prediction{
      trip_id: Map.get(trip, "trip_id"),
      route_id: Map.get(trip, "route_id"),
      route_pattern_id: Map.get(trip, "route_pattern_id"),
      direction_id: Map.get(trip, "direction_id"),
      vehicle_id: vehicle_id(raw),
      schedule_relationship: schedule_relationship(Map.get(trip, "schedule_relationship")),
      revenue: parse_revenue(Map.get(trip, "revenue", true)),
      update_type: parse_update_type(Map.get(raw, "update_type"))
    }
  end

  def prediction(update, base) do
    %{
      base
      | stop_id: Map.get(update, "stop_id"),
        arrival_time: time(Map.get(update, "arrival")),
        arrival_uncertainty: parse_uncertainty(Map.get(update, "arrival")),
        departure_time: time(Map.get(update, "departure")),
        departure_uncertainty: parse_uncertainty(Map.get(update, "departure")),
        stop_sequence: Map.get(update, "stop_sequence"),
        schedule_relationship: best_schedule_relationship(base.schedule_relationship, update),
        status: Map.get(update, "boarding_status")
    }
  end

  defp time(%{"time" => time}) when is_integer(time) do
    Parse.Timezone.unix_to_local(time)
  end

  defp time(_) do
    nil
  end

  defp parse_uncertainty(%{"uncertainty" => uncertainty}) when is_integer(uncertainty) do
    uncertainty
  end

  defp parse_uncertainty(_), do: nil

  defp vehicle_id(%{"vehicle" => %{"id" => id}}), do: id
  defp vehicle_id(_), do: nil

  defp best_schedule_relationship(relationship, update)

  defp best_schedule_relationship(:cancelled = relationship, _update) do
    relationship
  end

  defp best_schedule_relationship(relationship, update) do
    if update_relationship = schedule_relationship(Map.get(update, "schedule_relationship")) do
      update_relationship
    else
      relationship
    end
  end

  for relationship <- ~w(added skipped unscheduled no_data)a do
    binary = relationship |> Atom.to_string() |> String.upcase()
    defp schedule_relationship(unquote(binary)), do: unquote(relationship)
  end

  defp schedule_relationship("CANCELED"), do: :cancelled
  defp schedule_relationship(_), do: nil

  defp parse_revenue(false), do: :NON_REVENUE

  defp parse_revenue(_), do: :REVENUE

  defp parse_update_type("mid_trip"), do: :mid_trip
  defp parse_update_type("at_terminal"), do: :at_terminal
  defp parse_update_type("reverse_trip"), do: :reverse_trip
  defp parse_update_type(_), do: nil
end
