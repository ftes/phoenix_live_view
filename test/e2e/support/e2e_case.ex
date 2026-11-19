defmodule Phoenix.LiveViewTest.E2E.Case do
  @moduledoc """
  The fixtures of the e2e tests (`test-fixtures.js`: `page`'s checks, `request`, coverage) and
  the config's `projects`.

  Each module runs once per project (`parameterize: projects()`), each a desktop device, and
  gets Playwright Test's `browser`, `browserName` (`browser_name`), `context` and `page` from
  `Playwright.Case`; `PW_BROWSER=firefox` runs one project, as `--project`.

  The `page` fixture's checks (no unhandled page errors unless `ignore_js_errors`, no
  `[data-phx-skip]` left) run after the test, in an `on_exit`, as the fixture's teardown.
  `@tag ignore_js_errors: true` (or `@describetag`, `@moduletag`) is
  `test.use({ ignoreJSErrors: true })`.

  On Chromium, each test records the page's JS and CSS coverage (`autoTestFixture`) and dumps it
  to `test/e2e/test-results/coverage-dumps`, unless `PW_NO_COVERAGE` is set;
  `test/e2e/coverage-report.js` turns the dumps into the report monocart-reporter wrote.
  """

  alias Playwright.{APIRequest, Coverage, Expect, Page}
  alias Playwright.Test.BrowserPool

  @devices %{
    "chromium" => "Desktop Chrome",
    "firefox" => "Desktop Firefox",
    "webkit" => "Desktop Safari"
  }

  @doc "The config's `projects`: all browsers, or `PW_BROWSER`'s."
  def projects do
    names =
      if name = System.get_env("PW_BROWSER"), do: [name], else: ["chromium", "firefox", "webkit"]

    for name <- names,
        do: Playwright.Test.parameters(Playwright.device(Map.fetch!(@devices, name)))
  end

  defmacro __using__(opts) do
    quote do
      use Playwright.Case,
          Keyword.merge(
            [async: true, parameterize: Phoenix.LiveViewTest.E2E.Case.projects()],
            unquote(opts)
          )

      import Phoenix.LiveViewTest.E2E.Utils

      alias Playwright.{
        APIRequestContext,
        APIResponse,
        ConsoleMessage,
        Dialog,
        Download,
        Promise,
        Request,
        Route,
        WebSocketRoute
      }

      setup ctx do
        Phoenix.LiveViewTest.E2E.Case.page_fixture(ctx)
      end
    end
  end

  @doc false
  def page_fixture(%{browser: browser, page: page} = ctx) do
    # pageChecks: the errors outlive the test process, for the teardown in on_exit
    {:ok, errors} = Agent.start(fn -> [] end)
    Page.on(page, :page_error, fn error -> Agent.update(errors, &(&1 ++ [error])) end)
    ignore_js_errors = Map.get(ctx, :ignore_js_errors, false)

    ExUnit.Callbacks.on_exit(fn ->
      unhandled_errors = Agent.get(errors, & &1)
      Agent.stop(errors)

      if not ignore_js_errors do
        ExUnit.Assertions.assert(
          unhandled_errors == [],
          "Detected an unhandled JavaScript Error!"
        )
      end

      page |> Page.locator("[data-phx-skip]") |> Expect.to_have_count!(0)
    end)

    if ctx.browser_name == :chromium and !System.get_env("PW_NO_COVERAGE") do
      coverage_fixture(page)
    end

    # Playwright Test's `request` fixture: a request context with the config's `use`,
    # disposed at the end of the test.
    request =
      browser |> BrowserPool.playwright() |> Playwright.request() |> APIRequest.new_context!()

    %{request: request}
  end

  @coverage_dir "test/e2e/test-results/coverage-dumps"

  # autoTestFixture: coverage API is chromium only
  defp coverage_fixture(page) do
    coverage = Page.coverage(page)
    Coverage.start_js_coverage!(coverage, reset_on_navigation: false)
    Coverage.start_css_coverage!(coverage, reset_on_navigation: false)

    # registered after the page's checks, so it runs before them, as upstream's teardown order
    ExUnit.Callbacks.on_exit(fn ->
      js_coverage = Coverage.stop_js_coverage!(coverage)
      css_coverage = Coverage.stop_css_coverage!(coverage)
      # coverage-report.js adds the source map of phoenix_live_view.esm.js and the report
      File.mkdir_p!(@coverage_dir)

      path =
        Path.join(@coverage_dir, "#{System.pid()}-#{System.unique_integer([:positive])}.json")

      File.write!(path, JSON.encode!(js_coverage ++ css_coverage))
    end)
  end
end
