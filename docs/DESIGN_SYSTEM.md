# Design System

A premium, quiet interface: graphite and silver with ice-blue and cyan light. The
metaphor is glass and instruments, not neon and dashboards.

## 1. Principles

1. **The assistant has a presence, not a mascot.** A single glass orb carries the
   state. It reacts to real audio and real work — never to a decorative timer.
2. **Depth without noise.** Frosted panels with hairline specular edges sit on an
   ambient background; there are no drop shadows, gradients-for-gradients or
   unnecessary borders.
3. **Honest colour.** Colour encodes meaning: ice = interactive, cyan = live
   activity, amber = attention/confirmation, rose = failure, mint = verified
   success. It is never used decoratively.
4. **Calm under motion.** Motion is short and spring-based. Reduce Motion collapses
   every animation to a state change.

## 2. Tokens (`JarvisTheme`)

| Group | Values |
|---|---|
| Palette | `ink`, `graphite`, `slate`, `glassTint` (dark surfaces); `silver`, `ice`, `cyan`, `amber`, `rose`, `mint` (light); semantic aliases `success`, `warning`, `danger`, `info`; scheme-aware `primaryText/secondaryText/tertiaryText/hairline/canvas/elevated` |
| Spacing | `hairline 2`, `xs 6`, `s 10`, `m 16`, `l 24`, `xl 32`, `xxl 44` |
| Radius | `small 12`, `medium 18`, `large 26`, `pill 999` |
| Typography | Rounded system faces: `display 34`, `title 24`, `headline 18`, `body 16`, `callout 15`, `caption 13`, `micro 11`, `timer` (monospaced 15). All fonts are Dynamic-Type aware relative sizes. |
| Motion | `snappy` (0.32 s spring), `smooth` (0.55 s spring), `gentle` (0.45 s ease) — each gated by `respectReduceMotion` |

## 3. Surfaces

`JarvisGlassSurface` is the single glass primitive, exposed as
`.jarvisGlass(prominence:cornerRadius:accent:)` with three prominences:
`subtle` (list rows), `regular` (cards), `strong` (composer, tab bar, sheets).

* On iOS 26 and later, with Swift 6.2 or later, it delegates to the system
  `glassEffect` so JARVIS matches the platform material.
* Everywhere else it composes an ultra-thin material, a specular highlight along
  the top edge, a hairline stroke and a tinted inner glow — the same visual result
  without private APIs.
* Optional accent tints the stroke and inner glow (for example amber on a
  confirmation card).

`AmbientBackground` renders the base canvas with two drifting radial lights over a
`Canvas`-drawn `OrbitalLattice` — a deterministic field of thin arcs. It is static
under Reduce Motion.

## 4. The orb (`JarvisOrb`)

Seven states, each with an animation profile from `AssistantState.animationProfile`:
idle (slow breathing, ice), listening (fast ripple driven by the microphone level,
cyan), thinking (rotating sweep, ice), speaking (silver pulses driven by playback),
executing (segmented progress ring, cyan), awaiting confirmation (amber pulse),
failed (rose, with a brief desaturating settle).

Supporting views: `WaveformBars` (bar heights from `WaveformMath.barHeight`, which
is pure and unit-tested), `ProcessingSweep`, `ProgressRing`, `ConfirmationPulse`,
and `AudioWaveformView` for measured live levels during dictation and playback.

Nothing in the orb uses random numbers: what you see is a function of state and
measured level, so it cannot misrepresent what the assistant is doing.

## 5. Components (`JarvisComponents`)

`GlassCard`, `GlassButton` (44 pt minimum target; disabled buttons expose
`disabledReason` as an accessibility hint), `StatusPill` (+
`StatusPill.forCapability(_:)` for honest capability states), `EmptyStateView`,
`OrbitalGlyph` (procedural artwork used in empty states), `InlineBanner`,
`SectionHeader`, `CapabilityRow`, `LoadingDots`, `MetricTile`.

## 6. Accessibility

* Dynamic Type: layout uses relative fonts and wraps rather than truncates.
* VoiceOver: the orb exposes a combined label describing the current state and
  hint; transcript rows are labelled ("You said…", "JARVIS replied…"); capability
  rows read their state and the reason it is unavailable; buttons announce their
  action and, when disabled, why.
* Reduce Motion: all animations are collapsed; the ambient background stops moving.
* Contrast: body text meets or exceeds 4.5:1 on both schemes; the accent palette is
  used at large sizes or for icons rather than small text on glass.
* Haptics: `Haptics.tap/success/warning/error/selection`, always tied to a real
  event (approval, failure, selection) rather than decoration.

## 7. Light and dark

Both schemes are first-class: the palette resolves canvas, elevated surfaces, text
and hairlines per scheme, and the glass fallback adapts (white-tinted material in
light mode, dark-tinted in dark mode). The app follows the system appearance by
default — `preferredColorScheme(nil)` — and never forces one.

## 8. Icon and artwork

`scripts/generate_app_icon.py` renders the app icon, a 180 pt preview, a
documentation hero and a lockup from geometry defined in that file (unit-sphere
shading, analytic specular and caustic fields, orbital arcs). Requirements it
satisfies: original work, no trademarks, opaque 1024² marketing icon, non-full-bleed
composition, and legibility at 40 pt.
