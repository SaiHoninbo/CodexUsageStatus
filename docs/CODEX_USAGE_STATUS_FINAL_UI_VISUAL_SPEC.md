# CodexUsageStatus Final UI Visual Spec

Status: canonical implementation target for `CODEX_USAGE_STATUS_FINAL_VISUAL_COMPOSITION_REDESIGN_V2`
Theme: fixed dark macOS-like glass
Surface boundary: HUD-only Token feedback

This document is the visual source of truth for the final HUD and the three-tab
Popover. It defines the visual target, not a requirement to use opaque RGB
fills. Existing data, security, cadence, sizing, drag, and feedback semantics
remain authoritative.

## Geometry compatibility

The existing geometry contract is retained. The standard HUD state is the
two-quota, no-Credits state:

| Token | Value |
| --- | ---: |
| Standard panel width | 416 pt |
| Standard panel height | 256.4 pt |
| Outer padding | 11 pt |
| Corner radius | 15.2 pt |
| Token summary height | 52 pt |
| Token summary gap | 5 pt |
| Header height | 22 pt |
| Header gap | 5 pt |
| Quota row height | 34 pt |
| Baseline quota row count | 2 |
| Quota gap | 5 pt |
| Section gap | 6 pt |
| Primary action height | 38.4 pt |
| Action spacing | 8 pt |
| Workflow action height | 28 pt |
| Workflow action gap | 5 pt |
| Credits section height | 52 pt |

`416 × 256.4` is not a forced height for every runtime state. The existing
`HUDMetrics.panelSize(quotaRowCount:includesCredits:)` behavior remains valid:

- an additional or missing quota row may change the height;
- a visible Credits section may change the height;
- every scale level preserves the existing ratios;
- AppKit positioning, drag, visibility, and panel-host contracts do not change.

Popover content width remains `430 pt`, with `20 pt` outer padding and `16 pt`
root section spacing. The existing tabs remain `Overview`, `History`, and
`Settings`.

## Material and surface language

The product visual direction is graphite dark glass, not flat dark cards and not
an adaptive Light/Dark theme.

Reference targets (not opaque RGB invariants):

```yaml
graphite_reference:
  panel: "#111317"
  elevated: "#191D22"
  control: "#232830"
```

Implementation may combine SwiftUI/AppKit `regularMaterial`, dark color
scheme, graphite overlays, opacity, borders, and shadow to reach the target.
Material translucency must remain perceptible. Do not flatten every surface
into an opaque RGB fill.

Reference surface behavior:

- panel: dark material with a restrained graphite tint;
- elevated section: a slightly brighter graphite material/overlay;
- control: a brighter, still subdued graphite surface;
- border: soft white/gray at approximately 16% opacity;
- divider: soft white/gray at approximately 12% opacity;
- shadow: low-contrast black shadow, approximately 35% opacity, without a
  floating-dashboard appearance.

## Color and typography

Primary text is high-contrast white. Secondary and tertiary text use distinct
gray levels. Numeric content uses stable-width/monospaced digits.

Semantic accents are restrained and meaningful:

| Meaning | Accent |
| --- | --- |
| 5-hour quota | orange |
| 7-day quota | blue |
| Token Activity | cyan/teal |
| Full Verify | purple |
| Continue/success | green |
| General metadata | graphite/gray |

Accent color may appear in an icon, rail, border, selected state, or soft fill;
it must not turn the complete HUD into a high-saturation dashboard.

Typography roles:

- HUD identity: compact rounded system semibold;
- HUD plan/status: compact medium/semibold;
- HUD metric labels: small medium gray;
- HUD metric values: bold rounded system with monospaced digits;
- HUD quota value: bold and visually primary, reset text secondary;
- HUD actions: semibold title with smaller shortcut/help text;
- Popover title: prominent semibold;
- Popover section title: semibold;
- Popover body/caption: readable white/gray hierarchy;
- chart numbers and Token totals: monospaced digits.

## Control states

All controls preserve their geometry in every state.

- normal: graphite control surface and standard border;
- hover: slightly brighter surface and border, no size change;
- pressed: stronger surface tint or accent border, no scale/layout jump;
- disabled: reduced opacity while retaining readable label/icon contrast;
- loading: progress indication inside the existing control boundary;
- focus: visible high-contrast focus border/indicator.

## HUD composition, hierarchy, and behavior

The HUD remains a glance surface, but its internal composition is deliberately
recomposed rather than being the former light dashboard recolored. Within the
existing adaptive panel geometry, the canonical order is:

1. compact header with current account identity, plan, and connection state;
2. restrained 5-hour and 7-day quota rows;
3. optional Credits row when the existing model exposes it;
4. a compact Token summary strip containing the five historical metrics;
5. `Paste`, `Paste and Submit`, and `Continue` as primary shortcut controls;
6. `Repair`, `Full Verify`, and `Commit + Push` as workflow shortcuts.

Quota accents use thin rails, semantic borders, and small value emphasis rather
than full-width saturated fills. The six actions use subdued graphite controls
with restrained semantic accents; they are not six bright dashboard tiles. The
old Token-first ordering is not a permitted runtime branch.

The six actions remain shortcuts only. Keeping `Commit + Push` does not restore
a Git client or Git workspace page.

Token feedback is consumed by the HUD only:

- lifetime Token uses the existing stable-slot odometer;
- only changed numeric digits receive the numeric transition;
- commas, separators, unchanged digits, and slot positions remain stable;
- normal animation duration is `0.6s`;
- Reduce Motion uses opacity crossfade at `0.18s`;
- changed secondary metrics receive only a subtle pulse;
- a qualifying generation plays at most one short sound using the existing
  `Tink → Glass → system beep` fallback;
- startup, cache hydration, equal/older/timestamp-only data, account/scope/
  range changes, and background profile callbacks stay silent and static.

No Token odometer, pulse, or Token sound is attached to Overview or History.

## Popover responsibilities

### Overview — 看現在

Keep current account identity, current quota, necessary current Turn state,
Reset Credit, and compact refresh/Open Codex actions. Remove historical Token
dashboard, complete account list, duplicate update surface, and all Token
feedback animation/sound.

### History — 看過去

This is the only complete Token historical home. Keep the five historical
metrics, daily Token chart, 7/30 range, and retained local quota history. Use
dark chart axes, muted grid, and restrained semantic bars. History is stable and
does not animate on Token updates.

### Settings — 管理與設定

Keep full account management, notifications, HUD settings, sync, software
update, metadata, and existing actions. Account management is the authoritative
expanded section. Notifications, HUD, Sync, Software Update, and Metadata /
Actions are independent compact disclosure groups, collapsed by default using
view-local presentation state only; disclosure state is not persisted. Sixteen
accounts and long account identifiers must remain readable in the scrollable
surface. Do not restore RSS, Feed, Announcement, Git workspace, or duplicate
account/Token pages.

The Popover header and Overview are compact utility surfaces: there is no giant
remaining-percent hero, old full-width quota card, or oversized account-scope
segmented control. Overview owns current state only; History owns the complete
Token historical detail.

## Non-negotiable boundaries

- No public API or runtime architecture change.
- Preserve `HUDPresentation`, `HUDPresentationBoundary`, `HUDMetrics`, Token
  feedback policy, odometer slot policy, sound gate, and Reduce Motion behavior.
- Preserve Quota `60s`, Token `900s`, and Account `1800s` cadence.
- No second Token calculation, second account manager, persistence/schema change,
  dependency change, or new product setting.
- No install, push, release, or commit in this implementation pass.

## Review captures

The temporary candidate must provide separate captures for:

1. HUD normal;
2. HUD during a real qualifying Token increase;
3. Overview;
4. History;
5. Settings account management;
6. Settings lower disclosure groups (Notifications, HUD, Sync, Software
   Update, Metadata / Actions).

The qualifying Token capture must come from the existing network callback. A
startup, cache, range, or account transition is not an acceptable substitute.
