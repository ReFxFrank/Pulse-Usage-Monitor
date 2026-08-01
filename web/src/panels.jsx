import { useEffect, useRef, useState } from 'react';
import { motion, animate } from 'framer-motion';
import * as Select from '@radix-ui/react-select';
import * as Tooltip from '@radix-ui/react-tooltip';
import { ProgressRing } from './charts.jsx';
import { money, money2, tokens, num, pct, dur, durClock, hm, ago, dayLabel, ACCENT, perf, postJson } from './lib.js';
import { ModelLogo, modelFamily, FAMILY_META } from './logos.jsx';

const EASE = [0.2, 0.7, 0.2, 1];

// glass card with staggered entrance + hover lift (framer handles transform)
export function Card({ delay = 0, hover = true, className = '', children, ...rest }) {
  return (
    <motion.div
      className={'card ' + className}
      initial={{ opacity: 0, y: 16 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5, delay, ease: EASE }}
      whileHover={hover ? { y: -3 } : undefined}
      {...rest}
    >
      {children}
    </motion.div>
  );
}

// animates a number to its new value without per-frame React re-renders
export function AnimatedNumber({ value, format }) {
  const ref = useRef(null);
  const prev = useRef(value ?? 0);
  useEffect(() => {
    const from = prev.current;
    const to = value ?? 0;
    prev.current = to;
    // Lite mode / background tab: no 60fps text tween — jump to the value.
    if ((from === to || perf.lite || document.hidden) && ref.current) {
      ref.current.textContent = format(to);
      return;
    }
    const controls = animate(from, to, {
      duration: 0.9,
      ease: EASE,
      onUpdate: (v) => { if (ref.current) ref.current.textContent = format(v); },
    });
    return () => controls.stop();
  }, [value, format]);
  return <span ref={ref}>{format(value ?? 0)}</span>;
}

export function InfoTip({ children, text }) {
  return (
    <Tooltip.Provider delayDuration={120}>
      <Tooltip.Root>
        <Tooltip.Trigger asChild>{children}</Tooltip.Trigger>
        <Tooltip.Portal>
          <Tooltip.Content className="rtip" sideOffset={7}>
            {text}
            <Tooltip.Arrow style={{ fill: 'rgba(16,14,22,0.92)' }} />
          </Tooltip.Content>
        </Tooltip.Portal>
      </Tooltip.Root>
    </Tooltip.Provider>
  );
}

export function Legend({ period, colorMap, single }) {
  if (single) {
    return (
      <div className="legend">
        <span><i style={{ background: ACCENT }} />{period.sources[0] || 'cli'}</span>
      </div>
    );
  }
  return (
    <div className="legend">
      {(period.sources || []).map((s) => (
        <span key={s}><i style={{ background: colorMap.get(s) }} />{s}</span>
      ))}
    </div>
  );
}

// ---- current 5h block with reset ring ----
export function CurrentBlock({ cb, delay }) {
  // live re-render each second for the countdown
  useTickLocal();
  if (!cb) {
    return (
      <Card delay={delay} className="tile">
        <div className="label">Current 5h block</div>
        <div className="big muted">idle</div>
        <div className="sub">No active usage window. A new block starts on your next request.</div>
      </Card>
    );
  }
  const now = Date.now();
  const remaining = cb.end - now;
  const frac = 1 - Math.max(0, Math.min(1, (cb.end - cb.start) ? remaining / (cb.end - cb.start) : 0));
  return (
    <Card delay={delay} className="tile">
      <div className="label" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        Current 5h block
        <InfoTip text={cb.official
          ? 'Window timing comes from Anthropic’s official account meter (the same reset as /usage) — the exact true reset, covering usage on every device. Cost/tokens shown are this machine’s Claude contribution within that window; Codex has separate limits.'
          : 'Claude usage only (Codex has separate limits). Reconstructed from this machine’s logs: the first message after a ≥5h gap opens a 5-hour window. Claude’s REAL window is opened by your first message on any surface — claude.ai, mobile, another computer — so the actual reset can be earlier than shown. Enable account meters in the Server panel and this tile switches to the official timer automatically.'}>
          <span style={{ color: 'var(--text-3)', cursor: 'help', textTransform: 'none' }}>ⓘ</span>
        </InfoTip>
        {cb.official && <span className="offbadge">official</span>}
      </div>
      <div className="blockrow">
        <div className="col">
          <div className="big grad"><AnimatedNumber value={cb.cost} format={money2} /></div>
          <div className="sub">
            <span className="mono">{tokens(cb.tokens)}</span> tokens · <span className="mono">{num(cb.messages)}</span> msgs
          </div>
          {cb.vsPeakCostPct != null && (
            <div className="chip">vs heaviest block&nbsp;<b>{pct(cb.vsPeakCostPct)}</b></div>
          )}
        </div>
        <ProgressRing fraction={frac} size={96} stroke={9}>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', lineHeight: 1.15 }}>
            <span style={{ fontSize: 8.5, color: 'var(--text-3)', letterSpacing: '0.11em', textTransform: 'uppercase' }}>resets in</span>
            <span className="mono" style={{ fontSize: 14, color: 'var(--text)', fontWeight: 600, whiteSpace: 'nowrap', letterSpacing: '-0.02em' }}>{durClock(remaining)}</span>
          </div>
        </ProgressRing>
      </div>
      <div className="sub" style={{ marginTop: 12 }}>
        {hm(cb.start)} → {hm(cb.end)}{cb.official ? ' · synced to Anthropic’s clock' : ' · reconstructed'}
      </div>
    </Card>
  );
}

export function BurnRate({ burn, delay }) {
  return (
    <Card delay={delay} className="tile">
      <div className="label">Burn rate · 60 min</div>
      {!burn ? (
        <>
          <div className="big muted">—</div>
          <div className="sub">No activity in the last hour.</div>
        </>
      ) : (
        <>
          <div className="big">
            <AnimatedNumber value={burn.dollarsPerHour} format={money2} /><span className="unit">/hr</span>
          </div>
          <div className="sub">
            <span className="mono">{tokens(burn.tokensPerMin)}</span> tok/min · window {burn.elapsedMin.toFixed(0)}m
          </div>
        </>
      )}
    </Card>
  );
}

export function Rollup({ label, r, delay }) {
  return (
    <Card delay={delay} className="tile">
      <div className="label">{label}</div>
      <div className="big"><AnimatedNumber value={r.cost} format={money2} /></div>
      <div className="facts">
        <div className="fact">tokens<b>{tokens(r.tokens)}</b></div>
        <div className="fact">messages<b>{num(r.messages)}</b></div>
      </div>
    </Card>
  );
}

// speed chips — execution speed (fast vs standard) recorded in transcripts.
// `speeds` is a { speedName: count } map, or an array of names.
export function SpeedBadges({ speeds, align = 'flex-end' }) {
  let entries;
  if (Array.isArray(speeds)) entries = speeds.map((s) => [s, 0]);
  else entries = Object.entries(speeds || {}).sort((a, b) => b[1] - a[1]);
  if (!entries.length) return <span className="spd" style={{ justifyContent: align }} />;
  return (
    <span className="spd" style={{ justifyContent: align }}>
      {entries.map(([sp]) => (
        <span key={sp} className={'spdb' + (sp !== 'standard' ? ' hot' : '')}>{sp}</span>
      ))}
    </span>
  );
}

// effort chips — reasoning effort captured by Pulse's optional hook logging
// (node server.js --effort-setup). `efforts` is a {level: count} map or an
// array of level names; `ultracode` adds the ULTRA chip.
const EFFORT_ORDER = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
export function EffortBadges({ efforts, ultracode, align = 'flex-end' }) {
  let names;
  if (Array.isArray(efforts)) names = efforts.slice();
  else names = Object.keys(efforts || {});
  names = names.filter((n) => n && n !== 'ultracode');
  names.sort((a, b) => EFFORT_ORDER.indexOf(a) - EFFORT_ORDER.indexOf(b));
  if (!names.length && !ultracode) return null;
  return (
    <span className="spd" style={{ justifyContent: align }}>
      {ultracode && <span className="spdb ultra">ultra</span>}
      {names.map((n) => (
        <span key={n} className={'spdb e-' + n}>{n}</span>
      ))}
    </span>
  );
}

// Limit-alerts banner: the windows currently at/above a warning threshold.
// notifyState lets us offer to turn on desktop notifications inline.
export function AlertsBar({ alerts, notifyState, onEnableNotify }) {
  if (!alerts || !alerts.length) return null;
  // Only windows still *approaching* a limit reach here — the server drops any
  // that are already maxed out (a limit you've hit isn't one you're nearing).
  // Anomaly rows (opt-in spend spikes) carry their own `detail` text, no pct.
  // Headline follows the mix: anomaly-only, limits-only, or both.
  const hasAnomaly = alerts.some((a) => a.kind === 'anomaly');
  const anomalyOnly = hasAnomaly && alerts.every((a) => a.kind === 'anomaly');
  const headline = anomalyOnly ? 'Unusual spend —' : hasAnomaly ? 'Heads up —' : 'Approaching a limit —';
  return (
    <div className="alertbar" role="status">
      <span className="alertdot" />
      <span className="alerttxt">
        <b>{headline}</b>{' '}
        {alerts.map((a) => (a.kind === 'anomaly' ? a.detail : `${a.label} ${Math.round(a.pct)}%`)).join(' · ')}
      </span>
      {notifyState === 'default' && (
        <button className="btn ghost albtn" onClick={onEnableNotify}>Enable desktop alerts</button>
      )}
    </div>
  );
}

// Budget goal: progress toward a self-set monthly/weekly spend target, with an
// inline control to set/change/clear it. Colours shift ok → warn (≥80%) → over
// (≥100%). Renders a slim "set a budget" prompt when none is configured.
export function BudgetCard({ budget }) {
  const [editing, setEditing] = useState(false);
  const [amount, setAmount] = useState(budget ? String(budget.target) : '');
  const [period, setPeriod] = useState(budget ? budget.period : 'month');
  const [busy, setBusy] = useState(false);

  async function save(clear) {
    setBusy(true);
    try {
      const amt = clear ? 0 : parseFloat(amount);
      await postJson('/api/budget/set?amount=' + (isFinite(amt) ? amt : 0) + '&period=' + period);
      setEditing(false); // the 10s poll refreshes data.budget with the new spend
      if (clear) setAmount('');
    } catch (_) { /* leave the form open on failure */ }
    setBusy(false);
  }

  if (editing || !budget) {
    return (
      <div className="budgetcard set">
        <div className="bhead"><span className="blabel">Spend budget</span></div>
        {editing || !budget ? (
          <div className="bform">
            <span className="bcur">$</span>
            <input
              className="binput" type="number" min="0" step="1" inputMode="decimal"
              placeholder="e.g. 200" value={amount} autoFocus={editing}
              onChange={(e) => setAmount(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') save(false); }}
            />
            <div className="bperiod">
              {['month', 'week'].map((p) => (
                <button key={p} className={'bpchip' + (period === p ? ' on' : '')} onClick={() => setPeriod(p)}>/{p === 'month' ? 'mo' : 'wk'}</button>
              ))}
            </div>
            <button className="btn albtn" disabled={busy || !(parseFloat(amount) > 0)} onClick={() => save(false)}>Save</button>
            {budget && <button className="btn ghost albtn" disabled={busy} onClick={() => save(true)}>Clear</button>}
            {budget && <button className="btn ghost albtn" disabled={busy} onClick={() => { setEditing(false); setAmount(String(budget.target)); }}>Cancel</button>}
          </div>
        ) : (
          <button className="btn albtn" onClick={() => setEditing(true)}>Set a spend budget</button>
        )}
      </div>
    );
  }

  const p = Math.min(100, budget.pct);
  const msLeft = budget.resetsAt ? budget.resetsAt - Date.now() : null;
  // Monthly resets are days out — show "Nd" rather than hundreds of hours.
  const resetTxt = msLeft != null
    ? 'resets in ' + (msLeft >= 48 * 3600e3 ? Math.round(msLeft / 86400e3) + 'd' : dur(msLeft))
    : 'rolling 7 days';
  return (
    <div className={'budgetcard state-' + budget.state}>
      <div className="bhead">
        <span className="blabel">Budget · {budget.label}</span>
        <span className="bfig">
          <b>{money2(budget.spent)}</b> <span className="bof">of {money(budget.target)}</span>
          <span className="bpct">{Math.round(budget.pct)}%</span>
        </span>
        <button className="bedit" title="Change budget" onClick={() => { setEditing(true); setAmount(String(budget.target)); setPeriod(budget.period); }}>edit</button>
      </div>
      <div className="btrack"><div className="bfill" style={{ width: p + '%' }} /></div>
      <div className="bsub">
        {budget.state === 'over'
          ? <span className="bover">over by {money2(budget.spent - budget.target)}</span>
          : <span>{money2(budget.remaining)} left</span>}
        <span className="bsep">·</span>{resetTxt}
        {budget.projected != null && (
          <>
            <span className="bsep">·</span>
            <span className={'bpace' + (budget.projected > budget.target ? ' bad' : budget.projected >= 0.8 * budget.target ? ' warn' : '')}>
              on pace for ~{money(budget.projected)}
            </span>
          </>
        )}
      </div>
    </div>
  );
}

// ---- plan value ----
// What the subscription buys: the same usage repriced at API list prices,
// expressed as a multiple of what the plan costs. Under 1× is an ordinary
// quiet month, not a failure, so it is worded plainly and never coloured red.
const MONTHS_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function monthShort(key) {
  const m = parseInt(String(key).slice(5, 7), 10);
  return MONTHS_SHORT[m - 1] || key;
}
// 13.6× / 2.4× / 0.62× — enough precision to move month to month without
// implying more accuracy than list-price estimates have.
function multFmt(m) {
  if (m == null) return '—';
  return (m >= 10 ? m.toFixed(1) : m.toFixed(m < 1 ? 2 : 1)) + '×';
}

export function PlanValueCard({ plan }) {
  const [editing, setEditing] = useState(false);
  const [amount, setAmount] = useState(plan && plan.cost ? String(plan.cost) : '');
  const [label, setLabel] = useState((plan && plan.label) || '');
  const [busy, setBusy] = useState(false);
  if (!plan) return null; // server without the planValue block — stay silent

  async function save(clear) {
    setBusy(true);
    try {
      const amt = clear ? 0 : parseFloat(amount);
      await postJson('/api/plan/set?amount=' + (isFinite(amt) ? amt : 0)
        + '&label=' + encodeURIComponent(clear ? '' : label.trim()));
      setEditing(false); // the 10s poll brings back the recomputed planValue
      if (clear) { setAmount(''); setLabel(''); }
    } catch (_) { /* leave the form open on failure */ }
    setBusy(false);
  }

  if (editing || !plan.configured) {
    return (
      <div className="plancard set">
        <div className="phead"><span className="blabel">Plan value</span></div>
        <div className="pinvite">
          {/* Always the all-sources figure — the card is account-level and does
              not follow the dashboard's source filter, so it must say so. */}
          {plan.spend30 > 0 ? (
            <>You’ve run <b>{money2(plan.spend30)}</b> of list-priced usage across <b>all tracked tools</b> in the last 30 days. Tell Pulse what your subscription costs and it shows your usage as a multiple of it.</>
          ) : (
            <>Tell Pulse what your subscription costs each month and it shows your usage across all tracked tools as a multiple of it.</>
          )}
        </div>
        <div className="bform">
          <span className="bcur">$</span>
          <input
            className="binput" type="number" min="0" step="1" inputMode="decimal"
            placeholder="200" value={amount} autoFocus={editing}
            onChange={(e) => setAmount(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') save(false); }}
          />
          <span className="bcur">/mo</span>
          <input
            className="binput wide" type="text" maxLength={40}
            placeholder="plan name (optional)" value={label}
            onChange={(e) => setLabel(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') save(false); }}
          />
          <button className="btn albtn" disabled={busy || !(parseFloat(amount) > 0)} onClick={() => save(false)}>Save</button>
          {plan.configured && <button className="btn ghost albtn" disabled={busy} onClick={() => save(true)}>Clear</button>}
          {plan.configured && (
            <button className="btn ghost albtn" disabled={busy} onClick={() => { setEditing(false); setAmount(String(plan.cost)); setLabel(plan.label || ''); }}>Cancel</button>
          )}
        </div>
      </div>
    );
  }

  const under = plan.multiplier != null && plan.multiplier < 1;
  return (
    <div className={'plancard' + (under ? ' under' : '')}>
      <div className="phead">
        <span className="blabel">
          Plan value{plan.label ? ' · ' + plan.label : ''}&nbsp;
          <InfoTip text="Every tool Pulse tracks — Claude Code, Codex, Gemini CLI, Continue, Cline, Roo — repriced at each provider’s API list prices and divided by what you pay for the plan. Always all sources: a source filter narrows the dashboard, not what your subscription costs. It is not a bill and not a counterfactual — your plan never covered the non-Claude tools, and sources that record only local estimates (Continue) or their own cost figures (Cline, Roo) are folded in as-is, so read this as an estimate of what your usage is worth.">
            <span style={{ color: 'var(--text-3)', cursor: 'help' }}>ⓘ</span>
          </InfoTip>
        </span>
        <button className="bedit" title="Change plan cost" onClick={() => { setEditing(true); setAmount(String(plan.cost)); setLabel(plan.label || ''); }}>edit</button>
      </div>
      <div className="prow">
        <div className="phero">
          <div className="pmult">{multFmt(plan.multiplier)}</div>
          <div className="pcap">{under ? 'of your plan cost' : 'your plan’s cost'}</div>
        </div>
        <div className="pbody">
          <div className="pline">
            <b>{money2(plan.spend30)}</b> of list-priced usage across all sources in the last 30 days
            {' '}vs <b>{money(plan.cost)}</b>/mo{plan.label ? ' ' + plan.label : ''}
          </div>
          {/* Not a pay-as-you-go counterfactual: spend30 spans every tracked
              tool, including providers the subscription never covered and
              sources that only record local estimates. State what it is. */}
          <div className="psub">
            {under
              ? 'A quieter window — everything Pulse tracked priced under the plan’s monthly cost.'
              : `${money2(plan.spend30 - plan.cost)} more than the plan costs, counting every tracked tool — not only the work the subscription covers.`}
          </div>
          <PlanMonths months={plan.months} cost={plan.cost} />
        </div>
      </div>
    </div>
  );
}

// Calendar-month history, oldest first, with a dashed break-even line at the
// plan's monthly cost — the point where the multiplier crosses 1×.
// The current month is only partly spent but is divided by a FULL month of
// plan cost, so it must never be drawn as an under-break-even month: the
// server flags it `partial` and it gets its own hatched treatment, "so far"
// wording, and a pace figure instead of a verdict.
function PlanMonths({ months, cost }) {
  if (!months || months.length < 2) return null;
  let max = cost > 0 ? cost : 0;
  months.forEach((m) => { if (m.spend > max) max = m.spend; });
  if (max <= 0) return null;
  const breakEven = cost > 0 ? (cost / max) * 100 : null;
  const hasPartial = months.some((m) => m.partial);
  const tip = (m) => {
    if (!m.partial) return `${m.key} — ${money2(m.spend)} of list-priced usage · ${multFmt(m.multiplier)} plan cost`;
    const el = typeof m.elapsedFraction === 'number' ? m.elapsedFraction : null;
    // Too little of the month has elapsed for a straight-line pace to mean
    // anything, so it is simply omitted rather than shown as a wild number.
    const pace = el != null && el >= 0.05 ? ` · on pace for ~${money2(m.spend / el)}` : '';
    return `${m.key} — partial month, ${money2(m.spend)} of list-priced usage so far`
      + (el != null ? ` (${Math.round(el * 100)}% elapsed)` : '')
      + ` · ${multFmt(m.multiplier)} plan cost so far${pace}`;
  };
  return (
    <div className="pmwrap">
      <div className="pmbars">
        {breakEven != null && <span className="pmline0" style={{ bottom: breakEven + '%' }} />}
        {months.map((m) => (
          <InfoTip key={m.key} text={tip(m)}>
            <div className="pmcol">
              <i
                className={m.partial ? 'partial' : (m.multiplier != null && m.multiplier < 1 ? 'under' : '')}
                style={{ height: Math.max(2, (m.spend / max) * 100) + '%' }}
              />
            </div>
          </InfoTip>
        ))}
      </div>
      <div className="pmlabels">
        {months.map((m) => <span key={m.key} className={m.partial ? 'partial' : ''}>{monthShort(m.key)}</span>)}
      </div>
      {hasPartial && <div className="pmnote">Newest bar is the current month so far — a partial month against a full month’s plan cost.</div>}
    </div>
  );
}

// ---- prompt-cache economics ----
// Leads with the NET: reading from the cache is cheap, but writing to it costs
// a premium over plain input, and a window can genuinely come out behind. A
// negative net is shown as a negative number, never clamped to zero.
// Both this strip and the fast-mode one below are accumulated from the LIVE
// logs only (per-entry token types and speed exist nowhere else — the archive
// keeps day/model totals), while the period's headline cost merges live and
// archived days. On a long window the live share can be a small fraction of
// the headline sitting right above it, so say so rather than letting the
// number read as if it covered the whole period. Under ~1% of drift is
// rounding, not a caveat worth the noise.
function coverageNote(period) {
  if (!period) return null;
  const cost = period.cost || 0;
  const live = period.liveCost;
  if (typeof live !== 'number' || cost <= 0 || live >= cost * 0.99) return null;
  return `covers ${money2(live)} of this period’s ${money2(cost)} still in your logs`;
}

export function CacheSavings({ cache, period }) {
  if (!cache || (!cache.readTokens && !cache.writePremium)) return null;
  const neg = cache.net < 0;
  const cov = coverageNote(period);
  return (
    <div className={'cachesave' + (neg ? ' neg' : '')}>
      <span className="cstag">cache</span>
      <b>{(neg ? '−' : '') + money2(Math.abs(cache.net))}</b>
      <span className="cscap">net {neg ? 'cost' : 'saved'}</span>
      <span className="cssep">·</span>
      <span className="csdim">
        {money2(cache.saved)} off {tokens(cache.readTokens)} cached read tokens,
        less {money2(cache.writePremium)} paid to write the cache
      </span>
      {cov && <span className="cscov">{cov}</span>}
      <InfoTip text="Cache reads bill at a fraction of the input rate; cache writes bill above it (25% extra for the 5-minute TTL, 100% for the 1-hour TTL). Net is the read saving minus that write premium, priced per entry at each model’s own rate — so it can be negative when a window writes more cache than it reuses. Cache-write surcharges are an Anthropic pricing feature: entries from other providers (OpenAI, Google) carry no write premium and contribute only their read saving. Covers the sessions still in your logs — the long-window archive keeps day/model totals, not per-entry token types.">
        <span style={{ color: 'var(--text-3)', cursor: 'help' }}>ⓘ</span>
      </InfoTip>
    </div>
  );
}

// ---- fast-mode premium ----
// Only fast usage is interesting here; with no fast entries this is a row of
// zeros, so the whole strip stays hidden.
export function FastSpendNote({ speed, period }) {
  if (!speed || !speed.fast || !speed.fast.messages) return null;
  const std = speed.standard || { cost: 0, messages: 0 };
  const cov = coverageNote(period); // same live-only caveat as the cache strip
  return (
    <div className="fastspend">
      <span className="spdb hot">fast</span>
      <b>{money2(speed.fastPremium)}</b>
      <span className="cscap">above standard rates</span>
      <span className="cssep">·</span>
      <span className="csdim">
        {money2(speed.fast.cost)} over {num(speed.fast.messages)} fast msgs ({tokens(speed.fast.tokens)})
        {std.messages ? ` · ${money2(std.cost)} standard` : ''}
      </span>
      {cov && <span className="cscov">{cov}</span>}
      <InfoTip text="Fast mode bills at a higher per-token rate on the models that offer it. The premium is what those same messages would have cost at that model’s standard rate, subtracted from what they actually cost. Covers the sessions still in your logs — the long-window archive keeps day/model totals, not per-entry speed.">
        <span style={{ color: 'var(--text-3)', cursor: 'help' }}>ⓘ</span>
      </InfoTip>
    </div>
  );
}

// ---- Meshy · 3D generation credits ----
// Meshy bills in CREDITS and publishes no credit→dollar rate, so this card is
// deliberately quarantined from every dollar figure on the page: its own unit
// chip, its own accent, no "$" anywhere, and nothing here is ever added to
// spend, plan value or a period cost. Inventing a rate would be exactly the
// confidently-wrong number Pulse exists to avoid.

// Every task family Meshy documents. Only some have a list endpoint Pulse can
// confirm; the payload reports which ones actually answered, and anything
// missing is named out loud rather than quietly rounded to "everything".
// Mirrors the server's MESHY_FAMILIES probe list; anything the payload reports
// that isn't here is still shown, it just doesn't affect the "missing" list.
const MESHY_FAMILIES = [
  'text-to-3d', 'image-to-3d', 'multi-image-to-3d', 'text-to-texture',
  'retexture', 'remesh', 'rigging', 'animation',
];
const MESHY_TYPE_LABEL = {
  'text-to-3d': 'Text to 3D',
  'image-to-3d': 'Image to 3D',
  'multi-image-to-3d': 'Multi-image to 3D',
  'text-to-texture': 'Text to texture',
  retexture: 'Retexture',
  remesh: 'Remesh',
  rigging: 'Rigging',
  animation: 'Animation',
};
const meshyTypeLabel = (t) => MESHY_TYPE_LABEL[t] || t;

// Credits are whole-number-ish; never formatted like money.
function creditsFmt(v) {
  if (v == null) return '—';
  const n = Number(v);
  if (!isFinite(n)) return '—';
  if (Math.abs(n) >= 1000) return Math.round(n).toLocaleString();
  return (Math.round(n * 10) / 10).toLocaleString();
}

// Set / replace / remove the Meshy API key. The key is a SECRET: it goes in the
// POST body, it is wiped from component state the moment it is sent, and the
// server never echoes it back — the UI only ever learns that one is set.
export function MeshyKeyForm({ hasKey, onDone, onCancel }) {
  const [key, setKey] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);

  async function save() {
    const k = key.trim();
    if (!k) return;
    setBusy(true); setErr(null);
    try {
      await postJson('/api/meshy/enable', { key: k });
      setKey(''); // don't keep the secret around any longer than the request
      onDone && onDone();
    } catch (e) { setErr(e.message); }
    setBusy(false);
  }

  async function remove() {
    setBusy(true); setErr(null);
    try {
      // An empty key clears it server-side; consent stays as it is, so the card
      // falls back to its setup state instead of vanishing.
      await postJson('/api/meshy/enable', { key: '' });
      setKey('');
      onDone && onDone();
    } catch (e) { setErr(e.message); }
    setBusy(false);
  }

  return (
    <div className="msh-keyform">
      <div className="bform">
        <input
          className="binput wide"
          type="password"
          autoComplete="off"
          spellCheck={false}
          placeholder={hasKey ? 'paste a new Meshy API key' : 'paste your Meshy API key'}
          value={key}
          onChange={(e) => setKey(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') save(); }}
        />
        <button className="btn albtn" disabled={busy || !key.trim()} onClick={save}>
          {busy ? 'Saving…' : hasKey ? 'Replace key' : 'Save key'}
        </button>
        {hasKey && <button className="btn ghost albtn" disabled={busy} onClick={remove}>Remove key</button>}
        {onCancel && <button className="btn ghost albtn" disabled={busy} onClick={onCancel}>Cancel</button>}
      </div>
      {err && <div className="msh-note bad">Couldn’t save the key: {err}</div>}
    </div>
  );
}

function MeshyHead({ children }) {
  return (
    <h2 style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      Meshy · 3D generation
      <span className="msh-unit">credits</span>
      <InfoTip text="Meshy charges in credits, and there is no published credit-to-dollar rate — so Pulse reports credits as their own unit and never converts them. Nothing on this card is part of your spend, budget or plan value. Read with an opt-in Meshy API key, sent only to api.meshy.ai.">
        <span style={{ color: 'var(--text-3)', cursor: 'help', textTransform: 'none' }}>ⓘ</span>
      </InfoTip>
      <span style={{ marginLeft: 'auto', display: 'inline-flex', gap: 8 }}>{children}</span>
    </h2>
  );
}

export function MeshyCard({ meshy, delay = 0.19 }) {
  const [editing, setEditing] = useState(false);
  // 'disabled' (and a server that predates the block) means: not opted in.
  // The card disappears entirely — the Server panel is where you turn it on.
  if (!meshy || !meshy.enabled || meshy.status === 'disabled') return null;

  // No key yet: an invitation, not an error.
  if (!meshy.hasKey || meshy.status === 'no-key') {
    return (
      <Card delay={delay} hover={false} className="meshycard">
        <MeshyHead />
        <div className="msh-invite">
          Meshy generates 3D assets and bills in <b>credits</b>. Paste an API key and Pulse shows your
          remaining balance and the credits your generations consumed — kept in its own unit, never
          converted to dollars and never mixed into your spend.
        </div>
        <MeshyKeyForm hasKey={false} />
        <div className="msh-fine">
          Create a key in your Meshy account settings. Pulse stores it in <code>~/.pulse/config.json</code>{' '}
          on this machine, sends it only to <code>api.meshy.ai</code>, and never logs it or puts it in a
          page, a URL or an export.
        </div>
      </Card>
    );
  }

  const c = meshy.credits || {};
  const daily = Array.isArray(meshy.daily) ? meshy.daily : [];
  const types = Object.entries(meshy.byType || {})
    .filter(([, v]) => v && ((v.credits || 0) > 0 || (v.tasks || 0) > 0))
    .sort((a, b) => (b[1].credits || 0) - (a[1].credits || 0));
  const maxDaily = daily.reduce((m, d) => Math.max(m, d.credits || 0), 0);
  const maxType = types.reduce((m, t) => Math.max(m, t[1].credits || 0), 0) || 1;
  const totalTasks = types.reduce((n, t) => n + (t[1].tasks || 0), 0);
  const hasHistory = maxDaily > 0 || types.length > 0;

  const families = Array.isArray(meshy.families) ? meshy.families : [];
  const missing = MESHY_FAMILIES.filter((f) => !families.includes(f));

  // A failed or throttled refresh is not data loss: keep the last good numbers
  // and say plainly how old they are. The server also reports 'stale' before
  // its very first fetch lands — nothing is wrong then, so that case gets its
  // own wording instead of an implied failure.
  const degraded = meshy.status === 'stale' || meshy.status === 'error';
  const bad = meshy.status === 'error';
  const firstRead = meshy.status === 'stale' && !meshy.fetchedAt && !meshy.error;

  return (
    <Card delay={delay} hover={false} className={'meshycard' + (degraded ? ' degraded' : '')}>
      <MeshyHead>
        <button className="bedit" title="Replace or remove the stored Meshy API key" onClick={() => setEditing(!editing)}>
          {editing ? 'close' : 'key'}
        </button>
      </MeshyHead>

      {editing && <MeshyKeyForm hasKey onDone={() => setEditing(false)} onCancel={() => setEditing(false)} />}

      <div className="msh-row">
        <div className="msh-hero">
          <div className="msh-bal">{creditsFmt(meshy.balance)}</div>
          <div className="msh-cap">credits left</div>
        </div>
        <div className="msh-used">
          <div className="msh-usedlbl">credits used</div>
          <div className="msh-stats">
            <div className="msh-stat"><span>today</span><b>{creditsFmt(c.today)}</b></div>
            <div className="msh-stat"><span>last 7 days</span><b>{creditsFmt(c.week)}</b></div>
            <div className="msh-stat"><span>last 30 days</span><b>{creditsFmt(c.month)}</b></div>
            <div className="msh-stat">
              <span>
                tracked total&nbsp;
                <InfoTip text="Everything in Pulse’s local Meshy cache. Pulse pages back about 30 days the first time it reads your account, so generations older than that are not counted here.">
                  <span style={{ color: 'var(--text-3)', cursor: 'help' }}>ⓘ</span>
                </InfoTip>
              </span>
              <b>{creditsFmt(c.allTime)}</b>
            </div>
          </div>
        </div>
      </div>

      {hasHistory ? (
        <>
          <div className="msh-sechead">
            <span>Credits per day</span>
            <em>last {daily.length || 30} days · hover a bar</em>
          </div>
          <div className="msh-daily" aria-hidden="true">
            {daily.map((d) => (
              <i
                key={d.date}
                className={(d.credits || 0) > 0 ? '' : 'zero'}
                style={{ height: maxDaily > 0 ? Math.max(3, ((d.credits || 0) / maxDaily) * 100) + '%' : '3%' }}
                title={`${dayLabel(d.date)} — ${creditsFmt(d.credits)} credit${(d.credits || 0) === 1 ? '' : 's'} · ${num(d.tasks || 0)} task${(d.tasks || 0) === 1 ? '' : 's'}`}
              />
            ))}
          </div>

          {types.length > 0 && (
            <>
              <div className="msh-sechead">
                <span>By task type</span>
                <em>{num(totalTasks)} task{totalTasks === 1 ? '' : 's'} tracked</em>
              </div>
              <div className="msh-types">
                {types.map(([t, v]) => (
                  <div className="msh-type" key={t}>
                    <div className="msh-tn">{meshyTypeLabel(t)}</div>
                    <div className="msh-ttrack">
                      <i style={{ width: Math.max(2, ((v.credits || 0) / maxType) * 100) + '%' }} />
                    </div>
                    <div className="msh-tv">{creditsFmt(v.credits)} <small>· {num(v.tasks || 0)} task{(v.tasks || 0) === 1 ? '' : 's'}</small></div>
                  </div>
                ))}
              </div>
            </>
          )}
        </>
      ) : (
        <div className="sub" style={{ marginTop: 12 }}>
          {meshy.fetchedAt
            ? 'No generations in the last 30 days — the balance above is straight from your Meshy account.'
            : 'Nothing read from your Meshy account yet.'}
        </div>
      )}

      {/* Coverage honesty: only the families that actually answered are counted.
          Before the first read nothing has been probed, so there is nothing
          honest to say yet — the note waits rather than indicting every family. */}
      {missing.length > 0 && (families.length > 0 || !!meshy.fetchedAt) && (
        <div className="msh-fine">
          Counting {families.length ? <b>{families.join(', ')}</b> : <b>no task family yet</b>}.
          {' '}Credits spent on <b>{missing.join(', ')}</b> are <b>not</b> included — Meshy exposes no
          list endpoint Pulse could confirm for {missing.length === 1 ? 'it' : 'those'}, so the balance
          can fall by more than the usage shown here.
        </div>
      )}

      {degraded && (
        <div className={'msh-note' + (bad ? ' bad' : '')}>
          {firstRead ? 'Reading your Meshy account now — the numbers above come from Pulse’s local cache until it lands.' : (
            <>
              {meshy.fetchedAt
                ? <>Showing the last good numbers from <span className="mono">{ago(meshy.fetchedAt)}</span> — </>
                : null}
              {meshy.error || (bad ? 'the last Meshy refresh failed.' : 'Meshy is not responding; Pulse backs off and retries.')}
              {bad && ' If the key was revoked, replace it with the “key” button above.'}
            </>
          )}
        </div>
      )}
      {!degraded && meshy.fetchedAt && (
        <div className="msh-fine">
          Read from your Meshy account <span className="mono">{ago(meshy.fetchedAt)}</span>, at most every 15 minutes.
        </div>
      )}
    </Card>
  );
}

// Activity heatmap: weekday × hour, shaded by cost (messages on hover). A model
// only appears if it's in the logs, so the grid reflects real working hours.
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
export function Heatmap({ heatmap }) {
  if (!heatmap || !heatmap.grid) return null;
  const max = heatmap.maxCost > 0 ? heatmap.maxCost : 1;
  const HOURS = [0, 3, 6, 9, 12, 15, 18, 21];
  const hourLabel = (h) => (h === 0 ? '12a' : h === 12 ? '12p' : h < 12 ? h + 'a' : (h - 12) + 'p');
  return (
    <div className="heatmap">
      <div className="hm-hours">
        <span className="hm-daylabel" />
        {Array.from({ length: 24 }, (_, h) => (
          <span key={h} className="hm-hlabel">{HOURS.includes(h) ? hourLabel(h) : ''}</span>
        ))}
      </div>
      {heatmap.grid.map((row, d) => (
        <div className="hm-row" key={d}>
          <span className="hm-daylabel">{WEEKDAYS[d]}</span>
          {row.map((c, h) => {
            const intensity = c.cost > 0 ? 0.14 + 0.86 * Math.sqrt(c.cost / max) : 0;
            return (
              <InfoTip key={h} text={`${WEEKDAYS[d]} ${hourLabel(h)}–${hourLabel((h + 1) % 24)} — ${money2(c.cost)} · ${tokens(c.tokens)} tokens · ${num(c.messages)} msgs`}>
                <span className="hm-cell" style={{ background: c.cost > 0 ? `rgba(155,140,255,${intensity})` : undefined }} />
              </InfoTip>
            );
          })}
        </div>
      ))}
    </div>
  );
}

// horizontal bars for by-model / by-source. `modelLogos` swaps the color chip
// for a provider mark (recognized per model family) on the by-model list.
// Long lists clamp to the top N with an inline expander — a 17-project card
// must not tower over its 3-row neighbour (the grid sizes cards to content),
// and the top rows are what you look at anyway. Bars are pre-sorted by cost.
const CLAMP_ROWS = 8;
function useClamp(rows) {
  const [open, setOpen] = useState(false);
  const more = rows.length - CLAMP_ROWS;
  const shown = open || more <= 0 ? rows : rows.slice(0, CLAMP_ROWS);
  const toggle = more > 0 ? (
    <button className="barmore" onClick={() => setOpen(!open)}>
      {open ? 'show less ▴' : `show all ${rows.length} ▾`}
    </button>
  ) : null;
  return [shown, toggle];
}

export function BarList({ rows, modelLogos = false, estimatedSources = [] }) {
  let max = 0;
  rows.forEach((r) => { if (r.cost > max) max = r.cost; });
  if (max <= 0) max = 1;
  const est = new Set(estimatedSources);
  const [shown, moreToggle] = useClamp(rows);
  return (
    <>
      {/* the bar encodes spend, not tokens — spell it out so a low-token but
          costly model (or vice-versa) never looks mis-sized next to its numbers. */}
      <div className="barhint">bar length = spend · numbers show $ · tokens</div>
      <div className="hbars">
      {shown.map((r) => (
        <InfoTip key={r.name} text={`${modelLogos ? FAMILY_META[modelFamily(r.name)].label + ' · ' : ''}${r.name} — ${money2(r.cost)} · ${tokens(r.tokens)} tokens · ${num(r.messages)} msgs`}>
          <div className="hbar">
            <div className="nm">{modelLogos ? <ModelLogo model={r.name} size={16} /> : <i style={{ background: r.color }} />}{r.name}{est.has(r.name) && <sup className="estmark" title="Locally-estimated usage, not provider-billed">est</sup>}</div>
            <div className="track">
              <motion.i
                style={{ background: r.color }}
                initial={{ width: 0 }}
                animate={{ width: Math.max(2, (r.cost / max) * 100) + '%' }}
                transition={{ duration: 0.7, ease: EASE }}
              />
            </div>
            <div className="v">{money2(r.cost)} <small>· {tokens(r.tokens)}</small></div>
            <span className="spd" style={{ justifyContent: 'flex-end' }}>
              <EffortBadges efforts={r.efforts} ultracode={!!r.ultracode} align="flex-end" />
              <SpeedBadges speeds={onlyNonStandard(r.speeds)} />
            </span>
          </div>
        </InfoTip>
      ))}
      </div>
      {moreToggle}
    </>
  );
}

// Spend broken down by reasoning-effort level (incl. ultracode / default) —
// bars colored to match the effort-chip heat ramp.
const EFFORT_SPEND_ORDER = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultracode', 'default'];
const EFFORT_BAR_COLORS = {
  minimal: '#8a8f98', low: '#22b892', medium: '#4a9bf5', high: '#9b8cff',
  xhigh: '#e0a132', max: '#f27878', ultracode: '#c07be0', default: '#5b6270',
};
export function EffortSpendBars({ spend }) {
  const keys = EFFORT_SPEND_ORDER.filter((k) => spend && spend[k] && spend[k].cost > 0);
  if (!keys.length) {
    return <div className="sub" style={{ marginTop: 4 }}>No effort recorded in this window — set a level with <code>/effort</code> and it appears here.</div>;
  }
  let max = 0;
  keys.forEach((k) => { if (spend[k].cost > max) max = spend[k].cost; });
  if (max <= 0) max = 1;
  const label = (k) => (k === 'ultracode' ? 'ultra' : k);
  const cls = (k) => (k === 'ultracode' ? 'spdb ultra' : k === 'default' ? 'spdb' : 'spdb e-' + k);
  return (
    <div className="hbars">
      {keys.map((k) => (
        <InfoTip key={k} text={`${label(k)} — ${money2(spend[k].cost)} · ${tokens(spend[k].tokens)} tokens · ${num(spend[k].messages)} msgs`}>
          <div className="hbar">
            <div className="nm"><span className={cls(k)}>{label(k)}</span></div>
            <div className="track">
              <motion.i style={{ background: EFFORT_BAR_COLORS[k] }} initial={{ width: 0 }}
                animate={{ width: Math.max(2, (spend[k].cost / max) * 100) + '%' }} transition={{ duration: 0.7, ease: EASE }} />
            </div>
            <div className="v">{money2(spend[k].cost)} <small>· {tokens(spend[k].tokens)}</small></div>
          </div>
        </InfoTip>
      ))}
    </div>
  );
}

// Spend by project (working directory). Rows arrive pre-sorted by cost; we show
// the folder name and keep the full path in the tooltip.
function projectBase(p) {
  const s = String(p).replace(/[\\/]+$/, '');
  const i = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
  return i >= 0 ? s.slice(i + 1) : s;
}
export function ProjectBars({ rows }) {
  if (!rows || !rows.length) return <div className="sub" style={{ marginTop: 4 }}>No project activity in this window.</div>;
  let max = 0;
  rows.forEach((r) => { if (r.cost > max) max = r.cost; });
  if (max <= 0) max = 1;
  const [shown, moreToggle] = useClamp(rows);
  return (
    <>
    <div className="hbars">
      {shown.map((r) => {
        const special = r.project === '(other)' || r.project === '(unknown)';
        const name = special ? r.project : projectBase(r.project);
        return (
          <InfoTip key={r.project} text={`${r.project} — ${money2(r.cost)} · ${tokens(r.tokens)} tokens · ${num(r.messages)} msgs · ${num(r.sessions)} sessions`}>
            <div className="hbar">
              <div className="nm" style={special ? { color: 'var(--text-3)', fontStyle: 'italic' } : null}>{name}</div>
              <div className="track">
                <motion.i style={{ background: 'linear-gradient(90deg, #6f8cff, #9b8cff)' }} initial={{ width: 0 }}
                  animate={{ width: Math.max(2, (r.cost / max) * 100) + '%' }} transition={{ duration: 0.7, ease: EASE }} />
              </div>
              <div className="v">{money2(r.cost)} <small>· {tokens(r.tokens)}</small></div>
            </div>
          </InfoTip>
        );
      })}
    </div>
    {moreToggle}
    </>
  );
}

// with effort chips present, a "standard" speed chip on every row is noise —
// keep speed chips for the interesting case (fast) only
function onlyNonStandard(speeds) {
  const out = {};
  for (const [k, v] of Object.entries(speeds || {})) if (k !== 'standard') out[k] = v;
  return out;
}

export function SessionsTable({ sessions }) {
  if (!sessions || !sessions.length) return <div className="sub">No sessions yet.</div>;
  return (
    <div className="scrollx">
      <table>
        <thead>
          <tr>
            <th>Session</th><th>Source</th><th>Mode</th><th>Model(s)</th>
            <th className="n">Cost</th><th className="n">Tokens</th><th className="n">Msgs</th><th className="n">Last</th>
          </tr>
        </thead>
        <tbody>
          {sessions.map((s) => (
            <tr key={s.sessionId}>
              <td className="title">{s.title}</td>
              <td><span className="badge">{s.source}</span></td>
              <td>
                <span className="spd" style={{ justifyContent: 'flex-start' }}>
                  <EffortBadges efforts={s.efforts} ultracode={!!s.ultracode} align="flex-start" />
                  <SpeedBadges speeds={(s.speeds || []).filter((x) => x !== 'standard')} align="flex-start" />
                  {!(s.efforts && s.efforts.length) && !s.ultracode && !(s.speeds || []).some((x) => x !== 'standard') && (
                    <span style={{ color: 'var(--text-3)', fontFamily: 'var(--mono)', fontSize: 11 }}>—</span>
                  )}
                </span>
              </td>
              <td style={{ color: 'var(--text-3)' }}>
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
                  {s.models.map((mdl) => (
                    <span key={mdl} style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
                      <ModelLogo model={mdl} size={13} />{mdl}
                    </span>
                  ))}
                </span>
              </td>
              <td className="n">{money2(s.cost)}</td>
              <td className="n">{tokens(s.tokens)}</td>
              <td className="n">{num(s.messages)}</td>
              <td className="n tago">{ago(s.lastTs)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function PeriodSelect({ periods, value, onChange }) {
  return (
    <Select.Root value={value} onValueChange={onChange}>
      <Select.Trigger className="selTrigger" aria-label="Spend period">
        <Select.Value />
        <Select.Icon className="chev">▾</Select.Icon>
      </Select.Trigger>
      <Select.Portal>
        <Select.Content className="selContent" position="popper" sideOffset={6} align="end">
          <Select.Viewport>
            {periods.map((p) => (
              <Select.Item key={p.key} value={p.key} className="selItem">
                <Select.ItemText>{p.label} — {money2(p.cost)}</Select.ItemText>
              </Select.Item>
            ))}
          </Select.Viewport>
        </Select.Content>
      </Select.Portal>
    </Select.Root>
  );
}

// local 1s ticker (useState/useEffect imported at the top of the file)
function useTickLocal() {
  const [, set] = useState(0);
  useEffect(() => {
    const id = setInterval(() => set((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, []);
}
