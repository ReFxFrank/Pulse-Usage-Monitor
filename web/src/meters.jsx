import { Card, InfoTip } from './panels.jsx';
import { durClock, useTick, ago, tokens, dayLabel } from './lib.js';

// "Account limits · official" — provider-issued usage gauges.
//  - Claude (opt-in): Anthropic's account meter via your local login — unified
//    across claude.ai chats, Claude Code, cloud sessions and other devices.
//  - Codex (automatic): the rate_limits snapshot each Codex turn writes into
//    its local rollout log — your ChatGPT plan's Codex allowance. Only as
//    fresh as your last Codex turn, so rows carry an "as of" tag.
//  - Codex tokens (opt-in): REAL account-wide token counts from the ChatGPT
//    usage endpoint — the one thing Anthropic's percent-only API can't give.
export function MetersCard({ meters, codex, codexUsage, delay = 0.18 }) {
  useTick(1000); // live reset countdowns
  const anth = meters && meters.enabled ? meters : null;
  const cxu = codexUsage && codexUsage.enabled ? codexUsage : null;
  if (!anth && !codex && !cxu) return null;

  const anthBody = anth && (() => {
    if (anth.status === 'loading') {
      return <div className="sub">Fetching official usage from your Claude account…</div>;
    }
    if (anth.status === 'no-login') {
      // Normal on a Codex-only machine — informative, not alarming.
      return <div className="sub">Claude meters: {anth.error || 'no Claude Code login on this machine.'}</div>;
    }
    const hasBars = anth.buckets && anth.buckets.length > 0;
    if (anth.status === 'expired' || anth.status === 'error' || anth.status === 'rate-limited') {
      // A throttled or failed refresh is not data loss: keep showing the last
      // good numbers with an honest note about their age.
      const note = anth.status === 'rate-limited'
        ? (anth.error || 'Anthropic rate-limited the usage check — Pulse backs off and retries automatically.')
        : (anth.error || anth.status);
      if (hasBars) {
        return (
          <>
            <MeterRows buckets={anth.buckets} />
            <div className="sub" style={{ marginTop: 8, color: anth.status === 'rate-limited' ? 'var(--text-3)' : 'var(--warn)' }}>
              {anth.lastGoodAt ? <>Showing numbers from <span className="mono">{ago(anth.lastGoodAt)}</span> — </> : null}{note}
            </div>
          </>
        );
      }
      return <div className="sub" style={{ color: anth.status === 'rate-limited' ? 'var(--text-3)' : 'var(--warn)' }}>{note}</div>;
    }
    if (!hasBars) {
      return <div className="sub">No usage buckets reported for this account.</div>;
    }
    return <MeterRows buckets={anth.buckets} />;
  })();

  return (
    <Card delay={delay} hover={false}>
      <h2 style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        Account limits · official
        <InfoTip text="Provider-issued meters, not estimates. Claude rows (opt-in, Server panel): Anthropic's own account gauge — unified across claude.ai chats, cloud sessions and every device; fetched with your local Claude login, read-only. Codex rows: the official allowance snapshot each Codex turn records in its local log — nothing leaves your machine, but it's only as fresh as your last Codex turn. Codex token totals (opt-in, same switch): real account-wide token counts from ChatGPT's usage endpoint, fetched with your local Codex login, read-only.">
          <span style={{ color: 'var(--text-3)', cursor: 'help', textTransform: 'none' }}>ⓘ</span>
        </InfoTip>
      </h2>
      {anthBody}
      {codex && codex.buckets && codex.buckets.length > 0 && (
        <>
          {anth && <div style={{ height: 10 }} />}
          <MeterRows buckets={codex.buckets} asOf={codex.asOf} />
          <div className="sub" style={{ marginTop: 8 }}>
            Codex meters are read from your local Codex logs — snapshot from your last turn,{' '}
            <span className="mono">{ago(codex.asOf)}</span>. Run any Codex turn to refresh.
          </div>
        </>
      )}
      <CodexTokens cxu={cxu} hasCodexRows={!!(codex && codex.buckets && codex.buckets.length)} />
    </Card>
  );
}

// Account-wide Codex token totals + a 30-day mini chart. Only renders when
// there's something real to show: stats (fresh or last-good), or an expired
// login worth mentioning on a machine that clearly uses Codex.
function CodexTokens({ cxu, hasCodexRows }) {
  if (!cxu) return null;
  const stats = cxu.stats;
  if (!stats) {
    if (cxu.status === 'expired' && hasCodexRows) {
      return <div className="sub" style={{ marginTop: 8, color: 'var(--warn)' }}>{cxu.error}</div>;
    }
    return null; // loading / no-login / nothing yet — stay quiet
  }
  const staleNote = cxu.status !== 'ok' && cxu.lastGoodAt
    ? <> · showing numbers from <span className="mono">{ago(cxu.lastGoodAt)}</span></>
    : null;
  const max = Math.max(1, ...stats.buckets.map((b) => b.tokens));
  return (
    <div className="cxu">
      <div className="cxu-line">
        Codex · account tokens <span className="cxu-scope">all devices</span>{' '}
        <b>{tokens(stats.todayTokens)}</b> today · <b>{tokens(stats.last7Tokens)}</b> past 7d
        {stats.lifetimeTokens != null && <> · <b>{tokens(stats.lifetimeTokens)}</b> lifetime</>}
      </div>
      {stats.buckets.length > 1 && (
        <div className="cxu-spark" aria-hidden="true">
          {stats.buckets.map((b) => (
            <i key={b.date} style={{ height: Math.max(6, (b.tokens / max) * 100) + '%' }}
               title={dayLabel(b.date) + ' — ' + tokens(b.tokens) + ' tokens'} />
          ))}
        </div>
      )}
      <div className="sub" style={{ marginTop: 6 }}>
        True token counts from your ChatGPT account (same numbers as Codex&apos;s own usage
        chart){staleNote}. Anthropic&apos;s API reports percentages only, so Claude has no
        equivalent.
      </div>
    </div>
  );
}

function MeterRows({ buckets, asOf }) {
  return (
    <div className="mrows">
      {buckets.map((b) => {
        const stale = !!b.stale;
        const level = b.pct >= 85 ? 'hot' : b.pct >= 60 ? 'warm' : '';
        const remaining = b.resetsAt ? b.resetsAt - Date.now() : null;
        return (
          <div className={'mrow' + (stale ? ' stale' : '')} key={b.key}>
            <div className="ml">{b.label}</div>
            <div className="mtrack"><i className={level} style={{ width: Math.max(1.5, b.pct) + '%' }} /></div>
            <div className="mv">{stale ? '—' : b.pct.toFixed(0) + '%'}</div>
            <div className="mr">
              {stale
                ? 'window rolled over — run a turn to refresh'
                : remaining != null && remaining > 0
                  ? <>resets in <b>{durClock(remaining)}</b></>
                  : b.resetsAt ? 'resetting…' : ''}
            </div>
          </div>
        );
      })}
    </div>
  );
}
