# Teafair Official Design Specification

Brand and interface tokens for Teafair, from the Teafair emblem. This file is
the single source of the values. `docs/spec-b-client.md` §4 is the contract
that uses them (layouts, components, skeletons), and
`src/shared/tokens/` (Spec B) is the only code that holds them.

The app is styled with **NativeWind** in two layers:

1. **Primitives** (`teafair-*`, §1): fixed colours with no meaning.
2. **Semantic tokens** (§3): what components use. Each resolves to a
   primitive per theme.

**Components and screens use semantic classes only.** No hex, `rgb()` or
`hsl()` literals, no stock Tailwind palette classes (`emerald-500`,
`slate-900`, …), and no `teafair-*` primitive class outside
`src/shared/tokens/` and the emblem component. `tokens.guard.test.ts` and
ESLint enforce it.

## 1. Primitives: the emblem palette and the status colours

| Primitive | HEX | Role |
|---|---|---|
| `teafair-leaf` | `#629E28` | primary leaf green: actions, selection, progress, brand marks |
| `teafair-botanical` | `#1B3624` | secondary botanical dark: strong actions, headers, dark surfaces |
| `teafair-amber` | `#D97706` | accent: warnings, the one highlight on a screen |
| `teafair-canvas` | `#F4F6F9` | app background |
| `teafair-white` | `#FFFFFF` | surfaces, cards, sheets |
| `teafair-scrim` | `#111827` at 35% opacity | modal and sheet overlay |
| `teafair-ink` | `#0F172A` | primary text; the dark canvas |
| `teafair-slate` | `#64748B` | secondary text; control borders |
| `teafair-mist` | `#E2E8F0` | hairlines; muted text on dark |
| `teafair-red` | `#B91C1C` | danger on light themes |
| `teafair-red-soft` | `#F87171` | danger on the dark theme |
| `teafair-red-tint` | `#FEF2F2` | danger subtle background (light themes) |
| `teafair-blue` | `#0369A1` | info on light themes |
| `teafair-sky` | `#38BDF8` | info on the dark theme |
| `teafair-blue-tint` | `#F0F9FF` | info subtle background (light themes) |

The previous palette is retired. These names replace `teafair-emerald`,
`-lime`, `-forest`, `-black`, `-surface` and `-darkSurfaceEnd`, and nothing
may use the old names.

## 2. Contrast (WCAG 2.1, measured)

Text needs 4.5:1. Large text (18 px bold or 24 px) and non-text marks
(icons, borders, focus rings, indicators) need 3:1.

| Foreground on background | Ratio | Allowed for |
|---|---|---|
| ink on white / on canvas | 17.85 / 16.49 | all text |
| slate on white / on canvas | 4.76 / 4.40 | text on white; on canvas only 14 px semibold or larger |
| white on botanical | 13.13 | all text (the default primary button) |
| ink on leaf | 5.48 | all text on a leaf fill |
| white on leaf | 3.26 | large text and marks only |
| ink on amber | 5.60 | all text on an amber fill |
| white on amber | 3.19 | never for text |
| red on white / on canvas / on red-tint | 6.47 / 5.98 / 5.91 | all text; white on red is 6.47 |
| blue on white / on canvas / on blue-tint | 5.93 / 5.48 / 5.57 | all text; white on blue is 5.93 |
| canvas on ink / on botanical | 16.49 / 12.12 | dark theme text |
| mist on ink / on botanical | 14.48 / 10.65 | dark theme muted text and control borders |
| red-soft on ink / on botanical | 6.45 / 4.75 | dark theme danger |
| sky on ink / on botanical | 8.33 / 6.13 | dark theme info |
| leaf on botanical | 4.03 | dark theme marks and large text |
| mist on white | 1.23 | separators only, never a control boundary |
| red / blue on ink | 2.76 / 3.01 | never: the dark theme uses red-soft and sky |

`tokens/contrast.test.ts` holds every pair a theme uses, with its minimum,
and fails on any pair below it.

## 3. Semantic tokens per theme

Three themes. The role default applies until the user chooses (Spec B
§4.2, `usePrefsStore`):

- **`standard`:** the default for operational and tenant roles: ZSM, ASM,
  DSM, DSA, LOGISTICS_MANAGER, CLIENT_SERVICE_MANAGER, TENANT_ADMIN, and
  Monvelo agent members.
- **`daylight`:** high contrast for outdoor field work. The default for
  ZSA, ASA, TM, RETAIL_SHOP_OWNER and POS_AGENT.
- **`dark`:** for analytical views (dashboards, ledgers, reconciliation),
  by the user's choice.

| Semantic token | `standard` | `daylight` | `dark` |
|---|---|---|---|
| `canvas` | canvas | white | ink |
| `surface` | white | white | botanical |
| `scrim` | scrim | scrim | scrim |
| `ink` | ink | ink | canvas |
| `ink-muted` | slate | ink | mist |
| `hairline` | mist | slate | mist |
| `control` (input borders, checkboxes) | slate | ink | mist |
| `focus` | botanical (2 px ring) | ink (3 px ring) | leaf (2 px ring) |
| `action` (fill) / `on-action` | leaf / ink | botanical / white | leaf / ink |
| `action-strong` / `on-action-strong` | botanical / white | ink / white | canvas / ink |
| `skeleton` / `skeleton-highlight` | mist / canvas | mist / white | ink / botanical |

**Tones.** `SemanticTone` is `neutral | brand | success | warning | danger |
info | pending`. Each tone has a mark colour (icon, border, indicator), a
text colour, and a subtle background:

| Tone | Mark | Text (light / dark) | Subtle background (light / dark) |
|---|---|---|---|
| `neutral` | slate | ink-muted / mist | canvas / ink |
| `brand` | leaf | botanical / canvas | canvas / ink |
| `success` | leaf | botanical / canvas | canvas / ink |
| `warning` | amber | ink / canvas | canvas / ink |
| `danger` | red (dark: red-soft) | red / red-soft | red-tint / ink |
| `info` | blue (dark: sky) | blue / sky | blue-tint / ink |
| `pending` | slate | ink / canvas | canvas / ink |

Success and brand text is botanical, not leaf (leaf is 3.26:1 on white), and
warning text is ink, not amber (3.19:1). The colour of those tones is
carried by the mark.

**Status is never colour alone.** Every `Badge` and `Banner` takes a tone,
a label in words and an icon. The props are required, and there is no
colour-only variant. Each tone has a fixed icon:

| Tone | Icon |
|---|---|
| `neutral` | dot |
| `brand` | leaf |
| `success` | check |
| `warning` | triangle with an exclamation mark |
| `danger` | octagon with an exclamation mark |
| `info` | "i" in a circle |
| `pending` | clock |

The daylight theme draws every tone mark at full strength and gives badges a
1.5 px border.

## 4. Brand gradients (brand moments only)

Gradients appear only on the sign-in screen, the splash and empty states.
They never appear in a list, a form, a queue, a ledger or a workflow (Spec B
§4.1).

**Emblem Gradient** (sign-in hero, splash)

```css
linear-gradient(135deg, #1B3624 0%, #629E28 100%)
```

Tailwind: `bg-gradient-to-br from-teafair-botanical to-teafair-leaf` (brand components only)

**Leaf Glow** (empty states)

```css
linear-gradient(180deg, rgba(98, 158, 40, 0.12) 0%, rgba(98, 158, 40, 0) 100%)
```

Tailwind: `bg-gradient-to-b from-teafair-leaf/10 to-transparent`

**Dark Brand Surface** (dark-theme splash)

```css
linear-gradient(145deg, #0F172A 0%, #1B3624 100%)
```

Tailwind: `bg-gradient-to-br from-teafair-ink to-teafair-botanical`

## 5. Tailwind / NativeWind configuration

The primitives are plain colours. The semantic tokens are CSS variables that
each theme sets, so switching theme swaps variables and no class changes.
The real file lives in `src/shared/tokens/` and is exported as the NativeWind
preset (Spec B §4.2); this is its shape.

```javascript
// src/shared/tokens/preset.js (shape)
module.exports = {
  theme: {
    extend: {
      colors: {
        teafair: {
          leaf: '#629E28',
          botanical: '#1B3624',
          amber: '#D97706',
          canvas: '#F4F6F9',
          white: '#FFFFFF',
          scrim: 'rgba(17, 24, 39, 0.35)', // #111827 at 35%
          ink: '#0F172A',
          slate: '#64748B',
          mist: '#E2E8F0',
          red: '#B91C1C',
          'red-soft': '#F87171',
          'red-tint': '#FEF2F2',
          blue: '#0369A1',
          sky: '#38BDF8',
          'blue-tint': '#F0F9FF',
        },
        // semantic: every component class uses these
        canvas: 'var(--canvas)',
        surface: 'var(--surface)',
        scrim: 'var(--scrim)',
        ink: { DEFAULT: 'var(--ink)', muted: 'var(--ink-muted)' },
        hairline: 'var(--hairline)',
        control: 'var(--control)',
        focus: 'var(--focus)',
        action: { DEFAULT: 'var(--action)', on: 'var(--on-action)',
                  strong: 'var(--action-strong)', 'on-strong': 'var(--on-action-strong)' },
        skeleton: { DEFAULT: 'var(--skeleton)', highlight: 'var(--skeleton-highlight)' },
        tone: {
          // one of each per tone: neutral, brand, success, warning, danger, info, pending
          'danger-mark': 'var(--tone-danger-mark)',
          'danger-text': 'var(--tone-danger-text)',
          'danger-subtle': 'var(--tone-danger-subtle)',
          // …
        },
      },
    },
  },
};
```
