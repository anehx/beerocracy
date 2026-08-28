defmodule BeerocracyWeb.BallotWeatherLiveTest do
  # Not async: the forecast lives in `:persistent_term`, one entry for the whole
  # node. Two of these running at once would seed each other's weather, so they
  # are kept together and kept serial. Everything else in the ballot is async.
  use BeerocracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Beerocracy.Weather
  alias Beerocracy.Weather.Forecast
  alias Beerocracy.Week

  # The tiles for days that have been are closed, so the week is pinned open at
  # its Monday and every weekday is still a day somebody could vote for.
  setup do
    %{today: pin_today(Week.current().monday)}
  end

  describe "the outlook above each weekday" do
    test "prints the forecast above each weekday", %{conn: conn} do
      week = Week.current()

      Weather.put(
        Map.new(Week.weekdays(), fn weekday ->
          date = Week.date_of(week, weekday)

          {date,
           %Forecast{
             date: date,
             from_hour: 16,
             to_hour: 22,
             code: 0,
             temp_min: 18.6,
             temp_max: 24.4,
             rain: [{16, 5, 0.0}, {19, 12, 0.0}, {22, 20, 0.0}]
           }}
        end)
      )

      on_exit(&Weather.clear/0)
      {:ok, view, _html} = live(conn, ~p"/")

      # The hour is stated once for the row, not repeated on every tile.
      assert render(view) =~ "Outlook 16:00 - 22:00"

      for weekday <- Week.weekdays() do
        tile = view |> element("button[phx-value-weekday=#{weekday}]") |> render()

        assert tile =~ "☀️", "no weather symbol on #{weekday}"
        assert tile =~ "19 - 24°", "no temperature range on #{weekday}"
        assert tile =~ "Dry", "no rain verdict on #{weekday}"
        assert tile =~ "Clear between 16:00 and 22:00, 19 - 24°C. Dry — up to 20% chance"
      end
    end

    test "flags a soaking on the tile itself", %{conn: conn} do
      week = Week.current()
      wet = Week.date_of(week, :monday)
      dry = Week.date_of(week, :tuesday)

      Weather.put(%{
        wet => forecast(wet, code: 61, rain: [{16, 10, 0.0}, {19, 60, 3.0}, {22, 95, 3.0}]),
        dry => forecast(dry, code: 0, rain: [{16, 0, 0.0}, {19, 3, 0.0}, {22, 5, 0.0}])
      })

      on_exit(&Weather.clear/0)
      {:ok, view, _html} = live(conn, ~p"/")

      # Both days read the same temperature; only the verdict tells them apart.
      assert view
             |> element(~s{button[phx-value-weekday=monday] .day-tile-rain[data-level="3"]})
             |> render() =~ "Rain"

      assert view
             |> element(~s{button[phx-value-weekday=tuesday] .day-tile-rain[data-level="0"]})
             |> render() =~ "Dry"
    end

    test "keeps the tile intact when the forecast is unknown", %{conn: conn} do
      Weather.clear()
      {:ok, view, _html} = live(conn, ~p"/")

      # The weather line still renders, so the five tiles stay the same height.
      assert view
             |> element("button[phx-value-weekday=monday] .day-tile-weather")
             |> has_element?()

      refute view |> element("button[phx-value-weekday=monday] .day-tile-temp") |> has_element?()
    end
  end

  describe "weather meeting an outdoor place" do
    setup [:signed_in]

    test "warns when the winning day looks wet", %{view: view} do
      week = Week.current()
      thursday = Week.date_of(week, :thursday)

      Weather.put(%{
        thursday =>
          forecast(thursday, code: 61, rain: [{16, 60, 3.0}, {19, 80, 3.0}, {22, 95, 3.0}])
      })

      on_exit(&Weather.clear/0)

      tap_day(view, :thursday)
      render_hook(view, "swipe", %{"slug" => "bierfenster", "liked" => true})

      html = render(view)

      assert html =~ "Outdoors, and Thursday looks wet"
      assert html =~ "up to 95% chance"
    end

    test "stays quiet for an indoor place on the same wet day", %{view: view} do
      week = Week.current()
      thursday = Week.date_of(week, :thursday)

      Weather.put(%{
        thursday => forecast(thursday, code: 61, rain: [{16, 60, 3.0}, {22, 95, 3.0}])
      })

      on_exit(&Weather.clear/0)

      tap_day(view, :thursday)
      render_hook(view, "swipe", %{"slug" => "mccarthys", "liked" => true})

      refute render(view) =~ "Outdoors, and"
    end
  end

  defp forecast(date, overrides) do
    defaults = [
      date: date,
      from_hour: 16,
      to_hour: 22,
      code: 0,
      temp_min: 19.0,
      temp_max: 23.0,
      rain: [{16, 0, 0.0}, {19, 5, 0.0}, {22, 10, 0.0}]
    ]

    struct!(Forecast, Keyword.merge(defaults, overrides))
  end

  defp tap_day(view, weekday) do
    view |> element("button[phx-value-weekday=#{weekday}]") |> render_click()
  end

  defp signed_in(context) do
    %{conn: conn} = context = sign_in(context, name: "Jonas")
    {:ok, view, _html} = live(conn, ~p"/")
    Map.put(context, :view, view)
  end
end
