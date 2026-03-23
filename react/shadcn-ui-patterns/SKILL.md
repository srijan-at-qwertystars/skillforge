---
name: shadcn-ui-patterns
description:
  positive: "Use when user works with shadcn/ui, asks about installing components with npx shadcn-ui, customizing shadcn components, Radix UI primitives, or building forms with shadcn + react-hook-form + zod."
  negative: "Do NOT use for Material UI, Chakra UI, Ant Design, or headless UI libraries without shadcn context."
---

# shadcn/ui Component Patterns

## Fundamentals

shadcn/ui is NOT a package. It is a collection of reusable components you copy into your project. You own the code — modify freely.

Core principles:
- Copy-paste model: components live in your repo, not `node_modules`
- Built on Radix UI primitives (accessibility, keyboard nav, focus management)
- Styled with Tailwind CSS utility classes
- Variants managed via `class-variance-authority` (CVA)
- `cn()` utility merges Tailwind classes safely (uses `clsx` + `tailwind-merge`)

`components.json` configures paths, style preferences, and aliases:
```json
{
  "$schema": "https://ui.shadcn.com/schema.json",
  "style": "default",
  "tailwind": { "config": "tailwind.config.ts", "css": "app/globals.css", "baseColor": "slate" },
  "aliases": { "components": "@/components", "utils": "@/lib/utils" }
}
```

## Installation

```bash
# Initialize in a new project
npx shadcn@latest init

# Add specific components
npx shadcn@latest add button card dialog form table

# Add all components
npx shadcn@latest add --all

# Use a custom registry
npx shadcn@latest add https://my-registry.com/r/my-component.json

# Monorepo: specify path to target package
npx shadcn@latest add button --cwd packages/ui
```

After init, components are placed in `components/ui/`. Import via `@/components/ui/button`.

## Theming

Define theme colors as CSS variables in `globals.css`. Toggle dark mode with a `.dark` class on `<html>`.

```css
@layer base {
  :root {
    --background: 0 0% 100%;
    --foreground: 222.2 84% 4.9%;
    --primary: 222.2 47.4% 11.2%;
    --primary-foreground: 210 40% 98%;
    --destructive: 0 84.2% 60.2%;
    --ring: 222.2 84% 4.9%;
    --radius: 0.5rem;
  }
  .dark {
    --background: 222.2 84% 4.9%;
    --foreground: 210 40% 98%;
    --primary: 210 40% 98%;
    --primary-foreground: 222.2 47.4% 11.2%;
  }
}
```

Extend the palette by adding custom variables:
```css
:root {
  --brand: 262 83% 58%;
  --brand-foreground: 0 0% 100%;
}
```

Reference in Tailwind config:
```ts
// tailwind.config.ts
extend: {
  colors: {
    brand: "hsl(var(--brand))",
    "brand-foreground": "hsl(var(--brand-foreground))",
  },
}
```

Use `next-themes` for dark mode toggling in Next.js. Wrap app in `<ThemeProvider attribute="class" defaultTheme="system">`.

## Component Anatomy

Every shadcn/ui component follows this structure:

1. **Radix primitive** — handles logic, a11y, keyboard, focus
2. **CVA variants** — define visual variants (size, color, state)
3. **Tailwind classes** — style the rendered output
4. **`cn()` merge** — combine base + variant + custom classes
5. **`React.forwardRef`** — forward refs for composition

```tsx
import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "@/lib/utils"

const buttonVariants = cva(
  "inline-flex items-center justify-center rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-foreground hover:bg-primary/90",
        destructive: "bg-destructive text-destructive-foreground hover:bg-destructive/90",
        outline: "border border-input bg-background hover:bg-accent hover:text-accent-foreground",
        secondary: "bg-secondary text-secondary-foreground hover:bg-secondary/80",
        ghost: "hover:bg-accent hover:text-accent-foreground",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default: "h-10 px-4 py-2",
        sm: "h-9 rounded-md px-3",
        lg: "h-11 rounded-md px-8",
        icon: "h-10 w-10",
      },
    },
    defaultVariants: { variant: "default", size: "default" },
  }
)

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "button"
    return <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />
  }
)
Button.displayName = "Button"

export { Button, buttonVariants }
```

Use `asChild` to render a child element (e.g., `<Link>`) while inheriting shadcn behavior:
```tsx
<Button asChild>
  <Link href="/dashboard">Go to Dashboard</Link>
</Button>
```

## Core Components

### Card
```tsx
<Card>
  <CardHeader>
    <CardTitle>Title</CardTitle>
    <CardDescription>Subtitle</CardDescription>
  </CardHeader>
  <CardContent><p>Body content</p></CardContent>
  <CardFooter><Button>Action</Button></CardFooter>
</Card>
```

### Dialog
```tsx
<Dialog>
  <DialogTrigger asChild><Button>Open</Button></DialogTrigger>
  <DialogContent>
    <DialogHeader>
      <DialogTitle>Edit Profile</DialogTitle>
      <DialogDescription>Make changes and save.</DialogDescription>
    </DialogHeader>
    <div className="grid gap-4 py-4">{/* form fields */}</div>
    <DialogFooter><Button type="submit">Save</Button></DialogFooter>
  </DialogContent>
</Dialog>
```

### Dropdown Menu
```tsx
<DropdownMenu>
  <DropdownMenuTrigger asChild><Button variant="outline">Menu</Button></DropdownMenuTrigger>
  <DropdownMenuContent align="end">
    <DropdownMenuLabel>Account</DropdownMenuLabel>
    <DropdownMenuSeparator />
    <DropdownMenuItem>Profile</DropdownMenuItem>
    <DropdownMenuItem>Settings</DropdownMenuItem>
    <DropdownMenuSeparator />
    <DropdownMenuItem className="text-destructive">Log out</DropdownMenuItem>
  </DropdownMenuContent>
</DropdownMenu>
```

### Tabs
```tsx
<Tabs defaultValue="overview" className="w-full">
  <TabsList>
    <TabsTrigger value="overview">Overview</TabsTrigger>
    <TabsTrigger value="analytics">Analytics</TabsTrigger>
  </TabsList>
  <TabsContent value="overview">Overview content</TabsContent>
  <TabsContent value="analytics">Analytics content</TabsContent>
</Tabs>
```

## Form Patterns (react-hook-form + zod)

Install: `npx shadcn@latest add form input select textarea`

### Define schema with Zod
```tsx
import { z } from "zod"

const profileSchema = z.object({
  username: z.string().min(2, "Username must be at least 2 characters"),
  email: z.string().email("Invalid email address"),
  bio: z.string().max(160).optional(),
  role: z.enum(["admin", "user", "editor"]),
})

type ProfileFormValues = z.infer<typeof profileSchema>
```

### Build the form
```tsx
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Form, FormControl, FormDescription, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form"

export function ProfileForm() {
  const form = useForm<ProfileFormValues>({
    resolver: zodResolver(profileSchema),
    defaultValues: { username: "", email: "", bio: "", role: "user" },
  })

  function onSubmit(data: ProfileFormValues) {
    // Handle submission
  }

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-6">
        <FormField control={form.control} name="username" render={({ field }) => (
          <FormItem>
            <FormLabel>Username</FormLabel>
            <FormControl><Input placeholder="shadcn" {...field} /></FormControl>
            <FormDescription>Your public display name.</FormDescription>
            <FormMessage />
          </FormItem>
        )} />
        <FormField control={form.control} name="role" render={({ field }) => (
          <FormItem>
            <FormLabel>Role</FormLabel>
            <Select onValueChange={field.onChange} defaultValue={field.value}>
              <FormControl><SelectTrigger><SelectValue placeholder="Select role" /></SelectTrigger></FormControl>
              <SelectContent>
                <SelectItem value="admin">Admin</SelectItem>
                <SelectItem value="user">User</SelectItem>
                <SelectItem value="editor">Editor</SelectItem>
              </SelectContent>
            </Select>
            <FormMessage />
          </FormItem>
        )} />
        <Button type="submit">Save</Button>
      </form>
    </Form>
  )
}
```

### Cross-field validation
```tsx
const passwordSchema = z.object({
  password: z.string().min(8),
  confirmPassword: z.string(),
}).refine((data) => data.password === data.confirmPassword, {
  message: "Passwords don't match",
  path: ["confirmPassword"],
})
```

### Dynamic fields with useFieldArray
```tsx
const { fields, append, remove } = useFieldArray({ control: form.control, name: "urls" })
{fields.map((field, index) => (
  <FormField key={field.id} control={form.control} name={`urls.${index}.value`}
    render={({ field }) => (
      <FormItem>
        <FormControl><Input {...field} /></FormControl>
        <FormMessage />
      </FormItem>
    )}
  />
))}
<Button type="button" variant="outline" onClick={() => append({ value: "" })}>Add URL</Button>
```

## Data Table (TanStack Table + shadcn)

Install: `npm i @tanstack/react-table` and `npx shadcn@latest add table`

### Column definitions
```tsx
import { ColumnDef } from "@tanstack/react-table"

export const columns: ColumnDef<Payment>[] = [
  { accessorKey: "status", header: "Status" },
  { accessorKey: "email", header: ({ column }) => (
    <Button variant="ghost" onClick={() => column.toggleSorting(column.getIsSorted() === "asc")}>
      Email <ArrowUpDown className="ml-2 h-4 w-4" />
    </Button>
  )},
  { accessorKey: "amount", header: "Amount",
    cell: ({ row }) => {
      const amount = parseFloat(row.getValue("amount"))
      return <div className="text-right font-medium">{new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(amount)}</div>
    },
  },
  { id: "select", header: ({ table }) => (
    <Checkbox checked={table.getIsAllPageRowsSelected()} onCheckedChange={(v) => table.toggleAllPageRowsSelected(!!v)} />
  ), cell: ({ row }) => (
    <Checkbox checked={row.getIsSelected()} onCheckedChange={(v) => row.toggleSelected(!!v)} />
  )},
]
```

### Table component with sorting, filtering, pagination
```tsx
import { useReactTable, getCoreRowModel, getPaginationRowModel, getSortedRowModel, getFilteredRowModel, flexRender } from "@tanstack/react-table"

export function DataTable<TData, TValue>({ columns, data }: { columns: ColumnDef<TData, TValue>[]; data: TData[] }) {
  const [sorting, setSorting] = React.useState<SortingState>([])
  const [columnFilters, setColumnFilters] = React.useState<ColumnFiltersState>([])

  const table = useReactTable({
    data, columns, getCoreRowModel: getCoreRowModel(),
    getPaginationRowModel: getPaginationRowModel(),
    onSortingChange: setSorting, getSortedRowModel: getSortedRowModel(),
    onColumnFiltersChange: setColumnFilters, getFilteredRowModel: getFilteredRowModel(),
    state: { sorting, columnFilters },
  })

  return (
    <div>
      <Input placeholder="Filter emails..." value={(table.getColumn("email")?.getFilterValue() as string) ?? ""}
        onChange={(e) => table.getColumn("email")?.setFilterValue(e.target.value)} className="max-w-sm mb-4" />
      <Table>
        <TableHeader>
          {table.getHeaderGroups().map((hg) => (
            <TableRow key={hg.id}>
              {hg.headers.map((h) => <TableHead key={h.id}>{h.isPlaceholder ? null : flexRender(h.column.columnDef.header, h.getContext())}</TableHead>)}
            </TableRow>
          ))}
        </TableHeader>
        <TableBody>
          {table.getRowModel().rows.length ? table.getRowModel().rows.map((row) => (
            <TableRow key={row.id}>
              {row.getVisibleCells().map((cell) => <TableCell key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</TableCell>)}
            </TableRow>
          )) : <TableRow><TableCell colSpan={columns.length} className="text-center">No results.</TableCell></TableRow>}
        </TableBody>
      </Table>
      <div className="flex items-center justify-end gap-2 py-4">
        <Button variant="outline" size="sm" onClick={() => table.previousPage()} disabled={!table.getCanPreviousPage()}>Previous</Button>
        <Button variant="outline" size="sm" onClick={() => table.nextPage()} disabled={!table.getCanNextPage()}>Next</Button>
      </div>
    </div>
  )
}
```

## Combobox and Command

Use `Command` (built on `cmdk`) for searchable lists:
```tsx
<Popover open={open} onOpenChange={setOpen}>
  <PopoverTrigger asChild>
    <Button variant="outline" role="combobox" aria-expanded={open} className="w-[200px] justify-between">
      {value ? items.find((i) => i.value === value)?.label : "Select item..."}
      <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
    </Button>
  </PopoverTrigger>
  <PopoverContent className="w-[200px] p-0">
    <Command>
      <CommandInput placeholder="Search..." />
      <CommandEmpty>No results found.</CommandEmpty>
      <CommandGroup>
        {items.map((item) => (
          <CommandItem key={item.value} value={item.value}
            onSelect={(v) => { setValue(v === value ? "" : v); setOpen(false) }}>
            <Check className={cn("mr-2 h-4 w-4", value === item.value ? "opacity-100" : "opacity-0")} />
            {item.label}
          </CommandItem>
        ))}
      </CommandGroup>
    </Command>
  </PopoverContent>
</Popover>
```

Group items with multiple `<CommandGroup heading="Group Name">` blocks. For async loading, fetch on `CommandInput` change and show a spinner in `<CommandEmpty>`.

## Toast and Sonner

Use Sonner (recommended) for notifications:
```tsx
// layout.tsx — add <Toaster /> from sonner
import { Toaster } from "@/components/ui/sonner"
export default function Layout({ children }) {
  return <>{children}<Toaster /></>
}

// usage
import { toast } from "sonner"
toast("Event created")
toast.success("Profile updated")
toast.error("Something went wrong")
toast.promise(saveData(), { loading: "Saving...", success: "Saved!", error: "Failed to save" })
toast("Event created", { action: { label: "Undo", onClick: () => undoAction() } })
```

## Sheet and Dialog Patterns

### Controlled dialog
```tsx
const [open, setOpen] = useState(false)
<Dialog open={open} onOpenChange={setOpen}>
  <DialogContent>
    <form onSubmit={(e) => { e.preventDefault(); handleSave(); setOpen(false) }}>
      {/* fields */}
      <DialogFooter><Button type="submit">Save</Button></DialogFooter>
    </form>
  </DialogContent>
</Dialog>
```

### Responsive drawer/dialog
Use `vaul` for mobile drawer, `Dialog` for desktop:
```tsx
import { useMediaQuery } from "@/hooks/use-media-query"
const isDesktop = useMediaQuery("(min-width: 768px)")

if (isDesktop) {
  return <Dialog open={open} onOpenChange={setOpen}><DialogContent>{children}</DialogContent></Dialog>
}
return <Drawer open={open} onOpenChange={setOpen}><DrawerContent>{children}</DrawerContent></Drawer>
```

### Sheet for side panels
```tsx
<Sheet>
  <SheetTrigger asChild><Button variant="outline">Open Panel</Button></SheetTrigger>
  <SheetContent side="right" className="w-[400px] sm:w-[540px]">
    <SheetHeader><SheetTitle>Edit Item</SheetTitle></SheetHeader>
    <div className="py-4">{/* form or content */}</div>
    <SheetFooter><Button>Save</Button></SheetFooter>
  </SheetContent>
</Sheet>
```

## Customization

### Add custom variants to existing components
```tsx
const badgeVariants = cva("inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold", {
  variants: {
    variant: {
      default: "border-transparent bg-primary text-primary-foreground",
      secondary: "border-transparent bg-secondary text-secondary-foreground",
      success: "border-transparent bg-green-500 text-white",      // custom
      warning: "border-transparent bg-yellow-500 text-black",      // custom
    },
  },
})
```

### Extend components with wrapper pattern
```tsx
interface LoadingButtonProps extends ButtonProps { loading?: boolean }

const LoadingButton = React.forwardRef<HTMLButtonElement, LoadingButtonProps>(
  ({ loading, children, disabled, ...props }, ref) => (
    <Button ref={ref} disabled={disabled || loading} {...props}>
      {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
      {children}
    </Button>
  )
)
```
