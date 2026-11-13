defmodule Phoenix.LiveViewTest.E2E.Case do
  @moduledoc """
  The fixtures of the e2e tests (`page`, `request`, `browser_name`) and the projects' devices.

  A run uses one browser, `PW_BROWSER` (see `config/e2e.exs`), and each module holds a pooled
  driver and browser (`BrowserPool.browser/0` in `setup_all`), as Playwright Test's workers.
  Tests get a fresh context with the browser's desktop device, as the `projects` of a
  Playwright config with `devices["Desktop Chrome"]` and so on.

  The `page` fixture's checks (no unhandled page errors unless `ignore_js_errors`, no
  `[data-phx-skip]` left) run after the test, in an `on_exit`, as the fixture's teardown.
  `@tag ignore_js_errors: true` (or `@describetag`, `@moduletag`) is
  `test.use({ ignoreJSErrors: true })`.

  On Chromium, each test records the page's JS and CSS coverage (`autoTestFixture`) and dumps it
  to `test/e2e/test-results/coverage-dumps`, unless `PW_NO_COVERAGE` is set;
  `test/e2e/coverage-report.js` turns the dumps into the report monocart-reporter wrote.
  """

  alias PlaywrightEx.{APIRequest, Browser, BrowserContext, Coverage, Expect, Page, Playwright}
  alias PlaywrightEx.Test.BrowserPool

  @devices %{chromium: "Desktop Chrome", firefox: "Desktop Firefox", webkit: "Desktop Safari"}

  @doc "The run's browser, as Playwright Test's `browserName`: `@tag skip: browser_name() == :webkit`."
  def browser_name, do: Application.fetch_env!(:playwright_ex, :test)[:browser_name]

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, Keyword.merge([async: true], unquote(opts))
      use PlaywrightEx.Test

      import Phoenix.LiveViewTest.E2E.Case, only: [browser_name: 0]
      import Phoenix.LiveViewTest.E2E.Utils

      alias PlaywrightEx.{
        APIRequestContext,
        APIResponse,
        Browser,
        BrowserContext,
        ConsoleMessage,
        Dialog,
        Download,
        Expect,
        Keyboard,
        Locator,
        Mouse,
        Page,
        Promise,
        Request,
        Route,
        WebSocketRoute
      }

      alias PlaywrightEx.Test.BrowserPool

      setup_all do
        Phoenix.LiveViewTest.E2E.Case.browser_fixture()
      end

      setup ctx do
        Phoenix.LiveViewTest.E2E.Case.page_fixture(ctx)
      end
    end
  end

  @doc false
  def browser_fixture do
    browser = BrowserPool.browser()
    playwright = BrowserPool.playwright(browser)

    # `devices["Desktop Chrome"]` and so on; the project's browser is the run's.
    device =
      playwright
      |> Playwright.devices()
      |> Map.fetch!(@devices[browser_name()])
      |> Map.delete(:default_browser_type)

    %{browser: browser, browser_name: browser_name(), device: device, playwright: playwright}
  end

  @doc false
  def page_fixture(%{browser: browser, device: device, playwright: playwright} = ctx) do
    context = Browser.new_context!(browser, device)
    page = BrowserContext.new_page!(context)

    # pageChecks: the errors outlive the test process, for the teardown in on_exit.
    # Listeners fire until the context closes, last in PlaywrightEx.Test's on_exit, so this one
    # is removed before the Agent stops.
    {:ok, errors} = Agent.start(fn -> [] end)
    listener = fn error -> Agent.update(errors, &(&1 ++ [error])) end
    Page.on(page, :page_error, listener)
    ignore_js_errors = Map.get(ctx, :ignore_js_errors, false)

    ExUnit.Callbacks.on_exit(fn ->
      Page.off(page, :page_error, listener)
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

    if browser_name() == :chromium and !System.get_env("PW_NO_COVERAGE") do
      coverage_fixture(page)
    end

    # Playwright Test's `request` fixture: a request context with the config's `use`,
    # disposed at the end of the test.
    request = playwright |> Playwright.request() |> APIRequest.new_context!()

    %{context: context, page: page, request: request}
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
