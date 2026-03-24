#!/usr/bin/env bash
# ============================================================================
# generate-page-object.sh — Generate a Page Object class from a URL
#
# Inspects a web page's interactive elements and generates a Page Object
# class in Python or Java with locators, action methods, and waits.
#
# Usage:
#   ./generate-page-object.sh URL [OPTIONS]
#
# Options:
#   --lang python|java    Output language (default: python)
#   --class NAME          Class name (default: derived from URL path)
#   --output FILE         Output file path (default: stdout)
#   --headless            Run in headless mode (default: true)
#   --help                Show this help
#
# Requirements:
#   python3, selenium (pip install selenium)
#
# Examples:
#   ./generate-page-object.sh https://example.com/login
#   ./generate-page-object.sh https://example.com/login --lang java --class LoginPage
#   ./generate-page-object.sh https://example.com/search --output search_page.py
# ============================================================================

set -euo pipefail

if [[ "${1:-}" == "--help" || $# -eq 0 ]]; then
    head -20 "$0" | tail -18
    exit 0
fi

URL="$1"
shift

LANG="python"
CLASS_NAME=""
OUTPUT=""
HEADLESS="true"

while [[ $# -gt 0 ]]; do
    case $1 in
        --lang)     LANG="$2"; shift 2 ;;
        --class)    CLASS_NAME="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        --headless) HEADLESS="true"; shift ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required"; exit 1; }

INSPECT_SCRIPT=$(mktemp /tmp/page_inspect_XXXX.py)
trap 'rm -f "$INSPECT_SCRIPT"' EXIT

cat > "$INSPECT_SCRIPT" << 'PYTHON_SCRIPT'
import sys
import json
import re
from urllib.parse import urlparse

try:
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
except ImportError:
    print("Error: selenium not installed. Run: pip install selenium", file=sys.stderr)
    sys.exit(1)

url = sys.argv[1]
lang = sys.argv[2]
class_name = sys.argv[3]
headless = sys.argv[4] == "true"

if not class_name:
    path = urlparse(url).path.strip("/").split("/")[-1] or "home"
    class_name = re.sub(r'[^a-zA-Z0-9]', ' ', path).title().replace(' ', '') + "Page"

options = Options()
if headless:
    options.add_argument("--headless=new")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.add_argument("--window-size=1920,1080")

driver = webdriver.Chrome(options=options)
driver.set_page_load_timeout(30)

try:
    driver.get(url)
    WebDriverWait(driver, 10).until(
        lambda d: d.execute_script("return document.readyState") == "complete"
    )

    elements = driver.execute_script("""
        const results = [];
        const interactiveSelectors = [
            'input', 'textarea', 'select', 'button',
            'a[href]', '[role="button"]', '[role="link"]',
            '[role="textbox"]', '[role="checkbox"]', '[role="radio"]',
            '[type="submit"]', '[onclick]'
        ];
        const seen = new Set();

        interactiveSelectors.forEach(selector => {
            document.querySelectorAll(selector).forEach(el => {
                if (seen.has(el) || !el.offsetParent) return;
                seen.add(el);

                const info = {
                    tag: el.tagName.toLowerCase(),
                    type: el.type || '',
                    id: el.id || '',
                    name: el.name || '',
                    className: el.className || '',
                    text: (el.textContent || '').trim().substring(0, 50),
                    placeholder: el.placeholder || '',
                    role: el.getAttribute('role') || '',
                    ariaLabel: el.getAttribute('aria-label') || '',
                    dataTestId: el.getAttribute('data-testid') || '',
                    href: el.href || '',
                };
                results.push(info);
            });
        });
        return results;
    """)

    page_title = driver.title

finally:
    driver.quit()


def make_var_name(element):
    name = (element.get('dataTestId') or element.get('id') or
            element.get('name') or element.get('ariaLabel') or
            element.get('placeholder') or element.get('text', '')[:20])
    name = re.sub(r'[^a-zA-Z0-9]', '_', name).strip('_').lower()
    if not name:
        name = f"{element['tag']}_{element['type']}" if element['type'] else element['tag']
    return name


def get_locator(element):
    if element.get('dataTestId'):
        return ('CSS_SELECTOR', f"[data-testid='{element['dataTestId']}']")
    if element.get('id'):
        return ('ID', element['id'])
    if element.get('name'):
        return ('NAME', element['name'])
    if element.get('ariaLabel'):
        return ('CSS_SELECTOR', f"[aria-label='{element['ariaLabel']}']")
    css_parts = [element['tag']]
    if element.get('type'):
        css_parts.append(f"[type='{element['type']}']")
    if element.get('placeholder'):
        css_parts.append(f"[placeholder='{element['placeholder']}']")
    return ('CSS_SELECTOR', ''.join(css_parts))


def generate_python(elements, class_name, url):
    lines = []
    lines.append(f'"""Page Object for {url}"""')
    lines.append("from selenium.webdriver.common.by import By")
    lines.append("from selenium.webdriver.support.ui import WebDriverWait")
    lines.append("from selenium.webdriver.support import expected_conditions as EC")
    lines.append("")
    lines.append("")
    lines.append(f"class {class_name}:")
    lines.append(f'    URL = "{url}"')
    lines.append("")

    lines.append("    # Locators")
    for el in elements:
        var = make_var_name(el)
        strategy, value = get_locator(el)
        lines.append(f'    _{var} = (By.{strategy}, "{value}")')
    lines.append("")

    lines.append("    def __init__(self, driver, timeout=10):")
    lines.append("        self.driver = driver")
    lines.append("        self.timeout = timeout")
    lines.append("        self.wait = WebDriverWait(driver, timeout)")
    lines.append("")

    lines.append("    def open(self):")
    lines.append("        self.driver.get(self.URL)")
    lines.append("        return self")
    lines.append("")

    for el in elements:
        var = make_var_name(el)
        if el['tag'] in ('input', 'textarea') and el['type'] not in ('submit', 'button', 'checkbox', 'radio'):
            lines.append(f"    def enter_{var}(self, text):")
            lines.append(f"        element = self.wait.until(EC.visibility_of_element_located(self._{var}))")
            lines.append("        element.clear()")
            lines.append("        element.send_keys(text)")
            lines.append("        return self")
            lines.append("")
        elif el['tag'] in ('button', 'a') or el['type'] in ('submit', 'button') or el.get('role') == 'button':
            lines.append(f"    def click_{var}(self):")
            lines.append(f"        self.wait.until(EC.element_to_be_clickable(self._{var})).click()")
            lines.append("        return self")
            lines.append("")
        elif el['tag'] == 'select':
            lines.append(f"    def select_{var}(self, value):")
            lines.append("        from selenium.webdriver.support.select import Select")
            lines.append(f"        element = self.wait.until(EC.presence_of_element_located(self._{var}))")
            lines.append("        Select(element).select_by_visible_text(value)")
            lines.append("        return self")
            lines.append("")
        elif el['type'] in ('checkbox', 'radio'):
            lines.append(f"    def toggle_{var}(self):")
            lines.append(f"        self.wait.until(EC.element_to_be_clickable(self._{var})).click()")
            lines.append("        return self")
            lines.append("")

    print("\n".join(lines))


def generate_java(elements, class_name, url):
    lines = []
    lines.append("import org.openqa.selenium.*;")
    lines.append("import org.openqa.selenium.support.FindBy;")
    lines.append("import org.openqa.selenium.support.PageFactory;")
    lines.append("import org.openqa.selenium.support.ui.WebDriverWait;")
    lines.append("import org.openqa.selenium.support.ui.ExpectedConditions;")
    lines.append("import org.openqa.selenium.support.ui.Select;")
    lines.append("import java.time.Duration;")
    lines.append("")
    lines.append(f"/**")
    lines.append(f" * Page Object for {url}")
    lines.append(f" */")
    lines.append(f"public class {class_name} {{")
    lines.append(f"    private WebDriver driver;")
    lines.append(f"    private WebDriverWait wait;")
    lines.append(f'    public static final String URL = "{url}";')
    lines.append("")

    for el in elements:
        var = make_var_name(el)
        camel = re.sub(r'_([a-z])', lambda m: m.group(1).upper(), var)
        strategy, value = get_locator(el)
        java_how = {'ID': 'id', 'NAME': 'name', 'CSS_SELECTOR': 'css'}.get(strategy, 'css')
        lines.append(f'    @FindBy({java_how} = "{value}")')
        lines.append(f"    private WebElement {camel};")
        lines.append("")

    lines.append(f"    public {class_name}(WebDriver driver) {{")
    lines.append("        this.driver = driver;")
    lines.append("        this.wait = new WebDriverWait(driver, Duration.ofSeconds(10));")
    lines.append("        PageFactory.initElements(driver, this);")
    lines.append("    }")
    lines.append("")

    lines.append(f"    public {class_name} open() {{")
    lines.append("        driver.get(URL);")
    lines.append("        return this;")
    lines.append("    }")
    lines.append("")

    for el in elements:
        var = make_var_name(el)
        camel = re.sub(r'_([a-z])', lambda m: m.group(1).upper(), var)
        method_camel = camel[0].upper() + camel[1:]

        if el['tag'] in ('input', 'textarea') and el['type'] not in ('submit', 'button', 'checkbox', 'radio'):
            lines.append(f"    public {class_name} enter{method_camel}(String text) {{")
            lines.append(f"        wait.until(ExpectedConditions.visibilityOf({camel}));")
            lines.append(f"        {camel}.clear();")
            lines.append(f"        {camel}.sendKeys(text);")
            lines.append("        return this;")
            lines.append("    }")
            lines.append("")
        elif el['tag'] in ('button', 'a') or el['type'] in ('submit', 'button') or el.get('role') == 'button':
            lines.append(f"    public {class_name} click{method_camel}() {{")
            lines.append(f"        wait.until(ExpectedConditions.elementToBeClickable({camel})).click();")
            lines.append("        return this;")
            lines.append("    }")
            lines.append("")
        elif el['tag'] == 'select':
            lines.append(f"    public {class_name} select{method_camel}(String value) {{")
            lines.append(f"        new Select({camel}).selectByVisibleText(value);")
            lines.append("        return this;")
            lines.append("    }")
            lines.append("")

    lines.append("}")
    print("\n".join(lines))


if lang == "python":
    generate_python(elements, class_name, url)
elif lang == "java":
    generate_java(elements, class_name, url)
else:
    print(f"Error: unsupported language '{lang}'", file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT

if [[ -n "$OUTPUT" ]]; then
    python3 "$INSPECT_SCRIPT" "$URL" "$LANG" "$CLASS_NAME" "$HEADLESS" > "$OUTPUT"
    echo "Page Object generated: $OUTPUT"
    echo "Class: ${CLASS_NAME:-<auto-detected>}"
    echo "Language: $LANG"
    wc -l "$OUTPUT" | awk '{print "Lines: " $1}'
else
    python3 "$INSPECT_SCRIPT" "$URL" "$LANG" "$CLASS_NAME" "$HEADLESS"
fi
