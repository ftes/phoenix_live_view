# End-to-end tests

This directory contains end-to-end tests that drive real browsers (Chromium, Firefox, WebKit)
against a LiveView server, with [playwright_ex](https://github.com/ftes/playwright_ex), an Elixir
port of the Playwright client, on ExUnit. They were ported one to one from the Playwright Test
(JS) suite they replace: `tests/forms.spec.exs` was `tests/forms.spec.js`.

- `test_helper.exs` defines and starts the server on port 4004 (`Phoenix.LiveViewTest.E2E.Endpoint`).
- `support/` holds the LiveViews under test, `Phoenix.LiveViewTest.E2E.Case` (the fixtures:
  `page`, `request`, `browser_name`) and `Phoenix.LiveViewTest.E2E.Utils` (`utils.js`).
- `tests/` holds the tests, one module per former spec file.

## Running the tests

```bash
$ MIX_ENV=e2e mix deps.get
$ MIX_ENV=e2e mix playwright.install # the driver and the browsers
$ npm ci && mix assets.build            # the JS under test
$ MIX_ENV=e2e mix test                  # Chromium, Firefox and WebKit
$ PW_BROWSER=firefox MIX_ENV=e2e mix test
$ PW_BROWSER=webkit MIX_ENV=e2e mix test test/e2e/tests/streams.spec.exs:9
```

A run uses all three browsers, as Playwright's `projects`: each module runs once per browser
(`parameterize:`), with `browser_name` in the context. `PW_BROWSER` runs one, as `--project`; CI
runs a job per browser. With all three, half the schedulers' modules run at once, as Playwright's
workers, and each browser keeps that many warm (`config/e2e.exs`, `test_helper.exs`).
On Linux, `MIX_ENV=e2e mix playwright.install webkit --with-deps` also installs the
browser's system dependencies.

## Debugging

Failed tests keep a trace and a screenshot in `test-results/`. The failure prints how to open the
trace:

```bash
$ MIX_ENV=e2e mix playwright.cli show-trace test/e2e/test-results/<test>/trace.zip
```

To watch a test run, give the run headed, slowed-down browsers (`launch_options` merge over
`config/e2e.exs`), and the test no timeout if you `Page.pause/1` in it:

```elixir
# config/e2e.exs
config :playwright, :test, launch_options: [headless: false, slow_mo: 500]
```

```bash
$ MIX_ENV=e2e mix test test/e2e/tests/streams.spec.exs:9 --trace
```

## Coverage

On Chromium, each test dumps its JS and CSS coverage to `test-results/coverage-dumps`
(`PW_NO_COVERAGE=1` turns this off). `npm run e2e:coverage` adds the dumps up to the report in
`test-results/coverage`, whose raw data `npm run cover:merge` merges with the JS unit tests'.
`mix test --cover` exports the Elixir coverage as before.

## Known gaps

- 4212 skips at runtime (feature detection in the page): ExUnit can't skip a running test, so it
  reports as passed. So do the browser-only skips (`test.skip(browserName === ...)`), an `if`
  around the body, as a module runs on all browsers.
- No retries: rerun the failures with `mix test --failed` (CI does, twice).
- Nested `describe` blocks are flattened: the outer one is the module, and a `describe` repeated
  in a loop is one `describe` with the loop inside.
- playwright_ex comes from git until 1.65.0-rc.2 is on Hex; `mix.exs` pins the commit.
