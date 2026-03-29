---
name: wxt
description: |
  Web Extension framework for building browser extensions. Use for cross-browser extensions.
  NOT for single-browser specific extensions without cross-browser needs.
---

# WXT - Web Extension Framework

## Quick Start

```bash
# Create new project
npm create wxt@latest
# or
npx wxt@latest init

# Dev mode (hot reload)
npm run dev

# Build for production
npm run build

# Build for specific browser
npm run build -- --browser firefox
```

## Project Structure

```
my-extension/
├── .output/              # Build output
├── .wxt/                 # Generated types
├── src/
│   ├── entrypoints/      # Extension entrypoints
│   │   ├── background.ts
│   │   ├── content.ts
│   │   ├── popup/
│   │   │   ├── index.html
│   │   │   ├── index.ts
│   │   │   └── style.css
│   │   └── options/
│   ├── components/       # Shared UI components
│   ├── utils/            # Shared utilities
│   └── assets/           # Static assets
├── public/               # Copied to output as-is
├── wxt.config.ts         # WXT configuration
└── package.json
```

## Entrypoints

### Background Script

```typescript
// src/entrypoints/background.ts
export default defineBackground(() => {
  console.log('Background script loaded');
  
  browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === 'GET_TAB_INFO') {
      sendResponse({ url: sender.tab?.url });
    }
  });
  
  browser.alarms.create('cleanup', { periodInMinutes: 60 });
  browser.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === 'cleanup') {
      // Cleanup logic
    }
  });
});
```

### Content Script

```typescript
// src/entrypoints/content.ts
export default defineContentScript({
  matches: ['*://*.example.com/*'],
  runAt: 'document_end',
  
  main() {
    console.log('Content script injected');
    
    const banner = document.createElement('div');
    banner.textContent = 'Extension Active';
    document.body.appendChild(banner);
    
    browser.runtime.onMessage.addListener((msg) => {
      if (msg.action === 'highlight') {
        document.querySelectorAll(msg.selector).forEach(el => {
          el.classList.add('highlighted');
        });
      }
    });
  }
});
```

### Popup

```typescript
// src/entrypoints/popup/index.ts
import './style.css';

export default definePopup(() => {
  const button = document.querySelector('#action-btn');
  
  button?.addEventListener('click', async () => {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    await browser.tabs.sendMessage(tab.id!, { action: 'trigger' });
  });
});
```

```html
<!-- src/entrypoints/popup/index.html -->
<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
  </head>
  <body>
    <div id="app">
      <h1>My Extension</h1>
      <button id="action-btn">Click Me</button>
    </div>
    <script type="module" src="./index.ts"></script>
  </body>
</html>
```

### Options Page

```typescript
// src/entrypoints/options/index.ts
export default defineOptions(() => {
  const form = document.querySelector('#settings-form');
  
  browser.storage.sync.get(['apiKey', 'enabled']).then((result) => {
    (document.querySelector('#api-key') as HTMLInputElement).value = result.apiKey || '';
    (document.querySelector('#enabled') as HTMLInputElement).checked = result.enabled || false;
  });
  
  form?.addEventListener('submit', async (e) => {
    e.preventDefault();
    await browser.storage.sync.set({
      apiKey: (document.querySelector('#api-key') as HTMLInputElement).value,
      enabled: (document.querySelector('#enabled') as HTMLInputElement).checked
    });
  });
});
```

## Configuration (wxt.config.ts)

```typescript
import { defineConfig } from 'wxt';

export default defineConfig({
  manifest: {
    name: 'My Extension',
    version: '1.0.0',
    description: 'Does cool things',
    permissions: ['storage', 'tabs', 'activeTab'],
    host_permissions: ['*://*.example.com/*'],
    action: { default_popup: 'popup.html' }
  },
  srcDir: 'src',
  outDir: '.output',
  browser: 'chrome', // 'chrome' | 'firefox' | 'safari' | 'edge'
  dev: { port: 3000, reloadCommand: 'Alt+R' },
  imports: { eslintrc: { enabled: true } }
});
```

## UI Framework Integration

### Vue 3

```bash
npm install vue
npm install -D @vitejs/plugin-vue
```

```typescript
// wxt.config.ts
import vue from '@vitejs/plugin-vue';
export default defineConfig({
  vite: () => ({ plugins: [vue()] })
});
```

```vue
<!-- src/entrypoints/popup/Popup.vue -->
<template>
  <div class="popup">
    <h1>{{ title }}</h1>
    <button @click="handleClick">Count: {{ count }}</button>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue';
const title = 'My Extension';
const count = ref(0);
const handleClick = () => {
  count.value++;
  browser.storage.local.set({ count: count.value });
};
</script>
```

```typescript
// src/entrypoints/popup/main.ts
import { createApp } from 'vue';
import Popup from './Popup.vue';
createApp(Popup).mount('#app');
```

### React

```bash
npm install react react-dom
npm install -D @types/react @types/react-dom @vitejs/plugin-react
```

```typescript
// wxt.config.ts
import react from '@vitejs/plugin-react';
export default defineConfig({
  vite: () => ({ plugins: [react()] })
});
```

```tsx
// src/entrypoints/popup/Popup.tsx
import { useState, useEffect } from 'react';

export function Popup() {
  const [count, setCount] = useState(0);
  
  useEffect(() => {
    browser.storage.local.get('count').then(({ count }) => setCount(count || 0));
  }, []);
  
  const increment = () => {
    const newCount = count + 1;
    setCount(newCount);
    browser.storage.local.set({ count: newCount });
  };
  
  return (
    <div className="popup">
      <h1>My Extension</h1>
      <button onClick={increment}>Count: {count}</button>
    </div>
  );
}
```

```tsx
// src/entrypoints/popup/main.tsx
import { createRoot } from 'react-dom/client';
import { Popup } from './Popup';
createRoot(document.getElementById('app')!).render(<Popup />);
```

### Svelte

```bash
npm install svelte
npm install -D @sveltejs/vite-plugin-svelte
```

```typescript
// wxt.config.ts
import { svelte } from '@sveltejs/vite-plugin-svelte';
export default defineConfig({
  vite: () => ({ plugins: [svelte()] })
});
```

```svelte
<!-- src/entrypoints/popup/Popup.svelte -->
<script lang="ts">
  let count = 0;
  async function increment() {
    count++;
    await browser.storage.local.set({ count });
  }
  browser.storage.local.get('count').then(({ count: saved }) => {
    count = saved || 0;
  });
</script>

<div class="popup">
  <h1>My Extension</h1>
  <button on:click={increment}>Count: {count}</button>
</div>
```

## Storage API

```typescript
// Local storage (unlimited, extension-only)
await browser.storage.local.set({ key: 'value' });
const result = await browser.storage.local.get('key');
await browser.storage.local.remove('key');

// Sync storage (synced across devices, limited size)
await browser.storage.sync.set({ settings: { theme: 'dark' } });
const { settings } = await browser.storage.sync.get('settings');

// Listen for changes
browser.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === 'local' && changes.key) {
    console.log('New value:', changes.key.newValue);
  }
});
```

## Messaging

```typescript
// Content script → Background
const response = await browser.runtime.sendMessage({
  type: 'FETCH_DATA',
  url: 'https://api.example.com/data'
});

// Background → Content script
const tabs = await browser.tabs.query({ url: '*://*.example.com/*' });
for (const tab of tabs) {
  await browser.tabs.sendMessage(tab.id!, { action: 'refresh' });
}

// Background message handler
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'FETCH_DATA') {
    fetch(message.url)
      .then(res => res.json())
      .then(data => sendResponse({ success: true, data }))
      .catch(err => sendResponse({ success: false, error: err.message }));
    return true; // Keep channel open for async
  }
});
```

## Build Commands

```bash
# Development with hot reload
npm run dev

# Build for Chrome (default)
npm run build

# Build for Firefox
npm run build -- --browser firefox

# Build for all browsers
npm run build -- --browser chrome --browser firefox --browser safari

# Build with specific manifest version
npm run build -- --manifestVersion 2

# Zip for distribution
npm run zip
npm run zip -- --browser firefox --sources
```

## Publishing

### Chrome Web Store

```bash
npm run build
cd .output/chrome-mv3 && zip -r ../../chrome-extension.zip .
# Upload to https://chrome.google.com/webstore/devconsole
```

### Firefox Add-ons

```bash
npm run build -- --browser firefox
npm run zip -- --browser firefox --sources
# Upload to https://addons.mozilla.org/developers/
```

### Edge Add-ons

```bash
npm run build -- --browser edge
# Upload to https://partner.microsoft.com/dashboard/microsoftedge/
```

## Best Practices

### Content Script Isolation

```typescript
// Use Shadow DOM to avoid CSS conflicts
const container = document.createElement('div');
container.id = 'my-extension-root';
const shadow = container.attachShadow({ mode: 'open' });

const style = document.createElement('style');
style.textContent = `.my-widget { /* isolated styles */ }`;
shadow.appendChild(style);
shadow.innerHTML += '<div class="my-widget">Content</div>';
document.body.appendChild(container);
```

### Permission Strategy

```json
{
  "permissions": ["storage", "activeTab"],
  "optional_permissions": ["tabs", "bookmarks"],
  "host_permissions": ["*://*.example.com/*"]
}
```

```typescript
// Request optional permissions at runtime
const granted = await browser.permissions.request({
  permissions: ['tabs'],
  origins: ['*://*.another-site.com/*']
});
```

### Error Handling

```typescript
async function safeStorageGet<T>(key: string, defaultValue: T): Promise<T> {
  try {
    const result = await browser.storage.local.get(key);
    return result[key] ?? defaultValue;
  } catch (err) {
    console.error('Storage error:', err);
    return defaultValue;
  }
}

// Message response pattern
browser.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    try {
      const result = await processMessage(msg);
      sendResponse({ success: true, data: result });
    } catch (err) {
      sendResponse({ success: false, error: err.message });
    }
  })();
  return true;
});
```

### Type Safety

```typescript
type Message =
  | { type: 'GET_TAB_INFO' }
  | { type: 'SET_BADGE'; text: string }
  | { type: 'FETCH_DATA'; url: string };

function sendMessage<T extends Message>(message: T): Promise<any> {
  return browser.runtime.sendMessage(message);
}

// Usage with typed response
const tabInfo = await sendMessage({ type: 'GET_TAB_INFO' });
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `browser is not defined` | Use `import { browser } from 'wxt/browser'` or enable auto-imports |
| Content script not injecting | Check `matches` pattern in entrypoint config |
| Hot reload not working | Ensure `runAt: 'document_end'` for content scripts |
| Build fails with type errors | Run `npm run postinstall` to regenerate types |
| Manifest v2 vs v3 | Use `browser.action` (MV3) vs `browser.browserAction` (MV2) |
| Firefox compatibility | Avoid `chrome.*` namespace, use `browser.*` with polyfill |

## Environment Variables

```bash
# .env
WXT_API_KEY=your_api_key
WXT_DEBUG=true
```

```typescript
const apiKey = import.meta.env.WXT_API_KEY;
const isDebug = import.meta.env.WXT_DEBUG === 'true';
```
