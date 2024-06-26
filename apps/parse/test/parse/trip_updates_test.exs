defmodule Parse.TripUpdatesTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Parse.TripUpdates
  alias Parse.Realtime.TripUpdate.StopTimeEvent

  describe "parse/1" do
    test "can parse an Enhanced JSON file" do
      trip = %{
        "trip_id" => "CR-Weekday-Spring-17-205",
        "start_date" => "2017-08-09",
        "schedule_relationship" => "SCHEDULED",
        "route_id" => "CR-Haverhill",
        "direction_id" => 0,
        "revenue" => true,
        "last_trip" => false
      }

      update = %{
        "stop_id" => "place-north",
        "stop_sequence" => 6,
        "arrival" => %{
          "time" => 1_502_290_000
        },
        "departure" => %{
          "time" => 1_502_290_500,
          "uncertainty" => 60
        }
      }

      body =
        Jason.encode!(%{
          entity: [
            %{
              trip_update: %{
                trip: trip,
                stop_time_update: [update]
              }
            }
          ]
        })

      assert [%Model.Prediction{}] = parse(body)
    end
  end

  describe "parse_trip_update/1" do
    test "parses a vehicle ID if present" do
      update = %{
        trip: %{
          trip_id: "trip",
          route_id: "route",
          direction_id: 0,
          schedule_relationship: :SCHEDULED,
          revenue: true
        },
        stop_time_update: [
          %{
            stop_id: "stop",
            stop_sequence: 5,
            arrival: %{
              time: 1,
              uncertainty: 60
            },
            departure: nil,
            schedule_relationship: :SCHEDULED
          }
        ],
        update_type: "mid_trip",
        vehicle: %{
          id: "vehicle"
        }
      }

      [actual] = parse_trip_update(update)

      assert %Model.Prediction{
               trip_id: "trip",
               route_id: "route",
               stop_id: "stop",
               vehicle_id: "vehicle",
               stop_sequence: 5,
               arrival_time: %DateTime{},
               arrival_uncertainty: 60,
               departure_time: nil,
               departure_uncertainty: nil,
               revenue: :REVENUE,
               last_trip?: false,
               update_type: :mid_trip
             } = actual
    end

    test "does not require a vehicle ID" do
      update = %{
        trip: %{
          trip_id: "trip",
          route_id: "route",
          direction_id: 0,
          schedule_relationship: :SCHEDULED
        },
        stop_time_update: [
          %{
            stop_id: "stop",
            stop_sequence: 5,
            arrival: %{
              time: 1
            },
            departure: nil,
            schedule_relationship: :SCHEDULED
          }
        ],
        update_type: "mid_trip",
        vehicle: nil
      }

      [actual] = parse_trip_update(update)

      assert %Model.Prediction{
               vehicle_id: nil
             } = actual
    end

    test "parses revenue value for trip" do
      update = %{
        trip: %{
          trip_id: "trip",
          route_id: "route",
          direction_id: 0,
          schedule_relationship: :SCHEDULED,
          revenue: false
        },
        stop_time_update: [
          %{
            stop_id: "stop",
            stop_sequence: 5,
            arrival: %{
              time: 1
            },
            departure: nil,
            schedule_relationship: :SCHEDULED
          }
        ],
        update_type: "mid_trip",
        vehicle: nil
      }

      [actual] = parse_trip_update(update)

      assert %Model.Prediction{
               vehicle_id: nil,
               revenue: :NON_REVENUE
             } = actual
    end

    test "parses last_trip? value for trip" do
      update = %{
        trip: %{
          trip_id: "trip",
          route_id: "route",
          direction_id: 0,
          schedule_relationship: :SCHEDULED,
          last_trip?: true
        },
        stop_time_update: [
          %{
            stop_id: "stop",
            stop_sequence: 5,
            arrival: %{
              time: 1
            },
            departure: nil,
            schedule_relationship: :SCHEDULED
          }
        ],
        update_type: "mid_trip",
        vehicle: nil
      }

      [actual] = parse_trip_update(update)

      assert %Model.Prediction{
               vehicle_id: nil,
               last_trip?: true,
               update_type: :mid_trip
             } = actual

      update = put_in(update.update_type, "at_terminal")

      [actual] = parse_trip_update(update)

      assert %Model.Prediction{
               vehicle_id: nil,
               last_trip?: true,
               update_type: :at_terminal
             } = actual

      update = put_in(update.update_type, "reverse_trip")

      [actual] = parse_trip_update(update)

      assert %Model.Prediction{
               vehicle_id: nil,
               last_trip?: true,
               update_type: :reverse_trip
             } = actual
    end

    test "parses update_type values for trip" do
      update = %{
        trip: %{
          trip_id: "trip",
          route_id: "route",
          direction_id: 0,
          schedule_relationship: :SCHEDULED,
          last_trip?: true
        },
        stop_time_update: [
          %{
            stop_id: "stop",
            stop_sequence: 5,
            arrival: %{
              time: 1
            },
            departure: nil,
            schedule_relationship: :SCHEDULED
          }
        ],
        update_type: "mid_trip",
        vehicle: nil
      }

      [actual] = parse_trip_update(update)

      assert %Model.Prediction{
               vehicle_id: nil,
               last_trip?: true
             } = actual
    end
  end

  describe "parse_stop_time_event/1" do
    test "returns a local datetime if the time is present" do
      ndt = ~N[2017-01-01T00:00:00]
      expected = Timex.to_datetime(ndt, "America/New_York")
      event = %StopTimeEvent{time: DateTime.to_unix(expected)}
      actual = parse_stop_time_event(event)
      assert expected == actual
    end

    test "returns nil in other cases" do
      assert parse_stop_time_event(%StopTimeEvent{time: nil}) == nil
      assert parse_stop_time_event(%StopTimeEvent{time: 0}) == nil
      assert parse_stop_time_event(nil) == nil
    end
  end
end
