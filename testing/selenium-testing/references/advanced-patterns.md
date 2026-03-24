# Advanced Selenium Patterns

## Table of Contents

- [BiDi Protocol](#bidi-protocol)
  - [Network Interception](#network-interception)
  - [Console Log Capture](#console-log-capture)
  - [Authentication Handling](#authentication-handling)
  - [DOM Mutation Observation](#dom-mutation-observation)
- [Chrome DevTools Protocol Integration](#chrome-devtools-protocol-integration)
  - [Performance Metrics](#performance-metrics)
  - [Network Throttling](#network-throttling)
  - [Geolocation Mocking](#geolocation-mocking)
  - [Device Emulation](#device-emulation)
  - [Request Interception via CDP](#request-interception-via-cdp)
  - [Coverage Collection](#coverage-collection)
- [Custom ExpectedConditions](#custom-expectedconditions)
  - [Python Custom Conditions](#python-custom-conditions)
  - [Java Custom Conditions](#java-custom-conditions)
  - [Composing Conditions](#composing-conditions)
- [Advanced Actions API](#advanced-actions-api)
  - [Pointer Sequences](#pointer-sequences)
  - [Keyboard Sequences](#keyboard-sequences)
  - [Wheel (Scroll) Actions](#wheel-scroll-actions)
  - [Pen and Touch Input](#pen-and-touch-input)
- [Shadow DOM Interaction](#shadow-dom-interaction)
  - [Accessing Shadow Roots](#accessing-shadow-roots)
  - [Nested Shadow DOMs](#nested-shadow-doms)
  - [Shadow DOM with JavaScript Fallback](#shadow-dom-with-javascript-fallback)
- [Web Components Testing](#web-components-testing)
- [Multi-Window Orchestration](#multi-window-orchestration)
  - [Popup Handling Patterns](#popup-handling-patterns)
  - [Cross-Window Communication Testing](#cross-window-communication-testing)
- [Browser Extensions in Tests](#browser-extensions-in-tests)
- [Selenium Grid Observability](#selenium-grid-observability)
  - [Jaeger Tracing](#jaeger-tracing)
  - [VNC Live View](#vnc-live-view)
  - [GraphQL API Monitoring](#graphql-api-monitoring)
- [SeleniumManager Deep Dive](#seleniummanager-deep-dive)
- [W3C WebDriver Spec Compliance](#w3c-webdriver-spec-compliance)

---

## BiDi Protocol

Selenium 4 introduces the WebDriver BiDi (Bidirectional) protocol, enabling real-time event-driven communication between the test client and the browser. Unlike classic WebDriver (request/response), BiDi supports server-pushed events via WebSockets.

### Network Interception

Intercept, modify, or mock HTTP requests before they reach the server.

**Python:**
```python
from selenium import webdriver
from selenium.webdriver.common.bidi.network import NetworkInterceptor

driver = webdriver.Chrome()

# Intercept all requests and add custom header
def intercept_request(request):
    headers = dict(request.headers)
    headers["X-Custom-Auth"] = "Bearer test-token-12345"
    return request.create_response(headers=headers)

interceptor = NetworkInterceptor(driver)
interceptor.intercept(intercept_request)

driver.get("https://api.example.com/dashboard")
```

**Java:**
```java
try (NetworkInterceptor interceptor = new NetworkInterceptor(
        driver,
        Route.matching(req -> req.getUri().contains("/api/"))
             .to(() -> req -> new HttpResponse()
                 .setStatus(200)
                 .addHeader("Content-Type", "application/json")
                 .setContent(Contents.utf8String("{\"mocked\":true}"))))) {
    driver.get("https://example.com");
}
```

### Console Log Capture

Capture browser console output (log, warn, error) in real time.

**Python:**
```python
from selenium.webdriver.common.log import Log

# Using BiDi — get console messages as events
async with driver.bidi_connection() as connection:
    log = Log(driver, connection)
    async with log.mutation_events() as event:
        driver.get("https://example.com")
        # events are captured asynchronously

# CDP fallback for Chrome/Edge
driver.execute_cdp_cmd("Runtime.enable", {})
logs = driver.get_log("browser")
for entry in logs:
    print(f"[{entry['level']}] {entry['message']}")
```

**Java:**
```java
DevTools devTools = ((ChromeDriver) driver).getDevTools();
devTools.createSession();
devTools.send(Runtime.enable());

devTools.addListener(Runtime.consoleAPICalled(), event -> {
    System.out.printf("[%s] %s%n",
        event.getType(),
        event.getArgs().stream()
             .map(RemoteObject::getValue)
             .map(Optional::toString)
             .collect(Collectors.joining(" ")));
});

driver.get("https://example.com");
```

### Authentication Handling

Handle HTTP Basic/Digest authentication and browser auth popups.

**Python — BiDi network auth:**
```python
# Register authentication handler
from selenium.webdriver.common.bidi.network import AuthHandler

handler = AuthHandler(driver)
handler.add_credentials(
    uri_pattern="*://secure.example.com/*",
    username="admin",
    password="secret123"
)
driver.get("https://secure.example.com/protected")
```

**Python — CDP approach (Chrome):**
```python
import base64

credentials = base64.b64encode(b"admin:secret123").decode()
driver.execute_cdp_cmd("Network.setExtraHTTPHeaders", {
    "headers": {"Authorization": f"Basic {credentials}"}
})
driver.get("https://secure.example.com/protected")
```

**Java — DevTools auth:**
```java
DevTools devTools = ((ChromeDriver) driver).getDevTools();
devTools.createSession();

Predicate<URI> uriPredicate = uri -> uri.getHost().contains("secure.example.com");
((HasAuthentication) driver).register(uriPredicate, UsernameAndPassword.of("admin", "secret123"));
driver.get("https://secure.example.com/protected");
```

---

## Chrome DevTools Protocol Integration

### Performance Metrics

Collect detailed performance metrics directly from the browser engine.

**Python:**
```python
driver.execute_cdp_cmd("Performance.enable", {})
driver.get("https://example.com")

metrics = driver.execute_cdp_cmd("Performance.getMetrics", {})
metrics_dict = {m["name"]: m["value"] for m in metrics["metrics"]}

print(f"DOM Content Loaded: {metrics_dict.get('DomContentLoaded', 'N/A')}s")
print(f"JS Heap Used: {metrics_dict.get('JSHeapUsedSize', 0) / 1024 / 1024:.2f} MB")
print(f"Layout Count: {metrics_dict.get('LayoutCount', 0)}")
print(f"Nodes: {metrics_dict.get('Nodes', 0)}")
```

**Java:**
```java
DevTools devTools = ((ChromeDriver) driver).getDevTools();
devTools.createSession();
devTools.send(Performance.enable(Optional.empty()));

driver.get("https://example.com");
List<Metric> metrics = devTools.send(Performance.getMetrics());
metrics.forEach(m -> System.out.printf("%s: %.2f%n", m.getName(), m.getValue()));
```

### Network Throttling

Simulate various network conditions — 3G, offline, or custom bandwidth.

```python
# Simulate slow 3G
driver.execute_cdp_cmd("Network.emulateNetworkConditions", {
    "offline": False,
    "latency": 400,          # ms
    "downloadThroughput": 500 * 1024 / 8,  # 500 Kbps
    "uploadThroughput": 250 * 1024 / 8,    # 250 Kbps
})

# Simulate offline
driver.execute_cdp_cmd("Network.emulateNetworkConditions", {
    "offline": True,
    "latency": 0,
    "downloadThroughput": 0,
    "uploadThroughput": 0,
})

# Reset to normal
driver.execute_cdp_cmd("Network.emulateNetworkConditions", {
    "offline": False,
    "latency": 0,
    "downloadThroughput": -1,  # no throttle
    "uploadThroughput": -1,
})
```

### Geolocation Mocking

Override the browser's geolocation API.

```python
driver.execute_cdp_cmd("Emulation.setGeolocationOverride", {
    "latitude": 37.7749,
    "longitude": -122.4194,
    "accuracy": 100
})
driver.get("https://maps.example.com")
```

```java
devTools.send(Emulation.setGeolocationOverride(
    Optional.of(37.7749),   // latitude
    Optional.of(-122.4194), // longitude
    Optional.of(100)        // accuracy
));
```

### Device Emulation

Emulate mobile devices with specific screen sizes, user agents, and pixel ratios.

```python
device_metrics = {
    "width": 375,
    "height": 812,
    "deviceScaleFactor": 3,
    "mobile": True
}
driver.execute_cdp_cmd("Emulation.setDeviceMetricsOverride", device_metrics)
driver.execute_cdp_cmd("Emulation.setUserAgentOverride", {
    "userAgent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
                 "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
})
driver.get("https://example.com")
```

### Request Interception via CDP

Block specific resource types to speed up tests.

```python
driver.execute_cdp_cmd("Fetch.enable", {
    "patterns": [
        {"urlPattern": "*.png", "requestStage": "Request"},
        {"urlPattern": "*.jpg", "requestStage": "Request"},
        {"urlPattern": "*google-analytics*", "requestStage": "Request"},
    ]
})
```

### Coverage Collection

Measure CSS and JavaScript coverage to identify unused code.

```python
driver.execute_cdp_cmd("Profiler.enable", {})
driver.execute_cdp_cmd("Profiler.startPreciseCoverage", {
    "callCount": True, "detailed": True
})
driver.execute_cdp_cmd("CSS.enable", {})
driver.execute_cdp_cmd("CSS.startRuleUsageTracking", {})

driver.get("https://example.com")
# Interact with the page...

js_coverage = driver.execute_cdp_cmd("Profiler.takePreciseCoverage", {})
css_coverage = driver.execute_cdp_cmd("CSS.stopRuleUsageTracking", {})
```

---

## Custom ExpectedConditions

### Python Custom Conditions

Create reusable wait conditions for complex scenarios.

```python
from selenium.webdriver.support import expected_conditions as EC

class element_has_css_class:
    """Wait until an element has a specific CSS class."""
    def __init__(self, locator, css_class):
        self.locator = locator
        self.css_class = css_class

    def __call__(self, driver):
        element = driver.find_element(*self.locator)
        if self.css_class in element.get_attribute("class"):
            return element
        return False

class page_has_loaded:
    """Wait for document.readyState to be 'complete' and jQuery (if present) to finish."""
    def __call__(self, driver):
        ready = driver.execute_script("return document.readyState") == "complete"
        jquery_done = driver.execute_script(
            "return (typeof jQuery === 'undefined') || (jQuery.active === 0)"
        )
        return ready and jquery_done

class url_matches_pattern:
    """Wait until URL matches a regex pattern."""
    def __init__(self, pattern):
        self.pattern = pattern

    def __call__(self, driver):
        import re
        return bool(re.match(self.pattern, driver.current_url))

# Usage
wait = WebDriverWait(driver, 10)
wait.until(element_has_css_class((By.ID, "status"), "active"))
wait.until(page_has_loaded())
wait.until(url_matches_pattern(r"https://example\.com/dashboard/\d+"))
```

### Java Custom Conditions

```java
public class CustomConditions {
    public static ExpectedCondition<WebElement> elementHasCssClass(By locator, String cssClass) {
        return new ExpectedCondition<>() {
            @Override
            public WebElement apply(WebDriver driver) {
                WebElement el = driver.findElement(locator);
                String classes = el.getAttribute("class");
                return (classes != null && classes.contains(cssClass)) ? el : null;
            }
            @Override
            public String toString() {
                return String.format("element %s to have class '%s'", locator, cssClass);
            }
        };
    }

    public static ExpectedCondition<Boolean> jQueryAjaxComplete() {
        return driver -> (Boolean) ((JavascriptExecutor) driver)
            .executeScript("return (typeof jQuery === 'undefined') || jQuery.active === 0");
    }

}

// Usage
wait.until(CustomConditions.elementHasCssClass(By.id("status"), "active"));
wait.until(CustomConditions.jQueryAjaxComplete());
```

### Composing Conditions

Combine multiple conditions with AND/OR logic.

```python
class all_conditions:
    """AND: all conditions must be true."""
    def __init__(self, *conditions):
        self.conditions = conditions
    def __call__(self, driver):
        results = [c(driver) for c in self.conditions]
        return all(results) and results[-1]

class any_condition:
    """OR: at least one condition must be true."""
    def __init__(self, *conditions):
        self.conditions = conditions
    def __call__(self, driver):
        for c in self.conditions:
            result = c(driver)
            if result:
                return result
        return False

# Wait for element to be visible AND have a specific class
wait.until(all_conditions(
    EC.visibility_of_element_located((By.ID, "panel")),
    element_has_css_class((By.ID, "panel"), "loaded")
))
```

---

## Advanced Actions API

### Pointer Sequences

Low-level pointer control for complex drag operations, canvas drawing, and custom gestures.

```python
from selenium.webdriver.common.actions.action_builder import ActionBuilder
from selenium.webdriver.common.actions.pointer_input import PointerInput
from selenium.webdriver.common.actions.interaction import POINTER_MOUSE

# Draw a rectangle on a canvas
canvas = driver.find_element(By.ID, "drawing-canvas")
action = ActionBuilder(driver)
pointer = action.pointer_action

pointer.move_to(canvas, 10, 10)
pointer.pointer_down()
pointer.move_to(canvas, 200, 10)
pointer.move_to(canvas, 200, 150)
pointer.move_to(canvas, 10, 150)
pointer.move_to(canvas, 10, 10)
pointer.pointer_up()
action.perform()
```

**Java — Precise pointer control:**
```java
PointerInput mouse = new PointerInput(PointerInput.Kind.MOUSE, "default mouse");
Sequence draw = new Sequence(mouse, 0);

draw.addAction(mouse.createPointerMove(Duration.ZERO, PointerInput.Origin.fromElement(canvas), 10, 10));
draw.addAction(mouse.createPointerDown(PointerInput.MouseButton.LEFT.asArg()));
draw.addAction(mouse.createPointerMove(Duration.ofMillis(100), PointerInput.Origin.fromElement(canvas), 200, 10));
draw.addAction(mouse.createPointerMove(Duration.ofMillis(100), PointerInput.Origin.fromElement(canvas), 200, 150));
draw.addAction(mouse.createPointerUp(PointerInput.MouseButton.LEFT.asArg()));

((RemoteWebDriver) driver).perform(Collections.singletonList(draw));
```

### Keyboard Sequences

Complex keyboard shortcuts and text manipulation.

```python
from selenium.webdriver.common.keys import Keys
from selenium.webdriver import ActionChains

actions = ActionChains(driver)

# Ctrl+A, Ctrl+C, Tab, Ctrl+V — select all, copy, move to next field, paste
actions.key_down(Keys.CONTROL).send_keys("a").key_up(Keys.CONTROL)
actions.key_down(Keys.CONTROL).send_keys("c").key_up(Keys.CONTROL)
actions.send_keys(Keys.TAB)
actions.key_down(Keys.CONTROL).send_keys("v").key_up(Keys.CONTROL)
actions.perform()

# Type with delays between characters (for rate-limited inputs)
for char in "slow-typed-text":
    actions = ActionChains(driver)
    actions.send_keys(char).pause(0.1).perform()
```

### Wheel (Scroll) Actions

Precise scroll control (Selenium 4+).

```python
from selenium.webdriver.common.actions.wheel_input import ScrollOrigin

# Scroll within a specific container element
scrollable = driver.find_element(By.ID, "scroll-container")
origin = ScrollOrigin.from_element(scrollable)
ActionChains(driver).scroll_from_origin(origin, 0, 500).perform()

# Scroll to a specific element
target = driver.find_element(By.ID, "footer")
ActionChains(driver).scroll_to_element(target).perform()

# Scroll from viewport center
origin = ScrollOrigin.from_viewport(400, 300)
ActionChains(driver).scroll_from_origin(origin, 0, 1000).perform()
```

---

## Shadow DOM Interaction

### Accessing Shadow Roots

Selenium 4 provides native shadow DOM access via `shadow_root`.

```python
# Access shadow root element
host = driver.find_element(By.CSS_SELECTOR, "my-component")
shadow = host.shadow_root
inner_button = shadow.find_element(By.CSS_SELECTOR, "button.inner-btn")
inner_button.click()
```

```java
WebElement host = driver.findElement(By.cssSelector("my-component"));
SearchContext shadow = host.getShadowRoot();
WebElement innerBtn = shadow.findElement(By.cssSelector("button.inner-btn"));
innerBtn.click();
```

### Nested Shadow DOMs

Handle components with multiple levels of shadow DOM.

```python
def find_in_nested_shadow(driver, *selectors):
    """Traverse nested shadow DOMs.
    Usage: find_in_nested_shadow(driver, "outer-comp", "inner-comp", "button.target")
    """
    element = driver.find_element(By.CSS_SELECTOR, selectors[0])
    for selector in selectors[1:-1]:
        shadow = element.shadow_root
        element = shadow.find_element(By.CSS_SELECTOR, selector)
    shadow = element.shadow_root
    return shadow.find_element(By.CSS_SELECTOR, selectors[-1])

button = find_in_nested_shadow(driver, "app-shell", "nav-menu", "a.menu-link")
button.click()
```

---

## Multi-Window Orchestration

### Popup Handling Patterns

```python
def handle_popup(driver, trigger_action, popup_handler, timeout=10):
    """Execute action that triggers popup, handle it, return to original window."""
    original = driver.current_window_handle
    original_handles = set(driver.window_handles)

    trigger_action()

    WebDriverWait(driver, timeout).until(
        lambda d: len(d.window_handles) > len(original_handles)
    )
    new_handle = (set(driver.window_handles) - original_handles).pop()
    driver.switch_to.window(new_handle)

    result = popup_handler(driver)

    driver.close()
    driver.switch_to.window(original)
    return result

# Usage
result = handle_popup(
    driver,
    trigger_action=lambda: driver.find_element(By.ID, "open-popup").click(),
    popup_handler=lambda d: d.find_element(By.ID, "result").text
)
```

---

## Browser Extensions in Tests

Load browser extensions for testing or to augment test capabilities.

**Chrome:**
```python
options = webdriver.ChromeOptions()
# Load unpacked extension from directory
options.add_argument("--load-extension=/path/to/extension")
# Load packed .crx extension
options.add_extension("/path/to/extension.crx")
driver = webdriver.Chrome(options=options)
```

**Firefox:**
```python
driver = webdriver.Firefox()
driver.install_addon("/path/to/extension.xpi", temporary=True)
```

**Use case — Ad blocker for cleaner tests:**
```python
options = webdriver.ChromeOptions()
options.add_extension("ublock_origin.crx")
driver = webdriver.Chrome(options=options)
# Pages load without ads, reducing flakiness from ad elements
```

---

## Selenium Grid Observability

### Jaeger Tracing

Grid 4 supports distributed tracing via OpenTelemetry/Jaeger for diagnosing slow sessions.

```bash
# Start Jaeger for trace collection
docker run -d --name jaeger \
  -p 16686:16686 -p 14250:14250 \
  jaegertracing/all-in-one:latest

# Start Grid with tracing enabled
java -Dotel.traces.exporter=jaeger \
     -Dotel.exporter.jaeger.endpoint=http://localhost:14250 \
     -Dotel.resource.attributes=service.name=selenium-grid \
     -jar selenium-server-4.x.jar standalone
```

Traces show: session creation time, command execution duration, element lookup time, and node selection latency.

### VNC Live View

Watch tests execute in real time using VNC-enabled Grid nodes.

```yaml
# docker-compose.yml — Use debug images for VNC
chrome-debug:
  image: selenium/node-chrome:4-debug
  ports:
    - "7900:7900"   # noVNC web viewer
  environment:
    - SE_VNC_NO_PASSWORD=true
```

Access via browser: `http://localhost:7900` — live view of the browser session.

### GraphQL API Monitoring

Grid 4 exposes a GraphQL endpoint for querying grid state.

```python
import requests

query = """
{
  grid {
    totalSlots
    usedSlots
    sessionCount
    maxSession
    nodeCount
  }
  nodesInfo {
    nodes {
      id
      status
      sessionCount
      maxSession
      stereotypes
      sessions {
        id
        capabilities
        startTime
      }
    }
  }
}
"""

response = requests.post("http://localhost:4444/graphql", json={"query": query})
grid_data = response.json()
print(f"Grid utilization: {grid_data['data']['grid']['usedSlots']}/{grid_data['data']['grid']['totalSlots']}")
```

---

## SeleniumManager Deep Dive

SeleniumManager (built in Rust, bundled with Selenium 4.6+) automates browser and driver management.

**How it works:**
1. Detects installed browsers and their versions
2. Downloads the matching driver binary (chromedriver, geckodriver, msedgedriver)
3. Caches drivers in `~/.cache/selenium/` (Linux/macOS) or `%LOCALAPPDATA%\selenium\` (Windows)
4. Supports Chrome for Testing (CfT) — downloads a specific Chrome version if needed

**Configuration via environment variables:**
```bash
SE_MANAGER_LOG=DEBUG            # verbose logging
SE_MANAGER_BROWSER=chrome       # force browser
SE_MANAGER_BROWSER_VERSION=120  # pin browser version
SE_MANAGER_DRIVER_VERSION=120.0.6099.109  # pin driver version
SE_MANAGER_OFFLINE=true         # use cached only
SE_MANAGER_CACHE_PATH=/custom/cache  # custom cache dir
SE_MANAGER_PROXY=http://proxy:8080   # HTTP proxy
```

**CLI usage:**
```bash
# Check resolved driver/browser
selenium-manager --browser chrome --debug
selenium-manager --browser firefox --browser-version 121
selenium-manager --browser chrome --driver-version 120.0.6099.109
```

---

## W3C WebDriver Spec Compliance

Selenium 4 exclusively uses the W3C WebDriver protocol (no legacy JSON Wire Protocol).

**Key differences from legacy:**
- Capabilities use `alwaysMatch` and `firstMatch` instead of `desiredCapabilities`
- Element IDs use the `element-6066-11e4-a52e-4f735466cecf` key
- Actions API follows W3C input sources (pointer, key, wheel)
- Error responses use standardized error codes

**Ensuring W3C compliance in capabilities:**
```python
from selenium.webdriver.common.desired_capabilities import DesiredCapabilities

options = webdriver.ChromeOptions()
options.set_capability("browserName", "chrome")
options.set_capability("platformName", "linux")
# W3C standard timeout configuration
options.set_capability("timeouts", {
    "implicit": 5000,
    "pageLoad": 30000,
    "script": 10000
})
```

**W3C standard error codes:**
| Error Code | Description |
|---|---|
| `no such element` | Element not found by locator |
| `stale element reference` | Element no longer in DOM |
| `element not interactable` | Element not visible/enabled |
| `invalid element state` | Operation invalid for current state |
| `javascript error` | JS execution failed |
| `timeout` | Operation exceeded timeout |
| `no such window` | Window/tab was closed |
| `session not created` | Driver/browser version mismatch |
| `unknown command` | Command not recognized |
