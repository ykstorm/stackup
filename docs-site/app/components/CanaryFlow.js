// The demo canary, drawn from helm/demo/templates/rollout.yaml and
// analysis-template.yaml with the default values. Every stroke and label
// uses currentColor, so the diagram follows the page's light or dark theme.
const BOXES = [
  { x: 4, y: 92, w: 124, h: 52, label: 'git push', sub: ['image.tag: v2'] },
  { x: 182, y: 92, w: 140, h: 52, label: 'ArgoCD sync', sub: ['polls every 3m'] },
  { x: 376, y: 92, w: 144, h: 52, label: 'Rollout 25%', sub: ['1 new pod, 2 old'] },
  { x: 594, y: 85, w: 150, h: 66, label: 'AnalysisRun', sub: ['PromQL ≥ 0.95', '3 runs, 30s apart'] },
  { x: 790, y: 16, w: 126, h: 52, label: '50, 75, 100%', sub: ['30s pauses'] },
  { x: 790, y: 168, w: 126, h: 52, label: 'abort', sub: ['old pods serve'], dashed: true },
];

const EDGES = [
  { d: 'M128 118 H176' },
  { d: 'M322 118 H370', label: 'apply', x: 346, y: 108 },
  { d: 'M520 118 H588', label: 'pause 30s', x: 554, y: 108 },
  { d: 'M744 104 C766 104 766 42 784 42', label: 'pass', x: 764, y: 70, anchor: 'end' },
  { d: 'M744 132 C766 132 766 194 784 194', label: '2 failures', x: 764, y: 178, anchor: 'end', dashed: true },
];

const DASH = '5 4';

export default function CanaryFlow() {
  return (
    <svg className="canary-flow" viewBox="0 0 920 236" role="img" aria-labelledby="cf-title cf-desc">
      <title id="cf-title">The demo canary, from a git push to promote or abort</title>
      <desc id="cf-desc">
        A push changes helm/demo. ArgoCD syncs it and updates the Rollout, which moves to a 25% weight
        (one new pod next to two old ones) and pauses 30 seconds. An AnalysisRun then queries Prometheus
        three times, 30 seconds apart. While the success rate stays at or above 0.95 the rollout continues
        to 50, 75 and 100 percent with 30-second pauses. After two failed measurements it aborts and the
        old pods keep serving.
      </desc>
      <defs>
        <marker id="cf-arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8"
          markerUnits="userSpaceOnUse" orient="auto">
          <path d="M0 0 L10 5 L0 10 Z" fill="currentColor" />
        </marker>
      </defs>
      <g fill="none" stroke="currentColor" strokeWidth="1.5">
        {BOXES.map((b) => (
          <rect key={b.label} x={b.x} y={b.y} width={b.w} height={b.h} rx="4"
            strokeDasharray={b.dashed ? DASH : undefined} />
        ))}
        {EDGES.map((e) => (
          <path key={e.d} d={e.d} markerEnd="url(#cf-arrow)" strokeDasharray={e.dashed ? DASH : undefined} />
        ))}
      </g>
      <g fill="currentColor" textAnchor="middle">
        {BOXES.map((b) => (
          <text key={b.label} x={b.x + b.w / 2} y={b.y + 21}>
            {b.label}
            {b.sub.map((s, i) => (
              <tspan key={s} className="sub" x={b.x + b.w / 2} dy={i === 0 ? 19 : 17}>{s}</tspan>
            ))}
          </text>
        ))}
        {EDGES.filter((e) => e.label).map((e) => (
          <text key={e.label} className="sub" x={e.x} y={e.y} textAnchor={e.anchor || 'middle'}>
            {e.label}
          </text>
        ))}
      </g>
    </svg>
  );
}
