# Selenium Troubleshooting Guide

## Table of Contents

- [StaleElementReferenceException](#staleelementreferenceexception)
  - [Root Causes](#stale-root-causes)
  - [Fix Strategies](#stale-fix-strategies)
  - [Retry Decorator Pattern](#retry-decorator-pattern)
- [NoSuchElementException](#nosuchelementexception)
  - [Debugging Steps](#nosuch-debugging-steps)
  - [Common Causes](#nosuch-common-causes)
  - [Dynamic Content Solutions](#dynamic-content-solutions)
- [ElementNotInteractableException](#elementnotinteractableexception)
  - [Visibility vs Interactability](#visibility-vs-interactability)
  - [Fix Strategies](#interactable-fix-strategies)
- [TimeoutException](#timeoutexception)
  - [Diagnosis Approach](#timeout-diagnosis)
  - [Common Patterns](#timeout-patterns)
- [WebDriverException — Driver Version Mismatch](#webdriverexception--driver-version-mismatch)
  - [Diagnosing Version Issues](#version-diagnosis)
  - [Resolution Strategies](#version-resolution)
- [Flaky Test Patterns and Fixes](#flaky-test-patterns-and-fixes)
  - [Race Conditions](#race-conditions)
  - [Animation Interference](#animation-interference)
  - [Test Data Pollution](#test-data-pollution)
  - [Non-Deterministic Ordering](#non-deterministic-ordering)
  - [Flakiness Detection Framework](#flakiness-detection-framework)
- [Session Management Issues](#session-management-issues)
  - [Session Not Created](#session-not-created)
  - [Session Leaks](#session-leaks)
  - [Zombie Processes](#zombie-processes)
- [Memory Leaks in Long Test Suites](#memory-leaks-in-long-test-suites)
  - [Browser Memory Growth](#browser-memory-growth)
  - [Driver Process Accumulation](#driver-process-accumulation)
  - [Monitoring and Mitigation](#memory-monitoring)
- [Headless Mode Rendering Differences](#headless-mode-rendering-differences)
  - [Common Discrepancies](#headless-discrepancies)
  - [Configuration for Consistency](#headless-configuration)
- [CI/CD Specific Problems](#cicd-specific-problems)
  - [Missing Fonts and Rendering](#missing-fonts)
  - [Chrome Sandbox Issues](#chrome-sandbox)
  - [Display and Virtual Framebuffer](#display-issues)
  - [Container Resource Limits](#resource-limits)
- [Screenshot Comparison Drift](#screenshot-comparison-drift)
  - [Sources of Visual Drift](#drift-sources)
  - [Tolerance Strategies](#drift-tolerance)
- [Selenium Grid Session Allocation](#selenium-grid-session-allocation)
  - [Session Queue Timeout](#queue-timeout)
  - [Node Matching Failures](#node-matching)
  - [Grid Diagnostics](#grid-diagnostics)

---

## StaleElementReferenceException

Occurs when a previously found element is no longer attached to the DOM. The page may have re-rendered, an AJAX call refreshed the section, or a navigation occurred.

### Stale Root Causes

1. **Page re-render** — SPA frameworks (React, Angular, Vue) re-create DOM nodes on state change
2. **AJAX content refresh** — Partial page update replaces the element's parent container
3. **Navigation** — Moving to a new page invalidates all previously found elements
4. **Component lifecycle** — Framework component destroy/recreate cycles
5. **List re-ordering** — Sorting or filtering replaces list item elements

### Stale Fix Strategies

**Strategy 1: Re-find the element when needed**
```python
# BAD — storing element reference that will go stale
button = driver.find_element(By.ID, "submit")
# ... page updates happen here ...
button.click()  # StaleElementReferenceException!

# GOOD — find immediately before interaction
driver.find_element(By.ID, "submit").click()
```

**Strategy 2: Use explicit waits that re-find**
```python
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

# Wait will keep retrying find + condition check
element = WebDriverWait(driver, 10).until(
    EC.element_to_be_clickable((By.ID, "submit"))
)
element.click()
```

**Strategy 3: Wait for staleness then find new**
```python
old_element = driver.find_element(By.ID, "results")
trigger_refresh()

# Wait for the old element to become stale
WebDriverWait(driver, 10).until(EC.staleness_of(old_element))

# Now find the fresh element
new_element = WebDriverWait(driver, 10).until(
    EC.presence_of_element_located((By.ID, "results"))
)
```

### Retry Decorator Pattern

```python
import functools
from selenium.common.exceptions import StaleElementReferenceException

def retry_on_stale(max_retries=3):
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(max_retries):
                try:
                    return func(*args, **kwargs)
                except StaleElementReferenceException:
                    if attempt == max_retries - 1:
                        raise
            return None
        return wrapper
    return decorator

@retry_on_stale(max_retries=3)
def click_result_item(driver, index):
    items = driver.find_elements(By.CSS_SELECTOR, ".result-item")
    items[index].click()
```

**Java retry pattern:**
```java
public <T> T retryOnStale(Supplier<T> action, int maxRetries) {
    for (int i = 0; i < maxRetries; i++) {
        try {
            return action.get();
        } catch (StaleElementReferenceException e) {
            if (i == maxRetries - 1) throw e;
        }
    }
    return null;
}

// Usage
retryOnStale(() -> {
    driver.findElement(By.id("submit")).click();
    return null;
}, 3);
```

---

## NoSuchElementException

Element cannot be found using the provided locator strategy.

### NoSuch Debugging Steps

1. **Verify the locator in browser DevTools** — Open Console, run `document.querySelector("your-selector")` or `$x("your-xpath")`
2. **Check for iframes** — The element may be inside a frame; switch to frame first
3. **Check timing** — Element may not have loaded yet; add explicit wait
4. **Check visibility** — Element may exist but be hidden (use `presence_of_element_located`, not `visibility`)
5. **Take a screenshot** — Capture the page state at the point of failure

### NoSuch Common Causes

**Cause 1: Element inside iframe**
```python
# WRONG
driver.find_element(By.ID, "payment-input")  # NoSuchElementException

# RIGHT — switch to iframe first
driver.switch_to.frame("payment-iframe")
driver.find_element(By.ID, "payment-input")
driver.switch_to.default_content()
```

**Cause 2: Element not yet loaded**
```python
# WRONG — immediate find after navigation
driver.get("https://example.com/dashboard")
driver.find_element(By.ID, "chart")  # NoSuchElementException

# RIGHT — wait for element
WebDriverWait(driver, 15).until(
    EC.presence_of_element_located((By.ID, "chart"))
)
```

**Cause 3: Dynamic element IDs**
```python
# WRONG — ID changes on each page load
driver.find_element(By.ID, "input_a1b2c3d4")

# RIGHT — use stable attribute
driver.find_element(By.CSS_SELECTOR, "[data-testid='username-input']")
driver.find_element(By.XPATH, "//input[@aria-label='Username']")
```

**Cause 4: Shadow DOM**
```python
# WRONG — element is inside shadow root
driver.find_element(By.CSS_SELECTOR, "custom-element .inner-button")

# RIGHT — traverse shadow root
host = driver.find_element(By.CSS_SELECTOR, "custom-element")
shadow = host.shadow_root
shadow.find_element(By.CSS_SELECTOR, ".inner-button")
```

### Dynamic Content Solutions

```python
def safe_find(driver, locator, timeout=10, context=None):
    """Find element with comprehensive error handling."""
    parent = context or driver
    try:
        return WebDriverWait(parent, timeout).until(
            EC.presence_of_element_located(locator)
        )
    except TimeoutException:
        # Capture diagnostics
        driver.save_screenshot(f"/tmp/debug_{locator[1]}.png")
        page_source = driver.page_source
        frames = driver.execute_script(
            "return Array.from(document.querySelectorAll('iframe')).map(f => f.id || f.name || f.src)"
        )
        raise NoSuchElementException(
            f"Element {locator} not found after {timeout}s. "
            f"URL: {driver.current_url}, Frames: {frames}, "
            f"Page length: {len(page_source)}"
        )
```

---

## ElementNotInteractableException

Element exists in DOM but cannot be interacted with — it may be hidden, overlapped, or disabled.

### Visibility vs Interactability

- **Present in DOM** — `presence_of_element_located` — element exists, may be hidden
- **Visible** — `visibility_of_element_located` — element is displayed (not `display:none`, not zero size)
- **Interactable** — `element_to_be_clickable` — visible AND enabled

### Interactable Fix Strategies

**Fix 1: Scroll element into viewport**
```python
element = driver.find_element(By.ID, "target")
driver.execute_script("arguments[0].scrollIntoView({block: 'center'});", element)
time.sleep(0.3)  # brief pause for scroll animation
element.click()
```

**Fix 2: Wait for overlapping element to disappear**
```python
# Common: loading overlay, modal backdrop, cookie banner
WebDriverWait(driver, 10).until(
    EC.invisibility_of_element_located((By.CSS_SELECTOR, ".loading-overlay"))
)
driver.find_element(By.ID, "submit").click()
```

**Fix 3: Handle sticky headers/footers covering elements**
```python
# Remove fixed-position elements that block clicks
driver.execute_script("""
    document.querySelectorAll('[style*="position: fixed"], [style*="position: sticky"]')
        .forEach(el => el.style.display = 'none');
""")
element.click()
```

**Fix 4: JavaScript click as last resort**
```python
element = driver.find_element(By.ID, "hidden-submit")
driver.execute_script("arguments[0].click();", element)
```

---

## TimeoutException

An explicit wait condition was not met within the specified time.

### Timeout Patterns

**Pattern: Progressive timeout with diagnostics**
```python
def wait_with_diagnostics(driver, condition, timeout=10, message=""):
    try:
        return WebDriverWait(driver, timeout).until(condition)
    except TimeoutException:
        screenshot_path = f"/tmp/timeout_{int(time.time())}.png"
        driver.save_screenshot(screenshot_path)
        console_logs = driver.get_log("browser") if hasattr(driver, "get_log") else []
        error_msgs = [log for log in console_logs if log["level"] == "SEVERE"]
        raise TimeoutException(
            f"{message}\nURL: {driver.current_url}\n"
            f"Console errors: {error_msgs}\n"
            f"Screenshot: {screenshot_path}"
        )
```

**Pattern: Increased timeouts for known-slow operations**
```python
TIMEOUTS = {
    "fast": 5,      # simple element appears
    "normal": 10,   # page load, API response
    "slow": 30,     # file upload, report generation
    "very_slow": 60 # large data processing
}

WebDriverWait(driver, TIMEOUTS["slow"]).until(
    EC.presence_of_element_located((By.ID, "generated-report"))
)
```

---

## WebDriverException — Driver Version Mismatch

The most common startup failure. The chromedriver/geckodriver version does not match the browser version.

### Version Diagnosis

```python
# Check versions programmatically
from selenium import webdriver

try:
    driver = webdriver.Chrome()
except Exception as e:
    error_msg = str(e)
    if "This version of ChromeDriver only supports" in error_msg:
        print("DRIVER VERSION MISMATCH")
        print(error_msg)
        # Extract versions from error message
```

**Command-line checks:**
```bash
# Check installed browser versions
google-chrome --version          # or chromium-browser --version
firefox --version
microsoft-edge --version

# Check driver versions
chromedriver --version
geckodriver --version
msedgedriver --version

# Check Selenium Manager resolution
python -c "from selenium.webdriver.common.selenium_manager import SeleniumManager; \
           sm = SeleniumManager(); print(sm.binary_paths(['--browser', 'chrome', '--debug']))"
```

### Version Resolution

**Solution 1: Use Selenium 4.6+ (SeleniumManager auto-resolves)**
```python
# Just use it — no manual driver management needed
driver = webdriver.Chrome()
```

**Solution 2: Pin driver version with webdriver-manager**
```python
from webdriver_manager.chrome import ChromeDriverManager
from webdriver_manager.core.os_manager import ChromeType

# Match specific Chrome version
driver_path = ChromeDriverManager(driver_version="120.0.6099.109").install()

# For Chromium
driver_path = ChromeDriverManager(chrome_type=ChromeType.CHROMIUM).install()
```

---

## Flaky Test Patterns and Fixes

### Race Conditions

**Problem: Clicking before AJAX completes**
```python
# FLAKY — click may happen before new data loads
driver.find_element(By.ID, "search").click()
results = driver.find_elements(By.CSS_SELECTOR, ".result")

# STABLE — wait for results to appear after action
driver.find_element(By.ID, "search").click()
WebDriverWait(driver, 10).until(
    lambda d: len(d.find_elements(By.CSS_SELECTOR, ".result")) > 0
)
results = driver.find_elements(By.CSS_SELECTOR, ".result")
```

**Problem: Asserting during page transition**
```python
# FLAKY — may catch old page state
driver.find_element(By.LINK_TEXT, "Next").click()
assert "Page 2" in driver.title

# STABLE — wait for new page state
driver.find_element(By.LINK_TEXT, "Next").click()
WebDriverWait(driver, 10).until(EC.title_contains("Page 2"))
```

### Animation Interference

```python
# Disable CSS animations globally for test stability
driver.execute_script("""
    const style = document.createElement('style');
    style.textContent = `
        *, *::before, *::after {
            animation-duration: 0s !important;
            animation-delay: 0s !important;
            transition-duration: 0s !important;
            transition-delay: 0s !important;
        }
    `;
    document.head.appendChild(style);
""")
```

### Test Data Pollution

```python
# FLAKY — tests depend on shared state
def test_create_user():
    create_user("testuser")
    assert user_exists("testuser")

def test_delete_user():
    delete_user("testuser")  # fails if test_create_user didn't run first

# STABLE — each test manages its own data
def test_create_user(driver):
    unique_name = f"user_{uuid.uuid4().hex[:8]}"
    create_user(unique_name)
    assert user_exists(unique_name)
    delete_user(unique_name)  # cleanup
```

### Non-Deterministic Ordering

```python
# FLAKY — asserts exact element order that may vary
items = [el.text for el in driver.find_elements(By.CSS_SELECTOR, ".item")]
assert items == ["Apple", "Banana", "Cherry"]

# STABLE — check membership, not order (if order doesn't matter)
items = {el.text for el in driver.find_elements(By.CSS_SELECTOR, ".item")}
assert items == {"Apple", "Banana", "Cherry"}
```

### Flakiness Detection Framework

```python
import pytest

def pytest_collection_modifyitems(items):
    """Mark tests that have been historically flaky."""
    flaky_tests = {"test_checkout_flow", "test_realtime_notifications"}
    for item in items:
        if item.name in flaky_tests:
            item.add_marker(pytest.mark.flaky(reruns=3, reruns_delay=2))

# Use pytest-rerunfailures for automatic retry
# pip install pytest-rerunfailures
# pytest --reruns 3 --reruns-delay 2
```

---

## Session Management Issues

### Session Leaks

```python
# WRONG — quit not called on exception
driver = webdriver.Chrome()
driver.get("https://example.com")
assert "Expected" in driver.title  # if this fails, driver.quit() never runs

# RIGHT — always use try/finally or context manager
driver = webdriver.Chrome()
try:
    driver.get("https://example.com")
    assert "Expected" in driver.title
finally:
    driver.quit()

# BEST — pytest fixture handles cleanup
@pytest.fixture
def driver():
    d = webdriver.Chrome()
    yield d
    d.quit()  # always runs, even if test fails
```

### Zombie Processes

```bash
# Find orphaned browser/driver processes
ps aux | grep -E "(chrome|chromedriver|geckodriver|firefox)" | grep -v grep

# Kill all orphaned drivers (use in CI cleanup)
pkill -f chromedriver || true
pkill -f geckodriver || true
pkill -f "chrome --headless" || true
```

---

## Memory Leaks in Long Test Suites

### Driver Process Accumulation

```python
# conftest.py — session-scoped driver with periodic restart
@pytest.fixture(scope="session")
def driver_pool():
    pool = DriverPool(max_size=3)
    yield pool
    pool.shutdown()

class DriverPool:
    def __init__(self, max_size=3):
        self.drivers = []
        self.max_size = max_size

    def acquire(self):
        if self.drivers:
            return self.drivers.pop()
        return webdriver.Chrome()

    def release(self, driver):
        driver.delete_all_cookies()
        if len(self.drivers) < self.max_size:
            self.drivers.append(driver)
        else:
            driver.quit()

    def shutdown(self):
        for d in self.drivers:
            d.quit()
```

---

## Headless Mode Rendering Differences

### Headless Discrepancies

1. **Default viewport size** — Headless may use 800x600; always set explicitly
2. **Font rendering** — Missing system fonts cause layout shifts
3. **WebGL/Canvas** — Some GPU features unavailable in headless; use `--disable-gpu` on older versions
4. **Download behavior** — Downloads need explicit directory configuration in headless
5. **PDF printing** — `driver.print_page()` works differently in headless

### Headless Configuration

```python
options = webdriver.ChromeOptions()
options.add_argument("--headless=new")
options.add_argument("--window-size=1920,1080")
options.add_argument("--force-device-scale-factor=1")
options.add_argument("--disable-gpu")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.add_argument("--disable-extensions")
options.add_argument("--font-render-hinting=none")

# Enable downloads in headless
driver = webdriver.Chrome(options=options)
driver.execute_cdp_cmd("Page.setDownloadBehavior", {
    "behavior": "allow",
    "downloadPath": "/tmp/downloads"
})
```

**Firefox headless:**
```python
options = webdriver.FirefoxOptions()
options.add_argument("--headless")
options.add_argument("--width=1920")
options.add_argument("--height=1080")
driver = webdriver.Firefox(options=options)
```

---

## CI/CD Specific Problems

### Missing Fonts

```bash
# Ubuntu/Debian — install fonts for consistent rendering
apt-get install -y fonts-liberation fonts-noto-color-emoji \
    fonts-dejavu-core fonts-freefont-ttf fontconfig

# Rebuild font cache
fc-cache -fv

# Verify fonts are available
fc-list | head -20
```

**Docker font installation:**
```dockerfile
FROM selenium/standalone-chrome:4
USER root
RUN apt-get update && apt-get install -y \
    fonts-liberation fonts-noto-color-emoji \
    && fc-cache -fv
USER seluser
```

### Chrome Sandbox

```python
# CI containers often run as root — Chrome sandbox fails
options = webdriver.ChromeOptions()
options.add_argument("--no-sandbox")           # required in Docker/CI
options.add_argument("--disable-dev-shm-usage")  # prevent /dev/shm issues
options.add_argument("--disable-setuid-sandbox")
```

**Correct /dev/shm sizing in Docker:**
```bash
# Docker run
docker run --shm-size=2g selenium/standalone-chrome:4

# Docker Compose
services:
  chrome:
    image: selenium/standalone-chrome:4
    shm_size: '2g'
```

### Display Issues

```bash
# Linux CI without display — use Xvfb
apt-get install -y xvfb
Xvfb :99 -screen 0 1920x1080x24 &
export DISPLAY=:99

# Or use xvfb-run wrapper
xvfb-run --server-args="-screen 0 1920x1080x24" pytest tests/

# Headless mode is preferred — no display server needed
# Use --headless=new with Chrome 109+
```

### Resource Limits

```yaml
# GitHub Actions — increase available resources
jobs:
  test:
    runs-on: ubuntu-latest
    env:
      MALLOC_ARENA_MAX: 2  # reduce memory fragmentation
    steps:
      - name: Free disk space
        run: |
          sudo rm -rf /usr/share/dotnet
          sudo rm -rf /opt/ghc
```

```python
# Limit Chrome memory usage in CI
options.add_argument("--js-flags=--max-old-space-size=512")
options.add_argument("--renderer-process-limit=2")
options.add_argument("--disable-background-networking")
options.add_argument("--disable-default-apps")
```

---

## Screenshot Comparison Drift

### Drift Tolerance

```python
from PIL import Image
import numpy as np

def compare_screenshots(baseline_path, actual_path, threshold=0.02):
    """Compare screenshots with tolerance for minor rendering differences."""
    baseline = np.array(Image.open(baseline_path))
    actual = np.array(Image.open(actual_path))

    if baseline.shape != actual.shape:
        actual_img = Image.open(actual_path).resize(
            (baseline.shape[1], baseline.shape[0])
        )
        actual = np.array(actual_img)

    diff = np.abs(baseline.astype(float) - actual.astype(float))
    mismatch_ratio = np.count_nonzero(diff > 10) / diff.size

    return mismatch_ratio <= threshold, mismatch_ratio

# Usage in test
match, ratio = compare_screenshots("baseline/login.png", "actual/login.png")
assert match, f"Visual regression: {ratio:.2%} pixels differ"
```

---

## Selenium Grid Session Allocation

### Queue Timeout

```python
# Default new session timeout is 300 seconds
# Configure RemoteWebDriver with longer timeout for busy grids
from selenium.webdriver.remote.webdriver import WebDriver as RemoteWebDriver

options = webdriver.ChromeOptions()
options.set_capability("se:newSessionWaitTimeout", 600)  # 10 minutes

driver = webdriver.Remote(
    command_executor="http://grid-hub:4444",
    options=options
)
```

### Grid Diagnostics

```python
# Query Grid GraphQL API for detailed diagnostics
import requests

def grid_health_check(grid_url="http://localhost:4444"):
    """Comprehensive Grid health check."""
    # Check readiness
    status = requests.get(f"{grid_url}/status").json()
    ready = status["value"]["ready"]

    # GraphQL query for details
    query = """
    {
        grid { totalSlots usedSlots sessionCount maxSession nodeCount }
        sessionsInfo {
            sessions { id capabilities startTime nodeId }
        }
    }
    """
    gql = requests.post(f"{grid_url}/graphql", json={"query": query}).json()

    grid_info = gql["data"]["grid"]
    utilization = grid_info["usedSlots"] / max(grid_info["totalSlots"], 1) * 100

    return {
        "ready": ready,
        "utilization": f"{utilization:.1f}%",
        "active_sessions": grid_info["sessionCount"],
        "total_slots": grid_info["totalSlots"],
        "node_count": grid_info["nodeCount"],
    }
```
