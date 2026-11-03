# Teafair Official Design Specification

Brand design tokens for Teafair, derived from the logo.

The app is styled with **Tailwind / NativeWind**, mapped to the custom
`teafair-*` tokens below. **Never use stock Tailwind classes** (e.g.
`emerald-500`, `slate-900`) for Teafair brand elements: their values differ
from the logo's HEX codes. Always use the `teafair-*` classes defined in
`tailwind.config.js` (§3).

## 1. Brand Color Board & HEX Codes

| Token | HEX | Use | Tailwind / NativeWind class | CSS variable |
|---|---|---|---|---|
| **Teafair Emerald** | `#4CAF50` | Primary brand, active states, and buttons | `bg-teafair-emerald` / `text-teafair-emerald` | `var(--teafair-emerald)` |
| **Leaf Lime** | `#8BC34A` | Secondary brand, success badges, and highlights | `bg-teafair-lime` / `text-teafair-lime` | `var(--teafair-lime)` |
| **Deep Forest Green** | `#2E7D32` | Outer seal border, footers, and headers | `bg-teafair-forest` / `text-teafair-forest` | `var(--teafair-forest)` |
| **Midnight Core / Black** | `#111111` | Logotype `TF` and primary typography | `text-teafair-black` / `bg-teafair-black` | `var(--teafair-black)` |
| **Pure White** | `#FFFFFF` | Inner background and card surfaces | `bg-teafair-white` / `text-teafair-white` | `var(--teafair-white)` |
| **Soft Mist Gray** | `#F5F7F6` | Neutral backgrounds and input fields | `bg-teafair-surface` / `border-teafair-surface` | `var(--teafair-surface)` |
| **Dark Surface End** | `#1A2E1B` | End stop of the dark mode surface gradient | `to-teafair-darkSurfaceEnd` | `var(--teafair-dark-surface-end)` |

## 2. Signature Gradients

**Agricultural Emerald Gradient** (primary CTA / banners)

```css
linear-gradient(135deg, #2E7D32 0%, #4CAF50 50%, #8BC34A 100%)
```

Tailwind: `bg-gradient-to-br from-teafair-forest via-teafair-emerald to-teafair-lime`

**Fresh Leaf Glow** (card backgrounds & success states)

```css
linear-gradient(180deg, rgba(139, 195, 74, 0.15) 0%, rgba(76, 175, 80, 0.05) 100%)
```

Tailwind: `bg-gradient-to-b from-teafair-lime/15 to-teafair-emerald/5`

**Dark Mode Surface Gradient**

```css
linear-gradient(145deg, #111111 0%, #1A2E1B 100%)
```

Tailwind: `bg-gradient-to-br from-teafair-black to-teafair-darkSurfaceEnd`

## 3. Tailwind Configuration Token (`tailwind.config.js`)

```javascript
module.exports = {
  theme: {
    extend: {
      colors: {
        teafair: {
          emerald: '#4CAF50',
          lime: '#8BC34A',
          forest: '#2E7D32',
          black: '#111111',
          surface: '#F5F7F6', // --teafair-surface
          white: '#FFFFFF',
          darkSurfaceEnd: '#1A2E1B', // --teafair-dark-surface-end
        },
      },
    },
  },
};
```
