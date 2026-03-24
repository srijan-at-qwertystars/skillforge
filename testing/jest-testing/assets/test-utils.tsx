/**
 * React testing utilities — custom render with providers.
 * Import { render, screen, userEvent } from this file instead of @testing-library/react.
 */
import React, { type ReactElement, type ReactNode } from 'react';
import { render, type RenderOptions, screen, within, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

// -- Import your app's providers --
// import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
// import { ThemeProvider } from '@/providers/theme';
// import { AuthProvider } from '@/providers/auth';
// import { BrowserRouter } from 'react-router-dom';

// ---- Provider Setup ----

interface WrapperProps {
  children: ReactNode;
}

/**
 * Creates a fresh QueryClient for each test to prevent shared state.
 */
function createTestQueryClient() {
  // return new QueryClient({
  //   defaultOptions: {
  //     queries: { retry: false, gcTime: 0 },
  //     mutations: { retry: false },
  //   },
  //   logger: { log: () => {}, warn: () => {}, error: () => {} },
  // });
  return null; // Replace with real QueryClient
}

/**
 * Wraps components with all providers needed for testing.
 * Customize based on your app's provider tree.
 */
function AllProviders({ children }: WrapperProps) {
  // const queryClient = createTestQueryClient();
  return (
    // <BrowserRouter>
    //   <QueryClientProvider client={queryClient}>
    //     <ThemeProvider defaultTheme="light">
    //       <AuthProvider>
    //         {children}
    //       </AuthProvider>
    //     </ThemeProvider>
    //   </QueryClientProvider>
    // </BrowserRouter>
    <>{children}</>
  );
}

// ---- Custom Render ----

interface CustomRenderOptions extends Omit<RenderOptions, 'wrapper'> {
  /** Initial route for MemoryRouter (if using React Router) */
  route?: string;
  /** Override the wrapper component */
  wrapper?: React.ComponentType<WrapperProps>;
}

/**
 * Custom render that wraps component in all providers.
 * Also sets up userEvent instance for interaction testing.
 *
 * @example
 * const { user } = renderWithProviders(<LoginForm />);
 * await user.type(screen.getByLabelText(/email/i), 'test@example.com');
 * await user.click(screen.getByRole('button', { name: /submit/i }));
 */
function renderWithProviders(
  ui: ReactElement,
  options: CustomRenderOptions = {},
) {
  const { wrapper: Wrapper = AllProviders, ...renderOptions } = options;
  const user = userEvent.setup();

  return {
    user,
    ...render(ui, { wrapper: Wrapper, ...renderOptions }),
  };
}

// ---- Async Helpers ----

/**
 * Wait for loading state to finish.
 * Assumes loading indicators use role="progressbar" or aria-busy.
 */
async function waitForLoadingToFinish() {
  await waitFor(() => {
    const loaders = screen.queryAllByRole('progressbar');
    const busyElements = screen.queryAllByAttribute?.('aria-busy', document.body, 'true') ?? [];
    expect([...loaders, ...busyElements]).toHaveLength(0);
  });
}

/**
 * Assert no accessibility violations (requires jest-axe).
 * Install: npm i -D jest-axe @types/jest-axe
 */
// import { axe, toHaveNoViolations } from 'jest-axe';
// expect.extend(toHaveNoViolations);
// async function expectNoA11yViolations(container: HTMLElement) {
//   const results = await axe(container);
//   expect(results).toHaveNoViolations();
// }

// ---- Debug Helpers ----

/**
 * Pretty-print the current DOM state (useful for debugging failing tests).
 */
function debugDOM(element?: HTMLElement) {
  if (element) {
    screen.debug(element, Infinity);
  } else {
    screen.debug(document.body, Infinity);
  }
}

/**
 * Get all text content from element, useful for assertion debugging.
 */
function getTextContent(element: HTMLElement): string {
  return element.textContent?.trim() ?? '';
}

// ---- Exports ----

// Re-export everything from testing-library
export * from '@testing-library/react';

// Override render with custom version
export {
  renderWithProviders as render,
  renderWithProviders,
  userEvent,
  within,
  waitForLoadingToFinish,
  debugDOM,
  getTextContent,
  createTestQueryClient,
  AllProviders,
};
