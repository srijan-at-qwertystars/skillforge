---
name: selenium-testing
description: >
  Use when writing Selenium WebDriver tests, automating browsers with Selenium in Java/Python/C#/JavaScript,
  using Selenium Grid for parallel testing, or migrating from Selenium 3 to 4. Covers locators, waits,
  Page Object Model, Actions API, browser options, and cross-browser strategies.
  Do NOT use for Playwright tests, Cypress tests, Puppeteer automation, API-only testing, or mobile-native
  app testing with Appium (though Selenium can work with Appium for web views).
---

# Selenium WebDriver 4.x Testing

## Setup and Driver Management

Use Selenium 4.6+ built-in Selenium Manager for zero-config driver management. It auto-detects browsers and downloads correct drivers for Chrome, Firefox, Edge, and Safari.

**Python:**
```python
from selenium import webdriver

driver = webdriver.Chrome()  # Selenium Manager handles driver binary
driver.get("https://example.com")
driver.quit()
```

**Java:**
```java
WebDriver driver = new ChromeDriver(); // Selenium Manager handles driver binary
driver.get("https://example.com");
driver.quit();
```

For legacy projects, use `webdriver-manager` (Python) or Bonigarcia's `WebDriverManager` (Java):

```python
# Python — pip install webdriver-manager
from selenium.webdriver.chrome.service import Service
from webdriver_manager.chrome import ChromeDriverManager
driver = webdriver.Chrome(service=Service(ChromeDriverManager().install()))
```

```java
// Java — add io.github.bonigarcia:webdrivermanager:5.x to pom.xml
WebDriverManager.chromedriver().setup();
WebDriver driver = new ChromeDriver();
```

## Selenium 4 New Features

### Relative Locators
Find elements by spatial relationship to other elements. Use `locate_with` (Python) or `RelativeLocator.withTagName` (Java).

```python
from selenium.webdriver.support.relative_locator import locate_with
password = driver.find_element(locate_with(By.TAG_NAME, "input").below(username_field))
email = driver.find_element(locate_with(By.TAG_NAME, "input").near(label_element))
```

```java
WebElement password = driver.findElement(RelativeLocator.withTagName("input").below(usernameField));
WebElement submit = driver.findElement(RelativeLocator.withTagName("button").toRightOf(cancelBtn));
```

Methods: `above()`, `below()`, `toLeftOf()`, `toRightOf()`, `near()`. Chain them for precision.

### Chrome DevTools Protocol (CDP)
Access CDP directly for network emulation, console capture, and geolocation mocking.

```python
driver.execute_cdp_cmd("Network.emulateNetworkConditions", {
    "offline": False, "latency": 100,
    "downloadThroughput": 1000, "uploadThroughput": 500
})
```

```java
DevTools devTools = ((ChromeDriver) driver).getDevTools();
devTools.createSession();
devTools.send(Network.emulateNetworkConditions(false, 100, 1000, 500, Optional.empty()));
```

### BiDi Protocol
Enable bidirectional communication for real-time event listening — console logs, network interception, DOM mutations.

### New Window API
Open new tabs or windows directly:

```python
driver.switch_to.new_window("tab")    # opens new tab
driver.switch_to.new_window("window") # opens new window
```

```java
driver.switchTo().newWindow(WindowType.TAB);
driver.switchTo().newWindow(WindowType.WINDOW);
```

## Locator Strategies

Use these `By` strategies in order of preference for stability:

| Strategy | Python | Java |
|----------|--------|------|
| ID | `By.ID, "email"` | `By.id("email")` |
| Name | `By.NAME, "user"` | `By.name("user")` |
| CSS Selector | `By.CSS_SELECTOR, ".btn-primary"` | `By.cssSelector(".btn-primary")` |
| XPath | `By.XPATH, "//div[@role='alert']"` | `By.xpath("//div[@role='alert']")` |
| Class Name | `By.CLASS_NAME, "header"` | `By.className("header")` |
| Tag Name | `By.TAG_NAME, "input"` | `By.tagName("input")` |
| Link Text | `By.LINK_TEXT, "Sign In"` | `By.linkText("Sign In")` |
| Partial Link | `By.PARTIAL_LINK_TEXT, "Sign"` | `By.partialLinkText("Sign")` |

Prefer ID > CSS selectors > XPath. Avoid brittle absolute XPaths. Use relative XPath with attributes.

## Element Interactions

```python
element.click()                          # Java: element.click()
element.send_keys("text")               # Java: element.sendKeys("text")
element.clear()                          # Java: element.clear()
element.submit()                         # submits enclosing form
text = element.text                      # Java: element.getText()
value = element.get_attribute("href")    # Java: element.getAttribute("href")
color = element.value_of_css_property("color")  # Java: element.getCssValue("color")
is_visible = element.is_displayed()      # Java: element.isDisplayed()
is_on = element.is_enabled()
is_checked = element.is_selected()
```

## Waits — NEVER Use Thread.sleep

### Explicit Wait (Preferred)
Wait for a specific condition. Always prefer explicit waits.

```python
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

element = WebDriverWait(driver, 10).until(
    EC.visibility_of_element_located((By.ID, "result"))
)
```

```java
WebDriverWait wait = new WebDriverWait(driver, Duration.ofSeconds(10));
WebElement el = wait.until(ExpectedConditions.visibilityOfElementLocated(By.id("result")));
```

Common ExpectedConditions: `presence_of_element_located`, `visibility_of_element_located`, `element_to_be_clickable`, `text_to_be_present_in_element`, `alert_is_present`, `invisibility_of_element_located`, `frame_to_be_available_and_switch_to_it`.

### Fluent Wait
Configure polling interval and ignored exceptions:

```python
from selenium.webdriver.support.wait import WebDriverWait
wait = WebDriverWait(driver, timeout=15, poll_frequency=2,
                     ignored_exceptions=[NoSuchElementException])
element = wait.until(EC.element_to_be_clickable((By.ID, "btn")))
```

```java
Wait<WebDriver> wait = new FluentWait<>(driver)
    .withTimeout(Duration.ofSeconds(15))
    .pollingEvery(Duration.ofSeconds(2))
    .ignoring(NoSuchElementException.class);
WebElement el = wait.until(ExpectedConditions.elementToBeClickable(By.id("btn")));
```

### Implicit Wait
Set once globally. Avoid mixing with explicit waits.

```python
driver.implicitly_wait(10)  # seconds
```

## Navigation

```python
driver.get("https://example.com")
driver.back()
driver.forward()
driver.refresh()
url = driver.current_url
title = driver.title
```

## Windows, Tabs, and Frames

### Window/Tab Handling
```python
original = driver.current_window_handle
driver.switch_to.new_window("tab")
driver.get("https://other.com")
driver.close()
driver.switch_to.window(original)

# Iterate all windows
for handle in driver.window_handles:
    driver.switch_to.window(handle)
```

### Frames and iFrames
```python
driver.switch_to.frame("frame_name")       # by name or id
driver.switch_to.frame(0)                   # by index
driver.switch_to.frame(element)             # by WebElement
driver.switch_to.default_content()          # back to main page
driver.switch_to.parent_frame()             # up one level
```

## Alerts

```python
alert = driver.switch_to.alert      # Java: driver.switchTo().alert()
alert.accept()                       # click OK
alert.dismiss()                      # click Cancel
text = alert.text                    # read message
alert.send_keys("input")            # type into prompt
```

## Select Dropdowns

```python
from selenium.webdriver.support.select import Select
select = Select(driver.find_element(By.ID, "country"))
select.select_by_value("us")
select.select_by_visible_text("United States")
select.select_by_index(2)
options = select.options              # all options
selected = select.first_selected_option
select.deselect_all()                 # multi-select only
```

## Actions API

```python
from selenium.webdriver import ActionChains
actions = ActionChains(driver)
actions.move_to_element(menu).perform()                   # hover
actions.double_click(element).perform()                   # double-click
actions.context_click(element).perform()                  # right-click
actions.drag_and_drop(source, target).perform()           # drag & drop
actions.key_down(Keys.CONTROL).click(el).key_up(Keys.CONTROL).perform()
actions.scroll_to_element(element).perform()              # Selenium 4
```

```java
Actions actions = new Actions(driver);
actions.moveToElement(menu).perform();
actions.doubleClick(element).perform();
actions.dragAndDrop(source, target).perform();
actions.keyDown(Keys.CONTROL).click(el).keyUp(Keys.CONTROL).perform();
actions.scrollToElement(element).perform();
```

## Screenshots

```python
driver.save_screenshot("page.png")                        # viewport
element.screenshot("element.png")                         # single element
driver.get_full_page_screenshot_as_file("full.png")       # Firefox full-page
```

Java: `File f = ((TakesScreenshot) driver).getScreenshotAs(OutputType.FILE);`

## Page Object Model (POM)

Structure tests with one class per page. Centralize locators. Keep assertions in test code only.

**Python POM:**
```python
class LoginPage:
    URL = "https://app.example.com/login"

    def __init__(self, driver):
        self.driver = driver
        self._username = (By.ID, "username")
        self._password = (By.ID, "password")
        self._submit = (By.CSS_SELECTOR, "button[type='submit']")

    def open(self):
        self.driver.get(self.URL)
        return self

    def login(self, user, pwd):
        self.driver.find_element(*self._username).send_keys(user)
        self.driver.find_element(*self._password).send_keys(pwd)
        self.driver.find_element(*self._submit).click()
        return DashboardPage(self.driver)
```

**Java POM with Page Factory:**
```java
public class LoginPage {
    private WebDriver driver;

    @FindBy(id = "username")  private WebElement usernameInput;
    @FindBy(id = "password")  private WebElement passwordInput;
    @FindBy(css = "button[type='submit']") private WebElement submitBtn;

    public LoginPage(WebDriver driver) {
        this.driver = driver;
        PageFactory.initElements(driver, this);
    }

    public DashboardPage login(String user, String pwd) {
        usernameInput.sendKeys(user);
        passwordInput.sendKeys(pwd);
        submitBtn.click();
        return new DashboardPage(driver);
    }
}
```

## Browser Options

```python
options = webdriver.ChromeOptions()  # FirefoxOptions(), EdgeOptions() for others
options.add_argument("--headless=new")
options.add_argument("--window-size=1920,1080")
options.add_argument("--proxy-server=http://proxy:8080")
options.add_experimental_option("prefs", {
    "download.default_directory": "/tmp/downloads",
    "download.prompt_for_download": False,
})
driver = webdriver.Chrome(options=options)
```

```java
ChromeOptions options = new ChromeOptions();
options.addArguments("--headless=new", "--window-size=1920,1080");
WebDriver driver = new ChromeDriver(options);
```

## JavaScript Execution

```python
result = driver.execute_script("return document.title;")
driver.execute_script("arguments[0].scrollIntoView(true);", element)
driver.execute_script("arguments[0].click();", hidden_button)  # click hidden elements
driver.execute_async_script("var cb = arguments[arguments.length-1]; setTimeout(cb, 2000);")
```

## File Upload and Download

```python
# Upload — send file path to input[type="file"]
driver.find_element(By.CSS_SELECTOR, "input[type='file']").send_keys("/path/to/file.pdf")
# Download — set browser prefs: download.default_directory, download.prompt_for_download=False
```

## Cookie Management

```python
driver.add_cookie({"name": "session", "value": "abc123", "domain": ".example.com"})
cookie = driver.get_cookie("session")
all_cookies = driver.get_cookies()
driver.delete_cookie("session")
driver.delete_all_cookies()
```

## Selenium Grid 4

Grid 4 uses a microservices architecture: Router, Distributor, Session Map, New Session Queue, Event Bus, and Nodes.

### Standalone (dev/CI)
```bash
java -jar selenium-server-4.x.jar standalone
```

### Hub + Node (distributed)
```bash
java -jar selenium-server-4.x.jar hub
java -jar selenium-server-4.x.jar node --detect-drivers true
```

### Docker Compose
```yaml
version: "3"
services:
  hub:
    image: selenium/hub:4
    ports: ["4444:4444"]
  chrome:
    image: selenium/node-chrome:4
    depends_on: [hub]
    environment:
      - SE_EVENT_BUS_HOST=hub
      - SE_EVENT_BUS_PUBLISH_PORT=4442
      - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
  firefox:
    image: selenium/node-firefox:4
    depends_on: [hub]
    environment:
      - SE_EVENT_BUS_HOST=hub
      - SE_EVENT_BUS_PUBLISH_PORT=4442
      - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
```

Point tests to `http://localhost:4444`:
```python
driver = webdriver.Remote(
    command_executor="http://localhost:4444",
    options=Options()
)
```

For Kubernetes, use the official Selenium Helm chart. Scale browser nodes with `kubectl scale` or KEDA autoscaling.

## Cross-Browser Testing

```python
import pytest

@pytest.fixture(params=["chrome", "firefox", "edge"])
def driver(request):
    if request.param == "chrome":
        d = webdriver.Chrome()
    elif request.param == "firefox":
        d = webdriver.Firefox()
    elif request.param == "edge":
        d = webdriver.Edge()
    yield d
    d.quit()

def test_title(driver):
    driver.get("https://example.com")
    assert "Example" in driver.title
```

## Test Framework Integration

### Python — pytest
```python
# conftest.py
import pytest
from selenium import webdriver

@pytest.fixture
def driver():
    d = webdriver.Chrome()
    d.implicitly_wait(5)
    yield d
    d.quit()

# test_login.py
def test_login_success(driver):
    page = LoginPage(driver).open()
    dashboard = page.login("user", "pass")
    assert dashboard.is_loaded()
```

### Java — JUnit 5 / TestNG
```java
// JUnit 5
class LoginTest {
    WebDriver driver;
    @BeforeEach void setUp() { driver = new ChromeDriver(); }
    @AfterEach void tearDown() { driver.quit(); }
    @Test void testLogin() {
        new LoginPage(driver).login("user", "pass");
        assertEquals("Dashboard", driver.getTitle());
    }
}

// TestNG — use @BeforeMethod/@AfterMethod instead, Assert.assertEquals()
```

### JavaScript — Mocha
```javascript
const { Builder, By } = require("selenium-webdriver");
describe("Login", function () {
  let driver;
  before(async () => { driver = await new Builder().forBrowser("chrome").build(); });
  after(async () => { await driver.quit(); });
  it("should login", async function () {
    await driver.get("https://app.example.com/login");
    await driver.findElement(By.id("username")).sendKeys("user");
    await driver.findElement(By.id("password")).sendKeys("pass");
    await driver.findElement(By.css("button[type='submit']")).click();
    assert.strictEqual(await driver.getTitle(), "Dashboard");
  });
});
```

## Key Rules

- NEVER use `Thread.sleep()` or `time.sleep()` — use explicit waits with ExpectedConditions.
- Always call `driver.quit()` in teardown to release resources and close all windows.
- Use Page Object Model for any test suite beyond trivial scripts.
- Prefer CSS selectors over XPath for speed and readability.
- Run headless in CI pipelines; use headed mode only for debugging.
- Set explicit timeouts on all waits — never rely on defaults alone.
- Keep locators stable: prefer `data-testid` attributes over DOM structure.
- Use Selenium Grid or Docker for parallel cross-browser execution.
- Pin Selenium and driver versions in CI to avoid flaky version mismatches.
