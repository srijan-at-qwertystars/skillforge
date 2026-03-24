"""
pytest conftest.py for Selenium WebDriver tests.

Features:
  - Browser fixture with Chrome/Firefox/Edge support
  - Headless mode toggle
  - Selenium Grid remote execution
  - Automatic screenshot on test failure
  - Page source and console log capture on failure
  - Custom CLI options (--browser, --headless, --grid-url, --base-url)

Usage:
  pytest tests/ --browser chrome --headless
  pytest tests/ --grid-url http://localhost:4444
  pytest tests/ --browser firefox --base-url http://staging.example.com
"""

import os
import pytest
from datetime import datetime
from selenium import webdriver
from selenium.webdriver.chrome.options import Options as ChromeOptions
from selenium.webdriver.firefox.options import Options as FirefoxOptions
from selenium.webdriver.edge.options import Options as EdgeOptions


# ---------------------------------------------------------------------------
# CLI Options
# ---------------------------------------------------------------------------

def pytest_addoption(parser):
    parser.addoption(
        "--browser",
        default="chrome",
        choices=["chrome", "firefox", "edge"],
        help="Browser to run tests with (default: chrome)",
    )
    parser.addoption(
        "--headless",
        action="store_true",
        default=False,
        help="Run browser in headless mode",
    )
    parser.addoption(
        "--grid-url",
        default=None,
        help="Selenium Grid URL for remote execution (e.g., http://localhost:4444)",
    )
    parser.addoption(
        "--base-url",
        default="http://localhost:8080",
        help="Application base URL (default: http://localhost:8080)",
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def base_url(request):
    """Application base URL, configurable via --base-url."""
    return request.config.getoption("--base-url")


@pytest.fixture
def driver(request):
    """
    Selenium WebDriver fixture.

    Creates a browser instance per test. Supports local and remote (Grid)
    execution. Automatically captures screenshot on test failure.
    """
    browser_name = request.config.getoption("--browser")
    headless = request.config.getoption("--headless")
    grid_url = request.config.getoption("--grid-url")

    options = _build_options(browser_name, headless)

    if grid_url:
        d = webdriver.Remote(command_executor=grid_url, options=options)
    else:
        driver_class = {
            "chrome": webdriver.Chrome,
            "firefox": webdriver.Firefox,
            "edge": webdriver.Edge,
        }[browser_name]
        d = driver_class(options=options)

    d.set_window_size(1920, 1080)
    d.set_page_load_timeout(30)
    d.implicitly_wait(5)

    yield d

    d.quit()


@pytest.fixture
def logged_in_driver(driver, base_url):
    """
    Driver fixture with a pre-authenticated session.
    Override the login logic below for your application.
    """
    driver.get(f"{base_url}/login")
    # Customize login steps for your app:
    # driver.find_element(By.ID, "username").send_keys("admin")
    # driver.find_element(By.ID, "password").send_keys("password")
    # driver.find_element(By.CSS_SELECTOR, "button[type='submit']").click()
    # WebDriverWait(driver, 10).until(EC.title_contains("Dashboard"))
    return driver


# ---------------------------------------------------------------------------
# Browser Options Builder
# ---------------------------------------------------------------------------

def _build_options(browser_name, headless):
    """Build browser-specific options with common settings."""
    if browser_name == "chrome":
        options = ChromeOptions()
        if headless:
            options.add_argument("--headless=new")
        options.add_argument("--no-sandbox")
        options.add_argument("--disable-dev-shm-usage")
        options.add_argument("--window-size=1920,1080")
        options.add_argument("--disable-gpu")
        # Suppress logging noise
        options.add_experimental_option("excludeSwitches", ["enable-logging"])
        options.set_capability("goog:loggingPrefs", {"browser": "ALL"})

    elif browser_name == "firefox":
        options = FirefoxOptions()
        if headless:
            options.add_argument("--headless")
        options.set_preference("browser.download.folderList", 2)
        options.set_preference("browser.download.manager.showWhenStarting", False)

    elif browser_name == "edge":
        options = EdgeOptions()
        if headless:
            options.add_argument("--headless=new")
        options.add_argument("--no-sandbox")
        options.add_argument("--disable-dev-shm-usage")

    else:
        raise ValueError(f"Unsupported browser: {browser_name}")

    return options


# ---------------------------------------------------------------------------
# Hooks — Screenshot & Diagnostics on Failure
# ---------------------------------------------------------------------------

@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    """Capture screenshot, page source, and console logs on test failure."""
    outcome = yield
    report = outcome.get_result()

    if report.when != "call" or not report.failed:
        return

    driver = item.funcargs.get("driver")
    if not driver:
        return

    artifact_dir = os.path.join("test-artifacts", item.nodeid.replace("::", "_"))
    os.makedirs(artifact_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    # Screenshot
    try:
        screenshot_path = os.path.join(artifact_dir, f"failure_{timestamp}.png")
        driver.save_screenshot(screenshot_path)
        print(f"\n📸 Screenshot: {screenshot_path}")
    except Exception:
        pass

    # Page source
    try:
        source_path = os.path.join(artifact_dir, f"page_{timestamp}.html")
        with open(source_path, "w", encoding="utf-8") as f:
            f.write(driver.page_source)
    except Exception:
        pass

    # Console logs (Chrome/Edge only)
    try:
        logs = driver.get_log("browser")
        if logs:
            log_path = os.path.join(artifact_dir, f"console_{timestamp}.log")
            with open(log_path, "w") as f:
                for entry in logs:
                    f.write(f"[{entry['level']}] {entry['message']}\n")
    except Exception:
        pass

    # Context info
    try:
        context_path = os.path.join(artifact_dir, f"context_{timestamp}.txt")
        with open(context_path, "w") as f:
            f.write(f"URL: {driver.current_url}\n")
            f.write(f"Title: {driver.title}\n")
            f.write(f"Timestamp: {timestamp}\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Custom Markers
# ---------------------------------------------------------------------------

def pytest_configure(config):
    config.addinivalue_line("markers", "smoke: Critical path smoke tests")
    config.addinivalue_line("markers", "regression: Full regression suite")
    config.addinivalue_line("markers", "slow: Tests that take >30 seconds")
    config.addinivalue_line("markers", "requires_grid: Tests requiring Selenium Grid")
