// story-template.tsx — CSF3 Story Template
//
// Copy this template when creating new story files.
// Replace COMPONENT_NAME, update args/argTypes, and fill in play function.
//
// Usage: cp story-template.tsx src/components/MyComponent.stories.tsx

import type { Meta, StoryObj } from '@storybook/react';
import { expect, fn, userEvent, within, waitFor } from '@storybook/test';
import { COMPONENT_NAME } from './COMPONENT_NAME';

// --- Meta: component configuration ---
const meta = {
  title: 'Category/COMPONENT_NAME',
  component: COMPONENT_NAME,
  tags: ['autodocs'],

  // Default args applied to all stories
  args: {
    // label: 'Default Label',
    // disabled: false,
  },

  // Control types and descriptions for the Controls panel
  argTypes: {
    // variant: {
    //   control: 'select',
    //   options: ['primary', 'secondary', 'danger'],
    //   description: 'Visual style variant',
    //   table: {
    //     type: { summary: 'string' },
    //     defaultValue: { summary: 'primary' },
    //   },
    // },
    // size: { control: 'radio', options: ['sm', 'md', 'lg'] },
    // count: { control: { type: 'range', min: 0, max: 100, step: 5 } },
    // color: { control: 'color' },
    // config: { control: 'object' },
    // onClick: { action: 'clicked' },
    // hiddenProp: { table: { disable: true } },
    //
    // Conditional controls:
    // showLabel: { control: 'boolean' },
    // label: { control: 'text', if: { arg: 'showLabel' } },
  },

  // Decorators wrap each story
  decorators: [
    (Story) => (
      <div style={{ padding: '2rem' }}>
        <Story />
      </div>
    ),
  ],

  // Parameters configure addons and behavior
  parameters: {
    layout: 'centered', // 'centered' | 'fullscreen' | 'padded'
    docs: {
      description: {
        component: 'Description of the component — shown in autodocs.',
      },
    },
    // Chromatic visual testing
    // chromatic: { viewports: [320, 768, 1200] },
    // Accessibility
    // a11y: { config: { rules: [{ id: 'color-contrast', enabled: true }] } },
  },
} satisfies Meta<typeof COMPONENT_NAME>;

export default meta;
type Story = StoryObj<typeof meta>;

// --- Stories ---

/** Default rendering with base args. */
export const Default: Story = {};

/** Primary variant. */
export const Primary: Story = {
  args: {
    // variant: 'primary',
    // label: 'Primary Action',
  },
};

/** Secondary variant. */
export const Secondary: Story = {
  args: {
    // variant: 'secondary',
    // label: 'Secondary Action',
  },
};

/** Custom render for complex composition. */
export const Composed: Story = {
  render: (args) => (
    <div style={{ display: 'flex', gap: '1rem' }}>
      <COMPONENT_NAME {...args} />
      {/* Add additional components for composition */}
    </div>
  ),
};

/** Interactive story with play function. */
export const WithInteraction: Story = {
  args: {
    // onClick: fn(),
  },
  play: async ({ canvasElement, args, step }) => {
    const canvas = within(canvasElement);

    await step('Verify initial render', async () => {
      // const element = canvas.getByRole('button', { name: /label/i });
      // expect(element).toBeVisible();
    });

    await step('Perform user action', async () => {
      // await userEvent.click(canvas.getByRole('button'));
      // await waitFor(() => {
      //   expect(args.onClick).toHaveBeenCalledOnce();
      // });
    });

    await step('Verify result', async () => {
      // await expect(canvas.getByText('Success')).toBeVisible();
    });
  },
};

/** Responsive — use with viewport addon. */
export const Mobile: Story = {
  parameters: {
    viewport: { defaultViewport: 'iphone14' },
    chromatic: { viewports: [375] },
  },
};
