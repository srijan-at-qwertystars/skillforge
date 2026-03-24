// addon-template.tsx — Custom Storybook Addon Template
//
// This template provides a complete custom addon with:
//   - Panel addon (shows in the addons panel)
//   - Toolbar button (shows in the top toolbar)
//   - Parameter integration (reads per-story parameters)
//   - Communication channel between manager and preview
//
// Setup:
//   1. Copy this file to .storybook/addons/my-addon/manager.tsx
//   2. Create the preview part at .storybook/addons/my-addon/preview.ts
//   3. Register in main.ts: addons: ['./addons/my-addon/manager']
//
// Files needed:
//   - manager.tsx (this file) — UI that appears in the Storybook manager
//   - preview.ts  — decorator that runs in the story iframe
//   - preset.ts   — optional, for automatic registration

import React, { useCallback, useEffect, useState } from 'react';
import { addons, types, useAddonState, useChannel, useParameter } from 'storybook/manager-api';
import { AddonPanel } from 'storybook/internal/components';
import { IconButton } from 'storybook/internal/components';
import { LightningIcon } from '@storybook/icons';

// ============================================================
// Constants
// ============================================================

const ADDON_ID = 'my-org/my-addon';
const PANEL_ID = `${ADDON_ID}/panel`;
const TOOL_ID = `${ADDON_ID}/tool`;
const PARAM_KEY = 'myAddon';

// Channel events — for communication between manager and preview
const EVENTS = {
  REQUEST: `${ADDON_ID}/request`,
  RESULT: `${ADDON_ID}/result`,
  CLEAR: `${ADDON_ID}/clear`,
};

// ============================================================
// Types
// ============================================================

interface AddonState {
  enabled: boolean;
  data: Record<string, unknown>;
  lastUpdated: string | null;
}

interface AddonParameters {
  enabled?: boolean;
  options?: Record<string, unknown>;
}

const DEFAULT_STATE: AddonState = {
  enabled: false,
  data: {},
  lastUpdated: null,
};

// ============================================================
// Panel Component
// ============================================================

interface PanelProps {
  active: boolean;
}

const Panel: React.FC<PanelProps> = ({ active }) => {
  const [state, setState] = useAddonState<AddonState>(ADDON_ID, DEFAULT_STATE);
  const param = useParameter<AddonParameters>(PARAM_KEY, {});

  // Listen for events from the preview (story iframe)
  const emit = useChannel({
    [EVENTS.RESULT]: (data: Record<string, unknown>) => {
      setState({
        ...state,
        data,
        lastUpdated: new Date().toISOString(),
      });
    },
  });

  const handleRefresh = useCallback(() => {
    emit(EVENTS.REQUEST, { timestamp: Date.now() });
  }, [emit]);

  const handleClear = useCallback(() => {
    setState(DEFAULT_STATE);
    emit(EVENTS.CLEAR);
  }, [setState, emit]);

  if (!active) return null;

  return (
    <AddonPanel active={active}>
      <div style={{ padding: '16px', fontFamily: 'sans-serif' }}>
        <div style={{ display: 'flex', gap: '8px', marginBottom: '16px' }}>
          <button
            onClick={handleRefresh}
            style={{
              padding: '6px 12px',
              border: '1px solid #ccc',
              borderRadius: '4px',
              cursor: 'pointer',
              background: '#fff',
            }}
          >
            🔄 Refresh
          </button>
          <button
            onClick={handleClear}
            style={{
              padding: '6px 12px',
              border: '1px solid #ccc',
              borderRadius: '4px',
              cursor: 'pointer',
              background: '#fff',
            }}
          >
            🗑️ Clear
          </button>
        </div>

        {/* Per-story parameters */}
        {param.enabled !== undefined && (
          <div style={{ marginBottom: '12px', color: '#666', fontSize: '13px' }}>
            Story parameter: <code>{JSON.stringify(param)}</code>
          </div>
        )}

        {/* Collected data */}
        <div>
          <h4 style={{ margin: '0 0 8px' }}>Addon Data</h4>
          {state.lastUpdated ? (
            <>
              <pre
                style={{
                  background: '#f5f5f5',
                  padding: '12px',
                  borderRadius: '6px',
                  fontSize: '12px',
                  overflow: 'auto',
                  maxHeight: '400px',
                }}
              >
                {JSON.stringify(state.data, null, 2)}
              </pre>
              <div style={{ fontSize: '11px', color: '#999', marginTop: '8px' }}>
                Last updated: {state.lastUpdated}
              </div>
            </>
          ) : (
            <div style={{ color: '#999' }}>
              No data collected yet. Click Refresh or interact with the story.
            </div>
          )}
        </div>
      </div>
    </AddonPanel>
  );
};

// ============================================================
// Toolbar Button Component
// ============================================================

const ToolbarButton: React.FC = () => {
  const [state, setState] = useAddonState<AddonState>(ADDON_ID, DEFAULT_STATE);

  const toggleAddon = useCallback(() => {
    setState({ ...state, enabled: !state.enabled });
  }, [state, setState]);

  return (
    <IconButton
      active={state.enabled}
      title={state.enabled ? 'Disable My Addon' : 'Enable My Addon'}
      onClick={toggleAddon}
    >
      <LightningIcon />
    </IconButton>
  );
};

// ============================================================
// Registration
// ============================================================

addons.register(ADDON_ID, () => {
  // Register the panel
  addons.add(PANEL_ID, {
    type: types.PANEL,
    title: 'My Addon',
    match: ({ viewMode }) => viewMode === 'story',
    render: ({ active }) => <Panel active={active!} />,
  });

  // Register the toolbar button
  addons.add(TOOL_ID, {
    type: types.TOOL,
    title: 'My Addon Toggle',
    match: ({ viewMode }) => viewMode === 'story',
    render: () => <ToolbarButton />,
  });
});

// ============================================================
// Preview decorator (save to a separate preview.ts file)
// ============================================================

/*
// .storybook/addons/my-addon/preview.ts
import type { Decorator } from '@storybook/react';
import { useChannel } from '@storybook/preview-api';
import { EVENTS } from './constants';  // share event constants

export const withMyAddon: Decorator = (Story, context) => {
  const emit = useChannel({
    [EVENTS.REQUEST]: () => {
      // Collect data from the rendered story
      const root = document.getElementById('storybook-root');
      if (root) {
        emit(EVENTS.RESULT, {
          elementCount: root.querySelectorAll('*').length,
          textContent: root.textContent?.slice(0, 200),
          dimensions: {
            width: root.offsetWidth,
            height: root.offsetHeight,
          },
        });
      }
    },
    [EVENTS.CLEAR]: () => {
      // Reset any addon state in preview
    },
  });

  // Read per-story parameter
  const addonParam = context.parameters.myAddon || {};

  return <Story />;
};

// Register in preview.ts:
// decorators: [withMyAddon]
*/

// ============================================================
// Story usage example
// ============================================================

/*
// In any story file:
export const WithAddon: Story = {
  parameters: {
    myAddon: {
      enabled: true,
      options: { trackClicks: true, highlight: 'borders' },
    },
  },
};
*/
