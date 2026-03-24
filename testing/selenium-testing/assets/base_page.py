"""
BasePage — Python Page Object base class for Selenium tests.

Provides common helper methods for page interactions, waits, and assertions.
Extend this class for each page in your application.

Usage:
    class LoginPage(BasePage):
        URL = "/login"
        _username = (By.ID, "username")
        _password = (By.ID, "password")
        _submit = (By.CSS_SELECTOR, "button[type='submit']")

        def login(self, user, pwd):
            self.type(self._username, user)
            self.type(self._password, pwd)
            self.click(self._submit)
            return DashboardPage(self.driver)
"""

import logging
import os
import time
from typing import List, Optional, Tuple

from selenium.common.exceptions import (
    NoSuchElementException,
    StaleElementReferenceException,
    TimeoutException,
)
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.remote.webdriver import WebDriver
from selenium.webdriver.remote.webelement import WebElement
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.select import Select
from selenium.webdriver.support.ui import WebDriverWait

logger = logging.getLogger(__name__)

Locator = Tuple[str, str]


class BasePage:
    """Base class for all Page Objects."""

    URL: Optional[str] = None
    TIMEOUT: int = 10

    def __init__(self, driver: WebDriver, base_url: str = "", timeout: int = None):
        self.driver = driver
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout or self.TIMEOUT
        self.wait = WebDriverWait(
            driver,
            self.timeout,
            ignored_exceptions=[StaleElementReferenceException],
        )

    # ------------------------------------------------------------------
    # Navigation
    # ------------------------------------------------------------------

    def open(self, url: str = None) -> "BasePage":
        """Navigate to the page URL."""
        target = url or self.URL
        if target is None:
            raise ValueError("No URL defined for this page")
        if target.startswith("/"):
            target = self.base_url + target
        self.driver.get(target)
        self.wait_for_page_load()
        return self

    def wait_for_page_load(self, timeout: int = None) -> None:
        """Wait until document.readyState is 'complete'."""
        WebDriverWait(self.driver, timeout or self.timeout).until(
            lambda d: d.execute_script("return document.readyState") == "complete"
        )

    @property
    def current_url(self) -> str:
        return self.driver.current_url

    @property
    def title(self) -> str:
        return self.driver.title

    # ------------------------------------------------------------------
    # Element Finding
    # ------------------------------------------------------------------

    def find(self, locator: Locator) -> WebElement:
        """Find a single element with explicit wait for presence."""
        return self.wait.until(EC.presence_of_element_located(locator))

    def find_visible(self, locator: Locator) -> WebElement:
        """Find a single visible element."""
        return self.wait.until(EC.visibility_of_element_located(locator))

    def find_clickable(self, locator: Locator) -> WebElement:
        """Find an element that is visible and enabled (clickable)."""
        return self.wait.until(EC.element_to_be_clickable(locator))

    def find_all(self, locator: Locator) -> List[WebElement]:
        """Find all matching elements (returns empty list if none found)."""
        try:
            self.wait.until(EC.presence_of_element_located(locator))
        except TimeoutException:
            return []
        return self.driver.find_elements(*locator)

    def is_present(self, locator: Locator, timeout: int = 3) -> bool:
        """Check if element exists in DOM (may be hidden)."""
        try:
            WebDriverWait(self.driver, timeout).until(
                EC.presence_of_element_located(locator)
            )
            return True
        except TimeoutException:
            return False

    def is_visible(self, locator: Locator, timeout: int = 3) -> bool:
        """Check if element is visible on page."""
        try:
            WebDriverWait(self.driver, timeout).until(
                EC.visibility_of_element_located(locator)
            )
            return True
        except TimeoutException:
            return False

    # ------------------------------------------------------------------
    # Element Interactions
    # ------------------------------------------------------------------

    def click(self, locator: Locator) -> None:
        """Click an element after waiting for it to be clickable."""
        self.find_clickable(locator).click()

    def js_click(self, locator: Locator) -> None:
        """Click via JavaScript — use when normal click is intercepted."""
        element = self.find(locator)
        self.driver.execute_script("arguments[0].click();", element)

    def type(self, locator: Locator, text: str, clear_first: bool = True) -> None:
        """Type text into an input field."""
        element = self.find_visible(locator)
        if clear_first:
            element.clear()
        element.send_keys(text)

    def clear_and_type(self, locator: Locator, text: str) -> None:
        """Clear field using keyboard shortcuts, then type new text."""
        element = self.find_clickable(locator)
        element.click()
        element.send_keys(Keys.CONTROL, "a")
        element.send_keys(Keys.DELETE)
        element.send_keys(text)

    def get_text(self, locator: Locator) -> str:
        """Get the visible text of an element."""
        return self.find_visible(locator).text

    def get_value(self, locator: Locator) -> str:
        """Get the value attribute of an input element."""
        return self.find(locator).get_attribute("value") or ""

    def get_attribute(self, locator: Locator, attribute: str) -> Optional[str]:
        """Get any attribute of an element."""
        return self.find(locator).get_attribute(attribute)

    # ------------------------------------------------------------------
    # Select / Dropdown
    # ------------------------------------------------------------------

    def select_by_text(self, locator: Locator, text: str) -> None:
        """Select dropdown option by visible text."""
        Select(self.find(locator)).select_by_visible_text(text)

    def select_by_value(self, locator: Locator, value: str) -> None:
        """Select dropdown option by value attribute."""
        Select(self.find(locator)).select_by_value(value)

    def get_selected_text(self, locator: Locator) -> str:
        """Get currently selected option's text."""
        return Select(self.find(locator)).first_selected_option.text

    # ------------------------------------------------------------------
    # Checkbox / Radio
    # ------------------------------------------------------------------

    def check(self, locator: Locator) -> None:
        """Check a checkbox (no-op if already checked)."""
        element = self.find_clickable(locator)
        if not element.is_selected():
            element.click()

    def uncheck(self, locator: Locator) -> None:
        """Uncheck a checkbox (no-op if already unchecked)."""
        element = self.find_clickable(locator)
        if element.is_selected():
            element.click()

    # ------------------------------------------------------------------
    # Hover / Drag & Drop
    # ------------------------------------------------------------------

    def hover(self, locator: Locator) -> None:
        """Hover over an element."""
        element = self.find_visible(locator)
        ActionChains(self.driver).move_to_element(element).perform()

    def drag_and_drop(self, source: Locator, target: Locator) -> None:
        """Drag from source element to target element."""
        src = self.find_visible(source)
        tgt = self.find_visible(target)
        ActionChains(self.driver).drag_and_drop(src, tgt).perform()

    # ------------------------------------------------------------------
    # Scrolling
    # ------------------------------------------------------------------

    def scroll_to(self, locator: Locator) -> None:
        """Scroll element into view."""
        element = self.find(locator)
        self.driver.execute_script(
            "arguments[0].scrollIntoView({block: 'center'});", element
        )

    def scroll_to_bottom(self) -> None:
        """Scroll to the bottom of the page."""
        self.driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")

    def scroll_to_top(self) -> None:
        """Scroll to the top of the page."""
        self.driver.execute_script("window.scrollTo(0, 0);")

    # ------------------------------------------------------------------
    # Waits
    # ------------------------------------------------------------------

    def wait_for_text(self, locator: Locator, text: str, timeout: int = None) -> None:
        """Wait until element contains specific text."""
        WebDriverWait(self.driver, timeout or self.timeout).until(
            EC.text_to_be_present_in_element(locator, text)
        )

    def wait_for_invisible(self, locator: Locator, timeout: int = None) -> None:
        """Wait for element to disappear or become hidden."""
        WebDriverWait(self.driver, timeout or self.timeout).until(
            EC.invisibility_of_element_located(locator)
        )

    def wait_for_url_contains(self, substring: str, timeout: int = None) -> None:
        """Wait until URL contains a substring."""
        WebDriverWait(self.driver, timeout or self.timeout).until(
            EC.url_contains(substring)
        )

    def wait_for_title_contains(self, substring: str, timeout: int = None) -> None:
        """Wait until page title contains a substring."""
        WebDriverWait(self.driver, timeout or self.timeout).until(
            EC.title_contains(substring)
        )

    def wait_for_element_count(
        self, locator: Locator, count: int, timeout: int = None
    ) -> List[WebElement]:
        """Wait until exactly N elements match the locator."""
        def check(driver):
            elements = driver.find_elements(*locator)
            return elements if len(elements) == count else False
        return WebDriverWait(self.driver, timeout or self.timeout).until(check)

    # ------------------------------------------------------------------
    # Frames & Windows
    # ------------------------------------------------------------------

    def switch_to_frame(self, locator: Locator) -> None:
        """Switch to an iframe by locator."""
        self.wait.until(EC.frame_to_be_available_and_switch_to_it(locator))

    def switch_to_default(self) -> None:
        """Switch back to the main document."""
        self.driver.switch_to.default_content()

    def switch_to_new_window(self) -> str:
        """Switch to the most recently opened window/tab. Returns original handle."""
        original = self.driver.current_window_handle
        self.wait.until(lambda d: len(d.window_handles) > 1)
        new_handle = [h for h in self.driver.window_handles if h != original][-1]
        self.driver.switch_to.window(new_handle)
        return original

    # ------------------------------------------------------------------
    # Alerts
    # ------------------------------------------------------------------

    def accept_alert(self, timeout: int = 5) -> str:
        """Wait for alert, accept it, return its text."""
        alert = WebDriverWait(self.driver, timeout).until(EC.alert_is_present())
        text = alert.text
        alert.accept()
        return text

    def dismiss_alert(self, timeout: int = 5) -> str:
        """Wait for alert, dismiss it, return its text."""
        alert = WebDriverWait(self.driver, timeout).until(EC.alert_is_present())
        text = alert.text
        alert.dismiss()
        return text

    # ------------------------------------------------------------------
    # Screenshots & Debugging
    # ------------------------------------------------------------------

    def take_screenshot(self, name: str = "screenshot") -> str:
        """Take a screenshot and return the file path."""
        os.makedirs("screenshots", exist_ok=True)
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        path = os.path.join("screenshots", f"{name}_{timestamp}.png")
        self.driver.save_screenshot(path)
        logger.info("Screenshot saved: %s", path)
        return path

    def highlight(self, locator: Locator, duration: float = 0.5) -> None:
        """Briefly highlight an element for visual debugging."""
        element = self.find(locator)
        original_style = element.get_attribute("style")
        self.driver.execute_script(
            "arguments[0].style.border = '3px solid red';", element
        )
        time.sleep(duration)
        self.driver.execute_script(
            f"arguments[0].setAttribute('style', '{original_style or ''}');", element
        )

    # ------------------------------------------------------------------
    # JavaScript Execution
    # ------------------------------------------------------------------

    def execute_js(self, script: str, *args) -> any:
        """Execute JavaScript and return the result."""
        return self.driver.execute_script(script, *args)

    def disable_animations(self) -> None:
        """Disable all CSS animations and transitions for test stability."""
        self.driver.execute_script("""
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

    # ------------------------------------------------------------------
    # File Upload
    # ------------------------------------------------------------------

    def upload_file(self, locator: Locator, file_path: str) -> None:
        """Upload a file by sending the path to a file input."""
        element = self.find(locator)
        element.send_keys(os.path.abspath(file_path))
