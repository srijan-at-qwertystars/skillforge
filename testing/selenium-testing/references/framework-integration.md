# Test Framework Integration with Selenium

## Table of Contents

- [pytest + Selenium (Python)](#pytest--selenium-python)
  - [Fixtures and conftest.py](#fixtures-and-conftestpy)
  - [Custom Markers](#custom-markers)
  - [Parallel Execution with pytest-xdist](#parallel-execution-with-pytest-xdist)
  - [Parameterized Browser Tests](#parameterized-browser-tests)
  - [Screenshot on Failure Hook](#screenshot-on-failure-hook)
- [JUnit 5 + Selenium (Java)](#junit-5--selenium-java)
  - [Extensions](#junit-5-extensions)
  - [Parameterized Tests](#junit-5-parameterized-tests)
  - [Parallel Execution](#junit-5-parallel-execution)
  - [Test Lifecycle Management](#junit-5-lifecycle)
- [TestNG + Selenium (Java)](#testng--selenium-java)
  - [Data Providers](#testng-data-providers)
  - [Test Groups](#testng-groups)
  - [Listeners](#testng-listeners)
  - [Parallel Suite Execution](#testng-parallel-suites)
- [Mocha/Jest + Selenium (JavaScript)](#mochajest--selenium-javascript)
  - [Mocha Async Patterns](#mocha-async-patterns)
  - [Jest Integration](#jest-integration)
  - [Shared Driver Management](#js-shared-driver)
- [BDD with Cucumber + Selenium](#bdd-with-cucumber--selenium)
  - [Cucumber-Java Setup](#cucumber-java)
  - [Cucumber-Python (Behave) Setup](#cucumber-python-behave)
  - [Step Definition Best Practices](#step-definition-best-practices)
- [Allure Reporting Integration](#allure-reporting-integration)
  - [Python + Allure](#python-allure)
  - [Java + Allure](#java-allure)
  - [Attaching Screenshots and Logs](#allure-attachments)
- [CI/CD Pipeline Integration](#cicd-pipeline-integration)
  - [GitHub Actions with Selenium Grid](#github-actions)
  - [Jenkins Pipeline](#jenkins-pipeline)
  - [GitLab CI with Docker Services](#gitlab-ci)

---

## pytest + Selenium (Python)

### Fixtures and conftest.py

The `conftest.py` is the backbone of pytest + Selenium integration. See `assets/conftest.py` for a complete, ready-to-use implementation with browser selection, headless mode, Grid support, and screenshot-on-failure.

**Key conftest pattern:**
```python
@pytest.fixture
def driver(request):
    browser = request.config.getoption("--browser")
    headless = request.config.getoption("--headless")
    grid_url = request.config.getoption("--grid-url")
    options = _build_options(browser, headless)

    if grid_url:
        d = webdriver.Remote(command_executor=grid_url, options=options)
    else:
        d = webdriver.Chrome(options=options)

    d.set_window_size(1920, 1080)
    yield d
    d.quit()
```

### Custom Markers

See `pytest.ini` or `pyproject.toml` to register markers. Run with `pytest -m smoke` or `pytest -m "not slow"`.

### Parallel Execution with pytest-xdist

```bash
pip install pytest-xdist

# Auto-detect CPU count
pytest -n auto tests/

# Fixed workers, each gets its own browser; distribute by file
pytest -n 4 --dist loadfile tests/

# Parallel with Grid
pytest -n 8 --grid-url http://localhost:4444 tests/
```

### Parameterized Browser Tests

```python
@pytest.fixture(params=["chrome", "firefox", "edge"])
def multi_driver(request):
    options = _build_options(request.param, headless=True)
    d = getattr(webdriver, request.param.capitalize())(options=options)
    d.set_window_size(1920, 1080)
    yield d
    d.quit()

def test_homepage_loads(multi_driver):
    multi_driver.get("https://example.com")
    assert "Example" in multi_driver.title
```

### Screenshot on Failure Hook

Use `pytest_runtest_makereport` hook to capture screenshots, page source, and console logs automatically on test failure. See `assets/conftest.py` for a complete implementation.

---

## JUnit 5 + Selenium (Java)

### JUnit 5 Extensions

Create a reusable extension that manages the WebDriver lifecycle.

```java
import org.junit.jupiter.api.extension.*;
import org.openqa.selenium.WebDriver;
import org.openqa.selenium.chrome.ChromeDriver;
import org.openqa.selenium.chrome.ChromeOptions;
import org.openqa.selenium.OutputType;
import org.openqa.selenium.TakesScreenshot;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;

public class SeleniumExtension implements
        BeforeEachCallback, AfterEachCallback, TestWatcher, ParameterResolver {

    private static final ExtensionContext.Namespace NS =
        ExtensionContext.Namespace.create(SeleniumExtension.class);

    @Override
    public void beforeEach(ExtensionContext context) {
        ChromeOptions options = new ChromeOptions();
        if (System.getenv("CI") != null) {
            options.addArguments("--headless=new", "--no-sandbox", "--disable-dev-shm-usage");
        }
        options.addArguments("--window-size=1920,1080");

        WebDriver driver = new ChromeDriver(options);
        context.getStore(NS).put("driver", driver);
    }

    @Override
    public void afterEach(ExtensionContext context) {
        WebDriver driver = context.getStore(NS).get("driver", WebDriver.class);
        if (driver != null) {
            driver.quit();
        }
    }

    @Override
    public void testFailed(ExtensionContext context, Throwable cause) {
        WebDriver driver = context.getStore(NS).get("driver", WebDriver.class);
        if (driver instanceof TakesScreenshot) {
            try {
                File screenshot = ((TakesScreenshot) driver).getScreenshotAs(OutputType.FILE);
                Path dest = Path.of("target", "screenshots",
                    context.getDisplayName() + ".png");
                Files.createDirectories(dest.getParent());
                Files.copy(screenshot.toPath(), dest);
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
    }

    @Override
    public boolean supportsParameter(ParameterContext paramCtx, ExtensionContext extCtx) {
        return paramCtx.getParameter().getType() == WebDriver.class;
    }

    @Override
    public Object resolveParameter(ParameterContext paramCtx, ExtensionContext extCtx) {
        return extCtx.getStore(NS).get("driver", WebDriver.class);
    }
}

// Usage in test class
@ExtendWith(SeleniumExtension.class)
class LoginTest {
    @Test
    void testLoginSuccess(WebDriver driver) {
        driver.get("https://example.com/login");
        driver.findElement(By.id("username")).sendKeys("admin");
        driver.findElement(By.id("password")).sendKeys("secret");
        driver.findElement(By.cssSelector("button[type='submit']")).click();
        assertEquals("Dashboard", driver.getTitle());
    }
}
```

### JUnit 5 Parallel Execution

```properties
# junit-platform.properties (in src/test/resources)
junit.jupiter.execution.parallel.enabled=true
junit.jupiter.execution.parallel.mode.default=concurrent
junit.jupiter.execution.parallel.mode.classes.default=concurrent
junit.jupiter.execution.parallel.config.strategy=fixed
junit.jupiter.execution.parallel.config.fixed.parallelism=4
```

```java
// Thread-safe test class — each test gets its own driver via extension
@ExtendWith(SeleniumExtension.class)
@Execution(ExecutionMode.CONCURRENT)
class ParallelSearchTest {

    @Test void testSearchProducts(WebDriver driver) { /* ... */ }
    @Test void testSearchUsers(WebDriver driver) { /* ... */ }
    @Test void testSearchOrders(WebDriver driver) { /* ... */ }
}
```

---

## TestNG + Selenium (Java)

### TestNG Data Providers

```java
public class LoginDataDrivenTest {
    @DataProvider(name = "loginCredentials")
    public Object[][] credentials() {
        return new Object[][] {
            {"admin", "admin123", true},
            {"user", "user456", true},
            {"invalid", "wrong", false},
        };
    }

    @Test(dataProvider = "loginCredentials")
    public void testLogin(String username, String password, boolean shouldSucceed) {
        WebDriver driver = new ChromeDriver();
        try {
            LoginPage loginPage = new LoginPage(driver);
            loginPage.navigate();
            loginPage.login(username, password);
            if (shouldSucceed) {
                Assert.assertEquals(driver.getTitle(), "Dashboard");
            } else {
                Assert.assertTrue(loginPage.getErrorMessage().isDisplayed());
            }
        } finally {
            driver.quit();
        }
    }
}
```

### TestNG Groups

```java
public class EcommerceTests {

    @Test(groups = {"smoke", "checkout"})
    public void testAddToCart() { /* ... */ }

    @Test(groups = {"smoke", "checkout"})
    public void testCheckout() { /* ... */ }

    @Test(groups = {"regression", "search"})
    public void testSearchFilters() { /* ... */ }

    @Test(groups = {"regression", "user"}, dependsOnGroups = {"smoke"})
    public void testUserProfile() { /* ... */ }
}
```

```xml
<!-- testng.xml — run specific groups -->
<!DOCTYPE suite SYSTEM "https://testng.org/testng-1.0.dtd">
<suite name="E-commerce Suite" parallel="tests" thread-count="3">
    <test name="Smoke Tests">
        <groups>
            <run><include name="smoke"/></run>
        </groups>
        <classes>
            <class name="com.example.EcommerceTests"/>
        </classes>
    </test>
    <test name="Regression">
        <groups>
            <run>
                <include name="regression"/>
                <exclude name="slow"/>
            </run>
        </groups>
        <classes>
            <class name="com.example.EcommerceTests"/>
        </classes>
    </test>
</suite>
```

### TestNG Listeners

```java
public class SeleniumTestListener implements ITestListener {
    @Override
    public void onTestFailure(ITestResult result) {
        WebDriver driver = /* get driver from test context */;
        if (driver != null) {
            File screenshot = ((TakesScreenshot) driver).getScreenshotAs(OutputType.FILE);
            String path = "target/screenshots/" + result.getName() + ".png";
            try { FileUtils.copyFile(screenshot, new File(path)); }
            catch (IOException e) { e.printStackTrace(); }
        }
    }
}

// Register: @Listeners(SeleniumTestListener.class)
```

### TestNG Parallel Suites

```xml
<!-- Parallel by classes -->
<suite name="Parallel Suite" parallel="classes" thread-count="3">
    <test name="All Tests">
        <classes>
            <class name="com.example.SearchTest"/>
            <class name="com.example.LoginTest"/>
        </classes>
    </test>
</suite>

<!-- Cross-browser parallel -->
<suite name="Cross-Browser" parallel="tests" thread-count="3">
    <test name="Chrome">
        <parameter name="browser" value="chrome"/>
        <classes><class name="com.example.SmokeTest"/></classes>
    </test>
    <test name="Firefox">
        <parameter name="browser" value="firefox"/>
        <classes><class name="com.example.SmokeTest"/></classes>
    </test>
</suite>
```

---

## Mocha/Jest + Selenium (JavaScript)

### Mocha Async Patterns

```javascript
const { Builder, By, until } = require("selenium-webdriver");
const assert = require("assert");

describe("Dashboard", function () {
    this.timeout(30000); // Selenium tests need longer timeout

    let driver;

    before(async function () {
        driver = await new Builder()
            .forBrowser("chrome")
            .setChromeOptions(
                new (require("selenium-webdriver/chrome").Options)()
                    .addArguments("--headless=new", "--window-size=1920,1080")
            )
            .build();
    });

    after(async function () {
        if (driver) await driver.quit();
    });

    afterEach(async function () {
        if (this.currentTest.state === "failed") {
            const screenshot = await driver.takeScreenshot();
            const fs = require("fs");
            fs.mkdirSync("screenshots", { recursive: true });
            fs.writeFileSync(
                `screenshots/${this.currentTest.title}.png`,
                screenshot, "base64"
            );
        }
    });

    it("should display user stats after login", async function () {
        await driver.get("https://app.example.com/login");
        await driver.findElement(By.id("username")).sendKeys("admin");
        await driver.findElement(By.id("password")).sendKeys("secret");
        await driver.findElement(By.css("button[type='submit']")).click();

        await driver.wait(until.titleIs("Dashboard"), 10000);

        const stats = await driver.findElement(By.id("user-stats"));
        await driver.wait(until.elementIsVisible(stats), 5000);
        const text = await stats.getText();
        assert.ok(text.includes("Welcome"), `Expected welcome message, got: ${text}`);
    });
});
```

### Jest Integration

```javascript
// jest.config.js
module.exports = { testTimeout: 60000, testMatch: ["**/e2e/**/*.test.js"] };

// e2e/login.test.js
const { Builder, By, until } = require("selenium-webdriver");
const chrome = require("selenium-webdriver/chrome");

let driver;
beforeAll(async () => {
    const options = new chrome.Options().addArguments("--headless=new", "--no-sandbox");
    driver = await new Builder().forBrowser("chrome").setChromeOptions(options).build();
});
afterAll(async () => { if (driver) await driver.quit(); });

test("should login", async () => {
    await driver.get("https://app.example.com/login");
    await driver.findElement(By.id("username")).sendKeys("admin");
    await driver.findElement(By.id("password")).sendKeys("secret");
    await driver.findElement(By.css("button[type='submit']")).click();
    await driver.wait(until.titleContains("Dashboard"), 10000);
    expect(await driver.getTitle()).toContain("Dashboard");
});
```

---

## BDD with Cucumber + Selenium

### Cucumber-Java

**Project structure:**
```
src/test/
├── java/com/example/
│   ├── steps/
│   │   ├── LoginSteps.java
│   │   └── SearchSteps.java
│   ├── pages/
│   │   ├── LoginPage.java
│   │   └── SearchPage.java
│   ├── hooks/Hooks.java
│   └── runners/TestRunner.java
└── resources/features/
    ├── login.feature
    └── search.feature
```

**Step definitions (Java):**
```java
public class LoginSteps {
    private WebDriver driver;
    private LoginPage loginPage;

    @Given("I am on the login page")
    public void iAmOnTheLoginPage() {
        driver = Hooks.getDriver();
        loginPage = new LoginPage(driver);
        loginPage.navigate();
    }

    @When("I enter username {string} and password {string}")
    public void iEnterCredentials(String username, String password) {
        loginPage.enterUsername(username);
        loginPage.enterPassword(password);
    }

    @When("I click the login button")
    public void iClickLoginButton() {
        loginPage.clickLogin();
    }

    @Then("I should be redirected to the dashboard")
    public void iShouldBeOnDashboard() {
        new WebDriverWait(driver, Duration.ofSeconds(10))
            .until(ExpectedConditions.titleContains("Dashboard"));
    }

    @Then("I should see welcome message {string}")
    public void iShouldSeeWelcome(String message) {
        String actual = driver.findElement(By.id("welcome")).getText();
        assertEquals(message, actual);
    }

    @Then("I should see error message {string}")
    public void iShouldSeeError(String error) {
        String actual = loginPage.getErrorMessage();
        assertEquals(error, actual);
    }
}
```

**Hooks (Java):**
```java
public class Hooks {
    private static final ThreadLocal<WebDriver> driverThread = new ThreadLocal<>();

    @Before
    public void setUp() {
        ChromeOptions options = new ChromeOptions();
        options.addArguments("--headless=new", "--no-sandbox");
        driverThread.set(new ChromeDriver(options));
    }

    @After
    public void tearDown(Scenario scenario) {
        WebDriver driver = driverThread.get();
        if (scenario.isFailed() && driver != null) {
            byte[] screenshot = ((TakesScreenshot) driver).getScreenshotAs(OutputType.BYTES);
            scenario.attach(screenshot, "image/png", scenario.getName());
        }
        if (driver != null) { driver.quit(); driverThread.remove(); }
    }

    public static WebDriver getDriver() { return driverThread.get(); }
}
```

### Cucumber-Python (Behave)

```python
# features/environment.py
from selenium import webdriver
from selenium.webdriver.chrome.options import Options

def before_scenario(context, scenario):
    options = Options()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    context.driver = webdriver.Chrome(options=options)
    context.driver.set_window_size(1920, 1080)

def after_scenario(context, scenario):
    if scenario.status == "failed":
        context.driver.save_screenshot(f"screenshots/{scenario.name}.png")
    context.driver.quit()

# features/steps/login_steps.py
from behave import given, when, then
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

@given('I am on the login page')
def step_on_login_page(context):
    context.driver.get("https://app.example.com/login")

@when('I enter username "{username}" and password "{password}"')
def step_enter_credentials(context, username, password):
    context.driver.find_element(By.ID, "username").send_keys(username)
    context.driver.find_element(By.ID, "password").send_keys(password)

@when('I click the login button')
def step_click_login(context):
    context.driver.find_element(By.CSS_SELECTOR, "button[type='submit']").click()

@then('I should be redirected to the dashboard')
def step_on_dashboard(context):
    WebDriverWait(context.driver, 10).until(EC.title_contains("Dashboard"))

@then('I should see welcome message "{message}"')
def step_see_welcome(context, message):
    el = context.driver.find_element(By.ID, "welcome")
    assert el.text == message, f"Expected '{message}', got '{el.text}'"
```

### Step Definition Best Practices

1. **Keep steps atomic** — one action or assertion per step
2. **Use Page Objects in steps** — delegate to page objects, not raw Selenium calls
3. **Parameterize everything** — use `{string}`, `{int}`, Scenario Outlines
4. **Tag scenarios** — `@smoke`, `@wip`, `@skip` for selective execution

---

## Allure Reporting Integration

### Python Allure

```bash
pip install allure-pytest
```

```python
import allure
from allure_commons.types import Severity

@allure.epic("User Management")
@allure.feature("Authentication")
@allure.story("Login")
@allure.severity(Severity.CRITICAL)
@allure.title("Verify successful login with valid credentials")
def test_login_success(driver):
    with allure.step("Navigate to login page"):
        driver.get("https://app.example.com/login")

    with allure.step("Enter valid credentials"):
        driver.find_element(By.ID, "username").send_keys("admin")
        driver.find_element(By.ID, "password").send_keys("secret")

    with allure.step("Submit login form"):
        driver.find_element(By.CSS_SELECTOR, "button[type='submit']").click()

    with allure.step("Verify dashboard is displayed"):
        WebDriverWait(driver, 10).until(EC.title_contains("Dashboard"))
        allure.attach(
            driver.get_screenshot_as_png(),
            name="dashboard",
            attachment_type=allure.attachment_type.PNG
        )
```

```bash
# Generate report
pytest --alluredir=allure-results tests/
allure serve allure-results/
```

### Java Allure

```xml
<!-- pom.xml -->
<dependency>
    <groupId>io.qameta.allure</groupId>
    <artifactId>allure-junit5</artifactId>
    <version>2.25.0</version>
    <scope>test</scope>
</dependency>
```

```java
@Epic("User Management")
@Feature("Authentication")
public class LoginAllureTest {

    @Test
    @Story("Login")
    @Severity(SeverityLevel.CRITICAL)
    @Description("Verify successful login flow")
    void testLoginSuccess(WebDriver driver) {
        Allure.step("Navigate to login page", () -> {
            driver.get("https://app.example.com/login");
        });
        Allure.step("Enter credentials and submit", () -> {
            driver.findElement(By.id("username")).sendKeys("admin");
            driver.findElement(By.id("password")).sendKeys("secret");
            driver.findElement(By.cssSelector("button[type='submit']")).click();
        });
        Allure.step("Verify dashboard", () -> {
            new WebDriverWait(driver, Duration.ofSeconds(10))
                .until(ExpectedConditions.titleContains("Dashboard"));
            Allure.addAttachment("Screenshot",
                new ByteArrayInputStream(
                    ((TakesScreenshot) driver).getScreenshotAs(OutputType.BYTES)));
        });
    }
}
```

### Allure Attachments

```python
def attach_test_evidence(driver, name="evidence"):
    allure.attach(driver.get_screenshot_as_png(),
                  name=f"{name}_screenshot", attachment_type=allure.attachment_type.PNG)
    allure.attach(driver.page_source,
                  name=f"{name}_page_source", attachment_type=allure.attachment_type.HTML)
    allure.attach(driver.current_url, name=f"{name}_url",
                  attachment_type=allure.attachment_type.TEXT)
```

---

## CI/CD Pipeline Integration

### GitHub Actions

```yaml
name: Selenium Tests
on: [push, pull_request]

jobs:
  selenium-tests:
    runs-on: ubuntu-latest
    services:
      selenium-hub:
        image: selenium/hub:4
        ports: ["4444:4444"]
      chrome:
        image: selenium/node-chrome:4
        env:
          SE_EVENT_BUS_HOST: selenium-hub
          SE_EVENT_BUS_PUBLISH_PORT: 4442
          SE_EVENT_BUS_SUBSCRIBE_PORT: 4443
          SE_NODE_MAX_SESSIONS: 4
        options: --shm-size=2g

    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: pip install -r requirements.txt
      - name: Wait for Grid
        run: |
          for i in $(seq 1 30); do
            curl -s http://localhost:4444/status | grep -q '"ready":true' && break
            sleep 2
          done
      - run: pytest -n 4 --grid-url http://localhost:4444 --alluredir=allure-results tests/
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results
          path: |
            allure-results/
            screenshots/
```

### Jenkins Pipeline

```groovy
pipeline {
    agent any
    environment {
        GRID_URL = 'http://selenium-hub:4444'
    }
    stages {
        stage('Setup') {
            steps {
                sh 'docker compose -f docker-compose-grid.yml up -d'
                sh '''
                    for i in $(seq 1 30); do
                        curl -s $GRID_URL/status | grep -q '"ready":true' && break
                        sleep 2
                    done
                '''
            }
        }
        stage('Test') {
            steps {
                sh '''
                    python -m pytest tests/ \
                        --grid-url $GRID_URL \
                        -n 4 \
                        --alluredir=allure-results \
                        --junitxml=test-results.xml
                '''
            }
        }
    }
    post {
        always {
            junit 'test-results.xml'
            allure includeProperties: false, results: [[path: 'allure-results']]
            sh 'docker compose -f docker-compose-grid.yml down'
        }
        failure {
            archiveArtifacts artifacts: 'screenshots/**', allowEmptyArchive: true
        }
    }
}
```

### GitLab CI

```yaml
# .gitlab-ci.yml
variables:
  GRID_URL: "http://selenium-hub:4444"

services:
  - name: selenium/hub:4
    alias: selenium-hub
  - name: selenium/node-chrome:4
    alias: chrome-node
    variables:
      SE_EVENT_BUS_HOST: selenium-hub
      SE_EVENT_BUS_PUBLISH_PORT: "4442"
      SE_EVENT_BUS_SUBSCRIBE_PORT: "4443"

stages:
  - test

selenium-tests:
  stage: test
  image: python:3.12
  before_script:
    - pip install -r requirements.txt
    - |
      for i in $(seq 1 30); do
        curl -s $GRID_URL/status | grep -q '"ready":true' && break
        sleep 2
      done
  script:
    - pytest tests/ --grid-url $GRID_URL -n auto --alluredir=allure-results
  artifacts:
    when: always
    paths: [allure-results/, screenshots/]
    reports:
      junit: test-results.xml
```
