# Tailwind CSS Production Component Library

## Table of Contents
- [Buttons](#buttons)
- [Forms](#forms)
- [Cards](#cards)
- [Modals / Dialogs](#modals--dialogs)
- [Dropdowns](#dropdowns)
- [Navigation](#navigation)
- [Alerts / Toasts](#alerts--toasts)
- [Tables](#tables)
- [Pagination](#pagination)
- [Badges / Chips](#badges--chips)
- [Avatar Groups](#avatar-groups)

---

## Buttons

### Primary
```html
<button class="inline-flex items-center justify-center gap-2 rounded-lg bg-blue-600 px-4 py-2.5
               text-sm font-semibold text-white shadow-sm
               hover:bg-blue-700 focus-visible:outline-2 focus-visible:outline-offset-2
               focus-visible:outline-blue-600 active:bg-blue-800
               disabled:opacity-50 disabled:cursor-not-allowed transition-colors
               dark:bg-blue-500 dark:hover:bg-blue-400 dark:focus-visible:outline-blue-400">
  <svg class="size-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>
  Save Changes
</button>
```

### Secondary
```html
<button class="inline-flex items-center justify-center gap-2 rounded-lg bg-white px-4 py-2.5
               text-sm font-semibold text-gray-700 shadow-sm ring-1 ring-inset ring-gray-300
               hover:bg-gray-50 focus-visible:outline-2 focus-visible:outline-offset-2
               focus-visible:outline-blue-600 active:bg-gray-100
               disabled:opacity-50 disabled:cursor-not-allowed transition-colors
               dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-600 dark:hover:bg-gray-700">
  Cancel
</button>
```

### Danger
```html
<button class="inline-flex items-center justify-center gap-2 rounded-lg bg-red-600 px-4 py-2.5
               text-sm font-semibold text-white shadow-sm
               hover:bg-red-700 focus-visible:outline-2 focus-visible:outline-offset-2
               focus-visible:outline-red-600 active:bg-red-800
               disabled:opacity-50 disabled:cursor-not-allowed transition-colors
               dark:bg-red-500 dark:hover:bg-red-400">
  Delete Account
</button>
```

### Ghost
```html
<button class="inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2.5
               text-sm font-semibold text-gray-700
               hover:bg-gray-100 focus-visible:outline-2 focus-visible:outline-offset-2
               focus-visible:outline-blue-600 active:bg-gray-200
               disabled:opacity-50 disabled:cursor-not-allowed transition-colors
               dark:text-gray-300 dark:hover:bg-gray-800 dark:active:bg-gray-700">
  Learn More
</button>
```

### Loading State
```html
<button class="inline-flex items-center justify-center gap-2 rounded-lg bg-blue-600 px-4 py-2.5
               text-sm font-semibold text-white shadow-sm cursor-wait opacity-80"
        disabled>
  <svg class="size-4 animate-spin" viewBox="0 0 24 24" fill="none">
    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
  </svg>
  Saving...
</button>
```

### Button Sizes
```html
<!-- Extra Small -->
<button class="rounded px-2 py-1 text-xs font-medium">XS</button>
<!-- Small -->
<button class="rounded-md px-3 py-1.5 text-sm font-medium">Small</button>
<!-- Default -->
<button class="rounded-lg px-4 py-2.5 text-sm font-semibold">Default</button>
<!-- Large -->
<button class="rounded-lg px-5 py-3 text-base font-semibold">Large</button>
<!-- Icon Only -->
<button class="rounded-lg p-2.5" aria-label="Settings">
  <svg class="size-5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
</button>
```

### Button Group
```html
<div class="inline-flex rounded-lg shadow-sm" role="group">
  <button class="rounded-l-lg border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700
                 hover:bg-gray-50 focus:z-10 focus:outline-2 focus:outline-blue-600
                 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200">
    Left
  </button>
  <button class="border-y border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700
                 hover:bg-gray-50 focus:z-10 focus:outline-2 focus:outline-blue-600
                 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200">
    Center
  </button>
  <button class="rounded-r-lg border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700
                 hover:bg-gray-50 focus:z-10 focus:outline-2 focus:outline-blue-600
                 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200">
    Right
  </button>
</div>
```

---

## Forms

### Text Input with Label
```html
<div>
  <label for="email" class="block text-sm font-medium text-gray-700 dark:text-gray-300">
    Email address
  </label>
  <input type="email" id="email" name="email" placeholder="you@example.com"
         class="mt-1.5 block w-full rounded-lg border border-gray-300 bg-white px-3 py-2
                text-sm shadow-sm placeholder:text-gray-400
                focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20 focus:outline-none
                disabled:bg-gray-50 disabled:text-gray-500 disabled:cursor-not-allowed
                dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:placeholder:text-gray-500
                dark:focus:border-blue-400 dark:focus:ring-blue-400/20" />
</div>
```

### Input with Validation States
```html
<!-- Success -->
<div>
  <label class="block text-sm font-medium text-gray-700 dark:text-gray-300">Username</label>
  <div class="relative mt-1.5">
    <input type="text" value="johndoe" class="block w-full rounded-lg border border-green-500 bg-white px-3 py-2
           text-sm shadow-sm focus:border-green-500 focus:ring-2 focus:ring-green-500/20 focus:outline-none
           dark:border-green-400 dark:bg-gray-800 dark:text-white" />
    <div class="pointer-events-none absolute inset-y-0 right-0 flex items-center pr-3">
      <svg class="size-5 text-green-500" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/></svg>
    </div>
  </div>
  <p class="mt-1.5 text-sm text-green-600 dark:text-green-400">Username is available!</p>
</div>

<!-- Error -->
<div>
  <label class="block text-sm font-medium text-gray-700 dark:text-gray-300">Email</label>
  <div class="relative mt-1.5">
    <input type="email" value="invalid" aria-invalid="true" aria-describedby="email-error"
           class="block w-full rounded-lg border border-red-500 bg-white px-3 py-2
           text-sm shadow-sm focus:border-red-500 focus:ring-2 focus:ring-red-500/20 focus:outline-none
           dark:border-red-400 dark:bg-gray-800 dark:text-white" />
    <div class="pointer-events-none absolute inset-y-0 right-0 flex items-center pr-3">
      <svg class="size-5 text-red-500" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7 4a1 1 0 11-2 0 1 1 0 012 0zm-1-9a1 1 0 00-1 1v4a1 1 0 102 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/></svg>
    </div>
  </div>
  <p id="email-error" class="mt-1.5 text-sm text-red-600 dark:text-red-400">Please enter a valid email address.</p>
</div>
```

### Input Group (with Addon)
```html
<div>
  <label class="block text-sm font-medium text-gray-700 dark:text-gray-300">Website</label>
  <div class="mt-1.5 flex rounded-lg shadow-sm">
    <span class="inline-flex items-center rounded-l-lg border border-r-0 border-gray-300 bg-gray-50
                 px-3 text-sm text-gray-500 dark:border-gray-600 dark:bg-gray-700 dark:text-gray-400">
      https://
    </span>
    <input type="text" placeholder="www.example.com"
           class="block w-full min-w-0 flex-1 rounded-r-lg border border-gray-300 bg-white px-3 py-2
                  text-sm focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20 focus:outline-none
                  dark:border-gray-600 dark:bg-gray-800 dark:text-white" />
  </div>
</div>
```

### Floating Label
```html
<div class="relative">
  <input type="text" id="floating" placeholder=" " peer
         class="block w-full rounded-lg border border-gray-300 bg-white px-3 pb-2 pt-5
                text-sm focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20 focus:outline-none
                dark:border-gray-600 dark:bg-gray-800 dark:text-white" />
  <label for="floating"
         class="pointer-events-none absolute start-3 top-2 origin-[0] -translate-y-0 scale-75
                text-xs text-gray-500 transition-all duration-200
                peer-placeholder-shown:translate-y-2 peer-placeholder-shown:scale-100
                peer-placeholder-shown:text-sm
                peer-focus:-translate-y-0 peer-focus:scale-75 peer-focus:text-xs
                peer-focus:text-blue-600 dark:text-gray-400">
    Full Name
  </label>
</div>
```

### Select
```html
<div>
  <label class="block text-sm font-medium text-gray-700 dark:text-gray-300">Country</label>
  <select class="mt-1.5 block w-full rounded-lg border border-gray-300 bg-white px-3 py-2
                 text-sm shadow-sm focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20 focus:outline-none
                 dark:border-gray-600 dark:bg-gray-800 dark:text-white">
    <option value="">Select a country</option>
    <option>United States</option>
    <option>Canada</option>
    <option>United Kingdom</option>
  </select>
</div>
```

### Checkbox & Radio
```html
<!-- Checkbox -->
<label class="flex items-center gap-3 cursor-pointer">
  <input type="checkbox"
         class="size-4 rounded border-gray-300 text-blue-600 shadow-sm
                focus:ring-2 focus:ring-blue-500/20 focus:ring-offset-0
                dark:border-gray-600 dark:bg-gray-800 dark:checked:bg-blue-500" />
  <span class="text-sm text-gray-700 dark:text-gray-300">Remember me</span>
</label>

<!-- Radio group -->
<fieldset class="space-y-2">
  <legend class="text-sm font-medium text-gray-700 dark:text-gray-300">Plan</legend>
  <label class="flex items-center gap-3 cursor-pointer">
    <input type="radio" name="plan" value="free" checked
           class="size-4 border-gray-300 text-blue-600 shadow-sm
                  focus:ring-2 focus:ring-blue-500/20 focus:ring-offset-0
                  dark:border-gray-600 dark:bg-gray-800" />
    <span class="text-sm text-gray-700 dark:text-gray-300">Free</span>
  </label>
  <label class="flex items-center gap-3 cursor-pointer">
    <input type="radio" name="plan" value="pro"
           class="size-4 border-gray-300 text-blue-600 shadow-sm
                  focus:ring-2 focus:ring-blue-500/20 focus:ring-offset-0
                  dark:border-gray-600 dark:bg-gray-800" />
    <span class="text-sm text-gray-700 dark:text-gray-300">Pro — $9/mo</span>
  </label>
</fieldset>
```

### Textarea
```html
<div>
  <label for="message" class="block text-sm font-medium text-gray-700 dark:text-gray-300">Message</label>
  <textarea id="message" rows="4" placeholder="Write your message..."
            class="mt-1.5 block w-full rounded-lg border border-gray-300 bg-white px-3 py-2
                   text-sm shadow-sm placeholder:text-gray-400 resize-y
                   focus:border-blue-500 focus:ring-2 focus:ring-blue-500/20 focus:outline-none
                   dark:border-gray-600 dark:bg-gray-800 dark:text-white dark:placeholder:text-gray-500"></textarea>
  <p class="mt-1.5 text-xs text-gray-500 dark:text-gray-400">Max 500 characters</p>
</div>
```

### Toggle Switch
```html
<label class="inline-flex items-center gap-3 cursor-pointer">
  <span class="text-sm font-medium text-gray-700 dark:text-gray-300">Notifications</span>
  <div class="relative">
    <input type="checkbox" class="peer sr-only" />
    <div class="h-6 w-11 rounded-full bg-gray-200 peer-checked:bg-blue-600
                peer-focus-visible:ring-2 peer-focus-visible:ring-blue-500/20
                peer-focus-visible:ring-offset-2 transition-colors
                dark:bg-gray-700 dark:peer-checked:bg-blue-500"></div>
    <div class="absolute left-0.5 top-0.5 size-5 rounded-full bg-white shadow-sm
                transition-transform peer-checked:translate-x-5"></div>
  </div>
</label>
```

---

## Cards

### Basic Card
```html
<div class="rounded-xl border border-gray-200 bg-white p-6 shadow-sm
            dark:border-gray-700 dark:bg-gray-800">
  <h3 class="text-lg font-semibold text-gray-900 dark:text-white">Card Title</h3>
  <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">Card description with supporting text.</p>
  <div class="mt-4 flex gap-3">
    <button class="rounded-lg bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700">Action</button>
    <button class="rounded-lg px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-700">Cancel</button>
  </div>
</div>
```

### Card with Image
```html
<div class="overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm
            dark:border-gray-700 dark:bg-gray-800">
  <img src="..." alt="" class="aspect-video w-full object-cover" />
  <div class="p-6">
    <p class="text-xs font-medium uppercase tracking-wide text-blue-600 dark:text-blue-400">Category</p>
    <h3 class="mt-1 text-lg font-semibold text-gray-900 dark:text-white">Card Title</h3>
    <p class="mt-2 text-sm text-gray-600 dark:text-gray-400 line-clamp-2">Description text that might be long and will be clamped to two lines.</p>
    <div class="mt-4 flex items-center gap-3">
      <img src="..." alt="" class="size-8 rounded-full" />
      <div>
        <p class="text-sm font-medium text-gray-900 dark:text-white">Author Name</p>
        <p class="text-xs text-gray-500">Jan 15, 2025</p>
      </div>
    </div>
  </div>
</div>
```

### Horizontal Card (Responsive)
```html
<div class="flex flex-col sm:flex-row overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm
            dark:border-gray-700 dark:bg-gray-800">
  <img src="..." alt="" class="h-48 sm:h-auto sm:w-48 object-cover" />
  <div class="flex flex-1 flex-col justify-between p-6">
    <div>
      <h3 class="text-lg font-semibold text-gray-900 dark:text-white">Horizontal Card</h3>
      <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">Stacks vertically on mobile, horizontal on sm+.</p>
    </div>
    <a href="#" class="mt-4 text-sm font-medium text-blue-600 hover:text-blue-700 dark:text-blue-400">
      Read more →
    </a>
  </div>
</div>
```

### Interactive Card
```html
<a href="#" class="group block rounded-xl border border-gray-200 bg-white p-6 shadow-sm
                   transition-all hover:shadow-md hover:border-gray-300 hover:-translate-y-0.5
                   dark:border-gray-700 dark:bg-gray-800 dark:hover:border-gray-600">
  <div class="flex items-center gap-4">
    <div class="flex size-12 items-center justify-center rounded-lg bg-blue-100 text-blue-600
                group-hover:bg-blue-600 group-hover:text-white transition-colors
                dark:bg-blue-900/30 dark:text-blue-400">
      <svg class="size-6" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
    </div>
    <div>
      <h3 class="font-semibold text-gray-900 group-hover:text-blue-600 dark:text-white">Feature</h3>
      <p class="text-sm text-gray-500 dark:text-gray-400">Click to learn more</p>
    </div>
  </div>
</a>
```

---

## Modals / Dialogs

### Modal with Backdrop
```html
<!-- Backdrop -->
<div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm p-4">
  <!-- Modal -->
  <div class="w-full max-w-md rounded-xl bg-white p-6 shadow-xl
              dark:bg-gray-800" role="dialog" aria-modal="true" aria-labelledby="modal-title">
    <div class="flex items-center justify-between">
      <h2 id="modal-title" class="text-lg font-semibold text-gray-900 dark:text-white">Confirm Action</h2>
      <button class="rounded-lg p-1 text-gray-400 hover:bg-gray-100 hover:text-gray-600
                     dark:hover:bg-gray-700 dark:hover:text-gray-300" aria-label="Close">
        <svg class="size-5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
      </button>
    </div>
    <p class="mt-3 text-sm text-gray-600 dark:text-gray-400">
      Are you sure you want to proceed? This action cannot be undone.
    </p>
    <div class="mt-6 flex justify-end gap-3">
      <button class="rounded-lg px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-100
                     dark:text-gray-300 dark:hover:bg-gray-700">
        Cancel
      </button>
      <button class="rounded-lg bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700">
        Delete
      </button>
    </div>
  </div>
</div>
```

### Full-Screen Modal (Mobile)
```html
<div class="fixed inset-0 z-50 bg-black/50 p-4 sm:flex sm:items-center sm:justify-center">
  <div class="fixed inset-x-0 bottom-0 max-h-[90vh] overflow-y-auto rounded-t-2xl bg-white p-6
              sm:static sm:w-full sm:max-w-lg sm:rounded-xl
              dark:bg-gray-800">
    <!-- Sheet on mobile, centered modal on desktop -->
    <div class="mx-auto mb-4 h-1 w-12 rounded-full bg-gray-300 sm:hidden"></div>
    <h2 class="text-lg font-semibold text-gray-900 dark:text-white">Modal Title</h2>
    <div class="mt-4">Content here</div>
  </div>
</div>
```

---

## Dropdowns

### Dropdown Menu
```html
<div class="relative inline-block text-left">
  <button class="inline-flex items-center gap-1 rounded-lg border border-gray-300 bg-white px-4 py-2
                 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50
                 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-200">
    Options
    <svg class="size-4" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M5.23 7.21a.75.75 0 011.06.02L10 11.168l3.71-3.938a.75.75 0 111.08 1.04l-4.25 4.5a.75.75 0 01-1.08 0l-4.25-4.5a.75.75 0 01.02-1.06z" clip-rule="evenodd"/></svg>
  </button>
  <!-- Dropdown panel -->
  <div class="absolute right-0 z-10 mt-2 w-48 origin-top-right rounded-lg bg-white py-1 shadow-lg ring-1 ring-black/5
              dark:bg-gray-800 dark:ring-gray-700" role="menu">
    <a href="#" class="block px-4 py-2 text-sm text-gray-700 hover:bg-gray-100
                       dark:text-gray-300 dark:hover:bg-gray-700" role="menuitem">Edit</a>
    <a href="#" class="block px-4 py-2 text-sm text-gray-700 hover:bg-gray-100
                       dark:text-gray-300 dark:hover:bg-gray-700" role="menuitem">Duplicate</a>
    <hr class="my-1 border-gray-200 dark:border-gray-700" />
    <a href="#" class="block px-4 py-2 text-sm text-red-600 hover:bg-red-50
                       dark:text-red-400 dark:hover:bg-red-900/20" role="menuitem">Delete</a>
  </div>
</div>
```

---

## Navigation

### Navbar
```html
<nav class="sticky top-0 z-40 border-b border-gray-200 bg-white/80 backdrop-blur-lg
            dark:border-gray-800 dark:bg-gray-900/80">
  <div class="mx-auto flex h-16 max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8">
    <a href="/" class="text-xl font-bold text-gray-900 dark:text-white">Logo</a>
    <div class="hidden md:flex items-center gap-1">
      <a href="#" class="rounded-lg px-3 py-2 text-sm font-medium text-gray-900 hover:bg-gray-100
                         dark:text-white dark:hover:bg-gray-800">Dashboard</a>
      <a href="#" class="rounded-lg px-3 py-2 text-sm font-medium text-gray-500 hover:bg-gray-100 hover:text-gray-900
                         dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-white">Projects</a>
      <a href="#" class="rounded-lg px-3 py-2 text-sm font-medium text-gray-500 hover:bg-gray-100 hover:text-gray-900
                         dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-white">Settings</a>
    </div>
    <div class="flex items-center gap-3">
      <img src="..." alt="Avatar" class="size-8 rounded-full ring-2 ring-white dark:ring-gray-900" />
      <button class="md:hidden rounded-lg p-2 text-gray-500 hover:bg-gray-100
                     dark:text-gray-400 dark:hover:bg-gray-800" aria-label="Menu">
        <svg class="size-5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"/></svg>
      </button>
    </div>
  </div>
</nav>
```

### Sidebar
```html
<aside class="fixed inset-y-0 left-0 z-30 flex w-64 flex-col border-r border-gray-200 bg-white
              dark:border-gray-800 dark:bg-gray-900">
  <div class="flex h-16 items-center border-b border-gray-200 px-6 dark:border-gray-800">
    <span class="text-lg font-bold text-gray-900 dark:text-white">App</span>
  </div>
  <nav class="flex-1 overflow-y-auto p-4">
    <ul class="space-y-1">
      <li>
        <a href="#" class="flex items-center gap-3 rounded-lg bg-blue-50 px-3 py-2 text-sm font-medium text-blue-700
                          dark:bg-blue-900/30 dark:text-blue-300" aria-current="page">
          <svg class="size-5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-4 0h4"/></svg>
          Dashboard
        </a>
      </li>
      <li>
        <a href="#" class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium text-gray-700
                          hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800">
          <svg class="size-5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"/></svg>
          Users
        </a>
      </li>
      <li>
        <a href="#" class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium text-gray-700
                          hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800">
          <svg class="size-5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
          Settings
        </a>
      </li>
    </ul>
  </nav>
  <div class="border-t border-gray-200 p-4 dark:border-gray-800">
    <div class="flex items-center gap-3">
      <img src="..." alt="" class="size-9 rounded-full" />
      <div class="flex-1 truncate">
        <p class="text-sm font-medium text-gray-900 dark:text-white">John Doe</p>
        <p class="truncate text-xs text-gray-500">john@example.com</p>
      </div>
    </div>
  </div>
</aside>
```

### Breadcrumbs
```html
<nav aria-label="Breadcrumb">
  <ol class="flex items-center gap-1.5 text-sm">
    <li><a href="#" class="text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">Home</a></li>
    <li><svg class="size-4 text-gray-400" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z" clip-rule="evenodd"/></svg></li>
    <li><a href="#" class="text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">Projects</a></li>
    <li><svg class="size-4 text-gray-400" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z" clip-rule="evenodd"/></svg></li>
    <li><span class="font-medium text-gray-900 dark:text-white" aria-current="page">Settings</span></li>
  </ol>
</nav>
```

### Tabs
```html
<div>
  <div class="border-b border-gray-200 dark:border-gray-700">
    <nav class="-mb-px flex gap-1" role="tablist">
      <button class="border-b-2 border-blue-600 px-4 py-3 text-sm font-medium text-blue-600
                     dark:border-blue-400 dark:text-blue-400" role="tab" aria-selected="true">
        General
      </button>
      <button class="border-b-2 border-transparent px-4 py-3 text-sm font-medium text-gray-500
                     hover:border-gray-300 hover:text-gray-700
                     dark:text-gray-400 dark:hover:border-gray-600 dark:hover:text-gray-300" role="tab">
        Security
      </button>
      <button class="border-b-2 border-transparent px-4 py-3 text-sm font-medium text-gray-500
                     hover:border-gray-300 hover:text-gray-700
                     dark:text-gray-400 dark:hover:border-gray-600 dark:hover:text-gray-300" role="tab">
        Notifications
      </button>
    </nav>
  </div>
  <div class="p-4" role="tabpanel">Tab content here</div>
</div>
```

### Pill Tabs
```html
<nav class="flex gap-1 rounded-lg bg-gray-100 p-1 dark:bg-gray-800" role="tablist">
  <button class="rounded-md bg-white px-4 py-2 text-sm font-medium text-gray-900 shadow-sm
                 dark:bg-gray-700 dark:text-white" role="tab" aria-selected="true">
    Overview
  </button>
  <button class="rounded-md px-4 py-2 text-sm font-medium text-gray-500 hover:text-gray-700
                 dark:text-gray-400 dark:hover:text-gray-200" role="tab">
    Analytics
  </button>
  <button class="rounded-md px-4 py-2 text-sm font-medium text-gray-500 hover:text-gray-700
                 dark:text-gray-400 dark:hover:text-gray-200" role="tab">
    Reports
  </button>
</nav>
```

---

## Alerts / Toasts

### Alert Variants
```html
<!-- Info -->
<div class="flex gap-3 rounded-lg border border-blue-200 bg-blue-50 p-4
            dark:border-blue-800 dark:bg-blue-900/20" role="alert">
  <svg class="mt-0.5 size-5 flex-shrink-0 text-blue-600 dark:text-blue-400" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd"/></svg>
  <div>
    <h3 class="text-sm font-medium text-blue-800 dark:text-blue-300">Info</h3>
    <p class="mt-1 text-sm text-blue-700 dark:text-blue-400">A new version is available. Update now.</p>
  </div>
</div>

<!-- Success -->
<div class="flex gap-3 rounded-lg border border-green-200 bg-green-50 p-4
            dark:border-green-800 dark:bg-green-900/20" role="alert">
  <svg class="mt-0.5 size-5 flex-shrink-0 text-green-600 dark:text-green-400" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/></svg>
  <div>
    <h3 class="text-sm font-medium text-green-800 dark:text-green-300">Success</h3>
    <p class="mt-1 text-sm text-green-700 dark:text-green-400">Your changes have been saved.</p>
  </div>
</div>

<!-- Warning -->
<div class="flex gap-3 rounded-lg border border-yellow-200 bg-yellow-50 p-4
            dark:border-yellow-800 dark:bg-yellow-900/20" role="alert">
  <svg class="mt-0.5 size-5 flex-shrink-0 text-yellow-600 dark:text-yellow-400" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/></svg>
  <div>
    <h3 class="text-sm font-medium text-yellow-800 dark:text-yellow-300">Warning</h3>
    <p class="mt-1 text-sm text-yellow-700 dark:text-yellow-400">Your trial expires in 3 days.</p>
  </div>
</div>

<!-- Error -->
<div class="flex gap-3 rounded-lg border border-red-200 bg-red-50 p-4
            dark:border-red-800 dark:bg-red-900/20" role="alert">
  <svg class="mt-0.5 size-5 flex-shrink-0 text-red-600 dark:text-red-400" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/></svg>
  <div>
    <h3 class="text-sm font-medium text-red-800 dark:text-red-300">Error</h3>
    <p class="mt-1 text-sm text-red-700 dark:text-red-400">Failed to save. Please try again.</p>
  </div>
</div>
```

### Toast Notification
```html
<!-- Positioned in corner -->
<div class="fixed bottom-4 right-4 z-50 w-full max-w-sm">
  <div class="flex items-center gap-3 rounded-lg bg-white p-4 shadow-lg ring-1 ring-black/5
              dark:bg-gray-800 dark:ring-gray-700">
    <div class="flex size-10 flex-shrink-0 items-center justify-center rounded-full bg-green-100 text-green-600
                dark:bg-green-900/30 dark:text-green-400">
      <svg class="size-5" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/></svg>
    </div>
    <div class="flex-1">
      <p class="text-sm font-medium text-gray-900 dark:text-white">Saved successfully</p>
      <p class="mt-0.5 text-xs text-gray-500 dark:text-gray-400">Your changes are live.</p>
    </div>
    <button class="rounded p-1 text-gray-400 hover:text-gray-600 dark:hover:text-gray-300" aria-label="Dismiss">
      <svg class="size-4" viewBox="0 0 20 20" fill="currentColor"><path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z"/></svg>
    </button>
  </div>
</div>
```

---

## Tables

### Responsive Table
```html
<div class="overflow-x-auto rounded-lg border border-gray-200 dark:border-gray-700">
  <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
    <thead class="bg-gray-50 dark:bg-gray-800">
      <tr>
        <th scope="col" class="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500
                                dark:text-gray-400">Name</th>
        <th scope="col" class="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500
                                dark:text-gray-400">Status</th>
        <th scope="col" class="px-6 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500
                                dark:text-gray-400">Role</th>
        <th scope="col" class="px-6 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500
                                dark:text-gray-400">Actions</th>
      </tr>
    </thead>
    <tbody class="divide-y divide-gray-200 bg-white dark:divide-gray-700 dark:bg-gray-900">
      <tr class="hover:bg-gray-50 dark:hover:bg-gray-800/50">
        <td class="whitespace-nowrap px-6 py-4">
          <div class="flex items-center gap-3">
            <img src="..." alt="" class="size-8 rounded-full" />
            <div>
              <p class="text-sm font-medium text-gray-900 dark:text-white">Jane Cooper</p>
              <p class="text-xs text-gray-500">jane@example.com</p>
            </div>
          </div>
        </td>
        <td class="whitespace-nowrap px-6 py-4">
          <span class="inline-flex rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800
                       dark:bg-green-900/30 dark:text-green-400">Active</span>
        </td>
        <td class="whitespace-nowrap px-6 py-4 text-sm text-gray-500 dark:text-gray-400">Admin</td>
        <td class="whitespace-nowrap px-6 py-4 text-right">
          <button class="text-sm font-medium text-blue-600 hover:text-blue-700 dark:text-blue-400">Edit</button>
        </td>
      </tr>
    </tbody>
  </table>
</div>
```

### Sortable Column Header
```html
<th scope="col" class="group cursor-pointer px-6 py-3 text-left text-xs font-medium uppercase tracking-wider
                        text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
  <div class="flex items-center gap-1">
    Name
    <svg class="size-4 text-gray-400 group-hover:text-gray-600" viewBox="0 0 20 20" fill="currentColor">
      <path d="M10 3l-3.5 4h7L10 3zm0 14l3.5-4h-7L10 17z"/>
    </svg>
  </div>
</th>
```

---

## Pagination

### Simple Pagination
```html
<nav class="flex items-center justify-between border-t border-gray-200 px-4 py-3 dark:border-gray-700">
  <p class="text-sm text-gray-700 dark:text-gray-400">
    Showing <span class="font-medium">1</span> to <span class="font-medium">10</span> of
    <span class="font-medium">97</span> results
  </p>
  <div class="flex gap-1">
    <button class="rounded-lg border border-gray-300 px-3 py-2 text-sm font-medium text-gray-700
                   hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed
                   dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800" disabled>
      Previous
    </button>
    <button class="rounded-lg bg-blue-600 px-3.5 py-2 text-sm font-medium text-white">1</button>
    <button class="rounded-lg border border-gray-300 px-3.5 py-2 text-sm font-medium text-gray-700
                   hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800">2</button>
    <button class="rounded-lg border border-gray-300 px-3.5 py-2 text-sm font-medium text-gray-700
                   hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800">3</button>
    <span class="px-2 py-2 text-sm text-gray-500">...</span>
    <button class="rounded-lg border border-gray-300 px-3.5 py-2 text-sm font-medium text-gray-700
                   hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800">10</button>
    <button class="rounded-lg border border-gray-300 px-3 py-2 text-sm font-medium text-gray-700
                   hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800">
      Next
    </button>
  </div>
</nav>
```

---

## Badges / Chips

### Badge Variants
```html
<span class="inline-flex items-center rounded-full bg-gray-100 px-2.5 py-0.5 text-xs font-medium text-gray-800
             dark:bg-gray-700 dark:text-gray-300">Default</span>
<span class="inline-flex items-center rounded-full bg-blue-100 px-2.5 py-0.5 text-xs font-medium text-blue-800
             dark:bg-blue-900/30 dark:text-blue-400">Info</span>
<span class="inline-flex items-center rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800
             dark:bg-green-900/30 dark:text-green-400">Success</span>
<span class="inline-flex items-center rounded-full bg-yellow-100 px-2.5 py-0.5 text-xs font-medium text-yellow-800
             dark:bg-yellow-900/30 dark:text-yellow-400">Warning</span>
<span class="inline-flex items-center rounded-full bg-red-100 px-2.5 py-0.5 text-xs font-medium text-red-800
             dark:bg-red-900/30 dark:text-red-400">Error</span>
```

### Badge with Dot
```html
<span class="inline-flex items-center gap-1.5 rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800
             dark:bg-green-900/30 dark:text-green-400">
  <span class="size-1.5 rounded-full bg-green-600 dark:bg-green-400"></span>
  Online
</span>
```

### Removable Chip
```html
<span class="inline-flex items-center gap-1 rounded-full bg-blue-100 py-0.5 pl-2.5 pr-1 text-xs font-medium text-blue-800
             dark:bg-blue-900/30 dark:text-blue-400">
  React
  <button class="rounded-full p-0.5 hover:bg-blue-200 dark:hover:bg-blue-800" aria-label="Remove">
    <svg class="size-3" viewBox="0 0 20 20" fill="currentColor"><path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z"/></svg>
  </button>
</span>
```

---

## Avatar Groups

### Stacked Avatars
```html
<div class="flex -space-x-2">
  <img src="..." alt="User 1" class="size-8 rounded-full ring-2 ring-white dark:ring-gray-900" />
  <img src="..." alt="User 2" class="size-8 rounded-full ring-2 ring-white dark:ring-gray-900" />
  <img src="..." alt="User 3" class="size-8 rounded-full ring-2 ring-white dark:ring-gray-900" />
  <span class="flex size-8 items-center justify-center rounded-full bg-gray-200 text-xs font-medium text-gray-600
               ring-2 ring-white dark:bg-gray-700 dark:text-gray-300 dark:ring-gray-900">
    +5
  </span>
</div>
```

### Avatar with Status
```html
<div class="relative inline-block">
  <img src="..." alt="User" class="size-10 rounded-full" />
  <span class="absolute bottom-0 right-0 size-3 rounded-full border-2 border-white bg-green-500
               dark:border-gray-900"></span>
</div>
```

### Avatar with Initials
```html
<div class="flex size-10 items-center justify-center rounded-full bg-blue-600 text-sm font-medium text-white">
  JD
</div>
```

### Avatar Sizes
```html
<img src="..." alt="" class="size-6 rounded-full" />  <!-- xs -->
<img src="..." alt="" class="size-8 rounded-full" />  <!-- sm -->
<img src="..." alt="" class="size-10 rounded-full" /> <!-- md -->
<img src="..." alt="" class="size-12 rounded-full" /> <!-- lg -->
<img src="..." alt="" class="size-16 rounded-full" /> <!-- xl -->
```
