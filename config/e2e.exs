import Config

config :logger, :level, :error

config :phoenix_live_view, :root_tag_attribute, "phx-r"

# playwright.config.js's `use` and `outputDir`. One browser per run: PW_BROWSER=firefox.
config :playwright_ex, :test,
  browser_name: String.to_atom(System.get_env("PW_BROWSER", "chromium")),
  context_options: [base_url: "http://localhost:4004/", ignore_https_errors: true],
  trace: :retain_on_failure,
  screenshot: :only_on_failure,
  output_dir: "test/e2e/test-results"
