defmodule BeerocracyWeb.BallotMinutesLiveTest do
  use BeerocracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Beerocracy.Ballot
  alias Beerocracy.Minutes
  alias Beerocracy.Week

  # The tiles for days that have been are closed, so the week is pinned open at
  # its Monday and every weekday is still a day somebody could vote for.
  setup do
    %{today: pin_today(Week.current().monday)}
  end

  defp admin(context) do
    previous = Application.get_env(:beerocracy, :admins)
    Application.put_env(:beerocracy, :admins, ["anehx"])
    on_exit(fn -> Application.put_env(:beerocracy, :admins, previous || []) end)

    context = sign_in(context, login: "anehx", name: "Jonas")
    {:ok, view, _html} = live(context.conn, ~p"/")
    Map.put(context, :view, view)
  end

  defp ordinary(context) do
    context = sign_in(context, login: "somebody-else", name: "Mira")
    {:ok, view, _html} = live(context.conn, ~p"/")
    Map.put(context, :view, view)
  end

  # Something for the ballot to have an opinion about, so the record has
  # something to disagree with.
  defp voted(view) do
    view |> element("button[phx-value-weekday=thursday]") |> render_click()
    render_hook(view, "swipe", %{"slug" => "shamrock", "liked" => true})
    view
  end

  describe "the minutes form" do
    test "is offered to an admin", context do
      %{view: view} = admin(context)

      assert view |> element("form[phx-submit=record_visit]") |> has_element?()
    end

    test "is not offered to an ordinary voter", context do
      %{view: view} = ordinary(context)

      refute view |> element("form[phx-submit=record_visit]") |> has_element?()
    end

    test "is not offered to a stranger", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute view |> element("form[phx-submit=record_visit]") |> has_element?()
    end
  end

  describe "writing down where we went" do
    test "says so on the sheet", context do
      %{view: view} = admin(context)
      week = Week.current()

      html =
        render_submit(view, "record_visit", %{
          "week_key" => week.key,
          "weekday" => "friday",
          "slug" => "pickwick"
        })

      assert html =~ "In the end"
      assert html =~ "Friday at Mr. Pickwick Pub"
      assert html =~ "written down by Jonas"
    end

    test "demotes the vote's answer rather than hiding it", context do
      %{view: view} = admin(context)
      view = voted(view)

      assert render(view) =~ "As it stands"

      html =
        render_submit(view, "record_visit", %{
          "week_key" => Week.current().key,
          "weekday" => "friday",
          "slug" => "pickwick"
        })

      assert html =~ "What the vote said"
      refute html =~ "As it stands"
      # The ballot's own verdict is untouched.
      assert Ballot.outcome(Ballot.tally(Week.current())).places
             |> hd()
             |> Map.fetch!(:place)
             |> Map.fetch!(:slug) == "shamrock"
    end

    test "changes no votes", context do
      %{view: view} = admin(context)
      view = voted(view)

      render_submit(view, "record_visit", %{
        "week_key" => Week.current().key,
        "weekday" => "friday",
        "slug" => "pickwick"
      })

      tally = Ballot.tally(Week.current())

      assert tally.day_votes_cast == 1
      assert tally.place_votes_cast == 1
    end

    test "refuses a place that is not in the catalogue", context do
      %{view: view} = admin(context)

      html =
        render_submit(view, "record_visit", %{
          "week_key" => Week.current().key,
          "weekday" => "friday",
          "slug" => "not-a-pub"
        })

      assert html =~ "not a week and a place"
      assert Ballot.recorded_visit(Week.current()) == nil
    end
  end

  describe "an ordinary voter" do
    test "cannot write a week down, even by sending the event", context do
      %{view: view} = ordinary(context)

      html =
        render_submit(view, "record_visit", %{
          "week_key" => Week.current().key,
          "weekday" => "friday",
          "slug" => "pickwick"
        })

      assert html =~ "not yours to set"
      assert Ballot.recorded_visit(Week.current()) == nil
    end

    test "cannot clear one either", context do
      week = Week.current()
      Minutes.record(week, :friday, "pickwick", "Jonas")

      %{view: view} = ordinary(context)
      render_click(view, "clear_visit", %{"week_key" => week.key})

      assert Ballot.recorded_visit(week)
    end
  end

  describe "taking it back" do
    test "hands the week back to the vote", context do
      week = Week.current()
      Minutes.record(week, :friday, "pickwick", "Jonas")

      %{view: view} = admin(context)
      assert render(view) =~ "In the end"

      html = render_click(view, "clear_visit", %{"week_key" => week.key})

      refute html =~ "In the end"
      assert Ballot.recorded_visit(week) == nil
    end
  end

  describe "a past week on the sheet" do
    test "is marked as recorded in the archive", context do
      week = Week.current()
      last_week = Week.from_date(Date.add(week.monday, -7))

      Ballot.set_day(last_week, "Mira", "gh:2", :thursday, :yes)
      Ballot.swipe(last_week, "Mira", "gh:2", "shamrock", true)
      Minutes.record(last_week, :friday, "pickwick", "Jonas")

      %{view: view} = admin(context)
      html = render(view)

      assert html =~ "Where we went"
      assert html =~ "· recorded by Jonas"
      assert html =~ "Mr. Pickwick Pub"
    end
  end
end
