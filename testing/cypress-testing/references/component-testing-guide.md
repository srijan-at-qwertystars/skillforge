# Cypress Component Testing — Comprehensive Guide

A dense, practical reference for setting up and using Cypress Component Testing across React, Vue, Angular, and Svelte. Covers mounting, mocking, hooks, styling, code coverage, and comparison with Storybook.

---

## Table of Contents

1. [Setup for React](#1-setup-for-react)
   - [Vite + React Setup](#vite--react-setup)
   - [Webpack + React Setup](#webpack--react-setup)
   - [cypress.config.ts — Component Configuration](#cypressconfigts--component-configuration)
   - [Support File Setup](#support-file-setup)
   - [Mounting with Providers](#mounting-with-providers-react)
2. [Setup for Vue](#2-setup-for-vue)
   - [Vue 3 + Vite Setup](#vue-3--vite-setup)
   - [Pinia Store Mocking](#pinia-store-mocking)
   - [Vue Router Mocking](#vue-router-mocking)
   - [Mounting with Plugins](#mounting-with-plugins)
3. [Setup for Angular](#3-setup-for-angular)
   - [Angular CLI Integration](#angular-cli-integration)
   - [TestBed Comparison](#testbed-comparison)
   - [Mounting with Providers, Imports, Declarations](#mounting-with-providers-imports-declarations)
4. [Setup for Svelte](#4-setup-for-svelte)
   - [SvelteKit Setup](#sveltekit-setup)
   - [Mounting Svelte Components](#mounting-svelte-components)
   - [Binding and Event Testing](#binding-and-event-testing)
5. [Mounting Components](#5-mounting-components)
   - [cy.mount() Basics](#cymount-basics)
   - [Wrapping with Providers](#wrapping-with-providers)
   - [Custom Mount Commands](#custom-mount-commands)
   - [Passing Props, Slots, and Children](#passing-props-slots-and-children)
6. [Mocking Props, Stores, and API Calls](#6-mocking-props-stores-and-api-calls)
   - [cy.stub() for Callbacks](#cystub-for-callbacks)
   - [cy.intercept() for API Calls](#cyintercept-for-api-calls)
   - [Mocking Redux, Pinia, and NgRx Stores](#mocking-redux-pinia-and-ngrx-stores)
   - [Context Providers](#context-providers)
7. [Testing Hooks](#7-testing-hooks)
   - [Testing Custom React Hooks via Wrapper Components](#testing-custom-react-hooks-via-wrapper-components)
   - [Testing Hook State Changes](#testing-hook-state-changes)
   - [Testing Async Hooks](#testing-async-hooks)
8. [Testing Styled Components](#8-testing-styled-components)
   - [CSS-in-JS Testing](#css-in-js-testing)
   - [Tailwind CSS](#tailwind-css)
   - [CSS Modules](#css-modules)
   - [Verifying Computed Styles](#verifying-computed-styles)
   - [Responsive Testing](#responsive-testing)
9. [Code Coverage for Components](#9-code-coverage-for-components)
   - [@cypress/code-coverage Setup](#cypresscode-coverage-setup)
   - [Istanbul Instrumentation](#istanbul-instrumentation)
   - [NYC Configuration](#nyc-configuration)
   - [Merging E2E + Component Coverage](#merging-e2e--component-coverage)
   - [Coverage Thresholds](#coverage-thresholds)
10. [Comparing with Storybook Testing](#10-comparing-with-storybook-testing)
    - [Cypress CT vs Storybook Interaction Tests](#cypress-ct-vs-storybook-interaction-tests)
    - [When to Use Each](#when-to-use-each)
    - [Using Storybook Stories as Cypress Test Fixtures](#using-storybook-stories-as-cypress-test-fixtures)
    - [Pros/Cons Comparison Table](#proscons-comparison-table)

---

## 1. Setup for React

### Vite + React Setup

Install the required packages:

```bash
npm install --save-dev cypress @cypress/react @cypress/vite-dev-server
```

Create or update `cypress.config.ts`:

```ts
// cypress.config.ts
import { defineConfig } from "cypress";
import viteConfig from "./vite.config";

export default defineConfig({
  component: {
    devServer: {
      framework: "react",
      bundler: "vite",
      viteConfig,
    },
    specPattern: "src/**/*.cy.{ts,tsx}",
    supportFile: "cypress/support/component.ts",
  },
});
```

Ensure your `vite.config.ts` includes the React plugin:

```ts
// vite.config.ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@": "/src",
    },
  },
});
```

### Webpack + React Setup

```bash
npm install --save-dev cypress @cypress/react @cypress/webpack-dev-server
```

```ts
// cypress.config.ts
import { defineConfig } from "cypress";
import webpackConfig from "./webpack.config";

export default defineConfig({
  component: {
    devServer: {
      framework: "react",
      bundler: "webpack",
      webpackConfig,
    },
    specPattern: "src/**/*.cy.{ts,tsx}",
    supportFile: "cypress/support/component.ts",
  },
});
```

For Create React App projects, omit the explicit `webpackConfig` — Cypress auto-detects it:

```ts
export default defineConfig({
  component: {
    devServer: {
      framework: "create-react-app",
      bundler: "webpack",
    },
  },
});
```

### cypress.config.ts — Component Configuration

Key configuration options beyond the dev server:

```ts
// cypress.config.ts
import { defineConfig } from "cypress";

export default defineConfig({
  component: {
    devServer: {
      framework: "react",
      bundler: "vite",
    },
    specPattern: "src/**/*.cy.{ts,tsx}",
    supportFile: "cypress/support/component.ts",
    indexHtmlFile: "cypress/support/component-index.html",
    viewportWidth: 1280,
    viewportHeight: 720,
    video: false,
    screenshotOnRunFailure: true,
    setupNodeEvents(on, config) {
      // register code coverage plugin, etc.
      return config;
    },
  },
});
```

Custom `component-index.html` for loading global stylesheets or fonts:

```html
<!-- cypress/support/component-index.html -->
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <link rel="stylesheet" href="/src/index.css" />
  </head>
  <body>
    <div data-cy-root></div>
  </body>
</html>
```

### Support File Setup

```ts
// cypress/support/component.ts
import { mount } from "cypress/react18";
import "./commands";

// Augment the Cypress namespace
declare global {
  namespace Cypress {
    interface Chainable {
      mount: typeof mount;
    }
  }
}

Cypress.Commands.add("mount", mount);
```

Import global styles and reset CSS in the support file so every component test starts with the correct baseline:

```ts
// cypress/support/component.ts
import "../../src/index.css";
import "../../src/styles/reset.css";
import { mount } from "cypress/react18";

Cypress.Commands.add("mount", mount);
```

### Mounting with Providers (React)

Most React apps need context providers. Create a reusable wrapper:

```tsx
// cypress/support/mount.tsx
import { mount, MountOptions, MountReturn } from "cypress/react18";
import { BrowserRouter } from "react-router-dom";
import { Provider } from "react-redux";
import { ThemeProvider } from "styled-components";
import { I18nextProvider } from "react-i18next";
import { configureStore, EnhancedStore } from "@reduxjs/toolkit";
import rootReducer, { RootState } from "../../src/store/rootReducer";
import i18n from "../../src/i18n";
import { theme } from "../../src/styles/theme";

interface CustomMountOptions extends MountOptions {
  reduxState?: Partial<RootState>;
  route?: string;
  locale?: string;
}

function createTestStore(preloadedState?: Partial<RootState>): EnhancedStore {
  return configureStore({
    reducer: rootReducer,
    preloadedState: preloadedState as RootState,
  });
}

export function mountWithProviders(
  component: React.ReactNode,
  options: CustomMountOptions = {}
): Cypress.Chainable<MountReturn> {
  const { reduxState, route = "/", locale = "en", ...mountOptions } = options;

  const store = createTestStore(reduxState);

  if (locale !== "en") {
    i18n.changeLanguage(locale);
  }

  window.history.pushState({}, "", route);

  const wrapped = (
    <Provider store={store}>
      <BrowserRouter>
        <I18nextProvider i18n={i18n}>
          <ThemeProvider theme={theme}>{component}</ThemeProvider>
        </I18nextProvider>
      </BrowserRouter>
    </Provider>
  );

  return mount(wrapped, mountOptions);
}

Cypress.Commands.add("mount", mountWithProviders);
```

Usage in a spec:

```tsx
// src/components/UserProfile.cy.tsx
import { UserProfile } from "./UserProfile";

describe("UserProfile", () => {
  it("renders authenticated user", () => {
    cy.mount(<UserProfile userId="u-123" />, {
      reduxState: {
        auth: { user: { id: "u-123", name: "Ada Lovelace" }, token: "abc" },
      },
      route: "/profile/u-123",
    });

    cy.findByText("Ada Lovelace").should("be.visible");
  });
});
```

---

## 2. Setup for Vue

### Vue 3 + Vite Setup

```bash
npm install --save-dev cypress @cypress/vue @cypress/vite-dev-server
```

```ts
// cypress.config.ts
import { defineConfig } from "cypress";

export default defineConfig({
  component: {
    devServer: {
      framework: "vue",
      bundler: "vite",
    },
    specPattern: "src/**/*.cy.{ts,tsx}",
    supportFile: "cypress/support/component.ts",
  },
});
```

```ts
// cypress/support/component.ts
import { mount } from "cypress/vue";

declare global {
  namespace Cypress {
    interface Chainable {
      mount: typeof mount;
    }
  }
}

Cypress.Commands.add("mount", mount);
```

### Pinia Store Mocking

```ts
// src/stores/userStore.ts
import { defineStore } from "pinia";

interface User {
  id: string;
  name: string;
  email: string;
}

export const useUserStore = defineStore("user", {
  state: () => ({
    currentUser: null as User | null,
    isLoading: false,
  }),
  actions: {
    async fetchUser(id: string) {
      this.isLoading = true;
      const res = await fetch(`/api/users/${id}`);
      this.currentUser = await res.json();
      this.isLoading = false;
    },
  },
  getters: {
    displayName: (state) => state.currentUser?.name ?? "Guest",
  },
});
```

Test with a mocked Pinia store:

```ts
// src/components/UserCard.cy.ts
import { createPinia, setActivePinia } from "pinia";
import { createTestingPinia } from "@pinia/testing";
import UserCard from "./UserCard.vue";
import { useUserStore } from "../stores/userStore";

describe("UserCard", () => {
  it("displays user info from Pinia store", () => {
    const pinia = createTestingPinia({
      initialState: {
        user: {
          currentUser: { id: "1", name: "Grace Hopper", email: "grace@example.com" },
          isLoading: false,
        },
      },
      stubActions: false,
    });

    cy.mount(UserCard, {
      global: {
        plugins: [pinia],
      },
    });

    cy.get("[data-cy=user-name]").should("contain", "Grace Hopper");
    cy.get("[data-cy=user-email]").should("contain", "grace@example.com");
  });

  it("stubs fetchUser action", () => {
    const pinia = createTestingPinia({ stubActions: true });
    cy.mount(UserCard, { global: { plugins: [pinia] } });

    const store = useUserStore();
    expect(store.fetchUser).to.have.been.calledOnce;
  });
});
```

### Vue Router Mocking

```ts
// src/components/NavBar.cy.ts
import { createRouter, createMemoryHistory, RouteRecordRaw } from "vue-router";
import NavBar from "./NavBar.vue";

const routes: RouteRecordRaw[] = [
  { path: "/", component: { template: "<div>Home</div>" } },
  { path: "/about", component: { template: "<div>About</div>" } },
  { path: "/dashboard", component: { template: "<div>Dashboard</div>" } },
];

describe("NavBar", () => {
  it("highlights active route", () => {
    const router = createRouter({
      history: createMemoryHistory(),
      routes,
    });

    router.push("/about");

    cy.mount(NavBar, {
      global: {
        plugins: [router],
      },
    }).then(() => {
      cy.get("[data-cy=nav-about]").should("have.class", "active");
    });
  });

  it("navigates on click", () => {
    const router = createRouter({ history: createMemoryHistory(), routes });

    cy.mount(NavBar, { global: { plugins: [router] } });

    cy.get("[data-cy=nav-dashboard]").click();
    cy.get("[data-cy=nav-dashboard]").should("have.class", "active");
  });
});
```

### Mounting with Plugins

Create a reusable mount helper with all global plugins:

```ts
// cypress/support/vue-mount.ts
import { mount } from "cypress/vue";
import { createPinia } from "pinia";
import { createRouter, createMemoryHistory } from "vue-router";
import { createI18n } from "vue-i18n";
import type { Component } from "vue";
import type { MountingOptions } from "cypress/vue";

const i18n = createI18n({
  locale: "en",
  messages: { en: { greeting: "Hello" }, fr: { greeting: "Bonjour" } },
});

interface VueMountOptions<T extends Component> extends MountingOptions<T> {
  initialRoute?: string;
}

export function mountWithPlugins<T extends Component>(
  component: T,
  options: VueMountOptions<T> = {}
) {
  const { initialRoute = "/", ...mountOptions } = options;
  const router = createRouter({
    history: createMemoryHistory(initialRoute),
    routes: [{ path: "/:pathMatch(.*)*", component: { template: "<slot />" } }],
  });

  const globalConfig = mountOptions.global ?? {};
  globalConfig.plugins = [...(globalConfig.plugins ?? []), createPinia(), router, i18n];
  mountOptions.global = globalConfig;

  return mount(component, mountOptions);
}
```

---

## 3. Setup for Angular

### Angular CLI Integration

```bash
ng add @cypress/schematic
npx cypress open --component
```

```ts
// cypress.config.ts
import { defineConfig } from "cypress";

export default defineConfig({
  component: {
    devServer: {
      framework: "angular",
      bundler: "webpack",
      options: {
        projectConfig: {
          root: "",
          sourceRoot: "src",
          buildOptions: {
            tsConfig: "tsconfig.json",
          },
        },
      },
    },
    specPattern: "src/**/*.cy.ts",
    supportFile: "cypress/support/component.ts",
  },
});
```

```ts
// cypress/support/component.ts
import { mount } from "cypress/angular";

declare global {
  namespace Cypress {
    interface Chainable {
      mount: typeof mount;
    }
  }
}

Cypress.Commands.add("mount", mount);
```

### TestBed Comparison

| Feature                  | Angular TestBed             | Cypress Component Testing        |
| ------------------------ | --------------------------- | -------------------------------- |
| Rendering                | jsdom (virtual DOM)         | Real browser DOM                 |
| Visual verification      | Snapshot only               | Live in-browser rendering        |
| User interactions        | Programmatic `triggerEvent` | Real clicks, typing, scrolling   |
| Network mocking          | HttpClientTestingModule     | `cy.intercept()` on real network |
| Debug experience         | Console output              | Time-travel, DOM snapshots       |
| Speed                    | Fast (no browser)           | Moderate (real browser)          |
| Accessibility testing    | Limited                     | Real a11y with cypress-axe       |

### Mounting with Providers, Imports, Declarations

```ts
// src/app/components/todo-list/todo-list.component.cy.ts
import { TodoListComponent } from "./todo-list.component";
import { TodoItemComponent } from "../todo-item/todo-item.component";
import { TodoService } from "../../services/todo.service";
import { HttpClientModule } from "@angular/common/http";
import { ReactiveFormsModule } from "@angular/forms";
import { MatListModule } from "@angular/material/list";
import { MatCheckboxModule } from "@angular/material/checkbox";

describe("TodoListComponent", () => {
  const mockTodoService = {
    getTodos: cy.stub().returns(
      Promise.resolve([
        { id: 1, title: "Write tests", done: false },
        { id: 2, title: "Ship feature", done: true },
      ])
    ),
    toggleTodo: cy.stub().returns(Promise.resolve()),
  };

  beforeEach(() => {
    cy.mount(TodoListComponent, {
      declarations: [TodoItemComponent],
      imports: [
        HttpClientModule,
        ReactiveFormsModule,
        MatListModule,
        MatCheckboxModule,
      ],
      providers: [{ provide: TodoService, useValue: mockTodoService }],
      componentProperties: {
        title: "My Todos",
        showCompleted: true,
      },
    });
  });

  it("renders todos from service", () => {
    cy.get("[data-cy=todo-item]").should("have.length", 2);
    cy.get("[data-cy=todo-item]").first().should("contain", "Write tests");
  });

  it("calls toggleTodo when checkbox clicked", () => {
    cy.get("[data-cy=todo-checkbox]")
      .first()
      .click()
      .then(() => {
        expect(mockTodoService.toggleTodo).to.have.been.calledWith(1);
      });
  });
});
```

Standalone component mounting (Angular 14+):

```ts
// src/app/components/alert/alert.component.cy.ts
import { AlertComponent } from "./alert.component";
import { CommonModule } from "@angular/common";

describe("AlertComponent (Standalone)", () => {
  it("renders danger variant", () => {
    cy.mount(AlertComponent, {
      imports: [CommonModule],
      componentProperties: {
        variant: "danger",
        message: "Something went wrong",
        dismissible: true,
      },
    });

    cy.get("[data-cy=alert]")
      .should("have.class", "alert-danger")
      .and("contain", "Something went wrong");

    cy.get("[data-cy=dismiss-btn]").should("be.visible");
  });
});
```

---

## 4. Setup for Svelte

### SvelteKit Setup

```bash
npm install --save-dev cypress @cypress/svelte cypress-svelte-unit-test
```

```ts
// cypress.config.ts
import { defineConfig } from "cypress";

export default defineConfig({
  component: {
    devServer: {
      framework: "svelte",
      bundler: "vite",
    },
    specPattern: "src/**/*.cy.{ts,js}",
    supportFile: "cypress/support/component.ts",
  },
});
```

```ts
// cypress/support/component.ts
import { mount } from "cypress/svelte";

declare global {
  namespace Cypress {
    interface Chainable {
      mount: typeof mount;
    }
  }
}

Cypress.Commands.add("mount", mount);
```

### Mounting Svelte Components

```ts
// src/lib/components/Counter.cy.ts
import Counter from "./Counter.svelte";

describe("Counter", () => {
  it("renders with initial count", () => {
    cy.mount(Counter, { props: { initialCount: 5 } });
    cy.get("[data-cy=count]").should("have.text", "5");
  });

  it("increments on button click", () => {
    cy.mount(Counter, { props: { initialCount: 0 } });
    cy.get("[data-cy=increment]").click();
    cy.get("[data-cy=count]").should("have.text", "1");
  });

  it("respects max prop", () => {
    cy.mount(Counter, { props: { initialCount: 9, max: 10 } });
    cy.get("[data-cy=increment]").click();
    cy.get("[data-cy=count]").should("have.text", "10");
    cy.get("[data-cy=increment]").should("be.disabled");
  });
});
```

### Binding and Event Testing

```ts
// src/lib/components/SearchInput.cy.ts
import SearchInput from "./SearchInput.svelte";

describe("SearchInput", () => {
  it("dispatches search event on submit", () => {
    const onSearch = cy.stub().as("searchHandler");

    cy.mount(SearchInput, {
      props: {
        placeholder: "Search users...",
      },
    }).then(({ component }) => {
      component.$on("search", (e: CustomEvent<string>) => {
        onSearch(e.detail);
      });
    });

    cy.get("[data-cy=search-input]").type("cypress{enter}");
    cy.get("@searchHandler").should("have.been.calledWith", "cypress");
  });

  it("supports two-way binding via bind:value", () => {
    cy.mount(SearchInput, {
      props: { value: "" },
    });

    cy.get("[data-cy=search-input]").type("hello");
    cy.get("[data-cy=search-input]").should("have.value", "hello");
  });

  it("shows clear button when input has value", () => {
    cy.mount(SearchInput, { props: { value: "test" } });
    cy.get("[data-cy=clear-btn]").should("be.visible");
    cy.get("[data-cy=clear-btn]").click();
    cy.get("[data-cy=search-input]").should("have.value", "");
  });
});
```

---

## 5. Mounting Components

### cy.mount() Basics

The `cy.mount()` command renders a component into the test runner's real browser DOM. It works identically to how your framework's test utilities render components but inside a Cypress-controlled environment.

```tsx
// Simplest possible mount — React
import { Button } from "./Button";

it("renders", () => {
  cy.mount(<Button label="Click me" />);
  cy.get("button").should("have.text", "Click me");
});
```

```ts
// Vue
import Modal from "./Modal.vue";

it("renders", () => {
  cy.mount(Modal, { props: { title: "Confirm", open: true } });
  cy.get("[data-cy=modal-title]").should("have.text", "Confirm");
});
```

### Wrapping with Providers

For components requiring context, wrap the component inline or use a helper:

```tsx
// Inline wrapping — React
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { UserList } from "./UserList";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: false } },
});

it("renders user list with React Query provider", () => {
  cy.intercept("GET", "/api/users", { body: [{ id: 1, name: "Alan Turing" }] });

  cy.mount(
    <QueryClientProvider client={queryClient}>
      <UserList />
    </QueryClientProvider>
  );

  cy.findByText("Alan Turing").should("be.visible");
});
```

### Custom Mount Commands

Define a project-wide custom mount in `cypress/support/component.ts`:

```tsx
// cypress/support/component.ts
import { mount, MountOptions, MountReturn } from "cypress/react18";
import { MemoryRouter, MemoryRouterProps } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

interface AppMountOptions extends MountOptions {
  routerProps?: MemoryRouterProps;
  queryClient?: QueryClient;
}

const defaultQueryClient = () =>
  new QueryClient({
    defaultOptions: {
      queries: { retry: false, gcTime: 0 },
    },
  });

function customMount(
  component: React.ReactNode,
  options: AppMountOptions = {}
): Cypress.Chainable<MountReturn> {
  const { routerProps, queryClient, ...mountOptions } = options;

  const wrapped = (
    <QueryClientProvider client={queryClient ?? defaultQueryClient()}>
      <MemoryRouter {...routerProps}>{component}</MemoryRouter>
    </QueryClientProvider>
  );

  return mount(wrapped, mountOptions);
}

Cypress.Commands.add("mount", customMount);

declare global {
  namespace Cypress {
    interface Chainable {
      mount(
        component: React.ReactNode,
        options?: AppMountOptions
      ): Cypress.Chainable<MountReturn>;
    }
  }
}
```

### Passing Props, Slots, and Children

**React — Props and Children:**

```tsx
import { Card } from "./Card";

it("renders with children", () => {
  cy.mount(
    <Card title="Settings" variant="outlined">
      <p>Card body content</p>
      <button>Save</button>
    </Card>
  );

  cy.get("[data-cy=card-title]").should("have.text", "Settings");
  cy.get("[data-cy=card-body]").find("button").should("have.text", "Save");
});
```

**Vue — Named Slots:**

```ts
import DataTable from "./DataTable.vue";

it("renders header and footer slots", () => {
  cy.mount(DataTable, {
    props: {
      rows: [{ id: 1, name: "Item A" }],
      columns: ["id", "name"],
    },
    slots: {
      header: "<h2>Inventory</h2>",
      footer: '<div data-cy="footer">Total: 1 item</div>',
      "cell-name": '<template #cell-name="{ value }"><strong>{{ value }}</strong></template>',
    },
  });

  cy.get("h2").should("have.text", "Inventory");
  cy.get("[data-cy=footer]").should("contain", "Total: 1 item");
});
```

---

## 6. Mocking Props, Stores, and API Calls

### cy.stub() for Callbacks

```tsx
// src/components/DeleteDialog.cy.tsx
import { DeleteDialog } from "./DeleteDialog";

describe("DeleteDialog", () => {
  it("calls onConfirm with item id", () => {
    const onConfirm = cy.stub().as("onConfirm");
    const onCancel = cy.stub().as("onCancel");

    cy.mount(
      <DeleteDialog
        itemId="item-42"
        itemName="Report Q4"
        onConfirm={onConfirm}
        onCancel={onCancel}
      />
    );

    cy.findByText("Report Q4").should("be.visible");
    cy.findByRole("button", { name: /confirm/i }).click();

    cy.get("@onConfirm").should("have.been.calledOnceWith", "item-42");
    cy.get("@onCancel").should("not.have.been.called");
  });

  it("calls onCancel when dismissed", () => {
    const onConfirm = cy.stub();
    const onCancel = cy.stub().as("onCancel");

    cy.mount(
      <DeleteDialog
        itemId="item-42"
        itemName="Report Q4"
        onConfirm={onConfirm}
        onCancel={onCancel}
      />
    );

    cy.findByRole("button", { name: /cancel/i }).click();
    cy.get("@onCancel").should("have.been.calledOnce");
  });
});
```

### cy.intercept() for API Calls

```tsx
// src/components/UserSearch.cy.tsx
import { UserSearch } from "./UserSearch";

describe("UserSearch", () => {
  it("displays search results from API", () => {
    cy.intercept("GET", "/api/users/search?q=*", {
      statusCode: 200,
      body: {
        results: [
          { id: "1", name: "Marie Curie", role: "Scientist" },
          { id: "2", name: "Margaret Hamilton", role: "Engineer" },
        ],
      },
    }).as("searchUsers");

    cy.mount(<UserSearch />);

    cy.get("[data-cy=search-input]").type("mar");
    cy.wait("@searchUsers");

    cy.get("[data-cy=result-item]").should("have.length", 2);
    cy.get("[data-cy=result-item]").first().should("contain", "Marie Curie");
  });

  it("shows error state on API failure", () => {
    cy.intercept("GET", "/api/users/search?q=*", {
      statusCode: 500,
      body: { error: "Internal Server Error" },
    }).as("searchFailed");

    cy.mount(<UserSearch />);

    cy.get("[data-cy=search-input]").type("test");
    cy.wait("@searchFailed");

    cy.get("[data-cy=error-message]")
      .should("be.visible")
      .and("contain", "Something went wrong");
  });

  it("shows loading skeleton during request", () => {
    cy.intercept("GET", "/api/users/search?q=*", {
      statusCode: 200,
      body: { results: [] },
      delay: 1000,
    }).as("slowSearch");

    cy.mount(<UserSearch />);

    cy.get("[data-cy=search-input]").type("test");
    cy.get("[data-cy=loading-skeleton]").should("be.visible");

    cy.wait("@slowSearch");
    cy.get("[data-cy=loading-skeleton]").should("not.exist");
    cy.get("[data-cy=empty-state]").should("be.visible");
  });
});
```

### Mocking Redux, Pinia, and NgRx Stores

**Redux (React):**

```tsx
// src/components/CartSummary.cy.tsx
import { CartSummary } from "./CartSummary";
import { Provider } from "react-redux";
import { configureStore } from "@reduxjs/toolkit";
import cartReducer, { CartState } from "../store/cartSlice";

function renderWithStore(preloadedCart: Partial<CartState> = {}) {
  const store = configureStore({
    reducer: { cart: cartReducer },
    preloadedState: {
      cart: {
        items: [],
        total: 0,
        currency: "USD",
        ...preloadedCart,
      },
    },
  });

  return cy.mount(
    <Provider store={store}>
      <CartSummary />
    </Provider>
  );
}

describe("CartSummary", () => {
  it("shows empty cart", () => {
    renderWithStore({ items: [], total: 0 });
    cy.get("[data-cy=empty-cart]").should("be.visible");
  });

  it("calculates total", () => {
    renderWithStore({
      items: [
        { id: "1", name: "Widget", price: 9.99, quantity: 2 },
        { id: "2", name: "Gadget", price: 24.99, quantity: 1 },
      ],
      total: 44.97,
    });

    cy.get("[data-cy=cart-total]").should("contain", "$44.97");
    cy.get("[data-cy=cart-item]").should("have.length", 2);
  });
});
```

**NgRx (Angular):**

```ts
// src/app/components/notification-bell.component.cy.ts
import { NotificationBellComponent } from "./notification-bell.component";
import { provideMockStore, MockStore } from "@ngrx/store/testing";
import { selectUnreadCount } from "../../store/notification.selectors";

describe("NotificationBellComponent", () => {
  it("shows unread count badge", () => {
    cy.mount(NotificationBellComponent, {
      providers: [
        provideMockStore({
          selectors: [{ selector: selectUnreadCount, value: 5 }],
        }),
      ],
    });

    cy.get("[data-cy=unread-badge]").should("have.text", "5");
  });

  it("hides badge when no unread notifications", () => {
    cy.mount(NotificationBellComponent, {
      providers: [
        provideMockStore({
          selectors: [{ selector: selectUnreadCount, value: 0 }],
        }),
      ],
    });

    cy.get("[data-cy=unread-badge]").should("not.exist");
  });
});
```

### Context Providers

```tsx
// src/components/ThemeToggle.cy.tsx
import { ThemeToggle } from "./ThemeToggle";
import { ThemeContext, Theme } from "../contexts/ThemeContext";
import React, { useState } from "react";

function ThemeTestWrapper({ initialTheme = "light" }: { initialTheme?: Theme }) {
  const [theme, setTheme] = useState<Theme>(initialTheme);
  return (
    <ThemeContext.Provider value={{ theme, setTheme }}>
      <ThemeToggle />
      <div data-cy="current-theme">{theme}</div>
    </ThemeContext.Provider>
  );
}

describe("ThemeToggle", () => {
  it("toggles dark mode", () => {
    cy.mount(<ThemeTestWrapper initialTheme="light" />);

    cy.get("[data-cy=current-theme]").should("have.text", "light");
    cy.get("[data-cy=theme-toggle]").click();
    cy.get("[data-cy=current-theme]").should("have.text", "dark");
  });
});
```

---

## 7. Testing Hooks

### Testing Custom React Hooks via Wrapper Components

Cypress mounts components, not hooks directly. Wrap hooks in a small test component:

```tsx
// src/hooks/useDebounce.ts
import { useState, useEffect } from "react";

export function useDebounce<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(timer);
  }, [value, delayMs]);

  return debounced;
}
```

```tsx
// src/hooks/useDebounce.cy.tsx
import React, { useState } from "react";
import { useDebounce } from "./useDebounce";

function TestComponent({ delay = 300 }: { delay?: number }) {
  const [input, setInput] = useState("");
  const debounced = useDebounce(input, delay);

  return (
    <div>
      <input
        data-cy="input"
        value={input}
        onChange={(e) => setInput(e.target.value)}
      />
      <span data-cy="debounced">{debounced}</span>
    </div>
  );
}

describe("useDebounce", () => {
  it("debounces value updates", () => {
    cy.mount(<TestComponent delay={500} />);

    cy.get("[data-cy=input]").type("hello");
    cy.get("[data-cy=debounced]").should("have.text", "");

    cy.clock();
    cy.get("[data-cy=input]").clear().type("world");
    cy.tick(499);
    cy.get("[data-cy=debounced]").should("not.have.text", "world");
    cy.tick(1);
    cy.get("[data-cy=debounced]").should("have.text", "world");
  });
});
```

### Testing Hook State Changes

```tsx
// src/hooks/useToggle.ts
import { useCallback, useState } from "react";

export function useToggle(initial = false): [boolean, () => void, () => void, () => void] {
  const [state, setState] = useState(initial);
  const toggle = useCallback(() => setState((s) => !s), []);
  const setTrue = useCallback(() => setState(true), []);
  const setFalse = useCallback(() => setState(false), []);
  return [state, toggle, setTrue, setFalse];
}
```

```tsx
// src/hooks/useToggle.cy.tsx
import React from "react";
import { useToggle } from "./useToggle";

function ToggleHarness() {
  const [isOpen, toggle, open, close] = useToggle(false);

  return (
    <div>
      <span data-cy="state">{isOpen ? "open" : "closed"}</span>
      <button data-cy="toggle" onClick={toggle}>Toggle</button>
      <button data-cy="open" onClick={open}>Open</button>
      <button data-cy="close" onClick={close}>Close</button>
    </div>
  );
}

describe("useToggle", () => {
  beforeEach(() => cy.mount(<ToggleHarness />));

  it("starts closed", () => {
    cy.get("[data-cy=state]").should("have.text", "closed");
  });

  it("toggles state", () => {
    cy.get("[data-cy=toggle]").click();
    cy.get("[data-cy=state]").should("have.text", "open");
    cy.get("[data-cy=toggle]").click();
    cy.get("[data-cy=state]").should("have.text", "closed");
  });

  it("open and close set explicit states", () => {
    cy.get("[data-cy=open]").click();
    cy.get("[data-cy=state]").should("have.text", "open");
    cy.get("[data-cy=open]").click();
    cy.get("[data-cy=state]").should("have.text", "open");
    cy.get("[data-cy=close]").click();
    cy.get("[data-cy=state]").should("have.text", "closed");
  });
});
```

### Testing Async Hooks

```tsx
// src/hooks/useFetch.ts
import { useState, useEffect } from "react";

interface FetchState<T> {
  data: T | null;
  error: string | null;
  isLoading: boolean;
}

export function useFetch<T>(url: string): FetchState<T> {
  const [state, setState] = useState<FetchState<T>>({
    data: null,
    error: null,
    isLoading: true,
  });

  useEffect(() => {
    let cancelled = false;
    setState({ data: null, error: null, isLoading: true });

    fetch(url)
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json();
      })
      .then((data) => {
        if (!cancelled) setState({ data, error: null, isLoading: false });
      })
      .catch((err) => {
        if (!cancelled) setState({ data: null, error: err.message, isLoading: false });
      });

    return () => {
      cancelled = true;
    };
  }, [url]);

  return state;
}
```

```tsx
// src/hooks/useFetch.cy.tsx
import React from "react";
import { useFetch } from "./useFetch";

interface User {
  id: number;
  name: string;
}

function FetchHarness({ url }: { url: string }) {
  const { data, error, isLoading } = useFetch<User[]>(url);

  if (isLoading) return <div data-cy="loading">Loading...</div>;
  if (error) return <div data-cy="error">{error}</div>;

  return (
    <ul data-cy="results">
      {data?.map((u) => (
        <li key={u.id} data-cy="user">{u.name}</li>
      ))}
    </ul>
  );
}

describe("useFetch", () => {
  it("fetches and renders data", () => {
    cy.intercept("GET", "/api/users", {
      body: [
        { id: 1, name: "Linus Torvalds" },
        { id: 2, name: "Guido van Rossum" },
      ],
    }).as("fetchUsers");

    cy.mount(<FetchHarness url="/api/users" />);

    cy.get("[data-cy=loading]").should("be.visible");
    cy.wait("@fetchUsers");
    cy.get("[data-cy=user]").should("have.length", 2);
  });

  it("handles fetch errors", () => {
    cy.intercept("GET", "/api/users", { statusCode: 503 }).as("failedFetch");

    cy.mount(<FetchHarness url="/api/users" />);

    cy.wait("@failedFetch");
    cy.get("[data-cy=error]").should("contain", "HTTP 503");
  });
});
```

---

## 8. Testing Styled Components

### CSS-in-JS Testing

Cypress renders components in a real browser, so CSS-in-JS libraries (styled-components, Emotion) inject real `<style>` tags. No special setup is required beyond importing the `ThemeProvider` if needed.

```tsx
// src/components/Badge.cy.tsx
import styled from "styled-components";
import { Badge } from "./Badge";

describe("Badge", () => {
  it("applies correct colors for status variant", () => {
    cy.mount(<Badge variant="success">Active</Badge>);

    cy.get("[data-cy=badge]")
      .should("have.css", "background-color", "rgb(34, 197, 94)")
      .and("have.css", "color", "rgb(255, 255, 255)");
  });

  it("applies warning variant styles", () => {
    cy.mount(<Badge variant="warning">Pending</Badge>);

    cy.get("[data-cy=badge]").should(
      "have.css",
      "background-color",
      "rgb(234, 179, 8)"
    );
  });
});
```

### Tailwind CSS

Import the compiled Tailwind stylesheet in the support file or `component-index.html`:

```ts
// cypress/support/component.ts
import "../../src/index.css"; // contains @tailwind directives (compiled)
```

Then test Tailwind utility classes by verifying computed styles, not class names:

```tsx
// src/components/Alert.cy.tsx
import { Alert } from "./Alert";

describe("Alert with Tailwind", () => {
  it("renders error alert with correct styles", () => {
    cy.mount(<Alert type="error" message="Validation failed" />);

    cy.get("[data-cy=alert]")
      .should("have.css", "border-color", "rgb(239, 68, 68)")
      .and("have.css", "padding")
      .and("not.be.empty");
  });

  it("is dismissible", () => {
    cy.mount(<Alert type="info" message="Heads up!" dismissible />);
    cy.get("[data-cy=alert]").should("be.visible");
    cy.get("[data-cy=dismiss]").click();
    cy.get("[data-cy=alert]").should("not.exist");
  });
});
```

### CSS Modules

CSS Modules work automatically with Vite and Webpack loaders. The compiled class names are hashed, so always select by `data-cy` attributes or roles — never by generated class names.

```tsx
// src/components/Sidebar.cy.tsx
import { Sidebar } from "./Sidebar";

describe("Sidebar", () => {
  it("collapses and expands", () => {
    cy.mount(<Sidebar defaultCollapsed={false} />);

    cy.get("[data-cy=sidebar]").should("have.css", "width", "280px");

    cy.get("[data-cy=collapse-btn]").click();
    cy.get("[data-cy=sidebar]").should("have.css", "width", "64px");
  });
});
```

### Verifying Computed Styles

Use `should("have.css", ...)` for computed CSS and `window.getComputedStyle` for complex assertions:

```tsx
// src/components/ProgressBar.cy.tsx
import { ProgressBar } from "./ProgressBar";

describe("ProgressBar", () => {
  it("renders correct width percentage", () => {
    cy.mount(<ProgressBar value={65} max={100} />);

    cy.get("[data-cy=progress-fill]").should(($el) => {
      const width = parseFloat($el.css("width"));
      const parentWidth = parseFloat($el.parent().css("width"));
      const percentage = (width / parentWidth) * 100;
      expect(percentage).to.be.closeTo(65, 1);
    });
  });

  it("applies animation transition", () => {
    cy.mount(<ProgressBar value={50} max={100} animated />);

    cy.get("[data-cy=progress-fill]").should(
      "have.css",
      "transition"
    );
  });

  it("uses semantic colors for thresholds", () => {
    cy.mount(<ProgressBar value={15} max={100} />);
    cy.get("[data-cy=progress-fill]").should(
      "have.css",
      "background-color",
      "rgb(239, 68, 68)" // red for < 25%
    );

    cy.mount(<ProgressBar value={80} max={100} />);
    cy.get("[data-cy=progress-fill]").should(
      "have.css",
      "background-color",
      "rgb(34, 197, 94)" // green for >= 75%
    );
  });
});
```

### Responsive Testing

Use `cy.viewport()` to test responsive layouts in component tests:

```tsx
// src/components/NavigationMenu.cy.tsx
import { NavigationMenu } from "./NavigationMenu";

describe("NavigationMenu — Responsive", () => {
  const links = [
    { label: "Home", href: "/" },
    { label: "Products", href: "/products" },
    { label: "About", href: "/about" },
  ];

  it("shows horizontal nav on desktop", () => {
    cy.viewport(1280, 720);
    cy.mount(<NavigationMenu links={links} />);

    cy.get("[data-cy=desktop-nav]").should("be.visible");
    cy.get("[data-cy=mobile-hamburger]").should("not.be.visible");
  });

  it("shows hamburger on mobile", () => {
    cy.viewport(375, 667);
    cy.mount(<NavigationMenu links={links} />);

    cy.get("[data-cy=desktop-nav]").should("not.be.visible");
    cy.get("[data-cy=mobile-hamburger]").should("be.visible");
  });

  it("opens mobile drawer on hamburger click", () => {
    cy.viewport(375, 667);
    cy.mount(<NavigationMenu links={links} />);

    cy.get("[data-cy=mobile-hamburger]").click();
    cy.get("[data-cy=mobile-drawer]").should("be.visible");
    cy.get("[data-cy=mobile-nav-link]").should("have.length", 3);
  });

  it("renders correctly on tablet", () => {
    cy.viewport("ipad-2");
    cy.mount(<NavigationMenu links={links} />);
    cy.get("[data-cy=desktop-nav]").should("be.visible");
  });
});
```

---

## 9. Code Coverage for Components

### @cypress/code-coverage Setup

```bash
npm install --save-dev @cypress/code-coverage babel-plugin-istanbul nyc
```

Register the plugin in `cypress.config.ts`:

```ts
// cypress.config.ts
import { defineConfig } from "cypress";
import codeCoverageTask from "@cypress/code-coverage/task";

export default defineConfig({
  component: {
    devServer: {
      framework: "react",
      bundler: "vite",
    },
    setupNodeEvents(on, config) {
      codeCoverageTask(on, config);
      return config;
    },
  },
});
```

Import the support file hook:

```ts
// cypress/support/component.ts
import "@cypress/code-coverage/support";
import { mount } from "cypress/react18";

Cypress.Commands.add("mount", mount);
```

### Istanbul Instrumentation

**For Babel (Webpack/CRA):**

Add the Istanbul plugin to `.babelrc` or `babel.config.js`:

```json
{
  "env": {
    "test": {
      "plugins": ["istanbul"]
    }
  }
}
```

Set the environment variable when running Cypress:

```bash
BABEL_ENV=test npx cypress run --component
```

**For Vite:**

Use the `vite-plugin-istanbul` package:

```bash
npm install --save-dev vite-plugin-istanbul
```

```ts
// vite.config.ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import istanbul from "vite-plugin-istanbul";

export default defineConfig({
  plugins: [
    react(),
    istanbul({
      include: "src/*",
      exclude: ["node_modules", "cypress"],
      extension: [".ts", ".tsx"],
      cypress: true,
      requireEnv: false,
    }),
  ],
});
```

### NYC Configuration

Create `.nycrc.json` at the project root:

```json
{
  "all": true,
  "include": ["src/**/*.{ts,tsx}"],
  "exclude": [
    "src/**/*.cy.{ts,tsx}",
    "src/**/*.test.{ts,tsx}",
    "src/**/*.stories.{ts,tsx}",
    "src/**/*.d.ts",
    "src/test-utils/**",
    "src/mocks/**"
  ],
  "reporter": ["text", "text-summary", "lcov", "json"],
  "report-dir": "coverage/cypress",
  "temp-dir": ".nyc_output",
  "branches": 80,
  "lines": 80,
  "functions": 80,
  "statements": 80
}
```

### Merging E2E + Component Coverage

When running both E2E and component tests, merge the coverage reports:

```json
// package.json (scripts section)
{
  "scripts": {
    "cy:component": "cypress run --component",
    "cy:e2e": "cypress run --e2e",
    "cy:coverage:merge": "npx nyc merge coverage coverage/merged/coverage.json",
    "cy:coverage:report": "npx nyc report --reporter=lcov --reporter=text --temp-dir=coverage/merged --report-dir=coverage/combined",
    "cy:all": "npm run cy:component && npm run cy:e2e && npm run cy:coverage:merge && npm run cy:coverage:report"
  }
}
```

Directory structure after running:

```
coverage/
├── cypress/          # component test coverage
│   └── lcov.info
├── e2e/              # E2E coverage
│   └── lcov.info
├── merged/           # merged raw data
│   └── coverage.json
└── combined/         # final merged report
    └── lcov-report/
        └── index.html
```

### Coverage Thresholds

Enforce thresholds in CI by configuring NYC:

```json
// .nycrc.json
{
  "check-coverage": true,
  "branches": 80,
  "lines": 85,
  "functions": 80,
  "statements": 85,
  "per-file": true
}
```

Add a CI step:

```yaml
# .github/workflows/ci.yml
- name: Run component tests with coverage
  run: npx cypress run --component

- name: Check coverage thresholds
  run: npx nyc check-coverage --branches 80 --lines 85 --functions 80 --statements 85
```

Alternatively, configure thresholds directly in `cypress.config.ts` using the `after:run` event:

```ts
// cypress.config.ts
import { defineConfig } from "cypress";
import codeCoverageTask from "@cypress/code-coverage/task";

export default defineConfig({
  component: {
    devServer: { framework: "react", bundler: "vite" },
    setupNodeEvents(on, config) {
      codeCoverageTask(on, config);

      on("after:run", () => {
        const { execSync } = require("child_process");
        try {
          execSync("npx nyc check-coverage", { stdio: "inherit" });
        } catch {
          process.exit(1);
        }
      });

      return config;
    },
  },
});
```

---

## 10. Comparing with Storybook Testing

### Cypress CT vs Storybook Interaction Tests

**Storybook Interaction Test:**

```tsx
// src/components/LoginForm.stories.tsx
import type { Meta, StoryObj } from "@storybook/react";
import { within, userEvent, expect } from "@storybook/test";
import { LoginForm } from "./LoginForm";

const meta: Meta<typeof LoginForm> = {
  title: "Auth/LoginForm",
  component: LoginForm,
};
export default meta;

type Story = StoryObj<typeof LoginForm>;

export const SuccessfulLogin: Story = {
  args: {
    onSubmit: async (email: string, password: string) => {
      return { success: true };
    },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement);

    await userEvent.type(canvas.getByLabelText("Email"), "user@example.com");
    await userEvent.type(canvas.getByLabelText("Password"), "s3cure-pass!");
    await userEvent.click(canvas.getByRole("button", { name: /log in/i }));

    await expect(canvas.getByText("Welcome back!")).toBeInTheDocument();
  },
};
```

**Equivalent Cypress Component Test:**

```tsx
// src/components/LoginForm.cy.tsx
import { LoginForm } from "./LoginForm";

describe("LoginForm", () => {
  it("submits valid credentials", () => {
    const onSubmit = cy.stub().resolves({ success: true }).as("onSubmit");

    cy.mount(<LoginForm onSubmit={onSubmit} />);

    cy.findByLabelText("Email").type("user@example.com");
    cy.findByLabelText("Password").type("s3cure-pass!");
    cy.findByRole("button", { name: /log in/i }).click();

    cy.get("@onSubmit").should("have.been.calledWith", "user@example.com", "s3cure-pass!");
    cy.findByText("Welcome back!").should("be.visible");
  });

  it("shows validation errors for empty fields", () => {
    cy.mount(<LoginForm onSubmit={cy.stub()} />);

    cy.findByRole("button", { name: /log in/i }).click();

    cy.findByText("Email is required").should("be.visible");
    cy.findByText("Password is required").should("be.visible");
  });

  it("disables submit button during loading", () => {
    const onSubmit = cy.stub().returns(new Promise(() => {})); // never resolves

    cy.mount(<LoginForm onSubmit={onSubmit} />);

    cy.findByLabelText("Email").type("user@example.com");
    cy.findByLabelText("Password").type("password");
    cy.findByRole("button", { name: /log in/i }).click();

    cy.findByRole("button", { name: /log in/i }).should("be.disabled");
    cy.findByTestId("spinner").should("be.visible");
  });
});
```

### When to Use Each

**Use Cypress Component Testing when you need:**

- Real browser interactions (drag-and-drop, scroll, focus management)
- Network request mocking with `cy.intercept()`
- Cross-browser testing (Chrome, Firefox, Edge)
- Code coverage reporting
- Complex DOM assertions (computed styles, layout, visibility)
- Testing components that rely on browser APIs (IntersectionObserver, ResizeObserver)
- Debugging with time-travel snapshots

**Use Storybook Interaction Tests when you need:**

- Living documentation alongside tests
- Design review and visual regression (with Chromatic)
- Quick iteration with hot-reload in the Storybook UI
- Sharing interactive examples with non-developer stakeholders
- Testing component variants exhaustively (all prop combinations)
- Accessibility addon integration (a11y checks per story)

**Use both together when:**

- You maintain a design system (Storybook for docs, Cypress CT for regression)
- Your CI pipeline benefits from parallelized test suites
- Different team members own visual QA vs. behavioral QA

### Using Storybook Stories as Cypress Test Fixtures

Export the story args and reuse them in Cypress tests to avoid duplication:

```tsx
// src/components/DataGrid.stories.tsx
import type { Meta, StoryObj } from "@storybook/react";
import { DataGrid, DataGridProps } from "./DataGrid";

export const sampleColumns = [
  { key: "name", label: "Name", sortable: true },
  { key: "email", label: "Email", sortable: true },
  { key: "role", label: "Role", sortable: false },
];

export const sampleRows = [
  { name: "Ada Lovelace", email: "ada@example.com", role: "Admin" },
  { name: "Alan Turing", email: "alan@example.com", role: "Editor" },
  { name: "Grace Hopper", email: "grace@example.com", role: "Viewer" },
];

const meta: Meta<typeof DataGrid> = {
  title: "Data/DataGrid",
  component: DataGrid,
};
export default meta;

export const Default: StoryObj<typeof DataGrid> = {
  args: {
    columns: sampleColumns,
    rows: sampleRows,
    selectable: true,
  },
};

export const Empty: StoryObj<typeof DataGrid> = {
  args: { columns: sampleColumns, rows: [], selectable: false },
};
```

```tsx
// src/components/DataGrid.cy.tsx
import { DataGrid } from "./DataGrid";
import { sampleColumns, sampleRows } from "./DataGrid.stories";

describe("DataGrid", () => {
  it("renders all rows from story fixture", () => {
    cy.mount(
      <DataGrid columns={sampleColumns} rows={sampleRows} selectable />
    );

    cy.get("[data-cy=grid-row]").should("have.length", 3);
  });

  it("sorts by column header click", () => {
    cy.mount(
      <DataGrid columns={sampleColumns} rows={sampleRows} selectable />
    );

    cy.get("[data-cy=header-name]").click();
    cy.get("[data-cy=grid-row]").first().should("contain", "Ada Lovelace");

    cy.get("[data-cy=header-name]").click();
    cy.get("[data-cy=grid-row]").first().should("contain", "Grace Hopper");
  });

  it("allows row selection", () => {
    cy.mount(
      <DataGrid columns={sampleColumns} rows={sampleRows} selectable />
    );

    cy.get("[data-cy=row-checkbox]").eq(0).click();
    cy.get("[data-cy=row-checkbox]").eq(2).click();

    cy.get("[data-cy=selection-count]").should("have.text", "2 selected");
  });

  it("renders empty state from story fixture", () => {
    cy.mount(
      <DataGrid columns={sampleColumns} rows={[]} selectable={false} />
    );

    cy.get("[data-cy=empty-state]").should("be.visible");
    cy.get("[data-cy=grid-row]").should("not.exist");
  });
});
```

### Pros/Cons Comparison Table

| Dimension                  | Cypress Component Testing                           | Storybook Interaction Tests                       |
| -------------------------- | --------------------------------------------------- | ------------------------------------------------- |
| **Execution environment**  | Real browser (Chrome, Firefox, Edge, Electron)      | Browser via Storybook dev server or test-runner    |
| **Network mocking**        | `cy.intercept()` — powerful, declarative            | MSW (mock service worker) — separate setup        |
| **Debugging**              | Time-travel DOM snapshots, devtools integration     | Storybook panel, browser devtools                 |
| **Cross-browser testing**  | ✅ Native support                                   | ❌ Single browser via test-runner                  |
| **Visual regression**      | Via plugins (percy, happo)                          | ✅ Chromatic / built-in visual tests               |
| **Documentation**          | Test files only                                     | ✅ Interactive docs, controls panel                |
| **CI speed**               | Moderate — real browser overhead                    | Fast — can run headless with test-runner           |
| **Code coverage**          | ✅ `@cypress/code-coverage`                         | ✅ Via Istanbul / v8 instrumentation               |
| **Learning curve**         | Familiar Cypress API                                | Storybook + Testing Library + play functions       |
| **Design system docs**     | ❌ Not designed for this                             | ✅ Purpose-built                                   |
| **Assertion library**      | Chai + Cypress custom assertions                    | Jest / Vitest `expect`                            |
| **Watch mode / HMR**       | ✅ `cypress open --component`                       | ✅ Storybook dev server                            |
| **Parallel execution**     | ✅ Cypress Cloud parallelization                    | ✅ Sharded test-runner                             |
| **Shared test data**       | Import from any module                              | Story args, decorators, loaders                   |
| **Accessibility testing**  | `cypress-axe` plugin                                | `@storybook/addon-a11y`                           |
| **Framework support**      | React, Vue, Angular, Svelte                         | React, Vue, Angular, Svelte, Web Components, etc. |
| **Viewport / responsive**  | `cy.viewport()` — precise control                   | Viewport addon — toolbar control                  |
| **Maturity**               | GA since Cypress 11                                 | GA since Storybook 7                              |

---

## Quick Reference — Cheat Sheet

```ts
// Mount with all providers (React)
cy.mount(<App />, { reduxState: {...}, route: "/dashboard" });

// Stub a callback
const onClick = cy.stub().as("click");
cy.mount(<Button onClick={onClick} />);
cy.get("button").click();
cy.get("@click").should("have.been.calledOnce");

// Mock an API
cy.intercept("POST", "/api/items", { statusCode: 201, body: { id: "new" } }).as("create");
cy.mount(<CreateForm />);
cy.get("[data-cy=submit]").click();
cy.wait("@create").its("request.body").should("deep.include", { name: "Test" });

// Test responsive layout
cy.viewport("iphone-x");
cy.mount(<Header />);
cy.get("[data-cy=hamburger]").should("be.visible");

// Assert computed CSS
cy.get("[data-cy=badge]").should("have.css", "background-color", "rgb(59, 130, 246)");

// Use Storybook fixtures
import { Default } from "./Card.stories";
cy.mount(<Card {...Default.args} />);
```

---

*Last updated: 2025. Covers Cypress 13+, Storybook 8, React 18, Vue 3, Angular 17+, Svelte 4+.*
